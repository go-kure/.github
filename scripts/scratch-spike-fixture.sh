#!/usr/bin/env bash
# Disposable fixture for the Task 5 V3/V4/V6 live-fire spike
# (docs/pr-review-threads-live-findings.md). Not called by anything. Safe to
# delete once the spike PR is closed.
set -uo pipefail

user_input="$1"
eval "echo $user_input"

# trigger: enforce-mode run for V3/V4/V6 spike
