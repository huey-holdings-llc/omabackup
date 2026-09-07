#!/usr/bin/env bash
# self-test: run the black-box suite (tests/engine.test.sh) once, so a
# scheduled timer can prove the whole pipeline still works end to end, not
# just that today's individual snapshot succeeded. Sourced by bin/omabackup;
# never executed.
# shellcheck shell=bash

# cmd_self_test [--real]: --real also runs the two REAL-repo groups (21R,
# 31R) against the caller's own configured data repo -- see tests/
# engine.test.sh's own header comment for which groups those are.
#
# Guarded against recursion: tests/engine.test.sh exports OMABACKUP_IN_SUITE=1
# at its own top, so a self-test invoked while a suite is already running (a
# group 00 assertion, or a human running self-test from inside a suite's own
# shell) refuses with a JSON error instead of forking the whole suite again.
cmd_self_test() {
  local real=0 a
  for a in "$@"; do
    case "$a" in
      --real) real=1 ;;
      *) usage_die "self-test: unknown flag '$a'" ;;
    esac
  done
  [[ "${OMABACKUP_IN_SUITE:-0}" != 1 ]] \
    || die "self-test: already running inside a test suite; refusing to run recursively"
  [[ -f "$PLUGIN_DIR/tests/engine.test.sh" ]] || die "tests/engine.test.sh not found in $PLUGIN_DIR"
  OMABACKUP_REAL_REPO=$real OMABACKUP_TEST_TMP="$STATE_DIR/selftest" bash "$PLUGIN_DIR/tests/engine.test.sh"
}
