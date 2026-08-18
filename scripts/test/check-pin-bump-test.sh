#!/usr/bin/env bash
# check-pin-bump-test.sh — fixture tests for scripts/check-pin-bump.sh, run
# against a throwaway git repo so real commits/diffs exercise the checker
# instead of mocking git.
#
# Usage: check-pin-bump-test.sh [REPO_ROOT]

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
CHECKER="$ROOT/scripts/check-pin-bump.sh"

failures=0
pass_count=0

assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected rc=$expected, got rc=$actual" >&2
    failures=$((failures + 1))
  fi
}

SHA_A="1111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222"

new_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "test@example.invalid"
  git -C "$dir" config user.name "Test"
  echo "$dir"
}

workflow_with_pin() {
  local sha="$1"
  cat <<EOF
jobs:
  pr-review:
    steps:
      - uses: go-kure/.github/.github/actions/pr-review-threads@${sha} # main
EOF
}

# Fixture 1: bootstrap — base has no pin line at all, delegate code changes.
dir="$(new_repo)"
mkdir -p "$dir/.github/workflows" "$dir/.github/actions/pr-review-threads"
echo "placeholder" > "$dir/.github/workflows/pr-review.yml"
git -C "$dir" add -A && git -C "$dir" commit -q -m base
git -C "$dir" branch -q base_marker
workflow_with_pin "$SHA_A" > "$dir/.github/workflows/pr-review.yml"
echo "name: x" > "$dir/.github/actions/pr-review-threads/action.yml"
git -C "$dir" add -A && git -C "$dir" commit -q -m "add action"
(cd "$dir" && bash "$CHECKER" base_marker) >/dev/null 2>&1
assert_rc "bootstrap: no prior pin on base -> OK" "0" "$?"
rm -rf "$dir"

# Fixture 2: delegate code untouched -> OK regardless of pin state.
dir="$(new_repo)"
mkdir -p "$dir/.github/workflows" "$dir/.github/actions/pr-review-threads" "$dir/scripts"
workflow_with_pin "$SHA_A" > "$dir/.github/workflows/pr-review.yml"
echo "name: x" > "$dir/.github/actions/pr-review-threads/action.yml"
echo "unrelated" > "$dir/scripts/other.sh"
git -C "$dir" add -A && git -C "$dir" commit -q -m base
git -C "$dir" branch -q base_marker
echo "unrelated change" >> "$dir/scripts/other.sh"
git -C "$dir" add -A && git -C "$dir" commit -q -m "unrelated"
(cd "$dir" && bash "$CHECKER" base_marker) >/dev/null 2>&1
assert_rc "no delegate change -> OK" "0" "$?"
rm -rf "$dir"

# Fixture 3: delegate code changed, pin NOT bumped -> FAIL.
dir="$(new_repo)"
mkdir -p "$dir/.github/workflows" "$dir/.github/actions/pr-review-threads"
workflow_with_pin "$SHA_A" > "$dir/.github/workflows/pr-review.yml"
echo "name: x" > "$dir/.github/actions/pr-review-threads/action.yml"
git -C "$dir" add -A && git -C "$dir" commit -q -m base
git -C "$dir" branch -q base_marker
echo "name: x changed" > "$dir/.github/actions/pr-review-threads/action.yml"
git -C "$dir" add -A && git -C "$dir" commit -q -m "change action, forget pin"
(cd "$dir" && bash "$CHECKER" base_marker) >/dev/null 2>&1
assert_rc "delegate changed, pin unchanged -> FAIL" "1" "$?"
rm -rf "$dir"

# Fixture 4: delegate code changed, pin bumped -> OK.
dir="$(new_repo)"
mkdir -p "$dir/.github/workflows" "$dir/.github/actions/pr-review-threads"
workflow_with_pin "$SHA_A" > "$dir/.github/workflows/pr-review.yml"
echo "name: x" > "$dir/.github/actions/pr-review-threads/action.yml"
git -C "$dir" add -A && git -C "$dir" commit -q -m base
git -C "$dir" branch -q base_marker
echo "name: x changed" > "$dir/.github/actions/pr-review-threads/action.yml"
workflow_with_pin "$SHA_B" > "$dir/.github/workflows/pr-review.yml"
git -C "$dir" add -A && git -C "$dir" commit -q -m "change action, bump pin"
(cd "$dir" && bash "$CHECKER" base_marker) >/dev/null 2>&1
assert_rc "delegate changed, pin bumped -> OK" "0" "$?"
rm -rf "$dir"

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
