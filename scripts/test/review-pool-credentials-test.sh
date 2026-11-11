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

# run_step BACKEND CLAUDE_KEY OPENAI_KEY ANTHROPIC_KEY
# Runs the step body with a clean environment holding only what the step itself declares, so a key
# that happens to sit in the caller's environment cannot make a refusal arm pass.
run_step() {
  env -i PATH="$PATH" \
    REVIEW_BACKEND="$1" \
    CLAUDE_CODE_OAUTH_TOKEN="$2" \
    OPENAI_API_KEY="$3" \
    ANTHROPIC_API_KEY="$4" \
    bash -c "$BODY" 2>&1
}

# check LABEL WANT_RC WANT_TEXT BACKEND CLAUDE OPENAI ANTHROPIC
# Both the exit code and the message are asserted. The code alone cannot tell one refusal from
# another, and every refusal arm here exits 1.
check() {
  local label="$1" want_rc="$2" want_text="$3"
  shift 3
  local out rc
  out=$(run_step "$@")
  rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want_text"; then
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
  0 'the codex credential is present' codex '' "$K" ''
check 'codex refuses an empty key' \
  1 'OPENAI_API_KEY is empty' codex "$K" '' "$K"

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
env_of_step() {
  STEP_NAME="$1" yq -r \
    '.jobs.review.steps[] | select(.name == strenv(STEP_NAME)) | .env | to_entries | .[] | .key + "=" + .value' \
    "$WF"
}

# The expression each secret must carry, in both steps. One backend set per credential, matching the
# arm of the step body that reads it: claude for the OAuth token, codex and the openai opencode
# provider for the OpenAI key, the anthropic opencode provider for the Anthropic key.
declare -A WANT=(
  [CLAUDE_CODE_OAUTH_TOKEN]="\${{ inputs.backend == 'claude' && secrets.CLAUDE_CODE_OAUTH_TOKEN || '' }}"
  [OPENAI_API_KEY]="\${{ (inputs.backend == 'codex' || startsWith(inputs.backend, 'opencode:openai/')) && secrets.OPENAI_API_KEY || '' }}"
  [ANTHROPIC_API_KEY]="\${{ startsWith(inputs.backend, 'opencode:anthropic/') && secrets.ANTHROPIC_API_KEY || '' }}"
)

# check_gate STEP SECRET
# Compares that secret's expression in that step's env block against the expected text, whole.
# An unreadable block, an absent key and a wrong expression are three different defects and are
# reported as three different messages: a missing key would otherwise satisfy any test phrased as
# "does not hold the credential" while breaking the backend that needs it.
check_gate() {
  local step="$1" secret="$2" block line want got
  want="${WANT[$secret]}"
  if ! block=$(env_of_step "$step"); then
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s / %s: yq could not read the env block\n' "$step" "$secret"
    return
  fi
  line=$(printf '%s\n' "$block" | grep "^${secret}=" || true)
  if [ -z "$line" ]; then
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s / %s: the env block names no such key\n' "$step" "$secret"
    return
  fi
  got="${line#"${secret}="}"
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
WANT_KEYS='["ANTHROPIC_API_KEY","CLAUDE_CODE_OAUTH_TOKEN","OPENAI_API_KEY"]'
for STEP in 'Run one review with the sandbox turned off' 'Check the backend credential'; do
  keys=$(STEP_NAME="$STEP" yq -o=json -I=0 \
    '.jobs.review.steps[] | select(.name == strenv(STEP_NAME)) | .env | keys | sort' "$WF")
  if [ "$keys" = "$WANT_KEYS" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  %s declares those three credentials and no others\n' "$STEP"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s declares a different credential set\n      want: %s\n      got:  %s\n' \
      "$STEP" "$WANT_KEYS" "$keys"
  fi
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
