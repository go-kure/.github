#!/usr/bin/env bash
# review-pool-record-test.sh — the acceptance record carries what the run measured, not what it was
# allowed.
#
# review-run writes two numbers into provider.json: `seconds`, the budget the caller passed with
# --seconds, and `wall_seconds`, the measured duration. A record that took `seconds` stated 1500.0
# for runs of 3.889 and 10.979 seconds. A ceiling read as elapsed time always overstates, so every
# conclusion drawn from it is the alarming one, and two records of different runs could not be told
# apart by it.
#
# The step body is read out of the workflow rather than retyped here, so this suite tests the file
# CI will run. A retyped copy passes while the workflow is wrong.
#
# Usage: review-pool-record-test.sh [REPO_ROOT]
# Exit:  0 every case passed; 1 a case failed; 2 the step body could not be read.
# Needs: yq v4, jq, bash.

set -uo pipefail

ROOT="${1:-.}"
WF="$ROOT/.github/workflows/review-pool-acceptance.yml"

if [ ! -f "$WF" ]; then
  echo "cannot read the acceptance workflow at $WF" >&2
  exit 2
fi

if ! BODY=$(yq -r \
  '.jobs.review.steps[] | select(.name == "Write the acceptance record") | .run' "$WF"); then
  # A failed parse can still print a body on stdout, so the content checks below would accept it and
  # the suite would test a fragment of a file yq could not read as a whole.
  echo "yq failed to read $WF; the step body is not trustworthy" >&2
  exit 2
fi

# An absent step and an empty one produce the same empty string, so refuse rather than report zero
# failures over nothing.
if [ -z "${BODY//[[:space:]]/}" ] || [ "$BODY" = "null" ]; then
  echo "read no record step body from $WF" >&2
  exit 2
fi

PASS=0
FAIL=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# record CASE PROVIDER_JSON
# Runs the step body over a provider.json holding PROVIDER_JSON and prints the provider field of the
# record it wrote, parsed back to JSON. The field is a string holding JSON, so a case reads it with
# fromjson. The run id is the control: a record that was never written cannot carry it.
record() {
  local dir="$WORK/$1"
  mkdir -p "$dir/out"
  printf '%s\n' "$2" > "$dir/out/provider.json"
  env -i PATH="$PATH" HOME="$HOME" \
    RECORD_DIR="$dir" OUT_DIR="$dir/out" GITHUB_STEP_SUMMARY="$dir/summary.md" \
    GITHUB_REPOSITORY=go-kure/.github GITHUB_RUN_ID="run-$1" REVIEW_BACKEND=claude \
    REVIEW_SANDBOX=bwrap REVIEW_RUN_RC=0 RUNNER_TEMP="$dir" \
    bash -c "$BODY" > "$dir/step.out" 2>&1 || { cat "$dir/step.out" >&2; return 1; }
  jq -e --arg id "run-$1" 'select(.run_id == $id) | .provider | fromjson' "$dir/acceptance.json"
}

# check LABEL JQ_FILTER CASE PROVIDER_JSON
# The filter runs over the parsed provider field and must print true.
check() {
  local label="$1" filter="$2" out
  shift 2
  if out=$(record "$@") && [ "$(printf '%s' "$out" | jq -r "$filter")" = "true" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s: provider field was: %s\n' "$label" "$out"
  fi
}

DONE='{"outcome":"completed","reason":null,"backend":"claude","model":"m","seconds":1500.0,"wall_seconds":3.889}'
check 'a completed run records its measured duration, not the budget' \
  '.wall_seconds == 3.889 and (has("seconds") | not)' completed "$DONE"

# A run that never launched has no measured duration. The record must say so, never fall back to the
# budget, which would state a duration for a run that did not run.
FAILED='{"outcome":"launch-failed","reason":"x","backend":"claude","model":null,"seconds":1500.0,"wall_seconds":null}'
check 'a run with no measured duration records null, not the budget' \
  '.wall_seconds == null and (has("seconds") | not)' failed "$FAILED"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
