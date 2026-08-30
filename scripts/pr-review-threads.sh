#!/usr/bin/env bash
# pr-review-threads.sh — orchestrates resolvable, merge-gating PR review
# threads: chunk the diff, review + assess each chunk, fingerprint findings,
# reconcile against existing GitHub review threads (create/reply/resolve/
# unresolve), and render a job summary + optional advisory/overflow comment.
#
# See docs/pr-review-threads.md (once written) / the design plan this
# implements for the full reconciliation table and rationale. This script
# is orchestration only — every module it sources is independently unit
# tested (scripts/test/pr-review-threads-test.sh); this file wires them
# together and is exercised only by live-PR verification, not the unit
# suite.
#
# Required env (bound by .github/actions/pr-review-threads/action.yml):
#   PRT_GH_TOKEN        GitHub token with pull-requests: write
#   PRT_REPO            "owner/repo"
#   PRT_PR_NUMBER       PR number
#   PRT_HEAD_SHA        github.event.pull_request.head.sha (NOT github.sha)
#   PRT_BOT_LOGIN       login the token posts as (e.g. github-actions[bot])
#   PRT_PROXY_URL       claude-max-proxy base URL
# Optional env (defaults noted):
#   PRT_MODE                    enforce|advisory|off (default: advisory)
#   PRT_MODEL                   default: claude-opus-4
#   PRT_MAX_TOKENS               default: 1500
#   PRT_ASSESS_MODEL             default: claude-sonnet-4-6
#   PRT_ASSESS_MAX_TOKENS        default: 4096
#   PRT_MAX_DIFF_CHARS           per-chunk soft limit, default: 50000
#   PRT_MAX_FINDINGS_TOTAL       PR-wide gating cap, default: 5
#   PRT_PROJECT_CONTEXT           default: ""
#   PRT_AGENTS_FILE               default: AGENTS.md
#   PRT_STANDARDS_FILE             org standards doc injected as PROJECT
#                                   STANDARDS, resolved against THIS repo's own
#                                   checkout (the pinned action's, not the
#                                   caller's — see the PRT_SCRIPT_DIR note
#                                   below), default: docs/standards.md
#   PRT_MODEL_BUDGET_SECONDS       seconds reserved for review+assess model
#                                   calls out of the job's timeout-minutes: 20,
#                                   default: 1020 (17m) — see the
#                                   PRT_MODEL_DEADLINE_EPOCH comment below
#   PRT_MODEL_TIMEOUT_FLOOR        min seconds of budget to still attempt a
#                                   call (model.sh), default: 30
#   PRT_MODEL_TIMEOUT_CEILING      per-call --max-time ceiling even when more
#                                   budget remains (model.sh), default: 900
#   PRT_MODEL_CONNECT_RETRY_DELAY  seconds to wait before the one connect-class
#                                   retry (curl exit 6/7 only) inside
#                                   _prt_call_proxy (model.sh), default: 3

set -uo pipefail  # not -e: every stage must run to completion and report,
                   # a single failed write must not abort the whole run —
                   # the job now fails closed on the final exit (see the
                   # REVIEW_INCOMPLETE check at the bottom of this file), but
                   # a soft per-finding failure here must still not cascade
                   # into skipping every other finding before that check runs.

# PRT_SCRIPT_DIR is THIS script's own directory — go-kure/.github's own
# checkout at the pinned action SHA (GitHub Actions checks out the `uses:`
# repo itself to resolve action.yml/this script, separate from and alongside
# the caller's checkout, which is what `pwd`/PRT_AGENTS_FILE below resolve
# against). PROJECT STANDARDS below reads docs/standards.md from THIS
# location deliberately — that doc lives in go-kure/.github, not in the
# calling repo (kure/launcher), so a caller-relative read would always miss.
PRT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib/prt" && pwd)"
# shellcheck source=scripts/lib/prt/state.sh
source "$PRT_LIB_DIR/state.sh"
# shellcheck source=scripts/lib/prt/json.sh
source "$PRT_LIB_DIR/json.sh"
# shellcheck source=scripts/lib/prt/gh.sh
source "$PRT_LIB_DIR/gh.sh"
# shellcheck source=scripts/lib/prt/diff.sh
source "$PRT_LIB_DIR/diff.sh"
# shellcheck source=scripts/lib/prt/finding.sh
source "$PRT_LIB_DIR/finding.sh"
# shellcheck source=scripts/lib/prt/marker.sh
source "$PRT_LIB_DIR/marker.sh"
# shellcheck source=scripts/lib/prt/render.sh
source "$PRT_LIB_DIR/render.sh"
# shellcheck source=scripts/lib/prt/model.sh
source "$PRT_LIB_DIR/model.sh"
# shellcheck source=scripts/lib/prt/reconcile.sh
source "$PRT_LIB_DIR/reconcile.sh"

: "${PRT_MODE:=advisory}"
: "${PRT_MODEL:=claude-opus-4}"
: "${PRT_MAX_TOKENS:=1500}"
: "${PRT_ASSESS_MODEL:=claude-sonnet-4-6}"
: "${PRT_ASSESS_MAX_TOKENS:=4096}"
: "${PRT_MAX_DIFF_CHARS:=50000}"
: "${PRT_MAX_FINDINGS_TOTAL:=5}"
: "${PRT_PROJECT_CONTEXT:=}"
: "${PRT_AGENTS_FILE:=AGENTS.md}"
# Not `:=` like every other default above: action.yml's standards-file input
# documents "set to empty string to disable" (:76), so an explicitly-empty
# value must stay empty, not fall back to the default the way `:=` would —
# `:=` treats set-but-empty the same as unset. `+set` distinguishes them.
if [ -z "${PRT_STANDARDS_FILE+set}" ]; then
  PRT_STANDARDS_FILE="docs/standards.md"
fi

# PRT_MODEL_DEADLINE_EPOCH bounds every review/assess model call
# (model.sh:_prt_call_proxy) to a reserved slice of this job's own
# timeout-minutes: 20 budget (.github/workflows/pr-review.yml), leaving the
# remainder for the diff fetch above and the reconcile/render writes below.
# Computed ONCE here, not per call: model.sh derives each call's --max-time
# from whatever is left of it, so a multi-chunk PR's later calls get less
# headroom than its first, and a run that has already spent its budget
# refuses a doomed call instead of issuing one that can only fail.
#
# Root cause this replaces: a fixed 300s --max-time sat BELOW the workload's
# own measured p95 (315s over 1066 live calls against claude-proxy, 2026-08-30
# investigation) — about 1 in 20 calls was killed by curl mid-generation with
# no application fault at all, and on a single-chunk PR (the common case)
# that one killed call failed the whole required check closed.
: "${PRT_MODEL_BUDGET_SECONDS:=1020}"   # 17 of the job's 20 minutes
# shellcheck disable=SC2034 # read by _prt_call_proxy in lib/prt/model.sh, not within this file
PRT_MODEL_DEADLINE_EPOCH=$(( $(date +%s) + PRT_MODEL_BUDGET_SECONDS ))
# Anchored at THIS script's start, not the job's — checkout + "Setup tools"
# (.github/workflows/pr-review.yml) run before this script does, so their
# elapsed time is NOT inside the 180s margin the 1020s default reserves out
# of timeout-minutes: 20. Judged acceptable (go-kure/.github#128 round 1,
# thread on pr-review-threads.sh:116): checkout is a shallow clone of this
# small repo, and Setup tools is a `command -v` check that no-ops on the
# self-hosted runner image where curl/jq are already present — both
# expected in the single-digit-seconds range in the common case, well
# inside the margin. A runner needing a genuine cold apt-get install, or a
# slow checkout, could still erode it; anchoring PRT_MODEL_DEADLINE_EPOCH at
# a PRT_JOB_STARTED_EPOCH captured in a workflow step before checkout would
# close that gap if it's ever observed to matter in practice.

for req in PRT_GH_TOKEN PRT_REPO PRT_PR_NUMBER PRT_HEAD_SHA PRT_BOT_LOGIN PRT_PROXY_URL; do
  [ -n "${!req:-}" ] || { echo "ERROR: $req is required" >&2; exit 1; }
done

# These three feed --argjson calls downstream (PRT_PR_NUMBER at :478 below;
# PRT_MAX_TOKENS via model.sh's _prt_call_proxy; PRT_MAX_FINDINGS_TOTAL via
# reconcile.sh's cap arithmetic) — a non-numeric value fails jq with an
# unclear error deep in the run instead of a clear one here.
for numeric in PRT_PR_NUMBER PRT_MAX_TOKENS PRT_MAX_FINDINGS_TOTAL; do
  case "${!numeric}" in
    ''|*[!0-9]*) echo "ERROR: $numeric must be a non-negative integer, got '${!numeric}'" >&2; exit 1 ;;
  esac
done

# --- Mode resolution: an unrecognized value degrades to advisory, never to
# enforce — a typo must fail toward the safe side of a gate. ---
case "$PRT_MODE" in
  enforce|advisory|off) : ;;
  *)
    echo "WARNING: unrecognized PRT_MODE='$PRT_MODE', degrading to advisory" >&2
    PRT_MODE=advisory
    ;;
esac

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
prt_state_init "$WORKDIR"

# PRT_LAST_MODEL_FAILURE_FILE — every prt_model_review/prt_model_assess call
# below is invoked via command substitution (`raw="$(prt_model_review ...)"`),
# which forks a subshell; a plain PRT_LAST_MODEL_FAILURE="..." assignment made
# inside _prt_call_proxy (model.sh) during that call is invisible here once
# the substitution returns, so every failure annotation below read back
# "[unknown]" regardless of the real cause (go-kure/.github#128 round 1).
# model.sh's _prt_set_model_failure writes the same reason to this file too,
# which — unlike a shell variable — survives the subshell; each call site
# re-reads it into PRT_LAST_MODEL_FAILURE right after its own call returns.
export PRT_LAST_MODEL_FAILURE_FILE="$WORKDIR/last_model_failure"
: > "$PRT_LAST_MODEL_FAILURE_FILE"

# prt_log cannot be called before state.sh is sourced (:53-54); the
# earliest safe site with something worth reporting is here, right after
# prt_state_init — mode resolution above (:103-111) has already run, so this
# one line covers both.
prt_log "mode=$PRT_MODE repo=$PRT_REPO pr=$PRT_PR_NUMBER head=${PRT_HEAD_SHA:0:7}"

if [ "$PRT_MODE" = off ]; then
  {
    echo "## PR Review Threads: off"
    echo
    echo "PR_REVIEW_THREADS_MODE=off — skipped."
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi

# --- Fetch PR diff + metadata ---
DIFF_FILE="$WORKDIR/full.diff"
# Wrapped in prt_retry (gh.sh:208-235): a transient 5xx/timeout here used to
# fail the whole run with no retry, unlike every write path below. 406 (diff
# too large) is treated as a terminal, non-retryable outcome — retrying it
# would only burn the retry budget on a condition that can't change between
# attempts — so the retryable function itself returns success on 406 and lets
# the existing check below handle it exactly as before.
# shellcheck disable=SC2317,SC2329  # invoked indirectly: prt_retry calls it via "$@"
_prt_fetch_pr_diff() {
  http_code=$("$PRT_CURL" -sS -o "$DIFF_FILE" -w '%{http_code}' \
    --connect-timeout 10 --max-time 120 \
    -H "Authorization: Bearer ${PRT_GH_TOKEN}" \
    -H "Accept: application/vnd.github.diff" \
    "${PRT_API_BASE:-https://api.github.com}/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}") || http_code=000
  [[ "$http_code" =~ ^2[0-9]{2}$ ]] || [ "$http_code" = 406 ]
}
prt_retry 3 _prt_fetch_pr_diff
if [ "$http_code" = 406 ]; then
  echo "PR diff too large for GitHub API (HTTP 406), skipping." >&2
  { echo "## PR Review Threads: skipped"; echo; echo "Diff too large for the GitHub API (406)."; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi
if [[ ! "$http_code" =~ ^2[0-9]{2}$ ]]; then
  echo "ERROR: HTTP $http_code fetching PR diff" >&2
  exit 1
fi
EMPTY_DIFF=0
if [ ! -s "$DIFF_FILE" ]; then
  EMPTY_DIFF=1
  # advisory/off create no threads, so there is nothing to reconcile — keep
  # the cheap exit for them. enforce falls through with zero findings, which
  # loop 2 reads as "every owned thread is absent" (dot-github#60): the old
  # unconditional exit 0 here was ahead of the thread listing and both loops,
  # so a gating thread on a since-reverted file could never auto-resolve.
  if [ "$PRT_MODE" != enforce ]; then
    prt_log "no diff, nothing to review (mode=$PRT_MODE)"
    { echo "## PR Review Threads: no diff"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    exit 0
  fi
  prt_log "net diff empty — zero findings; reconciling existing threads only"
  { echo "Net diff against base is empty — no findings this run; existing threads still reconciled."; echo; } \
    >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi

# Initialised before the EMPTY_DIFF guard below regardless of which branch
# runs — set -u is active (C11): an unbound expansion downstream aborts with
# exit 127, no ERR trap, no diagnostic, the exact silent shape #61 exists to
# eliminate. LINE_INDEX is only read in loop 1's CREATE arm, unreachable with
# zero findings — initialised anyway rather than resting on a reachability
# argument surviving the next edit.
ALL_FINDINGS='[]'
chunk_idx=0
chunk_count=0
LINE_INDEX='{}'
PR_TITLE=""; PR_DESC=""; PROJECT_AGENTS=""; PROJECT_CLAUDE_MD=""; PROJECT_STANDARDS=""

if [ "$EMPTY_DIFF" != 1 ]; then
meta_json="$(prt_retry 3 prt_gh_rest GET "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}")" || {
  echo "ERROR: failed to fetch PR metadata" >&2
  exit 1
}
PR_TITLE="$(jq -r '.title // "Untitled"' <<< "$meta_json")"
PR_DESC="$(jq -r '.body // ""' <<< "$meta_json")"

PROJECT_AGENTS=""
[ -n "$PRT_AGENTS_FILE" ] && [ -f "$PRT_AGENTS_FILE" ] && PROJECT_AGENTS="$(cat "$PRT_AGENTS_FILE")"
PROJECT_CLAUDE_MD=""
[ -f ".claude/CLAUDE.md" ] && PROJECT_CLAUDE_MD="$(cat ".claude/CLAUDE.md")"
# Deliberately PRT_SCRIPT_DIR-relative, not cwd-relative like the two reads
# above — docs/standards.md lives in go-kure/.github's own tree, not the
# calling repo's checkout that PROJECT_AGENTS/PROJECT_CLAUDE_MD read from.
PROJECT_STANDARDS=""
if [ -n "$PRT_STANDARDS_FILE" ]; then
  _prt_standards_path="$PRT_SCRIPT_DIR/../$PRT_STANDARDS_FILE"
  [ -f "$_prt_standards_path" ] && PROJECT_STANDARDS="$(cat "$_prt_standards_path")"
  unset _prt_standards_path
fi

# --- Commentable-line index (full diff, not per chunk) ---
LINE_INDEX="$(prt_build_line_index "$DIFF_FILE")"

# --- Chunk + review + assess ---
CHUNK_DIR="$WORKDIR/chunks"
chunk_count="$(prt_split_diff "$DIFF_FILE" "$PRT_MAX_DIFF_CHARS" "$CHUNK_DIR")"
split_rc=$?
if [ "$split_rc" -ne 0 ] || ! [[ "$chunk_count" =~ ^[0-9]+$ ]]; then
  prt_mark_incomplete "prt_split_diff failed (rc=$split_rc, chunk_count='$chunk_count') — diff chunking did not complete; its own incomplete-file append may not have landed"
  chunk_count=0
  # prt_split_diff can fail after writing one or more chunk files (a mid-run
  # disk-full/permissions failure, not just a fail-fast at the first write) —
  # discard them so the review loop below (glob over chunk-*.diff) processes
  # nothing from a run we've already declared incomplete, rather than sending
  # partial diff content to the model and letting its findings reach
  # reconciliation/writes below (codex round 1 finding, go-kure/.github#60/#61).
  rm -f "$CHUNK_DIR"/chunk-*.diff 2>/dev/null || true
fi
prt_log "diff: $(wc -c < "$DIFF_FILE" | tr -d ' ') bytes, chunks=$chunk_count"

# prt_parse_or_salvage RAW — parses RAW as JSON directly, falling back to a
# prt_extract_json_braces (model.sh:63-83) salvage pass before giving up.
# Local to this orchestrator, not model.sh — go-kure/.github#95: the "parse,
# else salvage" block used to be written out twice verbatim in the chunk
# loop below (the original attempt and its one bounded retry); this wraps
# the two `jq -c '.'` attempts around prt_extract_json_braces once, used by
# both call sites. Prints compact JSON to stdout on success, nothing on
# failure.
#   rc 0 — parsed directly, no salvage needed.
#   rc 2 — direct parse failed; parsed only after prt_extract_json_braces
#          salvage.
#   rc 1 — unparseable either way; stdout is empty.
prt_parse_or_salvage() {
  local raw="$1" parsed salvage
  parsed="$(jq -c '.' <<< "$raw" 2>/dev/null || echo '')"
  if [ -n "$parsed" ]; then
    printf '%s' "$parsed"
    return 0
  fi
  salvage="$(prt_extract_json_braces "$raw")" && \
    parsed="$(jq -c '.' <<< "$salvage" 2>/dev/null || echo '')"
  if [ -n "$parsed" ]; then
    printf '%s' "$parsed"
    return 2
  fi
  return 1
}

ALL_FINDINGS='[]'
chunk_idx=0
# go-kure/.github#107: chunks whose review call never produced parseable
# JSON (transport fault on either attempt, or invalid JSON surviving
# salvage+retry) are collected here rather than marked incomplete inline —
# whether that's fatal or merely degraded depends on whether any OTHER
# chunk in this run succeeded, which isn't known until the whole loop
# closes. go-kure/.github#95: a shape-valid response whose .findings was
# rejected after its own retry (prt_normalize_findings rc=1) is collected
# here too, identically. See the decision made right after this loop.
review_parse_failures=()
for chunk_file in "$CHUNK_DIR"/chunk-*.diff; do
  [ -f "$chunk_file" ] || continue
  chunk_diff="$(cat "$chunk_file")"

  review_rc=0
  raw="$(prt_model_review "$PRT_PROXY_URL" "$PRT_MODEL" "$PRT_MAX_TOKENS" "$chunk_diff" \
    "$PR_TITLE" "$PR_DESC" "$PRT_PROJECT_CONTEXT" "$PROJECT_AGENTS" "$PROJECT_CLAUDE_MD" "$PROJECT_STANDARDS")" || review_rc=$?
  # The call above ran in a command-substitution subshell, so model.sh's own
  # PRT_LAST_MODEL_FAILURE assignment never reached this shell — re-read the
  # file-backed copy PRT_LAST_MODEL_FAILURE_FILE points at instead (set once,
  # near WORKDIR's creation).
  PRT_LAST_MODEL_FAILURE="$(cat "$PRT_LAST_MODEL_FAILURE_FILE" 2>/dev/null || true)"
  if [ "$review_rc" -ne 0 ]; then
    # Mirrors the assess call's own exit-status check below: a non-zero
    # return here is a transport/proxy fault (curl failure, non-2xx, or
    # empty response content, model.sh:394-413), a different problem than a
    # 2xx response that isn't parseable JSON below. Closes, on the review
    # call's own retry, the same mislabeling gap a codex review found and
    # fixed for the assess call's retry (a transport fault there was being
    # reported as "not valid JSON").
    review_parse_failures+=("chunk $chunk_idx: review call failed (transport/proxy error, exit $review_rc) [${PRT_LAST_MODEL_FAILURE:-unknown}]")
    prt_log "chunk $chunk_idx: review FAILED (transport error, exit $review_rc)"
    chunk_idx=$((chunk_idx + 1))
    continue
  fi

  # Parse, with a salvage pass ahead of the (bounded-to-1) retry — cheapest
  # recovery first. go-kure/.github#60/#61 round 2 fold-in: launcher#283 run
  # 32175849548 hit "chunk 0: review response was not valid JSON" ->
  # prt_mark_incomplete -> fail-closed exit; retry 39s later, same head SHA,
  # succeeded. PRT_MAX_TOKENS and a finish_reason==length check can't fix
  # this against this proxy backend (both facts confirmed dead — see
  # model.sh's docstring and the incident record for why); this is the
  # resilience that's actually available: salvage the JSON out of a
  # prose-wrapped response (model.sh:prt_extract_json_braces, targets fact 3
  # — prt_strip_fence only handles a fenced marker on line 1/last line, not
  # surrounding prose), and one retry of the model call itself (not
  # prt_retry's usual 3 — each call already costs 40-60s against the job's
  # 20-minute budget, model.sh:267-279) if salvage doesn't recover it either.
  #
  # go-kure/.github#95: an attempt is "usable" only when it BOTH parses
  # (prt_parse_or_salvage rc 0/2) AND normalizes to something usable
  # (prt_normalize_findings rc 0/2) — not merely when it parses. Before this,
  # a response that parsed cleanly but whose .findings was totally unusable
  # (finding.sh rc=1: missing/null/non-array, or every row malformed and
  # dropped) went straight to fatal with no retry at all, unlike its sibling
  # parse-failure case right above, which already got the retry. The retry
  # below now fires on EITHER trigger, still bounded to one retry (at most
  # two model calls total, unchanged). A transport fault on the ORIGINAL
  # attempt (above) is deliberately NOT retried here — that behavior is
  # unchanged from before this fix.
  retried=false
  salvaged=false
  raw_json="$(prt_parse_or_salvage "$raw")"
  parse_rc=$?
  [ "$parse_rc" -eq 2 ] && salvaged=true
  norm_rc=1
  normalized='[]'
  if [ "$parse_rc" -ne 1 ]; then
    normalized="$(prt_normalize_findings "$raw_json")"
    norm_rc=$?
  fi

  if [ "$parse_rc" -eq 1 ] || [ "$norm_rc" -eq 1 ]; then
    retried=true
    review_rc=0
    raw="$(prt_model_review "$PRT_PROXY_URL" "$PRT_MODEL" "$PRT_MAX_TOKENS" "$chunk_diff" \
      "$PR_TITLE" "$PR_DESC" "$PRT_PROJECT_CONTEXT" "$PROJECT_AGENTS" "$PROJECT_CLAUDE_MD" "$PROJECT_STANDARDS")" || review_rc=$?
    # Same subshell-scoping reason as the original attempt's re-read above.
    PRT_LAST_MODEL_FAILURE="$(cat "$PRT_LAST_MODEL_FAILURE_FILE" 2>/dev/null || true)"
    if [ "$review_rc" -ne 0 ]; then
      # The retry call can ALSO hit a transport fault, distinct from the
      # retry producing another unparseable/unusable body — collapsing this
      # into a parse/normalize-failure branch below would both mislabel it
      # and compute prt_response_shape over an empty string, mirroring the
      # assess call's own retry check above.
      review_parse_failures+=("chunk $chunk_idx: review call failed on retry (transport/proxy error, exit $review_rc) [${PRT_LAST_MODEL_FAILURE:-unknown}]")
      prt_log "chunk $chunk_idx: review FAILED (transport error on retry, exit $review_rc)"
      chunk_idx=$((chunk_idx + 1))
      continue
    fi
    # salvaged is reset here, not just norm_rc/normalized: it must describe
    # only the attempt whose result is actually used below. Without this
    # reset, a first attempt that salvaged but was rejected by
    # prt_normalize_findings (norm_rc=1) would leave salvaged=true even when
    # the retry's response parses cleanly on its own — go-kure/.github#115
    # review finding, PR1 of go-kure/.github#95.
    salvaged=false
    raw_json="$(prt_parse_or_salvage "$raw")"
    parse_rc=$?
    [ "$parse_rc" -eq 2 ] && salvaged=true
    norm_rc=1
    normalized='[]'
    if [ "$parse_rc" -ne 1 ]; then
      normalized="$(prt_normalize_findings "$raw_json")"
      norm_rc=$?
    fi
  fi

  if [ "$parse_rc" -eq 1 ]; then
    # Shape-only diagnostic — length + leading-char class + whether salvage
    # was attempted, never the response text itself (Step 3c rule, "Failure
    # surface" in docs/pr-review-threads.md, stays in force).
    shape="$(prt_response_shape "${raw:-}")"
    review_parse_failures+=("chunk $chunk_idx: review response was not valid JSON after retry=$retried, salvage_attempted=true ($shape)")
    prt_log "chunk $chunk_idx: review FAILED (invalid JSON, retried=$retried)"
    chunk_idx=$((chunk_idx + 1))
    continue
  fi

  if [ "$norm_rc" -eq 1 ]; then
    # go-kure/.github#95: nothing usable came out of this chunk even after
    # the retry above — either .findings itself was missing/null/non-array,
    # or every row in an array-shaped .findings was malformed and dropped
    # (total loss, go-kure/.github#98 round 1 codex finding P1). This is the
    # sibling of the parse-failure branch above and gets identical
    # treatment: collected into review_parse_failures rather than marked
    # fatal inline, so the fatal-vs-degraded decision is made once, after
    # every chunk has been attempted, by prt_resolve_review_parse_failures
    # (state.sh) — fatal only when EVERY chunk in the run hit an unusable
    # response this way.
    review_parse_failures+=("chunk $chunk_idx: .findings missing/null/non-array, or all rows malformed and dropped (after retry=$retried)")
    prt_log "chunk $chunk_idx: review FAILED (.findings unusable, retried=$retried)"
    chunk_idx=$((chunk_idx + 1))
    continue
  fi

  # This diagnostic must fire only once the retried/salvaged attempt's
  # prt_normalize_findings call itself has returned 0 or 2 (i.e. only once
  # we reach here, past both failure branches above) — not merely upon a
  # successful JSON parse. Logging it earlier (right after the parse) would
  # print a false "recovered" line for a chunk that parsed fine on the retry
  # but still returned norm_rc=1 (both attempts exhausted) and was just
  # routed to review_parse_failures as failed above.
  if [ "$retried" = true ] || [ "$salvaged" = true ]; then
    prt_log "chunk $chunk_idx: review recovered (retried=$retried salvaged=$salvaged)"
  fi

  if [ "$norm_rc" -eq 2 ]; then
    # go-kure/.github#98: a shape-valid .findings array with one or more
    # individually malformed rows dropped is degraded, not fatal — most of
    # the chunk was still reviewed (finding.sh:49-68's rc contract, enforced
    # at finding.sh:140-150). The
    # "partial-drop" substring in this reason is load-bearing: the absence
    # loop's incomplete_now check below (:914ish) greps prt_degraded_reasons
    # for it specifically, so a dropped row's existing thread still isn't
    # read as absent this run even though the run itself no longer fails
    # closed. Do NOT also call prt_mark_incomplete here — dual-marking would
    # force exit 1 regardless (the exit gate at this file's tail treats
    # PRT_INCOMPLETE_FILE as fatal unconditionally), defeating the point of
    # moving this case to degraded. The retry trigger above only fires on
    # rc=1, so an rc=2 result on the FIRST attempt never itself causes a
    # retry — but rc=2 can still be the outcome of a retried attempt, when
    # the first attempt returned rc=1 and the retry's response normalizes
    # with some (not all) rows malformed.
    prt_mark_degraded "chunk $chunk_idx: partial-drop — one or more malformed finding row(s) dropped from .findings, rest of chunk reviewed"
  fi

  tagged="$(jq -c --argjson idx "$chunk_idx" 'map(. + {_chunk: $idx})' <<< "$normalized")"
  ALL_FINDINGS="$(jq -c -n --argjson a "$ALL_FINDINGS" --argjson b "$tagged" '$a + $b')"
  prt_log "chunk $chunk_idx: review ok ($(jq 'length' <<< "$tagged") findings)"
  chunk_idx=$((chunk_idx + 1))
done

# go-kure/.github#107: resolve the deferred review_parse_failures decision
# now that every chunk has been attempted. See prt_resolve_review_parse_failures
# in lib/prt/state.sh for the fatal-vs-degraded rule and citations. chunk_idx
# here is every chunk actually iterated; if it's 0 (prt_split_diff itself
# failed, :218-227) there's nothing to resolve — that path already marked
# incomplete directly and left no chunk files to loop over.
prt_resolve_review_parse_failures "$chunk_idx" "${review_parse_failures[@]}"

# chunk_idx (chunks actually iterated, via the glob above) should always
# equal chunk_count (chunks prt_split_diff reported writing) — a mismatch
# means the glob saw fewer/more files than were written (e.g. a partial
# write) and the review below silently covers less of the diff than
# intended, with nothing else to catch it.
if [ "$chunk_idx" -ne "$chunk_count" ]; then
  prt_mark_incomplete "chunk count mismatch: prt_split_diff reported $chunk_count, $chunk_idx were iterated"
fi

# Ordinals/collisions assigned across the WHOLE run, not per chunk.
ALL_FINDINGS="$(prt_assign_ordinals "$ALL_FINDINGS")"

# Assessment: per chunk, against that chunk's own diff, joined by fp.
ASSESSED='[]'
for ((i = 0; i < chunk_idx; i++)); do
  chunk_file="$CHUNK_DIR/chunk-$(printf '%03d' "$i").diff"
  [ -f "$chunk_file" ] || continue
  chunk_findings="$(jq -c --argjson idx "$i" '[.[] | select(._chunk == $idx)]' <<< "$ALL_FINDINGS")"
  [ "$(jq 'length' <<< "$chunk_findings")" -gt 0 ] || continue
  chunk_diff="$(cat "$chunk_file")"

  assess_rc=0
  assess_raw="$(prt_model_assess "$PRT_PROXY_URL" "$PRT_ASSESS_MODEL" "$PRT_ASSESS_MAX_TOKENS" \
    "$chunk_diff" "$chunk_findings" "$PR_TITLE" "$PRT_PROJECT_CONTEXT" "$PROJECT_AGENTS" "$PROJECT_CLAUDE_MD" "$PROJECT_STANDARDS")" || assess_rc=$?
  # Command substitution above runs in a subshell; re-read the file-backed
  # PRT_LAST_MODEL_FAILURE (see the review call's identical comment above).
  PRT_LAST_MODEL_FAILURE="$(cat "$PRT_LAST_MODEL_FAILURE_FILE" 2>/dev/null || true)"
  if [ "$assess_rc" -ne 0 ]; then
    # A non-zero return here is a transport/proxy fault (prt_model_assess's
    # own stderr already named it — curl failure, non-2xx, or empty response
    # content, model.sh:394-413) and is a different problem than a 2xx
    # response that isn't parseable JSON below. Reported distinctly so the
    # two don't collapse into one ambiguous message (root cause 2).
    # go-kure/.github#98: an assessment-call fault means this chunk's review
    # ran and produced findings, only their VALID/PARTIALLY_VALID/
    # FALSE_POSITIVE verdicts are missing — degraded, not fatal (unlike a
    # review-call fault above, which means the chunk wasn't reviewed at
    # all). The finding stays open with verdict:null via the fallback below,
    # same as before this change; only the run's severity/exit code differs.
    prt_mark_degraded "chunk $i: assessment call failed (transport/proxy error, exit $assess_rc); findings stay unverdicted [${PRT_LAST_MODEL_FAILURE:-unknown}]"
    prt_log "chunk $i: review ok, assess FAILED (transport error, exit $assess_rc)"
    ASSESSED="$(jq -c -n --argjson a "$ASSESSED" --argjson b "$chunk_findings" '$a + ($b | map(. + {verdict: null, reasoning: null}))')"
    continue
  fi

  # Parse, with a salvage pass ahead of the (bounded-to-1) retry — mirrors the
  # review call's recovery path above (go-kure/.github#60/#61 round 2
  # fold-in): the assessment call shares the same backend and the same
  # prose-wrapping failure mode, so it gets the same recovery, not a lesser
  # one.
  assess_json="$(jq -c '.' <<< "$assess_raw" 2>/dev/null || echo '')"
  assess_retried=false
  assess_salvaged=false
  if [ -z "$assess_json" ]; then
    assess_salvage="$(prt_extract_json_braces "$assess_raw")" && \
      assess_json="$(jq -c '.' <<< "$assess_salvage" 2>/dev/null || echo '')"
    [ -n "$assess_json" ] && assess_salvaged=true
  fi
  if [ -z "$assess_json" ]; then
    assess_retried=true
    assess_rc=0
    assess_raw="$(prt_model_assess "$PRT_PROXY_URL" "$PRT_ASSESS_MODEL" "$PRT_ASSESS_MAX_TOKENS" \
      "$chunk_diff" "$chunk_findings" "$PR_TITLE" "$PRT_PROJECT_CONTEXT" "$PROJECT_AGENTS" "$PROJECT_CLAUDE_MD" "$PROJECT_STANDARDS")" || assess_rc=$?
    # Same subshell-scoping reason as the original attempt's re-read above.
    PRT_LAST_MODEL_FAILURE="$(cat "$PRT_LAST_MODEL_FAILURE_FILE" 2>/dev/null || true)"
    if [ "$assess_rc" -ne 0 ]; then
      # The retry call can ALSO hit a transport fault, distinct from the
      # retry producing another unparseable body — collapsing this into the
      # parse-failure branch below would both mislabel it and compute
      # prt_response_shape over an empty string (codex round-1 finding: a
      # transport failure on the retry was being reported as "not valid
      # JSON").
      # go-kure/.github#98: degraded, not fatal — see the original-attempt
      # transport-fault comment above; the same reasoning applies to the
      # retry.
      prt_mark_degraded "chunk $i: assessment call failed on retry (transport/proxy error, exit $assess_rc); findings stay unverdicted [${PRT_LAST_MODEL_FAILURE:-unknown}]"
      prt_log "chunk $i: review ok, assess FAILED (transport error on retry, exit $assess_rc)"
      ASSESSED="$(jq -c -n --argjson a "$ASSESSED" --argjson b "$chunk_findings" '$a + ($b | map(. + {verdict: null, reasoning: null}))')"
      continue
    fi
    if [ -n "$assess_raw" ]; then
      assess_json="$(jq -c '.' <<< "$assess_raw" 2>/dev/null || echo '')"
      if [ -z "$assess_json" ]; then
        assess_salvage="$(prt_extract_json_braces "$assess_raw")" && \
          assess_json="$(jq -c '.' <<< "$assess_salvage" 2>/dev/null || echo '')"
        [ -n "$assess_json" ] && assess_salvaged=true
      fi
    fi
  fi
  if [ -z "$assess_json" ]; then
    # Shape-only diagnostic, same rule as the review path above and
    # docs/pr-review-threads.md's "Failure surface" — never the response text.
    shape="$(prt_response_shape "${assess_raw:-}")"
    # go-kure/.github#98: degraded, not fatal — a residual parse failure
    # after salvage+retry still means the review itself ran; only the
    # verdicts are missing, same reasoning as the transport-fault sites
    # above.
    prt_mark_degraded "chunk $i: assessment response was not valid JSON after retry=$assess_retried, salvage_attempted=true ($shape); findings stay unverdicted"
    prt_log "chunk $i: review ok, assess FAILED (invalid JSON, retried=$assess_retried)"
    ASSESSED="$(jq -c -n --argjson a "$ASSESSED" --argjson b "$chunk_findings" '$a + ($b | map(. + {verdict: null, reasoning: null}))')"
    continue
  fi
  if [ "$assess_retried" = true ] || [ "$assess_salvaged" = true ]; then
    prt_log "chunk $i: assess recovered (retried=$assess_retried salvaged=$assess_salvaged)"
  fi
  # go-kure/.github#98: degraded, not fatal — distinct code path from the
  # three sites above (the assessment response DID parse as JSON here; it's
  # prt_join_assessment rejecting its `.assessments` shape), same outcome
  # (every finding in this chunk stays unverdicted, verdict:null).
  joined="$(prt_join_assessment "$chunk_findings" "$assess_json")" || \
    prt_mark_degraded "chunk $i: .assessments missing/null/non-array"
  prt_log "chunk $i: review ok, assess ok"
  ASSESSED="$(jq -c -n --argjson a "$ASSESSED" --argjson b "$joined" '$a + $b')"
done
ALL_FINDINGS="$ASSESSED"
fi # EMPTY_DIFF != 1

# --- List existing owned threads (GraphQL, paginated) — enforce mode only.
# advisory/off never read OWNED (advisory's branch below doesn't touch it,
# and loop 2 is already enforce-gated), so a transient GraphQL failure here
# must not cost the review that mode already computed and is about to post
# (dot-github#50 gmr finding R3: this used to run unconditionally and abort
# the whole job on any listing hiccup, in the mode that ships wired live). ---
OWNED='[]'
if [ "$PRT_MODE" = enforce ]; then
# shellcheck disable=SC2016  # $owner/$repo/$pr/$cursor are GraphQL variable
# references, resolved server-side from the `variables` JSON object built
# below via jq -n — they must NOT be shell-expanded here.
list_query='
query($owner:String!, $repo:String!, $pr:Int!, $cursor:String) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$pr) {
      reviewThreads(first:50, after:$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          resolvedBy { login }
          viewerCanResolve
          viewerCanUnresolve
          comments(first:50) {
            pageInfo { hasNextPage endCursor }
            nodes { id databaseId body author { login } }
          }
        }
      }
    }
  }
}'
# shellcheck disable=SC2016
comment_page_query='
query($id:ID!, $cursor:String) {
  node(id:$id) {
    ... on PullRequestReviewThread {
      comments(first:50, after:$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { id databaseId body author { login } }
      }
    }
  }
}'
OWNER="${PRT_REPO%%/*}"
REPO_NAME="${PRT_REPO##*/}"

THREADS='[]'
cursor=null
inventory_failed=0
inventory_failure_stage=''
prt_inventory_fail() {
  local stage="$1"
  if [ "$inventory_failed" != 1 ]; then
    inventory_failed=1
    inventory_failure_stage="$stage"
    echo "ERROR: review thread inventory failed at $stage; aborting before any write." >&2
  fi
}
while :; do
  if ! vars="$(jq -n --arg owner "$OWNER" --arg repo "$REPO_NAME" --argjson pr "$PRT_PR_NUMBER" --argjson cursor "$cursor" \
    '{owner:$owner, repo:$repo, pr:$pr, cursor:$cursor}' 2>/dev/null)"; then
    prt_inventory_fail "reviewThreads request variables"
    break
  fi
  if ! data="$(prt_gh_graphql "$list_query" "$vars" 2>/dev/null)"; then
    prt_inventory_fail "reviewThreads request"
    break
  fi
  if ! page="$(prt_json_extract_inventory_page review_threads "$data")"; then
    prt_inventory_fail "reviewThreads page extraction"
    break
  fi
  if ! page_nodes="$(jq -ce '.nodes | select(type == "array")' <<< "$page" 2>/dev/null)"; then
    prt_inventory_fail "reviewThreads page nodes"
    break
  fi
  if ! merged_threads="$(prt_json_concat_arrays "$THREADS" "$page_nodes")"; then
    prt_inventory_fail "reviewThreads page concatenation"
    break
  fi
  THREADS="$merged_threads"
  if ! has_next="$(jq -r '.pageInfo.hasNextPage' <<< "$page" 2>/dev/null)"; then
    prt_inventory_fail "reviewThreads pagination flag"
    break
  fi
  case "$has_next" in true|false) : ;; *) prt_inventory_fail "reviewThreads pagination flag"; break ;; esac
  [ "$inventory_failed" = 1 ] && break
  [ "$has_next" = true ] || break
  if ! next_cursor="$(jq -ce '.pageInfo.endCursor | select(type == "string" and length > 0)' <<< "$page" 2>/dev/null)"; then
    prt_inventory_fail "reviewThreads pagination cursor"
    break
  fi
  cursor="$next_cursor"
done

# Comment pagination: a thread with more than 50 comments hides any human
# reply past the 50th from the (first:50) page above — the absence loop
# would then treat an actively-discussed thread as unmatched and eligible
# for auto-resolve (dot-github#50 gmr finding C4). Fetch the rest, per
# thread, only for threads that actually need it.
if [ "$inventory_failed" != 1 ]; then
  if ! n_threads_pg="$(jq -r 'if type == "array" then length else error("not an array") end' <<< "$THREADS" 2>/dev/null)"; then
    prt_inventory_fail "reviewThreads array validation"
  fi
fi
if [ "$inventory_failed" != 1 ]; then
  for ((tpi = 0; tpi < n_threads_pg; tpi++)); do
    if ! th_pg="$(jq -ce --argjson i "$tpi" '.[$i] | select(type == "object")' <<< "$THREADS" 2>/dev/null)"; then
      prt_inventory_fail "thread selection at index $tpi"
      break
    fi
    if ! has_more="$(jq -r '.comments.pageInfo.hasNextPage' <<< "$th_pg" 2>/dev/null)"; then
      prt_inventory_fail "comment pagination flag at thread index $tpi"
      break
    fi
    case "$has_more" in true|false) : ;; *) prt_inventory_fail "comment pagination flag at thread index $tpi"; break ;; esac
    [ "$inventory_failed" = 1 ] && break
    [ "$has_more" = true ] || continue
    if ! tcursor="$(jq -ce '.comments.pageInfo.endCursor | select(type == "string" and length > 0)' <<< "$th_pg" 2>/dev/null)"; then
      prt_inventory_fail "initial comment pagination cursor at thread index $tpi"
      break
    fi
    if ! tid_pg="$(jq -er '.id | select(type == "string" and length > 0)' <<< "$th_pg" 2>/dev/null)"; then
      prt_inventory_fail "thread id at index $tpi"
      break
    fi
    extra_nodes='[]'
    while :; do
      if ! cvars="$(jq -n --arg id "$tid_pg" --argjson cursor "$tcursor" '{id:$id, cursor:$cursor}' 2>/dev/null)"; then
        prt_inventory_fail "comment page request variables at thread index $tpi"
        break
      fi
      if ! cdata="$(prt_gh_graphql "$comment_page_query" "$cvars" 2>/dev/null)"; then
        prt_inventory_fail "comment page request at thread index $tpi"
        break
      fi
      if ! cpage="$(prt_json_extract_inventory_page comments "$cdata")"; then
        prt_inventory_fail "comment page extraction at thread index $tpi"
        break
      fi
      if ! comment_nodes="$(jq -ce '.nodes | select(type == "array")' <<< "$cpage" 2>/dev/null)"; then
        prt_inventory_fail "comment page nodes at thread index $tpi"
        break
      fi
      if ! merged_comments="$(prt_json_concat_arrays "$extra_nodes" "$comment_nodes")"; then
        prt_inventory_fail "comment page concatenation at thread index $tpi"
        break
      fi
      extra_nodes="$merged_comments"
      if ! chas_next="$(jq -r '.pageInfo.hasNextPage' <<< "$cpage" 2>/dev/null)"; then
        prt_inventory_fail "comment pagination flag at thread index $tpi"
        break
      fi
      case "$chas_next" in true|false) : ;; *) prt_inventory_fail "comment pagination flag at thread index $tpi"; break ;; esac
      [ "$inventory_failed" = 1 ] && break
      [ "$chas_next" = true ] || break
      if ! next_tcursor="$(jq -ce '.pageInfo.endCursor | select(type == "string" and length > 0)' <<< "$cpage" 2>/dev/null)"; then
        prt_inventory_fail "comment pagination cursor at thread index $tpi"
        break
      fi
      tcursor="$next_tcursor"
    done
    [ "$inventory_failed" = 1 ] && break
    if ! updated_threads="$(prt_json_append_thread_comments "$THREADS" "$tpi" "$extra_nodes")"; then
      prt_inventory_fail "nested comment update at thread index $tpi"
      break
    fi
    THREADS="$updated_threads"
  done
fi

if [ "$inventory_failed" = 1 ]; then
  prt_mark_incomplete "review thread inventory failed at $inventory_failure_stage"
  {
    # 0, not $SUPPRESSED_COUNT: this abort happens before loop 1 (which
    # increments it) ever runs, so nothing has been suppressed yet.
    prt_render_summary "$PRT_MODE" "$PRT_HEAD_SHA" "$chunk_idx" "$ALL_FINDINGS" 0 "$(prt_incomplete_reasons)" "$(prt_degraded_reasons)"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  prt_report_degraded_annotations
  exit 1
fi

# Ownership = marker on first comment AND that comment's author is the bot.
# GraphQL's Bot.login omits the REST "[bot]" suffix PRT_BOT_LOGIN is
# documented and wired with (e.g. "github-actions[bot]" vs "github-actions",
# proven against a live comment — dot-github#50 gmr finding R1); strip it
# before comparing against a GraphQL-sourced login. A caller wiring a plain
# user login (no "[bot]" suffix) is unaffected — stripping a suffix that
# isn't present is a no-op.
PRT_BOT_LOGIN_GQL="${PRT_BOT_LOGIN%\[bot\]}"

# Build a lookup: fp -> {thread_id, resolved, resolved_by_bot, first_comment_id, has_human_reply}
n_threads="$n_threads_pg"
for ((ti = 0; ti < n_threads; ti++)); do
  if ! th="$(jq -ce --argjson i "$ti" '.[$i] | select(type == "object")' <<< "$THREADS" 2>/dev/null)"; then
    prt_inventory_fail "ownership thread selection at index $ti"
    break
  fi
  if ! first_comment="$(jq -c '.comments.nodes[0] // empty' <<< "$th" 2>/dev/null)"; then
    prt_inventory_fail "first-comment selection at thread index $ti"
    break
  fi
  [ -n "$first_comment" ] || continue
  if ! first_author="$(jq -r '.author.login // empty' <<< "$first_comment" 2>/dev/null)"; then
    prt_inventory_fail "first-comment author at thread index $ti"
    break
  fi
  if ! first_body="$(jq -r '.body' <<< "$first_comment" 2>/dev/null)"; then
    prt_inventory_fail "first-comment body at thread index $ti"
    break
  fi
  [ "$first_author" = "$PRT_BOT_LOGIN_GQL" ] || continue
  parsed="$(prt_marker_parse "$first_body")" || continue
  fp="$(cut -f1 <<< "$parsed")"
  collision="$(cut -f2 <<< "$parsed")"
  first_absent_sha="$(cut -f3 <<< "$parsed")"

  has_human_reply=false
  if ! n_comments="$(jq -r '.comments.nodes | length' <<< "$th" 2>/dev/null)"; then
    prt_inventory_fail "comment count at thread index $ti"
    break
  fi
  for ((ci = 1; ci < n_comments; ci++)); do
    if ! cbody="$(jq -r --argjson i "$ci" '.comments.nodes[$i].body' <<< "$th" 2>/dev/null)"; then
      prt_inventory_fail "comment body at thread index $ti comment index $ci"
      break
    fi
    if ! prt_marker_has_note "$cbody"; then has_human_reply=true; fi
  done
  [ "$inventory_failed" = 1 ] && break

  # Fail-closed on the resolvedBy:User vs Actions-token-is-a-Bot ambiguity
  # (V6, unverified until a live spike): a null resolvedBy on a resolved
  # thread is treated as human-resolved, never reopened. Costs a missed
  # reopen, never a wrong one.
  if ! ownership_row="$(jq -ce --arg fp "$fp" --arg collision "$collision" \
    --arg fas "$first_absent_sha" --arg bot "$PRT_BOT_LOGIN_GQL" \
    --argjson hhr "$has_human_reply" '
      {
        fp:$fp,
        collision:($collision == "true"),
        first_absent_sha:$fas,
        resolved:.isResolved,
        resolved_by_bot:(.isResolved and ((.resolvedBy.login // "") == $bot)),
        has_human_reply:$hhr,
        thread_id:.id,
        first_comment_id:.comments.nodes[0].id,
        first_comment_db_id:.comments.nodes[0].databaseId,
        viewer_can_resolve:.viewerCanResolve,
        viewer_can_unresolve:.viewerCanUnresolve
      }
    ' <<< "$th" 2>/dev/null)"; then
    prt_inventory_fail "ownership-row construction at thread index $ti"
    break
  fi
  if ! merged_owned="$(prt_json_concat_arrays "$OWNED" "[$ownership_row]")"; then
    prt_inventory_fail "ownership-row concatenation at thread index $ti"
    break
  fi
  OWNED="$merged_owned"
done
if [ "$inventory_failed" != 1 ]; then
  if ! owned_count="$(jq -r 'if type == "array" then length else error("not an array") end' <<< "$OWNED" 2>/dev/null)"; then
    prt_inventory_fail "owned-thread array validation"
  fi
fi
if [ "$inventory_failed" = 1 ]; then
  prt_mark_incomplete "review thread inventory failed at $inventory_failure_stage"
  {
    prt_render_summary "$PRT_MODE" "$PRT_HEAD_SHA" "$chunk_idx" "$ALL_FINDINGS" 0 "$(prt_incomplete_reasons)" "$(prt_degraded_reasons)"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  prt_report_degraded_annotations
  exit 1
fi
prt_log "threads listed: $n_threads, owned=$owned_count"
fi # PRT_MODE = enforce

# --- PR-wide severity cap: bound the number of gating (currently open, or
# about to become open/reopened) review threads to PRT_MAX_FINDINGS_TOTAL.
# The budget-derivation rationale (why this walks OWNED via prt_decide_finding
# instead of ranking existing threads, the 4-rewrite history, dot-github#51)
# now lives in scripts/lib/prt/reconcile.sh above prt_thread_stays_gating —
# it is the specification for the functions this line calls; not duplicated
# here.
if ! capped_findings="$(prt_apply_cap "$PRT_MAX_FINDINGS_TOTAL" "$OWNED" "$ALL_FINDINGS" 2>/dev/null)"; then
  echo "ERROR: review inventory cap evaluation failed; aborting before any write." >&2
  prt_mark_incomplete "review inventory cap evaluation failed"
  {
    prt_render_summary "$PRT_MODE" "$PRT_HEAD_SHA" "$chunk_idx" "$ALL_FINDINGS" 0 "$(prt_incomplete_reasons)" "$(prt_degraded_reasons)"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  prt_report_degraded_annotations
  exit 1
fi
ALL_FINDINGS="$capped_findings"

# ============================= LOOP 1: findings =============================
# Evaluates every finding this run produced to completion (successes and
# failures alike) BEFORE loop 2 reads REVIEW_INCOMPLETE.
OVERFLOW='[]'
SUPPRESSED_COUNT=0
MATCHED_FPS='[]'

if [ "$PRT_MODE" = advisory ]; then
  # advisory: zero thread creates/mutations, one plain issue comment with
  # the merged findings table — the staged-rollout mechanism itself.
  advisory_findings="$(jq -c '[.[] | select(.verdict != "FALSE_POSITIVE")]' <<< "$ALL_FINDINGS")"
  advisory_incomplete_reasons=""
  prt_is_incomplete && advisory_incomplete_reasons="$(prt_incomplete_reasons)"
  advisory_degraded_reasons=""
  prt_is_degraded && advisory_degraded_reasons="$(prt_degraded_reasons)"
  body="$(prt_render_advisory_comment "$advisory_findings" "$advisory_incomplete_reasons" "$advisory_degraded_reasons")"
  payload="$(jq -n --arg b "$body" '{body:$b}')"
  if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
    prt_gh_rest POST "/repos/${PRT_REPO}/issues/${PRT_PR_NUMBER}/comments" "$payload" >/dev/null || \
      prt_mark_incomplete "failed to post advisory comment (HTTP ${PRT_LAST_HTTP_STATUS:-unknown})"
  else
    prt_handle_freshness_rc "$?" "advisory comment"
  fi
else
  n_findings="$(jq 'length' <<< "$ALL_FINDINGS")"
  for ((fi = 0; fi < n_findings; fi++)); do
    f="$(jq -c ".[$fi]" <<< "$ALL_FINDINGS")"
    fp="$(jq -r '.fp' <<< "$f")"
    collision="$(jq -r '.collision' <<< "$f")"
    verdict="$(jq -r '.verdict // "NONE"' <<< "$f")"
    within_cap="$(jq -r '.within_cap' <<< "$f")"

    owned_match="$(jq -c --arg fp "$fp" 'map(select(.fp == $fp)) | .[0] // empty' <<< "$OWNED")"
    thread_exists=false; thread_resolved=false; resolved_by_bot=false
    if [ -n "$owned_match" ]; then
      thread_exists=true
      thread_resolved="$(jq -r '.resolved' <<< "$owned_match")"
      resolved_by_bot="$(jq -r '.resolved_by_bot' <<< "$owned_match")"
      MATCHED_FPS="$(jq -c --arg fp "$fp" '. + [$fp]' <<< "$MATCHED_FPS")"

      # Collision quarantine must be durable the moment multiplicity is
      # detected, even against a thread that predates the collision and is
      # therefore still marked collision=false — prt_decide_finding's row 1
      # returns NONE unconditionally for a colliding finding, so without
      # this write the thread's own marker would never learn it's
      # quarantined, and a later run reverting to a single finding on this
      # fp_base would silently resume normal reconcile/resolve/reopen
      # against what is actually an ambiguous identity (dot-github#50 gmr
      # finding C5).
      if [ "$collision" = true ]; then
        owned_collision="$(jq -r '.collision' <<< "$owned_match")"
        if [ "$owned_collision" != true ]; then
          if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
            db_id="$(jq -r '.first_comment_db_id' <<< "$owned_match")"
            cur_resp="$(prt_gh_rest GET "/repos/${PRT_REPO}/pulls/comments/${db_id}")"
            cur_body="$(jq -r '.body // empty' <<< "${cur_resp:-}" 2>/dev/null || true)"
            if [ -n "$cur_body" ]; then
              fas="$(jq -r '.first_absent_sha' <<< "$owned_match")"
              [ "$fas" = null ] && fas=""
              new_marker="$(prt_marker_build "$fp" "true" "$fas")"
              new_body="$(prt_marker_replace "$cur_body" "$new_marker")"
              prt_retry 3 prt_gh_rest_fresh PATCH "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" \
                "/repos/${PRT_REPO}/pulls/comments/${db_id}" \
                "$(jq -n --arg b "$new_body" '{body:$b}')" >/dev/null
              retry_rc=$?
              [ "$retry_rc" -eq 0 ] || \
                prt_handle_freshness_rc "$retry_rc" "fp=$fp: persisting collision=true onto existing thread (after up to 3 retries)"
            else
              prt_mark_incomplete "fp=$fp: GET before collision-marker persist failed or returned empty body, skipped"
            fi
          else
            prt_handle_freshness_rc "$?" "fp=$fp: collision-marker persist"
          fi
        fi
      fi
    fi

    # OR with the thread's own persisted collision flag, not just this
    # finding's this-run value: loop 2 already reads owned_match.collision
    # (the value the block above just persisted) at the absence-side
    # equivalent, so evaluating this side on the this-run value alone let
    # the two loops disagree about the same thread — a run that reverts to
    # a single (non-colliding) finding on an fp_base a prior run quarantined
    # would resume normal resolve/reopen here, exactly what the C5 write
    # above exists to prevent (dot-github#50 gmr finding B3).
    effective_collision="$collision"
    if [ "$thread_exists" = true ]; then
      owned_collision_eff="$(jq -r '.collision' <<< "$owned_match")"
      [ "$owned_collision_eff" = true ] && effective_collision=true
    fi

    action="$(prt_decide_finding "$effective_collision" "$verdict" "$thread_exists" "$thread_resolved" "$resolved_by_bot" "$within_cap")"
    prt_log "fp=$fp -> $action"

    case "$action" in
      NONE) : ;;
      SUPPRESS) SUPPRESSED_COUNT=$((SUPPRESSED_COUNT + 1)) ;;
      OVERFLOW) OVERFLOW="$(jq -c --argjson f "$f" '. + [$f]' <<< "$OVERFLOW")" ;;
      REPLY_RESOLVE)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_handle_freshness_rc "$?" "fp=$fp: reply+resolve"; continue; }
        can_resolve="$(jq -r '.viewer_can_resolve' <<< "$owned_match")"
        if [ "$can_resolve" != true ]; then
          prt_mark_incomplete "fp=$fp: viewerCanResolve=false, skipping resolve"
          continue
        fi
        thread_id="$(jq -r '.thread_id' <<< "$owned_match")"
        db_id="$(jq -r '.first_comment_db_id' <<< "$owned_match")"
        # Mutate first, reply only on success — reversing the naive
        # reply-then-mutate order. A resolve/unresolve failure (permission
        # gap, transient 5xx, secondary rate limit) previously left an
        # explanatory reply attached to a thread that stayed unresolved and
        # merge-blocking; the next run's decision table re-derives the same
        # REPLY_RESOLVE action with no memory that a reply was already sent,
        # so every subsequent run posted another identical reply forever
        # (dot-github#50 gmr finding R2). Mutating first means a failure
        # costs one skipped, retryable reply next run — not an unbounded
        # spam loop on a thread that never closes.
        mut="mutation(\$id:ID!){resolveReviewThread(input:{threadId:\$id}){thread{id}}}"
        if prt_gh_graphql "$mut" "$(jq -n --arg id "$thread_id" '{id:$id}')" >/dev/null; then
          # This freshness check only gates the reply, not the mutation
          # above — which already committed. prt_handle_freshness_rc's rc=1
          # ("safe to treat as non-fatal") relies on a superseding run
          # redoing the SAME skipped write; here nothing would be redone,
          # since the successor's decision table sees the thread already
          # resolved and computes NONE, so the explanatory reply is lost
          # for good (codex round-2 confirm finding, go-kure/.github#99).
          # Stay fatal via prt_mark_incomplete regardless of rc.
          if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
            reasoning="$(jq -r '.reasoning // "no reasoning provided"' <<< "$f")"
            reply="$(prt_render_reply_false_positive "$reasoning")"
            reply_payload="$(jq -n --arg b "$reply" --argjson r "$db_id" '{body:$b, in_reply_to:$r}')"
            prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" "$reply_payload" >/dev/null || \
              prt_mark_incomplete "fp=$fp: resolveReviewThread succeeded but the explanatory reply failed"
          else
            prt_mark_incomplete "fp=$fp: resolveReviewThread succeeded but the post-mutation freshness re-check did not pass (head moved, or the check itself failed) — mutation already applied and will not be redone by a superseding run, reply permanently skipped"
          fi
        else
          prt_mark_incomplete "fp=$fp: resolveReviewThread (FALSE POSITIVE) failed, reply skipped to avoid a duplicate on retry"
        fi
        ;;
      REPLY_UNRESOLVE)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_handle_freshness_rc "$?" "fp=$fp: reply+unresolve"; continue; }
        can_unresolve="$(jq -r '.viewer_can_unresolve' <<< "$owned_match")"
        if [ "$can_unresolve" != true ]; then
          prt_mark_incomplete "fp=$fp: viewerCanUnresolve=false, skipping unresolve"
          continue
        fi
        thread_id="$(jq -r '.thread_id' <<< "$owned_match")"
        db_id="$(jq -r '.first_comment_db_id' <<< "$owned_match")"
        mut="mutation(\$id:ID!){unresolveReviewThread(input:{threadId:\$id}){thread{id}}}"
        if prt_gh_graphql "$mut" "$(jq -n --arg id "$thread_id" '{id:$id}')" >/dev/null; then
          # Same reasoning as REPLY_RESOLVE above: this check only gates the
          # reply, the mutation already committed, so a superseding run will
          # not redo it — stay fatal via prt_mark_incomplete regardless of rc
          # (codex round-2 confirm finding, go-kure/.github#99).
          if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
            reply="$(prt_render_reply_recurrence)"
            reply_payload="$(jq -n --arg b "$reply" --argjson r "$db_id" '{body:$b, in_reply_to:$r}')"
            prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" "$reply_payload" >/dev/null || \
              prt_mark_incomplete "fp=$fp: unresolveReviewThread succeeded but the explanatory reply failed"
          else
            prt_mark_incomplete "fp=$fp: unresolveReviewThread succeeded but the post-mutation freshness re-check did not pass (head moved, or the check itself failed) — mutation already applied and will not be redone by a superseding run, reply permanently skipped"
          fi
        else
          prt_mark_incomplete "fp=$fp: unresolveReviewThread failed, reply skipped to avoid a duplicate on retry"
        fi
        ;;
      CREATE)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_handle_freshness_rc "$?" "fp=$fp: create"; continue; }
        marker="$(prt_marker_build "$fp" "$collision" "")"
        body="$(prt_render_finding_body "$f" "$marker")"
        file="$(jq -r '.file' <<< "$f")"
        line="$(jq -r '.line' <<< "$f")"
        anchored=false
        if [ "$line" != "null" ] && [ -n "$line" ]; then
          in_index="$(jq --arg f "$file" --argjson l "$line" '(.[$f] // []) | index($l) != null' <<< "$LINE_INDEX")"
          [ "$in_index" = true ] && anchored=true
        fi
        create_payload=""
        if [ "$anchored" = true ]; then
          create_payload="$(jq -n --arg b "$body" --arg sha "$PRT_HEAD_SHA" --arg path "$file" --argjson l "$line" \
            '{body:$b, commit_id:$sha, path:$path, line:$l, side:"RIGHT"}')"
        else
          create_payload="$(jq -n --arg b "$body" --arg sha "$PRT_HEAD_SHA" --arg path "$file" \
            '{body:$b, commit_id:$sha, path:$path, subject_type:"file"}')"
        fi
        if ! prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" "$create_payload" >/dev/null; then
          # 422 ladder gated on the actual status, not "any non-2xx": a
          # transient 403 (secondary rate limit) or 502 here previously
          # triggered an immediate second POST, which can succeed and leave
          # a duplicate gating thread for the same finding once the first
          # POST's failure was itself transient rather than a genuine
          # line/anchor rejection (dot-github#50 gmr finding N9).
          if [ "$anchored" = true ] && [ "$PRT_LAST_HTTP_STATUS" = 422 ]; then
            # Line rejected (out-of-diff line, deleted file anchor, etc.) —
            # fall back to a file-level thread once. Recheck freshness
            # immediately before this second write.
            if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
              fallback_payload="$(jq -n --arg b "$body" --arg sha "$PRT_HEAD_SHA" --arg path "$file" \
                '{body:$b, commit_id:$sha, path:$path, subject_type:"file"}')"
              prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" "$fallback_payload" >/dev/null || \
                prt_mark_incomplete "fp=$fp: create failed (line-anchored 422 and file-level fallback both rejected)"
            else
              prt_handle_freshness_rc "$?" "fp=$fp: create failed with 422, file-level fallback"
            fi
          else
            prt_mark_incomplete "fp=$fp: create failed (HTTP ${PRT_LAST_HTTP_STATUS:-unknown}$([ "$anchored" = true ] && echo ", not 422 — no fallback attempted"))"
          fi
        fi
        ;;
    esac
  done
fi

# ============================= LOOP 2: absence ==============================
# Every owned thread NOT matched by a finding's fp this run. Skipped
# entirely in advisory/off mode — no thread was ever created to reconcile.
if [ "$PRT_MODE" = enforce ]; then
  n_owned="$(jq 'length' <<< "$OWNED")"
  incomplete_now=false
  prt_is_incomplete && incomplete_now=true
  # go-kure/.github#98: a partial-drop chunk (finding.sh:97-121's rc=2) is
  # REVIEW_DEGRADED, not REVIEW_INCOMPLETE, so prt_is_incomplete above
  # doesn't see it — but a dropped row's existing thread still must not be
  # read as absent this run (same reasoning finding.sh's docstring gives for
  # the fatal case). Fold the degraded-for-partial-drop reason directly into
  # this check instead: prt_decide_absent's review_incomplete=true branch
  # (reconcile.sh:111-114) forces CLEAR_MARKER/NONE, never
  # SET_FIRST_ABSENT/REPLY_RESOLVE, which is exactly the fail-safe behavior
  # this needs without dual-marking (see the partial-drop call site above,
  # :313-330ish, for why dual-marking would defeat degraded's whole point).
  prt_degraded_reasons | grep -q 'partial-drop' && incomplete_now=true
  # go-kure/.github#107: same reasoning as the partial-drop fold-in just
  # above — a chunk whose review call never parsed reviewed nothing, so any
  # of its findings' existing threads must not be read as absent this run
  # even though the run itself no longer fails closed for it.
  prt_degraded_reasons | grep -q 'review-parse-failed' && incomplete_now=true
  for ((oi = 0; oi < n_owned; oi++)); do
    th="$(jq -c ".[$oi]" <<< "$OWNED")"
    fp="$(jq -r '.fp' <<< "$th")"
    # IN(), not [x] | inside(y) — see the within_cap comment above; same
    # substring-vs-exact-match trap for the same collision-ordinal fp shapes.
    already_matched="$(jq --arg fp "$fp" '. as $arr | $fp | IN($arr[])' <<< "$MATCHED_FPS")"
    [ "$already_matched" = true ] && continue

    collision="$(jq -r '.collision' <<< "$th")"
    has_human_reply="$(jq -r '.has_human_reply' <<< "$th")"
    thread_resolved="$(jq -r '.resolved' <<< "$th")"
    first_absent_sha="$(jq -r '.first_absent_sha' <<< "$th")"
    thread_id="$(jq -r '.thread_id' <<< "$th")"
    first_comment_db_id="$(jq -r '.first_comment_db_id' <<< "$th")"

    # Simplified from the design's full "unanswered MAINT_FAILURE reply"
    # detection (ordering-sensitive scan of every reply): a thread that
    # already carries a human reply is excluded above via has_human_reply,
    # which also covers the MAINT_FAILURE case in practice (a MAINT_FAILURE
    # reply itself is bot-authored with the -note marker, so it does not
    # set has_human_reply; a thread stuck on an unreplied MAINT_FAILURE with
    # no human reply since falls through to row 10's REPLY_RESOLVE, which
    # is the intended conservative behavior only if the maintenance failure
    # was transient — a real gap, tracked below as unanswered_maint_failure
    # always false, disclosed as a known residual gap in the PR's own review
    # ledger and iteration comments (dot-github#50 gmr finding R6), not in a
    # standalone doc this PR doesn't create.
    unanswered_maint_failure=false

    action="$(prt_decide_absent "$collision" "$has_human_reply" "$thread_resolved" \
      "$first_absent_sha" "$PRT_HEAD_SHA" "$incomplete_now" "$unanswered_maint_failure")"
    prt_log "fp=$fp absent -> $action"

    viewer_can_resolve="$(jq -r '.viewer_can_resolve' <<< "$th")"

    case "$action" in
      NONE) : ;;
      SET_FIRST_ABSENT)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_handle_freshness_rc "$?" "fp=$fp: setting first_absent_sha"; continue; }
        new_marker="$(prt_marker_build "$fp" "$collision" "$PRT_HEAD_SHA")"
        # The body comes from a fresh GET so prt_marker_replace preserves the
        # finding text exactly. The GET's own success/non-empty-body is checked
        # before ever
        # calling prt_marker_replace: an unchecked failure fed an empty
        # cur_body into prt_marker_replace's no-marker fallback, which
        # returns just the marker, and the PATCH that follows then
        # overwrote the whole finding comment down to that one line — the
        # exact blind-overwrite bug the marker module exists to prevent
        # (dot-github#50 gmr finding C2).
        cur_resp="$(prt_gh_rest GET "/repos/${PRT_REPO}/pulls/comments/${first_comment_db_id}")"
        cur_body="$(jq -r '.body // empty' <<< "${cur_resp:-}" 2>/dev/null || true)"
        if [ -z "$cur_body" ]; then
          prt_mark_incomplete "fp=$fp: GET before setting first_absent_sha failed or returned empty body, skipped"
          continue
        fi
        new_body="$(prt_marker_replace "$cur_body" "$new_marker")"
        prt_retry 3 prt_gh_rest_fresh PATCH "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" \
          "/repos/${PRT_REPO}/pulls/comments/${first_comment_db_id}" \
          "$(jq -n --arg b "$new_body" '{body:$b}')" >/dev/null
        retry_rc=$?
        [ "$retry_rc" -eq 0 ] || prt_handle_freshness_rc "$retry_rc" "fp=$fp: setting first_absent_sha (after up to 3 retries)"
        ;;
      CLEAR_MARKER)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_handle_freshness_rc "$?" "fp=$fp: marker clear"; continue; }
        new_marker="$(prt_marker_build "$fp" "$collision" "")"
        cur_resp="$(prt_gh_rest GET "/repos/${PRT_REPO}/pulls/comments/${first_comment_db_id}")"
        cur_body="$(jq -r '.body // empty' <<< "${cur_resp:-}" 2>/dev/null || true)"
        if [ -z "$cur_body" ]; then
          prt_mark_incomplete "fp=$fp: GET before clearing marker failed or returned empty body, skipped"
          continue
        fi
        new_body="$(prt_marker_replace "$cur_body" "$new_marker")"
        prt_retry 3 prt_gh_rest_fresh PATCH "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" \
          "/repos/${PRT_REPO}/pulls/comments/${first_comment_db_id}" \
          "$(jq -n --arg b "$new_body" '{body:$b}')" >/dev/null
        retry_rc=$?
        if [ "$retry_rc" -ne 0 ]; then
          prt_handle_freshness_rc "$retry_rc" "fp=$fp: clearing the absence marker (after up to 3 retries)"
          # No freshness gate on this reply itself: it documents a failure
          # that already happened and is structurally independent of the
          # marker (render.sh's prt_render_reply_maint_failure docstring) —
          # deliberately allowed to post even if the head moved meanwhile.
          reply="$(prt_render_reply_maint_failure "clearing the absence marker failed after 3 retries (or went stale mid-retry)")"
          prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" \
            "$(jq -n --arg b "$reply" --argjson r "$first_comment_db_id" '{body:$b, in_reply_to:$r}')" >/dev/null || true
        fi
        ;;
      REPLY_RESOLVE)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_handle_freshness_rc "$?" "fp=$fp: absence auto-close"; continue; }
        if [ "$viewer_can_resolve" != true ]; then
          prt_mark_incomplete "fp=$fp: viewerCanResolve=false, skipping absence auto-close"
          continue
        fi
        # Mutate first, reply only on success — same reasoning as loop 1's
        # REPLY_RESOLVE (dot-github#50 gmr finding R2): a resolve failure
        # must not leave an "resolving automatically" reply glued to a
        # thread that stays open, or every later run repeats the reply.
        mut="mutation(\$id:ID!){resolveReviewThread(input:{threadId:\$id}){thread{id}}}"
        if prt_gh_graphql "$mut" "$(jq -n --arg id "$thread_id" '{id:$id}')" >/dev/null; then
          # Same reasoning as loop 1's REPLY_RESOLVE: this check only gates
          # the reply, the mutation already committed, so a superseding run
          # will not redo it — stay fatal via prt_mark_incomplete regardless
          # of rc (codex round-2 confirm finding, go-kure/.github#99).
          if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
            reply="$(prt_render_reply_absent_resolved)"
            prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" \
              "$(jq -n --arg b "$reply" --argjson r "$first_comment_db_id" '{body:$b, in_reply_to:$r}')" >/dev/null || \
              prt_mark_incomplete "fp=$fp: absence resolveReviewThread succeeded but the explanatory reply failed"
          else
            prt_mark_incomplete "fp=$fp: absence resolveReviewThread succeeded but the post-mutation freshness re-check did not pass (head moved, or the check itself failed) — mutation already applied and will not be redone by a superseding run, reply permanently skipped"
          fi
        else
          prt_mark_incomplete "fp=$fp: absence resolveReviewThread failed, reply skipped to avoid a duplicate on retry"
        fi
        ;;
    esac
  done
fi

# --- Overflow / advisory output, summary ---
if [ "$PRT_MODE" = enforce ] && [ "$(jq 'length' <<< "$OVERFLOW")" -gt 0 ]; then
  if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
    overflow_body="$(prt_render_overflow_comment "$OVERFLOW")"
    prt_gh_rest POST "/repos/${PRT_REPO}/issues/${PRT_PR_NUMBER}/comments" \
      "$(jq -n --arg b "$overflow_body" '{body:$b}')" >/dev/null || \
      prt_mark_incomplete "failed to post overflow comment (HTTP ${PRT_LAST_HTTP_STATUS:-unknown})"
  else
    prt_handle_freshness_rc "$?" "overflow comment"
  fi
fi

# --- Clean-verdict comment (enforce mode only; GitLab mr-review.yml parity,
# "say so when a review finds nothing", 2026-08-22) ---
#
# A zero-finding enforce run creates no threads, so without this it posts
# NOTHING to the PR — indistinguishable on the PR page from: the job never
# running at all, a model response that parsed to zero findings without
# being a real review, or a stale queued run that self-suppressed. Gated on
# this run's own raw finding count (ALL_FINDINGS, pre-cap, pre-verdict-
# filter — matching GitLab's TOTAL_FINDINGS, which is likewise assigned
# before assessment ever runs) being zero AND the run not being
# REVIEW_INCOMPLETE — an incomplete run's silence must not read as "clean."
# advisory mode needs no equivalent: prt_render_advisory_comment already
# posts unconditionally, including an explicit "No issues found." line.
#
# Also excludes a review-parse-failed DEGRADED run (go-kure/.github#107,
# codex round-3 finding): that reason means one or more chunks never
# produced a usable review, same as the `incomplete_now` fold-in a few
# hundred lines below (:1003) — so the OTHER chunks coming back empty must
# not be allowed to post "Reviewed, no findings" over a PR whose diff was
# only partially looked at. Every other degraded reason (e.g. a superseded
# stale-head run, :182) is unrelated to whether findings are trustworthy and
# stays eligible for the clean comment.
if [ "$PRT_MODE" = enforce ]; then
  total_findings_this_run="$(jq 'length' <<< "$ALL_FINDINGS")"
  review_parse_failed_this_run=false
  prt_degraded_reasons | grep -q 'review-parse-failed' && review_parse_failed_this_run=true
  if [ "$total_findings_this_run" -eq 0 ] && ! prt_is_incomplete && ! "$review_parse_failed_this_run"; then
    if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
      if clean_id="$(prt_find_marked_comment "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_MARKER_CLEAN" "$PRT_BOT_LOGIN")"; then
        # Re-check immediately before the write, not just before the
        # (possibly multi-page) lookup above — matching prt_gh_rest_fresh's
        # own rationale (scripts/lib/prt/gh.sh:167-174): the run's real
        # wall-clock spans the pagination, so a check taken before it started
        # does not cover a write landing after the head has since moved.
        if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
          clean_body="$(prt_render_clean_comment "$PRT_HEAD_SHA" "$PRT_MODEL" "$chunk_idx")"
          prt_upsert_issue_comment "$PRT_REPO" "$PRT_PR_NUMBER" "$clean_body" "$clean_id" || \
            prt_mark_incomplete "failed to upsert clean-verdict comment (HTTP ${PRT_LAST_HTTP_STATUS:-unknown})"
        else
          prt_handle_freshness_rc "$?" "clean-verdict comment upsert"
        fi
      else
        prt_mark_incomplete "failed to list issue comments while looking for a prior clean-verdict comment"
      fi
    else
      prt_handle_freshness_rc "$?" "clean-verdict comment"
    fi
  elif [ "$total_findings_this_run" -gt 0 ]; then
    # Supersede, don't delete — matching prt_render_clean_comment_superseded's
    # own reasoning: the prior comment is the audit trail that SHA really was
    # clean, and that stays true of that SHA. Only rewrites an EXISTING clean
    # comment; a PR that never had one gets no new "superseded" noise.
    if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
      # A listing failure here is deliberately NOT prt_mark_incomplete —
      # matching GitLab's own asymmetry: this is best-effort tidy-up of a
      # PAST run's comment, not this run's primary output. Worst case a
      # stale clean note lingers next to this run's own (correctly posted)
      # open threads, which is a lesser, self-evident harm.
      if clean_id="$(prt_find_marked_comment "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_MARKER_CLEAN" "$PRT_BOT_LOGIN")"; then
        if [ -n "$clean_id" ]; then
          # Re-check immediately before the write — see the identical
          # rationale on the zero-findings branch above.
          if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
            superseded_body="$(prt_render_clean_comment_superseded "$PRT_HEAD_SHA" "$total_findings_this_run")"
            # go-kure/.github#98: degraded, not fatal — matching this
            # branch's own established asymmetry just above (a listing
            # failure here is deliberately NOT prt_mark_incomplete either):
            # this is best-effort tidy-up of a PAST run's comment, not this
            # run's primary output.
            prt_upsert_issue_comment "$PRT_REPO" "$PRT_PR_NUMBER" "$superseded_body" "$clean_id" || \
              prt_mark_degraded "failed to supersede the clean-verdict comment (HTTP ${PRT_LAST_HTTP_STATUS:-unknown}); this run's own findings/threads are unaffected, but the prior comment may still read as a clean verdict for an older SHA"
          else
            prt_handle_freshness_rc "$?" "clean-verdict supersede upsert"
          fi
        fi
      else
        echo "WARNING: could not list issue comments — any prior clean-verdict comment is left as it stands." >&2
      fi
    else
      prt_handle_freshness_rc "$?" "clean-verdict supersede check"
    fi
  fi
fi

{
  prt_render_summary "$PRT_MODE" "$PRT_HEAD_SHA" "$chunk_idx" "$ALL_FINDINGS" "$SUPPRESSED_COUNT" "$(prt_incomplete_reasons)" "$(prt_degraded_reasons)"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

incomplete_count=0
prt_is_incomplete && incomplete_count="$(prt_incomplete_reasons | grep -c . || true)"
degraded_count=0
prt_is_degraded && degraded_count="$(prt_degraded_reasons | grep -c . || true)"
prt_log "done: findings=$(jq 'length' <<< "$ALL_FINDINGS") gating=$(jq '[.[] | select(.within_cap == true)] | length' <<< "$ALL_FINDINGS") suppressed=$SUPPRESSED_COUNT incomplete=$incomplete_count degraded=$degraded_count"

# A non-empty REVIEW_INCOMPLETE state means some part of the review could not
# be completed (a skipped/failed read or write, a malformed model response,
# etc. — every prt_mark_incomplete call site above). Exiting 0 anyway used to
# make the two indistinguishable from a genuinely clean run to anything that
# only reads the job's own exit code (e.g. a future required status check) —
# only the job summary's REVIEW_INCOMPLETE section told the difference, and
# nothing consumed that but a human reading the summary by hand. The
# PRT_MODE=off short-circuit at :123-130 stays ahead of this check (an unconditional
# exit 0, run before prt_mark_incomplete can ever be called) — the incident
# escape hatch must keep working even if something else here is broken.
if prt_is_incomplete; then
  echo "ERROR: review incomplete — failing closed. Reasons:" >&2
  prt_incomplete_reasons | sed 's/^/  - /' >&2
  # Annotations go on stdout and GitHub caps them per step; the stderr list
  # above is always complete, this is the surfaced excerpt.
  prt_incomplete_reasons | head -10 | while IFS= read -r r; do
    printf '::error title=PR review threads incomplete::%s\n' "$(prt_annotation_escape "$r")"
  done
  # A run can be BOTH incomplete and degraded (e.g. an assessment
  # degradation earlier, then an unrelated inventory failure later) — this
  # exit must not drop the degraded recap just because it's also fatal
  # (go-kure/.github#101 F8).
  prt_report_degraded_annotations
  exit 1
fi

# Stale-only run (go-kure/.github#99): every REVIEW_DEGRADED reason this run
# recorded came from prt_handle_freshness_rc's genuinely-stale-head routing —
# nothing else went wrong. This is the normal shape of "pushed twice inside
# one run", not a fault, so it gets its own quiet log line instead of the
# generic REVIEW_DEGRADED warning recap below (matching
# meta/ci-templates/mr-review.yml's existing GitLab behavior). Safe because
# `.github/workflows/pr-review.yml`'s `cancel-in-progress: false` guarantees
# the superseding run — queued for the new head SHA — is going to run.
if prt_all_degraded_are_stale; then
  prt_log "Stale run: head moved; a newer run is already queued"
  exit 0
fi

# REVIEW_DEGRADED (go-kure/.github#98): unlike REVIEW_INCOMPLETE above, this
# does NOT fail the job — the run still produced a usable result, just not a
# fully clean one. Rendered as a warning (::warning, not ::error) so it's
# visible on the PR without gating merge on it; fatal-vs-degraded is exactly
# the distinction this whole mechanism exists to draw.
prt_report_degraded_annotations

exit 0
