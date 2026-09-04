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

# cmd_notify_failure snapshot|selftest: hidden verb, called from ExecStopPost
# / OnFailure= in the shipped units. Not in `usage`; not something a user
# types day to day.
cmd_notify_failure() {
  case "${1:-}" in
    snapshot) notify "OmaBackup: snapshot FAILED" "Run: journalctl --user -u omabackup-snapshot -n 50" critical ;;
    selftest) notify "OmaBackup: self-test FAILED" "A safety guard has stopped working. Run: omabackup self-test --real" critical ;;
    *) usage_die "notify-failure snapshot|selftest" ;;
  esac
}
