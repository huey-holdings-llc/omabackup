#!/usr/bin/env bash
# Restore this machine's configuration from the data repo. Dry-run unless
# --apply is passed. Every stage is opt-in. Nothing is ever deleted from
# $HOME -- an overwritten file or a type-conflicting item is always moved
# aside to a "<path>.bak.<epoch>" sibling first.
#
# Ported from the source engine, bin/restore.sh (all 308 lines). Sourced by
# bin/omabackup; never executed.
#
# ERREXIT DISCIPLINE: every command whose exit status is inspected sits on
# the left of `||` or inside an `if`. There is no bare `var=$(cmd)` around a
# command that is allowed to fail; process substitutions (`< <(...)`) are
# exempt by construction since their exit status is never checked by bash.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# restore_note MSG: advisory, does not count against failures.
restore_note() { log "  $*"; }
# restore_warn MSG: a real problem. Prints, and counts toward RESTORE_FAILURES
# the same way the source script's warn() did.
restore_warn() { warn "$*"; RESTORE_FAILURES=$((RESTORE_FAILURES+1)); }
# restore_skip PATH REASON: record a stage (or an item within one) that was
# not attempted.
restore_skip() { RESTORE_SKIPPED+=("{\"path\":$(jstr "$1"),\"reason\":$(jstr "$2")}"); }

# ---------------------------------------------------------- argv hygiene
# Manifest lines are repo-controlled strings that become ARGUMENTS to pacman,
# yay, systemctl and git. `missing_native` is intersected with `pacman -Slq`
# so the native path was already safe, but the AUR path was not: a line
# beginning with "-" became a yay FLAG (`--noconfirm`, defeating that file's
# own "interactive, never --noconfirm" promise), systemd-user.txt was read
# with `awk '{print $1}'` and handed to `systemctl --user enable --now`
# unvalidated so an absolute path to a unit file in the restored tree was
# enabled AND started, and a plugin revision reached `git checkout` with no
# separator. Every list-derived argument now sits after a `--`, and its shape
# is checked first: `--` alone would have turned `--noconfirm` into a package
# name yay then tried to install, which is noise, not safety.
#
# The leading character is constrained separately from the rest, because the
# character class a package name is allowed to use contains "-" and would
# otherwise accept "--noconfirm" as a perfectly good package name.
restore_pkg_ok()  { [[ "$1" =~ ^[A-Za-z0-9@._+][A-Za-z0-9@._+-]*$ ]]; }
restore_unit_ok() { [[ "$1" =~ ^[A-Za-z0-9@._-]+\.(service|timer|socket|target|path)$ ]]; }
restore_rev_ok()  { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/+-]*$ ]]; }

# restore_mode_target BASE REL: print the path a modes.txt record names,
# resolved, or fail when it is not a real path lying directly under BASE.
#
# The record itself was validated (mode digits, a "home/" prefix, no ".."
# segment, the final component not a symlink) and then resolved through
# whatever the freshly-rsynced tree happened to contain. A hostile repo
# shipping `home/link -> /home/you/.ssh` plus a record for
# `home/link/id_ed25519` therefore got a chmod on the real key (600 to 644,
# proven), and the restore still printed "completed with no failures".
# Comparing the RESOLVED path against BASE + REL rejects a symlinked
# component anywhere along the path, not just at the end, and confines the
# result to BASE in the same comparison. Used by verify's own mode check too,
# with the throwaway as BASE.
restore_mode_target() {
  local base=$1 rel=$2 base_real real
  base_real=$(realpath -e -- "$base" 2>/dev/null) || return 1
  real=$(realpath -e -- "$base/$rel" 2>/dev/null) || return 1
  [[ "$real" == "$base_real/$rel" ]] || return 1
  printf '%s' "$real"
}

# ---------------------------------------------------------- configs
# restore_stage_configs APPLY [MIN]: copy $DATA_REPO/home back into $HOME.
# MIN overrides the floor this stage refuses below. It is a PARAMETER, not an
# environment variable: cmd_verify used to set OMABACKUP_MIN_RESTORE=1
# in-process around its own call, which is exactly the guard-weakening shape
# lib/config.sh now refuses to honour from the outside.
restore_stage_configs() {
  local apply=$1 min_restore="${2:-${OMABACKUP_MIN_RESTORE:-50}}"

  # This stage copies from the WORKING TREE, not from HEAD. When snapshot_sync
  # has run but the commit after it has not (the staged secret gate refused,
  # the process was killed), home/ holds output nobody committed -- and this
  # would write it back over the live machine while `git log` still shows the
  # older state, with verify comparing the live files against that same
  # uncommitted tree and reporting ok. Fail closed. The widget's push
  # --confirm stages only the lists, so a dirty home/ is exactly the
  # "the commit did not happen" signature, never a user edit.
  # cmd_verify calls this too, so the guard covers both verbs from here.
  local pending
  pending=$( { git -C "$DATA_REPO" status --porcelain -- home etc manifests modes.txt || true; } | awk 'NR<=5' )
  if [[ -n "$pending" ]]; then
    printf '%s\n' "$pending" | sed 's/^/    /' >&2
    die "snapshot output has uncommitted changes in the data repo (the last run did not commit); run omabackup snapshot, then retry"
  fi

  if [[ ! -d "$DATA_REPO/home" ]]; then
    restore_warn "no home/ directory in the repo -- nothing to restore"
    restore_skip "home" "no home/ directory in the repo"
    return 0
  fi
  local have_n
  have_n=$(find "$DATA_REPO/home" \( -type f -o -type l \) -printf 'x\0' 2>/dev/null | tr -dc '\0' | wc -c) || true
  if [[ "${have_n:-0}" -lt "$min_restore" ]]; then
    restore_warn "refusing to restore: home/ holds only ${have_n:-0} files (floor $min_restore)"
    restore_skip "home" "refusing to restore: home/ holds only ${have_n:-0} files (floor $min_restore)"
    return 0
  fi

  local epoch; epoch=$(date +%s)
  # A dry run used to announce "Restoring configs into $HOME" before it
  # printed anything with "[dry]" in it, so a cautious reader working top
  # down believed they had just overwritten their home directory.
  if [[ "$apply" == 1 ]]; then
    log "Restoring configs into \$HOME"
  else
    log "[dry] nothing will be written; add --apply to do it for real"
  fi

  # Type conflicts: a FILE in $HOME where the snapshot has a DIRECTORY (or
  # vice versa, or a symlink either way) is invisible to the per-file backup
  # loop below and rsync would otherwise silently replace it with nothing
  # saved. Back those up explicitly first, then clear them so rsync can lay
  # down the correct type. NUL-delimited: a newline in a directory name must
  # not be able to forge a second record.
  local rec ty rel tgt live
  while IFS= read -r -d '' rec; do
    ty="${rec%% *}"; rel="${rec#* }"
    [[ -n "$rel" ]] || continue
    tgt="$HOME/$rel"
    [[ -e "$tgt" || -L "$tgt" ]] || continue
    if [[ -L "$tgt" ]]; then live=l
    elif [[ -d "$tgt" ]]; then live=d
    else live=f; fi
    [[ "$ty" != "$live" ]] || continue
    if [[ "$apply" == 1 ]]; then
      if cp -a "$tgt" "$tgt.bak.$epoch" 2>/dev/null; then
        # shellcheck disable=SC2088  # literal "~/" prefix, not a path to expand
        RESTORE_BACKED_UP+=("$(jstr "~/$rel")")
        rm -rf -- "$tgt"
        restore_warn "type conflict at ~/$rel ($live vs $ty in snapshot); backed up to ~/$rel.bak.$epoch"
      else
        restore_warn "could not back up type conflict at ~/$rel (data about to be overwritten was NOT saved)"
      fi
    else
      # shellcheck disable=SC2088  # literal "~/" prefix, not a path to expand
      RESTORE_WOULD+=("$(jstr "~/$rel (type conflict: $live live vs $ty in snapshot)")")
    fi
  done < <(cd "$DATA_REPO/home" && find . -mindepth 1 -printf '%y %P\0')

  # Per-file safety copy: anything about to be overwritten with different
  # content is copied aside first, preserving its mode. .gitkeep is a git-side
  # placeholder for an otherwise-empty directory and must never land in $HOME.
  #
  # Symlinks are enumerated too. `-type f` skipped them, and rsync -a below
  # replaces a live link whose target has changed since the snapshot with no
  # .bak.<epoch> beside it and no mention in a dry run: a repointed
  # ~/.config/something -> elsewhere was overwritten silently. A link is
  # compared by its target, not its content (cmp follows it, so a link and its
  # snapshot copy read as identical whenever the file behind them is), and
  # backed up with cp -P, which copies the link itself.
  local rty want live_l same
  while IFS= read -r -d '' rec; do
    rty="${rec%% *}"; rel="${rec#* }"
    [[ -n "$rel" ]] || continue
    case "$rel" in */.gitkeep|.gitkeep) continue ;; esac
    tgt="$HOME/$rel"
    if [[ "$apply" == 1 ]]; then
      same=0
      if [[ "$rty" == l ]]; then
        want=$(readlink -- "$DATA_REPO/home/$rel" 2>/dev/null || true)
        live_l=$(readlink -- "$tgt" 2>/dev/null || true)
        if [[ -L "$tgt" && -n "$want" && "$want" == "$live_l" ]]; then same=1; fi
      elif cmp -s "$DATA_REPO/home/$rel" "$tgt" 2>/dev/null; then
        same=1
      fi
      if [[ -e "$tgt" || -L "$tgt" ]] && [[ "$same" == 0 ]]; then
        # cp -P on a link copies the link, never what it points at; cp -p on a
        # regular file keeps its mode.
        local -a cpargs=(-p)
        [[ "$rty" != l ]] || cpargs=(-P)
        if cp "${cpargs[@]}" "$tgt" "$tgt.bak.$epoch" 2>/dev/null; then
          # shellcheck disable=SC2088  # literal "~/" prefix, not a path to expand
          RESTORE_BACKED_UP+=("$(jstr "~/$rel")")
        else
          restore_warn "could not back up ~/$rel before overwriting it"
        fi
      fi
      # shellcheck disable=SC2088  # literal "~/" prefix, not a path to expand
      RESTORE_WROTE+=("$(jstr "~/$rel")")
    else
      # shellcheck disable=SC2088  # literal "~/" prefix, not a path to expand
      RESTORE_WOULD+=("$(jstr "~/$rel")")
    fi
  done < <(cd "$DATA_REPO/home" && find . \( -type f -o -type l \) -printf '%y %P\0')

  if [[ "$apply" == 1 ]]; then
    # --delete is deliberately NOT used: never remove a $HOME file absent
    # here. .gitkeep itself is excluded -- rsync -a still creates the
    # directory that held it.
    if ! rsync -a --exclude=.gitkeep "$DATA_REPO/home/" "$HOME/"; then
      restore_warn "rsync reported errors -- some files were NOT restored (see above)"
    fi
    if [[ ! -f "$DATA_REPO/modes.txt" ]]; then
      restore_warn "modes.txt missing -- every restored file will keep default permissions (600 files will be 644)"
    else
      log "Replaying file modes"
      # modes.txt is untrusted input synced from the repo: validate every
      # field before it ever reaches chmod. NUL-delimited for the same
      # trailing-space-filename reason as everywhere else in this file.
      local mode path
      while IFS= read -r -d '' rec; do
        mode="${rec%% *}"; path="${rec#* }"
        case "$mode" in [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;; *) continue ;; esac
        case "$path" in home/*) ;; *) continue ;; esac
        case "$path" in *..*) restore_warn "suspicious modes.txt path, skipping: $path"; continue ;; esac
        [[ -e "$DATA_REPO/$path" ]] || continue
        tgt="$HOME/${path#home/}"
        # Absent here is routine (.gitkeep is excluded from the restore), so
        # it stays a silent skip; a path that EXISTS but resolves somewhere
        # else is the attack, and that is reported.
        [[ -e "$tgt" || -L "$tgt" ]] || continue
        [[ -L "$tgt" ]] && continue
        if ! tgt=$(restore_mode_target "$HOME" "${path#home/}"); then
          restore_warn "refusing to replay a mode through a symlinked path: $path"
          continue
        fi
        if [[ -f "$tgt" || -d "$tgt" ]]; then chmod "$mode" "$tgt"; fi
      done < "$DATA_REPO/modes.txt"
    fi
    # The .bak.<epoch> copies are the only way back, and the human output
    # never mentioned them: RESTORE_BACKED_UP was emitted under --json alone,
    # so anyone who did not ask for JSON was told "completed with no failures"
    # and never learned the undo copies existed.
    local n_bak=${#RESTORE_BACKED_UP[@]}
    if [[ "$n_bak" -gt 0 ]]; then
      log "$n_bak file(s) copied aside as <path>.bak.$epoch; delete them once you are happy"
    fi
    log "Done. Run 'omarchy restart shell' or log out for shell.json to take effect."
  else
    log "[dry] --configs would restore ${have_n:-0} file(s)/link(s) into \$HOME"
    restore_list_would
  fi
}

# restore_list_would: name the first RESTORE_WOULD paths in the human dry run.
# A count on its own is not a preview: the whole point of a dry run is seeing
# WHICH files it would touch, and those paths were emitted under --json only.
# The array holds JSON strings (jstr), so one jq call decodes the lot rather
# than one fork per line.
RESTORE_WOULD_SHOWN=20
restore_list_would() {
  [[ ${#RESTORE_WOULD[@]} -gt 0 ]] || return 0
  [[ "${JSON:-0}" == 1 ]] && return 0
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] && printf '      %s\n' "$p"
  done < <(jq -r ".[0:${RESTORE_WOULD_SHOWN}][]" <<<"[$(jjoin "${RESTORE_WOULD[@]}")]" 2>/dev/null)
  local extra=$(( ${#RESTORE_WOULD[@]} - RESTORE_WOULD_SHOWN ))
  [[ "$extra" -gt 0 ]] && printf '      ... and %s more (omabackup restore --configs --json lists them all)\n' "$extra"
  return 0
}

# ---------------------------------------------------------- etc
# restore_stage_etc APPLY: diff only, NEVER writes -- a bad pam.d file locks
# you out and an old fstab can make a machine unbootable. Apply by hand only.
# OMABACKUP_ETC_ROOT is the same test hook lib/drift.sh already uses to keep
# this off the real /etc during the suite.
restore_stage_etc() {
  local etc_root="${OMABACKUP_ETC_ROOT:-/etc}" rel
  log "/etc comparison (READ ONLY -- this stage never writes)"
  if [[ ! -d "$DATA_REPO/etc" ]]; then
    restore_note "no etc/ directory in the repo"
    return 0
  fi
  # Fail closed on a tree this cannot enumerate. `find` inside the process
  # substitution below reports its failure to nobody, so an unreadable etc/
  # printed no rows at all -- byte-identical to "every /etc file matches".
  # Non-zero return: the stage did not do its job, and cmd_restore's chain is
  # written so a stage saying so no longer costs the caller its JSON reply.
  if [[ ! -r "$DATA_REPO/etc" || ! -x "$DATA_REPO/etc" ]]; then
    restore_warn "cannot read $DATA_REPO/etc -- the /etc comparison was NOT made"
    restore_skip "etc" "the repo's etc/ directory is not readable"
    return 1
  fi
  while IFS= read -r rel; do
    if [[ ! -e "$etc_root/$rel" ]]; then
      [[ $JSON == 1 ]] || printf '  \033[1;33mMISSING\033[0m  /etc/%s\n' "$rel"
    elif cmp -s "$DATA_REPO/etc/$rel" "$etc_root/$rel" 2>/dev/null; then
      [[ $JSON == 1 ]] || printf '  same     /etc/%s\n' "$rel"
    else
      [[ $JSON == 1 ]] || printf '  \033[1;31mDIFFERS\033[0m  /etc/%s\n' "$rel"
    fi
  done < <(cd "$DATA_REPO/etc" && find . -type f -printf '%P\n')
  [[ $JSON == 1 ]] || echo "  To inspect:  diff etc/<path> /etc/<path>"
  [[ $JSON == 1 ]] || echo "  Apply by hand only. Never bulk-copy pam.d or fstab."
}

# ---------------------------------------------------------- packages
# restore_stage_packages APPLY: install missing packages (interactive, never
# --noconfirm -- an unattended install has previously pulled ~1.4GB of driver
# packages nobody asked for).
restore_stage_packages() {
  local apply=$1 M="$DATA_REPO/manifests"
  if [[ ! -f "$M/pacman-native.txt" ]]; then
    restore_warn "no pacman-native.txt manifest -- skipping package restore"
    restore_skip "manifests/pacman-native.txt" "manifest missing"
    return 0
  fi
  clean() { tr -d '\r' | grep -vE '^\s*(#|$)' | sed -E -e 's/[[:space:]]+#.*$//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//'; }
  local nat_total; nat_total=$(clean < "$M/pacman-native.txt" | grep -c . || true)
  if [[ "${nat_total:-0}" -lt 100 ]]; then
    restore_warn "pacman-native.txt has only ${nat_total:-0} entries -- looks truncated, skipping package install"
    restore_skip "manifests/pacman-native.txt" "looks truncated (${nat_total:-0} entries, floor 100)"
    return 0
  fi
  have pacman || { restore_warn "pacman not found -- cannot restore packages"; return 0; }

  local missing_native missing_aur
  missing_native=$(comm -23 <(clean < "$M/pacman-native.txt" | sort) <(pacman -Qqen 2>/dev/null | sort)) || true
  missing_aur=$(comm -23 <(clean < "$M/pacman-aur.txt" 2>/dev/null | sort) <(pacman -Qqem 2>/dev/null | sort)) || true

  # Refuse anything that is not a package name BEFORE the dry-run branch, so
  # a refusal shows up in the dry run rather than first appearing when
  # --apply hands the line to yay. Filtered in this shell, never in a command
  # substitution: restore_warn and restore_skip write globals.
  local p
  local -a native_pkgs=() aur_pkgs=()
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if restore_pkg_ok "$p"; then native_pkgs+=("$p")
    else
      restore_warn "manifests/pacman-native.txt line is not a package name, refusing: $p"
      restore_skip "manifests/pacman-native.txt" "refused a line that is not a package name: $p"
    fi
  done <<<"$missing_native"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if restore_pkg_ok "$p"; then aur_pkgs+=("$p")
    else
      restore_warn "manifests/pacman-aur.txt line is not a package name, refusing: $p"
      restore_skip "manifests/pacman-aur.txt" "refused a line that is not a package name: $p"
    fi
  done <<<"$missing_aur"
  missing_native=""; missing_aur=""
  if [[ ${#native_pkgs[@]} -gt 0 ]]; then missing_native=$(printf '%s\n' "${native_pkgs[@]}"); fi
  if [[ ${#aur_pkgs[@]} -gt 0 ]]; then missing_aur=$(printf '%s\n' "${aur_pkgs[@]}"); fi

  if [[ "$apply" != 1 ]]; then
    if [[ -n "$missing_native" ]]; then
      while IFS= read -r p; do [[ -n "$p" ]] && RESTORE_WOULD+=("$(jstr "package:$p")"); done <<<"$missing_native"
    fi
    if [[ -n "$missing_aur" ]]; then
      while IFS= read -r p; do [[ -n "$p" ]] && RESTORE_WOULD+=("$(jstr "aur:$p")"); done <<<"$missing_aur"
    fi
    return 0
  fi

  log "Installing missing packages (interactive -- never --noconfirm)"
  if [[ -n "$missing_native" ]]; then
    local available gone
    available=$(comm -12 <(printf '%s\n' "$missing_native") <(pacman -Slq 2>/dev/null | sort -u)) || true
    gone=$(comm -23 <(printf '%s\n' "$missing_native") <(pacman -Slq 2>/dev/null | sort -u)) || true
    if [[ -n "$gone" ]]; then
      restore_warn "no longer in the repos (moved to AUR, renamed, or dropped): $(tr '\n' ' ' <<<"$gone")"
    fi
    if [[ -n "$available" ]]; then
      # The list reaches pacman on STDIN (the trailing "-"), not as argv, so
      # there is no argument for a "--" to separate; every name in it has been
      # through restore_pkg_ok and then intersected with `pacman -Slq`.
      if printf '%s\n' "$available" | sudo pacman -S --needed -; then
        while IFS= read -r p; do [[ -n "$p" ]] && RESTORE_WROTE+=("$(jstr "package:$p")"); done <<<"$available"
      else
        restore_warn "some native packages failed -- continuing"
      fi
    fi
  else
    restore_note "native packages already satisfied"
  fi
  if [[ ${#aur_pkgs[@]} -gt 0 ]]; then
    have yay || { restore_warn "yay not found -- cannot install AUR packages"; return 0; }
    # `--` before the list: every name in it passed restore_pkg_ok above, so
    # this is belt and braces, and belt and braces is the point.
    if yay -S --needed -- "${aur_pkgs[@]}"; then
      for p in "${aur_pkgs[@]}"; do [[ -n "$p" ]] && RESTORE_WROTE+=("$(jstr "aur:$p")"); done
    else
      restore_warn "some AUR packages failed (unmaintained or removed from AUR?) -- continuing"
    fi
  else
    restore_note "AUR packages already satisfied"
  fi
}

# ---------------------------------------------------------- plugins
# restore_stage_plugins APPLY: re-clone omarchy shell plugins from the TSV.
restore_stage_plugins() {
  local apply=$1 M="$DATA_REPO/manifests/omarchy-plugins.tsv"
  if [[ ! -f "$M" ]]; then
    restore_warn "no omarchy-plugins.tsv manifest -- skipping plugin restore"
    restore_skip "manifests/omarchy-plugins.tsv" "manifest missing"
    return 0
  fi
  local id url rev
  while IFS=$'\t' read -r id url rev; do
    case "$id" in \#*|"") continue ;; esac
    if [[ -d "$HOME/.config/omarchy/plugins/$id" ]]; then
      restore_note "present: $id"
      continue
    fi
    if [[ "$apply" != 1 ]]; then
      RESTORE_WOULD+=("$(jstr "plugin:$id")")
      continue
    fi
    log "  adding $id from $url"
    have omarchy || { restore_warn "  omarchy not found -- cannot add $id"; continue; }
    # --yes is REQUIRED: omarchy-plugin-add gates on an interactive tty, and
    # this loop's stdin is the TSV file -- without it every plugin aborts.
    if omarchy plugin add --yes "$url" </dev/null; then
      RESTORE_WROTE+=("$(jstr "plugin:$id")")
      if [[ -n "${rev:-}" && -d "$HOME/.config/omarchy/plugins/$id/.git" ]]; then
        if ! restore_rev_ok "$rev"; then
          restore_warn "plugin revision is not a git object name, refusing to check it out: $rev"
          restore_skip "plugin:$id" "refused a revision that is not a git object name: $rev"
        else
          # `<rev> --`, not `-- <rev>`: the latter names a PATH to restore
          # from the index, which is a different command entirely. The empty
          # pathspec list after the separator is what stops a rev beginning
          # with "-" being read as an option.
          git -C "$HOME/.config/omarchy/plugins/$id" checkout --quiet "$rev" -- 2>/dev/null \
            || restore_note "pinned rev $rev unavailable for $id (left at HEAD)"
        fi
      fi
    else
      restore_warn "  failed: $id"
    fi
  done < "$M"
  log "Enable/placement comes from the restored shell.json."
}

# ---------------------------------------------------------- services
# restore_stage_services APPLY: enable only units this machine had enabled,
# skipping anything recorded as deliberately disabled. syncthing is skipped
# unconditionally -- enabling it mints a NEW device ID and breaks every
# existing peer pairing. OMABACKUP_SKIP_TIMERS keeps this stage from ever
# calling systemctl, for the test suite.
restore_stage_services() {
  local apply=$1 M="$DATA_REPO/manifests"
  if [[ ! -f "$M/systemd-user.txt" ]]; then
    restore_warn "no systemd-user.txt manifest -- skipping service restore"
    restore_skip "manifests/systemd-user.txt" "manifest missing"
    return 0
  fi
  local -A off=()
  local u
  if [[ -f "$M/systemd-user-off.txt" ]]; then
    while read -r u _rest; do [[ -n "$u" ]] && off["$u"]=1; done < "$M/systemd-user-off.txt"
  fi
  local skip_units=" syncthing.service "
  while read -r u; do
    case "$u" in ""|\#*) continue ;; esac
    # Before anything else, and before the dry-run branch below, so a hostile
    # or corrupt line is refused in the dry run rather than first mattering
    # when --apply hands it to systemctl. An absolute path to a unit file in
    # the just-restored tree used to be enabled AND started from here.
    if ! restore_unit_ok "$u"; then
      restore_warn "manifests/systemd-user.txt line is not a unit name, refusing: $u"
      restore_skip "manifests/systemd-user.txt" "refused a line that is not a unit name: $u"
      continue
    fi
    case "$skip_units" in *" $u "*) continue ;; esac
    if [[ -n "${off[$u]:-}" ]]; then
      restore_skip "$u" "disabled on purpose (systemd-user-off.txt)"
      continue
    fi
    if [[ "$apply" != 1 || "${OMABACKUP_SKIP_TIMERS:-0}" == 1 ]]; then
      RESTORE_WOULD+=("$(jstr "service:$u")")
      continue
    fi
    have systemctl || { restore_warn "  systemctl not found -- cannot enable $u"; continue; }
    if systemctl --user is-enabled -- "$u" >/dev/null 2>&1; then
      continue
    fi
    if systemctl --user enable --now -- "$u" >/dev/null 2>&1; then
      RESTORE_WROTE+=("$(jstr "service:$u")")
    else
      restore_warn "  could not enable $u"
    fi
  done < <(awk '{print $1}' "$M/systemd-user.txt" 2>/dev/null)
  restore_note "system units are not enabled automatically; syncthing.service is never enabled automatically either"
}

# ---------------------------------------------------------------------------
# restore_emit APPLY: the one JSON object, printed only when JSON=1.
restore_emit() {
  local apply=$1 ok=true
  [[ "$RESTORE_FAILURES" -eq 0 ]] || ok=false
  if [[ $JSON == 1 ]]; then
    jq -cn \
      --argjson ok "$ok" \
      --argjson applied "$([[ "$apply" == 1 ]] && echo true || echo false)" \
      --argjson would_write "[$(jjoin ${RESTORE_WOULD[@]+"${RESTORE_WOULD[@]}"})]" \
      --argjson wrote "[$(jjoin ${RESTORE_WROTE[@]+"${RESTORE_WROTE[@]}"})]" \
      --argjson backed_up "[$(jjoin ${RESTORE_BACKED_UP[@]+"${RESTORE_BACKED_UP[@]}"})]" \
      --argjson skipped "[$(jjoin ${RESTORE_SKIPPED[@]+"${RESTORE_SKIPPED[@]}"})]" \
      --argjson failures "$RESTORE_FAILURES" \
      '{ok:$ok, applied:$applied, would_write:$would_write, wrote:$wrote, backed_up:$backed_up, skipped:$skipped, failures:$failures}'
  else
    echo
    if [[ "$RESTORE_FAILURES" -gt 0 ]]; then
      printf '\033[1;31m%d problem(s) during restore -- read the [warn] lines above.\033[0m\n' "$RESTORE_FAILURES"
    else
      printf '\033[1;32mRestore stages completed with no failures.\033[0m\n'
    fi
  fi
}

# cmd_restore --configs|--etc|--packages|--plugins|--services|--all [--apply]
cmd_restore() {
  data_repo_require
  local do_configs=0 do_etc=0 do_packages=0 do_plugins=0 do_services=0 any=0 apply=0 a
  for a in "$@"; do
    case "$a" in
      --configs)  do_configs=1; any=1 ;;
      --etc)      do_etc=1; any=1 ;;
      --packages) do_packages=1; any=1 ;;
      --plugins)  do_plugins=1; any=1 ;;
      --services) do_services=1; any=1 ;;
      --all)      do_configs=1; do_packages=1; do_plugins=1; do_services=1; any=1 ;;
      --apply)    apply=1 ;;
      *) usage_die "restore: unknown flag '$a'" ;;
    esac
  done
  [[ "$any" == 1 ]] || usage_die "restore: choose at least one of --configs --etc --packages --plugins --services --all"

  RESTORE_WOULD=(); RESTORE_WROTE=(); RESTORE_BACKED_UP=(); RESTORE_SKIPPED=(); RESTORE_FAILURES=0

  if ! take_lock; then
    restore_warn "the repo lock is held (a snapshot may be running); try again shortly"
  else
    # One `if` per stage, and the non-zero return COUNTED, not discarded. The
    # chain used to be `[[ ... ]] && stage`, where the stage is the final
    # command of an AND list: under errexit a stage that returned non-zero took
    # the whole process down right there, skipping every later stage, drop_lock
    # and restore_emit -- so a --json caller got no JSON object at all (the one
    # thing the contract guarantees) and the flock was held until the process
    # died. `|| true` fixed that and then threw the answer away: a stage could
    # fail with nothing recording it, and ok:false rested on the stage having
    # remembered to call restore_warn itself. restore_warn here makes it
    # structural -- a stage that returns non-zero is a failure whether or not
    # it said so on its way out.
    if [[ "$do_configs" == 1 ]];  then restore_stage_configs "$apply"  || restore_warn "the configs stage did not complete"; fi
    if [[ "$do_etc" == 1 ]];      then restore_stage_etc "$apply"      || restore_warn "the etc stage did not complete"; fi
    if [[ "$do_packages" == 1 ]]; then restore_stage_packages "$apply" || restore_warn "the packages stage did not complete"; fi
    if [[ "$do_plugins" == 1 ]];  then restore_stage_plugins "$apply"  || restore_warn "the plugins stage did not complete"; fi
    if [[ "$do_services" == 1 ]]; then restore_stage_services "$apply" || restore_warn "the services stage did not complete"; fi
    drop_lock
  fi

  restore_emit "$apply"
  [[ "$RESTORE_FAILURES" -eq 0 ]]
}
