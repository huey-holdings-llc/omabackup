#!/usr/bin/env bash
# The remote model: is it safe to push? Ported from
# hp-laptop-config/bin/snapshot.sh:537-580 (the visibility probe) and 582-616,
# 649-681 (push_if_ahead and the post-commit push, folded into one function
# here since both were ever just "push if @{upstream}..HEAD is nonempty").
# Sourced by bin/omabackup; never executed.
#
# Deliberately does NOT use `gh`: gh's token lives in the keyring, which is
# not reliably readable from a systemd timer, and a personal access token
# would be one more secret to rotate. An unauthenticated probe of the GitHub
# REST API is enough: a private repo 404s, a public one 200s.
# shellcheck shell=bash
# shellcheck disable=SC2034  # PUSHED, SKIP_PUSH, DIVERGED: read by cmd_snapshot (Task 9), not this file

# remote_origin_url: read from git, not config -- a remote changed by hand
# (git remote set-url) must be respected without a config edit.
remote_origin_url() { git -C "$DATA_REPO" remote get-url origin 2>/dev/null || true; }

# remote_github_slug URL: print "owner/repo" for a GitHub remote, else print
# nothing. Only these four forms are recognized; anything else (a self-hosted
# Forgejo, a bare local path) is not GitHub and is not probed -- see
# remote_probe. ALWAYS returns 0: the caller (remote_probe, under errexit)
# treats "no slug" as a legitimate, common outcome, not a failure -- a bare
# `[[ ... ]] && printf ...` here made the function exit 1 for every non-GitHub
# remote, which silently killed the whole process before PUSH_VERIFIABLE was
# ever set (caught by group 27's local-bare-path origin).
remote_github_slug() {
  local u=$1 s=""
  case "$u" in
    git@github.com:*) s=${u#git@github.com:} ;;
    https://github.com/*) s=${u#https://github.com/} ;;
    ssh://git@ssh.github.com:443/*) s=${u#ssh://git@ssh.github.com:443/} ;;
    ssh://git@github.com/*) s=${u#ssh://git@github.com/} ;;
  esac
  s=${s%/}    # a trailing slash (github.com/o/r/) must not become part of the "r/" that .git-stripping below would otherwise leave alone
  s=${s%.git}
  if [[ "$s" == */* ]]; then printf '%s' "$s"; fi
  return 0
}

# remote_probe: sets PUSH_VERIFIABLE (true|false) and PUSH_REASON. GitHub only
# -- a non-GitHub remote (or none at all) cannot be probed this way, so it is
# only ever pushed to when the operator has explicitly marked it trusted.
# HTTP 200 is the ONLY proof of public and dies; 404 is proof of private
# (or not-yet-created) and is verifiable; everything else (403 rate-limited,
# 429, 5xx, a connection failure) proves nothing either way and must not
# abort the run -- it just means "commit locally, don't push yet".
remote_probe() {
  PUSH_VERIFIABLE=false; PUSH_REASON=""
  local url slug code
  url=$(remote_origin_url)
  [[ -n "$url" ]] || { PUSH_REASON="no-remote"; return 0; }
  # `|| true`: belt-and-braces alongside the `return 0` inside
  # remote_github_slug itself -- a bare assignment here must never be able to
  # take the whole process down under errexit, no matter what the callee does.
  slug=$(remote_github_slug "$url" || true)
  if [[ -z "$slug" ]]; then
    if [[ "$CFG_REMOTE_TRUSTED" == true ]]; then PUSH_VERIFIABLE=true; PUSH_REASON="trusted"; else PUSH_REASON="remote-unverified"; fi
    return 0
  fi
  if [[ "${OMABACKUP_NET:-1}" == 0 ]]; then
    if [[ "$CFG_REMOTE_TRUSTED" == true ]]; then PUSH_VERIFIABLE=true; PUSH_REASON="trusted"; else PUSH_REASON="net-disabled"; fi
    return 0
  fi
  # A Persistent= timer fires the moment the user manager starts at login,
  # routinely before WiFi is up. Wait (bounded) for NetworkManager to report
  # online before asking; returns at once when it already is. `have` and the
  # trailing `|| true` are both load-bearing: nm-online must not be required,
  # and its own failure (network never came up in time) must not abort the
  # probe -- the curl call right after is the real, authoritative check.
  have nm-online && nm-online -q -t "${NET_WAIT:-45}" >/dev/null 2>&1 || true
  # `|| true`: curl -w PRINTS 000 on a connection failure AND exits non-zero.
  # Under errexit, letting that failure propagate would kill the run one line
  # before the case statement -- with the message never seen and no die().
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://api.github.com/repos/$slug" || true)
  case "$code" in
    200) die "repository $slug is PUBLIC; refusing to push config anywhere public" ;;
    404) PUSH_VERIFIABLE=true; PUSH_REASON="private" ;;
    *)   PUSH_REASON="probe-$code" ;;
  esac
}

# remote_push_allowed: 0 (allowed) only when gitleaks is installed AND the
# probe above proved (or the operator declared) the remote safe. Requiring
# gitleaks here, not just at scan time, closes the gap where a machine with
# no gitleaks would otherwise scan nothing and still push.
remote_push_allowed() {
  gitleaks_available || { PUSH_REASON="gitleaks-missing"; return 1; }
  [[ "$PUSH_VERIFIABLE" == true ]]
}

# remote_push_if_ahead: push local commits ahead of upstream, if allowed.
# Sets PUSHED (true|false), SKIP_PUSH (0|1) and DIVERGED (true|false).
# The engine had two separate call sites for this -- one after committing,
# one on a "nothing changed" run to retry an old backlog -- that differed
# only in their log wording. Both are really just "is HEAD ahead of
# @{upstream}, and if so, push it", so this is one function called from both
# places in the pipeline (Task 9).
remote_push_if_ahead() {
  PUSHED=false; SKIP_PUSH=0; DIVERGED=false
  if ! remote_push_allowed; then
    SKIP_PUSH=1
    warn "push not verifiable ($PUSH_REASON); commit(s) kept locally, not pushed"
    return 0
  fi
  git -C "$DATA_REPO" remote get-url origin >/dev/null 2>&1 || return 0
  local no_upstream=0
  git -C "$DATA_REPO" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 || no_upstream=1
  local ahead=1
  # With an upstream already tracked, only push when actually ahead -- a bare
  # "push anyway" on every run is how a backlog retry turns into a needless
  # no-op push every single day. With no upstream yet there is nothing to
  # diff against; the first commit itself is the thing to push.
  [[ $no_upstream -eq 0 ]] && ahead=$(git -C "$DATA_REPO" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)
  [[ "${ahead:-0}" -gt 0 ]] || return 0
  local push_args=(origin HEAD)
  # Establish upstream tracking when absent. Without -u here, later runs
  # cannot count unpushed commits at all -- that check would silently do
  # nothing, which is how a machine ends up committing locally for weeks
  # with nothing off-disk.
  if [[ $no_upstream -eq 1 ]]; then
    local branch
    branch=$(repo_branch || true)
    [[ -n "$branch" ]] || die "cannot determine the current branch in $DATA_REPO; refusing to push"
    push_args=(-u origin "HEAD:$branch")
  fi
  local err
  # stderr is captured, not discarded: a port-22 outage is otherwise
  # indistinguishable from every other push failure in the log.
  if err=$(git -C "$DATA_REPO" push -q "${push_args[@]}" 2>&1 >/dev/null); then
    PUSHED=true
    rm -f "$STATE_DIR/diverged.stamp"
    log "Pushed to origin."
  else
    local behind
    behind=$(git -C "$DATA_REPO" rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo 0)
    if [[ "${behind:-0}" -gt 0 ]]; then
      DIVERGED=true
      warn "remote has diverged. Run: git -C $DATA_REPO pull --rebase"
      # The remote has commits we do not. Retrying forever is futile and a
      # daily "will retry" notification is pure cry-wolf -- the spec wants a
      # one-off, not a nag on every run of an unresolved divergence. Stamp
      # the remote head SHA we notified about; only notify again once that
      # SHA changes (a human pulled --rebase and pushed something new, or
      # the divergence moved on its own).
      local stamp="$STATE_DIR/diverged.stamp" remote_head="" prev=""
      remote_head=$(git -C "$DATA_REPO" rev-parse '@{upstream}' 2>/dev/null || true)
      if [[ -f "$stamp" ]]; then
        prev=$(cat "$stamp" 2>/dev/null || true)
      fi
      if [[ -z "$remote_head" || "$remote_head" != "$prev" ]]; then
        notify "OmaBackup: remote diverged" "Backups are committing locally but cannot push.
Run: git -C $DATA_REPO pull --rebase"
        if [[ -n "$remote_head" ]]; then
          # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
          mkdir -m 700 -p "$STATE_DIR"
          printf '%s\n' "$remote_head" > "$stamp"
        fi
      fi
    else
      warn "push failed: $(tail -n1 <<<"$err")"
      warn "commit is safe locally; the next run will push it"
    fi
  fi
}
