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
# The CHANGELOG's top release must match the shipped version, EXCEPT while that
# entry is still marked Unreleased. That is the window between writing the
# release notes and cutting the release, and in it the heading is deliberately
# ahead of manifest.json: the notes describe the version about to ship, and the
# release commit is what drops " - Unreleased" (Keep a Changelog puts the date
# there instead) and bumps manifest.json to match. Once the heading is no
# longer marked Unreleased this is plain equality again, so nothing can be
# tagged with notes for a different version.
cl_head=$(grep -m1 -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md)
cl_ver=$(tr -d '[]# ' <<<"${cl_head%% -*}")
m_ver=$(jq -r .version "$m")
if [[ "$cl_head" == *Unreleased* ]]; then
  if [[ "$cl_ver" == "$m_ver" ]] \
     || [[ "$(printf '%s\n%s\n' "$m_ver" "$cl_ver" | sort -V | head -1)" == "$m_ver" ]]; then
    ok "CHANGELOG top release $cl_ver is unreleased (manifest says $m_ver; the release commit bumps it)"
  else
    bad "CHANGELOG top release $cl_ver is behind manifest version $m_ver"
  fi
elif [[ "$cl_ver" == "$m_ver" ]]; then
  ok "CHANGELOG top release matches manifest version"
else
  bad "CHANGELOG top release $cl_ver != manifest version $m_ver"
fi
# THE SHIPPED TREE ONLY, for both checks below.
#
# They used to walk the whole working directory, which includes tests/tmp: the
# suite's fixture root, gitignored, and full of symlinks on purpose (a group
# builds a PATH of symlinks to prove the tool behaves when one binary is
# absent). A run that was interrupted leaves one behind, and from then on the
# release gate failed over a directory that ships to nobody. `git ls-files`
# is the shipping manifest -- what a clone gets, tracked plus not-yet-added,
# never anything ignored -- so that is what both checks look at.
shipped_paths() { git ls-files -z --cached --others --exclude-standard; }
in_git=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1

sym_found=0
if [[ $in_git == 1 ]]; then
  while IFS= read -r -d '' f; do
    [[ -L "$f" ]] || continue
    bad "symlink in the plugin tree (validator rejects them): $f"; sym_found=1
  done < <(shipped_paths)
else
  # No git (a tarball, a plugin dir copied into place): fall back to the walk,
  # with the suite's own scratch root pruned by name.
  if find . -path ./.git -prune -o -path ./tests/tmp -prune -o -type l -print | grep -q .; then
    bad "symlinks in the plugin tree (validator rejects them)"; sym_found=1
  fi
fi
[[ $sym_found == 0 ]] && ok "no symlinks"

# The validator walks a directory and has no exclude of its own, so it gets a
# throwaway copy of exactly the shipped set. The copy lives under tests/tmp
# (ours, inside the worktree, gitignored) and never in /tmp, and it is removed
# on the way out however this script ends.
lint_tree=""
# shellcheck disable=SC2317  # called from the EXIT trap below
lint_tree_clean() { [[ -n "$lint_tree" ]] && rm -rf "$lint_tree"; return 0; }
trap lint_tree_clean EXIT
if command -v omarchy-plugin-validate >/dev/null; then
  if [[ $in_git == 1 ]]; then
    mkdir -p "$HERE/tests/tmp"
    if lint_tree=$(mktemp -d "$HERE/tests/tmp/lint-tree.XXXXXX"); then
      copy_ok=1; copy_failed=""
      while IFS= read -r -d '' f; do
        # -P: copy a symlink AS a symlink instead of dereferencing it, so the
        # validator sees the same tree a clone would. The symlink check above
        # already fails the run on one; this just keeps the two checks from
        # disagreeing about what a shipped symlink looks like.
        mkdir -p "$lint_tree/$(dirname "$f")" && cp -Pp "$f" "$lint_tree/$f" \
          || { copy_ok=0; [[ -z "$copy_failed" ]] && copy_failed="$f"; }
      done < <(shipped_paths)
      if [[ $copy_ok == 1 ]]; then
        omarchy-plugin-validate "$lint_tree" >/dev/null && ok "omarchy-plugin-validate (shipped tree)" \
          || bad "omarchy-plugin-validate"
      else
        bad "could not assemble the shipped tree to validate: could not copy '$copy_failed'"
      fi
    else
      bad "could not create a scratch directory under tests/tmp"
    fi
  else
    omarchy-plugin-validate . >/dev/null && ok "omarchy-plugin-validate" || bad "omarchy-plugin-validate"
  fi
fi

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
if grep -rn -- $'\xe2\x80\x94' README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md LICENSE docs bin/omabackup share/units share/*.example *.qml ui/*.qml 2>/dev/null; then bad "em dash in user-facing text"; else ok "no em dashes"; fi
if grep -nE '\beval\b' bin/omabackup lib/*.sh; then bad "eval in the engine"; else ok "no eval"; fi

step "docs"
grep -q '## Remove' README.md && ok "README has a Remove section" || bad "README lacks Remove"
grep -q '## Update' README.md && ok "README has an Update section" || bad "README lacks Update"
grep -q 'omarchy plugin add' README.md && ok "README has the install command" || bad "README lacks install command"
[[ -f LICENSE && -f preview.png ]] && ok "LICENSE and preview.png present" || bad "LICENSE/preview.png"

echo; [[ $fail == 0 ]] && echo "lint: ok" || { echo "lint: FAILED"; exit 1; }
