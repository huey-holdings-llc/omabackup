#!/usr/bin/env bash
# Config and state paths. Unknown keys are an error: a typo must not silently
# disable a threshold.
# shellcheck shell=bash
# shellcheck disable=SC2034  # CFG_*, STOCK_DIR, WIDGET_DRIFT_LIMIT, NAG_DAYS: read by later libs, not this one

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CONFIG_FILE="${OMABACKUP_CONFIG:-$XDG_CONFIG_HOME/omabackup/config.json}"
STATE_DIR="${OMABACKUP_STATE_DIR:-$XDG_STATE_HOME/omabackup}"
STATUS_FILE="$STATE_DIR/status.json"
LOG_FILE="$STATE_DIR/omabackup.log"
STOCK_DIR="${OMABACKUP_STOCK_DIR:-/usr/share/omarchy}"
OMABACKUP_SKIP_ETC="${OMABACKUP_SKIP_ETC:-0}"
OMABACKUP_SKIP_TIMERS="${OMABACKUP_SKIP_TIMERS:-0}"
OMABACKUP_LOCK_WAIT="${OMABACKUP_LOCK_WAIT:-20}"
export OMABACKUP_SKIP_ETC OMABACKUP_SKIP_TIMERS OMABACKUP_LOCK_WAIT
WIDGET_DRIFT_LIMIT=2000
NAG_DAYS=7

# Test-only floor overrides: an empty value means "unset", i.e. derive from
# history instead of forcing a floor.
[[ -n "${OMABACKUP_MIN_FILES:-}" ]] || unset OMABACKUP_MIN_FILES
[[ -n "${OMABACKUP_MIN_ALLOWLIST:-}" ]] || unset OMABACKUP_MIN_ALLOWLIST

CONFIG_KNOWN='["dataRepo","remote","maxFileSize","staleDays","maxMissingPct","maxScanFiles","notify","shellNag","timer","setupPhase"]'
CONFIG_KNOWN_DOTTED='["remote.url","remote.trusted","timer.calendar","timer.jitter"]'
CONFIG_DEFAULTS='{"remote":{"url":"","trusted":false},"maxFileSize":"8m","staleDays":2,"maxMissingPct":25,"maxScanFiles":2000,"notify":true,"shellNag":false,"timer":{"calendar":"daily","jitter":"30m"},"setupPhase":""}'

logf() {
  mkdir -p "$STATE_DIR"
  if [[ -f "$LOG_FILE" ]] && (( $(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0) > 1000000 )); then mv -f "$LOG_FILE" "$LOG_FILE.1"; fi
  printf '%s %s\n' "$(date +%FT%T)" "$*" >> "$LOG_FILE"
}

config_exists() { [[ -r "$CONFIG_FILE" ]]; }

# config_load: parse, reject unknown keys, apply defaults, export CFG_* and paths.
config_load() {
  config_exists || die "no config at $CONFIG_FILE. Run: omabackup setup"
  jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || die "config is not valid JSON: $CONFIG_FILE"
  jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1 || die "config is not a JSON object: $CONFIG_FILE"
  local unknown
  unknown=$(jq -r --argjson known "$CONFIG_KNOWN" --argjson knownDotted "$CONFIG_KNOWN_DOTTED" '
    ([paths as $p | select(($p | length) == 1) | $p[0]] - $known) as $top
    | ([paths as $p | select(($p | length) == 2) | ($p[0] + "." + ($p[1] | tostring))] - $knownDotted) as $nested
    | ($top + $nested) | join(" ")
  ' "$CONFIG_FILE")
  [[ -z "$unknown" ]] || die "unknown config key(s): $unknown"
  CFG_JSON=$(jq -c --argjson d "$CONFIG_DEFAULTS" '$d * .' "$CONFIG_FILE")
  DATA_REPO=$(cfg dataRepo); DATA_REPO=${DATA_REPO/#\~/$HOME}
  [[ -n "$DATA_REPO" && "$DATA_REPO" != null ]] || die "config has no dataRepo"
  # Absolute only. A relative dataRepo resolves against the caller's working
  # directory, so the same config means one repo from a terminal and another
  # from the timer (which runs from /). Refuse rather than pick one.
  [[ "$DATA_REPO" == /* ]] || die "config dataRepo must be an absolute path, got: $DATA_REPO. Run: omabackup setup --data-repo <absolute dir>"
  STAGE="$DATA_REPO/.staging"
  CFG_REMOTE_URL=$(cfg remote.url); CFG_REMOTE_TRUSTED=$(cfg remote.trusted)
  CFG_MAX_FILE_SIZE=$(cfg maxFileSize); CFG_STALE_DAYS=$(cfg staleDays)
  CFG_MAX_MISSING_PCT=$(cfg maxMissingPct); CFG_MAX_SCAN_FILES=$(cfg maxScanFiles)
  CFG_NOTIFY=$(cfg notify); CFG_SHELL_NAG=$(cfg shellNag)
  CFG_TIMER_CALENDAR=$(cfg timer.calendar); CFG_TIMER_JITTER=$(cfg timer.jitter)
  for n in "$CFG_STALE_DAYS" "$CFG_MAX_MISSING_PCT" "$CFG_MAX_SCAN_FILES"; do
    [[ "$n" =~ ^[0-9]+$ ]] || die "config: staleDays, maxMissingPct and maxScanFiles must be integers"
  done
  [[ "$CFG_MAX_FILE_SIZE" =~ ^[0-9]+[kmg]?$ ]] || die "config: maxFileSize must look like 8m"
  export DATA_REPO STAGE
}

cfg() { jq -r --arg k "$1" 'getpath($k | split(".")) // empty' <<<"${CFG_JSON:-{\}}"; }

# config_write JSON: atomic, 0600, parent 0700.
config_write() {
  # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
  mkdir -m 700 -p "$(dirname "$CONFIG_FILE")"
  local tmp; tmp=$(mktemp "$(dirname "$CONFIG_FILE")/.config.XXXXXX")
  jq . <<<"$1" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$CONFIG_FILE"
}

# state_write_status JSON: atomic rename so the widget's FileView never sees a torn file.
state_write_status() {
  # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
  mkdir -m 700 -p "$STATE_DIR"
  local tmp; tmp=$(mktemp "$STATE_DIR/.status.XXXXXX")
  printf '%s\n' "$1" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$STATUS_FILE"
}

# data_repo_require: the marker is the contract; refuse a repo we do not understand.
data_repo_require() {
  [[ -d "$DATA_REPO/.git" ]] || die "data repo is not a git repository: $DATA_REPO"
  [[ -f "$DATA_REPO/.omabackup" ]] || die "data repo has no .omabackup marker: run omabackup setup --import $DATA_REPO"
  local fmt; fmt=$(jq -r '.format // 0' "$DATA_REPO/.omabackup" 2>/dev/null || echo 0)
  [[ "$fmt" == 1 ]] || die "data repo format $fmt is not supported by this version"
}
