#!/usr/bin/env bash
# Disposable fixture for the Task 5 V3/V4/V6 live-fire spike
# (docs/pr-review-threads-live-findings.md). Not called by anything. Safe to
# delete once the spike PR is closed.
set -uo pipefail

# padding to shift line numbers so the existing review thread's anchored
# line becomes stale without touching the underlying issue
echo "padding line 1"
echo "padding line 2"
echo "padding line 3"

user_input="$1"
eval "echo $user_input"

# trigger: enforce-mode run for V3/V4/V6 spike
