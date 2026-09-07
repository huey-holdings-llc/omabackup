#!/usr/bin/env bash
# Prove the backup actually reconstitutes this machine: restore the committed
# backup into a throwaway HOME and cmp every file against the live one. This
# is the strongest assertion the plugin makes: the floor check, the lint and
# the drift report all reason about what SHOULD be there -- this checks what
# actually comes back.
#
# Ported from the source engine, bin/verify-restore.sh (all 100 lines). Sourced
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
# "Since the last run" is read from the CONTENT of manifests/.last-run (the
# start-of-run epoch the engine writes there), matching every other consumer
# of that file (lib/lint.sh, lib/health.sh). The pipeline writes that content
# near the END of the run, well after staging, so a file edited between the
# run's start and its end must still read as "changed since" -- using the
# file's mtime instead (an earlier version of this file did) is systematically
# too late a cutoff and wrongly flags exactly that window as a real mismatch.
# Garbage or missing content is never silently treated as epoch 0 (that would
# excuse everything): unparseable content falls back to the file's own mtime,
# with a warning, and a missing file falls back to the data repo's last
# commit time, same as before.
#
# Two other departures from the literal source, both deliberate:
#   - The badmode early-exit threshold is 20, not the source's 5. This repo's
#     modes.txt fixtures commonly carry more than 5 entries under test, and 5
#     stops the check well before it has looked at a representative sample.
#   - The throwaway restore reuses restore_stage_configs from lib/restore.sh
#     (rsync plus the modes.txt replay) instead of the source's inline
#     find/cp loop -- see cmd_verify below.
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
# VERIFY_SINCE -- see the file header for what that is read from.
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
  # Guarded, both of them: under `set -e` a failing mkdir or mktemp ends the
  # process with no line of its own, so a read-only or full $STATE_DIR made
  # `verify` look like a crash rather than a refusal it could explain.
  mkdir -m 700 -p "$STATE_DIR" \
    || die "cannot create $STATE_DIR; refusing to verify without a scratch directory"
  VERIFY_R=$(mktemp -d "$STATE_DIR/verify.XXXXXX") \
    || die "cannot create scratch under $STATE_DIR; refusing to verify"
  trap 'rm -rf "${VERIFY_R:-}"' EXIT
  local R="$VERIFY_R"

  # Restore into the throwaway: reuse restore.sh's own configs stage (rsync
  # plus the modes.txt replay) rather than duplicating it, with $HOME
  # retargeted for the call and the restore floor lifted -- this is proving
  # the backup restores, not gating on how much of it there is.
  local live_home="$HOME"
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
  HOME="$R"
  # Floor of 1, passed as the stage's second ARGUMENT. This used to be
  # OMABACKUP_MIN_RESTORE=1 set in-process and put back afterwards, which is
  # the same guard-weakening-through-the-environment shape lib/config.sh now
  # refuses to honour from outside the test suite.
  restore_stage_configs 1 1
  HOME="$live_home"

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
    local since_content
    since_content=$(cat "$DATA_REPO/manifests/.last-run" 2>/dev/null) || since_content=""
    if [[ "$since_content" =~ ^[1-9][0-9]*$ ]]; then
      VERIFY_SINCE="$since_content"
    else
      # Never silently treat garbage as epoch 0 -- that would excuse every
      # mismatch in the run. Fall back to the file's own mtime, and say so.
      warn "manifests/.last-run content is not a positive integer ('$since_content'); falling back to its mtime"
      VERIFY_SINCE=$(stat -c %Y "$DATA_REPO/manifests/.last-run" 2>/dev/null) || VERIFY_SINCE=0
    fi
  else
    # No stamp at all: a fresh clone (the file is gitignored), or a repo that
    # has never snapshotted on this machine. The stand-in is the time of the
    # last commit that touched the snapshot's own output paths, which is the
    # last snapshot. It used to
    # be HEAD's time, and HEAD right after `setup --import` is the adoption
    # marker commit, hours or days after the snapshot, so every live file
    # edited in between read as a fidelity problem. A commit time is the END
    # of a run, not its start, so a file edited during that run can still be
    # reported; the warning says so, and a snapshot writes the real stamp.
    VERIFY_SINCE=$(git -C "$DATA_REPO" log -1 --format=%ct -- home etc manifests modes.txt 2>/dev/null) || VERIFY_SINCE=""
    if [[ -z "$VERIFY_SINCE" ]]; then
      VERIFY_SINCE=$(git -C "$DATA_REPO" log -1 --format=%ct 2>/dev/null) || VERIFY_SINCE=0
    fi
    warn "manifests/.last-run is missing (a fresh clone has none); files newer than the last snapshot commit are treated as changed since it. A file edited during that run may still be reported; run omabackup snapshot for an exact answer"
  fi

  # Symlinks are enumerated alongside files. `-type f` skipped them entirely,
  # so a live link repointed since the snapshot was never compared and verify
  # called the backup faithful. A link is compared by its target, not by its
  # content: cmp follows it, so a link and its restored copy read as identical
  # whenever the file behind them is. NUL-delimited with the type in front,
  # the same shape restore.sh walks.
  local compared=0 skip_norm=0 skip_changed=0 absent=0 rel live rest rec vty same want got_l
  while IFS= read -r -d '' rec; do
    vty="${rec%% *}"; rel="${rec#* }"
    [[ -n "$rel" ]] || continue
    live="$live_home/$rel"; rest="$R/$rel"
    if [[ ! -e "$live" && ! -L "$live" ]]; then
      # Backed up but not on the live machine: not a fidelity bug (restore
      # only ever adds), and not comparable either. Counted for the human
      # summary only -- the JSON schema has no field for it.
      absent=$((absent+1))
      continue
    fi
    compared=$((compared+1))
    same=0
    if [[ "$vty" == l ]]; then
      want=$(readlink -- "$rest" 2>/dev/null || true)
      got_l=$(readlink -- "$live" 2>/dev/null || true)
      if [[ -L "$live" && -n "$want" && "$want" == "$got_l" ]]; then same=1; fi
    elif cmp -s "$live" "$rest"; then
      same=1
    fi
    if [[ "$same" == 1 ]]; then
      :
    elif verify_is_normalized "$rel"; then
      skip_norm=$((skip_norm+1))
    elif verify_changed_since "$live"; then
      # stat does not dereference, so a link is judged by its own mtime here,
      # which is what `ln -sfn` updates when a link is repointed.
      skip_changed=$((skip_changed+1))
    else
      # shellcheck disable=SC2088  # literal "~/" prefix, not a path to expand
      verify_mismatch "~/$rel"
    fi
  done < <(cd "$R" && find . \( -type f -o -type l \) -printf '%y %P\0')

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
      [[ -e "$tgt" || -L "$tgt" ]] || continue
      [[ -L "$tgt" ]] && continue
      # Same confinement as the replay in restore_stage_configs: a record
      # whose path resolves through a symlinked component names a file
      # outside the throwaway entirely, so its mode says nothing about the
      # backup and reading it as agreement would hide a real fidelity gap.
      if ! tgt=$(restore_mode_target "$R" "$rel"); then
        # shellcheck disable=SC2088  # literal "~/" prefix, not a path to expand
        verify_mismatch "~/$rel (modes.txt path resolves outside the restored copy or through a symlink)"
        badmode=$((badmode+1))
        [[ "$badmode" -ge 20 ]] && break
        continue
      fi
      [[ -f "$tgt" || -d "$tgt" ]] || continue
      got=$(stat -c %a "$tgt" 2>/dev/null) || got=""
      if [[ "$got" != "$mode" ]]; then
        # shellcheck disable=SC2088  # literal "~/" prefix, not a path to expand
        verify_mismatch "~/$rel (mode $got, recorded $mode)"
        badmode=$((badmode+1))
      fi
      [[ "$badmode" -ge 20 ]] && break   # 20, not the source's 5 -- see the file header
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
    printf '  %s compared, %s normalised-as-expected, %s changed since the last run, %s absent from live\n' \
      "$compared" "$skip_norm" "$skip_changed" "$absent"
    if [[ "$ok" == true ]]; then
      printf '\033[1;32mrestore fidelity verified\033[0m\n'
    else
      printf '\033[1;31m%d fidelity problem(s)\033[0m\n' "${#MISMATCHED[@]}"
    fi
  fi
  [[ "$ok" == true ]]
}
