#!/usr/bin/env bash
# review-pool-prompt-rule-test.sh — the acceptance prompt names the word FINDING only where the
# parser cannot misread it.
#
# The acceptance workflow hands the reviewer a prompt, and the next step parses the reviewer's body
# with review-findings. That parser refuses a line outside a block header that carries the word
# FINDING, and it refuses the whole body for it. The effect is a correct review recorded as
# unparseable. The acceptance run then fails at the findings.json existence check, two steps from
# the cause. Four wordings of the prompt rule that forbids this were each wrong in a new way, and a
# human reviewer found every one. No existing check reads the prompt's own text.
#
# The property is plain enough to test. After the prompt is rendered, the substring "finding" (any
# case, so a plural counts too) may appear on only three kinds of line:
#   - a block header in one of the two example bodies, "[tag] FINDING — ...";
#   - the completion line of an example body, "REVIEW_COMPLETE: findings=N";
#   - the one rule sentence that names the word, which must be present exactly once.
# The rule is deliberately wider than the parser's own test, as the workflow's comment explains, so
# this check is too: it does not try to name the shapes the parser refuses.
#
# The prompt and both examples are read out of the workflow rather than retyped here, so this suite
# tests the file CI will run. A retyped copy passes while the workflow is wrong. Nothing in the step
# is run: the heredoc bodies are read as text.
#
# What this does not check: that the parser agrees with the property (the parser is not in this
# repository, and the step already runs both examples through it), and that a reviewer obeys the
# prompt. It checks that the prompt itself never writes the shape it forbids.
#
# Usage: review-pool-prompt-rule-test.sh [REPO_ROOT]
# Exit:  0 every case passed; 1 a case failed; 2 the prompt could not be read.
# Needs: yq v4, awk, sed, bash.

set -uo pipefail

ROOT="${1:-.}"
WF="$ROOT/.github/workflows/review-pool-acceptance.yml"

if [ ! -f "$WF" ]; then
  echo "cannot read the acceptance workflow at $WF" >&2
  exit 2
fi

# The step that carries the prompt is the one whose script holds the PROMPT heredoc. Select it by
# that, not by name, and require exactly one: zero and two both mean this suite is aimed wrong.
STEP_FILTER='.jobs.review.steps[] | select((.run // "") | contains("<<PROMPT"))'

# The rule sentence the check pins, as the prompt writes it, and the whole of its line. A line is
# exempt only when it equals this text exactly, so any text added to that line is still checked
# for the word. The live case below fails when the prompt rewords the sentence, and the mutants that
# edit it then stop with exit 2, so a reworded rule needs this line updated with it.
RULE_LINE='Never write the word FINDING anywhere except in a block header, in the position the form'

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# render WORKFLOW
# Prints the reviewer-facing prompt, one line per line, each prefixed "E:" when it comes from an
# example body and "P:" when it is the prompt's own prose. The prefix is what lets the check tell a
# header inside an example from a header-shaped line in the prose. Exit 2 when anything is missing.
render() {
  local wf="$1" count body
  if ! count=$(yq -r "[$STEP_FILTER] | length" "$wf"); then
    echo "yq failed to read $wf; the prompt is not trustworthy" >&2
    return 2
  fi
  if [ "$count" != 1 ]; then
    echo "found $count steps holding a PROMPT heredoc in $wf, want exactly 1" >&2
    return 2
  fi
  if ! body=$(yq -r "$STEP_FILTER | .run" "$wf"); then
    echo "yq failed to read the step body of $wf" >&2
    return 2
  fi
  # The example bodies are quoted heredocs, so they are verbatim. The prompt heredoc is not quoted,
  # and its two example lines stand for the bodies; every other line is printed as it is written.
  printf '%s\n' "$body" | LC_ALL=C awk '
    /^example_clean="\$\(cat <<'"'"'EXAMPLE'"'"'$/ { mode = "clean"; next }
    /^example_one="\$\(cat <<'"'"'EXAMPLE'"'"'$/   { mode = "one"; next }
    /^prompt="\$\(cat <<PROMPT$/                    { mode = "prompt"; seen = 1; next }
    /^EXAMPLE$/ && (mode == "clean" || mode == "one") { mode = ""; next }
    /^PROMPT$/ && mode == "prompt"                  { mode = ""; next }
    mode == "clean" { clean[++nc] = $0; next }
    mode == "one"   { one[++no] = $0; next }
    mode == "prompt" {
      if ($0 == "$example_one")        { for (i = 1; i <= no; i++) print "E:" one[i]; ne += no }
      else if ($0 == "$example_clean") { for (i = 1; i <= nc; i++) print "E:" clean[i]; ne += nc }
      else                             { print "P:" $0; np++ }
    }
    END { if (!seen || nc == 0 || no == 0 || ne == 0 || np == 0) exit 2 }
  '
}

# check_rendered
# Reads the rendered prompt on standard input. Prints one "stray:" line per offending line and then
# one scope line, so a pass states what it looked at. Exit 1 on any stray line, on a rule sentence
# that is not present exactly once, or on a scope with no header or no completion line to compare.
check_rendered() {
  LC_ALL=C awk -v rule="$RULE_LINE" '
    {
      src = substr($0, 1, 1)
      line = substr($0, 3)
    }
    index(tolower(line), "finding") == 0 { next }
    src == "E" && line ~ /^\[(blocking|wording|citation)\] FINDING — / { headers++; next }
    src == "E" && line ~ /^REVIEW_COMPLETE: findings=[0-9]+$/        { completions++; next }
    src == "P" && line == rule {
      rules++; next
    }
    { stray++; print "stray: " src ": " line }
    END {
      printf "scope: headers=%d completions=%d rule_sentences=%d stray=%d\n", headers, completions, rules, stray
      if (rules != 1) {
        print "the rule sentence is present " rules + 0 " times, want exactly 1."
        print "A deliberate rewording of that sentence needs this test updated with it: the whole line is pinned in RULE_LINE, and any text added to that line is checked for the word."
      }
      if (headers < 1 || completions < 1) print "the examples carry no header or no completion line, so the scope is empty"
      exit (stray > 0 || rules != 1 || headers < 1 || completions < 1) ? 1 : 0
    }
  '
}

# evaluate WORKFLOW
# Renders the prompt and checks it. Exit 0 clean, 1 a violation, 2 the prompt could not be read.
evaluate() {
  local rendered rc
  rendered=$(render "$1")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "the prompt could not be rendered from $1 (render exit $rc)"
    return 2
  fi
  printf '%s\n' "$rendered" | check_rendered
}

PASS=0
FAIL=0

# check LABEL WANT_RC WANT_TEXT WORKFLOW
# Both the exit code and a text of the verdict are asserted, so a case cannot pass for the wrong
# reason: a violation and an unreadable prompt are different exit codes with different messages.
check() {
  local label="$1" want_rc="$2" want_text="$3" wf="$4" out rc
  if [ -z "$wf" ]; then
    # A mutant that could not be built prints its own reason on standard error and yields no path.
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s: the mutant for this case was not built\n' "$label"
    return
  fi
  out=$(evaluate "$wf" 2>&1)
  rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want_text"; then
    PASS=$((PASS + 1))
    printf 'PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s: rc=%s want=%s, output: %s\n' "$label" "$rc" "$want_rc" "$out"
  fi
}

# mutate NAME SED_SCRIPT...
# Writes a copy of the workflow with the sed script applied and prints its path. A mutant must be a
# real change, or the case below would pass on an unchanged file, so an identical copy is refused.
mutate() {
  local name="$1" out="$WORK/$1.yml"
  shift
  sed "$@" "$WF" > "$out"
  if cmp -s "$WF" "$out"; then
    echo "mutant $name changed nothing; its sed pattern no longer matches the workflow" >&2
    exit 2
  fi
  printf '%s' "$out"
}


# An unreadable live prompt ends the run with exit 2, as the header says. Left to the cases below it
# would only count as a failed case and exit 1, the same as a violation, and a reader of the exit
# code could not tell "the prompt broke the rule" from "this suite read no prompt".
live_rc=0
evaluate "$WF" > /dev/null 2>&1 || live_rc=$?
if [ "$live_rc" -eq 2 ]; then
  evaluate "$WF" >&2
  exit 2
fi

# The live prompt. It states its scope, so a pass cannot be an empty read.
check 'the live prompt writes the word only in headers, completion lines and its one rule' \
  0 'stray=0' "$WF"
check 'the live prompt states a non-empty scope' \
  0 'rule_sentences=1' "$WF"

# The four earlier wordings were each wrong in a new way. Two of them are rebuilt here as the
# sentence they put in the prompt. Both name the word in lower case in a rule that lists shapes, so
# the rule sentence this check pins is absent and a line outside any header carries the word.
check 'the wording that named a colon, a hyphen and a dash is refused' \
  1 'stray: P: Never write the word finding immediately followed' \
  "$(mutate shapes-wording \
    "s/^\( *\)${RULE_LINE}\$/\1Never write the word finding immediately followed by a colon, a hyphen or a dash on any/")"

check 'the wording that named the shapes in a long syntax rule is refused' \
  1 'stray: P: word finding immediately followed by a colon.' \
  "$(mutate syntax-rule-wording \
    "s/^\( *\)${RULE_LINE}\$/\1One syntax rule, which applies to every line that is not a block header: never write the\n\1word finding immediately followed by a colon./")"

# The rule must be there. A prompt that drops it passes every stray-line test, so it needs its own.
check 'a prompt with no rule sentence is refused' \
  1 'the rule sentence is present 0 times' \
  "$(mutate rule-removed "/^ *${RULE_LINE}\$/d")"

check 'a prompt that states the rule twice is refused' \
  1 'the rule sentence is present 2 times' \
  "$(mutate rule-twice "/^ *${RULE_LINE}\$/p")"

# The rule line is exempt only as a whole. Text added to it, here the word in a clause, is checked
# like any other line, and it also leaves the pinned sentence absent.
check 'text added to the rule line, naming the word, is refused' \
  1 'stray: P: Never write the word FINDING anywhere except in a block header, in the position the form, and report each finding' \
  "$(mutate rule-line-extended "s/^\( *\)${RULE_LINE}\$/&, and report each finding/")"

# The word in an ordinary prose sentence, in each form a later edit could write it.
LEAD='Report in at least one sentence what you checked, including when you find nothing\.'
check 'the word in an ordinary sentence of the prompt is refused' \
  1 'stray: P: Report each finding as its own block.' \
  "$(mutate prose-singular "s/^\( *\)${LEAD}\$/&\n\1Report each finding as its own block./")"

check 'the plural in an ordinary sentence of the prompt is refused' \
  1 'stray: P: Report no findings you cannot point at.' \
  "$(mutate prose-plural "s/^\( *\)${LEAD}\$/&\n\1Report no findings you cannot point at./")"

check 'the word in upper case in an ordinary sentence is refused' \
  1 'stray: P: Report each FINDING as its own block.' \
  "$(mutate prose-upper "s/^\( *\)${LEAD}\$/&\n\1Report each FINDING as its own block./")"

# A header-shaped line is allowed inside an example body and nowhere in the prose, because the
# parser reads a header-shaped line wherever it stands in the reviewer's body.
check 'a header-shaped line in the prose, outside the examples, is refused' \
  1 'stray: P: [blocking] FINDING — x' \
  "$(mutate prose-header "s/^\( *\)${LEAD}\$/&\n\1[blocking] FINDING — x/")"

# The word inside an example body, anywhere but its header.
check 'the word in the sentence of the clean example is refused' \
  1 'stray: E: I read the credential gating' \
  "$(mutate example-sentence 's/and I report no defects\.$/and I report no finding./')"

# The controls on the reader: an unreadable prompt is refused, never passed as clean.
# shellcheck disable=SC2016  # the $( in the sed script is the workflow's own text, not an expansion
check 'a workflow whose PROMPT heredoc is not closed as one is refused as unreadable' \
  2 'could not be rendered' \
  "$(mutate heredoc-broken 's/^\( *\)prompt="\$(cat <<PROMPT$/\1prompt="$(cat <<PROMPT_RENAMED/')"

# The same unreadable prompt as the live workflow, run through this script itself: the exit code is
# 2, not 1, so a reader of the code can tell an unreadable prompt from a broken rule.
broken_root="$WORK/broken-root"
mkdir -p "$broken_root/.github/workflows"
# shellcheck disable=SC2016  # the $( in the sed script is the workflow's own text, not an expansion
cp "$(mutate heredoc-broken-live 's/^\( *\)prompt="\$(cat <<PROMPT$/\1prompt="$(cat <<PROMPT_RENAMED/')" \
  "$broken_root/.github/workflows/review-pool-acceptance.yml"
broken_rc=0
bash "$0" "$broken_root" > /dev/null 2>&1 || broken_rc=$?
if [ "$broken_rc" -eq 2 ]; then
  PASS=$((PASS + 1))
  printf 'PASS  an unreadable live prompt makes this script exit 2\n'
else
  FAIL=$((FAIL + 1))
  printf 'FAIL  an unreadable live prompt makes this script exit %s, want 2\n' "$broken_rc"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
