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
    -H "Authorization: Bearer ${PRT_GH_TOKEN:?PRT_GH_TOKEN not set}"
    -H "Accept: application/vnd.github+json"
    -H "Content-Type: application/json")
  if [ -n "$data" ]; then
    args+=(-d "$data")
  fi
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
# multiple model calls. Returns 1 (stale or read-error, fail-closed) unless
# the live head SHA matches exactly.
prt_freshness_check() {
  local repo="$1" pr_number="$2" expected_sha="$3"
  local body live_sha
  body="$(prt_gh_rest GET "/repos/${repo}/pulls/${pr_number}")" || return 1
  live_sha="$(jq -r '.head.sha // empty' <<< "$body" 2>/dev/null || true)"
  [ -n "$live_sha" ] || return 1
  [ "$live_sha" = "$expected_sha" ]
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
  local i rc
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
