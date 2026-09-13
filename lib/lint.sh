#!/usr/bin/env bash
# Lint allowlist.txt, drift-ignore.txt, etc-allowlist.txt and normalize.txt.
#
# WHY: these lists are the part of the system that grows forever. Left
# unchecked they accumulate dead entries, shadowed duplicates, and entries
# written in a form that silently means something wider than intended, which
# is how a "clean" drift report starts lying. This turns those chores into a
# lint failure instead of something nobody notices for a year.
#
# Ported from the source engine, bin/lint-lists.sh. Sourced by bin/omabackup;
# never executed.
#
# ERREXIT DISCIPLINE: every command whose exit status is inspected sits on
# the left of `||` or inside an `if`. There is no bare `var=$(cmd)` around a
# command that is allowed to fail, and normalize.txt's sed expressions are
# tried against the literal `x` inside an `if`, never bare.
# shellcheck shell=bash

# lint_bad CODE PATH [NOTE]: record a problem. Printed in red when JSON=0.
lint_bad() {
  local code=$1 path=$2 note=${3:-}
  LINT_PROBLEMS+=("{\"code\":$(jstr "$code"),\"path\":$(jstr "$path"),\"note\":$(jstr "$note")}")
  if [[ $JSON != 1 ]]; then
    if [[ -n "$note" ]]; then
      printf '  \033[1;31m%s\033[0m %s (%s)\n' "$code" "$path" "$note"
    else
      printf '  \033[1;31m%s\033[0m %s\n' "$code" "$path"
    fi
  fi
}
# lint_note CODE PATH [NOTE]: record an informational note, not a failure.
lint_note() {
  local code=$1 path=$2 note=${3:-}
  LINT_NOTES+=("{\"code\":$(jstr "$code"),\"path\":$(jstr "$path"),\"note\":$(jstr "$note")}")
  if [[ $JSON != 1 ]]; then
    if [[ -n "$note" ]]; then
      printf '  \033[1;33m%s\033[0m %s (%s)\n' "$code" "$path" "$note"
    else
      printf '  \033[1;33m%s\033[0m %s\n' "$code" "$path"
    fi
  fi
}

# lint_allowlist: DUP / TRAILSPACE / QMARK / TRAVERSAL / ABSOLUTE / MISSING /
# ABSENT. Fills the global LINT_AL array, reused by lint_completeness below.
lint_allowlist() {
  [[ $JSON == 1 ]] || echo "== allowlist.txt =="
  mapfile -t LINT_AL < <(read_list "$DATA_REPO/allowlist.txt")
  local -A seen_al=()
  local raw e
  for raw in "${LINT_AL[@]}"; do
    e="${raw#\?}"
    # Spaces are supported (each entry is a whole line), so this is
    # informational only, kept because a stray trailing space is usually a typo.
    case "$e" in *" ") lint_note "TRAILSPACE" "$raw" "trailing space, probably unintended" ;; esac
    [[ -n "${seen_al[$e]:-}" ]] && lint_bad "DUP" "$raw"
    seen_al[$e]=1
    # '?' anywhere but the first character is almost certainly a typo.
    case "${raw#\?}" in
      *'?'*) lint_note "QMARK" "$raw" "a '?' after the first char is a glob, not the optional marker" ;;
    esac
    # Defence in depth. rsync already refuses a ".." segment, and every entry
    # is joined to $HOME, so neither of these can currently walk out; they are
    # a hard lint failure anyway, because an allowlist entry is a path this
    # tool copies in BOTH directions and "rsync happens to refuse it" is not a
    # property worth depending on.
    case "/$e/" in
      *'/../'*) lint_bad "TRAVERSAL" "$raw" "a '..' path segment is never a valid entry" ;;
    esac
    case "$e" in
      /*) lint_bad "ABSOLUTE" "$raw" "entries are relative to \$HOME; drop the leading /" ;;
    esac
    # Does it actually resolve? A typo'd path aborts the snapshot entirely;
    # this is the one edit most likely to halt the whole backup if it slips
    # past lint. snapshot_entry_exists (lib/snapshot.sh) is the same test the
    # pipeline itself uses, so lint and the pipeline can never disagree.
    if ! snapshot_entry_exists "$e"; then
      case "$raw" in
        \?*) lint_note "ABSENT" "$raw" "optional, backups continue, recorded as GONE" ;;
        *)   lint_bad  "MISSING" "$raw" "resolves to nothing, snapshot will HALT" ;;
      esac
    fi
  done
  [[ $JSON == 1 ]] || echo "  ${#LINT_AL[@]} entries"
}

# lint_drift_ignore: DUP / SHADOWED / TOOWIDE / WIDE / CROSSES / STALE.
lint_drift_ignore() {
  [[ $JSON == 1 ]] || echo "== drift-ignore.txt =="
  local -a ig
  mapfile -t ig < <(read_list "$DATA_REPO/drift-ignore.txt")
  local -A seen_ig=()
  local e b lit p
  for e in "${ig[@]}"; do
    [[ -n "${seen_ig[$e]:-}" ]] && lint_bad "DUP" "$e"
    seen_ig[$e]=1
    # A bare entry plus its own /** twin: the subtree wins, the bare one is dead.
    case "$e" in
      */'**')
        b="${e%/\*\*}"
        [[ -n "${seen_ig[$b]:-}" ]] && lint_bad "SHADOWED" "$b" "dead: '$e' already covers it"
        ;;
    esac
    # A wildcard with NO literal characters left matches everything. Verified
    # in the source repo: a single `*` line took the drift report from 39
    # items to 0 while lint reported clean, a total fail-open of the tool
    # meant to prevent fail-open. Strip the wildcards and see whether
    # anything constraining remains:
    #   *        -> ""      TOOWIDE
    #   *.bak.*  -> ".bak." fine (a real suffix pattern)
    #   *~       -> "~"     fine
    lit="${e//\*/}"; lit="${lit//\?/}"
    case "$lit" in
      ''|'.'|'/'|'./') lint_bad "TOOWIDE" "$e" "no literal characters, silences the whole report" ;;
    esac
    # `foo/*` also crosses '/' in a case glob, so it silently means the
    # subtree. Only one of WIDE/CROSSES can fire per entry, in this order.
    case "$e" in
      *'/*')
        case "$e" in
          *'/**') ;;
          *) lint_bad "WIDE" "$e" "'foo/*' crosses '/' like a subtree, write 'foo/**' to say so explicitly" ;;
        esac
        ;;
      */*'*'*)
        case "$e" in
          */'**') ;;
          *) lint_note "CROSSES" "$e" "a '*' inside a path crosses '/' in a case glob, wider than it looks" ;;
        esac
        ;;
    esac
    # An ignore for a path that no longer exists is dead weight.
    case "$e" in
      *'*'*) ;;   # globs can legitimately match nothing today
      *)
        case "$e" in
          /*) p="$e" ;;
          *)  p="$HOME/$e" ;;
        esac
        [[ -e "$p" ]] || lint_note "STALE" "$e" "path no longer exists, safe to delete"
        ;;
    esac
  done
  # NOTE: a /** ignore overlapping an allowlisted child is NOT a conflict:
  # is_covered() runs before the ignores in every scan path, so the allowlist
  # wins (verified: .ssh/config, .ssh/*.pub, .claude memory notes and plans
  # are all backed up despite .ssh/** and .claude/projects/**). Flagging the
  # overlap was a false positive. What actually matters is the end-to-end
  # result, checked by the completeness walk below.
  [[ $JSON == 1 ]] || echo "  ${#ig[@]} entries"
}

# lint_completeness: NOTBACKEDUP. Requires lint_allowlist to have already run
# (reads LINT_AL). Skipped entirely when cmd_lint was called with --no-walk:
# the write verbs (Task 12: allow/ignore) gate their list edits with lint, and
# a just-allowed path CANNOT be in home/ until the next snapshot runs, so
# flagging it NOTBACKEDUP would roll back every real Allow. Hygiene above
# still runs unconditionally; completeness stays the job of the
# standalone/weekly lint, which runs after snapshots.
lint_completeness() {
  # The strongest assertion available: for every path the allowlist matches
  # on disk, the corresponding file must exist under home/. This catches an
  # ignore that really did win, an rsync --exclude that swallowed something,
  # and a .gitignore pattern that dropped a file, none of which the
  # count-based reconcile in the snapshot pipeline can localise.
  local nullglob_was_on
  shopt -q nullglob && nullglob_was_on=1 || nullglob_was_on=0
  shopt -s nullglob

  # Files created since the last snapshot are legitimately not in home/ yet.
  # Flagging them made lint fail every time a new file appeared between runs,
  # which is a false positive, not a fidelity bug.
  local since=0
  if [[ -f "$DATA_REPO/manifests/.last-run" ]]; then
    since=$(cat "$DATA_REPO/manifests/.last-run" 2>/dev/null) || since=0
  fi
  case "$since" in
    ''|*[!0-9]*) since=$(git -C "$DATA_REPO" log -1 --format=%ct 2>/dev/null) || since=0 ;;
  esac
  [[ -n "$since" ]] || since=0
  local size_find; size_find=$(manifests_find_size "$CFG_MAX_FILE_SIZE")

  local checked=0 miss=0 pending=0 e m rel f r mtime
  for e in "${LINT_AL[@]}"; do
    e="${e#\?}"
    for m in "$HOME"/$e; do
      [[ -e "$m" ]] || continue
      rel="${m#"$HOME"/}"
      if [[ -d "$m" ]]; then
        # NUL-delimited, like every other find reader here: a newline in a
        # filename split one path into two fragments, and both fragments were
        # then reported NOTBACKEDUP for a file that was backed up in full.
        while IFS= read -r -d '' f; do
          checked=$((checked+1))
          r="${f#"$HOME"/}"
          if [[ ! -e "$DATA_REPO/home/$r" ]]; then
            mtime=$(stat -c %Y "$f" 2>/dev/null) || mtime=0
            if [[ "$mtime" -gt "$since" ]]; then
              pending=$((pending+1))
            else
              lint_bad "NOTBACKEDUP" "$r"
              miss=$((miss+1))
              [[ "$miss" -ge 5 ]] && break 2
            fi
          fi
        # Same exclusions the snapshot's rsync applies (.git/, *.log, size
        # cap), or a deliberately skipped file is flagged NOTBACKEDUP forever.
        done < <(find "$m" -path '*/.git' -prune -o -type f ! -name '*.bak.*' ! -name '*.sample' \
                   ! -name 'mimeinfo.cache' ! -name '*.log' ! -size +"$size_find" -print0 2>/dev/null)
      else
        checked=$((checked+1))
        if [[ ! -e "$DATA_REPO/home/$rel" ]]; then
          mtime=$(stat -c %Y "$m" 2>/dev/null) || mtime=0
          if [[ "$mtime" -gt "$since" ]]; then
            pending=$((pending+1))
          else
            lint_bad "NOTBACKEDUP" "$rel"
            miss=$((miss+1))
          fi
        fi
      fi
    done
  done
  if [[ $JSON != 1 ]]; then
    if [[ "$pending" -gt 0 ]]; then
      echo "  $checked allowlisted file(s) verified present in home/ ($pending newer than the last snapshot, not yet captured)"
    else
      echo "  $checked allowlisted file(s) verified present in home/"
    fi
  fi
  [[ "$nullglob_was_on" == 1 ]] || shopt -u nullglob
}

# lint_etc_allowlist: NOTETC / STALE.
lint_etc_allowlist() {
  [[ $JSON == 1 ]] || echo "== etc-allowlist.txt =="
  local n=0 f
  while IFS= read -r f; do
    n=$((n+1))
    case "$f" in /etc/*) ;; *) lint_bad "NOTETC" "$f" ;; esac
    [[ -e "$f" ]] || lint_note "STALE" "$f" "not present on this machine"
  done < <(read_list "$DATA_REPO/etc-allowlist.txt")
  [[ $JSON == 1 ]] || echo "  $n entries"
}

# lint_normalize: NOEXPR / BADRULE / BADSED. Every sed expression is tried
# against the literal `x`, inside an `if`, so a broken rule is caught here
# rather than the next time it runs for real against a backed-up file.
#
# It is tried under `sed --sandbox` (normalize_expr_sandboxed, lib/snapshot.sh)
# and never bare. This check used to BE the execution site: a rule reading
# `home/x<TAB>1e touch /path` ran that shell command during a plain
# `omabackup lint` on a freshly cloned data repo, and lint then printed "lists
# clean". BADRULE covers both halves of that: a rule sed refuses to compile in
# sandbox mode (the e, r and w commands), and a path that could expand outside
# the staging tree. BADSED stays what it always was, a rule with a syntax error.
lint_normalize() {
  [[ $JSON == 1 ]] || echo "== normalize.txt =="
  local n=0 npath nexpr serr
  while IFS=$'\t' read -r npath nexpr; do
    case "$npath" in ''|'#'*) continue ;; esac
    n=$((n+1))
    if [[ -z "$nexpr" ]]; then
      lint_bad "NOEXPR" "$npath" "missing TAB-separated sed expression"
      continue
    fi
    if ! normalize_npath_ok "$npath"; then
      lint_bad "BADRULE" "$npath" "path must be relative to the staging root, with no '..' segment"
      continue
    fi
    if ! serr=$(normalize_expr_sandboxed "$nexpr"); then
      if [[ "$serr" == *"sandbox mode"* ]]; then
        lint_bad "BADRULE" "$npath" "runs commands or reads/writes files (sed e, r, w): $nexpr"
      else
        # BADSED reads "path -> expr", not "path (note)": the failing
        # expression itself is the useful detail here, not a parenthetical.
        LINT_PROBLEMS+=("{\"code\":$(jstr BADSED),\"path\":$(jstr "$npath"),\"note\":$(jstr "$nexpr")}")
        [[ $JSON == 1 ]] || printf '  \033[1;31m%s\033[0m %s -> %s\n' "BADSED" "$npath" "$nexpr"
      fi
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$DATA_REPO/normalize.txt" 2>/dev/null)
  [[ $JSON == 1 ]] || echo "  $n rules"
}

# lint_emit: the one JSON object, printed only when JSON=1.
#
# problems[] IS A LIST OF STRINGS, here and everywhere else. It used to be the
# one key in this tool whose type depended on which verb you asked: strings
# from status and health, {code,path,note} objects from lint. Panel.qml renders
# every entry as text and Service.qml puts problems[0] in the error line, so an
# object reached the user as "[object Object]" the moment a lint reply got
# there. The records are still the useful thing for a program, so they keep
# their own key, findings[], unchanged, and each one also becomes one sentence
# in problems[], out of the same code, path and note. Not a transcript of the
# non-JSON rendering: BADSED prints its note after an arrow rather than in
# brackets, and this mapping does not special-case it.
lint_emit() {
  [[ $JSON == 1 ]] || return 0
  local ok=true
  [[ ${#LINT_PROBLEMS[@]} -eq 0 ]] || ok=false
  jq -cn \
    --argjson ok "$ok" \
    --argjson findings "[$(jjoin ${LINT_PROBLEMS[@]+"${LINT_PROBLEMS[@]}"})]" \
    --argjson notes "[$(jjoin ${LINT_NOTES[@]+"${LINT_NOTES[@]}"})]" \
    '{ok:$ok,
      problems: ($findings | map(.code + " " + .path
                                 + (if (.note // "") == "" then "" else " (" + .note + ")" end))),
      findings:$findings, notes:$notes}'
}

# cmd_lint: `lint` verb. --no-walk skips lint_completeness (the write-gate
# mode Task 12's allow/ignore verbs use). Exit 0 clean, 1 problems found
# (capped, never the raw count, so the CLI's exit contract holds).
cmd_lint() {
  local a walk=1
  for a in "$@"; do
    case "$a" in
      --no-walk) walk=0 ;;
      *) usage_die "lint: unknown flag $a" ;;
    esac
  done
  data_repo_require

  LINT_PROBLEMS=(); LINT_NOTES=(); LINT_AL=()

  # Single instance. The completeness walk below compares live files against
  # home/, which the daily timer rewrites with rsync --delete: take the lock
  # so a mid-sync tree cannot produce five false NOTBACKEDUP lines and a red
  # weekly self-test.
  if ! take_lock 120; then
    drop_lock
    lint_bad "LOCKED" "snapshot is holding the lock (waited 120s); lint would read a changing tree"
    lint_emit
    return 1
  fi

  lint_allowlist
  lint_drift_ignore
  [[ $JSON == 1 ]] || echo "== allowlist -> backup completeness =="
  if [[ "$walk" == 1 ]]; then
    lint_completeness
  else
    [[ $JSON == 1 ]] || echo "  skipped (--no-walk: write-gate mode)"
  fi
  lint_etc_allowlist
  lint_normalize

  drop_lock

  if [[ $JSON != 1 ]]; then
    echo
    if [[ ${#LINT_PROBLEMS[@]} -eq 0 ]]; then
      echo "lists clean"
    else
      echo "${#LINT_PROBLEMS[@]} problem(s), see above"
    fi
  fi
  lint_emit
  [[ ${#LINT_PROBLEMS[@]} -eq 0 ]]
}
