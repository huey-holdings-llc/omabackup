#!/usr/bin/env bash
# Shared helpers. Sourced by bin/omabackup; never executed.
# shellcheck shell=bash

# ---- output ---------------------------------------------------------------
# JSON=1 means the caller asked for --json: stdout carries exactly one object.
log()  { [[ "${JSON:-0}" == 1 ]] || printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# die: refuse. Exit 1. With --json the refusal is still one JSON object.
die() {
  # A run that declared itself recordable (cmd_snapshot, for a real run) says
  # so on its way out, so health can report "the last run refused, here is
  # why" instead of a stale timestamp that still looks healthy. Guarded on the
  # flag so a refusal from lint, drift or the widget is not filed as a failed
  # backup, and `|| true` so a state directory nobody can write cannot change
  # what this refusal says or the code it exits with.
  if [[ -n "${RUN_RECORDING:-}" ]] && declare -F run_record >/dev/null; then
    run_record false "$*" || true
  fi
  if [[ "${JSON:-0}" == 1 ]]; then
    jq -cn --arg m "$*" '{ok:false, error:$m}'
  else
    printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2
  fi
  exit 1
}
# usage_die: bad usage. Exit 2. With --json the refusal is still one JSON object.
usage_die() {
  if [[ "${JSON:-0}" == 1 ]]; then
    jq -cn --arg m "$*" '{ok:false, error:$m, usage:true}'
  else
    printf 'omabackup: %s\nRun: omabackup help\n' "$*" >&2
  fi
  exit 2
}

# ---- scratch cleanup ------------------------------------------------------
# cleanup_add PATH: remove PATH when this process exits, however it exits.
#
# ONE REGISTRY, ONE TRAP. `trap ... EXIT` REPLACES whatever EXIT trap is
# already installed; it does not add to it. Two libraries each installing
# their own (the drift scan's listing directory, verify's throwaway restore
# tree) meant that whichever ran second silently disarmed the first, and the
# first one's directory would have been left in $STATE_DIR for good. Nothing
# runs both in one process today, which is exactly why it was worth fixing
# before something does.
#
# The paths registered here are ones this tool made itself, under its own
# 0700 scratch, so `rm -rf` is removing what it created and nothing else.
# INT and TERM route through the same handler and then exit with the
# conventional code for the signal, or a Ctrl-C would leave the scratch
# behind. Every step is best effort: this runs on the way out, and a removal
# that fails must not replace the reason the process is exiting.
CLEANUP_PATHS=()
CLEANUP_TRAP_INSTALLED=0
cleanup_run() {
  local p
  for p in ${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}; do
    [[ -n "$p" ]] || continue
    rm -rf "$p" 2>/dev/null || true
  done
  CLEANUP_PATHS=()
  return 0
}
cleanup_add() {
  [[ -n "${1:-}" ]] || return 0
  CLEANUP_PATHS+=("$1")
  if [[ "$CLEANUP_TRAP_INSTALLED" != 1 ]]; then
    trap cleanup_run EXIT
    trap 'cleanup_run; exit 130' INT
    trap 'cleanup_run; exit 143' TERM
    CLEANUP_TRAP_INSTALLED=1
  fi
  return 0
}

# ---- json -----------------------------------------------------------------
# Drift paths are arbitrary filenames: escape, and strip control bytes.
json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}
jstr()  { printf '"%s"' "$(json_escape "$1")"; }
jjoin() { local IFS=,; printf '%s' "$*"; }
# emit_json FILTER [jq args...]: print one object. Callers pass data via --arg.
emit_json() { local f=$1; shift; jq -cn "$@" "$f"; }

# ---- lists ----------------------------------------------------------------
# Strip comments and blank lines; keep a leading '?' (optional marker).
read_list() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | sed -E -e 's/[[:space:]]+#.*$//' -e 's/[[:space:]]*$//'; }

# ---- argv hygiene ---------------------------------------------------------
# Refuse values that could smuggle a second line or tab into a list file.
assert_argv_safe() {
  case "$1" in
    *$'\n'*|*$'\t'*) die "value contains a newline or tab" ;;
  esac
}

# ---- notifications --------------------------------------------------------
# notify HEAD [BODY] [URGENCY]; silent when config notify=false or OMABACKUP_NOTIFY=0.
notify() {
  [[ "${OMABACKUP_NOTIFY:-1}" == 0 ]] && return 0
  [[ "${CFG_NOTIFY:-true}" == true ]] || return 0
  local head=$1 body=${2:-} urg=${3:-normal}
  if have omarchy-notification-send; then
    omarchy-notification-send -u "$urg" "$head" "$body" >/dev/null 2>&1 || true
  elif have notify-send; then
    notify-send -u "$urg" "$head" "$body" >/dev/null 2>&1 || true
  fi
}

# cmd_notify_failure snapshot|selftest [RESULT]: hidden verb, called from
# ExecStopPost / OnFailure= in the shipped units. Not in `usage`; not something
# a user types day to day.
#
# RESULT is systemd's $SERVICE_RESULT, passed by the self-test unit. A run that
# was killed for taking too long and a run whose assertions failed are the same
# EXIT_STATUS (KILL), and only one of them means a guard stopped working, so
# they get different words and different urgency. Anything else, or nothing at
# all, reads as a real failure: that is the fail-closed direction.
#
# The snapshot body names `omabackup status` before journalctl. The journal is
# the complete answer and the unreadable one; status is what a person can act
# on, and it is the tool's own summary of why the run refused.
cmd_notify_failure() {
  local result=${2:-}
  case "${1:-}" in
    snapshot)
      # A run the unit KILLED never reaches die, so it records nothing on its
      # own and health would read the previous run's verdict. This is the one
      # path systemd guarantees to reach on a failure, so it files the run as
      # refused; a run that died at a gate has already written its own reason,
      # and this overwrite says only what this path actually knows.
      if declare -F run_record_unless_failed >/dev/null; then
        run_record_unless_failed "the run did not finish (see journalctl --user -u omabackup-snapshot)" || true
      fi
      # ...and refresh status.json, because the widget watches that file and
      # nothing else. Recording the verdict without rewriting the status left
      # the popup showing the previous healthy state until its own ten-minute
      # refresh came round, which is most of the promptness this fix is for.
      # Guarded twice: the function may not be sourced on this path, and a
      # repo it cannot read must not turn a failure notification into a
      # different failure.
      # In a SUBSHELL, because this verb runs without a loaded config on
      # purpose (the dispatcher only peeks at notify, so DATA_REPO is unset
      # here) and config_load can die. The side effect wanted is a written
      # file, which survives the subshell; a failure inside it must not turn a
      # failure notification into a different failure.
      if declare -F health_write_status >/dev/null; then
        ( config_load >/dev/null 2>&1 && health_write_status >/dev/null 2>&1 ) || true
      fi
      notify "OmaBackup: snapshot FAILED" "Run: omabackup status, then journalctl --user -u omabackup-snapshot -n 50" critical ;;
    selftest)
      if [[ "$result" == timeout ]]; then
        notify "OmaBackup: weekly self-test ran out of time" \
          "It was stopped before it finished, so nothing was proven either way. Run: omabackup self-test --real (backups are still running)"
      else
        notify "OmaBackup: weekly self-test failed" \
          "Run: omabackup self-test --real (backups are still running)" critical
      fi ;;
    *) usage_die "notify-failure snapshot|selftest [RESULT]" ;;
  esac
}
