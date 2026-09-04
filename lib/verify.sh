#!/usr/bin/env bash
# Prove the backup actually reconstitutes this machine: restore the committed
# backup into a throwaway HOME and cmp every file against the live one. This
# is the strongest assertion the plugin makes: the floor check, the lint and
# the drift report all reason about what SHOULD be there -- this checks what
# actually comes back.
#
# Ported from hp-laptop-config/bin/verify-restore.sh (all 100 lines). Sourced
# by bin/omabackup; never executed.
#
# Expected differences are declared in normalize.txt (fields the snapshot
# deliberately neutralised) or explained by a file having changed since the
# last run (the suite takes a while and configs keep changing under it, and
# on a real machine so does the 30-minute theme cycle). Anything else
# differing is a real fidelity bug.
#
# READ-ONLY with respect to $HOME: everything the restore writes lands in a
# throwaway directory under $STATE_DIR (never /tmp), removed on every exit
# path via an EXIT trap.
#
# "Since the last run" is read from the MTIME of manifests/.last-run, not its
# content, which is a deliberate change from the source script: the content
# is a wall-clock epoch with one-second resolution, so two lines of a fast
# test landing in the same second are indistinguishable from "unchanged" and
# the mtime is not. The mtime is exactly as meaningful -- both answer "when
# did the last run start" -- and it is what a test (or a human backdating a
# stamp by hand) can set precisely with touch -d.
#
# ERREXIT DISCIPLINE: every command whose exit status is inspected sits on
# the left of `||` or inside an `if`; process substitutions are exempt by
# construction since their exit status is never checked by bash.
# shellcheck shell=bash

# verify_mismatch MSG: record one fidelity problem. Printed immediately
# outside JSON mode, and appended to MISMATCHED (already jstr()-quoted) for
# the JSON array.
verify_mismatch() {
  MISMATCHED+=("$(jstr "$1")")
  [[ $JSON == 1 ]] || printf '  \033[1;31mFIDELITY\033[0m  %s\n' "$1"
}

# verify_is_normalized REL: true when normalize.txt declares REL a legitimate
# self-changing field. Entries are staged paths ("home/<rel>" TAB sed-expr);
# only the glob half, with the "home/" prefix stripped, matters here.
verify_is_normalized() {
  local q="$1" n
  for n in ${VERIFY_NORMALIZED[@]+"${VERIFY_NORMALIZED[@]}"}; do
    # shellcheck disable=SC2254  # $n is a glob from normalize.txt, matched deliberately, not literally
    case "$q" in $n) return 0 ;; esac
  done
  return 1
}

# verify_changed_since LIVE_PATH: true when LIVE_PATH is newer than
# VERIFY_SINCE -- see the file header for why that is an mtime, not a parse.
verify_changed_since() {
  local mtime; mtime=$(stat -c %Y "$1" 2>/dev/null) || mtime=0
  [[ "$mtime" -gt "${VERIFY_SINCE:-0}" ]]
}

# cmd_verify: restore the committed backup into a throwaway HOME and cmp
# every file against the live one.
cmd_verify() {
  data_repo_require

  # Share snapshot's lock: this reads $DATA_REPO/home and modes.txt while the
  # daily timer may be mid `rsync --delete` into them. A busy lock is a
  # reported failure, never silence -- verifying a tree that is changing
  # underneath the check would produce spurious fidelity failures.
  if ! take_lock 120; then
    drop_lock
    if [[ $JSON == 1 ]]; then
      jq -cn '{ok:false, error:"LOCKED: snapshot is holding the lock (waited 120s); cannot verify a tree that is changing"}'
    else
      printf '\033[1;31m[FAIL]\033[0m LOCKED: snapshot is holding the lock (waited 120s); cannot verify a tree that is changing\n' >&2
    fi
    return 1
  fi

  # VERIFY_R is deliberately NOT `local`: an EXIT trap fires when the whole
  # process exits, by which point cmd_verify's own call frame (and any local
  # variable in it) is long gone, and referencing it under `set -u` would be
  # an unbound-variable error. bin/omabackup runs exactly one verb per
  # process, so a plain global here is exactly as scoped as the trap is, and
  # EXIT (not RETURN) is required: RETURN is not scoped to this function
  # either -- it also fires when restore_stage_configs (called below)
  # returns, deleting the throwaway mid-comparison.
  # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
  mkdir -m 700 -p "$STATE_DIR"
  VERIFY_R=$(mktemp -d "$STATE_DIR/verify.XXXXXX")
  trap 'rm -rf "${VERIFY_R:-}"' EXIT
  local R="$VERIFY_R"

  # Restore into the throwaway: reuse restore.sh's own configs stage (rsync
  # plus the modes.txt replay) rather than duplicating it, with $HOME
  # retargeted for the call and the restore floor lifted -- this is proving
  # the backup restores, not gating on how much of it there is.
  local live_home="$HOME" saved_min="${OMABACKUP_MIN_RESTORE:-}"
  # RESTORE_WOULD, RESTORE_WROTE, RESTORE_BACKED_UP and RESTORE_SKIPPED are
  # read by restore_stage_configs in lib/restore.sh, not this file.
  # shellcheck disable=SC2034
  RESTORE_WOULD=()
  # shellcheck disable=SC2034
  RESTORE_WROTE=()
  # shellcheck disable=SC2034
  RESTORE_BACKED_UP=()
  # shellcheck disable=SC2034
  RESTORE_SKIPPED=()
  RESTORE_FAILURES=0
  HOME="$R"; OMABACKUP_MIN_RESTORE=1
  restore_stage_configs 1
  HOME="$live_home"
  if [[ -n "$saved_min" ]]; then OMABACKUP_MIN_RESTORE="$saved_min"; else unset OMABACKUP_MIN_RESTORE; fi

  local -a MISMATCHED=()
  if [[ "$RESTORE_FAILURES" -gt 0 ]]; then
    verify_mismatch "restore-stage: $RESTORE_FAILURES problem(s) restoring the throwaway copy, see above"
  fi

  local -a VERIFY_NORMALIZED=()
  if [[ -r "$DATA_REPO/normalize.txt" ]]; then
    mapfile -t VERIFY_NORMALIZED < <(grep -vE '^[[:space:]]*(#|$)' "$DATA_REPO/normalize.txt" 2>/dev/null \
      | cut -f1 | sed 's#^home/##' | sort -u)
  fi

  local VERIFY_SINCE=0
  if [[ -f "$DATA_REPO/manifests/.last-run" ]]; then
    VERIFY_SINCE=$(stat -c %Y "$DATA_REPO/manifests/.last-run" 2>/dev/null) || VERIFY_SINCE=0
  else
    VERIFY_SINCE=$(git -C "$DATA_REPO" log -1 --format=%ct 2>/dev/null) || VERIFY_SINCE=0
  fi

  local compared=0 skip_norm=0 skip_changed=0 rel live rest
  while IFS= read -r rel; do
    live="$live_home/$rel"; rest="$R/$rel"
    [[ -e "$live" ]] || continue
    compared=$((compared+1))
    if cmp -s "$live" "$rest"; then
      :
    elif verify_is_normalized "$rel"; then
      skip_norm=$((skip_norm+1))
    elif verify_changed_since "$live"; then
      skip_changed=$((skip_changed+1))
    else
      # shellcheck disable=SC2088  # literal "~/" prefix, not a path to expand
      verify_mismatch "~/$rel"
    fi
  done < <(cd "$R" && find . -type f -printf '%P\n')

  # Permissions must survive too -- git checks files/dirs out with its own
  # defaults, and only the modes.txt replay inside restore_stage_configs
  # above fixes that. This proves the replay actually worked. NUL-delimited,
  # matching how restore.sh writes and reads modes.txt.
  if [[ -f "$DATA_REPO/modes.txt" ]]; then
    local mode path tgt got badmode=0
    while IFS= read -r -d '' rec; do
      mode="${rec%% *}"; path="${rec#* }"
      case "$mode" in [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;; *) continue ;; esac
      case "$path" in home/*) ;; *) continue ;; esac
      case "$path" in *..*) continue ;; esac
      rel="${path#home/}"
      tgt="$R/$rel"
      [[ -L "$tgt" ]] && continue
      [[ -f "$tgt" || -d "$tgt" ]] || continue
      got=$(stat -c %a "$tgt" 2>/dev/null) || got=""
      if [[ "$got" != "$mode" ]]; then
        # shellcheck disable=SC2088  # literal "~/" prefix, not a path to expand
        verify_mismatch "~/$rel (mode $got, recorded $mode)"
        badmode=$((badmode+1))
      fi
      [[ "$badmode" -ge 20 ]] && break
    done < "$DATA_REPO/modes.txt"
  fi

  drop_lock

  local ok=true
  [[ ${#MISMATCHED[@]} -eq 0 ]] || ok=false
  if [[ $JSON == 1 ]]; then
    jq -cn \
      --argjson ok "$ok" \
      --argjson compared "$compared" \
      --argjson mismatched "[$(jjoin ${MISMATCHED[@]+"${MISMATCHED[@]}"})]" \
      --argjson skipped_normalized "$skip_norm" \
      --argjson skipped_changed "$skip_changed" \
      '{ok:$ok, compared:$compared, mismatched:$mismatched, skipped_normalized:$skipped_normalized, skipped_changed:$skipped_changed}'
  else
    echo
    printf '  %s compared, %s normalised-as-expected, %s changed since the last run\n' "$compared" "$skip_norm" "$skip_changed"
    if [[ "$ok" == true ]]; then
      printf '\033[1;32mrestore fidelity verified\033[0m\n'
    else
      printf '\033[1;31m%d fidelity problem(s)\033[0m\n' "${#MISMATCHED[@]}"
    fi
  fi
  [[ "$ok" == true ]]
}
