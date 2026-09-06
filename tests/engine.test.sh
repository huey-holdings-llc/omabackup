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
ROOT="${OMABACKUP_TEST_TMP:-$HERE/tmp}/$$"; mkdir -p "$ROOT"
trap 'rm -rf "$ROOT"' EXIT
# Marks a suite as already running, so a self-test verb exercised BY the
# suite (group 00's misuse/recursion assertions) refuses instead of forking
# the whole suite again -- see lib/selftest.sh.
export OMABACKUP_IN_SUITE=1
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
  git init -q --bare "$BARE"
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
group() { # group NN NAME: run unless OMABACKUP_TEST_GROUP selects another
  local n=$1; shift
  [[ -n "${OMABACKUP_TEST_GROUP:-}" && "$OMABACKUP_TEST_GROUP" != "$n" ]] && return 1
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

  # self-test: an unknown flag is a usage error (exit 2), same as every other
  # verb, and self-test refuses to run recursively from inside a suite that
  # is already running (this suite exports OMABACKUP_IN_SUITE=1 at its own
  # top) rather than forking the whole suite again.
  fails "self-test: unknown flag is refused" env HOME="$FH" "$CLI" self-test --help
  [[ $(env HOME="$FH" "$CLI" self-test --help >/dev/null 2>&1; echo $?) == 2 ]] \
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
  mk_fixture g04; seed_home; commit_baseline
  n1=$(git -C "$FR" rev-list --count HEAD)
  # Assert the run SUCCEEDED before counting: "no new commit" is trivially
  # true of a snapshot that refused to run at all.
  ob snapshot --no-push >/dev/null; rc=$?
  [[ $rc -eq 0 ]] && ok "snapshot runs" || bad "snapshot failed (rc=$rc)"
  n2=$(git -C "$FR" rev-list --count HEAD)
  eq "unchanged machine makes no commit" "$n2" "$n1"
  eq "json says committed=false" "$(obj snapshot --no-push | jq -r .committed)" "false"
  eq "working tree left clean" "$(git -C "$FR" status --porcelain)" ""
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
  eq "json names the code" "$(obj lint | jq -r '.problems[0].code')" "TOOWIDE"
  sed -i '$d' "$FR/drift-ignore.txt"
  printf '.config/nonexistent-dir\n' >> "$FR/allowlist.txt"
  has "a required entry that resolves to nothing is MISSING" "$(ob lint; true)" "MISSING"
  sed -i '$d' "$FR/allowlist.txt"
  # An allowlist entry is copied in BOTH directions, so a parent-traversal
  # segment or an absolute path is a hard failure, not a note.
  printf '.config/../../etc\n' >> "$FR/allowlist.txt"
  eq "a '..' segment is TRAVERSAL" "$(obj lint | jq -r '[.problems[].code] | index("TRAVERSAL") != null')" "true"
  sed -i '$d' "$FR/allowlist.txt"
  printf '/etc/passwd\n' >> "$FR/allowlist.txt"
  eq "an absolute entry is ABSOLUTE" "$(obj lint | jq -r '[.problems[].code] | index("ABSOLUTE") != null')" "true"
  sed -i '$d' "$FR/allowlist.txt"
  echo new > "$FH/.local/bin/late"; printf '.local/bin\n' >> "$FR/allowlist.txt"
  check "a file newer than the last run is pending, not NOTBACKEDUP" env HOME="$FH" "$CLI" lint
  check "--no-walk skips the completeness walk" env HOME="$FH" "$CLI" lint --no-walk
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
  mk_fixture g38; seed_home; commit_baseline
  # Backdate the last COMMIT well past staleDays, so a garbage stamp's
  # fallback (last commit time) still catches real staleness instead of
  # silently reading as healthy.
  old_ts=$(( $(date +%s) - 10*86400 ))
  GIT_COMMITTER_DATE="@$old_ts" git -C "$FR" commit -q --allow-empty -m "old" --date="@$old_ts"
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
  mk_fixture g43; seed_home; commit_baseline
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
  mk_fixture g46; seed_home
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
    [[ -z "$(git -C "$FR" status --porcelain -- allowlist.txt drift-ignore.txt etc-allowlist.txt normalize.txt .gitleaks.toml)" ]] \
      && ok "push --confirm: tracked list edits committed" || bad "tracked list edits still dirty"
    git -C "$FR" status --porcelain -- manifests | grep -q drift.txt \
      && ok "push --confirm: snapshot-owned paths were NOT swept up" || bad "scoped add leaked into manifests/"
    [[ "$(git -C "$FR" rev-list --count 'origin/main..main' 2>/dev/null || echo 1)" == 0 ]] \
      && ok "push --confirm: commit reached the remote" || bad "commit never pushed"
  else
    echo "  (gitleaks not installed: skipping push --confirm assertions)"
  fi
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
  [[ -f "$T/data/allowlist.txt" && -f "$T/data/drift-ignore.txt" && -f "$T/data/.gitleaks.toml" ]] && ok "seeds copied" || bad "seeds missing"
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
  # mk_fixture pre-authors a config that already trusts $BARE, and a rerun
  # against an unchanged remote now keeps a trust decision the operator
  # already made. Clear it first, so the assertion below tests what it says:
  # an unattended run must never turn trust ON by itself.
  jq '.remote.trusted=false' "$OMABACKUP_CONFIG" > "$T/c61" && mv "$T/c61" "$OMABACKUP_CONFIG" && chmod 600 "$OMABACKUP_CONFIG"
  check "import writes the marker" env HOME="$FH" "$CLI" setup --import "$FR" --no-timers --yes
  eq "marker format 1" "$(jq -r .format "$FR/.omabackup")" "1"
  # Nothing else ever commits the marker: the snapshot commits its four output
  # paths and push --confirm the five lists, so an uncommitted .omabackup meant
  # a clone of the adopted repo carried no marker and every verb refused it.
  eq "the adoption leaves the repo clean" "$(git -C "$FR" status --porcelain | grep -c . || true)" "0"
  if git -C "$FR" log -1 --name-only --format= | grep -qx '.omabackup'; then
    ok "the adoption commit names .omabackup"
  else
    bad "the marker was not committed" "$(git -C "$FR" log -1 --oneline --name-only)"
  fi
  # $FR's origin is $BARE, a local path: not GitHub. An unattended run
  # (--yes, no tty, no --trust-remote) must never turn trust on for it.
  eq "unattended import never turns trust ON for a non-GitHub remote" \
    "$(jq -r .remote.trusted "$OMABACKUP_CONFIG")" "false"

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
  # The push button stages the five watched list files and commits them. That
  # path had NO content scan at all, so a token pasted into .gitleaks.toml (or
  # any other list) was committed and then pushed by the very next line.
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
  has "the refusal names the floor" "$f66" "floor 99"

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
  git clone -q "$BARE" "$T/other"
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
  eq "the code is BADRULE" "$(jq -r '[.problems[]|select(.code=="BADRULE")]|length' <<<"$l71")" "1"
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
    "$(obj lint --no-walk | jq -r '[.problems[]|select(.code=="BADRULE")]|length')" "1"
  eq "snapshot refuses the traversal path" "$(obj snapshot --no-push | jq -r .ok)" "false"
  eq "the file above the data repo is untouched" "$(cat "$T/victim.txt")" "ORIGINAL"
  cp "$T/normalize.bak" "$FR/normalize.txt"

  printf '/etc/passwd\ts/a/b/\n' >> "$FR/normalize.txt"
  eq "lint refuses an absolute path as BADRULE" \
    "$(obj lint --no-walk | jq -r '[.problems[]|select(.code=="BADRULE")]|length')" "1"
  cp "$T/normalize.bak" "$FR/normalize.txt"

  # A syntax error stays BADSED: the two codes say different things, and only
  # one of them means "this rule tried to leave its box".
  printf 'home/.bashrc\ts/unterminated\n' >> "$FR/normalize.txt"
  b71=$(obj lint --no-walk)
  eq "a syntax error is still BADSED" "$(jq -r '[.problems[]|select(.code=="BADSED")]|length' <<<"$b71")" "1"
  eq "and it is not reported as BADRULE" "$(jq -r '[.problems[]|select(.code=="BADRULE")]|length' <<<"$b71")" "0"
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
  mk_fixture g76; seed_home; commit_baseline
  if ! command -v pacman >/dev/null; then
    echo "  (pacman not installed: skipping the package half)"
  else
    # Both manifests are replaced with a KNOWN set, so the "well-formed
    # entries still enumerate" assertion below can name an exact result
    # instead of a count that no input could ever fail.
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
  cat > "$T/fakebin/pacman" <<'FAKEOK'
#!/bin/sh
case "$1" in
  -Qii) printf 'Name            : fakepkg\nBackup Files    :\n/etc/fstab [modified]\n'; exit 0 ;;
  -Qqo) shift; for f in "$@"; do echo "error: No package owns $f" >&2; done; exit 1 ;;
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
  jq '.timer={calendar:"daily|; s|ExecStart=.*|ExecStart=/bin/sh -c evil|", jitter:"30m"}' \
    "$OMABACKUP_CONFIG" > "$T/bad.json"
  b85=$(OMABACKUP_CONFIG=$T/bad.json obj status)
  eq "a calendar carrying a sed delimiter is refused at load" "$(jq -r .ok <<<"$b85")" "false"
  has "the refusal names the key" "$(jq -r .error <<<"$b85")" "timer.calendar"
  jq '.timer={calendar:"daily", jitter:"every other tuesday"}' "$OMABACKUP_CONFIG" > "$T/bad2.json"
  eq "a jitter systemd cannot parse is refused too" \
    "$(OMABACKUP_CONFIG=$T/bad2.json obj status | jq -r .ok)" "false"
  has "the refusal names that key" \
    "$(OMABACKUP_CONFIG=$T/bad2.json obj status | jq -r .error)" "timer.jitter"
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

  # ...and a machine with no systemd-analyze says so, rather than only warning
  # into a timer's journal. A PATH of symlinks to everything in /usr/bin
  # except systemd-analyze: `command -v` has to find nothing at all, so
  # shadowing it with a stub would not do.
  nsa85="$T/nosdbin"; mkdir -p "$nsa85"
  cp -as /usr/bin/. "$nsa85"/ 2>/dev/null || true
  rm -f "$nsa85/systemd-analyze"
  if [[ -x "$nsa85/jq" && ! -e "$nsa85/systemd-analyze" ]]; then
    jq '.timer={calendar:"daily", jitter:"30m"}' "$OMABACKUP_CONFIG" > "$T/c" && mv "$T/c" "$OMABACKUP_CONFIG"
    n85=$(env HOME="$FH" PATH="$nsa85" "$CLI" status --json 2>/dev/null)
    has "an unvalidated timer setting is a problem, not just a warning" \
      "$(jq -r '.problems[]' <<<"$n85")" "timer settings not validated"
    eq "and that makes the state a fault" "$(jq -r .state <<<"$n85")" "fault"
    eq "the same run with systemd-analyze present says nothing of the kind" \
      "$(obj status | jq -r '[.problems[] | select(contains("not validated"))] | length')" "0"
    # The loss event in full: the backslash value on the machine that has no
    # systemd-analyze to catch it. The character class is the only thing
    # standing between that value and awk.
    eq "and the backslash value is still refused with no systemd-analyze at all" \
      "$(OMABACKUP_CONFIG=$T/bs.json env HOME="$FH" PATH="$nsa85" "$CLI" status --json 2>/dev/null | jq -r .ok)" "false"
    eq "the unit never gets written with an injected directive" \
      "$(grep -c 'ExecStart=/bin/sh' "$FH/.config/systemd/user/omabackup-snapshot.timer" || true)" "0"
  else
    # A skip says what it skipped and how much: a silent one reads as five
    # assertions that passed, and the suite total moves with no explanation.
    echo "  (could not build a systemd-analyze-free PATH: 5 assertions skipped)"
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
  mk_fixture g91e; seed_home
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

echo; echo "passed=$pass failed=$fail"
[[ $fail == 0 ]]
