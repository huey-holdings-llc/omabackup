#!/usr/bin/env bash
# The remote model: is it safe to push? Ported from
# the source engine, bin/snapshot.sh:537-580 (the visibility probe) and 582-616,
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

# remote_push_urls: every URL `git push origin` would actually write to, one
# per line. `remote.origin.pushurl` overrides the fetch URL for pushes only, so
# reading the fetch URL alone probes one remote and pushes to another: a
# private fetch URL with a public pushurl passed the probe and then published
# the config. With no pushurl set, git prints the fetch URL here, so the
# caller's comparison is a no-op in the normal case.
remote_push_urls() { git -C "$DATA_REPO" remote get-url --push --all origin 2>/dev/null || true; }

# remote_trust_ok URL: 0 when the operator's trust decision still applies to
# the URL git would push to right now. Trust is recorded against ONE remote
# (remote.url in the config); a later `git remote set-url origin` by hand
# leaves that yes attached to a remote nobody has vouched for, which is how a
# trusted private mirror silently becomes a public one. Warns and refuses
# instead of carrying the stale answer over.
remote_trust_ok() {
  [[ "$CFG_REMOTE_TRUSTED" == true ]] || return 1
  [[ "$CFG_REMOTE_URL" != "$1" ]] || return 0
  warn "origin has changed since it was trusted (trusted: $(remote_url_display "${CFG_REMOTE_URL:-none}")); rerun: omabackup setup --trust-remote"
  return 1
}

# remote_url_parts URL: print "host<TAB>path" for a git remote URL, with the
# scheme, the userinfo and the port stripped and the host lowercased. Prints
# an empty host for anything that is not a URL at all (a bare local path, the
# fixtures' /path/to/remote.git).
#
# ONE normaliser, because matching four literal prefixes missed real, working
# GitHub clone URLs: `http://github.com/o/r`, `https://GitHub.com/o/r`,
# `https://user@github.com/o/r` and `ssh://git@github.com:22/o/r` all read as
# "not GitHub", which meant no visibility probe ever ran and the widget then
# offered one click to trust a possibly PUBLIC repo. ALWAYS returns 0: the
# callers treat "not GitHub" as a legitimate, common outcome, not a failure.
remote_url_parts() {
  local u=$1 rest auth path="" host
  case "$u" in
    http://*|https://*|ssh://*|git://*) rest=${u#*://}
      auth=${rest%%/*}
      case "$rest" in */*) path=${rest#*/} ;; esac
      ;;
    *://*) printf '\t'; return 0 ;;   # some other scheme: not a form we parse
    *)
      # scp-like `[user@]host:path`. The FIRST colon separates the two, and a
      # string with no colon at all is a local path, not a remote host.
      case "$u" in *:*) ;; *) printf '\t'; return 0 ;; esac
      auth=${u%%:*}; path=${u#*:}
      ;;
  esac
  case "$auth" in *@*) auth=${auth##*@} ;; esac    # userinfo
  host=${auth%%:*}                                  # port
  host=${host,,}
  # A fully qualified name may carry the root's trailing dot, and resolvers
  # and git both treat "github.com." as github.com. Left on, it would be one
  # more spelling that reads as "not GitHub".
  host=${host%.}
  printf '%s\t%s' "$host" "$path"
  return 0
}

# remote_url_has_password URL: 0 when a scheme://user:password@host URL
# carries a password. Only the scheme form can: scp-like user@host:path has
# nowhere to put one. A password in a remote URL lands in .git/config, in
# this tool's config, and in every line that prints the remote, so setup
# refuses it rather than storing it.
remote_url_has_password() {
  local u=$1 auth
  case "$u" in *://*) ;; *) return 1 ;; esac
  auth=${u#*://}; auth=${auth%%/*}
  case "$auth" in *@*) auth=${auth%@*} ;; *) return 1 ;; esac
  case "$auth" in *:?*) return 0 ;; esac
  return 1
}

# remote_url_display URL: the URL with any password replaced by ***, for
# every place a remote is printed. The comparison sites keep the raw value.
remote_url_display() {
  local u=$1 rest auth path user
  remote_url_has_password "$u" || { printf '%s' "$u"; return 0; }
  rest=${u#*://}; auth=${rest%%/*}; path=${rest#"$auth"}
  user=${auth%@*}; user=${user%%:*}
  printf '%s://%s:***@%s%s' "${u%%://*}" "$user" "${auth##*@}" "$path"
}

# remote_is_github URL: 0 when the URL's HOST is GitHub, whatever shape the
# rest of it takes. Trust is refused for these (setup_remote): a GitHub remote
# is proven private by the API probe or not at all.
remote_is_github() {
  local hp; hp=$(remote_url_parts "$1")
  case "${hp%%$'\t'*}" in github.com|ssh.github.com) return 0 ;; esac
  return 1
}

# remote_github_slug URL: print "owner/repo" for a GitHub remote, else print
# nothing. The slug is interpolated into the api.github.com URL the probe
# asks about, so its SHAPE is validated: `https://github.com/o/r/..` used to
# yield the slug `o/r/..`, which curl normalised before sending, so the probe
# asked about a different repository than the one git pushes to and a 404 on
# the wrong path was recorded as "private". Anything that is not exactly
# owner/repo is unverifiable, and unverifiable is never probed.
remote_github_slug() {
  local hp host s
  hp=$(remote_url_parts "$1")
  host=${hp%%$'\t'*}; s=${hp#*$'\t'}
  case "$host" in github.com|ssh.github.com) ;; *) return 0 ;; esac
  s=${s%/}    # a trailing slash (github.com/o/r/) must not become part of the "r/" that .git-stripping below would otherwise leave alone
  s=${s%.git}
  [[ "$s" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 0
  printf '%s' "$s"
  return 0
}

# remote_pushurl_differs: 0 when origin pushes to any URL other than the one it
# fetches from. `remote.origin.pushurl` overrides the fetch URL for pushes
# only, so everything that reasons about "where the backup goes" has to ask
# this first: the probe refuses such a remote outright, and the popup must not
# name the fetch repository as the backup target when a push would go
# somewhere else entirely.
remote_pushurl_differs() {
  local url pu
  url=$(remote_origin_url)
  [[ -n "$url" ]] || return 1
  while IFS= read -r pu; do
    [[ -n "$pu" && "$pu" != "$url" ]] || continue
    return 0
  done < <(remote_push_urls)
  return 1
}

# remote_display_label URL SLUG: a short, safe identity for a remote, for the
# popup and anything else that shows a person WHERE their backup goes. SLUG is
# remote_github_slug's answer for the same URL, passed in so it is computed
# once per run rather than once per caller.
#
# NEVER the raw URL. remote_url_parts strips the userinfo before it returns, so
# a password cannot reach the label by construction, and a URL-shaped string
# that parser cannot read gets no label at all rather than a raw one: a string
# with "://" in it is the one shape that can carry a password, and printing an
# unparsed one is how it would leak into the popup and the log.
#
#   git@github.com:o/r.git            -> o/r
#   https://gitlab.example.com/a/b    -> gitlab.example.com/a/b
#   /srv/git/dots.git                 -> /srv/git/dots.git
#   https://[not a url               -> (nothing)
remote_display_label() {
  local u=$1 slug=${2:-} hp host path
  [[ -n "$u" ]] || return 0
  [[ -z "$slug" ]] || { printf '%s' "$slug"; return 0; }
  hp=$(remote_url_parts "$u")
  host=${hp%%$'\t'*}; path=${hp#*$'\t'}
  if [[ -n "$host" ]]; then
    path=${path#/}; path=${path%/}; path=${path%.git}
    if [[ -n "$path" ]]; then printf '%s/%s' "$host" "$path"; else printf '%s' "$host"; fi
    return 0
  fi
  # No host. A local path has no userinfo to hide and is the thing the operator
  # typed, so it is printed; anything URL-shaped is not.
  case "$u" in *://*) return 0 ;; esac
  printf '%s' "$u"
}

# remote_verdict_write VERIFIABLE REASON: record the push gate's last answer,
# against the URL it was an answer about.
#
# `push_verifiable` used to mean two unrelated things in one run: here, "the
# remote is proven private or explicitly trusted"; in lib/health.sh, "git
# rev-list --count parsed a number". On a machine with no gitleaks, one
# `snapshot --json` printed push_verifiable:false on stdout and wrote
# push_verifiable:true into status.json. The gate's answer lives in this
# process, and `status` is a different process that must never re-derive it
# (re-probing would put the widget's refresh on the wire), so it is persisted:
# health reads it back, and reads it as false unless the recorded URL is still
# the URL origin points at. Atomic rename, for the same reason status.json is.
#
# `at` is the time of the LAST PROBE and is rewritten every run. That is the
# right meaning for "is this answer fresh", and the wrong one for "how long
# has this been going on": a machine that cannot reach a verdict at all still
# writes a fresh `at` every day. So the file also carries the answer's
# history. `conclusive_at` is when the probe last actually settled the
# question (200 or 404, or any other reason that is an answer ABOUT THE
# REMOTE: see remote_reason_class), and it is carried forward untouched while
# the answers stay inconclusive.
# `inconclusive_since` dates the current streak for a machine that has never
# had a conclusive answer, so a first-run 403 behind a shared address still
# has a date to count from. Both are carried forward only when the recorded
# URL is still the URL origin points at, the same rule health reads the
# verdict by: a date about one remote says nothing about another.
remote_verdict_write() {
  local url; url=$(remote_origin_url)
  # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
  mkdir -m 700 -p "$STATE_DIR" || return 0
  local verdict="$STATE_DIR/push-verdict.json" now
  now=$(date +%s)
  local prev_url="" prev_conc="" prev_since=""
  if [[ -r "$verdict" ]]; then
    prev_url=$(jq -r '.url // ""' "$verdict" 2>/dev/null || true)
    if [[ -n "$url" && "$prev_url" == "$url" ]]; then
      prev_conc=$(jq -r '.conclusive_at // empty' "$verdict" 2>/dev/null || true)
      prev_since=$(jq -r '.inconclusive_since // empty' "$verdict" 2>/dev/null || true)
    fi
  fi
  # A 0.7.0 verdict has neither field, and a hand-edited one can have anything
  # in them. Whole seconds or nothing at all: an unusable value is dropped
  # rather than carried, and health then reports no age instead of a wrong one.
  case "$prev_conc" in ''|*[!0-9]*) prev_conc="" ;; esac
  case "$prev_since" in ''|*[!0-9]*) prev_since="" ;; esac
  local conc since
  case "$(remote_reason_class "$2")" in
    conclusive)   conc=$now;       since="" ;;
    inconclusive) conc=$prev_conc; since=${prev_since:-$now} ;;
    *)            conc=$prev_conc; since=$prev_since ;;
  esac
  local tmp
  tmp=$(mktemp "$STATE_DIR/.push-verdict.XXXXXX") || return 0
  if jq -cn --argjson v "$1" --arg r "$2" --arg u "$url" --argjson at "$now" \
       --arg conc "$conc" --arg since "$since" \
       '{verifiable:$v, reason:$r, url:$u, at:$at}
        + (if $conc  == "" then {} else {conclusive_at:      ($conc|tonumber)}  end)
        + (if $since == "" then {} else {inconclusive_since: ($since|tonumber)} end)' \
       > "$tmp" && chmod 600 "$tmp"; then
    mv -f "$tmp" "$verdict"
  else
    rm -f "$tmp"
  fi
  return 0
}

# remote_reason_class REASON: what this reason says about the REMOTE, which is
# the only question conclusive_at is dating.
#
#   conclusive    the question is settled: private, trusted, no-remote,
#                 remote-unverified, net-disabled, pushurl-differs. The clock
#                 restarts.
#   inconclusive  the probe shrugged (probe-<code>). The clock keeps running,
#                 and starts if it was not running.
#   silent        the answer is about THIS MACHINE, not the remote:
#                 gitleaks-missing (no scanner, so the gate shuts before the
#                 remote is even reached) and the unknown fallback. Neither
#                 date moves. Treating these as conclusive restarted the clock
#                 on every run of a machine whose scanner had been uninstalled
#                 for a month, which is exactly the streak this is meant to
#                 measure; treating them as inconclusive would have started a
#                 streak nothing had probed.
remote_reason_class() {
  case "$1" in
    probe-*)                 printf 'inconclusive' ;;
    gitleaks-missing|unknown|'') printf 'silent' ;;
    *)                       printf 'conclusive' ;;
  esac
}

# remote_probe: sets PUSH_VERIFIABLE (true|false) and PUSH_REASON. GitHub only
# -- a non-GitHub remote (or none at all) cannot be probed this way, so it is
# only ever pushed to when the operator has explicitly marked it trusted.
# HTTP 200 is the ONLY proof of public and dies; 404 is proof of private
# (or not-yet-created) and is verifiable; everything else (403 rate-limited,
# 429, 5xx, a connection failure) proves nothing either way and must not
# abort the run -- it just means "commit locally, don't push yet".
# Two things are checked before any of that: that git pushes where it fetches
# (no pushurl), and that a recorded trust decision still names the current
# origin. Both are about the same failure -- proving one URL safe and then
# writing to another.
remote_probe() {
  remote_probe_derive
  remote_verdict_write "$PUSH_VERIFIABLE" "${PUSH_REASON:-unknown}"
}
remote_probe_derive() {
  PUSH_VERIFIABLE=false; PUSH_REASON=""
  local url slug code pu
  url=$(remote_origin_url)
  [[ -n "$url" ]] || { PUSH_REASON="no-remote"; return 0; }
  # Fail closed on a pushurl that is not the URL everything below probes and
  # trusts. There is no safe way to verify two destinations from one answer,
  # and the fix is one command for the user: git remote set-url --push --delete.
  while IFS= read -r pu; do
    [[ -n "$pu" && "$pu" != "$url" ]] || continue
    warn "origin pushes to a different URL than it fetches from ($(remote_url_display "$pu")); refusing until the pushurl is removed"
    PUSH_REASON="pushurl-differs"
    return 0
  done < <(remote_push_urls)
  # `|| true`: belt-and-braces alongside the `return 0` inside
  # remote_github_slug itself -- a bare assignment here must never be able to
  # take the whole process down under errexit, no matter what the callee does.
  slug=$(remote_github_slug "$url" || true)
  if [[ -z "$slug" ]]; then
    # A GitHub HOST whose URL cannot be reduced to owner/repo can never be
    # probed, and trust does not apply to a GitHub host at all (setup refuses
    # to record one). Consulting trust here let a stale trusted flag push to
    # `https://github.com/o/r/..` with reason "trusted" and no probe ever run,
    # which is loss event (b) with the safety valve reading green.
    if remote_is_github "$url"; then PUSH_REASON="remote-unverified"; return 0; fi
    if remote_trust_ok "$url"; then PUSH_VERIFIABLE=true; PUSH_REASON="trusted"; else PUSH_REASON="remote-unverified"; fi
    return 0
  fi
  if [[ "${OMABACKUP_NET:-1}" == 0 ]]; then
    if remote_trust_ok "$url"; then PUSH_VERIFIABLE=true; PUSH_REASON="trusted"
    elif [[ "$CFG_REMOTE_TRUSTED" == true ]]; then PUSH_REASON="remote-unverified"
    else PUSH_REASON="net-disabled"; fi
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
  # PUSH_VERIFIABLE goes with the reason. It is the probe's answer until this
  # gate has run, and once the gate has refused it is this verb's answer to
  # "can anything be pushed" -- so a snapshot's own JSON and the status.json
  # written from the recorded verdict cannot disagree on a machine that has no
  # scanner, which is the one field the widget reads to say a commit can leave.
  gitleaks_available || { PUSH_VERIFIABLE=false; PUSH_REASON="gitleaks-missing"; return 1; }
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
    # The gate's real answer, gitleaks included: status.json reports THIS, not
    # health's own "the unpushed count parsed".
    remote_verdict_write false "${PUSH_REASON:-unknown}"
    SKIP_PUSH=1
    warn "push not verifiable ($PUSH_REASON); commit(s) kept locally, not pushed"
    return 0
  fi
  remote_verdict_write true "${PUSH_REASON:-verified}"
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
    # @{upstream} is a remote-tracking ref, and a rejected push does not
    # update it -- nor does anything else in this pipeline, which never
    # fetches. So a remote advanced on another machine still read as zero
    # commits behind: DIVERGED never fired, the rejection was classed as a
    # retryable "the next run will push it", and the same doomed push was
    # retried every day with no notification. Refresh the ref before counting.
    # Left of `||` so a fetch that fails (offline, auth, no `timeout` on this
    # PATH) keeps the old classification instead of killing the run under
    # errexit, and OMABACKUP_NET=0 keeps this off the wire entirely.
    if [[ "${OMABACKUP_NET:-1}" != 0 ]]; then
      timeout 30 git -C "$DATA_REPO" fetch -q origin >/dev/null 2>&1 \
        || warn "could not fetch origin after the failed push; the divergence check below may be stale"
    fi
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
          # WARN AND SKIP: the notification has already gone out, and a
          # state directory that cannot be written must not fail a run whose
          # push work is done. The cost is that the same divergence may be
          # announced again.
          if ! mkdir -m 700 -p "$STATE_DIR" || ! printf '%s\n' "$remote_head" > "$stamp"; then
            warn "cannot record the diverged stamp under $STATE_DIR; this may be announced again"
          fi
        fi
      fi
    else
      warn "push failed: $(tail -n1 <<<"$err")"
      warn "commit is safe locally; the next run will push it"
    fi
  fi
}
