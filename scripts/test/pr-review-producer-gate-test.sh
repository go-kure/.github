#!/usr/bin/env bash
# pr-review-producer-gate-test.sh — pr-review.yml can take its review from the review pool
# (vars.PR_REVIEW_BACKEND=file), and it must fail closed when that producer did not deliver.
#
# Why fail closed is the line this suite exists for: the posting job is the required check
# `pr-review / AI Code Review` on the consumer repositories. A job whose `needs` did not succeed is
# skipped, and a skipped required check counts as passing. So without a step that refuses, a producer
# that failed, was cancelled or never ran would let the pull request through unreviewed. The step
# body is read out of the workflow and run, so this suite tests the file CI will run.
#
# Usage: pr-review-producer-gate-test.sh [REPO_ROOT]
# Exit:  0 every case passed; 1 a case failed; 2 the workflow or a node of it could not be read.
# Needs: yq v4, bash.

# shellcheck disable=SC2016 # the ${{ }} below is workflow expression text compared as a string, never a shell expansion
set -uo pipefail # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
WF="$ROOT/.github/workflows/pr-review.yml"
GATE_NAME="Refuse to continue when the review producer did not succeed"

if [ ! -f "$WF" ]; then
  echo "cannot read the workflow at $WF" >&2
  exit 2
fi

failures=0
pass_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected '$expected', got '$actual'" >&2
    failures=$((failures + 1))
  fi
}

# read_into VAR QUERY: one yq read of the workflow, stored in VAR. It runs in the suite's own shell,
# never in a command substitution, because the `exit 2` for an unreadable node must end the suite: in
# a subshell it would only end the substitution, and every case would then run against an empty
# value and pass or fail for no reason. A failed parse can still print on stdout, so the status is
# the only thing that tells a clean read from a fragment; an absent node prints "null" or nothing,
# which is as unreadable.
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

read_into BODY ".jobs.pr-review.steps[] | select(.name == \"$GATE_NAME\") | .run"
read_into NEEDS '.jobs.pr-review.needs | join(",")'
read_into JOB_IF '.jobs.pr-review.if'
read_into GATE_INDEX ".jobs.pr-review.steps | to_entries | .[] | select(.value.name == \"$GATE_NAME\") | .key"
read_into PRODUCER_USES '.jobs.review-producer.uses'
read_into PRODUCER_SECRETS '.jobs.review-producer.secrets'
read_into PLAN_IF '.jobs.plan.if'
read_into PRODUCER_IF '.jobs.review-producer.if'
read_into DOWNLOAD_IF ".jobs.pr-review.steps[] | select(.name == \"Download the producer's result files\") | .if"
read_into NAME_IF '.jobs.pr-review.steps[] | select(.name == "Name the findings file and the identity it must carry") | .if'
read_into PLAN_OUTPUTS '.jobs.plan.outputs | keys | join(",")'
read_into PRODUCER_WITH_CONTEXT '.jobs.review-producer.with.context'
read_into PRODUCER_WITH_STANDARDS_FILE '.jobs.review-producer.with.standards_file'
read_into PRODUCER_WITH_STANDARDS_SOURCE '.jobs.review-producer.with.standards_source'

# run_gate BACKEND PLAN_RESULT PRODUCER_RESULT [EMPTY]: the step body in a clean environment holding
# only what the step itself declares, so a value in the caller's environment cannot make a case pass.
# EMPTY is the plan job's `empty` output; the default path has no plan job, so it is unset there.
run_gate() {
  env -i PATH="$PATH" BACKEND="$1" PLAN_RESULT="$2" PRODUCER_RESULT="$3" EMPTY="${4-}" bash -c "$BODY" > /dev/null 2>&1
  echo $?
}

# The default path: the switch is unset, both jobs are skipped, and the review is the proxy's.
assert_eq "switch unset, plan and producer skipped: the job goes on" "0" "$(run_gate '' skipped skipped)"
# The pool path, delivered.
assert_eq "switch file, plan and producer succeeded: the job goes on" "0" "$(run_gate file success success false)"
# The pool path, not delivered: each way a needed job can end without success.
assert_eq "switch file, producer failed: the job refuses" "1" "$(run_gate file success failure false)"
assert_eq "switch file, producer cancelled: the job refuses" "1" "$(run_gate file success cancelled false)"
assert_eq "switch file, producer skipped: the job refuses" "1" "$(run_gate file success skipped false)"
assert_eq "switch file, plan failed (the producer is then skipped): the job refuses" "1" "$(run_gate file failure skipped)"
assert_eq "switch file, plan skipped: the job refuses" "1" "$(run_gate file skipped skipped)"
# A net diff of nothing (a push that reverts every change): there is nothing to review, the plan job
# says so, the producer is skipped on purpose and the job goes on to reconcile the old threads.
assert_eq "switch file, empty net diff, producer skipped: the job goes on" "0" "$(run_gate file success skipped true)"
assert_eq "switch file, empty net diff, but the producer ran: the job refuses" "1" "$(run_gate file success success true)"
assert_eq "switch file, empty net diff, producer failed: the job refuses" "1" "$(run_gate file success failure true)"
assert_eq "switch file, empty net diff, plan failed: the job refuses" "1" "$(run_gate file failure skipped true)"
# The plan's answer is read exactly: anything but true or false is a plan that did not say.
assert_eq "switch file, plan succeeded with no answer on the diff: the job refuses" "1" "$(run_gate file success skipped '')"
assert_eq "switch file, plan answered something else: the job refuses" "1" "$(run_gate file success success yes)"
# A switch that is neither empty nor exactly file is a typo, never the default: an expression compares
# strings without regard to case, so `File` starts the jobs while the shell sees another value.
assert_eq "switch File: the job refuses" "1" "$(run_gate File success success false)"
assert_eq "switch proxy: the job refuses" "1" "$(run_gate proxy skipped skipped)"
# The default path with a needed job that ran is a contradiction, not a pass.
assert_eq "switch unset but the producer ran: the job refuses" "1" "$(run_gate '' skipped success)"

# Structure: the gate only holds when the job runs after a failed producer, and before it does any work.
assert_eq "pr-review needs plan and review-producer" "plan,review-producer" "$NEEDS"
assert_eq "pr-review runs after a failed producer (its if starts with !cancelled())" "true" \
  "$(case "$JOB_IF" in '!cancelled()'*) echo true ;; *) echo false ;; esac)"
assert_eq "the gate is the first step of pr-review" "0" "$GATE_INDEX"
assert_eq "the producer is the callable acceptance workflow at main" \
  "go-kure/.github/.github/workflows/review-pool-acceptance.yml@main" "$PRODUCER_USES"
assert_eq "the producer receives the caller's secrets" "inherit" "$PRODUCER_SECRETS"
# The caller's review configuration reaches the producer, from the same three inputs the proxy path reads.
assert_eq "the producer receives the caller's project context" '${{ inputs.pr_review_context }}' "$PRODUCER_WITH_CONTEXT"
assert_eq "the producer receives the caller's standards file" '${{ inputs.standards-file }}' "$PRODUCER_WITH_STANDARDS_FILE"
assert_eq "the producer receives the caller's standards source" '${{ inputs.standards-source }}' "$PRODUCER_WITH_STANDARDS_SOURCE"
# The empty-diff answer has to reach every place that acts on the producer.
assert_eq "the plan job outputs the base and whether the net diff is empty" "base,empty" "$PLAN_OUTPUTS"
for pair in "review-producer:$PRODUCER_IF" "download step:$DOWNLOAD_IF" "naming step:$NAME_IF"; do
  assert_eq "the ${pair%%:*} is skipped for an empty net diff" "true" \
    "$(case "${pair#*:}" in *"needs.plan.outputs.empty != 'true'"*) echo true ;; *) echo false ;; esac)"
done
# `case` on a variable, not a pipe into grep -q: under pipefail a grep that stops early can fail the
# pipeline for the writer, and a true match then reads false.
for pair in "plan:$PLAN_IF" "review-producer:$PRODUCER_IF"; do
  job="${pair%%:*}"
  cond="${pair#*:}"
  assert_eq "$job runs only when the switch is file" "true" \
    "$(case "$cond" in *"vars.PR_REVIEW_BACKEND == 'file'"*) echo true ;; *) echo false ;; esac)"
  assert_eq "$job runs only for same-repository pull requests" "true" \
    "$(case "$cond" in *'github.event.pull_request.head.repo.full_name == github.repository'*) echo true ;; *) echo false ;; esac)"
done

if [ "$failures" -gt 0 ]; then
  echo "pr-review-producer-gate-test: $failures failed, $pass_count passed" >&2
  exit 1
fi
echo "pr-review-producer-gate-test: passed: $pass_count, failed: 0"
