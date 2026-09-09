#!/usr/bin/env bash
# judge.sh -- decide which gold rows a reviewer's findings actually caught.
#
# Two stages. The first is free and deterministic: a finding is a candidate for a gold row
# only when it names the same file. The second asks a model whether the two describe the
# same underlying issue, under the hygiene the measurement literature requires:
#
#   - POSITION-SWAPPED, TWICE. The same pair is asked as (A=finding, B=gold) and again as
#     (A=gold, B=finding). GPT-4-class judges flip their verdict on ~35% of pairs when the
#     order changes, so a single-order verdict is not evidence.
#   - DISAGREEMENT IS NO MATCH. Both orders must say yes. This biases recall DOWNWARD, which
#     is the safe direction: a baseline that is too generous makes Phase 2 look worse than it
#     is, and a baseline that is too harsh cannot manufacture an improvement.
#   - PROVENANCE HIDDEN. Neither side is ever labelled "reviewer" or "known defect"; both are
#     "Statement A"/"Statement B". A judge told which one is ground truth agrees with it.
#
# Two hygiene items the literature asks for are NOT available through this backend, and are
# recorded here rather than asserted: TEMPERATURE 0 and a PINNED JUDGE MODEL. The proxy
# ignores the request's `model` field and always routes through the Claude Code CLI on the
# Max subscription (meta/ci-templates/mr-review.yml:14-20), and that CLI exposes no
# temperature control. --judge-model is therefore recorded in the output for provenance, not
# obeyed. The remaining control for judge variance is repetition: run.sh runs the whole
# harness >=3 times and reports the spread, which is what the spread is FOR.
#
# Input:  --findings  the adapter's document ({findings: [...]})
#         --gold      one gold document ({repo, pr, head_sha, base_sha, gold: [...]})
# Output: {gold_total, matched, recall, uncredited, judge_calls, matches: [...]}
#
# `uncredited` is a COUNT OF FINDINGS NOT CREDITED WITH A MATCH, and it is deliberately not
# called false positives. The gold set is mined from commits someone eventually fixed, so a
# reviewer naming a real defect nobody ever filed is uncredited but correct. Reporting it as
# precision would punish the better reviewer. See eval/README.md.
#
# The name is "uncredited" rather than "unmatched" because the two are not the same set. Once
# a gold row is matched, the loop below stops judging further pairs against it -- recall counts
# rows caught, not how many findings caught each -- so a SECOND finding describing that same
# row is never judged and lands here too. Calling that "matched no gold row" would be false;
# judging it anyway would spend model calls to refine a number that gates nothing. The count is
# a volume signal for a human, so the honest name is the cheaper correct answer.
#
# exit status
#   0  judged (a zero-match result is a legitimate outcome)
#   1  a judge call failed and the verdict would be incomplete
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
usage: judge.sh --findings <file> --gold <file> [--out <file>] [--judge-model <name>]

  --findings     adapter output: {findings: [{file, line, issue, fix, ...}]}
  --gold         one gold document: {gold: [{file, lines, note, confirmed}]}
  --out          write the JSON here instead of stdout
  --judge-model  recorded for provenance; the backend ignores it (see the header)

environment
  PRT_PROXY_URL          model proxy base URL (required)
  PRT_JUDGE_MAX_TOKENS   default: 512

exit status
  0  judged      1  a judge call failed      2  usage error
EOF
}

findings_file=
gold_file=
out_file=
judge_model=${PRT_JUDGE_MODEL:-claude-sonnet-4-6}

while [ $# -gt 0 ]; do
    case "$1" in
        --findings) findings_file=${2-}; shift 2 || die "--findings needs a value" ;;
        --gold) gold_file=${2-}; shift 2 || die "--gold needs a value" ;;
        --out) out_file=${2-}; shift 2 || die "--out needs a value" ;;
        --judge-model) judge_model=${2-}; shift 2 || die "--judge-model needs a value" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$findings_file" ] || die "--findings is required"
[ -n "$gold_file" ] || die "--gold is required"
[ -f "$findings_file" ] || die "no such file: $findings_file"
[ -f "$gold_file" ] || die "no such file: $gold_file"
[ -n "${PRT_PROXY_URL:-}" ] || die "PRT_PROXY_URL is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

: "${PRT_JUDGE_MAX_TOKENS:=512}"

lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib/prt" && pwd) \
    || die "cannot locate scripts/lib/prt"
# shellcheck source=/dev/null
. "$lib_dir/model.sh"

: "${PRT_MODEL_BUDGET_SECONDS:=1800}"
PRT_MODEL_DEADLINE_EPOCH=$(( $(date +%s) + PRT_MODEL_BUDGET_SECONDS ))
export PRT_MODEL_DEADLINE_EPOCH

workdir=$(mktemp -d "${TMPDIR:-/tmp}/judge.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$workdir"' EXIT
PRT_LAST_MODEL_FAILURE_FILE="$workdir/last_model_failure"
export PRT_LAST_MODEL_FAILURE_FILE
# judge_once always runs inside a `v1=$(judge_once ...)` command substitution -- a subshell --
# so a plain variable it sets is gone the instant that subshell exits. Same reason
# PRT_LAST_MODEL_FAILURE_FILE above is a file and not a variable.
_JUDGE_ONCE_CALLS_FILE="$workdir/last_judge_calls"

# ---------------------------------------------------------------------------
# the judge call
# ---------------------------------------------------------------------------

JUDGE_SYSTEM='You compare two descriptions of a possible software defect and decide whether
they describe THE SAME UNDERLYING ISSUE in the same code.

Same underlying issue means: fixing one would fix the other. A shared file, a shared line
number, or a shared general topic ("error handling", "this function") is NOT enough. Two
distinct defects in adjacent lines are NOT the same issue.

One description may be terse and the other detailed; that difference is irrelevant to your
decision. Judge the defect, not the wording.

Respond with ONLY a single JSON object, no markdown fences, no prose:
{"same": true, "reason": "one short sentence"}'

# judge_once A_TEXT B_TEXT -- prints "true" or "false"; returns 1 if the call was unusable after
# a retry.
#
# One retry of the WHOLE call (transport included) on any failure, not just a transport fault.
# _prt_call_proxy already retries connect-class transport faults once internally
# (model.sh:377-419), but a response that arrives and fails to parse, or parses to the wrong
# shape, gets no second attempt at this level: a transient bad reply currently costs the whole
# document (go-kure/.github#179). ~3% of document-judgements failed this way on the 12-document
# probe, so this adds at most one extra call for that ~3%, not for the other 97%.
#
# Writes the number of raw model calls this invocation actually made (1 or 2) to
# $_JUDGE_ONCE_CALLS_FILE, so the caller's judge_calls counter -- documented above as counting
# calls, not pairs -- stays accurate when a retry fires instead of silently undercounting real
# API usage. A variable would not survive the `v1=$(judge_once ...)` subshell at every call site.
judge_once() {
    local attempt calls=0
    for attempt in 1 2; do
        calls=$((calls + 1))
        if _judge_once_attempt "$1" "$2"; then
            printf '%s' "$calls" >"$_JUDGE_ONCE_CALLS_FILE"
            return 0
        fi
        [ "$attempt" -eq 1 ] || break
    done
    printf '%s' "$calls" >"$_JUDGE_ONCE_CALLS_FILE"
    return 1
}

# _judge_once_attempt A_TEXT B_TEXT -- the single-attempt call judge_once retries. Every failure
# path records its own reason via _prt_set_model_failure (model.sh:40-45) before returning, so
# judge.sh's failure log (below) names the actual condition instead of a generic default that
# five distinct causes could produce identically (go-kure/.github#179 problem 2).
#
# Every reason uses prt_response_shape (model.sh:178), never the response text itself: "never
# logging raw model responses" is a standing rule for this whole action (docs/pr-review-threads.md
# "Failure surface"), and A/B here are a finding's and a gold row's defect text -- exactly the
# content that rule protects.
_judge_once_attempt() {
    local a="$1" b="$2" raw parsed same
    local user
    user="Statement A:
${a}

Statement B:
${b}

Do A and B describe the same underlying issue?"

    raw=$(prt_model_review_judge "$user") || return 1
    parsed=$(jq -c '.' <<<"$raw" 2>/dev/null || echo '')
    if [ -z "$parsed" ]; then
        parsed=$(prt_extract_json_braces "$raw" 2>/dev/null || echo '')
        parsed=$(jq -c '.' <<<"$parsed" 2>/dev/null || echo '')
    fi
    if [ -z "$parsed" ]; then
        _prt_set_model_failure "not-json: $(prt_response_shape "$raw")"
        return 1
    fi
    # `.same` on a non-object -- a bare array, string or number -- makes jq ERROR rather than
    # return null, so `same` is set to the empty string, never the "bad" sentinel below. An
    # empty verdict then reads as "not a match" and the pair is silently scored as a miss,
    # which is a judge failure disguised as a reviewer failure: it lowers recall on evidence
    # that does not exist. Guard the type first, and check jq's own status, so an unusable
    # answer reaches the caller as a failed call.
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$parsed"; then
        _prt_set_model_failure "not-object: $(prt_response_shape "$parsed")"
        return 1
    fi
    if ! same=$(jq -r 'if .same == true then "true" elif .same == false then "false" else "bad" end' \
        <<<"$parsed"); then
        _prt_set_model_failure "same-eval-failed: $(prt_response_shape "$parsed")"
        return 1
    fi
    case "$same" in
        true|false) printf '%s' "$same" ;;
        *) _prt_set_model_failure "no-boolean-same: $(prt_response_shape "$parsed")"; return 1 ;;
    esac
}

# The judge does not use prt_model_review: that function wraps its input in the code-review
# system prompt. _prt_call_proxy is the transport, and is what both callers actually share.
prt_model_review_judge() {
    _prt_call_proxy "$PRT_PROXY_URL" "$judge_model" "$PRT_JUDGE_MAX_TOKENS" \
        "$JUDGE_SYSTEM" "$1"
}

# ---------------------------------------------------------------------------
# stage 1: same-file candidate pairs
# ---------------------------------------------------------------------------

gold_total=$(jq '.gold | length' "$gold_file")
[ "$gold_total" -gt 0 ] || die "gold document has no rows: $gold_file"

# One line per candidate pair: gold_index<TAB>finding_index. A gold row with no same-file
# finding never reaches the model at all -- that is the cheap half of the two-stage design.
jq -r --slurpfile f "$findings_file" '
    [ .gold | to_entries[] ] as $g
    | [ $f[0].findings | to_entries[] ] as $fi
    | [ $g[] as $gr | $fi[] as $fr
        | select($gr.value.file == $fr.value.file)
        | "\($gr.key)\t\($fr.key)" ]
    | .[]
' "$gold_file" >"$workdir/pairs.tsv"

n_pairs=$(wc -l <"$workdir/pairs.tsv")
log "$gold_total gold rows, $(jq '.findings | length' "$findings_file") findings, $n_pairs same-file pairs to judge"

# ---------------------------------------------------------------------------
# stage 2: judge each pair in both orders
# ---------------------------------------------------------------------------

matches='[]'
matched_gold=''
matched_findings=''
# Model calls, not candidate pairs -- the two differ and the name has to say which. A pair whose
# first-order verdict is true costs two calls (the position swap below), a false one costs one,
# so this counter reads 2 or 1 for the same single pair depending on the answer. As
# `pairs_judged` it looked like a workload constant while actually varying with the verdict, and
# anyone dividing cost by it got a number that moved with the reviewer's quality.
judge_calls=0
call_failed=0

while IFS=$'\t' read -r gi fi_idx; do
    [ -n "$gi" ] || continue

    # A gold row already matched needs no further pairs: recall counts rows caught, not
    # how many findings caught each one. The finding skipped here is therefore never credited
    # and is counted in `uncredited` -- which is why that field is not named "unmatched"; see
    # the header.
    case " $matched_gold " in *" $gi "*) continue ;; esac

    gold_text=$(jq -r --argjson i "$gi" '
        .gold[$i] | "File: \(.file)\nLines: \(.lines[0])-\(.lines[1])\nDefect: \(.note)"' \
        "$gold_file")
    finding_text=$(jq -r --argjson i "$fi_idx" '
        .findings[$i]
        | "File: \(.file)\nLine: \(.line // "unspecified")\nDefect: \(.issue)\nSuggested fix: \(.fix)"' \
        "$findings_file")

    # Both orders. Order 1 first: if it says no, order 2 cannot change the outcome (both
    # must agree), so the second call is skipped -- half the judge cost on non-matches.
    v1=$(judge_once "$finding_text" "$gold_text") || { call_failed=1; break; }
    judge_calls=$((judge_calls + $(cat "$_JUDGE_ONCE_CALLS_FILE")))
    verdict=false
    if [ "$v1" = "true" ]; then
        v2=$(judge_once "$gold_text" "$finding_text") || { call_failed=1; break; }
        judge_calls=$((judge_calls + $(cat "$_JUDGE_ONCE_CALLS_FILE")))
        [ "$v2" = "true" ] && verdict=true
    fi

    if [ "$verdict" = true ]; then
        matched_gold="$matched_gold $gi"
        # One finding can legitimately catch two gold rows in the same file. Record it once,
        # or the uncredited count below is decremented twice for a single finding and can go
        # negative on a small gold set.
        case " $matched_findings " in
            *" $fi_idx "*) ;;
            *) matched_findings="$matched_findings $fi_idx" ;;
        esac
        matches=$(jq -c \
            --argjson g "$(jq -c --argjson i "$gi" '.gold[$i]' "$gold_file")" \
            --arg fp "$(jq -r --argjson i "$fi_idx" '.findings[$i].fp // ""' "$findings_file")" \
            '. + [{gold: $g, fp: $fp}]' <<<"$matches")
    fi
done <"$workdir/pairs.tsv"

if [ "$call_failed" -ne 0 ]; then
    failure=$(cat "$PRT_LAST_MODEL_FAILURE_FILE" 2>/dev/null || true)
    # Exit 1 rather than reporting a partial verdict: a judge that stopped early
    # under-counts matches, and an under-counted recall is indistinguishable from a
    # genuinely worse reviewer.
    log "judge call failed [${failure:-unparseable}]; verdict would be incomplete"
    exit 1
fi

n_matched=$(printf '%s' "$matched_gold" | wc -w)
n_findings=$(jq '.findings | length' "$findings_file")
n_uncredited=$n_findings
for i in $matched_findings; do
    [ -n "$i" ] && n_uncredited=$((n_uncredited - 1))
done

result=$(jq -n \
    --argjson gold_total "$gold_total" \
    --argjson matched "$n_matched" \
    --argjson findings "$n_findings" \
    --argjson uncredited "$n_uncredited" \
    --argjson pairs "$judge_calls" \
    --argjson matches "$matches" \
    --arg judge_model "$judge_model" \
    '{gold_total: $gold_total, findings: $findings, matched: $matched,
      recall: (if $gold_total == 0 then null else ($matched / $gold_total) end),
      uncredited: $uncredited, judge_calls: $pairs,
      judge_model_requested: $judge_model, matches: $matches}') \
    || die "cannot build result JSON"

if [ -n "$out_file" ]; then
    printf '%s\n' "$result" >"$out_file" || die "cannot write $out_file"
else
    printf '%s\n' "$result"
fi
