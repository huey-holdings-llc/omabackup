#!/usr/bin/env bash
# Health checks: one collection pass shared by `status` (lib/widget.sh) and
# `health` (cmd_health below). Ported from
# hp-laptop-config/bin/widget-helper.sh:40-155 (the JSON severity model --
# drift/uncommitted = attention, everything else = fault) and
# hp-laptop-config/bin/health-check.sh:42-173 (the login-shell nag, which
# reuses the same collection instead of re-deriving it).
#
# FAIL CLOSED: an unreadable or garbage manifests/.last-run falls back to the
# last commit time, and if THAT is unavailable too it is itself a problem --
# never silently "no news is good news". A stamp in the future is its own
# problem, not a negative age nobody notices.
# shellcheck shell=bash

# health_setup_state: one of not-configured, gitleaks-missing,
# remote-unverified, ready. Surfaced as status.json's "setup" field so the
# widget can render a "finish setup" card instead of a blank badge.
health_setup_state() {
  config_exists || { echo not-configured; return; }
  [[ -f "$DATA_REPO/.omabackup" ]] || { echo not-configured; return; }
  gitleaks_available || { echo gitleaks-missing; return; }
  local url slug; url=$(remote_origin_url); slug=$(remote_github_slug "$url")
  if [[ -n "$url" && -z "$slug" && "$CFG_REMOTE_TRUSTED" != true ]]; then echo remote-unverified; return; fi
  echo ready
}

# health_not_configured_json: the schema-complete status object for when
# there is no config at all -- cmd_status/cmd_health never run in that case
# (bin/omabackup skips config_load for status/health specifically so it can
# still report SOMETHING), so this is the one place that builds the object
# instead, with a null/empty value for everything health_collect would
# otherwise have derived. health_setup_state is still the single owner of
# "setup": called here, before any config_load/data_repo_require has run, its
# own config_exists early return is what actually fires (DATA_REPO is never
# touched on this path).
health_not_configured_json() {
  local setup; setup=$(health_setup_state)
  jq -cn \
    --arg setup "$setup" \
    --argjson generated "$(date +%s)" \
    '{state:"attention", setup:$setup, repo:"", generated:$generated,
      last_run:0, last_run_age_days:-1,
      drift_scan_complete:false, drift_count:0, drift_truncated:false, drift:[],
      unpushed:0, diverged:false, push_verifiable:false, uncommitted:[],
      timers_checked:false, timer_enabled:false, timer_active:false, timer_next:"",
      selftest_enabled:false, selftest_active:false, problems:[]}'
}

# health_collect: fills the H_* globals below. Callers must have DATA_REPO
# set (config_load) and the repo validated (data_repo_require) first.
health_collect() {
  H_PROBLEMS=()
  local now last
  now=$(date +%s)

  # --- last successful RUN, not last commit: an unchanged machine commits
  # nothing, so a quiet-but-healthy machine must not read as stale.
  last=""
  if [[ -r "$DATA_REPO/manifests/.last-run" ]]; then
    last=$(cat "$DATA_REPO/manifests/.last-run" 2>/dev/null) || last=""
  fi
  case "$last" in ''|*[!0-9]*) last=$(git -C "$DATA_REPO" log -1 --format=%ct 2>/dev/null || true) ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  H_LAST=$last; H_AGE_DAYS=-1
  if [[ "$H_LAST" -eq 0 ]]; then
    H_PROBLEMS+=("cannot determine last snapshot time")
  else
    H_AGE_DAYS=$(( (now - H_LAST) / 86400 ))
    if [[ "$H_AGE_DAYS" -lt 0 ]]; then
      H_PROBLEMS+=("last-run stamp is in the FUTURE; staleness cannot be judged")
    elif [[ "$H_AGE_DAYS" -gt "$CFG_STALE_DAYS" ]]; then
      H_PROBLEMS+=("last snapshot was $H_AGE_DAYS days ago (limit $CFG_STALE_DAYS)")
    fi
  fi

  # --- drift report: a scan that never finished is a FAULT, never "clean".
  local drift_file="$DATA_REPO/manifests/drift.txt" items arr count
  H_SCAN_COMPLETE=false; H_DRIFT_COUNT=0; H_DRIFT_TRUNCATED=false; H_DRIFT_JSON="[]"
  if [[ ! -f "$drift_file" ]]; then
    H_PROBLEMS+=("no drift report -- snapshot.sh may not be running")
  else
    grep -q '^# drift-scan-complete' "$drift_file" && H_SCAN_COMPLETE=true
    [[ "$H_SCAN_COMPLETE" == true ]] || H_PROBLEMS+=("drift report is incomplete -- the scan did not finish")
    items=$(drift_parse "$drift_file")
    arr="[${items}]"
    count=$(jq 'length' <<<"$arr")
    H_DRIFT_COUNT=$count
    if (( count > WIDGET_DRIFT_LIMIT )); then
      H_DRIFT_TRUNCATED=true
      H_DRIFT_JSON=$(jq -c ".[0:${WIDGET_DRIFT_LIMIT}]" <<<"$arr")
    else
      H_DRIFT_JSON="$arr"
    fi
  fi

  if [[ -f "$DATA_REPO/.git/MERGE_HEAD" || -d "$DATA_REPO/.git/rebase-merge" || -d "$DATA_REPO/.git/rebase-apply" ]]; then
    H_PROBLEMS+=("repo is mid-merge/rebase -- snapshots are paused")
  fi

  # --- pushed = backed up; a local commit is not off the machine yet.
  H_UNPUSHED=0; H_DIVERGED=false; H_PUSH_VERIFIABLE=false
  if git -C "$DATA_REPO" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    local ahead behind
    ahead=$(git -C "$DATA_REPO" rev-list --count '@{upstream}..HEAD' 2>/dev/null || true)
    case "$ahead" in ''|*[!0-9]*) ahead=0 ;; *) H_PUSH_VERIFIABLE=true ;; esac
    H_UNPUSHED=$ahead
    [[ "$H_PUSH_VERIFIABLE" == true ]] || H_PROBLEMS+=("cannot verify whether commits are pushed")
    behind=$(git -C "$DATA_REPO" rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo 0)
    if [[ "${behind:-0}" -gt 0 ]]; then
      H_DIVERGED=true
      H_PROBLEMS+=("remote has diverged -- pull --rebase needed")
    fi
    [[ "$H_UNPUSHED" -gt 0 ]] && H_PROBLEMS+=("$H_UNPUSHED commit(s) never pushed -- not yet off this machine")
  else
    H_PROBLEMS+=("no upstream configured -- cannot tell if anything is pushed")
  fi

  # --- edits the timer will not commit (bin/, lists, README -- deliberately
  # left for a human; home/etc/manifests/modes.txt are the timer's own turf).
  local -a unc=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && unc+=("$(jstr "$line")")
  done < <(git -C "$DATA_REPO" status --porcelain -- . ':!home' ':!etc' ':!manifests' ':!modes.txt' 2>/dev/null)
  H_UNCOMMITTED_JSON=$(jjoin ${unc[@]+"${unc[@]}"})

  # --- timers armed. systemctl --user always sees the REAL machine, so
  # fixtures set OMABACKUP_SKIP_TIMERS=1 to keep real timer state out of tests.
  H_TIMERS_CHECKED=false; H_TIMER_ENABLED=false; H_TIMER_ACTIVE=false
  H_SELFTEST_ENABLED=false; H_SELFTEST_ACTIVE=false; H_TIMER_NEXT=""
  if [[ "${OMABACKUP_SKIP_TIMERS:-0}" != 1 ]] && have systemctl; then
    H_TIMERS_CHECKED=true
    systemctl --user is-enabled omabackup-snapshot.timer >/dev/null 2>&1 && H_TIMER_ENABLED=true
    systemctl --user is-active  omabackup-snapshot.timer >/dev/null 2>&1 && H_TIMER_ACTIVE=true
    systemctl --user is-enabled omabackup-selftest.timer >/dev/null 2>&1 && H_SELFTEST_ENABLED=true
    systemctl --user is-active  omabackup-selftest.timer >/dev/null 2>&1 && H_SELFTEST_ACTIVE=true
    H_TIMER_NEXT=$(systemctl --user show omabackup-snapshot.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
    case "$H_TIMER_NEXT" in ''|'n/a'|0) H_TIMER_NEXT="" ;; esac
    { [[ "$H_TIMER_ENABLED" == true ]] && [[ "$H_TIMER_ACTIVE" == true ]]; } || H_PROBLEMS+=("snapshot timer is not armed")
    { [[ "$H_SELFTEST_ENABLED" == true ]] && [[ "$H_SELFTEST_ACTIVE" == true ]]; } || H_PROBLEMS+=("self-test timer is not armed")
  fi

  H_SETUP=$(health_setup_state)
}

# health_state: ok, attention or fault. Any problem is a fault; else drift or
# an uncommitted edit is attention; else ok.
health_state() {
  if (( ${#H_PROBLEMS[@]} > 0 )); then
    echo fault
  elif [[ "$H_DRIFT_COUNT" -gt 0 || -n "$H_UNCOMMITTED_JSON" ]]; then
    echo attention
  else
    echo ok
  fi
}

# health_status_json: the one JSON object status.json holds and `status
# --json` prints. Field order matches the widget contract.
health_status_json() {
  local state; state=$(health_state)
  local -a probs_j=()
  local p
  for p in "${H_PROBLEMS[@]}"; do probs_j+=("$(jstr "$p")"); done
  # H_DRIFT_JSON can hold thousands of long paths -- passing it as an
  # --argjson exceeds the exec ARG_MAX (Argument list too long) on a real
  # home, so it goes in on stdin instead (a here-string, not argv) and
  # everything else stays a small --arg/--argjson.
  jq -c \
    --arg state "$state" \
    --arg setup "$H_SETUP" \
    --arg repo "$DATA_REPO" \
    --argjson generated "$(date +%s)" \
    --argjson last_run "$H_LAST" \
    --argjson age "$H_AGE_DAYS" \
    --argjson scan_complete "$H_SCAN_COMPLETE" \
    --argjson drift_count "$H_DRIFT_COUNT" \
    --argjson drift_truncated "$H_DRIFT_TRUNCATED" \
    --argjson unpushed "$H_UNPUSHED" \
    --argjson diverged "$H_DIVERGED" \
    --argjson push_verifiable "$H_PUSH_VERIFIABLE" \
    --argjson uncommitted "[$H_UNCOMMITTED_JSON]" \
    --argjson timers_checked "$H_TIMERS_CHECKED" \
    --argjson timer_enabled "$H_TIMER_ENABLED" \
    --argjson timer_active "$H_TIMER_ACTIVE" \
    --arg timer_next "$H_TIMER_NEXT" \
    --argjson selftest_enabled "$H_SELFTEST_ENABLED" \
    --argjson selftest_active "$H_SELFTEST_ACTIVE" \
    --argjson problems "[$(jjoin ${probs_j[@]+"${probs_j[@]}"})]" \
    '. as $drift | {state:$state, setup:$setup, repo:$repo, generated:$generated,
      last_run:$last_run, last_run_age_days:$age,
      drift_scan_complete:$scan_complete, drift_count:$drift_count,
      drift_truncated:$drift_truncated, drift:$drift,
      unpushed:$unpushed, diverged:$diverged, push_verifiable:$push_verifiable,
      uncommitted:$uncommitted,
      timers_checked:$timers_checked, timer_enabled:$timer_enabled, timer_active:$timer_active,
      timer_next:$timer_next, selftest_enabled:$selftest_enabled, selftest_active:$selftest_active,
      problems:$problems}' <<<"$H_DRIFT_JSON"
}

# health_write_status: collect fresh and persist, for callers (snapshot_result)
# that just want the file on disk, not the JSON on stdout.
health_write_status() {
  health_collect
  state_write_status "$(health_status_json)"
}

# health_print_human: the plain (non --json) `status` rendering.
health_print_human() {
  local state; state=$(health_state)
  local color=$'\033[1;32m'
  [[ "$state" == attention ]] && color=$'\033[1;33m'
  [[ "$state" == fault ]] && color=$'\033[1;31m'
  printf '%sstate: %s\033[0m (setup: %s)\n' "$color" "$state" "$H_SETUP"
  printf 'repo: %s\n' "$DATA_REPO"
  if [[ "$H_LAST" -gt 0 ]]; then
    printf 'last snapshot: %s day(s) ago\n' "$H_AGE_DAYS"
  else
    printf 'last snapshot: unknown\n'
  fi
  printf 'drift: %s item(s)' "$H_DRIFT_COUNT"
  [[ "$H_DRIFT_TRUNCATED" == true ]] && printf ' (truncated)'
  printf '\n'
  printf 'unpushed commits: %s\n' "$H_UNPUSHED"
  if (( ${#H_PROBLEMS[@]} > 0 )); then
    printf 'problems:\n'
    for p in "${H_PROBLEMS[@]}"; do printf '  - %s\n' "$p"; done
  fi
}

# cmd_health: login-shell check. Silent and exit 0 when healthy; coloured
# lines and exit 1 otherwise. Deliberately does NOT share severity with
# health_state/status.json for one class of problem: an uncommitted edit to
# the repo's own lists/scripts is a low-priority reminder, so it nags at most
# once every NAG_DAYS (or when the pending set changes), tracked by a
# signature stamp -- never on the JSON path, which always reflects the truth.
cmd_health() {
  data_repo_require
  health_collect
  local -a lines=()
  local p
  for p in "${H_PROBLEMS[@]}"; do lines+=("$p"); done
  if [[ "$H_DRIFT_COUNT" -gt 0 ]]; then
    lines+=("$H_DRIFT_COUNT config path(s) need attention (NEW = unbacked, GONE = vanished). Run: omabackup drift")
  fi

  local -a unc=()
  local line
  if [[ -n "$H_UNCOMMITTED_JSON" ]]; then
    while IFS= read -r line; do [[ -n "$line" ]] && unc+=("$line"); done < <(jq -r '.[]' <<<"[$H_UNCOMMITTED_JSON]")
  fi
  if (( ${#unc[@]} > 0 )); then
    local sig now stamp="$STATE_DIR/nag.stamp" last_at=0 last_sig="" days
    now=$(date +%s)
    sig=$(printf '%s\n' "${unc[@]}" | cksum | cut -d' ' -f1)
    if [[ -r "$stamp" ]]; then
      read -r last_at last_sig < "$stamp" || true
    fi
    case "$last_at" in ''|*[!0-9]*) last_at=0 ;; esac
    days=$(( (now - last_at) / 86400 ))
    if [[ "$sig" != "$last_sig" || "$days" -ge "$NAG_DAYS" ]]; then
      lines+=("reminder: ${#unc[@]} uncommitted edit(s) to the repo's own lists/scripts. Run: git -C $DATA_REPO add -A && git -C $DATA_REPO commit")
      # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
      mkdir -m 700 -p "$STATE_DIR"
      printf '%s %s\n' "$now" "$sig" > "$stamp"
    fi
  fi

  (( ${#lines[@]} == 0 )) && return 0
  for p in "${lines[@]}"; do printf '\033[1;31m[omabackup] %s\033[0m\n' "$p"; done
  return 1
}
