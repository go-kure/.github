#!/usr/bin/env bash
# Tests for scripts/release-state.sh
#
# One case per fact named in go-kure/.github#205, plus one per state in the
# closed set. The point of the issue is that each of those facts stops being a
# sentence an operator re-derives and becomes something that fails loudly, so a
# case here that merely PASSES is not enough — each was checked by mutating the
# script so that fact is handled wrongly and confirming this case, and only this
# case, then fails. Where a single case could pass for the wrong reason, it is
# paired with a differential: FACT 2 in particular is asserted by a pair of cases
# whose asset counts are swapped relative to their verdicts, because no single
# case can show that a number was ignored.
#
# Offline by construction: `gh` is stubbed onto PATH and every fixture is written
# here, so this needs no token, no network and no real repository.
#
# Run: bash scripts/test/release-state-test.sh .

set -uo pipefail # deliberately not -e: assertions continue past failures so one
                 # run reports every problem, not just the first.

ROOT="${1:-.}"
SCRIPT="$ROOT/scripts/release-state.sh"

failures=0
pass_count=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    shift
    local line
    for line in "$@"; do printf '      %s\n' "$line" >&2; done
    failures=$((failures + 1))
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass_count=$((pass_count + 1))
    else
        fail "$label" "expected: $expected" "actual:   $actual"
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) pass_count=$((pass_count + 1)) ;;
        *) fail "$label" "expected to contain: $needle" "actual output:" "$haystack" ;;
    esac
}

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) fail "$label" "expected NOT to contain: $needle" "actual output:" "$haystack" ;;
        *) pass_count=$((pass_count + 1)) ;;
    esac
}

if [ ! -f "$SCRIPT" ]; then
    fail "release-state.sh not found at $SCRIPT"
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

# --- the gh stub --------------------------------------------------------------
#
# Answers exactly the five request shapes release-state.sh makes, from files in
# $MOCK_DIR, and appends every request to $MOCK_LOG so a case can assert what was
# EXECUTED and not only what was printed. A 404 is emitted in gh's own wording
# (`(HTTP 404)`) because the script's 404-vs-everything-else split reads that
# text — stubbing a different wording would test a path production never takes.

cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${MOCK_LOG:-/dev/null}"

case "${1:-}" in
  api)
    # The path is the first non-flag argument, not $2: the jobs fetch calls
    # `gh api --paginate --slurp <path>?per_page=100`, and a stub that assumed $2
    # would silently start matching on the literal string "--paginate".
    shift
    path=""
    for a in "$@"; do
      case "$a" in -*) ;; *) path="$a"; break ;; esac
    done
    path="${path%%\?*}"
    case "$path" in
      */releases/tags/*)
        if [ -f "$MOCK_DIR/release.status" ]; then
          code=$(cat "$MOCK_DIR/release.status")
          echo "gh: Server Error (HTTP $code)" >&2
          exit 1
        fi
        if [ -f "$MOCK_DIR/release.json" ]; then cat "$MOCK_DIR/release.json"; exit 0; fi
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1
        ;;
      */actions/runs/*/attempts/*/jobs)
        id=${path#*/actions/runs/}; id=${id%%/*}
        rest=${path#*/attempts/}; n=${rest%%/*}
        f="$MOCK_DIR/run-$id-attempt-$n-jobs.json"
        ;;
      */actions/runs/*/attempts/*)
        id=${path#*/actions/runs/}; id=${id%%/*}
        n=${path##*/attempts/}
        f="$MOCK_DIR/run-$id-attempt-$n.json"
        ;;
      */actions/runs/*)
        id=${path##*/actions/runs/}
        f="$MOCK_DIR/run-$id.json"
        ;;
      # The run LIST, reached as a paginated REST call rather than `gh run list`.
      # Matched after the per-run arms above, which are strictly longer paths.
      */actions/runs)
        if [ -f "$MOCK_DIR/runs.json" ]; then cat "$MOCK_DIR/runs.json"; exit 0; fi
        echo "gh: Server Error (HTTP 500)" >&2
        exit 1
        ;;
      *)
        echo "gh: stub received an unexpected api path: $path" >&2
        exit 1
        ;;
    esac
    if [ -f "$f" ]; then cat "$f"; exit 0; fi
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
    ;;
  run)
    if [ -f "$MOCK_DIR/runs.json" ]; then cat "$MOCK_DIR/runs.json"; exit 0; fi
    echo "gh: run list failed" >&2
    exit 1
    ;;
esac

echo "gh: stub received an unexpected invocation: $*" >&2
exit 1
STUB
chmod +x "$BIN/gh"

# --- fixture helpers ----------------------------------------------------------

new_case() {
    local dir="$WORK/$1"
    mkdir -p "$dir"
    printf '%s' "$dir"
}

write_release() { # <dir> <asset-count>
    local dir="$1" n="$2" assets="" i=0
    while [ "$i" -lt "$n" ]; do
        [ -z "$assets" ] || assets="$assets,"
        assets="$assets{\"name\":\"artifact-$i.tar.gz\"}"
        i=$((i + 1))
    done
    printf '{"tag_name":"v1.0.0","created_at":"2026-09-01T10:00:00Z","draft":false,"prerelease":false,"assets":[%s]}\n' \
        "$assets" >"$dir/release.json"
}

# The run list is the REST payload, paginated and slurped — an array of page
# objects each carrying a `workflow_runs` envelope, with REST field names
# (`id`, `head_branch`, `created_at`), not gh's own `--json` view
# (`databaseId`, `headBranch`, `createdAt`). `gh run list --limit N` was
# replaced because it silently drops the oldest runs past N, which are the ones
# that carry the evidence a publish succeeded.
write_runs() { # <dir> <tag> <run-id>...
    local dir="$1" tag="$2"; shift 2
    local out="" id
    for id in "$@"; do
        [ -z "$out" ] || out="$out,"
        out="$out{\"id\":$id,\"name\":\"Release / Publish\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-09-01T09:00:00Z\",\"head_branch\":\"$tag\"}"
    done
    printf '[{"total_count":%s,"workflow_runs":[%s]}]\n' "$#" "$out" >"$dir/runs.json"
}

# Two pages of runs, so a case can put the ORIGINAL (oldest) run on page 2 —
# the exact row a capped, unpaginated list drops.
write_runs_paged() { # <dir> <tag> <page1-ids...> -- <page2-ids...>
    local dir="$1" tag="$2"; shift 2
    local p1=() p2=() seen=0 id out1="" out2=""
    for id in "$@"; do
        if [ "$id" = "--" ]; then seen=1; continue; fi
        if [ "$seen" = 0 ]; then p1+=("$id"); else p2+=("$id"); fi
    done
    for id in "${p1[@]}"; do
        [ -z "$out1" ] || out1="$out1,"
        out1="$out1{\"id\":$id,\"name\":\"Release / Publish\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-09-02T09:00:00Z\",\"head_branch\":\"$tag\"}"
    done
    for id in "${p2[@]}"; do
        [ -z "$out2" ] || out2="$out2,"
        out2="$out2{\"id\":$id,\"name\":\"Release / Publish\",\"status\":\"completed\",\"conclusion\":\"success\",\"created_at\":\"2026-09-01T09:00:00Z\",\"head_branch\":\"$tag\"}"
    done
    printf '[{"total_count":%s,"workflow_runs":[%s]},{"total_count":%s,"workflow_runs":[%s]}]\n' \
        "${#p1[@]}" "$out1" "${#p2[@]}" "$out2" >"$dir/runs.json"
}

write_run() { # <dir> <run-id> <attempt-count>
    printf '{"id":%s,"name":"Release / Publish","run_attempt":%s}\n' "$2" "$3" \
        >"$1/run-$2.json"
}

write_attempt() { # <dir> <run-id> <attempt> <run_started_at>
    printf '{"run_attempt":%s,"run_started_at":"%s"}\n' "$3" "$4" \
        >"$1/run-$2-attempt-$3.json"
}

# Spec is <name=conclusion=started_at[=status]>. `status` defaults to
# `completed`; a spec whose conclusion is the bare word `null` emits JSON null
# rather than the string, because that is what the forge sends for a job that
# has not concluded and the two are handled differently.
job_objects() { # <attempt> <spec>... -> JSON array body
    local attempt="$1"; shift
    local out="" spec name conclusion started status concl_json
    for spec in "$@"; do
        IFS='=' read -r name conclusion started status <<<"$spec"
        [ -n "$status" ] || status="completed"
        if [ "$conclusion" = "null" ]; then concl_json="null"
        else concl_json="\"$conclusion\""
        fi
        [ -z "$out" ] || out="$out,"
        out="$out{\"name\":\"$name\",\"conclusion\":$concl_json,\"status\":\"$status\",\"started_at\":\"$started\",\"run_attempt\":$attempt}"
    done
    printf '%s' "$out"
}

# The fixture is an ARRAY of page objects, because that is what `gh api
# --paginate --slurp` returns, and the merge back to a single object is
# production code that has to be exercised rather than assumed.
write_jobs() { # <dir> <run-id> <attempt> <name=conclusion=started_at>...
    local dir="$1" id="$2" attempt="$3"; shift 3
    printf '[{"total_count":%s,"jobs":[%s]}]\n' "$#" "$(job_objects "$attempt" "$@")" \
        >"$dir/run-$id-attempt-$attempt-jobs.json"
}

# Two pages, so the case can put the publishing job on the SECOND one.
write_jobs_paged() { # <dir> <run-id> <attempt> <page1-specs...> -- <page2-specs...>
    local dir="$1" id="$2" attempt="$3"; shift 3
    local p1=() p2=() seen=0 spec
    for spec in "$@"; do
        if [ "$spec" = "--" ]; then seen=1; continue; fi
        if [ "$seen" = 0 ]; then p1+=("$spec"); else p2+=("$spec"); fi
    done
    printf '[{"total_count":%s,"jobs":[%s]},{"total_count":%s,"jobs":[%s]}]\n' \
        "${#p1[@]}" "$(job_objects "$attempt" "${p1[@]}")" \
        "${#p2[@]}" "$(job_objects "$attempt" "${p2[@]}")" \
        >"$dir/run-$id-attempt-$attempt-jobs.json"
}

OUT=""
RC=0
run_case() { # <dir> <args>...
    local dir="$1"; shift
    OUT=$(MOCK_DIR="$dir" MOCK_LOG="$dir/requests.log" PATH="$BIN:$PATH" \
        bash "$SCRIPT" "$@" 2>&1)
    RC=$?
}

echo "== release-state.sh =="

# --- FACT 3 + FACT 6 + FACT 2 (zero assets) -----------------------------------
#
# goreleaser SUCCEEDED in attempt 1. Attempt 2 was re-run, failed in `test`, and
# so shows `goreleaser: skipped` — which is what `gh run view --json jobs` would
# report, because it answers for the latest attempt only. The release exists and
# carries ZERO assets, which is the correct count for a library repo.
#
# A script that read only the latest attempt returns `contradictory` here. One
# that treated `skipped` as "never ran" returns `contradictory` here. One that
# used the asset count as an oracle returns `partial` here. The right answer is
# `published`, and it is reachable only by querying every attempt.
d=$(new_case latest-attempt-skipped)
write_release "$d" 0
write_runs "$d" v1.0.0 5001
write_run "$d" 5001 2
write_attempt "$d" 5001 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5001 1 \
    "test=success=2026-09-01T09:01:00Z" \
    "validate=success=2026-09-01T09:01:00Z" \
    "goreleaser=success=2026-09-01T09:05:00Z"
write_attempt "$d" 5001 2 "2026-09-01T11:00:00Z"
write_jobs "$d" 5001 2 \
    "test=failure=2026-09-01T11:01:00Z" \
    "validate=success=2026-09-01T11:01:00Z" \
    "goreleaser=skipped=2026-09-01T11:05:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_eq "FACT 3+6: an earlier attempt's success is not masked by a later skip" \
    "published" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"
assert_eq "FACT 3+6: exit 0 when a state was determined" 0 "$RC"
assert_contains "FACT 3: attempt 1 was queried, not just the latest" \
    "$OUT" "attempt 1: goreleaser conclusion=success"
assert_contains "FACT 6: the skipped row is reported, not silently dropped" \
    "$OUT" "attempt 2: goreleaser conclusion=skipped"
assert_contains "FACT 3: both attempts were actually requested" \
    "$(cat "$d/requests.log")" "attempts/2/jobs"

# --- reusable-workflow job naming ---------------------------------------------
#
# Fixture copied from the real run for go-kure/kure v0.2.0-beta.11
# (repos/go-kure/kure/actions/runs/34512030764/attempts/3/jobs, read
# 2026-09-11): jobs called from a reusable workflow are reported under the
# CALLER's job id, so the publishing job is `release / goreleaser`, never
# `goreleaser`.
#
# This case exists because an exact-name match shipped first and looked correct:
# it found no publishing job in ANY attempt, so it answered `contradictory` for
# that tag — which is the right answer — while having never located the job at
# all. That failure mode returns `contradictory` for every tag ever passed to it,
# including healthy ones, so the assertion below is on `published`, where a
# name mismatch is visible.
d=$(new_case reusable-workflow-job-names)
write_release "$d" 0
write_runs "$d" v1.0.0 5012
write_run "$d" 5012 1
write_attempt "$d" 5012 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5012 1 \
    "release / Test=success=2026-09-01T09:01:00Z" \
    "release / Validate tag and changelog=success=2026-09-01T09:01:00Z" \
    "release / goreleaser=success=2026-09-01T09:05:00Z" \
    "release / post-release=success=2026-09-01T09:09:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_eq "a reusable-workflow job prefix does not hide the publishing job" \
    "published" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"
assert_contains "the evidence names the job as the forge reports it" \
    "$OUT" "attempt 1: release / goreleaser conclusion=success"
assert_not_contains "the publishing job was located, not missed" \
    "$OUT" "no 'goreleaser' job in this attempt"

# --- FACT 2, the other half of the differential -------------------------------
#
# Same shape, THREE assets this time, but goreleaser was cancelled. If the asset
# count fed the verdict at all, this case and the one above would have to agree
# with their counts; they deliberately disagree. `partial` here plus `published`
# above is the only pair that shows the number was ignored — neither case alone
# can, because either verdict is explicable by the count.
d=$(new_case assets-present-but-cancelled)
write_release "$d" 3
write_runs "$d" v1.0.0 5002
write_run "$d" 5002 1
write_attempt "$d" 5002 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5002 1 \
    "test=success=2026-09-01T09:01:00Z" \
    "validate=success=2026-09-01T09:01:00Z" \
    "goreleaser=cancelled=2026-09-01T09:05:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_eq "FACT 2+5: three assets do not make a cancelled publish a success" \
    "partial" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"
assert_contains "FACT 2: the asset count is reported as evidence only" \
    "$OUT" "release assets: 3 (evidence only"

# --- FACT 5 -------------------------------------------------------------------
#
# `cancelled` is neither `success` nor `failure`. A test written against
# `failure` reads the case above as fine; this asserts the script keys on
# not-success. `timed_out` is the same class and is checked here so the branch
# is shown to be general rather than a `cancelled` special case.
d=$(new_case timed-out)
write_release "$d" 0
write_runs "$d" v1.0.0 5003
write_run "$d" 5003 1
write_attempt "$d" 5003 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5003 1 "goreleaser=timed_out=2026-09-01T09:05:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_eq "FACT 5: timed_out is not success" \
    "partial" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"

# --- FACT 4 -------------------------------------------------------------------
#
# Attempt 2 re-ran only `test`, so GitHub carries `goreleaser` forward into
# attempt 2's job list unchanged — same name, same conclusion, same started_at as
# attempt 1. The two rows are byte-identical apart from the attempt they were
# fetched under, so nothing about the CONCLUSION can tell them apart; only the
# job's started_at against that attempt's run_started_at can. Asserting both
# labels in one case is the discrimination: a script that always printed
# `ran-here` passes the second assertion and fails the first.
d=$(new_case carried-forward)
write_release "$d" 0
write_runs "$d" v1.0.0 5004
write_run "$d" 5004 2
write_attempt "$d" 5004 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5004 1 \
    "test=failure=2026-09-01T09:01:00Z" \
    "goreleaser=success=2026-09-01T09:05:00Z"
write_attempt "$d" 5004 2 "2026-09-01T12:00:00Z"
write_jobs "$d" 5004 2 \
    "test=success=2026-09-01T12:01:00Z" \
    "goreleaser=success=2026-09-01T09:05:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_contains "FACT 4: a carried-forward row is labelled as carried" \
    "$OUT" "attempt 2: goreleaser conclusion=success status=completed (carried)"
assert_contains "FACT 4: a row that really ran in its attempt is labelled ran-here" \
    "$OUT" "attempt 1: goreleaser conclusion=success status=completed (ran-here)"

# --- the jobs endpoint paginates ----------------------------------------------
#
# GitHub's jobs endpoint defaults to 30 per page, and a matrixed workflow passes
# 30 without anyone noticing. A single default page then omits the publishing job
# entirely, and the script concludes `contradictory` for a tag that published
# perfectly — a failure that grows with the caller's job count, so it would have
# arrived long after the script was trusted.
#
# The publishing job is deliberately on the SECOND page: a fixture with it on
# page 1 passes whether or not the pages are merged.
d=$(new_case paginated-jobs)
write_release "$d" 0
write_runs "$d" v1.0.0 5013
write_run "$d" 5013 1
write_attempt "$d" 5013 1 "2026-09-01T09:00:00Z"
write_jobs_paged "$d" 5013 1 \
    "release / Test (1)=success=2026-09-01T09:01:00Z" \
    "release / Test (2)=success=2026-09-01T09:01:00Z" \
    -- \
    "release / Validate tag and changelog=success=2026-09-01T09:02:00Z" \
    "release / goreleaser=success=2026-09-01T09:05:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_eq "a publishing job on page 2 is still found" \
    "published" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"
assert_not_contains "page 2 is not reported as an absent job" \
    "$OUT" "no 'goreleaser' job in this attempt"
assert_contains "the jobs fetch asks for a full page, not the 30-item default" \
    "$(cat "$d/requests.log")" "per_page=100"

# --- provenance comes only from a row that ran ---------------------------------
#
# Attempt 2 re-ran only `test`; `goreleaser` is carried forward with attempt 1's
# failure, byte-identical apart from the attempt it was fetched under. The
# outcome still counts — a carried row repeats a real result — but the attempt
# NAMED in the evidence must be the one that executed the job. Reporting attempt
# 2 here is the conflation FACT 4's origin computation exists to prevent, and
# computing origin without consulting it is the same defect as not computing it.
d=$(new_case carried-provenance)
write_release "$d" 0
write_runs "$d" v1.0.0 5014
write_run "$d" 5014 2
write_attempt "$d" 5014 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5014 1 \
    "goreleaser=failure=2026-09-01T09:05:00Z"
write_attempt "$d" 5014 2 "2026-09-01T15:00:00Z"
write_jobs "$d" 5014 2 \
    "goreleaser=failure=2026-09-01T09:05:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_eq "the verdict still counts the carried outcome" \
    "partial" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"
assert_contains "the evidence names the attempt that actually ran the job" \
    "$OUT" "(run 5014 attempt 1)"
assert_not_contains "the evidence does not name the attempt that merely inherited it" \
    "$OUT" "(run 5014 attempt 2)"

# --- FACT 1 -------------------------------------------------------------------
#
# The recovery advice must name the full re-run and warn off `--failed`, because
# the two resolve the reusable workflow at different commits. Asserting only the
# presence of "rerun" would pass on advice that recommended the wrong one.
d=$(new_case fact1-partial-advice)
write_release "$d" 0
write_runs "$d" v1.0.0 5005
write_run "$d" 5005 1
write_attempt "$d" 5005 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5005 1 "goreleaser=failure=2026-09-01T09:05:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_contains "FACT 1: partial advice names the full re-run" \
    "$OUT" "gh run rerun"
assert_contains "FACT 1: --failed is explicitly warned against" \
    "$OUT" "Do NOT use --failed"
assert_contains "FACT 1: the reason is stated, not just the prohibition" \
    "$OUT" "pin the reusable workflow to"

# --- state: contradictory -----------------------------------------------------
#
# This is what kure v0.2.0-beta.11 actually was: a release object exists, and
# goreleaser is `skipped` in every attempt of every run, so nothing in the run
# record produced it. Neither an asset count nor a job-conclusion read reaches
# this answer — both report a healthy-looking release.
d=$(new_case contradictory)
write_release "$d" 2
write_runs "$d" v1.0.0 5006
write_run "$d" 5006 2
write_attempt "$d" 5006 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5006 1 "test=failure=2026-09-01T09:01:00Z" "goreleaser=skipped=2026-09-01T09:02:00Z"
write_attempt "$d" 5006 2 "2026-09-01T12:00:00Z"
write_jobs "$d" 5006 2 "test=failure=2026-09-01T12:01:00Z" "goreleaser=skipped=2026-09-01T12:02:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_eq "a release nothing in the run record produced is contradictory" \
    "contradictory" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"
assert_contains "contradictory advice forbids the blind re-run and the delete" \
    "$OUT" "Do not re-run and do not delete"

# --- state: contradictory, the other direction --------------------------------
#
# goreleaser succeeded but the release object is gone. That also means the run
# record and the release disagree, and it is emphatically not `published`.
d=$(new_case success-without-release)
write_runs "$d" v1.0.0 5007
write_run "$d" 5007 1
write_attempt "$d" 5007 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5007 1 "goreleaser=success=2026-09-01T09:05:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_eq "a success with no release object is contradictory, not published" \
    "contradictory" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"
# One state word, two opposite causes, and the advice must follow the cause. The
# first version printed the other direction's text here, telling the operator a
# release object existed one line below the evidence saying the lookup 404'd.
assert_contains "the vanished-release advice states the actual direction" \
    "$OUT" "object is gone"
assert_not_contains "the vanished-release advice does not claim a release exists" \
    "$OUT" "A release object exists that no recorded attempt produced"
assert_contains "the vanished-release advice forbids the re-run specifically" \
    "$OUT" "Do not re-run."

# --- a later failure does not unpublish an earlier success ---------------------
#
# FACT 3 and FACT 6 together: attempt 1 published, attempt 2 re-ran and failed.
# The release shipped and still exists, so the state is `published` and the
# advice is "nothing to do" — keying on the most recent attempt instead would
# report a shipped release as incomplete and invite a re-publish. This is the
# case that makes `partial` mean "never succeeded", not "most recently failed".
d=$(new_case success-then-later-failure)
write_release "$d" 0
write_runs "$d" v1.0.0 5015
write_run "$d" 5015 2
write_attempt "$d" 5015 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5015 1 "goreleaser=success=2026-09-01T09:05:00Z"
write_attempt "$d" 5015 2 "2026-09-01T12:00:00Z"
write_jobs "$d" 5015 2 "goreleaser=failure=2026-09-01T12:05:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_eq "an earlier success outranks a later failure" \
    "published" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"
assert_contains "the published advice tells the operator to do nothing" \
    "$OUT" "Nothing to do."
assert_not_contains "a shipped release is never reported as possibly incomplete" \
    "$OUT" "may be incomplete"

# --- the RUN list paginates too -----------------------------------------------
#
# `gh run list --limit 50` returns the N most recent runs and drops the rest.
# The rest are the OLDEST — and for a tag republished a few times the oldest run
# is the original tag push, the one that actually succeeded. Dropping it flips
# `published` to `contradictory` with nothing in the output saying a run was
# lost. Here the successful run is on page 2; a first-page-only fetch sees only
# the later failing run and gets the answer exactly backwards.
d=$(new_case paginated-runs)
write_release "$d" 0
write_runs_paged "$d" v1.0.0 5016 -- 5017
write_run "$d" 5016 1
write_attempt "$d" 5016 1 "2026-09-02T09:00:00Z"
write_jobs "$d" 5016 1 "release / goreleaser=failure=2026-09-02T09:05:00Z"
write_run "$d" 5017 1
write_attempt "$d" 5017 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5017 1 "release / goreleaser=success=2026-09-01T09:05:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_eq "a successful run on run-list page 2 is still found" \
    "published" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"
assert_contains "both runs are reported, not just the first page" \
    "$OUT" "runs for this tag: 2"
assert_contains "the run list asks for a full page, not a capped list" \
    "$(cat "$d/requests.log")" "per_page=100"

# --- an in-flight publish is NOT never-published -------------------------------
#
# The worst reachable wrong answer in this script. A publishing job that has not
# concluded reports conclusion null, which counted as neither ran nor succeeded;
# with no release object yet the verdict fell through to `never-published`, whose
# advice is "Re-running the whole run is safe". Re-running a publish that is
# running right now is the double-publish the whole script exists to prevent.
# `status` was already being read and printed as evidence — it just was not
# consulted.
d=$(new_case in-flight-publish)
write_runs "$d" v1.0.0 5018
write_run "$d" 5018 1
write_attempt "$d" 5018 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5018 1 "release / goreleaser=null=2026-09-01T09:05:00Z=in_progress"
run_case "$d" go-kure/kure v1.0.0
assert_eq "an unconcluded publish yields no state, not never-published" \
    "undetermined" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"
assert_eq "an undetermined state exits 1 so nothing branches on it" 1 "$RC"
assert_contains "the evidence says the job is still running" \
    "$OUT" "STILL RUNNING"
assert_contains "the advice forbids the re-run instead of recommending it" \
    "$OUT" "Do NOT re-run"
# The needle is deliberately a fragment that survives the source's line wrap:
# "Re-running the whole run is safe" is split across two lines in the
# never-published advice, so the full phrase is a needle that can never match
# and the assertion would pass for every possible script. Verified by mutation:
# with the in-flight branch disabled this assertion FAILS.
assert_not_contains "the safe-to-re-run advice is never shown mid-publish" \
    "$OUT" "Re-running the whole run is"

# A job that is `completed` with a null conclusion is a different thing and must
# not be swept into the in-flight branch — without this control the fix could be
# "treat every null as in-flight", which would make a genuinely absent
# conclusion undetectable.
d=$(new_case null-conclusion-completed)
write_runs "$d" v1.0.0 5019
write_run "$d" 5019 1
write_attempt "$d" 5019 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5019 1 "release / goreleaser=null=2026-09-01T09:05:00Z=completed"
run_case "$d" go-kure/kure v1.0.0
assert_eq "a completed job with no conclusion is not treated as in-flight" \
    "never-published" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"

# --- state: never-published ---------------------------------------------------
d=$(new_case never-published)
write_runs "$d" v1.0.0 5008
write_run "$d" 5008 1
write_attempt "$d" 5008 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5008 1 "goreleaser=failure=2026-09-01T09:05:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_eq "no release and no successful publish is never-published" \
    "never-published" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"
assert_contains "the 404 is reported as a fact about the resource" \
    "$OUT" "release object: ABSENT"

# --- state: no-run-found ------------------------------------------------------
d=$(new_case no-run-found)
printf '[]\n' >"$d/runs.json"
run_case "$d" go-kure/kure v1.0.0
assert_eq "no run for the tag is its own state" \
    "no-run-found" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"

# --- a run for a DIFFERENT tag is not this tag's run ---------------------------
#
# `gh run list --branch` is asked for one tag, but the filter is re-applied on
# headBranch afterwards. Without that, a listing that over-answers silently
# attributes another tag's successful publish to this one — the same class of
# defect as reading a date filter as a close filter.
d=$(new_case wrong-tag-run)
write_runs "$d" v0.9.0 5009
write_run "$d" 5009 1
write_attempt "$d" 5009 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5009 1 "goreleaser=success=2026-09-01T09:05:00Z"
run_case "$d" go-kure/kure v1.0.0
assert_eq "another tag's run is not counted as this tag's" \
    "no-run-found" "$(printf '%s' "$OUT" | sed -n 's/^STATE: //p')"

# --- an API failure is NOT a state --------------------------------------------
#
# The fixture returns HTTP 500 for the release lookup. `never-published` and "the
# API did not answer" are different claims, and a caller that branches on the
# first when the second happened re-publishes a release that may already exist.
d=$(new_case api-500)
printf '500\n' >"$d/release.status"
write_runs "$d" v1.0.0 5010
run_case "$d" go-kure/kure v1.0.0
assert_eq "a non-404 API failure exits non-zero" 1 "$RC"
assert_contains "a non-404 API failure reports undetermined" "$OUT" "STATE: undetermined"
assert_not_contains "a non-404 API failure is never reported as never-published" \
    "$OUT" "STATE: never-published"
assert_contains "the undetermined advice says not to branch on it" \
    "$OUT" "do not branch on it"

# --- --state-only -------------------------------------------------------------
d=$(new_case state-only)
write_release "$d" 0
write_runs "$d" v1.0.0 5011
write_run "$d" 5011 1
write_attempt "$d" 5011 1 "2026-09-01T09:00:00Z"
write_jobs "$d" 5011 1 "goreleaser=success=2026-09-01T09:05:00Z"
run_case "$d" --state-only go-kure/kure v1.0.0
assert_eq "--state-only prints the bare word and nothing else" "published" "$OUT"

# --- usage errors -------------------------------------------------------------
d=$(new_case usage)
run_case "$d"
assert_eq "no arguments exits 2" 2 "$RC"
run_case "$d" kure v1.0.0
assert_eq "a repo without an owner exits 2" 2 "$RC"
assert_contains "the repo-shape error says what was wrong" "$OUT" "must contain a slash"
run_case "$d" --nope go-kure/kure v1.0.0
assert_eq "an unknown flag exits 2" 2 "$RC"

# --- suite-level guard --------------------------------------------------------
#
# Without this, a change that made every case exit early would report a clean
# run: zero assertions and zero failures is indistinguishable from a pass when
# only the failure count is checked.
if [ "$pass_count" -eq 0 ] && [ "$failures" -eq 0 ]; then
    echo "FAIL: the suite ran no assertions at all — it did not test anything" >&2
    exit 1
fi

printf '\n%s assertions passed, %s failed\n' "$pass_count" "$failures"
[ "$failures" -eq 0 ] || exit 1
