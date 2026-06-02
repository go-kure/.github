#!/bin/bash
# Audit and apply GitHub repository settings
# Usage: ./github-settings.sh <repo> [--apply] [--ci] [--json]
#        ./github-settings.sh --all [--apply] [--ci] [--json]
#
# Requires: gh CLI (authenticated), jq, yq
#
# Examples:
#   ./github-settings.sh kure              # Audit kure repo
#   ./github-settings.sh kure --apply      # Apply settings to kure
#   ./github-settings.sh --all             # Audit all GitHub repos
#   ./github-settings.sh --all --apply     # Apply to all GitHub repos
#   ./github-settings.sh --all --ci        # Audit all repos (no colors, CI-friendly)
#   ./github-settings.sh --all --json      # Output JSON summary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHARF_DIR="$(dirname "$SCRIPT_DIR")"

# Default organization and repos (override via environment variables)
GITHUB_ORG="${GITHUB_ORG:-go-kure}"
GITHUB_REPOS="${GITHUB_REPOS:-.github kure launcher}"

LABELS_FILE="$WHARF_DIR/standards/labels.json"
POLICY_FILE="$WHARF_DIR/governance/repository-settings-policy.yaml"
CI_MODE=false
JSON_OUTPUT=false

# Label rename mapping: GitHub default name -> standard name
# Used to detect drifted labels that should be renamed instead of created
declare -A LABEL_RENAME_MAP=(
    ["bug"]="type/bug"
    ["enhancement"]="type/feature"
)

# Colors for output (disabled in CI mode)
setup_colors() {
    if [ "$CI_MODE" = "true" ]; then
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        NC=''
    else
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        NC='\033[0m'
    fi
}

# Counters for summary
LABELS_MISSING=0
LABELS_OK=0
LABELS_RENAMED=0
LABELS_EXTRA=0
LABELS_BLOCKED=0
SETTINGS_MISSING=0
SETTINGS_OK=0
RULESET_MISSING=0
RULESET_OK=0

# JSON results
json_results="[]"

usage() {
    echo "Usage: $0 <repo> [--apply] [--ci] [--json]"
    echo "       $0 --all [--apply] [--ci] [--json]"
    echo ""
    echo "Options:"
    echo "  <repo>     Repository name (e.g., kure)"
    echo "  --all      Audit/apply to all GitHub repos (\$GITHUB_REPOS)"
    echo "  --apply    Apply settings (default is dry-run/audit only)"
    echo "  --ci       Disable ANSI colors for clean CI log output"
    echo "  --json     Output machine-readable JSON summary"
    echo ""
    echo "Environment variables:"
    echo "  GITHUB_ORG    GitHub organization (default: go-kure)"
    echo "  GITHUB_REPOS  Space-separated list of GitHub repo names"
    echo ""
    echo "Examples:"
    echo "  $0 kure                    # Audit kure repo settings"
    echo "  $0 kure --apply            # Apply standard settings to kure"
    echo "  $0 --all                   # Audit all GitHub repos"
    echo "  $0 --all --apply           # Apply settings to all repos"
    echo "  $0 --all --ci              # CI-friendly audit (no ANSI colors)"
    echo "  $0 --all --json            # Output JSON summary"
    exit 1
}

check_requirements() {
    if ! command -v gh &>/dev/null; then
        echo -e "${RED}ERROR: gh CLI is required but not installed${NC}"
        echo "Install from: https://cli.github.com/"
        exit 1
    fi

    if ! gh auth status &>/dev/null; then
        echo -e "${RED}ERROR: gh CLI is not authenticated${NC}"
        echo "Run: gh auth login"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        echo -e "${RED}ERROR: jq is required but not installed${NC}"
        echo "Install with: apt install jq / brew install jq"
        exit 1
    fi

    if ! command -v yq &>/dev/null; then
        echo -e "${RED}ERROR: yq is required but not installed${NC}"
        echo "Install with: apt install yq / brew install yq"
        exit 1
    fi

    if [ ! -f "$LABELS_FILE" ]; then
        echo -e "${RED}ERROR: Labels file not found: $LABELS_FILE${NC}"
        exit 1
    fi

    if [ ! -f "$POLICY_FILE" ]; then
        echo -e "${RED}ERROR: Policy file not found: $POLICY_FILE${NC}"
        exit 1
    fi

    if ! yq -e '.github_defaults' "$POLICY_FILE" >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Policy file missing 'github_defaults' section: $POLICY_FILE${NC}"
        exit 1
    fi

    if ! yq -e '.github_defaults.rulesets' "$POLICY_FILE" >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Policy file missing 'github_defaults.rulesets' section: $POLICY_FILE${NC}"
        exit 1
    fi
}

# Read a policy value with per-repo override falling back to github_defaults
gh_policy_value() {
    local repo="$1"
    local key="$2"
    local override_val
    override_val=$(yq -r ".github_repos.\"$repo\".$key" "$POLICY_FILE")
    if [ "$override_val" != "null" ] && [ -n "$override_val" ]; then
        echo "$override_val"
    else
        yq -r ".github_defaults.$key" "$POLICY_FILE"
    fi
}

# Read a policy array value (returns JSON array)
gh_policy_array() {
    local repo="$1"
    local key="$2"
    local override_val
    override_val=$(yq -oj ".github_repos.\"$repo\".$key" "$POLICY_FILE" 2>/dev/null)
    if [ "$override_val" != "null" ] && [ -n "$override_val" ]; then
        echo "$override_val"
    else
        yq -oj ".github_defaults.$key" "$POLICY_FILE"
    fi
}

# Read a ruleset rule scalar with per-repo override falling back to github_defaults.
# path is relative to the ruleset (e.g. "rules.required_status_checks.strict").
ruleset_value() {
    local repo="$1"
    local ruleset="$2"
    local path="$3"
    local override_val
    override_val=$(yq -r ".github_repos.\"$repo\".rulesets.\"$ruleset\".$path" "$POLICY_FILE" 2>/dev/null)
    if [ "$override_val" != "null" ] && [ -n "$override_val" ]; then
        echo "$override_val"
    else
        yq -r ".github_defaults.rulesets.\"$ruleset\".$path" "$POLICY_FILE"
    fi
}

# Read a ruleset rule value as JSON with per-repo override falling back to defaults.
# Returns "null" when the key is absent in both (callers treat that as "omit").
ruleset_json() {
    local repo="$1"
    local ruleset="$2"
    local path="$3"
    local override_val
    override_val=$(yq -oj ".github_repos.\"$repo\".rulesets.\"$ruleset\".$path" "$POLICY_FILE" 2>/dev/null)
    if [ "$override_val" != "null" ] && [ -n "$override_val" ]; then
        echo "$override_val"
    else
        yq -oj ".github_defaults.rulesets.\"$ruleset\".$path" "$POLICY_FILE" 2>/dev/null
    fi
}

# Build the expected ruleset payload from policy YAML.
# All rule values honor per-repo overrides (ruleset_value/ruleset_json) so a repo
# like .github can keep rebase-check + strict while kure/launcher use a merge queue.
build_ruleset_payload() {
    local repo="$1"
    local ruleset_name="$2"

    # Read status check contexts + strict (per-repo override -> default)
    local contexts strict
    contexts=$(ruleset_json "$repo" "$ruleset_name" "rules.required_status_checks.contexts")
    strict=$(ruleset_value "$repo" "$ruleset_name" "rules.required_status_checks.strict")

    # Read pull_request settings (per-repo override -> default)
    local pr_review_count pr_dismiss_stale pr_code_owner pr_last_push pr_thread_resolution
    pr_review_count=$(ruleset_value "$repo" "$ruleset_name" "rules.pull_request.required_approving_review_count")
    pr_dismiss_stale=$(ruleset_value "$repo" "$ruleset_name" "rules.pull_request.dismiss_stale_reviews_on_push")
    pr_code_owner=$(ruleset_value "$repo" "$ruleset_name" "rules.pull_request.require_code_owner_review")
    pr_last_push=$(ruleset_value "$repo" "$ruleset_name" "rules.pull_request.require_last_push_approval")
    pr_thread_resolution=$(ruleset_value "$repo" "$ruleset_name" "rules.pull_request.required_review_thread_resolution")

    # Read conditions (not overridden per repo)
    local conditions
    conditions=$(yq -oj ".github_defaults.rulesets.\"$ruleset_name\".conditions" "$POLICY_FILE")

    # Read per-repo bypass actors (if any)
    local bypass_actors="[]"
    local repo_bypass
    repo_bypass=$(yq -oj ".github_repos.\"$repo\".rulesets.\"$ruleset_name\".bypass_actors // []" "$POLICY_FILE" 2>/dev/null)
    if [ "$repo_bypass" != "null" ] && [ "$repo_bypass" != "[]" ]; then
        bypass_actors="$repo_bypass"
    fi

    # Optional merge_queue rule (per-repo override -> default). "null"/absent => omitted.
    # The YAML parameter keys map 1:1 to the rulesets API merge_queue parameters.
    local merge_queue
    merge_queue=$(ruleset_json "$repo" "$ruleset_name" "rules.merge_queue")

    # Build status checks array for the API
    local status_checks_api
    status_checks_api=$(echo "$contexts" | jq '[.[] | {"context": .}]')

    # Build the rules array (merge_queue appended below if present)
    local rules
    rules=$(jq -n \
        --argjson status_checks "$status_checks_api" \
        --argjson strict "$strict" \
        --argjson pr_review_count "$pr_review_count" \
        --argjson pr_dismiss_stale "$pr_dismiss_stale" \
        --argjson pr_code_owner "$pr_code_owner" \
        --argjson pr_last_push "$pr_last_push" \
        --argjson pr_thread_resolution "$pr_thread_resolution" \
        '[
            {"type": "deletion"},
            {"type": "non_fast_forward"},
            {"type": "required_linear_history"},
            {
                "type": "pull_request",
                "parameters": {
                    "required_approving_review_count": $pr_review_count,
                    "dismiss_stale_reviews_on_push": $pr_dismiss_stale,
                    "require_code_owner_review": $pr_code_owner,
                    "require_last_push_approval": $pr_last_push,
                    "required_review_thread_resolution": $pr_thread_resolution
                }
            },
            {
                "type": "required_status_checks",
                "parameters": {
                    "strict_required_status_checks_policy": $strict,
                    "required_status_checks": $status_checks
                }
            }
        ]')

    if [ "$merge_queue" != "null" ] && [ -n "$merge_queue" ]; then
        rules=$(echo "$rules" | jq --argjson mq "$merge_queue" \
            '. + [{"type": "merge_queue", "parameters": $mq}]')
    fi

    # Build the full payload
    jq -n \
        --arg name "$ruleset_name" \
        --argjson conditions "$conditions" \
        --argjson bypass_actors "$bypass_actors" \
        --argjson rules "$rules" \
        '{
            "name": $name,
            "target": "branch",
            "enforcement": "active",
            "conditions": {
                "ref_name": {
                    "include": $conditions.ref_name.include,
                    "exclude": ($conditions.ref_name.exclude // [])
                }
            },
            "bypass_actors": $bypass_actors,
            "rules": $rules
        }'
}

# Apply a ruleset via GitHub API (create or update)
apply_ruleset() {
    local repo="$1"
    local ruleset_name="$2"

    local payload
    payload=$(build_ruleset_payload "$repo" "$ruleset_name")

    # Check if ruleset already exists
    local existing_id
    existing_id=$(gh api "repos/$GITHUB_ORG/$repo/rulesets" --jq ".[] | select(.name == \"$ruleset_name\") | .id" 2>/dev/null)

    local api_err
    if [ -n "$existing_id" ]; then
        echo -e "  ${YELLOW}UPDATING${NC}: Ruleset '$ruleset_name' (id: $existing_id)"
        if api_err=$(gh api "repos/$GITHUB_ORG/$repo/rulesets/$existing_id" \
            --method PUT \
            --input - <<<"$payload" 2>&1 >/dev/null); then
            echo -e "  ${GREEN}APPLIED${NC}: Ruleset '$ruleset_name' updated"
        else
            # Surface the real API error (permissions, 422 validation, etc.) instead
            # of guessing — a swallowed error here once masked a payload bug.
            echo -e "  ${RED}FAILED${NC}: Could not update ruleset: ${api_err}"
        fi
    else
        echo -e "  ${YELLOW}CREATING${NC}: Ruleset '$ruleset_name'"
        if api_err=$(gh api "repos/$GITHUB_ORG/$repo/rulesets" \
            --method POST \
            --input - <<<"$payload" 2>&1 >/dev/null); then
            echo -e "  ${GREEN}APPLIED${NC}: Ruleset '$ruleset_name' created"
        else
            echo -e "  ${RED}FAILED${NC}: Could not create ruleset: ${api_err}"
        fi
    fi
}

# Remove classic branch protection if it still exists (migration)
remove_classic_branch_protection() {
    local repo="$1"

    if gh api "repos/$GITHUB_ORG/$repo/branches/main/protection" --silent 2>/dev/null; then
        echo -e "  ${YELLOW}MIGRATING${NC}: Removing classic branch protection (replaced by rulesets)"
        if gh api "repos/$GITHUB_ORG/$repo/branches/main/protection" \
            --method DELETE \
            --silent 2>/dev/null; then
            echo -e "  ${GREEN}REMOVED${NC}: Classic branch protection deleted"
        else
            echo -e "  ${RED}FAILED${NC}: Could not remove classic branch protection (requires admin access)"
        fi
    fi
}

# Build reverse rename map: standard name -> old name that might exist
build_reverse_rename_map() {
    declare -gA REVERSE_RENAME_MAP
    local old_name standard_name
    for old_name in "${!LABEL_RENAME_MAP[@]}"; do
        standard_name="${LABEL_RENAME_MAP[$old_name]}"
        REVERSE_RENAME_MAP["$standard_name"]="$old_name"
    done
}

# Get current labels for a repo
get_github_labels() {
    local repo="$1"
    gh api "repos/$GITHUB_ORG/$repo/labels" --paginate --jq '.[].name'
}

# Audit labels
audit_labels() {
    local repo="$1"
    local apply="$2"

    echo -e "\n${BLUE}=== Labels ===${NC}"

    local existing_labels
    existing_labels=$(get_github_labels "$repo")

    build_reverse_rename_map

    local labels
    labels=$(jq -c '.labels[]' "$LABELS_FILE")

    while IFS= read -r label; do
        local name color description
        name=$(echo "$label" | jq -r '.name')
        color=$(echo "$label" | jq -r '.color' | sed 's/^#//')
        description=$(echo "$label" | jq -r '.description')

        if echo "$existing_labels" | grep -qx "$name"; then
            echo -e "  ${GREEN}OK${NC}: $name"
            LABELS_OK=$((LABELS_OK + 1))
        else
            # Check if there's a rename candidate
            local old_name="${REVERSE_RENAME_MAP[$name]:-}"
            if [ -n "$old_name" ] && echo "$existing_labels" | grep -qx "$old_name"; then
                # Rename candidate exists
                LABELS_RENAMED=$((LABELS_RENAMED + 1))
                if [ "$apply" = "true" ]; then
                    echo -e "  ${YELLOW}RENAMING${NC}: $old_name -> $name"
                    gh api "repos/$GITHUB_ORG/$repo/labels/$old_name" \
                        --method PATCH \
                        -f new_name="$name" \
                        -f color="$color" \
                        -f description="$description" \
                        --silent
                else
                    echo -e "  ${YELLOW}RENAME${NC}: $old_name -> $name (use --apply to rename)"
                fi
            else
                # Truly missing, needs creation
                LABELS_MISSING=$((LABELS_MISSING + 1))
                if [ "$apply" = "true" ]; then
                    echo -e "  ${YELLOW}CREATING${NC}: $name"
                    gh api "repos/$GITHUB_ORG/$repo/labels" \
                        --method POST \
                        -f name="$name" \
                        -f color="$color" \
                        -f description="$description" \
                        --silent
                else
                    echo -e "  ${RED}MISSING${NC}: $name"
                fi
            fi
        fi
    done <<<"$labels"

    # Detect extra labels (in repo but not in standard, and not a rename candidate)
    while IFS= read -r existing_name; do
        [ -z "$existing_name" ] && continue
        # Skip rename candidates (handled by rename logic above)
        if [[ -v LABEL_RENAME_MAP["$existing_name"] ]]; then
            continue
        fi
        if ! jq -e --arg n "$existing_name" '.labels[] | select(.name == $n)' "$LABELS_FILE" > /dev/null 2>&1; then
            LABELS_EXTRA=$((LABELS_EXTRA + 1))
            if [ "$apply" = "true" ]; then
                local issue_count
                issue_count=$(gh issue list --repo "$GITHUB_ORG/$repo" \
                    --label "$existing_name" --state all --limit 1 \
                    --json number --jq 'length' 2>/dev/null || echo "unknown")
                if [ "$issue_count" != "0" ]; then
                    LABELS_BLOCKED=$((LABELS_BLOCKED + 1))
                    echo -e "  ${YELLOW}SKIP${NC}: $existing_name (in use — $issue_count issue(s), manual removal required)"
                else
                    echo -e "  ${YELLOW}DELETING${NC}: $existing_name"
                    local encoded_name
                    encoded_name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$existing_name")
                    gh api "repos/$GITHUB_ORG/$repo/labels/$encoded_name" --method DELETE --silent
                fi
            else
                echo -e "  ${RED}EXTRA${NC}: $existing_name"
            fi
        fi
    done <<<"$existing_labels"
}

# Audit repo settings
audit_repo_settings() {
    local repo="$1"
    local apply="$2"

    echo -e "\n${BLUE}=== Repository Settings ===${NC}"

    local settings
    settings=$(gh api "repos/$GITHUB_ORG/$repo")

    # Settings to check: policy key -> GitHub API field
    local -a setting_keys=(
        "allow_rebase_merge"
        "allow_squash_merge"
        "allow_merge_commit"
        "delete_branch_on_merge"
        "allow_update_branch"
        "has_wiki"
        "allow_auto_merge"
        "has_projects"
    )

    local fixes="{}"

    for key in "${setting_keys[@]}"; do
        local expected actual
        expected=$(gh_policy_value "$repo" "$key")
        actual=$(echo "$settings" | jq -r ".$key")

        if [ "$actual" = "$expected" ]; then
            echo -e "  ${GREEN}OK${NC}: $key = $expected"
            SETTINGS_OK=$((SETTINGS_OK + 1))
        else
            SETTINGS_MISSING=$((SETTINGS_MISSING + 1))
            if [ "$apply" = "true" ]; then
                echo -e "  ${YELLOW}SETTING${NC}: $key to $expected (was: $actual)"
                fixes=$(echo "$fixes" | jq --arg k "$key" --argjson v "$expected" '. + {($k): $v}')
            else
                echo -e "  ${RED}WRONG${NC}: $key = $actual (should be $expected)"
            fi
        fi
    done

    # Apply all setting fixes in one PATCH call
    if [ "$apply" = "true" ] && [ "$fixes" != "{}" ]; then
        gh api "repos/$GITHUB_ORG/$repo" \
            --method PATCH \
            --input - <<<"$fixes" \
            --silent
    fi
}

# Audit rulesets
audit_rulesets() {
    local repo="$1"
    local apply="$2"

    echo -e "\n${BLUE}=== Rulesets (main) ===${NC}"

    # Check for leftover classic branch protection
    if gh api "repos/$GITHUB_ORG/$repo/branches/main/protection" --silent 2>/dev/null; then
        RULESET_MISSING=$((RULESET_MISSING + 1))
        echo -e "  ${YELLOW}LEGACY${NC}: Classic branch protection still exists (should be replaced by rulesets)"
        if [ "$apply" = "true" ]; then
            remove_classic_branch_protection "$repo"
        fi
    fi

    # Get list of expected ruleset names from policy
    local ruleset_names
    ruleset_names=$(yq -r '.github_defaults.rulesets | keys | .[]' "$POLICY_FILE")

    # Get existing rulesets
    local existing_rulesets
    existing_rulesets=$(gh api "repos/$GITHUB_ORG/$repo/rulesets" 2>/dev/null || echo "[]")

    for ruleset_name in $ruleset_names; do
        local existing
        existing=$(echo "$existing_rulesets" | jq -r ".[] | select(.name == \"$ruleset_name\")")

        if [ -z "$existing" ]; then
            RULESET_MISSING=$((RULESET_MISSING + 1))
            echo -e "  ${RED}MISSING${NC}: Ruleset '$ruleset_name' not found"
            if [ "$apply" = "true" ]; then
                apply_ruleset "$repo" "$ruleset_name"
            fi
            continue
        fi

        local existing_id
        existing_id=$(echo "$existing" | jq -r '.id')

        echo -e "  ${GREEN}OK${NC}: Ruleset '$ruleset_name' exists (id: $existing_id)"
        RULESET_OK=$((RULESET_OK + 1))

        # Fetch full ruleset details (list endpoint doesn't include all fields)
        local full_ruleset
        full_ruleset=$(gh api "repos/$GITHUB_ORG/$repo/rulesets/$existing_id" 2>/dev/null)

        # Check enforcement
        local actual_enforcement
        actual_enforcement=$(echo "$full_ruleset" | jq -r '.enforcement')
        if [ "$actual_enforcement" = "active" ]; then
            echo -e "  ${GREEN}OK${NC}: Enforcement = active"
            RULESET_OK=$((RULESET_OK + 1))
        else
            RULESET_MISSING=$((RULESET_MISSING + 1))
            echo -e "  ${RED}WRONG${NC}: Enforcement = $actual_enforcement (should be active)"
        fi

        # Check required status checks (per-repo override -> default)
        local expected_contexts
        expected_contexts=$(ruleset_json "$repo" "$ruleset_name" "rules.required_status_checks.contexts")

        local actual_contexts
        actual_contexts=$(echo "$full_ruleset" | jq '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] // []')

        if [ "$(echo "$actual_contexts" | jq 'sort')" = "$(echo "$expected_contexts" | jq 'sort')" ]; then
            echo -e "  ${GREEN}OK${NC}: Required status checks match policy"
            RULESET_OK=$((RULESET_OK + 1))
        else
            RULESET_MISSING=$((RULESET_MISSING + 1))
            echo -e "  ${RED}WRONG${NC}: Status checks differ"
            echo -e "    Expected: $(echo "$expected_contexts" | jq -c 'sort')"
            echo -e "    Actual:   $(echo "$actual_contexts" | jq -c 'sort')"
        fi

        # Check strict policy (per-repo override -> default)
        local expected_strict actual_strict
        expected_strict=$(ruleset_value "$repo" "$ruleset_name" "rules.required_status_checks.strict")
        actual_strict=$(echo "$full_ruleset" | jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy')
        if [ "$actual_strict" = "$expected_strict" ]; then
            echo -e "  ${GREEN}OK${NC}: strict_required_status_checks_policy = $expected_strict"
            RULESET_OK=$((RULESET_OK + 1))
        else
            RULESET_MISSING=$((RULESET_MISSING + 1))
            echo -e "  ${RED}WRONG${NC}: strict = $actual_strict (should be $expected_strict)"
        fi

        # Expected rule types — merge_queue only when the repo's policy defines it
        local expected_merge_queue
        expected_merge_queue=$(ruleset_json "$repo" "$ruleset_name" "rules.merge_queue")
        local -a expected_rule_types=(deletion non_fast_forward required_linear_history pull_request required_status_checks)
        if [ "$expected_merge_queue" != "null" ] && [ -n "$expected_merge_queue" ]; then
            expected_rule_types+=(merge_queue)
        fi

        # Check rule types present
        local actual_rule_types
        actual_rule_types=$(echo "$full_ruleset" | jq '[.rules[].type] | sort')
        for rule_type in "${expected_rule_types[@]}"; do
            if echo "$actual_rule_types" | jq -e "index(\"$rule_type\")" >/dev/null 2>&1; then
                echo -e "  ${GREEN}OK${NC}: Rule '$rule_type' present"
                RULESET_OK=$((RULESET_OK + 1))
            else
                RULESET_MISSING=$((RULESET_MISSING + 1))
                echo -e "  ${RED}MISSING${NC}: Rule '$rule_type' not found"
            fi
        done

        # Flag any unexpected rule types (e.g. a merge_queue rule that slipped onto a
        # repo whose policy omits it) — present-only checks would miss this drift.
        local unexpected_rule_types
        unexpected_rule_types=$(echo "$actual_rule_types" | jq -c \
            --argjson expected "$(printf '%s\n' "${expected_rule_types[@]}" | jq -R . | jq -s 'sort')" \
            '. - $expected')
        if [ "$unexpected_rule_types" != "[]" ]; then
            RULESET_MISSING=$((RULESET_MISSING + 1))
            echo -e "  ${RED}WRONG${NC}: Unexpected rule(s) present (not in policy): $unexpected_rule_types"
        fi

        # Check pull_request rule parameters
        local pr_params
        pr_params=$(echo "$full_ruleset" | jq '.rules[] | select(.type == "pull_request") | .parameters')
        if [ -n "$pr_params" ] && [ "$pr_params" != "null" ]; then
            for param in required_approving_review_count dismiss_stale_reviews_on_push require_code_owner_review require_last_push_approval required_review_thread_resolution; do
                local expected_param actual_param
                expected_param=$(ruleset_value "$repo" "$ruleset_name" "rules.pull_request.$param")
                actual_param=$(echo "$pr_params" | jq -r ".$param")
                if [ "$actual_param" = "$expected_param" ]; then
                    echo -e "  ${GREEN}OK${NC}: pull_request.$param = $expected_param"
                    RULESET_OK=$((RULESET_OK + 1))
                else
                    RULESET_MISSING=$((RULESET_MISSING + 1))
                    echo -e "  ${RED}WRONG${NC}: pull_request.$param = $actual_param (should be $expected_param)"
                fi
            done
        fi

        # Check merge_queue parameters (only when the repo's policy defines a queue)
        if [ "$expected_merge_queue" != "null" ] && [ -n "$expected_merge_queue" ]; then
            local mq_params
            mq_params=$(echo "$full_ruleset" | jq '.rules[] | select(.type == "merge_queue") | .parameters')
            if [ -n "$mq_params" ] && [ "$mq_params" != "null" ]; then
                for param in merge_method grouping_strategy min_entries_to_merge max_entries_to_merge max_entries_to_build min_entries_to_merge_wait_minutes check_response_timeout_minutes; do
                    local expected_mq actual_mq
                    expected_mq=$(echo "$expected_merge_queue" | jq -r ".$param")
                    actual_mq=$(echo "$mq_params" | jq -r ".$param")
                    if [ "$actual_mq" = "$expected_mq" ]; then
                        echo -e "  ${GREEN}OK${NC}: merge_queue.$param = $expected_mq"
                        RULESET_OK=$((RULESET_OK + 1))
                    else
                        RULESET_MISSING=$((RULESET_MISSING + 1))
                        echo -e "  ${RED}WRONG${NC}: merge_queue.$param = $actual_mq (should be $expected_mq)"
                    fi
                done
            fi
        fi

        # Check bypass actors (per-repo)
        local expected_bypass
        expected_bypass=$(yq -oj ".github_repos.\"$repo\".rulesets.\"$ruleset_name\".bypass_actors // []" "$POLICY_FILE" 2>/dev/null)
        if [ "$expected_bypass" != "null" ] && [ "$expected_bypass" != "[]" ]; then
            local expected_bypass_ids
            expected_bypass_ids=$(echo "$expected_bypass" | jq '[.[].actor_id] | sort')
            local actual_bypass_ids
            actual_bypass_ids=$(echo "$full_ruleset" | jq '[.bypass_actors[].actor_id] | sort')

            if [ "$actual_bypass_ids" = "$expected_bypass_ids" ]; then
                echo -e "  ${GREEN}OK${NC}: Bypass actors match policy"
                RULESET_OK=$((RULESET_OK + 1))
            else
                RULESET_MISSING=$((RULESET_MISSING + 1))
                echo -e "  ${RED}WRONG${NC}: Bypass actors differ"
                echo -e "    Expected: $(echo "$expected_bypass_ids" | jq -c '.')"
                echo -e "    Actual:   $(echo "$actual_bypass_ids" | jq -c '.')"
            fi
        fi

        if [ "$apply" = "true" ] && [ $RULESET_MISSING -gt 0 ]; then
            apply_ruleset "$repo" "$ruleset_name"
        fi
    done
}

# Audit a single repository
audit_repo() {
    local repo="$1"
    local apply="$2"

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Repository: $GITHUB_ORG/$repo${NC}"
    echo -e "${BLUE}========================================${NC}"

    # Verify repo exists
    if ! gh api "repos/$GITHUB_ORG/$repo" --silent 2>/dev/null; then
        echo -e "${RED}ERROR: Could not access $GITHUB_ORG/$repo${NC}"
        if [ "$JSON_OUTPUT" = "true" ]; then
            json_results=$(echo "$json_results" | jq --arg r "$repo" \
                '. + [{"repo": $r, "status": "ERROR", "reason": "repo not accessible"}]')
        fi
        return 1
    fi

    # Save counters before audit
    local labels_missing_before=$LABELS_MISSING
    local labels_ok_before=$LABELS_OK
    local labels_renamed_before=$LABELS_RENAMED
    local labels_extra_before=$LABELS_EXTRA
    local labels_blocked_before=$LABELS_BLOCKED
    local settings_missing_before=$SETTINGS_MISSING
    local settings_ok_before=$SETTINGS_OK
    local ruleset_missing_before=$RULESET_MISSING
    local ruleset_ok_before=$RULESET_OK

    # Run audits
    audit_labels "$repo" "$apply"
    audit_repo_settings "$repo" "$apply"
    audit_rulesets "$repo" "$apply"

    # JSON output for this repo
    if [ "$JSON_OUTPUT" = "true" ]; then
        local repo_labels_missing=$((LABELS_MISSING - labels_missing_before))
        local repo_labels_ok=$((LABELS_OK - labels_ok_before))
        local repo_labels_renamed=$((LABELS_RENAMED - labels_renamed_before))
        local repo_labels_extra=$((LABELS_EXTRA - labels_extra_before))
        local repo_labels_blocked=$((LABELS_BLOCKED - labels_blocked_before))
        local repo_settings_missing=$((SETTINGS_MISSING - settings_missing_before))
        local repo_settings_ok=$((SETTINGS_OK - settings_ok_before))
        local repo_ruleset_missing=$((RULESET_MISSING - ruleset_missing_before))
        local repo_ruleset_ok=$((RULESET_OK - ruleset_ok_before))
        local repo_status="OK"
        if [ $((repo_labels_missing + repo_labels_renamed + repo_labels_extra + repo_settings_missing + repo_ruleset_missing)) -gt 0 ]; then
            repo_status="WARN"
        fi
        json_results=$(echo "$json_results" | jq \
            --arg r "$repo" \
            --argjson lm "$repo_labels_missing" \
            --argjson lo "$repo_labels_ok" \
            --argjson lr "$repo_labels_renamed" \
            --argjson le "$repo_labels_extra" \
            --argjson lb "$repo_labels_blocked" \
            --argjson sm "$repo_settings_missing" \
            --argjson so "$repo_settings_ok" \
            --argjson rm "$repo_ruleset_missing" \
            --argjson ro "$repo_ruleset_ok" \
            --arg st "$repo_status" \
            '. + [{"repo": $r, "labels_missing": $lm, "labels_ok": $lo, "labels_renamed": $lr, "labels_extra": $le, "labels_blocked": $lb, "settings_missing": $sm, "settings_ok": $so, "rulesets_missing": $rm, "rulesets_ok": $ro, "status": $st}]')
    fi

    return 0
}

# Print summary
print_summary() {
    local apply="${1:-false}"

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Summary${NC}"
    echo -e "${BLUE}========================================${NC}"

    local total_issues=$((LABELS_MISSING + LABELS_RENAMED + LABELS_EXTRA + SETTINGS_MISSING + RULESET_MISSING))

    if [ "$apply" = "true" ]; then
        echo -e "Labels: ${GREEN}$LABELS_OK OK${NC}, ${YELLOW}$LABELS_MISSING created${NC}, ${YELLOW}$LABELS_RENAMED renamed${NC}, ${YELLOW}$LABELS_EXTRA extra (${LABELS_BLOCKED} skipped, in use)${NC}"
        echo -e "Settings: ${GREEN}$SETTINGS_OK OK${NC}, ${YELLOW}$SETTINGS_MISSING applied${NC}"
        echo -e "Rulesets: ${GREEN}$RULESET_OK OK${NC}, ${YELLOW}$RULESET_MISSING issues${NC}"
    else
        echo -e "Labels: ${GREEN}$LABELS_OK OK${NC}, ${RED}$LABELS_MISSING missing${NC}, ${YELLOW}$LABELS_RENAMED to rename${NC}, ${RED}$LABELS_EXTRA extra${NC}"
        echo -e "Settings: ${GREEN}$SETTINGS_OK OK${NC}, ${RED}$SETTINGS_MISSING wrong${NC}"
        echo -e "Rulesets: ${GREEN}$RULESET_OK OK${NC}, ${RED}$RULESET_MISSING wrong${NC}"
    fi

    if [ "$JSON_OUTPUT" = "true" ]; then
        jq -n \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --argjson lo "$LABELS_OK" \
            --argjson lm "$LABELS_MISSING" \
            --argjson lr "$LABELS_RENAMED" \
            --argjson le "$LABELS_EXTRA" \
            --argjson lb "$LABELS_BLOCKED" \
            --argjson so "$SETTINGS_OK" \
            --argjson sm "$SETTINGS_MISSING" \
            --argjson ro "$RULESET_OK" \
            --argjson rm "$RULESET_MISSING" \
            --argjson repos "$json_results" \
            '{"generated": $ts, "labels_ok": $lo, "labels_missing": $lm, "labels_renamed": $lr, "labels_extra": $le, "labels_blocked": $lb, "settings_ok": $so, "settings_missing": $sm, "rulesets_ok": $ro, "rulesets_missing": $rm, "repos": $repos}' \
            > github-settings-report.json
        echo ""
        echo "JSON report: github-settings-report.json"
    fi

    if [ "$total_issues" -gt 0 ] && [ "$apply" != "true" ]; then
        echo ""
        echo "Run with --apply to fix issues"
        return 1
    fi

    return 0
}

# Main
main() {
    local repo=""
    local all_repos=false
    local apply=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)
                all_repos=true
                shift
                ;;
            --apply)
                apply=true
                shift
                ;;
            --ci)
                CI_MODE=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --help | -h)
                usage
                ;;
            *)
                if [ -z "$repo" ]; then
                    repo="$1"
                else
                    echo "Unknown argument: $1"
                    usage
                fi
                shift
                ;;
        esac
    done

    # Validate arguments
    if [ "$all_repos" = "false" ] && [ -z "$repo" ]; then
        usage
    fi

    setup_colors
    check_requirements

    if [ "$apply" = "true" ]; then
        echo -e "${YELLOW}Running in APPLY mode - changes will be made${NC}"
    else
        echo -e "${BLUE}Running in AUDIT mode (dry-run) - no changes will be made${NC}"
    fi

    # Run audits
    if [ "$all_repos" = "true" ]; then
        for r in ${GITHUB_REPOS:-}; do
            audit_repo "$r" "$apply" || true
        done
    else
        audit_repo "$repo" "$apply"
    fi

    print_summary "$apply"
}

main "$@"
