#!/usr/bin/env bash
# renovate-cache-seed-contract-test.sh — the seed workflow and the test job agree.
#
# .github/workflows/renovate-cache-seed.yml saves the Renovate install cache on
# main so the first run of a pull request can restore it in ci.yml. The change
# is useless if the two keys or paths differ, and every other test stays green
# when they do. This test asserts three facts about the seed workflow:
#   1. its cache key and path equal the ones ci.yml restores,
#   2. its job runs only on refs/heads/main,
#   3. its job has a timeout.
# Each assertion also runs against a mutated copy that must fail, so a check
# that agrees with everything is caught.
#
# Usage: renovate-cache-seed-contract-test.sh [REPO_ROOT]

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
SEED="$ROOT/.github/workflows/renovate-cache-seed.yml"

failures=0
pass_count=0

# contract CI_FILE SEED_FILE — print one FAIL line per broken fact, return 1 if any.
contract() {
  local ci="$1" seed="$2" rc=0 lines f
  for f in "$ci" "$seed"; do
    if [ ! -s "$f" ]; then
      echo "FAIL: $f is missing or empty"
      return 1
    fi
  done
  # Both files must carry a key and a path, and the set of distinct lines across
  # the two files must be one: ci.yml restores and saves, the seed does the same.
  for f in "$ci" "$seed"; do
    if ! grep -qE '^ +key: renovate-lane-test-' "$f"; then
      echo "FAIL: no renovate-lane-test cache key in $f"
      rc=1
    fi
    if ! grep -qE '^ +path: \.renovate-lane-test$' "$f"; then
      echo "FAIL: no cache path .renovate-lane-test in $f"
      rc=1
    fi
  done
  lines="$(cat "$ci" "$seed" | grep -E '^ +key: renovate-lane-test-' | sed 's/^ *//' | sort -u | wc -l)"
  if [ "$lines" -gt 1 ]; then
    echo "FAIL: the cache key differs between ci.yml and the seed workflow ($lines distinct keys)"
    rc=1
  fi
  lines="$(cat "$ci" "$seed" | grep -E '^ +path: \.renovate-lane-test' | sed 's/^ *//' | sort -u | wc -l)"
  if [ "$lines" -gt 1 ]; then
    echo "FAIL: the cache path differs between ci.yml and the seed workflow"
    rc=1
  fi
  if ! grep -qE "^    if: github\.ref == 'refs/heads/main'\$" "$seed"; then
    echo "FAIL: the seed job has no refs/heads/main guard"
    rc=1
  fi
  if ! grep -qE '^    timeout-minutes: [0-9]+$' "$seed"; then
    echo "FAIL: the seed job has no timeout-minutes"
    rc=1
  fi
  return "$rc"
}

expect_pass() {
  local name="$1" out
  shift
  if out="$(contract "$@")"; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $name: expected a pass, got:"
    echo "$out"
    failures=$((failures + 1))
  fi
}

# expect_fail NAME WANTED_TEXT CI SEED
expect_fail() {
  local name="$1" want="$2" out
  shift 2
  if out="$(contract "$@")"; then
    echo "FAIL: $name: expected a failure, got a pass"
    failures=$((failures + 1))
  elif ! printf '%s\n' "$out" | grep -qF -- "$want"; then
    echo "FAIL: $name: expected '$want', got:"
    echo "$out"
    failures=$((failures + 1))
  else
    pass_count=$((pass_count + 1))
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

expect_pass "the real workflows agree" "$CI" "$SEED"

sed 's/node24-/node22-/' "$SEED" > "$tmp/seed-key"
expect_fail "a seed key that differs" "cache key differs" "$CI" "$tmp/seed-key"

sed 's#path: \.renovate-lane-test$#path: .renovate-seed#' "$SEED" > "$tmp/seed-path"
expect_fail "a seed path that differs" "no cache path" "$CI" "$tmp/seed-path"

grep -v "if: github.ref == 'refs/heads/main'" "$SEED" > "$tmp/seed-noguard"
expect_fail "a seed job with no main guard" "no refs/heads/main guard" "$CI" "$tmp/seed-noguard"

sed "s#if: github.ref == 'refs/heads/main'#if: github.ref == 'refs/heads/other'#" "$SEED" > "$tmp/seed-otherguard"
expect_fail "a seed job guarded on another ref" "no refs/heads/main guard" "$CI" "$tmp/seed-otherguard"

grep -v -E '^    timeout-minutes: ' "$SEED" > "$tmp/seed-notimeout"
expect_fail "a seed job with no timeout" "no timeout-minutes" "$CI" "$tmp/seed-notimeout"

: > "$tmp/empty"
expect_fail "an empty seed file" "missing or empty" "$CI" "$tmp/empty"

if [ "$failures" -eq 0 ]; then
  echo "renovate-cache-seed-contract-test: OK ($pass_count cases)"
  exit 0
fi
echo "renovate-cache-seed-contract-test: FAILED ($failures failed, $pass_count passed)"
exit 1
