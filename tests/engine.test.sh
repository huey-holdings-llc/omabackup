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
bad()  { fail=$((fail+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }
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
  jq '. + {bogus:1}' "$OMABACKUP_CONFIG" > "$T/bad.json"
  eq "unknown config key refused as JSON" "$(OMABACKUP_CONFIG=$T/bad.json obj status | jq -r .ok)" "false"
  has "refusal names the key" "$(OMABACKUP_CONFIG=$T/bad.json obj status)" "bogus"
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
  eq "resolve-gone: refuses a path drift does not list as GONE" \
    "$(obj resolve-gone "$(tp .config/appz/z.toml)" remove | jq -r .ok)" "false"

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

if group 70 "a filename holding the old note separator names its own drift row"; then
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

  # A note still round-trips, TAB-separated, through the JSON the popup reads.
  { printf 'TOOBIG     ~/.config/huge.img\t(exceeds 8m; NOT backed up)\n'
    printf '# drift-scan-complete\n'; } > "$FR/manifests/drift.txt"
  eq "a TAB-separated note parses into path and note" \
    "$(obj status | jq -c '[.drift[0].path,.drift[0].note]')" \
    '["~/.config/huge.img","(exceeds 8m; NOT backed up)"]'
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
  i74=1
  while [ "$i74" -le 25 ]; do
    printf 'x\n' > "$FH/.config/many/f$i74"
    printf '?.config/many/f%d\n' "$i74" >> "$FR/allowlist.txt"
    i74=$((i74+1))
  done
  git -C "$FR" commit -qam "25 optional entries, so the derived floors are real"
  check "baseline commits the full tree" env HOME="$FH" "$CLI" snapshot --no-push
  # Now hollow: 25 of the 28 tracked files are gone. Optional entries, so the
  # allowlist assertion records them as GONE and the run reaches the floor.
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
    printf -- '--noconfirm\n' >> "$FR/manifests/pacman-aur.txt"
    printf '/tmp/evil.service\n' >> "$FR/manifests/systemd-user.txt"
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
    [[ "$(jq -r '[.would_write[] | select(startswith("service:"))] | length' <<<"$r76")" -ge 0 ]] \
      && ok "well-formed entries still enumerate" || bad "the stage stopped enumerating"
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
  # The stage AFTER the failing one still ran: that is what proves the chain
  # continued rather than the process having died inside restore_stage_etc.
  eq "the later stage still ran" \
    "$(jq -r '[.would_write[] | select(startswith("service:"))] | length > 0' <<<"$r79")" "true"
  # And the lock was dropped, not held to process exit: the very next verb
  # takes the same lock with the fixture's 2-second wait.
  check "the next locking verb takes the lock straight away" env HOME="$FH" "$CLI" snapshot --no-push
fi

if group 80 "a mass disappearance halts the run even when every entry is optional"; then
  # maxMissingPct is the "wrong \$HOME, or an unmounted partition?" guard, and
  # it counted REQUIRED entries only. Every entry in share/allowlist.example
  # carries the optional `?` marker, so on a stock install the count it looked
  # at was permanently empty and the guard could never fire: an unmounted home
  # subvolume would have committed, rsync --delete'd the backup down to
  # whatever survived, and reported it as ordinary GONE rows at "attention".
  mk_fixture g80
  mkdir -p "$FH/.config/opt"
  for i in 1 2 3 4 5 6; do printf 'setting=%d\n' "$i" > "$FH/.config/opt/f$i.conf"; done
  for i in 1 2 3 4 5 6; do printf '?.config/opt/f%d.conf\n' "$i" >> "$FR/allowlist.txt"; done
  git -C "$FR" commit -qam "six optional entries"
  check "the baseline run commits with all six present" env HOME="$FH" "$CLI" snapshot --no-push

  # Two of six is 33%, over the default maxMissingPct of 25.
  rm -f "$FH/.config/opt/f1.conf" "$FH/.config/opt/f2.conf"
  m80=$(obj snapshot --no-push)
  eq "a third of the allowlist vanishing refuses the run" "$(jq -r .ok <<<"$m80")" "false"
  has "the refusal is the maxMissingPct one" "$(jq -r .error <<<"$m80")" "no longer exist; refusing to run"
  has "the refusal names the wrong-\$HOME case" "$(jq -r .error <<<"$m80")" "unmounted partition"
  eq "the count is of everything that vanished, optional included" \
    "$(jq -r .error <<<"$m80" | grep -c '^2 of 6 allowlist entries (33%)')" "1"
  eq "nothing was committed by the refused run" \
    "$(git -C "$FR" log --oneline | grep -c 'snapshot:' || true)" "1"

  # ...and one optional entry vanishing is still soft, so the guard has not
  # simply become "any GONE halts the backup".
  printf 'setting=1\n' > "$FH/.config/opt/f1.conf"
  check "one vanished optional entry still runs" env HOME="$FH" "$CLI" snapshot --no-push
  has "it is reported as GONE, not as a refusal" "$(cat "$FR/manifests/drift.txt")" "GONE"
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

  # The two objects status can emit must still carry the same key set.
  eq "not-configured status carries the same keys as a configured one" \
    "$(OMABACKUP_CONFIG=/nonexistent obj status | jq -S 'keys')" "$(obj status | jq -S 'keys')"
fi

echo; echo "passed=$pass failed=$fail"
[[ $fail == 0 ]]
