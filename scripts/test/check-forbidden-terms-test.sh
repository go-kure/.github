#!/usr/bin/env bash
# check-forbidden-terms-test.sh — fixture tests for scripts/check-forbidden-terms.sh.
#
# Pins the pragma check against a context window larger than a pipe buffer. The
# checker once fed that window to `grep -q` through a pipe under pipefail: grep
# exited on its first match, the writer then hit the closed pipe, and a covered
# hit was reported FORBIDDEN — intermittently, depending on scheduling. A >64 KiB
# line next to the hit makes that failure deterministic.
#
# The downstream term is assembled at runtime so this file carries no hit of its
# own for the repo's full-tree scan.
#
# Usage: check-forbidden-terms-test.sh [REPO_ROOT]

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
CHECKER="$ROOT/scripts/check-forbidden-terms.sh"

TERM_WORD="cra""ne"
CAMEL_WORD="Cra""ne"

failures=0
pass_count=0

# Runs the checker in --full-tree mode against a throwaway git repo holding one
# tracked notes.md with the given content. Invoked via `bash "$CHECKER"` so the
# fixture never depends on the checker's executable bit. Echoes the exit code.
run_fixture() {
  local content="$1" dir rc
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  printf '%s\n' "$content" > "$dir/notes.md"
  git -C "$dir" add notes.md
  (cd "$dir" && bash "$CHECKER" --full-tree >/dev/null 2>&1)
  rc=$?
  rm -rf "$dir"
  echo "$rc"
}

# Same, in --diff mode: notes.md is committed empty, then given the content as an
# uncommitted change, so every content line is an added line versus HEAD.
run_diff_fixture() {
  local content="$1" dir rc
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  : > "$dir/notes.md"
  git -C "$dir" add notes.md
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q --no-verify -m base
  printf '%s\n' "$content" > "$dir/notes.md"
  (cd "$dir" && bash "$CHECKER" --diff HEAD >/dev/null 2>&1)
  rc=$?
  rm -rf "$dir"
  echo "$rc"
}

assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected rc=$expected, got rc=$actual" >&2
    failures=$((failures + 1))
  fi
}

LONG_LINE="$(head -c 300000 /dev/zero | tr '\0' 'x')"

assert_rc "a covered hit passes" 0 \
  "$(run_fixture "$(printf 'see the %s operator # allow-term:%s' "$TERM_WORD" "$TERM_WORD")")"

assert_rc "an uncovered hit fails" 1 \
  "$(run_fixture "$(printf 'see the %s operator' "$TERM_WORD")")"

assert_rc "a covered hit next to a >64 KiB line passes" 0 \
  "$(run_fixture "$(printf 'see the %s operator # allow-term:%s\n%s' "$TERM_WORD" "$TERM_WORD" "$LONG_LINE")")"

assert_rc "an uncovered hit next to a >64 KiB line fails" 1 \
  "$(run_fixture "$(printf 'see the %s operator\n%s' "$TERM_WORD" "$LONG_LINE")")"

assert_rc "a pragma on the line above covers the hit" 0 \
  "$(run_fixture "$(printf '# allow-term:%s\nsee the %s operator\n%s' "$TERM_WORD" "$TERM_WORD" "$LONG_LINE")")"

assert_rc "a pragma for one term does not cover another on the same line" 1 \
  "$(run_fixture "$(printf 'the %s and the %s # allow-term:%s' "$TERM_WORD" "bar""ge" "$TERM_WORD")")"

# A term that starts a camelCase segment inside an identifier has no word boundary
# around it, so the whole-word rule alone lets it through.
assert_rc "a camelCase segment after a lowercase letter fails" 1 \
  "$(run_fixture "$(printf 'func stale%sProfile() {}' "$CAMEL_WORD")")"

assert_rc "a camelCase segment ending an identifier fails" 1 \
  "$(run_fixture "$(printf 'func TestFoo_Matches%s(t *testing.T) {}' "$CAMEL_WORD")")"

assert_rc "a camelCase segment after a digit fails" 1 \
  "$(run_fixture "$(printf 'var v2%sClient = nil' "$CAMEL_WORD")")"

assert_rc "a segment after an underscore fails" 1 \
  "$(run_fixture "$(printf 'func TestFoo_%s(t *testing.T) {}' "$CAMEL_WORD")")"

assert_rc "a pragma covers a camelCase hit" 0 \
  "$(run_fixture "$(printf 'func stale%sProfile() {} // allow-term:%s' "$CAMEL_WORD" "$TERM_WORD")")"

assert_rc "a pragma for another term does not cover a camelCase hit" 1 \
  "$(run_fixture "$(printf 'func stale%sProfile() {} // allow-term:%s' "$CAMEL_WORD" "bar""ge")")"

assert_rc "a pragma for the first of two adjacent camelCase terms does not cover the second" 1 \
  "$(run_fixture "$(printf 'func stale%s%sProfile() {} // allow-term:%s' "$CAMEL_WORD" "Bar""ge" "$TERM_WORD")")"

assert_rc "a capitalised term in prose still fails" 1 \
  "$(run_fixture "$(printf '%s is the operator.' "$CAMEL_WORD")")"

# The segment must be exactly the term, as the whole word must be in prose.
assert_rc "a longer camelCase segment starting with the term passes" 0 \
  "$(run_fixture "$(printf 'func new%ssList() {}' "$CAMEL_WORD")")"

assert_rc "a lowercase term inside a word passes" 0 \
  "$(run_fixture "$(printf 'var x%sx = 1' "$TERM_WORD")")"

assert_rc "diff mode flags an added camelCase hit" 1 \
  "$(run_diff_fixture "$(printf 'func stale%sProfile() {}' "$CAMEL_WORD")")"

assert_rc "diff mode passes an added line without a hit" 0 \
  "$(run_diff_fixture "func staleProfile() {}")"

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
