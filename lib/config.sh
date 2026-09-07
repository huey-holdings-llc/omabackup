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

# Guard-weakening test hooks, honoured ONLY when BOTH of these hold:
# OMABACKUP_IN_SUITE=1 (tests/engine.test.sh exports it at its own top) and
# OMABACKUP_CONFIG naming a config file. The marker alone is one exported
# variable away from being set by whoever set the hook, which puts the whole
# gate back where it started; every fixture points OMABACKUP_CONFIG at its own
# throwaway config, and a real install never sets it, because a real install
# reads $XDG_CONFIG_HOME/omabackup/config.json. Two variables that only ever
# occur together in a test run are a much worse thing to arrive at by accident
# than one. A marker set WITHOUT the redirection is reported as a problem of
# its own below, so the bypass attempt is visible rather than silent.
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
OMABACKUP_SUITE_MARKER_STRAY=0
_ob_in_suite=0
if [[ "${OMABACKUP_IN_SUITE:-0}" == 1 ]]; then
  if [[ -n "${OMABACKUP_CONFIG:-}" ]]; then _ob_in_suite=1; else OMABACKUP_SUITE_MARKER_STRAY=1; fi
fi
if [[ "$_ob_in_suite" != 1 ]]; then
  for _ob_hook in OMABACKUP_MIN_FILES OMABACKUP_MIN_ALLOWLIST OMABACKUP_MIN_RESTORE \
                  OMABACKUP_NET OMABACKUP_SKIP_ETC OMABACKUP_SKIP_DROPINS; do
    [[ -n "${!_ob_hook:-}" ]] || continue
    OMABACKUP_OVERRIDES_IGNORED+="${OMABACKUP_OVERRIDES_IGNORED:+ }$_ob_hook"
    unset "$_ob_hook"
  done
  unset _ob_hook
fi
# Kept (not unset) so the rest of the tool can tell a test run from a real one
# without re-deriving the rule. Assigned unconditionally here, so setting it in
# the environment achieves nothing.
OMABACKUP_SUITE_ACTIVE=$_ob_in_suite
unset _ob_in_suite
export OMABACKUP_OVERRIDES_IGNORED OMABACKUP_SUITE_MARKER_STRAY OMABACKUP_SUITE_ACTIVE

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

# logf LINE: append to the tool's own log. Never fatal, and never noisy about
# itself: a log line is a record of work that has already happened, so a
# $STATE_DIR that cannot be written must not end the run that was writing it
# (under `set -e` the bare mkdir and the bare append both did). One warn per
# process, not one per line: the first is the diagnosis and the rest is noise.
# The mode matches every other creator of this directory -- it holds the log,
# the status file and the push verdict, and 0700 is the whole reason scratch
# is allowed to live there.
LOGF_WARNED=0
logf() {
  # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
  if ! mkdir -m 700 -p "$STATE_DIR"; then
    [[ "$LOGF_WARNED" == 1 ]] || warn "cannot create $STATE_DIR; this run is not being logged"
    LOGF_WARNED=1
    return 0
  fi
  if [[ -f "$LOG_FILE" ]] && (( $(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0) > 1000000 )); then mv -f "$LOG_FILE" "$LOG_FILE.1"; fi
  if ! printf '%s %s\n' "$(date +%FT%T)" "$*" >> "$LOG_FILE"; then
    [[ "$LOGF_WARNED" == 1 ]] || warn "cannot write $LOG_FILE; this run is not being logged"
    LOGF_WARNED=1
  fi
  return 0
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
    # is known. Whole line against whole line: a substring test on the
    # newline-joined list read "known parent" for any name that merely appeared
    # inside another one, so `remote.x` was skipped whenever an unrelated
    # `remotely` key happened to be present in the same config.
    if grep -qxF -- "${k%%.*}" <<<"$unknown_top"; then continue; fi
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
  # The character class runs UNCONDITIONALLY, before and regardless of
  # systemd-analyze. Two reasons it cannot be left to systemd:
  #   * a backslash is not systemd syntax but IS awk syntax -- `awk -v x=…`
  #     interprets escape sequences in the value, so `daily\nExecStart=…`
  #     became a real newline and a second directive inside the unit, with
  #     systemd-analyze never consulted because the machine happened not to
  #     have it;
  #   * a `%` is a systemd unit specifier (%h, %i), which systemd-analyze
  #     accepts in a calendar string but which means something else entirely
  #     once it is inside a unit file.
  # A missing systemd-analyze is now a health problem rather than only a warn,
  # so "not validated" is visible in the widget instead of scrolling past in a
  # timer's journal.
  local tv
  for tv in "$CFG_TIMER_CALENDAR" "$CFG_TIMER_JITTER"; do
    case "$tv" in
      *\\*|*$'\n'*|*%*)
        die "config: timer.calendar and timer.jitter must not contain a backslash, a newline or a percent sign: $tv" ;;
    esac
  done
  CFG_TIMER_VALIDATED=1
  if have systemd-analyze; then
    systemd-analyze calendar -- "$CFG_TIMER_CALENDAR" >/dev/null 2>&1 \
      || die "config: timer.calendar is not a systemd OnCalendar expression: $CFG_TIMER_CALENDAR"
    systemd-analyze timespan -- "$CFG_TIMER_JITTER" >/dev/null 2>&1 \
      || die "config: timer.jitter is not a systemd time span: $CFG_TIMER_JITTER"
  else
    CFG_TIMER_VALIDATED=0
    warn "systemd-analyze not found: timer.calendar and timer.jitter were not validated"
  fi
  export DATA_REPO STAGE
}

# cfg KEY: one config value by dotted path, or nothing when the key is absent.
# `select(. != null)`, not `// empty`: jq's alternative operator treats false
# the same as null, so `notify: false` used to read back as the empty string
# and every caller's "default to true" then applied. The README documented
# the knob for two releases and nothing honoured it.
cfg() { jq -r --arg k "$1" 'getpath($k | split(".")) | select(. != null)' <<<"${CFG_JSON:-{\}}"; }

# config_write JSON: atomic, 0600, parent 0700.
config_write() {
  # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
  mkdir -m 700 -p "$(dirname "$CONFIG_FILE")"
  local tmp; tmp=$(mktemp "$(dirname "$CONFIG_FILE")/.config.XXXXXX")
  jq . <<<"$1" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$CONFIG_FILE"
}

# state_write_status JSON: atomic rename so the widget's FileView never sees a torn file.
#
# WARN AND SKIP on every step. This runs AFTER the verb has done its work and
# decided its answer, and that answer still has to reach stdout: under `set -e`
# an unwritable $STATE_DIR killed the process here, so `status --json` on a
# state directory nobody can write printed NOTHING at all -- no object, not
# even a refusal, which is the one thing the JSON contract forbids. The widget
# keeps reading the file it already has (health calls it stale soon enough).
state_write_status() {
  # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
  mkdir -m 700 -p "$STATE_DIR" \
    || { warn "cannot create $STATE_DIR; status.json was not updated"; return 0; }
  local tmp
  tmp=$(mktemp "$STATE_DIR/.status.XXXXXX") \
    || { warn "cannot write scratch under $STATE_DIR; status.json was not updated"; return 0; }
  if printf '%s\n' "$1" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$STATUS_FILE"; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  warn "cannot update $STATUS_FILE; the widget is reading an older status"
  return 0
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
  # Only ever tighten a directory that carries the marker. DATA_REPO comes
  # from a config file a human can edit, and chmod 700 on whatever it happens
  # to name (a home directory, a shared project) would be this tool's bug, not
  # its fix. setup writes the marker before it calls this.
  [[ -f "$DATA_REPO/.omabackup" ]] || return 0
  local d m
  for d in "$DATA_REPO" "$DATA_REPO/.git"; do
    [[ -d "$d" ]] || continue
    m=$(stat -c %a "$d" 2>/dev/null) || continue
    [[ "$m" == 700 ]] && continue
    warn "data repo path $d is mode $m; tightening to 700"
    chmod 700 "$d" || warn "could not chmod 700 $d"
  done
}

# data_repo_marker_format FILE: print the marker's format number, or return 1
# printing nothing when the file is not JSON this tool can read.
#
# Both callers used to spell this `jq -r '.format // 0' … || echo 0`, which
# substitutes a VALID answer for a parse failure: a corrupt or truncated
# marker read as format 0, sailed through the `<= 1` check as a repo this
# version understands, and setup then rewrote it -- so a half-written format:2
# marker was silently replaced with format:1 and the one record of what wrote
# the repo was gone. A parse failure is not a format; it is a refusal.
data_repo_marker_format() {
  local fmt
  fmt=$(jq -r '.format // 0' "$1" 2>/dev/null) || return 1
  case "$fmt" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$fmt"
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
  local fmt
  fmt=$(data_repo_marker_format "$DATA_REPO/.omabackup") \
    || die "data repo marker has no usable format field: $DATA_REPO/.omabackup. The marker is committed, so restore it with: git -C $DATA_REPO checkout -- .omabackup"
  [[ "$fmt" -le 1 ]] || die "data repo format $fmt is newer than this version understands; upgrade omabackup"
  data_repo_assert_mode
}

# data_repo_gitignore_sync: bring an EXISTING repo's .gitignore up to the set
# this version ships. Warn and fix; never remove, never reorder.
#
# Both cp sites in lib/setup.sh are conditional (`[[ -f ... ]] || cp`), which
# is the right call on its own -- a rewrite would take lines the user added --
# but together they mean a repo created before a class was added to
# share/data.gitignore never gets it, and nothing was ever going to. The live
# example is `.omabackup.*`: on a repo set up before that line existed, an
# interrupted setup leaves the marker scratch file untracked, and the login
# check names it as an uncommitted edit at every new terminal forever.
#
# What it does NOT do is remove or reorder anything, and the lines are appended
# in the shipped file's own order -- which is what keeps `id_*` ahead of
# `!id_*.pub` on a repo that has neither.
#
# "It can only ever ignore MORE" is what this comment used to claim, and it is
# not true in two directions, because share/data.gitignore carries a negation.
# Re-adding `!id_*.pub` to a repo where the user deleted it on purpose ignores
# LESS: public keys go back to being committed. And a shipped line appended
# below a negation the user wrote themselves shadows it, since git's last
# matching rule wins. Neither is a reason to stop syncing a file that is
# entirely credential classes and this tool's own scratch, but both are why
# the warn tells the user to look at the result, and why the README says to
# keep your own negations at the end.
#
# Comments and blank lines are not compared: they are formatting, not rules.
# One `printf` writes the whole block, and a repo that has every line writes
# nothing at all -- which is every repo from the second run on, and every repo
# setup created.
#
# Called from data_repo_gitignore_sync_commit only, never from the gate every
# verb passes through: a read-only verb (status, drift, lint, the widget's
# refresh) used to write this file outside the lock, racing whatever held
# it, and then left the edit for a human to commit. GITIGNORE_SYNC_ADDED is
# how many lines this call appended, 0 when it appended nothing or could not.
data_repo_gitignore_sync() {
  GITIGNORE_SYNC_ADDED=0
  local shipped="$PLUGIN_DIR/share/data.gitignore" have="$DATA_REPO/.gitignore"
  [[ -r "$shipped" ]] || return 0
  local exists=0
  if [[ -f "$have" ]]; then exists=1; fi
  # grep's THREE exit codes, not two. 0 is "the line is there", 1 is "it is
  # not", and anything above 1 is grep saying it could not answer -- an
  # unreadable file, a permission error. Read as a plain boolean, that third
  # answer meant "absent", so a .gitignore this tool cannot read would have had
  # every shipped pattern appended to it, in a duplicate block, on every single
  # run. A sync that cannot compare does not sync.
  local line missing=() rc
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    if [[ "$exists" == 1 ]]; then
      rc=0; grep -qxF -- "$line" "$have" || rc=$?
      [[ $rc -eq 0 ]] && continue
      if [[ $rc -gt 1 ]]; then
        warn "cannot read $have (grep exited $rc); leaving its ignore patterns alone"
        return 0
      fi
    fi
    missing+=("$line")
  done < "$shipped"
  (( ${#missing[@]} > 0 )) || return 0
  local block
  block=$(
    printf '\n# %s: ignore patterns this version of omabackup ships that this\n' "$(date +%F)"
    printf '# file did not have. Nothing here is ever removed by the tool.\n'
    printf '%s\n' "${missing[@]}"
  )
  printf '%s\n' "$block" >> "$have" \
    || { warn "cannot write $have; ${#missing[@]} shipped ignore pattern(s) are missing from it"; return 0; }
  GITIGNORE_SYNC_ADDED=${#missing[@]}
  log "added ${#missing[@]} ignore pattern(s) this version ships to $have"
}

# data_repo_gitignore_sync_commit: the sync, plus the commit it owes. Only a
# path that holds the repo lock and is about to commit anyway calls this (the
# snapshot, and setup adopting a repo). The commit stages .gitignore by name
# and nothing else, and it happens only when the file was clean before the
# sync and the index is empty: a user's own uncommitted edit to .gitignore, or
# anything they had staged, must not ride into a commit this tool signs.
# In those cases the patterns are still appended (they are all credential
# classes and this tool's own scratch, and every run without them is a run
# that could commit a credential file) and the edit is left for the user,
# which is what the popup's Commit button and push --confirm are for.
data_repo_gitignore_sync_commit() {
  local dirty_before
  dirty_before=$(git -C "$DATA_REPO" status --porcelain -- .gitignore 2>/dev/null) || dirty_before='?'
  data_repo_gitignore_sync
  (( GITIGNORE_SYNC_ADDED > 0 )) || return 0
  if [[ -n "$dirty_before" ]]; then
    warn "your own edit to .gitignore was already uncommitted, so the $GITIGNORE_SYNC_ADDED appended pattern(s) were not committed either; commit both with the popup's Commit button, or omabackup push --confirm"
    return 0
  fi
  if ! git -C "$DATA_REPO" diff --cached --quiet; then
    warn "something is already staged in the data repo, so the $GITIGNORE_SYNC_ADDED appended .gitignore pattern(s) were not committed; commit them with the popup's Commit button, or omabackup push --confirm"
    return 0
  fi
  git_ident_args
  if git -C "$DATA_REPO" add -- .gitignore \
     && git -C "$DATA_REPO" ${GIT_IDENT_ARGS[@]+"${GIT_IDENT_ARGS[@]}"} commit -q -m "omabackup: .gitignore gains $GITIGNORE_SYNC_ADDED ignore pattern(s) this version ships" -- .gitignore; then
    log "committed the .gitignore update"
  else
    warn "could not commit the .gitignore update; it stays an uncommitted edit (the popup's Commit button, or omabackup push --confirm)"
  fi
}
