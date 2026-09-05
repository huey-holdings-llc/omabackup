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
    *$'\n'*|*$'\t'*) return 1 ;;
    ..|../*|*/..|*/../*) return 1 ;;
  esac
  printf '%s' "$p"
}

# drift_has WANT TYPES: does the current drift report name this exact path
# under one of the pipe-separated TYPES?
drift_has() {
  local want=$1 types=$2 line t rest path
  while IFS= read -r line; do
    t=${line%%[[:space:]]*}
    rest=${line#"$t"}; rest=${rest#"${rest%%[![:space:]]*}"}
    case "$rest" in *' ('*) path=${rest%% (*} ;; *) path=$rest ;; esac
    path=${path%"${path##*[![:space:]]}"}
    [[ "$path" == "$want" ]] && return 0
  done < <(grep -E "^($types)" "$DATA_REPO/manifests/drift.txt" 2>/dev/null)
  return 1
}

# drift_has_under WANT TYPES: a "~/dir/" target is legitimate when at least
# one drifting path lies UNDER it. Depth 1 ("~/.config/") is always refused:
# one click must never be able to silence an entire report.
drift_has_under() {
  local want=$1 types=$2 line t rest path
  case "${want#\~/}" in */*/*) ;; *) return 1 ;; esac    # "seg/" is depth 1
  while IFS= read -r line; do
    t=${line%%[[:space:]]*}
    rest=${line#"$t"}; rest=${rest#"${rest%%[![:space:]]*}"}
    case "$rest" in *' ('*) path=${rest%% (*} ;; *) path=$rest ;; esac
    path=${path%"${path##*[![:space:]]}"}
    case "$path" in "$want"?*) return 0 ;; esac
  done < <(grep -E "^($types)" "$DATA_REPO/manifests/drift.txt" 2>/dev/null)
  return 1
}

# drift_names_target TILDE TYPES: shared gate for allow/ignore targets --
# an exact drift line, or a folder prefix with drifting children.
drift_names_target() {
  local tilde=$1 types=$2
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
  mkdir -m 700 -p "$STATE_DIR"
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
  drift_names_target "$raw" 'MODIFIED|NEW|EXCLUDED|TOOBIG' \
    || { widget_reply_fail "the drift report does not name that path (or the folder is too broad); refresh and retry"; return 1; }
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
  drift_names_target "$raw" 'MODIFIED|NEW|EXCLUDED|TOOBIG' \
    || { widget_reply_fail "the drift report does not name that path (or the folder is too broad); refresh and retry"; return 1; }
  case "$rel" in */) entry="${rel%/}/**" ;; *) entry=$rel ;; esac
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

# cmd_resolve_gone PATH remove|optional: edit exactly the one matching
# allowlist.txt line -- delete it, or mark it '?' (optional).
cmd_resolve_gone() {
  data_repo_require
  local raw=${1:-} verb=${2:-} rel
  assert_argv_safe "$raw"
  [[ -n "${2:-}" ]] && assert_argv_safe "$2"
  rel=$(rel_from_tilde "$raw") || { widget_reply_fail "not a clean ~/-relative path: $raw"; return 1; }
  case "$verb" in remove|optional) ;; *) widget_reply_fail "usage: resolve-gone <path> remove|optional"; return 1 ;; esac
  drift_has "$raw" 'GONE' \
    || { widget_reply_fail "the drift report does not list that path as GONE"; return 1; }
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
    ' "$DATA_REPO/allowlist.txt" > "$tmp" && mv -f "$tmp" "$DATA_REPO/allowlist.txt"
  }
  edited_with_lint_gate "allowlist.txt" _widget_edit_gone || return 1
  health_write_status
  printf '{"ok":true,"lint_ok":true,"resolved":%s,"verb":%s}\n' "$(jstr "$rel")" "$(jstr "$verb")"
}

# cmd_push [--confirm]: the dynamic push button. Plain push when only commits
# are waiting; when the four lists (or .gitleaks.toml) are dirty, report the
# files and require --confirm, then stage EXACTLY those paths (never -A) and
# commit with a message naming them.
cmd_push() {
  data_repo_require
  local confirm=${1:-} dirty=() line p files_json=() out
  [[ -n "$confirm" ]] && assert_argv_safe "$confirm"
  local -a watch=(allowlist.txt drift-ignore.txt etc-allowlist.txt normalize.txt .gitleaks.toml)
  while IFS= read -r -d '' line; do
    p=${line:3}
    [[ -n "$p" ]] && dirty+=("$p")
  done < <(git -C "$DATA_REPO" status --porcelain -z -- "${watch[@]}" 2>/dev/null)

  if [[ ${#dirty[@]} -gt 0 && "$confirm" != "--confirm" ]]; then
    for p in "${dirty[@]}"; do files_json+=("$(jstr "$p")"); done
    printf '{"ok":false,"needs_confirm":true,"files":[%s]}\n' "$(jjoin "${files_json[@]}")"
    return 1
  fi

  remote_probe
  remote_push_allowed || { widget_reply_fail "push not allowed: $PUSH_REASON"; return 1; }

  if [[ ${#dirty[@]} -gt 0 ]]; then
    if ! take_lock; then widget_reply_fail "the repo lock is held (a snapshot may be running); try again shortly"; return 1; fi
    git -C "$DATA_REPO" add -- "${dirty[@]}" \
      || { drop_lock; widget_reply_fail "git add failed for the listed files"; return 1; }
    # AUTHORITATIVE GATE, the same one the snapshot pipeline runs before its
    # own commit (lib/snapshot.sh). This path stages five files a human just
    # edited -- .gitleaks.toml among them -- and committed them with no
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
    out=$(git -C "$DATA_REPO" commit -q -m "lists: update ${dirty[*]} via widget" 2>&1) \
      || { drop_lock; widget_reply_fail "commit failed: $out"; return 1; }
    drop_lock
  fi
  remote_push_if_ahead
  health_write_status
  printf '{"ok":true,"committed":%s}\n' "${#dirty[@]}"
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
      # systemd to start it. When the unit is not loaded (or tests ask us to
      # skip real timer state with OMABACKUP_SKIP_TIMERS), fall back to a
      # detached snapshot so the popup's button still does something -- the
      # snapshot itself calls health_write_status when it finishes, which is
      # how the widget sees the result.
      if [[ "${OMABACKUP_SKIP_TIMERS:-0}" != 1 ]] && have systemctl \
        && systemctl --user start omabackup-snapshot.service >/dev/null 2>&1; then
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
  data_repo_require
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
