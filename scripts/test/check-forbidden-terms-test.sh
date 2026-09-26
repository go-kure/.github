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

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
