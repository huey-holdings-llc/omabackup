#!/usr/bin/env bash
# One flock per data repo, shared by snapshot, lint, verify and the write verbs.
# shellcheck shell=bash

take_lock() { # take_lock [WAIT]; returns 1 on timeout (caller decides)
  have flock || die "flock not found: cannot guarantee a single instance"
  exec 9>"$DATA_REPO/.lock"
  flock -w "${1:-${OMABACKUP_LOCK_WAIT:-20}}" 9
}
drop_lock() { exec 9>&-; }

# repo_assert_clean: the guards from the engine's snapshot header, verbatim in
# intent. Stale index.lock self-heals only when fuser proves nobody holds it.
repo_assert_clean() {
  [[ -d "$DATA_REPO/.git" ]] || die "$DATA_REPO is not a git repository"
  if [[ -f "$DATA_REPO/.git/index.lock" ]] && [[ -z "$(find "$DATA_REPO/.git/index.lock" -mmin -5 2>/dev/null)" ]]; then
    have fuser || die "stale .git/index.lock present but fuser is unavailable; refusing to guess. Remove it by hand if no git is running."
    if fuser -s "$DATA_REPO/.git/index.lock" 2>/dev/null; then
      die "another git process is using .git/index.lock; not touching it"
    fi
    warn "clearing an abandoned .git/index.lock (previous run was killed?)"
    rm -f "$DATA_REPO/.git/index.lock"
  fi
  if [[ -f "$DATA_REPO/.git/MERGE_HEAD" || -f "$DATA_REPO/.git/REBASE_HEAD" || -d "$DATA_REPO/.git/rebase-merge" || -d "$DATA_REPO/.git/rebase-apply" ]]; then
    die "repo is mid-merge/rebase; resolve it first, then re-run"
  fi
  git -C "$DATA_REPO" symbolic-ref --short -q HEAD >/dev/null || die "detached HEAD; check out main in $DATA_REPO first"
}
repo_branch() { git -C "$DATA_REPO" symbolic-ref --short -q HEAD; }

# git_ident_args: fill GIT_IDENT_ARGS with the `-c user.*` a commit needs on a
# machine that has no git identity at all, and leave it EMPTY on a machine
# that has one -- the user's own name and address must never be overridden.
# A fresh Omarchy install has no ~/.gitconfig, so without this every commit
# this tool makes dies with "Author identity unknown". One helper because
# every commit path needs it: the snapshot, both setup paths and the widget's
# push button, which had it in one place only.
#   git_ident_args
#   git -C "$DATA_REPO" ${GIT_IDENT_ARGS[@]+"${GIT_IDENT_ARGS[@]}"} commit ...
# shellcheck disable=SC2034  # GIT_IDENT_ARGS: filled here, read by the commit sites in snapshot/setup/widget
GIT_IDENT_ARGS=()
git_ident_args() {
  GIT_IDENT_ARGS=()
  local email
  email=$(git -C "$DATA_REPO" config user.email 2>/dev/null || true)
  # shellcheck disable=SC2034  # read by the commit sites in lib/snapshot.sh, lib/setup.sh and lib/widget.sh
  [[ -n "$email" ]] || GIT_IDENT_ARGS=(-c user.name=OmaBackup -c user.email=omabackup@localhost)
}
