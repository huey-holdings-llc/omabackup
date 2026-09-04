#!/usr/bin/env bash
# Allowlist and drift-ignore predicates. Sourced by bin/omabackup; never
# executed. Ported from hp-laptop-config/bin/drift.sh, which figured these
# semantics out the hard way: read the comments before changing the matching.
# shellcheck shell=bash

shopt -s nullglob

# lists_load: fill COVERED (from allowlist.txt) and IGNORED (from
# drift-ignore.txt), expanding allowlist globs against $HOME.
lists_load() {
  COVERED=()
  local e p _oldifs
  while IFS= read -r e; do
    [ -z "$e" ] && continue
    # Strip the '?' optional marker used by snapshot.sh, or these entries look
    # uncovered and every optional (plugin-owned) path is reported as drift.
    case "$e" in \?*) e="${e#\?}" ;; esac
    _oldifs=$IFS; IFS=$'\n'
    for p in $HOME/$e; do COVERED+=("${p#$HOME/}"); done
    IFS=$_oldifs
    COVERED+=("$e")
  done < <(read_list "$DATA_REPO/allowlist.txt")

  IGNORED=()
  while IFS= read -r e; do [ -n "$e" ] && IGNORED+=("$e"); done < <(read_list "$DATA_REPO/drift-ignore.txt")
}

# Is $1 covered by, or inside, any allowlist entry?
is_covered() {
  local q="$1" c
  for c in "${COVERED[@]}"; do
    [ "$q" = "$c" ] && return 0
    case "$q" in "$c"/*) return 0 ;; esac
  done
  return 1
}

# Ignore semantics, deliberately NOT prefix matching.
#
# This used to prefix-match like is_covered() does, which meant a directory
# entry silenced its entire subtree FOREVER, including files that did not exist
# when the decision was made. That is how five hand-written systemd units went
# unbacked while this script reported "clean", the exact fail-open shape this
# tool exists to prevent.
#
#   .config/foo        ignores that path exactly (and matches as a glob)
#   .config/foo/**     ignores the whole subtree, opted into explicitly
#
# Use /** only when you mean "nothing under here will ever matter".
# Only /** entries mean "nothing under here will ever matter". A bare entry
# suppresses the directory itself but its CHILDREN must still be checked,
# without this, a bare .config/omarchy entry hid every new file omarchy adds.
is_ignored_subtree() {
  local q="$1" c base
  for c in "${IGNORED[@]}"; do
    case "$c" in
      */'**')
        base="${c%/\*\*}"
        [ "$q" = "$base" ] && return 0
        case "$q" in "$base"/*) return 0 ;; esac
        ;;
    esac
  done
  return 1
}

# True when SOME child of $1 is allowlisted but $1 itself is not. This is
# derived from allowlist.txt rather than hand-maintained: previously every
# partially-covered directory needed a matching drift-ignore line, so adding one
# config was a two-file edit and 18 ignore entries existed only to say
# "only some children here are kept".
is_partially_covered() {
  local q="$1" c
  for c in "${COVERED[@]}"; do
    case "$c" in "$q"/*) return 0 ;; esac
  done
  return 1
}

is_ignored() {
  local q="$1" c base
  for c in "${IGNORED[@]}"; do
    case "$c" in
      */'**')
        base="${c%/\*\*}"
        [ "$q" = "$base" ] && return 0
        case "$q" in "$base"/*) return 0 ;; esac
        ;;
      *)
        [ "$q" = "$c" ] && return 0
        # shellcheck disable=SC2254 # unquoted on purpose so wildcards work
        case "$q" in $c) return 0 ;; esac
        ;;
    esac
  done
  return 1
}
