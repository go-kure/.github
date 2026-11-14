#!/usr/bin/env bash
# review-pool-capability-test.sh — a review that review-run refused never reaches the posting job.
#
# The producer runs review-run with the sandbox off, so the pool pod is the boundary and review-run's own
# tool restriction is what keeps the backend to read, grep and glob. review-run refuses a review whose
# backend declared a write tool, ran a shell command or reached the network, and its own tests cover that.
# What no test covered is what this workflow does with the refusal. The chain is: the review step records
# review-run's exit code and never fails itself, the extract step turns review.md into findings.json, and
# the last step fails the job on a nonzero code or a missing file. The posting job reads findings.json
# only from a job that succeeded, so a refusal must end in a red job and no findings file.
#
# The step bodies are read out of the workflow, not retyped, so this suite tests the file CI runs. They run
# here against a throwaway git repository and a stand-in review-run that behaves like each refusal.
#
# Cases, each isolated so one layer cannot hide another:
#   - a completed review passes the whole chain (the control: a chain that cannot pass proves nothing);
#   - a refused review, for each capability class, ends in a red last step and no findings.json;
#   - the extract step alone writes nothing after a nonzero code, even when a review.md is present;
#   - the last step alone fails on a nonzero code while all three result files exist, on a missing file
#     and on an unrecorded code;
#   - the review-run call carries exactly the options the producer means to pass: --sandbox none, no
#     --add-dir, the checkout as --root, and a non-empty diff on stdin.
#
# What it does not show: which credential each step receives (review-pool-credentials-test.sh), and what
# a real backend does when an injected prompt asks it to write, run or fetch. That one needs a model and
# the review pool, and is read from a job log under go-kure/.github#438.
#
# Usage: review-pool-capability-test.sh [REPO_ROOT]
# Exit:  0 every case passed; 1 a case failed; 2 a step body or a tool could not be read.
# Needs: yq v4, jq, git, bash.
set -uo pipefail

ROOT="${1:-.}"
WF="$ROOT/.github/workflows/review-pool-acceptance.yml"

if [ ! -f "$WF" ]; then
  echo "cannot read the acceptance workflow at $WF" >&2
  exit 2
fi
for tool in yq jq git sha256sum; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "needs $tool on PATH" >&2
    exit 2
  fi
done

# step_body NAME: the run script of that step. A failed parse can still print a body, and an absent step
# and an empty one print the same empty string, so both are refused rather than tested as nothing.
step_body() {
  local out
  if ! out="$(STEP_NAME="$1" yq -r \
    '.jobs.review.steps[] | select(.name == strenv(STEP_NAME)) | .run' "$WF")"; then
    echo "yq failed to read $WF; the '$1' step body is not trustworthy" >&2
    return 1
  fi
  if [ -z "${out//[[:space:]]/}" ] || [ "$out" = "null" ]; then
    echo "read no '$1' step body from $WF" >&2
    return 1
  fi
  printf '%s' "$out"
}
REVIEW_BODY="$(step_body 'Run one review with the sandbox turned off')" || exit 2
EXTRACT_BODY="$(step_body 'Extract the findings')" || exit 2
FINAL_BODY="$(step_body 'Fail unless the review completed')" || exit 2

# The sandbox value is the job's own, read from the workflow and not set here, so a change to it
# reaches the call this suite checks.
if ! SANDBOX_VALUE="$(yq -r '.jobs.review.env.REVIEW_SANDBOX' "$WF")" || [ -z "$SANDBOX_VALUE" ] \
  || [ "$SANDBOX_VALUE" = "null" ]; then
  echo "read no REVIEW_SANDBOX from the job env of $WF" >&2
  exit 2
fi

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/capability-test.XXXXXX")" || exit 2
trap 'rm -rf "$TMPD"' EXIT

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  echo "ok   $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "FAIL $1" >&2
  if [ -n "${2:-}" ]; then echo "     $2" >&2; fi
  # The last step's own output says why far more often than the assertion can.
  if [ -n "${CASE:-}" ] && [ -s "$CASE/last.log" ]; then sed 's/^/     | /' "$CASE/last.log" >&2; fi
}
# expect LABEL WANT GOT: equality, with both sides shown on a failure.
expect() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want '$2', got '$3'"; fi
}

# has_file LABEL PATH / no_file LABEL PATH: the file is there and non-empty, or it is absent.
has_file() {
  if [ -s "$2" ]; then ok "$1"; else bad "$1" "$2 is missing or empty"; fi
}
no_file() {
  if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "$2 exists"; fi
}

# --- stand-ins on PATH ---------------------------------------------------------------------------
FB="$TMPD/bin"
mkdir -p "$FB"

# review-findings: accepts any existing file; with --out it writes an empty findings document.
cat > "$FB/review-findings" << 'STUB'
#!/usr/bin/env bash
file="$1"
shift
[ -f "$file" ] || { echo "review-findings: no such file $file" >&2; exit 1; }
if [ "${1:-}" = "--out" ]; then printf '{"findings":[]}\n' > "$2"; fi
exit 0
STUB

# review-run: records its arguments (NUL-separated, the prompt holds newlines) and the size of its stdin,
# then behaves as FAKE_MODE says:
#   complete     review.md and a completed provider.json, exit 0
#   refuse       a refused provider.json and no review.md, exit 1 (what the real runner leaves)
#   refuse-body  a refused provider.json and a review.md, exit 1 (a leftover the runner never makes)
cat > "$FB/review-run" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$FAKE_ARGV"
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "--out" ] && out="$a"
  prev="$a"
done
tmp="$(mktemp "${TMPDIR:-/tmp}/stdin.XXXXXX")"
cat > "$tmp"
wc -c < "$tmp" > "$FAKE_ARGV.stdin-bytes"
sha="$(sha256sum < "$tmp" | cut -d' ' -f1)"
rm -f "$tmp"
mkdir -p "$out"
body() { printf 'I read the diff.\n\nREVIEW_COMPLETE: findings=0\n' > "$out/review.md"; }
record() {
  printf '{"outcome":"%s","reason":"%s","identity":{"input_sha256":"%s","material_sha256":"%s"}}\n' \
    "$1" "$2" "$sha" "$sha" > "$out/provider.json"
}
case "$FAKE_MODE" in
  complete) body; record completed ""; exit 0 ;;
  refuse) record refused "$FAKE_REASON"; exit 1 ;;
  refuse-body) body; record refused "$FAKE_REASON"; exit 1 ;;
esac
exit 99
STUB
chmod +x "$FB/review-findings" "$FB/review-run"

# The extract step calls bare `jq`, and the steps run in a clean environment (env -i), which is where a
# version manager's shim for jq fails to start. So the stand-in directory carries a real jq: the first
# binary that is not a shim and starts in a bare environment. Without one the suite refuses (exit 2),
# because a row of failures about a shim is not a result about the workflow.
real_jq=""
for cand in /usr/bin/jq /bin/jq /usr/local/bin/jq "$(command -v mise > /dev/null 2>&1 && mise which jq 2> /dev/null)"; do
  [ -n "$cand" ] && [ -x "$cand" ] || continue
  case "$cand" in */shims/*) continue ;; esac
  if env -i PATH=/usr/bin:/bin "$cand" --version > /dev/null 2>&1; then
    real_jq="$cand"
    break
  fi
done
if [ -z "$real_jq" ]; then
  echo "found no jq that starts without a version manager's environment" >&2
  exit 2
fi
ln -s "$real_jq" "$FB/jq"

# --- one case directory: a two-commit repository, a temp dir and an output dir -------------------
new_case() {
  CASE="$(mktemp -d "$TMPD/case.XXXXXX")"
  WS="$CASE/ws"
  RT="$CASE/rt"
  OUT="$RT/acceptance/out"
  mkdir -p "$WS" "$RT"
  : > "$RT/review-config.txt"
  # No template, no global or system configuration, no hooks: the fixture must not depend on, or run,
  # whatever this host's git is set up to do.
  fgit() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$WS" \
      -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t.invalid "$@"
  }
  fgit init -q --template=
  printf 'one\n' > "$WS/a.txt"
  fgit add a.txt
  fgit commit -q -m first
  BASE="$(fgit rev-parse HEAD)"
  printf 'two\n' >> "$WS/a.txt"
  fgit commit -q -am second
}

# step_env BODY [VAR=VALUE...]: runs a step body the way the job does, in a clean environment.
step_env() {
  local body="$1"
  shift
  env -i PATH="$FB:$PATH" HOME="$CASE" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GITHUB_WORKSPACE="$WS" RUNNER_TEMP="$RT" GITHUB_OUTPUT="$RT/gh-output" OUT_DIR="$OUT" \
    REVIEW_BASE="$BASE" REVIEW_BACKEND=claude REVIEW_SANDBOX="$SANDBOX_VALUE" \
    FAKE_ARGV="$CASE/argv" "$@" bash -c "$body" > "$CASE/last.log" 2>&1
}

# run_review MODE REASON [EFFORT]: the review step; sets REVIEW_RC to the code it recorded.
run_review() {
  step_env "$REVIEW_BODY" FAKE_MODE="$1" FAKE_REASON="$2" REVIEW_EFFORT="${3:-}"
  REVIEW_STEP_EXIT=$?
  REVIEW_RC="$(sed -n 's/^rc=//p' "$RT/gh-output" 2> /dev/null | tail -1)"
}
# run_extract RC / run_final RC: the other two steps, given the code the review step recorded.
run_extract() {
  step_env "$EXTRACT_BODY" REVIEW_RUN_RC="$1"
  EXTRACT_EXIT=$?
}
run_final() {
  step_env "$FINAL_BODY" REVIEW_RUN_RC="$1"
  FINAL_EXIT=$?
}
# put_results: a complete result set in OUT, for the cases that test one step alone.
put_results() {
  mkdir -p "$OUT"
  printf 'I read the diff.\n\nREVIEW_COMPLETE: findings=0\n' > "$OUT/review.md"
  printf '{"findings":[]}\n' > "$OUT/findings.json"
  printf '{"outcome":"completed","identity":{"input_sha256":"x","material_sha256":"x"}}\n' > "$OUT/provider.json"
}

# --- the control: a completed review passes the whole chain --------------------------------------
new_case
run_review complete ""
expect 'control: the review step exits 0' 0 "$REVIEW_STEP_EXIT"
expect 'control: the review step records code 0' 0 "$REVIEW_RC"
if grep -q 'the canonical diff binds renames with' "$CASE/last.log"; then
  ok 'control: the step ran to its diff, not to an early exit'
else
  bad 'control: the step ran to its diff, not to an early exit' "$(cat "$CASE/last.log")"
fi
run_extract "$REVIEW_RC"
expect 'control: the extract step exits 0' 0 "$EXTRACT_EXIT"
has_file 'control: findings.json is written' "$OUT/findings.json"
run_final "$REVIEW_RC"
expect 'control: the last step exits 0' 0 "$FINAL_EXIT"

# --- a refused review, for each capability class -------------------------------------------------
for class in file-write shell network; do
  new_case
  run_review refuse "REVIEW_TOOL_REFUSED: stage=capability-declaration rejected=$class"
  expect "refused ($class): the review step itself exits 0" 0 "$REVIEW_STEP_EXIT"
  expect "refused ($class): the review step records the nonzero code" 1 "$REVIEW_RC"
  run_extract "$REVIEW_RC"
  expect "refused ($class): the extract step exits 0" 0 "$EXTRACT_EXIT"
  no_file "refused ($class): no findings.json" "$OUT/findings.json"
  run_final "$REVIEW_RC"
  expect "refused ($class): the last step exits 1" 1 "$FINAL_EXIT"
  if grep -q 'review-run exited 1' "$CASE/last.log"; then
    ok "refused ($class): the last step names the code"
  else
    bad "refused ($class): the last step names the code" "$(cat "$CASE/last.log")"
  fi
  has_file "refused ($class): provider.json is kept for the artifact" "$OUT/provider.json"
done

# A review.md beside a nonzero code is a state the real runner never writes (it publishes review.md only
# for a completed run). The chain must not rely on that, so this case is what the extract guard is for.
new_case
run_review refuse-body "REVIEW_TOOL_REFUSED: stage=invocation rejected=shell"
run_extract "$REVIEW_RC"
no_file 'refused with a review.md: no findings.json through the chain' "$OUT/findings.json"
run_final "$REVIEW_RC"
expect 'refused with a review.md: the last step exits 1' 1 "$FINAL_EXIT"

# --- each layer on its own -----------------------------------------------------------------------
new_case
put_results
rm -f "$OUT/findings.json"
run_extract 1
expect 'extract alone, code 1 and a review.md: exits 0' 0 "$EXTRACT_EXIT"
no_file 'extract alone, code 1 and a review.md: writes no findings.json' "$OUT/findings.json"

new_case
put_results
rm -f "$OUT/findings.json"
run_extract 0
has_file 'extract alone, code 0 and a review.md: writes findings.json' "$OUT/findings.json"

new_case
put_results
run_final 1
expect 'last step alone, code 1 with all three files: exits 1' 1 "$FINAL_EXIT"

new_case
put_results
rm -f "$OUT/findings.json"
run_final 0
expect 'last step alone, code 0 and no findings.json: exits 1' 1 "$FINAL_EXIT"

new_case
put_results
step_env "$FINAL_BODY" REVIEW_RUN_RC=
expect 'last step alone, no recorded code: exits 1' 1 "$?"

new_case
put_results
run_final 0
expect 'last step alone, code 0 and all three files: exits 0' 0 "$FINAL_EXIT"

# --- the review-run call -------------------------------------------------------------------------
# The recorded call is read by structure, not by pattern: every argument but the last (the prompt) sits
# in a pair, an option and its value. An option in the `--name=value` form, a stray word or any other
# shape breaks the pairing, so it shows up as an unexpected option name or an odd argument count. A
# pattern that kept only well-formed option names let `--add-dir=/tmp` pass unseen.
#
# flag_value NAME: the value paired with that option in the recorded call.
flag_value() {
  local i
  for ((i = 0; i < ${#ARGV[@]} - 1; i += 2)); do
    if [ "${ARGV[i]}" = "$1" ]; then
      printf '%s' "${ARGV[i + 1]}"
      return
    fi
  done
}
# call_flags: the sorted option positions of the recorded call, verbatim, comma-separated.
call_flags() {
  local i
  for ((i = 0; i < ${#ARGV[@]} - 1; i += 2)); do
    printf '%s\n' "${ARGV[i]}"
  done | sort | tr '\n' ','
}
# call_paired: 0 when the arguments before the prompt come in pairs, 1 when they do not.
call_paired() {
  echo $(((${#ARGV[@]} - 1) % 2))
}
# call_mentions_add_dir: yes when any argument is --add-dir, alone or as --add-dir=value.
call_mentions_add_dir() {
  local a
  for a in "${ARGV[@]}"; do
    case "$a" in --add-dir | --add-dir=*) echo yes; return ;; esac
  done
  echo no
}

# The reader itself: a call carrying --add-dir in the equals form must be seen. A mutant of the workflow
# cannot reach this, so the checks are run on a constructed argument list, with an ordinary call beside
# it as the control.
ARGV=(--backend claude --root /w --base b --sandbox none --seconds 1500 --out /o prompt)
expect 'reader: an ordinary call is paired' 0 "$(call_paired)"
expect 'reader: an ordinary call has no --add-dir' no "$(call_mentions_add_dir)"
ARGV=(--backend claude --root /w --base b --sandbox none --seconds 1500 --out /o --add-dir=/tmp prompt)
expect 'reader: --add-dir=/tmp is seen' yes "$(call_mentions_add_dir)"
expect 'reader: --add-dir=/tmp breaks the pairing' 1 "$(call_paired)"
ARGV=(--backend claude --root /w --base b --sandbox none --seconds 1500 --out /o --add-dir /tmp prompt)
expect 'reader: --add-dir /tmp is seen' yes "$(call_mentions_add_dir)"
ARGV=(--backend claude --root /w --base b --sandbox none --seconds 1500 --out /o stray prompt)
expect 'reader: a stray word breaks the pairing' 1 "$(call_paired)"

new_case
run_review complete ""
mapfile -d '' -t ARGV < "$CASE/argv"
expect 'call: exactly the intended options, no effort set' \
  '--backend,--base,--out,--root,--sandbox,--seconds,' "$(call_flags)"
expect 'call: --sandbox none' none "$(flag_value --sandbox)"
expect 'call: --root is the checkout' "$WS" "$(flag_value --root)"
expect 'call: --backend is the input' claude "$(flag_value --backend)"
expect 'call: no --add-dir, in either form' no "$(call_mentions_add_dir)"
expect 'call: every option has a value, then the prompt' 0 "$(call_paired)"
stdin_bytes="$(cat "$CASE/argv.stdin-bytes" 2> /dev/null || echo 0)"
if [ "$stdin_bytes" -gt 0 ]; then ok 'call: the diff reaches stdin'; else bad 'call: the diff reaches stdin'; fi

new_case
run_review complete "" high
mapfile -d '' -t ARGV < "$CASE/argv"
expect 'call: --effort is added when an effort is set, and nothing else' \
  '--backend,--base,--effort,--out,--root,--sandbox,--seconds,' "$(call_flags)"

echo "review-pool-capability-test: passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
