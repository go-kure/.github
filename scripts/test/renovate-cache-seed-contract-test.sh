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

# cache_lines FILE — the key: and path: lines of every actions/cache step, trimmed.
# A step starts at a "- name:" line and counts as a cache step once its uses: line
# names actions/cache.
cache_lines() {
  awk '
    /^ *- name:/ { in_cache = 0 }
    /^ *uses: actions\/cache\// { in_cache = 1 }
    in_cache && /^ *(key|path): / { sub(/^ */, ""); print }
  ' "$1"
}

# contract CI_FILE SEED_FILE — print one FAIL line per broken fact, return 1 if any.
contract() {
  local ci="$1" seed="$2" rc=0 lines f
  for f in "$ci" "$seed"; do
    if [ ! -s "$f" ]; then
      echo "FAIL: $f is missing or empty"
      return 1
    fi
  done
  # Every actions/cache step (restore and save) in both files carries a key and a
  # path, read whatever their value is. All of them together must hold exactly one
  # distinct key and one distinct path.
  for f in "$ci" "$seed"; do
    if ! cache_lines "$f" | grep -q '^key: '; then
      echo "FAIL: no cache key in $f"
      rc=1
    fi
    if ! cache_lines "$f" | grep -q '^path: '; then
      echo "FAIL: no cache path in $f"
      rc=1
    fi
  done
  lines="$(for f in "$ci" "$seed"; do cache_lines "$f"; done | grep '^key: ' | sort -u | wc -l)"
  if [ "$lines" -gt 1 ]; then
    echo "FAIL: the cache key differs between ci.yml and the seed workflow ($lines distinct keys)"
    rc=1
  fi
  lines="$(for f in "$ci" "$seed"; do cache_lines "$f"; done | grep '^path: ' | sort -u | wc -l)"
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
expect_fail "a seed path that differs" "cache path differs" "$CI" "$tmp/seed-path"

# Only the save step changes: the restore step still agrees, which a check that
# selects entries by their expected value would miss.
sed '/actions\/cache\/save@/,$ s/key: renovate-lane-test-/key: renovate-seed-/' "$SEED" > "$tmp/seed-savekey"
expect_fail "a seed save key that differs" "cache key differs" "$CI" "$tmp/seed-savekey"

sed '/actions\/cache\/save@/,$ s#path: \.renovate-lane-test$#path: .renovate-seed#' "$SEED" > "$tmp/seed-savepath"
expect_fail "a seed save path that differs" "cache path differs" "$CI" "$tmp/seed-savepath"

sed '/actions\/cache\/save@/,$ s/key: renovate-lane-test-/key: renovate-seed-/' "$CI" > "$tmp/ci-savekey"
expect_fail "a ci.yml save key that differs" "cache key differs" "$tmp/ci-savekey" "$SEED"

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
