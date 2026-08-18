#!/usr/bin/env bash
# SCRATCH — live-spike V6 (go-kure/.github#60/#61 follow-up). Never merged;
# this PR exists only to observe AI Code Review enforce-mode behavior and is
# closed unmerged when the spike is done.
set -uo pipefail

run_user_command() {
  local user_input="$1"
  case "$user_input" in
    status|version) "$user_input" ;;
    *) echo "unsupported command: $user_input" >&2; return 1 ;;
  esac
}

run_user_command "$1"
