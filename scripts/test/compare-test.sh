#!/usr/bin/env bash
# compare-test.sh — tests for scripts/eval/compare.sh's comparability gates.
#
# Usage: compare-test.sh [REPO_ROOT]

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)" || { echo "no such directory: ${1:-.}" >&2; exit 2; }
COMPARE="$ROOT/scripts/eval/compare.sh"
[ -f "$COMPARE" ] || { echo "not found: $COMPARE" >&2; exit 2; }

failures=0
pass_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected [$expected], got [$actual]" >&2
    failures=$((failures + 1))
  fi
}

assert_match() {
  local desc="$1" pattern="$2" actual="$3"
  if [[ "$actual" == *"$pattern"* ]]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected to find [$pattern] in [$actual]" >&2
    failures=$((failures + 1))
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/compare-test.XXXXXX")" \
  || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# A complete, comparable pair — every gate this file checks must pass on this base before any
# single field is mutated to prove that field's own gate, or a broken base would pass every case
# vacuously.
base_common='{"gold_tree":"t1","standards_sha":"s1","context_sha":"c1","assess":true,
  "excluded_per_run":[[],[],[]],"denominator_stable":true}'

write_result() {
  # write_result FILE ENGINE MEAN_R SPREAD [EXTRA_JQ_FILTER]
  local file="$1" engine="$2" mean_r="$3" spread="$4" extra="${5:-.}"
  jq -c --arg engine "$engine" --argjson mean_r "$mean_r" --argjson spread "$spread" \
    ". + {engine: \$engine, mean_r: \$mean_r, spread: \$spread} | $extra" \
    <<<"$base_common" > "$file"
}

# --- happy path: both stable, candidate wins by more than combined spread ---
write_result "$WORK/baseline.json" chat 0.50 0.02
write_result "$WORK/candidate.json" service 0.60 0.02
out="$(bash "$COMPARE" "$WORK/baseline.json" "$WORK/candidate.json")"
rc=$?
assert_eq "happy path: exit 0 (candidate wins)" "0" "$rc"
assert_match "happy path: verdict names the winner" "service beats chat" "$out"

# --- denominator_stable missing from one side: refused, not silently treated as stable ---
write_result "$WORK/baseline.json" chat 0.50 0.02
write_result "$WORK/candidate.json" service 0.60 0.02 'del(.denominator_stable)'
out="$(bash "$COMPARE" "$WORK/baseline.json" "$WORK/candidate.json" 2>&1)"
rc=$?
assert_eq "missing denominator_stable: exit 2 (usage/comparability error)" "2" "$rc"
assert_match "missing denominator_stable: names the field" "denominator_stable is missing" "$out"

# --- denominator_stable false on the baseline: refused even though excluded_per_run matches ---
#
# This is the exact case the equality gate above cannot catch (go-kure/.github#179 problem 3):
# both sides show the identical excluded_per_run pattern, so that gate alone would pass a
# spread that is partly a judge failure on one side.
write_result "$WORK/baseline.json" chat 0.50 0.02 \
  '.excluded_per_run = [[],["doc.json"],[]] | .denominator_stable = false'
write_result "$WORK/candidate.json" service 0.60 0.02 \
  '.excluded_per_run = [[],["doc.json"],[]] | .denominator_stable = false'
out="$(bash "$COMPARE" "$WORK/baseline.json" "$WORK/candidate.json" 2>&1)"
rc=$?
assert_eq "unstable baseline: exit 2, not a passed verdict" "2" "$rc"
assert_match "unstable baseline: names the reason" "denominator_stable is false" "$out"

# --- denominator_stable false on the candidate only: still refused ---
write_result "$WORK/baseline.json" chat 0.50 0.02
write_result "$WORK/candidate.json" service 0.60 0.02 '.denominator_stable = false'
out="$(bash "$COMPARE" "$WORK/baseline.json" "$WORK/candidate.json" 2>&1)"
rc=$?
assert_eq "unstable candidate: exit 2, not a passed verdict" "2" "$rc"
assert_match "unstable candidate: names the reason" "denominator_stable is false" "$out"

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
