#!/usr/bin/env bash
# review-pool-revision-test.sh — the acceptance run reviews only commits this repository carries.
#
# The revision input is free-form and actions/checkout takes it as a ref, so a dispatch can name any
# ref of this repository, a fork pull request's refs/pull/N/head included. The review that follows
# runs with the sandbox off and this organization's backend credential in its environment, so
# content from outside the repository must never reach it. The resolve step is the only place that
# refuses such a commit, and its failure mode is quiet: a guard that admits an unreachable commit
# looks exactly like a guard that works, because the review then runs and reports a result.
#
# The step body is read out of the workflow rather than retyped here, so this suite tests the file
# CI will run. A retyped copy passes while the workflow is wrong.
#
# Each case builds a real repository and runs the step body in it. The reachability claim is about
# git's own answer, so a fixture that fakes that answer would prove nothing.
#
# Usage: review-pool-revision-test.sh [REPO_ROOT]
# Exit:  0 every case passed; 1 a case failed; 2 the step body could not be read.
# Needs: yq v4, git, bash.

set -uo pipefail

ROOT="${1:-.}"
WF="$ROOT/.github/workflows/review-pool-acceptance.yml"

if [ ! -f "$WF" ]; then
  echo "cannot read the acceptance workflow at $WF" >&2
  exit 2
fi

if ! BODY=$(yq -r \
  '.jobs.review.steps[] | select(.name == "Resolve the reviewed range") | .run' "$WF"); then
  # A failed parse can still print a body on stdout, so the content checks below would accept it and
  # the suite would test a fragment of a file yq could not read as a whole. The status is the only
  # thing that distinguishes that from a clean read.
  echo "yq failed to read $WF; the step body is not trustworthy" >&2
  exit 2
fi

# An absent step and an empty one produce the same empty string, so refuse rather than report zero
# failures over nothing.
if [ -z "${BODY//[[:space:]]/}" ] || [ "$BODY" = "null" ]; then
  echo "read no resolve step body from $WF" >&2
  exit 2
fi

PASS=0
FAIL=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# build_fixture DIR WITH_REMOTE
# Builds a repository shaped like the checkout the step runs in: two commits on a local branch, a
# remote-tracking ref for that branch when WITH_REMOTE is yes, and one commit that no branch
# reaches, kept under refs/pull to match where a fork pull request head actually lives.
# It prints the inside commit, then the outside commit.
build_fixture() {
  local dir="$1" with_remote="$2"
  git init -q -b main "$dir"
  git -C "$dir" -c user.email=t@example.invalid -c user.name=t \
    commit -q --allow-empty -m 'first'
  git -C "$dir" -c user.email=t@example.invalid -c user.name=t \
    commit -q --allow-empty -m 'second'
  local inside outside
  inside=$(git -C "$dir" rev-parse HEAD)
  if [ "$with_remote" = yes ]; then
    git -C "$dir" update-ref refs/remotes/origin/main "$inside"
  fi
  # The outside commit descends from the first commit, exactly as a fork pull request head does, so
  # a guard that only tested "is this a commit of this object store" would admit it.
  git -C "$dir" -c user.email=t@example.invalid -c user.name=t \
    commit-tree -p "$(git -C "$dir" rev-parse HEAD~1)" \
    -m 'outside content' "$(git -C "$dir" rev-parse 'HEAD^{tree}')" > "$dir/.outside"
  outside=$(tr -d '\n' < "$dir/.outside")
  git -C "$dir" update-ref refs/pull/9/head "$outside"
  printf '%s %s\n' "$inside" "$outside"
}

# run_step DIR HEAD_COMMIT BASE_INPUT
# Runs the step body with the repository checked out at HEAD_COMMIT, in a clean environment holding
# only what the step itself reads. A base input that sits in the caller's environment cannot leak in.
run_step() {
  local dir="$1" head="$2" base_input="$3"
  git -C "$dir" checkout -q --detach "$head"
  env -i PATH="$PATH" HOME="$dir" \
    REVIEW_BASE_INPUT="$base_input" \
    GITHUB_ENV="$dir/github_env" \
    bash -c "cd '$dir' && $BODY" 2>&1
}

# check LABEL WANT_RC WANT_TEXT DIR HEAD_COMMIT BASE_INPUT
# Both the exit code and the message are asserted. The admit case and the refuse case both exit on a
# code this step shares with every other failure, so the code alone names nothing.
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

read -r INSIDE OUTSIDE < <(build_fixture "$WORK/repo" yes)

# The ordinary dispatch: a commit of this repository, with the implicit base.
check 'a commit of this repository is reviewed' \
  0 "reviewed revision $INSIDE" "$WORK/repo" "$INSIDE" ''

# The finding's own case. The commit is in this repository's object store and under a real ref of
# it, and no branch reaches it. Without the guard the step resolves it and the review runs.
check 'a commit no branch reaches is refused' \
  1 'reachable from no branch of this repository' "$WORK/repo" "$OUTSIDE" ''

# The base decides the diff the review reads, so an outside base is the same exposure by another
# door. A guard on the revision alone passes this case while the review still reads outside content.
check 'an outside base is refused' \
  1 'reachable from no branch of this repository' "$WORK/repo" "$INSIDE" "$OUTSIDE"

# A base that is a commit of this repository is admitted, so the guard is not refusing every
# explicit base.
PARENT=$(git -C "$WORK/repo" rev-parse "$INSIDE^")
check 'an explicit base of this repository is reviewed' \
  0 "reviewed base     $PARENT" "$WORK/repo" "$INSIDE" "$PARENT"

# Fail closed. A repository with no remote-tracking branch is what a missing or partial fetch looks
# like, and the reachability read cannot tell that from outside content. Both must refuse: a guard
# that reads an empty branch list as "nothing to object to" is off whenever the fetch changes.
read -r INSIDE2 _ < <(build_fixture "$WORK/norefs" no)
check 'no fetched branch refuses rather than admits' \
  1 'reachable from no branch of this repository' "$WORK/norefs" "$INSIDE2" ''

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
