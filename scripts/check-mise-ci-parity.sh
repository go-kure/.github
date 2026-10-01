#!/usr/bin/env bash
# check-mise-ci-parity.sh — fail when `mise run verify` and CI check different scripts.
#
# AGENTS.md promises that `mise run verify` runs everything CI runs. Both sides
# carry the script lists as literals, so a script added to one list and not the
# other narrows the local check silently while CI stays honest (#208 shipped
# release-state.sh that way; #215). This compares two pairs of lists:
#
#   lint  the .sh paths mise.toml [tasks."lint:shell"] shellchecks
#         vs the .sh paths the `shellcheck` lines in .github/workflows/ci.yml check
#   test  the scripts/test/*-test.sh suites mise.toml [tasks.test] runs
#         vs the scripts/test/*-test.sh suites ci.yml runs
#
# This is not a shell parser. It understands one canonical line form per pair
# and refuses (exit 2) anything else that could change the answer, so an
# unusual line is reported instead of being misread:
#
#   lint  a line whose first word is `shellcheck`, with only plain arguments
#         (flags, option values, paths; no quotes, `;`, `&&`, `#`, `$`, ...).
#         Options are matched against shellcheck's own list: one that takes a
#         value consumes the next token (so `-P dir.sh` adds no path), and an
#         option not on the list is refused. The remaining tokens ending in .sh
#         are the paths. A `shellcheck` that is not the
#         first word of its line is not counted, which can only cause a FAIL,
#         never a false pass.
#   test  a line that is exactly `bash scripts/test/<name>-test.sh`, optionally
#         followed by ` .`. Any other line naming a scripts/test/*-test.sh path
#         (`echo`, `bash -e`, `./`, quoted, a trailing command or comment) is
#         refused, because the check cannot tell whether it runs the suite.
#
# Full-line comments are skipped. A counted line that follows a line ending in
# `\` is refused: it is part of the previous command, not a command of its own.
# Control flow (`if false; then`), heredocs and the like are not evaluated; the
# check guards against a list edited on one side only, not against a step built
# to hide a suite. Other test runners (the renovate lane's node script) are not
# compared.
#
# A ci.yml step or job that sets working-directory makes a textual path name a
# different file, so the check refuses (exit 2) rather than compare it.
#
# A path in only one list of a pair fails, unless PARITY_OPT_OUT below names it
# as "<pair>:<path>". The list starts empty: add an entry only with a comment
# saying why that script is checked on one side only.
#
# Out of scope, deliberately: a script that appears in neither list. That is a
# coverage question, not a parity one, and a single check answering both would
# report the wrong cause.
#
# Usage: check-mise-ci-parity.sh [REPO_ROOT]
# Exit:  0 parity holds; 1 a path is one-sided; 2 a list could not be read.
# Needs: yq v4 (reads mise.toml as TOML and ci.yml as YAML).

set -euo pipefail

ROOT="${1:-.}"
MISE="$ROOT/mise.toml"
CI="$ROOT/.github/workflows/ci.yml"

PARITY_OPT_OUT=()

die() {
  echo "check-mise-ci-parity: $*" >&2
  exit 2
}

[ -f "$MISE" ] || die "missing $MISE"
[ -f "$CI" ] || die "missing $CI"
command -v yq >/dev/null 2>&1 || die "yq not found"

mise_lint_run="$(yq -p toml -o yaml '.tasks."lint:shell".run // ""' "$MISE")" || die "cannot parse $MISE"
mise_test_run="$(yq -p toml -o yaml '.tasks.test.run // ""' "$MISE")" || die "cannot parse $MISE"
ci_runs="$(yq '.jobs[].steps[].run | select(. != null)' "$CI")" || die "cannot parse $CI"
ci_wd="$(yq '[.defaults.run."working-directory", .jobs[].defaults.run."working-directory", .jobs[].steps[]."working-directory"] | map(select(. != null)) | length' "$CI")" \
  || die "cannot parse $CI"
[ "$ci_wd" = 0 ] || die "$CI sets working-directory, so its script paths may not name the files CI checks; refusing to compare"

# classify LABEL — reads shell text on stdin and prints "lint <path>" for each
# path a canonical shellcheck line checks and "test <path>" for each canonical
# suite line. Exits 2 on any line the header says is refused.
classify() {
  local label="$1" line trimmed continued prev_continues=false tok takes_value
  local -a toks
  local suite_re='^bash[[:space:]]+(scripts/test/[A-Za-z0-9._-]+-test\.sh)([[:space:]]+\.)?$'
  while IFS= read -r line || [ -n "$line" ]; do
    continued="$prev_continues"
    prev_continues=false
    [[ "$line" == *\\ ]] && prev_continues=true
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    case "$trimmed" in
      '' | '#'*) continue ;;
    esac
    if [[ "$trimmed" =~ ^shellcheck([[:space:]]|$) ]]; then
      if [ "$continued" = true ] || [ "$prev_continues" = true ]; then
        echo "check-mise-ci-parity: $label: put each shellcheck command on one line of its own: $trimmed" >&2
        return 2
      fi
      read -ra toks <<< "${trimmed#shellcheck}"
      takes_value=false
      for tok in "${toks[@]}"; do
        if ! [[ "$tok" =~ ^[A-Za-z0-9._/=+-]+$ ]]; then
          echo "check-mise-ci-parity: $label: unsupported shellcheck argument '$tok' (plain flags and paths only) in: $trimmed" >&2
          return 2
        fi
        if [ "$takes_value" = true ]; then
          takes_value=false
          continue
        fi
        case "$tok" in
          -a | --check-sourced | -x | --external-sources | --norc | --color | --color=* | -C | -C*) ;;
          -e | --exclude | -f | --format | -i | --include | -o | --enable | -P | --source-path \
            | -s | --shell | -S | --severity | -W | --wiki-link-count | --rcfile)
            takes_value=true ;;
          --exclude=* | --format=* | --include=* | --enable=* | --source-path=* | --shell=* \
            | --severity=* | --wiki-link-count=* | --rcfile=* | --extended-analysis=*) ;;
          -*)
            echo "check-mise-ci-parity: $label: unknown shellcheck option '$tok' (add it to the option list in this script) in: $trimmed" >&2
            return 2
            ;;
          *.sh) echo "lint ${tok#./}" ;;
        esac
      done
      if [ "$takes_value" = true ]; then
        echo "check-mise-ci-parity: $label: shellcheck option without a value in: $trimmed" >&2
        return 2
      fi
    elif [[ "$trimmed" == *scripts/test/*-test.sh* ]]; then
      if [ "$continued" = false ] && [[ "$trimmed" =~ $suite_re ]]; then
        echo "test ${BASH_REMATCH[1]}"
      else
        echo "check-mise-ci-parity: $label: cannot tell whether this line runs a suite; write it as 'bash scripts/test/<name>-test.sh .' on a line of its own: $trimmed" >&2
        return 2
      fi
    fi
  done
  return 0
}

mise_lint_cls="$(printf '%s\n' "$mise_lint_run" | classify "$MISE [tasks.\"lint:shell\"]")" || exit 2
mise_test_cls="$(printf '%s\n' "$mise_test_run" | classify "$MISE [tasks.test]")" || exit 2
ci_cls="$(printf '%s\n' "$ci_runs" | classify "$CI")" || exit 2

mise_lint="$(sed -n 's/^lint //p' <<< "$mise_lint_cls" | sort -u)"
ci_lint="$(sed -n 's/^lint //p' <<< "$ci_cls" | sort -u)"
mise_test="$(sed -n 's/^test //p' <<< "$mise_test_cls" | sort -u)"
ci_test="$(sed -n 's/^test //p' <<< "$ci_cls" | sort -u)"

# An empty side would make every comparison vacuous, so it is fatal, not a pass.
[ -n "$mise_lint" ] || die "no shellcheck paths found in $MISE [tasks.\"lint:shell\"]"
[ -n "$ci_lint" ] || die "no shellcheck paths found in $CI"
[ -n "$mise_test" ] || die "no scripts/test/*-test.sh suite found in $MISE [tasks.test]"
[ -n "$ci_test" ] || die "no scripts/test/*-test.sh suite found in $CI"

opted_out() {
  local key="$1" entry
  for entry in "${PARITY_OPT_OUT[@]+"${PARITY_OPT_OUT[@]}"}"; do
    [ "$entry" = "$key" ] && return 0
  done
  return 1
}

failures=0

# report PAIR SIDE_LABEL PATHS_ONLY_ON_THAT_SIDE
report() {
  local pair="$1" side="$2" paths="$3" path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if opted_out "$pair:$path"; then
      echo "OPT-OUT: $pair: $path (only in $side)"
      continue
    fi
    echo "FAIL: $pair: $path is only in $side"
    failures=$((failures + 1))
  done <<< "$paths"
}

report lint 'mise.toml lint:shell' "$(comm -23 <(printf '%s\n' "$mise_lint") <(printf '%s\n' "$ci_lint"))"
report lint 'ci.yml shellcheck' "$(comm -13 <(printf '%s\n' "$mise_lint") <(printf '%s\n' "$ci_lint"))"
report test 'mise.toml test' "$(comm -23 <(printf '%s\n' "$mise_test") <(printf '%s\n' "$ci_test"))"
report test 'ci.yml' "$(comm -13 <(printf '%s\n' "$mise_test") <(printf '%s\n' "$ci_test"))"

if [ "$failures" -gt 0 ]; then
  echo "check-mise-ci-parity: $failures path(s) checked on one side only — add each to the other list" >&2
  exit 1
fi

printf 'check-mise-ci-parity: OK (lint %d paths, test %d suites)\n' \
  "$(printf '%s\n' "$mise_lint" | wc -l)" "$(printf '%s\n' "$mise_test" | wc -l)"
