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
# The fixture models the ref layout the pinned checkout actually produces, which is the whole point
# of the suite. At fetch-depth 0 that action fetches +refs/heads/*:refs/remotes/origin/* and
# +refs/tags/*:refs/tags/*, and when the requested ref is refs/pull/N/head it also fetches that head
# into refs/remotes/pull/N/head. A fixture that keeps the outside commit only under refs/pull/9/head
# is therefore the easy case: a guard reading every remote-tracking ref passes it while the real
# checkout would hand the fork head straight to the review.
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

GIT_ID=(-c user.email=t@example.invalid -c user.name=t)

# sibling DIR PARENT MESSAGE
# Writes a commit that descends from PARENT and sits on no branch, exactly as a fork pull request
# head does. A guard that only asked "is this a commit of this object store" would admit it.
sibling() {
  local dir="$1" parent="$2" message="$3"
  git -C "$dir" "${GIT_ID[@]}" commit-tree -p "$parent" -m "$message" \
    "$(git -C "$dir" rev-parse 'HEAD^{tree}')"
}

# build_fixture DIR MODE
# MODE=full       the ref layout a real dispatch produces: the repository's branches under
#                 refs/remotes/origin/, its tags under refs/tags/, and the requested fork head under
#                 refs/remotes/pull/9/head as well as refs/pull/9/head.
# MODE=notrusted  a checkout where the fetch created no trusted ref at all, with the fork head's
#                 tracking ref still present, so an empty trusted set cannot be papered over by the
#                 pull namespace.
# Prints: INSIDE OUTSIDE TAGGED FEATURE
build_fixture() {
  local dir="$1" mode="$2"
  git init -q -b main "$dir"
  git -C "$dir" "${GIT_ID[@]}" commit -q --allow-empty -m 'first'
  git -C "$dir" "${GIT_ID[@]}" commit -q --allow-empty -m 'second'
  local inside parent outside tagged feature
  inside=$(git -C "$dir" rev-parse HEAD)
  parent=$(git -C "$dir" rev-parse 'HEAD^')
  outside=$(sibling "$dir" "$parent" 'outside content, as a fork pull request head')
  tagged=$(sibling "$dir" "$parent" 'a release this organization tagged, its branch since deleted')
  feature=$(sibling "$dir" "$parent" 'an unmerged branch of this organization')
  # The fork head reaches the checkout through both namespaces, and the tracking one is the ref that
  # makes a test over every remote-tracking ref admit it.
  git -C "$dir" update-ref refs/pull/9/head "$outside"
  git -C "$dir" update-ref refs/remotes/pull/9/head "$outside"
  if [ "$mode" = full ]; then
    git -C "$dir" update-ref refs/remotes/origin/main "$inside"
    git -C "$dir" update-ref refs/remotes/origin/feature "$feature"
    git -C "$dir" update-ref refs/tags/v1 "$tagged"
  fi
  printf '%s %s %s %s\n' "$inside" "$outside" "$tagged" "$feature"
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
# code this step shares with every other failure, so the code alone names nothing. The refusal cases
# assert which endpoint the message names, because a dispatcher that cannot tell the revision from
# the base cannot act on the refusal.
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

read -r INSIDE OUTSIDE TAGGED FEATURE < <(build_fixture "$WORK/repo" full)
PARENT=$(git -C "$WORK/repo" rev-parse "$INSIDE^")

# The ordinary dispatch: a commit of this repository, with the implicit base.
check 'a commit of this repository is reviewed' \
  0 "reviewed revision $INSIDE" "$WORK/repo" "$INSIDE" ''

# The finding's own case, and the one the first version of this guard got wrong. The commit sits
# under refs/remotes/pull/9/head, which is where the real checkout puts a requested fork head, so a
# guard that reads every remote-tracking ref admits it and the review runs with the credential.
check 'a fork pull request head is refused' \
  1 'the reviewed revision' "$WORK/repo" "$OUTSIDE" ''

# The base decides the diff the review reads, so an outside base is the same exposure by another
# door. A guard on the revision alone passes this case while the review still reads outside content.
check 'an outside base is refused, and the message names the base' \
  1 'the reviewed base' "$WORK/repo" "$INSIDE" "$OUTSIDE"

# A base that is a commit of this repository is admitted, so the guard is not refusing every
# explicit base.
check 'an explicit base of this repository is reviewed' \
  0 "reviewed base     $PARENT" "$WORK/repo" "$INSIDE" "$PARENT"

# Tags are trusted on purpose. A commit this organization tagged is code this repository carries,
# and the branch that held it may since have been deleted, so a branches-only test refuses a
# dispatch over a retained release.
check 'a commit only a tag of this repository reaches is reviewed' \
  0 "reviewed revision $TAGGED" "$WORK/repo" "$TAGGED" ''

# The deliberate deviation from the review comment's suggestion, pinned as a case. Reachability from
# the default branch alone would refuse this organization's own unmerged branches, which is the case
# this workflow is dispatched on.
check 'an unmerged branch of this repository is reviewed' \
  0 "reviewed revision $FEATURE" "$WORK/repo" "$FEATURE" ''

# Fail closed, with its own message. A checkout whose fetch created no trusted ref is what a missing
# or partial fetch looks like, and the reachability read cannot tell that from outside content. The
# fork head's tracking ref is present here, so this also asserts that the pull namespace does not
# count towards the trusted set.
read -r INSIDE2 _ < <(build_fixture "$WORK/notrusted" notrusted)
check 'no trusted ref refuses, and says so in its own words' \
  1 'no branch or tag of this repository was fetched' "$WORK/notrusted" "$INSIDE2" ''

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
