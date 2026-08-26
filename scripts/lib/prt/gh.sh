#!/usr/bin/env bash
# gh.sh — the only I/O module: REST + GraphQL calls, retry, freshness check,
# rate-limit handling. curl, not `gh` — the runner's `gh` CLI availability is
# unverified (pr-review.yml apt-installs curl/jq at runtime, implying a
# minimal image), and curl is already the bootstrapped dependency.
#
# PRT_CURL indirection: tests override this to a stub instead of hitting the
# network. Defaults to "curl".
: "${PRT_CURL:=curl}"

set -uo pipefail

# --- Empirically verified facts (see docs/pr-review-threads-live-findings.md
# for the recorded answers once V1-V6 are run) ---
# - Exceeding the primary rate limit returns HTTP 200 with
#   x-ratelimit-remaining: 0 and a GraphQL errors[] body — status code alone
#   is not a reliable failure signal for either REST or GraphQL.
# - resolveReviewThread/unresolveReviewThread need write access or PR
#   authorship, not thread ownership; gate every mutation on
#   viewerCanResolve/viewerCanUnresolve rather than inferring from token type.

PRT_API_BASE="${PRT_API_BASE:-https://api.github.com}"

# Populated by every prt_gh_rest call from the response headers, consumed by
# prt_retry for rate-limit-aware backoff. Empty when the header was absent
# (e.g. under the test stub, which never writes to -D's file).
PRT_LAST_RATELIMIT_REMAINING=""
PRT_LAST_RETRY_AFTER=""
# The literal HTTP status of the most recent prt_gh_rest call (2xx or not) —
# callers that must distinguish failure *kinds* (e.g. a genuine 422 vs. a
# transient 403/502) read this instead of only the 0/1 return code.
PRT_LAST_HTTP_STATUS=""

# prt_gh_rest METHOD PATH [DATA_JSON] — PATH is relative to PRT_API_BASE
# (e.g. "/repos/owner/repo/pulls/1/comments"). Prints the response body on
# 2xx; on failure prints nothing to stdout and a diagnostic to stderr, and
# returns 1. Never trusts curl's own exit code alone (a network-transport
# success with a 4xx/5xx body must still fail).
prt_gh_rest() {
  local method="$1" path="$2" data="${3:-}"
  local tmp hdrs status
  tmp="$(mktemp)"
  hdrs="$(mktemp)"
  local -a args=(-sS -o "$tmp" -D "$hdrs" -w '%{http_code}' -X "$method"
    --connect-timeout 10 --max-time 120
    -H "Authorization: Bearer ${PRT_GH_TOKEN:?PRT_GH_TOKEN not set}"
    -H "Accept: application/vnd.github+json"
    -H "Content-Type: application/json")
  if [ -n "$data" ]; then
    args+=(-d "$data")
  fi
  # Reset before the call, not just on success: a curl transport failure
  # below returns before these are ever (re)assigned from this call's own
  # response, so without this reset a caller reading PRT_LAST_HTTP_STATUS
  # after a transport failure would see a STALE status/rate-limit signal
  # left over from a completely unrelated earlier call — e.g. the 422-ladder
  # fallback (dot-github#50 gmr finding N9-followup) reading a prior call's
  # 422 and firing a duplicate create even though this call's actual
  # request may have reached GitHub and succeeded server-side, with only
  # curl losing the response.
  PRT_LAST_RATELIMIT_REMAINING=""
  PRT_LAST_RETRY_AFTER=""
  PRT_LAST_HTTP_STATUS=""
  status="$("$PRT_CURL" "${args[@]}" "${PRT_API_BASE}${path}")" || {
    echo "prt_gh_rest: curl transport failure for $method $path" >&2
    rm -f "$tmp" "$hdrs"
    return 1
  }
  # Rate-limit headers, captured regardless of status — a 403/429 carries
  # them same as a 200-with-remaining-0. Case-insensitive (curl lowercases
  # response header names, but don't rely on that), last match wins (a
  # redirect chain can repeat the header per hop).
  PRT_LAST_RATELIMIT_REMAINING="$(grep -i '^x-ratelimit-remaining:' "$hdrs" 2>/dev/null | tail -1 | cut -d: -f2- | tr -d ' \r\n')"
  PRT_LAST_RETRY_AFTER="$(grep -i '^retry-after:' "$hdrs" 2>/dev/null | tail -1 | cut -d: -f2- | tr -d ' \r\n')"
  # shellcheck disable=SC2034 # read by callers in pr-review-threads.sh (the 422 ladder), not within this file
  PRT_LAST_HTTP_STATUS="$status"
  rm -f "$hdrs"
  if [[ "$status" =~ ^2[0-9]{2}$ ]]; then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi
  echo "prt_gh_rest: HTTP $status from $method $path" >&2
  head -c 1000 "$tmp" >&2
  rm -f "$tmp"
  return 1
}

# prt_gh_graphql QUERY VARIABLES_JSON — VARIABLES_JSON is a jq object
# (may be "{}"). Prints `.data` on success. A GraphQL response is only a
# success if HTTP is 2xx AND `.errors` is null/absent — GitHub can return
# HTTP 200 with a populated errors[] array (including the rate-limit case
# above), which a bare status-code check would miss entirely.
prt_gh_graphql() {
  local query="$1" variables="${2:-{\}}"
  local payload body errors
  payload="$(jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')"
  body="$(prt_gh_rest POST /graphql "$payload")" || return 1
  errors="$(jq -c '.errors // empty' <<< "$body" 2>/dev/null || true)"
  if [ -n "$errors" ]; then
    echo "prt_gh_graphql: errors[] in response body: $errors" >&2
    return 1
  fi
  jq -c '.data' <<< "$body"
}

# prt_freshness_check REPO PR_NUMBER EXPECTED_SHA — re-fetches the PR's
# current head SHA and compares against EXPECTED_SHA (which must be
# github.event.pull_request.head.sha, never github.sha — under the
# pull_request event github.sha is a temporary merge commit). Called
# immediately before every single write (create/reply/resolve/unresolve/
# marker edit), not once per run, since the run's real wall-clock spans
# multiple model calls.
#
# Three-way exit status (go-kure/.github#99 — the caller distinguishes
# these; see pr-review-threads.sh's prt_handle_freshness_rc call sites),
# mirroring finding.sh's own 0/1/2 prt_normalize_findings convention of
# giving each distinguishable outcome its own return code rather than
# collapsing them behind one bit of information:
#   0 — fresh: the live head SHA matches EXPECTED_SHA exactly. Proceed.
#   1 — genuinely stale: the PR was read successfully and its live head SHA
#       is a real, well-formed (40-hex), different value. This is the ONLY
#       case a caller may treat as non-fatal (prt_mark_degraded) and let the
#       run exit 0 — it is only safe because a superseding run for the new
#       head SHA is guaranteed to be queued (`.github/workflows/pr-review.yml`'s
#       `cancel-in-progress: false`).
#   2 — could not determine freshness at all: the PR read itself failed
#       (prt_gh_rest error), it returned a response with no usable
#       `.head.sha`, or `.head.sha` was present but not a well-formed 40-hex
#       SHA (a malformed/unexpected response shape must NOT be treated as
#       "genuinely moved" just because it happens to differ from
#       EXPECTED_SHA — go-kure/.github#99 codex round 1 finding). None of
#       these mean "a newer run will redo this" — no run is guaranteed to be
#       queued for an unreadable or malformed PR response — so this stays
#       fatal (prt_mark_incomplete) at every call site.
prt_freshness_check() {
  local repo="$1" pr_number="$2" expected_sha="$3"
  local body live_sha
  body="$(prt_gh_rest GET "/repos/${repo}/pulls/${pr_number}")" || {
    echo "prt_freshness_check: failed to read PR ${repo}#${pr_number} (see prt_gh_rest error above)" >&2
    return 2
  }
  live_sha="$(jq -r '.head.sha // empty' <<< "$body" 2>/dev/null || true)"
  if [ -z "$live_sha" ]; then
    echo "prt_freshness_check: PR ${repo}#${pr_number} response had no .head.sha" >&2
    return 2
  fi
  # A non-empty-but-malformed .head.sha (not a 40-hex commit SHA — e.g. a
  # stringified error, a truncated value, a schema change upstream) must NOT
  # fall through to the mismatch branch below: comparing it against
  # expected_sha would almost always differ and get misread as "genuinely
  # moved", which the caller is allowed to treat as safe/non-fatal
  # (go-kure/.github#99 codex round 1 finding) — but a malformed value gives
  # no such guarantee that a superseding run is actually queued. Fail closed
  # via the same status as an empty/absent field instead.
  if ! [[ "$live_sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "prt_freshness_check: PR ${repo}#${pr_number} .head.sha was not a well-formed 40-hex SHA: '$live_sha'" >&2
    return 2
  fi
  if [ "$live_sha" != "$expected_sha" ]; then
    echo "prt_freshness_check: head moved: $expected_sha -> $live_sha" >&2
    return 1
  fi
  return 0
}

# prt_gh_rest_fresh METHOD REPO PR_NUMBER EXPECTED_SHA PATH [DATA_JSON] —
# freshness-gated prt_gh_rest, meant to be passed to prt_retry so EVERY
# retry attempt rechecks freshness immediately before its write, not just
# once before the retry loop starts. A rate-limit backoff sleep inside
# prt_retry can run up to ~60s per attempt (up to ~120s across 3 attempts);
# a single check before the loop began does not cover a write that actually
# lands a minute or two later, after the PR head may have moved
# (dot-github#50 gmr finding C9).
#
# Four-way exit status (go-kure/.github#99), extending prt_freshness_check's
# own 0/1/2 with one more: this wraps a write, so a fresh-but-failed write
# needs a status distinct from either freshness outcome — collapsing it into
# 1 previously made a genuine HTTP failure on the write itself indistinguishable
# from a stale head at every call site (both forced through prt_mark_incomplete
# either way, so no caller could tell "stale" from "write failed" apart even
# after prt_freshness_check itself started distinguishing them).
#   0 — the freshness check passed AND the write succeeded.
#   1 — passed straight through from prt_freshness_check: genuinely stale.
#   2 — passed straight through from prt_freshness_check: read failure or
#       malformed response.
#   3 — the freshness check passed (head was fresh at that instant) but the
#       wrapped prt_gh_rest write itself failed (an unrelated HTTP error) —
#       always fatal, matching status 2 above: no queued run will retry this
#       specific write for you.
prt_gh_rest_fresh() {
  local method="$1" repo="$2" pr_number="$3" expected_sha="$4" path="$5" data="${6:-}"
  local fresh_rc
  prt_freshness_check "$repo" "$pr_number" "$expected_sha"
  fresh_rc=$?
  [ "$fresh_rc" -eq 0 ] || return "$fresh_rc"
  prt_gh_rest "$method" "$path" "$data" || return 3
}

# prt_retry N CMD... — retries CMD up to N times. Between attempts, honors
# GitHub's own back-off signal if the last prt_gh_rest call set one
# (Retry-After, or x-ratelimit-remaining: 0 — the documented HTTP-200-with-
# no-budget-left case): sleep that many seconds (capped at 60, so a huge or
# malformed header can't stall a job for its full timeout) rather than
# hammering an active rate limit. No default backoff otherwise — on the
# self-hosted in-cluster runner, failures with no rate-limit signal are
# almost always a transient 5xx, not a network partition worth waiting out.
prt_retry() {
  local n="$1"; shift
  # rc defaults to 1 so `return "$rc"` never reads unset under `set -u` if
  # called with n<1 (no caller does today, but the loop body — the only
  # place rc is otherwise assigned — never runs in that case).
  local i rc=1
  for ((i = 1; i <= n; i++)); do
    # Never `if "$@"; then return 0; fi` followed by `rc=$?` — when the
    # condition is false and no branch runs, bash reports the if construct's
    # OWN status as 0, not the tested command's, so that pattern silently
    # turns every failed attempt into a reported success. Call directly and
    # read $? right after, before anything else can overwrite it.
    "$@"
    rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$i" -lt "$n" ]; then
      local wait="${PRT_LAST_RETRY_AFTER:-}"
      if [ -z "$wait" ] && [ "${PRT_LAST_RATELIMIT_REMAINING:-}" = "0" ]; then
        wait=30
      fi
      if [ -n "$wait" ] && [[ "$wait" =~ ^[0-9]+$ ]]; then
        [ "$wait" -gt 60 ] && wait=60
        sleep "$wait"
      fi
    fi
  done
  return "$rc"
}

# prt_find_marked_comment REPO PR_NUMBER MARKER BOT_LOGIN — paginates
# /issues/{pr}/comments (REST — same endpoint the advisory/overflow comments
# already POST to) looking for a comment authored by BOT_LOGIN whose body
# contains MARKER anywhere. This is a plain top-level issue comment, not a
# thread's first-comment marker (marker.sh), so there is no "first line"
# convention to key off — `contains`, not an anchored line match. BOT_LOGIN
# is compared against REST's `.user.login`, which — unlike GraphQL's
# author.login — keeps the "[bot]" suffix, so pass PRT_BOT_LOGIN here
# unstripped (contrast the PRT_BOT_LOGIN_GQL variant used against GraphQL
# thread authors elsewhere in this script). Prints the comment's numeric id
# on stdout if found, prints nothing (exit 0) if none — that is "no comment
# yet," not a failure. Returns 1 only when a paginated GET itself fails, so
# callers can tell "no comment yet" from "could not check."
prt_find_marked_comment() {
  local repo="$1" pr_number="$2" marker="$3" bot_login="$4"
  local page=1 body count id
  while :; do
    body="$(prt_gh_rest GET "/repos/${repo}/issues/${pr_number}/comments?per_page=100&page=${page}")" || return 1
    count="$(jq 'length' <<< "$body" 2>/dev/null || echo 0)"
    [ "$count" -eq 0 ] && break
    id="$(jq -r --arg m "$marker" --arg bot "$bot_login" '
      [.[] | select(.user.login == $bot) | select((.body // "") | contains($m))] | .[0].id // empty
    ' <<< "$body" 2>/dev/null || true)"
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
  return 0
}

# prt_upsert_issue_comment REPO PR_NUMBER BODY [EXISTING_ID] — PATCHes
# EXISTING_ID (edit in place) if given/non-empty, else POSTs a new comment.
# Single attempt, not prt_retry-wrapped — matching every other comment POST
# in this codebase (advisory, overflow): a genuine failure here becomes
# REVIEW_INCOMPLETE at the call site, not a silent retry loop.
prt_upsert_issue_comment() {
  local repo="$1" pr_number="$2" body="$3" existing_id="${4:-}"
  local payload
  payload="$(jq -n --arg b "$body" '{body:$b}')"
  if [ -n "$existing_id" ]; then
    prt_gh_rest PATCH "/repos/${repo}/issues/comments/${existing_id}" "$payload" >/dev/null
  else
    prt_gh_rest POST "/repos/${repo}/issues/${pr_number}/comments" "$payload" >/dev/null
  fi
}
