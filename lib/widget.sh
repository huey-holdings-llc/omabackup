#!/usr/bin/env bash
# JSON backend for the bar widget. The panel renders exactly what `status`
# prints; all judgment lives in lib/health.sh, versioned and self-tested with
# the rest of the engine (self-test group 50), never in the widget itself.
#
# This file also carries the write verbs (allow/ignore/resolve-gone/push,
# plus timer/open) driven by the popup's triage buttons. Ported from
# the source engine, bin/widget-helper.sh:156-381. Every write path enforces:
#   * input must be a path the CURRENT drift report names (no arbitrary
#     writes), "~/"-prefixed exactly as `status` emitted it;
#   * the repo flock is held for the edit (and any rollback) -- but NOT while
#     lint runs, because lint takes the same lock itself (lib/lint.sh);
#   * `cmd_lint --no-walk` must pass afterward or the edit is rolled back.
# shellcheck shell=bash

# cmd_status: writes status.json and prints it (--json) or a human summary.
cmd_status() {
  data_repo_require
  health_collect
  local j; j=$(health_status_json)
  state_write_status "$j"
  if [[ $JSON == 1 ]]; then printf '%s\n' "$j"; else health_print_human; fi
  return 0
}

# ---- write actions ---------------------------------------------------------

# widget_reply_fail MSG: the one-line refusal shape every write verb uses.
widget_reply_fail() { printf '{"ok":false,"problems":[%s]}\n' "$(jstr "$1")"; return 1; }

# rel_from_tilde PATH: "~/rel" -> rel, refusing anything that is not a clean
# HOME-relative path. Matches the LITERAL "~/" prefix `status` emits; no
# expansion wanted (a real ~ expansion would let a hostile value walk outside
# $HOME entirely).
rel_from_tilde() {
  local p=$1
  # shellcheck disable=SC2088  # literal "~/" prefix, not a path to expand
  case "$p" in "~/"*) ;; *) return 1 ;; esac
  p=${p#\~/}
  case "$p" in
    ''|/*) return 1 ;;
    # A TAB is refused here (and by assert_argv_safe before this even runs)
    # for two reasons: it would smuggle a second field into a list file, and
    # it is the drift report's path/note separator, so a path carrying one
    # could never be matched against a report line anyway.
    *$'\n'*|*$'\t'*) return 1 ;;
    ..|../*|*/..|*/../*) return 1 ;;
  esac
  printf '%s' "$p"
}

# DRIFT_TARGET_DIR: 1 when the row (or folder) the gate below matched names a
# DIRECTORY, 0 when it names a single file. Set by drift_names_target, read by
# cmd_ignore. The trailing slash used to carry this, and it cannot any more:
# the popup sends the path exactly as the JSON gives it, and the JSON strips
# the slash. Without this, ignoring a collapsed ">2000 files" row wrote a bare
# entry, which by drift-ignore's own documented semantics means "look inside",
# so the next scan enumerated the whole tree the row existed to collapse.
DRIFT_TARGET_DIR=0

# widget_no_glob_chars PATH: 0 when PATH holds none of the glob characters an
# allowlist or drift-ignore entry is MATCHED with.
#
# The lists are globs, not literal paths: lists_load expands every allowlist
# entry against $HOME and is_ignored runs each ignore entry as a `case`
# pattern. A file genuinely named `*` (or holding `?` or `[`) is a legal
# filename the scan will report, and one Allow click would then have written
# an entry matching every sibling it has. Refusing here rather than escaping
# is the honest answer: there is no escaping syntax in these file formats to
# escape it INTO -- which is also why neither refusal below sends the user to
# a hand edit any more. There is no allowlist spelling that resolves to a
# literal `[`, so "edit allowlist.txt by hand" named an action nobody can
# take. The two that exist are renaming the file and ignoring the folder it
# sits in, and the messages say so.
widget_no_glob_chars() {
  case "$1" in *'*'*|*'?'*|*'['*) return 1 ;; esac
  return 0
}

# drift_has WANT TYPES: does the current drift report name this exact path
# under one of the pipe-separated TYPES? The line is split by
# drift_line_split (lib/drift.sh), the same function that builds the JSON the
# popup renders: this gate and the row the user clicked must recover the same
# path from the same line, or a crafted filename lets one click widen the
# allowlist to a directory the scan never reported.
#
# The comparison is made on both sides with one trailing slash stripped, which
# is exactly what drift_items_json does before the path reaches the widget
# ("a directory's trailing / is report display flourish"). It used to compare
# the slashless argument the popup sends against the slashed report line, so
# EVERY whole-directory row -- a new ~/.config/<app>/, a new dot-directory, a
# tree collapsed for being over the scan cap, which is most of what a real
# machine reports -- refused both buttons with "the drift report does not name
# that path; refresh and retry", and refreshing never helped.
drift_has() {
  local want=$1 types=$2 line
  local w=${want%/}
  while IFS= read -r line; do
    drift_line_split "$line" || continue
    [[ "${DRIFT_PATH%/}" == "$w" ]] || continue
    # THE REPORT'S OWN SLASH IS THE ONLY AUTHORITY. Taking the argument's as
    # well meant `allow '~/.config/foo.conf/'` matched a FILE row and then
    # wrote a subtree ignore for a path that is not a directory; before Wave C
    # that spelling was refused, and it goes back to being refused.
    case "$want" in */) [[ "$DRIFT_PATH" == */ ]] || continue ;; esac
    case "$DRIFT_PATH" in */) DRIFT_TARGET_DIR=1 ;; esac
    return 0
  done < <(grep -E "^($types)" "$DATA_REPO/manifests/drift.txt" 2>/dev/null)
  return 1
}

# drift_has_under WANT TYPES: a "~/dir/" target is legitimate when at least
# one drifting path lies UNDER it. Depth 1 ("~/.config/") is always refused:
# one click must never be able to silence an entire report.
drift_has_under() {
  local want=$1 types=$2 line
  case "${want#\~/}" in */*/*) ;; *) return 1 ;; esac    # "seg/" is depth 1
  while IFS= read -r line; do
    drift_line_split "$line" || continue
    # Same normalisation as drift_has: a collapsed child row ("~/a/b/c/")
    # lies under "~/a/b/" whether or not its own slash survived the report.
    case "${DRIFT_PATH%/}" in "$want"?*) DRIFT_TARGET_DIR=1; return 0 ;; esac
  done < <(grep -E "^($types)" "$DATA_REPO/manifests/drift.txt" 2>/dev/null)
  return 1
}

# drift_names_target TILDE TYPES: shared gate for allow/ignore targets --
# an exact drift line, or a folder prefix with drifting children.
drift_names_target() {
  local tilde=$1 types=$2
  DRIFT_TARGET_DIR=0
  drift_has "$tilde" "$types" && return 0
  case "$tilde" in */) drift_has_under "$tilde" "$types" && return 0 ;; esac
  return 1
}

# edited_with_lint_gate FILE EDITOR: back FILE up, run EDITOR (a shell
# function that edits it in place) under the repo lock, drop the lock, then
# lint. Roll the edit back when lint rejects the result. lint runs in a
# subshell (command substitution already gives one) with JSON=1 so its own
# take_lock/drop_lock never fights the fd this function already dropped.
edited_with_lint_gate() {
  local file=$1 editor=$2 bak lint_json lint_ok problems
  # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
  mkdir -m 700 -p "$STATE_DIR" \
    || { widget_reply_fail "could not create $STATE_DIR to back the list up before editing it"; return 1; }
  bak=$(mktemp "$STATE_DIR/.widget-list.XXXXXX") \
    || { widget_reply_fail "could not create a backup file under $STATE_DIR"; return 1; }
  if ! take_lock; then
    rm -f "$bak"
    widget_reply_fail "the repo lock is held (a snapshot may be running); try again shortly"
    return 1
  fi
  if ! cp "$DATA_REPO/$file" "$bak"; then
    drop_lock; rm -f "$bak"
    widget_reply_fail "could not back up $file before editing"
    return 1
  fi
  if ! "$editor"; then
    # Best-effort restore: the editor may have failed before touching the
    # file at all, but a failed restore here must not itself crash the
    # reply -- the caller still needs the JSON refusal below.
    cp "$bak" "$DATA_REPO/$file" 2>/dev/null || true
    drop_lock; rm -f "$bak"
    widget_reply_fail "the edit to $file failed; rolled back"
    return 1
  fi
  drop_lock
  # --no-walk: hygiene only. A just-allowed path cannot be in home/ until the
  # next snapshot runs, so the completeness walk would roll back every real
  # Allow. Completeness stays the standalone/weekly lint's job.
  lint_json=$(JSON=1 cmd_lint --no-walk 2>/dev/null)
  lint_ok=$(jq -r '.ok // false' <<<"$lint_json" 2>/dev/null || echo false)
  if [[ "$lint_ok" != true ]]; then
    # Same best-effort note as above: a rollback failure here must not
    # prevent the lint-rejection reply from reaching the caller.
    if take_lock; then cp "$bak" "$DATA_REPO/$file" 2>/dev/null || true; drop_lock; fi
    rm -f "$bak"
    problems=$(jq -r '[.problems[] | "\(.code) \(.path)"] | .[0:2] | join(" ")' <<<"$lint_json" 2>/dev/null)
    printf '{"ok":false,"lint_ok":false,"problems":[%s]}\n' \
      "$(jstr "lint rejected the edit (rolled back): $problems")"
    return 1
  fi
  rm -f "$bak"
  return 0
}

# cmd_allow PATH: append PATH to allowlist.txt, lint-gated.
cmd_allow() {
  data_repo_require
  local raw=${1:-} rel
  assert_argv_safe "$raw"
  rel=$(rel_from_tilde "$raw") || { widget_reply_fail "not a clean ~/-relative path: $raw"; return 1; }
  widget_no_glob_chars "$rel" \
    || { widget_reply_fail "a file whose name contains * ? or [ cannot be backed up by name; rename it, or ignore the folder it is in"; return 1; }
  # ALLOW IS NOT OFFERED FOR TOOBIG OR EXCLUDED, and the engine has to say so
  # too. Both classes are paths the allowlist ALREADY covers: one is held back
  # by maxFileSize, the other by .gitignore. Taking the click wrote an entry
  # that lifted neither limit, so the row struck itself out and came back
  # unchanged on the next scan. The popup hides the button (ui/DriftRow.qml);
  # a CLI caller gets the same sentence the row's explain line carries, naming
  # the limit that is actually holding the file.
  if ! drift_names_target "$raw" 'MODIFIED|NEW'; then
    local bare=${rel%/} msg
    if drift_names_target "$raw" 'TOOBIG'; then
      msg="$bare is over maxFileSize, so it is allowlisted but not copied; raise maxFileSize in the config, or ignore the file"
    elif drift_names_target "$raw" 'EXCLUDED'; then
      msg="$bare is matched by .gitignore, so it is allowlisted but not committed; add a negation line (for example !${bare##*/}) to the repo's .gitignore, or ignore the file"
    else
      msg="the drift report does not name that path (or the folder is too broad); refresh and retry"
    fi
    widget_reply_fail "$msg" || return 1
  fi
  rel=${rel%/}
  if grep -qxF -e "$rel" -e "?$rel" "$DATA_REPO/allowlist.txt"; then
    widget_reply_fail "already allowlisted: $rel"; return 1
  fi
  _widget_edit_allow() { printf '%s\n' "$rel" >> "$DATA_REPO/allowlist.txt"; }
  edited_with_lint_gate "allowlist.txt" _widget_edit_allow || return 1
  health_write_status
  printf '{"ok":true,"lint_ok":true,"added":%s}\n' "$(jstr "$rel")"
}

# cmd_ignore PATH [REASON]: append a dated entry to drift-ignore.txt,
# lint-gated. A collapsed tree ("path/") becomes the explicit /** subtree
# form drift-ignore.txt documents.
cmd_ignore() {
  data_repo_require
  local raw=${1:-} reason=${2:-} rel entry
  assert_argv_safe "$raw"
  [[ -n "${2:-}" ]] && assert_argv_safe "$2"
  rel=$(rel_from_tilde "$raw") || { widget_reply_fail "not a clean ~/-relative path: $raw"; return 1; }
  widget_no_glob_chars "$rel" \
    || { widget_reply_fail "a file whose name contains * ? or [ cannot be ignored by name; rename it, or ignore the folder it is in"; return 1; }
  drift_names_target "$raw" 'MODIFIED|NEW|EXCLUDED|TOOBIG' \
    || { widget_reply_fail "the drift report does not name that path (or the folder is too broad); refresh and retry"; return 1; }
  # A directory becomes the explicit /** subtree form drift-ignore.txt
  # documents, whether or not the argument carried the trailing slash: the
  # popup sends the JSON path, which never does. A bare entry on a directory
  # means "silence the directory, keep checking its children" (lib/lists.sh),
  # which on a collapsed ">2000 files" row would replace one row with
  # thousands.
  if [[ "$DRIFT_TARGET_DIR" == 1 ]]; then entry="${rel%/}/**"; else entry=$rel; fi
  reason=${reason:-"triaged from widget"}
  # Exact-entry comparison (comments stripped), not a regex: ignore entries
  # are globs, and escaping them for grep -E is exactly the kind of code that
  # rots.
  if awk -v e="$entry" '{ line=$0; sub(/[ \t]+#.*$/,"",line); sub(/[ \t]+$/,"",line)
      if (line==e) { found=1; exit } } END { exit !found }' "$DATA_REPO/drift-ignore.txt" 2>/dev/null; then
    widget_reply_fail "already ignored: $entry"; return 1
  fi
  _widget_edit_ignore() { printf '%s   # %s %s\n' "$entry" "$(date +%F)" "$reason" >> "$DATA_REPO/drift-ignore.txt"; }
  edited_with_lint_gate "drift-ignore.txt" _widget_edit_ignore || return 1
  health_write_status
  printf '{"ok":true,"lint_ok":true,"ignored":%s}\n' "$(jstr "$entry")"
}

# widget_entry_vanished REL: 0 when allowlist.txt carries an entry for REL
# (optional or not) that does not resolve in $HOME at this moment. The entry
# is compared whole, comments stripped, because an entry is a glob and
# building a regex out of one is the kind of code that rots.
widget_entry_vanished() {
  local rel=$1
  awk -v rel="$rel" '
    { line=$0; sub(/[ \t]+#.*$/,"",line); sub(/[ \t]+$/,"",line) }
    line==rel || line=="?"rel { found=1; exit }
    END { exit !found }' "$DATA_REPO/allowlist.txt" 2>/dev/null || return 1
  # snapshot_entry_exists (lib/snapshot.sh) is the one matcher that knows an
  # entry may be a glob, may hold a space, and may be a literal path that
  # nullglob leaves standing.
  snapshot_entry_exists "$rel" && return 1
  return 0
}

# cmd_resolve_gone PATH remove|optional: edit exactly the one matching
# allowlist.txt line -- delete it, or mark it '?' (optional).
cmd_resolve_gone() {
  data_repo_require
  local raw=${1:-} verb=${2:-} rel
  assert_argv_safe "$raw"
  [[ -n "${2:-}" ]] && assert_argv_safe "$2"
  rel=$(rel_from_tilde "$raw") || { widget_reply_fail "not a clean ~/-relative path: $raw"; return 1; }
  case "$verb" in remove|optional) ;; *) widget_reply_fail "usage: resolve-gone <path> remove|optional"; return 1 ;; esac
  # THE GATE HAS TWO HALVES, and it needs both. The mass-disappearance refusal
  # names this verb as the way out, and that run DIES before it writes a drift
  # report: the entries that caused the refusal are precisely the ones the last
  # committed report does not list as GONE, so the named way out could not be
  # taken and a hand edit of allowlist.txt was the only fix left. An allowlist
  # entry that does not resolve in $HOME right now is the same fact the report
  # would have recorded, checked live instead of read from yesterday's file.
  if ! drift_has "$raw" 'GONE' && ! widget_entry_vanished "$rel"; then
    widget_reply_fail "the drift report does not list that path as GONE, and allowlist.txt has no entry for it that has stopped resolving"
    return 1
  fi
  # "Mark optional" on an entry that is ALREADY optional used to reprint the
  # line unchanged and still reply ok, so the popup marked the row handled, it
  # disappeared, and the next snapshot brought it straight back. Every seed
  # entry ships optional and a fresh machine has none of the apps they name,
  # so that was the first thing a new user clicked. Say what actually helps.
  if [[ "$verb" == optional ]] && awk -v rel="$rel" '
      { line=$0; sub(/[ \t]+#.*$/,"",line); sub(/[ \t]+$/,"",line) }
      line=="?"rel { found=1; exit }
      END { exit !found }' "$DATA_REPO/allowlist.txt" 2>/dev/null; then
    widget_reply_fail "already optional; use Remove to drop the entry"
    return 1
  fi
  # Both halves of the gate above can pass with NO allowlist line to edit: a
  # GONE row survives in yesterday's report after the entry behind it was
  # deleted by hand. The edit would then rewrite the file unchanged and reply
  # ok, and the popup would strike the row off for a decision nobody recorded.
  if ! awk -v rel="$rel" '
      { line=$0; sub(/[ \t]+#.*$/,"",line); sub(/[ \t]+$/,"",line) }
      line==rel || line=="?"rel { found=1; exit }
      END { exit !found }' "$DATA_REPO/allowlist.txt" 2>/dev/null; then
    widget_reply_fail "allowlist.txt has no entry for that path; nothing to resolve"
    return 1
  fi
  _widget_edit_gone() {
    local tmp
    tmp=$(mktemp "$DATA_REPO/.allowlist.widget-tmp.XXXXXX") || return 1
    awk -v rel="$rel" -v verb="$verb" '
      { line=$0; sub(/[ \t]+#.*$/,"",line); sub(/[ \t]+$/,"",line) }
      !done && (line==rel || line=="?"rel) {
        done=1
        if (verb=="optional" && line==rel) { print "?" $0 }
        else if (verb=="optional") { print }
        next
      }
      { print }
      # A no-op rewrite is not an edit. The pre-check above is what a user
      # sees, but this is the one that cannot be raced: if the line went away
      # between the two, the edit fails and edited_with_lint_gate rolls back
      # rather than reporting a decision that was never recorded.
      END { exit !done }
    ' "$DATA_REPO/allowlist.txt" > "$tmp" && mv -f "$tmp" "$DATA_REPO/allowlist.txt" || { rm -f "$tmp"; return 1; }
  }
  edited_with_lint_gate "allowlist.txt" _widget_edit_gone || return 1
  health_write_status
  printf '{"ok":true,"lint_ok":true,"resolved":%s,"verb":%s}\n' "$(jstr "$rel")" "$(jstr "$verb")"
}

# push_nothing_ahead: 0 when git can prove there is nothing to send. An
# upstream must exist (without one the first push is exactly what establishes
# it, so "nothing ahead" is unprovable and the answer is no) and the ahead
# count must parse as zero. Every unreadable answer means "carry on and try",
# which is the fail-closed direction here: the cost is a probe, not a missed
# backup.
#
# ORIGIN MUST STILL BE THE REMOTE THE CONFIG NAMES. refs/remotes/origin/* is a
# LOCAL cache of a remote this repo may no longer be pointed at: `git remote
# set-url origin` does not invalidate it, so after a repoint "nothing ahead"
# is an answer about the remote git used to talk to, and the new one may have
# none of these commits at all. That is the same "trust belongs to one remote"
# rule remote_trust_ok enforces, and here it decides whether the shortcut is
# allowed to speak at all.
push_nothing_ahead() {
  local url; url=$(remote_origin_url)
  [[ -n "$url" && "$url" == "${CFG_REMOTE_URL:-}" ]] || return 1
  git -C "$DATA_REPO" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 || return 1
  local ahead
  ahead=$(git -C "$DATA_REPO" rev-list --count '@{upstream}..HEAD' 2>/dev/null) || return 1
  [[ "$ahead" == 0 ]]
}

# cmd_push [--confirm [SIG]]: the dynamic push button. Plain push when only
# commits are waiting. When the data repo has edits of its own (anything
# outside the snapshot's home/, etc/, manifests/ and modes.txt), report them
# and require --confirm, then stage EXACTLY those paths, literally (never -A,
# never a glob), and commit them.
#
# The set is repo_own_edits (lib/health.sh), the same list status counts as
# uncommitted. It used to be five named list files while status counted
# everything, so an edit outside the five was an "N uncommitted" the button
# ran against and never moved. Every file status reports as an uncommitted
# edit needs a button that commits it; one producer makes that true by
# construction instead of by keeping two lists in step.
#
# SIG is status.json's uncommitted_sig. The popup passes the one it drew the
# dialog from, and a list that changed since (a file saved between the dialog
# and the click) is answered with needs_confirm and the new list, never
# committed unseen. `--confirm` alone, typed after a plain `push` printed the
# list, still works.
cmd_push() {
  data_repo_require
  local confirm=${1:-} want_sig=${2:-} p files_json=() out sig
  local -a dirty=() stage=()
  [[ -n "$confirm" ]] && assert_argv_safe "$confirm"
  if [[ -n "$want_sig" ]]; then
    [[ "$confirm" == --confirm && "$want_sig" =~ ^[0-9]+$ ]] \
      || usage_die "push --confirm takes one optional SIGNATURE: the number status reports as uncommitted_sig"
  fi
  mapfile -d '' -t dirty < <(repo_own_edits | LC_ALL=C sort -zu)
  sig=$(own_edits_sig ${dirty[@]+"${dirty[@]}"})

  # A list the popup cannot show in full is not one this button may commit.
  if (( ${#dirty[@]} > UNCOMMITTED_LIMIT )); then
    widget_reply_fail "${#dirty[@]} uncommitted edits in the data repo is more than the Commit button commits at once ($UNCOMMITTED_LIMIT); look at them with git -C $DATA_REPO status and commit them by hand"
    return 1
  fi
  # Nor is one it cannot show AS IT IS. json_escape drops control bytes, so a
  # name holding one would be listed as a different name from the path the
  # signature binds and git stages, and two names could list as one.
  for p in ${dirty[@]+"${dirty[@]}"}; do
    if [[ "$p" == *[[:cntrl:]]* ]]; then
      widget_reply_fail "an edit in the data repo has a control character in its name, which the list cannot show as it is: $(printf '%q' "$p"); rename it, or commit it by hand"
      return 1
    fi
  done
  # The snapshot's filename gate (secrets_filename_gate), over what this button
  # would add or change. The five list files it used to stage could never
  # match; now an adopted repo's tracked `.env` or vault can, .gitignore only
  # hides untracked files, and the content scan cannot read an encrypted
  # vault. A deletion is not checked: taking such a file out is the fix.
  local hits
  hits=$(for p in ${dirty[@]+"${dirty[@]}"}; do
           [[ -e "$DATA_REPO/$p" || -L "$DATA_REPO/$p" ]] && printf '%s\0' "${p##*/}"
         done | grep -zE "$SECRET_NAME_RE" | grep -zvE "$SECRET_KEY_PUB_RE" | tr '\0' ' ' || true)
  if [[ -n "$hits" ]]; then
    widget_reply_fail "credential-looking filename(s) among the data repo's edits, nothing committed: ${hits% }; take them out of the repo (git -C $DATA_REPO rm --cached FILE) or rename them"
    return 1
  fi

  if [[ ${#dirty[@]} -gt 0 ]] && { [[ "$confirm" != --confirm ]] || [[ -n "$want_sig" && "$want_sig" != "$sig" ]]; }; then
    for p in "${dirty[@]}"; do files_json+=("$(jstr "$p")"); done
    printf '{"ok":false,"needs_confirm":true,"files":[%s],"sig":"%s"}\n' "$(jjoin "${files_json[@]}")" "$sig"
    return 1
  fi

  # NOTHING TO DO IS NOT A REFUSAL, and it must not touch the network to say
  # so. The popup shows Push whenever a remote exists, so pressing it on a
  # healthy machine is the normal case -- and that ran the visibility probe
  # and then painted "push not allowed: remote-unverified" in the urgent
  # colour, over a repo with nothing waiting and nothing wrong. Answer from
  # git alone, and record no verdict: a probe that was never asked for must
  # not overwrite the answer of one that was.
  if [[ ${#dirty[@]} -eq 0 ]] && push_nothing_ahead; then
    printf '{"ok":true,"pushed":0,"note":"nothing to push"}\n'
    return 0
  fi

  remote_probe
  # THE RECORDED VERDICT IS THE GATE'S, NOT THE PROBE'S. remote_probe has just
  # written what the probe alone decided, and the gate is stricter than the
  # probe: no gitleaks means no push whatever the remote turned out to be. Left
  # as it was, a machine with no scanner refused this button and status.json
  # went on saying push_verifiable:true, which is the one field the widget uses
  # to tell the user their commits can leave the machine.
  remote_push_allowed || {
    remote_verdict_write false "${PUSH_REASON:-unknown}"
    widget_reply_fail "push not allowed: $PUSH_REASON"; return 1
  }

  if [[ ${#dirty[@]} -gt 0 ]]; then
    if ! take_lock; then widget_reply_fail "the repo lock is held (a snapshot may be running); try again shortly"; return 1; fi
    # `git commit` commits the whole INDEX, not just the paths staged below.
    # The same defect the snapshot pipeline had: anything already staged when
    # the button was pressed -- a hand `git add` under home/, or what a run
    # that died between staging and committing left behind -- rode into this
    # list commit and was pushed with it. Unstage first. `git reset` leaves
    # the working tree alone, so the other edit survives as an uncommitted
    # change and is still reported by status and the login nag.
    if ! git -C "$DATA_REPO" diff --cached --quiet; then
      local pre
      pre=$( { git -C "$DATA_REPO" diff --cached --name-only || true; } | awk 'NR<=5' | paste -sd' ' )
      warn "unstaging what was staged before this push; anything in the confirmed list is staged again, the rest stays an uncommitted change: $pre"
      git -C "$DATA_REPO" reset -q \
        || { drop_lock; widget_reply_fail "could not unstage pre-existing staged changes"; return 1; }
    fi
    # The reset can shrink the list: an edit that only ever lived in the index
    # (added, then deleted from the working tree) is gone, and so is a staged
    # change the working tree already undid. Stage what is still an edit AND
    # was confirmed; never something that appeared since. The "k" prefix keeps
    # a file named `@` or `*` from being read as a subscript.
    local -A still=()
    while IFS= read -r -d '' p; do still["k$p"]=1; done < <(repo_own_edits)
    for p in "${dirty[@]}"; do [[ -n "${still["k$p"]:-}" ]] && stage+=("$p"); done
    if (( ${#stage[@]} == 0 )); then
      drop_lock
      remote_push_if_ahead
      health_write_status
      printf '{"ok":true,"committed":0}\n'
      return 0
    fi
    # --literal-pathspecs: a file named `m*.txt` or `a[1].txt`, or one that
    # starts with `:`, is that file, not a pattern that also matches the
    # snapshot's manifests/drift.txt. From stdin, not argv: no length limit.
    printf '%s\0' "${stage[@]}" \
      | git -C "$DATA_REPO" --literal-pathspecs add --pathspec-from-file=- --pathspec-file-nul \
      || { git -C "$DATA_REPO" reset -q 2>/dev/null || true; drop_lock; widget_reply_fail "git add failed for the listed files"; return 1; }
    # AUTHORITATIVE GATE, the same one the snapshot pipeline runs before its
    # own commit (lib/snapshot.sh). This path stages list files a human just
    # edited and committed them with no
    # content scan at all, so a token pasted into a list could be committed
    # and then pushed by the very next line. secrets_scan_staged die()s on a
    # hit, so it runs in a command substitution (its own subshell): the die
    # can only take THAT subshell down, its `git reset -q` has already undone
    # the staging in the real repo, and the refusal below is still this
    # verb's own {ok:false, problems:[...]} shape.
    local scan_rc=0 scan_out=""
    scan_out=$(secrets_scan_staged 2>&1) || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
      [[ -z "$scan_out" ]] || printf '%s\n' "$scan_out" >&2
      git -C "$DATA_REPO" reset -q 2>/dev/null || true
      drop_lock
      widget_reply_fail "the staged secret scan refused these files; staging undone, nothing committed"
      return 1
    fi
    # Same identity fallback as every other commit path: a machine with no
    # ~/.gitconfig cannot commit at all, and this one failed with "Author
    # identity unknown" and left the lists staged behind it. The reset on
    # failure is what keeps a refusal from leaving that mess.
    git_ident_args
    out=$( { printf 'omabackup: commit %d edit(s) from the Commit button\n\n' "${#stage[@]}"; printf '%s\n' "${stage[@]}"; } \
      | git -C "$DATA_REPO" ${GIT_IDENT_ARGS[@]+"${GIT_IDENT_ARGS[@]}"} commit -q -F - 2>&1) \
      || { git -C "$DATA_REPO" reset -q 2>/dev/null || true; drop_lock; widget_reply_fail "commit failed: $out"; return 1; }
    drop_lock
  fi
  remote_push_if_ahead
  health_write_status
  printf '{"ok":true,"committed":%s}\n' "${#stage[@]}"
}

# cmd_timer pause|resume|status|run: drive the daily unit.
cmd_timer() {
  data_repo_require
  local verb=${1:-} out
  [[ -n "$verb" ]] && assert_argv_safe "$verb"
  case "$verb" in
    pause)
      out=$(systemctl --user disable --now omabackup-snapshot.timer 2>&1) \
        || { widget_reply_fail "could not pause the timer: $out"; return 1; }
      health_write_status
      printf '{"ok":true}\n'
      ;;
    resume)
      out=$(systemctl --user enable --now omabackup-snapshot.timer 2>&1) \
        || { widget_reply_fail "could not resume the timer: $out"; return 1; }
      health_write_status
      printf '{"ok":true}\n'
      ;;
    status)
      local enabled=false active=false next=""
      if have systemctl; then
        systemctl --user is-enabled omabackup-snapshot.timer >/dev/null 2>&1 && enabled=true
        systemctl --user is-active  omabackup-snapshot.timer >/dev/null 2>&1 && active=true
        next=$(systemctl --user show omabackup-snapshot.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
        case "$next" in ''|'n/a'|0) next="" ;; esac
      fi
      jq -cn --argjson enabled "$enabled" --argjson active "$active" --arg next "$next" \
        '{ok:true, enabled:$enabled, active:$active, next:$next}'
      ;;
    run)
      # The proven daily path is the unit; block only long enough to ask
      # systemd to start it. --no-block is what makes that true: the unit is
      # Type=oneshot, so a plain `systemctl start` waits for the whole
      # snapshot (up to TimeoutStartSec=10min) and the popup's button would
      # hold `busy` for exactly as long as running the snapshot inline. The
      # run's outcome still reaches the widget: the snapshot calls
      # health_write_status when it finishes, status.json changes on disk, and
      # Service.qml's FileView plus the panel's settle timer pick it up. A
      # unit that is not loaded still fails here immediately, with or without
      # --no-block, so the fallback below is unaffected.
      #
      # When the unit is not loaded (or tests ask us to skip real timer state
      # with OMABACKUP_SKIP_TIMERS), fall back to a detached snapshot so the
      # button still does something.
      if [[ "${OMABACKUP_SKIP_TIMERS:-0}" != 1 ]] && have systemctl \
        && systemctl --user start --no-block omabackup-snapshot.service >/dev/null 2>&1; then
        printf '{"ok":true,"started":"unit"}\n'
      else
        have setsid || { widget_reply_fail "setsid is not available"; return 1; }
        if ! setsid -f "$PLUGIN_DIR/bin/omabackup" snapshot >/dev/null 2>&1; then
          widget_reply_fail "could not start a detached snapshot"
          return 1
        fi
        printf '{"ok":true,"started":"detached"}\n'
      fi
      ;;
    *) widget_reply_fail "usage: timer pause|resume|status|run"; return 1 ;;
  esac
}

# cmd_open: the escape hatch for everything a button should not judge
# (MODIFIED, TOOBIG, ERROR lines) -- a terminal, cd'd into the data repo.
# Always an argv array, never a shell string; detached so the popup does not
# wait on it.
cmd_open() {
  # Flags before the repo check: a typo is a usage error whatever state the
  # repo is in, and every other verb answers that way.
  local want_remote=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote) want_remote=1; shift ;;
      *) usage_die "open: unknown flag $1" ;;
    esac
  done
  data_repo_require
  [[ $want_remote == 0 ]] || { open_remote_page; return $?; }
  local -a term=()
  if have omarchy-launch-floating-terminal-with-presentation; then
    term=(omarchy-launch-floating-terminal-with-presentation)
  elif have xdg-terminal-exec; then
    term=(xdg-terminal-exec)
  else
    widget_reply_fail "no terminal launcher available (xdg-terminal-exec or omarchy-launch-floating-terminal-with-presentation)"
    return 1
  fi
  have setsid || { widget_reply_fail "setsid is not available"; return 1; }
  if ! ( cd "$DATA_REPO" && setsid -f "${term[@]}" >/dev/null 2>&1 ); then
    widget_reply_fail "could not open a terminal in $DATA_REPO"
    return 1
  fi
  printf '{"ok":true}\n'
}

# open_remote_page: the data repo's own page in a browser. Only a GitHub remote
# has a page this tool can name, and the URL is BUILT HERE from a slug
# remote_github_slug has already validated as exactly owner/repo -- so nothing
# a git remote says can choose the host, the scheme or the path. argv, never a
# shell string, and detached so the popup does not wait on a browser starting.
#
# The refusals below are the same condition status.json reports as
# remote_linkable:false, so the popup does not offer the click in the first
# place; a person typing the verb still gets a reason rather than silence.
open_remote_page() {
  local url slug page
  url=$(remote_origin_url)
  [[ -n "$url" ]] || { widget_reply_fail "this data repo has no remote, so there is no page to open"; return 1; }
  # Same rule the label follows: origin pushes elsewhere, so the fetch URL is
  # not where the backup goes and the engine will not push to either.
  ! remote_pushurl_differs \
    || { widget_reply_fail "origin pushes to a different URL than it fetches from, so there is no one repository to open; remove the pushurl with: git -C $DATA_REPO remote set-url --push --delete origin"; return 1; }
  slug=$(remote_github_slug "$url")
  [[ -n "$slug" ]] || { widget_reply_fail "no web page is known for this remote; only a GitHub remote has one this tool can name"; return 1; }
  page="https://github.com/$slug"
  local -a browser=()
  if have omarchy-launch-browser; then
    browser=(omarchy-launch-browser)
  elif have xdg-open; then
    browser=(xdg-open)
  else
    widget_reply_fail "no browser launcher available (omarchy-launch-browser or xdg-open)"
    return 1
  fi
  have setsid || { widget_reply_fail "setsid is not available"; return 1; }
  if ! setsid -f "${browser[@]}" "$page" >/dev/null 2>&1; then
    widget_reply_fail "could not open $page"
    return 1
  fi
  printf '{"ok":true,"opened":%s}\n' "$(jstr "$page")"
}
