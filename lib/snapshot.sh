#!/usr/bin/env bash
# The daily pipeline. Ten phases, each a function, in the engine's order.
# Ported from the source engine, bin/snapshot.sh:79-108 (floors), 112-199
# (assert), 200-287 (stage), 477-487 (modes), 488-512 (scan), 513-520 (floor),
# 521-536 (sync), 581-648 (commit), 649-681 (push). Sourced by bin/omabackup;
# never executed.
#
# ERREXIT DISCIPLINE. bin/omabackup runs under `set -euo pipefail`, and this
# file is where that bites hardest: rsync exits 24 on a routine race, find
# exits 1 on an unreadable directory, grep -c exits 1 when the count is zero.
# Every command whose exit status is inspected sits on the LEFT of `||` or
# inside an `if`. There is no `cmd; rc=$?` anywhere here, and no bare
# `var=$(cmd)` around a command that is allowed to fail.
# shellcheck shell=bash

# ---------------------------------------------------------------- 0. floors
# Floors are DERIVED from the last commit, not hardcoded: a repo's home/ grows
# over the years, so a fixed number stops discriminating. Half the previous
# count is tight enough to catch a staging collapse and loose enough that
# deleting one allowlisted glob is not an emergency. OMABACKUP_MIN_FILES and
# OMABACKUP_MIN_ALLOWLIST override; config.sh unsets them when they are empty,
# which is how a caller asks for "derive it" explicitly.
# shellcheck disable=SC2034  # PREV_TRACKED: read by snapshot_assert_allowlist, not this function
snapshot_floors_from_history() {
  local prev_tracked=0 prev_entries=0 listing
  if git -C "$DATA_REPO" rev-parse --verify HEAD >/dev/null 2>&1; then
    # NOT `|| true`. HEAD resolving but its tree failing to read means a
    # damaged object store, and swallowing that drops the floor to the
    # bootstrap 20 -- exactly the state in which a hollow snapshot sails
    # through and overwrites a healthy backup. The listing is taken first so
    # its failure can reach die(); the counting after it is allowed to find
    # nothing (a repo with no home/ yet is legitimate).
    listing=$(git -C "$DATA_REPO" ls-tree -r --name-only HEAD home/ 2>/dev/null) \
      || die "HEAD exists but is unreadable; run: git -C $DATA_REPO fsck"
    prev_tracked=$(grep -c . <<<"$listing" || true)
    # This one IS allowed to fail: a repo whose first commit predates
    # allowlist.txt has no such path in HEAD, which is bootstrap, not damage.
    prev_entries=$(git -C "$DATA_REPO" show HEAD:allowlist.txt 2>/dev/null | grep -cvE '^[[:space:]]*(#|$)' || true)
  fi
  # Also the gate on the mass-disappearance check below: "does a real backup
  # exist to compare against". It comes from the repo's own history, so it is
  # the same answer on a fresh clone as on the machine that made it.
  PREV_TRACKED=$prev_tracked
  if [[ "${prev_tracked:-0}" -ge 20 ]]; then
    MIN_FILES="${OMABACKUP_MIN_FILES:-$(( prev_tracked / 2 ))}"
  else
    MIN_FILES="${OMABACKUP_MIN_FILES:-20}"      # bootstrap: no meaningful history yet
  fi
  if [[ "${prev_entries:-0}" -ge 20 ]]; then
    MIN_ALLOWLIST="${OMABACKUP_MIN_ALLOWLIST:-$(( prev_entries * 9 / 10 ))}"
  else
    MIN_ALLOWLIST="${OMABACKUP_MIN_ALLOWLIST:-20}"
  fi
}

# snapshot_entry_exists ENTRY: true when at least one live path matches.
# nullglob only suppresses words that CONTAIN a wildcard, so a literal path
# that does not exist expands to itself: counting matches is not enough, each
# candidate has to be tested. IFS=$'\n' rather than the default, or an entry
# holding a literal space (".config/My App") looks missing and halts a backup.
snapshot_entry_exists() {
  local entry=$1 m rc=1 oldifs=$IFS
  IFS=$'\n'
  for m in $HOME/$entry; do
    if [[ -e "$m" ]]; then rc=0; break; fi
  done
  IFS=$oldifs
  return "$rc"
}

# snapshot_ever_added_load: fill EVER_ADDED with every path this data repo has
# ever ADDED under home/. One listing per run, built where the vanish check
# needs it and never cached beyond this process.
#
# `--diff-filter=A --name-only` over the whole history, so a path an earlier
# run's `rsync --delete` has since removed is still in the set: that is what
# makes the check cumulative, and without it erosion at just under the
# threshold passes every run forever, because each run's losses leave HEAD
# before the next run looks. `-z` because a filename may contain a newline,
# and git would otherwise quote it into something that is not the path.
#
# `--no-renames` because rename detection is ON by default (diff.renames, git
# 2.9 onward) and a detected rename is reported as R, never as A. So every
# path that entered the repo by a rename was missing from this set, answered
# "this repo never backed it up", and could not count as vanished. Measured:
# rename the entries once, then delete 20 of 25, and the run drains the backup
# where the same repo refused before the rename.
#
# The listing goes through a file, not a process substitution, so a `git log`
# that fails can still be seen. It used to vanish: the loop read nothing, every
# entry answered "never backed up", and the guard went quiet on exactly the run
# that could not prove anything. Fail closed instead.
snapshot_ever_added_load() {
  EVER_ADDED=()
  local p hist
  # Guarded, and with the same message shape as the mktemp below it: under
  # `set -e` a failing mkdir kills the process with no line of its own, so a
  # read-only or full $STATE_DIR ended a snapshot with nothing said about why.
  # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
  mkdir -m 700 -p "$STATE_DIR" \
    || die "cannot create $STATE_DIR; refusing to judge vanished entries"
  hist=$(mktemp "$STATE_DIR/.ever-added.XXXXXX") \
    || die "cannot write scratch under $STATE_DIR; refusing to judge vanished entries"
  if ! git -C "$DATA_REPO" log --no-renames --diff-filter=A --name-only --format= -z -- home/ >"$hist" 2>/dev/null; then
    rm -f "$hist"
    die "cannot read the repo history; refusing to judge vanished entries. Run: git -C $DATA_REPO fsck"
  fi
  while IFS= read -r -d '' p; do
    [[ -n "$p" ]] || continue
    EVER_ADDED+=("$p")
  done < <(sort -zu "$hist")
  rm -f "$hist"
}

# snapshot_entry_was_backed_up ENTRY: 0 when this data repo has ever held
# content that ENTRY names. That, and not "is it in today's drift report", is
# what makes an absence a DISAPPEARANCE: a seed entry that never resolved on
# this machine was never backed up, so it is not something that went missing.
#
# AN ALLOWLIST ENTRY IS A PATTERN, not always a path. This used to ask git
# about one entry at a time -- `cat-file -e HEAD:home/<entry>`, then a
# `rev-list` walk with `:(literal)` -- and neither of those can match
# `.config/g1/*.conf`, an entry that covers four real files. So every glob
# entry answered "this repo never backed it up", could never count as
# vanished, and the guard was blind to exactly the entries that cover the most
# files: 20 of 25 glob entries disappearing was measured as 0, the run
# committed, and rsync --delete took the backup from 100 files to 20.
#
# Matching is bash's own, against the set of paths the repo has ever added, so
# a glob answers the same way the rest of this tool reads the lists. The RHS
# is deliberately unquoted: it is a pattern. A directory entry matches its
# children too, which is how `.config/hypr` covers what is under it.
snapshot_entry_was_backed_up() {
  local entry=$1 p
  for p in ${EVER_ADDED[@]+"${EVER_ADDED[@]}"}; do
    # shellcheck disable=SC2053  # the entry is a pattern; matching it literally is the defect this fixes
    if [[ "$p" == home/$entry || "$p" == home/$entry/* ]]; then return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------- 1. assert
# An allowlist entry that no longer resolves means a typo, or Omarchy renaming
# a file out from under us. Never silently back up less.
snapshot_assert_allowlist() {
  local al="$DATA_REPO/allowlist.txt"
  [[ -r "$al" ]] || die "allowlist not readable: $al"
  [[ -r "$DATA_REPO/etc-allowlist.txt" ]] || die "etc allowlist not readable: $DATA_REPO/etc-allowlist.txt"
  log "Asserting allowlist entries resolve"

  local nullglob_was_on
  shopt -q nullglob && nullglob_was_on=1 || nullglob_was_on=0
  shopt -s nullglob

  local entry opt
  local -a missing=() still=()
  GONE=()
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    # A leading '?' marks the entry OPTIONAL: its absence warns instead of
    # halting. Plugin-owned paths use it. Without the marker, uninstalling one
    # plugin stopped every backup until a human edited allowlist.txt.
    opt=0
    case "$entry" in \?*) opt=1; entry="${entry#\?}" ;; esac
    if ! snapshot_entry_exists "$entry"; then
      if [[ $opt -eq 1 ]]; then GONE+=("$entry"); else missing+=("$entry"); fi
    fi
  done < <(read_list "$al")

  local entry_count
  entry_count=$(read_list "$al" | grep -c . || true)
  [[ "${entry_count:-0}" -ge "${MIN_ALLOWLIST:-20}" ]] \
    || die "allowlist has only ${entry_count:-0} entries (floor ${MIN_ALLOWLIST:-20}); refusing to run"

  # Second look. Omarchy migrations move a file aside and rewrite it, so a
  # daily run can catch a real path mid-rename; only a persistent absence is a
  # genuine one. The same rationale covers optional entries, which would
  # otherwise record a GONE that nags at every login.
  if [[ ${#missing[@]} -gt 0 || ${#GONE[@]} -gt 0 ]]; then
    sleep 5
    still=()
    for entry in ${missing[@]+"${missing[@]}"}; do
      snapshot_entry_exists "$entry" || still+=("$entry")
    done
    missing=(${still[@]+"${still[@]}"})
    still=()
    for entry in ${GONE[@]+"${GONE[@]}"}; do
      snapshot_entry_exists "$entry" || still+=("$entry")
    done
    GONE=(${still[@]+"${still[@]}"})
  fi

  # DEFAULT IS SOFT. Halting every backup because one uninstalled app left an
  # allowlist entry behind is too brittle for a machine whose apps churn: it
  # happened for real, and unrelated config went uncaptured for weeks while
  # the lists were argued about.
  #
  # A LARGE fraction missing is a different animal: wrong $HOME, an unmounted
  # partition, a bad edit. Committing then would destroy the backup. So many
  # vanished dies, a few are recorded as GONE and the run carries on.
  #
  local pct
  if [[ ${#missing[@]} -gt 0 ]]; then
    pct=$(( ${#missing[@]} * 100 / (entry_count > 0 ? entry_count : 1) ))
    if [[ "$pct" -ge "${CFG_MAX_MISSING_PCT:-25}" ]]; then
      printf '  missing: %s\n' "${missing[@]}" >&2
      die "${#missing[@]} of $entry_count allowlist entries ($pct%) no longer exist; refusing to run. Wrong \$HOME, or an unmounted partition?"
    fi
  fi

  # ...and the same percentage over the OPTIONAL entries too, which is where
  # the guard actually had to look. Every entry in share/allowlist.example
  # carries the `?` marker, so on a stock install `missing` above is
  # permanently empty and maxMissingPct -- the guard whose stated purpose is
  # "wrong $HOME, or an unmounted partition?" -- could never fire at all. The
  # only thing left between an unmounted $HOME and an `rsync --delete` over a
  # good backup was the halved-file floor, which lets about half of it go.
  #
  # VANISHED = THIS REPO HAS BACKED IT UP AND $HOME NO LONGER HAS IT, required
  # and optional entries alike. The repo's own history is the whole baseline,
  # which matters three ways:
  #   * it travels with a clone, so the check is armed on the FIRST run after
  #     `setup --import` on a second machine -- the case an earlier version
  #     missed, because it keyed on manifests/.last-run, which is gitignored
  #     and therefore never present in a fresh clone;
  #   * a seed entry that never resolved here was never backed up, so it is
  #     not a disappearance and a sparse machine is never refused for it;
  #   * it is cumulative. An earlier version compared against the last drift
  #     report and ignored an absence that report already carried, so erosion
  #     at just under the threshold passed every run, forever, and the backup
  #     drained away one notch at a time.
  # The gate is PREV_TRACKED, from the same history: under 20 tracked files
  # there is no real backup yet, nothing to destroy, and nothing to compare
  # against.
  # Nothing absent means nothing to judge, so the history listing is never
  # walked on a healthy run: it is the one expensive read here (the whole log,
  # every commit), and a run with a full $HOME has no question for it to
  # answer.
  if [[ "${PREV_TRACKED:-0}" -ge 20 && ( ${#missing[@]} -gt 0 || ${#GONE[@]} -gt 0 ) ]]; then
    local e
    local -a vanished=()
    snapshot_ever_added_load
    for e in ${missing[@]+"${missing[@]}"} ${GONE[@]+"${GONE[@]}"}; do
      if snapshot_entry_was_backed_up "$e"; then vanished+=("$e"); fi
    done
    if [[ ${#vanished[@]} -gt 0 ]]; then
      pct=$(( ${#vanished[@]} * 100 / (entry_count > 0 ? entry_count : 1) ))
      if [[ "$pct" -ge "${CFG_MAX_MISSING_PCT:-25}" ]]; then
        printf '  vanished: %s\n' "${vanished[@]}" >&2
        die "${#vanished[@]} of $entry_count allowlist entries ($pct%) no longer exist; refusing to run. Wrong \$HOME, or an unmounted partition? If they are gone for good: omabackup resolve-gone <path> remove, or edit allowlist.txt by hand and commit it"
      fi
    fi
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    for entry in "${missing[@]}"; do
      GONE+=("$entry")
      warn "allowlist entry absent (uninstalled?): $entry"
    done
  fi

  [[ "$nullglob_was_on" = 1 ]] || shopt -u nullglob
}

# ---------------------------------------------------------------- 2. stage
snapshot_stage() {
  have rsync || die "rsync not found: cannot stage the backup"
  log "Staging files"
  rm -rf "$STAGE"
  mkdir -p "$STAGE/home" "$STAGE/etc" "$STAGE/manifests"

  local maxsize="${CFG_MAX_FILE_SIZE:-8m}" findsize
  findsize=$(manifests_find_size "$maxsize")
  local -a excludes=(
    --exclude='*.bak.*'          # omarchy migration backups
    --exclude='*.sample'         # stock hook samples
    --exclude='mimeinfo.cache'   # regenerated by desktop-file-utils
    --exclude='*.log'
    --exclude='.git/'
    # No size guard existed once. A 200MB file in an allowlisted directory put
    # the secret scan past the unit's TimeoutStartSec (SIGKILL mid-scan) AFTER
    # `git add` had written the blob: .git grew by the full size with nothing
    # committed, and none of it reclaimable.
    --max-size="$maxsize"
  )
  # Deliberately no generic 'plugins/' exclude: it would also swallow the
  # allowlisted .claude/plugins/known_marketplaces.json. Plugin clones are
  # simply never listed as a source instead.

  local nullglob_was_on
  shopt -q nullglob && nullglob_was_on=1 || nullglob_was_on=0
  shopt -s nullglob

  local back=$PWD
  cd "$HOME" || die "cannot cd \$HOME ($HOME)"
  local entry path sym oldifs rc
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    case "$entry" in \?*) entry="${entry#\?}" ;; esac
    oldifs=$IFS; IFS=$'\n'
    for path in $entry; do
      IFS=$oldifs
      if [[ -e "$path" ]]; then
        # rsync -a stores a symlink, not the tree behind it. Only a symlinked
        # DIRECTORY is dangerous: the whole subtree silently leaves the backup
        # while the drift scan still calls it covered. A symlinked FILE is
        # stored as a link, which is correct and expected.
        if [[ -L "$path" && -d "$path" ]]; then
          die "allowlist entry is now a symlink to a directory: $path; its contents would NOT be backed up"
        fi
        # The same hazard one level down. Checked on the LIVE tree on purpose:
        # this used to run over the staging copy, where a RELATIVE link whose
        # target lies outside the allowlisted subtree (the exact case that
        # loses data) dangles, so -xtype d was false and the guard passed.
        sym=$(find "$path" -path '*/.git' -prune -o -type l -xtype d -print -quit 2>/dev/null || true)
        [[ -n "$sym" ]] && die "symlinked directory inside the backup: ~/${sym#./}; its contents are NOT saved"
        rc=0
        rsync -a --relative "${excludes[@]}" "./$path" "$STAGE/home/" || rc=$?
        if [[ $rc -ne 0 ]]; then
          # 24 is rsync's "some files vanished before I could copy them". The
          # allowlist covers paths that editors and Omarchy rewrite constantly,
          # so this race is routine, not an error.
          [[ $rc -eq 24 ]] || die "rsync failed ($rc) copying $path"
          warn "files vanished while copying $path; they will be captured next run"
        fi
      fi
      IFS=$'\n'
    done
    IFS=$oldifs
  done < <(read_list "$DATA_REPO/allowlist.txt")

  # /etc: reference copies only, never written back by restore.
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in \?*) f="${f#\?}" ;; esac
    # "${f#/etc/}" is a string strip, not path confinement: an entry like
    # /etc/../<abs path> would escape $STAGE entirely. Confine explicitly.
    case "$f" in /etc/*) ;; *) warn "not under /etc, skipping: $f"; continue ;; esac
    case "$f" in *..*)  warn "path traversal, skipping: $f"; continue ;; esac
    [[ -r "$f" ]] || { warn "unreadable, skipping: $f"; continue; }
    install -Dm644 "$f" "$STAGE/etc/${f#/etc/}" || warn "could not stage $f"
  done < <(read_list "$DATA_REPO/etc-allowlist.txt")

  # Anything the size guard skipped. A silently dropped config is the exact
  # failure mode this whole tool exists to prevent, so it is reported both to
  # the terminal and into the drift report.
  local big
  while IFS= read -r -d '' big; do
    [[ -z "$big" ]] && continue
    warn "too large for the backup (> $maxsize): ~/${big#"$HOME"/}"
    # Same rule as every other producer: a TAB or a newline in the name means
    # the row cannot say which file it is about, so it becomes an ERROR row
    # (which is a fault) rather than a TOOBIG row naming a different path.
    # shellcheck disable=SC2088  # literal "~/" display prefix, exactly what the report prints; never a path bash is asked to expand
    if drift_path_representable "~/${big#"$HOME"/}"; then
      printf 'TOOBIG     ~/%s\t(exceeds %s; NOT backed up)\n' "${big#"$HOME"/}" "$maxsize" \
        >> "$STAGE/manifests/.toobig"
    else
      drift_error_unrepresentable "~/${big#"$HOME"/}" >> "$STAGE/manifests/.toobig"
    fi
  done < <(snapshot_oversized "$findsize")

  cd "$back" || die "cannot return to $back"
  # git cannot store an empty directory, so it silently vanishes on clone and
  # restore. Marked in STAGING so the floor count and the .gitignore reconcile
  # see exactly what git will.
  find "$STAGE/home" -type d -empty -exec touch {}/.gitkeep \; 2>/dev/null || true
  [[ "$nullglob_was_on" = 1 ]] || shopt -u nullglob
}

# snapshot_oversized FINDSIZE: print live allowlisted files above the size cap,
# NUL-delimited: a newline in a filename would otherwise split one path into
# two fragments before the TOOBIG producer saw it.
# The rsync excludes are repeated here, or files dropped BY DESIGN (*.log,
# *.bak.*) are reported as TOOBIG forever with no way to silence them.
snapshot_oversized() {
  local findsize=$1 e p oldifs=$IFS
  IFS=$'\n'
  for e in $(read_list "$DATA_REPO/allowlist.txt"); do
    case "$e" in \?*) e="${e#\?}" ;; esac
    for p in $HOME/$e; do
      if [[ -e "$p" ]]; then
        find "$p" -type f -size +"$findsize" \
          ! -name '*.log' ! -name '*.bak.*' ! -name '*.sample' ! -name 'mimeinfo.cache' \
          ! -path '*/.git/*' -print0 2>/dev/null || true
      fi
    done
  done
  IFS=$oldifs
}

# ---------------------------------------------------------------- 3b. drift
# The GONE lines and the sentinel check. Optional allowlist entries that have
# disappeared are recorded in the report rather than only warned to the
# journal, so a shrinking backup is visible at every login instead of never.
snapshot_drift_finish() {
  local rep="$STAGE/manifests/drift.txt" g
  for g in ${GONE[@]+"${GONE[@]}"}; do
    # shellcheck disable=SC2088  # literal "~/" display prefix, exactly what the report prints; never a path bash is asked to expand
    if drift_path_representable "~/$g"; then
      printf 'GONE       ~/%s\n' "$g" >> "$rep"
    else
      drift_error_unrepresentable "~/$g" >> "$rep"
    fi
    warn "optional entry absent (uninstalled?): $g"
  done
  # A crashed scan used to be indistinguishable from a clean one: the output
  # was captured with `|| true` and everything downstream saw zero findings.
  # drift_scan ends with a sentinel; its absence is a hard failure.
  grep -q '^# drift-scan-complete' "$rep" \
    || die "drift scan did not complete; refusing to commit a snapshot whose drift report is unreliable"
  # Advance the committed copy immediately. The new-drift comparison reads the
  # repo copy, so if a later step died the same item re-fired a critical
  # notification on every subsequent run, forever.
  if [[ "$SNAP_DRY" != 1 ]]; then
    cp "$rep" "$DATA_REPO/manifests/drift.txt" 2>/dev/null || true
  fi
  # GONE belongs in this filter alongside NEW: an optional entry that has
  # vanished means the backup just got smaller, which is the one drift class
  # nobody notices on their own. It must match manifests_drift's capture of
  # the previous report exactly, or the comm below diffs two different things.
  local new_drift
  new_drift=$(grep -hE "$DRIFT_CLASSES" "$rep" 2>/dev/null | sort || true)
  SNAP_NEW_DRIFT=$(comm -13 <(printf '%s\n' "$MAN_DRIFT_PREV") <(printf '%s\n' "$new_drift") | grep . || true)
  manifests_drift_counts "$rep"
  log "drift: ${DRIFT_N} item(s); see manifests/drift.txt"
  if [[ -n "$SNAP_NEW_DRIFT" ]]; then
    warn "NEW unbacked config detected:"
    printf '%s\n' "$SNAP_NEW_DRIFT" | sed 's/^/    /' >&2
  fi
}

# ---------------------------------------------------------------- 4. modes
# git stores only the exec bit, but plenty of these files are mode 600.
# NUL-delimited: with '\n' a directory name containing a newline splits one
# record into two, and the forged second line is a syntactically valid
# "MODE path" record (verified to restore a 600 file as 777). NUL also fixes
# filenames with trailing spaces, which `read -r mode path` silently truncated.
# Directories too: git checks every directory out as 755, so ~/.ssh (700) came
# back world-listable on a fresh clone.
snapshot_modes() {
  ( cd "$STAGE" && find home etc \( -type f -o -type d \) -printf '%m %p\0' | sort -z -k2 ) \
    > "$STAGE/modes.txt" || die "could not record file modes"
}

# ---------------------------------------------------------------- 6. floor
snapshot_floor() {
  # `-printf 'x\n'` prints one constant line per file, so a filename holding a
  # newline cannot inflate the count -- which is what made the .gitignore
  # reconcile below abort with a false, empty accusation.
  STAGED_COUNT=$(find "$STAGE/home" \( -type f -o -type l \) -printf 'x\n' 2>/dev/null | grep -c . || true)
  STAGED_COUNT=${STAGED_COUNT:-0}
  log "Staged $STAGED_COUNT files under home/"
  [[ "$STAGED_COUNT" -ge "$MIN_FILES" ]] \
    || die "only $STAGED_COUNT files staged (floor is $MIN_FILES); refusing to commit a hollow snapshot"
}

# ------------------------------------------------------------ 6b. normalize
# Apply normalize.txt: neutralise self-changing values so an unchanged system
# produces an identical tree and therefore no commit. Adding a newly discovered
# volatile field is a one-line data edit, not a code change.
#
# normalize.txt is DATA, and data is never code. It lives in the data repo, so
# it travels with a clone, a pull and any hand edit, and both halves of a rule
# were once trusted completely: GNU sed's `e` command (and the s///e flag)
# executes the pattern space as a shell command, and the glob half was expanded
# unquoted and unconfined, so `../../victim.txt` had `sed -i` rewrite a file
# two levels above the repo. Both halves are checked here and by
# `omabackup lint` (which was itself the execution site: it tried every rule
# with a bare `sed -e`, so a clean lint of a freshly cloned repo ran the rule).

# normalize_npath_ok NPATH: 0 when the glob half of a rule can only ever
# expand inside $STAGE. Empty, absolute and any ".." segment are refused
# BEFORE the glob runs; the expansion is re-checked against the staging root
# afterwards, because a glob can still reach a symlink.
normalize_npath_ok() {
  local p=$1
  [[ -n "$p" ]] || return 1
  case "$p" in
    /*) return 1 ;;
    ..|../*|*/..|*/../*) return 1 ;;
  esac
  return 0
}

# normalize_expr_sandboxed EXPR: run EXPR against a literal `x` under GNU
# sed's --sandbox (4.3+), which rejects exactly the e, r and w commands at
# compile time, before any of them can run. Prints sed's own message on
# stdout so the caller can tell a sandbox refusal ("...in sandbox mode") from
# a plain syntax error; LC_ALL=C keeps that message stable. Always call it in
# a condition: a rejected rule is an expected outcome, not an abort.
normalize_expr_sandboxed() {
  # shellcheck disable=SC2069  # deliberate swap: stderr to the caller's
  # capture, stdout (the rewritten `x`) discarded. Written the other way round
  # the message would be lost and only the exit status would survive.
  printf 'x\n' | LC_ALL=C sed --sandbox -e "$1" 2>&1 >/dev/null
}

snapshot_normalize() {
  local nf="$DATA_REPO/normalize.txt"
  [[ -r "$nf" ]] || return 0
  local stage_real
  stage_real=$(realpath -e -- "$STAGE") || die "the staging tree vanished before normalize"
  local npath nexpr target real serr
  while IFS=$'\t' read -r npath nexpr; do
    case "$npath" in ''|'#'*) continue ;; esac
    [[ -n "${nexpr:-}" ]] || continue
    normalize_npath_ok "$npath" \
      || die "normalize rule path escapes the staging tree: $npath (run: omabackup lint)"
    if ! serr=$(normalize_expr_sandboxed "$nexpr"); then
      die "normalize rule for $npath refused: ${serr:-sed rejected the expression} (run: omabackup lint)"
    fi
    for target in "$STAGE"/$npath; do
      [[ -f "$target" ]] || continue
      # Re-check after expansion: the glob half is confined above, but a
      # symlink inside the staging tree would still land the write elsewhere.
      real=$(realpath -e -- "$target") || continue
      case "$real" in "$stage_real"/*) ;;
        *) die "normalize rule for $npath resolves outside the staging tree: $real" ;;
      esac
      [[ -f "$real.prenorm" ]] || cp "$real" "$real.prenorm"
      LC_ALL=C sed --sandbox -i -e "$nexpr" "$real" \
        || die "normalize rule for $npath failed on ${real#"$stage_real"/}; check normalize.txt"
      # A rule like `d` is valid sed but empties the file. Backing up 0 bytes
      # while the live file has content is silent data loss.
      [[ -s "$real" ]] || [[ ! -s "$real.prenorm" ]] \
        || die "normalize rule emptied ${real#"$stage_real"/}; check normalize.txt"
    done
  done < <(grep -vE '^[[:space:]]*(#|$)' "$nf" || true)

  # Any JSON we rewrote must still parse. Only fail if WE broke it: VS Code's
  # settings.json is officially JSONC and may hold // comments and trailing
  # commas written by its own UI. Treating that as corruption stopped every
  # backup on this machine until a human hand-edited the file.
  if have python3; then
    local j
    while IFS= read -r j; do
      [[ -f "$j.prenorm" ]] || continue
      if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$j.prenorm" 2>/dev/null; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$j" 2>/dev/null \
          || die "normalisation produced invalid JSON: ${j#"$STAGE/"}"
      fi
      rm -f "$j.prenorm"
    done < <(snapshot_normalized_json "$nf")
  fi
  find "$STAGE" -name '*.prenorm' -delete 2>/dev/null || true
}

# snapshot_normalized_json NORMALIZE_FILE: print every staged .json file a
# normalize rule could have touched.
snapshot_normalized_json() {
  local g f
  while IFS= read -r g; do
    # Same confinement as snapshot_normalize: this loop globs a repo-supplied
    # path too, and its caller rm -f's the .prenorm sibling of every hit.
    normalize_npath_ok "$g" || continue
    for f in "$STAGE"/$g; do [[ -f "$f" ]] && printf '%s\n' "$f"; done
  done < <(grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | cut -f1 | grep '\.json$' || true)
}

# ---------------------------------------------------------------- 7. sync
snapshot_sync() {
  log "Syncing staging into the repo"
  rsync -a --delete "$STAGE/home/"      "$DATA_REPO/home/"      || die "sync of home/ failed"
  rsync -a --delete "$STAGE/etc/"       "$DATA_REPO/etc/"       || die "sync of etc/ failed"
  rsync -a --delete "$STAGE/manifests/" "$DATA_REPO/manifests/" || die "sync of manifests/ failed"
  cp "$STAGE/modes.txt" "$DATA_REPO/modes.txt" || die "could not write modes.txt"
  rm -rf "$STAGE"
}

# ---------------------------------------------------------------- 9. commit
# Only snapshot OUTPUT is staged. `git add -A` used to sweep an in-progress
# edit to the lists, the README or the rules file into a "snapshot:" commit and
# push it. Those are committed by a human, on purpose, with a real message;
# anything else dirty is reported here and nagged about at login.
snapshot_commit() {
  COMMITTED=false

  # `git commit` commits the whole INDEX, not just what the add below staged.
  # Anything already staged when the run started -- a half-finished
  # allowlist.txt edit the user ran `git add` on, or the staging a refused
  # `push --confirm` left behind -- rode into the snapshot commit and was
  # pushed with it, which is exactly what the mutation rule forbids. Unstage
  # it: `git reset` leaves the working tree alone, so the edit survives as an
  # uncommitted change, gets reported below, and still shows in the login nag.
  if ! git -C "$DATA_REPO" diff --cached --quiet; then
    local pre
    pre=$( { git -C "$DATA_REPO" diff --cached --name-only || true; } | awk 'NR<=5' | paste -sd' ' )
    warn "unstaging edits that were staged before this run (they stay as uncommitted changes): $pre"
    git -C "$DATA_REPO" reset -q || die "could not unstage pre-existing staged changes"
  fi

  git -C "$DATA_REPO" add -A -- home etc manifests modes.txt || die "git add failed"

  # Reconcile: .gitignore is applied at `git add` time, AFTER staging and the
  # floor check, so an allowlisted file matching a .gitignore pattern (id_*,
  # *.key, *.pem) would be dropped silently while every check still reported
  # healthy. Warn, do not die: an app dropping a *.sqlite into an allowlisted
  # directory is a reporting gap worth knowing about, not a reason to stop
  # every future backup.
  local tracked_n
  tracked_n=$( { git -C "$DATA_REPO" ls-files -z home/ || true; } | tr -dc '\0' | wc -c )
  if [[ "$STAGED_COUNT" -ne "$tracked_n" ]]; then
    warn "$((STAGED_COUNT - tracked_n)) staged file(s) excluded by .gitignore"
    local ex
    while IFS= read -r ex; do
      [[ -z "$ex" ]] && continue
      # shellcheck disable=SC2088  # literal "~/" display prefix, exactly what the report prints; never a path bash is asked to expand
      if drift_path_representable "~/${ex#home/}"; then
        printf 'EXCLUDED   ~/%s\t(matches .gitignore; NOT backed up)\n' "${ex#home/}" \
          >> "$DATA_REPO/manifests/drift.txt"
      else
        drift_error_unrepresentable "~/${ex#home/}" >> "$DATA_REPO/manifests/drift.txt"
      fi
    done < <(git -C "$DATA_REPO" ls-files -o -i --exclude-standard home/ 2>/dev/null | awk 'NR<=20' || true)
    # Re-stage. These lines are written after the `git add` above, so without
    # this they are never committed AND leave the working tree permanently
    # dirty -- the feature was inert for months.
    git -C "$DATA_REPO" add -f manifests/drift.txt 2>/dev/null || true
  fi

  local others
  others=$(git -C "$DATA_REPO" status --porcelain -- . ':!home' ':!etc' ':!manifests' ':!modes.txt' 2>/dev/null | awk 'NR<=5' || true)
  if [[ -n "$others" ]]; then
    warn "uncommitted edits outside the snapshot (NOT included; commit them yourself):"
    printf '%s\n' "$others" | sed 's/^/    /' >&2
  fi

  if git -C "$DATA_REPO" diff --cached --quiet; then
    log "No changes. Nothing to commit."
    return 0
  fi

  # AUTHORITATIVE GATE. The staging scan covers only files copied in from
  # $HOME; this scans exactly what is about to be committed. It runs BEFORE
  # `git commit` on purpose -- its `git reset` undoes the staging, and there is
  # nothing to undo afterwards.
  secrets_scan_staged

  # awk, not head: head exits early and can SIGPIPE the upstream, which under
  # pipefail would abort the run one line before `git commit`.
  local summary
  summary=$( { git -C "$DATA_REPO" diff --cached --name-only || true; } | cut -d/ -f1-2 | sort -u | awk 'NR<=8' | paste -sd' ' )
  # A machine with no git identity configured cannot commit at all. The
  # fallback lives in git_ident_args (lib/lock.sh) so every commit path in
  # this tool gets the same one.
  git_ident_args
  git -C "$DATA_REPO" ${GIT_IDENT_ARGS[@]+"${GIT_IDENT_ARGS[@]}"} commit -q \
    -m "snapshot: $(date '+%Y-%m-%d %H:%M')" -m "areas: $summary" || die "git commit failed"
  COMMITTED=true
  log "Committed: $(git -C "$DATA_REPO" log -1 --format='%h %s' || true)"
}

# ------------------------------------------------------------- 10. notify
# Desktop popups are for the unattended timer path ONLY. A manual run -- a
# person, an agent, the test fixture -- already prints the same warning to a
# terminal somebody is reading, and the fixture's popups once named paths that
# existed only under a scratch $HOME. systemd sets INVOCATION_ID for a unit's
# processes and nothing else does. The signature file makes the popup fire on
# CHANGE, not on state: a daily nag about something already triaged trains you
# to ignore the one that matters.
snapshot_notify_new_drift() {
  local rep="$DATA_REPO/manifests/drift.txt"
  [[ -f "$rep" ]] || return 0
  local sig prev=""
  sig=$(sha256sum "$rep" 2>/dev/null | cut -d' ' -f1 || true)
  [[ -n "$sig" ]] || return 0
  [[ -f "$STATE_DIR/drift.sig" ]] && prev=$(cat "$STATE_DIR/drift.sig" 2>/dev/null || true)
  # Advance the signature even on a manual run, and even when no popup is due:
  # the point is that a given report is announced at most once.
  if [[ "$sig" != "$prev" ]]; then
    # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
    mkdir -m 700 -p "$STATE_DIR"
    printf '%s\n' "$sig" > "$STATE_DIR/drift.sig"
  else
    return 0
  fi
  [[ -n "${INVOCATION_ID:-}" ]] || return 0
  [[ -n "${SNAP_NEW_DRIFT:-}" ]] || return 0
  # One line of body on purpose: a multi-line notification body is truncated by
  # most daemons anyway, and the report itself is one command away.
  notify "OmaBackup: new unbacked config" \
    "$(printf '%s' "$SNAP_NEW_DRIFT" | grep -c . || true) new item(s). Run: omabackup drift" critical
}

# snapshot_result STATE: the one JSON object this verb contracts to produce,
# and the status file the widget reads. health_write_status arrives with the
# health library; until then a minimal placeholder keeps the file present so
# the widget renders "unknown" rather than a blank badge.
snapshot_result() {
  local state=$1 rep="$DATA_REPO/manifests/drift.txt"
  [[ "$state" == dry && -f "$STAGE/manifests/drift.txt" ]] && rep="$STAGE/manifests/drift.txt"
  manifests_drift_counts "$rep"
  if [[ "${JSON:-0}" == 1 ]]; then
    jq -cn \
      --arg state "$state" \
      --argjson committed "${COMMITTED:-false}" \
      --argjson pushed "${PUSHED:-false}" \
      --argjson pv "${PUSH_VERIFIABLE:-false}" \
      --arg reason "${PUSH_REASON:-}" \
      --argjson drift "${DRIFT_N:-0}" \
      --argjson toobig "${TOOBIG_N:-0}" \
      --argjson excluded "${EXCLUDED_N:-0}" \
      '{ok:true, state:$state, committed:$committed, pushed:$pushed,
        push_verifiable:$pv, push_reason:$reason,
        drift_count:$drift, toobig:$toobig, excluded:$excluded}'
  fi
  if declare -F health_write_status >/dev/null; then
    health_write_status
  else
    state_write_status "$(jq -cn --argjson t "$(date +%s)" '{state:"unknown", generated:$t}')"
  fi
  logf "snapshot state=$state committed=${COMMITTED:-false} pushed=${PUSHED:-false} drift=${DRIFT_N:-0}"
}

# ---------------------------------------------------------------------------
cmd_snapshot() {
  local a dry=0 nopush=0
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --no-push) nopush=1 ;;
      *) usage_die "snapshot: unknown flag $a" ;;
    esac
  done
  SNAP_DRY=$dry
  # Stamped at the START of the run, not the end: anything comparing a live
  # file against this stamp treats a file newer than it as "changed since the
  # snapshot". Stamping at the end left a window where a file rewritten
  # mid-run looked like a fidelity bug.
  RUN_START=$(date +%s)
  # SKIP_PUSH and DIVERGED are pipeline state: remote_push_if_ahead writes
  # them, and the health library (Task 10) reads them. Reset here so a second
  # call in the same process cannot inherit the first run's verdict.
  COMMITTED=false; PUSHED=false
  # shellcheck disable=SC2034  # written here, read by lib/remote.sh and lib/health.sh
  SKIP_PUSH=0
  # shellcheck disable=SC2034  # written by remote_push_if_ahead, read by lib/health.sh
  DIVERGED=false
  PUSH_VERIFIABLE=false; PUSH_REASON=""
  SNAP_NEW_DRIFT=""; MAN_DRIFT_PREV=""; STAGED_COUNT=0
  GONE=()

  data_repo_require
  cd "$DATA_REPO" || die "cannot cd $DATA_REPO"

  # Single instance, and it is taken BEFORE repo_assert_clean, not after.
  # Two concurrent runs share one $STAGE, and the second one's
  # `rm -rf "$STAGE"` can empty the tree between the floor check and the sync
  # -- which once committed a snapshot with 213 of 214 files deleted. More
  # narrowly: repo_assert_clean DELETES an abandoned .git/index.lock, and the
  # only thing that makes that safe is being the sole instance. Asserting
  # first and locking second let two runs race over that removal, which is the
  # argument the engine's own comment makes for the guard. Wait briefly rather
  # than skipping instantly: a manual run overlapping the timer should queue,
  # not silently do nothing.
  if ! take_lock; then
    exec 9>&-
    warn "another run held the lock for ${OMABACKUP_LOCK_WAIT:-20}s; skipping this run"
    snapshot_result skipped
    return 0
  fi

  repo_assert_clean
  snapshot_floors_from_history
  snapshot_assert_allowlist
  snapshot_stage
  lists_load
  manifests_generate "$STAGE"
  snapshot_drift_finish
  snapshot_modes
  secrets_filename_gate "$STAGE"
  secrets_scan_staging "$STAGE"
  snapshot_floor
  snapshot_normalize

  if [[ $dry == 1 ]]; then
    log "dry run: staged and scanned $STAGED_COUNT files; the repo was NOT modified"
    snapshot_result dry
    rm -rf "$STAGE"
    drop_lock
    return 0
  fi

  snapshot_sync
  remote_probe
  snapshot_commit
  printf '%s\n' "$RUN_START" > "$DATA_REPO/manifests/.last-run"
  if [[ $nopush == 1 ]]; then
    # shellcheck disable=SC2034  # read by lib/remote.sh and lib/health.sh
    SKIP_PUSH=1
  else
    remote_push_if_ahead
  fi
  snapshot_notify_new_drift
  snapshot_result "done"
  drop_lock
}
