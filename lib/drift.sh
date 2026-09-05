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
  _drift_report() {
    [ -n "${_reported[$2]:-}" ] && return 0
    _reported[$2]=1
    printf '%-10s %s\n' "$1" "$2"; found=$((found+1))
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
  # world-readable directory. It goes in the data repo's own .staging when a
  # repo is configured, and $STATE_DIR for a standalone drift run that has
  # none; both are 0700 and both are ours.
  #
  # DRIFT_TMP is deliberately NOT `local`: the trap below fires when the whole
  # process exits, by which point this call frame is gone, and referencing a
  # local under `set -u` would be an unbound-variable error (the same lesson
  # as VERIFY_R in lib/verify.sh). bin/omabackup runs one verb per process, so
  # a plain global is exactly as scoped as the trap is.
  local _dscratch="${STAGE:-$STATE_DIR}"
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
    while IFS= read -r a; do
      rows+=("$a"); count["${a#*$'\t'}"]="${a%%$'\t'*}"
    done < <(awk -v home="$HOME/" '
      { p = $0; if (index(p, home) == 1) p = substr(p, length(home) + 1)
        while ((i = match(p, /\/[^\/]*$/)) > 0) { p = substr(p, 1, i - 1); count[p]++ } }
      END { for (d in count) { depth = gsub(/\//, "/", d); print depth "\t" count[d] "\t" d } }
    ' "$list" | sort -t$'\t' -k1,1nr | cut -f2-)
    for a in "${rows[@]}"; do
      n="${a%%$'\t'*}"; rel="${a#*$'\t'}"
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
        _drift_report NEW "~/$top/ (>$MAX_SCAN_FILES files: too large to scan; allowlist it, or add a dated .../** line to drift-ignore.txt)"
      fi
      printf '%s/%s/\n' "$HOME" "$top" >> "$excl"
      a="$rel"
      while [ "${a%/*}" != "$a" ]; do a="${a%/*}"; excluded[$a]=$(( ${excluded[$a]:-0} + residual )); done
    done
  }

  # $1 root, $2 "tree" (also honours /** ignores per file) or "children".
  _drift_walk_tree() {
    local root="$1" mode="$2" f rel
    local list="$_dtmp/files" excl="$_dtmp/excl"
    find "$root" "${PRUNE[@]}" -type f -print 2>/dev/null > "$list"
    _drift_collapse_huge_dirs "$list" "$excl" "$root"
    while IFS= read -r f; do
      rel="${f#$HOME/}"
      is_covered "$rel" && continue
      [ "$mode" = tree ] && is_ignored_subtree "$rel" && continue
      is_ignored "$rel" && continue
      _drift_report NEW "~/$rel"
    done < <(awk -v exclfile="$excl" '
      BEGIN { while ((getline p < exclfile) > 0) if (p != "") ex[++n] = p }
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
  local u
  while IFS= read -r u; do
    rel="${u#$HOME/}"
    is_covered "$rel" || is_ignored "$rel" || _drift_report NEW "~/$rel"
  done < <(find "$HOME/.config/systemd/user" -type f 2>/dev/null)

  # --- 4. user scripts in ~/.local/bin ---------------------------------------
  # mise shims are regenerable noise; anything larger is probably yours.
  local b
  while IFS= read -r b; do
    rel="${b#$HOME/}"
    is_covered "$rel" && continue
    is_ignored "$rel" && continue
    [ -L "$b" ] && continue
    [ "$(stat -c %s "$b" 2>/dev/null || echo 0)" -gt 300 ] && _drift_report NEW "~/$rel"
  # No -maxdepth: _drift_build_prune prunes .local/bin from the generic
  # walkers, so a script in a subdirectory would otherwise be invisible to
  # everything.
  done < <(find "$HOME/.local/bin" -type f 2>/dev/null)

  # --- 5. /etc ---------------------------------------------------------------
  # Re-run pacman's own modified-backup-file scan and diff it against what we
  # keep. OMABACKUP_SKIP_ETC=1 is used by the test fixtures so a synthetic
  # fixture is not swamped by this machine's real /etc state.
  local etc_skip etc_live etc_known f
  etc_skip='/etc/(passwd|group|subuid|subgid|shells|resolv\.conf|pacman\.d/mirrorlist|cups/cups-browsed\.conf|nsswitch\.conf|plymouth/plymouthd\.conf|security/faillock\.conf|skel/\.bashrc)$'
  if [ "${OMABACKUP_SKIP_ETC:-0}" != "1" ]; then
  # A failing pacman used to yield an empty result indistinguishable from "no
  # /etc drift", while the completion sentinel still printed. Check the producer.
  if ! LC_ALL=C pacman -Qii >/dev/null 2>&1; then
    echo "# ERROR: pacman query failed; /etc drift NOT checked"
    found=$((found+1))
  fi
  etc_live=$(LC_ALL=C pacman -Qii 2>/dev/null | grep -F '[modified]' \
    | sed -E 's/^(Backup Files *: *)?[[:space:]]*//; s/ \[modified\]//' | sort -u)
  etc_known=$(read_list "$DATA_REPO/etc-allowlist.txt" | sort -u)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    echo "$f" | grep -qE "$etc_skip" && continue
    grep -qxF "$f" <<<"$etc_known" || _drift_report NEW "$f"
  done <<<"$etc_live"
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
    while IFS= read -r f; do dropin_files+=("$f"); done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null | sort)
  done
  if [ ${#dropin_files[@]} -gt 0 ]; then
    # One pacman call for all of them; unowned files come back on stderr.
    unowned=$(LC_ALL=C pacman -Qqo "${dropin_files[@]}" 2>&1 >/dev/null \
              | sed -nE 's/^error: No package owns (.*)$/\1/p')
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      real="/etc/${f#$ETC_DROPIN_ROOT/}"          # allowlist/ignore are written as /etc/...
      echo "$real" | grep -qE "$etc_skip" && continue
      grep -qxF "$real" <<<"$etc_known" && continue
      is_ignored "$real" && continue
      _drift_report NEW "$real"
    done <<<"$unowned"
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
cmd_drift() {
  data_repo_require; lists_load
  if [[ $JSON == 1 ]]; then
    local rep; rep=$(drift_scan)
    local complete=false; [[ "$(tail -1 <<<"$rep")" == "# drift-scan-complete" ]] && complete=true
    printf '{"ok":true,"complete":%s,"items":[%s]}\n' "$complete" "$(drift_items_json <<<"$rep")"
  else
    drift_scan
  fi
}

# drift_items_json: report lines on stdin -> JSON array body (type, path, note).
# Used by cmd_drift --json and, later, health/widget via drift_parse. Leading
# whitespace is trimmed with `${v#"${v%%[! ]*}"}` (strip the longest
# leading-spaces-only prefix), not `${v##+( )}`, so this needs no `extglob`:
# that shopt used to be set at file scope and leaked into every other verb
# for the rest of the process, the same class of leak Task 5 fixed for
# nullglob.
drift_items_json() {
  local items=() type path note rest line
  while IFS= read -r line; do
    case "$line" in
      '# ERROR'*)
        # Both "# ERROR: msg" (drift_scan's own lines) and "# ERROR msg" are
        # accepted: strip the marker, an optional colon, then leading spaces,
        # so path carries the message, never the "# ERROR" prefix.
        type=ERROR
        path=${line#'# ERROR'}; path=${path#:}
        path=${path#"${path%%[! ]*}"}
        note=""
        ;;
      ''|'#'*) continue ;;
      *)
        type=${line%% *}; rest=${line#"$type"}
        rest=${rest#"${rest%%[! ]*}"}
        path=${rest%% (*}; note=""; [[ "$rest" == *" ("* ]] && note=${rest#*"$path" }
        path=${path%/}   # a directory's trailing "/" is report display flourish, not part of the path
        ;;
    esac
    items+=("{\"type\":$(jstr "$type"),\"path\":$(jstr "$path"),\"note\":$(jstr "$note")}")
  done
  jjoin "${items[@]}"
}
# drift_parse FILE: emit JSON items from a saved report file, honouring the sentinel.
drift_parse() { drift_items_json < "$1"; }
