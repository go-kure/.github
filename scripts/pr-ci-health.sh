#!/bin/bash
# Report open, non-draft PRs across org repos whose combined CI status is
# failing or erroring — a second, independent signal alongside the Org
# Settings audit (settings drift vs. PR/CI health). Read-only: never
# comments, labels, or otherwise touches a PR; it only reports.
#
# Usage: ./pr-ci-health.sh [--ci] [--json]
#   --ci    No ANSI colors (CI-friendly output)
#   --json  Also write pr-ci-health-report.json (used by the workflow's
#           step-summary step; safe to pass in local/manual runs too)
#
# Requires: gh CLI (authenticated), jq
#
# Exit: 1 if any open, non-draft PR has a FAILURE/ERROR statusCheckRollup, or
# if any repo's GraphQL query itself failed (coverage was incomplete — a
# distinct ERROR-prefixed line says which, so the two causes aren't
# confused); 0 otherwise. A red run here is meant to be the notification.
#
# Known gaps (see docs/standards.md, "PR CI Health" for the full writeup):
#  - Drafts are excluded (isDraft). A "dependency-dashboard-gated" exclusion
#    was considered and deferred — Renovate has no distinct API-visible
#    state for "on hold via the Dependency Dashboard" that this script could
#    key on; such PRs simply don't exist as open PRs yet, so nothing here
#    special-cases them. If Renovate-authored PRs turn out to be a real
#    source of noise once this has run for a while, that's the place to
#    add a targeted exclusion, not this comment.
#  - Only the first 100 open PRs per repo are scanned (no pagination) — a
#    repo with more open PRs than that gets a stderr warning, not a silent
#    truncation.

set -euo pipefail

GITHUB_ORG="${GITHUB_ORG:-go-kure}"
# Kept in sync by hand with GITHUB_REPOS_DEFAULT in github-settings.sh —
# both name the same GitHub-side repos this org manages.
GITHUB_REPOS_DEFAULT=".github kure launcher go-kure.github.io"
GITHUB_REPOS="${GITHUB_REPOS:-$GITHUB_REPOS_DEFAULT}"

CI_MODE=false
JSON_MODE=false
for arg in "$@"; do
    case "$arg" in
        --ci) CI_MODE=true ;;
        --json) JSON_MODE=true ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 [--ci] [--json]" >&2
            exit 2
            ;;
    esac
done

if [ "$CI_MODE" = true ] || [ ! -t 1 ]; then
    RED=""; GREEN=""; RESET=""
else
    RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
fi

# GraphQL variables ($owner/$repo/$cursor-shaped names below), not shell
# expansions — bound via `gh api graphql -F owner=... -F repo=...`, so the
# single quotes are intentional.
# shellcheck disable=SC2016
QUERY='
query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequests(states: OPEN, first: 100) {
      pageInfo { hasNextPage }
      nodes {
        number
        title
        url
        isDraft
        commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup { state }
            }
          }
        }
      }
    }
  }
}'

failing_json="[]"
query_error_count=0
query_error_repos="[]"
for repo in $GITHUB_REPOS; do
    # A failure here must not abort the loop: the report is only written
    # after it, so aborting mid-loop means no report at all and no repo
    # after the failing one gets scanned — a query outage would silently
    # look identical to "there are failing PRs" (go-kure/.github#141
    # review finding). Record and move on instead; still exit non-zero at
    # the end, with a message that says "could not query" rather than
    # "found a failing PR" so the two causes aren't confused. The failed
    # repo also goes into the JSON report itself (not just stderr), so the
    # step-summary step — which only reads the JSON — can say "coverage
    # incomplete" instead of misreporting "all green" on an empty findings
    # array (go-kure/.github#141 follow-up review finding).
    resp=$(gh api graphql -f query="$QUERY" -F owner="$GITHUB_ORG" -F repo="$repo") || {
        echo "ERROR: GraphQL query failed for $GITHUB_ORG/$repo — this repo was not scanned" >&2
        query_error_count=$((query_error_count + 1))
        query_error_repos=$(jq --arg repo "$repo" '. + [$repo]' <<< "$query_error_repos")
        continue
    }

    has_next=$(echo "$resp" | jq -r '.data.repository.pullRequests.pageInfo.hasNextPage')
    if [ "$has_next" = "true" ]; then
        echo "WARNING: $GITHUB_ORG/$repo has more than 100 open PRs; only the first 100 were scanned" >&2
    fi

    page_failing=$(echo "$resp" | jq --arg repo "$repo" '
        [.data.repository.pullRequests.nodes[]
            | select(.isDraft == false)
            | . as $pr
            | ($pr.commits.nodes[0].commit.statusCheckRollup.state // "") as $state
            | select($state == "FAILURE" or $state == "ERROR")
            | {repo: $repo, number: $pr.number, title: $pr.title, url: $pr.url, state: $state}]')

    failing_json=$(jq -s 'add' <(echo "$failing_json") <(echo "$page_failing"))
done

count=$(echo "$failing_json" | jq 'length')

if [ "$JSON_MODE" = true ]; then
    jq -n --argjson failing "$failing_json" --argjson query_errors "$query_error_repos" \
        '{failing: $failing, query_errors: $query_errors}' > pr-ci-health-report.json
fi

if [ "$count" -eq 0 ] && [ "$query_error_count" -eq 0 ]; then
    echo "${GREEN}pr-ci-health: 0 open PR(s) with failing/erroring checks${RESET}"
else
    if [ "$count" -gt 0 ]; then
        echo "${RED}pr-ci-health: $count open PR(s) with failing/erroring checks${RESET}"
        echo "$failing_json" | jq -r --arg red "$RED" --arg reset "$RESET" \
            '.[] | "  " + $red + .repo + "#" + (.number|tostring) + "  " + .state + $reset + "  " + .title + "  " + .url'
    fi
    if [ "$query_error_count" -gt 0 ]; then
        echo "${RED}pr-ci-health: $query_error_count repo(s) could not be queried — coverage incomplete, see ERROR lines above${RESET}"
    fi
fi

[ "$count" -eq 0 ] && [ "$query_error_count" -eq 0 ]
