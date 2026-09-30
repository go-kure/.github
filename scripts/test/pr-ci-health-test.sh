#!/usr/bin/env bash
# pr-ci-health-test.sh — fixture tests for scripts/pr-ci-health.sh. A stub
# `gh` placed first on PATH answers each repo's GraphQL query from a fixture
# file, so the real jq classification and exit-status logic run unmodified.
#
# Usage: pr-ci-health-test.sh [REPO_ROOT]

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
SCRIPT="$ROOT/scripts/pr-ci-health.sh"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — [$needle] not found in output" >&2
    failures=$((failures + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — [$needle] unexpectedly present in output" >&2
    failures=$((failures + 1))
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fixtures"

# The stub answers `gh api graphql ... -F repo=<name>` with
# fixtures/<name>.json, and fails the query when fixtures/<name>.fail exists.
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    -F) shift; case "$1" in repo=*) repo="${1#repo=}" ;; esac ;;
  esac
  shift
done
if [ -e "$PCIH_FIXTURES/$repo.fail" ]; then
  echo "stub gh: simulated GraphQL failure for $repo" >&2
  exit 1
fi
cat "$PCIH_FIXTURES/$repo.json"
EOF
chmod +x "$WORK/bin/gh"

# pr NUMBER IS_DRAFT ROLLUP — ROLLUP is a state string, "null" for a null
# statusCheckRollup, or "nocommit" for an empty commits.nodes list.
pr() {
  local number="$1" draft="$2" rollup="$3"
  case "$rollup" in
    null)
      jq -n --argjson n "$number" --argjson d "$draft" \
        '{number: $n, title: ("PR " + ($n|tostring)), url: ("https://example.invalid/" + ($n|tostring)), isDraft: $d,
          commits: {nodes: [{commit: {statusCheckRollup: null}}]}}' ;;
    nocommit)
      jq -n --argjson n "$number" --argjson d "$draft" \
        '{number: $n, title: ("PR " + ($n|tostring)), url: ("https://example.invalid/" + ($n|tostring)), isDraft: $d,
          commits: {nodes: []}}' ;;
    *)
      jq -n --argjson n "$number" --argjson d "$draft" --arg s "$rollup" \
        '{number: $n, title: ("PR " + ($n|tostring)), url: ("https://example.invalid/" + ($n|tostring)), isDraft: $d,
          commits: {nodes: [{commit: {statusCheckRollup: {state: $s}}}]}}' ;;
  esac
}

# fixture REPO PR_JSON... — writes the GraphQL response for REPO.
fixture() {
  local repo="$1"
  shift
  printf '%s\n' "$@" | jq -s '{data: {repository: {pullRequests: {pageInfo: {hasNextPage: false}, nodes: .}}}}' \
    > "$WORK/fixtures/$repo.json"
}

# run_health REPOS — runs the script in a fresh directory; sets OUT, RC, REPORT.
run_health() {
  local dir
  dir="$(mktemp -d "$WORK/run.XXXXXX")"
  OUT="$(cd "$dir" && PATH="$WORK/bin:$PATH" PCIH_FIXTURES="$WORK/fixtures" \
    GITHUB_ORG=test-org GITHUB_REPOS="$1" bash "$SCRIPT" --ci --json 2>&1)"
  RC=$?
  REPORT="$dir/pr-ci-health-report.json"
}

numbers() {
  jq -c --arg k "$1" '[.[$k][] | .number]' "$REPORT"
}

# Case 1: a mixed repo. Only non-draft PRs count; a null rollup and a missing
# head commit are "no checks"; PENDING and EXPECTED are neither list.
fixture mixed \
  "$(pr 1 false SUCCESS)" \
  "$(pr 2 false FAILURE)" \
  "$(pr 3 false null)" \
  "$(pr 4 true null)" \
  "$(pr 5 true FAILURE)" \
  "$(pr 6 false PENDING)" \
  "$(pr 7 false nocommit)" \
  "$(pr 8 false ERROR)" \
  "$(pr 9 false EXPECTED)"
run_health mixed
assert_eq "mixed: failing PR present -> exit 1" "1" "$RC"
assert_eq "mixed: failing = FAILURE and ERROR non-drafts only" "[2,8]" "$(numbers failing)"
assert_eq "mixed: no_checks = null rollup and missing commit, non-drafts only" "[3,7]" "$(numbers no_checks)"
assert_eq "mixed: no query errors" "[]" "$(jq -c '.query_errors' "$REPORT")"
assert_eq "mixed: report has exactly failing, no_checks, query_errors" \
  '["failing","no_checks","query_errors"]' "$(jq -c 'keys_unsorted' "$REPORT")"
assert_contains "mixed: failing verdict line" "pr-ci-health: 2 open PR(s) with failing/erroring checks" "$OUT"
assert_contains "mixed: no-checks warning line" \
  "WARNING: pr-ci-health: 2 open PR(s) with no checks reported on the head commit (not counted as failing)" "$OUT"
assert_contains "mixed: no-checks PR listed" "mixed#3  NO_CHECKS  PR 3" "$OUT"
assert_not_contains "mixed: draft with no checks not listed" "mixed#4" "$OUT"

# Case 2: only a PR with no checks — listed, but the exit status stays 0.
fixture quiet "$(pr 10 false SUCCESS)" "$(pr 11 false null)"
run_health quiet
assert_eq "no-checks only: exit 0" "0" "$RC"
assert_eq "no-checks only: failing empty" "[]" "$(numbers failing)"
assert_eq "no-checks only: no_checks lists it" "[11]" "$(numbers no_checks)"
assert_contains "no-checks only: green verdict still printed" "pr-ci-health: 0 open PR(s) with failing/erroring checks" "$OUT"
assert_contains "no-checks only: warning printed" "WARNING: pr-ci-health: 1 open PR(s) with no checks" "$OUT"

# Case 3: everything green — exit 0, both lists empty, no warning.
fixture green "$(pr 20 false SUCCESS)" "$(pr 21 true null)"
run_health green
assert_eq "green: exit 0" "0" "$RC"
assert_eq "green: failing empty" "[]" "$(numbers failing)"
assert_eq "green: no_checks empty" "[]" "$(numbers no_checks)"
assert_not_contains "green: no warning" "WARNING:" "$OUT"

# Case 4: one repo's query fails, another has a PR with no checks — exit 1
# for the coverage gap, and the other repo's no-checks PR is still reported.
touch "$WORK/fixtures/broken.fail"
run_health "broken quiet"
assert_eq "query error: exit 1" "1" "$RC"
assert_eq "query error: repo recorded" '["broken"]' "$(jq -c '.query_errors' "$REPORT")"
assert_eq "query error: other repo's no_checks still reported" "[11]" "$(numbers no_checks)"
assert_contains "query error: coverage line" "1 repo(s) could not be queried" "$OUT"

# The other half of go-kure/.github#175 in this repo: ci.yml's pull_request
# trigger carries no base-branch filter, so a PR stacked on another PR's
# branch gets a CI run. actionlint accepts a `branches: [main]` filter, so
# only this assertion notices one coming back.
CI_YML="$ROOT/.github/workflows/ci.yml"
if command -v yq >/dev/null 2>&1; then
  assert_eq "ci.yml runs on pull_request" "true" "$(yq '.on | has("pull_request")' "$CI_YML")"
  assert_eq "ci.yml pull_request has no branches filter" "none" "$(yq '.on.pull_request.branches // "none"' "$CI_YML")"
  assert_eq "ci.yml pull_request has no branches-ignore filter" "none" "$(yq '.on.pull_request.branches-ignore // "none"' "$CI_YML")"
else
  echo "FAIL: yq is required to check ci.yml's pull_request trigger" >&2
  failures=$((failures + 1))
fi

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
