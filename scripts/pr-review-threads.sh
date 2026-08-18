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
    prt_mark_incomplete "chunk $chunk_idx: .findings missing/null/non-array, or one or more malformed finding rows dropped"

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

# Comment pagination: a thread with more than 50 comments hides any human
# reply past the 50th from the (first:50) page above — the absence loop
# would then treat an actively-discussed thread as unmatched and eligible
# for auto-resolve (dot-github#50 gmr finding C4). Fetch the rest, per
# thread, only for threads that actually need it.
if [ "$list_failed" != 1 ]; then
  n_threads_pg="$(jq 'length' <<< "$THREADS")"
  for ((tpi = 0; tpi < n_threads_pg; tpi++)); do
    th_pg="$(jq -c ".[$tpi]" <<< "$THREADS")"
    has_more="$(jq -r '.comments.pageInfo.hasNextPage // false' <<< "$th_pg")"
    [ "$has_more" = true ] || continue
    tcursor="$(jq -c '.comments.pageInfo.endCursor' <<< "$th_pg")"
    tid_pg="$(jq -r '.id' <<< "$th_pg")"
    extra_nodes='[]'
    while :; do
      cvars="$(jq -n --arg id "$tid_pg" --argjson cursor "$tcursor" '{id:$id, cursor:$cursor}')"
      cdata="$(prt_gh_graphql "$comment_page_query" "$cvars")" || { list_failed=1; break; }
      cpage="$(jq -c '.node.comments' <<< "$cdata")"
      extra_nodes="$(jq -c -n --argjson a "$extra_nodes" --argjson b "$(jq -c '.nodes' <<< "$cpage")" '$a + $b')"
      chas_next="$(jq -r '.pageInfo.hasNextPage' <<< "$cpage")"
      [ "$chas_next" = true ] || break
      tcursor="$(jq -c '.pageInfo.endCursor' <<< "$cpage")"
    done
    [ "$list_failed" = 1 ] && break
    THREADS="$(jq -c --argjson i "$tpi" --argjson extra "$extra_nodes" '.[$i].comments.nodes += $extra' <<< "$THREADS")"
  done
fi

if [ "$list_failed" = 1 ]; then
  echo "ERROR: failed to list review threads; aborting before any write." >&2
  prt_mark_incomplete "GraphQL reviewThreads listing failed"
  {
    prt_render_summary "$PRT_MODE" "$PRT_HEAD_SHA" "$chunk_idx" "$ALL_FINDINGS" "$(prt_incomplete_reasons)"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
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
n_threads="$(jq 'length' <<< "$THREADS")"
for ((ti = 0; ti < n_threads; ti++)); do
  th="$(jq -c ".[$ti]" <<< "$THREADS")"
  first_comment="$(jq -c '.comments.nodes[0] // empty' <<< "$th")"
  [ -n "$first_comment" ] || continue
  first_author="$(jq -r '.author.login // empty' <<< "$first_comment")"
  first_body="$(jq -r '.body' <<< "$first_comment")"
  [ "$first_author" = "$PRT_BOT_LOGIN_GQL" ] || continue
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
  [ "$is_resolved" = true ] && [ "$resolved_by" = "$PRT_BOT_LOGIN_GQL" ] && resolved_by_bot=true

  has_human_reply=false
  n_comments="$(jq -c '.comments.nodes | length' <<< "$th")"
  for ((ci = 1; ci < n_comments; ci++)); do
    cbody="$(jq -r ".comments.nodes[$ci].body" <<< "$th")"
    if ! prt_marker_has_note "$cbody"; then has_human_reply=true; fi
  done

  first_comment_id="$(jq -r '.id' <<< "$first_comment")"
  first_comment_db_id="$(jq -r '.databaseId' <<< "$first_comment")"
  thread_id="$(jq -r '.id' <<< "$th")"
  viewer_can_resolve="$(jq -r '.viewerCanResolve' <<< "$th")"
  viewer_can_unresolve="$(jq -r '.viewerCanUnresolve' <<< "$th")"

  OWNED="$(jq -c -n --argjson a "$OWNED" \
    --arg fp "$fp" --arg collision "$collision" --arg fas "$first_absent_sha" \
    --arg resolved "$is_resolved" --arg rbb "$resolved_by_bot" --arg hhr "$has_human_reply" \
    --arg tid "$thread_id" --arg fcid "$first_comment_id" --arg fcdbid "$first_comment_db_id" \
    --arg vcr "$viewer_can_resolve" --arg vcu "$viewer_can_unresolve" \
    '$a + [{fp:$fp, collision:($collision=="true"), first_absent_sha:$fas,
            resolved:($resolved=="true"), resolved_by_bot:($rbb=="true"),
            has_human_reply:($hhr=="true"), thread_id:$tid,
            first_comment_id:$fcid, first_comment_db_id:$fcdbid,
            viewer_can_resolve:($vcr=="true"), viewer_can_unresolve:($vcu=="true")}]')"
done
fi # PRT_MODE = enforce

# --- PR-wide severity cap: rank VALID/PARTIALLY_VALID across ALL chunks,
# top N gate, the rest overflow. FALSE_POSITIVE never competes for a slot.
# Computed AFTER OWNED, not before, and excludes only the OWNED-matched
# findings that are GUARANTEED non-gating this run: collision-quarantined
# (row 1, always NONE) and human-resolved (row 6, NONE, a deliberate
# resolution is never reopened). This is NOT "exclude every OWNED match" —
# a broader exclusion was tried and reverted (dot-github#50 gmr finding
# iter5-code-reviewer F1): row 5 (open, still gating, NONE) and row 7
# (bot-resolved and recurred, REPLY_UNRESOLVE) are ALSO reachable once
# thread_exists=true, but BOTH leave the thread gating after this run. The
# cap's whole job is to bound how many threads are gating at once — a
# finding on one of those two rows must keep occupying a rank slot, or the
# cap stops bounding anything: exclude them and every already-open thread
# stops competing for a slot, so a full 5 NEW threads (not 5 total) get
# created on the very next run, growing without limit across reruns even
# with no push in between (traced by hand: 12 valid findings, cap 5 — run 1
# creates 5, run 2 was correctly still 5 gating before this fix, un-reverted
# would have produced 10, run 3 would have produced all 12). reconcile.sh's
# WITHIN_CAP argument is read only in the thread_exists=false branch (row
# 4), which is exactly why the ORIGINAL narrower exclusion (collision-only,
# iteration 4) undercounted: it missed the human-resolved case, which is
# the OTHER row where WITHIN_CAP truly doesn't matter and the slot is
# genuinely free (dot-github#50 gmr finding iter5-codex #1). Row 5 and row 7
# are not that case — they are rows where the thread stays or becomes
# gating regardless of WITHIN_CAP, so they must still consume the budget. ---
SEV_RANK='{"Critical":0,"High":1,"Medium":2}'
NON_GATING_OWNED_FPS="$(jq -c '
  [.[] | select(.collision == true or (.resolved == true and .resolved_by_bot != true)) | .fp]
' <<< "$OWNED")"
GATING_ELIGIBLE="$(jq -c --argjson rank "$SEV_RANK" --argjson non_gating "$NON_GATING_OWNED_FPS" '
  [.[] | select((.verdict == "VALID" or .verdict == "PARTIALLY_VALID" or .verdict == null)
                and (.collision != true) and ((.fp | IN($non_gating[])) | not))]
  | sort_by($rank[.severity] // 99)
' <<< "$ALL_FINDINGS")"
CAPPED_FPS="$(jq -c --argjson n "$PRT_MAX_FINDINGS_TOTAL" '[limit($n; .[])] | map(.fp)' <<< "$GATING_ELIGIBLE")"
ALL_FINDINGS="$(jq -c --argjson capped "$CAPPED_FPS" '
  # IN(), not [x] | inside(y) — jq inside() on strings is substring
  # containment, not array-element equality: `["fp"] | inside(["fp-2"])` is
  # true. A base fingerprint would then read as "within cap" whenever an
  # unrelated ordinal-suffixed sibling fp happened to be capped.
  map(. + {within_cap: (.fp | IN($capped[]))})
' <<< "$ALL_FINDINGS")"

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
  body="$(prt_render_advisory_comment "$advisory_findings" "$advisory_incomplete_reasons")"
  payload="$(jq -n --arg b "$body" '{body:$b}')"
  if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
    prt_gh_rest POST "/repos/${PRT_REPO}/issues/${PRT_PR_NUMBER}/comments" "$payload" >/dev/null || \
      prt_mark_incomplete "failed to post advisory comment (HTTP ${PRT_LAST_HTTP_STATUS:-unknown})"
  else
    prt_mark_incomplete "stale head SHA, skipped advisory comment"
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
                "$(jq -n --arg b "$new_body" '{body:$b}')" >/dev/null || \
                prt_mark_incomplete "fp=$fp: persisting collision=true onto existing thread failed after 3 retries (or went stale mid-retry)"
            else
              prt_mark_incomplete "fp=$fp: GET before collision-marker persist failed or returned empty body, skipped"
            fi
          else
            prt_mark_incomplete "fp=$fp: stale head SHA, skipped collision-marker persist"
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

    case "$action" in
      NONE) : ;;
      SUPPRESS) SUPPRESSED_COUNT=$((SUPPRESSED_COUNT + 1)) ;;
      OVERFLOW) OVERFLOW="$(jq -c --argjson f "$f" '. + [$f]' <<< "$OVERFLOW")" ;;
      REPLY_RESOLVE)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_mark_incomplete "fp=$fp: stale head SHA, skipped reply+resolve"; continue; }
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
          if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
            reasoning="$(jq -r '.reasoning // "no reasoning provided"' <<< "$f")"
            reply="$(prt_render_reply_false_positive "$reasoning")"
            reply_payload="$(jq -n --arg b "$reply" --argjson r "$db_id" '{body:$b, in_reply_to:$r}')"
            prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" "$reply_payload" >/dev/null || \
              prt_mark_incomplete "fp=$fp: resolveReviewThread succeeded but the explanatory reply failed"
          else
            prt_mark_incomplete "fp=$fp: resolveReviewThread succeeded but head SHA went stale before the reply"
          fi
        else
          prt_mark_incomplete "fp=$fp: resolveReviewThread (FALSE POSITIVE) failed, reply skipped to avoid a duplicate on retry"
        fi
        ;;
      REPLY_UNRESOLVE)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_mark_incomplete "fp=$fp: stale head SHA, skipped reply+unresolve"; continue; }
        can_unresolve="$(jq -r '.viewer_can_unresolve' <<< "$owned_match")"
        if [ "$can_unresolve" != true ]; then
          prt_mark_incomplete "fp=$fp: viewerCanUnresolve=false, skipping unresolve"
          continue
        fi
        thread_id="$(jq -r '.thread_id' <<< "$owned_match")"
        db_id="$(jq -r '.first_comment_db_id' <<< "$owned_match")"
        mut="mutation(\$id:ID!){unresolveReviewThread(input:{threadId:\$id}){thread{id}}}"
        if prt_gh_graphql "$mut" "$(jq -n --arg id "$thread_id" '{id:$id}')" >/dev/null; then
          if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
            reply="$(prt_render_reply_recurrence)"
            reply_payload="$(jq -n --arg b "$reply" --argjson r "$db_id" '{body:$b, in_reply_to:$r}')"
            prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" "$reply_payload" >/dev/null || \
              prt_mark_incomplete "fp=$fp: unresolveReviewThread succeeded but the explanatory reply failed"
          else
            prt_mark_incomplete "fp=$fp: unresolveReviewThread succeeded but head SHA went stale before the reply"
          fi
        else
          prt_mark_incomplete "fp=$fp: unresolveReviewThread failed, reply skipped to avoid a duplicate on retry"
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
              prt_mark_incomplete "fp=$fp: create failed with 422, stale head SHA before file-level fallback"
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
    # always false, disclosed as a known residual gap in the PR's own review
    # ledger and iteration comments (dot-github#50 gmr finding R6), not in a
    # standalone doc this PR doesn't create.
    unanswered_maint_failure=false

    action="$(prt_decide_absent "$collision" "$has_human_reply" "$thread_resolved" \
      "$first_absent_sha" "$PRT_HEAD_SHA" "$incomplete_now" "$unanswered_maint_failure")"

    viewer_can_resolve="$(jq -r '.viewer_can_resolve' <<< "$th")"

    case "$action" in
      NONE) : ;;
      SET_FIRST_ABSENT)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_mark_incomplete "fp=$fp: stale head SHA, skipped setting first_absent_sha"; continue; }
        new_marker="$(prt_marker_build "$fp" "$collision" "$PRT_HEAD_SHA")"
        # first_comment_id currently unused here (body comes from a fresh
        # GET so prt_marker_replace preserves the finding text exactly).
        # The GET's own success/non-empty-body is checked before ever
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
        if ! prt_retry 3 prt_gh_rest_fresh PATCH "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" \
             "/repos/${PRT_REPO}/pulls/comments/${first_comment_db_id}" \
             "$(jq -n --arg b "$new_body" '{body:$b}')" >/dev/null; then
          prt_mark_incomplete "fp=$fp: setting first_absent_sha failed after 3 retries (or went stale mid-retry)"
        fi
        ;;
      CLEAR_MARKER)
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_mark_incomplete "fp=$fp: stale head SHA, skipped marker clear"; continue; }
        new_marker="$(prt_marker_build "$fp" "$collision" "")"
        cur_resp="$(prt_gh_rest GET "/repos/${PRT_REPO}/pulls/comments/${first_comment_db_id}")"
        cur_body="$(jq -r '.body // empty' <<< "${cur_resp:-}" 2>/dev/null || true)"
        if [ -z "$cur_body" ]; then
          prt_mark_incomplete "fp=$fp: GET before clearing marker failed or returned empty body, skipped"
          continue
        fi
        new_body="$(prt_marker_replace "$cur_body" "$new_marker")"
        if ! prt_retry 3 prt_gh_rest_fresh PATCH "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" \
             "/repos/${PRT_REPO}/pulls/comments/${first_comment_db_id}" \
             "$(jq -n --arg b "$new_body" '{body:$b}')" >/dev/null; then
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
        prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA" || { prt_mark_incomplete "fp=$fp: stale head SHA, skipped absence auto-close"; continue; }
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
          if prt_freshness_check "$PRT_REPO" "$PRT_PR_NUMBER" "$PRT_HEAD_SHA"; then
            reply="$(prt_render_reply_absent_resolved)"
            prt_gh_rest POST "/repos/${PRT_REPO}/pulls/${PRT_PR_NUMBER}/comments" \
              "$(jq -n --arg b "$reply" --argjson r "$first_comment_db_id" '{body:$b, in_reply_to:$r}')" >/dev/null || \
              prt_mark_incomplete "fp=$fp: absence resolveReviewThread succeeded but the explanatory reply failed"
          else
            prt_mark_incomplete "fp=$fp: absence resolveReviewThread succeeded but head SHA went stale before the reply"
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
    prt_mark_incomplete "stale head SHA, skipped overflow comment"
  fi
fi

{
  prt_render_summary "$PRT_MODE" "$PRT_HEAD_SHA" "$chunk_idx" "$ALL_FINDINGS" "$(prt_incomplete_reasons)"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

exit 0
