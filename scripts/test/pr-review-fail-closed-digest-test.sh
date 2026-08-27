#!/usr/bin/env bash
# pr-review-fail-closed-digest-test.sh — function-level regression tests for
# the classifier/aggregator/render functions in
# scripts/pr-review-fail-closed-digest.sh.
#
# No mocked `gh`/network harness: most functions exercised here are the pure,
# no-network half of the script (classify/build/render/threshold). The live
# network behaviour of pr_digest_find_workflow_id, pr_digest_list_failed_runs
# and pr_digest_get_annotations_for_run is covered by the plan's own oracle
# check instead (run against the real org, compare against known historical
# run ids) — not reproducible here without live GitHub state. The one
# exception is the "fail-closed propagation" check below, which stubs
# gh_api_call to fail and asserts the *process itself* aborts rather than
# looping or returning empty — that's a bash-semantics property, not a live
# API behaviour, and is exactly what shipped broken in this script's first
# version (see that test's own comment).
#
# Usage: pr-review-fail-closed-digest-test.sh [REPO_ROOT]

set -uo pipefail # deliberately not -e: assertions continue past failures to report all of them

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"

# shellcheck source=/dev/null
source "$ROOT/scripts/pr-review-fail-closed-digest.sh"

# The sourced script's own `set -euo pipefail` runs at source time and
# leaks into this shell too (source doesn't sandbox options) — without
# undoing it, the first assertion whose right-hand side returns non-zero
# would abort this whole test script with no error message, well before
# checking the rest (same reasoning as github-settings-test.sh).
set +e

failures=0
pass_count=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $desc"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        failures=$((failures + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "PASS: $desc"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc — expected to find: $needle"
        echo "  in: $haystack"
        failures=$((failures + 1))
    fi
}

# ---- pr_digest_strip_chunk_prefix ----

assert_eq "strips a numeric chunk prefix" \
    "review response was not valid JSON after retry=true" \
    "$(pr_digest_strip_chunk_prefix "chunk 7: review response was not valid JSON after retry=true")"

assert_eq "leaves a message with no chunk prefix unchanged" \
    "no chunk prefix here" \
    "$(pr_digest_strip_chunk_prefix "no chunk prefix here")"

# ---- pr_digest_classify_reason ----

assert_eq "classifies 'not valid JSON' (first attempt)" \
    "not_valid_json" \
    "$(pr_digest_classify_reason "review response was not valid JSON after retry=false, salvage_attempted=true (len=12, empty)")"

assert_eq "classifies 'not valid JSON' (after retry)" \
    "not_valid_json" \
    "$(pr_digest_classify_reason "review response was not valid JSON after retry=true, salvage_attempted=true (len=0, empty)")"

assert_eq "classifies '.findings missing/null/non-array'" \
    "findings_missing" \
    "$(pr_digest_classify_reason ".findings missing/null/non-array, or all rows malformed and dropped")"

assert_eq "classifies transport/proxy failure (first attempt)" \
    "transport_proxy" \
    "$(pr_digest_classify_reason "review call failed (transport/proxy error, exit 1)")"

assert_eq "classifies transport/proxy failure (retry form)" \
    "transport_proxy" \
    "$(pr_digest_classify_reason "review call failed on retry (transport/proxy error, exit 7)")"

assert_eq "does not classify an unrelated message" \
    "" \
    "$(pr_digest_classify_reason "fp=abc123: create failed (HTTP 422, not 422 — no fallback attempted)")"

# ---- pr_digest_classify_annotations ----

titled_event='[{"title": "PR review threads incomplete", "message": "chunk 0: review response was not valid JSON after retry=true, salvage_attempted=true (len=0, empty)"}]'
classify_out="$(pr_digest_classify_annotations "$titled_event")"
assert_eq "an annotation set with the target title+pattern classifies as an event" \
    "true" "$(jq -r '.is_event' <<<"$classify_out")"
assert_eq "...and records the matched reason class" \
    '["not_valid_json"]' "$(jq -c '.reasons' <<<"$classify_out")"

other_untitled='[{"title": "", "message": "Unable to resolve action go-kure/.github@0000000000000000000000000000000000000000, unable to find version"}]'
classify_out="$(pr_digest_classify_annotations "$other_untitled")"
assert_eq "an untitled 'Unable to resolve action' annotation classifies as other failure" \
    "false" "$(jq -r '.is_event' <<<"$classify_out")"
assert_eq "...with no matched reasons" \
    '[]' "$(jq -c '.reasons' <<<"$classify_out")"

same_titled_no_pattern='[{"title": "PR review threads incomplete", "message": "fp=deadbeef: create failed (line-anchored 422 and file-level fallback both rejected)"}, {"title": "PR review threads incomplete", "message": "chunk count mismatch: prt_split_diff reported 3, 2 were iterated"}]'
classify_out="$(pr_digest_classify_annotations "$same_titled_no_pattern")"
assert_eq "a same-titled clean-comment-upsert/chunk-count-mismatch message classifies as other failure" \
    "false" "$(jq -r '.is_event' <<<"$classify_out")"

retry_transport='[{"title": "PR review threads incomplete", "message": "chunk 3: review call failed on retry (transport/proxy error, exit 28)"}]'
classify_out="$(pr_digest_classify_annotations "$retry_transport")"
assert_eq "the retry-transport form classifies as an event too" \
    "true" "$(jq -r '.is_event' <<<"$classify_out")"
assert_eq "...as transport_proxy" \
    '["transport_proxy"]' "$(jq -c '.reasons' <<<"$classify_out")"

mixed_reasons='[{"title": "PR review threads incomplete", "message": "chunk 0: review call failed (transport/proxy error, exit 1)"}, {"title": "PR review threads incomplete", "message": "chunk 1: review call failed on retry (transport/proxy error, exit 1)"}, {"title": "PR review threads incomplete", "message": "chunk 2: .findings missing/null/non-array, or all rows malformed and dropped"}]'
classify_out="$(pr_digest_classify_annotations "$mixed_reasons")"
assert_eq "reason-class grouping dedupes repeated classes across annotations" \
    '["findings_missing","transport_proxy"]' "$(jq -c '.reasons | sort' <<<"$classify_out")"

# ---- pr_digest_threshold_met ----

if pr_digest_threshold_met 2 2; then
    echo "PASS: threshold_met is true when count equals threshold"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: threshold_met should be true when count equals threshold"
    failures=$((failures + 1))
fi

if pr_digest_threshold_met 3 2; then
    echo "PASS: threshold_met is true when count exceeds threshold"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: threshold_met should be true when count exceeds threshold"
    failures=$((failures + 1))
fi

if ! pr_digest_threshold_met 1 2; then
    echo "PASS: threshold_met is false when count is below threshold"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: threshold_met should be false when count is below threshold"
    failures=$((failures + 1))
fi

# ---- pr_digest_build_row ----

run_json='{"id": 32385365058, "html_url": "https://github.com/go-kure/launcher/actions/runs/32385365058", "head_branch": "feature-x", "created_at": "2026-08-20T09:00:00Z", "pull_requests": [{"number": 283}]}'
classify_json='{"is_event": true, "reasons": ["not_valid_json"]}'
row="$(pr_digest_build_row "launcher" "$run_json" "$classify_json")"
assert_eq "build_row carries the run id" "32385365058" "$(jq -r '.run_id' <<<"$row")"
assert_eq "build_row carries the pr number" "283" "$(jq -r '.pr_number' <<<"$row")"
assert_eq "build_row carries the repo" "launcher" "$(jq -r '.repo' <<<"$row")"

run_json_no_pr='{"id": 1, "html_url": "https://example.invalid/1", "head_branch": "b", "created_at": "2026-08-20T09:00:00Z", "pull_requests": []}'
row_no_pr="$(pr_digest_build_row "kure" "$run_json_no_pr" "$classify_json")"
assert_eq "build_row's pr_number is null, not empty string, when pull_requests is empty" \
    "null" "$(jq -r '.pr_number' <<<"$row_no_pr")"

# ---- render shape ----

rows_json="$(jq -c -n --argjson a "$row" --argjson b "$row_no_pr" '[$a, $b]')"

md="$(pr_digest_render_markdown "$rows_json" 3)"
assert_contains "markdown render includes a table header" "$md" "| Repo | Run | PR | Branch"
assert_contains "markdown render includes the PR-less row's run url" "$md" "https://example.invalid/1"
assert_contains "markdown render reports the other-failure count" "$md" "3 other failed run(s)"

empty_md="$(pr_digest_render_markdown '[]' 0)"
assert_contains "markdown render says so when nothing was found" "$empty_md" "No fail-closed pr-review-threads events"

json_out="$(pr_digest_render_json "$rows_json" 24 2 "2026-08-27T00:00:00Z" 3)"
assert_eq "json render reports the affected count" "2" "$(jq -r '.affected_count' <<<"$json_out")"
assert_eq "json render reports threshold_met" "true" "$(jq -r '.threshold_met' <<<"$json_out")"
assert_eq "json render carries the other_failure_count through" "3" "$(jq -r '.other_failure_count' <<<"$json_out")"
assert_eq "json render's reason_summary groups by class" \
    "2" "$(jq -r '.reason_summary.not_valid_json' <<<"$json_out")"

below_threshold_json="$(pr_digest_render_json '[]' 24 2 "2026-08-27T00:00:00Z" 0)"
assert_eq "json render's threshold_met is false below threshold" \
    "false" "$(jq -r '.threshold_met' <<<"$below_threshold_json")"

# ---- fail-closed propagation on a real API failure ----
#
# Regression for a codex round 1 finding: bash disables `set -e` inside
# every command-substitution subshell by default (the non-POSIX
# `inherit_errexit` default), so a `gh_api_call` failure three calls deep
# inside `x="$(pr_digest_find_workflow_id ...)"` fell through into that
# function's own subsequent jq parses on an empty/garbage response and
# looped forever retrying the same failing page — it never reached the exit
# gate this script promises. `shopt -s inherit_errexit` (top of the target
# script) is the fix; this proves it holds, in a FRESH bash process rather
# than this already-`set +e` test shell (needed above to survive sourcing
# the target script, which would otherwise mask exactly the propagation
# behaviour under test here). Bounded by `timeout` so a regression here
# hangs this test for 5s, not forever.
# shellcheck disable=SC2016 # single-quoted on purpose: this is a script
# template for the CHILD `bash -c` process below, not this shell — its `$1`
# must stay literal here and expand only once, inside that child, from the
# positional arg ("$ROOT") passed after `_`.
fail_closed_repro='
source "$1/scripts/pr-review-fail-closed-digest.sh"
gh_api_call() { echo "ERROR: HTTP 401 from GET forced-failure" >&2; return 1; }
GITHUB_ORG="go-kure"
pr_digest_find_workflow_id ".github"
'
timeout 5 bash -c "$fail_closed_repro" _ "$ROOT" >/dev/null 2>&1
fail_closed_rc=$?
assert_eq "a forced gh_api_call failure aborts the whole run (fail-closed), rather than looping or returning empty" \
    "1" "$fail_closed_rc"

# ---- structural: the auth-header wrapper cannot be bypassed ----
#
# gh_api_call is the only permitted call site of the shared api_call
# helper — every other network function in this script must go through it,
# or a call could reach the GitHub API unauthenticated (all three repos are
# public, so an unauthenticated request also returns 200) with nothing here
# to catch it. Counts only bare invocations of the underlying helper: the
# simpler `grep -c 'api_call '` would also match every wrapped call site (a
# literal substring) and never equal 1 once the wrapper is used throughout.
bare_helper_count="$(grep -oE '(gh_)?api_call' "$ROOT/scripts/pr-review-fail-closed-digest.sh" | grep -xc 'api_call')"
assert_eq "the shared API helper is called bare exactly once (inside gh_api_call's own definition)" \
    "1" "$bare_helper_count"

echo ""
echo "pr-review-fail-closed-digest-test: $pass_count passed, $failures failed"
if [ "$failures" -gt 0 ]; then
    exit 1
fi
