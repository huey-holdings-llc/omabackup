#!/usr/bin/env bash
# Static checks: run before a release or after edits. No shell, no widget load.
#   bash tests/lint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$HERE" || exit 1
fail=0
step() { printf '== %s\n' "$1"; }
bad() { echo "  ✗ $1"; fail=1; }
ok() { echo "  ✓ $1"; }

step "shellcheck"
if shellcheck -S warning scripts/*.sh tests/*.sh; then ok "clean"; else bad "shellcheck findings"; fi

step "manifest.json"
m=manifest.json
jq -e '.schemaVersion == 1' "$m" >/dev/null && ok "schemaVersion is the number 1" || bad "schemaVersion must be the number 1"
jq -e '.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")' "$m" >/dev/null && ok "version is semver" || bad "version"
for k in id name author license description homepage; do
  jq -e --arg k "$k" '.[$k] | type == "string" and length > 0' "$m" >/dev/null && ok "$k present" || bad "$k missing"
done
ep=$(jq -r '.entryPoints.barWidget // empty' "$m")
[[ -n "$ep" && -f "$ep" ]] && ok "bar-widget entry point: $ep" || bad "bar-widget entry point missing"
if find . -path ./.git -prune -o -type l -print | grep -q .; then bad "symlinks in the plugin tree (validator rejects them)"; else ok "no symlinks"; fi
command -v omarchy-plugin-validate >/dev/null && { omarchy-plugin-validate . >/dev/null && ok "omarchy-plugin-validate" || bad "omarchy-plugin-validate"; }

step "QML hygiene"
if grep -nE '"bash", *"-c"|"sh", *"-c"|bash -c' -- *.qml ui/*.qml; then bad "shell strings built in QML"; else ok "no shell strings in QML"; fi
# The whole design: the QML must only ever exec the helper, nothing else.
if grep -nE 'Quickshell\.execDetached|Process' -- *.qml ui/*.qml | grep -vE 'widget-helper|actionComponent|statusProc|property Component|createObject|^\S+:[0-9]+: *//' | grep -q 'exec'; then
  bad "a process runs something other than widget-helper.sh"
else
  ok "all processes route through widget-helper.sh"
fi

echo
if [[ "$fail" -eq 0 ]]; then echo "lint clean"; else echo "problems found"; fi
exit "$fail"
