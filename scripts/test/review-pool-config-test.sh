#!/usr/bin/env bash
# review-pool-config-test.sh — the review pool's producer carries the caller's review configuration.
#
# pr-review.yml can take its first-pass review from the review pool (vars.PR_REVIEW_BACKEND=file).
# Its own review prompt carries three things the caller sets: the project context (the
# pr_review_context input), a standards document (standards-file and standards-source) and the
# repository's AGENTS.md and .claude/CLAUDE.md. A producer that ignores them silently reviews with
# less than the proxy path does, and nothing fails. So the producer takes them as inputs, and one
# step turns them into a section of its prompt. That step body is read out of the workflow and run
# here, so this suite tests the file CI will run.
#
# The standards document can be 70 KB, which no workflow input or prompt argument carries. So the
# prompt names the file and the reviewer reads it: the step only has to put the file on disk and
# name it, and to refuse a path that leaves the checkout.
#
# Usage: review-pool-config-test.sh [REPO_ROOT]
# Exit:  0 every case passed; 1 a case failed; 2 the workflow or a node of it could not be read.
# Needs: yq v4, bash.

set -uo pipefail # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
WF="$ROOT/.github/workflows/review-pool-acceptance.yml"
STEP_NAME="Resolve the caller's review configuration"

if [ ! -f "$WF" ]; then
  echo "cannot read the workflow at $WF" >&2
  exit 2
fi

failures=0
pass_count=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected '$expected', got '$actual'" >&2
    failures=$((failures + 1))
  fi
}

# has NEEDLE TEXT: true when TEXT contains NEEDLE. A `case`, not a pipe into grep -q: under pipefail
# a grep that stops early can fail the pipeline for the writer, and a true match then reads false.
has() {
  case "$2" in *"$1"*) echo true ;; *) echo false ;; esac
}

# read_into VAR QUERY: one yq read of the workflow, stored in VAR, in the suite's own shell so the
# `exit 2` for an unreadable node ends the suite. An absent node prints "null" or nothing, which is
# as unreadable.
read_into() {
  local var="$1" out
  if ! out=$(yq -r "$2" "$WF"); then
    echo "yq failed to read $WF ($2); what it printed is not trustworthy" >&2
    exit 2
  fi
  if [ -z "${out//[[:space:]]/}" ] || [ "$out" = "null" ]; then
    echo "read nothing for $2 from $WF" >&2
    exit 2
  fi
  printf -v "$var" '%s' "$out"
}

read_into BODY ".jobs.review.steps[] | select(.name == \"$STEP_NAME\") | .run"
read_into STEP_INDEX ".jobs.review.steps | to_entries | .[] | select(.value.name == \"$STEP_NAME\") | .key"
read_into REVIEW_INDEX '.jobs.review.steps | to_entries | .[] | select(.value.id == "review") | .key'
read_into REVIEW_BODY '.jobs.review.steps[] | select(.id == "review") | .run'
read_into CALL_INPUTS '.on.workflow_call.inputs | keys | sort | join(",")'
read_into DISPATCH_INPUTS '.on.workflow_dispatch.inputs | keys | sort | join(",")'

# run_step CASE_NAME CONTEXT FILE SOURCE: the step body in a clean environment holding only what the
# step declares, in its own workspace and temp directory. Prints the exit code; the section it wrote
# for the prompt is $WORK/CASE_NAME/temp/review-config.txt.
run_step() {
  local dir="$WORK/$1"
  mkdir -p "$dir/workspace" "$dir/temp" "$dir/bin"
  cat > "$dir/bin/curl" <<'FAKECURL'
#!/usr/bin/env bash
# Records the URL and writes a fixed document, or the answer a case asks for.
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
case "${FAKE_CURL_CODE:-200}" in
  200) printf 'standards from the action repository\n' > "$out"; printf 200 ;;
  000) exit 28 ;;
  *) : > "$out"; printf '%s' "${FAKE_CURL_CODE}" ;;
esac
FAKECURL
  chmod +x "$dir/bin/curl"
  : > "$dir/curl.log"
  env -i PATH="$dir/bin:$PATH" GITHUB_WORKSPACE="$dir/workspace" RUNNER_TEMP="$dir/temp" \
    FAKE_CURL_LOG="$dir/curl.log" FAKE_CURL_CODE="${FAKE_CURL_CODE:-200}" LC_ALL="${STEP_LC_ALL:-}" \
    REVIEW_CONTEXT="$2" REVIEW_STANDARDS_FILE="$3" REVIEW_STANDARDS_SOURCE="$4" \
    bash -c "$BODY" > "$dir/out.log" 2>&1
  echo $?
}
section() { cat "$WORK/$1/temp/review-config.txt" 2>/dev/null; }

# No configuration: nothing is added, so the default prompt is exactly what it was.
assert_eq "no configuration: the step goes on" "0" "$(run_step none '' '' caller)"
assert_eq "no configuration: the section is empty" "" "$(section none)"

# The project context reaches the prompt word for word.
assert_eq "context only: the step goes on" "0" "$(run_step ctx 'Be strict about error wrapping.' '' caller)"
assert_eq "context only: the section names it" "true" \
  "$(has 'ADDITIONAL PROJECT CONTEXT:'$'\n''Be strict about error wrapping.' "$(section ctx)")"
assert_eq "context only: no standards line" "false" "$(has 'PROJECT STANDARDS' "$(section ctx)")"
big="$(head -c 60001 /dev/zero | tr '\0' 'x')"
assert_eq "context over 60000 bytes: refused, so the prompt argument stays under the kernel limit" "1" \
  "$(run_step bigctx "$big" '' caller)"
# The kernel caps bytes, and a UTF-8 locale counts characters: 21000 three-byte characters are 63000
# bytes, so a character count lets the context through and the argument then fails to start.
wide="$(head -c 21000 /dev/zero | tr '\0' 'x' | sed 's/x/界/g')"
assert_eq "context of 63000 bytes in 21000 characters, UTF-8 locale: refused" "1" \
  "$(STEP_LC_ALL=C.utf8 run_step widectx "$wide" '' caller)"
narrow="$(head -c 19000 /dev/zero | tr '\0' 'x' | sed 's/x/界/g')"
assert_eq "context of 57000 bytes in 19000 characters, UTF-8 locale: accepted" "0" \
  "$(STEP_LC_ALL=C.utf8 run_step narrowctx "$narrow" '' caller)"

# A standards document in the caller's checkout is named by its path, and the file is not copied
# into the prompt.
mkdir -p "$WORK/std/workspace/docs"
printf 'rule one\n' > "$WORK/std/workspace/docs/standards.md"
std_rc="$(run_step std '' docs/standards.md caller)"
assert_eq "caller standards: the step goes on" "0" "$std_rc"
assert_eq "caller standards: the section names the file by its resolved path" "true" \
  "$(has "$WORK/std/workspace/docs/standards.md" "$(section std)")"
assert_eq "caller standards: the document itself is not in the prompt" "false" "$(has 'rule one' "$(section std)")"
assert_eq "caller standards: the caller's checkout is not fetched from the network" "" "$(cat "$WORK/std/curl.log")"

# A file that is not there is logged and reviewed without, as the proxy path does.
assert_eq "caller standards file missing: the step goes on" "0" "$(run_step nostd '' docs/none.md caller)"
assert_eq "caller standards file missing: the section names no standards" "false" "$(has 'PROJECT STANDARDS' "$(section nostd)")"
assert_eq "caller standards file missing: the log says so" "true" "$(has 'not found' "$(cat "$WORK/nostd/out.log")")"

# A path that leaves the checkout is refused: a symlink in the reviewed head must not name a file of the runner.
assert_eq "standards path with .. : refused" "1" "$(run_step dots '' ../etc/passwd caller)"
assert_eq "standards path that is absolute: refused" "1" "$(run_step abs '' /etc/passwd caller)"
mkdir -p "$WORK/link/workspace"
ln -s /etc/hostname "$WORK/link/workspace/standards.md"
assert_eq "standards path through a symlink that leaves the checkout: refused" "1" "$(run_step link '' standards.md caller)"

# The action's own standards document is fetched from go-kure/.github at main.
assert_eq "action standards: the step goes on" "0" "$(run_step act '' docs/standards.md action)"
assert_eq "action standards: it asked for the file in go-kure/.github at main" \
  "https://raw.githubusercontent.com/go-kure/.github/main/docs/standards.md" "$(cat "$WORK/act/curl.log")"
assert_eq "action standards: the section names the fetched copy" "true" \
  "$(has "$WORK/act/temp/standards-from-action.md" "$(section act)")"
assert_eq "action standards: a 404 is logged and reviewed without" "0" "$(FAKE_CURL_CODE=404 run_step act404 '' docs/standards.md action)"
assert_eq "action standards: a 404 leaves no standards line" "false" "$(has 'PROJECT STANDARDS' "$(section act404)")"
assert_eq "action standards: a server error is not a missing file, so it refuses" "1" "$(FAKE_CURL_CODE=502 run_step act502 '' docs/standards.md action)"
assert_eq "action standards: a failed fetch refuses" "1" "$(FAKE_CURL_CODE=000 run_step act000 '' docs/standards.md action)"
assert_eq "an unknown source: refused" "1" "$(run_step badsrc '' docs/standards.md elsewhere)"

# The repository's own convention files are named when they exist, as the proxy path injects them.
mkdir -p "$WORK/agents/workspace/.claude"
printf 'a\n' > "$WORK/agents/workspace/AGENTS.md"
printf 'c\n' > "$WORK/agents/workspace/.claude/CLAUDE.md"
assert_eq "convention files: the step goes on" "0" "$(run_step agents '' '' caller)"
assert_eq "convention files: AGENTS.md is named" "true" "$(has 'AGENTS.md' "$(section agents)")"
assert_eq "convention files: .claude/CLAUDE.md is named" "true" "$(has '.claude/CLAUDE.md' "$(section agents)")"

# Structure: the inputs exist in both modes, and the review step reads the section after this step ran.
for input in context standards_file standards_source; do
  assert_eq "a call takes the input $input" "true" "$(has ",$input," ",$CALL_INPUTS,")"
done
assert_eq "a call and a dispatch take the same inputs" "$CALL_INPUTS" "$DISPATCH_INPUTS"
assert_eq "the step runs before the review" "true" "$([ "$STEP_INDEX" -lt "$REVIEW_INDEX" ] && echo true || echo false)"
assert_eq "the review step puts the section into its prompt" "true" "$(has 'review-config.txt' "$REVIEW_BODY")"

if [ "$failures" -gt 0 ]; then
  echo "review-pool-config-test: $failures failed, $pass_count passed" >&2
  exit 1
fi
echo "review-pool-config-test: passed: $pass_count, failed: 0"
