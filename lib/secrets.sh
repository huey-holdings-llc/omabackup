#!/usr/bin/env bash
# Secret gates. The filename gate always runs; gitleaks runs when installed.
# Ported from the source engine, bin/snapshot.sh:488-512 (staging pass) and
# 614-623 (the staged-commit pass, "AUTHORITATIVE GATE" in the engine).
# The rules file is always $PLUGIN_DIR/share/gitleaks.toml, never a copy that
# lives inside the mutable data repo -- the engine preferred a repo-local
# .gitleaks.toml when present, so deleting that file silently fell back to
# gitleaks' bundled defaults (no ANTHROPIC_API_KEY rule, for one). Pinning the
# path here means the data repo cannot blind its own gate.
# shellcheck shell=bash

# `^id_[a-z0-9]+$` was narrower than the rule share/data.gitignore states
# (`id_*` minus `id_*.pub`): it matched id_rsa and id_ed25519 but not
# id_rsa_backup, id_ecdsa-sk or id_rsa.old, which are exactly the names a
# private key acquires when someone rotates or archives one. The class now
# covers the same set as the gitignore, and the public half is exempted
# structurally in secrets_filename_gate below (ERE has no lookahead).
SECRET_NAME_RE='(ghp_|gho_|github_pat_|AKIA[0-9A-Z]{16}|sk-ant-|BEGIN.*PRIVATE|^id_[A-Za-z0-9._-]+$|\.pem$|\.key$|\.kdbx$|^hosts\.yml$)'
# The one documented exemption, and it belongs to the `id_` class ALONE:
# share/data.gitignore says `id_*` then `!id_*.pub`, nothing wider. A bare
# `\.pub$` here would have exempted every other class too, so ghp_token.pub,
# AKIA....pub and sk-ant-oat01-....pub would all have walked straight through
# a gate that refused them before. Anchored at both ends for that reason.
SECRET_KEY_PUB_RE='^id_[A-Za-z0-9._-]+\.pub$'
RULES_FILE="$PLUGIN_DIR/share/gitleaks.toml"

gitleaks_available() { have gitleaks; }

# secrets_filename_gate DIR: die on a credential-looking basename. No pipe:
# `find | grep -q` failed open on SIGPIPE in the original engine -- grep -q
# exits at the first match, find dies of SIGPIPE (141), and pipefail reported
# 141 so the `if` never fired (snapshot.sh:502-508).
secrets_filename_gate() {
  local hits
  hits=$(find "$1" -type f -printf '%f\n' 2>/dev/null \
    | grep -E "$SECRET_NAME_RE" \
    | grep -vE "$SECRET_KEY_PUB_RE" || true)
  [[ -z "$hits" ]] || die "credential-looking filename(s) in the staging tree: $(head -3 <<<"$hits" | tr '\n' ' ')"
}

# secrets_scan_staging DIR: content scan of the staging tree, before anything
# is synced into the repo. -i pins the .gitleaksignore lookup to the data
# repo: gitleaks defaults that to ".", and the engine always ran this scan
# from inside $REPO_DIR (snapshot.sh:42,265), so a repo carrying a
# .gitleaksignore keeps working here even though this function does not cd.
secrets_scan_staging() {
  gitleaks_available || { warn "gitleaks not installed: content scan skipped (push will be refused)"; return 0; }
  log "Scanning staged tree with gitleaks ($RULES_FILE)"
  # gitleaks 8.19+ has `dir`; older builds use `detect --no-git` (engine: snapshot.sh:495-499).
  local -a gl
  if gitleaks dir --help >/dev/null 2>&1; then
    gl=(gitleaks dir "$1" -c "$RULES_FILE" -i "$DATA_REPO" --no-banner --redact --exit-code 1)
  else
    gl=(gitleaks detect --source "$1" --no-git -c "$RULES_FILE" -i "$DATA_REPO" --no-banner --redact --exit-code 1)
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
  if [[ "${JSON:-0}" == 1 ]]; then "${gl[@]}" >&2 || rc=$?; else "${gl[@]}" || rc=$?; fi
  [[ $rc -eq 0 ]] || die "gitleaks exited $rc scanning the staging tree; investigate the output above; nothing committed"
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
  local rc=0
  if [[ "${JSON:-0}" == 1 ]]; then
    ( cd "$DATA_REPO" && gitleaks git --staged --config "$RULES_FILE" --no-banner --redact --exit-code 1 >&2 ) || rc=$?
  else
    ( cd "$DATA_REPO" && gitleaks git --staged --config "$RULES_FILE" --no-banner --redact --exit-code 1 ) || rc=$?
  fi
  [[ $rc -eq 0 ]] || { git -C "$DATA_REPO" reset -q; die "gitleaks exited $rc on the staged commit; staging undone, nothing committed"; }
}
