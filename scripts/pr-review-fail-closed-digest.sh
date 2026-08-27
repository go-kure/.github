#!/bin/bash
# pr-review-fail-closed-digest.sh — daily org-wide digest of fail-closed
# pr-review-threads events, per go-kure/.github#117 (raised by go-kure/.github#95).
#
# Nothing today aggregates the fatal REVIEW_INCOMPLETE exit across repos: each
# run's own ::error annotations and non-green job are only visible on that
# one PR. This script scans the org's "PR Review" workflow runs, isolates the
# genuine model/proxy fail-closed events (as opposed to an unrelated failure
# that happens to carry the same annotation title — see the classifier below)
# and emits a digest so the pattern — several fatal runs inside a short
# window, meaning the shared proxy backend or the model itself is sick — is
# visible without a human noticing by chance.
#
# Usage: pr-review-fail-closed-digest.sh [--window-hours N] [--threshold N]
#                                        [--json] [--ci] [REPO_ROOT]
#
#   --window-hours N   How far back to scan (default: 24).
#   --threshold N       Affected-run count at/above which the caller should
#                        treat the window as alert-worthy (default: 2). This
#                        script only reports it in --json output as
#                        threshold_met — raising an actual alert is the
#                        calling workflow's job, not this script's.
#   --json               Emit a machine-readable JSON object instead of the
#                         default markdown table (job-summary ready).
#   --ci                 Reserved for CLI parity with this repo's other
#                        scripts (github-settings.sh); this script prints no
#                         color either way.
#   REPO_ROOT             Defaults to ".". Not read for any repo-local file —
#                         this script only calls the GitHub API — but the
#                        positional stays for CLI/test-harness parity with
#                        this repo's other scripts (github-settings-test.sh's
#                        sourcing idiom). An invalid path fails immediately
#                         (cd below).
#
# Environment:
#   GH_TOKEN       Required. A token readable across every repo in
#                  $GITHUB_REPOS (Actions: read, Checks: read) — see
#                  docs/pr-review-threads.md § Fail-closed alerting for which
#                  org secret that resolves to.
#   GITHUB_ORG     Default: go-kure.
#   GITHUB_REPOS   Default: same list as scripts/github-settings.sh
#                  (GITHUB_REPOS_DEFAULT below) — space-separated, override to
#                  narrow to a subset for a single run.
#
# Fails closed: any non-2xx from the GitHub API aborts the whole run with
# "ERROR: HTTP <code> from <method> <url>" and exit 1 (via the shared
# gh_api_call wrapper below and this script's own `set -e`), rather than
# silently reporting a short or empty digest. A run with zero events found is
# a legitimate, non-fatal outcome; a run that couldn't read some part of the
# org is not, and must not look the same on exit.

set -euo pipefail
# Without this, `set -e` is silently unset inside every command-substitution
# subshell by default (bash's non-POSIX default) — a gh_api_call failure
# three function calls deep inside `x="$(some_func ...)"` would NOT abort
# this script; it would fall through into the network functions' own
# subsequent jq parses on an empty/garbage response and, worst case, loop
# forever retrying the same failing page (codex round 1 finding, confirmed
# by direct reproduction — see the commit history for this line). This
# restores the fail-closed guarantee the header above promises for every
# gh_api_call call site, not only the ones at true top level.
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/api.sh
source "$SCRIPT_DIR/lib/api.sh"

# Every network call in this script must go through this wrapper, never the
# shared helper it wraps directly — all three repos are public, so an
# unauthenticated request also returns 200 (verified live during this
# script's plan review), meaning a call that forgot the header would run
# unauthenticated end to end and nobody would notice from the output alone.
# scripts/test/pr-review-fail-closed-digest-test.sh asserts structurally that
# this is the only bare call site of the wrapped helper in this file.
gh_api_call() { api_call "$@" --header "Authorization: Bearer $GH_TOKEN"; }

GITHUB_ORG="${GITHUB_ORG:-go-kure}"
GITHUB_REPOS_DEFAULT=".github kure launcher go-kure.github.io"
GITHUB_REPOS="${GITHUB_REPOS:-$GITHUB_REPOS_DEFAULT}"
GH_API_BASE="https://api.github.com"

usage() {
  cat <<'EOF'
Usage: pr-review-fail-closed-digest.sh [--window-hours N] [--threshold N]
                                       [--json] [--ci] [REPO_ROOT]

  --window-hours N  How far back to scan, in hours (default: 24)
  --threshold N     Affected-run count the caller treats as alert-worthy
                     (default: 2); reported in --json output only
  --json            Emit machine-readable JSON instead of a markdown table
  --ci              CLI parity with this repo's other scripts (no-op here)
  REPO_ROOT         Defaults to "."

Environment:
  GH_TOKEN      Required — a token with Actions:read + Checks:read across
                every repo in GITHUB_REPOS
  GITHUB_ORG    Default: go-kure
  GITHUB_REPOS  Default: ".github kure launcher go-kure.github.io"
EOF
}

# --- Pure helpers (no network) -------------------------------------------

# Bash array -> JSON array of strings, zero-element-safe (mirrors
# github-settings.sh's bash_array_to_json: printf reuses the format string
# once even with zero args, which would otherwise produce [""] not []).
pr_digest_bash_array_to_json() {
  if [ "$#" -eq 0 ]; then
    echo "[]"
  else
    printf '%s\n' "$@" | jq -R . | jq -sc .
  fi
}

# pr_digest_strip_chunk_prefix MESSAGE — strips a leading "chunk N: " prefix
# (pr-review-threads.sh's convention at every prt_mark_incomplete /
# review_parse_failures call site relevant here); returns the message
# unchanged if the prefix isn't present.
pr_digest_strip_chunk_prefix() {
  local msg="$1" re='^chunk [0-9]+: (.*)$'
  if [[ "$msg" =~ $re ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$msg"
  fi
}

# pr_digest_classify_reason MESSAGE (already chunk-prefix-stripped) — echoes
# one of the three known fail-closed reason classes, or "" for no match.
# Anchored to the exact message shapes pr-review-threads.sh emits
# (scripts/pr-review-threads.sh: the review-call and .findings branches):
#   - "review response was not valid JSON after retry=..." (both the
#     first-attempt and retried forms carry this same prefix)
#   - ".findings missing/null/non-array, or all rows malformed and dropped"
#   - "review call failed (transport/proxy error, ...)" (first attempt) and
#     "review call failed on retry (transport/proxy error, ...)" (the one
#     retry) — both must match, or every retry-transport fatal silently
#     falls into "other failure"
pr_digest_classify_reason() {
  local msg="$1"
  case "$msg" in
    "review response was not valid JSON"*)
      printf 'not_valid_json' ;;
    *".findings missing/null/non-array"*)
      printf 'findings_missing' ;;
    "review call failed (transport/proxy error"* | "review call failed on retry (transport/proxy error"*)
      printf 'transport_proxy' ;;
    *)
      printf '' ;;
  esac
}

# pr_digest_classify_annotations ANNOTATIONS_JSON — ANNOTATIONS_JSON is a
# JSON array of {title, message, ...} check-run annotation objects. Returns
# {"is_event": bool, "reasons": [...]}. A run is a fail-closed "event" only
# when at least one annotation is titled exactly "PR review threads
# incomplete" AND its (chunk-prefix-stripped) message matches one of the
# three known patterns above — the title alone over-includes fatals that
# share it for an unrelated reason (clean-comment-upsert failures, a chunk
# count mismatch, ...). reasons is the deduped list of matched classes;
# empty when is_event is false.
pr_digest_classify_annotations() {
  local annotations_json="${1:-[]}"
  local titled count
  titled="$(jq -c '[.[] | select(.title == "PR review threads incomplete")]' <<<"$annotations_json")"
  count="$(jq 'length' <<<"$titled")"

  local reasons=()
  local i msg stripped class
  for ((i = 0; i < count; i++)); do
    msg="$(jq -r ".[$i].message" <<<"$titled")"
    stripped="$(pr_digest_strip_chunk_prefix "$msg")"
    class="$(pr_digest_classify_reason "$stripped")"
    [ -n "$class" ] && reasons+=("$class")
  done

  local reasons_json is_event
  reasons_json="$(jq -c 'unique' <<<"$(pr_digest_bash_array_to_json "${reasons[@]}")")"
  is_event="false"
  [ "$(jq 'length' <<<"$reasons_json")" -gt 0 ] && is_event="true"

  jq -n --argjson reasons "$reasons_json" --argjson is_event "$is_event" \
    '{is_event: $is_event, reasons: $reasons}'
}

# pr_digest_build_row REPO RUN_JSON CLASSIFY_JSON — one digest row from a
# single run's own JSON (as returned by the runs-list API) and its
# classification. pr_number is null (not "" — not every run is PR-triggered)
# when .pull_requests is empty; the run URL and head branch already identify
# the row in that case, so no separate fallback lookup is needed.
pr_digest_build_row() {
  local repo="$1" run_json="$2" classify_json="$3"
  jq -n \
    --arg repo "$repo" \
    --argjson run "$run_json" \
    --argjson classify "$classify_json" \
    '{
      repo: $repo,
      run_id: $run.id,
      run_url: $run.html_url,
      pr_number: ($run.pull_requests[0].number // null),
      head_branch: $run.head_branch,
      created_at: $run.created_at,
      reasons: $classify.reasons
    }'
}

# pr_digest_threshold_met COUNT THRESHOLD — pure comparison, kept separate
# from the JSON renderer below so it's directly unit-testable.
pr_digest_threshold_met() {
  local count="$1" threshold="$2"
  [ "$count" -ge "$threshold" ]
}

# pr_digest_render_markdown ROWS_JSON OTHER_FAILURE_COUNT — job-summary-ready
# markdown table. Also the default stdout format.
pr_digest_render_markdown() {
  local rows_json="$1" other_failure_count="${2:-0}"
  local count
  count="$(jq 'length' <<<"$rows_json")"
  if [ "$count" -eq 0 ]; then
    echo "No fail-closed pr-review-threads events in the window."
  else
    echo "| Repo | Run | PR | Branch | When (UTC) | Reasons |"
    echo "|------|-----|----|--------|------------|---------|"
    jq -r '.[] | "| \(.repo) | [\(.run_id)](\(.run_url)) | \(if .pr_number then "#\(.pr_number)" else "-" end) | \(.head_branch) | \(.created_at) | \(.reasons | join(", ")) |"' <<<"$rows_json"
  fi
  echo ""
  echo "_${other_failure_count} other failed run(s) in the window excluded — not a fail-closed model/proxy event (e.g. a pin-bump window, a checkout fault, or a same-titled but different-cause fatal)._"
}

# pr_digest_render_json ROWS_JSON WINDOW_HOURS THRESHOLD GENERATED_AT
# OTHER_FAILURE_COUNT — machine-readable form for the calling workflow's
# issue-raising step. Single source of truth for the shape both the workflow
# and this script's own markdown mode read from.
pr_digest_render_json() {
  local rows_json="$1" window_hours="$2" threshold="$3" generated_at="$4" other_failure_count="${5:-0}"
  local count threshold_met_bool reason_summary
  count="$(jq 'length' <<<"$rows_json")"
  threshold_met_bool="false"
  pr_digest_threshold_met "$count" "$threshold" && threshold_met_bool="true"
  reason_summary="$(jq -c '([.[].reasons[]] | group_by(.) | map({key: .[0], value: length}) | from_entries) // {}' <<<"$rows_json")"

  jq -n \
    --arg generated_at "$generated_at" \
    --argjson window_hours "$window_hours" \
    --argjson threshold "$threshold" \
    --argjson affected_count "$count" \
    --argjson other_failure_count "$other_failure_count" \
    --argjson threshold_met "$threshold_met_bool" \
    --argjson reason_summary "$reason_summary" \
    --argjson rows "$rows_json" \
    '{
      generated_at: $generated_at,
      window_hours: $window_hours,
      threshold: $threshold,
      affected_count: $affected_count,
      other_failure_count: $other_failure_count,
      threshold_met: $threshold_met,
      reason_summary: $reason_summary,
      rows: $rows
    }'
}

# --- Network helpers -------------------------------------------------------
#
# None of these use return-code signalling for "nothing found" — an empty
# result after full pagination is a legitimate, successful outcome (not
# every repo runs a workflow literally named "PR Review"; not every failed
# run has an "AI Code Review" job). Every call site below is a plain
# statement, never inside `if`/`&&`/`||`/`!` — bash disables `set -e` for the
# whole duration of a function invoked as such a construct's tested command,
# not just for its own exit status, which would otherwise silently swallow a
# real API failure surfacing from deep inside one of these.

# pr_digest_find_workflow_id REPO — echoes the workflow id whose name is
# exactly "PR Review" (never match on filename — it differs per repo:
# .github/workflows/pr-review-caller.yml vs kure/launcher's pr-review.yml),
# or an empty string if this repo has no such workflow.
#
# go-kure/.github itself hosts BOTH the caller (pr-review-caller.yml,
# triggered on pull_request) and the reusable definition it calls
# (pr-review.yml, workflow_call-only) — GitHub's workflows-list API returns
# an entry for every syntactically valid file under .github/workflows/
# regardless of trigger type, and both files declare `name: PR Review`
# (codex round 2 finding, confirmed by direct read of both files' `name:`
# lines). Matching on name alone and taking the first hit is therefore
# ambiguous for exactly this one repo: depending on API list order, it can
# resolve to the reusable definition's id instead of the caller's, silently
# scoping every subsequent query to a workflow whose own run history does
# not carry this repo's actual pull-request-triggered failures — the digest
# would then miss go-kure/.github's own fail-closed events indefinitely.
# All possible name matches are gathered across every page first (never
# return on the first hit), then disambiguated using this org's own stated
# convention (AGENTS.md "Working with Reusable Workflows": caller files end
# in `-caller.yml`, the reusable definitions they delegate to do not) —
# prefer a path ending in `-caller.yml` when more than one match exists.
# kure/launcher only ever have a single match (they reference the reusable
# workflow remotely, by @main, never as a local file), so this preference
# is a no-op there. If somehow neither match ends in `-caller.yml`, fall
# back to the first one rather than erroring — there is nothing further to
# disambiguate on with the fields this endpoint returns.
pr_digest_find_workflow_id() {
  local repo="$1" page=1 per_page=100
  local acc='[]'
  while :; do
    local resp batch n
    resp="$(gh_api_call GET "$GH_API_BASE/repos/$GITHUB_ORG/$repo/actions/workflows?per_page=${per_page}&page=${page}")"
    batch="$(jq -c '.workflows' <<<"$resp")"
    acc="$(jq -c -n --argjson a "$acc" --argjson b "$batch" '$a + $b')"
    n="$(jq 'length' <<<"$batch")"
    if [ "$n" -lt "$per_page" ]; then
      break
    fi
    page=$((page + 1))
  done
  jq -r '
    [.[] | select(.name == "PR Review")] as $matches
    | if ($matches | length) == 0 then ""
      elif ($matches | length) == 1 then ($matches[0].id | tostring)
      else
        ([$matches[] | select(.path | endswith("-caller.yml"))]) as $callers
        | if ($callers | length) > 0 then ($callers[0].id | tostring)
          else ($matches[0].id | tostring)
          end
      end
  ' <<<"$acc"
}

# pr_digest_list_failed_runs REPO WORKFLOW_ID SINCE_DATE — every failed run
# of that workflow with created >= SINCE_DATE (YYYY-MM-DD; date granularity
# only — the caller re-filters to the exact hour bound), paginated to
# exhaustion. .github's workflow alone returned total_count=48 against a
# per_page=30 default in a live check during this script's plan review, so
# page 1 alone would silently drop older-page events still inside the
# window.
pr_digest_list_failed_runs() {
  local repo="$1" workflow_id="$2" since_date="$3" page=1 per_page=100
  local acc='[]'
  while :; do
    local resp batch n
    resp="$(gh_api_call GET "$GH_API_BASE/repos/$GITHUB_ORG/$repo/actions/workflows/$workflow_id/runs?status=failure&created=%3E%3D${since_date}&per_page=${per_page}&page=${page}")"
    batch="$(jq -c '.workflow_runs' <<<"$resp")"
    acc="$(jq -c -n --argjson a "$acc" --argjson b "$batch" '$a + $b')"
    n="$(jq 'length' <<<"$batch")"
    if [ "$n" -lt "$per_page" ]; then
      break
    fi
    page=$((page + 1))
  done
  echo "$acc"
}

# pr_digest_get_annotations_for_run REPO RUN_ID — the annotations on the
# run's "AI Code Review" job (the job name pr-review-threads.sh's own step
# runs under), or "[]" if the run has no such job (a checkout/runner fault,
# or the pin-bump-window case — a run that fails before that job runs at
# all).
pr_digest_get_annotations_for_run() {
  local repo="$1" run_id="$2"
  local jobs_resp check_run_url
  jobs_resp="$(gh_api_call GET "$GH_API_BASE/repos/$GITHUB_ORG/$repo/actions/runs/$run_id/jobs?per_page=100")"
  check_run_url="$(jq -r '.jobs[] | select(.name == "AI Code Review") | .check_run_url' <<<"$jobs_resp" | head -1)"
  if [ -z "$check_run_url" ]; then
    echo "[]"
    return 0
  fi
  gh_api_call GET "${check_run_url}/annotations?per_page=100"
}

# --- Main -------------------------------------------------------------------

main() {
  local window_hours=24 threshold=2 json_mode=false ci_mode=false repo_root="."

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --window-hours)
        window_hours="$2"
        shift 2
        ;;
      --threshold)
        threshold="$2"
        shift 2
        ;;
      --json)
        json_mode=true
        shift
        ;;
      --ci)
        ci_mode=true
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "ERROR: unknown option: $1" >&2
        usage
        exit 1
        ;;
      *)
        repo_root="$1"
        shift
        ;;
    esac
  done
  # ci_mode has no effect (this script prints no color either way) — kept
  # only for CLI parity with this repo's other scripts. Referencing it here
  # avoids an unused-variable lint finding on an intentionally-accepted flag.
  : "$ci_mode"

  cd "$repo_root"

  : "${GH_TOKEN:?ERROR: GH_TOKEN must be set (Actions:read + Checks:read across every repo in GITHUB_REPOS)}"

  local since_date since_iso generated_at
  since_iso="$(date -u -d "-${window_hours} hours" +%Y-%m-%dT%H:%M:%SZ)"
  since_date="$(date -u -d "-${window_hours} hours" +%Y-%m-%d)"
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local rows_json='[]' other_failure_count=0
  local repo
  for repo in $GITHUB_REPOS; do
    local workflow_id
    workflow_id="$(pr_digest_find_workflow_id "$repo")"
    if [ -z "$workflow_id" ]; then
      continue
    fi

    local runs_json run_count
    runs_json="$(pr_digest_list_failed_runs "$repo" "$workflow_id" "$since_date")"
    runs_json="$(jq -c --arg since "$since_iso" '[.[] | select(.created_at >= $since)]' <<<"$runs_json")"
    run_count="$(jq 'length' <<<"$runs_json")"

    local i
    for ((i = 0; i < run_count; i++)); do
      local run_json run_id annotations_json classify_json is_event row
      run_json="$(jq -c ".[$i]" <<<"$runs_json")"
      run_id="$(jq -r '.id' <<<"$run_json")"
      annotations_json="$(pr_digest_get_annotations_for_run "$repo" "$run_id")"
      classify_json="$(pr_digest_classify_annotations "$annotations_json")"
      is_event="$(jq -r '.is_event' <<<"$classify_json")"
      if [ "$is_event" = "true" ]; then
        row="$(pr_digest_build_row "$repo" "$run_json" "$classify_json")"
        rows_json="$(jq -c -n --argjson a "$rows_json" --argjson b "$row" '$a + [$b]')"
      else
        other_failure_count=$((other_failure_count + 1))
      fi
    done
  done

  rows_json="$(jq -c 'sort_by(.created_at)' <<<"$rows_json")"

  if [ "$json_mode" = true ]; then
    pr_digest_render_json "$rows_json" "$window_hours" "$threshold" "$generated_at" "$other_failure_count"
  else
    pr_digest_render_markdown "$rows_json" "$other_failure_count"
  fi
}

# Sourceable for tests (scripts/test/pr-review-fail-closed-digest-test.sh
# sources this file to exercise the pure classifier/aggregator/render
# functions directly, without a live `gh`/network) while remaining a normal,
# unchanged CLI when executed directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
