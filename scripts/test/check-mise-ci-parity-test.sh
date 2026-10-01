#!/usr/bin/env bash
# check-mise-ci-parity-test.sh — fixture tests for scripts/check-mise-ci-parity.sh.
#
# Each case builds a throwaway repo with a minimal mise.toml and ci.yml and
# asserts the checker's exit code and the FAIL line it prints. An unreadable or
# empty side must exit 2, never pass: a parity check that compares two empty
# lists agrees with everything.
#
# Usage: check-mise-ci-parity-test.sh [REPO_ROOT]

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
CHECKER="$ROOT/scripts/check-mise-ci-parity.sh"

failures=0
pass_count=0

# write_fixture DIR MISE_LINT MISE_TESTS CI_LINT CI_TESTS
# MISE_LINT/CI_LINT: the shellcheck argument string ("" omits the line).
# MISE_TESTS/CI_TESTS: space-separated suite paths, one bash line each.
write_fixture() {
  local dir="$1" mise_lint="$2" mise_tests="$3" ci_lint="$4" ci_tests="$5" t
  mkdir -p "$dir/.github/workflows"
  {
    echo '[tasks."lint:shell"]'
    if [ -n "$mise_lint" ]; then
      echo "run = \"shellcheck $mise_lint\""
    else
      echo 'run = "true"'
    fi
    echo
    echo '[tasks.test]'
    echo 'run = """'
    for t in $mise_tests; do echo "bash $t ."; done
    echo 'node scripts/test/other.mjs'
    echo '"""'
  } > "$dir/mise.toml"
  {
    echo 'name: CI'
    echo 'on: [push]'
    echo 'jobs:'
    echo '  smoke:'
    echo '    runs-on: ubuntu-latest'
    echo '    steps:'
    echo '      - uses: actions/checkout@v4'
    if [ -n "$ci_lint" ]; then
      echo '      - name: shellcheck'
      echo "        run: shellcheck $ci_lint"
    fi
    for t in $ci_tests; do
      echo "      - name: suite $t"
      echo "        run: bash $t ."
    done
    echo '      - name: multi-line step'
    echo '        run: |'
    echo '          echo unrelated'
  } > "$dir/.github/workflows/ci.yml"
}

# run_case DESC EXPECTED_RC EXPECTED_SUBSTRING CHECKER_PATH FIXTURE_ARGS...
run_case() {
  local desc="$1" want_rc="$2" want_out="$3" checker="$4" dir out rc
  shift 4
  dir="$(mktemp -d)"
  write_fixture "$dir" "$@"
  out="$(bash "$checker" "$dir" 2>&1)"
  rc=$?
  rm -rf "$dir"
  if [ "$rc" != "$want_rc" ]; then
    echo "FAIL: $desc — expected rc=$want_rc, got rc=$rc; output: $out" >&2
    failures=$((failures + 1))
    return
  fi
  if [ -n "$want_out" ] && ! grep -qF -- "$want_out" <<< "$out"; then
    echo "FAIL: $desc — output lacks '$want_out'; output: $out" >&2
    failures=$((failures + 1))
    return
  fi
  pass_count=$((pass_count + 1))
}

L='scripts/a.sh scripts/b.sh'
T='scripts/test/a-test.sh scripts/test/b-test.sh'

run_case "identical lists pass" 0 "OK (lint 2 paths, test 2 suites)" "$CHECKER" \
  "$L" "$T" "$L" "$T"
run_case "order and shellcheck flags do not matter" 0 "OK" "$CHECKER" \
  "$L" "$T" "-x scripts/b.sh scripts/a.sh" "scripts/test/b-test.sh scripts/test/a-test.sh"
run_case "script shellchecked only by mise fails" 1 "FAIL: lint: scripts/c.sh is only in mise.toml lint:shell" "$CHECKER" \
  "$L scripts/c.sh" "$T" "$L" "$T"
run_case "script shellchecked only by CI fails" 1 "FAIL: lint: scripts/c.sh is only in ci.yml shellcheck" "$CHECKER" \
  "$L" "$T" "$L scripts/c.sh" "$T"
run_case "suite run only by mise fails" 1 "FAIL: test: scripts/test/c-test.sh is only in mise.toml test" "$CHECKER" \
  "$L" "$T scripts/test/c-test.sh" "$L" "$T"
run_case "suite run only by CI fails" 1 "FAIL: test: scripts/test/c-test.sh is only in ci.yml" "$CHECKER" \
  "$L" "$T" "$L" "$T scripts/test/c-test.sh"
run_case "no shellcheck line in CI is fatal, not a pass" 2 "no shellcheck paths found in" "$CHECKER" \
  "$L" "$T" "" "$T"
run_case "no shellcheck paths in mise is fatal" 2 "no shellcheck paths found" "$CHECKER" \
  "" "$T" "$L" "$T"
run_case "no test suites in mise is fatal" 2 "no scripts/test/*-test.sh suite found in" "$CHECKER" \
  "$L" "" "$L" "$T"

# run_raw DESC EXPECTED_RC EXPECTED_SUBSTRING MISE_TOML CI_YML — literal file
# contents, for shapes write_fixture cannot produce.
run_raw() {
  local desc="$1" want_rc="$2" want_out="$3" dir out rc
  dir="$(mktemp -d)"
  mkdir -p "$dir/.github/workflows"
  printf '%s\n' "$4" > "$dir/mise.toml"
  printf '%s\n' "$5" > "$dir/.github/workflows/ci.yml"
  out="$(bash "$CHECKER" "$dir" 2>&1)"
  rc=$?
  rm -rf "$dir"
  if [ "$rc" != "$want_rc" ]; then
    echo "FAIL: $desc — expected rc=$want_rc, got rc=$rc; output: $out" >&2
    failures=$((failures + 1))
    return
  fi
  if [ -n "$want_out" ] && ! grep -qF -- "$want_out" <<< "$out"; then
    echo "FAIL: $desc — output lacks '$want_out'; output: $out" >&2
    failures=$((failures + 1))
    return
  fi
  pass_count=$((pass_count + 1))
}

MISE_STD='[tasks."lint:shell"]
run = "shellcheck scripts/a.sh scripts/b.sh"

[tasks.test]
run = """
bash scripts/test/a-test.sh .
bash scripts/test/b-test.sh .
"""'

ci_with() {  # ci_with STEP_LINES... — a ci.yml whose one job has these step lines
  printf '%s\n' 'name: CI' 'on: [push]' 'jobs:' '  smoke:' '    runs-on: ubuntu-latest' '    steps:' "$@"
}

CI_LINT_STEP='      - run: shellcheck scripts/a.sh scripts/b.sh'
CI_A_STEP='      - run: bash scripts/test/a-test.sh .'
CI_B_STEP='      - run: bash scripts/test/b-test.sh .'

run_raw "option values and a ./ prefix do not create paths; a non-leading shellcheck word is ignored" 0 \
  "OK (lint 2 paths" "$MISE_STD" \
  "$(ci_with '      - run: |' '          sudo install -m755 /tmp/x /usr/local/bin/shellcheck' \
     '          shellcheck -s bash -x ./scripts/b.sh scripts/a.sh' "$CI_A_STEP" "$CI_B_STEP")"
run_raw "an option value is not a checked path" 1 \
  "FAIL: lint: scripts/b.sh is only in mise.toml lint:shell" "$MISE_STD" \
  "$(ci_with '      - run: shellcheck -P scripts/b.sh scripts/a.sh' "$CI_A_STEP" "$CI_B_STEP")"
run_raw "an --option=value is read, and its value is not a checked path" 1 \
  "FAIL: lint: scripts/b.sh is only in mise.toml lint:shell" "$MISE_STD" \
  "$(ci_with '      - run: shellcheck --source-path=scripts/b.sh scripts/a.sh' "$CI_A_STEP" "$CI_B_STEP")"
run_raw "a trailing option value on the last line still passes" 0 "OK (lint 2 paths" "$MISE_STD" \
  "$(ci_with "$CI_A_STEP" "$CI_B_STEP" '      - run: shellcheck scripts/a.sh scripts/b.sh -s bash')"
run_raw "a commented-out suite in CI does not count as run" 1 \
  "FAIL: test: scripts/test/b-test.sh is only in mise.toml test" "$MISE_STD" \
  "$(ci_with "$CI_LINT_STEP" "$CI_A_STEP" '      - run: |' '          # bash scripts/test/b-test.sh .' '          true')"
run_raw "a suite shellchecked in CI is not mistaken for a suite CI runs" 1 \
  "FAIL: test: scripts/test/b-test.sh is only in mise.toml test" "$MISE_STD" \
  "$(ci_with '      - run: shellcheck scripts/a.sh scripts/b.sh scripts/test/b-test.sh' "$CI_A_STEP")"

# Every line the checker cannot read with certainty is refused (rc 2), one form
# per case so that no form can hide behind another.
refused() {  # refused DESC CI_STEP_LINES... — a CI with these steps added must exit 2
  local desc="$1"
  shift
  run_raw "$desc is refused" 2 "/.github/workflows/ci.yml: " "$MISE_STD" \
    "$(ci_with "$CI_LINT_STEP" "$CI_A_STEP" "$@")"
}
refused "bash -e before a suite" '      - run: bash -e scripts/test/b-test.sh .'
refused "a ./ suite invocation" '      - run: ./scripts/test/b-test.sh .'
refused "a quoted suite path" "      - run: bash 'scripts/test/b-test.sh' ."
refused "a suite that is only mentioned" '      - run: echo scripts/test/b-test.sh'
# Block scalars below: in a plain YAML scalar ` #` starts a YAML comment, so the
# text after it would never reach the step's run.
refused "a suite line with a trailing comment" '      - run: |' '          bash scripts/test/b-test.sh . # nightly'
refused "a suite after a quoted #" '      - run: |' "          printf '%s\\n' 'issue #123'; bash scripts/test/b-test.sh ."
refused "a suite chained after shellcheck" \
  '      - run: shellcheck scripts/a.sh scripts/b.sh && bash scripts/test/b-test.sh .'
refused "a quoted shellcheck path" "      - run: shellcheck \"scripts/b.sh\""
refused "a comment on a shellcheck line" '      - run: |' '          shellcheck scripts/a.sh # scripts/c.sh'
refused "an unknown shellcheck option" '      - run: shellcheck --made-up scripts/c.sh'
refused "a shellcheck option missing its value" '      - run: shellcheck scripts/c.sh -s'
# The trailing '\' in the next fixtures is a literal shell continuation inside
# the generated ci.yml, not an attempted quote escape.
# shellcheck disable=SC1003
refused "a suite line continuing a previous line" \
  '      - run: |' '          env FOO=1 \' '          bash scripts/test/b-test.sh .'
# shellcheck disable=SC1003
refused "a suite line after a comment ending in a backslash" \
  '      - run: |' '          # note \' '          bash scripts/test/b-test.sh .'
# shellcheck disable=SC1003
refused "a shellcheck line continued onto the next" \
  '      - run: |' '          shellcheck scripts/a.sh \' '            scripts/c.sh' "$CI_B_STEP"
# shellcheck disable=SC1003
refused "a shellcheck line continuing a previous line" \
  '      - run: |' '          env FOO=1 \' '          shellcheck scripts/a.sh scripts/b.sh' "$CI_B_STEP"
run_raw "the mise side refuses the same forms" 2 "mise.toml [tasks.test]" \
  "${MISE_STD/bash scripts\/test\/b-test.sh ./bash -e scripts/test/b-test.sh .}" \
  "$(ci_with "$CI_LINT_STEP" "$CI_A_STEP" "$CI_B_STEP")"

# working-directory makes a textual path name a different file: refused at
# every level it can be set.
run_raw "a step working-directory is refused" 2 "sets working-directory" "$MISE_STD" \
  "$(ci_with "$CI_LINT_STEP" "$CI_A_STEP" "$CI_B_STEP" '        working-directory: other-checkout')"
run_raw "a job default working-directory is refused" 2 "sets working-directory" "$MISE_STD" \
  "$(printf '%s\n' 'name: CI' 'on: [push]' 'jobs:' '  smoke:' '    runs-on: ubuntu-latest' \
     '    defaults:' '      run:' '        working-directory: other-checkout' '    steps:' \
     "$CI_LINT_STEP" "$CI_A_STEP" "$CI_B_STEP")"
run_raw "a workflow default working-directory is refused" 2 "sets working-directory" "$MISE_STD" \
  "$(printf '%s\n' 'name: CI' 'on: [push]' 'defaults:' '  run:' '    working-directory: other-checkout' \
     'jobs:' '  smoke:' '    runs-on: ubuntu-latest' '    steps:' "$CI_LINT_STEP" "$CI_A_STEP" "$CI_B_STEP")"

# Opt-out: a copy of the checker with one entry in PARITY_OPT_OUT.
optdir="$(mktemp -d)"
sed 's|^PARITY_OPT_OUT=()$|PARITY_OPT_OUT=("lint:scripts/test/c-test.sh")|' "$CHECKER" > "$optdir/checker.sh"
if grep -q '^PARITY_OPT_OUT=("lint:scripts/test/c-test.sh")$' "$optdir/checker.sh"; then
  run_case "opted-out one-sided script passes" 0 "OPT-OUT: lint: scripts/test/c-test.sh (only in mise.toml lint:shell)" "$optdir/checker.sh" \
    "$L scripts/test/c-test.sh" "$T" "$L" "$T"
  run_case "opt-out is per pair: the same path in test still fails" 1 "FAIL: test: scripts/test/c-test.sh" "$optdir/checker.sh" \
    "$L" "$T scripts/test/c-test.sh" "$L" "$T"
else
  echo "FAIL: could not inject an opt-out entry — PARITY_OPT_OUT=() line changed shape" >&2
  failures=$((failures + 1))
fi
rm -rf "$optdir"

# The repository itself must hold parity.
if out="$(bash "$CHECKER" "$ROOT" 2>&1)"; then
  pass_count=$((pass_count + 1))
else
  echo "FAIL: this repository's own mise.toml and ci.yml differ: $out" >&2
  failures=$((failures + 1))
fi

echo "check-mise-ci-parity-test: $pass_count passed, $failures failed"
[ "$failures" -eq 0 ]
