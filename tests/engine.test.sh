#!/usr/bin/env bash
# Black-box suite for omabackup. Every group builds a throwaway fixture (home,
# stock stand-in, data repo, bare remote, config) and drives bin/omabackup.
# Nothing here reads lib/ internals, so any library can be reimplemented behind
# the same verbs and this suite still decides.
#   bash tests/engine.test.sh                 # all groups
#   OMABACKUP_TEST_GROUP=07 bash tests/engine.test.sh
#   OMABACKUP_REAL_REPO=1 ...                 # also run the two real-repo groups
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/../bin/omabackup"
# $$ alone is not unique enough: two checkouts, or a rerun after a PID wrap,
# share a fixture root and then delete each other's fixtures mid-run. The
# suffix costs nothing and makes a concurrent run merely slow, not wrong.
ROOT="${OMABACKUP_TEST_TMP:-$HERE/tmp}/$$.$RANDOM"; mkdir -p "$ROOT"
trap 'rm -rf "$ROOT"' EXIT
# Marks a suite as already running, so a self-test verb exercised BY the
# suite (group 00's misuse/recursion assertions) refuses instead of forking
# the whole suite again -- see lib/selftest.sh.
export OMABACKUP_IN_SUITE=1

# ---- the fake machine-fact tier ---------------------------------------------
# Every fixture snapshot ran the real generators in lib/manifests.sh (pacman,
# systemctl, npm, fprintd, dconf and the rest), about four seconds a run on a
# laptop across some 180 runs: most of this suite's twelve minutes. No group
# asserts on what they print, so here they print something fixed, from stubs
# first on PATH; every generator finds its command through PATH. A group that
# needs the real tools calls real_manifests right after mk_fixture, and
# OMABACKUP_TEST_REAL_MANIFESTS=1 (self-test --real) puts every group on them.
# /var/log/pacman.log, /etc/os-release and uname are still read for real.
REAL_PATH=$PATH
FAKE_TOOLS="$ROOT/fakebin-manifests"; mkdir -p "$FAKE_TOOLS"
fake_tool() { printf '#!/bin/sh\n%s\n' "$2" > "$FAKE_TOOLS/$1"; chmod +x "$FAKE_TOOLS/$1"; }
# Output that is not a placeholder (is_placeholder, lib/manifests.sh), or the
# carry-forward guard would keep the last copy instead. pacman answers -Qii and
# -Qqo in the wording group 81 pins, and lists enough packages for restore.
fake_tool pacman 'case "$1" in
  -Qqen|-Slq) i=1; while [ $i -le 120 ]; do echo "fakepkg$i"; i=$((i+1)); done ;;
  -Qqem) echo fakeaur ;;
  -Q) shift; for p in "$@"; do echo "$p 1.0-1"; done ;;
  -Qii) printf "Name            : fakepkg\nBackup Files    :\n/etc/fstab [modified]\n" ;;
  -Qqo) shift; for f in "$@"; do echo "error: No package owns $f" >&2; done; exit 1 ;;
esac
exit 0'
# Only the listing the generators ask for. Every other verb fails the way the
# real one does against a unit that is not installed, so nothing here can
# start, enable or report a timer; groups that drive timers bring their own.
fake_tool systemctl 'for a in "$@"; do
  [ "$a" = list-unit-files ] && { echo "fake-unit.service enabled enabled"; exit 0; }
done
echo "fake systemctl: $*" >&2; exit 1'
# setup_units and setup_check both fork `systemd-analyze calendar -- VALUE`
# and `systemd-analyze timespan -- VALUE` (lib/setup.sh) to validate
# timer.calendar/timer.jitter, and a container with no systemd-analyze at
# all (an Arch container missing the `systemd` package, for one) would
# otherwise put every ordinary `setup` run in this suite on the "absent"
# branch, which now refuses (fail closed) rather than warns -- so every
# fixture needs a systemd-analyze on PATH exactly the way it needs a real
# Omarchy box's, or nothing here would ever finish `setup` at all. Accepts
# anything an OnCalendar/timespan value in this suite's fixtures actually
# is; refuses the two shapes a real systemd-analyze refuses that the tests
# rely on: a `;` in a calendar (the sed-delimiter injection payload) and a
# jitter that is not digits-then-a-unit-letter ("every other tuesday"). A
# group that needs systemd-analyze reported ABSENT builds its own PATH
# without this stub, the way group 105 builds a PATH without one tool.
fake_tool systemd-analyze 'case "$1" in
  calendar) case "$3" in *";"*) exit 1 ;; esac ;;
  timespan) case "$3" in [0-9]*[a-zA-Z]) : ;; *) exit 1 ;; esac ;;
esac
exit 0'
fake_tool dconf 'printf "[org/fake]\nkey=1\n"'
fake_tool lpstat 'case "$1" in -p) echo "printer fake is idle.";; -v) echo "device for fake: ipp://fake";; esac'
fake_tool timedatectl 'echo Etc/UTC'
fake_tool localectl 'echo "System Locale: LANG=C.UTF-8"'
# The generator drops the first line, the header the real tool prints.
fake_tool fprintd-list 'printf "found 1 devices\nfake-finger\n"'
fake_tool nmcli 'echo "fakenet:802-11-wireless"'
fake_tool code 'echo fake.extension'
fake_tool uv 'echo "faketool v1.0"'
# The generator drops the first line (npm's own prefix) and takes basenames.
fake_tool npm 'printf "/usr/lib\n/usr/lib/node_modules/fakepkg\n"'
# Only the listing. `restore --plugins --apply` runs `omarchy plugin add`, and
# a stub that said yes to that would report an install that never happened.
fake_tool omarchy '[ "$1 $2" = "plugin list" ] && { echo "[{\"id\":\"fake\"}]"; exit 0; }
echo "fake omarchy: $*" >&2; exit 1'
# real_manifests: this group needs the real tools. Call it after mk_fixture,
# which puts every fixture back on the stubs.
real_manifests() { export PATH="$REAL_PATH"; }
if [[ "${OMABACKUP_TEST_REAL_MANIFESTS:-0}" != 1 ]]; then export PATH="$FAKE_TOOLS:$REAL_PATH"; fi

STOCK_SRC="$HERE/fixtures/stock"
MANIFEST_VERSION=$(jq -r .version "$HERE/../manifest.json")

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ✓ $1"; }
# RETURNS 0, deliberately. Many assertions are written `cond && bad "..." ||
# ok "..."`, so a bad() that returns non-zero (which it did whenever no detail
# argument was passed, the `[[ -n "${2:-}" ]] && echo` being the last command)
# ran the ok() branch too: one failing assertion recorded a fail AND a pass,
# and the totals said more assertions had run than there are.
bad()  { fail=$((fail+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; return 0; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d" "cmd: $*"; fi; }
fails() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d" "unexpectedly succeeded: $*"; else ok "$d"; fi; }
eq()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "got '$2' expected '$3'"; }
has()  { grep -q -- "$3" <<<"$2" && ok "$1" || bad "$1" "missing '$3'"; }
rand_body() { head -c 300 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
# modes_has LINE: modes.txt is NUL-delimited, so translate before grepping
# rather than relying on grep treating NUL as a line terminator.
modes_has() { tr '\0' '\n' < "$FR/modes.txt" | grep -qx "$1"; }
# allow ENTRY: append an allowlist entry and commit it, so a group's own
# subject is what the run's "uncommitted edits" report is about.
allow() { printf '%s\n' "$1" >> "$FR/allowlist.txt"; git -C "$FR" commit -qam "allow $1"; }
# fake_curl CODE [EXIT]: a curl stand-in printing CODE for -w %{http_code}, put on
# $T/fakebin so callers can prepend it to PATH. Call after mk_fixture (needs $T).
fake_curl() {
  mkdir -p "$T/fakebin"; printf '#!/bin/sh\nprintf %%s "%s"\nexit %s\n' "$1" "${2:-0}" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
}

# ---- fixture ----------------------------------------------------------------
# mk_fixture NAME: fresh home + stock + data repo + bare remote + config under $ROOT/NAME.
mk_fixture() {
  T="$ROOT/$1"; FH="$T/home"; FR="$T/data"; BARE="$T/remote.git"; STOCK="$T/stock"
  mkdir -p "$FH" "$FR" "$T/state" "$T/cfg"
  cp -a "$STOCK_SRC" "$STOCK"
  # -b main: a fresh git has no init.defaultBranch, so a clone of this bare
  # would otherwise land on master and never see the main the engine pushes.
  git init -q --bare -b main "$BARE"
  git -C "$FR" init -q -b main
  git -C "$FR" config user.email t@t; git -C "$FR" config user.name t
  git -C "$FR" remote add origin "$BARE"
  # Header-only: a real seed list carries Omarchy-stock entries a fixture home
  # does not have, and a required entry that does not resolve halts the
  # snapshot by design. Groups that need entries append their own (see seed_home).
  printf '# Paths under $HOME that omabackup backs up, one per line, relative to $HOME.\n# Prefix a line with ? to mark it optional.\n' > "$FR/allowlist.txt"
  cp "$HERE/../share/drift-ignore.example" "$FR/drift-ignore.txt"
  cp "$HERE/../share/etc-allowlist.example" "$FR/etc-allowlist.txt"
  cp "$HERE/../share/normalize.example" "$FR/normalize.txt"
  cp "$HERE/../share/data.gitignore" "$FR/.gitignore"
  # A pre-0.7.0 repo shape on purpose: setup used to copy the rules file in
  # here, and the copy is inert (lib/secrets.sh always scans with the plugin's
  # own share/gitleaks.toml). Group 41 removes it to prove the scan does not
  # depend on it; groups 51, 60 and 61 prove nothing writes or watches it.
  cp "$HERE/../share/gitleaks.toml" "$FR/.gitleaks.toml"
  printf '{"format":1,"createdBy":"test"}\n' > "$FR/.omabackup"
  # The repo root and .git are 0700 on a real install (setup chmods both, and
  # data_repo_require re-asserts it), so the fixture starts that way too --
  # otherwise every verb here would spend its first line tightening them.
  chmod 700 "$FR" "$FR/.git"
  : > "$FR/modes.txt"; mkdir -p "$FR/home" "$FR/etc" "$FR/manifests"
  git -C "$FR" add -A && git -C "$FR" commit -qm "fixture"
  export OMABACKUP_CONFIG="$T/cfg/config.json" OMABACKUP_STATE_DIR="$T/state" OMABACKUP_STOCK_DIR="$STOCK"
  export OMABACKUP_NET=0 OMABACKUP_NOTIFY=0 OMABACKUP_SKIP_ETC=1 OMABACKUP_SKIP_TIMERS=1
  export OMABACKUP_MIN_FILES=1 OMABACKUP_MIN_ALLOWLIST=1 OMABACKUP_LOCK_WAIT=2 OMABACKUP_MIN_RESTORE=1
  # Nothing in a fixture is mid-rename; group 53 sets its own wait.
  export OMABACKUP_SECOND_LOOK=0
  # Back on the stubs, so a real_manifests group (or one that exported its own
  # PATH) cannot leave the next group on something else.
  if [[ "${OMABACKUP_TEST_REAL_MANIFESTS:-0}" == 1 ]]; then export PATH="$REAL_PATH"; else export PATH="$FAKE_TOOLS:$REAL_PATH"; fi
  jq -n --arg r "$FR" --arg u "$BARE" '{dataRepo:$r, remote:{url:$u, trusted:true}}' > "$OMABACKUP_CONFIG"
  chmod 600 "$OMABACKUP_CONFIG"
}
# ob VERB...: run the CLI as the fixture user. obj adds --json.
ob()  { env HOME="$FH" "$CLI" "$@" 2>&1; }
obj() { env HOME="$FH" "$CLI" "$@" --json 2>/dev/null; }
# seed_home: a handful of allowlisted files (stock-derived and user-made) and one unbacked file.
seed_home() {
  mkdir -p "$FH/.config/hypr" "$FH/.config/mytool" "$FH/.local/bin"
  cp "$STOCK/config/hypr/bindings.lua" "$FH/.config/hypr/bindings.lua"
  echo 'bind("SUPER","B","exec","browser")' >> "$FH/.config/hypr/bindings.lua"
  printf 'setting=1\n' > "$FH/.config/mytool/mytool.conf"
  printf '#!/bin/sh\necho hi\n' > "$FH/.local/bin/hello"; chmod +x "$FH/.local/bin/hello"
  printf 'source stock\nexport EDITOR=nvim\n' > "$FH/.bashrc"
  printf '.config/hypr/bindings.lua\n.local/bin/hello\n.bashrc\n' >> "$FR/allowlist.txt"
  git -C "$FR" commit -qam "seed allowlist"
}
commit_baseline() { ob snapshot --no-push >/dev/null; }

# ---- groups -----------------------------------------------------------------
declare -A GROUPS_RUN=()
# Seconds per group, for the slowest-five footer. group() has no end hook, so
# a group's time is closed when the next one starts, and at the footer.
declare -A GROUP_SECS=()
GROUP_CUR=""; GROUP_T0=0
group_close() { [[ -n "$GROUP_CUR" ]] && GROUP_SECS[$GROUP_CUR]=$(( SECONDS - GROUP_T0 )); GROUP_CUR=""; }
group() { # group NN NAME: run unless OMABACKUP_TEST_GROUP selects another
  local n=$1; shift
  group_close
  [[ -n "${OMABACKUP_TEST_GROUP:-}" && "$OMABACKUP_TEST_GROUP" != "$n" ]] && return 1
  GROUP_CUR=$n; GROUP_T0=$SECONDS
  printf '\n\033[1;34m== %s. %s\033[0m\n' "$n" "$*"
  # shellcheck disable=SC2034  # written per group run; a later task's summary step reads it
  GROUPS_RUN[$n]=1
  return 0
}

if group 00 "baseline: version, help, config validation"; then
  eq "version matches manifest" "$("$CLI" version)" "$MANIFEST_VERSION"
  check "help exits 0" "$CLI" help
  fails "unknown verb is usage (exit 2)" "$CLI" bogus
  [[ $("$CLI" bogus >/dev/null 2>&1; echo $?) == 2 ]] && ok "exit code 2 for usage" || bad "usage exit code"
  mk_fixture g00
  # A TYPO of a known key, not a wholly unknown one: a misspelled key is a
  # threshold the user believes is set and is not, so it still halts. A key
  # this version has simply never heard of warns instead (group 87).
  jq '. + {dataRepoo:1}' "$OMABACKUP_CONFIG" > "$T/bad.json"
  eq "a mistyped config key refused as JSON" "$(OMABACKUP_CONFIG=$T/bad.json obj status | jq -r .ok)" "false"
  has "refusal names the key" "$(OMABACKUP_CONFIG=$T/bad.json obj status)" "dataRepoo"
  # status and health are special-cased (Task 10): they run without a config
  # and report "not-configured" instead of dying, so this die()-refusal probe
  # uses a verb that still requires config unconditionally.
  eq "missing config refused with setup hint" "$(OMABACKUP_CONFIG=/nonexistent ob drift; true)" "$(printf '\033[1;31m[FAIL]\033[0m no config at /nonexistent. Run: omabackup setup')"

  # self-test: --help is answered by the dispatcher, before any lib/ parser
  # sees the flag, so it prints the verb's own usage line and exits 0 (it used
  # to reach cmd_self_test and come back as "unknown flag"). An unknown flag
  # is still a usage error (exit 2), same as every other verb, and self-test
  # refuses to run recursively from inside a suite that is already running
  # (this suite exports OMABACKUP_IN_SUITE=1 at its own top) rather than
  # forking the whole suite again.
  check "self-test: --help is answered, not refused" env HOME="$FH" "$CLI" self-test --help
  [[ $(env HOME="$FH" "$CLI" self-test --help >/dev/null 2>&1; echo $?) == 0 ]] \
    && ok "self-test: --help exits 0" || bad "self-test: --help exit code"
  has "self-test: --help prints the verb's own usage line" \
    "$(env HOME="$FH" "$CLI" self-test --help 2>&1)" "self-test"
  fails "self-test: unknown flag is refused" env HOME="$FH" "$CLI" self-test --bogus
  [[ $(env HOME="$FH" "$CLI" self-test --bogus >/dev/null 2>&1; echo $?) == 2 ]] \
    && ok "self-test: unknown flag exits 2" || bad "self-test: unknown flag exit code"
  eq "self-test: refuses to run from inside a running suite" "$(obj self-test | jq -r .ok)" "false"
  has "the refusal names the guard" "$(obj self-test)" "recursively"

  # notify-failure: hidden verb (not in usage), used from ExecStopPost / OnFailure=
  # in the shipped units. A bad arg is a usage error like any other verb; a
  # known one is silent, since the fixture (like the unit files) runs with
  # OMABACKUP_NOTIFY=0.
  fails "notify-failure: unknown arg is usage (exit 2)" ob notify-failure bogus
  [[ $(ob notify-failure bogus >/dev/null 2>&1; echo $?) == 2 ]] \
    && ok "notify-failure: unknown arg exits 2" || bad "notify-failure: unknown arg exit code"
  nf_out=$(ob notify-failure snapshot); nf_rc=$?
  eq "notify-failure snapshot exits 0" "$nf_rc" "0"
  eq "notify-failure snapshot is silent with OMABACKUP_NOTIFY=0" "$nf_out" ""

  # THE FAILURE THIS VERB EXISTS TO ANNOUNCE INCLUDES THE CONFIG ITSELF. It was
  # in the config_load list, so a config that no longer parses -- or was
  # removed while the timer stayed installed -- died here too, and the one
  # signal the user had about a snapshot that stopped working was a line in a
  # journal nobody reads. It reads the config best-effort now: notify() already
  # defaults CFG_NOTIFY to true, which is the fail-loud direction.
  printf 'not json at all {\n' > "$T/broken.json"
  nfb_rc=$(OMABACKUP_CONFIG=$T/broken.json ob notify-failure snapshot >/dev/null 2>&1; echo $?)
  eq "notify-failure snapshot exits 0 with an unparsable config" "$nfb_rc" "0"
  nfm_rc=$(OMABACKUP_CONFIG=/nonexistent ob notify-failure snapshot >/dev/null 2>&1; echo $?)
  eq "notify-failure snapshot exits 0 with no config at all" "$nfm_rc" "0"
  eq "a bad arg is still a usage error, config or no config" \
    "$(OMABACKUP_CONFIG=/nonexistent ob notify-failure bogus >/dev/null 2>&1; echo $?)" "2"

  # The WORDING, read the way a user reads it: through a notifier on PATH.
  # notify() prefers omarchy-notification-send and falls back to notify-send,
  # so both are stubbed (group 49 does the same). Three things are asserted
  # here because all three are wrong when they are wrong and nobody sees it
  # until the notification fires on somebody's laptop:
  #   - the snapshot body names `omabackup status`, the readable answer,
  #     before the journal command;
  #   - a self-test FAILURE no longer says "a safety guard has stopped
  #     working", which reads like data loss for a suite that can go red for a
  #     dozen benign reasons, and it says backups are still running;
  #   - a self-test the unit KILLED for running past TimeoutStartSec says so,
  #     and is not critical, because a run that was stopped proved nothing.
  mkdir -p "$T/fakebin"
  for n in notify-send omarchy-notification-send; do
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/nf.log"\n' "$T" > "$T/fakebin/$n"
    chmod +x "$T/fakebin/$n"
  done
  nf() { : > "$T/nf.log"; env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_NOTIFY=1 "$CLI" notify-failure "$@" >/dev/null 2>&1; cat "$T/nf.log"; }
  nf_snap=$(nf snapshot)
  has "the snapshot notification sends the user to status first" "$nf_snap" "omabackup status, then journalctl"
  nf_fail=$(nf selftest)
  has "a self-test failure says backups are still running" "$nf_fail" "backups are still running"
  eq "a self-test failure does not claim a guard has stopped working" \
    "$(grep -c 'safety guard' <<<"$nf_fail" || true)" "0"
  eq "a self-test failure is still critical" "$(grep -c -- '-u critical' <<<"$nf_fail" || true)" "1"
  nf_to=$(nf selftest timeout)
  has "a timed-out self-test says it ran out of time" "$nf_to" "ran out of time"
  eq "a timed-out self-test is not critical: it proved nothing either way" \
    "$(grep -c -- '-u critical' <<<"$nf_to" || true)" "0"
fi

# Later tasks append groups here, in numeric order, each starting with mk_fixture.

if group 01 "assert: allowlist entry no longer resolves"; then
  mk_fixture g01; seed_home; commit_baseline
  before=$(git -C "$FR" rev-parse HEAD)
  cp "$FR/allowlist.txt" "$T/al.bak"
  # nullglob only suppresses words that CONTAIN a wildcard, so a literal
  # missing path expands to itself and a naive match-count guard passes.
  echo '.config/nope/GONE-RENAMED.conf' >> "$FR/allowlist.txt"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -ne 0 ]] && ok "literal missing path aborts" || bad "literal missing path did NOT abort"
  has "the refusal says the entries no longer exist" "$out" "no longer exist"
  eq "no commit created" "$(git -C "$FR" rev-parse HEAD)" "$before"
  cp "$T/al.bak" "$FR/allowlist.txt"
  echo '.config/nope/*.toml' >> "$FR/allowlist.txt"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -ne 0 ]] && ok "non-matching glob aborts" || bad "non-matching glob did NOT abort"
  has "the glob refusal says the entries no longer exist" "$out" "no longer exist"
  cp "$T/al.bak" "$FR/allowlist.txt"
fi
if group 02 "gitleaks gate"; then
  mk_fixture g02; seed_home; commit_baseline
  # shellcheck disable=SC2034  # only the assignment's exit status is used, to gate on gitleaks being installed
  if have_gitleaks=$(command -v gitleaks); then
    key="sk-ant-api03-$(rand_body 90)AA"
    printf 'ANTHROPIC_API_KEY=%s\n' "$key" > "$FH/.config/mytool/env"
    printf '.config/mytool/env\n' >> "$FR/allowlist.txt"; git -C "$FR" commit -qam allow
    before=$(git -C "$FR" rev-parse HEAD)
    out=$(ob snapshot --no-push); rc=$?
    [[ $rc -ne 0 ]] && ok "snapshot refuses a staged Anthropic key" || bad "the key was NOT blocked"
    has "the refusal names the staging tree" "$out" "staging tree"
    # The fixture's own baseline is a "snapshot:" commit too, so grepping the
    # log for one proves nothing: pin HEAD across the refused run instead.
    eq "nothing committed" "$(git -C "$FR" rev-parse HEAD)" "$before"
  else
    echo "  (gitleaks not installed: skipping content gate; filename gate still tested in group 13)"
  fi
fi
if group 03 "floor check (hollow snapshot)"; then
  mk_fixture g03; seed_home; commit_baseline
  for i in $(seq 1 30); do echo "$i" > "$FH/.config/mytool/f$i"; done
  allow '.config/mytool'
  check "baseline with 30 files" env HOME="$FH" "$CLI" snapshot --no-push
  rm -rf "$FH/.config/mytool"; mkdir -p "$FH/.config/mytool"
  # OMABACKUP_MIN_FILES= (empty) means "derive the floor from history", which
  # is the whole point: a fixed number stops discriminating as home/ grows.
  out=$(env HOME="$FH" OMABACKUP_MIN_FILES= "$CLI" snapshot --no-push 2>&1); rc=$?
  [[ $rc -ne 0 ]] && ok "a hollow snapshot is refused" || bad "committed a hollow snapshot"
  has "the floor message is explicit" "$out" "refusing to commit a hollow snapshot"
fi
if group 03b "a damaged object store refuses instead of lowering the floor"; then
  # HEAD resolving while its tree does not read means a damaged object store.
  # Swallowing that failure dropped the derived floor to the bootstrap 20, and
  # a repo in that state would then accept a hollow snapshot over a healthy
  # backup. Pointing the branch at a NON-tree object reproduces it exactly:
  # rev-parse --verify still succeeds, ls-tree does not.
  mk_fixture g03b; seed_home; commit_baseline
  for i in $(seq 1 30); do echo "$i" > "$FH/.config/mytool/f$i"; done
  allow '.config/mytool'
  check "baseline with 30 files" env HOME="$FH" "$CLI" snapshot --no-push
  # Written straight into the loose ref: `git update-ref` refuses to point a
  # branch at a non-commit, and a real damaged store never asked its permission.
  blob=$(printf 'not a commit\n' | git -C "$FR" hash-object -w --stdin)
  printf '%s\n' "$blob" > "$FR/.git/refs/heads/main"
  out=$(env HOME="$FH" OMABACKUP_MIN_FILES= "$CLI" snapshot --no-push 2>&1); rc=$?
  [[ $rc -ne 0 ]] && ok "a damaged HEAD is refused" || bad "ran against a damaged object store"
  has "the refusal points at fsck" "$out" "fsck"
fi
if group 04 "idempotency"; then
  # Regression: drift.txt and versions.txt embedded a timestamp, so every run
  # committed and the backup history became noise.
  # Real tools: the one group that would catch a real generator that is not
  # deterministic.
  mk_fixture g04; real_manifests; seed_home; commit_baseline
  n1=$(git -C "$FR" rev-list --count HEAD)
  # Assert the run SUCCEEDED before counting: "no new commit" is trivially
  # true of a snapshot that refused to run at all.
  ob snapshot --no-push >/dev/null; rc=$?
  [[ $rc -eq 0 ]] && ok "snapshot runs" || bad "snapshot failed (rc=$rc)"
  n2=$(git -C "$FR" rev-list --count HEAD)
  # A red run here on a real machine almost always means the machine itself
  # changed between the two snapshots (a plugin updated, a package installed,
  # a connection added), not a determinism bug in omabackup -- naming the
  # manifest that moved is the fastest way to tell the two apart.
  if [[ "$n2" == "$n1" ]]; then
    ok "unchanged machine makes no commit"
  else
    bad "unchanged machine makes no commit" "$(git -C "$FR" diff --stat "HEAD~$((n2 - n1))" HEAD)"
  fi
  eq "json says committed=false" "$(obj snapshot --no-push | jq -r .committed)" "false"
  dirty04=$(git -C "$FR" status --porcelain)
  if [[ -z "$dirty04" ]]; then
    ok "working tree left clean"
  else
    bad "working tree left clean" "$(git -C "$FR" status --short)"
  fi
fi
if group 05 "permissions are recorded in modes.txt"; then
  # git stores only the exec bit. The restore half of self-test.sh:160-184
  # (replaying these modes into a fresh $HOME) needs the restore verb and
  # lands with it; what the pipeline owns is recording them at all.
  mk_fixture g05; seed_home
  mkdir -p "$FH/.config/appb"; printf '{"a":1}\n' > "$FH/.config/appb/settings.json"
  chmod 600 "$FH/.config/appb/settings.json"; chmod 700 "$FH/.config/appb"
  allow '.config/appb'
  check "snapshot runs" env HOME="$FH" "$CLI" snapshot --no-push
  modes_has '600 home/.config/appb/settings.json' \
    && ok "modes.txt records the 600" || bad "modes.txt missing the 600"
  # Directories too: git checks every directory out as 755, so a 700 ~/.ssh
  # came back world-listable on a fresh clone.
  modes_has '700 home/.config/appb' \
    && ok "modes.txt records the 700 directory" || bad "modes.txt missing the directory mode"
fi
if group 06 "restore --configs: dry run touches nothing, --apply backs up and never deletes, /etc never writes"; then
  mk_fixture g06; seed_home
  mkdir -p "$FH/.config/appb"; printf '{"a":1}\n' > "$FH/.config/appb/settings.json"
  chmod 600 "$FH/.config/appb/settings.json"; chmod 700 "$FH/.config/appb"
  allow '.config/appb'; allow '.config/mytool'
  # Enough files that the dry run's listing has to cap itself: a real $HOME
  # has thousands, and 20 names plus a count is the preview, not a wall.
  mkdir -p "$FH/.config/appmany"
  for i in $(seq 1 25); do printf 'many %s\n' "$i" > "$FH/.config/appmany/f$i.conf"; done
  allow '.config/appmany'
  printf 'x\n' > "$FH/.config/mytool/trailing .conf "; chmod 600 "$FH/.config/mytool/trailing .conf "
  check "baseline snapshot runs" env HOME="$FH" "$CLI" snapshot --no-push

  # Local drift after the snapshot: one tracked file edited, one file the
  # snapshot never saw at all.
  printf 'LOCAL EDIT\n' > "$FH/.config/mytool/mytool.conf"
  printf 'keepme\n' > "$FH/.config/mytool/not-in-snapshot.conf"
  before=$(find "$FH" -type f -exec md5sum {} + 2>/dev/null | sort | md5sum)

  # --- dry run: $HOME is byte-for-byte unchanged ---
  check "dry run exits 0" env HOME="$FH" "$CLI" restore --configs
  after=$(find "$FH" -type f -exec md5sum {} + 2>/dev/null | sort | md5sum)
  eq "dry run left \$FH byte-for-byte unchanged" "$after" "$before"
  eq "json: applied is false on a dry run" "$(obj restore --configs | jq -r .applied)" "false"
  eq "json: a dry run writes nothing" "$(obj restore --configs | jq -r '.wrote | length')" "0"

  # --- the human dry run: it must not open by announcing a restore, and a
  # count on its own is not a preview of what it would touch ---
  dry06=$(ob restore --configs)
  has "the dry run leads with what it will not do" "$dry06" "\[dry\] nothing will be written; add --apply to do it for real"
  [[ "$dry06" != *"Restoring configs into"* ]] \
    && ok "the dry run never says it is restoring" || bad "the dry run announced a restore"
  # shellcheck disable=SC2088  # the literal "~/" the report prints, not a path to expand
  has "the dry run names the paths it would write, not just a count" "$dry06" "~/.config/appmany/f"
  # The cap: 20 paths, then a count of the rest, so a real \$HOME does not
  # scroll the terminal away.
  eq "the dry run lists at most 20 paths" \
    "$(grep -c '^      ~/' <<<"$dry06")" "20"
  has "and says how many it did not list" "$dry06" "and .* more"
  eq "the dry run still prints exactly one JSON object under --json" \
    "$(obj restore --configs | jq -s 'length')" "1"

  # --- --apply: overwrites the tracked file, leaves a .bak.<epoch> copy,
  # never deletes the file the snapshot never saw ---
  out=$(obj restore --configs --apply)
  eq "json: applied is true" "$(jq -r .applied <<<"$out")" "true"
  eq "the tracked file was restored" "$(cat "$FH/.config/mytool/mytool.conf")" "setting=1"
  bak=$(find "$FH/.config/mytool" -maxdepth 1 -name 'mytool.conf.bak.*' -print -quit 2>/dev/null)
  [ -n "$bak" ] && ok "the overwritten file left a .bak.<epoch> safety copy" \
    || bad "no .bak.<epoch> safety copy was left"
  [ -n "$bak" ] && eq "the safety copy holds the pre-restore content" "$(cat "$bak" 2>/dev/null)" "LOCAL EDIT"
  [ -f "$FH/.config/mytool/not-in-snapshot.conf" ] \
    && ok "a file absent from the snapshot is not deleted" || bad "restore deleted an untracked file"
  # shellcheck disable=SC2088  # literal "~/" prefix inside a jq filter/expected value, not a path to expand
  eq "json names the restored file in wrote[]" \
    "$(jq -r '.wrote[] | select(. == "~/.config/mytool/mytool.conf")' <<<"$out")" "~/.config/mytool/mytool.conf"
  # shellcheck disable=SC2088  # literal "~/" prefix inside a jq filter/expected value, not a path to expand
  eq "json names the backed-up file in backed_up[]" \
    "$(jq -r '.backed_up[] | select(. == "~/.config/mytool/mytool.conf")' <<<"$out")" "~/.config/mytool/mytool.conf"

  # The .bak.<epoch> copies are the only way back from an --apply, and the
  # human output never mentioned them at all: they were emitted under --json
  # alone, so a user who did not ask for JSON read "completed with no
  # failures" and never learned the copies existed.
  printf 'LOCAL EDIT AGAIN\n' > "$FH/.config/mytool/mytool.conf"
  apply06=$(ob restore --configs --apply)
  has "--apply says how many copies it made aside, and where" "$apply06" "file(s) copied aside as <path>.bak."
  has "and how to be rid of them" "$apply06" "delete them once you are happy"

  # --- permissions and a trailing-space filename survive a restore into a
  # FRESH $HOME. Git checks every directory out as 755 and every file gets
  # whatever the checkout's umask is -- only the modes.txt replay fixes this,
  # so the repo's checked-out copy is corrupted the same way first, or a mode
  # that was simply never wrong would prove nothing. ---
  chmod 755 "$FR/home/.config/appb"
  RH="$T/restored"; mkdir -p "$RH"
  check "restore into a fresh \$HOME" env HOME="$RH" "$CLI" restore --configs --apply
  [ "$(stat -c %a "$RH/.config/appb/settings.json" 2>/dev/null)" = "600" ] \
    && ok "restored file is 600, not 644" || bad "restored file lost its mode"
  [ "$(stat -c %a "$RH/.config/appb" 2>/dev/null)" = "700" ] \
    && ok "restored directory is 700, not 755 (~/.ssh would be world-listable)" || bad "restored directory lost its mode"
  [ "$(stat -c %a "$RH/.config/mytool/trailing .conf " 2>/dev/null)" = "600" ] \
    && ok "trailing-space filename keeps its mode" || bad "trailing-space filename lost its mode"
  [ -z "$(find "$RH" -name .gitkeep -print -quit 2>/dev/null)" ] \
    && ok "no .gitkeep placeholders restored into \$HOME" || bad ".gitkeep litter restored into \$HOME"
  # verify's own restore-and-compare must agree the modes round-tripped too.
  check "verify passes against a freshly restored \$HOME (permissions round-trip)" env HOME="$RH" "$CLI" verify
  eq "verify json: no mismatches after a clean restore" \
    "$(env HOME="$RH" "$CLI" verify --json 2>/dev/null | jq '.mismatched|length')" "0"
  chmod 700 "$FR/home/.config/appb"

  # --- /etc is diff-only: never writes, even under --apply ---
  ETCROOT="$T/etc-live"; mkdir -p "$ETCROOT"
  mkdir -p "$FR/etc/ssh"; printf 'PermitRootLogin no\n' > "$FR/etc/ssh/sshd_config"
  before_etc=$(find "$ETCROOT" -type f 2>/dev/null | sort | md5sum)
  etc_out=$(env HOME="$FH" OMABACKUP_ETC_ROOT="$ETCROOT" "$CLI" restore --etc --apply 2>&1)
  after_etc=$(find "$ETCROOT" -type f 2>/dev/null | sort | md5sum)
  eq "--etc never writes under the \$FH-mapped etc root, even with --apply" "$after_etc" "$before_etc"
  has "the comparison reports the missing file" "$etc_out" "MISSING"
  has "the comparison names the file" "$etc_out" "/etc/ssh/sshd_config"

  # --- a symlink whose target moved since the snapshot. The safety-copy loop
  # only enumerated -type f, so rsync -a replaced a live link with the
  # snapshot's with nothing copied aside and no mention in the dry run. ---
  mkdir -p "$FH/.config/linky"
  printf 'A\n' > "$FH/.config/linky/a.conf"; printf 'B\n' > "$FH/.config/linky/b.conf"
  ln -s a.conf "$FH/.config/linky/current.conf"
  allow '.config/linky'
  check "snapshot stores the symlink" env HOME="$FH" "$CLI" snapshot --no-push
  eq "the repo holds the link itself, not a copy of its target" \
    "$(readlink "$FR/home/.config/linky/current.conf")" "a.conf"
  ln -sfn b.conf "$FH/.config/linky/current.conf"
  # shellcheck disable=SC2088  # literal "~/" prefix inside a jq filter/expected value, not a path to expand
  eq "a dry run lists the repointed link under would_write" \
    "$(obj restore --configs | jq -r '.would_write[] | select(. == "~/.config/linky/current.conf")')" \
    "~/.config/linky/current.conf"
  lout=$(obj restore --configs --apply)
  eq "the link is restored to its snapshot target" "$(readlink "$FH/.config/linky/current.conf")" "a.conf"
  lbak=$(find "$FH/.config/linky" -maxdepth 1 -name 'current.conf.bak.*' -print -quit 2>/dev/null)
  [ -n "$lbak" ] && ok "the repointed link left a .bak.<epoch> safety copy" \
    || bad "no safety copy for a repointed symlink"
  [ -L "$lbak" ] && ok "the safety copy is a link, not a dereferenced copy" \
    || bad "the safety copy dereferenced the link"
  eq "the safety copy still points where the live link did" "$(readlink "$lbak" 2>/dev/null)" "b.conf"
  # shellcheck disable=SC2088  # literal "~/" prefix inside a jq filter/expected value, not a path to expand
  eq "json names the link in backed_up[]" \
    "$(jq -r '.backed_up[] | select(. == "~/.config/linky/current.conf")' <<<"$lout")" \
    "~/.config/linky/current.conf"
  # An unchanged link must not collect a .bak on every run.
  lout2=$(obj restore --configs --apply)
  eq "an unchanged link is not backed up again" \
    "$(jq -r '[.backed_up[] | select(. == "~/.config/linky/current.conf")] | length' <<<"$lout2")" "0"
fi
if group 17 "restore refuses a hollow snapshot"; then
  mk_fixture g17; seed_home; commit_baseline
  out=$(env HOME="$FH" OMABACKUP_MIN_RESTORE=9999 "$CLI" restore --configs --apply 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "a hollow snapshot is refused" || bad "restore accepted a hollow snapshot"
  has "the floor message is explicit" "$out" "refusing to restore"
  eq "json failures is nonzero" \
    "$(OMABACKUP_MIN_RESTORE=9999 obj restore --configs --apply | jq -r '.failures > 0')" "true"
fi
if group 07 "drift detection"; then
  mk_fixture g07; seed_home
  out=$(ob drift)
  has "unbacked user file is NEW" "$out" "NEW        ~/.config/mytool"
  has "changed stock file that is allowlisted is not reported" "$out" "drift-scan-complete"
  ! grep -q 'bindings.lua' <<<"$out" && ok "allowlisted file not reported" || bad "allowlisted file reported"
  eq "json items carry type and path" "$(obj drift | jq -r '.items[] | select(.path=="~/.config/mytool") | .type')" "NEW"
fi
if group 08 "unpushed-commit detection"; then
  # Regression: with no upstream configured this check silently did nothing.
  mk_fixture g08; seed_home; commit_baseline
  git -C "$FR" push -q -u origin HEAD:main 2>/dev/null
  git -C "$FR" commit -q --allow-empty -m "unpushed"
  has "unpushed commit is reported" "$(ob health)" "never pushed"
  git -C "$FR" push -q origin HEAD:main 2>/dev/null
  eq "clears after push" "$(grep -c 'never pushed' <<<"$(ob health)")" "0"
  # fail-closed: a missing upstream must be reported, not silently skipped
  git -C "$FR" branch --unset-upstream 2>/dev/null
  has "missing upstream is reported (fails closed)" "$(ob health)" "no upstream"
  git -C "$FR" branch --set-upstream-to=origin/main main 2>/dev/null
fi
if group 09 "staleness"; then
  mk_fixture g09; seed_home; commit_baseline
  printf '%s\n' "$(( $(date +%s) - 5*86400 ))" > "$FR/manifests/.last-run"
  has "stale snapshot is reported" "$(ob health)" "days ago"
fi
if group 10 "offline visibility probe (curl prints 000 AND exits non-zero) does not abort the backup"; then
  # curl -w PRINTS 000 on a connection failure *and* exits non-zero; a naive
  # `code=$(curl ... ) || code=000` concatenates the two into "000000" and
  # falls through to the die branch -- every offline run would abort.
  mk_fixture g10; seed_home
  git -C "$FR" remote set-url origin git@github.com:someone/omabackup-data.git
  fake_curl 000 7
  check "snapshot commits despite curl failing offline" env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_NET=1 "$CLI" snapshot
  git -C "$FR" log --oneline | grep -q 'snapshot:' && ok "commit landed locally" || bad "no local commit made"
fi
if group 11 "drift scan completion sentinel"; then
  mk_fixture g11; seed_home
  has "report ends with the sentinel" "$(ob drift | tail -1)" "# drift-scan-complete"
  eq "json complete=true" "$(obj drift | jq -r .complete)" "true"
fi
if group 12 "mid-merge repo is refused"; then
  mk_fixture g12; seed_home
  touch "$FR/.git/MERGE_HEAD"
  fails "snapshot refuses mid-merge" env HOME="$FH" "$CLI" snapshot --no-push
  has "reason names the merge" "$(ob snapshot --no-push; true)" "mid-merge"
  rm "$FR/.git/MERGE_HEAD"
fi
if group 13 "filename that looks like a credential"; then
  mk_fixture g13; seed_home; allow '.config/mytool'; commit_baseline
  ghp13="$FH/.config/mytool/ghp_$(rand_body 20).txt"
  printf 'x\n' > "$ghp13"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -ne 0 ]] && ok "snapshot refuses a ghp_ filename" || bad "a credential-looking filename was staged"
  has "the refusal names the filename gate" "$out" "credential-looking filename"
  rm -f "$ghp13"

  # The name class must cover the same set share/data.gitignore does: `id_*`
  # minus `id_*.pub`. A rotated or archived private key keeps a suffix
  # (id_rsa.old, id_rsa_backup, id_ecdsa-sk), and the old `^id_[a-z0-9]+$`
  # matched none of them.
  printf 'PRIVATE KEY BODY\n' > "$FH/.config/mytool/id_rsa.old"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -ne 0 ]] && ok "snapshot refuses id_rsa.old" || bad "id_rsa.old passed the filename gate"
  has "the id_rsa.old refusal names the filename gate" "$out" "credential-looking filename"
  rm -f "$FH/.config/mytool/id_rsa.old"

  # ...and the public half is the one documented exemption.
  printf 'ssh-ed25519 AAAA comment\n' > "$FH/.config/mytool/id_ed25519.pub"
  check "a public key is not treated as a credential" env HOME="$FH" "$CLI" snapshot --no-push

  # The exemption has to cover the same names the widened id_ class refuses.
  # It did not: `id_*` matches anything after the prefix, while the exemption
  # spelled its stem `[A-Za-z0-9._-]+`, so the copy a file manager makes of a
  # public key was refused over a name share/data.gitignore's own `!id_*.pub`
  # keeps. Innocuous body, so only the filename can explain the answer.
  printf 'ssh-ed25519 AAAA comment\n' > "$FH/.config/mytool/id_ed25519 (copy).pub"
  check "a public key whose name a file manager copied is still exempt" \
    env HOME="$FH" "$CLI" snapshot --no-push
  # ...and the private half of that same name is still refused, so the wider
  # stem widened the exemption and nothing else.
  printf 'nothing secret in here\n' > "$FH/.config/mytool/id_ed25519 (copy)"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -ne 0 ]] && ok "the private key beside it is still refused" \
    || bad "the wider .pub stem let a private key name through"
  has "and that refusal names the filename gate" "$out" "credential-looking filename"
  rm -f "$FH/.config/mytool/id_ed25519 (copy)"

  # That exemption belongs to the id_ class ALONE. A .pub suffix on any other
  # credential name is not a public key, it is a credential with a suffix.
  # Contents are deliberately innocuous in both: only the FILENAME may
  # explain the refusal, or the content scan would answer for the gate under
  # test and the assertion would pass with the exemption wide open.
  printf 'nothing secret in here\n' > "$FH/.config/mytool/ghp_token.pub"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -ne 0 ]] && ok "snapshot refuses ghp_token.pub" || bad "a .pub suffix let a ghp_ filename through"
  has "the ghp_token.pub refusal names the filename gate" "$out" "credential-looking filename"
  rm -f "$FH/.config/mytool/ghp_token.pub"
  printf 'nothing secret in here\n' > "$FH/.config/mytool/AKIAABCDEFGHIJKLMNOP.pub"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -ne 0 ]] && ok "snapshot refuses an AWS key id with a .pub suffix" || bad "a .pub suffix let an AKIA filename through"
  has "the AKIA .pub refusal names the filename gate" "$out" "credential-looking filename"
  rm -f "$FH/.config/mytool/AKIAABCDEFGHIJKLMNOP.pub"

  # A BASENAME MAY CONTAIN A NEWLINE, and the gate read find's output a line at
  # a time: `id_<LF>rsa` arrived as `id_` and `rsa`, neither of which matches
  # anything, so the private key the gate exists to stop walked through it. The
  # body is innocuous on purpose: only the FILENAME may explain the refusal, or
  # the content scan would be answering for the gate under test.
  nl13=$'id_\nrsa'
  printf 'nothing secret in here\n' > "$FH/.config/mytool/$nl13"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -ne 0 ]] && ok "snapshot refuses a key name with a newline inside it" \
    || bad "a newline in the basename walked through the filename gate"
  has "the newline-name refusal names the filename gate" "$out" "credential-looking filename"
  rm -f "$FH/.config/mytool/$nl13"

  # Both original cases still hold with the narrowed exemption in place.
  check "id_ed25519.pub is still allowed" env HOME="$FH" "$CLI" snapshot --no-push
  printf 'PRIVATE KEY BODY\n' > "$FH/.config/mytool/id_rsa.old"
  fails "id_rsa.old is still refused" env HOME="$FH" "$CLI" snapshot --no-push
  rm -f "$FH/.config/mytool/id_rsa.old"
fi
if group 14 "allowlist entry that became a symlink"; then
  mk_fixture g14; seed_home; allow '.config/mytool'
  # rsync -a stores the link, not the tree behind it: the whole subtree leaves
  # the backup while the drift scan still calls it covered.
  mv "$FH/.config/mytool" "$FH/mytool-real"; ln -s "$FH/mytool-real" "$FH/.config/mytool"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -ne 0 ]] && ok "symlinked allowlist entry is refused" || bad "symlinked entry silently emptied the backup"
  has "the refusal names the symlink" "$out" "symlink to a directory"
fi
if group 15 "a dry run must not touch the working tree"; then
  mk_fixture g15; seed_home; allow '.config/mytool'; commit_baseline
  printf 'dryrun\n' > "$FH/.config/mytool/dry.conf"
  before_tree=$(git -C "$FR" status --porcelain | md5sum)
  check "dry run exits 0" env HOME="$FH" "$CLI" snapshot --dry-run
  eq "the dry run left the repo untouched" "$(git -C "$FR" status --porcelain | md5sum)" "$before_tree"
  eq "json reports the dry state and no commit" \
    "$(obj snapshot --dry-run | jq -r '"\(.state) \(.committed)"')" "dry false"
fi
if group 16 "modes survive a filename with a trailing space"; then
  # `read -r mode path` silently truncated these; modes.txt is NUL-delimited
  # for exactly this reason. The restore half lands with the restore verb.
  mk_fixture g16; seed_home; allow '.config/mytool'
  printf 'x\n' > "$FH/.config/mytool/trailing .conf "
  chmod 600 "$FH/.config/mytool/trailing .conf "
  check "snapshot runs" env HOME="$FH" "$CLI" snapshot --no-push
  modes_has '600 home/.config/mytool/trailing .conf ' \
    && ok "trailing-space filename keeps its recorded mode" || bad "trailing-space filename lost its mode"
fi
if group 18 "type-conflict guard does not fire spuriously"; then
  # `while IFS= read -r ty rel` (no field split) made every entry look like a
  # conflict and ran `cp -a "$HOME/" ...` once per file -- a recursive copy of
  # $HOME into itself. Restoring into an EMPTY $HOME must produce zero
  # conflicts and zero runaway backup artifacts.
  mk_fixture g18; seed_home; commit_baseline
  RH="$T/restored"; rm -rf "$RH"; mkdir -p "$RH"
  out=$(env HOME="$RH" "$CLI" restore --configs --apply 2>&1)
  n_tc=$(grep -c 'type conflict' <<<"$out" || true)
  [ "${n_tc:-0}" -eq 0 ] && ok "no spurious type conflicts on a clean restore" \
    || bad "$n_tc spurious type-conflict warning(s) (field-splitting bug)"
  [ -z "$(find "$RH" -name '*.bak.*' -print -quit 2>/dev/null)" ] \
    && ok "no runaway .bak artifacts on a clean restore" || bad "runaway backup artifacts were created"
fi
if group 19 "a REAL type conflict is detected and backed up"; then
  mk_fixture g19; seed_home; allow '.config/mytool'; commit_baseline
  RH="$T/restored"; rm -rf "$RH"; mkdir -p "$RH/.config"
  printf 'i am a file\n' > "$RH/.config/mytool"   # snapshot has mytool as a DIRECTORY
  out=$(env HOME="$RH" "$CLI" restore --configs --apply 2>&1)
  has "file-vs-directory conflict is reported" "$out" "type conflict at ~/.config/mytool"
  [ -n "$(find "$RH/.config" -maxdepth 1 -name 'mytool.bak.*' -print -quit 2>/dev/null)" ] \
    && ok "the conflicting file was backed up" || bad "the conflicting file was NOT backed up"
  [ -d "$RH/.config/mytool" ] && ok "the directory now exists in its place" || bad "the directory was not restored"
fi
if group 20 "truncated package manifest actually skips"; then
  mk_fixture g20; seed_home; commit_baseline
  printf 'bash\ncoreutils\n' > "$FR/manifests/pacman-native.txt"
  out=$(ob restore --packages)
  has "a truncated manifest is refused" "$out" "looks truncated"
  ! grep -qE 'pacman -S|Installing missing' <<<"$out" \
    && ok "did not fall through to install" || bad "fell through and tried to install anyway"
  eq "json marks it skipped, with the reason" "$(obj restore --packages | jq -r '.skipped[0].reason')" \
    "looks truncated (2 entries, floor 100)"
fi
# Group 38 (self-test.sh:497-503, staleness against a garbage/future
# manifests/.last-run stamp) lands with the health verb -- see below.
if group 21 "list hygiene"; then
  mk_fixture g21; seed_home; commit_baseline
  check "clean lists lint clean" env HOME="$FH" "$CLI" lint
  printf '*   # 2026-09-03 too wide\n' >> "$FR/drift-ignore.txt"
  fails "a bare * ignore is TOOWIDE" env HOME="$FH" "$CLI" lint
  eq "json names the code" "$(obj lint | jq -r '.findings[0].code')" "TOOWIDE"
  sed -i '$d' "$FR/drift-ignore.txt"
  printf '.config/nonexistent-dir\n' >> "$FR/allowlist.txt"
  has "a required entry that resolves to nothing is MISSING" "$(ob lint; true)" "MISSING"
  sed -i '$d' "$FR/allowlist.txt"
  # An allowlist entry is copied in BOTH directions, so a parent-traversal
  # segment or an absolute path is a hard failure, not a note.
  printf '.config/../../etc\n' >> "$FR/allowlist.txt"
  eq "a '..' segment is TRAVERSAL" "$(obj lint | jq -r '[.findings[].code] | index("TRAVERSAL") != null')" "true"
  sed -i '$d' "$FR/allowlist.txt"
  printf '/etc/passwd\n' >> "$FR/allowlist.txt"
  eq "an absolute entry is ABSOLUTE" "$(obj lint | jq -r '[.findings[].code] | index("ABSOLUTE") != null')" "true"
  sed -i '$d' "$FR/allowlist.txt"
  echo new > "$FH/.local/bin/late"; printf '.local/bin\n' >> "$FR/allowlist.txt"
  check "a file newer than the last run is pending, not NOTBACKEDUP" env HOME="$FH" "$CLI" lint
  check "--no-walk skips the completeness walk" env HOME="$FH" "$CLI" lint --no-walk

  # The completeness walk read find's output a line at a time, so a newline in
  # a filename arrived as two fragment paths: neither exists under home/, so a
  # file that was backed up in full produced two NOTBACKEDUP rows and a red
  # lint that no amount of backing it up could clear.
  mk_fixture g21n; seed_home; allow '.config/mytool'
  nl21=$'bad\nname.conf'
  printf 'setting=1\n' > "$FH/.config/mytool/$nl21"
  check "the snapshot backs up a file whose name holds a newline" env HOME="$FH" "$CLI" snapshot --no-push
  [[ -e "$FR/home/.config/mytool/$nl21" ]] && ok "the file really is in the backup" \
    || bad "the newline-named file was not backed up"
  eq "and the completeness walk reports no NOTBACKEDUP fragments for it" \
    "$(obj lint | jq -r '[.findings[] | select(.code == "NOTBACKEDUP")] | length')" "0"
  check "so lint is clean" env HOME="$FH" "$CLI" lint
fi
if [[ "${OMABACKUP_REAL_REPO:-0}" == 1 ]] && group 21R "list hygiene against the REAL data repo"; then
  unset OMABACKUP_CONFIG OMABACKUP_STATE_DIR OMABACKUP_STOCK_DIR OMABACKUP_SKIP_ETC
  check "real lists lint clean" "$CLI" lint
fi
if group 22 "partial coverage is DERIVED, not declared"; then
  mk_fixture g22; seed_home
  mkdir -p "$FH/.config/partial/keep" "$FH/.config/partial/drop"
  echo a > "$FH/.config/partial/keep/a.conf"; echo b > "$FH/.config/partial/drop/b.log"
  printf '.config/partial/keep\n' >> "$FR/allowlist.txt"; git -C "$FR" commit -qam allow
  out=$(ob drift)
  has "the uncovered sibling is reported" "$out" "NEW        ~/.config/partial/drop"
  # shellcheck disable=SC2088 # matching drift's literal "~/" report prefix, not a path to expand
  ! grep -q '~/.config/partial$' <<<"$out" && ok "the parent is not reported as a whole" || bad "parent reported wholesale"
fi
if group 23 "runs correctly from any working directory"; then
  # The timer unit runs with WorkingDirectory=$HOME. A git call placed before
  # the cd into the data repo queried the CALLER's directory, exited 128, and
  # errexit killed the run with zero output: the daily timer was silently dead.
  mk_fixture g23; seed_home
  out=$(cd "$T" && env HOME="$FH" "$CLI" snapshot --dry-run 2>&1); rc=$?
  [[ $rc -eq 0 ]] && ok "runs from an unrelated CWD" || bad "fails when CWD is not the repo (timer path)" "$out"
fi
if group 24 "a vanishing file does not abort the run"; then
  # rsync exit 24 is a WARNING. Allowlisted paths include files editors and
  # Omarchy rewrite constantly, so this race is routine.
  mk_fixture g24; seed_home; allow '.config/mytool'
  mkdir -p "$FH/.config/mytool/many"
  for i in $(seq 1 300); do printf 'x\n' > "$FH/.config/mytool/many/f$i"; done
  ( sleep 0.05; rm -f "$FH/.config/mytool/many/f2"* ) &
  ob snapshot --no-push >/dev/null 2>&1; rc24=$?
  wait 2>/dev/null
  [[ $rc24 -eq 0 ]] && ok "tolerates files vanishing mid-copy" || bad "aborted on rsync exit 24 (rc=$rc24)"
fi
if group 25 "an unverifiable repo visibility (403) does not abort the backup"; then
  # Only HTTP 200 proves a repo is public. 403 (unauthenticated rate limit),
  # 429 and 5xx prove nothing and must not hard-fail the whole snapshot.
  mk_fixture g25; seed_home
  git -C "$FR" remote set-url origin git@github.com:someone/omabackup-data.git
  fake_curl 403
  check "snapshot commits despite an unverifiable 403" env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_NET=1 "$CLI" snapshot
  git -C "$FR" log --oneline | grep -q 'snapshot:' && ok "commit landed locally" || bad "no local commit made"
fi
if group 26 "a .gitignore-excluded file warns instead of halting"; then
  # An app dropping a *.sqlite into an allowlisted directory is a reporting
  # gap, not data loss: it must not stop every future backup.
  mk_fixture g26; seed_home; allow '.config/mytool'
  printf 'x\n' > "$FH/.config/mytool/cache.sqlite"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -eq 0 ]] && ok "a gitignore exclusion warns, it does not die" || bad "died on a gitignore exclusion (rc=$rc)"
  has "the exclusion is reported" "$out" "excluded by .gitignore"
  eq "json counts the exclusion" "$(obj snapshot --no-push | jq -r .excluded)" "1"
fi
if group 27 "unverified visibility must NOT push"; then
  mk_fixture g27; seed_home
  git -C "$FR" remote set-url origin "$BARE"; jq '.remote.trusted=false' "$OMABACKUP_CONFIG" > "$T/c2" && mv "$T/c2" "$OMABACKUP_CONFIG"
  check "snapshot commits" env HOME="$FH" "$CLI" snapshot
  eq "nothing reached the remote" "$(git -C "$BARE" rev-list --count main 2>/dev/null || echo 0)" "0"
  eq "status says push not verifiable" "$(obj status | jq -r .push_verifiable)" "false"
  jq '.remote.trusted=true' "$OMABACKUP_CONFIG" > "$T/c2" && mv "$T/c2" "$OMABACKUP_CONFIG"
  check "trusted remote pushes" env HOME="$FH" "$CLI" snapshot
  [[ $(git -C "$BARE" rev-list --count main) -ge 1 ]] && ok "pushed once trusted" || bad "not pushed"
fi
if group 28 "empty directories survive the backup"; then
  mk_fixture g28; seed_home; allow '.config/mytool'
  mkdir -p "$FH/.config/mytool/emptydir"
  check "snapshot runs" env HOME="$FH" "$CLI" snapshot --no-push
  [[ -e "$FR/home/.config/mytool/emptydir/.gitkeep" ]] \
    && ok "empty dir marked with .gitkeep" || bad "empty dir lost (git cannot store one)"
  git -C "$FR" ls-files home/ | grep -q gitkeep && ok ".gitkeep is tracked" || bad ".gitkeep not tracked"
fi
if group 29 "JSONC settings do not block the backup"; then
  # VS Code's settings.json is officially JSONC. Rejecting comments and
  # trailing commas stopped every backup until a human edited the file.
  mk_fixture g29; seed_home
  mkdir -p "$FH/.config/appjsonc"
  printf '{\n  // a comment\n  "theme": "x",\n}\n' > "$FH/.config/appjsonc/settings.json"
  printf '.config/appjsonc/settings.json\n' >> "$FR/allowlist.txt"
  printf 'home/.config/appjsonc/settings.json\ts/"theme": *"[^"]*"/"theme":"n"/g\n' > "$FR/normalize.txt"
  git -C "$FR" commit -qam "allow and normalize"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -eq 0 ]] && ok "pre-existing JSONC is tolerated" || bad "JSONC blocked the backup (rc=$rc)"
  # ...and prove the rule actually ran, or the assertion above is vacuous.
  grep -q '"theme":"n"' "$FR/home/.config/appjsonc/settings.json" 2>/dev/null \
    && ok "the normalize rule actually applied" || bad "normalize rule never ran; the check above was vacuous"
fi
if group 30 "a symlinked directory inside the backup is refused"; then
  # RELATIVE link, target OUTSIDE the allowlisted tree: the case that loses
  # data. The guard used to run over the STAGING copy, where this link dangles
  # because its target was never copied, so -xtype d was false and it passed.
  mk_fixture g30; seed_home; allow '.config/mytool'
  mkdir -p "$FH/.local/share/outside"; printf 'important\n' > "$FH/.local/share/outside/important.conf"
  ln -s ../../.local/share/outside "$FH/.config/mytool/sub"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -ne 0 ]] && ok "relative symlinked subdirectory is refused" \
    || bad "relative symlinked subdir silently dropped its contents (rc=$rc)"
  has "the refusal names the symlinked directory" "$out" "symlinked directory inside the backup"
fi
if group 31 "restore fidelity"; then
  mk_fixture g31; seed_home; commit_baseline
  check "verify passes on a fresh snapshot" env HOME="$FH" "$CLI" verify
  eq "json mismatched is empty" "$(obj verify | jq '.mismatched|length')" "0"
  # A file changed since the last run legitimately differs from the backup --
  # a fast test (and a slow real one) both rewrite configs after the run
  # finishes. "Since" is the last-run stamp's CONTENT (the start-of-run
  # epoch the engine writes there, same as lib/lint.sh and lib/health.sh
  # read), so the backdating writes content, not just mtime; the mtime is
  # kept in step too since a real snapshot always agrees.
  printf 'changed\n' > "$FH/.bashrc"
  date -d '1 hour ago' +%s > "$FR/manifests/.last-run"
  touch -d '1 hour ago' "$FR/manifests/.last-run"
  git -C "$FR" commit -qam x 2>/dev/null || true
  eq "a file changed since the last run is skipped, not failed" "$(obj verify | jq -r .ok)" "true"
  # Now the mismatch predates the last-run stamp: it must be reported, not
  # silently swallowed by the same exception.
  touch -d '1 hour ago' "$FH/.bashrc"
  date +%s > "$FR/manifests/.last-run"
  touch "$FR/manifests/.last-run"
  fails "a mismatch older than the last run fails verify" env HOME="$FH" "$CLI" verify
  # Regression: the pipeline writes manifests/.last-run's CONTENT at the
  # START of the run but its MTIME lands later, near the run's end (whatever
  # else the pipeline does after that write). A file edited in that window
  # (after the content epoch, before the mtime) must still be excused by the
  # content-based cutoff -- an mtime-based cutoff wrongly flags it, because
  # the mtime is a later, stricter boundary than the run actually started at.
  since_t=$(date +%s)
  printf '%s\n' "$since_t" > "$FR/manifests/.last-run"
  touch -d "@$((since_t + 3))" "$FR/manifests/.last-run"
  touch -d "@$((since_t + 1))" "$FH/.bashrc"
  eq "a file edited after the content epoch but before the later mtime is excused" \
    "$(obj verify | jq -c '[.ok,.skipped_changed]')" '[true,1]'

  # Symlinks were never compared at all: the enumeration was `-type f`, so a
  # live link repointed after the snapshot read as verified.
  pre31=$(obj verify | jq -r .compared)
  mkdir -p "$FH/.config/linky"
  printf 'A\n' > "$FH/.config/linky/a.conf"; printf 'B\n' > "$FH/.config/linky/b.conf"
  ln -s a.conf "$FH/.config/linky/current.conf"
  allow '.config/linky'
  check "snapshot stores the link" env HOME="$FH" "$CLI" snapshot --no-push
  l31=$(obj verify)
  eq "a matching link still verifies" "$(jq -r .ok <<<"$l31")" "true"
  eq "the link itself counts in compared" "$(( $(jq -r .compared <<<"$l31") - pre31 ))" "3"
  # Repoint it and backdate the link. `touch -h` times the link, not its
  # target, so the changed-since exception cannot excuse the difference.
  ln -sfn b.conf "$FH/.config/linky/current.conf"
  touch -h -d '1 hour ago' "$FH/.config/linky/current.conf"
  m31=$(obj verify)
  eq "a repointed link is a fidelity mismatch" "$(jq -r .ok <<<"$m31")" "false"
  # shellcheck disable=SC2088  # literal "~/" prefix inside a jq filter/expected value, not a path to expand
  eq "the mismatch names the link" \
    "$(jq -r '.mismatched[] | select(. == "~/.config/linky/current.conf")' <<<"$m31")" \
    "~/.config/linky/current.conf"
  # ...and one repointed since the last run is excused like any other changed
  # file, rather than reported as a fidelity bug.
  touch -h "$FH/.config/linky/current.conf"
  eq "a link repointed since the last run is skipped as changed" \
    "$(obj verify | jq -c '[.ok,.skipped_changed]')" '[true,1]'
fi
if [[ "${OMABACKUP_REAL_REPO:-0}" == 1 ]] && group 31R "restore fidelity against the REAL backup"; then
  unset OMABACKUP_CONFIG OMABACKUP_STATE_DIR OMABACKUP_STOCK_DIR OMABACKUP_SKIP_ETC
  check "real backup verifies" "$CLI" verify
fi
if group 32 "a .gitignore-excluded file is committed into the drift report"; then
  # The EXCLUDED lines were appended AFTER `git add`, so they were never
  # committed and left the tree permanently dirty: the feature was inert.
  # The health half of self-test.sh:441 lands with the health verb.
  mk_fixture g32; seed_home; allow '.config/mytool'
  printf 'x\n' > "$FH/.config/mytool/cache.sqlite"
  check "snapshot runs" env HOME="$FH" "$CLI" snapshot --no-push
  git -C "$FR" show HEAD:manifests/drift.txt 2>/dev/null | grep -q EXCLUDED \
    && ok "the EXCLUDED line is committed" || bad "EXCLUDED line never committed (inert feature)"
  eq "working tree left clean" "$(git -C "$FR" status --porcelain)" ""
fi
if group 33 "drift reports each path exactly once"; then
  mk_fixture g33; seed_home
  # Container recursion means section 1, 2b and 2c can all reach the same file.
  mkdir -p "$FH/.config/dedup"; printf 'x\n' > "$FH/.config/dedup/probe.conf"
  d=$(ob drift)
  n=$(grep -c 'dedup/probe.conf' <<<"$d" || true)
  [[ "${n:-0}" -eq 1 ]] && ok "reported once, not $n times" || bad "reported $n times (double-counting)"
fi
if group 34 "a script in a ~/.local/bin SUBDIRECTORY is not invisible"; then
  mk_fixture g34; seed_home
  # .local/bin is pruned from the generic walkers, so section 4 must recurse.
  mkdir -p "$FH/.local/bin/tools"
  printf '#!/bin/bash\n%s\n' "$(head -c 400 /dev/zero | tr '\0' 'x')" > "$FH/.local/bin/tools/deep.sh"
  d=$(ob drift)
  grep -q 'tools/deep.sh' <<<"$d" && ok "nested script surfaces" || bad "nested script invisible to every scanner"
fi
if group 35 "a removed app does not halt backups, but mass disappearance does"; then
  # Real event: an uninstalled app's stale allowlist entry blocked every backup
  # while unrelated changes went uncaptured. One missing entry must be soft;
  # many missing means something structural (wrong HOME, unmounted disk).
  mk_fixture g35; seed_home; commit_baseline
  jq '.maxMissingPct=90' "$OMABACKUP_CONFIG" > "$T/c2" && mv "$T/c2" "$OMABACKUP_CONFIG"
  mv "$FH/.bashrc" "$T/bashrc.away"
  out=$(ob snapshot --no-push); rc1=$?
  [[ $rc1 -eq 0 ]] && ok "one absent entry does not halt the backup" || bad "halted on a single absent entry"
  grep -q '^GONE' "$FR/manifests/drift.txt" && ok "recorded as GONE" || bad "not recorded as GONE"
  mv "$T/bashrc.away" "$FH/.bashrc"
  jq '.maxMissingPct=25' "$OMABACKUP_CONFIG" > "$T/c2" && mv "$T/c2" "$OMABACKUP_CONFIG"
  mv "$FH/.config/hypr" "$T/hypr.away"; mv "$FH/.local/bin" "$T/bin.away"
  out=$(ob snapshot --no-push); rc2=$?
  [[ $rc2 -ne 0 ]] && ok "mass disappearance still refuses to run" || bad "committed with most entries missing"
  has "the refusal says the entries no longer exist" "$out" "no longer exist"
  mv "$T/hypr.away" "$FH/.config/hypr"; mv "$T/bin.away" "$FH/.local/bin"
fi
if group 36 "an oversized file is skipped and reported, not silently dropped"; then
  mk_fixture g36; seed_home; allow '.config/mytool'; commit_baseline
  head -c 12000000 /dev/urandom > "$FH/.config/mytool/huge.dat"
  gitsize_before=$(du -sk "$FR/.git" | cut -f1)
  check "snapshot runs" env HOME="$FH" "$CLI" snapshot --no-push
  [[ ! -e "$FR/home/.config/mytool/huge.dat" ]] \
    && ok "oversized file kept out of the backup" || bad "oversized file was committed"
  grep -q '^TOOBIG' "$FR/manifests/drift.txt" && ok "reported as TOOBIG" || bad "silently dropped"
  eq "json counts it" "$(obj snapshot --no-push | jq -r .toobig)" "1"
  gitsize_after=$(du -sk "$FR/.git" | cut -f1)
  [[ $((gitsize_after - gitsize_before)) -lt 2000 ]] \
    && ok ".git did not grow by the file size" || bad ".git grew $((gitsize_after - gitsize_before))KB"
fi
if group 37 "a stale .git/index.lock self-heals"; then
  mk_fixture g37; seed_home
  touch -d '10 minutes ago' "$FR/.git/index.lock"
  check "snapshot clears an abandoned lock and runs" env HOME="$FH" "$CLI" snapshot --no-push
  [[ ! -f "$FR/.git/index.lock" ]] && ok "stale lock removed" || bad "stale lock still present"
fi
if group 38 "a future/garbage last-run stamp does not blind the staleness check"; then
  mk_fixture g38; seed_home
  # Backdate the last SNAPSHOT well past staleDays, so a garbage stamp's
  # fallback (the last snapshot commit's time) still catches real staleness
  # instead of silently reading as healthy. It used to backdate an empty
  # commit, which the fallback now rightly ignores: only a commit that touched
  # the snapshot's own paths counts as a snapshot.
  old_ts=$(( $(date +%s) - 10*86400 ))
  check "a snapshot dated ten days ago" env HOME="$FH" GIT_COMMITTER_DATE="@$old_ts" GIT_AUTHOR_DATE="@$old_ts" "$CLI" snapshot --no-push
  printf 'not-a-number\n' > "$FR/manifests/.last-run"
  has "garbage stamp falls back to commit time and still reports staleness" "$(ob health)" "days ago"
  echo $(( $(date +%s) + 2592000 )) > "$FR/manifests/.last-run"
  has "future stamp is reported, not silently accepted" "$(ob health)" "FUTURE"
  date +%s > "$FR/manifests/.last-run"
fi
if group 39 "a LIVE .git/index.lock is never deleted"; then
  mk_fixture g39; seed_home
  touch -d '10 minutes ago' "$FR/.git/index.lock"
  ( exec 3<"$FR/.git/index.lock"; sleep 5 ) & holder=$!
  sleep 0.3
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -ne 0 ]] && ok "snapshot refuses while another process holds index.lock" || bad "ran with a live index.lock"
  has "the refusal names the live holder" "$out" "another git process is using"
  [[ -f "$FR/.git/index.lock" ]] && ok "live lock untouched" || bad "live lock deleted"
  kill $holder 2>/dev/null; wait $holder 2>/dev/null
fi
if group 40 "a missing stock tree does not disable ALL drift detection"; then
  mk_fixture g40; seed_home
  # An early exit once skipped sections 2, 2b, 2c, 3, 4 and 5, none of which
  # need the stock tree, so everything reported clean while drift was fully off.
  mkdir -p "$FH/.config/stockprobe"; printf 'x\n' > "$FH/.config/stockprobe/c.conf"
  d_without=$(OMABACKUP_STOCK_DIR=/nonexistent ob drift)
  n_without=$(grep -cE '^(NEW|MODIFIED)' <<<"$d_without" || true)
  [[ "${n_without:-0}" -gt 0 ]] && ok "still reports drift without the stock tree ($n_without items)" \
    || bad "reported 0 items without the stock tree; drift fully disabled"
  has "sentinel still emitted" "$d_without" "drift-scan-complete"
  has "the missing tree is reported" "$d_without" "ERROR: omarchy stock config tree not found"
fi
if group 41 "the secret gate does not blind itself"; then
  mk_fixture g41; seed_home; commit_baseline
  rm "$FR/.gitleaks.toml"
  if command -v gitleaks >/dev/null; then
    check "snapshot still passes rules from share/ when the repo copy is gone" env HOME="$FH" "$CLI" snapshot --no-push
    has "run mentions the rules path" "$(ob snapshot --no-push --dry-run)" "gitleaks.toml"
  fi
fi
if group 42 "a disabled drift scanner is surfaced, not silent"; then
  mk_fixture g42; seed_home
  # drift emits '# ERROR' and bumps found nothing else reads by itself, so a
  # missing stock tree must still be visible in the scan's own output (health,
  # arriving in a later task, then just has to surface what is already here).
  out=$(OMABACKUP_STOCK_DIR=/nonexistent ob drift)
  has "a disabled scanner is surfaced as # ERROR" "$out" "# ERROR"
  eq "json items carry it as type ERROR" \
    "$(OMABACKUP_STOCK_DIR=/nonexistent obj drift | jq -r '[.items[] | select(.type=="ERROR")] | length > 0')" "true"
  eq "json ERROR item carries the message, not the prefix" \
    "$(OMABACKUP_STOCK_DIR=/nonexistent obj drift | jq -r '.items[] | select(.type=="ERROR") | .path' | head -1 | grep -c '^# ERROR')" "0"
  [[ -n "$(OMABACKUP_STOCK_DIR=/nonexistent obj drift | jq -r '.items[] | select(.type=="ERROR") | .path' | head -1)" ]] \
    && ok "the ERROR item's message text is not empty" || bad "the ERROR item's message text is empty"
fi
if group 43 "every manifest is generated BEFORE its carry-forward guard"; then
  # stock-fingerprint.txt was generated AFTER the loop that protects manifests
  # from being blanked, so the loop tested a file that did not exist yet: a
  # permanent false alarm on the one guard that stops rsync --delete eating
  # real data.
  mk_fixture g43; real_manifests; seed_home; commit_baseline
  # Same reason as group 04: "no warning in the output" is trivially true of a
  # run that produced no output because the verb refused.
  _run=$(ob snapshot --no-push); rc=$?
  [[ $rc -eq 0 ]] && ok "snapshot runs" || bad "snapshot failed (rc=$rc)"
  grep -q 'could not be regenerated' <<<"$_run" \
    && bad "spurious carry-forward warning" "$(grep -o '[a-z-]*\.[a-z]* could not be regenerated' <<<"$_run" | head -1)" \
    || ok "a healthy run emits no carry-forward warning"
  [[ -s "$FR/manifests/stock-fingerprint.txt" ]] \
    && ok "stock-fingerprint.txt is non-empty after a normal run" || bad "stock-fingerprint.txt missing or empty"
fi
if group 44 "the snapshot commits only its own output, and the staged gate still scans"; then
  # A human edit to the lists or the README used to be swept into a
  # "snapshot:" commit by `git add -A`. The health half of self-test.sh:588
  # lands with the health verb.
  mk_fixture g44; seed_home; allow '.config/mytool'; commit_baseline
  printf 'scratch note\n' > "$FR/notes.txt"
  printf 'scoped\n' > "$FH/.config/mytool/scoped.conf"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -eq 0 ]] && ok "a dirty non-snapshot file does not block the run" || bad "run failed with a dirty repo root (rc=$rc)"
  git -C "$FR" show --name-only --format= HEAD | grep -qx 'notes.txt' \
    && bad "notes.txt was swept into the snapshot commit" || ok "notes.txt was NOT committed by the snapshot"
  has "the edit is reported in the run" "$out" "uncommitted edits outside the snapshot"

  # `git commit` commits the INDEX, not what the last `git add` named, so a
  # half-finished edit a human had already staged (or the staging a refused
  # push --confirm left behind) rode into the snapshot commit and was pushed
  # with it. Unstaging is what keeps the mutation rule true; the edit itself
  # must survive untouched in the working tree.
  printf '# staged by hand\n' >> "$FR/allowlist.txt"
  git -C "$FR" add allowlist.txt
  printf 'more\n' > "$FH/.config/mytool/more.conf"
  before44=$(git -C "$FR" rev-parse HEAD)
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -eq 0 ]] && ok "a pre-staged edit does not stop the run" || bad "the run failed with a staged edit (rc=$rc)"
  [[ "$(git -C "$FR" rev-parse HEAD)" != "$before44" ]] \
    && ok "the snapshot still commits its own output" || bad "the snapshot committed nothing"
  if git -C "$FR" show --name-only --format= HEAD | grep -qx 'allowlist.txt'; then
    bad "the pre-staged allowlist edit was committed by the snapshot"
  else
    ok "the pre-staged allowlist edit was NOT committed"
  fi
  has "the run says it unstaged the edit" "$out" "unstaging edits that were staged before this run"
  eq "the edit survives as an unstaged change" \
    "$(git -C "$FR" status --porcelain -- allowlist.txt)" " M allowlist.txt"
  git -C "$FR" checkout -q -- allowlist.txt

  # ...and the staged-commit gate is still the authoritative one. normalize
  # rules rewrite the staging tree AFTER the tree scan has run, so a rule can
  # inject a token into a file nothing has scanned since; only the scan over
  # exactly what is about to be committed sees it.
  if command -v gitleaks >/dev/null; then
    cp "$FR/normalize.txt" "$T/normalize.bak"
    printf 'home/.bashrc\ts/EDITOR=nvim/ghp_%s/\n' "$(rand_body 36)" >> "$FR/normalize.txt"
    git -C "$FR" commit -qam "normalize rule"
    printf 'gate\n' > "$FH/.config/mytool/gate.conf"
    before=$(git -C "$FR" rev-parse HEAD)
    out=$(ob snapshot --no-push); rc=$?
    [[ $rc -ne 0 ]] && ok "a secret injected after the tree scan blocks the commit" || bad "staged gate did NOT fire (rc=$rc)"
    has "the refusal names the staged commit" "$out" "staged commit"
    eq "no commit created" "$(git -C "$FR" rev-parse HEAD)" "$before"
    git -C "$FR" diff --cached --quiet && ok "the index was reset" || bad "index left staged after the abort"
    cp "$T/normalize.bak" "$FR/normalize.txt"
  else
    echo "  (gitleaks not installed: skipping the staged-commit gate)"
  fi
fi
if group 45 "a PUBLIC repo aborts the run (HTTP 200 is the only proof of public)"; then
  mk_fixture g45; seed_home
  git -C "$FR" remote set-url origin git@github.com:someone/omabackup-data.git
  fake_curl 200
  fails "snapshot dies on 200" env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_NET=1 "$CLI" snapshot
  has "reason says public" "$(PATH="$T/fakebin:$PATH" OMABACKUP_NET=1 ob snapshot; true)" "public"
fi
if group 46 "hand-authored /etc drop-ins are reported"; then
  # Real pacman prose, and before the `command -v pacman` below, which a stub
  # would answer wrongly.
  mk_fixture g46; real_manifests; seed_home
  if ! command -v pacman >/dev/null 2>&1; then
    echo "  (skipped: pacman not available on this machine)"
  else
    ETCROOT="$T/etc"; mkdir -p "$ETCROOT/modprobe.d" "$ETCROOT/sysctl.d"
    printf 'options hid_apple fnmode=2\n' > "$ETCROOT/modprobe.d/zz-fixture.conf"
    export OMABACKUP_SKIP_ETC=0 OMABACKUP_ETC_ROOT="$ETCROOT"
    d=$(ob drift)
    has "unowned drop-in is reported" "$d" "$(printf 'NEW        %s' '/etc/modprobe.d/zz-fixture.conf')"
    printf '/etc/modprobe.d/zz-fixture.conf\n' >> "$FR/etc-allowlist.txt"
    d=$(ob drift)
    ! grep -q 'zz-fixture' <<<"$d" && ok "allowlisted drop-in is quiet" || bad "still reported after being allowlisted"
    chmod 000 "$ETCROOT/sysctl.d"
    d=$(ob drift)
    has "an unreadable drop-in dir is reported as a scanner gap" "$d" "# ERROR: cannot read"
    chmod 755 "$ETCROOT/sysctl.d"
    export OMABACKUP_SKIP_ETC=1; unset OMABACKUP_ETC_ROOT
  fi
fi
if group 47 "a bare drift-ignore on a top-level dot-directory does not silence its subtree"; then
  mk_fixture g47; seed_home
  mkdir -p "$FH/.config/systemd/user"; printf '[Unit]\n' > "$FH/.config/systemd/user/mine.service"
  printf '.config/systemd   # 2026-09-03 test: bare entry\n' >> "$FR/drift-ignore.txt"
  has "unit inside a bare-ignored dir is still reported" "$(ob drift)" "mine.service"
  printf '.config/systemd/**   # 2026-09-03 test: subtree\n' >> "$FR/drift-ignore.txt"
  ! grep -q 'mine.service' <<<"$(ob drift)" && ok "subtree ignore silences it" || bad "subtree ignore ineffective"
fi
if group 48 "a huge unbacked tree is reported wholesale, never scanned per-file"; then
  mk_fixture g48; seed_home
  # Any directory over maxScanFiles must collapse into ONE actionable NEW line,
  # without silencing small siblings, and without reporting an allowlisted tree.
  jq '.maxScanFiles=50' "$OMABACKUP_CONFIG" > "$T/cfg.tmp" && mv "$T/cfg.tmp" "$OMABACKUP_CONFIG"
  mkdir -p "$FH/.local/share/blob/store" "$FH/.local/share/small" "$FH/.local/share/bigok/sub"
  for i in $(seq 1 60); do : > "$FH/.local/share/blob/store/f$i"; : > "$FH/.local/share/bigok/sub/f$i"; done
  printf 'x\n' > "$FH/.local/share/small/one.conf"
  printf '.local/share/bigok\n' >> "$FR/allowlist.txt"; git -C "$FR" commit -qam allow
  d=$(ob drift)
  # shellcheck disable=SC2088 # matching drift's literal "~/" report prefix, not a path to expand
  want=$(printf 'NEW        %s\t%s' '~/.local/share/blob/' '(>50 files: too large to scan; allowlist it, or add a dated .../** line to drift-ignore.txt)')
  # grep -F: the expected line has regex metacharacters (.../** ...) that are not a pattern here.
  grep -qF -- "$want" <<<"$d" && ok "huge tree collapses to one NEW line" || bad "huge tree collapses to one NEW line" "missing '$want'"
  ! grep -q 'blob/store/f' <<<"$d" && ok "no per-file lines for the huge tree" || bad "huge tree was still scanned per-file"
  has "small sibling is still scanned" "$d" "share/small/one.conf"
  ! grep -q 'bigok' <<<"$d" && ok "allowlisted huge tree stays quiet" || bad "allowlisted huge tree wrongly reported"
  has "sentinel still present with the guard" "$d" "# drift-scan-complete"
fi
if group 49 "desktop popups fire only from the timer, never from a manual run"; then
  # A manual run already prints the same warning to a terminal somebody is
  # reading, and the fixture's popups once named paths that exist only under a
  # scratch $HOME. systemd sets INVOCATION_ID for a unit's processes and
  # nothing else does. notify() prefers omarchy-notification-send and falls
  # back to notify-send, so BOTH are stubbed or an Omarchy machine never
  # reaches the log at all.
  mk_fixture g49; seed_home; commit_baseline
  mkdir -p "$T/fakebin"
  for n in notify-send omarchy-notification-send; do
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/notify.log"\n' "$T" > "$T/fakebin/$n"
    chmod +x "$T/fakebin/$n"
  done
  # $@ = env options/assignments; prints how many "new unbacked" popups the run sent
  npop() {
    : > "$T/notify.log"
    env "$@" PATH="$T/fakebin:$PATH" HOME="$FH" "$CLI" snapshot --no-push >/dev/null 2>&1
    grep -c 'new unbacked' "$T/notify.log" || true
  }
  mkdir -p "$FH/.config/appd"; printf 'x\n' > "$FH/.config/appd/d.toml"
  eq "manual run (no INVOCATION_ID) sends no popup" "$(npop -u INVOCATION_ID OMABACKUP_NOTIFY=1)" "0"
  mkdir -p "$FH/.config/appe"; printf 'x\n' > "$FH/.config/appe/e.toml"
  eq "timer path (INVOCATION_ID set) pops once for new drift" "$(npop INVOCATION_ID=fixture OMABACKUP_NOTIFY=1)" "1"
  eq "an unchanged report does not pop again" "$(npop INVOCATION_ID=fixture OMABACKUP_NOTIFY=1)" "0"
  mkdir -p "$FH/.config/appf"; printf 'x\n' > "$FH/.config/appf/f.toml"
  eq "OMABACKUP_NOTIFY=0 silences the timer path too" "$(npop INVOCATION_ID=fixture OMABACKUP_NOTIFY=0)" "0"
  # A vanished OPTIONAL entry is a GONE line, and the backup just got smaller.
  # That is the one drift class nobody notices on their own, so it has to pop
  # exactly like a NEW line does: once, then never again for the same report.
  # Four more covered entries first. One entry vanishing out of four is 25% of
  # the allowlist, which is the mass-disappearance guard's default threshold:
  # this group is about notifications, and a real install has twenty-odd
  # entries, so give the fixture enough that one GONE is the minority it would
  # be in practice.
  mkdir -p "$FH/.config/appn"
  for i in 1 2 3 4; do printf 'x\n' > "$FH/.config/appn/n$i.conf"; allow "?.config/appn/n$i.conf"; done
  mkdir -p "$FH/.config/appg"; printf 'x\n' > "$FH/.config/appg/g.toml"
  allow '?.config/appg'
  eq "adding a covered optional entry is not new drift" "$(npop INVOCATION_ID=fixture OMABACKUP_NOTIFY=1)" "0"
  rm -rf "$FH/.config/appg"
  eq "a vanished optional entry (GONE) pops once" "$(npop INVOCATION_ID=fixture OMABACKUP_NOTIFY=1)" "1"
  eq "the same GONE does not pop again" "$(npop INVOCATION_ID=fixture OMABACKUP_NOTIFY=1)" "0"
fi
if group 50 "status: JSON for the bar widget"; then
  # The bar widget renders exactly this JSON and nothing else, so every field
  # the QML relies on gets an assertion here -- a health regression must show
  # up as a weekly red, not as a blank badge nobody questions.
  mk_fixture g50; seed_home; commit_baseline
  { printf 'NEW        ~/.config/appz/z.toml\n'
    printf 'GONE       ~/.config/gonezo\n'
    printf 'NEW        ~/.local/share/bigz/\t(>2000 files: too large to scan; add or ignore wholesale)\n'
    printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"
  date +%s > "$FR/manifests/.last-run"
  git -C "$FR" push -q -u origin main 2>/dev/null || true

  s=$(obj status)
  eq "status emits valid JSON" "$(jq -e . <<<"$s" >/dev/null 2>&1 && echo ok || echo bad)" "ok"
  eq "drift_count matches the report" "$(jq -r .drift_count <<<"$s")" "3"
  eq "drift lines parse into type+path" "$(jq -r '.drift[0].type + "|" + .drift[0].path' <<<"$s")" "NEW|~/.config/appz/z.toml"
  eq "GONE lines carried through" "$(jq -r '.drift[1].type' <<<"$s")" "GONE"
  has "collapsed-tree note survives parsing" "$(jq -r '.drift[2].note' <<<"$s")" "too large"
  eq "sentinel detected" "$(jq -r .drift_scan_complete <<<"$s")" "true"
  eq "clean tree: nothing pending" "$(jq -c '[.unpushed,.uncommitted]' <<<"$s")" "[0,[]]"
  eq "drift alone yields state=attention" "$(jq -r .state <<<"$s")" "attention"
  eq "last-run age surfaces" "$(jq -c '[(.last_run>0),.last_run_age_days]' <<<"$s")" "[true,0]"

  # The badge must be able to say "and N more" without shipping thousands of
  # rows of JSON: 2001 synthetic lines exercise the real WIDGET_DRIFT_LIMIT.
  { i=1; while [ "$i" -le 2001 ]; do printf 'NEW        ~/.config/cap%d.toml\n' "$i"; i=$((i+1)); done
    printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"
  eq "drift list caps at the limit with the true count kept" \
    "$(obj status | jq -c '[(.drift|length),.drift_truncated,.drift_count]')" "[2000,true,2001]"

  # A report that never finished must read as a FAULT, never as "all clean"
  # -- the same fail-closed rule cmd_health enforces.
  printf 'NEW        ~/.config/x.toml\n' > "$FR/manifests/drift.txt"
  eq "missing sentinel is a fault with a stated problem" \
    "$(obj status | jq -c '[.drift_scan_complete,.state,(.problems|length>0)]')" '[false,"fault",true]'
  printf '# drift-scan-complete\n' > "$FR/manifests/drift.txt"
  eq "empty completed report is state=ok" "$(obj status | jq -c '[.drift_count,.state]')" '[0,"ok"]'

  # Unpushed commits mirror cmd_health severity: data not off the machine = fault.
  git -C "$FR" commit -q --allow-empty -m "widget-unpushed"
  eq "unpushed commit counted and escalated" "$(obj status | jq -c '[.unpushed,.state]')" '[1,"fault"]'
  git -C "$FR" push -q origin main 2>/dev/null
  eq "clears after push" "$(obj status | jq -r .unpushed)" "0"

  # Edits the timer will not commit (same pathspec as cmd_health).
  printf '\n# widget-fixture-edit\n' >> "$FR/drift-ignore.txt"
  has "uncommitted script edit listed" "$(obj status | jq -r '.uncommitted[]')" "drift-ignore.txt"
  git -C "$FR" checkout -q -- drift-ignore.txt

  # Paths are attacker-ish input for a JSON emitter: quotes and backslashes in
  # a filename must not produce invalid JSON or a mangled path.
  printf 'NEW        ~/.config/we"ird\\path.toml\n# drift-scan-complete\n' > "$FR/manifests/drift.txt"
  # shellcheck disable=SC2088 # expected literal string, not a path to expand
  eq "quote+backslash in a path round-trips" "$(obj status | jq -r '.drift[0].path')" '~/.config/we"ird\path.toml'

  # A clean slate for the closing assertions, isolated from the synthetic
  # drift used above.
  printf '# drift-scan-complete\n' > "$FR/manifests/drift.txt"
  date +%s > "$FR/manifests/.last-run"

  eq "status.json exists after status" "$(test -f "$OMABACKUP_STATE_DIR/status.json" && echo yes)" "yes"
  eq "status.json equals stdout" "$(obj status | jq -S .)" "$(jq -S . "$OMABACKUP_STATE_DIR/status.json")"
  eq "setup is ready in the fixture" "$(obj status | jq -r .setup)" "ready"

  # remote_label / remote_linkable: the popup names the repository the backup
  # goes to, and offers a click only for a remote whose page this tool can
  # actually name. The fixture's origin is a local bare path, which has a
  # label (it is what the operator typed) and no page.
  eq "a local bare remote is labelled by its path, and is not linkable" \
    "$(obj status | jq -c '[.remote_label, .remote_linkable]')" "[\"$BARE\",false]"
  # Every spelling of the same GitHub repo yields the same owner/repo label.
  for u50 in "git@github.com:o/r.git" "https://github.com/o/r" "https://GitHub.com/o/r/" \
             "ssh://git@github.com:22/o/r" "http://github.com/o/r" "https://user@github.com/o/r"; do
    git -C "$FR" remote set-url origin "$u50"
    eq "github remote labelled and linkable: $u50" \
      "$(obj status | jq -c '[.remote_label, .remote_linkable]')" '["o/r",true]'
  done
  # A GitHub host whose path is not exactly owner/repo has no page this tool
  # can name: it is still labelled, and it is NOT offered as a link.
  git -C "$FR" remote set-url origin "https://github.com/o/r/extra"
  eq "an unslugged github path is labelled but not linkable" \
    "$(obj status | jq -c '[.remote_label, .remote_linkable]')" '["github.com/o/r/extra",false]'
  # Another host is labelled host/path, and a password in the URL never
  # reaches the label: remote_url_parts strips the userinfo before it returns.
  git -C "$FR" remote set-url origin "https://alice:hunter2secret@gitlab.example.com/alice/dots.git"
  l50=$(obj status | jq -r .remote_label)
  eq "a non-github remote is labelled host/path" "$l50" "gitlab.example.com/alice/dots"
  eq "and no password reaches the label" "$(grep -c hunter2secret <<<"$l50" || true)" "0"
  eq "nor the status file" "$(grep -c hunter2secret "$OMABACKUP_STATE_DIR/status.json" || true)" "0"
  # A pushurl that differs means the fetch URL is NOT where the backup goes,
  # and the engine refuses to push to either until it is removed. Naming the
  # fetch repository as the backup target would be a lie the panel tells
  # confidently (Codex, PR 8).
  git -C "$FR" remote set-url origin "https://github.com/o/r"
  git -C "$FR" remote set-url --push origin "https://github.com/someone/else"
  eq "a differing push url means no label and no link" \
    "$(obj status | jq -c '[.remote_label, .remote_linkable]')" '["",false]'
  o50p=$(env HOME="$FH" "$CLI" open --remote 2>&1); rc50p=$?
  eq "and open --remote refuses" "$rc50p" "1"
  has "naming the mismatch" "$o50p" "pushes to a different URL"
  git -C "$FR" remote set-url --push --delete origin "https://github.com/someone/else" 2>/dev/null || true
  eq "removing the pushurl brings the label back" \
    "$(obj status | jq -c '[.remote_label, .remote_linkable]')" '["o/r",true]'
  # No origin at all: no label, no link. The Pushed row already says local only.
  git -C "$FR" remote remove origin
  eq "no origin means no label and no link" \
    "$(obj status | jq -c '[.remote_label, .remote_linkable]')" '["",false]'
  # Put the fixture back exactly as it was: the assertions after this one are
  # about health, and health reads the upstream, which a remove/add drops.
  git -C "$FR" remote add origin "$BARE"
  git -C "$FR" fetch -q origin
  git -C "$FR" branch --set-upstream-to=origin/main main >/dev/null 2>&1
  jq '.remote.trusted=false' "$OMABACKUP_CONFIG" > "$T/c2" && mv "$T/c2" "$OMABACKUP_CONFIG"
  eq "setup reports remote-unverified for an untrusted non-GitHub remote" "$(obj status | jq -r .setup)" "remote-unverified"
  jq '.remote.trusted=true' "$OMABACKUP_CONFIG" > "$T/c2" && mv "$T/c2" "$OMABACKUP_CONFIG"
  eq "health exits 0 and prints nothing when ok" "$(ob health)" ""

  # `health --json` is a verb like any other: exactly one JSON object on
  # stdout, especially when it is refusing. It used to print a coloured ANSI
  # line (or nothing at all) and leave a --json caller with nothing to parse.
  hj=$(obj health)
  eq "health --json on a healthy repo is one object with ok true" \
    "$(jq -c '[.ok,.state,(.problems|length)]' <<<"$hj")" '[true,"ok",0]'
  rm -f "$FR/manifests/drift.txt"
  hj=$(obj health); hrc=$?
  eq "health --json with no drift report says ok false" "$(jq -c '[.ok,.state]' <<<"$hj")" '[false,"fault"]'
  has "the problems array names the missing report" "$(jq -r '.problems[]' <<<"$hj")" "no drift report"
  eq "the problem names this tool's timer, not a foreign script" \
    "$(jq -r '.problems[]' <<<"$hj" | grep -c 'snapshot\.sh')" "0"
  eq "an unhealthy health --json still exits 1" "$hrc" "1"
  eq "not-configured health --json is one object with ok false" \
    "$(OMABACKUP_CONFIG=/nonexistent obj health | jq -r .ok)" "false"
  eq "not-configured health --json is exactly one object" \
    "$(OMABACKUP_CONFIG=/nonexistent obj health | jq -s 'length')" "1"
  eq "not-configured health --json still exits 1" \
    "$(OMABACKUP_CONFIG=/nonexistent ob health --json >/dev/null 2>&1; echo $?)" "1"
  printf '# drift-scan-complete\n' > "$FR/manifests/drift.txt"

  # setup=not-configured must be reportable even with no config at all: the
  # dispatcher skips config_load for status/health only in that case.
  eq "not-configured status reports setup" "$(OMABACKUP_CONFIG=/nonexistent obj status | jq -r .setup)" "not-configured"
  eq "not-configured status state is attention" "$(OMABACKUP_CONFIG=/nonexistent obj status | jq -r .state)" "attention"
  eq "not-configured status exits 0" "$(OMABACKUP_CONFIG=/nonexistent ob status >/dev/null 2>&1; echo $?)" "0"
  eq "not-configured health exits 1" "$(OMABACKUP_CONFIG=/nonexistent ob health >/dev/null 2>&1; echo $?)" "1"

  # status.json is the widget's only view of the world: a stale "healthy"
  # file from before the config vanished must not survive a not-configured run.
  printf '{"state":"ok","setup":"ready"}\n' > "$OMABACKUP_STATE_DIR/status.json"
  ncj=$(OMABACKUP_CONFIG=/nonexistent obj status)
  eq "not-configured status.json overwrites the stale file, not just stdout" \
    "$(jq -S . "$OMABACKUP_STATE_DIR/status.json")" "$(jq -S . <<<"$ncj")"
  eq "the written file says not-configured, not the stale ready" \
    "$(jq -r .setup "$OMABACKUP_STATE_DIR/status.json")" "not-configured"
  eq "not-configured status carries the full configured key set" \
    "$(jq -S 'keys' <<<"$ncj")" "$(obj status | jq -S 'keys')"
fi
if group 51 "widget write verbs: allow, ignore, resolve-gone, push, timer, open"; then
  # Popup buttons append to the lists. Every write path must refuse arbitrary
  # input (only paths the CURRENT drift report names), take the repo flock,
  # lint afterward, and roll back when lint rejects the result -- the widget
  # must never be able to corrupt the lists it serves.
  # Drift paths reach these verbs VERBATIM, "~/"-prefixed and never
  # shell-expanded (the QML passes the JSON path field straight through);
  # tp() builds them so that stays visibly deliberate.
  mk_fixture g51; seed_home; commit_baseline
  # shellcheck disable=SC2088  # matching the LITERAL "~/" status emits, not a path to expand
  tp() { printf '~/%s' "$1"; }
  mkdir -p "$FH/.config/appz"; printf 'z=1\n' > "$FH/.config/appz/z.toml"
  mkdir -p "$FH/.local/share/bigz"; printf 'b\n' > "$FH/.local/share/bigz/f1"
  { printf 'NEW        ~/.config/appz/z.toml\n'
    printf 'NEW        ~/.local/share/bigz/\t(>2000 files: too large to scan; add or ignore wholesale)\n'
    printf 'GONE       ~/.config/gonezo\n'
    printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"

  eq "a file row says it is not a directory" \
    "$(obj status | jq -r '.drift[] | select(.path | endswith("z.toml")) | .dir')" "false"
  eq "allow: accepted and lint-gated" \
    "$(obj allow "$(tp .config/appz/z.toml)" | jq -c '[.ok,.lint_ok]')" "[true,true]"
  grep -qx '.config/appz/z.toml' "$FR/allowlist.txt" && ok "allow: appended to allowlist.txt" || bad "allowlist not updated"
  eq "allow: refuses a path the drift report never named" \
    "$(obj allow "$(tp .config/never-drifted.conf)" | jq -r .ok)" "false"

  # A duplicate append is exactly what lint rejects: the edit must roll back.
  eq "allow: re-allowing an allowlisted path is refused" \
    "$(obj allow "$(tp .config/appz/z.toml)" | jq -r .ok)" "false"
  [[ "$(grep -cx '.config/appz/z.toml' "$FR/allowlist.txt")" == 1 ]] \
    && ok "allow: no duplicate line left behind" || bad "duplicate line written"

  # An absolute path smuggled after the "~/" prefix, and a newline smuggled
  # into the value, must both be refused before the value ever reaches a list
  # file (rel_from_tilde and assert_argv_safe respectively).
  # shellcheck disable=SC2088  # literal "~/" prefix, not a path to expand
  eq "allow: refuses an absolute path smuggled after ~/" "$(obj allow '~//etc/passwd' | jq -r .ok)" "false"
  # shellcheck disable=SC2088  # literal "~/" prefix, not a path to expand
  eq "allow: refuses a newline-smuggling value" "$(obj allow "$(printf '~/x\ny')" | jq -r .ok)" "false"

  # Even a hostile drift line must not let a write escape $HOME-relative space.
  cp "$FR/manifests/drift.txt" "$T/drift51.tmp"
  printf 'NEW        ~/../outside.conf\n# drift-scan-complete\n' > "$FR/manifests/drift.txt"
  eq "allow: refuses traversal even when drift names it" \
    "$(obj allow "$(tp ../outside.conf)" | jq -r .ok)" "false"
  cp "$T/drift51.tmp" "$FR/manifests/drift.txt"

  # ALLOW IS NOT THE FIX FOR A TOOBIG OR AN EXCLUDED ROW, and the engine has to
  # say so rather than write an entry that lifts neither limit. Both classes
  # name paths the allowlist ALREADY covers -- one held back by maxFileSize,
  # the other by .gitignore -- so the click struck the row out and the next
  # scan brought it back unchanged. The popup hides the button; the refusal
  # here is what a CLI caller (and the popup, if it ever regressed) gets.
  mkdir -p "$FH/.config/appbig"
  printf 'x\n' > "$FH/.config/appbig/huge.img"; printf 'x\n' > "$FH/.config/appbig/keep.key"
  { printf 'TOOBIG     ~/.config/appbig/huge.img\t(exceeds 8m; NOT backed up)\n'
    printf 'EXCLUDED   ~/.config/appbig/keep.key\t(matches .gitignore; NOT backed up)\n'
    printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"
  a51b=$(obj allow "$(tp .config/appbig/huge.img)")
  eq "allow: refuses a TOOBIG row" "$(jq -r .ok <<<"$a51b")" "false"
  eq "allow: the TOOBIG refusal is one JSON object" "$(jq -sc 'length' <<<"$a51b")" "1"
  has "allow: the TOOBIG refusal names the limit that holds the file" "$a51b" "maxFileSize"
  a51e=$(obj allow "$(tp .config/appbig/keep.key)")
  eq "allow: refuses an EXCLUDED row" "$(jq -r .ok <<<"$a51e")" "false"
  has "allow: the EXCLUDED refusal names .gitignore" "$a51e" ".gitignore"
  has "allow: ...and the negation line that lifts it" "$a51e" "negation line"
  eq "allow: neither refusal appended anything" \
    "$(grep -c 'appbig' "$FR/allowlist.txt" || true)" "0"
  # Ignore still takes both classes: it is the triage that does apply.
  eq "ignore: still accepts a TOOBIG row" \
    "$(obj ignore "$(tp .config/appbig/huge.img)" 'too big to keep' | jq -r .ok)" "true"
  cp "$T/drift51.tmp" "$FR/manifests/drift.txt"

  # Ignore: dated entry, reason recorded, collapsed trees become subtree ignores.
  eq "ignore: accepted" \
    "$(obj ignore "$(tp .local/share/bigz/)" 'huge store, regenerable' | jq -r .ok)" "true"
  grep -qE '^\.local/share/bigz/\*\*[[:space:]]+# 20[0-9]{2}-[0-9]{2}-[0-9]{2} huge store, regenerable' "$FR/drift-ignore.txt" \
    && ok "ignore: dated subtree entry written" || bad "ignore entry malformed"

  # No reason given: the default is dated, not a bare unattributed line.
  mkdir -p "$FH/.config/appdef"; printf 'x\n' > "$FH/.config/appdef/d.toml"
  printf 'NEW        ~/.config/appdef/d.toml\n# drift-scan-complete\n' > "$FR/manifests/drift.txt"
  eq "ignore: accepted with no reason given" "$(obj ignore "$(tp .config/appdef/d.toml)" | jq -r .ok)" "true"
  grep -qE '^\.config/appdef/d\.toml[[:space:]]+# 20[0-9]{2}-[0-9]{2}-[0-9]{2} triaged from widget' "$FR/drift-ignore.txt" \
    && ok "ignore: default reason is dated 'triaged from widget'" || bad "default reason missing or malformed"
  cp "$T/drift51.tmp" "$FR/manifests/drift.txt"

  # Folder-level decisions: a "~/dir/" target is accepted when at least one
  # drifting path lies UNDER it (the folder itself is never a drift line),
  # refused when nothing under it drifts, and always refused at depth 1 --
  # "~/.config/" would silence an entire report in one click.
  mkdir -p "$FH/.config/appq/sub" "$FH/.config/appr"
  printf 'q\n' > "$FH/.config/appq/a.toml"; printf 'q\n' > "$FH/.config/appq/sub/b.toml"
  printf 'r\n' > "$FH/.config/appr/a.toml"; printf 'r\n' > "$FH/.config/appr/b.toml"
  { printf 'NEW        ~/.config/appq/a.toml\n'
    printf 'NEW        ~/.config/appq/sub/b.toml\n'
    printf 'NEW        ~/.config/appr/a.toml\n'
    printf 'NEW        ~/.config/appr/b.toml\n'
    printf 'GONE       ~/.config/gonezo\n'
    printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"
  eq "folder ignore: prefix of drifting files becomes a /** entry" \
    "$(obj ignore "$(tp .config/appq/)" 'widget folder test' | jq -c '[.ok,.ignored]')" '[true,".config/appq/**"]'
  eq "folder allow: prefix of drifting files allowlisted as the dir" \
    "$(obj allow "$(tp .config/appr/)" | jq -c '[.ok,.added]')" '[true,".config/appr"]'
  grep -qx '.config/appr' "$FR/allowlist.txt" && ok "folder allow: entry written" || bad "folder allow entry missing"
  eq "folder ignore: refused when nothing under it drifts" \
    "$(obj ignore "$(tp .config/appx/)" | jq -r .ok)" "false"
  eq "folder ignore: depth-1 folder refused (would silence the report)" \
    "$(obj ignore "$(tp .config/)" | jq -r .ok)" "false"
  cp "$T/drift51.tmp" "$FR/manifests/drift.txt"

  # WHOLE-DIRECTORY ROWS, ADDRESSED THE WAY THE POPUP ACTUALLY ADDRESSES THEM.
  # drift_items_json strips a report row's trailing slash, and the QML passes
  # that JSON path straight back to allow/ignore -- so these verbs are given
  # "~/.mozilla", never "~/.mozilla/". Every such row (a new ~/.config/<app>/,
  # a new dot-directory, a tree collapsed for being over the scan cap) used to
  # be refused by both buttons, which is most of what a real machine reports.
  mkdir -p "$FH/.mozilla/profile" "$FH/.config/appdir/sub" "$FH/.local/share/bigq"
  printf 'm\n' > "$FH/.mozilla/profile/prefs.js"
  printf 'a\n' > "$FH/.config/appdir/sub/a.toml"
  printf 'q\n' > "$FH/.local/share/bigq/f1"
  { printf 'NEW        ~/.mozilla/\n'
    printf 'NEW        ~/.config/appdir/\n'
    printf 'NEW        ~/.local/share/bigq/\t(>2000 files: too large to scan; add or ignore wholesale)\n'
    printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"
  # shellcheck disable=SC2088  # expected literal string, not a path to expand
  eq "a directory row reaches the widget with no trailing slash" \
    "$(obj status | jq -r '[.drift[].path] | join(",")')" '~/.mozilla,~/.config/appdir,~/.local/share/bigq'
  # The slash is stripped, so the FACT it carried is published instead: the
  # popup's wording for Allow on a folder is deciding for everything put in
  # it later, and "back this up" does not say that.
  eq "and the row says it is a directory" \
    "$(obj status | jq -r '[.drift[].dir] | join(",")')" "true,true,true"
  eq "allow: takes a directory row exactly as the JSON names it" \
    "$(obj allow "$(tp .config/appdir)" | jq -c '[.ok,.added]')" '[true,".config/appdir"]'
  grep -qx '.config/appdir' "$FR/allowlist.txt" && ok "allow: the directory entry was written" || bad "directory allow entry missing"
  # And the ignore it writes is still the SUBTREE form: a bare entry means
  # "silence the directory, keep checking its children", which would replace
  # one collapsed row with every file under it.
  eq "ignore: takes a directory row and still records the subtree form" \
    "$(obj ignore "$(tp .local/share/bigq)" 'huge store' | jq -c '[.ok,.ignored]')" '[true,".local/share/bigq/**"]'
  eq "ignore: a top-level directory row is taken too" \
    "$(obj ignore "$(tp .mozilla)" 'browser profile' | jq -c '[.ok,.ignored]')" '[true,".mozilla/**"]'
  cp "$T/drift51.tmp" "$FR/manifests/drift.txt"

  # A file OLDER than the last snapshot is the normal allow case: it cannot be
  # in home/ until the next snapshot runs, so the write gate must not fail the
  # completeness walk (that stays the standalone/weekly lint's job).
  mkdir -p "$FH/.config/appold"; printf 'o\n' > "$FH/.config/appold/old.toml"
  touch -d '2 days ago' "$FH/.config/appold/old.toml"
  date +%s > "$FR/manifests/.last-run"
  printf 'NEW        ~/.config/appold/old.toml\n# drift-scan-complete\n' > "$FR/manifests/drift.txt"
  eq "allow: a file predating the last snapshot is accepted" \
    "$(obj allow "$(tp .config/appold/old.toml)" | jq -r .ok)" "true"
  grep -qx '.config/appold/old.toml' "$FR/allowlist.txt" && ok "allow: old-file entry written" || bad "old-file entry missing"

  # When the lists are ALREADY broken, widget writes must refuse (rolled back)
  # and say why in clean text: no ANSI escapes leaking into the popup.
  printf '.config/no-such-thing-xyz\n' >> "$FR/allowlist.txt"
  printf 'o\n' > "$FH/.config/appold/old2.toml"
  printf 'NEW        ~/.config/appold/old2.toml\n# drift-scan-complete\n' > "$FR/manifests/drift.txt"
  out51=$(obj allow "$(tp .config/appold/old2.toml)")
  eq "broken lists refuse the write" "$(jq -r .ok <<<"$out51")" "false"
  has "the refusal names the lint code" "$(jq -r '.problems[0]' <<<"$out51")" "MISSING"
  [[ "$(jq -r '.problems[0]' <<<"$out51")" != *$'\033'* ]] \
    && ok "refusal message has no ANSI escapes" || bad "ANSI leaked into the popup message"
  grep -qx '.config/appold/old2.toml' "$FR/allowlist.txt" && bad "edit not rolled back" || ok "edit rolled back on pre-existing lint problem"
  sed -i '/no-such-thing-xyz/d' "$FR/allowlist.txt"
  cp "$T/drift51.tmp" "$FR/manifests/drift.txt"

  # GONE resolution edits exactly one allowlist line.
  printf '.config/gonezo\n' >> "$FR/allowlist.txt"
  eq "resolve-gone remove: accepted" "$(obj resolve-gone "$(tp .config/gonezo)" remove | jq -r .ok)" "true"
  grep -q '^\.config/gonezo' "$FR/allowlist.txt" && bad "gone entry still present" || ok "resolve-gone remove: entry deleted"
  printf '.config/gonezo\n' >> "$FR/allowlist.txt"
  eq "resolve-gone optional: accepted" "$(obj resolve-gone "$(tp .config/gonezo)" optional | jq -r .ok)" "true"
  grep -qx '?.config/gonezo' "$FR/allowlist.txt" && ok "resolve-gone optional: '?' prefixed" || bad "optional marker missing"
  # Twice is the case a fresh machine hits first: every seed entry ships
  # optional, so day one is a column of GONE rows whose "Mark optional" button
  # reprinted the line unchanged, replied ok, and let the popup mark the row
  # handled -- then the next snapshot brought it straight back.
  out51=$(obj resolve-gone "$(tp .config/gonezo)" optional)
  eq "resolve-gone optional: refused on an already-optional entry" "$(jq -r .ok <<<"$out51")" "false"
  has "the refusal points at Remove" "$(jq -r '.problems[0]' <<<"$out51")" "already optional"
  eq "resolve-gone optional: the allowlist still carries exactly one entry" \
    "$(grep -cx '?.config/gonezo' "$FR/allowlist.txt")" "1"
  # The popup can only hide that button if the engine says which rows are
  # already optional, so the GONE item carries the fact.
  eq "the GONE item reports that its entry is optional" \
    "$(obj status | jq -r '.drift[] | select(.type == "GONE") | .optional')" "true"
  eq "and a NEW row carries the field as false rather than leaving it out" \
    "$(obj status | jq -r '.drift[] | select(.type == "NEW") | .optional' | sort -u)" "false"
  # A REQUIRED entry that vanished is a GONE row too, and marking that one
  # optional is the whole point of the button.
  sed -i 's/^?\.config\/gonezo$/.config\/gonezo/' "$FR/allowlist.txt"
  eq "a required entry's GONE row is not reported as optional" \
    "$(obj status | jq -r '.drift[] | select(.type == "GONE") | .optional')" "false"
  eq "resolve-gone optional: still accepted on a required entry" \
    "$(obj resolve-gone "$(tp .config/gonezo)" optional | jq -r .ok)" "true"
  # A path is not a glob. The lists are MATCHED as globs (lists_load expands
  # every allowlist entry, is_ignored runs each ignore entry as a pattern), so
  # a file genuinely named `*` would have had one Allow click write an entry
  # matching every sibling it has. A `[` has an escaped spelling and is
  # accepted (group 110); `*` and `?` have none and stay refused.
  # The report NAMES both, so the refusal below is about the glob characters
  # and nothing else.
  printf 'x\n' > "$FH/.config/appz/*"; printf 'x\n' > "$FH/.config/appz/?"
  printf 'y\n' > "$FH/.config/appz/slashme.toml"
  { printf 'NEW        ~/.config/appz/*\n'
    printf 'NEW        ~/.config/appz/?\n'
    printf 'NEW        ~/.config/appz/slashme.toml\n'
    printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"
  out51=$(obj allow "$(tp '.config/appz/*')")
  eq "allow: refuses a path holding a glob character" "$(jq -r .ok <<<"$out51")" "false"
  # The message has to name an action that exists. "Edit allowlist.txt by
  # hand" did not: no allowlist spelling resolves a literal `*`.
  has "and names the two things a user can actually do" \
    "$(jq -r '.problems[0]' <<<"$out51")" "rename it, or ignore the folder it is in"
  eq "and nothing was written" "$(grep -c '^\.config/appz/\*$' "$FR/allowlist.txt")" "0"
  eq "ignore: refuses a question mark too" "$(obj ignore "$(tp '.config/appz/?')" | jq -r .ok)" "false"
  eq "and no ignore entry was written for it" \
    "$(grep -cE '^\.config/appz/\?' "$FR/drift-ignore.txt")" "0"

  # A slashed argument names a DIRECTORY, and a file row is not one. The
  # report's own slash is the only authority for that; taking the argument's
  # as well let this spelling write a subtree ignore for a plain file.
  eq "allow: a trailing slash on a file row is refused" \
    "$(obj allow "$(tp .config/appz/slashme.toml/)" | jq -r .ok)" "false"
  eq "and nothing was written for it either" \
    "$(grep -c '^\.config/appz/slashme\.toml$' "$FR/allowlist.txt")" "0"
  eq "ignore: the same spelling is refused there too" \
    "$(obj ignore "$(tp .config/appz/slashme.toml/)" | jq -r .ok)" "false"
  rm -f "$FH/.config/appz/*" "$FH/.config/appz/?" "$FH/.config/appz/[a]" "$FH/.config/appz/slashme.toml"
  cp "$T/drift51.tmp" "$FR/manifests/drift.txt"

  # Both halves of the GONE gate can pass with no allowlist line left to edit
  # (a hand-deleted entry, a report from before it went). A rewrite that
  # changes nothing must not report a decision.
  printf 'GONE       ~/.config/no-entry-at-all\n# drift-scan-complete\n' > "$FR/manifests/drift.txt"
  out51=$(obj resolve-gone "$(tp .config/no-entry-at-all)" remove)
  eq "resolve-gone: refused when no allowlist line matches" "$(jq -r .ok <<<"$out51")" "false"
  has "and says why" "$(jq -r '.problems[0]' <<<"$out51")" "no entry for that path"
  cp "$T/drift51.tmp" "$FR/manifests/drift.txt"

  eq "resolve-gone: refuses a path drift does not list as GONE" \
    "$(obj resolve-gone "$(tp .config/appz/z.toml)" remove | jq -r .ok)" "false"

  # NOTHING TO PUSH IS NOT A REFUSAL, and it must not touch the network to
  # say so. The popup shows Push whenever a remote exists, so pressing it on
  # a healthy machine is the normal case, and it ran the visibility probe and
  # then painted "push not allowed: remote-unverified" red over a repo with
  # nothing waiting and nothing wrong. Untrusted, nothing ahead, nothing
  # dirty: the reply is ok with a note, and the recorded verdict is untouched.
  git -C "$FR" add -A >/dev/null 2>&1; git -C "$FR" commit -qm "settle before the push probe" >/dev/null 2>&1
  git -C "$FR" push -q -u origin HEAD >/dev/null 2>&1
  jq '.remote.trusted=false' "$OMABACKUP_CONFIG" > "$T/c51" && mv "$T/c51" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  printf '{"verifiable":true,"reason":"canary","url":"canary","at":1}\n' > "$OMABACKUP_STATE_DIR/push-verdict.json"
  out51=$(obj push)
  eq "push with nothing ahead and nothing dirty is ok, not a refusal" \
    "$(jq -c '[.ok,.pushed,.note]' <<<"$out51")" '[true,0,"nothing to push"]'
  eq "and it recorded no verdict, because it never probed" \
    "$(jq -r .reason "$OMABACKUP_STATE_DIR/push-verdict.json")" "canary"
  # And the shortcut only speaks for the remote the config names: a
  # `git remote set-url origin` by hand leaves refs/remotes/origin/* pointing
  # at commits the NEW remote may not have, so "nothing to push" would be an
  # answer about a remote this repo no longer talks to.
  git -C "$FR" remote set-url origin "$T/repointed.git"
  eq "a repointed origin does not get the nothing-to-push shortcut" \
    "$(obj push | jq -r .ok)" "false"
  git -C "$FR" remote set-url origin "$BARE"

  # A gate refusal with a commit actually waiting is still a refusal.
  printf 'ahead\n' > "$FH/.config/mytool/mytool.conf"
  ob snapshot --no-push >/dev/null 2>&1
  out51=$(obj push)
  eq "push with a commit waiting and the gate shut still refuses" "$(jq -r .ok <<<"$out51")" "false"
  has "and says which gate" "$(jq -r '.problems[0]' <<<"$out51")" "push not allowed"
  jq '.remote.trusted=true' "$OMABACKUP_CONFIG" > "$T/c51" && mv "$T/c51" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  cp "$T/drift51.tmp" "$FR/manifests/drift.txt"
  # The commit above settled the list edits the confirm-gate assertions below
  # are about; put one back so they still have something to confirm.
  printf '.config/re-dirtied-for-the-confirm-gate/**   # %s widget test\n' "$(date +%F)" >> "$FR/drift-ignore.txt"

  # The dynamic push button: confirm-gated scoped commit, never `git add -A`.
  out51=$(obj push)
  eq "push: pending list edits require confirmation" \
    "$(jq -c '[.ok,.needs_confirm,(.files|length>0)]' <<<"$out51")" '[false,true,true]'
  printf '# dirty manifest line\n' >> "$FR/manifests/drift.txt"
  if command -v gitleaks >/dev/null 2>&1; then
    eq "push --confirm: succeeded" "$(obj push --confirm | jq -r .ok)" "true"
    [[ -z "$(git -C "$FR" status --porcelain -- allowlist.txt drift-ignore.txt etc-allowlist.txt normalize.txt)" ]] \
      && ok "push --confirm: tracked list edits committed" || bad "tracked list edits still dirty"
    git -C "$FR" status --porcelain -- manifests | grep -q drift.txt \
      && ok "push --confirm: snapshot-owned paths were NOT swept up" || bad "scoped add leaked into manifests/"
    [[ "$(git -C "$FR" rev-list --count 'origin/main..main' 2>/dev/null || echo 1)" == 0 ]] \
      && ok "push --confirm: commit reached the remote" || bad "commit never pushed"
  else
    echo "  (gitleaks not installed: skipping push --confirm assertions)"
  fi
  # `.gitleaks.toml` is inert (lib/secrets.sh scans with the plugin's own
  # share/gitleaks.toml), and it is still a file in the repo: status counts an
  # edit to it, so the button has to offer it. What the button asks about is
  # exactly what status counts, not a judgement about which files matter.
  printf '\n# an edit to the inert rules copy\n' >> "$FR/.gitleaks.toml"
  eq "push asks about every edit status counts, the inert .gitleaks.toml included" \
    "$(obj push | jq -r '[.files[]? | select(. == ".gitleaks.toml")] | length')" "1"
  git -C "$FR" checkout -q -- .gitleaks.toml
  # Back to the crafted report: checkout would resurrect the last COMMITTED
  # drift.txt, which never named appz, and the lock test below needs it named.
  cp "$T/drift51.tmp" "$FR/manifests/drift.txt"

  # While the lock is held, writes must refuse rather than interleave.
  ( flock -x 9; sleep 2 ) 9>>"$FR/.lock" &
  _lockpid=$!
  sleep 0.3
  out51=$(env HOME="$FH" OMABACKUP_LOCK_WAIT=1 "$CLI" ignore "$(tp .config/appz/z.toml)" x --json 2>/dev/null)
  eq "writes refuse while the repo lock is held" "$(jq -r .ok <<<"$out51")" "false"
  has "the refusal names the lock" "$(jq -r '.problems[0]' <<<"$out51")" "lock"
  wait "$_lockpid" 2>/dev/null

  # timer/run/pause/resume drive systemctl --user with exactly the right argv
  # (a fake systemctl records what would have run).
  mkdir -p "$T/fakebin"
  printf '#!/bin/sh\necho "$@" >> "%s/sysctl.log"\nexit 0\n' "$T" > "$T/fakebin/systemctl"
  chmod +x "$T/fakebin/systemctl"
  : > "$T/sysctl.log"
  # OMABACKUP_SKIP_TIMERS unset (0) here so these calls actually exercise the
  # fake systemctl, unlike the rest of this suite which sets it to 1.
  whp()  { env PATH="$T/fakebin:$PATH" HOME="$FH" OMABACKUP_SKIP_TIMERS=0 "$CLI" "$@" --json 2>/dev/null; }
  whpd() { env PATH="$T/fakebin:$PATH" HOME="$FH" OMABACKUP_SKIP_TIMERS=1 "$CLI" "$@" --json 2>/dev/null; }

  eq "timer run: starts the unit when systemctl accepts it" \
    "$(whp timer run | jq -c '[.ok,.started]')" '[true,"unit"]'
  # --no-block is load-bearing: the unit is Type=oneshot, so a plain start
  # would block for the whole snapshot and the popup's button would hold busy
  # exactly as long as running it inline.
  grep -qx -- '--user start --no-block omabackup-snapshot.service' "$T/sysctl.log" \
    && ok "timer run: starts the snapshot service without blocking on it" || bad "timer run argv wrong"

  # pause/resume are write verbs too: status.json must refresh after each,
  # same as allow/ignore/resolve-gone/push (compared by the "generated"
  # epoch, a full second apart so a same-second collision can't hide a bug).
  before_gen=$(jq -r '.generated // 0' "$OMABACKUP_STATE_DIR/status.json" 2>/dev/null || echo 0)
  sleep 1
  whp timer pause >/dev/null
  grep -qx -- '--user disable --now omabackup-snapshot.timer' "$T/sysctl.log" \
    && ok "timer pause: disables --now" || bad "timer pause argv wrong"
  after_gen=$(jq -r '.generated // 0' "$OMABACKUP_STATE_DIR/status.json" 2>/dev/null || echo 0)
  [[ "$after_gen" -gt "$before_gen" ]] \
    && ok "timer pause refreshes status.json" || bad "timer pause left status.json stale"

  sleep 1
  whp timer resume >/dev/null
  grep -qx -- '--user enable --now omabackup-snapshot.timer' "$T/sysctl.log" \
    && ok "timer resume: enables --now" || bad "timer resume argv wrong"
  before_gen=$after_gen
  after_gen=$(jq -r '.generated // 0' "$OMABACKUP_STATE_DIR/status.json" 2>/dev/null || echo 0)
  [[ "$after_gen" -gt "$before_gen" ]] \
    && ok "timer resume refreshes status.json" || bad "timer resume left status.json stale"

  eq "timer: unknown verb refused" "$(whp timer sideways | jq -r .ok)" "false"

  # Detached fallback: OMABACKUP_SKIP_TIMERS=1 must never touch systemctl, and
  # the detached snapshot's OWN health_write_status call refreshes status.json
  # a few seconds later -- that is how the widget learns the run finished.
  rm -f "$OMABACKUP_STATE_DIR/status.json"
  : > "$T/sysctl.log"
  eq "timer run: detached fallback when timers are skipped" \
    "$(whpd timer run | jq -c '[.ok,.started]')" '[true,"detached"]'
  [[ -s "$T/sysctl.log" ]] && bad "detached fallback still called systemctl" || ok "detached fallback did not touch systemctl"
  _deadline=$(( $(date +%s) + 10 ))
  while [[ ! -s "$OMABACKUP_STATE_DIR/status.json" && $(date +%s) -lt $_deadline ]]; do sleep 0.2; done
  [[ -s "$OMABACKUP_STATE_DIR/status.json" ]] \
    && ok "detached snapshot refreshed status.json within a few seconds" || bad "status.json never appeared"

  # open: a terminal, argv only (never a shell string), cd'd into the data
  # repo, detached. Both candidate launchers are faked so a real terminal
  # never pops on the machine running the suite.
  for n in omarchy-launch-floating-terminal-with-presentation xdg-terminal-exec; do
    printf '#!/bin/sh\npwd > "%s/open.cwd"\nexit 0\n' "$T" > "$T/fakebin/$n"
    chmod +x "$T/fakebin/$n"
  done
  : > "$T/open.cwd"
  eq "open: accepted" "$(env PATH="$T/fakebin:$PATH" HOME="$FH" "$CLI" open --json 2>/dev/null | jq -r .ok)" "true"
  _deadline=$(( $(date +%s) + 5 ))
  while [[ ! -s "$T/open.cwd" && $(date +%s) -lt $_deadline ]]; do sleep 0.1; done
  eq "open: launches the terminal cd'd into the data repo" "$(cat "$T/open.cwd" 2>/dev/null)" "$FR"
fi

if group 60 "setup creates a data repo, seeds, marker, config"; then
  T="$ROOT/g60"; FH="$T/home"; mkdir -p "$FH" "$T/state"
  export OMABACKUP_CONFIG="$T/cfg.json" OMABACKUP_STATE_DIR="$T/state" OMABACKUP_STOCK_DIR="$STOCK_SRC" OMABACKUP_NET=0 OMABACKUP_NOTIFY=0 OMABACKUP_SKIP_ETC=1 OMABACKUP_SKIP_TIMERS=1
  export OMABACKUP_MIN_FILES=1 OMABACKUP_MIN_ALLOWLIST=1

  fails "setup: --data-repo with no value is usage (exit 2)" env HOME="$FH" "$CLI" setup --data-repo
  [[ $(env HOME="$FH" "$CLI" setup --data-repo >/dev/null 2>&1; echo $?) == 2 ]] \
    && ok "setup: --data-repo with no value exits 2" || bad "setup: --data-repo with no value exit code"

  check "unattended setup, local only, no timers" env HOME="$FH" "$CLI" setup --data-repo "$T/data" --no-timers --yes
  [[ -f "$T/data/.omabackup" ]] && ok "marker written" || bad "no marker"
  [[ -f "$T/data/allowlist.txt" && -f "$T/data/drift-ignore.txt" && -f "$T/data/normalize.txt" ]] && ok "seeds copied" || bad "seeds missing"
  # NOT a seed. The rules file the scan actually uses is the plugin's own, and
  # a copy in the data repo is read by nothing, so laying one down told the
  # user their edits to it would matter.
  [[ -e "$T/data/.gitleaks.toml" ]] && bad "setup seeded a .gitleaks.toml the engine never reads" \
    || ok "setup lays down no .gitleaks.toml"
  eq "config dataRepo set" "$(jq -r .dataRepo "$OMABACKUP_CONFIG")" "$T/data"
  eq "config is 0600" "$(stat -c %a "$OMABACKUP_CONFIG")" "600"
  eq "phase recorded as done" "$(jq -r .setupPhase "$OMABACKUP_CONFIG")" "done"
  check "setup check passes" env HOME="$FH" "$CLI" setup check

  # A rerun must merge into the existing config, not replace it: a manual
  # edit to an unrelated key (here timer.calendar) must survive.
  jq '.timer.calendar="hourly"' "$OMABACKUP_CONFIG" > "$T/cfg.tmp" && mv "$T/cfg.tmp" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  check "setup is idempotent" env HOME="$FH" "$CLI" setup --data-repo "$T/data" --no-timers --yes
  eq "a rerun preserves an unrelated config edit (merge, not replace)" "$(jq -r .timer.calendar "$OMABACKUP_CONFIG")" "hourly"
  eq "phase still done after rerun" "$(jq -r .setupPhase "$OMABACKUP_CONFIG")" "done"

  # A --no-timers run stamps setupPhase=done without ever running the first
  # snapshot; a LATER rerun without --no-timers must still run it (whether
  # the first snapshot ran is decided by manifests/.last-run, never by
  # phase rank, since "done" is always the phase at the end of ANY run).
  [[ ! -f "$T/data/manifests/.last-run" ]] && ok "no snapshot has run yet" || bad ".last-run already present before the timers-on rerun"
  # Restore the default calendar (the earlier merge check above set it to
  # "hourly" on purpose) so this check has a known value to grep for.
  jq '.timer.calendar="daily"' "$OMABACKUP_CONFIG" > "$T/cfg.tmp" && mv "$T/cfg.tmp" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  check "setup rerun with timers on runs the first snapshot" env HOME="$FH" OMABACKUP_SKIP_TIMERS=1 "$CLI" setup --data-repo "$T/data" --yes
  [[ -f "$T/data/manifests/.last-run" ]] && ok "the first snapshot ran (manifests/.last-run exists)" || bad "manifests/.last-run missing: first snapshot never ran"
  [[ -f "$FH/.config/systemd/user/omabackup-snapshot.timer" ]] && ok "unit files landed under ~/.config/systemd/user" || bad "unit files missing"
  grep -q '^OnCalendar=daily$' "$FH/.config/systemd/user/omabackup-snapshot.timer" \
    && ok "the snapshot timer has @CALENDAR@ substituted" || bad "OnCalendar=daily not found in the snapshot timer"

  # A config that exists but is not valid JSON must not crash the wizard
  # under set -e: it must refuse cleanly, one JSON object, exit 1. Placed
  # last since it leaves the config broken.
  printf 'not json' > "$OMABACKUP_CONFIG"
  out60=$(env HOME="$FH" "$CLI" setup --data-repo "$T/data" --no-timers --yes --json 2>/dev/null); rc60=$?
  eq "an unparsable existing config refuses instead of crashing (exit 1)" "$rc60" "1"
  eq "the refusal is exactly one JSON object with ok false" "$(jq -c '[.ok]' <<<"$out60" 2>/dev/null)" "[false]"
fi

if group 61 "setup --import adopts an existing engine repo; unattended trust stays opt-in"; then
  mk_fixture g61; seed_home; rm "$FR/.omabackup"
  # Adopt a repo that has no .gitleaks.toml, so the assertion below is about
  # what import writes rather than about what mk_fixture left lying around.
  git -C "$FR" rm -q --cached .gitleaks.toml >/dev/null 2>&1
  rm -f "$FR/.gitleaks.toml"
  git -C "$FR" commit -qm "drop the inert rules copy" >/dev/null
  # mk_fixture pre-authors a config that already trusts $BARE, and a rerun
  # against an unchanged remote now keeps a trust decision the operator
  # already made. Clear it first, so the assertion below tests what it says:
  # an unattended run must never turn trust ON by itself.
  jq '.remote.trusted=false' "$OMABACKUP_CONFIG" > "$T/c61" && mv "$T/c61" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  check "import writes the marker" env HOME="$FH" "$CLI" setup --import "$FR" --no-timers --yes
  eq "marker format 1" "$(jq -r .format "$FR/.omabackup")" "1"
  # Nothing else ever commits the marker: the snapshot commits its four output
  # paths and push --confirm the four lists, so an uncommitted .omabackup meant
  # a clone of the adopted repo carried no marker and every verb refused it.
  eq "the adoption leaves the repo clean" "$(git -C "$FR" status --porcelain | grep -c . || true)" "0"
  if git -C "$FR" log -1 --name-only --format= | grep -qx '.omabackup'; then
    ok "the adoption commit names .omabackup"
  else
    bad "the marker was not committed" "$(git -C "$FR" log -1 --oneline --name-only)"
  fi
  # An INTERRUPTED adoption leaves the scratch file the atomic write used, and
  # it is untracked at the repo root: nothing ever commits it, so it was
  # reported as an uncommitted edit at every login, forever, over a file the
  # user has no way to act on.
  printf 'half a marker\n' > "$FR/.omabackup.tmpXYZ"
  eq "a leftover marker scratch file is not an uncommitted edit" \
    "$(obj status | jq -r '[.uncommitted[]] | length')" "0"
  eq "and the run has nothing to report about it either" \
    "$(ob snapshot --no-push | grep -c 'omabackup.tmpXYZ' || true)" "0"
  rm -f "$FR/.omabackup.tmpXYZ"
  # $FR's origin is $BARE, a local path: not GitHub. An unattended run
  # (--yes, no tty, no --trust-remote) must never turn trust on for it.
  eq "unattended import never turns trust ON for a non-GitHub remote" \
    "$(jq -r .remote.trusted "$OMABACKUP_CONFIG")" "false"
  [[ -e "$FR/.gitleaks.toml" ]] && bad "import wrote a .gitleaks.toml the engine never reads" \
    || ok "import lays down no .gitleaks.toml either"
  # A held lock refuses the import BEFORE the config names the repo: the
  # refusal used to come after config_write, so a busy repo silently replaced
  # a working configuration with one setup had just said it could not adopt
  # (Codex, PR 3).
  jq '.dataRepo="/somewhere/else"' "$OMABACKUP_CONFIG" > "$T/c61b" && mv "$T/c61b" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  rm -f "$FR/.omabackup"
  flock "$FR/.lock" sleep 30 &
  hold61=$!
  sleep 0.5
  l61=$(env HOME="$FH" OMABACKUP_LOCK_WAIT=1 "$CLI" setup --import "$FR" --no-timers --yes 2>&1); rc61=$?
  kill "$hold61" 2>/dev/null; wait "$hold61" 2>/dev/null || true
  eq "import refuses while the repo lock is held" "$rc61" "1"
  has "and says so" "$l61" "lock is held"
  eq "and the config still names the repo it had before" "$(jq -r .dataRepo "$OMABACKUP_CONFIG")" "/somewhere/else"
  eq "and no marker was written" "$([[ -f "$FR/.omabackup" ]] && echo yes || echo no)" "no"

  git init -q "$T/notarepo"
  fails "import refuses a directory without the lists" env HOME="$FH" "$CLI" setup --import "$T/notarepo" --no-timers --yes

  # Rerunning setup against the same non-GitHub remote with --trust-remote
  # is the only way to flip it to trusted.
  check "setup --remote --trust-remote rerun" env HOME="$FH" "$CLI" setup --data-repo "$FR" --remote "$BARE" --trust-remote --no-timers --yes
  eq "explicit --trust-remote sets remote.trusted true" "$(jq -r .remote.trusted "$OMABACKUP_CONFIG")" "true"

  # A trust decision belongs to ONE remote. A rerun against that same remote
  # keeps it, so the widget's setup card cannot silently untrust a remote the
  # operator vouched for; a different url makes the question live again.
  check "flagless rerun after --trust-remote" env HOME="$FH" "$CLI" setup --yes --no-timers
  eq "a rerun against the same remote keeps trusted true" "$(jq -r .remote.trusted "$OMABACKUP_CONFIG")" "true"
  eq "the rerun keeps the remote url too" "$(jq -r .remote.url "$OMABACKUP_CONFIG")" "$BARE"

  git init -q --bare "$T/other.git"
  out61=$(env HOME="$FH" "$CLI" setup --remote "$T/other.git" --yes --no-timers 2>&1)
  eq "a different remote url resets trusted to false" "$(jq -r .remote.trusted "$OMABACKUP_CONFIG")" "false"
  eq "the new remote url is recorded" "$(jq -r .remote.url "$OMABACKUP_CONFIG")" "$T/other.git"
  has "the reset warns that the new remote is untrusted" "$out61" "left untrusted"
fi

if group 62 "setup --remove takes back what setup put in, and leaves the data repo alone"; then
  mk_fixture g62; seed_home
  cp "$FH/.bashrc" "$T/bashrc.before"
  # shellNag=true is all setup_shell_nag needs to install the login check
  # unattended (--yes alone deliberately never opts you in).
  jq '.shellNag=true' "$OMABACKUP_CONFIG" > "$T/cfg.tmp" && mv "$T/cfg.tmp" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  check "a full setup run installs units, the CLI link and the login check" \
    env HOME="$FH" "$CLI" setup --data-repo "$FR" --yes
  if grep -qxF '# OmaBackup login check' "$FH/.bashrc"; then ok "the .bashrc comment line was added"; else bad "the .bashrc comment line is missing"; fi
  if grep -qxF 'command -v omabackup >/dev/null && omabackup health' "$FH/.bashrc"; then ok "the .bashrc check line was added"; else bad "the .bashrc check line is missing"; fi
  [[ -L "$FH/.local/bin/omabackup" ]] && ok "the CLI symlink was created" || bad "no CLI symlink"
  [[ -f "$FH/.config/systemd/user/omabackup-snapshot.timer" ]] && ok "unit files were installed" || bad "no unit files"

  out62=$(obj setup --remove --yes); rc62=$?
  eq "remove --json exits 0" "$rc62" "0"
  eq "remove --json prints exactly one JSON object" "$(jq -c '[.ok,.removed]' <<<"$out62")" "[true,true]"
  [[ ! -f "$OMABACKUP_CONFIG" ]] && ok "config removed" || bad "config still there"
  [[ ! -e "$FH/.local/bin/omabackup" ]] && ok "CLI symlink removed" || bad "CLI symlink survived --remove"
  [[ ! -e "$FH/.config/systemd/user/omabackup-snapshot.timer" ]] && ok "snapshot unit removed" || bad "snapshot unit survived --remove"
  [[ ! -e "$FH/.config/systemd/user/omabackup-selftest.timer" ]] && ok "selftest unit removed" || bad "selftest unit survived --remove"
  if grep -q 'OmaBackup login check' "$FH/.bashrc"; then bad "the .bashrc comment survived --remove"; else ok "the .bashrc comment was removed"; fi
  if grep -q 'omabackup health' "$FH/.bashrc"; then bad "the .bashrc check line survived --remove"; else ok "the .bashrc check line was removed"; fi
  if cmp -s "$T/bashrc.before" "$FH/.bashrc"; then ok ".bashrc is byte-identical to before setup"; else bad ".bashrc differs from before setup" "$(diff "$T/bashrc.before" "$FH/.bashrc" | head -5)"; fi
  [[ -f "$FR/allowlist.txt" ]] && ok "data repo untouched" || bad "data repo damaged"

  # The order matters and the tool has to say so: ~/.local/bin/omabackup is a
  # symlink INTO the plugin directory, so "omarchy plugin remove" first leaves
  # it dangling and this verb can no longer be reached at all. The README used
  # to document exactly that order.
  check "a full setup run again, to remove a second time" \
    env HOME="$FH" "$CLI" setup --data-repo "$FR" --yes
  human62=$(env HOME="$FH" "$CLI" setup --remove --yes 2>&1)
  has "the removal says which way round the two steps go" "$human62" "Run this before removing the plugin"

  # And anyone who already followed the old order is running this with the
  # plugin gone: a dangling CLI link must be cleaned up, not choked on.
  env HOME="$FH" "$CLI" setup --data-repo "$FR" --yes >/dev/null 2>&1
  ln -sfn "$T/no-such-plugin-dir/bin/omabackup" "$FH/.local/bin/omabackup"
  [[ -L "$FH/.local/bin/omabackup" && ! -e "$FH/.local/bin/omabackup" ]] \
    && ok "the CLI link is dangling, as it is after the plugin goes first" || bad "could not build a dangling link"
  eq "remove still exits 0 with the plugin directory gone" \
    "$(env HOME="$FH" "$CLI" setup --remove --yes --json >/dev/null 2>&1; echo $?)" "0"
  [[ ! -e "$FH/.local/bin/omabackup" && ! -L "$FH/.local/bin/omabackup" ]] \
    && ok "and the dangling link is gone too" || bad "the dangling link survived --remove"
fi

if group 63 "a huge drift report does not blow the jq ARG_MAX"; then
  # 2000 NEW paths of ~120 chars each is well over jq's single-argument
  # limit (MAX_ARG_STRLEN, 128 KiB) even after the WIDGET_DRIFT_LIMIT=2000
  # truncation -- health_status_json must feed the drift array to jq on
  # stdin, never as --argjson, or `status` dies with "Argument list too
  # long" and status.json ends up empty (Task 18's finding, live on a real
  # ~6900-path home).
  mk_fixture g63; seed_home; commit_baseline
  filler=$(printf 'x%.0s' $(seq 1 100))
  { i=1
    while [ "$i" -le 2000 ]; do
      # shellcheck disable=SC2088 # expected literal string, not a path to expand
      printf 'NEW %s/%04d-%s\n' "~/.config/drift-h1" "$i" "$filler"
      i=$((i+1))
    done
    printf '# drift-scan-complete\n'
  } > "$FR/manifests/drift.txt"
  date +%s > "$FR/manifests/.last-run"
  bytes=$(wc -c < "$FR/manifests/drift.txt")
  [[ "$bytes" -gt 131072 ]] && ok "fixture drift report itself exceeds 128 KiB (${bytes} bytes)" \
    || bad "fixture too small to reproduce ARG_MAX" "only ${bytes} bytes"

  s=$(obj status); rc63=$?
  eq "status exits 0 on a huge drift report" "$rc63" "0"
  eq "status emits valid JSON" "$(jq -e . <<<"$s" >/dev/null 2>&1 && echo ok || echo bad)" "ok"
  eq "drift array holds all 2000 entries" "$(jq -r '.drift | length' <<<"$s")" "2000"
  eq "drift_count matches" "$(jq -r .drift_count <<<"$s")" "2000"
  eq "not truncated: 2000 is exactly the limit, not over it" "$(jq -r .drift_truncated <<<"$s")" "false"

  eq "status.json on disk parses" \
    "$(jq -e . "$OMABACKUP_STATE_DIR/status.json" >/dev/null 2>&1 && echo ok || echo bad)" "ok"
  eq "status.json on disk has the same drift length" \
    "$(jq -r '.drift | length' "$OMABACKUP_STATE_DIR/status.json")" "2000"
fi

if group 64 "a flagless setup rerun keeps the configured data repo, remote and path shape"; then
  T="$ROOT/g64"; FH="$T/home"; mkdir -p "$FH" "$T/state"
  export OMABACKUP_CONFIG="$T/cfg.json" OMABACKUP_STATE_DIR="$T/state" OMABACKUP_STOCK_DIR="$STOCK_SRC" \
    OMABACKUP_NET=0 OMABACKUP_NOTIFY=0 OMABACKUP_SKIP_ETC=1 OMABACKUP_SKIP_TIMERS=1
  export OMABACKUP_MIN_FILES=1 OMABACKUP_MIN_ALLOWLIST=1
  TABS="$(cd "$T" && pwd -P)"
  git init -q --bare "$T/remote.git"

  # A data repo that is NOT the hardcoded default, with a remote the operator
  # explicitly trusted.
  check "setup with a non-default data repo and a trusted remote" \
    env HOME="$FH" "$CLI" setup --data-repo "$T/elsewhere" --remote "$T/remote.git" --trust-remote --no-timers --yes
  eq "dataRepo is the non-default directory" "$(jq -r .dataRepo "$OMABACKUP_CONFIG")" "$TABS/elsewhere"
  eq "remote.url recorded" "$(jq -r .remote.url "$OMABACKUP_CONFIG")" "$T/remote.git"
  eq "remote.trusted recorded" "$(jq -r .remote.trusted "$OMABACKUP_CONFIG")" "true"

  # The regression: a FLAGLESS rerun (what the widget's setup card runs) must
  # not repoint dataRepo at the hardcoded default, and must not blank the
  # remote by reading a brand-new repo's missing origin.
  check "flagless setup rerun" env HOME="$FH" "$CLI" setup --yes --no-timers
  eq "the rerun leaves dataRepo alone" "$(jq -r .dataRepo "$OMABACKUP_CONFIG")" "$TABS/elsewhere"
  eq "the rerun leaves remote.url alone" "$(jq -r .remote.url "$OMABACKUP_CONFIG")" "$T/remote.git"
  [[ ! -d "$FH/.local/share/omabackup/data" ]] && ok "the rerun created no repo at the default location" \
    || bad "the rerun created a second data repo at the default location"

  # And an explicit --trust-remote rerun flips trust on this non-GitHub
  # remote without moving anything else. (The widget's remote-unverified card
  # runs plain `setup` in a terminal, never this: see group 72.)
  check "setup --trust-remote --yes rerun" env HOME="$FH" "$CLI" setup --trust-remote --yes --no-timers
  eq "the trust rerun still keeps dataRepo" "$(jq -r .dataRepo "$OMABACKUP_CONFIG")" "$TABS/elsewhere"
  eq "the trust rerun still keeps remote.url" "$(jq -r .remote.url "$OMABACKUP_CONFIG")" "$T/remote.git"
  eq "the trust rerun flips remote.trusted" "$(jq -r .remote.trusted "$OMABACKUP_CONFIG")" "true"

  # A rerun now reaches a REAL data repo, so setup_seed must stage only what
  # it laid down. An in-progress edit to a list is the user's to commit, with
  # their own message: the wizard must never sweep it into "omabackup: initial
  # layout" behind their back.
  printf '.config/an-edit-in-progress\n' >> "$TABS/elsewhere/allowlist.txt"
  head64=$(git -C "$TABS/elsewhere" rev-parse HEAD)
  check "flagless rerun with a dirty allowlist" env HOME="$FH" "$CLI" setup --yes --no-timers
  has "the allowlist edit is still uncommitted after the rerun" \
    "$(git -C "$TABS/elsewhere" status --porcelain -- allowlist.txt)" "allowlist.txt"
  eq "the rerun created no commit touching allowlist.txt" \
    "$(git -C "$TABS/elsewhere" rev-list "$head64"..HEAD -- allowlist.txt | grep -c . || true)" "0"
  git -C "$TABS/elsewhere" checkout -q -- allowlist.txt

  # A relative --data-repo is stored resolved: the timer runs from /, so a
  # path relative to the terminal setup happened to run in means nothing.
  ( cd "$T" && env HOME="$FH" OMABACKUP_CONFIG="$T/rel.json" "$CLI" setup --data-repo relrepo --no-timers --yes ) >/dev/null 2>&1
  eq "a relative --data-repo is stored absolute" "$(jq -r .dataRepo "$T/rel.json")" "$TABS/relrepo"

  # And a hand-written relative dataRepo is refused rather than resolved
  # against whatever directory the caller happened to be in.
  jq -n '{dataRepo:"relative/data"}' > "$T/badrel.json"
  relout=$(env HOME="$FH" OMABACKUP_CONFIG="$T/badrel.json" "$CLI" status --json 2>/dev/null)
  eq "a relative dataRepo in config is refused" "$(jq -r .ok <<<"$relout")" "false"
  has "the refusal names dataRepo" "$relout" "dataRepo"
fi

if group 65 "push --confirm runs the staged secret gate"; then
  # The push button stages the repo's own edits (the lists among them) and
  # commits them. That path had NO content scan at all, so a token pasted into
  # a list was committed and then pushed by the very next line.
  mk_fixture g65; seed_home; commit_baseline
  git -C "$FR" push -q -u origin main 2>/dev/null || true

  # This group must decide on every machine, so when gitleaks is not
  # installed a fake stands in for exactly the one call it is about: the
  # staged-commit scan. Same PATH-shadow pattern as the fake curl and fake
  # systemctl elsewhere in this suite. The fake reads the real staged diff, so
  # it still distinguishes a planted token from a clean edit; everything else
  # (the version probe, the staging-tree scan) exits 0.
  GL65=""
  if ! command -v gitleaks >/dev/null; then
    mkdir -p "$T/fakebin"
    cat > "$T/fakebin/gitleaks" <<'FAKEGL'
#!/bin/sh
case " $* " in
  *" --staged "*)
    if git diff --cached 2>/dev/null | grep -q 'sk-ant-'; then
      echo "fake gitleaks: anthropic-api-key found in a staged file"
      exit 1
    fi
    ;;
esac
exit 0
FAKEGL
    chmod +x "$T/fakebin/gitleaks"
    GL65="$T/fakebin:"
    echo "  (gitleaks not installed: a fake on PATH stands in for the staged scan)"
  fi
  # Same shape as ob/obj, with the fake (if any) ahead of the real PATH.
  pj65() { env HOME="$FH" PATH="${GL65}$PATH" "$CLI" "$@" --json 2>/dev/null; }

  before65=$(git -C "$FR" rev-parse HEAD)
  key65="sk-ant-api03-$(rand_body 90)AA"
  # drift-ignore.txt, not .gitleaks.toml: gitleaks' own default config
  # allowlists paths named gitleaks.toml, so a token planted there proves
  # nothing about this gate.
  printf '\n# pasted by accident: %s\n' "$key65" >> "$FR/drift-ignore.txt"
  p65=$(pj65 push --confirm)
  eq "push --confirm refuses a secret in a watched list file" "$(jq -r .ok <<<"$p65")" "false"
  has "the refusal names the staged scan" "$p65" "staged secret scan"
  eq "nothing was committed" "$(git -C "$FR" rev-parse HEAD)" "$before65"
  eq "the staging was undone" "$(git -C "$FR" diff --cached --name-only | grep -c . || true)" "0"
  git -C "$FR" checkout -q -- drift-ignore.txt
  # And a clean list edit still commits, so the gate is not just refusing
  # everything.
  printf '\n# clean note\n' >> "$FR/drift-ignore.txt"
  eq "a clean list edit still commits" "$(pj65 push --confirm | jq -r .ok)" "true"
  eq "the clean edit is committed" "$(git -C "$FR" status --porcelain -- drift-ignore.txt | grep -c . || true)" "0"

  # `git commit` commits the INDEX, not the paths this verb staged. An edit
  # staged before the button was pressed -- snapshot output left behind by a
  # run that died between staging and committing, or a hand `git add` -- rode
  # into the list commit and was pushed with it. Same defect, same fix as the
  # snapshot pipeline: unstage first, working tree untouched.
  printf '\n# staged by hand, nothing to do with the lists\n' >> "$FR/home/.bashrc"
  git -C "$FR" add home/.bashrc
  printf '\n# another clean note\n' >> "$FR/drift-ignore.txt"
  eq "a list edit still commits with an unrelated path pre-staged" "$(pj65 push --confirm | jq -r .ok)" "true"
  eq "the commit touches only the watched list" \
    "$(git -C "$FR" show --name-only --format= HEAD | grep -c . || true)" "1"
  eq "the commit names the list, not the pre-staged path" \
    "$(git -C "$FR" show --name-only --format= HEAD | grep -c '^drift-ignore.txt$' || true)" "1"
  eq "the pre-staged edit survives as an unstaged modification" \
    "$(git -C "$FR" status --porcelain -- home/.bashrc)" " M home/.bashrc"
  git -C "$FR" checkout -q -- home/.bashrc

  # ...including on a machine with NO git identity at all. A fresh Omarchy
  # install has no ~/.gitconfig: the snapshot supplied a fallback identity and
  # this path did not, so the push button died with "Author identity unknown"
  # and left the five lists staged behind it. mk_fixture sets user.* on the
  # fixture repo, so that has to go too for the assertion to mean anything.
  git -C "$FR" config --unset user.email || true
  git -C "$FR" config --unset user.name || true
  NOID65="$T/noid-home"; mkdir -p "$NOID65"
  printf '\n# clean note, no identity\n' >> "$FR/drift-ignore.txt"
  head65=$(git -C "$FR" rev-parse HEAD)
  i65=$(env HOME="$NOID65" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PATH="${GL65}$PATH" \
    "$CLI" push --confirm --json 2>/dev/null)
  eq "push --confirm commits on a machine with no git identity" "$(jq -r .ok <<<"$i65")" "true"
  [[ "$(git -C "$FR" rev-parse HEAD)" != "$head65" ]] \
    && ok "the identity-less run made a commit" || bad "no commit: the identity fallback did not fire"
  eq "the fallback identity is the tool's own" "$(git -C "$FR" log -1 --format=%ae)" "omabackup@localhost"
  eq "nothing is left staged" "$(git -C "$FR" diff --cached --name-only | grep -c . || true)" "0"
fi

if group 66 "guards that had no proving assertion"; then
  mk_fixture g66; seed_home; commit_baseline

  # data_repo_require: the marker IS the contract for "this is our repo".
  mv "$FR/.omabackup" "$T/marker.json"
  eq "a data repo with no marker is refused" "$(obj status | jq -r .ok)" "false"
  has "the refusal names the marker" "$(obj status)" ".omabackup"
  printf '{"format":2,"createdBy":"a newer omabackup"}\n' > "$FR/.omabackup"
  eq "an unsupported data repo format is refused" "$(obj status | jq -r .ok)" "false"
  has "the refusal names the format" "$(obj status)" "format 2"
  cp "$T/marker.json" "$FR/.omabackup"

  # repo_assert_clean: a detached HEAD has no branch to commit onto.
  git -C "$FR" checkout -q --detach HEAD
  d66=$(obj snapshot --no-push)
  eq "a detached HEAD refuses the snapshot" "$(jq -r .ok <<<"$d66")" "false"
  has "the refusal names the detached HEAD" "$d66" "detached HEAD"
  git -C "$FR" checkout -q main

  # The allowlist entry-count floor: a truncated list must never be allowed to
  # shrink the backup.
  f66=$(env HOME="$FH" OMABACKUP_MIN_ALLOWLIST=99 "$CLI" snapshot --no-push --json 2>/dev/null)
  eq "an allowlist below the floor refuses the run" "$(jq -r .ok <<<"$f66")" "false"
  has "the refusal names the floor" "$f66" "floor of 99"

  # snapshot_normalize: a rule like `d` is valid sed and empties the file.
  # Backing up 0 bytes while the live file has content is silent data loss.
  cp "$FR/normalize.txt" "$T/normalize.bak"
  printf 'home/.bashrc\td\n' >> "$FR/normalize.txt"
  n66=$(obj snapshot --no-push)
  eq "a normalize rule that empties a file refuses the run" "$(jq -r .ok <<<"$n66")" "false"
  has "the refusal names the emptied file" "$n66" "normalize rule emptied"
  cp "$T/normalize.bak" "$FR/normalize.txt"

  # ...and a rule that leaves a staged .json unparsable, when it parsed before.
  if command -v python3 >/dev/null; then
    printf '{"a":1}\n' > "$FH/.config/mytool/settings.json"
    printf '.config/mytool/settings.json\n' >> "$FR/allowlist.txt"
    git -C "$FR" commit -qam "allow settings.json"
    printf 'home/.config/mytool/settings.json\ts/1/oops/\n' >> "$FR/normalize.txt"
    j66=$(obj snapshot --no-push)
    eq "a normalize rule that breaks JSON refuses the run" "$(jq -r .ok <<<"$j66")" "false"
    has "the refusal names the invalid JSON" "$j66" "invalid JSON"
    cp "$T/normalize.bak" "$FR/normalize.txt"
  else
    echo "  (python3 not installed: skipping the normalize JSON re-parse guard)"
  fi

  # remote_push_allowed: no gitleaks, no push, ever -- otherwise a machine
  # with no scanner would scan nothing and still push. Proved with a PATH
  # holding symlinks to everything the CLI needs EXCEPT gitleaks.
  mkdir -p "$T/nogl"
  for b66 in bash sh env jq git rsync flock date cat grep sed awk find mktemp stat chmod \
             mv rm cp ln cut sort tr head tail wc cksum paste readlink dirname basename \
             touch mkdir sleep comm uniq xargs diff cmp; do
    p66=$(command -v "$b66" 2>/dev/null) || continue
    ln -sf "$p66" "$T/nogl/$b66"
  done
  if [[ -e "$T/nogl/gitleaks" ]]; then bad "the no-gitleaks PATH still carries gitleaks"; else ok "the no-gitleaks PATH carries no gitleaks"; fi
  eq "the restricted PATH still runs the CLI" \
    "$(env HOME="$FH" PATH="$T/nogl" "$CLI" version)" "$MANIFEST_VERSION"
  g66=$(env HOME="$FH" PATH="$T/nogl" "$CLI" push --json 2>/dev/null)
  eq "push refuses outright when gitleaks is not installed" "$(jq -r .ok <<<"$g66")" "false"
  has "the refusal names gitleaks" "$g66" "gitleaks-missing"

  # A $STATE_DIR NOBODY CAN WRITE STILL GETS AN ANSWER OUT. status decides
  # first and writes status.json afterwards, and that write ran unguarded: under
  # `set -e` the mkdir/mktemp pair took the process down between the decision
  # and the print, so `status --json` emitted no object at all -- the one thing
  # the JSON contract forbids. The write is best effort now (the widget keeps
  # reading the file it already has, which health calls stale soon enough).
  mkdir -p "$T/ro-state"; chmod 500 "$T/ro-state"
  s66=$(env HOME="$FH" OMABACKUP_STATE_DIR="$T/ro-state" "$CLI" status --json 2>/dev/null)
  eq "status with an unwritable state dir still prints one JSON object" \
    "$(jq -sc 'length' <<<"$s66" 2>/dev/null || echo 0)" "1"
  eq "and the object is a status, not an empty line" "$(jq -r 'has("state")' <<<"$s66")" "true"
  chmod 700 "$T/ro-state"

  # The snapshot lock timeout: warn, exit 0, and commit nothing. A manual run
  # overlapping the timer must queue briefly and then step aside, never fail.
  l66=$(git -C "$FR" rev-parse HEAD)
  ( flock -x 9; sleep 5 ) 9>"$FR/.lock" &
  lockpid66=$!
  sleep 1
  lo66=$(ob snapshot --no-push); lrc66=$?
  eq "a held repo lock skips the run instead of failing" "$lrc66" "0"
  has "the skip says another run held the lock" "$lo66" "held the lock"
  eq "the skipped run committed nothing" "$(git -C "$FR" rev-parse HEAD)" "$l66"
  wait "$lockpid66" 2>/dev/null || true
fi

if group 67 "the push target itself is verified: no pushurl, and trust bound to the current origin"; then
  mk_fixture g67; seed_home

  # A pushurl is where git ACTUALLY writes. The probe read the fetch URL, so a
  # private fetch URL with a public pushurl passed every check and published
  # the config to the public one.
  git init -q --bare "$T/elsewhere.git"
  git -C "$FR" remote set-url --push origin "$T/elsewhere.git"
  s67=$(obj snapshot)
  eq "the snapshot still commits with a pushurl set" "$(jq -r .committed <<<"$s67")" "true"
  eq "but it does not push" "$(jq -r .pushed <<<"$s67")" "false"
  eq "and it names the pushurl as the reason" "$(jq -r .push_reason <<<"$s67")" "pushurl-differs"
  eq "nothing reached the fetch remote" "$(git -C "$BARE" rev-list --count --all)" "0"
  eq "nothing reached the push remote" "$(git -C "$T/elsewhere.git" rev-list --count --all)" "0"
  p67=$(obj push)
  eq "push refuses outright while a pushurl is set" "$(jq -r .ok <<<"$p67")" "false"
  has "the refusal names the pushurl" "$p67" "pushurl-differs"

  # `remote set-url --push --delete` refuses to remove the last pushurl, so
  # the documented undo is the config key itself.
  git -C "$FR" config --unset remote.origin.pushurl
  eq "removing the pushurl restores the push" "$(obj push | jq -r .ok)" "true"
  [[ $(git -C "$BARE" rev-list --count --all) -ge 1 ]] && ok "the commit reached the trusted remote" || bad "not pushed after the pushurl was removed"

  # Trust belongs to ONE remote. `git remote set-url origin` by hand left the
  # old yes attached to a remote nobody vouched for.
  git -C "$FR" remote set-url origin "$T/elsewhere.git"
  q67=$(obj push)
  eq "a repointed origin refuses the push" "$(jq -r .ok <<<"$q67")" "false"
  has "the refusal names the unverified remote" "$q67" "remote-unverified"
  jq --arg u "$T/elsewhere.git" '.remote.url=$u' "$OMABACKUP_CONFIG" > "$T/c67" \
    && mv "$T/c67" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  eq "recording the new remote makes the trust decision live again" "$(obj push | jq -r .ok)" "true"

  # The same binding on the GitHub-with-no-network branch, which trusted the
  # config flag on its own too. --no-push keeps this off the network entirely;
  # remote_probe still runs and reports.
  git -C "$FR" remote set-url origin "https://github.com/someone/omabackup-data.git"
  printf 'note\n' >> "$FH/.bashrc"
  eq "a stale trust decision does not cover a GitHub remote either" \
    "$(obj snapshot --no-push | jq -r .push_reason)" "remote-unverified"
  jq --arg u "https://github.com/someone/omabackup-data.git" '.remote.url=$u' "$OMABACKUP_CONFIG" > "$T/c67b" \
    && mv "$T/c67b" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  printf 'note2\n' >> "$FH/.bashrc"
  eq "recording that url restores trust on the offline branch" \
    "$(obj snapshot --no-push | jq -r .push_reason)" "trusted"
fi

if group 68 "restore and verify refuse a data repo whose snapshot output is uncommitted"; then
  # Restore copies from the WORKING TREE. If snapshot_sync ran and the commit
  # after it did not, home/ holds output nobody committed: restore writes it
  # back over the live machine, and verify compares the live files against
  # that same uncommitted tree and reports ok, while HEAD still names the
  # older state. Both must refuse instead.
  mk_fixture g68; seed_home; commit_baseline
  eq "a clean data repo restores" "$(obj restore --configs | jq -r .ok)" "true"
  eq "a clean data repo verifies" "$(obj verify | jq -r .ok)" "true"

  # Exactly the "snapshot_sync ran, the commit did not" signature: home/ holds
  # a faithful copy of the live file, but HEAD does not.
  printf 'export PAGER=less\n' >> "$FH/.bashrc"
  printf 'export PAGER=less\n' >> "$FR/home/.bashrc"
  before68=$(find "$FH" -type f -exec md5sum {} + 2>/dev/null | sort | md5sum)

  r68=$(obj restore --configs --apply)
  eq "restore refuses while home/ is uncommitted" "$(jq -r .ok <<<"$r68")" "false"
  has "the refusal says the last run did not commit" "$r68" "the last run did not commit"
  eq "the refusal is exactly one JSON object" "$(jq -s length <<<"$r68")" "1"
  eq "the refusal wrote nothing into \$HOME" \
    "$(find "$FH" -type f -exec md5sum {} + 2>/dev/null | sort | md5sum)" "$before68"
  [[ $(obj restore --configs --apply >/dev/null 2>&1; echo $?) == 1 ]] \
    && ok "the refusal exits 1" || bad "restore did not exit 1 on the refusal"

  v68=$(obj verify)
  eq "verify refuses the same way" "$(jq -r .ok <<<"$v68")" "false"
  has "verify names the uncommitted snapshot output" "$v68" "uncommitted changes in the data repo"
  eq "verify's refusal is one JSON object too" "$(jq -s length <<<"$v68")" "1"

  git -C "$FR" commit -qam "the snapshot output the last run never committed"
  eq "committing it lets restore run again" "$(obj restore --configs | jq -r .ok)" "true"
  eq "committing it lets verify run again" "$(obj verify | jq -r .ok)" "true"
fi

if group 69 "a remote advanced elsewhere reads as diverged, not as a retryable push failure"; then
  # The divergence check counted HEAD..@{upstream}, a remote-tracking ref a
  # rejected push does not update and nothing in the pipeline ever fetched.
  # A remote advanced on another machine therefore read as zero commits
  # behind: DIVERGED never fired, the rejection was classed retryable, and
  # the same doomed push was retried daily with no notification.
  mk_fixture g69; seed_home; commit_baseline
  git -C "$FR" push -q -u origin main

  # A second clone stands in for the other machine.
  git clone -q -b main "$BARE" "$T/other"
  git -C "$T/other" config user.email t@t; git -C "$T/other" config user.name t
  git -C "$T/other" commit -q --allow-empty -m "from the other machine"
  git -C "$T/other" push -q origin main
  remote_head69=$(git -C "$BARE" rev-parse main)

  # ...and a local commit here, so the push is a real non-fast-forward.
  printf '\nexport EDITOR=vim\n' >> "$FH/.bashrc"
  # OMABACKUP_NET=1: the fixture's origin is a local bare path, so nothing
  # here reaches the network (remote_github_slug finds no slug and no probe
  # runs), but the fetch that classifies a failed push is only attempted when
  # the tool is allowed to talk to the remote at all.
  s69=$(env HOME="$FH" OMABACKUP_NET=1 "$CLI" snapshot --json 2>/dev/null)
  eq "the snapshot still commits" "$(jq -r .committed <<<"$s69")" "true"
  eq "the push was rejected" "$(jq -r .pushed <<<"$s69")" "false"
  eq "the local commit is still there" \
    "$(git -C "$FR" status --porcelain -- home | grep -c . || true)" "0"
  st69=$(env HOME="$FH" OMABACKUP_NET=1 "$CLI" status --json 2>/dev/null)
  eq "the divergence is reported, not hidden behind a retry" "$(jq -r .diverged <<<"$st69")" "true"
  has "status states the problem in words" "$(jq -r '.problems[]' <<<"$st69")" "diverged"
  # The one-off notification path: stamped with the remote head it warned
  # about, so an unresolved divergence does not nag on every run.
  eq "the divergence notification is stamped once" \
    "$(cat "$OMABACKUP_STATE_DIR/diverged.stamp" 2>/dev/null)" "$remote_head69"

  # Resolving it clears the stamp on the next successful push.
  git -C "$FR" pull -q --rebase origin main
  printf '\nexport VISUAL=vim\n' >> "$FH/.bashrc"
  eq "the run after a rebase pushes again" \
    "$(env HOME="$FH" OMABACKUP_NET=1 "$CLI" snapshot --json 2>/dev/null | jq -r .pushed)" "true"
  [[ ! -f "$OMABACKUP_STATE_DIR/diverged.stamp" ]] \
    && ok "the divergence stamp is cleared by a successful push" || bad "the stamp outlived the divergence"
fi

if group 70 "a filename the report cannot name never renames someone else's row"; then
  # The report used to separate a note from the path with " (", and every
  # consumer recovered the path by cutting at the first one. A file literally
  # named "creds (readme" therefore produced a row whose displayed path was
  # the PREFIX "~/.config/creds" -- a deliberately never-backed-up secrets
  # directory -- and the widget's own "does the report name this path" gate
  # truncated identically, so it agreed with itself and one Allow click
  # widened the allowlist to a directory the scan had never reported. The note
  # is TAB-separated now, and a path can never contain a TAB.
  mk_fixture g70; seed_home
  mkdir -p "$FH/.config/creds"
  printf 'token\n' > "$FH/.config/creds/token.json"
  printf 'readme\n' > "$FH/.config/creds (readme"
  printf '.config/creds/**   # 2026-09-05 test: secrets, never backed up\n' >> "$FR/drift-ignore.txt"
  git -C "$FR" commit -qam "ignore the secrets directory"
  commit_baseline

  ! grep -q 'creds/token.json' "$FR/manifests/drift.txt" \
    && ok "the drift-ignored secrets directory stays out of the report" || bad "the ignored directory was reported"
  grep -qxF -- 'NEW        ~/.config/creds (readme' "$FR/manifests/drift.txt" \
    && ok "the report row carries the whole filename" || bad "the report row does not carry the whole filename" \
       "$(grep creds "$FR/manifests/drift.txt" || true)"
  # shellcheck disable=SC2088 # expected literal string, not a path to expand
  eq "status parses the row as the whole filename, not the prefix" \
    "$(obj status | jq -r '.drift[] | select(.path | test("creds")) | .path')" \
    '~/.config/creds (readme'

  # The gate: the truncated prefix is a path the report does not name.
  # shellcheck disable=SC2088 # literal "~/" prefix, not a path to expand
  a70=$(obj allow '~/.config/creds')
  eq "allow refuses the prefix the report never named" "$(jq -r .ok <<<"$a70")" "false"
  has "the refusal says the report does not name it" "$a70" "does not name that path"
  grep -qx '.config/creds' "$FR/allowlist.txt" \
    && bad "the never-backed-up secrets directory was allowlisted" || ok "the secrets directory stayed out of the allowlist"

  # ...and the row IS actionable under its real name.
  # shellcheck disable=SC2088 # literal "~/" prefix, not a path to expand
  eq "allow accepts the row under its real name" "$(obj allow '~/.config/creds (readme' | jq -r .ok)" "true"
  grep -qxF -- '.config/creds (readme' "$FR/allowlist.txt" \
    && ok "the real name was written to the allowlist" || bad "the real name is missing from the allowlist"

  # The same attack in its raw form. Changing the separator is not a fix on
  # its own: find hands the producers whatever is on disk, so a filename
  # holding a TAB (or a newline) still splits a row into a path and a note.
  # The producers refuse such a name and emit an ERROR row instead, which is a
  # fault and which no write verb can act on.
  printf 'readme\n' > "$FH/.config/creds"$'\t'"tabbed"
  printf 'readme\n' > "$FH/.config/creds"$'\n'"newlined"
  commit_baseline
  s70=$(obj status)
  eq "no actionable row claims the truncated prefix" \
    "$(jq -r '[.drift[] | select(.type != "ERROR") | select(.path == "~/.config/creds")] | length' <<<"$s70")" "0"
  eq "both unrepresentable names become ERROR rows" \
    "$(jq -r '[.drift[] | select(.type == "ERROR") | select(.path | test("cannot represent"))] | length' <<<"$s70")" "2"
  has "the ERROR row names the parent and escapes the basename" \
    "$(jq -r '.drift[] | select(.type=="ERROR") | .path' <<<"$s70")" \
    "a name the report cannot represent: ~/.config/"
  eq "an ERROR row makes the state a fault" "$(jq -r .state <<<"$s70")" "fault"
  # ...and health says what actually happened. The scan COMPLETED; one name in
  # it cannot be written as a row. "drift scan could not complete a check"
  # said the opposite of the row it was quoting, and named no way out.
  has "the problem repeats the row's own words" \
    "$(jq -r '.problems[]' <<<"$s70")" "a name the report cannot represent"
  eq "and does not claim a check failed to run" \
    "$(jq -r '[.problems[] | select(test("could not complete a check"))] | length' <<<"$s70")" "0"
  has "the problem names the two ways out" \
    "$(jq -r '.problems[]' <<<"$s70")" "rename the file, or add a drift-ignore glob"
  # shellcheck disable=SC2088 # literal "~/" prefix, not a path to expand
  a70b=$(obj allow '~/.config/creds')
  eq "allow still refuses the truncated prefix" "$(jq -r .ok <<<"$a70b")" "false"
  grep -qx '.config/creds' "$FR/allowlist.txt" \
    && bad "the secrets directory was allowlisted through the TAB row" \
    || ok "the secrets directory stayed out of the allowlist"
  commit_baseline
  [[ -e "$FR/home/.config/creds/token.json" ]] \
    && bad "the next snapshot copied the secret" || ok "the next snapshot did not copy the secret"
  if git -C "$FR" ls-files -- 'home/.config/creds/*' | grep -q .; then
    bad "the secret is tracked in the repo"
  else
    ok "the secret is not tracked in the repo"
  fi
  rm -f "$FH/.config/creds"$'\t'"tabbed" "$FH/.config/creds"$'\n'"newlined"

  # A note still round-trips, TAB-separated, through the JSON the popup reads.
  { printf 'TOOBIG     ~/.config/huge.img\t(exceeds 8m; NOT backed up)\n'
    printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"
  eq "a TAB-separated note parses into path and note" \
    "$(obj status | jq -c '[.drift[0].path,.drift[0].note]')" \
    '["~/.config/huge.img","(exceeds 8m; NOT backed up)"]'
  # A NEWLINE in a filename, deep enough to reach the full-depth walkers. They
  # ran `find -print` and read the result a line at a time, so one path split
  # into two fragments before any producer saw it: the row named
  # `~/.local/share/deep/bad` (a path that is not a file) and a second row
  # named `~/name` (a path in an entirely different part of $HOME, which the
  # widget would then happily allow). NUL-delimited end to end now, so the
  # whole name reaches _drift_report and becomes one ERROR row.
  mkdir -p "$FH/.local/share/deep"
  printf 'x\n' > "$FH/.local/share/deep/bad"$'\n'"name"
  d70=$(ob drift)
  eq "the newline name yields exactly one ERROR row" \
    "$(grep -c 'a name the report cannot represent' <<<"$d70" || true)" "1"
  eq "the ERROR row names the directory it is in" \
    "$(grep -c 'cannot represent: ~/.local/share/deep/' <<<"$d70" || true)" "1"
  eq "no row claims the truncated fragment is a file" \
    "$(grep -cx 'NEW        ~/.local/share/deep/bad' <<<"$d70" || true)" "0"
  eq "and no row names a path in someone else's part of \$HOME" \
    "$(grep -cx 'NEW        ~/name' <<<"$d70" || true)" "0"
  eq "the scan still finishes" "$(tail -1 <<<"$d70")" "# drift-scan-complete"
  rm -f "$FH/.local/share/deep/bad"$'\n'"name"

fi

if group 71 "normalize rules are data: no command execution, no writes outside the staging tree"; then
  # normalize.txt lives in the data repo, so it travels with a clone, a pull
  # and any hand edit. GNU sed's `e` command executes the pattern space as a
  # shell command, and `omabackup lint` was itself the execution site: it
  # tried every rule with a bare `sed -e`, so a clean lint of a freshly cloned
  # repo ran whatever the rule said and then printed "lists clean". The glob
  # half was expanded unquoted and unconfined too, so `../../victim.txt` had
  # sed -i rewrite a file two levels above the repo.
  mk_fixture g71; seed_home; commit_baseline
  cp "$FR/normalize.txt" "$T/normalize.bak"
  eq "the shipped normalize.example rules still pass" "$(obj lint --no-walk | jq -r .ok)" "true"

  mark71="$T/PWNED-BY-NORMALIZE"
  printf 'home/.bashrc\t1e touch %s\n' "$mark71" >> "$FR/normalize.txt"
  l71=$(obj lint --no-walk)
  eq "lint refuses a rule that would run a command" "$(jq -r .ok <<<"$l71")" "false"
  eq "the code is BADRULE" "$(jq -r '[.findings[]|select(.code=="BADRULE")]|length' <<<"$l71")" "1"
  [[ ! -e "$mark71" ]] && ok "lint never ran the command" || bad "lint executed the rule"
  s71=$(obj snapshot --no-push)
  eq "snapshot refuses the same rule" "$(jq -r .ok <<<"$s71")" "false"
  has "the refusal points at lint" "$(jq -r .error <<<"$s71")" "omabackup lint"
  [[ ! -e "$mark71" ]] && ok "snapshot never ran the command either" || bad "snapshot executed the rule"
  cp "$T/normalize.bak" "$FR/normalize.txt"

  # The glob half: $STAGE is $DATA_REPO/.staging, so "../../" is the fixture
  # root, outside the data repo entirely.
  printf 'ORIGINAL\n' > "$T/victim.txt"
  printf '../../victim.txt\ts/ORIGINAL/OWNED-BY-NORMALIZE/\n' >> "$FR/normalize.txt"
  eq "lint refuses a traversal path as BADRULE" \
    "$(obj lint --no-walk | jq -r '[.findings[]|select(.code=="BADRULE")]|length')" "1"
  eq "snapshot refuses the traversal path" "$(obj snapshot --no-push | jq -r .ok)" "false"
  eq "the file above the data repo is untouched" "$(cat "$T/victim.txt")" "ORIGINAL"
  cp "$T/normalize.bak" "$FR/normalize.txt"

  printf '/etc/passwd\ts/a/b/\n' >> "$FR/normalize.txt"
  eq "lint refuses an absolute path as BADRULE" \
    "$(obj lint --no-walk | jq -r '[.findings[]|select(.code=="BADRULE")]|length')" "1"
  cp "$T/normalize.bak" "$FR/normalize.txt"

  # A syntax error stays BADSED: the two codes say different things, and only
  # one of them means "this rule tried to leave its box".
  printf 'home/.bashrc\ts/unterminated\n' >> "$FR/normalize.txt"
  b71=$(obj lint --no-walk)
  eq "a syntax error is still BADSED" "$(jq -r '[.findings[]|select(.code=="BADSED")]|length' <<<"$b71")" "1"
  eq "and it is not reported as BADRULE" "$(jq -r '[.findings[]|select(.code=="BADRULE")]|length' <<<"$b71")" "0"
  cp "$T/normalize.bak" "$FR/normalize.txt"

  # The check AFTER the glob expands. The path half is confined before the
  # glob runs, but a glob can still land on a symlink inside the staging tree
  # whose target is somewhere else entirely, and the rule is applied to the
  # RESOLVED path, so without this check sed rewrites the file the link
  # points at. The link points into the suite's own scratch area, never /etc.
  printf 'ORIGINAL\n' > "$T/outside-target.txt"
  ln -sfn "$T/outside-target.txt" "$FH/.config/mytool/outref"
  allow '.config/mytool'
  head71=$(git -C "$FR" rev-parse HEAD)
  printf 'home/.config/mytool/outref\ts/ORIGINAL/OWNED-BY-NORMALIZE/\n' >> "$FR/normalize.txt"
  x71=$(obj snapshot --no-push)
  eq "a rule whose target resolves outside the staging tree refuses the run" "$(jq -r .ok <<<"$x71")" "false"
  has "the refusal names the confinement" "$(jq -r .error <<<"$x71")" "resolves outside the staging tree"
  eq "the file the link points at is untouched" "$(cat "$T/outside-target.txt")" "ORIGINAL"
  eq "and nothing was committed" "$(git -C "$FR" rev-parse HEAD)" "$head71"
  rm -f "$FH/.config/mytool/outref"
  cp "$T/normalize.bak" "$FR/normalize.txt"

  eq "the fixture lints clean again" "$(obj lint --no-walk | jq -r .ok)" "true"
fi

if group 72 "a GitHub remote is recognised whatever the URL spelling, and is never trusted by hand"; then
  # remote_github_slug matched four literal prefixes, so real, working GitHub
  # clone URLs read as "not GitHub": no visibility probe ever ran, health
  # reported remote-unverified, and the widget's card offered one click to
  # mark a possibly PUBLIC repo trusted. The slug also went into the API URL
  # unvalidated, so "github.com/o/r/.." probed a different repository than the
  # one git pushes to and its 404 was recorded as proof of private.
  mk_fixture g72; seed_home; commit_baseline
  jq '.remote.trusted=false' "$OMABACKUP_CONFIG" > "$T/c72" && mv "$T/c72" "$OMABACKUP_CONFIG" \
    && chmod 600 "$OMABACKUP_CONFIG"
  # A curl stand-in that RECORDS the URL it was asked for, so the assertion is
  # about the exact api.github.com path the probe built, not just the verdict.
  # nm-online is stubbed too: remote_probe waits on it before probing, and a
  # real one blocks for NET_WAIT seconds on a machine that is offline.
  mkdir -p "$T/fakebin"
  printf '#!/bin/sh\nfor a; do :; done\nprintf "%%s\\n" "$a" > "%s"\nprintf 404\n' "$T/probed" > "$T/fakebin/curl"
  printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/nm-online"
  chmod +x "$T/fakebin/curl" "$T/fakebin/nm-online"
  # probe72 URL: point origin at URL, run the pipeline far enough to probe,
  # and print "push_reason|the URL curl was asked for".
  probe72() {
    git -C "$FR" remote set-url origin "$1"
    : > "$T/probed"
    printf '# %s\n' "$1" >> "$FH/.bashrc"    # something to commit, so each run is a real one
    local r
    r=$(env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_NET=1 NET_WAIT=1 \
        "$CLI" snapshot --no-push --json 2>/dev/null | jq -r .push_reason)
    printf '%s|%s' "$r" "$(cat "$T/probed" 2>/dev/null)"
  }

  for u72 in 'http://github.com/o/r' 'https://GitHub.com/o/r' 'https://user@github.com/o/r' \
             'ssh://git@github.com:22/o/r' 'git@github.com:o/r.git'; do
    eq "$u72 is probed as o/r and reads private" "$(probe72 "$u72")" \
      "private|https://api.github.com/repos/o/r"
  done

  # Unverifiable shapes: empty slug, no probe, and never "trusted".
  for u72 in 'https://github.com/o/r/..' 'https://github.com//o/r'; do
    eq "$u72 is unverifiable and never probed" "$(probe72 "$u72")" "remote-unverified|"
  done

  # Trust is the escape hatch for a remote that cannot be checked. A GitHub
  # remote can be, so marking one trusted only ever means "skip the probe on a
  # repo that might be public".
  git -C "$FR" remote set-url origin "https://github.com/someone/omabackup-data.git"
  t72=$(obj setup --trust-remote --yes --no-timers)
  eq "setup --trust-remote refuses a GitHub origin" "$(jq -r .ok <<<"$t72")" "false"
  has "the refusal says GitHub is verified automatically" "$(jq -r .error <<<"$t72")" "verified automatically"
  eq "the refusal left remote.trusted alone" "$(jq -r .remote.trusted "$OMABACKUP_CONFIG")" "false"
  git -C "$FR" remote set-url origin "git@github.com:someone/omabackup-data.git"
  eq "the scp-like spelling is refused too" "$(obj setup --trust-remote --yes --no-timers | jq -r .ok)" "false"

  # A GitHub HOST whose URL cannot be reduced to owner/repo can never be
  # probed, and trust does not apply to a GitHub host at all. Consulting the
  # config here let a stale trusted flag push to a repo nothing had checked,
  # with reason "trusted" and the widget rendering "ready".
  git -C "$FR" remote set-url origin 'https://github.com/o/r/..'
  jq --arg u 'https://github.com/o/r/..' '.remote={url:$u, trusted:true}' "$OMABACKUP_CONFIG" > "$T/c72b" \
    && mv "$T/c72b" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  : > "$T/probed"
  printf '# stale trust\n' >> "$FH/.bashrc"
  u72=$(env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_NET=1 NET_WAIT=1 \
        "$CLI" snapshot --no-push --json 2>/dev/null)
  eq "a trusted but unverifiable GitHub remote is not push_verifiable" \
    "$(jq -r .push_verifiable <<<"$u72")" "false"
  eq "the reason is remote-unverified, not trusted" "$(jq -r .push_reason <<<"$u72")" "remote-unverified"
  eq "and no probe was made for it" "$(cat "$T/probed")" ""
  st72=$(env HOME="$FH" PATH="$T/fakebin:$PATH" "$CLI" status --json 2>/dev/null)
  eq "the widget reads remote-unverified, not ready" "$(jq -r .setup <<<"$st72")" "remote-unverified"
  eq "status.json carries the same verdict" \
    "$(jq -c '[.push_verifiable,.push_reason]' <<<"$st72")" '[false,"remote-unverified"]'

  # A fully qualified name carries the root's trailing dot, and git resolves
  # it to the same host, so it must not read as one more non-GitHub spelling.
  eq "github.com. is recognised as GitHub" "$(probe72 'https://github.com./o/r')" \
    "private|https://api.github.com/repos/o/r"
fi

if group 73 "a modes.txt record never chmods through a symlinked path"; then
  # The replay validated the RECORD (mode digits, a "home/" prefix, no ".."
  # segment, the final component not a symlink) and then resolved it through
  # whatever the freshly-rsynced tree contained. A repo shipping
  # "home/link -> ~/.ssh" plus a record for "home/link/id_ed25519" got a chmod
  # on the real key, and restore printed "completed with no failures".
  mk_fixture g73; seed_home; commit_baseline
  mkdir -p "$FH/.ssh"; printf 'PRIVATE KEY\n' > "$FH/.ssh/id_ed25519"; chmod 600 "$FH/.ssh/id_ed25519"
  ln -sfn "$FH/.ssh" "$FR/home/link"
  printf '644 home/link/id_ed25519\0' >> "$FR/modes.txt"
  git -C "$FR" add -A >/dev/null && git -C "$FR" commit -qm "a repo carrying a symlinked mode record"

  r73=$(ob restore --configs --apply)
  eq "the real key keeps mode 600" "$(stat -c %a "$FH/.ssh/id_ed25519")" "600"
  has "the restore says it refused the record" "$r73" "refusing to replay a mode through a symlinked path"
  j73=$(obj restore --configs --apply)
  eq "the refusal counts as a failure, not a clean run" "$(jq -r .ok <<<"$j73")" "false"
  eq "the key is still 600 after the JSON run too" "$(stat -c %a "$FH/.ssh/id_ed25519")" "600"

  # verify reads modes.txt the same way, against its own throwaway.
  v73=$(obj verify)
  eq "verify refuses the record instead of reading a mode from outside" "$(jq -r .ok <<<"$v73")" "false"
  has "verify names the symlinked path" "$(jq -r '.mismatched[]' <<<"$v73")" "resolves outside"

  # An ordinary record still replays: the guard must not disarm the feature.
  rm -f "$FR/home/link"
  : > "$FR/modes.txt"
  printf '600 home/.bashrc\0' >> "$FR/modes.txt"
  git -C "$FR" add -A >/dev/null && git -C "$FR" commit -qm "an ordinary mode record"
  chmod 644 "$FH/.bashrc"
  check "restore --apply runs" env HOME="$FH" "$CLI" restore --configs --apply
  eq "an ordinary record still replays" "$(stat -c %a "$FH/.bashrc")" "600"
fi

if group 74 "guard-weakening OMABACKUP_* hooks need the suite marker, and status says when one was ignored"; then
  # A `systemd --user` unit inherits the user manager's environment, so
  # OMABACKUP_MIN_FILES=1 set once in ~/.config/environment.d or .bashrc
  # reached the daily timer forever and disabled the hollow-snapshot floor
  # that stops a collapsed staging tree overwriting a good backup. These
  # hooks are honoured only alongside OMABACKUP_IN_SUITE=1.
  mk_fixture g74; seed_home
  mkdir -p "$FH/.config/many" "$T/etcroot"
  # Two kinds of entry, on purpose. 25 file entries that STAY put the allowlist
  # over the floor of 20 (that floor's own override is ignored without the
  # marker too), and one directory entry holds the 60 files that vanish below.
  # Every allowlist entry keeps resolving, so this stays a question about the
  # hollow-snapshot floor rather than about the mass-disappearance guard, which
  # would otherwise refuse first and prove nothing about the floor.
  mkdir -p "$FH/.config/keep"
  i74=1
  while [ "$i74" -le 25 ]; do
    printf 'x\n' > "$FH/.config/keep/k$i74"
    printf '?.config/keep/k%d\n' "$i74" >> "$FR/allowlist.txt"
    i74=$((i74+1))
  done
  i74=1
  while [ "$i74" -le 60 ]; do printf 'x\n' > "$FH/.config/many/f$i74"; i74=$((i74+1)); done
  printf '.config/many\n' >> "$FR/allowlist.txt"
  git -C "$FR" commit -qam "29 entries and 88 files, so the derived floors are real"
  check "baseline commits the full tree" env HOME="$FH" "$CLI" snapshot --no-push
  # Now hollow: 60 of the 88 tracked files are gone, with every allowlist entry
  # still resolving.
  rm -f "$FH/.config/many"/f*

  # OMABACKUP_ETC_ROOT is a path redirection, not a guard, so it still works
  # without the marker and keeps this machine's real /etc drop-ins out of it.
  o74=$(env -u OMABACKUP_IN_SUITE HOME="$FH" OMABACKUP_ETC_ROOT="$T/etcroot" \
        OMABACKUP_MIN_FILES=1 "$CLI" snapshot --no-push --json 2>/dev/null)
  eq "without the marker the floor override is ignored and the run refuses" "$(jq -r .ok <<<"$o74")" "false"
  has "the refusal is the hollow-snapshot floor" "$(jq -r .error <<<"$o74")" "refusing to commit a hollow snapshot"

  s74=$(env -u OMABACKUP_IN_SUITE HOME="$FH" OMABACKUP_MIN_FILES=1 "$CLI" status --json 2>/dev/null)
  eq "status reads fault while an override is set" "$(jq -r .state <<<"$s74")" "fault"
  # grep -q takes a basic regex, so the literal "*" in the message is left
  # out of the pattern rather than escaped.
  has "status names the ignored override" "$(jq -r '.problems[]' <<<"$s74")" \
    "override(s) set in the environment"
  has "and names the variable itself" "$(jq -r '.problems[]' <<<"$s74")" "OMABACKUP_MIN_FILES"
  ! grep -q 'ignoring OMABACKUP' <<<"$(obj status | jq -r '.problems[]')" \
    && ok "under the marker no override problem is reported" || bad "the suite's own hooks read as ignored"

  # The marker alone is not enough. It is one exported variable away from
  # being set by whoever set the hook, which would put the gate back where it
  # started, so the fixtures' own OMABACKUP_CONFIG redirection has to be there
  # too. A real install sets neither. Same fixture, marker kept, redirection
  # dropped, and a config where a real install would keep one.
  mkdir -p "$FH/.config/omabackup"
  cp "$OMABACKUP_CONFIG" "$FH/.config/omabackup/config.json"
  chmod 600 "$FH/.config/omabackup/config.json"
  # XDG_CONFIG_HOME is pinned inside the fixture rather than left to the
  # caller's: with OMABACKUP_CONFIG gone the CLI falls back to
  # $XDG_CONFIG_HOME/omabackup/config.json, and the developer running this
  # suite has that exported to their REAL config directory.
  m74=$(env -u OMABACKUP_CONFIG HOME="$FH" XDG_CONFIG_HOME="$FH/.config" \
        XDG_STATE_HOME="$FH/.local/state" OMABACKUP_ETC_ROOT="$T/etcroot" \
        OMABACKUP_MIN_FILES=1 "$CLI" snapshot --no-push --json 2>/dev/null)
  eq "the marker without the config redirection does not revive the hook" "$(jq -r .ok <<<"$m74")" "false"
  has "the refusal is still the hollow-snapshot floor" \
    "$(jq -r .error <<<"$m74")" "refusing to commit a hollow snapshot"
  n74=$(env -u OMABACKUP_CONFIG HOME="$FH" XDG_CONFIG_HOME="$FH/.config" \
        XDG_STATE_HOME="$FH/.local/state" OMABACKUP_MIN_FILES=1 "$CLI" status --json 2>/dev/null)
  eq "status reads fault while the marker is set alone" "$(jq -r .state <<<"$n74")" "fault"
  has "status names the stray marker" \
    "$(jq -r '.problems[]' <<<"$n74")" "OMABACKUP_IN_SUITE is set outside a test run"
  has "and still names the ignored override" "$(jq -r '.problems[]' <<<"$n74")" "OMABACKUP_MIN_FILES"
  ! grep -q 'set outside a test run' <<<"$(obj status | jq -r '.problems[]')" \
    && ok "a real fixture run reports no stray marker" || bad "the suite's own runs read as a stray marker"

  # ...and under the marker the hook still does its job, or the suite could
  # not build a fixture at all.
  eq "under the marker the floor override is honoured" "$(obj snapshot --no-push | jq -r .ok)" "true"
fi

if group 75 "the filename gate covers the credential classes data.gitignore already names"; then
  # With gitleaks absent this is the ONLY gate before `git commit`: push is
  # refused, but the secret is already in local history and in every later
  # clone of the repo. It missed .env, *.p12, *.pfx, .credentials.json and
  # Cookies* while share/data.gitignore named all five.
  mk_fixture g75; seed_home; allow '.config/mytool'; commit_baseline
  # gate75 NAME: stage a file called NAME and report whether the run survived.
  gate75() {
    printf 'x\n' > "$FH/.config/mytool/$1"
    local r
    r=$(env HOME="$FH" "$CLI" snapshot --no-push --json 2>/dev/null | jq -r .ok)
    rm -f "$FH/.config/mytool/$1"
    printf '%s' "$r"
  }
  eq "a staged .netrc is refused" "$(gate75 '.netrc')" "false"
  eq "a staged .git-credentials is refused" "$(gate75 '.git-credentials')" "false"
  eq "a staged *.p12 is refused" "$(gate75 'client.p12')" "false"
  # A filled-in template is indistinguishable from a real one by name, so the
  # .env.* class deliberately covers .env.example (README says so).
  eq "a staged .env.example is refused too" "$(gate75 '.env.example')" "false"
  # ...and the one documented exemption still holds: id_*.pub is a PUBLIC key.
  eq "a staged id_ed25519.pub is still allowed" "$(gate75 'id_ed25519.pub')" "true"
fi

if group 76 "restore refuses manifest lines that are not package or unit names"; then
  # Manifest lines are repo-controlled strings that become ARGUMENTS. A line
  # beginning with "-" in pacman-aur.txt became a yay FLAG (--noconfirm,
  # defeating that file's own "interactive, never --noconfirm" promise), and
  # systemd-user.txt was handed to `systemctl --user enable --now`
  # unvalidated, so an absolute path to a unit file in the just-restored tree
  # was enabled AND started.
  # restore --packages asks the real pacman what is installed and available.
  mk_fixture g76; real_manifests; seed_home; commit_baseline
  if ! command -v pacman >/dev/null; then
    echo "  (pacman not installed: skipping the package half)"
  else
    # The manifests are replaced with a KNOWN set, so the "well-formed
    # entries still enumerate" assertion below can name an exact result
    # instead of a count that no input could ever fail. The native list is
    # padded past the stage's 100-entry truncation floor: a minimal container
    # has fewer explicit packages than that, and the floor returns before the
    # refusals this group is about.
    seq -f 'known-native-%03g' 1 100 > "$FR/manifests/pacman-native.txt"
    printf -- '--noconfirm\naur-not-installed-zzz\n' > "$FR/manifests/pacman-aur.txt"
    printf 'ok-one.service\nok-two.timer\n/tmp/evil.service\n' > "$FR/manifests/systemd-user.txt"
    : > "$FR/manifests/systemd-user-off.txt"
    git -C "$FR" commit -qam "manifest lines that are not names"
    r76=$(obj restore --packages --services)
    eq "the run reports the refusals rather than passing them on" "$(jq -r .ok <<<"$r76")" "false"
    has "the option-shaped package line is refused" \
      "$(jq -r '.skipped[].reason' <<<"$r76")" "not a package name: --noconfirm"
    has "the absolute unit path is refused" \
      "$(jq -r '.skipped[].reason' <<<"$r76")" "not a unit name: /tmp/evil.service"
    ! grep -qF -- 'aur:--noconfirm' <<<"$(jq -r '.would_write[]' <<<"$r76")" \
      && ok "the dry run would not hand --noconfirm to yay" || bad "--noconfirm still reaches the install list"
    ! grep -qF -- 'evil.service' <<<"$(jq -r '.would_write[]' <<<"$r76")" \
      && ok "the dry run would not enable the absolute unit path" || bad "the unit path still reaches systemctl"
    # Ordinary names are untouched: the guard must not empty the stage.
    eq "the well-formed units still enumerate, and only those" \
      "$(jq -r '[.would_write[] | select(startswith("service:"))] | sort | join(",")' <<<"$r76")" \
      "service:ok-one.service,service:ok-two.timer"
    eq "the well-formed AUR package still enumerates, and only that" \
      "$(jq -r '[.would_write[] | select(startswith("aur:"))] | join(",")' <<<"$r76")" \
      "aur:aur-not-installed-zzz"
  fi
fi

if group 77 "the data repo root and .git are 0700 on every path into the repo"; then
  # .git holds every backed-up config, in full history. Nothing asserted its
  # mode: `mkdir -m 700 -p` leaves an EXISTING directory alone and
  # `setup --import` chmod'd nothing, so pointing setup at a directory that
  # was already there, or adopting a clone made under a looser umask, left all
  # of it group and world readable. home/, etc/ and manifests/ self-heal
  # through the snapshot's rsync -a; .git never does.
  mk_fixture g77; seed_home
  chmod 755 "$FR" "$FR/.git"
  eq "the repo starts 0755 on both paths" "$(stat -c %a "$FR")/$(stat -c %a "$FR/.git")" "755/755"
  check "setup --import adopts it" env HOME="$FH" "$CLI" setup --import "$FR" --no-timers --yes
  eq "import ends 0700 on both paths" "$(stat -c %a "$FR")/$(stat -c %a "$FR/.git")" "700/700"

  chmod 755 "$FR" "$FR/.git"
  check "setup --data-repo over the same directory" env HOME="$FH" "$CLI" setup --data-repo "$FR" --no-timers --yes
  eq "setup --data-repo ends 0700 on both paths" "$(stat -c %a "$FR")/$(stat -c %a "$FR/.git")" "700/700"

  # ...and a repo loosened after setup closes itself on the next verb, rather
  # than staying open until someone reruns the wizard.
  chmod 755 "$FR" "$FR/.git"
  d77=$(ob drift)
  has "an ordinary verb says it tightened the repo" "$d77" "tightening to 700"
  eq "the verb ends 0700 on both paths" "$(stat -c %a "$FR")/$(stat -c %a "$FR/.git")" "700/700"
fi

if group 78 "a nested take_lock does not release the caller's lock"; then
  # The one check in this suite that is not black box, and deliberately so:
  # the defect is that a verb calling another locking verb IN-PROCESS released
  # the outer lock, and every verb-calls-verb site today happens to fork a
  # subshell (a command substitution), so no verb can reach the nesting from
  # outside. The probe below sources lib/lock.sh, nests a take, and asks a
  # SEPARATE process whether the file is still locked -- which is exactly the
  # question the guard exists to answer.
  mk_fixture g78
  cat > "$T/lockprobe.sh" <<PROBE
#!/usr/bin/env bash
set -euo pipefail
JSON=0
. "$HERE/../lib/common.sh"
. "$HERE/../lib/lock.sh"
DATA_REPO="$FR"
held() { if flock -n "\$DATA_REPO/.lock" -c true 2>/dev/null; then echo free; else echo held; fi; }
take_lock
take_lock          # nested: a no-op, not a second open
drop_lock          # inner drop: must NOT release
held
drop_lock          # outer drop: releases
held
PROBE
  chmod +x "$T/lockprobe.sh"
  p78=$(bash "$T/lockprobe.sh")
  eq "the inner drop leaves the lock held, the outer one releases it" "$(tr '\n' ' ' <<<"$p78")" "held free "
  # ...and the ordinary single take/drop pair still behaves, so the counter
  # has not simply pinned the lock open for the life of the process.
  cat > "$T/lockprobe2.sh" <<PROBE2
#!/usr/bin/env bash
set -euo pipefail
JSON=0
. "$HERE/../lib/common.sh"
. "$HERE/../lib/lock.sh"
DATA_REPO="$FR"
take_lock
if flock -n "\$DATA_REPO/.lock" -c true 2>/dev/null; then echo free; else echo held; fi
drop_lock
if flock -n "\$DATA_REPO/.lock" -c true 2>/dev/null; then echo free; else echo held; fi
PROBE2
  eq "one take, one drop still locks then releases" "$(bash "$T/lockprobe2.sh" | tr '\n' ' ')" "held free "
  # A verb still runs end to end with the counting lock in place.
  seed_home
  check "an ordinary locking verb still runs" env HOME="$FH" "$CLI" snapshot --no-push
fi

if group 79 "a restore stage that fails still leaves one JSON object and a released lock"; then
  # cmd_restore ran its stages as `[[ do_x ]] && stage_x`, so a stage that
  # returned non-zero exited the process on the spot under errexit: no later
  # stage ran, drop_lock never ran, and restore_emit never printed the single
  # JSON object every verb promises under --json. Every stage happens to end
  # on a zero-returning statement today, which is not a property anyone can
  # rely on while adding the next one.
  mk_fixture g79; seed_home; commit_baseline
  # A known unit manifest: the snapshot fills systemd-user.txt from the running
  # user session, and a container or a CI runner has none, so "the later stage
  # still ran" needs names it can be seen enumerating.
  printf 'ok-one.service\nok-two.timer\n' > "$FR/manifests/systemd-user.txt"
  git -C "$FR" commit -qam "known unit manifest"
  # An etc/ tree the stage cannot enumerate: the stage now says so and returns
  # non-zero, which is exactly the shape the chain has to survive.
  chmod 000 "$FR/etc"
  r79=$(env HOME="$FH" "$CLI" restore --etc --services --json 2>/dev/null)
  rc79=$?
  chmod 700 "$FR/etc"
  eq "the reply is exactly one JSON object" "$(jq -s 'length' <<<"$r79" 2>/dev/null || echo 0)" "1"
  eq "the run reports the failure rather than vanishing" "$(jq -r .ok <<<"$r79")" "false"
  eq "a failing stage still exits 1, not the stage's own status" "$rc79" "1"
  has "the unreadable tree is named in skipped[]" "$(jq -r '.skipped[].reason' <<<"$r79")" "not readable"
  # ...and the stage's own non-zero return is counted, not discarded. `|| true`
  # left ok:false resting on the stage having remembered to warn on its way
  # out; a stage that fails silently must still be a failure. Counted ONCE:
  # the etc stage warns about the unreadable tree and then returns non-zero,
  # and the generic "did not complete" line used to add a second failure for
  # the same event, so one problem was reported as two.
  eq "the failing stage is counted once, not twice" \
    "$(jq -r .failures <<<"$r79")" "1"
  chmod 000 "$FR/etc"
  h79=$(env HOME="$FH" "$CLI" restore --etc --services 2>&1 || true)
  chmod 700 "$FR/etc"
  has "and the human summary says one problem, not two" "$h79" "1 problem(s) during restore"
  # The stage AFTER the failing one still ran: that is what proves the chain
  # continued rather than the process having died inside restore_stage_etc.
  eq "the later stage still ran" \
    "$(jq -r '[.would_write[] | select(startswith("service:"))] | length > 0' <<<"$r79")" "true"
  # And the lock was dropped, not held to process exit: the very next verb
  # takes the same lock with the fixture's 2-second wait.
  check "the next locking verb takes the lock straight away" env HOME="$FH" "$CLI" snapshot --no-push
fi

if group 80 "a mass disappearance halts the run, and slow erosion does not slip past it"; then
  # maxMissingPct is the "wrong \$HOME, or an unmounted partition?" guard, and
  # it counted REQUIRED entries only. Every entry in share/allowlist.example
  # carries the optional `?` marker, so on a stock install the count it looked
  # at was permanently empty and the guard could never fire: an unmounted home
  # subvolume would have committed, rsync --delete'd the backup down to
  # whatever survived, and reported it as ordinary GONE rows at "attention".
  #
  # What counts as vanished is "this repo has backed it up and $HOME no longer
  # has it", read from the repo's own history. Twenty-five entries, four files
  # each, so the tracked-file gate and the halved-file floor both stay clear of
  # the entry percentages this group is actually about.
  mk_fixture g80
  i80=1
  while [ "$i80" -le 25 ]; do
    mkdir -p "$FH/.config/full/d$i80"
    for j80 in 1 2 3 4; do printf 'setting=%d\n' "$j80" > "$FH/.config/full/d$i80/f$j80.conf"; done
    printf '?.config/full/d%d\n' "$i80" >> "$FR/allowlist.txt"
    i80=$((i80+1))
  done
  git -C "$FR" commit -qam "25 optional directory entries, 100 files"
  check "the baseline run commits all of it" env HOME="$FH" "$CLI" snapshot --no-push
  eq "the backup holds 100 files" \
    "$(git -C "$FR" ls-tree -r --name-only HEAD home/ | grep -c . || true)" "100"

  # One entry vanishing is soft: 4% is nowhere near the threshold, and the
  # guard must not have become "any GONE halts the backup".
  rm -rf "$FH/.config/full/d1"
  check "one vanished optional entry still runs" env HOME="$FH" "$CLI" snapshot --no-push
  has "it is reported as GONE, not as a refusal" "$(cat "$FR/manifests/drift.txt")" "GONE"

  # SLOW EROSION. Five more go, which with d1 is 6 of 25 (24%), just under the
  # threshold: this run is meant to pass. The previous run committed d1's
  # removal, so d1 is no longer in HEAD -- only the repo's history still knows
  # it was ever backed up, and that is exactly what stops the next run being
  # judged on this run's losses alone.
  for i80 in 2 3 4 5 6; do rm -rf "$FH/.config/full/d$i80"; done
  check "24% in one run is under the threshold and still runs" env HOME="$FH" "$CLI" snapshot --no-push
  eq "the backup is down to 76 files" \
    "$(git -C "$FR" ls-tree -r --name-only HEAD home/ | grep -c . || true)" "76"

  # Another 24% on the next run. Each run on its own is under the threshold;
  # together they are 48% of the allowlist, and the run refuses. Judged one run
  # at a time this drained the backup away a notch at a time, forever.
  for i80 in 7 8 9 10 11 12; do rm -rf "$FH/.config/full/d$i80"; done
  e80=$(obj snapshot --no-push)
  eq "the second 24% is refused, because erosion accumulates" "$(jq -r .ok <<<"$e80")" "false"
  has "the refusal is the maxMissingPct one" "$(jq -r .error <<<"$e80")" "no longer exist; refusing to run"
  eq "and it counts every entry this repo ever backed up" \
    "$(jq -r .error <<<"$e80" | grep -c '^12 of 25 allowlist entries (48%)' || true)" "1"
  has "it names the way out" "$(jq -r .error <<<"$e80")" "resolve-gone"
  eq "nothing was committed by the refused run" \
    "$(git -C "$FR" ls-tree -r --name-only HEAD home/ | grep -c . || true)" "76"

  # THE MULTI-MACHINE CASE. A clone carries the history but not
  # manifests/.last-run, which is gitignored: an earlier version keyed the
  # whole check on that file, so the first run on machine B -- the run most
  # likely to be looking at an unmounted or half-synced $HOME -- had the guard
  # switched off entirely.
  mk_fixture g80i
  mkdir -p "$FH/.config"
  i80=1
  while [ "$i80" -le 25 ]; do
    printf 'setting=%d\n' "$i80" > "$FH/.config/mach$i80.conf"
    printf '?.config/mach%d.conf\n' "$i80" >> "$FR/allowlist.txt"
    i80=$((i80+1))
  done
  git -C "$FR" commit -qam "25 optional entries"
  check "machine A takes a full backup" env HOME="$FH" "$CLI" snapshot --no-push
  git clone -q "$FR" "$T/clone"
  # etc/ is empty in this fixture and git does not track empty directories, so
  # the clone needs it back before it looks like an engine repo. A real repo
  # with any /etc reference copy in it carries the directory itself.
  mkdir -p "$T/clone/etc"
  rm -f "$FR/manifests/.last-run" 2>/dev/null || true
  [[ ! -f "$T/clone/manifests/.last-run" ]] \
    && ok "the clone carries no .last-run (it is gitignored)" || bad ".last-run travelled with the clone"
  check "machine B adopts the clone" env HOME="$FH" "$CLI" setup --import "$T/clone" --no-timers --yes
  # ...and machine B's $HOME is missing a third of it: an unmounted subvolume,
  # a half-finished sync, a wrong $HOME.
  for i80 in 1 2 3 4 5 6 7 8 9; do rm -f "$FH/.config/mach$i80.conf"; done
  m80=$(obj snapshot --no-push)
  eq "the first run on the second machine refuses" "$(jq -r .ok <<<"$m80")" "false"
  has "with the maxMissingPct refusal" "$(jq -r .error <<<"$m80")" "no longer exist; refusing to run"
  eq "counting what the clone's own history says was backed up" \
    "$(jq -r .error <<<"$m80" | grep -c '^9 of 25 allowlist entries (36%)' || true)" "1"
  eq "and the clone's backup is untouched" \
    "$(git -C "$T/clone" ls-tree -r --name-only HEAD home/ | grep -c . || true)" "25"

  # THE SPARSE FIRST RUN, the other half of the same rule. No backup exists
  # yet, so nothing can have disappeared: share/allowlist.example seeds 23
  # optional Omarchy paths and a fresh install legitimately has few of them.
  mk_fixture g80b
  cp "$HERE/../share/allowlist.example" "$FR/allowlist.txt"
  mkdir -p "$FH/.config"; printf 'x\n' > "$FH/.bashrc"
  printf '.bashrc\n' >> "$FR/allowlist.txt"
  git -C "$FR" commit -qam "the shipped seed list on a sparse fresh home"
  check "a first run on a sparse fresh home is not refused" env HOME="$FH" "$CLI" snapshot --no-push
  eq "the unresolved seed entries are recorded as GONE" \
    "$(( $(grep -c '^GONE' "$FR/manifests/drift.txt" || true) > 5 ))" "1"
  check "and the run after it is not refused either" env HOME="$FH" "$CLI" snapshot --no-push

  # GLOB ENTRIES, which is most of what a real allowlist is made of. "Has this
  # repo ever backed it up" was asked of git one entry at a time, as a literal
  # path (`cat-file -e HEAD:home/<entry>`, then a `:(literal)` rev-list), and
  # neither can match `.config/g1/*.conf` -- one entry covering four real
  # files. So every glob entry answered "never backed up", could not count as
  # vanished, and the guard was blind to the entries covering the most files.
  # Measured: 20 of 25 glob entries removed was counted as 0 vanished, the run
  # committed, and rsync --delete took the backup from 100 files to 20.
  mk_fixture g80g
  i80=1
  while [ "$i80" -le 25 ]; do
    mkdir -p "$FH/.config/g$i80"
    for j80 in 1 2 3 4; do printf 'setting=%d\n' "$j80" > "$FH/.config/g$i80/f$j80.conf"; done
    printf '?.config/g%d/*.conf\n' "$i80" >> "$FR/allowlist.txt"
    i80=$((i80+1))
  done
  git -C "$FR" commit -qam "25 optional glob entries, 100 files"
  check "the baseline run commits every glob entry" env HOME="$FH" "$CLI" snapshot --no-push
  eq "the backup holds 100 files" \
    "$(git -C "$FR" ls-tree -r --name-only HEAD home/ | grep -c . || true)" "100"
  i80=1
  while [ "$i80" -le 20 ]; do rm -rf "$FH/.config/g$i80"; i80=$((i80+1)); done
  g80=$(obj snapshot --no-push)
  eq "20 of 25 glob entries vanishing refuses the run" "$(jq -r .ok <<<"$g80")" "false"
  has "with the maxMissingPct refusal" "$(jq -r .error <<<"$g80")" "no longer exist; refusing to run"
  eq "and the count includes the glob entries" \
    "$(jq -r .error <<<"$g80" | grep -c '^20 of 25 allowlist entries (80%)' || true)" "1"
  eq "the backup the run would have drained is untouched" \
    "$(git -C "$FR" ls-tree -r --name-only HEAD home/ | grep -c . || true)" "100"

  # RENAMED ENTRIES, which is how Omarchy actually moves config around. The
  # history listing asked git for `--diff-filter=A`, and rename detection is on
  # by default (diff.renames, git 2.9 onward): a path that entered the repo by
  # a detected rename is reported as R, never as A. So the moment an entry was
  # renamed it dropped out of "ever backed up", answered "this repo never held
  # it", and the guard went silent on the very files it was tracking.
  mk_fixture g80m
  i80=1
  while [ "$i80" -le 25 ]; do
    mkdir -p "$FH/.config/ren$i80"
    for j80 in 1 2 3 4; do printf 'setting=%d-%d\n' "$i80" "$j80" > "$FH/.config/ren$i80/f$j80.conf"; done
    printf '?.config/ren%d\n' "$i80" >> "$FR/allowlist.txt"
    i80=$((i80+1))
  done
  git -C "$FR" commit -qam "25 optional directory entries, 100 files"
  check "the baseline run before the rename commits all of it" env HOME="$FH" "$CLI" snapshot --no-push
  # The rename, followed by the allowlist edit that follows it: one commit that
  # deletes 100 paths and adds the same 100 bodies under new names, which is
  # precisely what git reports as a rename.
  i80=1
  while [ "$i80" -le 25 ]; do mv "$FH/.config/ren$i80" "$FH/.config/moved$i80"; i80=$((i80+1)); done
  sed -i 's|^?\.config/ren|?.config/moved|' "$FR/allowlist.txt"
  git -C "$FR" commit -qam "the entries move"
  check "the run after the rename commits the new paths" env HOME="$FH" "$CLI" snapshot --no-push
  eq "the backup still holds 100 files" \
    "$(git -C "$FR" ls-tree -r --name-only HEAD home/ | grep -c . || true)" "100"
  # The premise, stated out loud: if git ever stops detecting these as renames
  # this assertion is the one that says the group is no longer testing it.
  eq "and git did record that commit as renames" \
    "$(( $(git -C "$FR" show --diff-filter=R --name-only --format= HEAD | grep -c . || true) > 0 ))" "1"
  i80=1
  while [ "$i80" -le 20 ]; do rm -rf "$FH/.config/moved$i80"; i80=$((i80+1)); done
  r80=$(obj snapshot --no-push)
  eq "20 of 25 renamed entries vanishing refuses the run" "$(jq -r .ok <<<"$r80")" "false"
  has "with the maxMissingPct refusal" "$(jq -r .error <<<"$r80")" "no longer exist; refusing to run"
  eq "counting the paths that entered the repo by a rename" \
    "$(jq -r .error <<<"$r80" | grep -c '^20 of 25 allowlist entries (80%)' || true)" "1"
  eq "the backup the rename would have drained is untouched" \
    "$(git -C "$FR" ls-tree -r --name-only HEAD home/ | grep -c . || true)" "100"

  # THE LISTING ITSELF, both ways round. A `git log` that cannot walk the
  # history disappeared into a process substitution: the set came back empty,
  # every vanished entry answered "never backed up", and the guard fell silent
  # on the one run that could prove nothing. And the listing was taken before
  # anything asked for it, so a healthy run paid for the whole log every day
  # and would now die over a question it never had to ask.
  mk_fixture g80h
  i80=1
  while [ "$i80" -le 25 ]; do
    mkdir -p "$FH/.config/hist$i80"
    for j80 in 1 2 3 4; do printf 'setting=%d-%d\n' "$i80" "$j80" > "$FH/.config/hist$i80/f$j80.conf"; done
    printf '?.config/hist%d\n' "$i80" >> "$FR/allowlist.txt"
    i80=$((i80+1))
  done
  git -C "$FR" commit -qam "25 optional directory entries, 100 files"
  check "the baseline run commits all of it" env HOME="$FH" "$CLI" snapshot --no-push
  # Break the walk without touching HEAD: the fixture's root commit object is
  # not needed to read HEAD's tree, but `git log` has to walk through it.
  root80=$(git -C "$FR" rev-list --max-parents=0 HEAD)
  rm -f "$FR/.git/objects/${root80:0:2}/${root80:2}"
  fails "the history really is unreadable now" git -C "$FR" log --format= --name-only
  check "a healthy run never asks the history anything" env HOME="$FH" "$CLI" snapshot --no-push
  rm -rf "$FH/.config/hist1"
  h80=$(obj snapshot --no-push)
  eq "but one vanished entry over an unreadable history refuses" "$(jq -r .ok <<<"$h80")" "false"
  has "and the refusal says what it could not read" "$(jq -r .error <<<"$h80")" "cannot read the repo history"
  eq "nothing was committed by the run that could not prove anything" \
    "$(git -C "$FR" ls-tree -r --name-only HEAD home/ | grep -c . || true)" "100"
fi
if group 81 "a pacman whose wording changed is an error, never a clean /etc scan"; then
  # Both /etc sections read pacman's prose, not an API: the field name
  # `Backup Files` in -Qii and the literal `error: No package owns <path>` on
  # -Qqo's stderr. A reword makes both parses empty, which was byte-identical
  # to "nothing drifted" -- while the # drift-scan-complete sentinel still
  # printed, so the pipeline committed and every dashboard read clean. That is
  # the exact fail-open this tool exists to prevent.
  mk_fixture g81; seed_home
  mkdir -p "$T/etcroot/sysctl.d"
  printf 'vm.swappiness=10\n' > "$T/etcroot/sysctl.d/99-omabackup-probe.conf"
  mkdir -p "$T/fakebin"

  # A pacman that works, in the wording the parsers were written against.
  # /etc/fstab is answered as owned on -Qqo: the -Qii branch now confirms
  # ownership before trusting a modified-backup-file candidate (PR 6), and
  # /etc/fstab is a real file every one of these test machines has. Real
  # pacman exits 0 when every queried file is owned and only non-zero when
  # at least one is not (Codex, PR 6 round 2: an all-owned batch that still
  # exited non-zero with empty stderr is exactly the silent failure the
  # ownership check must not mistake for "everyone is owned").
  cat > "$T/fakebin/pacman" <<'FAKEOK'
#!/bin/sh
case "$1" in
  -Qii) printf 'Name            : fakepkg\nBackup Files    :\n/etc/fstab [modified]\n'; exit 0 ;;
  -Qqo) shift; [ "$1" = "--" ] && shift
        rc=0
        for f in "$@"; do
          case "$f" in
            /etc/fstab) : ;;
            *) echo "error: No package owns $f" >&2; rc=1 ;;
          esac
        done; exit "$rc" ;;
esac
exit 0
FAKEOK
  chmod +x "$T/fakebin/pacman"
  d81() { env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_SKIP_ETC=0 OMABACKUP_ETC_ROOT="$T/etcroot" "$CLI" drift; }
  ok81=$(d81)
  has "the expected wording still reports a modified backup file" "$ok81" "NEW        /etc/fstab"
  has "the expected wording still reports an unowned drop-in" "$ok81" "/etc/sysctl.d/99-omabackup-probe.conf"
  eq "and says nothing about being unable to parse" "$(grep -c '# ERROR' <<<"$ok81" || true)" "0"

  # The same machine after pacman rewords both messages. Nothing here is
  # broken from pacman's point of view: it exits the same way and prints the
  # same information, in different words.
  cat > "$T/fakebin/pacman" <<'FAKEDE'
#!/bin/sh
case "$1" in
  -Qii) printf 'Name             : fakepkg\nSicherungsdateien :\n/etc/fstab [geaendert]\n'; exit 0 ;;
  -Qqo) shift; for f in "$@"; do echo "Fehler: kein Paket besitzt $f" >&2; done; exit 1 ;;
esac
exit 0
FAKEDE
  chmod +x "$T/fakebin/pacman"
  bad81=$(d81)
  has "a reworded -Qii is an explicit parse error" "$bad81" "cannot parse pacman backup-file output"
  has "a reworded -Qqo stderr is an explicit parse error" "$bad81" "cannot parse pacman ownership output"
  eq "the scan still finishes, so the error is carried, not lost" \
    "$(tail -1 <<<"$bad81")" "# drift-scan-complete"
  eq "neither section reported zero drift" "$(grep -c '# clean:' <<<"$bad81" || true)" "0"
  # The two ERROR rows are drift items like any other, so they reach status.
  ej81=$(env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_SKIP_ETC=0 OMABACKUP_ETC_ROOT="$T/etcroot" "$CLI" drift --json 2>/dev/null)
  eq "both parse failures parse back out as ERROR items" \
    "$(jq -r '[.items[] | select(.type=="ERROR")] | length' <<<"$ej81")" "2"
fi

if group 82 "an ERROR row in the drift report is a fault, and the stock tree follows OMARCHY_PATH"; then
  # An ERROR row means a detector did not run. It was counted as one more
  # drift item, so "the biggest detector is switched off" rendered exactly
  # like one unbacked file, at severity attention, in a list people skim.
  mk_fixture g82; seed_home; commit_baseline
  git -C "$FR" push -q -u origin main 2>/dev/null || true
  { printf 'NEW        ~/.config/appz/z.toml\n'
    printf '# ERROR: omarchy stock config tree not found at /usr/share/omarchy/config\n'
    printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"
  date +%s > "$FR/manifests/.last-run"
  s82=$(obj status)
  eq "an ERROR row makes the state a fault, not attention" "$(jq -r .state <<<"$s82")" "fault"
  has "the problem names the check that did not run" "$(jq -r '.problems[]' <<<"$s82")" \
    "omarchy stock config tree not found"
  has "the problem says a check could not complete" "$(jq -r '.problems[]' <<<"$s82")" \
    "drift scan could not complete a check"
  eq "the row is still an ERROR item in the drift list" \
    "$(jq -r '[.drift[] | select(.type=="ERROR")] | length' <<<"$s82")" "1"
  # Control: the same report without the ERROR row is attention, so this is
  # not simply "any drift is a fault now".
  { printf 'NEW        ~/.config/appz/z.toml\n'; printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"
  eq "ordinary drift alone is still attention" "$(obj status | jq -r .state)" "attention"

  # STOCK_DIR followed a hardcoded /usr/share/omarchy while the shell itself
  # resolves the same tree from OMARCHY_PATH, so a moved tree (or an
  # `omarchy dev link` checkout) broke the engine and not the shell -- and
  # section 1, the single biggest detector, went quiet behind one ERROR row.
  o82=$(env -u OMABACKUP_STOCK_DIR HOME="$FH" OMARCHY_PATH="$STOCK" "$CLI" drift)
  eq "OMARCHY_PATH is enough to find the stock tree" "$(grep -c 'stock config tree not found' <<<"$o82" || true)" "0"
  n82=$(env -u OMABACKUP_STOCK_DIR HOME="$FH" OMARCHY_PATH="$T/no-such-omarchy" "$CLI" drift)
  has "and a bad OMARCHY_PATH is reported against that path, not the hardcoded one" \
    "$n82" "$T/no-such-omarchy/config"

  # A stock tree pointed somewhere other than the installed one changes what
  # drift MEANS, so status says which tree the answers came from -- outside a
  # test run, whose whole point is a stock stand-in.
  r82=$(env -u OMABACKUP_IN_SUITE HOME="$FH" "$CLI" status --json 2>/dev/null)
  has "a redirected stock tree is reported" "$(jq -r '.problems[]' <<<"$r82")" \
    "not the installed Omarchy tree"
  has "naming the tree it used" "$(jq -r '.problems[]' <<<"$r82")" "$STOCK"
  eq "and the suite's own runs say nothing of the kind" \
    "$(obj status | jq -r '[.problems[] | select(contains("installed Omarchy tree"))] | length')" "0"
fi

if group 83 "status.json's push_verifiable is the push gate's answer, not git's arithmetic"; then
  # One key, two meanings, in the same run: lib/remote.sh set it to "the
  # remote is proven private or explicitly trusted (and gitleaks is here)",
  # lib/health.sh set it to "git rev-list --count parsed a number". So a
  # snapshot printed push_verifiable:false on stdout and wrote
  # push_verifiable:true into status.json, and the first person to wire the
  # widget's push button to the field would have got the wrong one.
  mk_fixture g83; seed_home
  jq '.remote.trusted=false' "$OMABACKUP_CONFIG" > "$T/c" && mv "$T/c" "$OMABACKUP_CONFIG"
  check "a snapshot against an unverified remote still commits" env HOME="$FH" "$CLI" snapshot
  git -C "$FR" push -q -u origin main 2>/dev/null || true    # upstream readable, gate still shut
  s83=$(obj status)
  eq "the upstream count is readable" "$(jq -r .upstream_readable <<<"$s83")" "true"
  eq "...and push_verifiable is still false, because the remote is unverified" \
    "$(jq -r .push_verifiable <<<"$s83")" "false"
  eq "the reason is the gate's own" "$(jq -r .push_reason <<<"$s83")" "remote-unverified"
  eq "status.json on disk says the same" \
    "$(jq -r .push_verifiable "$OMABACKUP_STATE_DIR/status.json")" "false"

  # Trust the remote and the same two fields separate the other way.
  jq '.remote.trusted=true' "$OMABACKUP_CONFIG" > "$T/c" && mv "$T/c" "$OMABACKUP_CONFIG"
  check "a snapshot against a trusted remote runs" env HOME="$FH" "$CLI" snapshot
  eq "the gate now says verifiable" "$(obj status | jq -r .push_verifiable)" "true"
  eq "with the gate's reason" "$(obj status | jq -r .push_reason)" "trusted"

  # A verdict is an answer ABOUT ONE URL. Point origin somewhere else and the
  # recorded yes must not carry over, the same rule remote_trust_ok applies.
  git -C "$FR" remote set-url origin "$T/elsewhere.git"
  eq "a verdict recorded for another origin does not count" \
    "$(obj status | jq -r .push_verifiable)" "false"
  eq "and says so" "$(obj status | jq -r .push_reason)" "unprobed"

  # A verdict has an age, and an old yes is not a yes: a repository can be made
  # public between one run and the next, and nothing re-probes on a widget
  # refresh. The `at` field was written and never read.
  git -C "$FR" remote set-url origin "$BARE"
  check "a fresh snapshot records a fresh verdict" env HOME="$FH" "$CLI" snapshot
  eq "which reads as verifiable" "$(obj status | jq -r .push_verifiable)" "true"
  jq --argjson t "$(( $(date +%s) - 40 * 86400 ))" '.at=$t' \
    "$OMABACKUP_STATE_DIR/push-verdict.json" > "$T/v" && mv "$T/v" "$OMABACKUP_STATE_DIR/push-verdict.json"
  eq "a verdict older than staleDays stops counting" "$(obj status | jq -r .push_verifiable)" "false"
  eq "and says why" "$(obj status | jq -r .push_reason)" "stale"
  # A verdict with no usable timestamp is no verdict at all.
  jq '.at="soon"' "$OMABACKUP_STATE_DIR/push-verdict.json" > "$T/v" && mv "$T/v" "$OMABACKUP_STATE_DIR/push-verdict.json"
  eq "an unusable timestamp reads as stale too" "$(obj status | jq -r .push_reason)" "stale"

  # The two objects status can emit must still carry the same key set.
  eq "not-configured status carries the same keys as a configured one" \
    "$(OMABACKUP_CONFIG=/nonexistent obj status | jq -S 'keys')" "$(obj status | jq -S 'keys')"

  # THE RECORDED VERDICT IS THE GATE'S, NOT THE PROBE'S. Two paths refuse a
  # push without ever calling remote_push_if_ahead -- the popup's Push button
  # when the gate says no, and `snapshot --no-push` -- and both used to leave
  # the probe's "trusted" answer standing in push-verdict.json. On a machine
  # with no gitleaks that is a widget reading push_verifiable:true over a repo
  # whose commits can never leave, which is the exact confusion this group
  # exists to prevent.
  mk_fixture g83b; seed_home
  # A PATH mirroring this machine's, minus gitleaks. Mirrored rather than
  # hand-listed because a whole snapshot runs under it, not just one verb.
  mkdir -p "$T/nogl"; IFS=: read -ra pdirs83 <<<"$PATH"
  for d83 in ${pdirs83[@]+"${pdirs83[@]}"}; do
    [[ -d "$d83" ]] || continue
    for f83 in "$d83"/*; do
      b83=${f83##*/}
      [[ "$b83" == gitleaks ]] && continue
      [[ -x "$f83" && ! -d "$f83" ]] || continue
      [[ -e "$T/nogl/$b83" ]] || ln -s "$f83" "$T/nogl/$b83"
    done
  done
  if [[ -e "$T/nogl/gitleaks" ]]; then bad "the no-gitleaks PATH still carries gitleaks"; else ok "the no-gitleaks PATH carries no gitleaks" ; fi
  check "a snapshot with gitleaks present records a verdict" env HOME="$FH" "$CLI" snapshot
  eq "which reads as verifiable, because the remote is trusted" \
    "$(obj status | jq -r .push_verifiable)" "true"

  # (a) the popup's Push button, refused by the gate.
  printf '# an edit for the push button to carry\n' >> "$FR/allowlist.txt"
  p83=$(env HOME="$FH" PATH="$T/nogl" "$CLI" push --confirm --json 2>/dev/null)
  eq "push refuses when gitleaks is missing" "$(jq -r .ok <<<"$p83")" "false"
  eq "the refusal leaves push_verifiable false" "$(obj status | jq -r .push_verifiable)" "false"
  eq "with the gate's own reason, not the probe's" "$(obj status | jq -r .push_reason)" "gitleaks-missing"
  git -C "$FR" checkout -q -- allowlist.txt

  # (b) snapshot --no-push, which skips the push without asking the gate.
  check "a fresh snapshot with gitleaks records a verifiable verdict again" env HOME="$FH" "$CLI" snapshot
  eq "the verdict is verifiable before the --no-push run" "$(obj status | jq -r .push_verifiable)" "true"
  printf 'later\n' >> "$FH/.bashrc"
  n83=$(env HOME="$FH" PATH="$T/nogl" "$CLI" snapshot --no-push --json 2>/dev/null)
  eq "snapshot --no-push still runs without gitleaks" "$(jq -r .ok <<<"$n83")" "true"
  eq "and its own JSON says the gate is shut" "$(jq -r .push_verifiable <<<"$n83")" "false"
  eq "the recorded verdict says the same" "$(obj status | jq -r .push_verifiable)" "false"
  eq "and names gitleaks, not the remote" "$(obj status | jq -r .push_reason)" "gitleaks-missing"
fi

if group 84 "the wizard's own first snapshot uses the remote the wizard just configured"; then
  # CFG_* is a cache of the config file. setup_remote wrote the new remote to
  # disk and left the cache alone, and setup_first_snapshot runs cmd_snapshot
  # IN-PROCESS -- so the wizard's own snapshot probed with the pre-setup remote
  # values and the status.json setup itself wrote said remote-unverified,
  # immediately after --trust-remote. The widget then showed the "review the
  # remote" card until the next status run. Untested until now because every
  # setup group passes --no-timers, which skips the first snapshot entirely.
  mk_fixture g84; seed_home
  jq '.remote={url:"",trusted:false}' "$OMABACKUP_CONFIG" > "$T/c" && mv "$T/c" "$OMABACKUP_CONFIG"
  git -C "$FR" remote remove origin
  # No --no-timers: the first snapshot has to run. OMABACKUP_SKIP_TIMERS=1 (set
  # by mk_fixture) keeps systemctl out of it.
  check "setup wires the remote and trusts it" \
    env HOME="$FH" "$CLI" setup --remote "$BARE" --trust-remote --yes
  eq "the config records the trust" "$(jq -r '.remote.trusted' "$OMABACKUP_CONFIG")" "true"
  eq "the wizard's own status.json says setup is ready" \
    "$(jq -r .setup "$OMABACKUP_STATE_DIR/status.json")" "ready"
  eq "and the push gate agrees, in the same file" \
    "$(jq -r .push_verifiable "$OMABACKUP_STATE_DIR/status.json")" "true"
  # A later status run must not be the first thing to notice: it should agree
  # with what the wizard already wrote.
  eq "a later status agrees" "$(obj status | jq -r .setup)" "ready"
fi

if group 85 "timer.calendar and timer.jitter are validated, substituted safely, and compared with the unit"; then
  # These two were the only config values that reached a FILE unchecked. They
  # went into the unit templates through `sed s|@CALENDAR@|<value>|`, so a `|`
  # in the value terminated the s command and the rest became more sed script:
  # `daily|; s|ExecStart=.*|ExecStart=/bin/sh -c "curl ..."|` rewrites the unit
  # that runs daily as the user. An innocent typo corrupted it just as well.
  mk_fixture g85; seed_home
  # timer.calendar and timer.jitter are validated against systemd's own
  # grammar in setup now, not in config_load: status (and every other verb)
  # would otherwise fork systemd-analyze on every run for a pair of values
  # only setup ever consumes. A value systemd cannot parse is still refused,
  # just at the point it is actually about to reach a unit file.
  jq '.timer={calendar:"daily|; s|ExecStart=.*|ExecStart=/bin/sh -c evil|", jitter:"30m"}' \
    "$OMABACKUP_CONFIG" > "$T/bad.json"
  b85=$(OMABACKUP_CONFIG=$T/bad.json obj setup --yes)
  eq "a calendar carrying a sed delimiter is refused at setup" "$(jq -r .ok <<<"$b85")" "false"
  has "the refusal names the key" "$(jq -r .error <<<"$b85")" "timer.calendar"
  jq '.timer={calendar:"daily", jitter:"every other tuesday"}' "$OMABACKUP_CONFIG" > "$T/bad2.json"
  eq "a jitter systemd cannot parse is refused too" \
    "$(OMABACKUP_CONFIG=$T/bad2.json obj setup --yes | jq -r .ok)" "false"
  has "the refusal names that key" \
    "$(OMABACKUP_CONFIG=$T/bad2.json obj setup --yes | jq -r .error)" "timer.jitter"
  # A backslash is not systemd syntax, but it IS awk syntax: `awk -v x=VALUE`
  # runs the value through awk's escape processing, so `daily\nExecStart=...`
  # arrived in the unit as a real newline and a second directive -- and the
  # systemd-analyze check that would have caught the value never ran, because
  # it only warns when the tool is absent. The character class is
  # unconditional for exactly that reason.
  jq '.timer={calendar:"daily\\nExecStart=/bin/sh -c evil", jitter:"30m"}' \
    "$OMABACKUP_CONFIG" > "$T/bs.json"
  bs85=$(OMABACKUP_CONFIG=$T/bs.json obj status)
  eq "a calendar carrying a backslash is refused at load" "$(jq -r .ok <<<"$bs85")" "false"
  has "the refusal names the class" "$(jq -r .error <<<"$bs85")" "must not contain a backslash"
  jq '.timer={calendar:"daily", jitter:"30m%h"}' "$OMABACKUP_CONFIG" > "$T/pct.json"
  eq "a percent sign (a systemd unit specifier) is refused too" \
    "$(OMABACKUP_CONFIG=$T/pct.json obj status | jq -r .ok)" "false"

  # A perfectly ordinary calendar with spaces and asterisks still loads, and
  # lands in the unit verbatim: the substitution must not be doing anything
  # clever with the value.
  jq '.timer={calendar:"Mon *-*-* 04:00:00", jitter:"45m"}' "$OMABACKUP_CONFIG" > "$T/c" && mv "$T/c" "$OMABACKUP_CONFIG"
  check "a real OnCalendar expression loads" env HOME="$FH" "$CLI" status
  check "setup writes the units" env HOME="$FH" "$CLI" setup --data-repo "$FR" --yes
  eq "the calendar reaches the unit verbatim" \
    "$(grep '^OnCalendar=' "$FH/.config/systemd/user/omabackup-snapshot.timer")" "OnCalendar=Mon *-*-* 04:00:00"
  eq "and so does the jitter" \
    "$(grep '^RandomizedDelaySec=' "$FH/.config/systemd/user/omabackup-snapshot.timer")" "RandomizedDelaySec=45m"
  eq "an installed unit matching the config is not a problem" \
    "$(obj status | jq -r '[.problems[] | select(contains("installed snapshot timer"))] | length')" "0"
  # setup check is the doctor for timer.calendar and timer.jitter now: a good
  # value on a machine with systemd-analyze says so, in the same three-shape
  # line every other check uses.
  ok85=$(env HOME="$FH" "$CLI" setup check)
  has "a good calendar is an ok line" "$ok85" "^ok    timer.calendar$"
  has "a good jitter is an ok line" "$ok85" "^ok    timer.jitter$"

  # Editing config.json has no effect until setup is rerun, so the two can
  # disagree indefinitely with nothing saying so.
  jq '.timer.calendar="weekly"' "$OMABACKUP_CONFIG" > "$T/c" && mv "$T/c" "$OMABACKUP_CONFIG"
  m85=$(obj status)
  has "a config the installed unit does not match is reported" \
    "$(jq -r '.problems[]' <<<"$m85")" "installed snapshot timer"
  has "the problem quotes the unit's value" "$(jq -r '.problems[]' <<<"$m85")" "04:00:00"
  has "and the config's" "$(jq -r '.problems[]' <<<"$m85")" "config says 'weekly'"
  has "and names the fix" "$(jq -r '.problems[]' <<<"$m85")" "omabackup setup"
  eq "the mismatch is a fault, not a footnote" "$(jq -r .state <<<"$m85")" "fault"

  # ...and a machine with no systemd-analyze says so as a FAIL line from the
  # doctor, not as a status-time fault: status itself no longer forks
  # systemd-analyze at all, so it has nothing to say about it either way.
  # `setup` fails closed the same way: neither value can be proved valid
  # without systemd-analyze, so setup_units now refuses to write a unit file
  # it cannot validate, rather than warning and writing one anyway. A PATH of
  # symlinks to everything in /usr/bin except systemd-analyze: `command -v`
  # has to find nothing at all, so shadowing it with a stub would not do.
  nsa85="$T/nosdbin"; mkdir -p "$nsa85"
  cp -as /usr/bin/. "$nsa85"/ 2>/dev/null || true
  rm -f "$nsa85/systemd-analyze"
  if [[ -x "$nsa85/jq" && ! -e "$nsa85/systemd-analyze" ]]; then
    jq '.timer={calendar:"daily", jitter:"30m"}' "$OMABACKUP_CONFIG" > "$T/c" && mv "$T/c" "$OMABACKUP_CONFIG"
    eq "status says nothing about validation either way, with or without systemd-analyze" \
      "$(env HOME="$FH" PATH="$nsa85" "$CLI" status --json 2>/dev/null | jq -r '[.problems[] | select(contains("not validated"))] | length')" "0"
    chk85=$(env HOME="$FH" PATH="$nsa85" "$CLI" setup check 2>/dev/null); chkrc85=$?
    has "the doctor FAILs rather than assumes the calendar is fine" "$chk85" \
      "^FAIL  timer.calendar: systemd-analyze not found"
    has "and names installing it as the fix" "$chk85" "pacman -S systemd"
    has "and names --no-timers as the other way out" "$chk85" "setup --no-timers"
    has "the jitter check fails the same way" "$chk85" "^FAIL  timer.jitter: systemd-analyze not found"
    eq "a doctor that cannot validate the timer exits 1, not 0" "$chkrc85" "1"
    su85=$(env HOME="$FH" PATH="$nsa85" "$CLI" setup --data-repo "$FR" --yes --json 2>/dev/null)
    eq "setup refuses without systemd-analyze (a wall, not a floor)" "$(jq -r .ok <<<"$su85")" "false"
    has "and the refusal names the missing tool" "$(jq -r .error <<<"$su85")" "systemd-analyze"
    has "and names --no-timers as the way out" "$(jq -r .error <<<"$su85")" "--no-timers"
    eq "the previously-installed unit is untouched by the refused rerun" \
      "$(grep '^OnCalendar=' "$FH/.config/systemd/user/omabackup-snapshot.timer")" "OnCalendar=Mon *-*-* 04:00:00"
    # The loss event in full: the backslash value on the machine that has no
    # systemd-analyze to catch it. The character class is the only thing
    # standing between that value and awk, and it runs regardless of
    # systemd-analyze.
    eq "and the backslash value is still refused with no systemd-analyze at all" \
      "$(OMABACKUP_CONFIG=$T/bs.json env HOME="$FH" PATH="$nsa85" "$CLI" status --json 2>/dev/null | jq -r .ok)" "false"
    eq "the unit never gets written with an injected directive" \
      "$(grep -c 'ExecStart=/bin/sh' "$FH/.config/systemd/user/omabackup-snapshot.timer" || true)" "0"
    # --no-timers is the documented way out, and it really does not touch
    # setup_units at all, so it succeeds where a timers setup just refused.
    eq "--no-timers finishes setup with no systemd-analyze at all" \
      "$(env HOME="$FH" PATH="$nsa85" "$CLI" setup --data-repo "$FR" --no-timers --yes --json 2>/dev/null | jq -r .ok)" "true"
  else
    # A skip says what it skipped and how much. A silent one does not add
    # eleven passes, it takes eleven assertions out of the total, and a
    # suite that reports 11 fewer than the last run with nothing said about
    # why reads as a count nobody can check.
    echo "  (could not build a systemd-analyze-free PATH: 11 assertions skipped)"
  fi
fi

if group 86 "the gitleaks rules and the staged scan survive an older or a newer gitleaks"; then
  # The rules file declared no minVersion (gitleaks asks for one by name) and
  # used the deprecated singular [rules.allowlist]. A gitleaks 9 that drops the
  # singular form makes both scans exit non-zero, which dies: fail-closed, but
  # a total daily stoppage of the tool.
  mk_fixture g86; seed_home; commit_baseline
  has "the rules file states the version it needs" "$(cat "$HERE/../share/gitleaks.toml")" 'minVersion = "8.19.0"'
  eq "no deprecated singular rule allowlist is left" \
    "$(grep -c '^\s*\[rules\.allowlist\]' "$HERE/../share/gitleaks.toml" || true)" "0"
  # At least one: the count is not the point, the singular form's absence is,
  # and a second scoped allowlist on a future rule must not fail this.
  eq "the scoped allowlist is the plural form" \
    "$(( $(grep -c '^\s*\[\[rules\.allowlists\]\]' "$HERE/../share/gitleaks.toml" || true) >= 1 ))" "1"
  if command -v gitleaks >/dev/null; then
    mkdir -p "$T/glempty"
    g86=$(gitleaks dir "$T/glempty" -c "$HERE/../share/gitleaks.toml" --no-banner 2>&1 || true)
    eq "the installed gitleaks parses it with nothing deprecated" "$(grep -ci 'deprecated' <<<"$g86" || true)" "0"
    eq "and asks for no minVersion" "$(grep -ci 'minVersion' <<<"$g86" || true)" "0"
  else
    echo "  (gitleaks not installed: skipping the live parse)"
  fi

  # A build with no `git` subcommand: the staged gate had no fallback, so it
  # died on every snapshot while the staging-tree gate coped. The fake refuses
  # `git` the way an older binary would, and answers `protect --staged`.
  mkdir -p "$T/fakebin"
  cat > "$T/fakebin/gitleaks" <<'OLDGL'
#!/bin/sh
case "$1" in
  git) echo "unknown command \"git\" for \"gitleaks\"" >&2; exit 1 ;;
  protect)
    case " $* " in
      *" --staged "*)
        if git diff --cached 2>/dev/null | grep -q 'sk-ant-'; then
          echo "fake gitleaks (protect): anthropic-api-key found in a staged file"
          exit 1
        fi
        ;;
    esac
    exit 0 ;;
  dir) echo "unknown command \"dir\" for \"gitleaks\"" >&2; exit 1 ;;
esac
exit 0
OLDGL
  chmod +x "$T/fakebin/gitleaks"
  o86() { env HOME="$FH" PATH="$T/fakebin:$PATH" "$CLI" "$@" --json 2>/dev/null; }
  git -C "$FR" push -q -u origin main 2>/dev/null || true
  printf '\n# a clean note\n' >> "$FR/drift-ignore.txt"
  eq "a clean list edit commits on a build with no git subcommand" "$(o86 push --confirm | jq -r .ok)" "true"
  # ...and the fallback is a real scan, not a shrug: the same build still
  # refuses a planted secret.
  key86="sk-ant-api03-$(rand_body 90)AA"
  printf '\n# pasted by accident: %s\n' "$key86" >> "$FR/drift-ignore.txt"
  p86=$(o86 push --confirm)
  eq "the fallback still refuses a secret in a staged list file" "$(jq -r .ok <<<"$p86")" "false"
  has "and names the staged scan" "$p86" "staged secret scan"
  git -C "$FR" checkout -q -- drift-ignore.txt
fi

if group 87 "a repo or a config from a newer version is refused or ignored, never downgraded"; then
  # Both halves of the same trap. The marker was equality-checked and rewritten
  # as format:1 on every setup run, so a 1.0 engine adopting a repo a 1.1
  # engine wrote silently downgraded it. And config_load died on ANY key it did
  # not know, so the first time a knob is added, the older machine in a synced
  # pair refuses to run at all rather than ignoring one field.
  mk_fixture g87; seed_home; commit_baseline

  # format 0: a marker written before the field existed. Understood completely.
  printf '{"createdBy":"older"}\n' > "$FR/.omabackup"
  eq "a marker with no format is accepted" "$(env HOME="$FH" "$CLI" status >/dev/null 2>&1; echo $?)" "0"
  printf '{"format":0,"createdBy":"older"}\n' > "$FR/.omabackup"
  eq "format 0 is accepted" "$(env HOME="$FH" "$CLI" status >/dev/null 2>&1; echo $?)" "0"

  # format 2: layout this version may misread. Refused, and NOT rewritten.
  printf '{"format":2,"createdBy":"newer"}\n' > "$FR/.omabackup"
  s87=$(obj status)
  eq "format 2 is refused" "$(jq -r .ok <<<"$s87")" "false"
  has "the refusal says which way the gap runs" "$(jq -r .error <<<"$s87")" "newer than this version"
  # A refused import must leave the repo and the config exactly as found. The
  # format refusal used to fire from data_repo_require, reached through the
  # first drift scan -- long after the config had been repointed, the seed
  # files copied in, the marker rewritten and a commit made.
  head87=$(git -C "$FR" rev-parse HEAD)
  cfg87=$(cat "$OMABACKUP_CONFIG")
  # The marker edit above is the test's own; compare the tree with itself.
  tree87=$(git -C "$FR" status --porcelain)
  fails "setup --import cannot adopt it either" \
    env HOME="$FH" "$CLI" setup --import "$FR" --no-timers --yes
  eq "and the format:2 marker survives that attempt" "$(jq -r .format "$FR/.omabackup")" "2"
  eq "the refused import made no commit" "$(git -C "$FR" rev-parse HEAD)" "$head87"
  eq "the refused import left the working tree alone" \
    "$(git -C "$FR" status --porcelain)" "$tree87"
  eq "the refused import left the config alone" "$(cat "$OMABACKUP_CONFIG")" "$cfg87"

  # A marker that is present but not JSON is NOT format 0. Read as 0 it passed
  # every check, and setup then overwrote it with format:1 -- so a corrupt or
  # half-written format:2 marker was replaced by one claiming the repo is
  # older than it is, and the only record of what wrote it was gone.
  printf 'garbage not json\n' > "$FR/.omabackup"
  c87=$(obj status)
  eq "an unparseable marker is refused" "$(jq -r .ok <<<"$c87")" "false"
  has "the refusal names the marker" "$(jq -r .error <<<"$c87")" ".omabackup"
  # A marker this tool refuses to read is one a user has no in-tool way to
  # repair: every verb stops at it, including the ones that would rewrite it.
  # It is a committed file, so git has the answer, and the refusal says so.
  has "and the refusal names the recovery" "$(jq -r .error <<<"$c87")" \
    "git -C $FR checkout -- .omabackup"
  i87=$(env HOME="$FH" "$CLI" setup --import "$FR" --no-timers --yes 2>&1 || true)
  has "the import refusal names the recovery too" "$i87" "git -C $FR checkout -- .omabackup"
  s87b=$(env HOME="$FH" "$CLI" setup --data-repo "$FR" --no-timers --yes 2>&1 || true)
  has "and so does the flagless rerun" "$s87b" "git -C $FR checkout -- .omabackup"
  fails "setup will not adopt an unparseable marker either" \
    env HOME="$FH" "$CLI" setup --import "$FR" --no-timers --yes
  eq "and the unparseable marker is left byte for byte alone" \
    "$(cat "$FR/.omabackup")" "garbage not json"
  fails "a flagless setup rerun will not rewrite it either" \
    env HOME="$FH" "$CLI" setup --data-repo "$FR" --no-timers --yes
  eq "still untouched" "$(cat "$FR/.omabackup")" "garbage not json"
  git -C "$FR" checkout -q -- . 2>/dev/null || true

  printf '{"format":1,"createdBy":"test"}\n' > "$FR/.omabackup"
  eq "an ordinary format:1 repo still works" "$(env HOME="$FH" "$CLI" status >/dev/null 2>&1; echo $?)" "0"

  # A key from the future loads with a warning; a typo of a known key does not.
  jq '. + {futureKey:{a:1}}' "$OMABACKUP_CONFIG" > "$T/future.json"
  f87=$(OMABACKUP_CONFIG=$T/future.json ob status 2>&1)
  eq "a wholly unknown key still lets the tool run" \
    "$(OMABACKUP_CONFIG=$T/future.json env HOME="$FH" "$CLI" status >/dev/null 2>&1; echo $?)" "0"
  has "and says it is ignoring it" "$f87" "ignoring config key(s) this version does not know"
  has "naming the key" "$f87" "futureKey"
  jq '. + {maxMisingPct:30}' "$OMABACKUP_CONFIG" > "$T/typo.json"
  t87=$(OMABACKUP_CONFIG=$T/typo.json obj status)
  eq "a typo of a known key still halts" "$(jq -r .ok <<<"$t87")" "false"
  has "and says why it is not being ignored" "$(jq -r .error <<<"$t87")" "typo"
  jq '. + {DataRepo:"/x"}' "$OMABACKUP_CONFIG" > "$T/case.json"
  eq "a known key in the wrong case halts too" \
    "$(OMABACKUP_CONFIG=$T/case.json obj status | jq -r .ok)" "false"
  # A nested key under a known parent gets the same treatment as a top-level one.
  jq '.remote.trustd=true' "$OMABACKUP_CONFIG" > "$T/nested.json"
  eq "a mistyped nested key halts" "$(OMABACKUP_CONFIG=$T/nested.json obj status | jq -r .ok)" "false"
  jq '.remote.mirrorOf="x"' "$OMABACKUP_CONFIG" > "$T/nested2.json"
  eq "an unknown nested key from the future does not" \
    "$(OMABACKUP_CONFIG=$T/nested2.json env HOME="$FH" "$CLI" status >/dev/null 2>&1; echo $?)" "0"
fi

if group 88 "a repo with no remote is a supported state, not a permanent fault"; then
  # The wizard offers "Private git remote URL (empty to stay local)", and
  # "no upstream configured" was then a problem forever: any problem is a
  # fault, so the bar showed the alert triangle for the life of the install
  # and the login check printed a red line in every new terminal.
  mk_fixture g88; seed_home; commit_baseline
  # A clean slate, the same way group 50 builds one: an empty complete report
  # and a fresh stamp, so "ok" here is about the remote and nothing else.
  printf '# drift-scan-complete\n' > "$FR/manifests/drift.txt"
  date +%s > "$FR/manifests/.last-run"
  git -C "$FR" add -A >/dev/null 2>&1; git -C "$FR" commit -qm "clean slate" >/dev/null 2>&1

  # LOCAL-ONLY MEANS THE CONFIG SAYS SO. mk_fixture writes remote.url, so
  # clearing it is what actually makes this fixture the install that answered
  # "empty to stay local"; removing origin alone is a different situation
  # entirely, asserted right after.
  git -C "$FR" remote remove origin
  jq '.remote={url:"", trusted:false}' "$OMABACKUP_CONFIG" > "$T/c88" \
    && mv "$T/c88" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  s88=$(obj status)
  eq "with no origin and no configured remote the state is ok" "$(jq -r .state <<<"$s88")" "ok"
  eq "and status says so in one word" "$(jq -r .remote <<<"$s88")" "none"
  eq "no upstream problem is reported" \
    "$(jq -r '[.problems[] | select(test("upstream"))] | length' <<<"$s88")" "0"
  eq "the login check is silent, so it does not paint every new terminal red" \
    "$(ob health)" ""
  has "the human status names the local-only state" "$(ob status)" "remote: none (local only)"

  # A REMOVED ORIGIN IS NOT A LOCAL-ONLY INSTALL. Deleted by hand, or lost
  # with a re-cloned .git: git looks identical to the case above, and every
  # commit since has gone nowhere while the widget said "Remote: none (local
  # only)" in green. config.json is what records the intent, so it decides.
  jq --arg u "$BARE" '.remote={url:$u, trusted:true}' "$OMABACKUP_CONFIG" > "$T/c88" \
    && mv "$T/c88" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  s88=$(obj status)
  eq "a configured remote with no origin is reported as missing" "$(jq -r .remote <<<"$s88")" "missing"
  eq "and that is a fault, not a healthy local-only install" "$(jq -r .state <<<"$s88")" "fault"
  has "the problem names the remote that went away" \
    "$(jq -r '.problems[]' <<<"$s88")" "but the repo has no origin"
  eq "the login check is no longer silent about it" \
    "$(ob health >/dev/null 2>&1; echo $?)" "1"
  # The human line has to say the same thing the JSON does. It used to fall
  # through to the push counter and print "unpushed commits: 0", which is
  # arithmetic about a remote that is not there and reads as the all-clear.
  h88=$(ob status; true)
  has "the human status names the missing origin" "$h88" "remote: missing (origin removed)"
  eq "and does not report a push count for a remote that is gone" \
    "$(grep -c '^unpushed commits:' <<<"$h88" || true)" "0"

  # A remote that EXISTS and has never been pushed to is the third state: that
  # one really is "your backup is not off this machine yet".
  git -C "$FR" remote add origin "$BARE"
  s88=$(obj status)
  eq "an origin with no upstream is still a problem" \
    "$(jq -r '[.problems[] | select(test("upstream"))] | length' <<<"$s88")" "1"
  eq "and that makes the state a fault" "$(jq -r .state <<<"$s88")" "fault"
  eq "status reports the remote as configured" "$(jq -r .remote <<<"$s88")" "configured"
  has "with the push gate open it is a plain upstream problem" \
    "$(jq -r '.problems[]' <<<"$s88")" "cannot tell if anything is pushed"
  # And when the gate is SHUT, the problem names the reason a user can act on.
  # "No upstream configured" sends them looking for a git problem; the gate is
  # why nothing was ever pushed, and it is the half they can fix.
  rm -f "$OMABACKUP_STATE_DIR/push-verdict.json"
  s88=$(obj status)
  has "with the gate shut the problem names the gate, not just git" \
    "$(jq -r '.problems[]' <<<"$s88")" "pushes are off (unprobed)"
  eq "the not-configured object carries the same keys" \
    "$(OMABACKUP_CONFIG=/nonexistent obj status | jq -S 'keys')" "$(jq -S 'keys' <<<"$s88")"

  # The wizard's own first snapshot no longer suppresses the push, so a setup
  # that finishes leaves an upstream behind and the widget is not born in the
  # fault state. OMABACKUP_SKIP_TIMERS (not --no-timers, which skips the first
  # snapshot entirely) keeps real systemd out of it.
  mk_fixture g88b
  seed_home
  eq "setup runs to completion" \
    "$(OMABACKUP_SKIP_TIMERS=1 obj setup --data-repo "$FR" --remote "$BARE" --trust-remote --yes | jq -r .ok)" "true"
  eq "the wizard's first snapshot established an upstream" \
    "$(git -C "$FR" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo none)" "origin/main"
  eq "so the widget does not open on 'no upstream configured'" \
    "$(obj status | jq -r '[.problems[] | select(test("upstream"))] | length')" "0"

  # AND THE OTHER SIDE OF THE SAME RULING: letting the gate decide means the
  # gate can say no, and a refused push must be a warning inside a successful
  # setup, never a failed wizard. An untrusted non-GitHub remote is exactly
  # that case, and it is what a user who declines the trust question gets.
  mk_fixture g88c
  seed_home
  jq '.remote={url:"", trusted:false}' "$OMABACKUP_CONFIG" > "$T/c88c" \
    && mv "$T/c88c" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  out88=$(OMABACKUP_SKIP_TIMERS=1 env HOME="$FH" "$CLI" setup --data-repo "$FR" --remote "$BARE" --yes --json 2>"$T/setup88.err")
  rc88=$?
  eq "setup with an untrusted remote still exits 0" "$rc88" "0"
  eq "and prints exactly one JSON object saying ok" "$(jq -c '[.ok]' <<<"$out88" 2>/dev/null)" "[true]"
  eq "exactly one object, not two" "$(jq -s 'length' <<<"$out88")" "1"
  has "the refused push is a warning on stderr, naming the reason" \
    "$(cat "$T/setup88.err")" "push not verifiable"
  eq "nothing was pushed, so the bare remote is still empty" \
    "$(git -C "$BARE" rev-list --count --all 2>/dev/null || echo 0)" "0"
  [[ "$(git -C "$FR" rev-list --count HEAD)" -gt 1 ]] \
    && ok "the snapshot still committed locally, so nothing was lost" || bad "the first snapshot committed nothing"
fi

if group 89 "a newline in a DIRECTORY name does not take the whole scan down"; then
  # The collapse pass counts the files under every directory in one awk. Its
  # INPUT was NUL-delimited (find -print0) and its OUTPUT was newline
  # terminated, so a directory named `bad<LF>dir 2` split one
  # "depth<TAB>count<TAB>dir" record in two. The fragment reached the decision
  # loop, `n` held text instead of a number, and `$(( n - ... ))` died
  # "unbound variable" inside the command substitution that captures the
  # report: exit 1, no sentinel, and `snapshot --json` printed no JSON object
  # at all -- the one thing every verb promises. A file with a newline in its
  # own name never did this: only a DIRECTORY name becomes a record key.
  mk_fixture g89; seed_home
  mkdir -p "$FH/.local/share/deep/bad"$'\n'"dir 2"
  printf 'x\n' > "$FH/.local/share/deep/bad"$'\n'"dir 2/f.conf"
  d89=$(ob drift)
  eq "the scan reaches its sentinel" "$(tail -1 <<<"$d89")" "# drift-scan-complete"
  eq "the unrepresentable name is exactly one ERROR row" \
    "$(grep -c 'a name the report cannot represent' <<<"$d89" || true)" "1"
  eq "no fragment row claims the first half of the name is a file" \
    "$(grep -cx 'NEW        ~/.local/share/deep/bad' <<<"$d89" || true)" "0"
  eq "no NEW row is produced under that directory at all" \
    "$(grep -c '^NEW .*\.local/share/deep' <<<"$d89" || true)" "0"
  s89=$(obj snapshot --no-push)
  eq "snapshot --json still prints exactly one JSON object" \
    "$(jq -s 'length' <<<"$s89" 2>/dev/null || echo 0)" "1"
  eq "and the run itself completed" "$(jq -r .ok <<<"$s89")" "true"
  rm -rf "$FH/.local/share/deep"
fi

if group 90 "the way out of a refused run is one a user can actually take"; then
  # The mass-disappearance refusal names `omabackup resolve-gone <path> remove`.
  # resolve-gone accepted only paths the last COMMITTED drift report lists as
  # GONE, and the refused run dies in the allowlist assertion, long before it
  # writes a report -- so the entries that caused the refusal were exactly the
  # ones resolve-gone would not touch. The named way out could not be taken and
  # the only fix left was a hand edit of allowlist.txt the message never
  # mentioned.
  mk_fixture g90
  i90=1
  while [ "$i90" -le 25 ]; do
    mkdir -p "$FH/.config/e$i90"
    for j90 in 1 2 3 4; do printf 'setting=%d\n' "$j90" > "$FH/.config/e$i90/f$j90.conf"; done
    printf '?.config/e%d\n' "$i90" >> "$FR/allowlist.txt"
    i90=$((i90+1))
  done
  git -C "$FR" commit -qam "25 optional entries, 100 files"
  check "the baseline run commits all of it" env HOME="$FH" "$CLI" snapshot --no-push
  i90=1
  while [ "$i90" -le 8 ]; do rm -rf "$FH/.config/e$i90"; i90=$((i90+1)); done
  r90=$(obj snapshot --no-push)
  eq "the run refuses" "$(jq -r .ok <<<"$r90")" "false"
  has "and names resolve-gone as the way out" "$(jq -r .error <<<"$r90")" "resolve-gone <path> remove"
  has "and the hand edit as the other one" "$(jq -r .error <<<"$r90")" "edit allowlist.txt by hand"
  eq "the report the refused run never wrote does not list them as GONE" \
    "$(grep -c '^GONE .*\.config/e1$' "$FR/manifests/drift.txt" || true)" "0"

  ok90=true
  i90=1
  while [ "$i90" -le 8 ]; do
    # shellcheck disable=SC2088 # the literal "~/" the popup sends, not a path to expand
    [[ "$(obj resolve-gone "~/.config/e$i90" remove | jq -r .ok)" == true ]] || ok90=false
    i90=$((i90+1))
  done
  eq "resolve-gone removes every entry that caused the refusal" "$ok90" "true"
  eq "the entries are gone from the allowlist" \
    "$(grep -c '^?\.config/e[1-8]$' "$FR/allowlist.txt" || true)" "0"
  eq "the ones that still resolve are untouched" \
    "$(grep -c '^?\.config/e' "$FR/allowlist.txt" || true)" "17"
  check "and the next snapshot runs" env HOME="$FH" "$CLI" snapshot --no-push

  # The gate did not become "anything the user names": an entry that is still
  # there, and a path no allowlist entry names at all, are both refused.
  # shellcheck disable=SC2088 # literal "~/" prefix, not a path to expand
  n90=$(obj resolve-gone '~/.config/e25' remove)
  eq "an entry that still resolves is refused" "$(jq -r .ok <<<"$n90")" "false"
  eq "and it stays in the allowlist" \
    "$(grep -c '^?\.config/e25$' "$FR/allowlist.txt" || true)" "1"
  # shellcheck disable=SC2088 # literal "~/" prefix, not a path to expand
  eq "a path no entry names is refused too" \
    "$(obj resolve-gone '~/.config/never-listed' remove | jq -r .ok)" "false"
fi

if group 91 "every find reader is NUL-delimited, so a newline cannot forge a row"; then
  # The deep walkers were fixed first; these four readers were not. Each ran
  # `find -print` and read it a line at a time, so a newline in a filename
  # split one path into two fragments before any producer saw it. The prefix
  # fragment names a path that is not a file, and the SUFFIX fragment becomes a
  # real row for a path in an entirely different part of $HOME -- one the
  # widget's Allow button then accepts, because the report does name it.
  mk_fixture g91; seed_home
  mkdir -p "$FH/.config/systemd/user"
  printf '[Unit]\nDescription=x\n' > "$FH/.config/systemd/user/bad"$'\n'"unit.service"
  printf '#!/bin/sh\n# %s\n' "$(rand_body 400)" > "$FH/.local/bin/bad"$'\n'"script"
  chmod +x "$FH/.local/bin/bad"$'\n'"script"
  d91=$(ob drift)
  eq "the hand-written unit yields one ERROR row" \
    "$(grep -c 'cannot represent: ~/\.config/systemd/user/' <<<"$d91" || true)" "1"
  eq "no row names the suffix fragment as a file in another directory" \
    "$(grep -cx 'NEW        ~/unit.service' <<<"$d91" || true)" "0"
  eq "no row claims the prefix fragment is a file" \
    "$(grep -cx 'NEW        ~/.config/systemd/user/bad' <<<"$d91" || true)" "0"
  eq "the ~/.local/bin script yields one ERROR row" \
    "$(grep -c 'cannot represent: ~/\.local/bin/' <<<"$d91" || true)" "1"
  eq "and no row names either half of it" \
    "$(grep -c '^NEW .*\.local/bin' <<<"$d91" || true)" "0"
  eq "the scan still reaches its sentinel" "$(tail -1 <<<"$d91")" "# drift-scan-complete"
  rm -f "$FH/.config/systemd/user/bad"$'\n'"unit.service" "$FH/.local/bin/bad"$'\n'"script"

  # The oversized producer reads the same kind of listing. A file too big for
  # the backup is the one thing this tool exists to shout about, so a name that
  # splits must not become a TOOBIG row for a file that does not exist.
  allow '.config/mytool'; commit_baseline
  head -c 12000000 /dev/urandom > "$FH/.config/mytool/huge"$'\n'"name.dat"
  check "the snapshot still runs" env HOME="$FH" "$CLI" snapshot --no-push
  eq "the oversized name is one ERROR row" \
    "$(grep -c 'cannot represent: ~/\.config/mytool/' "$FR/manifests/drift.txt" || true)" "1"
  eq "and no TOOBIG row names a fragment" \
    "$(grep -c '^TOOBIG' "$FR/manifests/drift.txt" || true)" "0"
  rm -f "$FH/.config/mytool/huge"$'\n'"name.dat"

  # ...and the /etc drop-in walk. Its ownership answer comes back from pacman
  # as prose ("error: No package owns <path>"), which a newline splits just as
  # badly, so an unwritable name is reported as the scanner gap it is before
  # pacman is asked about it at all.
  mk_fixture g91e; real_manifests; seed_home
  if ! command -v pacman >/dev/null 2>&1; then
    echo "  (skipped: pacman not available on this machine)"
  else
    ETCROOT91="$T/etc"; mkdir -p "$ETCROOT91/modprobe.d"
    printf 'options hid_apple fnmode=2\n' > "$ETCROOT91/modprobe.d/zz-fixture.conf"
    printf 'options x y\n' > "$ETCROOT91/modprobe.d/bad"$'\n'"dropin.conf"
    export OMABACKUP_SKIP_ETC=0 OMABACKUP_ETC_ROOT="$ETCROOT91"
    d91e=$(ob drift)
    export OMABACKUP_SKIP_ETC=1; unset OMABACKUP_ETC_ROOT
    eq "the drop-in with a newline in its name is one ERROR row" \
      "$(grep -c 'cannot represent: /etc/modprobe.d/' <<<"$d91e" || true)" "1"
    eq "no row names either fragment of it" \
      "$(grep -c '^NEW .*dropin.conf' <<<"$d91e" || true)" "0"
    has "the ordinary drop-in beside it is still reported" "$d91e" \
      "NEW        /etc/modprobe.d/zz-fixture.conf"
  fi
fi

if group 92 "omabackup's own unit files are not drift, and their neighbours still are"; then
  # Section 3 of the drift scan reports every regular file under
  # ~/.config/systemd/user, because on a stock machine those are all
  # hand-written units (the packaged ones are symlinks into /usr/lib). So a
  # fresh install opened the popup on five NEW rows the tool had just written
  # about itself, which is precisely the noise that teaches people to ignore
  # the list. share/drift-ignore.example carries a dated entry for them.
  mk_fixture g92; seed_home
  mkdir -p "$FH/.config/systemd/user"
  # The names come from the SHIPPED units, so renaming one there without
  # touching the seed line is caught here rather than on somebody's machine.
  for u92 in "$HERE/../share/units"/*; do
    printf '[Unit]\nDescription=fixture\n' > "$FH/.config/systemd/user/$(basename "$u92")"
  done
  printf '[Unit]\nDescription=mine\n' > "$FH/.config/systemd/user/my-own.service"
  d92=$(ob drift)
  eq "none of omabackup's own units is reported as drift" \
    "$(grep -c 'systemd/user/omabackup-' <<<"$d92" || true)" "0"
  # The entry is a name pattern, NOT a subtree ignore: the directory is one of
  # the best detectors there is, and silencing it wholesale is the fail-open
  # shape this tool exists to prevent.
  has "a hand-written unit beside them is still reported" "$d92" "systemd/user/my-own.service"
  eq "and lint is happy with the seeded entry" "$(obj lint --no-walk | jq -r .ok)" "true"
  # A repo adopted from an older version has no seed line for them, and the
  # first popup after adoption opened on five rows about the tool itself. The
  # scan exempts its own unit names on its own; the seed line is a courtesy.
  grep -vF 'systemd/user/omabackup-' "$FR/drift-ignore.txt" > "$T/di92" && mv "$T/di92" "$FR/drift-ignore.txt"
  git -C "$FR" commit -qam "an ignore list from before the units existed"
  d92b=$(ob drift)
  eq "without the seed line the tool's units are still not drift" \
    "$(grep -c 'systemd/user/omabackup-' <<<"$d92b" || true)" "0"
  has "and the hand-written unit beside them still is" "$d92b" "systemd/user/my-own.service"
  # Exact names, not a prefix: a unit that merely starts with omabackup- is
  # somebody else's and must stay visible (Codex, PR 6).
  printf '[Unit]\nDescription=not ours\n' > "$FH/.config/systemd/user/omabackup-report.service"
  has "a hand-written unit that shares the prefix is still reported" "$(ob drift)" "systemd/user/omabackup-report.service"
  # The tool's own config directory is machine-local (an absolute dataRepo,
  # a remote URL that may carry credentials): never backed up, never drift.
  # WHEREVER it lives: the exemption is derived from CONFIG_FILE, because
  # lib/config.sh honours XDG_CONFIG_HOME and a hardcoded ~/.config/omabackup
  # exempted the wrong directory on a machine that sets it (Codex, PR 6).
  mkdir -p "$FH/.config/omabackup"
  cp "$OMABACKUP_CONFIG" "$FH/.config/omabackup/config.json"
  eq "the default config directory is not drift" \
    "$(env HOME="$FH" OMABACKUP_CONFIG="$FH/.config/omabackup/config.json" "$CLI" drift 2>&1 | grep -c 'config/omabackup' || true)" "0"
  # The same, with XDG_CONFIG_HOME pointing somewhere else entirely and no
  # OMABACKUP_CONFIG override: the real config directory is exempt and the
  # default one, which this run does not use, is reported like any other.
  mkdir -p "$FH/.config-alt/omabackup"
  cp "$OMABACKUP_CONFIG" "$FH/.config-alt/omabackup/config.json"
  d92x=$(env -u OMABACKUP_CONFIG HOME="$FH" XDG_CONFIG_HOME="$FH/.config-alt" "$CLI" drift 2>&1)
  eq "an XDG_CONFIG_HOME config directory is not drift" \
    "$(grep -c 'config-alt/omabackup' <<<"$d92x" || true)" "0"
  has "and the unused default one is reported like anything else" "$d92x" ".config/omabackup"
  rm -rf "$FH/.config-alt"
  eq "and the seed allowlist does not back it up" \
    "$(grep -c 'config/omabackup' "$HERE/../share/allowlist.example" || true)" "0"
fi

if group 93 "an existing repo's .gitignore gains the patterns this version ships, and the sync owns its commit"; then
  # Both cp sites in setup are conditional (`[[ -f .gitignore ]] || cp`), which
  # is right on its own -- a rewrite would take lines the user added -- but
  # together they meant a repo created before a class was added to
  # share/data.gitignore never got it, and nothing was going to. `.omabackup.*`
  # is the live example: on such a repo the marker's interrupted-setup scratch
  # file is an untracked file the login check names at every new terminal.
  #
  # The sync used to run from data_repo_require, so every verb, including the
  # read-only ones the widget calls every few minutes, wrote to the data repo
  # outside the lock, and then left the edit for a human to commit. It now
  # runs from the snapshot, under the lock, and commits what it appended.
  mk_fixture g93; seed_home
  # A pre-0.7.0 .gitignore: the shipped file minus two of its lines, plus one
  # of the user's own that nothing may touch.
  grep -vxF -e '.omabackup.*' -e 'Cookies*' "$HERE/../share/data.gitignore" > "$FR/.gitignore"
  printf '\n# mine, not omabackup\nmy-own-scratch/\n' >> "$FR/.gitignore"
  git -C "$FR" commit -qam "a .gitignore from an older version"
  n93=$(wc -l < "$FR/.gitignore")
  # Read-only verbs, and a dry run, do not write to the data repo at all.
  eq "status still answers about this repo" "$(obj status | jq -r .repo)" "$FR"
  obj lint --no-walk >/dev/null; ob drift >/dev/null; ob snapshot --dry-run >/dev/null
  eq "status, lint, drift and a dry run leave .gitignore alone" "$(wc -l < "$FR/.gitignore")" "$n93"
  eq "and the repo clean" "$(git -C "$FR" status --porcelain -- .gitignore)" ""
  # The snapshot syncs, and commits the sync on its own, before its own commit.
  check "the snapshot runs" env HOME="$FH" "$CLI" snapshot --no-push
  eq "the marker-scratch pattern is there now" \
    "$(grep -cxF '.omabackup.*' "$FR/.gitignore")" "1"
  eq "and so is every other shipped line it lacked" \
    "$(grep -cxF 'Cookies*' "$FR/.gitignore")" "1"
  eq "the line the user added is untouched" \
    "$(grep -cxF 'my-own-scratch/' "$FR/.gitignore")" "1"
  eq "nothing shipped was removed" "$(grep -cxF '.staging/' "$FR/.gitignore")" "1"
  eq "the sync's edit is committed" "$(git -C "$FR" status --porcelain -- .gitignore)" ""
  eq "in a commit of its own that names what it did" \
    "$(git -C "$FR" log -1 --format=%s -- .gitignore)" "omabackup: .gitignore gains 2 ignore pattern(s) this version ships"
  eq "and that commit holds .gitignore and nothing else" \
    "$(git -C "$FR" log -1 --name-only --format= -- .gitignore)" ".gitignore"
  if git -C "$FR" log -1 --name-only --format= | grep -qx '.gitignore'; then
    bad "the snapshot commit swept .gitignore up" "$(git -C "$FR" log -1 --oneline --name-only)"
  else
    ok "the snapshot's own commit does not carry .gitignore"
  fi
  # ONCE. A second snapshot, and every read-only verb, append nothing.
  n93=$(wc -l < "$FR/.gitignore"); c93=$(git -C "$FR" rev-list --count HEAD)
  obj status >/dev/null; obj lint --no-walk >/dev/null; ob drift >/dev/null
  check "a second snapshot runs" env HOME="$FH" "$CLI" snapshot --no-push
  eq "a second snapshot and three verbs append nothing" "$(wc -l < "$FR/.gitignore")" "$n93"
  eq "and no pattern is duplicated" "$(grep -cxF '.omabackup.*' "$FR/.gitignore")" "1"
  eq "and no second sync commit exists" \
    "$(git -C "$FR" log --format=%s | grep -c 'gitignore gains' || true)" "1"
  [[ $(git -C "$FR" rev-list --count HEAD) -le $((c93 + 1)) ]] \
    && ok "the second snapshot made at most its own commit" || bad "extra commits after the second snapshot"

  # A repo that already has every line is the normal case, and it must not be
  # written to at all: mk_fixture copies the shipped file verbatim.
  mk_fixture g93b; seed_home; commit_baseline
  c93b=$(git -C "$FR" rev-list --count HEAD)
  obj status >/dev/null
  check "a snapshot on a current repo" env HOME="$FH" "$CLI" snapshot --no-push
  eq "a current repo's .gitignore is left completely alone" \
    "$(git -C "$FR" status --porcelain -- .gitignore)" ""
  eq "and gets no sync commit" \
    "$(git -C "$FR" log --format=%s | grep -c 'gitignore gains' || true)" "0"
  [[ $(git -C "$FR" rev-list --count HEAD) -le $((c93b + 1)) ]] \
    && ok "at most the snapshot's own commit" || bad "extra commits on a current repo"

  # The user's OWN uncommitted edit to .gitignore: the patterns are still
  # appended (every run without them can commit a credential file), but the
  # tool signs no commit that carries an edit it did not make. The edit is
  # reported, and push offers to commit exactly that file.
  mk_fixture g93c; seed_home
  grep -vxF '.omabackup.*' "$HERE/../share/data.gitignore" > "$FR/.gitignore"
  git -C "$FR" commit -qam "a .gitignore from an older version"
  printf 'my-unfinished-edit/\n' >> "$FR/.gitignore"
  s93c=$(ob snapshot --no-push || true)
  eq "the shipped pattern was still appended" "$(grep -cxF '.omabackup.*' "$FR/.gitignore")" "1"
  eq "the user's edit is intact" "$(grep -cxF 'my-unfinished-edit/' "$FR/.gitignore")" "1"
  eq "nothing was committed for .gitignore" \
    "$(git -C "$FR" log --format=%s | grep -c 'gitignore gains' || true)" "0"
  has "and the run says why" "$s93c" "already uncommitted"
  eq "the edit is reported" \
    "$(obj status | jq -r '[.uncommitted[] | select(test("gitignore"))] | length')" "1"
  eq "and push offers to commit exactly that file" \
    "$(obj push | jq -r '[.files[]? | select(. == ".gitignore")] | length')" "1"
  # Something the user STAGED before the run is the other way an edit rides
  # into a commit that is not theirs. snapshot_commit unstages it; the sync
  # commit runs before that and must see it and stand down.
  mk_fixture g93s; seed_home
  grep -vxF '.omabackup.*' "$HERE/../share/data.gitignore" > "$FR/.gitignore"
  git -C "$FR" commit -qam "a .gitignore from an older version"
  printf 'staged-by-hand\n' >> "$FR/allowlist.txt"; git -C "$FR" add allowlist.txt
  h93s=$(git -C "$FR" rev-parse HEAD)
  s93s=$(ob snapshot --no-push || true)
  eq "with a dirty index the pattern is appended" "$(grep -cxF '.omabackup.*' "$FR/.gitignore")" "1"
  eq "but not committed" "$(git -C "$FR" log --format=%s | grep -c 'gitignore gains' || true)" "0"
  has "and the run says the index was the reason" "$s93s" "already staged"
  if git -C "$FR" log "$h93s..HEAD" --name-only --format= | grep -qx 'allowlist.txt'; then
    bad "the staged allowlist edit rode into a commit" "$(git -C "$FR" log "$h93s..HEAD" --oneline --name-only | head -6)"
  else
    ok "the staged allowlist edit rode into no commit"
  fi

  # Adoption is the other path that commits, and a repo from an older version
  # is exactly what it adopts: the sync and its commit happen there too, so
  # the very first status after import reports a clean repo.
  mk_fixture g93i; seed_home; rm "$FR/.omabackup"
  grep -vxF '.omabackup.*' "$HERE/../share/data.gitignore" > "$FR/.gitignore"
  git -C "$FR" commit -qam "a .gitignore from an older version"
  check "import adopts the older repo" env HOME="$FH" "$CLI" setup --import "$FR" --no-timers --yes
  eq "import synced the shipped pattern" "$(grep -cxF '.omabackup.*' "$FR/.gitignore")" "1"
  eq "and committed it" "$(git -C "$FR" status --porcelain | grep -c . || true)" "0"
  eq "as the sync's own commit" \
    "$(git -C "$FR" log --format=%s | grep -c 'gitignore gains' || true)" "1"

  # The sync commit lands BEFORE the pipeline's checks, so a run that then
  # refuses still leaves it as HEAD. Health's stand-in for a missing stamp
  # used to be HEAD's time, which made that refused run read as a snapshot
  # taken just now and silenced the stale-backup problem (Codex, PR 3). The
  # stand-in is the last commit that touched the snapshot's own paths.
  mk_fixture g93r; seed_home
  old93=$(( $(date +%s) - 5*86400 ))
  check "a snapshot dated five days ago" env HOME="$FH" GIT_COMMITTER_DATE="@$old93" GIT_AUTHOR_DATE="@$old93" "$CLI" snapshot --no-push
  grep -vxF '.omabackup.*' "$HERE/../share/data.gitignore" > "$FR/.gitignore"
  git -C "$FR" commit -qam "a .gitignore from an older version"
  rm -f "$FR/manifests/.last-run"
  # A credential-shaped name in an allowlisted folder: the filename gate
  # refuses, and it runs after the sync.
  allow '.config/mytool'
  printf 'k\n' > "$FH/.config/mytool/mytool.key"
  fails "the run refuses at the filename gate" env HOME="$FH" "$CLI" snapshot --no-push
  eq "the sync commit is HEAD all the same" \
    "$(git -C "$FR" log -1 --format=%s)" "omabackup: .gitignore gains 1 ignore pattern(s) this version ships"
  st93r=$(obj status)
  eq "but the last snapshot still reads as five days old" "$(jq -r .last_run_age_days <<<"$st93r")" "5"
  has "and the stale-backup problem is reported" "$(jq -r '.problems[]' <<<"$st93r")" "last snapshot was 5 days ago"
  rm -f "$FH/.config/mytool/mytool.key"

  # GREP HAS THREE EXIT CODES, and only two of them are an answer. 0 is "the
  # line is there", 1 is "it is not", and anything above 1 is grep saying it
  # could not look. Read as a plain boolean, that third code means "absent",
  # so a .gitignore this tool cannot READ but can WRITE had the entire shipped
  # block appended to it -- on every run, to a file that may already have had
  # every line. A sync that cannot compare does not sync.
  mk_fixture g93d; seed_home
  before93=$(wc -c < "$FR/.gitignore")
  chmod 200 "$FR/.gitignore"
  w93=$(ob snapshot --no-push || true)
  chmod 600 "$FR/.gitignore"
  eq "an unreadable .gitignore is left byte for byte as it was" \
    "$(wc -c < "$FR/.gitignore")" "$before93"
  has "and the run says it could not read it" "$w93" "cannot read"
  eq "the repo is still clean afterwards" \
    "$(git -C "$FR" status --porcelain -- .gitignore)" ""
fi

if group 94 "notify: false in the config actually silences notifications"; then
  # cfg() read every value through jq's `// empty`, and the alternative
  # operator treats false exactly like null, so a configured false came back
  # as the empty string and notify() then defaulted it to true. The README
  # documented the knob; nothing honoured it. remote.trusted and shellNag are
  # the same class and were harmless only because every reader of theirs
  # compares against the word true.
  mk_fixture g94; seed_home; commit_baseline
  mkdir -p "$T/fakebin"
  for n in notify-send omarchy-notification-send; do
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/nf.log"\n' "$T" > "$T/fakebin/$n"
    chmod +x "$T/fakebin/$n"
  done
  # notify-failure is the one verb whose whole job is a notification, and it
  # reads the config for exactly this knob.
  nf94() { : > "$T/nf.log"; env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_NOTIFY=1 "$CLI" notify-failure snapshot >/dev/null 2>&1; cat "$T/nf.log"; }
  set94() { jq --argjson v "$1" '.notify=$v' "$OMABACKUP_CONFIG" > "$T/c94.json" && mv "$T/c94.json" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"; }
  set94 true
  [[ -n "$(nf94)" ]] && ok "control: notify true sends" || bad "control: notify true sent nothing"
  set94 false
  eq "notify false sends nothing" "$(nf94)" ""
  # The default, with the key absent, is still on: fail loud is the direction.
  jq 'del(.notify)' "$OMABACKUP_CONFIG" > "$T/c94.json" && mv "$T/c94.json" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  [[ -n "$(nf94)" ]] && ok "an absent notify key still sends" || bad "an absent notify key sent nothing"
fi

if group 95 "verify without a last-run stamp reasons from the last snapshot, not from HEAD"; then
  # manifests/.last-run is gitignored, so a fresh clone has none, and verify
  # fell back to HEAD's commit time. Right after `setup --import` HEAD is the
  # adoption marker commit, hours or days after the last snapshot, so every
  # live file edited in between was reported as a fidelity problem (four of
  # them on the first dry run of Task 22). The stand-in is now the last commit
  # that touched the snapshot's own output paths.
  mk_fixture g95; seed_home; commit_baseline
  snap_t=$(git -C "$FR" log -1 --format=%ct)
  # A live edit after the snapshot, then a later commit that is not a
  # snapshot: the shape adoption, a list commit and a .gitignore sync all make.
  printf 'changed\n' > "$FH/.bashrc"; touch -d "@$((snap_t + 60))" "$FH/.bashrc"
  env GIT_COMMITTER_DATE="@$((snap_t + 7200))" GIT_AUTHOR_DATE="@$((snap_t + 7200))" \
    git -C "$FR" commit -q --allow-empty -m "omabackup: adopt existing repo"
  rm -f "$FR/manifests/.last-run"
  v95=$(obj verify)
  eq "the edit after the snapshot is excused, not failed" "$(jq -c '[.ok,.skipped_changed]' <<<"$v95")" '[true,1]'
  has "and the run says the stamp is missing" "$(ob verify || true)" "last-run is missing"
  # A mismatch OLDER than the snapshot is still a mismatch: the stand-in must
  # not excuse everything.
  touch -d "@$((snap_t - 60))" "$FH/.bashrc"
  fails "a mismatch older than the snapshot still fails verify" env HOME="$FH" "$CLI" verify
  # With the stamp present nothing here changes: the stamp wins.
  printf '%s\n' "$((snap_t + 30))" > "$FR/manifests/.last-run"
  touch -d "@$((snap_t + 90))" "$FH/.bashrc"
  eq "with a stamp the stamp decides" "$(obj verify | jq -r .ok)" "true"
fi

if group 96 "a filename gate that cannot walk the staging tree refuses the run"; then
  # The gate's find sat in one pipeline ending in `|| true`, put there for
  # grep's no-match exit, and it swallowed find's exit too: a find that died
  # on an unreadable directory, or never started, produced no names, nothing
  # matched, and the gate passed. A gate that cannot look must refuse. The
  # lever is a find on PATH that fails only on the gate's own basename walk,
  # so every other find in the pipeline (the drift scan, the size check)
  # behaves, and the failure is the gate's alone.
  mk_fixture g96; seed_home; commit_baseline
  mkdir -p "$T/fakebin"
  real_find=$(command -v find)
  printf '#!/bin/sh\ncase "$*" in *"%%f\\0"*) "%s" "$@"; echo "find: fake failure on the gate walk" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$real_find" "$real_find" > "$T/fakebin/find"
  chmod +x "$T/fakebin/find"
  printf 'export NEWLINE=1\n' >> "$FH/.bashrc"
  head96=$(git -C "$FR" rev-parse HEAD)
  out96=$(env HOME="$FH" PATH="$T/fakebin:$PATH" "$CLI" snapshot --no-push 2>&1); rc96=$?
  eq "the run refuses" "$rc96" "1"
  has "and names the gate that could not look" "$out96" "filename gate could not walk"
  eq "nothing was committed" "$(git -C "$FR" rev-parse HEAD)" "$head96"
  eq "the gate's scratch file is cleaned up" "$(find "$OMABACKUP_STATE_DIR" -name '.gate.*' | wc -l)" "0"
  # With a working find the same edit commits, so the refusal above was the
  # gate's and not something else in the pipeline.
  check "the run commits once find works" env HOME="$FH" "$CLI" snapshot --no-push
  eq "and leaves no scratch file either" "$(find "$OMABACKUP_STATE_DIR" -name '.gate.*' | wc -l)" "0"
fi

if group 97 "a remote URL with a password in it is refused, and never printed"; then
  # setup stored whatever URL it was given, and remote_url_parts strips the
  # userinfo for the GitHub check, so https://user:password@host/... passed
  # every check and landed in .git/config, in config.json and in every line
  # that prints the remote (Codex, PR 6).
  mk_fixture g97; seed_home; commit_baseline
  before97=$(jq -r .remote.url "$OMABACKUP_CONFIG")
  bad97="https://alice:hunter2secret@example.com/alice/dots.git"
  out97=$(env HOME="$FH" "$CLI" setup --data-repo "$FR" --remote "$bad97" --no-timers --yes 2>&1); rc97=$?
  eq "setup refuses a --remote with a password" "$rc97" "1"
  has "and says why" "$out97" "carries a password"
  eq "without printing the password" "$(grep -c hunter2secret <<<"$out97" || true)" "0"
  # Fixed-string: the stars in the redaction are not a regex.
  grep -qF -- "https://alice:***@example.com/alice/dots.git" <<<"$out97" \
    && ok "but with the rest of the URL, redacted" || bad "the redacted URL is not in the refusal" "$out97"
  eq "origin was not touched" "$(git -C "$FR" remote get-url origin)" "$BARE"
  eq "and the config still names the remote it had" "$(jq -r .remote.url "$OMABACKUP_CONFIG")" "$before97"
  # An origin that already carries one is refused the same way at adoption,
  # and status never prints the password either.
  git -C "$FR" remote set-url origin "$bad97"
  rm -f "$FR/.omabackup"
  imp97=$(env HOME="$FH" "$CLI" setup --import "$FR" --no-timers --yes 2>&1); irc97=$?
  eq "import refuses a repo whose origin carries a password" "$irc97" "1"
  eq "and prints no password" "$(grep -c hunter2secret <<<"$imp97" || true)" "0"
  git -C "$FR" remote set-url origin "$BARE"
  # A PUSH URL carries the password just as well, and it is the one a push
  # actually uses. A clean fetch URL with a credential-bearing pushurl passed
  # the guard entirely, and lib/remote.sh then named that pushurl in a warning
  # (Codex, PR 7). Both halves are covered: the refusal, and the warning.
  git -C "$FR" remote set-url origin "$BARE"
  git -C "$FR" remote set-url --push origin "$bad97"
  p97=$(env HOME="$FH" "$CLI" setup --data-repo "$FR" --no-timers --yes 2>&1); prc=$?
  eq "setup refuses a password in the PUSH url" "$prc" "1"
  has "and says why" "$p97" "carries a password"
  eq "without printing the password" "$(grep -c hunter2secret <<<"$p97" || true)" "0"
  # The pushurl-differs warning is the other place that URL is printed.
  w97=$(env HOME="$FH" OMABACKUP_NET=1 "$CLI" snapshot --no-push 2>&1 || true)
  eq "the pushurl-differs warning prints no password either" "$(grep -c hunter2secret <<<"$w97" || true)" "0"
  has "but still names the mismatch" "$w97" "pushes to a different URL"
  git -C "$FR" remote set-url --push --delete origin "$bad97" 2>/dev/null || true
  git -C "$FR" remote set-url origin "$BARE"
  # A userinfo WITHOUT a password is fine: git@ and user@ forms are normal.
  check "a user@ URL without a password is accepted" \
    env HOME="$FH" "$CLI" setup --data-repo "$FR" --remote "ssh://git@example.com/alice/dots.git" --no-timers --yes
  eq "and stored" "$(jq -r .remote.url "$OMABACKUP_CONFIG")" "ssh://git@example.com/alice/dots.git"
  git -C "$FR" remote set-url origin "$BARE"
fi

if group 98 "open --remote opens the repo's own page, and builds the URL itself"; then
  # The popup may launch nothing but the CLI, so "show me the repository" is a
  # verb. The URL is built HERE from a slug remote_github_slug has already
  # validated as exactly owner/repo, which is what stops anything a git remote
  # says from choosing the host, the scheme or the path.
  mk_fixture g98; seed_home; commit_baseline
  mkdir -p "$T/fakebin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/browser.log"\n' "$T" > "$T/fakebin/omarchy-launch-browser"
  chmod +x "$T/fakebin/omarchy-launch-browser"
  # setsid -f detaches, so the log lands a moment after the verb returns.
  br98() { : > "$T/browser.log"; env HOME="$FH" PATH="$T/fakebin:$PATH" "$CLI" open --remote 2>&1; }
  wait98() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$T/browser.log" ]] && break; sleep 0.2; done; cat "$T/browser.log"; }

  git -C "$FR" remote set-url origin "git@github.com:alice/dots.git"
  o98=$(br98); rc98=$?
  eq "the verb succeeds on a github remote" "$rc98" "0"
  # br98 passes no --json, so this is the human reply: one line naming the
  # page. The JSON field the popup reads is checked right after.
  eq "and reports the page it opened" "$o98" "opened https://github.com/alice/dots"
  eq "the browser was launched with exactly that URL, and nothing else" \
    "$(wait98)" "https://github.com/alice/dots"
  eq "--json names the same page in the field the popup reads" \
    "$(env HOME="$FH" PATH="$T/fakebin:$PATH" "$CLI" open --remote --json 2>/dev/null | jq -r .opened)" \
    "https://github.com/alice/dots"
  # The remote is never passed through: an ssh URL still produces an https page.
  git -C "$FR" remote set-url origin "ssh://git@github.com:22/alice/dots"
  br98 >/dev/null
  eq "an ssh remote still opens the https page" "$(wait98)" "https://github.com/alice/dots"

  # A GitHub host whose path is not exactly owner/repo is unverifiable, and a
  # guessed URL is worse than a refusal.
  git -C "$FR" remote set-url origin "https://github.com/alice/dots/tree/main"
  : > "$T/browser.log"
  o98b=$(env HOME="$FH" PATH="$T/fakebin:$PATH" "$CLI" open --remote 2>&1); rcb=$?
  eq "an unslugged github path refuses" "$rcb" "1"
  has "and says no page is known" "$o98b" "no web page is known"
  eq "and launches nothing" "$(wc -c < "$T/browser.log")" "0"

  # Another host has no page this tool can name either.
  git -C "$FR" remote set-url origin "https://gitlab.example.com/alice/dots.git"
  : > "$T/browser.log"
  o98c=$(env HOME="$FH" PATH="$T/fakebin:$PATH" "$CLI" open --remote 2>&1); rcc=$?
  eq "a non-github remote refuses" "$rcc" "1"
  has "and says why" "$o98c" "no web page is known"
  eq "and launches nothing either" "$(wc -c < "$T/browser.log")" "0"

  # No origin at all is its own message: there is nothing to open, rather than
  # something this tool cannot name.
  git -C "$FR" remote remove origin
  : > "$T/browser.log"
  o98d=$(env HOME="$FH" PATH="$T/fakebin:$PATH" "$CLI" open --remote 2>&1); rcd=$?
  eq "no remote refuses" "$rcd" "1"
  has "and says there is no remote" "$o98d" "no remote"
  eq "and launches nothing at all" "$(wc -c < "$T/browser.log")" "0"
  git -C "$FR" remote add origin "$BARE"

  # A typo is a usage error, exit 2, like every other verb's.
  fails "open rejects an unknown flag" env HOME="$FH" "$CLI" open --bogus
  eq "and exits 2 for it" "$(env HOME="$FH" "$CLI" open --bogus >/dev/null 2>&1; echo $?)" "2"
  # Bare `open` is deliberately NOT exercised here: it launches a real terminal
  # on whoever is running the suite. The flag loop is proven by --bogus above
  # and by the --remote cases; the terminal path itself is unchanged.
fi

if group 99 "a snapshot that refuses says so at once, instead of looking healthy for two days"; then
  # manifests/.last-run only moves when a run FINISHES, so a run that refuses
  # left the previous run's timestamp standing and health said nothing until
  # staleDays had passed. On the owner's laptop that was four hours of refused
  # snapshots reported as a healthy backup, while the drift line -- scanned
  # before the gate that refused -- said every allowlisted path was captured.
  mk_fixture g99; seed_home; allow '.config/mytool'; commit_baseline
  rec99="$OMABACKUP_STATE_DIR/last-run.json"
  eq "a successful run records itself as ok" "$(jq -r .ok "$rec99")" "true"
  # The fixture snapshots with --no-push, so it always carries "no upstream
  # configured". What matters here is that nothing reports a refused run.
  eq "and nothing claims the run refused" \
    "$(obj status | jq -r '[.problems[] | select(test("refused"))] | length')" "0"

  # A credential-shaped filename stops the run at the filename gate, which is
  # a refusal with a reason, exactly like the secret scan that bit the owner.
  ghp99="$FH/.config/mytool/ghp_$(rand_body 20).txt"
  printf 'x\n' > "$ghp99"
  fails "the run refuses" env HOME="$FH" "$CLI" snapshot --no-push
  eq "the refusal is recorded, not just logged" "$(jq -r .ok "$rec99")" "false"
  has "with the reason that stopped it" "$(jq -r .reason "$rec99")" "credential-looking filename"
  # ...and the panel says so NOW, on a stamp that is seconds old.
  st99=$(obj status)
  eq "status is a fault straight away" "$(jq -r .state <<<"$st99")" "fault"
  eq "on a last_run that is not remotely stale" "$(jq -r .last_run_age_days <<<"$st99")" "0"
  has "and the problem names the refusal" "$(jq -r '.problems[]' <<<"$st99")" "the last snapshot refused"
  has "and carries the reason with it" "$(jq -r '.problems[]' <<<"$st99")" "credential-looking filename"

  # A dry run is an inspection, not a backup attempt: it must not file a
  # verdict about the backup in either direction.
  before99=$(cat "$rec99")
  fails "a dry run refuses too" env HOME="$FH" "$CLI" snapshot --dry-run
  eq "but records nothing of its own" "$(cat "$rec99")" "$before99"

  # Fixing it clears the fault on the next run. No timer, no waiting.
  rm -f "$ghp99"
  check "the next run succeeds" env HOME="$FH" "$CLI" snapshot --no-push
  eq "the record flips back to ok" "$(jq -r .ok "$rec99")" "true"
  eq "and the refusal is gone from status" \
    "$(obj status | jq -r '[.problems[] | select(test("refused"))] | length')" "0"

  # A run the unit KILLED never reaches the refusal path, so systemd's
  # OnFailure hook files it instead. That is the only path guaranteed to run.
  check "notify-failure records a killed run" env HOME="$FH" "$CLI" notify-failure snapshot
  eq "as a failure" "$(jq -r .ok "$rec99")" "false"
  has "with what that path actually knows" "$(jq -r .reason "$rec99")" "did not finish"
  has "and status reports it" "$(jq -r '.problems[]' <<<"$(obj status)")" "the last snapshot refused"

  # ...but it must never overwrite a reason the refusal itself explained. The
  # generic "did not finish" landing on top of "gitleaks found a secret" is
  # the difference between a fixable message and a trip to the journal.
  check "a run succeeds first" env HOME="$FH" "$CLI" snapshot --no-push
  printf 'x\n' > "$ghp99"
  fails "then one refuses with a reason" env HOME="$FH" "$CLI" snapshot --no-push
  check "and OnFailure fires after it" env HOME="$FH" "$CLI" notify-failure snapshot
  has "the specific reason survives" "$(jq -r .reason "$rec99")" "credential-looking filename"
  rm -f "$ghp99"

  # A run the unit kills after an EARLIER run refused must be reported as
  # "did not finish", not with the older run's gate reason: status would
  # otherwise go on naming a gate that may already be fixed (Codex, PR 9).
  # run_record_start is what makes this correlate: a new run clears the
  # verdict, so a false can only have come from this run's own refusal.
  printf 'x\n' > "$ghp99"
  fails "an earlier run refuses with a reason" env HOME="$FH" "$CLI" snapshot --no-push
  has "leaving that reason on record" "$(jq -r .reason "$rec99")" "credential-looking filename"
  rm -f "$ghp99"
  # Now a run that starts and is killed before it can refuse or finish.
  env HOME="$FH" "$CLI" snapshot --no-push >/dev/null 2>&1 &
  k99=$!
  sleep 0.3
  kill -9 $k99 2>/dev/null; wait $k99 2>/dev/null || true
  check "OnFailure fires for the killed run" env HOME="$FH" "$CLI" notify-failure snapshot
  has "and it is reported as not finishing" "$(jq -r .reason "$rec99")" "did not finish"
  eq "not with the older gate's reason" \
    "$(jq -r .reason "$rec99" | grep -c 'credential-looking' || true)" "0"
  # The widget watches status.json and nothing else, so the failure hook has
  # to refresh it rather than leaving the popup on the last healthy state.
  has "and status.json carries the refusal too" \
    "$(jq -r '.problems[]' "$OMABACKUP_STATE_DIR/status.json")" "the last snapshot refused"
  check "a run succeeds again" env HOME="$FH" "$CLI" snapshot --no-push

  # A leftover failure from before the last successful run must not nag: the
  # record is compared against the stamp, not trusted on its own.
  check "a later run succeeds" env HOME="$FH" "$CLI" snapshot --no-push
  jq '.ok=false | .reason="stale leftover" | .at=1' "$rec99" > "$T/r99" && mv "$T/r99" "$rec99"
  eq "a failure older than the last good run is ignored" \
    "$(obj status | jq -r '[.problems[] | select(test("refused"))] | length')" "0"
fi

if group 52 "the Commit button commits every edit status counts, and only what it showed"; then
  # status counted every dirty path outside the snapshot's own four, and the
  # button staged a hardcoded five list files. Anything in the first set and
  # not the second -- the owner's case was a Claude skill file living in the
  # data repo through a symlink -- was an "N uncommitted" nothing could clear.
  mk_fixture g52; seed_home; commit_baseline
  mkdir -p "$FR/bin"; printf 'echo 1\n' > "$FR/bin/foo"; printf 'old\n' > "$FR/old-note.md"
  git -C "$FR" add bin/foo old-note.md && git -C "$FR" commit -qm "hand-kept files"
  git -C "$FR" push -q -u origin main 2>/dev/null || true

  # The staged scan is part of what this group proves, so it must decide on a
  # machine without gitleaks too: the same fake group 65 uses.
  GL52=""
  if ! command -v gitleaks >/dev/null; then
    mkdir -p "$T/fakebin"
    cat > "$T/fakebin/gitleaks" <<'FAKEGL'
#!/bin/sh
case " $* " in
  *" --staged "*)
    if git diff --cached 2>/dev/null | grep -q 'sk-ant-'; then
      echo "fake gitleaks: anthropic-api-key found in a staged file"
      exit 1
    fi
    ;;
esac
exit 0
FAKEGL
    chmod +x "$T/fakebin/gitleaks"
    GL52="$T/fakebin:"
  fi
  pj52() { env HOME="$FH" PATH="${GL52}$PATH" "$CLI" "$@" --json 2>/dev/null; }

  # Four kinds of edit outside the old watch list: a tracked edit, an untracked
  # file inside an untracked directory, a deletion, and a name that is a glob.
  printf 'echo 2\n' >> "$FR/bin/foo"
  mkdir -p "$FR/.claude/skills/x"; printf 'registry\n' > "$FR/.claude/skills/x/registry.md"
  rm "$FR/old-note.md"
  printf 'literal\n' > "$FR/m*.txt"
  # And two edits that are the snapshot's own turf, which the button must never
  # sweep up. `m*.txt` read as a glob matches manifests/drift.txt, so a button
  # that did not stage its paths literally would commit it.
  printf '# dirty manifest line\n' >> "$FR/manifests/drift.txt"
  printf '\n# edited in the repo copy\n' >> "$FR/home/.bashrc"

  s52=$(pj52 status)
  eq "status names every own edit by its bare path" \
    "$(jq -c '.uncommitted | sort' <<<"$s52")" \
    '[".claude/skills/x/registry.md","bin/foo","m*.txt","old-note.md"]'
  sig52=$(jq -r '.uncommitted_sig // ""' <<<"$s52")
  [[ "$sig52" =~ ^[0-9]+$ ]] && ok "status carries a signature of that list" || bad "no uncommitted_sig" "$sig52"
  has "the login nag names the button's own verb" "$(ob health)" "omabackup push --confirm"

  p52=$(pj52 push)
  eq "push without --confirm asks about exactly the same files" \
    "$(jq -c '[.needs_confirm, (.files | sort)]' <<<"$p52")" \
    '[true,[".claude/skills/x/registry.md","bin/foo","m*.txt","old-note.md"]]'
  eq "and with the same signature" "$(jq -r .sig <<<"$p52")" "$sig52"

  # A file dirtied between the popup drawing the list and the click must not be
  # committed unseen: the signature no longer matches, so the reply asks again.
  head52=$(git -C "$FR" rev-parse HEAD)
  printf 'late\n' > "$FR/late.txt"
  r52=$(pj52 push --confirm "$sig52")
  eq "a stale signature is sent back for confirmation" "$(jq -c '[.ok,.needs_confirm]' <<<"$r52")" '[false,true]'
  has "naming the file that appeared" "$(jq -r '.files[]' <<<"$r52")" "late.txt"
  eq "and nothing was committed" "$(git -C "$FR" rev-parse HEAD)" "$head52"
  fails "a signature that is not a number is refused" pj52 push --confirm 'abc'
  eq "and that commits nothing either" "$(git -C "$FR" rev-parse HEAD)" "$head52"

  sig52=$(jq -r .sig <<<"$r52")
  c52=$(pj52 push --confirm "$sig52")
  eq "the current signature commits" "$(jq -c '[.ok,.committed]' <<<"$c52")" '[true,5]'
  eq "the commit holds exactly the five edits, the deletion included" \
    "$(git -C "$FR" show --name-only --format= HEAD | LC_ALL=C sort | paste -sd' ')" \
    ".claude/skills/x/registry.md bin/foo late.txt m*.txt old-note.md"
  eq "nothing is left for the button" "$(pj52 status | jq -c .uncommitted)" "[]"
  has "the snapshot's manifest edit was not swept up" "$(git -C "$FR" status --porcelain -- manifests)" "drift.txt"
  has "nor its home/ edit" "$(git -C "$FR" status --porcelain -- home)" ".bashrc"
  eq "the commit reached the remote" "$(git -C "$FR" rev-list --count origin/main..main 2>/dev/null || echo x)" "0"
  git -C "$FR" checkout -q -- manifests home

  # A rename staged by hand carries two paths; both are the edit.
  git -C "$FR" mv bin/foo bin/bar
  sig52=$(pj52 status | jq -r .uncommitted_sig)
  eq "a staged rename commits" "$(pj52 push --confirm "$sig52" | jq -r .ok)" "true"
  eq "as a rename, with nothing left behind" \
    "$(git -C "$FR" status --porcelain | grep -c . || true)|$(git -C "$FR" show --name-status --format= HEAD | cut -c1)" "0|R"

  # The snapshot's filename gate applies here too (Codex, PR 10). An adopted
  # repo can already track a credential-named file, .gitignore only hides
  # untracked ones, and the content scan cannot read an encrypted vault.
  printf 'x\n' > "$FR/vault.kdbx"
  git -C "$FR" add -f vault.kdbx && git -C "$FR" commit -qm "a vault someone tracked by hand"
  printf 'y\n' >> "$FR/vault.kdbx"
  head52=$(git -C "$FR" rev-parse HEAD)
  v52=$(pj52 push --confirm)
  eq "an edit to a credential-named file is refused by name" "$(jq -r .ok <<<"$v52")" "false"
  has "saying why" "$(jq -r '.problems[0]' <<<"$v52")" "credential-looking filename"
  eq "and nothing is committed" "$(git -C "$FR" rev-parse HEAD)" "$head52"
  eq "or left staged" "$(git -C "$FR" diff --cached --name-only | grep -c . || true)" "0"
  # Taking it out of the repo is the fix, not the leak.
  rm "$FR/vault.kdbx"
  eq "deleting it commits" "$(pj52 push --confirm | jq -r .ok)" "true"
  eq "as a deletion" "$(git -C "$FR" show --name-status --format= HEAD)" "$(printf 'D\tvault.kdbx')"

  # json_escape drops control bytes, so the dialog would show a name that is
  # not the path the signature binds and git stages (Codex, PR 10).
  printf 'n\n' > "$FR/notes"$'\r'".md"
  head52=$(git -C "$FR" rev-parse HEAD)
  n52=$(pj52 push --confirm)
  eq "a name with a control character is refused, not shown altered" "$(jq -r .ok <<<"$n52")" "false"
  has "saying so" "$(jq -r '.problems[0]' <<<"$n52")" "control character"
  eq "and nothing is committed" "$(git -C "$FR" rev-parse HEAD)" "$head52"
  rm "$FR/notes"$'\r'".md"
  # The same for a byte that is not UTF-8: jq turns it into U+FFFD on its way
  # into status.json, so the dialog would show a name git never stages, and
  # two such names could show as one (Codex, PR 10, second review).
  printf 'b\n' > "$FR/bad"$'\xff'".md"
  b52=$(pj52 push --confirm)
  eq "a name that is not UTF-8 is refused, not shown altered" "$(jq -r .ok <<<"$b52")" "false"
  has "saying so" "$(jq -r '.problems[0]' <<<"$b52")" "not valid UTF-8"
  eq "and nothing is committed" "$(git -C "$FR" rev-parse HEAD)" "$head52"
  rm "$FR/bad"$'\xff'".md"

  # Widening what the button commits must not widen what it lets through.
  printf 'TOKEN=sk-ant-api03-%sAA\n' "$(rand_body 90)" > "$FR/bin/tok.sh"
  head52=$(git -C "$FR" rev-parse HEAD)
  t52=$(pj52 push --confirm)
  eq "a secret in a file outside the lists is refused" "$(jq -r .ok <<<"$t52")" "false"
  has "by the staged scan" "$t52" "staged secret scan"
  eq "nothing committed" "$(git -C "$FR" rev-parse HEAD)" "$head52"
  eq "and the staging undone" "$(git -C "$FR" diff --cached --name-only | grep -c . || true)" "0"
  rm "$FR/bin/tok.sh"

  # A list the popup cannot show in full is not one the button may commit.
  mkdir -p "$FR/bulk"
  for i in $(seq 1 1001); do : > "$FR/bulk/f$i"; done
  eq "a long list is capped, with the true count kept" \
    "$(pj52 status | jq -c '[(.uncommitted | length), .uncommitted_truncated, .uncommitted_count]')" '[1000,true,1001]'
  b52=$(pj52 push --confirm)
  eq "and the button refuses it" "$(jq -r .ok <<<"$b52")" "false"
  has "saying how many" "$(jq -r '.problems[0]' <<<"$b52")" "1001"
  rm -r "$FR/bulk"
fi

if group 53 "the vanish guard's second look: it rescues a file, and its wait is a suite-only knob"; then
  # The allowlist guard looks twice before calling an entry missing or GONE,
  # because an Omarchy migration moves a file aside and rewrites it, and a run
  # can catch the path mid-rename. Nothing proved the second look rescued
  # anything, and its fixed five seconds cost this suite a minute or two.
  mk_fixture g53; seed_home
  printf '?.config/flicker.conf\n' >> "$FR/allowlist.txt"; git -C "$FR" commit -qam "an optional entry"
  commit_baseline
  gone53() { grep -c '^GONE .*flicker\.conf' "$FR/manifests/drift.txt" || true; }
  eq "an optional entry that stays away is GONE" "$(gone53)" "1"

  # Back one second in, looked at again four seconds in: rescued.
  ( sleep 1; printf 'back\n' > "$FH/.config/flicker.conf" ) &
  env HOME="$FH" OMABACKUP_SECOND_LOOK=4 "$CLI" snapshot --no-push >/dev/null 2>&1
  wait
  eq "a file back before the second look is not GONE" "$(gone53)" "0"

  # With no wait, the second look comes before the file does.
  rm "$FH/.config/flicker.conf"
  ( sleep 3; printf 'back\n' > "$FH/.config/flicker.conf" ) &
  env HOME="$FH" OMABACKUP_SECOND_LOOK=0 "$CLI" snapshot --no-push >/dev/null 2>&1
  eq "the knob shortens the wait inside the suite" "$(gone53)" "1"
  wait

  # A wait of zero on the daily timer would turn every migration into a GONE
  # row, so outside the suite the knob is dropped and named, like MIN_FILES.
  s53=$(env -u OMABACKUP_IN_SUITE HOME="$FH" OMABACKUP_SECOND_LOOK=0 "$CLI" status --json 2>/dev/null)
  has "outside the suite the knob is ignored and named" "$(jq -r '.problems[]' <<<"$s53")" "OMABACKUP_SECOND_LOOK"
fi

if group 54 "/etc reference copies are never wider than their source"; then
  # install -Dm644 staged every readable /etc file 0644, so a 0600 or 0640 one
  # the user can read landed world-readable in the repo's working tree, and
  # modes.txt recorded the widened mode as if it were the real one.
  mk_fixture g54; seed_home
  E54="$T/etcroot/app"; mkdir -p "$E54"
  printf 'tight\n' > "$E54/tight.conf"; chmod 600 "$E54/tight.conf"
  printf 'group\n' > "$E54/group.conf"; chmod 640 "$E54/group.conf"
  printf '#!/bin/sh\n' > "$E54/hook.sh"; chmod 755 "$E54/hook.sh"
  printf 'target\n' > "$E54/target.conf"; chmod 600 "$E54/target.conf"; ln -s target.conf "$E54/link.conf"
  printf '/etc/app/tight.conf\n/etc/app/group.conf\n/etc/app/hook.sh\n/etc/app/link.conf\n' >> "$FR/etc-allowlist.txt"
  git -C "$FR" commit -qam "four /etc reference copies"
  check "the snapshot runs" env HOME="$FH" OMABACKUP_ETC_ROOT="$T/etcroot" "$CLI" snapshot --no-push
  eq "a 0600 source stays 0600" "$(stat -c %a "$FR/etc/app/tight.conf" 2>/dev/null)" "600"
  eq "a 0640 source stays 0640" "$(stat -c %a "$FR/etc/app/group.conf" 2>/dev/null)" "640"
  eq "a symlink takes its target's mode, not the link's" "$(stat -c %a "$FR/etc/app/link.conf" 2>/dev/null)" "600"
  eq "an executable source is not executable in the repo" "$(stat -c %a "$FR/etc/app/hook.sh" 2>/dev/null)" "644"
  eq "and git records it as a plain file" "$(git -C "$FR" ls-files -s etc/app/hook.sh | cut -d' ' -f1)" "100644"
  modes_has "600 etc/app/tight.conf" && ok "modes.txt records the real mode" || bad "modes.txt widened the mode"
fi

if group 55 "a gitleaks false positive is recorded once, in the data repo's .gitleaksignore"; then
  # The two secret scans named one finding two ways: the staged scan by its
  # repo path, the staging-tree scan by an absolute path under .staging. A
  # fingerprint copied from one refusal satisfied that gate and not the other,
  # and the line that satisfied the other carried this machine's own path.
  if ! command -v gitleaks >/dev/null; then
    echo "  (gitleaks not installed: skipping)"
  else
    mk_fixture g55; seed_home; commit_baseline
    key55="sk-ant-api03-$(rand_body 90)AA"
    printf 'export EXAMPLE_TOKEN=%s\n' "$key55" >> "$FH/.bashrc"
    r55=$(ob snapshot --no-push); rc55=$?
    [[ $rc55 -ne 0 ]] && ok "a credential-shaped line refuses the snapshot" || bad "the snapshot went through"
    # Without -v gitleaks says only "leaks found: 1", so the refusal named no
    # file, no rule and no fingerprint for the user to record.
    has "the refusal names the fingerprint to record" "$r55" "home/.bashrc:anthropic-api-key:3"
    eq "and never prints the value" "$(grep -c -- "$key55" <<<"$r55" || true)" "0"
    printf 'home/.bashrc:anthropic-api-key:3\n' > "$FR/.gitleaksignore"
    git -C "$FR" add .gitleaksignore && git -C "$FR" commit -qm "a recorded false positive"
    check "one repo-relative fingerprint lets it through both scans" env HOME="$FH" "$CLI" snapshot --no-push
    eq "and the line is in the snapshot" "$(git -C "$FR" show HEAD:home/.bashrc | grep -c EXAMPLE_TOKEN)" "1"
    printf 'export OTHER_TOKEN=sk-ant-api03-%sAA # gitleaks:allow\n' "$(rand_body 90)" >> "$FH/.bashrc"
    check "an inline gitleaks:allow does the same" env HOME="$FH" "$CLI" snapshot --no-push
  fi
fi

if group 56 "the last attempt reaches status.json, and a run that stands down on the lock leaves no verdict"; then
  # The popup's Snapshot button starts the unit and returns at once, so the
  # panel has to learn from status.json when the run it asked for has landed.
  # status.json carried only last_run, which a refused run never moves.
  mk_fixture g56; seed_home; allow '.config/mytool'; commit_baseline
  s56=$(obj status)
  eq "a finished run is an ok attempt" "$(jq -c .last_attempt_ok <<<"$s56")" "true"
  [[ "$(jq -r '.last_attempt_at // 0' <<<"$s56")" -ge "$(jq -r .last_run <<<"$s56")" && "$(jq -r '.last_attempt_at // 0' <<<"$s56")" -gt 0 ]] \
    && ok "stamped no earlier than the run's own start" || bad "last_attempt_at missing or before last_run" "$s56"
  ghp56="$FH/.config/mytool/ghp_$(rand_body 20).txt"; printf 'x\n' > "$ghp56"
  fails "a run refuses" env HOME="$FH" "$CLI" snapshot --no-push
  eq "and status carries a failed attempt" "$(obj status | jq -c .last_attempt_ok)" "false"
  rm "$ghp56"
  check "a run succeeds again" env HOME="$FH" "$CLI" snapshot --no-push
  # A run that finds the lock held stands down without starting. It cleared
  # the verdict first, so status said a run was under way with none running.
  ( flock -x 9; sleep 3 ) 9>>"$FR/.lock" &
  _l56=$!
  sleep 0.3
  env HOME="$FH" OMABACKUP_LOCK_WAIT=1 "$CLI" snapshot --no-push >/dev/null 2>&1
  wait "$_l56" 2>/dev/null
  eq "a run that stood down on the lock leaves the last verdict alone" \
    "$(jq -c .ok "$OMABACKUP_STATE_DIR/last-run.json")" "true"
  # In flight: the record a run writes as it starts.
  jq -n '{ok:null, reason:"the run has not finished", at:(now|floor)}' > "$OMABACKUP_STATE_DIR/last-run.json"
  eq "an attempt under way reads as null, not as a verdict" "$(obj status | jq -c .last_attempt_ok)" "null"
  # Record writes are serialised on a sidecar lock. A writer that holds it
  # for longer than the wait is wedged, and a write made without the lock
  # would be the race the lock exists to stop, so the write is skipped and
  # said so; the run's own outcome is unchanged (Codex, PR 13, round two).
  jq -n '{ok:true, reason:"", at:(now|floor)}' > "$OMABACKUP_STATE_DIR/last-run.json"
  ( flock -x 8; sleep 6 ) 8>>"$OMABACKUP_STATE_DIR/.last-run.lock" &
  _w56=$!
  sleep 0.3
  printf 'x\n' > "$ghp56"
  o56=$(ob snapshot --no-push); rc56=$?
  eq "the run still refuses on its own terms" "$rc56" "1"
  has "and says the record was not written" "$o56" "last-run record"
  eq "the stalled writer's record is untouched" "$(jq -c .ok "$OMABACKUP_STATE_DIR/last-run.json")" "true"
  rm "$ghp56"; wait "$_w56" 2>/dev/null
fi

if group 57 "omabackup drift shows GONE rows, live, before the sentinel"; then
  # GONE rows were written only by the snapshot, so the popup showed them and
  # the command the login nag names ("NEW = unbacked, GONE = vanished. Run:
  # omabackup drift") never did.
  mk_fixture g57; seed_home; allow '.config/mytool'
  printf '?.config/was-here.conf\n.config/also-gone.conf\n' >> "$FR/allowlist.txt"
  git -C "$FR" commit -qam "two entries that do not resolve"
  d57=$(ob drift)
  has "an optional entry that does not resolve is GONE" "$d57" "GONE       ~/.config/was-here.conf"
  has "and so is a required one" "$d57" "GONE       ~/.config/also-gone.conf"
  eq "the sentinel is still the last line" "$(tail -1 <<<"$d57")" "# drift-scan-complete"
  eq "and nothing calls a report with GONE rows clean" "$(grep -c '^# clean' <<<"$d57" || true)" "0"
  eq "--json carries them as GONE, and complete" \
    "$(obj drift | jq -c '[.complete, ([.items[] | select(.type=="GONE") | .path] | sort)]')" \
    '[true,["~/.config/also-gone.conf","~/.config/was-here.conf"]]'
fi

if group 58 "ERROR rows are faults, not paths to triage"; then
  # An ERROR row has no buttons, so counting it as drift put a number on the
  # badge that nothing in the popup could bring down.
  mk_fixture g58; seed_home; commit_baseline
  printf 'NEW        ~/.config/one.toml\n# ERROR: omarchy stock config tree not found at /nowhere\n# drift-scan-complete\n' > "$FR/manifests/drift.txt"
  s58=$(obj status)
  eq "the ERROR row is not counted as drift" "$(jq -r .drift_count <<<"$s58")" "1"
  eq "it is still a fault" "$(jq -r .state <<<"$s58")" "fault"
  has "with the failed check named" "$(jq -r '.problems[]' <<<"$s58")" "stock config tree not found"
  eq "and the row is still there to read" "$(jq -r '[.drift[] | select(.type=="ERROR")] | length' <<<"$s58")" "1"
  # The snapshot's own drift_count comes from a different counter, and it
  # counted ERROR rows while status did not (Codex, PR 13). A stock tree that
  # is not there makes the live scan write an ERROR row of its own.
  j58=$(env HOME="$FH" OMABACKUP_STOCK_DIR="$T/nowhere" "$CLI" snapshot --no-push --json 2>/dev/null)
  eq "the live scan wrote an ERROR row" "$(grep -c '^# ERROR' "$FR/manifests/drift.txt" || true)" "1"
  eq "snapshot --json counts drift the way status does, ERROR rows excluded" \
    "$(jq -r .drift_count <<<"$j58")" "$(obj status | jq -r .drift_count)"
fi

if group 59 "the new-drift toast is normal urgency, and open --report shows the report"; then
  mk_fixture g59; seed_home
  mkdir -p "$T/fakebin"
  for n in notify-send omarchy-notification-send; do
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/notify.log"\n' "$T" > "$T/fakebin/$n"; chmod +x "$T/fakebin/$n"
  done
  : > "$T/notify.log"
  env INVOCATION_ID=fixture OMABACKUP_NOTIFY=1 PATH="$T/fakebin:$PATH" HOME="$FH" "$CLI" snapshot --no-push >/dev/null 2>&1
  has "a timer run with new drift sends the toast" "$(cat "$T/notify.log")" "new unbacked"
  eq "at normal urgency: new drift is news, not an emergency" \
    "$(grep 'new unbacked' "$T/notify.log" | grep -c -- '-u critical' || true)" "0"

  # Triage opened a bare shell in the data repo. It opens the report the
  # popup is showing, argv only, the same launcher.
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/open.argv"\nexit 0\n' "$T" \
    > "$T/fakebin/omarchy-launch-floating-terminal-with-presentation"
  chmod +x "$T/fakebin/omarchy-launch-floating-terminal-with-presentation"
  # The pager is faked too: CI's container has none, and the assertion is
  # about the argv the launcher gets, not about less.
  printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/less"; chmod +x "$T/fakebin/less"
  : > "$T/open.argv"
  eq "open --report: accepted" \
    "$(env PATH="$T/fakebin:$PATH" HOME="$FH" "$CLI" open --report --json 2>/dev/null | jq -r .ok)" "true"
  _d59=$(( $(date +%s) + 5 ))
  while [[ ! -s "$T/open.argv" && $(date +%s) -lt $_d59 ]]; do sleep 0.1; done
  has "the terminal runs a pager" "$(cat "$T/open.argv" 2>/dev/null)" "^less$"
  has "on the drift report" "$(cat "$T/open.argv" 2>/dev/null)" "$FR/manifests/drift.txt"
fi

if group 100 "status and snapshot agree on the drift count, TOOBIG and EXCLUDED included"; then
  # health_collect (status) counted every non-ERROR row, and
  # manifests_drift_counts (snapshot) filtered with DRIFT_CLASSES, which never
  # matched TOOBIG or EXCLUDED lines at all: a report with either disagreed
  # between the two --json replies, and the popup and the badge could show
  # two different numbers for the same report.
  mk_fixture g100; seed_home; allow '.config/mytool'; commit_baseline
  # A TOOBIG row (group 36's fixture): a live file over maxFileSize inside an
  # allowlisted directory.
  head -c 12000000 /dev/urandom > "$FH/.config/mytool/huge.dat"
  # An EXCLUDED row (group 32's fixture): a live file the allowlist covers but
  # the data repo's own .gitignore matches (share/data.gitignore: *.sqlite).
  printf 'x\n' > "$FH/.config/mytool/cache.sqlite"
  j100=$(obj snapshot --no-push)
  s100=$(obj status)
  grep -q '^TOOBIG' "$FR/manifests/drift.txt" && ok "the fixture produced a TOOBIG row" \
    || bad "no TOOBIG row; fixture is not exercising the disagreement"
  grep -q '^EXCLUDED' "$FR/manifests/drift.txt" && ok "the fixture produced an EXCLUDED row" \
    || bad "no EXCLUDED row; fixture is not exercising the disagreement"
  actionable100=$(jq -r '[.drift[] | select(.type != "ERROR")] | length' <<<"$s100")
  eq "status --json .drift_count is the number of non-ERROR rows in .drift" \
    "$(jq -r .drift_count <<<"$s100")" "$actionable100"
  eq "snapshot --json .drift_count agrees with status --json .drift_count" \
    "$(jq -r .drift_count <<<"$j100")" "$(jq -r .drift_count <<<"$s100")"
fi

if group 101 "the triage verbs honour --json: one human line without it, one object with it"; then
  # Service.qml appends --json to every call it makes, so the popup's contract
  # is untouched; a person typing the verb gets a sentence instead of a JSON
  # object they have to read back through jq. Exit codes do not move: 0 ran,
  # 1 refused, 2 usage, in both modes.
  mk_fixture g101; seed_home; commit_baseline
  # shellcheck disable=SC2088  # matching the LITERAL "~/" status emits, not a path to expand
  tp101() { printf '~/%s' "$1"; }
  # The human mode with stderr dropped: these assertions also prove that the
  # one line is ALL that reaches stdout.
  obh() { env HOME="$FH" "$CLI" "$@" 2>/dev/null; }
  mkdir -p "$FH/.config/appy"
  printf 'y=1\n' > "$FH/.config/appy/y.toml"
  printf 'w=1\n' > "$FH/.config/appy/w.toml"
  printf 'v=1\n' > "$FH/.config/appy/v.toml"
  { printf 'NEW        ~/.config/appy/y.toml\n'
    printf 'NEW        ~/.config/appy/w.toml\n'
    printf 'NEW        ~/.config/appy/v.toml\n'
    printf 'GONE       ~/.config/gone101\n'
    printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"

  a101=$(obh allow "$(tp101 .config/appy/y.toml)"); a101rc=$?
  eq "allow: one human line, no JSON" "$a101" "allowed ~/.config/appy/y.toml"
  eq "allow: exit 0" "$a101rc" "0"
  eq "allow --json: the object the widget has always read" \
    "$(obj allow "$(tp101 .config/appy/w.toml)" | jq -c '[.ok,.lint_ok,.added]')" \
    '[true,true,".config/appy/w.toml"]'

  # A refusal is one line too, and the same sentence the JSON carries.
  r101=$(obh allow "$(tp101 .config/never101.conf)"); r101rc=$?
  eq "allow: a refusal is one human line" "$r101" \
    "refused: the drift report does not name that path (or the folder is too broad); refresh and retry"
  eq "allow: a refusal still exits 1" "$r101rc" "1"
  rj101=$(obj allow "$(tp101 .config/never101.conf)"); rj101rc=$?
  eq "allow --json: the refusal is still one JSON object" "$(jq -sc length <<<"$rj101")" "1"
  eq "allow --json: and still ok:false" "$(jq -r .ok <<<"$rj101")" "false"
  eq "allow --json: refusing still exits 1" "$rj101rc" "1"
  eq "both modes carry the same reason" "$(jq -r '.problems[0]' <<<"$rj101")" "${r101#refused: }"

  i101=$(obh ignore "$(tp101 .config/appy/v.toml)" 'regenerable')
  eq "ignore: one human line, naming the reason" "$i101" \
    "ignored ~/.config/appy/v.toml (reason: regenerable)"

  # An allowlist entry that no longer resolves: the GONE row above is about
  # this one, and taking it out is what makes lint clean again.
  allow ".config/gone101"
  g101=$(obh resolve-gone "$(tp101 .config/gone101)" remove); g101rc=$?
  eq "resolve-gone: one human line, naming the verb" "$g101" "resolved ~/.config/gone101 (remove)"
  eq "resolve-gone: exit 0" "$g101rc" "0"
  grep -qx '.config/gone101' "$FR/allowlist.txt" && bad "resolve-gone did not remove the entry" \
    || ok "resolve-gone: the entry is gone from allowlist.txt"

  # push: the list edits above are uncommitted, so this is the confirm gate.
  p101=$(obh push); p101rc=$?
  eq "push: the confirm gate refuses in one line" "$p101rc" "1"
  has "push: the line says what is waiting" "$p101" "uncommitted edit"
  has "push: and how to confirm" "$p101" "push --confirm"
  eq "push --json: the confirm gate is unchanged" \
    "$(obj push | jq -c '[.ok,.needs_confirm,(.files|length>0),(.sig|length>0)]')" '[false,true,true,true]'

  t101=$(obh timer status)
  eq "timer status: one human line" "$t101" "timer: enabled=false active=false"
  eq "timer status --json: unchanged" \
    "$(obj timer status | jq -c '[.ok,.enabled,.active]')" '[true,false,false]'
  tb101=$(obh timer sideways); tb101rc=$?
  eq "timer: an unknown verb refuses in one line" "$tb101" "refused: usage: timer pause|resume|status|run"
  eq "timer: and exits 1" "$tb101rc" "1"

  mkdir -p "$T/fakebin"
  for n in omarchy-launch-floating-terminal-with-presentation xdg-terminal-exec; do
    printf '#!/bin/sh\npwd > "%s/open101.cwd"\nexit 0\n' "$T" > "$T/fakebin/$n"
    chmod +x "$T/fakebin/$n"
  done
  : > "$T/open101.cwd"
  o101=$(env PATH="$T/fakebin:$PATH" HOME="$FH" "$CLI" open 2>/dev/null); o101rc=$?
  eq "open: one human line naming where it opened" "$o101" "opened a terminal in $FR"
  eq "open: exit 0" "$o101rc" "0"
  eq "open --json: unchanged" \
    "$(env PATH="$T/fakebin:$PATH" HOME="$FH" "$CLI" open --json 2>/dev/null | jq -r .ok)" "true"

  # --report is a different destination and says so. The pager is faked like
  # group 59's: CI's container has no less, and the line is the subject here.
  printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/less"; chmod +x "$T/fakebin/less"
  : > "$T/open101.cwd"
  or101=$(env PATH="$T/fakebin:$PATH" HOME="$FH" "$CLI" open --report 2>/dev/null); or101rc=$?
  eq "open --report: its own human line" "$or101" "opened the drift report in a terminal"
  eq "open --report: exit 0" "$or101rc" "0"

  # The lint gate's rollback is a reply too. Break the lists first, then make
  # an edit that clears every pre-check and cannot survive lint --no-walk.
  mkdir -p "$FH/.config/appr"; printf 'r=1\n' > "$FH/.config/appr/r.toml"
  printf '.config/no-such-thing-101\n' >> "$FR/allowlist.txt"
  printf 'NEW        ~/.config/appr/r.toml\n# drift-scan-complete\n' > "$FR/manifests/drift.txt"
  lg101=$(obh allow "$(tp101 .config/appr/r.toml)"); lg101rc=$?
  eq "the lint gate refuses in one human line" "$lg101" \
    "refused: lint rejected the edit (rolled back): MISSING .config/no-such-thing-101"
  eq "and exits 1" "$lg101rc" "1"
  grep -qx '.config/appr/r.toml' "$FR/allowlist.txt" && bad "the lint-gate refusal did not roll back" \
    || ok "and the edit was rolled back"
  eq "the same refusal under --json still carries lint_ok:false" \
    "$(obj allow "$(tp101 .config/appr/r.toml)" | jq -c '[.ok,.lint_ok]')" '[false,false]'
  sed -i '/no-such-thing-101/d' "$FR/allowlist.txt"

  # timer pause/resume and both run branches, against a systemctl that says
  # yes to everything. OMABACKUP_SKIP_TIMERS=0 is what lets the unit branch
  # run at all; the rest of this suite sets it to 1.
  printf '#!/bin/sh\necho "$@" >> "%s/sysctl101.log"\nexit 0\n' "$T" > "$T/fakebin/systemctl"
  chmod +x "$T/fakebin/systemctl"
  : > "$T/sysctl101.log"
  tw101() { env PATH="$T/fakebin:$PATH" HOME="$FH" OMABACKUP_SKIP_TIMERS=0 "$CLI" "$@" 2>/dev/null; }
  eq "timer pause: one human line" "$(tw101 timer pause)" "timer paused"
  eq "timer resume: one human line" "$(tw101 timer resume)" "timer resumed"
  eq "timer run: the unit branch names the unit" "$(tw101 timer run)" "snapshot started (the systemd unit)"
  # The wording and the branch, not just the wording: this one really did ask
  # systemd, which is what makes the next assertion a different branch.
  grep -qx -- '--user start --no-block omabackup-snapshot.service' "$T/sysctl101.log" \
    && ok "timer run: and really asked systemd for it" || bad "timer run never reached systemctl"
  # Last in this fixture on purpose: the fallback really does detach a snapshot.
  : > "$T/sysctl101.log"
  eq "timer run: the detached fallback says that instead" \
    "$(env PATH="$T/fakebin:$PATH" HOME="$FH" OMABACKUP_SKIP_TIMERS=1 "$CLI" timer run 2>/dev/null)" \
    "snapshot started (detached, no unit loaded)"
  [[ -s "$T/sysctl101.log" ]] && bad "the detached fallback still called systemctl" \
    || ok "timer run: and the fallback did not touch systemctl"

  # A usage error is still a usage error in both modes: exit 2, and under
  # --json one object carrying usage:true, not a widget-shaped refusal.
  eq "open: an unknown flag exits 2 without --json" \
    "$(env HOME="$FH" "$CLI" open --bogus >/dev/null 2>&1; echo $?)" "2"
  u101=$(obj open --bogus); u101rc=$?
  eq "open --json: an unknown flag exits 2" "$u101rc" "2"
  eq "open --json: and is one usage object" "$(jq -c '[.ok,.usage]' <<<"$u101")" '[false,true]'

  # push's SUCCESS lines need a repo with nothing dirty and a push the gate
  # will allow, which the fixture above no longer is: its own fixture, last.
  mk_fixture g101p; seed_home; commit_baseline
  if command -v gitleaks >/dev/null 2>&1; then
    git -C "$FR" add -A >/dev/null 2>&1; git -C "$FR" commit -qm "settle before the push lines" >/dev/null 2>&1
    # THE LAST LINE, not the whole of stdout. Without --json the engine's own
    # progress log speaks too ("==> Pushed to origin.", log() in lib/common.sh,
    # which has always printed on this path); the reply is what the verb ends
    # on. Under --json log() is silent and stdout is the one object, which the
    # last assertion in this block pins.
    pu101() { env HOME="$FH" "$CLI" push "$@" 2>/dev/null | tail -1; }
    # Nothing dirty, commits waiting: the reply the verb ends on, count zero.
    eq "push: a plain push reports what it committed" "$(pu101)" "committed 0 edit(s)"
    # One list edit, confirmed: the same line with a count.
    printf '\n# an edit for the Commit button\n' >> "$FR/drift-ignore.txt"
    eq "push --confirm: the count is in the line" "$(pu101 --confirm)" "committed 1 edit(s)"
    # An edit that only ever lived in the index (added, then deleted from the
    # working tree) is gone after the unstage, so there is nothing left to
    # stage and the verb takes its own early exit.
    printf 'x\n' > "$FR/ghost101.txt"
    git -C "$FR" add ghost101.txt
    rm -f "$FR/ghost101.txt"
    head101=$(git -C "$FR" rev-parse HEAD)
    eq "push --confirm: an edit that vanished before staging commits nothing" \
      "$(pu101 --confirm)" "committed 0 edit(s)"
    eq "and it really did commit nothing" "$(git -C "$FR" rev-parse HEAD)" "$head101"
    # And the invariant the popup depends on: under --json, stdout is that one
    # object and nothing else, log line included.
    jp101=$(env HOME="$FH" "$CLI" push --confirm --json 2>/dev/null)
    eq "push --json: stdout is one line" "$(wc -l <<<"$jp101")" "1"
    eq "push --json: and it is one JSON object" "$(jq -sc length <<<"$jp101")" "1"
  else
    echo "  (gitleaks not installed: skipping push's success lines)"
  fi
fi

if group 102 "lint --json: problems[] are strings, findings[] keeps the objects"; then
  # problems[] is one shape everywhere now, because Panel.qml renders every
  # entry as text and Service.qml shows problems[0] as the error line. lint's
  # {code,path,note} records are still the useful thing for a tool, so they
  # move to findings[] rather than being thrown away.
  mk_fixture g102; seed_home
  printf '*\n' >> "$FR/drift-ignore.txt"
  printf '/abs/entry\n?.config/absent102/x.conf\n' >> "$FR/allowlist.txt"
  l102=$(obj lint --no-walk)
  eq "lint --json is still one object" "$(jq -sc length <<<"$l102")" "1"
  eq "and still says ok:false when there are problems" "$(jq -r .ok <<<"$l102")" "false"
  eq "every problems[] entry is a string" "$(jq -c '[.problems[]|type]|unique' <<<"$l102")" '["string"]'
  has "the string carries the code" "$(jq -r '.problems[]' <<<"$l102")" "TOOWIDE"
  has "and the entry it is about" "$(jq -r '.problems[]' <<<"$l102")" "ABSOLUTE /abs/entry"
  eq "findings[] keeps the objects" \
    "$(jq -r '[.findings[]|select(.code=="TOOWIDE")]|length' <<<"$l102")" "1"
  eq "one finding per problem" "$(jq -r '(.problems|length) == (.findings|length)' <<<"$l102")" "true"
  eq "a finding still carries code, path and note" \
    "$(jq -r '[.findings[]|select(.code=="ABSOLUTE")][0] | [(.code|type),(.path|type),(.note|type)] | join(",")' <<<"$l102")" \
    "string,string,string"
  eq "notes[] are untouched objects" "$(jq -c '[.notes[]|type]|unique' <<<"$l102")" '["object"]'
  # The human rendering does not change at all.
  h102=$(ob lint --no-walk; true)
  has "the human lint still prints the code" "$h102" "TOOWIDE"
  has "and still counts the problems" "$h102" "problem(s), see above"
fi

if group 103 "status on a data repo it cannot read records the fault, instead of leaving yesterday's file standing"; then
  # data_repo_require die()s before anything is written, so a repo that broke
  # overnight left the widget reading a green status.json from the last good
  # run. The refusal on stdout is unchanged; what changes is that the file the
  # popup reads now says what happened.
  mk_fixture g103; seed_home; commit_baseline
  # An upstream, so the "before" file is the reassuring one this fix is about
  # rather than a fault for an unrelated reason.
  git -C "$FR" push -q -u origin HEAD >/dev/null 2>&1
  obj status >/dev/null; s103arc=$?
  eq "a readable repo still reports normally" "$s103arc" "0"
  eq "and status.json names the repo" "$(jq -r .repo "$OMABACKUP_STATE_DIR/status.json")" "$FR"
  before103=$(jq -r '.generated // 0' "$OMABACKUP_STATE_DIR/status.json")
  eq "status.json is not a fault yet" "$(jq -r '.state == "fault"' "$OMABACKUP_STATE_DIR/status.json")" "false"

  # A full second, so a same-second collision cannot hide a file that was
  # never rewritten.
  sleep 1
  rm -f "$FR/.omabackup"
  s103=$(obj status); rc103=$?
  eq "status refuses" "$rc103" "1"
  eq "and the refusal is still one JSON object" "$(jq -sc length <<<"$s103")" "1"
  eq "with ok:false" "$(jq -r .ok <<<"$s103")" "false"
  has "naming the marker" "$(jq -r .error <<<"$s103")" ".omabackup marker"

  eq "status.json now says fault" "$(jq -r .state "$OMABACKUP_STATE_DIR/status.json")" "fault"
  after103=$(jq -r '.generated // 0' "$OMABACKUP_STATE_DIR/status.json")
  [[ "$after103" -gt "$before103" ]] && ok "and it was rewritten just now" \
    || bad "status.json was not rewritten" "generated $before103 -> $after103"
  has "the reason is in problems[0]" "$(jq -r '.problems[0]' "$OMABACKUP_STATE_DIR/status.json")" \
    "no .omabackup marker"
  eq "problems[] is still an array of strings" \
    "$(jq -c '[.problems[]|type]|unique' "$OMABACKUP_STATE_DIR/status.json")" '["string"]'
  eq "repo is blank, as the not-configured writer leaves it" \
    "$(jq -r .repo "$OMABACKUP_STATE_DIR/status.json")" ""
  eq "the object still carries the whole schema" \
    "$(jq -r 'has("drift") and has("uncommitted") and has("timer_next") and has("push_reason")' "$OMABACKUP_STATE_DIR/status.json")" "true"

  # health is the other verb that reads through data_repo_require, and it is
  # the one that runs at login, so it records the same fault.
  rm -f "$OMABACKUP_STATE_DIR/status.json"
  h103=$(obj health); h103rc=$?
  eq "health refuses too" "$h103rc" "1"
  eq "and its refusal is one JSON object" "$(jq -sc length <<<"$h103")" "1"
  eq "health recorded the fault as well" "$(jq -r .state "$OMABACKUP_STATE_DIR/status.json")" "fault"

  # A write verb must NOT be weakened by any of this: it still refuses outright,
  # and from data_repo_require itself, not from some later gate that happens to
  # say no too. `error` (not `problems`) is what die() emits, and the reason is
  # the marker's.
  # shellcheck disable=SC2088  # the literal "~/" prefix the drift report emits, not a path to expand
  w103=$(obj allow '~/x'); w103rc=$?
  eq "a write verb still refuses a repo with no marker" "$(jq -r .ok <<<"$w103")" "false"
  eq "and it exits 1" "$w103rc" "1"
  has "and the refusal is data_repo_require's own" "$(jq -r '.error // empty' <<<"$w103")" \
    "no .omabackup marker"
fi

if group 104 "an inconclusive probe keeps the date of the last conclusive answer"; then
  # A 403 from the GitHub API proves nothing about visibility, so the run
  # commits and does not push. `at` was rewritten every run, so a machine
  # behind a shared or CGNAT address could sit on probe-403 for weeks with
  # nothing recording how long it had been that way: the popup said "up to
  # date" and the only hint was a reason code. The verdict now carries
  # conclusive_at, carried forward untouched across inconclusive answers.
  mk_fixture g104; seed_home; commit_baseline
  jq '.remote.trusted=false' "$OMABACKUP_CONFIG" > "$T/c104" && mv "$T/c104" "$OMABACKUP_CONFIG" \
    && chmod 600 "$OMABACKUP_CONFIG"
  git -C "$FR" remote set-url origin "https://github.com/o/r"
  mkdir -p "$T/fakebin"
  # nm-online is stubbed for the same reason group 72 stubs it: remote_probe
  # waits on it, and a real one blocks for NET_WAIT seconds when offline.
  printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/nm-online"; chmod +x "$T/fakebin/nm-online"
  V104="$OMABACKUP_STATE_DIR/push-verdict.json"
  # run104 CODE: one real snapshot whose probe gets CODE back from the API.
  run104() {
    fake_curl "$1" "${2:-0}"
    printf '# %s\n' "$1 $SECONDS" >> "$FH/.bashrc"   # something to commit, so each run is a real one
    # PATH104 overrides the WHOLE search path, so the no-gitleaks run below
    # cannot pick the real gitleaks back up off the tail of $PATH.
    env HOME="$FH" PATH="${PATH104:-$T/fakebin:$PATH}" OMABACKUP_NET=1 NET_WAIT=1 \
      "$CLI" snapshot --no-push --json >/dev/null 2>&1 || true
  }
  PATH104=""

  run104 404
  eq "a 404 is a conclusive answer" "$(jq -r .reason "$V104")" "private"
  c104=$(jq -r '.conclusive_at // ""' "$V104")
  [[ "$c104" =~ ^[0-9]+$ ]] && ok "...and the verdict records when it was given" \
    || bad "a conclusive verdict records when it was given" "conclusive_at='$c104'"
  eq "a conclusive verdict has no unverifiable age" \
    "$(obj status | jq -r '.push_unverifiable_days')" "null"
  eq "...and no date for the popup to show" \
    "$(obj status | jq -r '.push_unverifiable_since')" ""

  run104 403
  eq "a 403 proves nothing and is recorded as such" "$(jq -r .reason "$V104")" "probe-403"
  eq "...and the last conclusive answer's date is carried forward" \
    "$(jq -r '.conclusive_at // ""' "$V104")" "$c104"
  eq "...and at is still the time of the last probe, never behind it" \
    "$(jq -r 'if .at >= .conclusive_at then "at or after" else "before" end' "$V104")" "at or after"
  run104 403
  eq "a second inconclusive run keeps it still" "$(jq -r '.conclusive_at // ""' "$V104")" "$c104"
  s104=$(obj status)
  eq "status counts the days since that answer" "$(jq -r .push_unverifiable_days <<<"$s104")" "0"
  eq "...and names the day it went unverifiable" \
    "$(jq -r .push_unverifiable_since <<<"$s104")" "$(date -d "@$c104" +%F)"
  eq "...and says nothing about it yet, inside staleDays" \
    "$(jq -r '[.problems[] | select(startswith("push has been unverifiable"))] | length' <<<"$s104")" "0"

  # Past staleDays the age is a problem in its own right, with the reason and
  # the explanation a user behind a shared address needs.
  b104=$(( $(date +%s) - 9 * 86400 ))
  jq --argjson t "$b104" '.conclusive_at=$t' "$V104" > "$T/v104" && mv "$T/v104" "$V104"
  s104=$(obj status)
  eq "the days are counted from the last conclusive answer" \
    "$(jq -r .push_unverifiable_days <<<"$s104")" "9"
  eq "the ISO date follows it" \
    "$(jq -r .push_unverifiable_since <<<"$s104")" "$(date -d "@$b104" +%F)"
  has "a problem says how long, and which reason" "$(jq -r '.problems[]' <<<"$s104")" \
    "push has been unverifiable for 9 days (probe-403)"
  has "...and why a 403 can last" "$(jq -r '.problems[]' <<<"$s104")" \
    "rate limited per address"

  # ...and the rate-limit sentence belongs to 403 ALONE. probe-000 is no
  # network: curl prints 000 and exits non-zero on a connection failure, which
  # is what a laptop that has been shut in a bag for a week produces. Telling
  # that user their address is rate limited is a confident wrong answer.
  run104 000 7
  eq "a connection failure is probe-000" "$(jq -r .reason "$V104")" "probe-000"
  eq "...and it carries the same date forward" "$(jq -r '.conclusive_at // ""' "$V104")" "$b104"
  s104=$(obj status)
  eq "the age is counted the same way" "$(jq -r .push_unverifiable_days <<<"$s104")" "9"
  has "the problem names probe-000" "$(jq -r '.problems[]' <<<"$s104")" \
    "push has been unverifiable for 9 days (probe-000)"
  eq "...and says nothing about a rate limit" \
    "$(jq -r '[.problems[] | select(contains("rate limited"))] | length' <<<"$s104")" "0"

  # A verdict the stale check has already discarded is not an answer any more,
  # so no streak is dated from it: one silence, one complaint.
  jq --argjson t "$(( $(date +%s) - 40 * 86400 ))" '.at=$t' "$V104" > "$T/v104s" && mv "$T/v104s" "$V104"
  s104=$(obj status)
  eq "a stale verdict reads as stale, as it always did" "$(jq -r .push_reason <<<"$s104")" "stale"
  eq "...and is not dated as a streak" "$(jq -r .push_unverifiable_days <<<"$s104")" "null"
  eq "...and raises no unverifiable-for-N-days problem" \
    "$(jq -r '[.problems[] | select(startswith("push has been unverifiable"))] | length' <<<"$s104")" "0"

  # A clock that has gone backwards leaves the last conclusive answer in the
  # future. Report no age rather than a negative one.
  run104 403
  jq --argjson t "$(( $(date +%s) + 3 * 86400 ))" '.conclusive_at=$t' "$V104" > "$T/v104f" && mv "$T/v104f" "$V104"
  s104=$(obj status)
  eq "a date in the future is no age" "$(jq -r .push_unverifiable_days <<<"$s104")" "null"
  eq "...and no date for the popup either" "$(jq -r .push_unverifiable_since <<<"$s104")" ""
  eq "...and no problem invented from it" \
    "$(jq -r '[.problems[] | select(startswith("push has been unverifiable"))] | length' <<<"$s104")" "0"

  # gitleaks-missing is an answer about THIS MACHINE, not about the remote.
  # The gate writes it over the probe's own verdict on the same run, and
  # treating it as conclusive restarted the clock every day on a machine whose
  # scanner had been uninstalled for a month: the streak this exists to
  # measure could never accumulate there. Neither date moves.
  jq --argjson t "$b104" '.conclusive_at=$t' "$V104" > "$T/v104g" && mv "$T/v104g" "$V104"
  mkdir -p "$T/nogl"; IFS=: read -ra pd104 <<<"$PATH"
  for d104 in ${pd104[@]+"${pd104[@]}"}; do
    [[ -d "$d104" ]] || continue
    for f104 in "$d104"/*; do
      bn104=${f104##*/}
      [[ "$bn104" == gitleaks ]] && continue
      [[ -x "$f104" && ! -d "$f104" ]] || continue
      [[ -e "$T/nogl/$bn104" ]] || ln -s "$f104" "$T/nogl/$bn104"
    done
  done
  if [[ -e "$T/nogl/gitleaks" ]]; then bad "the no-gitleaks PATH still carries gitleaks"; else ok "the no-gitleaks PATH carries no gitleaks"; fi
  PATH104="$T/fakebin:$T/nogl"
  run104 403
  PATH104=""
  eq "with no scanner the gate's own reason is recorded" "$(jq -r .reason "$V104")" "gitleaks-missing"
  eq "...and it leaves the streak's date exactly where it was" \
    "$(jq -r '.conclusive_at // ""' "$V104")" "$b104"

  # A conclusive answer ends the streak: the date resets to now, and the age
  # goes back to null rather than to zero.
  run104 404
  n104=$(jq -r '.conclusive_at // ""' "$V104")
  [[ "$n104" =~ ^[0-9]+$ && "$n104" -gt "$b104" && $(( $(date +%s) - n104 )) -le 300 ]] \
    && ok "a conclusive answer resets the date to now" \
    || bad "a conclusive answer resets the date to now" "conclusive_at='$n104'"
  s104=$(obj status)
  eq "and the unverifiable age is null again" "$(jq -r .push_unverifiable_days <<<"$s104")" "null"
  eq "and the problem is gone" \
    "$(jq -r '[.problems[] | select(startswith("push has been unverifiable"))] | length' <<<"$s104")" "0"

  # Never conclusive at all: the first answer this machine ever got was a 403.
  # There is no conclusive_at to carry, so the streak is dated from the first
  # inconclusive probe instead, and that date is carried forward the same way.
  mk_fixture g104b; seed_home
  jq '.remote.trusted=false' "$OMABACKUP_CONFIG" > "$T/c104b" && mv "$T/c104b" "$OMABACKUP_CONFIG" \
    && chmod 600 "$OMABACKUP_CONFIG"
  git -C "$FR" remote set-url origin "https://github.com/o/r"
  mkdir -p "$T/fakebin"
  printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/nm-online"; chmod +x "$T/fakebin/nm-online"
  V104="$OMABACKUP_STATE_DIR/push-verdict.json"
  run104 403
  eq "a first-ever 403 records no conclusive answer" "$(jq -r '.conclusive_at // "absent"' "$V104")" "absent"
  f104=$(jq -r '.inconclusive_since // ""' "$V104")
  [[ "$f104" =~ ^[0-9]+$ ]] && ok "...but it does record when the streak began" \
    || bad "a first-ever 403 records when the streak began" "inconclusive_since='$f104'"
  run104 403
  eq "and the second 403 carries that date forward" "$(jq -r '.inconclusive_since // ""' "$V104")" "$f104"
  eq "status dates the streak from it" \
    "$(obj status | jq -r .push_unverifiable_since)" "$(date -d "@$f104" +%F)"

  # An upgrade from 0.7.0: a verdict file with neither field, and a malformed
  # one. Neither may error, and neither may invent an age.
  jq 'del(.conclusive_at, .inconclusive_since)' "$V104" > "$T/v104b" && mv "$T/v104b" "$V104"
  s104=$(obj status)
  eq "a pre-0.8.0 verdict still reads" "$(jq -r .push_reason <<<"$s104")" "probe-403"
  eq "...and claims no age it cannot know" "$(jq -r .push_unverifiable_days <<<"$s104")" "null"
  jq '.conclusive_at="yesterday"' "$V104" > "$T/v104c" && mv "$T/v104c" "$V104"
  s104=$(obj status)
  eq "a malformed timestamp is no age either" "$(jq -r .push_unverifiable_days <<<"$s104")" "null"
  eq "and status still answers" "$(jq -r .push_reason <<<"$s104")" "probe-403"
fi

if group 105 "setup check is a doctor: three line shapes, and a missing tool names its own package"; then
  # The human branch used to be `jq to_entries` over the same object --json
  # prints, so a nested object (tools, units, remote) arrived as raw JSON and
  # the only package it ever named was gitleaks. A doctor that cannot say
  # which package to install is a refusal with no way out.
  mk_fixture g105; seed_home
  # A PATH holding everything the CLI needs, so one tool can be taken out of
  # it at a time and nothing else goes missing with it (group 66 builds the
  # same kind of PATH for its no-gitleaks proof). jq is deliberately not one
  # of the tools taken out: bin/omabackup refuses before any verb runs
  # without it, so there is no doctor line to read.
  D105="$T/allbin"; mkdir -p "$D105"
  for b105 in bash sh env jq git rsync flock date cat grep sed awk find mktemp stat chmod \
              mv rm cp ln cut sort tr head tail wc cksum paste readlink dirname basename \
              touch mkdir sleep comm uniq xargs diff cmp; do
    p105=$(command -v "$b105" 2>/dev/null) || continue
    ln -sf "$p105" "$D105/$b105"
  done
  # gum, gitleaks, systemctl and systemd-analyze only have to EXIST for the
  # doctor's probe (this fixture's timer.calendar/timer.jitter are the
  # unedited "daily"/"30m" defaults, so systemd-analyze answering yes to
  # everything is enough); none of the four is installed everywhere this
  # suite runs, and a missing systemd-analyze is now its own FAIL, not
  # something this group is testing.
  for b105 in gum gitleaks systemctl systemd-analyze; do printf '#!/bin/sh\nexit 0\n' > "$D105/$b105"; chmod +x "$D105/$b105"; done
  # A PATH with one binary left out. Built by copying the links rather than by
  # deleting from a shared directory, so the groups below cannot race or leak.
  mk_path105() {
    local omit=$1
    local d="$T/path-$omit" f
    mkdir -p "$d"
    for f in "$D105"/*; do
      [[ "$(basename "$f")" == "$omit" ]] || cp -P "$f" "$d/"
    done
    printf '%s' "$d"
  }

  base105=$(env HOME="$FH" PATH="$D105" "$CLI" setup check 2>/dev/null)
  bad105=$(grep -cvE '^(ok    |warn  |FAIL  )' <<<"$base105" || true)
  eq "every line is an ok, a warn or a FAIL line" "$bad105" "0"
  eq "no nested object reaches the human output as raw JSON" \
    "$(grep -c '[{}]' <<<"$base105" || true)" "0"
  has "and the checks that pass say so" "$base105" "^ok    git$"
  # The README tells anyone recovering a diverged remote to read their data
  # repo path off this report, so the PASSING line has to carry it: the path
  # used to appear only on the branch a healthy machine never takes.
  has "the data repo line carries the path even when it is fine" "$base105" "^ok    data repo ($FR)$"

  # Severity is the exit code, said out loud: FAIL is exactly the set of
  # checks that refuse (the four required tools and the marker), warn is
  # everything else that is wrong. So a FAIL line means exit 1, and exit 0
  # means there was no FAIL line.
  for row105 in git:git:FAIL:1 rsync:rsync:FAIL:1 flock:util-linux:FAIL:1 \
                gum:gum:warn:0 gitleaks:gitleaks:warn:0; do
    IFS=: read -r t105 pkg105 sev105 rc105 <<<"$row105"
    d105=$(mk_path105 "$t105")
    o105=$(env HOME="$FH" PATH="$d105" "$CLI" setup check 2>/dev/null); orc105=$?
    l105=$(grep -E "^$sev105  $t105:" <<<"$o105" || true)
    [[ -n "$l105" ]] && ok "a missing $t105 is one $sev105 line" || bad "a missing $t105 is not one $sev105 line" "$o105"
    has "and the $t105 line names its own package" "$l105" "pacman -S $pkg105"
    eq "and a missing $t105 exits $rc105" "$orc105" "$rc105"
  done

  # The two timer checks are rendered from the same two values --json reports.
  # They used to be gated on OMABACKUP_SKIP_TIMERS, which the suite exports, so
  # the human report silently dropped two checks --json was still answering.
  has "a timer that is not armed is a warn line" "$base105" "^warn  snapshot timer:"
  has "and it names the systemctl line that arms it" "$base105" \
    "systemctl --user enable --now omabackup-snapshot.timer"
  has "the self-test timer too" "$base105" "^warn  self-test timer:"
  # ...and an armed one says ok. OMABACKUP_SKIP_TIMERS=0 lets the probe run,
  # against the stub systemctl in $D105, which answers yes to is-enabled.
  on105=$(env HOME="$FH" PATH="$D105" OMABACKUP_SKIP_TIMERS=0 "$CLI" setup check 2>/dev/null)
  has "an armed snapshot timer says ok" "$on105" "^ok    snapshot timer$"
  has "an armed self-test timer says ok" "$on105" "^ok    self-test timer$"

  # The --json shape is the widget's and it is additive only: the keys that
  # were there before are still there, still with the same types.
  j105=$(env HOME="$FH" PATH="$D105" "$CLI" setup check --json 2>/dev/null)
  eq "setup check --json still prints exactly one object" "$(jq -sc 'length' <<<"$j105" 2>/dev/null || echo 0)" "1"
  eq "and its shape is unchanged" \
    "$(jq -r '[(.ok|type), (.tools.git|type), (.config|type), (.dataRepo|type), (.marker|type), (.units.snapshot|type), (.remote.kind|type)] | join(",")' <<<"$j105")" \
    "boolean,boolean,boolean,boolean,boolean,boolean,string"
fi

if group 106 "every verb answers --help, --remove says how to confirm, and divergence is explained"; then
  mk_fixture g106; seed_home

  # --help is intercepted by the dispatcher, so no lib/ verb parser ever sees
  # it: restore, lint, snapshot, self-test, setup and open used to call it an
  # unknown flag, and drift, status and health quietly ran the whole verb.
  for v106 in setup snapshot drift status allow ignore resolve-gone push lint \
              restore verify health timer self-test open version; do
    h106=$(env HOME="$FH" "$CLI" "$v106" --help 2>&1); rc106=$?
    eq "$v106 --help exits 0" "$rc106" "0"
    has "$v106 --help names the verb" "$h106" "$v106"
    has "$v106 --help is the usage text, not a run" "$h106" "Exit 0 ran, 1 refused or unhealthy, 2 usage."
  done
  eq "-h is the same door" \
    "$(env HOME="$FH" "$CLI" restore -h 2>&1)" "$(env HOME="$FH" "$CLI" restore --help 2>&1)"
  eq "--help under --json is still one JSON object" \
    "$(env HOME="$FH" "$CLI" restore --help --json 2>/dev/null | jq -sc 'length')" "1"
  has "and the object carries the verb's usage" \
    "$(env HOME="$FH" "$CLI" restore --help --json 2>/dev/null | jq -r .usage)" "restore"
  # An unknown verb is still an unknown verb, --help or no --help. The verb
  # is DATA: looked up with a case pattern it was glob text, so a bare "*"
  # matched every row in the table and answered with the whole usage, exit 0.
  eq "a verb that does not exist is still usage (exit 2)" \
    "$(env HOME="$FH" "$CLI" bogus --help >/dev/null 2>&1; echo $?)" "2"
  eq "and a verb that is a glob is not read as one (exit 2)" \
    "$(env HOME="$FH" "$CLI" '*' --help >/dev/null 2>&1; echo $?)" "2"

  # setup --remove with nothing that can ask: the answer is no, and the
  # message has to say how to mean yes. It used to say only "cancelled".
  d106="$T/nogum"; mkdir -p "$d106"
  for b106 in bash sh env jq git rsync flock date cat grep sed awk find mktemp stat chmod \
              mv rm cp ln cut sort tr head tail wc cksum paste readlink dirname basename \
              touch mkdir sleep comm uniq xargs diff cmp; do
    p106=$(command -v "$b106" 2>/dev/null) || continue
    ln -sf "$p106" "$d106/$b106"
  done
  [[ -e "$d106/gum" ]] && bad "the no-gum PATH still carries gum" || ok "the no-gum PATH carries no gum"
  r106=$(env HOME="$FH" PATH="$d106" "$CLI" setup --remove </dev/null 2>&1); rrc106=$?
  eq "setup --remove with no terminal and no gum refuses (exit 1)" "$rrc106" "1"
  has "and the refusal says how to mean yes" "$r106" "--yes"
  [[ -f "$OMABACKUP_CONFIG" ]] && ok "the refused removal removed nothing" || bad "the config went anyway"

  # Divergence, in words a non-developer can act on. The problem used to be
  # "remote has diverged -- pull --rebase needed", a git incantation with no
  # explanation and no recovery for the conflict case; the README carries
  # both now, under a row this text names.
  mk_fixture g106b; seed_home; commit_baseline
  git -C "$FR" push -q -u origin main
  git clone -q -b main "$BARE" "$T/other"
  git -C "$T/other" config user.email t@t; git -C "$T/other" config user.name t
  git -C "$T/other" commit -q --allow-empty -m "from the other machine"
  git -C "$T/other" push -q origin main
  printf '\nexport EDITOR=vim\n' >> "$FH/.bashrc"
  env HOME="$FH" OMABACKUP_NET=1 "$CLI" snapshot --json >/dev/null 2>&1
  p106b=$(env HOME="$FH" OMABACKUP_NET=1 "$CLI" status --json 2>/dev/null | jq -r '.problems[]')
  has "the divergence problem still fires" "$p106b" "diverged"
  has "and points at the README row that carries the recovery" "$p106b" "Remote has diverged"
  eq "and no longer hands a git incantation to a non-developer" \
    "$(grep -c -- 'pull --rebase' <<<"$p106b" || true)" "0"
  # Read from the suite because the message above is a POINTER: it names a
  # README row instead of carrying the command, so a row that gets renamed or
  # deleted leaves the user nowhere, and only an assertion that reads the file
  # catches that. The 20-line window is the row's own length (it holds a
  # fenced command block), narrow enough that a match cannot come from the
  # next row down.
  grep -q '^\* \*\*Remote has diverged\*\*' "$HERE/../README.md" \
    && ok "the README row it names exists" || bad "README has no 'Remote has diverged' troubleshooting row"
  grep -A20 '^\* \*\*Remote has diverged\*\*' "$HERE/../README.md" | grep -q -- 'pull --rebase' \
    && ok "and the row carries the command" || bad "the README row does not carry the pull --rebase command"
  grep -A20 '^\* \*\*Remote has diverged\*\*' "$HERE/../README.md" | grep -q -- 'rebase --continue' \
    && ok "and what to do when it conflicts" || bad "the README row does not say what to do on a conflict"
fi

if group 107 "the human dry run names what every restore stage would do, not just --configs"; then
  # restore_list_would was called for --configs alone. --packages, --plugins
  # and --services filled RESTORE_WOULD and printed it under --json only, so
  # the human dry run of the three stages that install and enable things said
  # nothing at all about what they would install or enable.
  mk_fixture g107; seed_home; commit_baseline
  # Past the stage's 100-entry truncation floor, and none of them installed:
  # the suite's pacman stub answers -Qqen with fakepkg1..120.
  seq -f 'known-native-%03g' 1 100 > "$FR/manifests/pacman-native.txt"
  printf 'known-aur-one\n' > "$FR/manifests/pacman-aur.txt"
  printf 'ok-one.service\n' > "$FR/manifests/systemd-user.txt"
  : > "$FR/manifests/systemd-user-off.txt"
  # id, url, rev: the plugin stage adds anything the TSV names that is not
  # already under ~/.config/omarchy/plugins, and the fixture home has none.
  printf 'known-plugin\thttps://example.invalid/known-plugin\t\n' > "$FR/manifests/omarchy-plugins.tsv"
  git -C "$FR" add -A && git -C "$FR" commit -qm "manifests with one package, one plugin and one unit"

  h107=$(ob restore --packages --plugins --services)
  has "the package stage says how many it would install" "$h107" "\[dry\] --packages"
  has "and names one of them" "$h107" "known-native-001"
  has "and says how many it left out of the listing" "$h107" "more (add --json to list every one)"
  has "the plugin stage says how many it would add" "$h107" "\[dry\] --plugins would add 1 plugin"
  has "and names the plugin" "$h107" "plugin:known-plugin"
  has "the service stage says how many it would enable" "$h107" "\[dry\] --services"
  has "and names the unit" "$h107" "ok-one.service"
  eq "the dry run still changes nothing" \
    "$(git -C "$FR" status --porcelain | grep -c . || true)" "0"
  # --json is unchanged: the same paths, in the same array.
  j107=$(obj restore --packages --plugins --services)
  eq "and --json still lists every one, the AUR package the human listing truncated included" \
    "$(jq -r '[.would_write[] | select(. == "package:known-native-001" or . == "aur:known-aur-one" or . == "plugin:known-plugin" or . == "service:ok-one.service")] | length' <<<"$j107")" "4"

  # A stage with nothing to do still says so. Silence reads as "this stage did
  # not run", and the three stages used to disagree about it.
  : > "$FR/manifests/systemd-user.txt"
  git -C "$FR" commit -qam "no units left to enable"
  eq "a stage with nothing to do prints its zero" \
    "$(ob restore --services | grep -c '\[dry\] --services would enable 0 unit' || true)" "1"
fi

if group 108 "the allowlist floor follows the last committed list, and minAllowlist is the way to trim it"; then
  # The floor was derived from history only once history held 20 or more
  # entries; below that the bootstrap 20 applied. A machine whose config
  # legitimately lives in 15 paths was therefore refused every run, with a
  # message about damage and no way out short of a test-only variable.
  mk_fixture g108
  # mk_fixture pins the floor at 1 so every other group can get on with its
  # own subject. This group is about the derived floor, so it takes the pin out.
  unset OMABACKUP_MIN_ALLOWLIST
  mkdir -p "$FH/.config/f108"
  i108=1
  while [ "$i108" -le 15 ]; do
    printf 'setting=%d\n' "$i108" > "$FH/.config/f108/e$i108.conf"
    printf '.config/f108/e%d.conf\n' "$i108" >> "$FR/allowlist.txt"
    i108=$((i108+1))
  done
  git -C "$FR" commit -qam "15 entries, a legitimate small machine"
  check "a 15-entry allowlist backs up, where the bootstrap 20 refused it" \
    env HOME="$FH" "$CLI" snapshot --no-push

  # The trim is left UNCOMMITTED on purpose: the floor compares the working
  # list against the one the last successful run had, which is HEAD's.
  sed -i '/^\.config\/f108\/e15\.conf$/d' "$FR/allowlist.txt"
  rm -f "$FH/.config/f108/e15.conf"
  check "14 against a committed 15 is inside the floor" \
    env HOME="$FH" "$CLI" snapshot --no-push

  sed -i -e '/^\.config\/f108\/e14\.conf$/d' -e '/^\.config\/f108\/e13\.conf$/d' "$FR/allowlist.txt"
  rm -f "$FH/.config/f108/e14.conf" "$FH/.config/f108/e13.conf"
  f108=$(obj snapshot --no-push)
  eq "12 against a committed 15 is below it" "$(jq -r .ok <<<"$f108")" "false"
  has "the refusal counts both lists and shows its arithmetic" "$(jq -r .error <<<"$f108")" \
    "allowlist has 12 entries; the last successful run had 15, so the floor is 13"
  has "and names the key that lifts it, in the file it goes in" "$(jq -r .error <<<"$f108")" \
    "set minAllowlist in $OMABACKUP_CONFIG"
  eq "nothing was committed by the refused run" \
    "$(git -C "$FR" ls-tree -r --name-only HEAD home/ | grep -c 'f108' || true)" "14"

  jq '.minAllowlist=5' "$OMABACKUP_CONFIG" > "$T/c108" && mv "$T/c108" "$OMABACKUP_CONFIG"
  check "an explicit minAllowlist is the escape hatch, and a known key" \
    env HOME="$FH" "$CLI" snapshot --no-push

  # NO HISTORY. The fixture's HEAD carries a header-only allowlist, so no run
  # has ever committed a list to compare against: the bootstrap floor applies
  # and it is minAllowlist's default.
  mk_fixture g108n
  unset OMABACKUP_MIN_ALLOWLIST
  mkdir -p "$FH/.config/n108"
  i108=1
  while [ "$i108" -le 15 ]; do
    printf 'setting=%d\n' "$i108" > "$FH/.config/n108/e$i108.conf"
    printf '.config/n108/e%d.conf\n' "$i108" >> "$FR/allowlist.txt"
    i108=$((i108+1))
  done
  n108=$(obj snapshot --no-push)
  eq "15 entries with no committed list yet is below the bootstrap floor" "$(jq -r .ok <<<"$n108")" "false"
  has "the refusal says which floor it is" "$(jq -r .error <<<"$n108")" \
    "allowlist has 15 entries, below the bootstrap floor of 20 (minAllowlist)"
  has "and names the config file to set it in" "$(jq -r .error <<<"$n108")" "$OMABACKUP_CONFIG"
  jq '.minAllowlist=10' "$OMABACKUP_CONFIG" > "$T/c108" && mv "$T/c108" "$OMABACKUP_CONFIG"
  check "an explicit minAllowlist lifts the bootstrap floor too" \
    env HOME="$FH" "$CLI" snapshot --no-push
  jq '.minAllowlist="lots"' "$OMABACKUP_CONFIG" > "$T/c108" && mv "$T/c108" "$OMABACKUP_CONFIG"
  has "and a minAllowlist that is not a number is refused like the other integers" \
    "$(obj status | jq -r .error)" "must be integers"

  # setup writes the default config verbatim, so a minAllowlist among the
  # defaults would land in every config ever written and pin the floor at 20
  # on every install: the key's PRESENCE is what says the user chose a floor,
  # and the tool must not choose one on their behalf.
  mk_fixture g108s
  unset OMABACKUP_MIN_ALLOWLIST
  check "unattended setup, local only, no timers" \
    env HOME="$FH" "$CLI" setup --data-repo "$T/setupdata" --no-timers --yes
  eq "the config setup writes does not pin minAllowlist" \
    "$(jq -r 'has("minAllowlist")' "$OMABACKUP_CONFIG")" "false"
fi

if group 109 "one registry owns the scratch directories, and the vanish guard needs none"; then
  # Two verbs, two scratch directories, and each used to install a bare EXIT
  # trap of its own: whichever ran second silently replaced the first, so the
  # first one's directory would have been left behind. No verb runs both in
  # one process today, which is what makes the collision latent; what a black
  # box can prove is that neither leaks, through the one handler both now use.
  mk_fixture g109; seed_home; commit_baseline
  ob drift >/dev/null
  eq "drift leaves no scratch behind" \
    "$(find "$OMABACKUP_STATE_DIR" -maxdepth 1 -name '.drift.*' 2>/dev/null | grep -c . || true)" "0"
  eq "a clean repo verifies" "$(obj verify | jq -r .ok)" "true"
  eq "verify leaves no scratch behind either" \
    "$(find "$OMABACKUP_STATE_DIR" -maxdepth 1 -name 'verify.*' 2>/dev/null | grep -c . || true)" "0"

  # THE VANISH GUARD'S SCRATCH FILE. It used to mktemp under $STATE_DIR and
  # die if it could not, so a state directory nobody can write stopped a
  # backup over a file the guard did not need: the history listing is held in
  # the process now.
  mk_fixture g109v
  i109=1
  while [ "$i109" -le 25 ]; do
    mkdir -p "$FH/.config/v109/d$i109"
    for j109 in 1 2 3 4; do printf 'setting=%d\n' "$j109" > "$FH/.config/v109/d$i109/f$j109.conf"; done
    printf '?.config/v109/d%d\n' "$i109" >> "$FR/allowlist.txt"
    i109=$((i109+1))
  done
  git -C "$FR" commit -qam "25 optional directory entries, 100 files"
  check "the baseline run commits all of it" env HOME="$FH" "$CLI" snapshot --no-push
  rm -rf "$FH/.config/v109/d1"
  chmod 500 "$OMABACKUP_STATE_DIR"
  v109=$(ob snapshot --no-push)
  chmod 700 "$OMABACKUP_STATE_DIR"
  grep -q "refusing to judge vanished entries" <<<"$v109" \
    && bad "the vanish guard still asks for a scratch file" \
    || ok "a state directory that takes no new files no longer stops the vanish guard"
  # The run still refuses, at the drift scan, whose own scratch directory is a
  # separate guard and out of this fix's scope. Getting that far is the proof
  # that the allowlist phase judged the vanished entry without writing a thing.
  has "the run gets past the allowlist phase to the drift scan" "$v109" "drift scan did not complete"

  # ...and the guard still guards. 13 of 25 entries gone is well over
  # maxMissingPct, and the answer comes from the same history listing.
  for i109 in 2 3 4 5 6 7 8 9 10 11 12 13; do rm -rf "$FH/.config/v109/d$i109"; done
  m109=$(obj snapshot --no-push)
  eq "a mass disappearance is still refused" "$(jq -r .ok <<<"$m109")" "false"
  has "with the maxMissingPct refusal" "$(jq -r .error <<<"$m109")" "no longer exist; refusing to run"
  eq "and nothing was committed" \
    "$(git -C "$FR" ls-tree -r --name-only HEAD home/ | grep -c . || true)" "100"
fi

if group 110 "a [ in a filename can be allowed and ignored, and matches only itself"; then
  # Both lists are MATCHED as globs, so a bare `[` in an entry is a character
  # class and never the file it came from. `[[]` is the one spelling every
  # reader here agrees on: a class holding a literal bracket. `*` and `?` have
  # no such spelling and stay refused.
  # shellcheck disable=SC2088  # matching the LITERAL "~/" status emits, not a path to expand
  tp110() { printf '~/%s' "$1"; }
  mk_fixture g110; seed_home
  mkdir -p "$FH/.config/brk"
  printf 'x\n' > "$FH/.config/brk/note[1].conf"
  printf 'y\n' > "$FH/.config/brk/note1.conf"
  printf 'z\n' > "$FH/.config/brk/other[2].conf"
  commit_baseline
  { printf 'NEW        ~/.config/brk/note[1].conf\n'
    printf 'NEW        ~/.config/brk/note1.conf\n'
    printf 'NEW        ~/.config/brk/other[2].conf\n'
    printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"

  a110=$(obj allow "$(tp110 '.config/brk/note[1].conf')")
  eq "allow: a bracket in the name is accepted" "$(jq -r .ok <<<"$a110")" "true"
  eq "the entry is written with the bracket as a one-character class" \
    "$(grep -cxF '.config/brk/note[[]1].conf' "$FR/allowlist.txt")" "1"
  i110=$(obj ignore "$(tp110 '.config/brk/other[2].conf')")
  eq "ignore: a bracket in the name is accepted" "$(jq -r .ok <<<"$i110")" "true"
  eq "and written the same way" \
    "$(grep -cF '.config/brk/other[[]2].conf' "$FR/drift-ignore.txt")" "1"

  check "the next snapshot runs" env HOME="$FH" "$CLI" snapshot --no-push
  check "the bracketed file is in the backup" test -f "$FR/home/.config/brk/note[1].conf"
  fails "and the sibling the raw name would have matched is not" \
    test -f "$FR/home/.config/brk/note1.conf"

  d110=$(ob drift)
  eq "the allowed path is no longer drift" "$(grep -c 'note\[1\]' <<<"$d110" || true)" "0"
  eq "the ignored path is no longer drift" "$(grep -c 'other\[2\]' <<<"$d110" || true)" "0"
  eq "and the sibling still is" "$(grep -c 'note1\.conf' <<<"$d110" || true)" "1"

  l110=$(obj lint)
  eq "lint accepts both escaped entries" "$(jq -r .ok <<<"$l110")" "true"
  eq "and complains about neither" \
    "$(jq -r '[.problems[] | select(.path | test("note|other"))] | length' <<<"$l110")" "0"
  eq "nor calls the escaped ignore entry stale" \
    "$(jq -r '[.notes[] | select(.code == "STALE" and (.path | test("other")))] | length' <<<"$l110")" "0"

  # No spelling resolves these to a literal, so both stay refused.
  printf 'q\n' > "$FH/.config/brk/star*"
  printf 'r\n' > "$FH/.config/brk/quer?"
  { printf 'NEW        ~/.config/brk/star*\n'
    printf 'NEW        ~/.config/brk/quer?\n'
    printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"
  s110=$(obj allow "$(tp110 '.config/brk/star*')")
  eq "a * in the name is still refused" "$(jq -r .ok <<<"$s110")" "false"
  has "and the refusal names only the two it cannot spell" "$(jq -r '.problems[0]' <<<"$s110")" \
    "contains \* or ?"
  eq "a ? in the name is still refused too" \
    "$(obj ignore "$(tp110 '.config/brk/quer?')" | jq -r .ok)" "false"
  eq "and neither was written" \
    "$(grep -cE '^\.config/brk/(star|quer)' "$FR/allowlist.txt" "$FR/drift-ignore.txt" | grep -cv ':0$' || true)" "0"
fi

if group 113 "manifests absorb tool-order jitter (nmcli returns its connections in a different order)"; then
  # A real NetworkManager can hand back the same connections in a different
  # order between two runs seconds apart -- one re-ordered, one restarted --
  # for reasons that carry no meaning. A fake nmcli on PATH plays that back
  # deterministically: same three connections both times, reversed the
  # second call. Prepended ahead of the suite's own nmcli stub (fake_tool,
  # near the top of this file) so this group controls it precisely; every
  # other generator stays on the ordinary fixed stubs.
  mk_fixture g113; seed_home
  mkdir -p "$T/fakebin113"
  nmcli_called="$T/nmcli.called"
  cat > "$T/fakebin113/nmcli" <<EOF
#!/bin/sh
if [ -f "$nmcli_called" ]; then
  printf 'work:802-11-wireless\nhome:802-11-wireless\nlan:802-3-ethernet\n'
else
  : > "$nmcli_called"
  printf 'lan:802-3-ethernet\nhome:802-11-wireless\nwork:802-11-wireless\n'
fi
EOF
  chmod +x "$T/fakebin113/nmcli"
  export PATH="$T/fakebin113:$PATH"
  check "first snapshot runs" ob snapshot --no-push
  n1_113=$(git -C "$FR" rev-list --count HEAD)
  m1_113=$(cat "$FR/manifests/network.txt")
  check "second snapshot runs" ob snapshot --no-push
  n2_113=$(git -C "$FR" rev-list --count HEAD)
  m2_113=$(cat "$FR/manifests/network.txt")
  eq "network.txt is identical despite nmcli's reordering" "$m1_113" "$m2_113"
  if [[ "$n2_113" == "$n1_113" ]]; then
    ok "no second commit from order jitter alone"
  else
    bad "no second commit from order jitter alone" "$(git -C "$FR" diff --stat HEAD~1 HEAD)"
  fi
fi

if group 111 "a newline in pacman's own /etc prose never becomes a row"; then
  # Both /etc sections parse pacman's prose, not an API: there is no `--null`
  # / `-0` form for either the -Qii "Backup Files" list or the -Qqo "No
  # package owns" stderr. A path containing a real newline breaks either
  # parse into two physical lines, and the fragment that still matches the
  # parser's own marker used to become a row on its own, naming a file that
  # was never on disk while the real path it was cut from went unreported.
  # A fake pacman reproduces that split directly, so this does not depend on
  # creating a real file whose name contains a newline.
  mk_fixture g111; seed_home
  mkdir -p "$T/etcroot/sysctl.d"
  good_qii="$T/etcroot/good-backup.conf"; printf 'x\n' > "$good_qii"
  good_dropin="$T/etcroot/sysctl.d/good-dropin.conf"; printf 'vm.swappiness=10\n' > "$good_dropin"
  mkdir -p "$T/fakebin"
  # The dropin-fragment stderr below is scoped to a call that is actually
  # asking about $good_dropin (checked by argument, not fired on every
  # -Qqo call), so a later addition to this group cannot be confused by it.
  cat > "$T/fakebin/pacman" <<PACMAN111
#!/bin/sh
case "\$1" in
  -Qii)
    printf 'Name            : fakepkg\nBackup Files    :\n%s [modified]\n' "$good_qii"
    printf '%s\n%s [modified]\n' "$T/etcroot/newline-fragment-qii-a" "newline-fragment-qii-b"
    ;;
  -Qqo)
    shift
    [ "\$1" = "--" ] && shift
    is_dropin_call=0
    for f in "\$@"; do
      [ "\$f" = "$good_dropin" ] && is_dropin_call=1
    done
    rc=0
    for f in "\$@"; do
      case "\$f" in
        "$good_qii") : ;;
        *) echo "error: No package owns \$f" >&2; rc=1 ;;
      esac
    done
    # The extra line is a clean, well-formed "No package owns" answer for a
    # candidate nobody asked about, standing in for the surviving half of a
    # split (the non-matching residue a real split also produces is not
    # simulated here: any such line would fail the WHOLE batch, per
    # drift_etc_ownership_incomplete, which the mixed-diagnostic case below
    # covers on its own; this case is about the surviving candidate itself).
    if [ "\$is_dropin_call" = 1 ]; then
      echo "error: No package owns newline-fragment-dropin-a" >&2
      rc=1
    fi
    exit "\$rc"
    ;;
esac
exit 0
PACMAN111
  chmod +x "$T/fakebin/pacman"
  d111() { env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_SKIP_ETC=0 OMABACKUP_ETC_ROOT="$T/etcroot" "$CLI" drift; }
  out111=$(d111)
  has "the good modified backup file is still reported" "$out111" "$(printf 'NEW        %s' "$good_qii")"
  has "the good unowned drop-in is still reported" "$out111" "$(printf 'NEW        %s' '/etc/sysctl.d/good-dropin.conf')"
  eq "exactly one unparseable-path ERROR row per split fragment" \
    "$(grep -c 'unparseable /etc path from pacman output' <<<"$out111" || true)" "2"
  has "the -Qii fragment is named in its ERROR row" "$out111" "newline-fragment-qii-b"
  has "the -Qqo fragment is named in its ERROR row" "$out111" "newline-fragment-dropin-a"
  ! grep -qE '^(NEW|MODIFIED)[[:space:]]+.*newline-fragment' <<<"$out111" \
    && ok "neither fragment became a NEW or MODIFIED row" \
    || bad "a fragment became a NEW or MODIFIED row" "$out111"
  eq "the scan still finishes" "$(tail -1 <<<"$out111")" "# drift-scan-complete"

  # A fragment that begins with `-`: without `--` before the candidate
  # array, pacman would read it as an option and the whole batched call
  # could answer nothing for anyone in it, not just the dash-led candidate.
  # The fake pacman below simulates exactly that corruption when it does
  # NOT see a `--`, so this only stays green with `--` actually in place.
  good_qii2="$T/etcroot/good-backup-2.conf"; printf 'x\n' > "$good_qii2"
  printf 'x\n' > "$T/-dash-fragment.conf"
  cat > "$T/fakebin/pacman" <<PACMAN111DASH
#!/bin/sh
case "\$1" in
  -Qii)
    printf 'Name            : fakepkg\nBackup Files    :\n%s [modified]\n' "$good_qii2"
    printf '%s\n%s [modified]\n' "$T/etcroot/dash-fragment-source" "-dash-fragment.conf"
    ;;
  -Qqo)
    shift
    if [ "\$1" = "--" ]; then
      shift
    else
      for f in "\$@"; do
        case "\$f" in
          -*) echo "pacman: invalid option -- '\$f'" >&2; exit 1 ;;
        esac
      done
    fi
    for f in "\$@"; do
      case "\$f" in
        "$good_qii2") : ;;
        *) echo "error: No package owns \$f" >&2 ;;
      esac
    done
    exit 1
    ;;
esac
exit 0
PACMAN111DASH
  chmod +x "$T/fakebin/pacman"
  # cd into $T so the relative dash-led candidate resolves to the file just
  # created there, the way it would resolve relative to wherever this ran.
  d111dash() { ( cd "$T" && env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_SKIP_ETC=0 OMABACKUP_ETC_ROOT="$T/etcroot" "$CLI" drift ); }
  out111dash=$(d111dash)
  has "the dash-led fragment is one ERROR row" "$out111dash" "unparseable /etc path from pacman output (-dash-fragment.conf)"
  has "the good candidate in the same batch is still reported" "$out111dash" "$(printf 'NEW        %s' "$good_qii2")"
  ! grep -qE '^(NEW|MODIFIED)[[:space:]]+.*dash-fragment\.conf$' <<<"$out111dash" \
    && ok "the dash-led fragment never became a NEW or MODIFIED row" \
    || bad "the dash-led fragment became a row of its own" "$out111dash"

  # pacman's ownership check itself can fail for a reason that has nothing
  # to do with any candidate (a locked database, here) -- the -Qii branch
  # infers "owned" from the ABSENCE of a "No package owns" line, so a query
  # that failed outright must never read the same as "everyone is owned".
  good_qii3="$T/etcroot/good-backup-3.conf"; printf 'x\n' > "$good_qii3"
  cat > "$T/fakebin/pacman" <<PACMAN111LOCK
#!/bin/sh
case "\$1" in
  -Qii) printf 'Name            : fakepkg\nBackup Files    :\n%s [modified]\n' "$good_qii3" ;;
  -Qqo) echo "error: could not lock database: File exists" >&2; exit 1 ;;
esac
exit 0
PACMAN111LOCK
  chmod +x "$T/fakebin/pacman"
  d111lock() { env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_SKIP_ETC=0 OMABACKUP_ETC_ROOT="$T/etcroot" "$CLI" drift; }
  out111lock=$(d111lock)
  ! grep -qE "^(NEW|MODIFIED)[[:space:]]+.*good-backup-3\.conf\$" <<<"$out111lock" \
    && ok "an unrelated ownership-query failure never reads as 'owned'" \
    || bad "an unrelated ownership-query failure was silently trusted as owned" "$out111lock"
  n111lock=$(grep -c '^# ERROR' <<<"$out111lock" || true)
  [ "$n111lock" -ge 1 ] \
    && ok "and it is at least one ERROR row instead" \
    || bad "and it is at least one ERROR row instead" "got $n111lock ERROR rows: $out111lock"

  # The ownership check can fail SILENTLY too: a non-zero exit with nothing
  # at all on stderr (a crash, a kill). A bare "stderr is empty" check alone
  # read this exactly like "pacman ran and confirmed everyone is owned"
  # (Codex, PR 6 round 2) -- the fake pacman here reproduces that gap
  # directly: exit 1, print nothing.
  good_qii4="$T/etcroot/good-backup-4.conf"; printf 'x\n' > "$good_qii4"
  cat > "$T/fakebin/pacman" <<PACMAN111SILENT
#!/bin/sh
case "\$1" in
  -Qii) printf 'Name            : fakepkg\nBackup Files    :\n%s [modified]\n' "$good_qii4" ;;
  -Qqo) exit 1 ;;
esac
exit 0
PACMAN111SILENT
  chmod +x "$T/fakebin/pacman"
  d111silent() { env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_SKIP_ETC=0 OMABACKUP_ETC_ROOT="$T/etcroot" "$CLI" drift; }
  out111silent=$(d111silent)
  ! grep -qE "^(NEW|MODIFIED)[[:space:]]+.*good-backup-4\.conf\$" <<<"$out111silent" \
    && ok "a silent ownership-check failure (non-zero exit, no stderr) never reads as owned" \
    || bad "a silent ownership-check failure was silently trusted as owned" "$out111silent"
  n111silent=$(grep -c '^# ERROR' <<<"$out111silent" || true)
  [ "$n111silent" -ge 1 ] \
    && ok "and it is at least one ERROR row instead (silent failure)" \
    || bad "and it is at least one ERROR row instead (silent failure)" "got $n111silent ERROR rows: $out111silent"

  # One valid "No package owns" line beside one unrelated diagnostic: the
  # candidate that DID parse must not be trusted piecemeal while the rest of
  # the batch is quietly ignored. Both this batch's candidates go to ERROR,
  # not a mix of one normal row and one fault.
  good_qii5="$T/etcroot/good-backup-5.conf"; printf 'x\n' > "$good_qii5"
  bad_qii5="$T/etcroot/bad-backup-5.conf"; printf 'x\n' > "$bad_qii5"
  cat > "$T/fakebin/pacman" <<PACMAN111MIXED
#!/bin/sh
case "\$1" in
  -Qii)
    printf 'Name            : fakepkg\nBackup Files    :\n%s [modified]\n' "$good_qii5"
    printf '%s [modified]\n' "$bad_qii5"
    ;;
  -Qqo)
    echo "error: No package owns $bad_qii5" >&2
    echo "error: could not lock database: File exists" >&2
    exit 1
    ;;
esac
exit 0
PACMAN111MIXED
  chmod +x "$T/fakebin/pacman"
  d111mixed() { env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_SKIP_ETC=0 OMABACKUP_ETC_ROOT="$T/etcroot" "$CLI" drift; }
  out111mixed=$(d111mixed)
  ! grep -qE "^(NEW|MODIFIED)[[:space:]]+.*(good|bad)-backup-5\.conf\$" <<<"$out111mixed" \
    && ok "a mix of one valid line and one unrelated diagnostic trusts neither candidate" \
    || bad "a mixed ownership answer produced a normal row instead of failing the whole batch" "$out111mixed"
  n111mixed=$(grep -c '^# ERROR' <<<"$out111mixed" || true)
  [ "$n111mixed" -ge 1 ] \
    && ok "and the batch becomes ERROR rows instead of a mix" \
    || bad "and the batch becomes ERROR rows instead of a mix" "got $n111mixed ERROR rows: $out111mixed"

  # The drop-in section's SECOND `pacman -Qqo` call (the recheck of
  # survivors after the existence filter) asks pacman DIRECTLY about each
  # candidate, unlike the first pass whose answer for any one of them was
  # only ever a side effect of splitting someone else's stderr line -- so
  # it needs the same incomplete-answer guard on its OWN mixed answer, not
  # just inherited safety from the first pass (Codex, PR 6 round 3). The
  # fake pacman below distinguishes the two calls by the leading "--" only
  # the recheck sends.
  good_dropin2="$T/etcroot/sysctl.d/good-dropin-2.conf"; printf 'x\n' > "$good_dropin2"
  cat > "$T/fakebin/pacman" <<PACMAN111RECHECK
#!/bin/sh
case "\$1" in
  -Qii) printf 'Name            : fakepkg\nBackup Files    :\n' ;;
  -Qqo)
    shift
    if [ "\$1" = "--" ]; then
      shift
      echo "error: No package owns \$1" >&2
      echo "error: could not lock database: File exists" >&2
      exit 1
    fi
    for f in "\$@"; do
      echo "error: No package owns \$f" >&2
    done
    exit 1
    ;;
esac
exit 0
PACMAN111RECHECK
  chmod +x "$T/fakebin/pacman"
  d111recheck() { env HOME="$FH" PATH="$T/fakebin:$PATH" OMABACKUP_SKIP_ETC=0 OMABACKUP_ETC_ROOT="$T/etcroot" "$CLI" drift; }
  out111recheck=$(d111recheck)
  ! grep -qE "^(NEW|MODIFIED)[[:space:]]+.*good-dropin(-2)?\.conf\$" <<<"$out111recheck" \
    && ok "the drop-in recheck's own mixed answer trusts no candidate" \
    || bad "the drop-in recheck's mixed answer produced a normal row" "$out111recheck"
  n111recheck=$(grep -c '^# ERROR' <<<"$out111recheck" || true)
  [ "$n111recheck" -ge 1 ] \
    && ok "and the recheck batch becomes ERROR rows instead of a mix" \
    || bad "and the recheck batch becomes ERROR rows instead of a mix" "got $n111recheck ERROR rows: $out111recheck"
fi

if group 112 "two forks per process: the widget's status refresh runs no systemd-analyze, and gitleaks is probed once per subcommand family"; then
  # config_load used to run `systemd-analyze calendar` and `systemd-analyze
  # timespan` on every verb that loads config, including status -- the
  # widget's own refresh -- to validate timer.calendar and timer.jitter, two
  # values only setup ever consumes. A counting stub in place of the real
  # binary proves the fork is gone from status and lands exactly once per
  # field where setup actually writes the units.
  mk_fixture g112; seed_home
  SDA112="$T/fakebin-sda"; mkdir -p "$SDA112"
  SDALOG112="$T/sda-calls.log"; : > "$SDALOG112"
  # A minimal stand-in, not a reimplementation: it logs its own argv and
  # refuses only the two literal values these assertions plant, so the
  # doctor's FAIL line can be exercised without a real systemd on PATH.
  cat > "$SDA112/systemd-analyze" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SDALOG112"
case "\$1 \$3" in
  "calendar bogus-calendar") exit 1 ;;
  "timespan bogus-jitter") exit 1 ;;
esac
exit 0
EOF
  chmod +x "$SDA112/systemd-analyze"
  ob112() { env HOME="$FH" PATH="$SDA112:$PATH" "$CLI" "$@" 2>/dev/null; }
  obj112() { env HOME="$FH" PATH="$SDA112:$PATH" "$CLI" "$@" --json 2>/dev/null; }

  check "status still runs" ob112 status
  eq "status forks systemd-analyze zero times" "$(grep -c . "$SDALOG112" || true)" "0"

  : > "$SDALOG112"
  check "setup writes the units" ob112 setup --data-repo "$FR" --yes
  eq "setup forks systemd-analyze exactly once for the calendar" \
    "$(grep -c '^calendar -- daily$' "$SDALOG112" || true)" "1"
  eq "and exactly once for the jitter" \
    "$(grep -c '^timespan -- 30m$' "$SDALOG112" || true)" "1"
  eq "and nothing else calls it during that setup" "$(wc -l < "$SDALOG112" || true)" "2"

  # setup check is the doctor: a bad timer.calendar is a FAIL line naming the
  # fix, not a die buried in a status refresh.
  jq '.timer.calendar="bogus-calendar"' "$OMABACKUP_CONFIG" > "$T/badcal.json"
  chk112=$(OMABACKUP_CONFIG="$T/badcal.json" ob112 setup check)
  has "a bad timer.calendar is a FAIL line" "$chk112" \
    "^FAIL  timer.calendar: not a systemd OnCalendar expression"
  has "and it names the fix" "$chk112" "edit timer.calendar in $T/badcal.json"

  # Fail closed: with systemd-analyze not merely returning failure but
  # entirely absent from PATH, setup refuses before it writes (or
  # overwrites) any unit file, rather than warning and writing one it never
  # actually validated. A PATH of symlinks to everything already on PATH
  # except systemd-analyze: `command -v` has to find nothing at all, so
  # shadowing it with a stub (like SDA112 above) would not prove the point.
  NSA112="$T/nosdbin112"; mkdir -p "$NSA112"
  cp -as /usr/bin/. "$NSA112"/ 2>/dev/null || true
  rm -f "$NSA112/systemd-analyze"
  if [[ -x "$NSA112/jq" && ! -e "$NSA112/systemd-analyze" ]]; then
    before112=$(grep '^OnCalendar=' "$FH/.config/systemd/user/omabackup-snapshot.timer" 2>/dev/null || true)
    su112=$(env HOME="$FH" PATH="$NSA112" "$CLI" setup --data-repo "$FR" --yes --json 2>/dev/null)
    eq "setup with systemd-analyze absent from PATH refuses" "$(jq -r .ok <<<"$su112")" "false"
    has "and names the missing tool" "$(jq -r .error <<<"$su112")" "systemd-analyze"
    has "and names --no-timers as the way out" "$(jq -r .error <<<"$su112")" "--no-timers"
    eq "the unit already on disk is untouched by the refused write" \
      "$(grep '^OnCalendar=' "$FH/.config/systemd/user/omabackup-snapshot.timer" 2>/dev/null || true)" "$before112"
    chkna112=$(env HOME="$FH" PATH="$NSA112" "$CLI" setup check 2>/dev/null); chkna112rc=$?
    has "and setup check prints FAIL for it, not warn" "$chkna112" \
      "^FAIL  timer.calendar: systemd-analyze not found"
    eq "so setup check exits 1 too" "$chkna112rc" "1"
  else
    echo "  (could not build a systemd-analyze-free PATH: 5 assertions skipped)"
  fi

  # The gitleaks half: a snapshot's two scans (staging tree, then the staged
  # commit) each choose between the modern and legacy subcommand once, and
  # the choice is memoised so a re-entrant caller in the same process cannot
  # reprobe -- lib/secrets.sh's gitleaks_has_dir / gitleaks_has_git.
  GLBIN112="$T/fakebin-gl"; mkdir -p "$GLBIN112"
  GLLOG112="$T/gl-calls.log"; : > "$GLLOG112"
  cat > "$GLBIN112/gitleaks" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$GLLOG112"
exit 0
EOF
  chmod +x "$GLBIN112/gitleaks"
  # The setup call above already ran the fixture's first snapshot (its own
  # phase, not this test's concern), so the repo is clean; an edit is needed
  # so this snapshot actually has something to stage and commit -- otherwise
  # it returns before the staged-commit scan ever runs, and "0" would read as
  # a pass for the wrong reason.
  printf 'export FOO112=bar\n' >> "$FH/.bashrc"
  check "a snapshot runs with the fake gitleaks installed" \
    env HOME="$FH" PATH="$GLBIN112:$PATH" "$CLI" snapshot --no-push
  # This pins one probe per subcommand family for the SNAPSHOT path only:
  # `snapshot` runs both scans (staging tree, then staged commit) in one
  # process, so the memo set by the first is read by the second. The
  # widget's push --confirm path is not covered here -- it runs
  # secrets_scan_staged in a subshell (lib/widget.sh:537), so any memo it
  # sets dies with that subshell and cannot be read back by a caller outside
  # it. That is fine for this process's own probe count (still one fork,
  # since nothing else in that subshell asks again), but it means the memo
  # never crosses the subshell boundary either way.
  eq "one dir --help probe for the whole snapshot" \
    "$(grep -c '^dir --help$' "$GLLOG112" || true)" "1"
  eq "one git --help probe for the whole snapshot" \
    "$(grep -c '^git --help$' "$GLLOG112" || true)" "1"
fi

group_close
if (( ${#GROUP_SECS[@]} > 1 )); then
  echo; echo "slowest groups (seconds):"
  for g in "${!GROUP_SECS[@]}"; do printf '%s %s\n' "${GROUP_SECS[$g]}" "$g"; done | sort -rn | head -5 | sed 's/^/  /'
fi
echo; echo "passed=$pass failed=$fail"
[[ $fail == 0 ]]
