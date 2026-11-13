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

# The only variables the prompt prose may expand besides the two example lines, by name. Both hold a
# full object id printed by git rev-parse, never the text of a ref or of the base input: REVIEW_BASE
# comes from `git rev-parse --verify "<input>^{commit}"` or `<rev>^`, and head_oid from
# `git rev-parse HEAD`. Hex digits cannot spell the word, so neither value can carry it into the
# prompt. A new variable in the prompt makes the reader refuse with exit 2, and the fix is to list
# it here after reading how its value is set.
PROMPT_VARS='REVIEW_BASE head_oid'

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# render WORKFLOW
# Prints the reviewer-facing prompt, one line per line, each prefixed "E:" when it comes from an
# example body and "P:" when it is the prompt's own prose. The prefix is what lets the check tell a
# header inside an example from a header-shaped line in the prose. Exit 2 when anything is missing.
#
# The reader must see the prompt as bash builds it. The decision for each shape it can receive:
#   - closer missing, renamed, indented or followed by a space: reject (exit 2). Bash needs the
#     delimiter alone on its line, so no prompt is built.
#   - a delimiter line in the middle of the prose: reject. The closer must be followed by the line
#     )" that ends the step's substitution, so an early closer is not taken for the last one.
#   - backslash-newline in the prompt: join. Bash joins the two lines, and an even run of
#     backslashes is an escaped backslash, so only an odd run joins.
#   - an expansion other than the two example lines and the names in PROMPT_VARS ($name form only):
#     reject. Its text is unknown here, and the braces form counts as unknown.
#   - an escaped dollar sign, backtick or backslash (\$, \` or \\): accept as literal text, and
#     remove the pair before the expansion test. The pairs go left to right, so \\$(...) is still an
#     expansion.
#   - a bare dollar sign that bash would keep literal ("$ 5"): reject too. Modelling every case where
#     bash expands is the open-ended way; the message tells the author to write \$ instead.
#   - the delimiter word in a comment-shaped or quoted line: accept as prose, as bash does.
#   - a quoted or dash opener (<<'PROMPT', <<-PROMPT): reject. It is not the unquoted heredoc, so no
#     step matches the filter and the suite is aimed wrong.
#   - CRLF line endings: accept. yq reads CRLF as LF, so the shape does not reach this reader, and a
#     case holds that fact.
#   - the example bodies are quoted heredocs: no joins and no expansions, read as written. Their
#     closer follows the same rule as the prompt's.
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
  printf '%s\n' "$body" | LC_ALL=C awk -v vars="$PROMPT_VARS" '
    function bad_input(msg) { print msg > "/dev/stderr"; bad = 1 }
    # One prose line of the prompt, after any backslash-newline join. A line that is exactly an example
    # variable stands for that body. A backslash pair (\\, \$ or \`) is literal text, so it goes first,
    # left to right. Any other $ or backtick must then be a listed variable followed by a non-name
    # character: anything else would put text in the prompt that this reader never saw. Only the name
    # is removed, never the character after it, because that character can start the next expansion.
    function emit(line,    t, i, n, v) {
      if (line == "$example_one")   { for (i = 1; i <= no; i++) print "E:" one[i]; ne += no; return }
      if (line == "$example_clean") { for (i = 1; i <= nc; i++) print "E:" clean[i]; ne += nc; return }
      t = line
      gsub(/\\[\\$`]/, "", t)
      n = split(vars, v, " ")
      for (i = 1; i <= n; i++)
        while (match(t, "[$]" v[i] "([^A-Za-z0-9_]|$)"))
          t = substr(t, 1, RSTART - 1) " " substr(t, RSTART + 1 + length(v[i]))
      if (t ~ /[$`]/) bad_input("unsupported expansion in the prompt: " line " (a literal dollar sign or backtick needs a backslash before it)")
      print "P:" line; np++
    }
    expect != "" {
      if ($0 != ")\"") bad_input("the " expect " closing delimiter is not followed by )\" on the next line, so it is not the closer the step ends on")
      expect = ""; next
    }
    mode == "" && /^example_clean="\$\(cat <<'"'"'EXAMPLE'"'"'$/ { mode = "clean"; next }
    mode == "" && /^example_one="\$\(cat <<'"'"'EXAMPLE'"'"'$/   { mode = "one"; next }
    mode == "" && /^prompt="\$\(cat <<PROMPT$/                    { mode = "prompt"; seen = 1; next }
    /^EXAMPLE$/ && (mode == "clean" || mode == "one") { mode = ""; expect = "EXAMPLE"; next }
    /^PROMPT$/ && mode == "prompt" {
      if (pending != "") { emit(pending); pending = "" }
      mode = ""; expect = "PROMPT"; next
    }
    mode == "clean" { clean[++nc] = $0; next }
    mode == "one"   { one[++no] = $0; next }
    mode == "prompt" {
      cur = pending $0; pending = ""
      if (match(cur, /\\+$/) && RLENGTH % 2 == 1) { pending = substr(cur, 1, length(cur) - 1); next }
      emit(cur)
    }
    END {
      if (mode == "prompt") bad_input("the PROMPT heredoc is not closed")
      else if (mode != "")  bad_input("the EXAMPLE heredoc is not closed")
      if (expect != "")     bad_input("the " expect " closing delimiter is the last line, with no )\" after it")
      if (bad || !seen || nc == 0 || no == 0 || ne == 0 || np == 0) exit 2
    }
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

# The reader must read the prompt as bash does. One case per shape the region can receive; the
# decision for each shape (join, reject or accept) is written above the reader in render().
# shellcheck disable=SC1003  # literal backslashes for a sed replacement, not an escaped quote
ONE_BS='\\'
# shellcheck disable=SC1003  # as above: two literal backslashes in the replacement
TWO_BS='\\\\'

# Missing closer: bash cannot build the prompt, so the text is not a prompt this suite can vouch for.
check 'a PROMPT closer that is renamed is refused as unreadable' \
  2 'the PROMPT heredoc is not closed' \
  "$(mutate closer-renamed "s/^\( *\)PROMPT\$/\1PROMPT_RENAMED/")"

check 'a PROMPT closer with leading space is refused as unreadable' \
  2 'the PROMPT heredoc is not closed' \
  "$(mutate closer-indented "s/^\( *\)PROMPT\$/\1  PROMPT/")"

check 'a PROMPT closer with trailing space is refused as unreadable' \
  2 'the PROMPT heredoc is not closed' \
  "$(mutate closer-trailing "s/^\( *\)PROMPT\$/&   /")"

# A line that is exactly the delimiter in the middle ends the heredoc early, in bash and here.
check 'a PROMPT line in the middle of the prose is refused as unreadable' \
  2 'is not followed by' \
  "$(mutate closer-premature "s/^\( *\)${LEAD}\$/&\n\1PROMPT/")"

check 'an example closer that is renamed is refused as unreadable' \
  2 'the EXAMPLE heredoc is not closed' \
  "$(mutate example-closer-renamed "/^ *example_one=/,/^ *EXAMPLE\$/ s/^\( *\)EXAMPLE\$/\1EXAMPLE_RENAMED/")"

# Backslash-newline: the unquoted heredoc joins the two lines, so the word can be split across them.
check 'a backslash-newline that splits the word across two lines is joined and refused' \
  1 'stray: P: Report each finding as its own block.' \
  "$(mutate continuation-split "s/^\( *\)${LEAD}\$/&\n\1Report each find${ONE_BS}\n\1ing as its own block./")"

# Two backslashes are one escaped backslash, and the newline then stays: no join, nothing to refuse.
check 'an escaped backslash before the newline is not a continuation and joins nothing' \
  0 'stray=0' \
  "$(mutate continuation-escaped "s/^\( *\)${LEAD}\$/&\n\1Report each find${TWO_BS}\n\1ing as its own block./")"

# An expansion the reader does not model puts text in the prompt that it never saw.
check 'an example variable inside a prose line is refused as unreadable' \
  2 'unsupported expansion in the prompt' \
  "$(mutate expansion-example-inline "s/^\( *\)${LEAD}\$/&\n\1See \$example_clean here./")"

check 'a command substitution in the prose is refused as unreadable' \
  2 'unsupported expansion in the prompt' \
  "$(mutate expansion-command "s/^\( *\)${LEAD}\$/&\n\1Report \$(printf fin%s ding) now./")"

check 'a backtick command in the prose is refused as unreadable' \
  2 'unsupported expansion in the prompt' \
  "$(mutate expansion-backtick "s/^\( *\)${LEAD}\$/&\n\1Report \`printf finding\` now./")"

check 'a variable the suite does not list is refused as unreadable' \
  2 'unsupported expansion in the prompt' \
  "$(mutate expansion-unlisted "s/^\( *\)${LEAD}\$/&\n\1Report \$OTHER_VAR now./")"

# A listed variable is removed, but the text next to it is not: an expansion that follows it stays seen.
check 'a command substitution right after a listed variable is refused as unreadable' \
  2 'unsupported expansion in the prompt' \
  "$(mutate expansion-adjacent "s/^\( *\)${LEAD}\$/&\n\1Report \$REVIEW_BASE\$(printf fin%s ding) now./")"

# A backslash escapes the dollar sign and the backtick in an unquoted heredoc, so the text is literal.
check 'an escaped dollar sign is literal text and passes' \
  0 'stray=0' \
  "$(mutate escaped-dollar "s/^\( *\)${LEAD}\$/&\n\1Report ${ONE_BS}\$5 now./")"

check 'an escaped backtick is literal text and passes' \
  0 'stray=0' \
  "$(mutate escaped-backtick "s/^\( *\)${LEAD}\$/&\n\1Report ${ONE_BS}\`x${ONE_BS}\` now./")"

# A bare dollar sign that bash keeps literal is still refused, with the way out in the message.
check 'a bare dollar sign is refused as unreadable and the message names the backslash' \
  2 'needs a backslash before it' \
  "$(mutate bare-dollar "s/^\( *\)${LEAD}\$/&\n\1Report the cost \$ 5 now./")"

# Two backslashes are one escaped backslash, and the dollar sign after them is a live expansion.
check 'an escaped backslash before a command substitution is still refused as unreadable' \
  2 'unsupported expansion in the prompt' \
  "$(mutate escaped-backslash-expansion "s/^\( *\)${LEAD}\$/&\n\1Report ${TWO_BS}\$(printf fin%s ding) now./")"

# The delimiter word on a line of its own shape is prose, in bash too: nothing to refuse.
check 'the delimiter word inside a comment-shaped or quoted line is prose and passes' \
  0 'stray=0' \
  "$(mutate delimiter-as-prose "s/^\( *\)${LEAD}\$/&\n\1# PROMPT\n\1\"PROMPT\"/")"

# A quoted opener is a different heredoc (no expansion): the suite is aimed at the unquoted one only.
check 'a quoted PROMPT opener is refused as unreadable' \
  2 'found 0 steps' \
  "$(mutate opener-quoted "s/<<PROMPT\$/<<'PROMPT'/")"

# yq reads CRLF text as LF, so the shape cannot reach the reader. If a later yq keeps the CR, the
# delimiter lines stop matching and this case turns red.
check 'a workflow with CRLF line endings reads as the same prompt' \
  0 'stray=0' \
  "$(mutate crlf 's/$/\r/')"

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
broken_wf="$(mutate heredoc-broken-live 's/^\( *\)prompt="\$(cat <<PROMPT$/\1prompt="$(cat <<PROMPT_RENAMED/')"
broken_rc=0
broken_out=
# Exit 2 alone is not enough: a mutant that was never built also ends in exit 2, from the missing
# workflow file. So the case needs the mutant built and copied, and the script's own message.
if [ -n "$broken_wf" ] && cp "$broken_wf" "$broken_root/.github/workflows/review-pool-acceptance.yml"; then
  broken_out=$(bash "$0" "$broken_root" 2>&1) || broken_rc=$?
else
  broken_rc=built-no
fi
if [ "$broken_rc" = 2 ] && printf '%s' "$broken_out" | grep -qF 'the prompt could not be rendered'; then
  PASS=$((PASS + 1))
  printf 'PASS  an unreadable live prompt makes this script exit 2\n'
else
  FAIL=$((FAIL + 1))
  printf 'FAIL  an unreadable live prompt makes this script exit %s, want 2 with its own message: %s\n' "$broken_rc" "$broken_out"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
