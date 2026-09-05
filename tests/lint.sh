#!/usr/bin/env bash
# Static checks that need no home dir, no data repo and no widget load: run in
# CI and before a release.
#   bash tests/lint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$HERE" || exit 1
fail=0
step() { printf '== %s\n' "$1"; }
bad() { echo "  ✗ $1"; fail=1; }
ok() { echo "  ✓ $1"; }

step "shellcheck"
if shellcheck -S warning bin/omabackup lib/*.sh scripts/*.sh tests/*.sh; then ok "clean"; else bad "shellcheck findings"; fi

step "manifest.json"
m=manifest.json
jq -e '.schemaVersion == 1' "$m" >/dev/null && ok "schemaVersion is the number 1" || bad "schemaVersion must be the number 1"
jq -e '.id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (startswith("omarchy.") | not)' "$m" >/dev/null && ok "id well-formed" || bad "id"
jq -e '.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")' "$m" >/dev/null && ok "version is semver" || bad "version"
for k in name author license description homepage; do jq -e --arg k "$k" '.[$k] | type == "string" and length > 0' "$m" >/dev/null && ok "$k present" || bad "$k missing"; done
for kind in $(jq -r '.kinds[]' "$m"); do
  case "$kind" in bar-widget) key=barWidget ;; *) key=$kind ;; esac
  ep=$(jq -r --arg k "$key" '.entryPoints[$k] // empty' "$m")
  [[ -n "$ep" && -f "$ep" ]] && ok "entry point for $kind: $ep" || bad "entry point for $kind missing or absent on disk"
done
[[ "$(jq -r .version "$m")" == "$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | tr -d '[]# ')" ]] && ok "CHANGELOG top release matches manifest version" || bad "CHANGELOG top release != manifest version"
if find . -path ./.git -prune -o -type l -print | grep -q .; then bad "symlinks in the plugin tree (validator rejects them)"; else ok "no symlinks"; fi
command -v omarchy-plugin-validate >/dev/null && { omarchy-plugin-validate . >/dev/null && ok "omarchy-plugin-validate" || bad "omarchy-plugin-validate"; }

step "QML hygiene"
if grep -nE '"bash", *"-c"|"sh", *"-c"|bash -c' -- *.qml ui/*.qml; then bad "shell strings built in QML"; else ok "no shell strings in QML"; fi
if grep -nE '"/tmp' -- *.qml ui/*.qml bin/omabackup lib/*.sh; then bad "/tmp referenced"; else ok "no /tmp paths"; fi
# A bare `mktemp` (or `mktemp -d`) lands in $TMPDIR, i.e. /tmp: scratch must
# name its own directory under the data repo's .staging or $STATE_DIR, both
# of which are ours and 0700. Calls that pass a template are fine.
if grep -nE 'mktemp( +-[a-zA-Z]+)* *(\)|;|\||&|$)' bin/omabackup lib/*.sh; then
  bad "mktemp with no path template (scratch must live in the data repo or \$STATE_DIR, never /tmp)"
else
  ok "every mktemp names its own directory"
fi
for f in *.qml ui/*.qml; do [[ -s "$f" ]] || bad "$f empty"; done
if command -v qmllint >/dev/null; then qmllint --version >/dev/null 2>&1 && ok "qmllint available (imports need the shell; not run)"; fi
# The whole design: every process launch site must name the CLI (or the one
# terminal launcher a plugin is allowed to shell into), nothing else.
qml_process_bad=0
while IFS=: read -r qf qln _; do
  bad "a process launches something other than omabackup: $qf:$qln"
  qml_process_bad=1
done < <(grep -nE 'command:|execDetached\(' -- *.qml ui/*.qml | grep -vE 'omabackup|svc\.cli|Service\.cli|root\.cli|omarchy-launch-floating-terminal-with-presentation|wl-copy')
[[ $qml_process_bad == 0 ]] && ok "all processes route through omabackup"

step "secret filename classes"
# lib/secrets.sh's SECRET_NAME_GLOBS, its SECRET_NAME_RE and
# share/data.gitignore are three views of ONE list of credential filename
# classes, and the gate is only as good as the narrowest of them: it used to
# miss .env, *.p12, *.pfx, .credentials.json and Cookies*, all of which
# data.gitignore already named. Fail when they disagree.
# shellcheck disable=SC2034  # PLUGIN_DIR is read by lib/secrets.sh, sourced below
PLUGIN_DIR=.
# shellcheck source=../lib/secrets.sh
. lib/secrets.sh
sec_bad=0
while IFS= read -r glob; do
  [[ -n "$glob" ]] || continue
  grep -qxF -- "$glob" share/data.gitignore \
    || { bad "share/data.gitignore does not name the secret class: $glob"; sec_bad=1; }
  # A sample basename of that shape must actually reach the gate. `*` becomes
  # one ordinary character, which is enough to exercise every class here.
  sample=${glob//\*/x}
  if ! printf '%s\n' "$sample" | grep -qE "$SECRET_NAME_RE"; then
    bad "SECRET_NAME_RE does not cover the class $glob (sample: $sample)"; sec_bad=1
  fi
done <<<"$SECRET_NAME_GLOBS"
[[ $sec_bad == 0 ]] && ok "SECRET_NAME_GLOBS, SECRET_NAME_RE and share/data.gitignore agree"
printf 'id_ed25519.pub\n' | grep -qE "$SECRET_KEY_PUB_RE" \
  && ok "the documented id_*.pub exemption still applies" || bad "id_*.pub is no longer exempt"

step "copy"
if grep -rn -- $'\xe2\x80\x94' README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md bin/omabackup share/units *.qml ui/*.qml 2>/dev/null; then bad "em dash in user-facing text"; else ok "no em dashes"; fi
if grep -nE '\beval\b' bin/omabackup lib/*.sh; then bad "eval in the engine"; else ok "no eval"; fi

step "docs"
grep -q '## Remove' README.md && ok "README has a Remove section" || bad "README lacks Remove"
grep -q '## Update' README.md && ok "README has an Update section" || bad "README lacks Update"
grep -q 'omarchy plugin add' README.md && ok "README has the install command" || bad "README lacks install command"
[[ -f LICENSE && -f preview.png ]] && ok "LICENSE and preview.png present" || bad "LICENSE/preview.png"

echo; [[ $fail == 0 ]] && echo "lint: ok" || { echo "lint: FAILED"; exit 1; }
