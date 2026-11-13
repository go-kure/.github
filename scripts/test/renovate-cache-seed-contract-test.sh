#!/usr/bin/env bash
# renovate-cache-seed-contract-test.sh — the seed workflow and the test job agree.
#
# .github/workflows/renovate-cache-seed.yml saves the Renovate install cache on
# main so the first run of a pull request can restore it in ci.yml. The change
# is useless if the two keys or paths differ, and every other test stays green
# when they do. This test asserts these facts about the two workflows:
#   1. the cache key and path of the seed equal the ones ci.yml restores,
#   2. the seed job runs only on refs/heads/main,
#   3. the seed job has a timeout,
#   4. ci.yml never saves the cache (only the seed writes the shared cache),
#   5. the key of both files names the cache period, the 14-day number that
#      makes the key change before the cache server deletes an old object.
# Each assertion also runs against a mutated copy that must fail, so a check
# that agrees with everything is caught.
#
# Usage: renovate-cache-seed-contract-test.sh [REPO_ROOT]

# shellcheck disable=SC2016  # the single-quoted ${{ }} strings are GitHub expressions, not shell
set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
SEED="$ROOT/.github/workflows/renovate-cache-seed.yml"

failures=0
pass_count=0

# cache_lines FILE — the key: and path: lines of every actions/cache step, trimmed.
# A step starts at any list item line ("- name:" or "- uses:") and counts as a
# cache step once its uses: line names actions/cache.
cache_lines() {
  awk '
    /^ *- / { in_cache = 0 }
    /^ *(- +)?uses: actions\/cache\// { in_cache = 1 }
    in_cache && /^ *(key|path): / { sub(/^ */, ""); print }
  ' "$1"
}

# contract CI_FILE SEED_FILE — print one FAIL line per broken fact, return 1 if any.
contract() {
  local ci="$1" seed="$2" rc=0 lines f cache
  for f in "$ci" "$seed"; do
    if [ ! -s "$f" ]; then
      echo "FAIL: $f is missing or empty"
      return 1
    fi
  done
  # Every actions/cache step (restore and save) in both files carries a key and a
  # path, read whatever their value is. All of them together must hold exactly one
  # distinct key and one distinct path.
  # Here-strings, not `cache_lines | grep -q`: grep -q exits on the first match, and
  # under pipefail a writer still writing into the closed pipe fails the test.
  for f in "$ci" "$seed"; do
    cache="$(cache_lines "$f")"
    if ! grep -q '^key: ' <<<"$cache"; then
      echo "FAIL: no cache key in $f"
      rc=1
    fi
    if ! grep -q '^path: ' <<<"$cache"; then
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
  for f in "$ci" "$seed"; do
    cache="$(cache_lines "$f" | grep '^key: ' || true)"
    if grep -vqF -- '-p${{ steps.cache-period.outputs.n }}' <<<"$cache"; then
      echo "FAIL: a cache key in $f does not end in the cache period"
      rc=1
    fi
  done
  if grep -qE '^ *(- +)?uses: actions/cache(/save)?@' "$ci"; then
    echo "FAIL: ci.yml saves the cache; only the seed workflow writes it"
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
  elif ! grep -qF -- "$want" <<<"$out"; then
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

# A save step in ci.yml, with the same key and path, still agrees on both: only
# the fourth fact catches it.
{
  cat "$CI"
  printf '%s\n' \
    '      - name: Save renovate install' \
    '        uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0' \
    '        with:' \
    '          path: .renovate-lane-test' \
    '          key: renovate-lane-test-${{ runner.os }}-${{ runner.arch }}-node24-${{ steps.renovate-pin.outputs.version }}-p${{ steps.cache-period.outputs.n }}'
} > "$tmp/ci-save"
expect_fail "a ci.yml that saves the cache" "ci.yml saves the cache" "$tmp/ci-save" "$SEED"

# The same save step written as a list item that starts with "- uses:", with no
# "- name:" line: the fourth fact must still see it.
{
  cat "$CI"
  printf '%s\n' \
    '      - uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0' \
    '        with:' \
    '          path: .renovate-lane-test' \
    '          key: renovate-lane-test-${{ runner.os }}-${{ runner.arch }}-node24-${{ steps.renovate-pin.outputs.version }}-p${{ steps.cache-period.outputs.n }}'
} > "$tmp/ci-save-dash"
expect_fail "a ci.yml that saves in the - uses: form" "ci.yml saves the cache" "$tmp/ci-save-dash" "$SEED"

# That step with a different key must also reach the key check, which reads every
# cache step whatever the form of its first line.
{
  cat "$SEED"
  printf '%s\n' \
    '      - uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0' \
    '        with:' \
    '          path: .renovate-lane-test' \
    '          key: renovate-seed-other-p${{ steps.cache-period.outputs.n }}'
} > "$tmp/seed-dash-key"
expect_fail "a seed cache step in the - uses: form with another key" "cache key differs" "$CI" "$tmp/seed-dash-key"

# Both files lose the period in every key: they still agree with each other.
sed 's/-p\${{ steps\.cache-period\.outputs\.n }}$//' "$CI" > "$tmp/ci-noperiod"
sed 's/-p\${{ steps\.cache-period\.outputs\.n }}$//' "$SEED" > "$tmp/seed-noperiod"
expect_fail "keys that name no cache period" "does not end in the cache period" "$tmp/ci-noperiod" "$tmp/seed-noperiod"

# Only the seed save key loses the period: the restore key still has it.
sed '/actions\/cache\/save@/,$ s/-p\${{ steps\.cache-period\.outputs\.n }}$//' "$SEED" > "$tmp/seed-saveperiod"
expect_fail "a seed save key with no cache period" "does not end in the cache period" "$CI" "$tmp/seed-saveperiod"

grep -v "if: github.ref == 'refs/heads/main'" "$SEED" > "$tmp/seed-noguard"
expect_fail "a seed job with no main guard" "no refs/heads/main guard" "$CI" "$tmp/seed-noguard"

sed "s#if: github.ref == 'refs/heads/main'#if: github.ref == 'refs/heads/other'#" "$SEED" > "$tmp/seed-otherguard"
expect_fail "a seed job guarded on another ref" "no refs/heads/main guard" "$CI" "$tmp/seed-otherguard"

grep -v -E '^    timeout-minutes: ' "$SEED" > "$tmp/seed-notimeout"
expect_fail "a seed job with no timeout" "no timeout-minutes" "$CI" "$tmp/seed-notimeout"

: > "$tmp/empty"
expect_fail "an empty seed file" "missing or empty" "$CI" "$tmp/empty"

# Control for the here-string matches in contract: a seed with thousands of identical cache
# steps makes cache_lines write far more than a pipe holds. The pipe form must fail on it
# (grep -q exits on the first line, awk gets SIGPIPE, pipefail reports it), which proves the
# case below tests the right thing. The contract must still pass on the same file.
keyline="$(cache_lines "$SEED" | grep '^key: ' | sort -u)"
pathline="$(cache_lines "$SEED" | grep '^path: ' | sort -u)"
{
  cat "$SEED"
  for _ in $(seq 1 3000); do
    printf '      - uses: actions/cache/restore@x\n        with:\n          %s\n          %s\n' "$keyline" "$pathline"
  done
} > "$tmp/seed-many"
cache_lines "$tmp/seed-many" | grep -q '^key: '
pipe_rc=$?
if [ "$pipe_rc" -eq 0 ]; then
  echo "FAIL: control: the pipe form did not fail on a producer over the pipe buffer"
  failures=$((failures + 1))
else
  pass_count=$((pass_count + 1))
  echo "PASS  control: the pipe form fails on a producer over the pipe buffer"
fi
expect_pass "a seed file whose cache lines exceed the pipe buffer" "$CI" "$tmp/seed-many"

if [ "$failures" -eq 0 ]; then
  echo "renovate-cache-seed-contract-test: OK ($pass_count cases)"
  exit 0
fi
echo "renovate-cache-seed-contract-test: FAILED ($failures failed, $pass_count passed)"
exit 1
