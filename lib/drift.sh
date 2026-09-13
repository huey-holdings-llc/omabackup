#!/usr/bin/env bash
# The drift scan: compare the live $HOME (and, unless skipped, /etc) against
# Omarchy's stock defaults and the allowlist/drift-ignore lists, and report
# whatever falls through, config that looks user-authored but is NOT backed
# up. Ported from the source engine, bin/drift.sh, which learned most of these
# rules the hard way; read the comments before changing the matching.
#
# Silence an entry by adding it to drift-ignore.txt with a dated reason.
#
# shellcheck shell=bash
# shellcheck disable=SC2088 # drift_scan's report lines print a literal "~/"
# prefix as human-readable display text, never a path bash is asked to
# expand. Rewriting it to "$HOME/" would change the report and break the
# `has` assertions in tests/engine.test.sh that match strings like
# "NEW        ~/.config/mytool".

# DRIFT_CLASSES: NOT the actionable-row count (see drift_count_actionable
# below for that, deliberately a separate job with its own TOOBIG/EXCLUDED
# rows). This is the narrower set "new since the last report" is computed
# over: manifests_drift's MAN_DRIFT_PREV and snapshot_drift_finish's
# new_drift both filter the SAME report with this one regex, and comm(1)
# diffs those two filtered lists against each other. One constant for both,
# because a class added to one and not the other made every run report the
# same item as new, forever.
# shellcheck disable=SC2034  # read by lib/manifests.sh and lib/snapshot.sh
DRIFT_CLASSES='^(MODIFIED|NEW|GONE|# ERROR)'

# drift_path_representable PATH: 0 when PATH can be written as a report row.
#
# The row format is `TYPE<spaces>PATH<TAB>(note)`, one row per line, so a TAB
# or a newline in a FILENAME cannot be represented: a file named
# `creds<TAB>readme` under a drift-ignored secrets directory produced a row
# whose path read `~/.config/creds`, the widget's own "does the report name
# this path" gate split it identically and agreed with itself, and one Allow
# click widened the allowlist to a directory the scan had never reported.
# Changing the separator does not fix that on its own, because `find` hands
# the producers whatever is on disk. So the producers refuse such a path and
# emit an ERROR row instead (drift_error_unrepresentable): ERROR rows are
# faults, and no write verb can act on one.
drift_path_representable() {
  case "$1" in *$'\t'*|*$'\n'*) return 1 ;; esac
  return 0
}

# drift_error_unrepresentable PATH: the ERROR row that stands in for a path
# the report cannot name. The parent is printed plainly so a human can go and
# look, and the basename is %q-escaped so the row itself stays one line with
# no TAB in it. A parent that is ITSELF unrepresentable is escaped too, or the
# stand-in would carry the same byte it exists to keep out.
#
# The wording says what happened: the scan DID complete, and one name in it
# cannot be written as a row. It used to read "unrepresentable path under
# <dir>", which health then quoted under "drift scan could not complete a
# check" -- two statements about the same row that contradicted each other,
# and neither told the reader what to do about it (rename the file, or add a
# drift-ignore glob for its directory; README Troubleshooting).
drift_error_unrepresentable() {
  local p=$1 parent name
  parent=${p%/*}
  [ "$parent" = "$p" ] && parent="."
  name=${p##*/}
  case "$parent" in *$'\t'*|*$'\n'*) parent=$(printf '%q' "$parent") ;; esac
  printf '# ERROR: a name the report cannot represent: %s/%s\n' "$parent" "$(printf '%q' "$name")"
}

# drift_etc_unparseable_row CANDIDATE: the "# ERROR" row for a /etc candidate
# that failed the /etc scan's own producer-contract validation: pacman's
# -Qii "Backup Files" list and -Qqo's "No package owns" stderr are both prose
# with no NUL-delimited form, so a real newline inside a reported path splits
# one entry into two physical lines. Read line by line, the fragment that
# still matches the parser's marker looks like a whole path on its own and
# used to become a NEW or MODIFIED row naming a file that was never on disk,
# while the real path it was cut from went unreported. A candidate is only
# ever trusted once it is confirmed against the filesystem and pacman's own
# ownership answer (drift_scan, /etc sections 5 and 5b); this row stands in
# for one that fails that check. Capped at 80 characters, with any embedded
# newline shown as the two bytes `\n` rather than a raw one, so this stays a
# single line no matter what pacman printed.
drift_etc_unparseable_row() {
  local s=${1//$'\n'/\\n}
  printf '# ERROR: unparseable /etc path from pacman output (%s)\n' "${s:0:80}"
}

# drift_etc_ownership_incomplete STDERR RC: 0 (true) when a batched
# `pacman -Qqo` answer about /etc candidates cannot be trusted at all, so
# every candidate in that batch must become an unparseable-ERROR row (or one
# summary ERROR row for the whole batch) instead of a normal one. Sections 5
# and 5b each infer "owned" (or "still unowned") from the ABSENCE of a
# candidate in this stderr, so a call that did not actually answer must
# never read as a clean "nobody is missing" -- the exact fail-open the /etc
# scan exists to prevent (Codex, PR 6 round 2).
#
# Incomplete either way: the call exited non-zero with NOTHING on stderr
# (pacman crashed, was killed, or failed silently in some way this parser
# has never seen -- a bare `-z "$err"` check alone reads this the same as
# "every candidate is owned"), or stderr held anything besides a clean run
# of "error: No package owns <path>" lines, even one such line beside ones
# that did parse (an unrelated diagnostic must fail the whole batch, not
# get silently dropped while the lines beside it are trusted). A non-zero
# exit whose stderr is made ENTIRELY of those lines is pacman's ordinary way
# of saying "at least one of these is unowned", and is the expected answer,
# not a failure.
drift_etc_ownership_incomplete() {
  local err=$1 rc=$2
  if [ -z "$err" ]; then
    [ "$rc" -ne 0 ]
  else
    grep -qvE '^error: No package owns ' <<<"$err"
  fi
}

# drift_line_split LINE: split one report line into DRIFT_TYPE, DRIFT_PATH and
# DRIFT_NOTE. Returns 1 for a line that is not a report row (blank, or a
# comment other than "# ERROR"), so callers write `... || continue`.
#
# The report format is `TYPE<spaces>PATH` with an optional note separated from
# the path by a TAB: `TYPE<spaces>PATH<TAB>(note)`. It used to separate the
# note with " (", and every consumer recovered the path by cutting at the
# first " (" -- see drift_path_representable above for the loss event that
# came of it. A TAB reaches a path here only if something other than this
# tool wrote the report, so a row carrying more than one is malformed rather
# than a path plus a note, and is read as ERROR rather than trusted up to the
# first separator.
drift_line_split() {
  local line=$1 rest tabs
  DRIFT_TYPE=""; DRIFT_PATH=""; DRIFT_NOTE=""
  case "$line" in
    '# ERROR'*)
      # Both "# ERROR: msg" (drift_scan's own lines) and "# ERROR msg" are
      # accepted: strip the marker, an optional colon, then leading spaces,
      # so the path carries the message, never the "# ERROR" prefix.
      DRIFT_TYPE=ERROR
      rest=${line#'# ERROR'}; rest=${rest#:}
      DRIFT_PATH=${rest#"${rest%%[! ]*}"}
      return 0 ;;
    ''|'#'*) return 1 ;;
  esac
  DRIFT_TYPE=${line%%[[:space:]]*}
  rest=${line#"$DRIFT_TYPE"}
  rest=${rest#"${rest%%[![:space:]]*}"}
  tabs=${rest//[!$'\t']/}
  if [[ ${#tabs} -gt 1 ]]; then
    DRIFT_TYPE=ERROR
    DRIFT_PATH="malformed drift row, more than one TAB: $(printf '%q' "$line")"
    return 0
  fi
  case "$rest" in
    *$'\t'*) DRIFT_PATH=${rest%%$'\t'*}; DRIFT_NOTE=${rest#*$'\t'} ;;
    *)       DRIFT_PATH=$rest ;;
  esac
  return 0
}

# drift_scan: print the report to stdout, ending with the "# drift-scan-complete"
# sentinel. The daily pipeline (snapshot, Task 9) refuses to commit without that
# line, so a scan that dies partway through can no longer be mistaken for a
# clean report. Requires lists_load to have already filled COVERED/IGNORED.
drift_scan() {
  # Below this line is written the way drift.sh's own header was: `set -uo
  # pipefail`, deliberately WITHOUT -e. The whole algorithm leans on
  # `cmd && next` and `if cmd; then ...` to mean "handle this failure right
  # here", not "abort the whole scan" -- a pacman lookup or a stat on a broken
  # symlink failing is routine, not fatal. `local -` saves bin/omabackup's
  # shell options and restores them the moment this function returns, so that
  # assumption holds here without sprinkling `|| true` after every find, diff,
  # stat and pacman call.
  local -
  set +e

  local STOCK_CONFIG="$STOCK_DIR/config" STOCK_DEFAULT="$STOCK_DIR/default"
  local MAX_SCAN_FILES="$CFG_MAX_SCAN_FILES"
  local ETC_DROPIN_ROOT="${OMABACKUP_ETC_ROOT:-/etc}"

  local _nullglob_was_on
  shopt -q nullglob && _nullglob_was_on=1 || _nullglob_was_on=0
  shopt -s nullglob

  local live rel base found stock_missing
  local -A _reported=()
  found=0
  stock_missing=0

  # Dedupe: the container recursion means section 1 (.config/<app>), section
  # 2b (.config, .local) and section 2c (.local/{state,share}/*) can each
  # reach the same file. Reporting it more than once would inflate every
  # count downstream (the item total, a future health summary).
  # _drift_report TYPE PATH [NOTE]: one row. The note is TAB-separated from
  # the path (see drift_line_split); it is never appended to the path itself,
  # or a filename containing the separator renames the row. A path that holds
  # the separator (or a newline) cannot be a row at all: find hands this
  # function whatever is on disk, so it becomes an ERROR row naming the
  # parent, which is a fault and which no write verb can act on.
  _drift_report() {
    [ -n "${_reported[$2]:-}" ] && return 0
    _reported[$2]=1
    if ! drift_path_representable "$2"; then
      drift_error_unrepresentable "$2"; found=$((found+1)); return 0
    fi
    if [ -n "${3:-}" ]; then
      printf '%-10s %s\t(%s)\n' "$1" "$2" "$3"
    else
      printf '%-10s %s\n' "$1" "$2"
    fi
    found=$((found+1))
  }

  # find(1) prune arguments built from the /** ignore entries, so full-depth
  # walks skip Steam, browser profiles, plugin clones etc. instead of
  # enumerating them.
  local -a PRUNE=()
  _drift_build_prune() {
    PRUNE=()
    local c base
    for c in "${IGNORED[@]}"; do
      case "$c" in
        */'**')
          base="${c%/\*\*}"
          case "$base" in *'*'*) continue ;; esac   # skip patterns, -path needs a literal
          PRUNE+=( -path "$HOME/$base" -prune -o )
          ;;
      esac
    done
    # Section 4 is the sole authority on ~/.local/bin: it applies a size filter
    # so the ~13 mise shims stay quiet while a real script surfaces. Pruning it
    # here stops the generic walkers from reporting the shims and bypassing
    # that rule. Deliberately NOT a drift-ignore entry; that would silence
    # section 4 too.
    PRUNE+=( -path "$HOME/.local/bin" -prune -o )
  }

  # Walk a tree at FULL depth (pruned), reporting anything neither covered nor
  # ignored. Replaces the old hardcoded 3-root, maxdepth-2 scan which missed
  # .local/state/{tensaku,agent-bar,omarchy-notification-center} entirely and
  # could not see .local/state/omarchy/agents/usage/*.json at depth 3.
  #
  # Every file below costs a bash loop over ~200 ignore patterns (x3 checks). A
  # 30k-file pnpm store under ~/.local/share (2026-08-28, in the source repo)
  # turned that into >5 min of CPU, the timer looked hung and was stopped by
  # hand, and OnFailure fired. So the walk is two-phase: list the files once,
  # then collapse any directory holding more than MAX_SCAN_FILES of them into
  # ONE report line, unless that directory is allowlisted / subtree-ignored
  # (its files would be skipped anyway, so skip them silently) or is a
  # container we are meant to look inside (partially covered, or
  # bare-ignored), in which case the decision is deferred to its children.
  # Only the leftover files are matched per-file.
  # Scratch for the two-phase walk. Never /tmp: a bare `mktemp -d` put the
  # full listing of every file under $HOME (paths are themselves private) in a
  # world-readable directory.
  #
  # $STATE_DIR, not $STAGE, on EVERY path including the snapshot's own drift
  # pass. $STAGE is torn down and rebuilt by `rm -rf "$STAGE"` at the top of
  # snapshot_stage and again at the end of snapshot_sync, so a standalone
  # `omabackup drift` running alongside a snapshot would have had its listing
  # deleted mid-walk. $STATE_DIR belongs to no other phase, is 0700, and is
  # already where verify puts its throwaway. One code path, no "which caller
  # am I" question to get wrong later.
  #
  # DRIFT_TMP is deliberately NOT `local`: the trap below fires when the whole
  # process exits, by which point this call frame is gone, and referencing a
  # local under `set -u` would be an unbound-variable error (the same lesson
  # as VERIFY_R in lib/verify.sh). bin/omabackup runs one verb per process, so
  # a plain global is exactly as scoped as the trap is.
  local _dscratch="$STATE_DIR"
  # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
  mkdir -m 700 -p "$_dscratch" || { echo "# ERROR drift: cannot create scratch under $_dscratch"; return 1; }
  DRIFT_TMP=$(mktemp -d "$_dscratch/.drift.XXXXXX") \
    || { echo "# ERROR drift: cannot create a scratch directory under $_dscratch"; return 1; }
  trap 'rm -rf "${DRIFT_TMP:-}" 2>/dev/null || true' EXIT
  trap 'rm -rf "${DRIFT_TMP:-}" 2>/dev/null; exit 130' INT
  trap 'rm -rf "${DRIFT_TMP:-}" 2>/dev/null; exit 143' TERM
  local _dtmp="$DRIFT_TMP"

  # Reads absolute file paths from $1, writes the prefixes to exclude to $2
  # and reports each over-full directory that has no other explanation. $3 is
  # the walk root: the file list covers nothing above it, so no decision may
  # either.
  _drift_collapse_huge_dirs() {
    local list="$1" excl="$2" root_rel n rel top parent residual a
    root_rel="${3%/}"; root_rel="${root_rel#"$HOME"/}"   # roots arrive with or without a trailing /
    local -A count=() excluded=()
    local -a rows=()
    : > "$excl"
    # "count<TAB>dir" for EVERY directory (and ancestor) in the listing,
    # deepest first, so a subtree is decided before the directories that
    # contain it. All counts are loaded before any decision: the float-up
    # below reads parents.
    # NUL IN, NUL OUT. $list is NUL-delimited (find -print0), so RS is a NUL
    # here: a newline in a FILENAME would otherwise be a record separator and
    # one file would be counted as two, in two different directories. The
    # OUTPUT has to match, and used to not: the records are
    # "depth<TAB>count<TAB>dir" and a DIRECTORY name holding a newline split
    # one of them in two, so a fragment reached the loop below, `n` was the
    # fragment's text rather than a number, and `$(( n - ... ))` died
    # "unbound variable" inside the scan's command substitution -- exit 1, no
    # sentinel, and `snapshot --json` printed nothing at all. sort(1) and
    # cut(1) read and write NUL-terminated records too (-z).
    while IFS= read -r -d '' a; do
      rows+=("$a"); count["${a#*$'\t'}"]="${a%%$'\t'*}"
    done < <(awk -v home="$HOME/" '
      BEGIN { RS = "\0"; ORS = "\0" }
      { p = $0; if (index(p, home) == 1) p = substr(p, length(home) + 1)
        while ((i = match(p, /\/[^\/]*$/)) > 0) { p = substr(p, 1, i - 1); count[p]++ } }
      END { for (d in count) { depth = gsub(/\//, "/", d); print depth "\t" count[d] "\t" d } }
    ' "$list" | sort -z -t$'\t' -k1,1nr | cut -z -f2-)
    for a in "${rows[@]}"; do
      n="${a%%$'\t'*}"; rel="${a#*$'\t'}"
      # A count that is not a number means the record shape is not what this
      # function built, and arithmetic on it would take the whole scan down.
      # Report the gap and carry on: an ERROR row is a fault a human sees.
      case "$n" in
        ''|*[!0-9]*)
          echo "# ERROR: drift scan could not count the files under a directory; that directory is NOT collapsed"
          found=$((found+1)); continue ;;
      esac
      residual=$(( n - ${excluded[$rel]:-0} ))
      [ "$residual" -gt "$MAX_SCAN_FILES" ] || continue
      if is_partially_covered "$rel" || is_ignored "$rel"; then
        continue                      # a container: look inside, never collapse it
      fi
      # Float up to the highest directory that holds nothing but this blob, so
      # the report names ~/.local/share/pnpm/ rather than .../pnpm/store/v3/files/.
      top="$rel"
      while [ "$top" != "$root_rel" ]; do
        parent="${top%/*}"
        [ "$parent" != "$top" ] || break
        [ "${count[$parent]:-0}" -eq "${count[$top]}" ] || break
        if is_partially_covered "$parent" || is_ignored "$parent" \
           || is_covered "$parent" || is_ignored_subtree "$parent"; then break; fi
        top="$parent"
      done
      if ! is_covered "$top" && ! is_ignored_subtree "$top"; then
        _drift_report NEW "~/$top/" ">$MAX_SCAN_FILES files: too large to scan; allowlist it, or add a dated .../** line to drift-ignore.txt"
      fi
      printf '%s/%s/\0' "$HOME" "$top" >> "$excl"
      a="$rel"
      while [ "${a%/*}" != "$a" ]; do a="${a%/*}"; excluded[$a]=$(( ${excluded[$a]:-0} + residual )); done
    done
  }

  # $1 root, $2 "tree" (also honours /** ignores per file) or "children".
  _drift_walk_tree() {
    local root="$1" mode="$2" f rel
    local list="$_dtmp/files" excl="$_dtmp/excl"
    # NUL-DELIMITED END TO END. With `-print` and a line-oriented read, a
    # newline in a filename split one path into two fragments before any
    # producer saw it: `~/.local/share/deep/bad<LF>name` was reported as
    # `NEW ~/.local/share/deep/bad` AND `NEW ~/name`, two rows, neither of
    # which is a file, and the second of which names a path in someone else's
    # part of $HOME. The path reaches _drift_report whole now, which turns it
    # into an ERROR row (drift_path_representable) instead.
    find "$root" "${PRUNE[@]}" -type f -print0 2>/dev/null > "$list"
    _drift_collapse_huge_dirs "$list" "$excl" "$root"
    while IFS= read -r -d '' f; do
      rel="${f#$HOME/}"
      is_covered "$rel" && continue
      [ "$mode" = tree ] && is_ignored_subtree "$rel" && continue
      is_ignored "$rel" && continue
      _drift_report NEW "~/$rel"
    done < <(awk -v exclfile="$excl" '
      BEGIN { RS = "\0"; ORS = "\0"
              while ((getline p < exclfile) > 0) if (p != "") ex[++n] = p }
      { for (i = 1; i <= n; i++) if (index($0, ex[i]) == 1) next; print }
    ' "$list")
  }

  _drift_scan_tree() {
    [ -d "$1" ] || return 0
    _drift_walk_tree "$1" tree
  }

  # Report files inside a partially-covered directory (some children
  # allowlisted, the directory itself ignored). drift used to stop at depth 1,
  # so anything new in .config/omarchy, .config/Code/User, .config/voxtype ...
  # was invisible.
  _drift_scan_children() {
    _drift_walk_tree "$1" children
  }

  _drift_build_prune

  if [ ! -d "$STOCK_CONFIG" ]; then
    echo "# ERROR: omarchy stock config tree not found at $STOCK_CONFIG"
    echo "#        section 1 (~/.config vs stock) is SKIPPED to avoid ~20 false"
    echo "#        NEW entries; every other section still runs."
    stock_missing=1
    found=$((found+1))
  fi

  echo "# drift report (timestamp intentionally omitted: keeps output deterministic"
  echo "# so an unchanged system yields no commit; see the snapshot's idempotency)"
  echo "# MODIFIED = differs from omarchy stock. NEW = no stock counterpart."
  echo "# Add a dated line to drift-ignore.txt to silence an entry."
  echo

  # --- 1. ~/.config against omarchy's stock tree -----------------------------
  for live in "$HOME"/.config/*; do
    [ "$stock_missing" = 1 ] && break
    rel="${live#$HOME/}"
    is_covered "$rel" && continue
    is_ignored_subtree "$rel" && continue
    # Partial coverage is derived, not declared: if any child is allowlisted,
    # look inside rather than reporting (or silencing) the whole directory.
    if [ -d "$live" ] && is_partially_covered "$rel"; then
      _drift_scan_children "$live"
      continue
    fi
    if is_ignored "$rel"; then
      [ -d "$live" ] && _drift_scan_children "$live"
      continue
    fi
    base="$(basename "$live")"
    if [ -e "$STOCK_CONFIG/$base" ]; then
      if ! diff -rq "$STOCK_CONFIG/$base" "$live" >/dev/null 2>&1; then
        _drift_report MODIFIED "~/.config/$base"
      fi
    else
      # No stock counterpart: newly installed software, or something you created.
      if [ -d "$live" ]; then
        [ -n "$(find "$live" -type f -print -quit 2>/dev/null)" ] && _drift_report NEW "~/.config/$base/"
      else
        _drift_report NEW "~/.config/$base"
      fi
    fi
  done

  # --- 2. $HOME top-level dotfiles -------------------------------------------
  for live in "$HOME"/.[!.]*; do
    [ -f "$live" ] || continue
    rel="${live#$HOME/}"
    is_covered "$rel" && continue
    is_ignored "$rel" && continue
    case "$rel" in
      .bash_history|.bash_logout|.pulse-cookie|.steampath|.steampid|.XCompose.bak) continue ;;
    esac
    if [ -e "$STOCK_DEFAULT/${rel#.}" ]; then
      diff -q "$STOCK_DEFAULT/${rel#.}" "$live" >/dev/null 2>&1 || _drift_report MODIFIED "~/$rel"
    else
      _drift_report NEW "~/$rel"
    fi
  done

  # --- 2b. $HOME top-level dot-directories -----------------------------------
  # The loop above is `[ -f ]` only, so a whole new app directory (~/.mozilla,
  # ~/.dotnet) was never reported.
  for live in "$HOME"/.[!.]*/; do
    rel="${live%/}"; rel="${rel#$HOME/}"
    is_covered "$rel" && continue
    is_ignored_subtree "$rel" && continue
    # Same derivation as section 1: a container whose children are allowlisted
    # (.config, .local, .claude, .ssh, .pi) is not itself "new"; look inside.
    if is_partially_covered "$rel"; then
      _drift_scan_children "$live"
      continue
    fi
    # A BARE ignore suppresses the directory itself, not its children (same
    # rule as section 1). This used to `continue`, so a bare `.local` line
    # silenced the whole subtree forever; the documented semantics said
    # otherwise. Verified by fixture.
    if is_ignored "$rel"; then
      _drift_scan_children "$live"
      continue
    fi
    [ -n "$(find "$live" -type f -print -quit 2>/dev/null)" ] && _drift_report NEW "~/$rel/"
  done

  # --- 2d. non-dot top level ----------------------------------------------------
  # Nothing above looks at ~/foo.conf, ~/bin or ~/scripts, so a hand-written
  # script there was invisible to every scanner. Other non-dot directories
  # (Documents, projects, vaults, Wallpapers unless allowlisted...) are data,
  # not config, and are deliberately NOT walked; that decision is recorded in
  # drift-ignore.txt.
  for live in "$HOME"/*; do
    [ -f "$live" ] || continue
    rel="${live#$HOME/}"
    is_covered "$rel" && continue
    is_ignored "$rel" && continue
    _drift_report NEW "~/$rel"
  done
  for d in bin scripts; do
    [ -d "$HOME/$d" ] || continue
    is_covered "$d" && continue
    is_ignored_subtree "$d" && continue
    _drift_scan_tree "$HOME/$d"
  done

  # --- 2c. plugin/app state under .local -------------------------------------
  # Plugins store SETTINGS in shell.json but STATE here; nothing scanned this
  # tree, so the next plugin that keeps state was silently unbacked forever.
  local root
  for root in "$HOME/.local/state"/* "$HOME/.local/share"/*; do
    _drift_scan_tree "$root"
  done

  # --- 3. hand-written systemd user units ------------------------------------
  # find -type f returns exactly the hand-written units: the other entries are
  # symlinks into /usr/lib/systemd/user, so this has no false positives.
  # NUL-delimited, like every other find reader here: with -print and a
  # line-oriented read a newline in a unit's filename split one path into two
  # fragments before any producer saw it, and the suffix fragment became a
  # real row naming a path in another part of $HOME. Whole, the name reaches
  # _drift_report, which turns it into an ERROR row.
  local u
  while IFS= read -r -d '' u; do
    rel="${u#$HOME/}"
    is_covered "$rel" || is_ignored "$rel" || _drift_report NEW "~/$rel"
  done < <(find "$HOME/.config/systemd/user" -type f -print0 2>/dev/null)

  # --- 4. user scripts in ~/.local/bin ---------------------------------------
  # mise shims are regenerable noise; anything larger is probably yours.
  local b
  while IFS= read -r -d '' b; do
    rel="${b#$HOME/}"
    is_covered "$rel" && continue
    is_ignored "$rel" && continue
    [ -L "$b" ] && continue
    [ "$(stat -c %s "$b" 2>/dev/null || echo 0)" -gt 300 ] && _drift_report NEW "~/$rel"
  # No -maxdepth: _drift_build_prune prunes .local/bin from the generic
  # walkers, so a script in a subdirectory would otherwise be invisible to
  # everything.
  done < <(find "$HOME/.local/bin" -type f -print0 2>/dev/null)

  # --- 5. /etc ---------------------------------------------------------------
  # Re-run pacman's own modified-backup-file scan and diff it against what we
  # keep. OMABACKUP_SKIP_ETC=1 is used by the test fixtures so a synthetic
  # fixture is not swamped by this machine's real /etc state.
  local etc_skip etc_live etc_known etc_qii f
  etc_skip='/etc/(passwd|group|subuid|subgid|shells|resolv\.conf|pacman\.d/mirrorlist|cups/cups-browsed\.conf|nsswitch\.conf|plymouth/plymouthd\.conf|security/faillock\.conf|skel/\.bashrc)$'
  if [ "${OMABACKUP_SKIP_ETC:-0}" != "1" ]; then
  # PRODUCER CONTRACT. This section reads pacman's human-readable prose, not an
  # API: the field name `Backup Files` and the literal marker ` [modified]`.
  # LC_ALL=C pins the locale but not the wording, and the day either changes,
  # an empty parse is byte-identical to "no /etc drift" while the completion
  # sentinel still prints and every dashboard reads clean. So: a failing pacman
  # is an ERROR (it always was), and so now is a pacman that ran fine and
  # emitted nothing this parser recognises. Zero modified files is only ever
  # concluded from output that had at least one `Backup Files` line in it.
  etc_qii=""
  if ! etc_qii=$(LC_ALL=C pacman -Qii 2>/dev/null); then
    echo "# ERROR: pacman query failed; /etc drift NOT checked"
    found=$((found+1))
  elif ! grep -qF 'Backup Files' <<<"$etc_qii"; then
    echo "# ERROR: cannot parse pacman backup-file output; /etc drift NOT checked"
    found=$((found+1))
  else
    etc_live=$(grep -F '[modified]' <<<"$etc_qii" \
      | sed -E 's/^(Backup Files *: *)?[[:space:]]*//; s/ \[modified\]//' | sort -u)
    etc_known=$(read_list "$DATA_REPO/etc-allowlist.txt" | sort -u)
    # A real newline in a backup file's path splits this prose the same way
    # (see drift_etc_unparseable_row): the fragment that keeps the [modified]
    # marker reads as a whole path on its own, so nothing here is trusted
    # until it exists AND some package still claims it (one batched -Qqo
    # call, the same ownership question section 5b asks over its own list).
    # `--` ends option parsing before the array: a fragment that happens to
    # start with `-` is a filename argument, never a flag that could corrupt
    # every other candidate answered in the same call.
    local etc_candidates=() etc_bad=() etc_unowned="" etc_unowned_err="" etc_qqo_rc=0
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      echo "$f" | grep -qE "$etc_skip" && continue
      if [ -e "$f" ]; then etc_candidates+=("$f"); else etc_bad+=("$f"); fi
    done <<<"$etc_live"
    if [ ${#etc_candidates[@]} -gt 0 ]; then
      etc_unowned_err=$(LC_ALL=C pacman -Qqo -- "${etc_candidates[@]}" 2>&1 >/dev/null); etc_qqo_rc=$?
      etc_unowned=$(sed -nE 's/^error: No package owns (.*)$/\1/p' <<<"$etc_unowned_err")
    fi
    # See drift_etc_ownership_incomplete: this branch infers "owned" from
    # ABSENCE in that stderr, so a validation call that did not actually
    # answer (silently, or with an unrelated diagnostic beside whatever did
    # parse) would otherwise read as "every candidate here is owned" and
    # every one of them would reach a normal row -- the exact fail-open this
    # scan exists to prevent.
    if [ ${#etc_candidates[@]} -gt 0 ] && drift_etc_ownership_incomplete "$etc_unowned_err" "$etc_qqo_rc"; then
      echo "# ERROR: cannot parse pacman ownership output; modified /etc files NOT checked"
      found=$((found+1))
    else
      for f in "${etc_candidates[@]}"; do
        # `--`: same reason the pacman calls above take it. A candidate
        # starting with `-` is grep's pattern argument here, not stdin, so
        # without it grep reads the candidate itself as an option string.
        if grep -qxF -- "$f" <<<"$etc_unowned"; then
          etc_bad+=("$f")
        else
          grep -qxF -- "$f" <<<"$etc_known" || _drift_report NEW "$f"
        fi
      done
    fi
    for f in "${etc_bad[@]}"; do
      drift_etc_unparseable_row "$f"; found=$((found+1))
    done
  fi
  fi

  # --- 5b. hand-authored /etc drop-ins ----------------------------------------
  # Section 5 only sees files a package DECLARES as backup files. A sysctl,
  # modprobe, udev or systemd override you write yourself is owned by no
  # package, so pacman never reports it, and it was invisible here in the
  # source repo (/etc/modprobe.d/hid_apple.conf sat unbacked while every
  # monitor said clean). Walk the standard drop-in directories and report any
  # file no package owns that is not in etc-allowlist.txt.
  # OMABACKUP_ETC_ROOT / OMABACKUP_SKIP_DROPINS exist for the test fixtures.
  if [ "${OMABACKUP_SKIP_DROPINS:-${OMABACKUP_SKIP_ETC:-0}}" != "1" ]; then
  etc_known="${etc_known:-$(read_list "$DATA_REPO/etc-allowlist.txt" | sort -u)}"
  # sudoers.d is deliberately absent: it is 750 root on every Arch install, so
  # this user-level scan can never read it and would report "# ERROR" at every
  # shell for the rest of time; a permanent alarm is one that gets ignored.
  # The gap is recorded in etc-allowlist.txt instead; a NOPASSWD rule you
  # write must be added there by hand (restore, arriving in a later task,
  # still never writes sudoers).
  local DROPIN_DIRS dropin_files dir unowned real
  DROPIN_DIRS="sysctl.d modprobe.d udev/rules.d systemd/system systemd/user systemd/network
NetworkManager/conf.d NetworkManager/dispatcher.d pacman.d/hooks mkinitcpio.conf.d default
environment.d profile.d ssh/sshd_config.d ssh/ssh_config.d limine-entry-tool.d
X11/xorg.conf.d fonts/conf.d"
  dropin_files=()
  for d in $DROPIN_DIRS; do
    dir="$ETC_DROPIN_ROOT/$d"
    [ -d "$dir" ] || continue
    # Fail closed: an unreadable drop-in directory (sudoers.d is 750 root) is
    # reported as a scanner gap, not silently treated as empty.
    if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
      echo "# ERROR: cannot read $dir; drop-ins there are NOT checked"
      found=$((found+1)); continue
    fi
    # NUL-delimited: a newline in a drop-in's filename split one path into
    # two fragments, and the suffix fragment became a NEW row for a file that
    # does not exist. A name this report cannot write is reported as such
    # HERE, before the pacman call, because ownership comes back as prose
    # ("error: No package owns <path>") that a newline splits just as badly:
    # the file is a scanner gap either way, and an ERROR row is a fault.
    while IFS= read -r -d '' f; do
      if ! drift_path_representable "$f"; then
        drift_error_unrepresentable "/etc/${f#"$ETC_DROPIN_ROOT"/}"; found=$((found+1)); continue
      fi
      dropin_files+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
  done
  if [ ${#dropin_files[@]} -gt 0 ]; then
    # One pacman call for all of them; unowned files come back on stderr as the
    # literal `error: No package owns <path>`.
    #
    # PRODUCER CONTRACT, the same one section 5 has: stderr that this parser
    # turns into nothing is only "every drop-in is owned by a package" when
    # there was no stderr at all. Any other stderr (a reworded message, a
    # locale that slipped through, a pacman that changed how it reports this)
    # used to read as a clean scan, which is how a hand-written
    # /etc/modprobe.d/*.conf goes unbacked while every monitor says fine.
    local unowned_err dropin_candidates=() dropin_bad=() dropin_still_unowned="" dropin_qqo_rc=0
    local dropin_still_unowned_err="" dropin_recheck_rc=0
    unowned_err=$(LC_ALL=C pacman -Qqo "${dropin_files[@]}" 2>&1 >/dev/null); dropin_qqo_rc=$?
    unowned=$(sed -nE 's/^error: No package owns (.*)$/\1/p' <<<"$unowned_err")
    # See drift_etc_ownership_incomplete: the same rule section 5's ownership
    # check uses, so the two match. A bare "stderr empty" check alone read a
    # silent, non-zero-exit failure the same as "every drop-in is owned".
    if drift_etc_ownership_incomplete "$unowned_err" "$dropin_qqo_rc"; then
      echo "# ERROR: cannot parse pacman ownership output; /etc drop-ins NOT checked"
      found=$((found+1))
    else
      # Same producer contract as section 5 (drift_etc_unparseable_row): a
      # real newline in a reported path splits this stderr line by line too,
      # and the fragment that still matches "error: No package owns " reads
      # as a whole path on its own. Trust none of them until they exist AND
      # a second, batched pacman call still says nobody owns them.
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        if [ -e "$f" ]; then dropin_candidates+=("$f"); else dropin_bad+=("$f"); fi
      done <<<"$unowned"
      if [ ${#dropin_candidates[@]} -gt 0 ]; then
        # `--`: same reason section 5's recheck uses it (a split fragment
        # that starts with `-` must be a filename argument, never a flag).
        # This call asks pacman DIRECTLY about each surviving candidate
        # (unlike the first pass above, whose answer for any one of them
        # was only ever a side effect of splitting someone else's stderr
        # line), so it is its own producer-contract check: a diagnostic
        # beside a genuine "No package owns" line here must fail every
        # candidate in THIS batch (Codex, PR 6 round 3), the same as the
        # other two -Qqo calls.
        dropin_still_unowned_err=$(LC_ALL=C pacman -Qqo -- "${dropin_candidates[@]}" 2>&1 >/dev/null); dropin_recheck_rc=$?
        dropin_still_unowned=$(sed -nE 's/^error: No package owns (.*)$/\1/p' <<<"$dropin_still_unowned_err")
      fi
      if [ ${#dropin_candidates[@]} -gt 0 ] && drift_etc_ownership_incomplete "$dropin_still_unowned_err" "$dropin_recheck_rc"; then
        dropin_bad+=("${dropin_candidates[@]}")
      else
        for f in "${dropin_candidates[@]}"; do
          # `--`: same reason section 5's equivalent check takes it.
          if grep -qxF -- "$f" <<<"$dropin_still_unowned"; then
            real="/etc/${f#$ETC_DROPIN_ROOT/}"          # allowlist/ignore are written as /etc/...
            echo "$real" | grep -qE "$etc_skip" && continue
            grep -qxF -- "$real" <<<"$etc_known" && continue
            is_ignored "$real" && continue
            _drift_report NEW "$real"
          else
            dropin_bad+=("$f")
          fi
        done
      fi
      for f in "${dropin_bad[@]}"; do
        drift_etc_unparseable_row "$f"; found=$((found+1))
      done
    fi
  fi
  fi

  echo
  if [ "$found" -eq 0 ]; then
    echo "# clean: everything user-authored is either backed up or explicitly ignored"
  else
    echo "# $found item(s) unbacked. Add to allowlist.txt, or to drift-ignore.txt with a reason."
  fi
  rm -rf "$_dtmp"; DRIFT_TMP=""
  [ "$_nullglob_was_on" = 1 ] || shopt -u nullglob
  # Sentinel. The daily pipeline refuses to commit without this line, so a
  # scan that dies partway through can no longer be mistaken for a clean report.
  echo "# drift-scan-complete"
}

# cmd_drift: `drift` verb. --json wraps the report as {ok, complete, items[]}.
#
# GONE rows are added here, live, from allowlist_unresolved. Only the snapshot
# used to write them, so the popup showed them and this command, which the
# login nag names for "NEW = unbacked, GONE = vanished", never did. They go in
# just before the sentinel, which --json requires to be the last line, and a
# report with any of them is not "clean".
cmd_drift() {
  data_repo_require; lists_load
  local rep g gone="" n=0 sentinel='# drift-scan-complete' body tail=""
  rep=$(drift_scan)
  while IFS= read -r g; do
    [[ -n "$g" ]] || continue
    n=$((n+1))
    # shellcheck disable=SC2088  # literal "~/" display prefix, exactly what the report prints
    if drift_path_representable "~/$g"; then
      gone+=$(printf 'GONE       ~/%s' "$g")$'\n'
    else
      gone+=$(drift_error_unrepresentable "~/$g")$'\n'
    fi
  done < <(allowlist_unresolved)
  if (( n > 0 )); then
    body=$rep
    if [[ "$(tail -1 <<<"$rep")" == "$sentinel" ]]; then body=${rep%"$sentinel"}; tail=$sentinel; fi
    body=$(grep -v '^# clean:' <<<"$body" || true)
    rep=$(printf '%s\n%s# %d allowlist entr(ies) resolve to nothing. Run: omabackup resolve-gone PATH remove|optional\n%s' \
            "$body" "$gone" "$n" "$tail")
  fi
  if [[ $JSON == 1 ]]; then
    local complete=false; [[ "$(tail -1 <<<"$rep")" == "$sentinel" ]] && complete=true
    printf '{"ok":true,"complete":%s,"items":[%s]}\n' "$complete" "$(drift_items_json <<<"$rep")"
  else
    printf '%s\n' "$rep"
  fi
}

# drift_items_json: report lines on stdin -> JSON array body (type, path, note).
# Used by cmd_drift --json and health/widget via drift_parse. Every field
# comes from drift_line_split above, which every other consumer uses too, so
# the JSON the widget renders and the gate the write verbs apply can never
# disagree about which path a row names. Leading whitespace is trimmed there
# with `${v#"${v%%[![:space:]]*}"}` (strip the longest leading-space-only
# prefix), not `${v##+( )}`, so this needs no `extglob`: that shopt used to be
# set at file scope and leaked into every other verb for the rest of the
# process, the same class of leak Task 5 fixed for nullglob.
drift_items_json() {
  local items=() path line opt rel dir
  drift_optional_load
  while IFS= read -r line; do
    drift_line_split "$line" || continue
    path=${DRIFT_PATH%/}   # a directory's trailing "/" is report display flourish, not part of the path
    # `optional` is only ever meaningful on a GONE row, and it is false
    # everywhere else rather than absent: the popup reads one shape for every
    # row, and a typed QML property must never be assigned undefined.
    opt=false
    if [[ "$DRIFT_TYPE" == GONE ]]; then
      rel=${path#\~/}
      [[ -z "${DRIFT_OPTIONAL[$rel]:-}" ]] || opt=true
    fi
    # `dir` is the fact the trailing slash carried before this function
    # stripped it, published rather than thrown away. The write verbs recover
    # it the same way (DRIFT_TARGET_DIR, lib/widget.sh) to decide whether an
    # ignore is a subtree; the popup needs it for a different reason, because
    # "Add to allowlist (back this up)" is the wrong sentence about a folder
    # whose whole future contents the click is deciding for.
    dir=false
    case "$DRIFT_PATH" in */) dir=true ;; esac
    items+=("{\"type\":$(jstr "$DRIFT_TYPE"),\"path\":$(jstr "$path"),\"note\":$(jstr "$DRIFT_NOTE"),\"optional\":$opt,\"dir\":$dir}")
  done
  jjoin "${items[@]}"
}

# DRIFT_OPTIONAL: the allowlist entries carrying the '?' optional marker,
# keyed by entry. Filled by drift_optional_load, read by drift_items_json.
#
# Every seed entry ships optional, and a fresh machine has none of the apps
# they name, so day one is a column of GONE rows. "Mark optional" on one of
# those changed nothing and still replied ok, so the row vanished from the
# popup and came back at the next snapshot. The popup can only hide that
# button if the engine tells it which rows are already optional; this is that
# fact, derived from the allowlist rather than guessed at in QML.
declare -A DRIFT_OPTIONAL=()
drift_optional_load() {
  DRIFT_OPTIONAL=()
  local e
  while IFS= read -r e; do
    case "$e" in \?*) DRIFT_OPTIONAL[${e#\?}]=1 ;; esac
  done < <(read_list "$DATA_REPO/allowlist.txt")
}
# drift_parse FILE: emit JSON items from a saved report file, honouring the sentinel.
drift_parse() { drift_items_json < "$1"; }

# drift_count_actionable: reads a parsed drift-items JSON ARRAY on stdin --
# the shape drift_parse/drift_items_json produce, wrapped in "[...]", exactly
# what health_collect and manifests_drift_counts already build for their own
# purposes -- and prints the number of rows a human can act on. NEW,
# MODIFIED, GONE, TOOBIG and EXCLUDED all offer a button (ui/DriftRow.qml:
# Allow, Ignore, or Ignore alone for the last two); an ERROR row has none,
# and is not counted.
#
# TAKES PARSED DATA, NEVER A PATH. `status --json .drift_count` (lib/health.sh)
# and `snapshot --json .drift_count` (lib/manifests.sh, manifests_drift_counts)
# both call this so the two can never disagree about what counts -- that was
# the whole point of the shared function -- but a first version took a FILE
# and reopened it, and health_collect had already parsed the very same file
# for status.json's `.drift` array a few lines above. cmd_status takes no
# repo lock, so a concurrent snapshot could replace manifests/drift.txt
# between those two reads: `.drift` and `.drift_count` would then describe
# two different reports, and a report that went clean on the second read
# could publish `state:"ok"` beside rows still sitting in `.drift` from the
# first (Codex, PR 14, round 2). Every caller now parses the report exactly
# once and hands those same parsed bytes to both the `.drift` array and this
# count.
drift_count_actionable() {
  jq '[.[] | select(.type != "ERROR")] | length'
}
