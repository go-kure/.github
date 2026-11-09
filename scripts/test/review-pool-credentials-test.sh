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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
