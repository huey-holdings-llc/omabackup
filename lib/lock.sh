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
