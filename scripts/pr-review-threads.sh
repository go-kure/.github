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

set -uo pipefail  # not -e: every stage must run to completion and report,
                   # a single failed write must not abort the whole run —
                   # continue-on-error at the job level already accepts a
                   # hard failure, but a soft per-finding failure here must
                   # not cascade into skipping every other finding.

PRT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib/prt" && pwd)"
# shellcheck source=scripts/lib/prt/state.sh
source "$PRT_LIB_DIR/state.sh"
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

for req in PRT_GH_TOKEN PRT_REPO PRT_PR_NUMBER PRT_HEAD_SHA PRT_BOT_LOGIN PRT_PROXY_URL; do
  [ -n "${!req:-}" ] || { echo "ERROR: $req is required" >&2; exit 1; }
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
{
  http_code=$("$PRT_CURL" -sS -o "$DIFF_FILE" -w '%{http_code}' \
    -H "Authorization: Bearer ${PRT_GH_TOKEN}" \
    -H "Accept: application/vnd.github.diff" \
    "${PRT_API_BASE:-https://api.github.com}/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}")
} || http_code=000
if [ "$http_code" = 406 ]; then
  echo "PR diff too large for GitHub API (HTTP 406), skipping." >&2
  { echo "## PR Review Threads: skipped"; echo; echo "Diff too large for the GitHub API (406)."; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi
if [[ ! "$http_code" =~ ^2[0-9]{2}$ ]]; then
  echo "ERROR: HTTP $http_code fetching PR diff" >&2
  exit 1
fi
if [ ! -s "$DIFF_FILE" ]; then
  echo "No diff, nothing to review." >&2
  { echo "## PR Review Threads: no diff"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi

meta_json="$(prt_gh_rest GET "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}")" || exit 1
PR_TITLE="$(jq -r '.title // "Untitled"' <<< "$meta_json")"
PR_DESC="$(jq -r '.body // ""' <<< "$meta_json")"

PROJECT_AGENTS=""
[ -n "$PRT_AGENTS_FILE" ] && [ -f "$PRT_AGENTS_FILE" ] && PROJECT_AGENTS="$(cat "$PRT_AGENTS_FILE")"
PROJECT_CLAUDE_MD=""
[ -f ".claude/CLAUDE.md" ] && PROJECT_CLAUDE_MD="$(cat ".claude/CLAUDE.md")"

# --- Commentable-line index (full diff, not per chunk) ---
LINE_INDEX="$(prt_build_line_index "$DIFF_FILE")"

# --- Chunk + review + assess ---
CHUNK_DIR="$WORKDIR/chunks"
chunk_count="$(prt_split_diff "$DIFF_FILE" "$PRT_MAX_DIFF_CHARS" "$CHUNK_DIR")"

ALL_FINDINGS='[]'
chunk_idx=0
for chunk_file in "$CHUNK_DIR"/chunk-*.diff; do
  [ -f "$chunk_file" ] || continue
  chunk_diff="$(cat "$chunk_file")"

  raw="$(prt_model_review "$PRT_PROXY_URL" "$PRT_MODEL" "$PRT_MAX_TOKENS" "$chunk_diff" \
    "$PR_TITLE" "$PR_DESC" "$PRT_PROJECT_CONTEXT" "$PROJECT_AGENTS" "$PROJECT_CLAUDE_MD")"
  if [ -z "$raw" ]; then
    prt_mark_incomplete "chunk $chunk_idx: empty/failed review response"
    chunk_idx=$((chunk_idx + 1))
    continue
  fi
  raw_json="$(jq -c '.' <<< "$raw" 2>/dev/null || echo '')"
  if [ -z "$raw_json" ]; then
    prt_mark_incomplete "chunk $chunk_idx: review response was not valid JSON"
    chunk_idx=$((chunk_idx + 1))
    continue
  fi
  normalized="$(prt_normalize_findings "$raw_json")" || \
    prt_mark_incomplete "chunk $chunk_idx: .findings missing/null/non-array in review response"

  tagged="$(jq -c --argjson idx "$chunk_idx" 'map(. + {_chunk: $idx})' <<< "$normalized")"
  ALL_FINDINGS="$(jq -c -n --argjson a "$ALL_FINDINGS" --argjson b "$tagged" '$a + $b')"
  chunk_idx=$((chunk_idx + 1))
done

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

  assess_raw="$(prt_model_assess "$PRT_PROXY_URL" "$PRT_ASSESS_MODEL" "$PRT_ASSESS_MAX_TOKENS" \
    "$chunk_diff" "$chunk_findings" "$PR_TITLE" "$PRT_PROJECT_CONTEXT" "$PROJECT_AGENTS" "$PROJECT_CLAUDE_MD")"
  assess_json="$(jq -c '.' <<< "$assess_raw" 2>/dev/null || echo '')"
  if [ -z "$assess_json" ]; then
    prt_mark_incomplete "chunk $i: assessment response was empty/not valid JSON; findings stay unverdicted"
    ASSESSED="$(jq -c -n --argjson a "$ASSESSED" --argjson b "$chunk_findings" '$a + ($b | map(. + {verdict: null, reasoning: null}))')"
    continue
  fi
  joined="$(prt_join_assessment "$chunk_findings" "$assess_json")" || \
    prt_mark_incomplete "chunk $i: .assessments missing/null/non-array"
  ASSESSED="$(jq -c -n --argjson a "$ASSESSED" --argjson b "$joined" '$a + $b')"
done
ALL_FINDINGS="$ASSESSED"

# --- PR-wide severity cap: rank VALID/PARTIALLY_VALID across ALL chunks,
# top N gate, the rest overflow. FALSE_POSITIVE never competes for a slot. ---
SEV_RANK='{"Critical":0,"High":1,"Medium":2}'
GATING_ELIGIBLE="$(jq -c --argjson rank "$SEV_RANK" '
  [.[] | select(.verdict == "VALID" or .verdict == "PARTIALLY_VALID" or .verdict == null)]
  | sort_by($rank[.severity] // 99)
' <<< "$ALL_FINDINGS")"
CAPPED_FPS="$(jq -c --argjson n "$PRT_MAX_FINDINGS_TOTAL" '[limit($n; .[])] | map(.fp)' <<< "$GATING_ELIGIBLE")"
ALL_FINDINGS="$(jq -c --argjson capped "$CAPPED_FPS" '
  map(. + {within_cap: (([.fp] | inside($capped))) })
' <<< "$ALL_FINDINGS")"

# --- List existing owned threads (GraphQL, paginated) ---
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
          comments(first:50) {
            nodes { id databaseId body author { login } }
          }
        }
      }
    }
  }
}'
OWNER="${PRT_REPO%%/*}"
REPO_NAME="${PRT_REPO##*/}"

THREADS='[]'
cursor=null
list_failed=0
while :; do
  vars="$(jq -n --arg owner "$OWNER" --arg repo "$REPO_NAME" --argjson pr "$PRT_PR_NUMBER" --argjson cursor "$cursor" \
    '{owner:$owner, repo:$repo, pr:$pr, cursor:$cursor}')"
  data="$(prt_gh_graphql "$list_query" "$vars")" || { list_failed=1; break; }
  page="$(jq -c '.repository.pullRequest.reviewThreads' <<< "$data")"
  THREADS="$(jq -c -n --argjson a "$THREADS" --argjson b "$(jq -c '.nodes' <<< "$page")" '$a + $b')"
  has_next="$(jq -r '.pageInfo.hasNextPage' <<< "$page")"
  [ "$has_next" = true ] || break
  cursor="$(jq -c '.pageInfo.endCursor' <<< "$page")"
done

if [ "$list_failed" = 1 ]; then
  echo "ERROR: failed to list review threads; aborting before any write." >&2
  prt_mark_incomplete "GraphQL reviewThreads listing failed"
  {
    prt_render_summary "$PRT_MODE" "$PRT_HEAD_SHA" "$chunk_idx" "$ALL_FINDINGS" "$(prt_incomplete_reasons)"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 1
fi

# Ownership = marker on first comment AND that comment's author is the bot.
# Build a lookup: fp -> {thread_id, resolved, resolved_by_bot, first_comment_id, has_human_reply}
OWNED='[]'
n_threads="$(jq 'length' <<< "$THREADS")"
for ((ti = 0; ti < n_threads; ti++)); do
  th="$(jq -c ".[$ti]" <<< "$THREADS")"
  first_comment="$(jq -c '.comments.nodes[0] // empty' <<< "$th")"
  [ -n "$first_comment" ] || continue
  first_author="$(jq -r '.author.login // empty' <<< "$first_comment")"
  first_body="$(jq -r '.body' <<< "$first_comment")"
  [ "$first_author" = "$PRT_BOT_LOGIN" ] || continue
  parsed="$(prt_marker_parse "$first_body")" || continue
  fp="$(cut -f1 <<< "$parsed")"
  collision="$(cut -f2 <<< "$parsed")"
  first_absent_sha="$(cut -f3 <<< "$parsed")"

  is_resolved="$(jq -r '.isResolved' <<< "$th")"
  resolved_by="$(jq -r '.resolvedBy.login // empty' <<< "$th")"
  # Fail-closed on the resolvedBy:User vs Actions-token-is-a-Bot ambiguity
  # (V6, unverified until a live spike): a null resolvedBy on a resolved
  # thread is treated as human-resolved, never reopened. Costs a missed
  # reopen, never a wrong one.
  resolved_by_bot=false
  [ "$is_resolved" = true ] && [ "$resolved_by" = "$PRT_BOT_LOGIN" ] && resolved_by_bot=true

  has_human_reply=false
  n_comments="$(jq -c '.comments.nodes | length' <<< "$th")"
  for ((ci = 1; ci < n_comments; ci++)); do
    cbody="$(jq -r ".comments.nodes[$ci].body" <<< "$th")"
    if ! prt_marker_has_note "$cbody"; then has_human_reply=true; fi
  done

  first_comment_id="$(jq -r '.id' <<< "$first_comment")"
  first_comment_db_id="$(jq -r '.databaseId' <<< "$first_comment")"
  thread_id="$(jq -r '.id' <<< "$th")"

  OWNED="$(jq -c -n --argjson a "$OWNED" \
    --arg fp "$fp" --arg collision "$collision" --arg fas "$first_absent_sha" \
    --arg resolved "$is_resolved" --arg rbb "$resolved_by_bot" --arg hhr "$has_human_reply" \
    --arg tid "$thread_id" --arg fcid "$first_comment_id" --arg fcdbid "$first_comment_db_id" \
    '$a + [{fp:$fp, collision:($collision=="true"), first_absent_sha:$fas,
            resolved:($resolved=="true"), resolved_by_bot:($rbb=="true"),
            has_human_reply:($hhr=="true"), thread_id:$tid,
            first_comment_id:$fcid, first_comment_db_id:$fcdbid}]')"
done

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
  body="$(prt_render_advisory_comment "$advisory_findings")"
  payload="$(jq -n --arg b "$body" '{body:$b}')"
  prt_gh_rest POST "/repos/${PRT_REPO}/issues/${PRT_PR_NUMBER}/comments" "$payload" >/dev/null || \
    echo "WARNING: failed to post advisory comment" >&2
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
    fi

    action="$(prt_decide_finding "$collision" "$verdict" "$thread_exists" "$thread_resolved" "$resolved_by_bot" "$within_cap")"

    case "$action" in
      NONE) : ;;
      SUPPRESS) SUPPRESSED_COUNT=$((SUPPRESSED_COUNT + 1)) ;;
      OVERFLOW) OVERFLOW="$(jq -c --argjson f "$f" '. + [$f]' <<< "$OVERFLOW")" ;;
      REPLY_RESOLVE)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_mark_incomplete "fp=$fp: stale head SHA, skipped reply+resolve"; continue; }
        reasoning="$(jq -r '.reasoning // "no reasoning provided"' <<< "$f")"
        reply="$(prt_render_reply_false_positive "$reasoning")"
        db_id="$(jq -r '.first_comment_db_id' <<< "$owned_match")"
        thread_id="$(jq -r '.thread_id' <<< "$owned_match")"
        reply_payload="$(jq -n --arg b "$reply" --argjson r "$db_id" '{body:$b, in_reply_to:$r}')"
        if prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" "$reply_payload" >/dev/null; then
          mut="mutation(\$id:ID!){resolveReviewThread(input:{threadId:\$id}){thread{id}}}"
          prt_gh_graphql "$mut" "$(jq -n --arg id "$thread_id" '{id:$id}')" >/dev/null || prt_mark_incomplete "fp=$fp: resolveReviewThread failed after reply"
        else
          prt_mark_incomplete "fp=$fp: reply (FALSE POSITIVE) failed, resolve skipped"
        fi
        ;;
      REPLY_UNRESOLVE)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_mark_incomplete "fp=$fp: stale head SHA, skipped reply+unresolve"; continue; }
        reply="$(prt_render_reply_recurrence)"
        db_id="$(jq -r '.first_comment_db_id' <<< "$owned_match")"
        thread_id="$(jq -r '.thread_id' <<< "$owned_match")"
        reply_payload="$(jq -n --arg b "$reply" --argjson r "$db_id" '{body:$b, in_reply_to:$r}')"
        if prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" "$reply_payload" >/dev/null; then
          mut="mutation(\$id:ID!){unresolveReviewThread(input:{threadId:\$id}){thread{id}}}"
          prt_gh_graphql "$mut" "$(jq -n --arg id "$thread_id" '{id:$id}')" >/dev/null || prt_mark_incomplete "fp=$fp: unresolveReviewThread failed after reply"
        else
          prt_mark_incomplete "fp=$fp: recurrence reply failed, unresolve skipped"
        fi
        ;;
      CREATE)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_mark_incomplete "fp=$fp: stale head SHA, skipped create"; continue; }
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
          if [ "$anchored" = true ]; then
            # 422 ladder: line rejected (out-of-diff line, deleted file
            # anchor, etc.) — fall back to a file-level thread once.
            fallback_payload="$(jq -n --arg b "$body" --arg sha "$PRT_HEAD_SHA" --arg path "$file" \
              '{body:$b, commit_id:$sha, path:$path, subject_type:"file"}')"
            prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" "$fallback_payload" >/dev/null || \
              prt_mark_incomplete "fp=$fp: create failed (line-anchored and file-level fallback both rejected)"
          else
            prt_mark_incomplete "fp=$fp: create (file-level) failed"
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
  for ((oi = 0; oi < n_owned; oi++)); do
    th="$(jq -c ".[$oi]" <<< "$OWNED")"
    fp="$(jq -r '.fp' <<< "$th")"
    already_matched="$(jq --arg fp "$fp" '([$fp] | inside(.))' <<< "$MATCHED_FPS")"
    [ "$already_matched" = true ] && continue

    collision="$(jq -r '.collision' <<< "$th")"
    has_human_reply="$(jq -r '.has_human_reply' <<< "$th")"
    thread_resolved="$(jq -r '.resolved' <<< "$th")"
    first_absent_sha="$(jq -r '.first_absent_sha' <<< "$th")"
    thread_id="$(jq -r '.thread_id' <<< "$th")"
    first_comment_id="$(jq -r '.first_comment_id' <<< "$th")"
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
    # always false. See docs/pr-review-threads.md "Known limitations".
    unanswered_maint_failure=false

    action="$(prt_decide_absent "$collision" "$has_human_reply" "$thread_resolved" \
      "$first_absent_sha" "$PRT_HEAD_SHA" "$incomplete_now" "$unanswered_maint_failure")"

    case "$action" in
      NONE) : ;;
      SET_FIRST_ABSENT)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || continue
        new_marker="$(prt_marker_build "$fp" "$collision" "$PRT_HEAD_SHA")"
        # first_comment_id currently unused here (body comes from a fresh
        # GET so prt_marker_replace preserves the finding text exactly).
        cur_body="$(prt_gh_rest GET "/repos/${PRT_REPO}/pulls/comments/${first_comment_db_id}" | jq -r '.body')"
        new_body="$(prt_marker_replace "$cur_body" "$new_marker")"
        if ! prt_retry 3 prt_gh_rest PATCH "/repos/${PRT_REPO}/pulls/comments/${first_comment_db_id}" \
             "$(jq -n --arg b "$new_body" '{body:$b}')" >/dev/null; then
          prt_mark_incomplete "fp=$fp: setting first_absent_sha failed after 3 retries"
        fi
        ;;
      CLEAR_MARKER)
        new_marker="$(prt_marker_build "$fp" "$collision" "")"
        cur_body="$(prt_gh_rest GET "/repos/${PRT_REPO}/pulls/comments/${first_comment_db_id}" | jq -r '.body')"
        new_body="$(prt_marker_replace "$cur_body" "$new_marker")"
        if ! prt_retry 3 prt_gh_rest PATCH "/repos/${PRT_REPO}/pulls/comments/${first_comment_db_id}" \
             "$(jq -n --arg b "$new_body" '{body:$b}')" >/dev/null; then
          reply="$(prt_render_reply_maint_failure "clearing the absence marker failed after 3 retries")"
          prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" \
            "$(jq -n --arg b "$reply" --argjson r "$first_comment_db_id" '{body:$b, in_reply_to:$r}')" >/dev/null || true
        fi
        ;;
      REPLY_RESOLVE)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || continue
        reply="$(prt_render_reply_absent_resolved)"
        if prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" \
             "$(jq -n --arg b "$reply" --argjson r "$first_comment_db_id" '{body:$b, in_reply_to:$r}')" >/dev/null; then
          mut="mutation(\$id:ID!){resolveReviewThread(input:{threadId:\$id}){thread{id}}}"
          prt_gh_graphql "$mut" "$(jq -n --arg id "$thread_id" '{id:$id}')" >/dev/null || \
            prt_mark_incomplete "fp=$fp: absence resolveReviewThread failed after reply"
        else
          prt_mark_incomplete "fp=$fp: absence auto-close reply failed, resolve skipped"
        fi
        ;;
    esac
  done
fi

# --- Overflow / advisory output, summary ---
if [ "$PRT_MODE" = enforce ] && [ "$(jq 'length' <<< "$OVERFLOW")" -gt 0 ]; then
  overflow_body="$(prt_render_overflow_comment "$OVERFLOW")"
  prt_gh_rest POST "/repos/${PRT_REPO}/issues/${PRT_PR_NUMBER}/comments" \
    "$(jq -n --arg b "$overflow_body" '{body:$b}')" >/dev/null || \
    echo "WARNING: failed to post overflow comment" >&2
fi

{
  prt_render_summary "$PRT_MODE" "$PRT_HEAD_SHA" "$chunk_idx" "$ALL_FINDINGS" "$(prt_incomplete_reasons)"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

exit 0
