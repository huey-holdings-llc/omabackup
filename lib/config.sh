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
# OMARCHY_PATH is how the shell itself resolves the stock tree
# (/usr/share/omarchy/shell/shell.qml reads it), and `omarchy dev link` points
# it at a checkout. Hardcoding /usr/share/omarchy meant a moved or linked stock
# tree broke the engine while the shell carried on: section 1 of the drift scan
# (~/.config against stock, the single biggest detector) would emit one ERROR
# row and stop reporting every newly appearing ~/.config/<app>.
STOCK_DIR="${OMABACKUP_STOCK_DIR:-${OMARCHY_PATH:-/usr/share/omarchy}}"

# Guard-weakening test hooks, honoured ONLY when the suite marks itself with
# OMABACKUP_IN_SUITE=1 (tests/engine.test.sh exports it at its own top).
#
# A `systemd --user` unit inherits the user manager's environment
# (~/.config/environment.d/*.conf, `systemctl --user import-environment`, a
# line in .bashrc), so one of these set once reached the daily timer forever
# and nothing said so: OMABACKUP_MIN_FILES=1 disables the hollow-snapshot
# floor that stops a collapsed staging tree overwriting a good backup, and
# OMABACKUP_NET=0 makes the visibility probe skip the public-repo check
# entirely. Outside the suite they are unset here and named in a health
# problem below, so the widget reads fault rather than a quietly weaker guard.
#
# The path redirections (OMABACKUP_CONFIG, OMABACKUP_STATE_DIR,
# OMABACKUP_STOCK_DIR, OMABACKUP_ETC_ROOT) and OMABACKUP_SKIP_TIMERS,
# OMABACKUP_LOCK_WAIT and OMABACKUP_NOTIFY are deliberately NOT in this list:
# they point the tool at other files or quieten it, they do not weaken a guard
# over what it does look at.
OMABACKUP_OVERRIDES_IGNORED=""
if [[ "${OMABACKUP_IN_SUITE:-0}" != 1 ]]; then
  for _ob_hook in OMABACKUP_MIN_FILES OMABACKUP_MIN_ALLOWLIST OMABACKUP_MIN_RESTORE \
                  OMABACKUP_NET OMABACKUP_SKIP_ETC OMABACKUP_SKIP_DROPINS; do
    [[ -n "${!_ob_hook:-}" ]] || continue
    OMABACKUP_OVERRIDES_IGNORED+="${OMABACKUP_OVERRIDES_IGNORED:+ }$_ob_hook"
    unset "$_ob_hook"
  done
  unset _ob_hook
fi
export OMABACKUP_OVERRIDES_IGNORED

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

# config_key_near_miss KEY KNOWN_JSON: 0 when KEY reads as a typo of one of the
# keys in the KNOWN_JSON array -- the same name in a different case, or within
# Levenshtein distance 2. Distance rather than a prefix test because the
# realistic typos are a doubled letter (dataRepoo), a dropped one (maxMisingPct)
# and a transposition (staleDsya), none of which a prefix match catches. The key
# is passed to awk through -v as DATA; awk never sees it as program text.
config_key_near_miss() {
  local key=$1 known=$2
  jq -r '.[]' <<<"$known" | awk -v k="$key" '
    function min3(a, b, c,   m) { m = a; if (b < m) m = b; if (c < m) m = c; return m }
    function lev(s, t,   n, m, i, j, cost, prev, cur) {
      n = length(s); m = length(t)
      for (j = 0; j <= m; j++) prev[j] = j
      for (i = 1; i <= n; i++) {
        cur[0] = i
        for (j = 1; j <= m; j++) {
          cost = (substr(s, i, 1) == substr(t, j, 1)) ? 0 : 1
          cur[j] = min3(cur[j-1] + 1, prev[j] + 1, prev[j-1] + cost)
        }
        for (j = 0; j <= m; j++) prev[j] = cur[j]
      }
      return prev[m]
    }
    tolower($0) == tolower(k) { found = 1; exit }
    lev($0, k) <= 2 { found = 1; exit }
    END { exit(found ? 0 : 1) }
  '
}

# config_load: parse, reject unknown keys, apply defaults, export CFG_* and paths.
config_load() {
  config_exists || die "no config at $CONFIG_FILE. Run: omabackup setup"
  jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || die "config is not valid JSON: $CONFIG_FILE"
  jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1 || die "config is not a JSON object: $CONFIG_FILE"
  # UNKNOWN KEYS: a typo halts, a key from the future does not.
  #
  # Every unrecognised key used to be a hard die, on every verb. That is right
  # for `maxMisingPct`, where a silently ignored key means a threshold the user
  # believes is set and is not. It is wrong for a key a NEWER omabackup wrote:
  # the first time 1.1 adds a knob, a 1.0 install (or the other machine in a
  # synced pair) refuses to run at all rather than ignoring one field it can
  # safely ignore. So: a near-miss of a known key -- same name in different
  # case, or within edit distance 2 -- is a typo and dies; anything else warns
  # and is ignored. CONFIG_KNOWN/CONFIG_KNOWN_DOTTED stay the source of truth
  # for both halves.
  local unknown_top unknown_nested k
  unknown_top=$(jq -r --argjson known "$CONFIG_KNOWN" '
    [paths as $p | select(($p | length) == 1) | $p[0]] - $known | join("\n")' "$CONFIG_FILE")
  unknown_nested=$(jq -r --argjson knownDotted "$CONFIG_KNOWN_DOTTED" '
    [paths as $p | select(($p | length) == 2) | ($p[0] + "." + ($p[1] | tostring))] - $knownDotted
    | join("\n")' "$CONFIG_FILE")
  local -a typos=() novel=()
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    if config_key_near_miss "$k" "$CONFIG_KNOWN"; then typos+=("$k"); else novel+=("$k"); fi
  done <<<"$unknown_top"
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    # A nested key under a top-level key that is itself unrecognised is already
    # covered by the warning about its parent; only judge the ones whose parent
    # is known.
    case "$unknown_top" in *"${k%%.*}"*) continue ;; esac
    if config_key_near_miss "$k" "$CONFIG_KNOWN_DOTTED"; then typos+=("$k"); else novel+=("$k"); fi
  done <<<"$unknown_nested"
  [[ ${#typos[@]} -eq 0 ]] \
    || die "unknown config key(s): ${typos[*]} -- close enough to a known key to be a typo, so nothing here is being ignored quietly"
  [[ ${#novel[@]} -eq 0 ]] \
    || warn "ignoring config key(s) this version does not know: ${novel[*]}"
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
  # timer.* was the one pair of config values that reached a FILE unchecked:
  # both are substituted into the shipped unit templates, and a `|` used to
  # terminate the sed `s` command and let the rest of the value become more sed
  # script (`daily|; s|ExecStart=.*|ExecStart=...|` rewrites the unit that runs
  # daily as the user). The substitution no longer uses sed, but a value
  # systemd cannot parse still produces a unit systemd refuses to load, which
  # is a backup that silently stops. Ask systemd itself; it is the only
  # authority on its own grammar. Skipped, loudly, where systemd-analyze is not
  # installed -- refusing every verb over a missing diagnostic tool would be a
  # worse failure than the one being prevented.
  if have systemd-analyze; then
    systemd-analyze calendar -- "$CFG_TIMER_CALENDAR" >/dev/null 2>&1 \
      || die "config: timer.calendar is not a systemd OnCalendar expression: $CFG_TIMER_CALENDAR"
    systemd-analyze timespan -- "$CFG_TIMER_JITTER" >/dev/null 2>&1 \
      || die "config: timer.jitter is not a systemd time span: $CFG_TIMER_JITTER"
  else
    warn "systemd-analyze not found: timer.calendar and timer.jitter were not validated"
  fi
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

# data_repo_assert_mode: the repo root and .git must be 0700. .git holds every
# backed-up config in full history, and nothing was ever asserting its mode:
# `mkdir -m 700 -p` leaves an EXISTING directory alone, and `setup --import`
# chmod'd nothing, so pointing setup at a directory that already existed, or
# adopting a clone made under a looser umask, left all of it group and world
# readable. home/, etc/ and manifests/ self-heal through the snapshot's
# `rsync -a`; .git never does. Warn and fix rather than die: a too-open repo
# is a thing to close, not a reason to stop backing up.
data_repo_assert_mode() {
  local d m
  for d in "$DATA_REPO" "$DATA_REPO/.git"; do
    [[ -d "$d" ]] || continue
    m=$(stat -c %a "$d" 2>/dev/null) || continue
    [[ "$m" == 700 ]] && continue
    warn "data repo path $d is mode $m; tightening to 700"
    chmod 700 "$d" || warn "could not chmod 700 $d"
  done
}

# data_repo_require: the marker is the contract; refuse a repo we do not understand.
data_repo_require() {
  [[ -d "$DATA_REPO/.git" ]] || die "data repo is not a git repository: $DATA_REPO"
  [[ -f "$DATA_REPO/.omabackup" ]] || die "data repo has no .omabackup marker: run omabackup setup --import $DATA_REPO"
  # `<= 1`, not `== 1`. A repo whose marker says a LOWER format is one this
  # engine already understands completely; equality made format 0 (a marker
  # written before the field existed) unreadable for no reason. A HIGHER format
  # still refuses: a 1.1 repo may carry layout this version would misread, and
  # guessing is how a backup gets quietly damaged. setup_marker never lowers an
  # existing format, so the newer machine in a synced pair keeps working.
  local fmt; fmt=$(jq -r '.format // 0' "$DATA_REPO/.omabackup" 2>/dev/null || echo 0)
  case "$fmt" in ''|*[!0-9]*) die "data repo marker has no usable format field: $DATA_REPO/.omabackup" ;; esac
  [[ "$fmt" -le 1 ]] || die "data repo format $fmt is newer than this version understands; upgrade omabackup"
  data_repo_assert_mode
}
