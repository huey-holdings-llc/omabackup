#!/usr/bin/env bash
# Manifests: everything about this machine that is NOT a file under $HOME.
# Ported from the source engine, bin/snapshot.sh:288-476 (phase 3 of the daily
# pipeline). Sourced by bin/omabackup; never executed.
#
# Two rules govern this whole file, both learned the hard way by the engine:
#
#   1. Every generator is guarded by `have`. A tool that is not installed on
#      this machine writes a documented placeholder instead of an empty file
#      or a hard failure -- omabackup runs on machines without cups, without
#      fprintd, without npm.
#   2. manifests/ is synced into the data repo with `rsync --delete`, so a
#      manifest that fails to regenerate is DELETED from the backup rather
#      than left alone. is_placeholder + the carry-forward loop restore the
#      previous committed copy for every manifest that must never silently
#      become empty. The placeholders themselves count as failures: an early
#      version tested only for emptiness, so "(none)" happily replaced real
#      data under --delete.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # MAN_DRIFT_PREV, DRIFT_N, TOOBIG_N, EXCLUDED_N are read by lib/snapshot.sh

# Manifests whose previous copy is carried forward when regeneration fails.
# versions.txt and drift.txt are deliberately absent: they are generated from
# data that is always available, so a change in them is real.
#
# groups.txt used to be in that "always available" set on the strength of
# `id -nG` never failing. It can: in a container, mid-NSS-outage, or with a
# broken sssd, it returns nothing, and an empty groups.txt then replaced the
# real one under `rsync --delete`. Carrying it forward costs nothing and is
# the same fail-closed rule every other machine fact already gets.
MANIFESTS_CARRIED=(
  install-history.tsv systemd-user.txt systemd-system.txt systemd-user-off.txt groups.txt
  dconf.txt pacman-native.txt pacman-aur.txt omarchy-plugins.tsv
  omarchy-plugins.json network.txt printers.txt fingerprint.txt
  vscode-extensions.txt timezone.txt locale.txt stock-fingerprint.txt
  uv-tools.txt npm-global.txt
)

# is_placeholder FILE: true when FILE holds nothing worth keeping. Empty, or
# one of the documented "the tool was not there" markers. Whitespace is
# stripped first so a trailing newline does not defeat the match.
is_placeholder() {
  [[ -s "$1" ]] || return 0
  local squashed
  squashed=$(tr -d '[:space:]' < "$1" 2>/dev/null || true)
  case "$squashed" in
    '(none)'|'unknown'|'[]'|'(noprinters)'|'(dconfunavailable)'|'(nmcliunavailable)'|\
    '(codeCLIunavailable)'|'(uvunavailable)'|'(npmunavailable)'|'(pacmanunavailable)') return 0 ;;
  esac
  # A header-only file is a placeholder too: the plugin TSV always emits its
  # header, so emptiness alone never fires for it.
  case "$1" in
    *omarchy-plugins.tsv)
      local body; body=$(grep -cv '^#' "$1" 2>/dev/null || true)
      [[ "${body:-0}" -eq 0 ]] && return 0
      ;;
  esac
  return 1
}

# manifests_bounded CMD...: run CMD under a 30-second ceiling where `timeout`
# exists, plain where it does not. The generators that talk to D-Bus (dconf,
# fprintd) or the network (nmcli, npm, omarchy, the VS Code CLI) can hang
# indefinitely, and the daily run holds the data repo's flock for the whole
# time they do: one wedged call blocks every later run and the timer with it,
# until somebody notices the backup stopped. A timeout exits non-zero, so each
# caller's `|| placeholder` fallback fires exactly as it does for a tool that
# is not installed, and the carry-forward guard then restores the previous
# committed copy rather than letting rsync --delete eat it.
MANIFESTS_TIMEOUT=30
manifests_bounded() {
  if have timeout; then timeout "$MANIFESTS_TIMEOUT" "$@"; else "$@"; fi
}

# manifests_find_size SIZE: translate the config's rsync-flavoured maxFileSize
# ("8m") into find's flavour ("8M"). They must agree or the TOOBIG report
# names files rsync actually copied, or misses files it dropped.
manifests_find_size() {
  local s=${1,,}
  case "$s" in
    *k) printf '%sk' "${s%k}" ;;
    *m) printf '%sM' "${s%m}" ;;
    *g) printf '%sG' "${s%g}" ;;
    *)  printf '%sc' "$s" ;;      # bare digits are bytes in the config, 'c' in find
  esac
}

# ---------------------------------------------------------------------------
# manifests_generate STAGE: write every manifest into STAGE/manifests.
# Requires lists_load to have run (drift_scan reads COVERED/IGNORED).
manifests_generate() {
  local stage=$1 M="$1/manifests"
  mkdir -p "$M"
  log "Generating manifests"

  # ---- packages ----------------------------------------------------------
  # An upgrade in progress holds the pacman db lock; the query fails, and the
  # carry-forward loop below keeps yesterday's list rather than committing an
  # empty one.
  if have pacman; then
    pacman -Qqen > "$M/pacman-native.txt" 2>/dev/null || {
      warn "pacman query failed (upgrade in progress?); carrying the previous package list forward"
      : > "$M/pacman-native.txt"
    }
    pacman -Qqem > "$M/pacman-aur.txt" 2>/dev/null || : > "$M/pacman-aur.txt"
  else
    printf '(pacman unavailable)\n' > "$M/pacman-native.txt"
    printf '(pacman unavailable)\n' > "$M/pacman-aur.txt"
  fi

  # Install provenance. A bare package list tells you WHAT but never WHY; an
  # install date per explicit package lets future-you reconstruct intent.
  # Append-only, so daily diffs stay small.
  : > "$M/install-history.tsv"
  if [[ -r /var/log/pacman.log ]]; then
    grep -E '\[ALPM\] installed' /var/log/pacman.log 2>/dev/null \
      | sed -E 's/^\[([0-9T:+-]+)\].*installed ([^ ]+) \((.*)\)$/\1\t\2\t\3/' \
      > "$M/install-history.tsv" || true
  fi

  # ---- services ----------------------------------------------------------
  : > "$M/systemd-user.txt"; : > "$M/systemd-system.txt"; : > "$M/systemd-user-off.txt"
  if have systemctl; then
    systemctl --user list-unit-files --state=enabled --no-legend > "$M/systemd-user.txt" 2>/dev/null || true
    systemctl        list-unit-files --state=enabled --no-legend > "$M/systemd-system.txt" 2>/dev/null || true
    # Units you deliberately turned OFF. Without this, `restore --services`
    # happily re-enables something you disabled on purpose.
    systemctl --user list-unit-files --state=disabled,masked --no-legend > "$M/systemd-user-off.txt" 2>/dev/null || true
  fi

  # ---- identity and desktop ---------------------------------------------
  id -nG > "$M/groups.txt" 2>/dev/null || printf '(none)\n' > "$M/groups.txt"
  if have dconf; then
    manifests_bounded dconf dump / > "$M/dconf.txt" 2>/dev/null || printf '(dconf unavailable)\n' > "$M/dconf.txt"
  else
    printf '(dconf unavailable)\n' > "$M/dconf.txt"
  fi
  # "enabled since <date>" changes on every cupsd restart and would produce a
  # commit with no config change in it (same class as drift and versions).
  if have lpstat; then
    { lpstat -p 2>/dev/null | sed 's/  *enabled since .*//'; lpstat -v 2>/dev/null; } > "$M/printers.txt" \
      || printf '(no printers)\n' > "$M/printers.txt"
  else
    printf '(no printers)\n' > "$M/printers.txt"
  fi
  # Timezone and locale live nowhere else in the repo: /etc/localtime is a
  # symlink into the tzdata tree and is not a pacman backup file, so the drift
  # scan never sees it.
  if have timedatectl; then
    timedatectl show -p Timezone --value > "$M/timezone.txt" 2>/dev/null || printf 'unknown\n' > "$M/timezone.txt"
  else
    printf 'unknown\n' > "$M/timezone.txt"
  fi
  if have localectl; then
    localectl status > "$M/locale.txt" 2>/dev/null || printf 'unknown\n' > "$M/locale.txt"
  else
    printf 'unknown\n' > "$M/locale.txt"
  fi
  if have fprintd-list; then
    manifests_bounded fprintd-list "${USER:-$(id -un)}" 2>/dev/null | tail -n +2 > "$M/fingerprint.txt" \
      || printf '(none)\n' > "$M/fingerprint.txt"
  else
    printf '(none)\n' > "$M/fingerprint.txt"
  fi
  # Connection NAMES only. The files under /etc/NetworkManager/system-connections
  # hold WiFi PSKs and WireGuard private keys and are never copied anywhere.
  if have nmcli; then
    manifests_bounded nmcli -t -f NAME,TYPE con show > "$M/network.txt" 2>/dev/null || printf '(nmcli unavailable)\n' > "$M/network.txt"
  else
    printf '(nmcli unavailable)\n' > "$M/network.txt"
  fi

  # ---- toolchains that live only on this disk ---------------------------
  if have code; then
    manifests_bounded code --list-extensions > "$M/vscode-extensions.txt" 2>/dev/null || printf '(code CLI unavailable)\n' > "$M/vscode-extensions.txt"
  else
    printf '(code CLI unavailable)\n' > "$M/vscode-extensions.txt"
  fi
  if have uv; then
    uv tool list 2>/dev/null | grep -v '^- ' > "$M/uv-tools.txt" || printf '(uv unavailable)\n' > "$M/uv-tools.txt"
  else
    printf '(uv unavailable)\n' > "$M/uv-tools.txt"
  fi
  if have npm; then
    manifests_bounded npm ls -g --depth=0 --parseable 2>/dev/null | tail -n +2 | xargs -rn1 basename | grep -vx npm > "$M/npm-global.txt" \
      || printf '(npm unavailable)\n' > "$M/npm-global.txt"
  else
    printf '(npm unavailable)\n' > "$M/npm-global.txt"
  fi

  # ---- omarchy plugins ---------------------------------------------------
  {
    echo "# omarchy plugin clones: id <TAB> remote <TAB> pinned rev"
    local d
    for d in "$HOME"/.config/omarchy/plugins/*/; do
      [[ -d "$d/.git" ]] || continue
      printf '%s\t%s\t%s\n' "$(basename "$d")" \
        "$(git -C "$d" remote get-url origin 2>/dev/null || true)" \
        "$(git -C "$d" rev-parse --short HEAD 2>/dev/null || true)"
    done
  } > "$M/omarchy-plugins.tsv"
  if have omarchy; then
    manifests_bounded omarchy plugin list --json > "$M/omarchy-plugins.json" 2>/dev/null || printf '[]\n' > "$M/omarchy-plugins.json"
  else
    printf '[]\n' > "$M/omarchy-plugins.json"
  fi

  # ---- stock fingerprint -------------------------------------------------
  # Omarchy's own defaults are a moving target; on restore this says whether
  # upstream drifted since the snapshot. LC_ALL=C must match whatever compares
  # it later, or a restore under a different locale falsely reports movement.
  # MUST be generated ABOVE the carry-forward loop: it used to sit below it, so
  # the loop tested a file that did not exist yet and warned "could not be
  # regenerated" on every single run while guarding nothing (self-test 43).
  : > "$M/stock-fingerprint.txt"
  if [[ -d "$STOCK_DIR/config" ]]; then
    find "$STOCK_DIR/config" -type f -exec sha256sum {} + 2>/dev/null \
      | LC_ALL=C sort -k2 > "$M/stock-fingerprint.txt" || true
  fi

  # ---- carry-forward guard ----------------------------------------------
  local mf
  for mf in "${MANIFESTS_CARRIED[@]}"; do
    if is_placeholder "$M/$mf" && [[ -s "$DATA_REPO/manifests/$mf" ]] && ! is_placeholder "$DATA_REPO/manifests/$mf"; then
      warn "$mf could not be regenerated; keeping the previous copy"
      cp "$DATA_REPO/manifests/$mf" "$M/$mf"
    fi
  done

  # ---- versions ----------------------------------------------------------
  # No timestamp anywhere in here on purpose: an unchanged system must produce
  # a byte-identical file, or every run commits (self-test 4, idempotency).
  {
    echo "# capture time is the git commit date; no timestamp here, so an"
    echo "# unchanged system produces an identical file and therefore no commit."
    echo "host: $(uname -n)"
    echo "kernel: $(uname -r)"
    echo
    echo "## omarchy packages"
    if have pacman; then pacman -Q omarchy omarchy-settings omarchy-keyring 2>/dev/null || true; fi
    echo
    echo "## os-release"
    cat /etc/os-release 2>/dev/null || true
  } > "$M/versions.txt"

  manifests_drift "$stage"
}

# manifests_drift STAGE: write STAGE/manifests/drift.txt from drift_scan and
# fold in the TOOBIG lines snapshot_stage left behind. Sets MAN_DRIFT_PREV to
# the actionable lines of the PREVIOUS committed report -- manifests/ has not
# been synced yet, so the repo copy still holds the last run's output, and the
# "is this drift new?" comparison has to be taken here, before it moves.
manifests_drift() {
  local M="$1/manifests"
  # Same filter as snapshot_drift_finish's "new_drift", GONE included: the two
  # are the operands of one comm, so they have to select the same line classes.
  MAN_DRIFT_PREV=$(grep -hE "$DRIFT_CLASSES" "$DATA_REPO/manifests/drift.txt" 2>/dev/null | sort || true)
  # stderr lands in the report on purpose: a scan that dies partway through
  # must leave its reason where a human reading drift.txt will find it. The
  # missing sentinel is what the pipeline actually refuses on.
  drift_scan > "$M/drift.txt" 2>&1 || true
  if [[ -s "$M/.toobig" ]]; then cat "$M/.toobig" >> "$M/drift.txt"; fi
  rm -f "$M/.toobig"
}

# manifests_drift_counts FILE: set DRIFT_N, TOOBIG_N and EXCLUDED_N from a
# drift report. GONE, TOOBIG and EXCLUDED lines are appended to that file by
# the pipeline after the scan itself has run, so the counting has to be a
# separate pass over the finished file rather than part of the generator.
manifests_drift_counts() {
  DRIFT_N=0; TOOBIG_N=0; EXCLUDED_N=0
  [[ -f "$1" ]] || return 0
  # ERROR rows are faults, not paths to triage, and health counts them that
  # way; this count used to include them, so `snapshot --json` and `status
  # --json` gave two drift_counts for one report (Codex, PR 13).
  DRIFT_N=$( { grep -E "$DRIFT_CLASSES" "$1" 2>/dev/null || true; } | grep -cv '^# ERROR' || true)
  TOOBIG_N=$(grep -c '^TOOBIG' "$1" 2>/dev/null || true)
  EXCLUDED_N=$(grep -c '^EXCLUDED' "$1" 2>/dev/null || true)
  DRIFT_N=${DRIFT_N:-0}; TOOBIG_N=${TOOBIG_N:-0}; EXCLUDED_N=${EXCLUDED_N:-0}
}
