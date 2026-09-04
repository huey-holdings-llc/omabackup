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
  export OMABACKUP_MIN_FILES=5 OMABACKUP_MIN_ALLOWLIST=1 OMABACKUP_LOCK_WAIT=2
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
  eq "missing config refused with setup hint" "$(OMABACKUP_CONFIG=/nonexistent ob status; true)" "$(printf '\033[1;31m[FAIL]\033[0m no config at /nonexistent. Run: omabackup setup')"
fi

# Later tasks append groups here, in numeric order, each starting with mk_fixture.

if group 07 "drift detection"; then
  mk_fixture g07; seed_home
  out=$(ob drift)
  has "unbacked user file is NEW" "$out" "NEW        ~/.config/mytool"
  has "changed stock file that is allowlisted is not reported" "$out" "drift-scan-complete"
  ! grep -q 'bindings.lua' <<<"$out" && ok "allowlisted file not reported" || bad "allowlisted file reported"
  eq "json items carry type and path" "$(obj drift | jq -r '.items[] | select(.path=="~/.config/mytool") | .type')" "NEW"
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
if group 37 "a stale .git/index.lock self-heals"; then
  mk_fixture g37; seed_home
  touch -d '10 minutes ago' "$FR/.git/index.lock"
  check "snapshot clears an abandoned lock and runs" env HOME="$FH" "$CLI" snapshot --no-push
  [[ ! -f "$FR/.git/index.lock" ]] && ok "stale lock removed" || bad "stale lock still present"
fi
if group 39 "a LIVE .git/index.lock is never deleted"; then
  mk_fixture g39; seed_home
  touch -d '10 minutes ago' "$FR/.git/index.lock"
  ( exec 3<"$FR/.git/index.lock"; sleep 5 ) & holder=$!
  sleep 0.3
  fails "snapshot refuses while another process holds index.lock" env HOME="$FH" "$CLI" snapshot --no-push
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

echo; echo "passed=$pass failed=$fail"
[[ $fail == 0 ]]
