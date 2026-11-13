#!/usr/bin/env bash
# review-pool-credentials-test.sh — the acceptance run's credential step routes each backend to the
# credential that backend's own binary reads.
#
# The runner renames no credential: it hands its own environment to the backend binary. So the
# credential step is the only place that states which variable each backend needs, and a wrong arm
# is invisible until a dispatch fails on authentication minutes into a review. The step is also
# fail-closed by design, which is the failure mode a test has to pin: an arm that refuses when the
# key is present, and an arm that admits when the key is absent, both pass a smoke test that only
# dispatches the happy path.
#
# The step body is read out of the workflow rather than retyped here, so this suite tests the file
# CI will run. A retyped copy passes while the workflow is wrong, which is the one outcome that
# would make this suite worse than nothing.
#
# Usage: review-pool-credentials-test.sh [REPO_ROOT]
# Exit:  0 every case passed; 1 a case failed; 2 the step body could not be read.
# Needs: yq v4, bash.

set -uo pipefail

ROOT="${1:-.}"
WF="$ROOT/.github/workflows/review-pool-acceptance.yml"

if [ ! -f "$WF" ]; then
  echo "cannot read the acceptance workflow at $WF" >&2
  exit 2
fi

if ! BODY=$(yq -r \
  '.jobs.review.steps[] | select(.name == "Check the backend credential") | .run' "$WF"); then
  # A failed parse can still print a body on stdout, so the content checks below would accept it and
  # the suite would test a fragment of a file yq could not read as a whole. The status is the only
  # thing that distinguishes that from a clean read.
  echo "yq failed to read $WF; the step body is not trustworthy" >&2
  exit 2
fi

# An absent step and an empty one produce the same empty string, so refuse rather than report zero
# failures over nothing. A suite that silently tests an empty body passes forever.
if [ -z "${BODY//[[:space:]]/}" ] || [ "$BODY" = "null" ]; then
  echo "read no credential step body from $WF" >&2
  exit 2
fi

PASS=0
FAIL=0

# run_step BACKEND CLAUDE_KEY OPENAI_KEY ANTHROPIC_KEY [CODEX_KEY]
# Runs the step body with a clean environment holding only what the step itself declares, so a key
# that happens to sit in the caller's environment cannot make a refusal arm pass.
#
# CODEX_KEY is last and defaults to OPENAI_KEY, because the workflow sets both names from one
# secret: a case that does not name it separately gets the pairing the workflow produces, and only
# a case testing one name against the other has to say so.
run_step() {
  env -i PATH="$PATH" \
    REVIEW_BACKEND="$1" \
    CLAUDE_CODE_OAUTH_TOKEN="$2" \
    OPENAI_API_KEY="$3" \
    ANTHROPIC_API_KEY="$4" \
    CODEX_API_KEY="${5-$3}" \
    bash -c "$BODY" 2>&1
}

# check LABEL WANT_RC WANT_TEXT BACKEND CLAUDE OPENAI ANTHROPIC [CODEX]
# Both the exit code and the message are asserted. The code alone cannot tell one refusal from
# another, and every refusal arm here exits 1.
check() {
  local label="$1" want_rc="$2" want_text="$3"
  shift 3
  local out rc
  out=$(run_step "$@")
  rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -qF -- "$want_text" <<<"$out"; then
    PASS=$((PASS + 1))
    printf 'PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s: rc=%s want=%s, output: %s\n' "$label" "$rc" "$want_rc" "$out"
  fi
}

K='test-key-value'

# Each backend with its key present, then the same backend with only that key absent. The second
# case is what proves the arm reads the variable it claims to: an arm testing the wrong variable
# admits a run whose real credential is missing.
check 'claude admits a present token' \
  0 'the claude credential is present' claude "$K" '' ''
check 'claude refuses an empty token' \
  1 'CLAUDE_CODE_OAUTH_TOKEN is empty' claude '' "$K" "$K"

check 'codex admits a present key' \
  0 'the codex credential is present under both names' codex '' "$K" ''
check 'codex refuses an empty key' \
  1 'OPENAI_API_KEY is empty' codex "$K" '' "$K" "$K"

# codex reads two names for one credential, so each name gets its own refusal case. Without them an
# arm that checks only one name admits a run whose other name is empty, and the review then fails on
# authentication minutes in, which is the failure mode this whole suite exists to move forward into
# CI. The two cases differ only in which name is empty, and each asserts its own message, because
# the exit code cannot tell one refusal from the other.
check 'codex refuses an empty CODEX_API_KEY beside a present OPENAI_API_KEY' \
  1 'CODEX_API_KEY is empty' codex '' "$K" '' ''
check 'codex refuses an empty OPENAI_API_KEY beside a present CODEX_API_KEY' \
  1 'OPENAI_API_KEY is empty' codex '' '' '' "$K"

check 'opencode openai admits a present key' \
  0 'the openai credential is present' 'opencode:openai/gpt-5-codex' '' "$K" ''
check 'opencode openai refuses an empty key' \
  1 'OPENAI_API_KEY is empty' 'opencode:openai/gpt-5-codex' "$K" '' "$K"

check 'opencode anthropic admits a present key' \
  0 'the anthropic credential is present' 'opencode:anthropic/claude-opus-5' '' '' "$K"
check 'opencode anthropic refuses an empty key' \
  1 'ANTHROPIC_API_KEY is empty' 'opencode:anthropic/claude-opus-5' "$K" "$K" ''

# An opencode backend naming a provider this organization holds no key for is refused for that
# reason, not reported as an unknown backend: the name is well formed and the key is what is absent.
check 'opencode names an unheld provider' \
  1 'names a provider with no credential here' 'opencode:groq/llama-3' "$K" "$K" "$K"

# The second line of that refusal names the providers the workflow has an arm for. It once said the
# organization held keys for openai and anthropic, and it holds one for openai only
# (go-kure/.github#365), so the line states what the workflow does and not what the organization holds.
check 'the unheld-provider refusal names the arms the workflow has' \
  1 'credential arm for the providers openai and anthropic only' 'opencode:groq/llama-3' "$K" "$K" "$K"

check 'an unknown backend is refused' \
  1 'has no credential in this organization' gemini "$K" "$K" "$K"

# A bare `opencode` carries no provider, so review-run cannot parse it as a backend at all. It must
# reach the catch-all rather than any opencode arm. Without this case an `opencode*` pattern would
# swallow it and the step would report a provider problem for a malformed name.
check 'bare opencode reaches the catch-all' \
  1 'has no credential in this organization' opencode "$K" "$K" "$K"

# --- Which credentials each step is given at all -------------------------------------------------
#
# The cases above test the step body, which decides whether the credential it needs is present. They
# say nothing about which credentials the step is handed, and that is a separate property of the
# workflow: a step's `env:` block is what puts a secret into the process environment.
#
# It matters because the review step runs with the sandbox off and the runner hands its whole
# environment to the backend binary, which reads repository content. A credential in that
# environment that the chosen backend does not need is reachable by anything that content can make
# the backend do, and it buys nothing: no arm of the step body reads it.
#
# This is a static read of the workflow text, not an evaluation. GitHub evaluates the expression and
# nothing here can run that evaluator, so each case compares the expression against the exact text
# the review of this change accepted.
#
# Exact text, and not a search for the backend name, because a condition can name the right backend
# and still be wrong in the one direction that matters. `inputs.backend == 'claude' || inputs.backend
# == 'codex'` mentions `inputs.backend`, contains `'claude'`, and hands the Claude token to a Codex
# review. A substring test passes it. That was the first form of these cases and a reviewer broke
# them exactly that way, so the assertion is equality: the condition, its secret reference and its
# empty fallback, whole.
#
# The cost is that an intentional change to a condition fails here until the expected text is
# updated in the same commit. That is the intended cost. These three expressions decide which
# organization credential reaches a process that reads repository content with the sandbox off, so a
# change to one of them is a change a reviewer should have to see.
#
# What equality still does not give: it cannot tell whether the expression means what it says. Two
# things cover that gap and neither is here. The credential check's own arms, tested above, refuse an
# empty value, so a condition that withholds a credential the backend needs fails loudly in CI. And
# Actions comparisons ignore case while the shell `case` does not, so a dispatch naming `CLAUDE`
# passes the gate and is then refused by the step body before any review runs.

# The step name goes through the environment rather than into the expression. This yq is not jq and
# takes no --arg, and interpolating the name into the expression would make a name holding a quote
# change the query rather than fail it.
#
# It emits the whole block as one compact JSON object rather than as `key=value` lines. The line
# form could not carry a value holding a newline: a YAML block scalar produces several lines, and
# the `grep "^KEY="` this case used kept only the first of them. So a block whose first line was
# the expected expression passed while its later lines put another credential into the environment,
# and the suite read 19 passed, 0 failed on exactly that input. JSON keeps every value whole and
# keeps the key boundary, which is the same reason the key-set case below compares a JSON array.
env_of_step() {
  STEP_NAME="$1" yq -o=json -I=0 \
    '.jobs.review.steps[] | select(.name == strenv(STEP_NAME)) | .env // {}' \
    "$WF"
}

# The expression each secret must carry, in both steps. One backend set per credential, matching the
# arm of the step body that reads it: claude for the OAuth token, codex and the openai opencode
# provider for the OpenAI key, the anthropic opencode provider for the Anthropic key.
declare -A WANT=(
  [CLAUDE_CODE_OAUTH_TOKEN]="\${{ inputs.backend == 'claude' && secrets.CLAUDE_CODE_OAUTH_TOKEN || '' }}"
  [OPENAI_API_KEY]="\${{ (inputs.backend == 'codex' || startsWith(inputs.backend, 'opencode:openai/')) && secrets.OPENAI_API_KEY || '' }}"
  [CODEX_API_KEY]="\${{ inputs.backend == 'codex' && secrets.OPENAI_API_KEY || '' }}"
  [ANTHROPIC_API_KEY]="\${{ startsWith(inputs.backend, 'opencode:anthropic/') && secrets.ANTHROPIC_API_KEY || '' }}"
)

# CODEX_API_KEY carries the same organization OpenAI key as OPENAI_API_KEY, for the codex backend
# only. codex reads CODEX_API_KEY for its noninteractive authentication and OPENAI_API_KEY for its
# openai provider configuration, and the binary at the pinned version carries both names. Two names
# for one key reach no secret that one of them alone does not, so the property these cases guard is
# unchanged: the set of organization secrets a backend's process can read.

# check_gate STEP SECRET
# Compares that secret's expression in that step's env block against the expected text, whole.
# An unreadable block, an absent key and a wrong expression are three different defects and are
# reported as three different messages: a missing key would otherwise satisfy any test phrased as
# "does not hold the credential" while breaking the backend that needs it.
#
# The comparison is between two JSON strings, and both sides are printed JSON-encoded with every
# character outside printable ASCII escaped. Two reasons, and the first is the security property.
# Extracting the value with jq keeps it whole, so a value holding a newline is compared entire
# rather than down to its first line. The second is the diagnostic: a name or an expression that
# differs from the expected one only by an invisible character used to print a want and a got line
# that a reader sees as identical beside the word FAIL, and the next step after concluding that the
# test is broken is to weaken the assertion. Escaped, that difference prints as a backslash-u-200b
# or a backslash-n escape. This comment carries no such character itself, and names the escapes in
# words on purpose: writing one here to illustrate the point would plant in the file the exact
# thing the check exists to surface.
check_gate() {
  local step="$1" secret="$2" block want got
  want=$(printf '%s' "${WANT[$secret]}" | jq -Rsa .)
  if ! block=$(env_of_step "$step") || [ -z "$block" ]; then
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s / %s: yq could not read the env block\n' "$step" "$secret"
    return
  fi
  if [ "$(printf '%s' "$block" | jq --arg k "$secret" 'has($k)')" != 'true' ]; then
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s / %s: the env block names no such key\n' "$step" "$secret"
    return
  fi
  got=$(printf '%s' "$block" | jq -ca --arg k "$secret" '.[$k]')
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  %s / %s carries the reviewed expression\n' "$step" "$secret"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s / %s expression differs\n      want: %s\n      got:  %s\n' \
      "$step" "$secret" "$want" "$got"
  fi
}

# The control. Without it every case below passes on a workflow whose step name changed, because an
# absent step yields an empty block and every assertion then reports its own absence as a failure
# that reads like a gate defect rather than a rename.
#
# It is not a universal control, and the limit is worth stating because the `|| true` hides a yq
# failure that still printed something. A read that fails with output reaches the cases below, which
# then fail on the comparison rather than here. That is a worse message for the same defect, not a
# missed defect.
for STEP in 'Check the backend credential' 'Run one review with the sandbox turned off'; do
  if [ -z "$(env_of_step "$STEP" || true)" ]; then
    echo "read no env block for the step '$STEP'; the gate cases below are not trustworthy" >&2
    exit 2
  fi
done

for STEP in 'Run one review with the sandbox turned off' 'Check the backend credential'; do
  check_gate "$STEP" CLAUDE_CODE_OAUTH_TOKEN
  check_gate "$STEP" OPENAI_API_KEY
  check_gate "$STEP" CODEX_API_KEY
  check_gate "$STEP" ANTHROPIC_API_KEY
done

# The two steps declare the same three credentials, and only those three. A fourth key in either
# block is a credential the gate above says nothing about, and the equality cases cannot see it.
#
# The comparison is against a sorted JSON array, not a string of names joined by a separator. Any
# separator is a character a key name may itself contain, so a joined string loses the boundaries it
# was built to carry: the first form of this case joined on a space, and a block holding a key
# literally named `ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN` beside `OPENAI_API_KEY` produced the
# expected string and passed. A JSON array quotes each element, so a name holding a space, a name
# holding a quote and a blank record are all visible in both the comparison and the message.
#
# Both sides are printed with every character outside printable ASCII escaped, because a key name
# differing from the expected one only by an invisible character printed a want and a got line a
# reader saw as identical beside the word FAIL. The comparison was already right; the message was
# the defect, and a message that reads as a broken test invites weakening the assertion.
WANT_KEYS='["ANTHROPIC_API_KEY","CLAUDE_CODE_OAUTH_TOKEN","CODEX_API_KEY","OPENAI_API_KEY"]'
for STEP in 'Run one review with the sandbox turned off' 'Check the backend credential'; do
  keys=$(STEP_NAME="$STEP" yq -o=json -I=0 \
    '.jobs.review.steps[] | select(.name == strenv(STEP_NAME)) | .env | keys | sort' "$WF")
  if [ "$keys" = "$WANT_KEYS" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  %s declares those four credentials and no others\n' "$STEP"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s declares a different credential set\n      want: %s\n      got:  %s\n' \
      "$STEP" \
      "$(printf '%s' "$WANT_KEYS" | jq -ca .)" \
      "$(printf '%s' "$keys" | jq -ca . 2>/dev/null || printf '%s' "$keys")"
  fi
done

# The regression case for the value shape the line form could not carry. It builds a workflow whose
# CLAUDE_CODE_OAUTH_TOKEN is a YAML block scalar: the first line is the reviewed expression, and a
# second line exposes the Claude token to a Codex review. Against the retired `grep "^KEY="` form
# this passed, because grep kept the first line and dropped the rest, and the suite read 19 passed,
# 0 failed on it. The case runs the real check_gate against the crafted file and requires a failure,
# so it is red on the retired form and green on the JSON one.
#
# Its own control is the clean read: without asserting that the same harness passes on the real
# workflow, a check_gate broken in any way would make this case pass and prove nothing. So the
# clean case above is part of this case's evidence, and both are asserted here.
#
# The sizing lesson this case records: F8 and F9 repaired two copies of one class, an assertion that
# passes on an input its own message says it rejects, and the class stayed open because neither
# repair considered a value holding a newline. A class repair is closed by a case over every value
# shape, not by the copies found so far.
CRAFTED=$(mktemp)
trap 'rm -f "$CRAFTED" "$CRAFTED.out"' EXIT
WANT_LINE="${WANT[CLAUDE_CODE_OAUTH_TOKEN]}"
{
  printf 'jobs:\n  review:\n    steps:\n'
  printf '      - name: Check the backend credential\n        env:\n'
  printf '          CLAUDE_CODE_OAUTH_TOKEN: |-\n'
  printf '            %s\n' "$WANT_LINE"
  printf '            %s\n' "\${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}"
  printf '          OPENAI_API_KEY: x\n          CODEX_API_KEY: x\n          ANTHROPIC_API_KEY: x\n'
} > "$CRAFTED"

# check_gate's own message is captured rather than printed: on this input a refusal is the expected
# outcome, and a passing run that prints the word FAIL reads as a failure to anyone skimming. The
# redirection is not a subshell, so the counters it keeps are still this shell's.
before_fail=$FAIL
WF="$CRAFTED" check_gate 'Check the backend credential' CLAUDE_CODE_OAUTH_TOKEN \
  > "$CRAFTED.out" 2>&1
if [ "$FAIL" -gt "$before_fail" ]; then
  # The crafted input failed as it must, so undo its contribution to the counters and score the
  # regression case itself as the pass.
  FAIL=$before_fail
  PASS=$((PASS + 1))
  printf 'PASS  a multiline value whose first line is the reviewed expression is rejected\n'
else
  PASS=$((PASS - 1))
  FAIL=$((FAIL + 1))
  printf 'FAIL  a multiline value whose first line is the reviewed expression was accepted\n'
  printf '      this is the defect the JSON comparison exists to close: the value was compared\n'
  printf '      down to its first line, so a later line could expose another credential\n'
  printf '      what the comparison reported on the crafted input:\n'
  sed 's/^/      /' "$CRAFTED.out"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
