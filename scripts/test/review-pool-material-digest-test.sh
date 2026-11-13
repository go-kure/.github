#!/usr/bin/env bash
# review-pool-material-digest-test.sh — a missing material digest fails the acceptance run.
#
# The extract step compares the digest of the bytes the reviewer read on stdin with the digest of
# the runner's own canonical diff of the reviewed range. A disagreement means the review read other
# bytes than the record names, so every finding in the body would be about material the record
# misdescribes.
#
# Both reads fall back to the same literal when their field is missing, so a record carrying neither
# digest made the comparison compare "absent" with "absent", pass, and print that the material
# matched. That is the one thing this check exists to disprove, and the failure mode is quiet: the
# step prints a success line and the acceptance run reports a result nobody can trust.
#
# The fixtures below are defensive malformed-record cases, not a reproduction of a writer on this
# path. This workflow passes --base on every acceptance run (review-pool-acceptance.yml:496), so
# material_sha256 is never left null here, and the review runner builds its identity block before it
# constructs the record, so a record that writer creates carries both fields. What the repair guards
# is a record that reaches the step malformed by any route, because a comparison with nothing in it
# answers falsely whatever wrote the record.
#
# The step body is read out of the workflow rather than retyped here, so this suite tests the file
# CI will run. A retyped copy passes while the workflow is wrong.
#
# The cases cover the value shapes the two fields take, not only the one site: neither digest, each
# one missing on its own, both present and equal, both present and different, and no record at all.
# A sweep of one site closes a location and leaves the value space open.
#
# Usage: review-pool-material-digest-test.sh [REPO_ROOT]
# Exit:  0 every case passed; 1 a case failed; 2 the step body could not be read.
# Needs: yq v4, bash, and a real jq binary (not a version manager's shim): on a system directory,
#        on PATH, or named by `mise which jq`.

set -uo pipefail

ROOT="${1:-.}"
WF="$ROOT/.github/workflows/review-pool-acceptance.yml"

if [ ! -f "$WF" ]; then
  echo "cannot read the acceptance workflow at $WF" >&2
  exit 2
fi

if ! BODY=$(yq -r \
  '.jobs.review.steps[] | select(.name == "Extract the findings") | .run' "$WF"); then
  # A failed parse can still print a body on stdout, so the content checks below would accept it and
  # the suite would test a fragment of a file yq could not read as a whole. The status is the only
  # thing that distinguishes that from a clean read.
  echo "yq failed to read $WF; the step body is not trustworthy" >&2
  exit 2
fi

# An absent step and an empty one produce the same empty string, so refuse rather than report zero
# failures over nothing.
if [ -z "${BODY//[[:space:]]/}" ] || [ "$BODY" = "null" ]; then
  echo "read no extract step body from $WF" >&2
  exit 2
fi

# The cases below assert messages this comparison emits, so a body without it fails them rather than
# passes. What this control catches is a body extracted from the wrong step, which would fail every
# case for a reason that has nothing to do with the digests. It names that cause once, here, instead
# of leaving it to be inferred from seven failures.
if ! grep -q 'material_sha256' <<<"$BODY"; then
  echo "the extract step body names no material_sha256; this suite is aimed at the wrong step" >&2
  exit 2
fi

PASS=0
FAIL=0

# The step calls bare `jq`, and the sandbox below removes the environment a version manager's shim
# needs to start. A shim on the caller's PATH therefore fails inside the sandbox for a reason that
# has nothing to do with the step, and every case then reports a failure the workflow does not have.
# So resolve a binary that starts in that bare environment, and test every candidate rather than
# only the first one found: an executable that cannot start is not a usable jq, and the next
# candidate may be. The search covers PATH as well as the usual system directories, so a host whose
# jq lives elsewhere is not refused while holding every prerequisite. Where none runs the suite
# refuses, because an exit 2 says it did not run, which a row of failures would hide.
JQ_SYSTEM_DIRS="${JQ_SYSTEM_DIRS:-/usr/bin /bin /usr/local/bin}"
# resolve_jq prints the first real jq that starts in a bare environment, or fails. A real jq is a
# binary: a path under a version manager's shims directory is refused even when it starts, because
# what it runs depends on the environment the sandbox removes. Candidates, in order: the system
# directories, every jq on PATH (`type -ap`; bash's `command` has no -a), then `mise which jq`, which
# names the binary behind a shim that is on PATH.
resolve_jq() {
  local cand dir
  while IFS= read -r cand; do
    [ -x "$cand" ] || continue
    case "$cand" in */shims/*) continue ;; esac
    if env -i PATH="$(dirname "$cand")" "$cand" --version >/dev/null 2>&1; then
      printf '%s\n' "$cand"
      return 0
    fi
  done < <(
    for dir in $JQ_SYSTEM_DIRS; do printf '%s/jq\n' "$dir"; done
    type -ap jq 2>/dev/null
    if command -v mise >/dev/null 2>&1; then mise which jq 2>/dev/null; fi
  )
  return 1
}

# resolve_jq self-test. Each case runs in a subshell whose PATH holds only fixture directories, so
# the host's own jq cannot decide the answer. The stub "jq" prints a line and needs nothing; the shim
# fails unless a version manager's variable is set, as a real shim does.
# One temporary root holds the resolver fixtures and the step cases, under one cleanup trap.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
R="$WORK/resolve"
mkdir -p "$R"
mkdir -p "$R/tools" "$R/real" "$R/mise/shims" "$R/okshim/shims" "$R/misebin"
ln -s "$(command -v env)" "$R/tools/env"
ln -s "$(command -v dirname)" "$R/tools/dirname"
printf '#!/bin/sh\necho jq-stub\n' > "$R/real/jq"
# shellcheck disable=SC2016  # stub script text, expanded when the stub runs
printf '#!/bin/sh\n[ -n "${MISE_SHIM_ENV:-}" ] || exit 1\necho jq-stub\n' > "$R/mise/shims/jq"
printf '#!/bin/sh\necho jq-stub\n' > "$R/okshim/shims/jq"
# shellcheck disable=SC2016  # stub script text, expanded when the stub runs
printf '#!/bin/sh\n[ "$1" = which ] && echo "$FAKE_WHICH"\n' > "$R/misebin/mise"
chmod +x "$R/real/jq" "$R/mise/shims/jq" "$R/okshim/shims/jq" "$R/misebin/mise"

# resolve_case LABEL WANT PATH_DIRS [FAKE_WHICH]
# WANT is the path resolve_jq must print, or NONE when it must find nothing.
resolve_case() {
  local label="$1" want="$2" path_dirs="$3" fake_which="${4:-}" got
  got=$(PATH="$path_dirs" JQ_SYSTEM_DIRS="$R/none" FAKE_WHICH="$fake_which" resolve_jq) || got=NONE
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  resolve_jq: %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  resolve_jq: %s: got %s want %s\n' "$label" "$got" "$want"
  fi
}

resolve_case 'a real jq on PATH is chosen (control)' "$R/real/jq" "$R/real:$R/tools"
resolve_case 'a shim alone finds nothing' NONE "$R/mise/shims:$R/tools"
resolve_case 'a shim on PATH falls back to mise which' "$R/real/jq" "$R/mise/shims:$R/misebin:$R/tools" "$R/real/jq"
resolve_case 'a shim that starts anyway is still refused' NONE "$R/okshim/shims:$R/tools"
resolve_case 'mise which naming a shim is refused' NONE "$R/misebin:$R/tools" "$R/mise/shims/jq"

JQ="$(resolve_jq)"
if [ -z "$JQ" ]; then
  echo "found no jq that runs without a version manager's environment; the digest step cannot be tested" >&2
  exit 2
fi
SANDBOX_PATH="$(dirname "$JQ"):/usr/bin:/bin"

# run_step CASE_DIR PROVIDER_JSON
# Runs the step body with OUT_DIR pointing at a fresh directory holding only the record under test.
# No review.md is written, so the step takes its own "the review did not complete" branch after the
# digest check and the result is the digest check's own verdict. The environment carries only what
# the step reads, so nothing from the caller can decide the outcome.
run_step() {
  local dir="$1" provider="$2"
  mkdir -p "$dir"
  if [ "$provider" != NONE ]; then
    printf '%s\n' "$provider" > "$dir/provider.json"
  fi
  env -i PATH="$SANDBOX_PATH" HOME="$dir" \
    OUT_DIR="$dir" \
    RUNNER_TEMP="$dir" \
    bash -c "$BODY" 2>&1
}

# check LABEL WANT_RC WANT_TEXT CASE_NAME PROVIDER_JSON
# Both the exit code and the message are asserted. A missing digest and a real mismatch both exit 1,
# so the code alone cannot tell them apart, and the dispatcher who reads the log needs to know which
# field is missing rather than that two strings differed.
check() {
  local label="$1" want_rc="$2" want_text="$3" name="$4" provider="$5"
  local out rc
  out=$(run_step "$WORK/$name" "$provider")
  rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -qF -- "$want_text" <<<"$out"; then
    PASS=$((PASS + 1))
    printf 'PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s: rc=%s want=%s, output: %s\n' "$label" "$rc" "$want_rc" "$out"
  fi
}

# The finding's own case. A record with no identity block at all sends both reads to the fallback,
# and the comparison then holds between two copies of the same literal. Before the repair this
# printed the success line and exited 0.
check 'neither digest present refuses, and names both fields' \
  1 'names no stdin input_sha256 and no canonical material_sha256' \
  both-absent '{}'

# The same absence by the other route: an identity key whose value is null. jq's `//` treats a null
# exactly as it treats a missing key, so this case proves the repair reads the value rather than the
# presence of the key.
check 'a null identity block refuses' \
  1 'names no stdin input_sha256 and no canonical material_sha256' \
  identity-null '{"identity":null}'

# One digest recorded and the other not. It exited 1 before the repair too, but as a mismatch, which
# told the reader the two digests disagreed when in truth one was never recorded.
check 'a missing canonical digest refuses, and names that field' \
  1 'names no canonical material_sha256' \
  material-absent '{"identity":{"input_sha256":"a1","material_sha256":null}}'

# The mirror shape, for completeness of the value space rather than because this writer produces it.
check 'a missing stdin digest refuses, and names that field' \
  1 'names no stdin input_sha256' \
  input-absent '{"identity":{"input_sha256":null,"material_sha256":"b2"}}'

# The control that keeps the repair honest: a record with both digests equal still passes. A fix that
# failed every run would satisfy every case above and break the workflow.
check 'two equal digests pass' \
  0 'the reviewed material matches the recorded range: c3' \
  equal '{"identity":{"input_sha256":"c3","material_sha256":"c3"}}'

# The original check still refuses a real disagreement, in its own words.
check 'two different digests refuse as a mismatch' \
  1 'the reviewed material is not the recorded range' \
  different '{"identity":{"input_sha256":"d4","material_sha256":"e5"}}'

# No record at all is not this check's business: the step skips the comparison and the run's own
# failure is reported by the step that fails the job on the recorded exit code.
check 'no provider record skips the check' \
  0 'the review did not complete' \
  no-record NONE

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
