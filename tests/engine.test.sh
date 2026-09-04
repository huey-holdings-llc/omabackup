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
  printf 'x\n' > "$FH/.config/mytool/ghp_$(rand_body 20).txt"
  out=$(ob snapshot --no-push); rc=$?
  [[ $rc -ne 0 ]] && ok "snapshot refuses a ghp_ filename" || bad "a credential-looking filename was staged"
  has "the refusal names the filename gate" "$out" "credential-looking filename"
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
  # ...but if a human has STAGED something with a secret in it, the staged gate
  # must still catch it: it scans exactly what is about to be committed.
  if command -v gitleaks >/dev/null; then
    printf 'note: ghp_%s\n' "$(rand_body 36)" > "$FR/notes.txt"
    git -C "$FR" add notes.txt
    printf 'gate\n' > "$FH/.config/mytool/gate.conf"
    before=$(git -C "$FR" rev-parse HEAD)
    out=$(ob snapshot --no-push); rc=$?
    [[ $rc -ne 0 ]] && ok "a secret in a pre-staged file blocks the commit" || bad "staged gate did NOT fire (rc=$rc)"
    has "the refusal names the staged commit" "$out" "staged commit"
    eq "no commit created" "$(git -C "$FR" rev-parse HEAD)" "$before"
    git -C "$FR" diff --cached --quiet && ok "the index was reset" || bad "index left staged after the abort"
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
  want=$(printf 'NEW        %s' '~/.local/share/blob/ (>50 files: too large to scan; allowlist it, or add a dated .../** line to drift-ignore.txt)')
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
    printf 'NEW        ~/.local/share/bigz/ (>2000 files: too large to scan; add or ignore wholesale)\n'
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
    printf 'NEW        ~/.local/share/bigz/ (>2000 files: too large to scan; add or ignore wholesale)\n'
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
  grep -qx -- '--user start omabackup-snapshot.service' "$T/sysctl.log" \
    && ok "timer run: starts the snapshot service" || bad "timer run argv wrong"

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
  check "import writes the marker" env HOME="$FH" "$CLI" setup --import "$FR" --no-timers --yes
  eq "marker format 1" "$(jq -r .format "$FR/.omabackup")" "1"
  # $FR's origin is $BARE, a local path: not GitHub. An unattended run
  # (--yes, no tty, no --trust-remote) must never trust it, even though
  # mk_fixture's own pre-authored config said trusted:true.
  eq "unattended import leaves a non-GitHub remote untrusted without --trust-remote" \
    "$(jq -r .remote.trusted "$OMABACKUP_CONFIG")" "false"

  git init -q "$T/notarepo"
  fails "import refuses a directory without the lists" env HOME="$FH" "$CLI" setup --import "$T/notarepo" --no-timers --yes

  # Rerunning setup against the same non-GitHub remote with --trust-remote
  # is the only way to flip it to trusted.
  check "setup --remote --trust-remote rerun" env HOME="$FH" "$CLI" setup --data-repo "$FR" --remote "$BARE" --trust-remote --no-timers --yes
  eq "explicit --trust-remote sets remote.trusted true" "$(jq -r .remote.trusted "$OMABACKUP_CONFIG")" "true"
fi

if group 62 "setup --remove leaves the data repo alone"; then
  mk_fixture g62; seed_home
  out62=$(obj setup --remove --yes); rc62=$?
  eq "remove --json exits 0" "$rc62" "0"
  eq "remove --json prints exactly one JSON object" "$(jq -c '[.ok,.removed]' <<<"$out62")" "[true,true]"
  [[ ! -f "$OMABACKUP_CONFIG" ]] && ok "config removed" || bad "config still there"
  [[ -f "$FR/allowlist.txt" ]] && ok "data repo untouched" || bad "data repo damaged"
fi

echo; echo "passed=$pass failed=$fail"
[[ $fail == 0 ]]
