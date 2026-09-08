#!/usr/bin/env bash
# Health checks: one collection pass shared by `status` (lib/widget.sh) and
# `health` (cmd_health below). Ported from
# the source engine, bin/widget-helper.sh:40-155 (the JSON severity model --
# drift/uncommitted = attention, everything else = fault) and
# the source engine, bin/health-check.sh:42-173 (the login-shell nag, which
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
  if [[ -n "$url" && -z "$slug" ]]; then
    # A GitHub host with no usable slug is unverifiable whatever the config
    # says: the probe is the only thing that can speak for a GitHub remote,
    # and setup refuses to record trust for one, so a stale trusted flag must
    # not make the widget render "ready" over a repo nothing ever checked.
    remote_is_github "$url" && { echo remote-unverified; return; }
    [[ "$CFG_REMOTE_TRUSTED" == true ]] || { echo remote-unverified; return; }
  fi
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
      unpushed:0, diverged:false, upstream_readable:false, remote:"none",
      remote_label:"", remote_linkable:false,
      push_verifiable:false, push_reason:"unprobed", uncommitted:[],
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
  # No stamp (a fresh clone has none) or garbage: the stand-in is the last
  # commit that touched the snapshot's own output paths, which is the last
  # snapshot. HEAD's time stood in before, and HEAD is whatever committed
  # last: the adoption marker, a list commit from push --confirm, or the
  # .gitignore sync's own commit, which lands before the pipeline's checks and
  # so exists even when the run then refused. Any of those made a stale
  # backup read as fresh. HEAD only when no snapshot has ever been committed.
  case "$last" in ''|*[!0-9]*)
    last=$(git -C "$DATA_REPO" log -1 --format=%ct -- home etc manifests modes.txt 2>/dev/null || true)
    case "$last" in '') last=$(git -C "$DATA_REPO" log -1 --format=%ct 2>/dev/null || true) ;; esac ;;
  esac
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

  # --- did the last ATTEMPT refuse? The stamp above only moves when a run
  # finishes, so a run that refuses leaves it standing and nothing is said
  # until staleDays have passed. That is two days of a panel reporting a
  # healthy backup while every run is being stopped at a gate. The reason
  # comes from the refusal itself, so the problem names what to fix rather
  # than sending the operator to the journal.
  local lr_ok lr_reason lr_at
  if [[ -r "$STATE_DIR/last-run.json" ]]; then
    # NOT `.ok // empty`: jq's alternative operator treats false exactly like
    # null, so the one value this field exists to carry read back as absent.
    lr_ok=$(jq -r 'if .ok == null then "" else (.ok|tostring) end' "$STATE_DIR/last-run.json" 2>/dev/null) || lr_ok=""
    lr_reason=$(jq -r '.reason // ""' "$STATE_DIR/last-run.json" 2>/dev/null) || lr_reason=""
    lr_at=$(jq -r '.at // 0' "$STATE_DIR/last-run.json" 2>/dev/null) || lr_at=0
    case "$lr_at" in ''|*[!0-9]*) lr_at=0 ;; esac
    # `>= H_LAST`: a record older than the last successful run is a leftover
    # from a version that did not clear it, and must not nag forever.
    if [[ "$lr_ok" == false && "$lr_at" -ge "$H_LAST" ]]; then
      if [[ -n "$lr_reason" ]]; then
        H_PROBLEMS+=("the last snapshot refused and nothing was backed up: $lr_reason")
      else
        H_PROBLEMS+=("the last snapshot refused and nothing was backed up; run omabackup snapshot to see why")
      fi
    fi
  fi

  # --- drift report: a scan that never finished is a FAULT, never "clean".
  local drift_file="$DATA_REPO/manifests/drift.txt" items arr count
  H_SCAN_COMPLETE=false; H_DRIFT_COUNT=0; H_DRIFT_TRUNCATED=false; H_DRIFT_JSON="[]"
  if [[ ! -f "$drift_file" ]]; then
    H_PROBLEMS+=("no drift report -- the snapshot timer may not be running")
  else
    grep -q '^# drift-scan-complete' "$drift_file" && H_SCAN_COMPLETE=true
    [[ "$H_SCAN_COMPLETE" == true ]] || H_PROBLEMS+=("drift report is incomplete -- the scan did not finish")
    items=$(drift_parse "$drift_file")
    arr="[${items}]"
    count=$(jq 'length' <<<"$arr")
    H_DRIFT_COUNT=$count
    # An ERROR row means a detector did not run: a missing stock tree, a pacman
    # this scan could not parse, an unreadable drop-in directory. Counting it
    # as one more drift item made "the biggest detector is switched off" render
    # exactly like one unbacked file, at severity attention, in a list a user
    # has learned to skim. Any ERROR is a problem, and any problem is a fault.
    # This retro-fits a loud failure onto every present and future producer of
    # an ERROR line, which is why it is done here and not at each producer.
    local err
    while IFS= read -r err; do
      [[ -n "$err" ]] || continue
      case "$err" in
        # A name the report cannot write is not an unfinished scan: the scan
        # ran, and one file in it cannot be named as a row. Saying "could not
        # complete a check" about that row contradicted the row itself, and
        # told the reader nothing they could act on.
        'a name the report cannot represent:'*)
          H_PROBLEMS+=("drift report: $err -- rename the file, or add a drift-ignore glob for its directory") ;;
        *) H_PROBLEMS+=("drift scan could not complete a check: $err") ;;
      esac
    done < <(jq -r '.[] | select(.type == "ERROR") | .path' <<<"$arr")
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
  #
  # TWO SEPARATE QUESTIONS, and they used to share the name push_verifiable.
  # H_UPSTREAM_READABLE answers "did git manage to count how far ahead HEAD
  # is": a local, mechanical question. push_verifiable is the REMOTE GATE's
  # answer -- gitleaks present and the remote proven private or explicitly
  # trusted -- which only lib/remote.sh can decide and only while it is
  # probing. Under one name, a machine with no gitleaks printed
  # push_verifiable:false from snapshot and wrote push_verifiable:true into
  # status.json, in the same run.
  #
  # STAYING LOCAL IS A SUPPORTED ANSWER. The wizard offers it ("Private git
  # remote URL (empty to stay local)"), and "no upstream configured" was then
  # reported as a problem forever: any problem is a fault, so the bar showed
  # the alert triangle for the life of the install and the login check printed
  # a red line in every new terminal. A remote that EXISTS and cannot be
  # verified stays a problem, which is the half that is actually about a
  # backup not leaving the machine.
  #
  # THREE STATES, NOT TWO, because git alone cannot tell the two quiet ones
  # apart. Asking only "does origin exist" made a REMOVED origin -- deleted by
  # hand, or lost with a re-cloned .git -- read exactly like a deliberate
  # local-only install: state ok, "Remote: none (local only)", health silent,
  # while config.json still recorded the remote the operator set up and every
  # commit since had gone nowhere. The config is what records the INTENT, so
  # it decides which of the two quiet answers this is.
  H_UNPUSHED=0; H_DIVERGED=false; H_UPSTREAM_READABLE=false
  # The popup names the repository the backup goes to, so the label and whether
  # it is worth a click are decided here, once, from the live origin. Both are
  # pure string work over one `git remote get-url` this block already ran: no
  # network, because status refreshes every time the popup opens.
  H_REMOTE_LABEL=""; H_REMOTE_LINKABLE=false
  local origin_url no_upstream=0; origin_url=$(remote_origin_url)
  if [[ -n "$origin_url" ]]; then
    H_REMOTE=configured
    # ...unless origin pushes somewhere other than it fetches from. Then the
    # fetch URL is not where the backup goes, the push URL is, and the engine
    # refuses to push to either until the pushurl is removed. Naming the fetch
    # repository as the backup target would be the panel's worst kind of lie.
    # The pushurl-differs push_reason is what explains it.
    if ! remote_pushurl_differs; then
      local origin_slug; origin_slug=$(remote_github_slug "$origin_url")
      [[ -z "$origin_slug" ]] || H_REMOTE_LINKABLE=true
      H_REMOTE_LABEL=$(remote_display_label "$origin_url" "$origin_slug")
    fi
  elif [[ -n "${CFG_REMOTE_URL:-}" ]]; then
    H_REMOTE=missing
    H_PROBLEMS+=("a remote was configured ($(remote_url_display "$CFG_REMOTE_URL")) but the repo has no origin; run omabackup setup")
  else
    H_REMOTE=none
  fi
  if git -C "$DATA_REPO" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    local ahead behind
    ahead=$(git -C "$DATA_REPO" rev-list --count '@{upstream}..HEAD' 2>/dev/null || true)
    case "$ahead" in ''|*[!0-9]*) ahead=0 ;; *) H_UPSTREAM_READABLE=true ;; esac
    H_UNPUSHED=$ahead
    [[ "$H_UPSTREAM_READABLE" == true ]] || H_PROBLEMS+=("cannot count unpushed commits")
    behind=$(git -C "$DATA_REPO" rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo 0)
    if [[ "${behind:-0}" -gt 0 ]]; then
      H_DIVERGED=true
      H_PROBLEMS+=("remote has diverged -- pull --rebase needed")
    fi
    [[ "$H_UNPUSHED" -gt 0 ]] && H_PROBLEMS+=("$H_UNPUSHED commit(s) never pushed -- not yet off this machine")
  elif [[ "$H_REMOTE" == configured ]]; then
    # The problem itself is decided here; its WORDING waits for the push
    # verdict below, because "no upstream configured" on its own sends a user
    # looking for a git problem when the actual reason nothing has been pushed
    # is usually the gate: no gitleaks, or a remote nothing has verified.
    no_upstream=1
  fi

  # --- the push gate's last recorded answer. Written by remote_probe and
  # remote_push_if_ahead (lib/remote.sh) to $STATE_DIR/push-verdict.json; read
  # here rather than re-derived, because re-deriving means probing the network
  # from a widget refresh. A verdict recorded against a DIFFERENT origin is not
  # an answer about this one: trust is bound to a URL everywhere else in this
  # tool, and it is bound to a URL here too.
  # The verdict also has an AGE, and an old yes is not a yes. The probe is the
  # only thing that knows whether the remote is still private, and a repository
  # can be made public between one run and the next; a verdict recorded when
  # the file was written and never looked at again would keep saying "safe to
  # push" for as long as nobody ran a snapshot. staleDays is the same limit the
  # rest of this file uses for "the backup has stopped running", so it is the
  # same answer to the same question: how long may this tool go on believing
  # something it has not checked.
  H_PUSH_VERIFIABLE=false; H_PUSH_REASON="unprobed"
  local verdict="$STATE_DIR/push-verdict.json" v_url v_ok v_reason v_at cur_url
  if [[ -r "$verdict" ]]; then
    cur_url=$(remote_origin_url)
    v_url=$(jq -r '.url // ""' "$verdict" 2>/dev/null || true)
    if [[ -n "$cur_url" && "$v_url" == "$cur_url" ]]; then
      v_at=$(jq -r '.at // 0' "$verdict" 2>/dev/null || echo 0)
      case "$v_at" in ''|*[!0-9]*) v_at=0 ;; esac
      # WHOLE DAYS, the same arithmetic the snapshot-age check above uses.
      # This one compared seconds against staleDays * 86400, so a verdict and
      # a snapshot of exactly the same age could be called stale by one check
      # and fresh by the other, on the same status line.
      local v_age_days=-1
      [[ "$v_at" -gt 0 ]] && v_age_days=$(( (now - v_at) / 86400 ))
      if [[ "$v_at" -le 0 || "$v_age_days" -gt "$CFG_STALE_DAYS" ]]; then
        H_PUSH_REASON="stale"
      else
        v_ok=$(jq -r 'if .verifiable == true then "true" else "false" end' "$verdict" 2>/dev/null || echo false)
        v_reason=$(jq -r '.reason // ""' "$verdict" 2>/dev/null || true)
        H_PUSH_VERIFIABLE=$v_ok
        [[ -z "$v_reason" ]] || H_PUSH_REASON=$v_reason
      fi
    fi
  fi

  # The wording deferred above. Nothing has ever been pushed to this remote,
  # and the reason is either "git has no upstream yet" or, far more often, the
  # push gate is shut -- no gitleaks, a remote nothing verified, a probe that
  # proved nothing. Name the one the user can act on.
  if [[ "$no_upstream" == 1 ]]; then
    if [[ "$H_PUSH_VERIFIABLE" == true ]]; then
      H_PROBLEMS+=("no upstream configured -- cannot tell if anything is pushed")
    else
      H_PROBLEMS+=("no upstream configured and pushes are off ($H_PUSH_REASON) -- nothing has left this machine")
    fi
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

  # --- the INSTALLED timer against the config that is supposed to describe it.
  # Editing timer.calendar in config.json has no effect until setup is rerun,
  # so the two could disagree indefinitely with nothing saying so: a user who
  # set "weekly" went on believing the backup ran weekly while the unit still
  # said daily, or the other way round. Read the unit file rather than
  # systemctl, because the file is what setup wrote and the comparison must
  # work with the timer skipped (fixtures) as well as with it armed.
  # A machine with no systemd-analyze cannot have its timer settings checked
  # against systemd's own grammar, and the character-class refusal in
  # config_load is a floor, not a substitute. Say so where it can be seen.
  [[ "${CFG_TIMER_VALIDATED:-1}" == 1 ]] \
    || H_PROBLEMS+=("timer settings not validated: systemd-analyze missing")

  local snap_unit="$HOME/.config/systemd/user/omabackup-snapshot.timer" unit_cal
  if [[ -r "$snap_unit" ]]; then
    unit_cal=$(sed -nE 's/^[[:space:]]*OnCalendar[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$snap_unit" 2>/dev/null | tail -1)
    if [[ -n "$unit_cal" && -n "${CFG_TIMER_CALENDAR:-}" && "$unit_cal" != "$CFG_TIMER_CALENDAR" ]]; then
      H_PROBLEMS+=("the installed snapshot timer runs '$unit_cal' but config says '$CFG_TIMER_CALENDAR'; run: omabackup setup")
    fi
  fi

  # --- guard-weakening OMABACKUP_* hooks found in the ambient environment.
  # lib/config.sh already ignored them (they only work under the test suite's
  # own marker), but a value that reached the daily timer and did nothing is
  # still someone believing a guard is off. Report it: any problem is a fault.
  [[ -z "${OMABACKUP_OVERRIDES_IGNORED:-}" ]] \
    || H_PROBLEMS+=("ignoring OMABACKUP_* override(s) set in the environment: $OMABACKUP_OVERRIDES_IGNORED")
  # The suite marker on its own is the shape of an attempt to switch the
  # hooks back on: it means something set the marker without the config
  # redirection every fixture uses, which no real install does.
  [[ "${OMABACKUP_SUITE_MARKER_STRAY:-0}" != 1 ]] \
    || H_PROBLEMS+=("OMABACKUP_IN_SUITE is set outside a test run")
  # Section 1 of the drift scan compares ~/.config against the stock tree, and
  # it is the biggest detector there is. A STOCK_DIR pointed somewhere else is
  # therefore a change to what "drift" even means, and it comes from the
  # environment, exactly like the ignored hooks above. Say which tree the
  # answers came from. Not during a test run, whose whole point is a stock
  # stand-in -- the same exemption the hooks above get, from the same gate.
  if [[ "${OMABACKUP_SUITE_ACTIVE:-0}" != 1 && "$STOCK_DIR" != /usr/share/omarchy ]]; then
    H_PROBLEMS+=("drift is being compared against $STOCK_DIR, not the installed Omarchy tree")
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
    --argjson upstream_readable "$H_UPSTREAM_READABLE" \
    --arg remote "$H_REMOTE" \
    --arg remote_label "$H_REMOTE_LABEL" \
    --argjson remote_linkable "$H_REMOTE_LINKABLE" \
    --argjson push_verifiable "$H_PUSH_VERIFIABLE" \
    --arg push_reason "$H_PUSH_REASON" \
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
      unpushed:$unpushed, diverged:$diverged, upstream_readable:$upstream_readable,
      remote:$remote, remote_label:$remote_label, remote_linkable:$remote_linkable,
      push_verifiable:$push_verifiable, push_reason:$push_reason,
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
  # Three states, three lines. A `missing` remote has no upstream to count
  # against, so "unpushed commits: 0" was arithmetic about a remote that is
  # not there, and it read as the one reassuring answer this state must never
  # give. The problems list below carries the fix; this line carries the fact.
  if [[ "$H_REMOTE" == none ]]; then
    printf 'remote: none (local only)\n'
  elif [[ "$H_REMOTE" == missing ]]; then
    printf 'remote: missing (origin removed)\n'
  else
    printf 'unpushed commits: %s\n' "$H_UNPUSHED"
  fi
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
      # WARN AND SKIP, not die: the reminder has already been decided and
      # added above, and a state directory that cannot be written must not
      # turn `health` into a failed run. The cost of skipping is that the
      # same reminder is due again on the next login.
      if ! mkdir -m 700 -p "$STATE_DIR" || ! printf '%s %s\n' "$now" "$sig" > "$stamp"; then
        warn "cannot record the reminder stamp under $STATE_DIR; this reminder may repeat"
      fi
    fi
  fi

  # One JSON object on stdout under --json, even (especially) when unhealthy:
  # `health` is a verb like any other, and a caller asking for JSON got a
  # coloured ANSI line and nothing to parse. `state` is the same three-way
  # verdict status.json carries; `problems` is exactly the set of lines the
  # human rendering would print, throttling included, so the two modes can
  # never disagree about what is wrong.
  local healthy=true
  (( ${#lines[@]} == 0 )) || healthy=false
  if [[ $JSON == 1 ]]; then
    local -a probs_j=()
    for p in ${lines[@]+"${lines[@]}"}; do probs_j+=("$(jstr "$p")"); done
    jq -cn --argjson ok "$healthy" --arg state "$(health_state)" \
      --argjson problems "[$(jjoin ${probs_j[@]+"${probs_j[@]}"})]" \
      '{ok:$ok, state:$state, problems:$problems}'
  elif [[ $healthy == false ]]; then
    for p in "${lines[@]}"; do printf '\033[1;31m[omabackup] %s\033[0m\n' "$p"; done
  fi
  [[ $healthy == true ]]
}
