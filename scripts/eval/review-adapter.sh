#!/usr/bin/env bash
# review-adapter.sh -- run the shipped diff-only reviewer over one diff and print its findings.
#
# This is the `chat` engine of the evaluation harness: the same code path CI runs, minus the
# forge. It sources scripts/lib/prt/{state,diff,model,finding}.sh and calls prt_model_review /
# prt_model_assess exactly as scripts/pr-review-threads.sh does, so a number measured here is a
# number about the reviewer that actually ships. It reads no forge API, posts nothing, and
# creates no threads -- the only network call it makes is to the model proxy.
#
# Output (stdout, or --out):
#   {engine, chunks, findings: [{file, category, line, severity, issue, fix, fp, collision,
#                                verdict, reasoning}], incomplete: [...], degraded: [...]}
# `verdict`/`reasoning` are present only under --assess, and are null for a finding the
# assessment pass returned no valid row for.
#
# exit status
#   0  findings printed (an empty list is a legitimate review outcome, not an error)
#   1  every chunk failed to produce usable findings -- the run has no signal, not zero defects
#   2  usage or environment error

set -uo pipefail

readonly PROG=${0##*/}

die() {
    printf '%s: %s\n' "$PROG" "$*" >&2
    exit 2
}

log() { printf '%s: %s\n' "$PROG" "$*" >&2; }

usage() {
    cat <<'EOF'
usage: review-adapter.sh --diff <file> --title <text> [options]

  --diff        unified diff to review (required)
  --title       PR/MR title given to the model (required)
  --desc        PR/MR description (default: empty)
  --context     extra project context string
  --agents      file whose contents become PROJECT DOCUMENTATION (AGENTS.md)
  --claude-md   file whose contents become PROJECT NOTES (.claude/CLAUDE.md)
  --standards   file whose contents become PROJECT STANDARDS
  --assess      also run the assessment pass and join verdicts by fp
  --out         write the JSON here instead of stdout

environment (same names and defaults as scripts/pr-review-threads.sh)
  PRT_PROXY_URL           model proxy base URL (required)
  PRT_MODEL               default: claude-opus-4
  PRT_MAX_TOKENS          default: 1500
  PRT_ASSESS_MODEL        default: claude-sonnet-4-6
  PRT_ASSESS_MAX_TOKENS   default: 4096
  PRT_MAX_DIFF_CHARS      per-chunk soft limit, default: 50000
  PRT_MODEL_BUDGET_SECONDS  whole-run model budget, default: 1800

exit status
  0  findings printed (possibly an empty list)
  1  no chunk produced usable findings
  2  usage or environment error
EOF
}

# ---------------------------------------------------------------------------
# arguments and environment
# ---------------------------------------------------------------------------

diff_file=
pr_title=
pr_desc=
project_context=${PRT_PROJECT_CONTEXT:-}
agents_file=
claude_md_file=
standards_file=
do_assess=false
out_file=

while [ $# -gt 0 ]; do
    case "$1" in
        --diff) diff_file=${2-}; shift 2 || die "--diff needs a value" ;;
        --title) pr_title=${2-}; shift 2 || die "--title needs a value" ;;
        --desc) pr_desc=${2-}; shift 2 || die "--desc needs a value" ;;
        --context) project_context=${2-}; shift 2 || die "--context needs a value" ;;
        --agents) agents_file=${2-}; shift 2 || die "--agents needs a value" ;;
        --claude-md) claude_md_file=${2-}; shift 2 || die "--claude-md needs a value" ;;
        --standards) standards_file=${2-}; shift 2 || die "--standards needs a value" ;;
        --assess) do_assess=true; shift ;;
        --out) out_file=${2-}; shift 2 || die "--out needs a value" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$diff_file" ] || die "--diff is required"
[ -f "$diff_file" ] || die "no such diff file: $diff_file"
[ -n "$pr_title" ] || die "--title is required"
[ -n "${PRT_PROXY_URL:-}" ] || die "PRT_PROXY_URL is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib/prt" && pwd) \
    || die "cannot locate scripts/lib/prt"
for f in state.sh diff.sh model.sh finding.sh; do
    [ -f "$lib_dir/$f" ] || die "missing library: $lib_dir/$f"
done
# shellcheck source=/dev/null
. "$lib_dir/state.sh"
# shellcheck source=/dev/null
. "$lib_dir/diff.sh"
# shellcheck source=/dev/null
. "$lib_dir/model.sh"
# shellcheck source=/dev/null
. "$lib_dir/finding.sh"

: "${PRT_MODEL:=claude-opus-4}"
: "${PRT_MAX_TOKENS:=1500}"
: "${PRT_ASSESS_MODEL:=claude-sonnet-4-6}"
: "${PRT_ASSESS_MAX_TOKENS:=4096}"
: "${PRT_MAX_DIFF_CHARS:=50000}"
# The harness has no 20-minute job budget to protect, but _prt_call_proxy falls back to
# `now + 300` PER CALL when this is unset -- a ceiling below the workload's measured p95
# (model.sh:325-343). Set it once here so the fallback never applies.
: "${PRT_MODEL_BUDGET_SECONDS:=1800}"
PRT_MODEL_DEADLINE_EPOCH=$(( $(date +%s) + PRT_MODEL_BUDGET_SECONDS ))
export PRT_MODEL_DEADLINE_EPOCH

# The three context files are validated HERE, not inside the command substitutions below.
# `die` called from inside `$(...)` exits only the subshell: with `set -uo pipefail` and no
# `-e`, the failed assignment's status goes unchecked and the run continues with an empty
# context string -- a review silently missing its AGENTS.md, then scored as though it had it.
# Proved on this host: `v=$(f /nonexistent)` where f calls die prints the message and the next
# line still runs with v empty. `|| exit` at each call site would also work; validating up
# front keeps the failure attached to the argument that caused it.
for ctx_file in "$agents_file" "$claude_md_file" "$standards_file"; do
    [ -z "$ctx_file" ] || [ -f "$ctx_file" ] || die "no such file: $ctx_file"
done
unset ctx_file

read_optional() {
    local path="$1"
    [ -n "$path" ] || return 0
    cat -- "$path"
}

project_agents=$(read_optional "$agents_file")
project_claude_md=$(read_optional "$claude_md_file")
project_standards=$(read_optional "$standards_file")

workdir=$(mktemp -d "${TMPDIR:-/tmp}/review-adapter.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$workdir"' EXIT

prt_state_init "$workdir"
# prt_model_review runs inside a command substitution, so model.sh's own in-shell assignment
# to PRT_LAST_MODEL_FAILURE never reaches us; the file-backed copy is how the failure class
# crosses that subshell boundary (pr-review-threads.sh:167,330-334).
PRT_LAST_MODEL_FAILURE_FILE="$workdir/last_model_failure"
export PRT_LAST_MODEL_FAILURE_FILE

# ---------------------------------------------------------------------------
# chunk
# ---------------------------------------------------------------------------

chunk_dir="$workdir/chunks"
chunk_count=$(prt_split_diff "$diff_file" "$PRT_MAX_DIFF_CHARS" "$chunk_dir")
split_rc=$?
# prt_split_diff prints its count ONLY on success and returns 1 on any write failure, so the
# substitution's own status is the check -- a swallowed failure would otherwise arrive as a
# plausible-looking short chunk count (diff.sh:23-29).
[ "$split_rc" -eq 0 ] || die "prt_split_diff failed (exit $split_rc)"
log "diff: $(wc -c <"$diff_file" | tr -d ' ') bytes, chunks=$chunk_count"

# ---------------------------------------------------------------------------
# review, chunk by chunk
# ---------------------------------------------------------------------------

# parse_or_salvage RAW -- mirrors pr-review-threads.sh:296-310 (rc 0 direct, 2 salvaged,
# 1 unparseable). Duplicated rather than shared because it lives in the orchestrator, not
# in a library this script may source.
parse_or_salvage() {
    local raw="$1" parsed salvage
    parsed=$(jq -c '.' <<<"$raw" 2>/dev/null || echo '')
    if [ -n "$parsed" ]; then printf '%s' "$parsed"; return 0; fi
    salvage=$(prt_extract_json_braces "$raw") \
        && parsed=$(jq -c '.' <<<"$salvage" 2>/dev/null || echo '')
    if [ -n "$parsed" ]; then printf '%s' "$parsed"; return 2; fi
    return 1
}

all_findings='[]'
chunk_idx=0
n_chunk_ok=0
n_chunk_failed=0

for chunk_file in "$chunk_dir"/chunk-*.diff; do
    [ -f "$chunk_file" ] || continue
    chunk_diff=$(cat "$chunk_file")

    review_rc=0
    raw=$(prt_model_review "$PRT_PROXY_URL" "$PRT_MODEL" "$PRT_MAX_TOKENS" "$chunk_diff" \
        "$pr_title" "$pr_desc" "$project_context" "$project_agents" "$project_claude_md" \
        "$project_standards") || review_rc=$?
    if [ "$review_rc" -ne 0 ]; then
        failure=$(cat "$PRT_LAST_MODEL_FAILURE_FILE" 2>/dev/null || true)
        log "chunk $chunk_idx: review call failed (exit $review_rc) [${failure:-unknown}]"
        prt_mark_degraded "chunk $chunk_idx: review transport failure"
        n_chunk_failed=$((n_chunk_failed + 1))
        chunk_idx=$((chunk_idx + 1))
        continue
    fi

    raw_json=$(parse_or_salvage "$raw")
    parse_rc=$?
    normalized='[]'
    norm_rc=1
    if [ "$parse_rc" -ne 1 ]; then
        normalized=$(prt_normalize_findings "$raw_json")
        norm_rc=$?
    fi

    # No retry here, deliberately, and it is not an oversight: CI retries once because a
    # transient failure costs a whole PR its review, while the harness runs the same config
    # >=3 times by construction and reports the spread. A silent retry would hide exactly the
    # variance the noise floor is meant to measure.
    if [ "$parse_rc" -eq 1 ] || [ "$norm_rc" -eq 1 ]; then
        log "chunk $chunk_idx: no usable findings (parse_rc=$parse_rc norm_rc=$norm_rc)"
        prt_mark_degraded "chunk $chunk_idx: unusable review response"
        n_chunk_failed=$((n_chunk_failed + 1))
        chunk_idx=$((chunk_idx + 1))
        continue
    fi
    [ "$norm_rc" -eq 2 ] && prt_mark_degraded "chunk $chunk_idx: some findings malformed and dropped"

    chunk_findings=$(prt_assign_ordinals "$normalized")

    if [ "$do_assess" = true ] && [ "$(jq 'length' <<<"$chunk_findings")" != "0" ]; then
        assess_rc=0
        assess_raw=$(prt_model_assess "$PRT_PROXY_URL" "$PRT_ASSESS_MODEL" \
            "$PRT_ASSESS_MAX_TOKENS" "$chunk_diff" "$chunk_findings" "$pr_title" \
            "$project_context" "$project_agents" "$project_claude_md" \
            "$project_standards") || assess_rc=$?
        if [ "$assess_rc" -ne 0 ]; then
            log "chunk $chunk_idx: assess call failed (exit $assess_rc); findings stay unverdicted"
            prt_mark_degraded "chunk $chunk_idx: assess transport failure"
        else
            assess_json=$(parse_or_salvage "$assess_raw")
            assess_parse_rc=$?
            if [ "$assess_parse_rc" -eq 1 ]; then
                log "chunk $chunk_idx: assess response unparseable; findings stay unverdicted"
                prt_mark_degraded "chunk $chunk_idx: unparseable assess response"
            else
                # prt_join_assessment returns the findings unchanged (rc 1) on a bad
                # `.assessments` shape, so its output is usable either way.
                chunk_findings=$(prt_join_assessment "$chunk_findings" "$assess_json") || true
            fi
        fi
    fi

    all_findings=$(jq -c --argjson add "$chunk_findings" '. + $add' <<<"$all_findings")
    n_chunk_ok=$((n_chunk_ok + 1))
    chunk_idx=$((chunk_idx + 1))
done

# ---------------------------------------------------------------------------
# emit
# ---------------------------------------------------------------------------

# Zero chunks is not an empty review, it is a diff with nothing in it: prt_split_diff returns
# 0 chunks and exit 0 for an empty file (verified), so the loop body never runs, both counters
# stay 0, and without this guard the adapter would print `findings: []` from a reviewer that
# was never called -- the same "no signal scored as no defects" mistake the exit-1 path below
# exists to prevent. Deterministic in the input rather than the backend being nondeterministic,
# so it is a setup fault: exit 2, not the exit 1 a caller reads as "exclude this document".
[ "$chunk_count" -gt 0 ] || die "diff produced no chunks; is $diff_file empty?"

# Every chunk failing is "no signal", not "no defects" -- a run that scored this as a clean
# empty review would report perfect precision and zero recall from a reviewer that never ran.
# Tested on n_chunk_ok alone, so a counted chunk that never reached the loop (a file vanishing
# between the split and the glob) fails here too rather than emitting an empty review.
if [ "$n_chunk_ok" -eq 0 ]; then
    log "no chunk produced usable findings ($n_chunk_failed failed of $chunk_count); no usable review"
    exit 1
fi

# Re-assign ordinals across the WHOLE review, the way the shipped reviewer does. In the loop
# above the assignment is per chunk, because the assess round-trip needs a fingerprint to key
# its verdicts on before the next chunk exists. Left at that, an oversized file split across
# chunks yields two findings with the same file/category carrying the same unsuffixed fp and
# `collision: false`, while production -- which aggregates first and assigns once -- gives them
# distinct ordinals and flags the collision. Identity is what the reconcile table matches
# threads on, so a harness that assigns it differently is not measuring the shipped pipeline.
#
# Dropping fp/collision first is what makes this a re-assignment rather than a no-op: the
# function recomputes fp_base from file and category and re-groups, so it is safe to re-run,
# and any verdict joined in above rides along on the row untouched.
all_findings=$(prt_assign_ordinals "$(jq -c 'map(del(.fp, .collision))' <<<"$all_findings")") \
    || die "cannot assign fingerprints across the aggregated review"

to_json_array() {
    local file="$1"
    [ -s "$file" ] || { printf '[]'; return 0; }
    jq -Rsc 'split("\n") | map(select(length > 0))' <"$file"
}

incomplete=$(to_json_array "${PRT_INCOMPLETE_FILE:-/dev/null}")
degraded=$(to_json_array "${PRT_DEGRADED_FILE:-/dev/null}")

# chunks_failed is the caller's exclusion signal, and it must be a count rather than the
# degraded list's length: `degraded` also collects malformed-findings-dropped notes from chunks
# that otherwise succeeded, so its length answers "was anything imperfect", not "did part of
# this diff go unreviewed". Only the second decides whether the document's gold rows can be
# scored -- a gold row sitting in a chunk the model never answered for is a reviewer that did
# not run, not a reviewer that missed something, and scoring it as a miss biases recall down by
# exactly the failure rate the harness exists to tolerate. Exiting 1 here would be wrong the
# other way: the findings from the chunks that DID succeed are real, and the caller decides.
result=$(jq -n \
    --arg engine chat \
    --argjson chunks "$chunk_count" \
    --argjson chunks_ok "$n_chunk_ok" \
    --argjson chunks_failed "$n_chunk_failed" \
    --argjson findings "$all_findings" \
    --argjson incomplete "$incomplete" \
    --argjson degraded "$degraded" \
    '{engine: $engine, chunks: $chunks, chunks_ok: $chunks_ok,
      chunks_failed: $chunks_failed, findings: $findings,
      incomplete: $incomplete, degraded: $degraded}') \
    || die "cannot build result JSON"

if [ -n "$out_file" ]; then
    printf '%s\n' "$result" >"$out_file" || die "cannot write $out_file"
    log "wrote $(jq '.findings | length' <<<"$result") findings to $out_file"
else
    printf '%s\n' "$result"
fi
