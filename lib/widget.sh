#!/usr/bin/env bash
# JSON backend for the bar widget. The panel renders exactly what `status`
# prints; all judgment lives in lib/health.sh, versioned and self-tested with
# the rest of the engine (self-test group 50), never in the widget itself.
# Task 12 adds the write verbs (allow/ignore triage from the popup) here.
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
