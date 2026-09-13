#!/usr/bin/env bash
# Secret gates. The filename gate always runs; gitleaks runs when installed.
# Ported from the source engine, bin/snapshot.sh:488-512 (staging pass) and
# 614-623 (the staged-commit pass, "AUTHORITATIVE GATE" in the engine).
# The rules file is always $PLUGIN_DIR/share/gitleaks.toml, never a copy that
# lives inside the mutable data repo -- the engine preferred a repo-local
# .gitleaks.toml when present, so deleting that file silently fell back to
# gitleaks' bundled defaults (no ANTHROPIC_API_KEY rule, for one). Pinning the
# path here means the data repo cannot blind its own gate. Setup no longer
# lays a copy down either (lib/setup.sh), so nothing tells a user that editing
# a repo-local .gitleaks.toml would change what the scan looks for.
# shellcheck shell=bash

# SECRET_NAME_GLOBS: the credential filename classes, written in gitignore
# shape. This list and share/data.gitignore are two halves of ONE list, and
# tests/lint.sh fails when they disagree: the gate used to miss `.env`,
# `*.p12`, `*.pfx`, `.credentials.json` and `Cookies*`, all of which the
# project's own data.gitignore already treated as dangerous. That matters most
# on a machine with no gitleaks, where this filename check is the ONLY gate
# before `git commit` (push is refused, but the secret is already in local
# history and in every later clone of the repo).
#
# `.env.*` deliberately covers `.env.example` too: a template that has been
# filled in is indistinguishable from a real one by name, and the cost of a
# false refusal here is renaming one file.
# shellcheck disable=SC2034  # read by tests/lint.sh, which sources this file
SECRET_NAME_GLOBS='id_*
*.pem
*.key
*.p12
*.pfx
*.kdbx
*.ovpn
*.jks
*.asc
.env
.env.*
.netrc
.git-credentials
.npmrc
.pypirc
.credentials.json
credentials
Cookies*
hosts.yml'

# The regex half of the same list, plus the token prefixes no filename glob
# expresses. `^id_[a-z0-9]+$` was narrower than the rule share/data.gitignore
# states (`id_*` minus `id_*.pub`): it matched id_rsa and id_ed25519 but not
# id_rsa_backup, id_ecdsa-sk or id_rsa.old, which are exactly the names a
# private key acquires when someone rotates or archives one. The class now
# covers the same set as the gitignore, and the public half is exempted
# structurally in secrets_filename_gate below (ERE has no lookahead).
#
# The four original token classes stay unanchored, as they always were. The
# ones added here are anchored at the start of the basename, because that is
# what "prefix" means and unanchored they would refuse ordinary files:
# `SG\.` alone matches MSG.txt, and `npm_` matches npm_debug-anything.
SECRET_NAME_RE='(ghp_|gho_|github_pat_|AKIA[0-9A-Z]{16}|sk-ant-|BEGIN.*PRIVATE'\
'|^glpat-|^xox[baprs]-|^AIza|^sk-proj-|^hf_|^npm_|^dop_v1_|^SG\.'\
'|^id_[^/]+$|\.pem$|\.key$|\.p12$|\.pfx$|\.kdbx$|\.ovpn$|\.jks$|\.asc$'\
'|^\.env$|^\.env\.|^\.netrc$|^\.git-credentials$|^\.npmrc$|^\.pypirc$'\
'|^\.credentials\.json$|^credentials$|^Cookies|^hosts\.yml$)'
# The one documented exemption, and it belongs to the `id_` class ALONE:
# share/data.gitignore says `id_*` then `!id_*.pub`, nothing wider. A bare
# `\.pub$` here would have exempted every other class too, so ghp_token.pub,
# AKIA....pub and sk-ant-oat01-....pub would all have walked straight through
# a gate that refused them before. Anchored at both ends for that reason.
#
# The stem is `[^/]+`, the same class the widened `id_` rule above uses, and
# it has to be: a narrower one here does not narrow what is EXEMPT, it
# narrows it against a wider refusal, and the difference is a name the gate
# stops dead. `id_ed25519 (copy).pub` is what a file manager hands you when
# you duplicate a public key; the space and the parentheses fell outside
# `[A-Za-z0-9._-]`, so the widened refusal caught it and the exemption did
# not, and a snapshot refused over a file share/data.gitignore's own
# `!id_*.pub` keeps. The two halves are one rule and now spell it the same
# way; anything that is not an `id_` name is still refused by name.
SECRET_KEY_PUB_RE='^id_[^/]+\.pub$'
RULES_FILE="$PLUGIN_DIR/share/gitleaks.toml"

gitleaks_available() { have gitleaks; }

# gitleaks_has_dir / gitleaks_has_git: does this gitleaks build answer to the
# modern `dir` / `git` subcommands, or only the pre-8.19 `detect` / `protect`
# pair (engine: snapshot.sh:495-499)? Each probe is a fork (`gitleaks ...
# --help`), and a snapshot asks both -- staging scan, then staged scan -- so
# the answer is memoised in a process-global variable, set on first use and
# read on every call after. Initialised empty here, at library scope, rather
# than left to spring into existence on first use: an unrelated exported
# GITLEAKS_HAS_DIR/GITLEAKS_HAS_GIT in the calling environment would
# otherwise read as "already probed" and pick a scan command gitleaks was
# never asked whether it supports. Empty (not merely unset) means "not
# probed yet", so a build that fails the probe still memoises false rather
# than probing again on every subsequent call. Never exported: the answer is
# only ever good for the process that just asked gitleaks, never cached
# across a process boundary where a different gitleaks could be on PATH.
GITLEAKS_HAS_DIR=""
GITLEAKS_HAS_GIT=""
gitleaks_has_dir() {
  if [[ -z "${GITLEAKS_HAS_DIR:-}" ]]; then
    if gitleaks dir --help >/dev/null 2>&1; then GITLEAKS_HAS_DIR=1; else GITLEAKS_HAS_DIR=0; fi
  fi
  [[ "$GITLEAKS_HAS_DIR" == 1 ]]
}
gitleaks_has_git() {
  if [[ -z "${GITLEAKS_HAS_GIT:-}" ]]; then
    if gitleaks git --help >/dev/null 2>&1; then GITLEAKS_HAS_GIT=1; else GITLEAKS_HAS_GIT=0; fi
  fi
  [[ "$GITLEAKS_HAS_GIT" == 1 ]]
}

# secrets_filename_gate DIR: die on a credential-looking basename. No pipe:
# `find | grep -q` failed open on SIGPIPE in the original engine -- grep -q
# exits at the first match, find dies of SIGPIPE (141), and pipefail reported
# 141 so the `if` never fired (snapshot.sh:502-508).
#
# NUL-delimited, and the `id_` class matches share/data.gitignore's `id_*`
# rather than a character class of its own. A basename may contain a newline:
# `%f\n` split `id_<LF>rsa` into `id_` and `rsa`, neither of which matches
# anything, so a private key walked straight through the gate that exists to
# stop it. `%f\0` with `grep -z` keeps the name whole, and `[^/]+` is what
# lets the whole name match once the newline is part of it.
#
# find's own exit status is checked, separately from the greps that follow
# it. The whole walk used to sit in one pipeline ending in `|| true`, which
# was there for grep's "no match" exit and swallowed find's too: a find that
# died on an unreadable directory, or did not start at all, produced no
# names, no names matched, and the gate passed. A gate that could not look
# refuses the run. The list goes through a file (a redirect, not a pipe, so
# find's status is find's) because a NUL byte does not survive a bash
# variable, and the file lives in $STATE_DIR, never /tmp.
secrets_filename_gate() {
  local hits names rc
  # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
  mkdir -m 700 -p "$STATE_DIR" 2>/dev/null || true
  names=$(mktemp "$STATE_DIR/.gate.XXXXXX") || die "filename gate: cannot create its scratch file under $STATE_DIR; no snapshot was committed"
  rc=0; find "$1" -type f -printf '%f\0' > "$names" || rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "$names"
    die "filename gate could not walk the staging tree (find exited $rc); a gate that cannot look does not pass. No snapshot was committed"
  fi
  hits=$(grep -zE "$SECRET_NAME_RE" "$names" \
    | grep -zvE "$SECRET_KEY_PUB_RE" \
    | tr '\n\0' ' \n' || true)
  rm -f "$names"
  [[ -z "$hits" ]] || die "credential-looking filename(s) in the staging tree: $(head -3 <<<"$hits" | tr '\n' ' ')"
}

# secrets_scan_staging DIR: content scan of the staging tree, before anything
# is synced into the repo. -i pins the .gitleaksignore lookup to the data
# repo, where gitleaks would otherwise look in ".".
#
# It scans "." from INSIDE the staging tree, so a finding is named
# home/<path>:<rule>:<line>, the same fingerprint the staged scan below gives
# it. Handed the absolute path, gitleaks named it by that path, so one line
# in .gitleaksignore satisfied one gate and not the other, and the line that
# satisfied this one carried the machine's own path. -v prints each finding
# (value redacted) with its fingerprint: without it the refusal said only
# "leaks found: 1" and named nothing to fix or record.
secrets_scan_staging() {
  gitleaks_available || { warn "gitleaks not installed: content scan skipped (push will be refused)"; return 0; }
  log "Scanning staged tree with gitleaks ($RULES_FILE)"
  # gitleaks 8.19+ has `dir`; older builds use `detect --no-git` (engine: snapshot.sh:495-499).
  local -a gl
  if gitleaks_has_dir; then
    gl=(gitleaks dir . -c "$RULES_FILE" -i "$DATA_REPO" --no-banner --redact -v --exit-code 1)
  else
    gl=(gitleaks detect --source . --no-git -c "$RULES_FILE" -i "$DATA_REPO" --no-banner --redact -v --exit-code 1)
  fi
  # Let gitleaks' own stdout/stderr through (findings are already --redact'd) --
  # swallowing it made a missing rules file, a crashed binary and a real leak
  # all die with the same "found a secret", with nothing to tell them apart
  # (engine: snapshot.sh:495-512 does not redirect either). With --json, stdout
  # must stay a single JSON object, so gitleaks' stdout is rerouted to stderr;
  # its own stderr is never swallowed in either mode. `|| rc=$?` keeps the
  # gitleaks invocation on the left of `||`: bin/omabackup runs under
  # `set -euo pipefail`, and a failing command inside a bare `if ...; then`
  # body is NOT errexit-exempt -- it killed the process before `rc` could be
  # read, so a real leak never reached reset/die at all.
  local rc=0
  if [[ "${JSON:-0}" == 1 ]]; then
    ( cd "$1" && "${gl[@]}" >&2 ) || rc=$?
  else
    ( cd "$1" && "${gl[@]}" ) || rc=$?
  fi
  [[ $rc -eq 0 ]] || die "gitleaks exited $rc scanning the staging tree; investigate the output above; no snapshot was committed"
}

# secrets_scan_staged: the authoritative gate, over exactly what `git add`
# staged -- the staging-tree scan above only ever covers files copied in from
# $HOME (engine: snapshot.sh:614-618). Runs before `git commit`, so on a
# nonzero exit `git reset -q` undoes the staging (the `git add`), not a
# commit -- nothing has been committed yet at this point in the pipeline.
secrets_scan_staged() {
  gitleaks_available || return 0
  log "Scanning the staged commit"
  # `|| rc=$?` for the same reason as secrets_scan_staging: under
  # `set -euo pipefail`, a failing command in a bare `if ...; then` body is
  # not errexit-exempt and would kill the process before reset/die ran.
  # The two halves of one gate had different version tolerance:
  # secrets_scan_staging probes for `gitleaks dir` and falls back to the older
  # `detect --no-git`, while this half called `gitleaks git --staged` with no
  # fallback at all. On a build without the `git` subcommand that is a non-zero
  # exit, which dies -- so the authoritative gate stopped every snapshot on a
  # machine whose other gate coped fine. `protect --staged` is the same scan
  # under the pre-8.19 name.
  local -a gl
  if gitleaks_has_git; then
    gl=(gitleaks git --staged --config "$RULES_FILE" --no-banner --redact -v --exit-code 1)
  else
    gl=(gitleaks protect --staged --config "$RULES_FILE" --no-banner --redact -v --exit-code 1)
  fi
  local rc=0
  if [[ "${JSON:-0}" == 1 ]]; then
    ( cd "$DATA_REPO" && "${gl[@]}" >&2 ) || rc=$?
  else
    ( cd "$DATA_REPO" && "${gl[@]}" ) || rc=$?
  fi
  [[ $rc -eq 0 ]] || { git -C "$DATA_REPO" reset -q; die "gitleaks exited $rc on the staged commit; staging undone, no snapshot was committed"; }
}

# repo_commit_scanned PATH... -m MSG: stage those paths, scan exactly what the
# staging produced, and commit them.
#
# THE THIRD AND FOURTH PUSHABLE COMMIT PATHS. Invariant 3 asks for gitleaks
# over exactly what `git add` staged, before every commit that can be pushed.
# `snapshot --accept-allowlist` and the .gitignore sync each add one file and
# commit it inside a run that then reaches remote_push_if_ahead, and both used
# to go straight from `git add` to `git commit` with no scan at all: a token
# pasted onto a comment line in allowlist.txt was committed and pushed by the
# very next line (whole-release review, SEC-C1). snapshot_commit's own staging
# is deliberately limited to home/ etc/ manifests/ modes.txt, so the scan it
# runs never saw either file.
#
# There is no filename gate here and none to add. That gate is about
# credential-looking BASENAMES in the staging tree ($STAGE/home/..., the files
# copied in from $HOME); the two paths this helper commits are the data repo's
# own list files, named allowlist.txt and .gitignore, which the gate would
# have nothing to say about. The content scan is the gate that applies.
#
# secrets_scan_staged is called the way cmd_push calls it (lib/widget.sh): in
# a command substitution, because it die()s on a hit and the die may only take
# THAT subshell down, never the run's own reporting. Its `git reset -q` has
# already undone the staging in the real repo by then (a git command, not
# shell state, so the subshell boundary does not contain it); the reset below
# is the belt to that braces, and it names the paths this call staged so a
# refusal cannot unstage anything else.
#
# Returns 0 committed, 2 the scan refused (nothing committed, index reset, and
# it is the caller's job to refuse the run), 1 the add or the commit itself
# failed.
repo_commit_scanned() {
  local -a paths=()
  while (( $# )); do
    [[ "$1" == "-m" ]] && { shift; break; }
    paths+=("$1"); shift
  done
  local msg=${1:-}
  (( ${#paths[@]} > 0 )) || die "repo_commit_scanned was given no paths to commit"
  [[ -n "$msg" ]] || die "repo_commit_scanned was given no commit message"

  git -C "$DATA_REPO" add -- "${paths[@]}" || return 1

  local scan_rc=0 scan_out=""
  scan_out=$(secrets_scan_staged 2>&1) || scan_rc=$?
  # Always back to stderr, never stdout: the scan's own narration and
  # gitleaks' findings (already --redact'ed) are worth keeping in both modes,
  # and under --json stdout carries one object and nothing else.
  [[ -z "$scan_out" ]] || printf '%s\n' "$scan_out" >&2
  if [[ $scan_rc -ne 0 ]]; then
    git -C "$DATA_REPO" reset -q -- "${paths[@]}" 2>/dev/null || true
    return 2
  fi

  # Same identity fallback as every other commit path: a machine with no
  # ~/.gitconfig cannot commit at all without it.
  git_ident_args
  git -C "$DATA_REPO" ${GIT_IDENT_ARGS[@]+"${GIT_IDENT_ARGS[@]}"} \
    commit -q -m "$msg" -- "${paths[@]}" || return 1
}
