#!/usr/bin/env bash
# One flock per data repo, shared by snapshot, lint, verify and the write verbs.
#
# THE LOCK AND NOTHING ELSE. This file needs only lib/common.sh (for have and
# die) and $DATA_REPO, which is what lets the suite source it on its own and
# drive take_lock/drop_lock as white-box code. The git and repo helpers that
# used to sit below it live in lib/config.sh now, beside data_repo_require.
# shellcheck shell=bash

# LOCK_DEPTH: how many nested take_lock calls are outstanding in THIS process.
#
# The lock was one hardcoded fd taken and closed unconditionally, so a verb
# that called another locking verb in-process released the caller's lock the
# moment the inner one finished -- mid-write, with an `rsync --delete` into
# home/ still to come. Every verb-calls-verb site today (setup's drift and
# snapshot calls, the widget's lint call, self-test) is safe only because a
# command substitution forks a subshell, a property nothing enforces and
# nothing states at the call site. Counting makes a nested take a no-op and
# lets only the outermost drop close fd 9, so the rule is in the lock rather
# than in three comments in three files.
LOCK_DEPTH=0

take_lock() { # take_lock [WAIT]; returns 1 on timeout (caller decides)
  if (( LOCK_DEPTH > 0 )); then
    LOCK_DEPTH=$((LOCK_DEPTH+1))
    return 0
  fi
  have flock || die "flock not found: cannot guarantee a single instance"
  exec 9>"$DATA_REPO/.lock"
  if flock -w "${1:-${OMABACKUP_LOCK_WAIT:-20}}" 9; then
    LOCK_DEPTH=1
    return 0
  fi
  # Timed out: close the fd this call opened, so a later take_lock starts from
  # a clean fd rather than inheriting an unlocked one.
  exec 9>&-
  return 1
}
drop_lock() {
  (( LOCK_DEPTH > 0 )) || return 0     # never taken, or already released
  LOCK_DEPTH=$((LOCK_DEPTH-1))
  (( LOCK_DEPTH == 0 )) && exec 9>&-
  return 0                              # the (( )) above is a test, not a result
}
