#!/usr/bin/env bash
# release-state.sh — decide, from the forge record alone, what a tag's publish
# run actually did.
#
# The publish runbooks in the caller repos used to ask an operator to answer this
# by hand, and answering it correctly needs six independent facts held at once.
# Each of the six was found as a separate review finding, one per round, over five
# rounds — and findings 3, 4 and 6 were each introduced or left open by the fix
# for the previous one. Correctness was being maintained by review rounds instead
# of by construction. Every one of the six is encoded here, and every one is
# pinned by a case in scripts/test/release-state-test.sh, so finding 7 arrives as
# a failing test rather than as a review comment on the next PR that touches the
# paragraph.
#
#   FACT 1  A full `gh run rerun <id>` re-resolves a reusable workflow at @main;
#           `--failed` and single-job re-runs pin to the FIRST attempt's SHA. The
#           two are not interchangeable, so the recovery advice names one and
#           warns off the other rather than saying "re-run it".
#   FACT 2  The release's asset count is NOT an oracle. How many assets a complete
#           release carries is decided by that tag's own .goreleaser.yml, and for a
#           library repo the correct count is zero. The count is REPORTED as
#           evidence and is never an input to the verdict.
#   FACT 3  `gh run view --json jobs` reports the LATEST attempt, which need not be
#           the attempt that ran goreleaser. Every attempt is queried, oldest to
#           newest, via the per-attempt jobs endpoint.
#   FACT 4  A re-run CARRIES NON-RERUN JOBS FORWARD unchanged, so an attempt's job
#           list mixes attempts. A carried-over row is identified by its own
#           started_at preceding that attempt's run_started_at — never by its
#           conclusion, which is identical either way.
#   FACT 5  The decision keys on NOT `success`, never on `failure`. A job cancelled
#           mid-upload concludes `cancelled`, and a `failure`-only test reads that
#           as fine.
#   FACT 6  `goreleaser: skipped` does not mean it never ran. It declares
#           `needs: [test, validate]`, so a re-run that fails in `test` skips it
#           while an earlier attempt's release object still exists.
#
# And one rule that is not a fact about GitHub but about this script: an API call
# that fails for a reason other than 404 yields NO state. `never-published` and
# "the API did not answer" are different claims, and collapsing them is how a
# recovery path proceeds on an undetermined answer.
#
# Usage:
#   release-state.sh [--state-only] <owner/repo> <tag>
#
# States (closed set, one of):
#   published         a goreleaser job concluded success in SOME attempt, and the
#                     release exists. Deliberately not "the most recent attempt":
#                     FACT 3 and FACT 6 both say a later attempt must not mask an
#                     earlier successful publish, so a re-run that fails in `test`
#                     afterwards leaves the state `published`.
#   partial           the release exists, the publishing job RAN, and it never
#                     concluded success in any attempt — it failed or was
#                     cancelled, so the release may be incomplete
#   never-published   no release object, and no successful goreleaser job
#   contradictory     the run record and the release object disagree, in either
#                     direction: a release exists that the job never ran to
#                     produce, OR the job succeeded and the release is gone
#   no-run-found      no workflow run for this tag at all
#
# Exit: 0 when a state was determined, 1 when it could not be (API failure — the
# state is then reported as `undetermined` and must not be branched on), 2 on a
# usage error.
#
# Requires: gh (authenticated), jq.

set -uo pipefail

STATE_ONLY=false
REPO=""
TAG=""

# The job that creates the release object. Named once: every reference below goes
# through this, so a rename in release-publish.yml is a one-line change here and a
# failing test rather than a silently wrong verdict.
PUBLISH_JOB="${RELEASE_STATE_PUBLISH_JOB:-goreleaser}"

usage() {
    cat <<'EOF'
Usage: release-state.sh [--state-only] <owner/repo> <tag>

Decide what a tag's publish run actually did, from the forge record.

  --state-only   print only the state word, no evidence block
  --help         this text

States: published | partial | never-published | contradictory | no-run-found
Exit:   0 determined, 1 undetermined (API failure), 2 usage error
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --state-only) STATE_ONLY=true; shift ;;
        --help|-h) usage; exit 0 ;;
        -*) echo "release-state.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            if [ -z "$REPO" ]; then REPO="$1"
            elif [ -z "$TAG" ]; then TAG="$1"
            else echo "release-state.sh: unexpected argument: $1" >&2; exit 2
            fi
            shift
            ;;
    esac
done

if [ -z "$REPO" ] || [ -z "$TAG" ]; then
    usage >&2
    exit 2
fi
case "$REPO" in
    */*) ;;
    *) echo "release-state.sh: <owner/repo> must contain a slash, got '$REPO'" >&2; exit 2 ;;
esac

for tool in gh jq; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "release-state.sh: $tool is required but not installed" >&2; exit 2; }
done

EVIDENCE=()
note() { EVIDENCE+=("$*"); }

# emit <state> <rc> [advice-key]
#
# The third argument exists because one state word can be reached from opposite
# evidence. `contradictory` covers both "a release exists that nothing in the run
# record produced" and "a success is recorded but the release object is gone" —
# the operator's next move differs, and printing one text for both told them a
# release existed when the lookup had just 404'd. The STATE word stays the closed
# set a caller branches on; only the prose varies.
emit() {
    local state="$1" rc="$2" advice_key="${3:-$1}"
    if [ "$STATE_ONLY" = true ]; then
        printf '%s\n' "$state"
    else
        printf 'release-state %s %s\n' "$REPO" "$TAG"
        printf '\nEvidence:\n'
        local line
        for line in "${EVIDENCE[@]}"; do printf '  %s\n' "$line"; done
        printf '\n%s\n' "$(advice "$advice_key")"
        printf '\nSTATE: %s\n' "$state"
    fi
    exit "$rc"
}

advice() {
    case "$1" in
        published)
            cat <<EOF
Nothing to do. The publishing job succeeded and the release object exists.
If the asset list looks wrong, check that TAG's own .goreleaser.yml before
concluding anything — the correct count for a library repo is zero, so the
number of assets proves nothing on its own (FACT 2).
EOF
            ;;
        partial)
            cat <<EOF
The release object exists, the publishing job ran, and it never concluded success
in any attempt — it failed or was cancelled, so the release may be incomplete.

Re-run the WHOLE run:      gh run rerun <run-id> --repo $REPO
Do NOT use --failed or a single-job re-run: those pin the reusable workflow to
the FIRST attempt's commit, so a fix merged to the shared workflow since then
will not be picked up (FACT 1).

Deleting the release object is an escalation, not a step in this path.
EOF
            ;;
        never-published)
            cat <<EOF
No release object and no successful publishing job. Re-running the whole run is
safe:                      gh run rerun <run-id> --repo $REPO
Do NOT use --failed or a single-job re-run (FACT 1).
EOF
            ;;
        contradictory)
            cat <<EOF
A release object exists that no recorded attempt produced — the publishing job
never ran to a conclusion in any attempt of any run for this tag (it was skipped
or absent throughout). Something outside the run record created it (a manual
release, or a run that no longer exists).

Do not re-run and do not delete. Escalate: the run record cannot tell you what
that release object contains.
EOF
            ;;
        contradictory-vanished)
            cat <<EOF
The opposite direction: the publishing job DID conclude success, but the release
object is gone — the lookup returned 404. Something removed it after the fact.

Do not re-run. A re-run would republish under a tag whose previous contents you
cannot see, and you do not yet know whether the removal was deliberate.
Escalate: establish who or what deleted it first.
EOF
            ;;
        no-run-found)
            cat <<EOF
No workflow run was found for this tag. Check that the tag was actually pushed
and that the publish workflow is triggered for it, before concluding anything
about the release.
EOF
            ;;
        undetermined)
            cat <<EOF
The state could not be determined: an API call failed for a reason other than a
404. This is NOT "never published" — do not branch on it. Retry, and if it
persists, check gh auth status and the API's status page.
EOF
            ;;
    esac
}

# --- forge access -------------------------------------------------------------
#
# gh_json <api-path> -> body on stdout.
# Returns 0 on success, 44 on a genuine 404, 1 on anything else. Three outcomes,
# not two: a 404 is a fact about the resource, every other failure is an absence
# of information, and the caller must be able to tell them apart.
gh_json() {
    local path="$1" body err rc
    err=$(mktemp) || return 1
    body=$(gh api "$path" 2>"$err")
    rc=$?
    if [ "$rc" -eq 0 ]; then
        rm -f "$err"
        printf '%s' "$body"
        return 0
    fi
    if grep -q 'HTTP 404' "$err"; then
        rm -f "$err"
        return 44
    fi
    echo "release-state.sh: API call failed: $path" >&2
    sed 's/^/  /' "$err" >&2
    rm -f "$err"
    return 1
}

# gh_jobs <api-path> -> {"jobs": [...]} on stdout, same three return codes.
#
# The jobs endpoint paginates, and its default page is 30. A matrixed workflow
# passes 30 jobs without anyone noticing, and a single default page then omits
# the publishing job entirely — at which point this script reports "no publishing
# job in this attempt's job list" and concludes `contradictory` for a tag that
# published perfectly. That failure grows with the caller's job count, so it
# would have arrived long after the script was trusted.
gh_jobs() {
    local path="$1" body err rc
    err=$(mktemp) || return 1
    body=$(gh api --paginate --slurp "${path}?per_page=100" 2>"$err")
    rc=$?
    if [ "$rc" -eq 0 ]; then
        rm -f "$err"
        # --slurp wraps each page as one element; merge the pages' job arrays
        # back into the single-object shape the caller reads.
        printf '%s' "$body" \
            | jq -c 'if type == "array"
                     then {jobs: (map(.jobs // []) | add // [])}
                     else . end'
        return 0
    fi
    if grep -q 'HTTP 404' "$err"; then
        rm -f "$err"
        return 44
    fi
    echo "release-state.sh: API call failed: $path" >&2
    sed 's/^/  /' "$err" >&2
    rm -f "$err"
    return 1
}

# --- 1. the release object ----------------------------------------------------

RELEASE_EXISTS=false
release_json=""
release_json=$(gh_json "repos/$REPO/releases/tags/$TAG")
case $? in
    0)
        RELEASE_EXISTS=true
        note "release object: EXISTS (created $(printf '%s' "$release_json" | jq -r '.created_at // "?"'), draft=$(printf '%s' "$release_json" | jq -r '.draft // false'), prerelease=$(printf '%s' "$release_json" | jq -r '.prerelease // false'))"
        # Reported, never decisive — see FACT 2.
        note "release assets: $(printf '%s' "$release_json" | jq -r '.assets | length') (evidence only; the correct count is decided by that tag's .goreleaser.yml, and is zero for a library repo)"
        ;;
    44)
        note "release object: ABSENT (HTTP 404 for the tag, which is a fact about the resource, not a failed lookup)"
        ;;
    *)
        note "release object: LOOKUP FAILED for a reason other than 404"
        emit undetermined 1
        ;;
esac

# --- 2. the runs for this tag -------------------------------------------------

if ! runs_json=$(gh run list --repo "$REPO" --branch "$TAG" --limit 50 \
        --json databaseId,workflowName,status,conclusion,createdAt,headBranch 2>/dev/null) \
   || [ -z "$runs_json" ]; then
    note "run list: LOOKUP FAILED for the tag"
    emit undetermined 1
fi

run_ids=$(printf '%s' "$runs_json" | jq -r --arg tag "$TAG" \
    '[.[] | select(.headBranch == $tag)] | sort_by(.createdAt) | .[].databaseId')

if [ -z "$run_ids" ]; then
    note "runs for this tag: NONE"
    emit no-run-found 0
fi
note "runs for this tag: $(printf '%s\n' "$run_ids" | grep -c .) ($(printf '%s' "$run_ids" | tr '\n' ' '))"

# --- 3. every attempt of every run --------------------------------------------
#
# FACT 3: `gh run view --json jobs` would answer only for the latest attempt. The
# per-attempt endpoint is queried for every attempt instead, oldest first.

PUBLISH_SUCCEEDED=false
PUBLISH_RAN_AT_ALL=false
LAST_PUBLISH_CONCLUSION=""
LAST_PUBLISH_RUN=""
LAST_PUBLISH_ATTEMPT=""

while read -r run_id; do
    [ -n "$run_id" ] || continue

    run_json=$(gh_json "repos/$REPO/actions/runs/$run_id")
    case $? in
        0) ;;
        44) note "run $run_id: 404 — skipped"; continue ;;
        *) note "run $run_id: LOOKUP FAILED"; emit undetermined 1 ;;
    esac

    attempts=$(printf '%s' "$run_json" | jq -r '.run_attempt // 1')
    note "run $run_id: $attempts attempt(s), workflow '$(printf '%s' "$run_json" | jq -r '.name // "?"')'"

    n=1
    while [ "$n" -le "$attempts" ]; do
        attempt_json=$(gh_json "repos/$REPO/actions/runs/$run_id/attempts/$n")
        case $? in
            0) ;;
            44) note "  attempt $n: 404 — skipped"; n=$((n + 1)); continue ;;
            *) note "  attempt $n: LOOKUP FAILED"; emit undetermined 1 ;;
        esac
        attempt_started=$(printf '%s' "$attempt_json" | jq -r '.run_started_at // ""')

        jobs_json=$(gh_jobs "repos/$REPO/actions/runs/$run_id/attempts/$n/jobs")
        case $? in
            0) ;;
            44) note "  attempt $n: jobs 404 — skipped"; n=$((n + 1)); continue ;;
            *) note "  attempt $n: jobs LOOKUP FAILED"; emit undetermined 1 ;;
        esac

        # FACT 4: a job whose own started_at precedes this attempt's
        # run_started_at was CARRIED FORWARD from an earlier attempt, not run
        # here. Its conclusion is identical either way, so the conclusion cannot
        # be used to tell them apart — only the timestamps can.
        # A job called from a reusable workflow is reported under the CALLER's
        # job id, not its own: `release-publish.yml`'s `goreleaser` appears in
        # kure's run as `release / goreleaser`. An exact-name match therefore
        # finds nothing in production, and "no publishing job in any attempt"
        # then reads as `contradictory` — the right verdict for every tag, for
        # entirely the wrong reason, on a script that never once located the job.
        # Match the last `/`-separated segment, and report the full name so the
        # evidence shows which job was actually read.
        row=$(printf '%s' "$jobs_json" | jq -r \
            --arg job "$PUBLISH_JOB" --arg started "$attempt_started" '
            [ .jobs[]? | select((.name | split(" / ") | last) == $job) ] | .[0] // empty
            | [ (.name),
                (.conclusion // "null"),
                (.status // "null"),
                (if ($started != "" and (.started_at // "") != "" and (.started_at < $started))
                 then "carried" else "ran-here" end) ] | @tsv')

        if [ -z "$row" ]; then
            note "  attempt $n: no '$PUBLISH_JOB' job in this attempt's job list"
        else
            IFS=$'\t' read -r job_name conclusion status origin <<<"$row"
            note "  attempt $n: $job_name conclusion=$conclusion status=$status ($origin)"

            # FACT 6: `skipped` means `needs: [test, validate]` was not satisfied
            # in THIS attempt. It says nothing about any other attempt, so it is
            # not counted as the job having run.
            if [ "$conclusion" != "skipped" ] && [ "$conclusion" != "null" ]; then
                PUBLISH_RAN_AT_ALL=true
                # FACT 5: key on success, so every other conclusion — failure,
                # cancelled, timed_out, action_required — falls to the not-success
                # branch. A `failure`-only test reads a mid-upload cancel as fine.
                if [ "$conclusion" = "success" ]; then
                    PUBLISH_SUCCEEDED=true
                fi
                # FACT 4, applied rather than merely computed. The outcome above
                # counts from any row — a carried row repeats a real result and
                # does not stop being true for being copied — but the PROVENANCE
                # may only come from a row that ran in this attempt. Recording a
                # carried row's attempt here names an attempt that never executed
                # the job, which is exactly the conflation `origin` exists to
                # prevent; computing `origin` and then not consulting it is the
                # same defect as never computing it.
                if [ "$origin" = "ran-here" ]; then
                    LAST_PUBLISH_CONCLUSION="$conclusion"
                    LAST_PUBLISH_RUN="$run_id"
                    LAST_PUBLISH_ATTEMPT="$n"
                fi
            fi
        fi

        n=$((n + 1))
    done
done <<<"$run_ids"

if [ "$PUBLISH_SUCCEEDED" = true ]; then
    note "verdict input: '$PUBLISH_JOB' concluded success in at least one attempt"
elif [ "$PUBLISH_RAN_AT_ALL" = true ]; then
    if [ -n "$LAST_PUBLISH_RUN" ]; then
        note "verdict input: '$PUBLISH_JOB' ran but never succeeded; last non-skipped conclusion '$LAST_PUBLISH_CONCLUSION' (run $LAST_PUBLISH_RUN attempt $LAST_PUBLISH_ATTEMPT)"
    else
        # Every non-skipped row seen was carried forward, so the attempt that
        # actually ran the job is not in the record this script could read —
        # say that, rather than naming an attempt that merely inherited the row.
        note "verdict input: '$PUBLISH_JOB' ran but never succeeded; every row seen was carried forward, so no attempt here executed it"
    fi
else
    note "verdict input: '$PUBLISH_JOB' never ran in any attempt (skipped or absent throughout)"
fi

# --- 4. the verdict -----------------------------------------------------------

# A success in ANY attempt wins, not the most recent one. FACT 3 (a later attempt
# does not mask an earlier successful publish) and FACT 6 (a re-run failing in
# `test` skips goreleaser while the earlier release still exists) both require
# this, so a run whose attempt 1 published and whose attempt 2 failed is
# `published` — the release did ship, and "Nothing to do" is the correct advice.
# `partial` is therefore the never-succeeded-but-did-run case, which is reachable
# and distinct; it is not the most-recent-attempt-failed case.
if [ "$PUBLISH_SUCCEEDED" = true ]; then
    # A success plus a missing release object is not "published": something
    # removed the release after the fact, and that is exactly the shape that must
    # not be quietly re-run.
    if [ "$RELEASE_EXISTS" = true ]; then
        emit published 0
    fi
    note "verdict input: success recorded but NO release object — the two disagree"
    emit contradictory 0 contradictory-vanished
fi

if [ "$RELEASE_EXISTS" = true ]; then
    if [ "$PUBLISH_RAN_AT_ALL" = true ]; then
        emit partial 0
    fi
    # FACT 6's real consequence: skipped everywhere while a release exists means
    # nothing in the run record published it.
    emit contradictory 0
fi

emit never-published 0
