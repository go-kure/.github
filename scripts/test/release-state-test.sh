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
    path="${2:-}"
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

write_runs() { # <dir> <tag> <run-id>...
    local dir="$1" tag="$2"; shift 2
    local out="" id
    for id in "$@"; do
        [ -z "$out" ] || out="$out,"
        out="$out{\"databaseId\":$id,\"workflowName\":\"Release / Publish\",\"status\":\"completed\",\"conclusion\":\"failure\",\"createdAt\":\"2026-09-01T09:00:00Z\",\"headBranch\":\"$tag\"}"
    done
    printf '[%s]\n' "$out" >"$dir/runs.json"
}

write_run() { # <dir> <run-id> <attempt-count>
    printf '{"id":%s,"name":"Release / Publish","run_attempt":%s}\n' "$2" "$3" \
        >"$1/run-$2.json"
}

write_attempt() { # <dir> <run-id> <attempt> <run_started_at>
    printf '{"run_attempt":%s,"run_started_at":"%s"}\n' "$3" "$4" \
        >"$1/run-$2-attempt-$3.json"
}

write_jobs() { # <dir> <run-id> <attempt> <name=conclusion=started_at>...
    local dir="$1" id="$2" attempt="$3"; shift 3
    local out="" spec name conclusion started
    for spec in "$@"; do
        IFS='=' read -r name conclusion started <<<"$spec"
        [ -z "$out" ] || out="$out,"
        out="$out{\"name\":\"$name\",\"conclusion\":\"$conclusion\",\"status\":\"completed\",\"started_at\":\"$started\",\"run_attempt\":$attempt}"
    done
    printf '{"total_count":%s,"jobs":[%s]}\n' "$#" "$out" \
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
