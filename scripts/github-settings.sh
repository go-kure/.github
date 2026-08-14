#!/bin/bash
# Audit and apply GitHub repository settings
# Usage: ./github-settings.sh <repo> [--apply] [--ci] [--json]
#        ./github-settings.sh --all [--apply] [--ci] [--json]
#        ./github-settings.sh <repo>|--all --import
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
#   ./github-settings.sh kure --import     # Dump kure's live settings as policy-shaped YAML
#   ./github-settings.sh --all --import > /tmp/live.yaml   # Dump all repos, then diff by hand
#                                                            # against governance/repository-settings-policy.yaml
#                                                            # to decide what to fold in as a default vs override

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHARF_DIR="$(dirname "$SCRIPT_DIR")"

# Default organization and repos (override via environment variables).
# GITHUB_REPOS_DEFAULT stays fixed even when GITHUB_REPOS is narrowed to a
# subset for a single run (e.g. GITHUB_REPOS=.github) — validate_policy uses
# it so a partial run doesn't misreport policy-known repos as unknown.
GITHUB_ORG="${GITHUB_ORG:-go-kure}"
GITHUB_REPOS_DEFAULT=".github kure launcher go-kure.github.io"
GITHUB_REPOS="${GITHUB_REPOS:-$GITHUB_REPOS_DEFAULT}"

LABELS_FILE="$WHARF_DIR/standards/labels.json"
POLICY_FILE="$WHARF_DIR/governance/repository-settings-policy.yaml"
CI_MODE=false
JSON_OUTPUT=false

# Whole policy file, loaded once as JSON in check_requirements(). All lookup
# helpers read this instead of re-invoking yq per key — yq's dot-path parser
# can't handle quoted keys containing spaces (e.g. a ruleset named "Code
# Quality Copilot review for default branch"), and re-spawning yq per lookup
# is slow across --all. jq --arg/getpath sidesteps both.
POLICY_JSON=""

# Cache for build_ruleset_import_jq() — assembled once from the rule
# registry below, reused across repos/rulesets in --import.
RULESET_IMPORT_JQ_CACHE=""

# Label rename mapping: GitHub default name -> standard name
# Used to detect drifted labels that should be renamed instead of created
declare -A LABEL_RENAME_MAP=(
    ["bug"]="type/bug"
    ["enhancement"]="type/feature"
)

# Top-level repo settings tracked by policy (audit_repo_settings + import_repo).
# Shared so --import emits the same key set the auditor checks. Existing keys
# stay first so audit-output diffs from adding new ones stay readable.
# Deliberately excluded: archived, private/visibility, disabled — flipping
# any of those is a different class of operation than a settings sync.
SETTING_KEYS=(
    "allow_rebase_merge"
    "allow_squash_merge"
    "allow_merge_commit"
    "delete_branch_on_merge"
    "allow_update_branch"
    "has_wiki"
    "allow_auto_merge"
    "has_projects"
    "has_issues"
    "has_discussions"
    "has_downloads"
    "is_template"
    "allow_forking"
    "web_commit_signoff_required"
    "merge_commit_title"
    "merge_commit_message"
    "squash_merge_commit_title"
    "squash_merge_commit_message"
)

# Organization-level settings tracked by policy (audit_org_settings + import_org).
# Only touched behind --org — every other invocation (--all, single-repo,
# settings.yml's daily run) never calls these paths and never needs
# admin:org. Deliberately excludes identity/billing fields (name,
# description, company, blog, location, email, twitter_username,
# billing_email) — those are content, not governance, and would make every
# audit noisy. Key names are verbatim from `gh api orgs/{org}`.
ORG_SETTING_KEYS=(
    "default_repository_permission"
    "members_can_create_repositories"
    "members_can_create_public_repositories"
    "members_can_create_private_repositories"
    "members_can_create_internal_repositories"
    "members_can_fork_private_repositories"
    "members_can_delete_repositories"
    "members_can_change_repo_visibility"
    "members_can_delete_issues"
    "members_can_invite_outside_collaborators"
    "members_can_create_pages"
    "members_can_create_public_pages"
    "members_can_create_private_pages"
    "members_can_create_teams"
    "has_organization_projects"
    "has_repository_projects"
    "readers_can_create_discussions"
    "members_can_view_dependency_insights"
    "display_commenter_full_name_setting_enabled"
    "deploy_keys_enabled_for_repositories"
    "web_commit_signoff_required"
    "dependabot_alerts_enabled_for_new_repositories"
    "dependabot_security_updates_enabled_for_new_repositories"
    "dependency_graph_enabled_for_new_repositories"
    "secret_scanning_enabled_for_new_repositories"
    "secret_scanning_push_protection_enabled_for_new_repositories"
    "secret_scanning_push_protection_custom_link_enabled"
    "secret_scanning_validity_checks_enabled"
)

# Readable via GET /orgs/{org} but not writable via PATCH /orgs/{org} — audited
# normally, but --apply skips them with a BLOCKED line instead of sending a
# PATCH that would error. two_factor_requirement_enabled is set via the
# org/enterprise UI; advanced_security_enabled_for_new_repositories is
# unavailable on the current (free) plan; default_repository_branch isn't in
# the PATCH schema; members_allowed_repository_creation_type is deprecated by
# GitHub in favor of the four granular members_can_create_* booleans above.
ORG_READONLY_KEYS=(
    "two_factor_requirement_enabled"
    "advanced_security_enabled_for_new_repositories"
    "default_repository_branch"
    "members_allowed_repository_creation_type"
)

# Organization Actions permissions, split across two endpoints (both PUT
# full-replace, so apply always sends every key, not just drifted ones).
ORG_ACTIONS_PERMISSIONS_KEYS=(
    "enabled_repositories"
    "allowed_actions"
    "sha_pinning_required"
)
ORG_ACTIONS_WORKFLOW_KEYS=(
    "default_workflow_permissions"
    "can_approve_pull_request_reviews"
)

# Rule-type registry. This is the single source of truth for which ruleset
# rule types this script understands — build_ruleset_payload (apply),
# ruleset_diff (audit + drift detection) and build_ruleset_import_jq
# (--import) all derive their expected rule list from RULE_TYPE_ORDER /
# RULE_KIND, so they cannot silently diverge from each other. A policy rule
# type missing from RULE_KIND is a validate_policy() startup error, not a
# silently-dropped field — GitHub's ruleset PUT is a full replace, so a
# dropped field on apply means a deleted rule, not a no-op.
RULE_TYPE_ORDER=(
    deletion
    non_fast_forward
    required_linear_history
    pull_request
    required_status_checks
    merge_queue
    copilot_code_review
)

# flag: no parameters, emitted as {"type": X} when the policy value is true.
# passthrough: policy params object maps 1:1 onto the API "parameters" object.
# transform: policy <-> API shapes differ; see RULE_TO_API_JQ/RULE_FROM_API_JQ.
declare -A RULE_KIND=(
    [deletion]=flag
    [non_fast_forward]=flag
    [required_linear_history]=flag
    [pull_request]=passthrough
    [required_status_checks]=transform
    [merge_queue]=passthrough
    [copilot_code_review]=passthrough
)

# policy rule params -> API "parameters" object. Types not listed here pass
# through unchanged ("."). Only required_status_checks needs a real remap:
# policy uses {strict, contexts}, the API uses
# {strict_required_status_checks_policy, required_status_checks: [{context}]}.
declare -A RULE_TO_API_JQ=(
    [required_status_checks]='{strict_required_status_checks_policy: .strict, required_status_checks: [.contexts[] | {context: .}]}'
)

# API "parameters" object -> policy rule params. Types not listed here pass
# through unchanged ("."). pull_request additionally drops dismissal_restriction
# and required_reviewers: the live API returns them, but they're read-shaped —
# pasting them back into policy and applying would risk a 422 on write.
declare -A RULE_FROM_API_JQ=(
    [required_status_checks]='{strict: .strict_required_status_checks_policy, contexts: [.required_status_checks[].context]}'
    [pull_request]='del(.dismissal_restriction, .required_reviewers)'
)

rule_kind() {
    echo "${RULE_KIND[$1]:-}"
}

rule_to_api_jq() {
    echo "${RULE_TO_API_JQ[$1]:-.}"
}

rule_from_api_jq() {
    echo "${RULE_FROM_API_JQ[$1]:-.}"
}

# Canonicalize a JSON value for comparison: sort every array (recursively),
# leave everything else untouched. Used wherever policy and live-API JSON
# need to compare equal regardless of array ordering (contexts, rule types,
# bypass actor ids, ...).
CANON_JQ='walk(if type == "array" then sort else . end)'

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
SETTINGS_BLOCKED=0
RULESET_MISSING=0
RULESET_OK=0

# JSON results
json_results="[]"
json_org_result="null"

usage() {
    echo "Usage: $0 <repo> [--apply] [--ci] [--json]"
    echo "       $0 --all [--apply] [--ci] [--json]"
    echo "       $0 <repo>|--all --import"
    echo "       $0 --org [--apply] [--ci] [--json]"
    echo "       $0 --org --import"
    echo ""
    echo "Options:"
    echo "  <repo>     Repository name (e.g., kure)"
    echo "  --all      Audit/apply/import all GitHub repos (\$GITHUB_REPOS)"
    echo "  --org      Audit/apply/import organization-level settings instead of a"
    echo "             repo. Requires a token with the admin:org scope. Mutually"
    echo "             exclusive with <repo> and --all — they are different scopes."
    echo "  --apply    Apply settings (default is dry-run/audit only)"
    echo "  --import   Print live settings as policy-shaped YAML instead of auditing"
    echo "             (never writes; diff the output against"
    echo "             governance/repository-settings-policy.yaml by hand). Mutually"
    echo "             exclusive with --apply."
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
    echo "  $0 kure --import           # Dump kure's live settings as policy-shaped YAML"
    echo "  $0 --all --import > /tmp/live.yaml   # Dump all repos, then diff by hand"
    echo "  $0 --org                   # Audit organization-level settings"
    echo "  $0 --org --apply           # Apply organization-level settings"
    echo "  $0 --org --import          # Dump org drift as policy-shaped YAML"
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

    POLICY_JSON=$(yq -oj '.' "$POLICY_FILE")

    validate_policy
}

# --org preflight. GET /orgs/{org}/actions/permissions requires admin:org —
# GET /orgs/{org} alone only needs read:org and would succeed even without
# it, so probing that endpoint here gives a named cause up front instead of
# a bare 403 three layers down inside audit_org_actions. Only called when
# --org is passed; no other code path needs admin:org or calls this.
require_org_scope() {
    if ! gh api "orgs/$GITHUB_ORG/actions/permissions" --silent 2>/dev/null; then
        echo -e "${RED}ERROR: --org requires a token with the admin:org scope${NC}"
        echo "  Run: gh auth refresh -h github.com -s admin:org"
        exit 1
    fi
}

# Sanity-check the policy file against what this script actually knows how
# to manage. Run once at startup so a bad policy fails loudly here instead
# of silently mis-auditing or (worse) deleting a rule on --apply.
validate_policy() {
    local errors=0

    # 1. Every rule type declared anywhere in policy (defaults or any repo
    #    override) must be a known registry type. This is the check that
    #    prevents the silent-drop-then-delete failure this script used to
    #    have: an unmodeled rule type used to just vanish from the payload
    #    on the next --apply.
    local declared_types
    declared_types=$(jq -r '
        [
            (.github_defaults.rulesets // {} | to_entries[] | .value.rules // {} | keys[]),
            ((.github_repos // {}) | to_entries[] | .value.rulesets // {} | to_entries[] | .value.rules // {} | keys[])
        ] | unique | .[]
    ' <<<"$POLICY_JSON")
    local t
    while IFS= read -r t; do
        [ -z "$t" ] && continue
        if [ -z "$(rule_kind "$t")" ]; then
            echo -e "${RED}ERROR: policy declares rule type '$t' this script does not model (see RULE_KIND in $0)${NC}"
            errors=$((errors + 1))
        fi
    done <<<"$declared_types"

    # 2. SETTING_KEYS and github_defaults' scalar keys must agree in both
    #    directions — a key in one but not the other is either dead code or
    #    an unmanaged live setting silently omitted from the audit.
    local policy_scalar_keys setting_keys_sorted
    policy_scalar_keys=$(jq -r '
        .github_defaults
        | to_entries
        | map(select((.value | type) != "object" and (.value | type) != "array"))
        | .[].key
    ' <<<"$POLICY_JSON" | sort)
    setting_keys_sorted=$(printf '%s\n' "${SETTING_KEYS[@]}" | sort)
    if [ "$policy_scalar_keys" != "$setting_keys_sorted" ]; then
        echo -e "${RED}ERROR: SETTING_KEYS and github_defaults scalar keys disagree${NC}"
        echo "  SETTING_KEYS only:"
        comm -23 <(echo "$setting_keys_sorted") <(echo "$policy_scalar_keys") | sed 's/^/    /'
        echo "  github_defaults only:"
        comm -13 <(echo "$setting_keys_sorted") <(echo "$policy_scalar_keys") | sed 's/^/    /'
        errors=$((errors + 1))
    fi

    # 3. Enum sanity on every declared ruleset's enforcement/target.
    local bad_enforcement bad_target
    bad_enforcement=$(jq -r '
        [
            (.github_defaults.rulesets // {} | to_entries[] | select(.value.enforcement != null and (.value.enforcement | IN("active","evaluate","disabled") | not)) | .key),
            ((.github_repos // {}) | to_entries[] | .value.rulesets // {} | to_entries[] | select(.value.enforcement != null and (.value.enforcement | IN("active","evaluate","disabled") | not)) | .key)
        ] | unique | .[]
    ' <<<"$POLICY_JSON")
    if [ -n "$bad_enforcement" ]; then
        echo -e "${RED}ERROR: ruleset(s) with invalid enforcement (must be active/evaluate/disabled): $bad_enforcement${NC}"
        errors=$((errors + 1))
    fi
    bad_target=$(jq -r '
        [
            (.github_defaults.rulesets // {} | to_entries[] | select(.value.target != null and (.value.target | IN("branch","tag","push") | not)) | .key),
            ((.github_repos // {}) | to_entries[] | .value.rulesets // {} | to_entries[] | select(.value.target != null and (.value.target | IN("branch","tag","push") | not)) | .key)
        ] | unique | .[]
    ' <<<"$POLICY_JSON")
    if [ -n "$bad_target" ]; then
        echo -e "${RED}ERROR: ruleset(s) with invalid target (must be branch/tag/push): $bad_target${NC}"
        errors=$((errors + 1))
    fi

    # 4. Every repos: scope entry must be a repo this script actually knows
    #    about — catches a typo that would silently disable a ruleset everywhere.
    #    Validated against GITHUB_REPOS_DEFAULT unioned with the runtime
    #    GITHUB_REPOS, not GITHUB_REPOS alone: GITHUB_REPOS is documented as
    #    selecting a subset (e.g. only .github) or a fork's repo set for a
    #    single run, and a subset run must not read policy repos it simply
    #    isn't targeting this time as unknown.
    local bad_scope_repos repo_list_json
    # shellcheck disable=SC2086 # intentional word-splitting: these are
    # space-separated lists and unquoted expansion is what turns them into
    # one printf argument (one line) per repo name — quoting would pass each
    # as a single argument and produce one JSON array element for the whole string.
    repo_list_json=$(printf '%s\n' ${GITHUB_REPOS_DEFAULT:-} ${GITHUB_REPOS:-} | jq -R . | jq -s 'unique')
    bad_scope_repos=$(jq -r --argjson known "$repo_list_json" '
        [.github_defaults.rulesets // {} | to_entries[] | select(.value.repos != null) | .value.repos[] | select(. as $r | $known | index($r) | not)] | unique | .[]
    ' <<<"$POLICY_JSON")
    if [ -n "$bad_scope_repos" ]; then
        echo -e "${RED}ERROR: ruleset repos: scope references unknown repo(s): $bad_scope_repos${NC}"
        errors=$((errors + 1))
    fi

    # 5-6 only apply once a policy declares github_org: — skipped entirely
    # when absent, so the policy file stays valid mid-migration (before the
    # first --org --import) and for anyone who never uses --org.
    if jq -e '.github_org != null' <<<"$POLICY_JSON" >/dev/null; then
        # 5. ORG_SETTING_KEYS + ORG_READONLY_KEYS and github_org's scalar keys
        #    must agree in both directions — same reasoning as check 2, applied
        #    to the org tier (which has no override, so there's only one set to
        #    compare against).
        local org_scalar_keys org_setting_keys_sorted
        org_scalar_keys=$(jq -r '
            .github_org
            | to_entries
            | map(select((.value | type) != "object" and (.value | type) != "array"))
            | .[].key
        ' <<<"$POLICY_JSON" | sort)
        org_setting_keys_sorted=$(printf '%s\n' "${ORG_SETTING_KEYS[@]}" "${ORG_READONLY_KEYS[@]}" | sort)
        if [ "$org_scalar_keys" != "$org_setting_keys_sorted" ]; then
            echo -e "${RED}ERROR: ORG_SETTING_KEYS+ORG_READONLY_KEYS and github_org scalar keys disagree${NC}"
            echo "  ORG_SETTING_KEYS/ORG_READONLY_KEYS only:"
            comm -23 <(echo "$org_setting_keys_sorted") <(echo "$org_scalar_keys") | sed 's/^/    /'
            echo "  github_org only:"
            comm -13 <(echo "$org_setting_keys_sorted") <(echo "$org_scalar_keys") | sed 's/^/    /'
            errors=$((errors + 1))
        fi

        # 6. Enum sanity on github_org.actions. `.[]` unwraps the array to one
        #    line per bad key (or zero lines) — a bare `-r` on an array would
        #    print the literal text "[]" even when empty, which is a
        #    non-empty bash string and would always trip the check below.
        local bad_actions_enum
        bad_actions_enum=$(jq -r '
            [
                (.github_org.actions.enabled_repositories // "all" | select(IN("all","none","selected") | not) | "enabled_repositories"),
                (.github_org.actions.allowed_actions // "all" | select(IN("all","local_only","selected") | not) | "allowed_actions"),
                (.github_org.actions.default_workflow_permissions // "read" | select(IN("read","write") | not) | "default_workflow_permissions")
            ] | .[]
        ' <<<"$POLICY_JSON")
        if [ -n "$bad_actions_enum" ]; then
            echo -e "${RED}ERROR: github_org.actions has invalid enum value(s) for: $bad_actions_enum${NC}"
            errors=$((errors + 1))
        fi
    fi

    if [ "$errors" -gt 0 ]; then
        exit 1
    fi
}

# Read a policy value with per-repo override falling back to github_defaults.
# key may be dotted (e.g. "security.dependabot_security_updates") for nested
# lookups. Prints the literal text "null" when absent in both, matching the
# old yq -r behavior callers already guard against with [ "$val" != "null" ].
gh_policy_value() {
    local repo="$1"
    local key="$2"
    jq -r --arg repo "$repo" --arg key "$key" '
        ($key | split(".")) as $path
        | (.github_repos[$repo] // {} | getpath($path)) as $o
        | if $o != null then $o else (.github_defaults | getpath($path)) end
    ' <<<"$POLICY_JSON"
}

# Same override -> default resolution as gh_policy_value, but returns
# compact JSON instead of a raw/unquoted scalar. Use this (not
# gh_policy_value) wherever the result feeds `jq --argjson` — a raw string
# value like PR_TITLE isn't valid JSON on its own and --argjson rejects it.
gh_policy_json() {
    local repo="$1"
    local key="$2"
    jq -c --arg repo "$repo" --arg key "$key" '
        ($key | split(".")) as $path
        | (.github_repos[$repo] // {} | getpath($path)) as $o
        | if $o != null then $o else (.github_defaults | getpath($path)) end
    ' <<<"$POLICY_JSON"
}

# Read a policy array value (returns JSON array). Kept for interface parity;
# identical resolution to gh_policy_json.
gh_policy_array() {
    gh_policy_json "$1" "$2"
}

# Read a value from github_org, JSON-encoded. No override tier — an
# organization has no per-repo variants — so this reads .github_org directly
# rather than resolving repo-override-then-default like gh_policy_json does.
# key may be dotted (e.g. "actions.default_workflow_permissions"). getpath
# already returns null on a missing path, so no `// null` fallback is
# needed here — and none is used deliberately: `//` treats jq `false` as
# falsy too, so a fallback would silently turn every false-valued key into
# null (the exact bug ruleset_applies' `// "ALL"` sentinel comment already
# warns about elsewhere in this file).
org_policy_json() {
    local key="$1"
    jq -c --arg key "$key" '
        ($key | split(".")) as $path
        | (.github_org // {}) | getpath($path)
    ' <<<"$POLICY_JSON"
}

# Read a ruleset rule scalar with per-repo override falling back to
# github_defaults. path is relative to the ruleset (e.g.
# "rules.required_status_checks.strict"). ruleset name is passed as --arg,
# not interpolated into the jq program, so names containing spaces work.
ruleset_value() {
    local repo="$1"
    local ruleset="$2"
    local path="$3"
    jq -r --arg repo "$repo" --arg ruleset "$ruleset" --arg path "$path" '
        ($path | split(".")) as $p
        | (.github_repos[$repo].rulesets[$ruleset] // {} | getpath($p)) as $o
        | if $o != null then $o else (.github_defaults.rulesets[$ruleset] | getpath($p)) end
    ' <<<"$POLICY_JSON"
}

# Read a ruleset rule value as JSON with per-repo override falling back to
# defaults. Returns "null" when the key is absent in both (callers treat
# that as "omit").
ruleset_json() {
    local repo="$1"
    local ruleset="$2"
    local path="$3"
    jq -c --arg repo "$repo" --arg ruleset "$ruleset" --arg path "$path" '
        ($path | split(".")) as $p
        | (.github_repos[$repo].rulesets[$ruleset] // {} | getpath($p)) as $o
        | if $o != null then $o else (.github_defaults.rulesets[$ruleset] | getpath($p)) end
    ' <<<"$POLICY_JSON"
}

# All ruleset names declared in policy, one per line — safe to mapfile even
# when a name contains spaces. Union of github_defaults.rulesets keys and
# every github_repos.<repo>.rulesets key: a ruleset can also exist as a
# repo-only override with no github_defaults counterpart (e.g. an --import
# dump of an unmanaged live ruleset pasted straight under
# github_repos.<repo>.rulesets), and ruleset_applies() below treats that case
# as scoped to just the repo(s) that declare it.
ruleset_names() {
    jq -r '
        [(.github_defaults.rulesets // {} | keys[]),
         ((.github_repos // {}) | to_entries[] | .value.rulesets // {} | keys[])]
        | flatten | unique[]
    ' <<<"$POLICY_JSON"
}

# Names present in `applicable` (JSON array) but absent from `existing`
# (JSON array) — pulled out of import_repo as a pure set-difference so the
# "policy ruleset deleted live" detection is unit-testable without a `gh
# api` call.
ruleset_names_missing() {
    local applicable_json="$1"
    local existing_json="$2"
    jq -c --argjson e "$existing_json" '. - $e' <<<"$applicable_json"
}

# Bash array elements -> JSON array of strings, zero-element-safe.
# `printf '%s\n' "${arr[@]}"` on an empty array still emits one blank line
# (bash reuses the format string once even with zero args), which
# `jq -R . | jq -s .` would then turn into `[""]` instead of `[]` — a real
# bug caught by review on the first version of this helper's call sites,
# where a repo with zero applicable/zero live rulesets fed a spurious ""
# into ruleset_names_missing.
bash_array_to_json() {
    if [ "$#" -eq 0 ]; then
        echo "[]"
    else
        printf '%s\n' "$@" | jq -R . | jq -sc .
    fi
}

# Does ruleset `name` apply to `repo`? When `name` is declared in
# github_defaults: a ruleset with no "repos" field applies everywhere; one
# with "repos: [...]" only applies to listed repos (mirrors the existing
# label-scoping pattern in standards/labels.json). An explicit empty list
# means "applies nowhere" — deliberately distinguished from "field absent"
# via the `// "ALL"` sentinel (`//` treats [] as truthy). When `name` has no
# github_defaults entry at all, it's a repo-only ruleset — it applies only to
# the repo(s) whose github_repos.<repo>.rulesets block defines it directly.
ruleset_applies() {
    local repo="$1"
    local name="$2"
    jq -e --arg repo "$repo" --arg name "$name" '
        if (.github_defaults.rulesets[$name]) != null then
            (.github_defaults.rulesets[$name].repos // "ALL") as $scope
            | if $scope == "ALL" then true else ($scope | index($repo) != null) end
        else
            (.github_repos[$repo].rulesets[$name]) != null
        end
    ' <<<"$POLICY_JSON" >/dev/null
}

# Read a top-level ruleset field (target/enforcement) with per-repo override
# falling back to default, falling back to `default_val` if declared nowhere.
ruleset_field() {
    local repo="$1"
    local name="$2"
    local field="$3"
    local default_val="$4"
    jq -r --arg repo "$repo" --arg name "$name" --arg field "$field" --arg default "$default_val" '
        (.github_repos[$repo].rulesets[$name][$field]) as $o
        | if $o != null then $o
          elif (.github_defaults.rulesets[$name][$field]) != null then .github_defaults.rulesets[$name][$field]
          else $default end
    ' <<<"$POLICY_JSON"
}

# The merged `rules:` object for this repo+ruleset: github_defaults deep-
# merged with the repo override (repo values win, `*` merges maps
# recursively and replaces arrays wholesale — same semantics the old
# per-leaf ruleset_value/ruleset_json calls had).
ruleset_rules_json() {
    local repo="$1"
    local name="$2"
    jq -c --arg repo "$repo" --arg name "$name" '
        (.github_defaults.rulesets[$name].rules // {}) as $d
        | (.github_repos[$repo].rulesets[$name].rules // {}) as $o
        | $d * $o
    ' <<<"$POLICY_JSON"
}

# Conditions are not currently overridden per repo in practice, but are
# resolvable per repo (a repo override wins wholesale over the default).
ruleset_conditions_json() {
    local repo="$1"
    local name="$2"
    jq -c --arg repo "$repo" --arg name "$name" '
        (.github_repos[$repo].rulesets[$name].conditions) as $o
        | (if $o != null then $o else .github_defaults.rulesets[$name].conditions end) as $c
        | {ref_name: {include: ($c.ref_name.include // []), exclude: ($c.ref_name.exclude // [])}}
    ' <<<"$POLICY_JSON"
}

# Bypass actors are per-repo only — github_defaults never declares them.
ruleset_bypass_json() {
    local repo="$1"
    local name="$2"
    jq -c --arg repo "$repo" --arg name "$name" '
        .github_repos[$repo].rulesets[$name].bypass_actors // []
    ' <<<"$POLICY_JSON"
}

# Rule types this repo's policy expects to be present on `name`, in
# RULE_TYPE_ORDER, one per line. flag types are included only when true;
# passthrough/transform types are included only when their params object is
# present (non-null) in the merged rules.
expected_rule_types() {
    local repo="$1"
    local name="$2"
    local rules_json
    rules_json=$(ruleset_rules_json "$repo" "$name")

    local t
    for t in "${RULE_TYPE_ORDER[@]}"; do
        case "$(rule_kind "$t")" in
            flag)
                jq -e --arg t "$t" '(.[$t] // false) == true' <<<"$rules_json" >/dev/null && echo "$t"
                ;;
            passthrough | transform)
                jq -e --arg t "$t" '.[$t] != null' <<<"$rules_json" >/dev/null && echo "$t"
                ;;
        esac
    done
}

# Build the expected ruleset payload from policy YAML, driven entirely by
# the rule registry — adding a new rule type means adding a RULE_KIND entry,
# not editing this function.
build_ruleset_payload() {
    local repo="$1"
    local ruleset_name="$2"

    local target enforcement conditions bypass_actors rules_json
    target=$(ruleset_field "$repo" "$ruleset_name" target branch)
    enforcement=$(ruleset_field "$repo" "$ruleset_name" enforcement active)
    conditions=$(ruleset_conditions_json "$repo" "$ruleset_name")
    bypass_actors=$(ruleset_bypass_json "$repo" "$ruleset_name")
    rules_json=$(ruleset_rules_json "$repo" "$ruleset_name")

    local rules="[]"
    local t
    while IFS= read -r t; do
        [ -z "$t" ] && continue
        if [ "$(rule_kind "$t")" = "flag" ]; then
            rules=$(jq --arg t "$t" '. + [{"type": $t}]' <<<"$rules")
        else
            local params
            params=$(jq -c --arg t "$t" '.[$t]' <<<"$rules_json" | jq -c "$(rule_to_api_jq "$t")")
            rules=$(jq --arg t "$t" --argjson p "$params" '. + [{"type": $t, "parameters": $p}]' <<<"$rules")
        fi
    done < <(expected_rule_types "$repo" "$ruleset_name")

    jq -n \
        --arg name "$ruleset_name" \
        --arg target "$target" \
        --arg enforcement "$enforcement" \
        --argjson conditions "$conditions" \
        --argjson bypass_actors "$bypass_actors" \
        --argjson rules "$rules" \
        '{
            name: $name,
            target: $target,
            enforcement: $enforcement,
            conditions: $conditions,
            bypass_actors: $bypass_actors,
            rules: $rules
        }'
}

# Apply a ruleset via GitHub API (create or update)
apply_ruleset() {
    local repo="$1"
    local ruleset_name="$2"

    local payload
    payload=$(build_ruleset_payload "$repo" "$ruleset_name")

    # Check if ruleset already exists. includes_parents=false so an
    # org-inherited ruleset of the same name can't yield an id that 404s on
    # the PUT below.
    local existing_id
    existing_id=$(gh api "repos/$GITHUB_ORG/$repo/rulesets?includes_parents=false" 2>/dev/null \
        | jq -r --arg n "$ruleset_name" '.[] | select(.name == $n) | .id')

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

    echo -e "\n${BLUE}=== Labels: $GITHUB_ORG/$repo ===${NC}"

    local existing_labels
    existing_labels=$(get_github_labels "$repo")

    build_reverse_rename_map

    local labels
    labels=$(jq -c '.labels[]' "$LABELS_FILE")

    while IFS= read -r label; do
        local name color description applies
        name=$(echo "$label" | jq -r '.name')
        color=$(echo "$label" | jq -r '.color' | sed 's/^#//')
        description=$(echo "$label" | jq -r '.description')

        # Repo-scoped labels (optional "repos" array) only apply to listed repos.
        # A label with no "repos" field applies to every repo.
        applies=$(echo "$label" | jq -r --arg r "$repo" 'if (.repos // null) == null then true else (.repos | index($r) != null) end')
        if [ "$applies" != "true" ]; then
            continue
        fi

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
        # A label is "expected" on this repo when it is in the standard AND either
        # has no "repos" scope or lists this repo. Anything else is extra.
        if ! jq -e --arg n "$existing_name" --arg r "$repo" '.labels[] | select(.name == $n) | select((.repos // null) == null or (.repos | index($r) != null))' "$LABELS_FILE" > /dev/null 2>&1; then
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

    echo -e "\n${BLUE}=== Repository Settings: $GITHUB_ORG/$repo ===${NC}"

    local settings
    settings=$(gh api "repos/$GITHUB_ORG/$repo")

    local fixes="{}"

    for key in "${SETTING_KEYS[@]}"; do
        # Compare JSON-encoded forms on both sides so this works uniformly
        # for booleans and strings (a raw/JSON mismatch here would falsely
        # report drift on every string-valued setting).
        local expected_json actual_json
        expected_json=$(gh_policy_json "$repo" "$key")
        actual_json=$(jq -c ".$key" <<<"$settings")

        if [ "$actual_json" = "$expected_json" ]; then
            echo -e "  ${GREEN}OK${NC}: $key = $(jq -r '.' <<<"$expected_json")"
            SETTINGS_OK=$((SETTINGS_OK + 1))
        else
            SETTINGS_MISSING=$((SETTINGS_MISSING + 1))
            if [ "$apply" = "true" ]; then
                echo -e "  ${YELLOW}SETTING${NC}: $key to $(jq -r '.' <<<"$expected_json") (was: $(jq -r '.' <<<"$actual_json"))"
                fixes=$(jq --arg k "$key" --argjson v "$expected_json" '. + {($k): $v}' <<<"$fixes")
            else
                echo -e "  ${RED}WRONG${NC}: $key = $(jq -r '.' <<<"$actual_json") (should be $(jq -r '.' <<<"$expected_json"))"
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

# Audit security_and_analysis settings. secret_scanning and
# secret_scanning_push_protection live under a nested security_and_analysis.<key>.status
# object in both the GET response and the PATCH body ("enabled"/"disabled" strings, not
# top-level booleans), so they can't share audit_repo_settings' setting_keys loop — that
# loop reads/writes top-level boolean fields. dependabot_security_updates is readable
# under the same GET nested object, but the PATCH /repos/{owner}/{repo} request schema
# does not list it as a writable security_and_analysis sub-field — it's toggled via the
# dedicated PUT/DELETE .../automated-security-fixes endpoint instead.
audit_security_settings() {
    local repo="$1"
    local apply="$2"

    echo -e "\n${BLUE}=== Security: $GITHUB_ORG/$repo ===${NC}"

    local settings
    settings=$(gh api "repos/$GITHUB_ORG/$repo")

    local -a patch_keys=(
        "secret_scanning"
        "secret_scanning_push_protection"
    )

    local fixes="{}"

    for key in "${patch_keys[@]}"; do
        local expected actual
        expected=$(gh_policy_value "$repo" "security.$key")
        [ "$expected" = "null" ] && continue # not declared in policy — skip, don't report as drift
        actual=$(echo "$settings" | jq -r ".security_and_analysis.$key.status // \"disabled\"")

        if [ "$actual" = "$expected" ]; then
            echo -e "  ${GREEN}OK${NC}: security.$key = $expected"
            SETTINGS_OK=$((SETTINGS_OK + 1))
        else
            SETTINGS_MISSING=$((SETTINGS_MISSING + 1))
            if [ "$apply" = "true" ]; then
                echo -e "  ${YELLOW}SETTING${NC}: security.$key to $expected (was: $actual)"
                fixes=$(echo "$fixes" | jq --arg k "$key" --arg v "$expected" '. + {($k): {"status": $v}}')
            else
                echo -e "  ${RED}WRONG${NC}: security.$key = $actual (should be $expected)"
            fi
        fi
    done

    if [ "$apply" = "true" ] && [ "$fixes" != "{}" ]; then
        gh api "repos/$GITHUB_ORG/$repo" \
            --method PATCH \
            --input - <<<"$(jq -n --argjson f "$fixes" '{security_and_analysis: $f}')" \
            --silent
    fi

    local expected_dsu actual_dsu
    expected_dsu=$(gh_policy_value "$repo" "security.dependabot_security_updates")
    if [ "$expected_dsu" != "null" ]; then
        actual_dsu=$(echo "$settings" | jq -r '.security_and_analysis.dependabot_security_updates.status // "disabled"')
        if [ "$actual_dsu" = "$expected_dsu" ]; then
            echo -e "  ${GREEN}OK${NC}: security.dependabot_security_updates = $expected_dsu"
            SETTINGS_OK=$((SETTINGS_OK + 1))
        else
            SETTINGS_MISSING=$((SETTINGS_MISSING + 1))
            if [ "$apply" = "true" ]; then
                echo -e "  ${YELLOW}SETTING${NC}: security.dependabot_security_updates to $expected_dsu (was: $actual_dsu)"
                if [ "$expected_dsu" = "enabled" ]; then
                    gh api "repos/$GITHUB_ORG/$repo/automated-security-fixes" --method PUT --silent
                else
                    gh api "repos/$GITHUB_ORG/$repo/automated-security-fixes" --method DELETE --silent
                fi
            else
                echo -e "  ${RED}WRONG${NC}: security.dependabot_security_updates = $actual_dsu (should be $expected_dsu)"
            fi
        fi
    fi
}

# Audit organization-level scalar settings (ORG_SETTING_KEYS + ORG_READONLY_KEYS
# against GET/PATCH /orgs/{org}). Structurally a copy of audit_repo_settings,
# but reading policy straight from org_policy_json — there's no per-repo
# override tier to resolve at this scope. Only called from --org; every other
# code path never reaches here and never needs admin:org.
audit_org_settings() {
    local apply="$1"

    echo -e "\n${BLUE}=== Organization Settings: $GITHUB_ORG ===${NC}"

    local settings
    settings=$(gh api "orgs/$GITHUB_ORG")

    local fixes="{}"

    local key
    for key in "${ORG_SETTING_KEYS[@]}"; do
        local expected_json actual_json
        expected_json=$(org_policy_json "$key")
        actual_json=$(jq -c ".$key" <<<"$settings")

        if [ "$actual_json" = "$expected_json" ]; then
            echo -e "  ${GREEN}OK${NC}: $key = $(jq -r '.' <<<"$expected_json")"
            SETTINGS_OK=$((SETTINGS_OK + 1))
        else
            SETTINGS_MISSING=$((SETTINGS_MISSING + 1))
            if [ "$apply" = "true" ]; then
                echo -e "  ${YELLOW}SETTING${NC}: $key to $(jq -r '.' <<<"$expected_json") (was: $(jq -r '.' <<<"$actual_json"))"
                fixes=$(jq --arg k "$key" --argjson v "$expected_json" '. + {($k): $v}' <<<"$fixes")
            else
                echo -e "  ${RED}WRONG${NC}: $key = $(jq -r '.' <<<"$actual_json") (should be $(jq -r '.' <<<"$expected_json"))"
            fi
        fi
    done

    for key in "${ORG_READONLY_KEYS[@]}"; do
        local expected_json actual_json
        expected_json=$(org_policy_json "$key")
        actual_json=$(jq -c ".$key" <<<"$settings")

        if [ "$actual_json" = "$expected_json" ]; then
            echo -e "  ${GREEN}OK${NC}: $key = $(jq -r '.' <<<"$expected_json") (audit-only)"
            SETTINGS_OK=$((SETTINGS_OK + 1))
        else
            # Tracked separately from SETTINGS_MISSING: this drift is
            # audit-only and can never be resolved by --apply, so counting it
            # under SETTINGS_MISSING would let print_summary's --apply branch
            # report it as "applied" even though nothing changed.
            SETTINGS_BLOCKED=$((SETTINGS_BLOCKED + 1))
            if [ "$apply" = "true" ]; then
                echo -e "  ${YELLOW}BLOCKED${NC}: $key is audit-only (not writable via PATCH /orgs) — live: $(jq -r '.' <<<"$actual_json"), policy: $(jq -r '.' <<<"$expected_json")"
            else
                echo -e "  ${RED}WRONG${NC}: $key = $(jq -r '.' <<<"$actual_json") (should be $(jq -r '.' <<<"$expected_json"), but audit-only — can't be applied)"
            fi
        fi
    done

    if [ "$apply" = "true" ] && [ "$fixes" != "{}" ]; then
        gh api "orgs/$GITHUB_ORG" \
            --method PATCH \
            --input - <<<"$fixes" \
            --silent
    fi
}

# Audit organization-wide Actions permissions, two flat objects on two PUT
# full-replace endpoints. Both PUTs always send every governed key, not just
# the drifted ones — a partial PUT to either endpoint would reset the
# unlisted fields to GitHub's default, not leave them alone.
audit_org_actions() {
    local apply="$1"

    echo -e "\n${BLUE}=== Organization Actions Permissions: $GITHUB_ORG ===${NC}"

    local perms workflow
    perms=$(gh api "orgs/$GITHUB_ORG/actions/permissions")
    workflow=$(gh api "orgs/$GITHUB_ORG/actions/permissions/workflow")

    local perms_drift=false workflow_drift=false
    local key

    for key in "${ORG_ACTIONS_PERMISSIONS_KEYS[@]}"; do
        local expected_json actual_json
        expected_json=$(org_policy_json "actions.$key")
        actual_json=$(jq -c ".$key" <<<"$perms")

        if [ "$actual_json" = "$expected_json" ]; then
            echo -e "  ${GREEN}OK${NC}: actions.$key = $(jq -r '.' <<<"$expected_json")"
            SETTINGS_OK=$((SETTINGS_OK + 1))
        else
            SETTINGS_MISSING=$((SETTINGS_MISSING + 1))
            perms_drift=true
            if [ "$apply" = "true" ]; then
                echo -e "  ${YELLOW}SETTING${NC}: actions.$key to $(jq -r '.' <<<"$expected_json") (was: $(jq -r '.' <<<"$actual_json"))"
            else
                echo -e "  ${RED}WRONG${NC}: actions.$key = $(jq -r '.' <<<"$actual_json") (should be $(jq -r '.' <<<"$expected_json"))"
            fi
        fi
    done

    for key in "${ORG_ACTIONS_WORKFLOW_KEYS[@]}"; do
        local expected_json actual_json
        expected_json=$(org_policy_json "actions.$key")
        actual_json=$(jq -c ".$key" <<<"$workflow")

        if [ "$actual_json" = "$expected_json" ]; then
            echo -e "  ${GREEN}OK${NC}: actions.$key = $(jq -r '.' <<<"$expected_json")"
            SETTINGS_OK=$((SETTINGS_OK + 1))
        else
            SETTINGS_MISSING=$((SETTINGS_MISSING + 1))
            workflow_drift=true
            if [ "$apply" = "true" ]; then
                echo -e "  ${YELLOW}SETTING${NC}: actions.$key to $(jq -r '.' <<<"$expected_json") (was: $(jq -r '.' <<<"$actual_json"))"
            else
                echo -e "  ${RED}WRONG${NC}: actions.$key = $(jq -r '.' <<<"$actual_json") (should be $(jq -r '.' <<<"$expected_json"))"
            fi
        fi
    done

    if [ "$apply" = "true" ] && [ "$perms_drift" = "true" ]; then
        local body="{}"
        for key in "${ORG_ACTIONS_PERMISSIONS_KEYS[@]}"; do
            body=$(jq --arg k "$key" --argjson v "$(org_policy_json "actions.$key")" '. + {($k): $v}' <<<"$body")
        done
        gh api "orgs/$GITHUB_ORG/actions/permissions" --method PUT --input - <<<"$body" --silent
    fi

    if [ "$apply" = "true" ] && [ "$workflow_drift" = "true" ]; then
        local body="{}"
        for key in "${ORG_ACTIONS_WORKFLOW_KEYS[@]}"; do
            body=$(jq --arg k "$key" --argjson v "$(org_policy_json "actions.$key")" '. + {($k): $v}' <<<"$body")
        done
        gh api "orgs/$GITHUB_ORG/actions/permissions/workflow" --method PUT --input - <<<"$body" --silent
    fi
}

# Compare a policy-declared ruleset against its live API representation.
# Emits one tab-separated record per line to stdout:
#   OK|WRONG    <key>            <expected>  <actual>
#   MISSING     rules.<type>     -           -   (expected rule type absent)
#   EXTRA       rules.<type>     -           -   (live rule type not in policy)
# Keys are in policy vocabulary (enforcement, target, conditions,
# bypass_actors, rules.<type>, rules.<type>.<param>) so both audit_rulesets
# (renderer) and ruleset_has_drift (collapse-to-boolean) can share this one
# comparison engine and can never diverge from each other.
ruleset_diff() {
    local repo="$1"
    local ruleset_name="$2"
    local full_ruleset="$3"

    local expected_enforcement expected_target
    expected_enforcement=$(ruleset_field "$repo" "$ruleset_name" enforcement active)
    expected_target=$(ruleset_field "$repo" "$ruleset_name" target branch)
    _rd_scalar "enforcement" "$expected_enforcement" "$(jq -r '.enforcement' <<<"$full_ruleset")"
    _rd_scalar "target" "$expected_target" "$(jq -r '.target' <<<"$full_ruleset")"

    local expected_conditions actual_conditions
    expected_conditions=$(ruleset_conditions_json "$repo" "$ruleset_name" | jq -Sc "$CANON_JQ")
    actual_conditions=$(jq -c '.conditions' <<<"$full_ruleset" | jq -Sc "$CANON_JQ")
    _rd_scalar "conditions" "$expected_conditions" "$actual_conditions"

    local -a expected_types actual_types
    mapfile -t expected_types < <(expected_rule_types "$repo" "$ruleset_name")
    mapfile -t actual_types < <(jq -r '.rules[].type' <<<"$full_ruleset" | sort)

    local t
    for t in "${expected_types[@]}"; do
        if printf '%s\n' "${actual_types[@]}" | grep -qx "$t"; then
            printf 'OK\trules.%s\tpresent\tpresent\n' "$t"
        else
            printf 'MISSING\trules.%s\t-\t-\n' "$t"
        fi
    done
    for t in "${actual_types[@]}"; do
        if ! printf '%s\n' "${expected_types[@]}" | grep -qx "$t"; then
            printf 'EXTRA\trules.%s\t-\t-\n' "$t"
        fi
    done

    local rules_json
    rules_json=$(ruleset_rules_json "$repo" "$ruleset_name")

    for t in "${expected_types[@]}"; do
        printf '%s\n' "${actual_types[@]}" | grep -qx "$t" || continue
        [ "$(rule_kind "$t")" = "flag" ] && continue

        local expected_params actual_params
        expected_params=$(jq -c --arg t "$t" '.[$t] // {}' <<<"$rules_json")
        actual_params=$(jq -c --arg t "$t" '.rules[] | select(.type == $t) | .parameters' <<<"$full_ruleset" \
            | jq -c "$(rule_from_api_jq "$t")")

        local k
        for k in $(jq -r 'keys[]' <<<"$expected_params"); do
            local exp_val act_val
            exp_val=$(jq -Sc --arg k "$k" '.[$k]' <<<"$expected_params" | jq -Sc "$CANON_JQ")
            act_val=$(jq -Sc --arg k "$k" '.[$k]' <<<"$actual_params" | jq -Sc "$CANON_JQ")
            _rd_scalar "rules.$t.$k" "$exp_val" "$act_val"
        done
    done

    # Compare the full actor object (id, actor_type, bypass_mode), not just
    # actor_id — drift in type or mode (e.g. an actor granted "always" bypass
    # instead of the expected "pull_request") can bypass governed branch
    # protections just as much as an unexpected actor_id. Runs unconditionally,
    # including when policy expects zero actors, so live-only actors aren't
    # ignored.
    local expected_bypass expected_actors actual_actors
    expected_bypass=$(ruleset_bypass_json "$repo" "$ruleset_name")
    expected_actors=$(jq -c '[.[] | {actor_id, actor_type, bypass_mode}] | sort_by(.actor_id)' <<<"$expected_bypass" | jq -Sc "$CANON_JQ")
    actual_actors=$(jq -c '[.bypass_actors[] | {actor_id, actor_type, bypass_mode}] | sort_by(.actor_id)' <<<"$full_ruleset" | jq -Sc "$CANON_JQ")
    _rd_scalar "bypass_actors" "$expected_actors" "$actual_actors"
}

_rd_scalar() {
    local key="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'OK\t%s\t%s\t%s\n' "$key" "$expected" "$actual"
    else
        printf 'WRONG\t%s\t%s\t%s\n' "$key" "$expected" "$actual"
    fi
}

# Audit rulesets
audit_rulesets() {
    local repo="$1"
    local apply="$2"

    echo -e "\n${BLUE}=== Rulesets (main): $GITHUB_ORG/$repo ===${NC}"

    # Check for leftover classic branch protection
    if gh api "repos/$GITHUB_ORG/$repo/branches/main/protection" --silent 2>/dev/null; then
        RULESET_MISSING=$((RULESET_MISSING + 1))
        echo -e "  ${YELLOW}LEGACY${NC}: Classic branch protection still exists (should be replaced by rulesets)"
        if [ "$apply" = "true" ]; then
            remove_classic_branch_protection "$repo"
        fi
    fi

    local -a all_names applicable_names
    mapfile -t all_names < <(ruleset_names)
    applicable_names=()
    local name
    for name in "${all_names[@]}"; do
        ruleset_applies "$repo" "$name" && applicable_names+=("$name")
    done

    # Get existing rulesets. includes_parents=false excludes org-level rulesets that
    # apply here by inheritance — those are managed at the org level, not this repo's,
    # and would otherwise show up as unmanaged drift below.
    local existing_rulesets
    existing_rulesets=$(gh api "repos/$GITHUB_ORG/$repo/rulesets?includes_parents=false" 2>/dev/null || echo "[]")

    for name in "${applicable_names[@]}"; do
        local existing_id
        existing_id=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .id' <<<"$existing_rulesets")

        if [ -z "$existing_id" ]; then
            RULESET_MISSING=$((RULESET_MISSING + 1))
            echo -e "  ${RED}MISSING${NC}: Ruleset '$name' not found"
            if [ "$apply" = "true" ]; then
                apply_ruleset "$repo" "$name"
            fi
            continue
        fi

        echo -e "  ${GREEN}OK${NC}: Ruleset '$name' exists (id: $existing_id)"
        RULESET_OK=$((RULESET_OK + 1))

        # Fetch full ruleset details (list endpoint doesn't include all fields)
        local full_ruleset
        full_ruleset=$(gh api "repos/$GITHUB_ORG/$repo/rulesets/$existing_id" 2>/dev/null)

        # Apply is gated on drift local to THIS ruleset only — a global
        # cumulative counter would trigger a PUT of every ruleset in the
        # loop (including ones with no drift) as soon as any one of them
        # had an issue.
        local drift=0
        local status key expected actual
        while IFS=$'\t' read -r status key expected actual; do
            case "$status" in
                OK)
                    if [ "$expected" = "present" ]; then
                        echo -e "  ${GREEN}OK${NC}: Rule '${key#rules.}' present"
                    else
                        echo -e "  ${GREEN}OK${NC}: $key = $expected"
                    fi
                    RULESET_OK=$((RULESET_OK + 1))
                    ;;
                WRONG)
                    echo -e "  ${RED}WRONG${NC}: $key = $actual (should be $expected)"
                    RULESET_MISSING=$((RULESET_MISSING + 1))
                    drift=$((drift + 1))
                    ;;
                MISSING)
                    echo -e "  ${RED}MISSING${NC}: Rule '${key#rules.}' not found"
                    RULESET_MISSING=$((RULESET_MISSING + 1))
                    drift=$((drift + 1))
                    ;;
                EXTRA)
                    echo -e "  ${RED}WRONG${NC}: Unexpected rule '${key#rules.}' present (not in policy)"
                    RULESET_MISSING=$((RULESET_MISSING + 1))
                    drift=$((drift + 1))
                    ;;
            esac
        done < <(ruleset_diff "$repo" "$name" "$full_ruleset")

        if [ "$apply" = "true" ] && [ "$drift" -gt 0 ]; then
            apply_ruleset "$repo" "$name"
        fi
    done

    # Flag rulesets that exist on the repo but aren't applicable-and-known
    # (e.g. a "Code Quality Copilot review" ruleset created via the UI
    # before policy modeled it, or a ruleset whose repos: scope excludes
    # this repo). Report-only — never auto-deleted, since it may be an
    # intentional per-repo addition.
    local applicable_names_json unmanaged_rulesets
    applicable_names_json=$(printf '%s\n' "${applicable_names[@]}" | jq -R . | jq -s 'sort')
    unmanaged_rulesets=$(jq -c --argjson known "$applicable_names_json" \
        '[.[] | select(.name as $n | $known | index($n) | not) | .name]' <<<"$existing_rulesets")
    if [ "$unmanaged_rulesets" != "[]" ]; then
        RULESET_MISSING=$((RULESET_MISSING + $(jq 'length' <<<"$unmanaged_rulesets")))
        echo -e "  ${RED}UNMANAGED${NC}: Ruleset(s) not in policy (created out-of-band): $unmanaged_rulesets"
    fi
}

# Does this known (policy-declared) ruleset's live config match what policy
# resolves to for this repo? Delegates to ruleset_diff — the same
# comparison audit_rulesets renders — so "no drift" here means
# audit_rulesets would print nothing but OK lines.
# Returns 0 (bash true) if drift was found, 1 if the live ruleset matches policy.
ruleset_has_drift() {
    local repo="$1"
    local ruleset_name="$2"
    local full_ruleset="$3"

    local status
    while IFS=$'\t' read -r status _ _ _; do
        [ "$status" != "OK" ] && return 0
    done < <(ruleset_diff "$repo" "$ruleset_name" "$full_ruleset")

    return 1
}

# Assemble the jq filter that maps a live API ruleset onto the compact
# policy shape, generated from the rule registry so adding a rule type
# means adding a RULE_KIND entry, not hand-editing this filter. Cached on
# first call — this doesn't change during a run.
build_ruleset_import_jq() {
    if [ -n "$RULESET_IMPORT_JQ_CACHE" ]; then
        printf '%s' "$RULESET_IMPORT_JQ_CACHE"
        return 0
    fi

    local -a pieces=()
    local t
    for t in "${RULE_TYPE_ORDER[@]}"; do
        if [ "$(rule_kind "$t")" = "flag" ]; then
            pieces+=("{\"$t\": (\$r[\"$t\"] // false)}")
        else
            pieces+=("(if \$r[\"$t\"] then {\"$t\": (\$r[\"$t\"] | $(rule_from_api_jq "$t"))} else {} end)")
        fi
    done

    local rule_expr
    rule_expr=$(IFS='+'; printf '%s' "${pieces[*]}")

    local known_types_json
    known_types_json=$(printf '%s\n' "${RULE_TYPE_ORDER[@]}" | jq -R . | jq -c -s .)

    RULESET_IMPORT_JQ_CACHE="(.rules | map({(.type): (.parameters // true)}) | add) as \$r
| {
    target: .target,
    enforcement: .enforcement,
    conditions: {
      ref_name: {
        include: (.conditions.ref_name.include // []),
        exclude: (.conditions.ref_name.exclude // [])
      }
    },
    bypass_actors: (.bypass_actors // []),
    rules: ($rule_expr),
    unmapped_rule_types: ([\$r | keys[]] - $known_types_json)
  }"

    printf '%s' "$RULESET_IMPORT_JQ_CACHE"
}

# Dump ONLY the parts of a repo's live settings that drift from what policy
# currently resolves to (via default or per-repo override) — settings/security
# keys use a JSON-vs-JSON comparison; rulesets already known to (and scoped
# to this repo by) policy use ruleset_has_drift(); rulesets policy doesn't
# apply here at all always print in full since there's nothing to diff
# against. Values that already match policy are omitted entirely — the
# point is to show what needs a decision, not the whole resolved config.
# Read-only: prints to stdout for the caller to diff against
# governance/repository-settings-policy.yaml and paste under github_defaults
# (general) or github_repos.<repo> (override). Never writes the policy file
# itself — it carries hand-authored comments a yq round-trip would risk
# mangling, and default-vs-override is a judgment call.
import_repo() {
    local repo="$1"

    echo "# ---- drift from policy: $GITHUB_ORG/$repo ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ----"

    local settings
    settings=$(gh api "repos/$GITHUB_ORG/$repo")

    local settings_json="{}"
    local key
    for key in "${SETTING_KEYS[@]}"; do
        local expected_json actual_json
        expected_json=$(gh_policy_json "$repo" "$key")
        actual_json=$(jq -c ".$key" <<<"$settings")
        if [ "$actual_json" != "$expected_json" ]; then
            settings_json=$(jq --arg k "$key" --argjson v "$actual_json" '. + {($k): $v}' <<<"$settings_json")
        fi
    done

    local security_json="{}"
    for key in secret_scanning secret_scanning_push_protection dependabot_security_updates; do
        local expected actual
        expected=$(gh_policy_value "$repo" "security.$key")
        [ "$expected" = "null" ] && continue
        actual=$(echo "$settings" | jq -r ".security_and_analysis.$key.status // \"disabled\"")
        if [ "$actual" != "$expected" ]; then
            security_json=$(echo "$security_json" | jq --arg k "$key" --arg v "$actual" '. + {($k): $v}')
        fi
    done

    local -a all_names applicable_names
    mapfile -t all_names < <(ruleset_names)
    applicable_names=()
    local n
    for n in "${all_names[@]}"; do
        ruleset_applies "$repo" "$n" && applicable_names+=("$n")
    done

    # includes_parents=false: same reasoning as audit_rulesets — org-inherited
    # rulesets are managed at the org level, importing them here would duplicate them.
    # Failure tracked separately from "genuinely zero live rulesets" — falling
    # through to [] on a permissions/rate-limit/transient error would otherwise
    # make the missing-ruleset check below report every applicable ruleset as
    # deleted, a false and actively misleading claim from a read-only diff tool.
    local existing_rulesets rulesets_fetch_ok=true
    if ! existing_rulesets=$(gh api "repos/$GITHUB_ORG/$repo/rulesets?includes_parents=false" 2>/dev/null); then
        existing_rulesets="[]"
        rulesets_fetch_ok=false
    fi

    local rulesets_json="{}"
    local -a existing_ruleset_names=()
    local ruleset_id
    for ruleset_id in $(echo "$existing_rulesets" | jq -r '.[].id'); do
        local full_ruleset ruleset_name
        full_ruleset=$(gh api "repos/$GITHUB_ORG/$repo/rulesets/$ruleset_id" 2>/dev/null)
        ruleset_name=$(echo "$full_ruleset" | jq -r '.name')
        existing_ruleset_names+=("$ruleset_name")

        local is_applicable=false
        for n in "${applicable_names[@]}"; do
            [ "$n" = "$ruleset_name" ] && is_applicable=true && break
        done

        if [ "$is_applicable" = "true" ] && ! ruleset_has_drift "$repo" "$ruleset_name" "$full_ruleset"; then
            continue # matches policy exactly — nothing to show
        fi

        local transformed unmapped clean
        transformed=$(jq "$(build_ruleset_import_jq)" <<<"$full_ruleset")
        unmapped=$(echo "$transformed" | jq -c '.unmapped_rule_types')
        if [ "$unmapped" != "[]" ]; then
            echo "# WARNING: ruleset '$ruleset_name' has rule type(s) this script doesn't model, omitted from import: $unmapped" >&2
        fi
        clean=$(echo "$transformed" | jq 'del(.unmapped_rule_types)')
        rulesets_json=$(echo "$rulesets_json" | jq --arg n "$ruleset_name" --argjson v "$clean" '. + {($n): $v}')
    done

    # A ruleset policy expects here but that no longer exists live (deleted
    # on GitHub) leaves no live JSON to dump — flag it instead of letting it
    # silently drop out of rulesets_json and read as "matches policy". Skipped
    # entirely when the rulesets fetch itself failed above: existing_rulesets
    # is "[]" either way, and computing "missing" from that would report
    # every applicable ruleset as deleted — a false claim, not an unknown one.
    local missing_rulesets_json="[]"
    if [ "$rulesets_fetch_ok" = "true" ]; then
        local applicable_names_json existing_names_json
        applicable_names_json=$(bash_array_to_json "${applicable_names[@]}")
        existing_names_json=$(bash_array_to_json "${existing_ruleset_names[@]}")
        missing_rulesets_json=$(ruleset_names_missing "$applicable_names_json" "$existing_names_json")
        if [ "$missing_rulesets_json" != "[]" ]; then
            echo "# WARNING: policy ruleset(s) expected on $repo but not found live (deleted?): $(jq -r 'join(", ")' <<<"$missing_rulesets_json")"
        fi
    else
        echo "# WARNING: could not fetch live rulesets for $repo — ruleset drift and missing-ruleset detection skipped this run" >&2
    fi

    if [ "$rulesets_fetch_ok" = "true" ] && [ "$settings_json" = "{}" ] && [ "$security_json" = "{}" ] && [ "$rulesets_json" = "{}" ] && [ "$missing_rulesets_json" = "[]" ]; then
        echo "# $repo: matches policy — nothing to import"
        echo ""
        return 0
    fi

    local body="$settings_json"
    [ "$security_json" != "{}" ] && body=$(echo "$body" | jq --argjson s "$security_json" '. + {security: $s}')
    [ "$rulesets_json" != "{}" ] && body=$(echo "$body" | jq --argjson r "$rulesets_json" '. + {rulesets: $r}')

    jq -n --arg repo "$repo" --argjson body "$body" '{($repo): $body}' | yq -p=json -o=yaml -
    echo ""
}

# Dump ONLY the parts of org-level settings that drift from policy, as a
# paste-ready github_org: YAML block — the same read-only, never-writes
# contract as import_repo (diff by hand against
# governance/repository-settings-policy.yaml). Only reached via --org --import.
import_org() {
    echo "# ---- drift from policy: org $GITHUB_ORG ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ----"

    local settings actions_perms actions_workflow
    settings=$(gh api "orgs/$GITHUB_ORG")
    actions_perms=$(gh api "orgs/$GITHUB_ORG/actions/permissions")
    actions_workflow=$(gh api "orgs/$GITHUB_ORG/actions/permissions/workflow")

    local settings_json="{}"
    local key
    for key in "${ORG_SETTING_KEYS[@]}" "${ORG_READONLY_KEYS[@]}"; do
        local expected_json actual_json
        expected_json=$(org_policy_json "$key")
        actual_json=$(jq -c ".$key" <<<"$settings")
        if [ "$actual_json" != "$expected_json" ]; then
            settings_json=$(jq --arg k "$key" --argjson v "$actual_json" '. + {($k): $v}' <<<"$settings_json")
        fi
    done

    local actions_json="{}"
    for key in "${ORG_ACTIONS_PERMISSIONS_KEYS[@]}"; do
        local expected_json actual_json
        expected_json=$(org_policy_json "actions.$key")
        actual_json=$(jq -c ".$key" <<<"$actions_perms")
        if [ "$actual_json" != "$expected_json" ]; then
            actions_json=$(jq --arg k "$key" --argjson v "$actual_json" '. + {($k): $v}' <<<"$actions_json")
        fi
    done
    for key in "${ORG_ACTIONS_WORKFLOW_KEYS[@]}"; do
        local expected_json actual_json
        expected_json=$(org_policy_json "actions.$key")
        actual_json=$(jq -c ".$key" <<<"$actions_workflow")
        if [ "$actual_json" != "$expected_json" ]; then
            actions_json=$(jq --arg k "$key" --argjson v "$actual_json" '. + {($k): $v}' <<<"$actions_json")
        fi
    done

    if [ "$settings_json" = "{}" ] && [ "$actions_json" = "{}" ]; then
        echo "# org: matches policy — nothing to import"
        echo ""
        return 0
    fi

    local body="$settings_json"
    [ "$actions_json" != "{}" ] && body=$(jq --argjson a "$actions_json" '. + {actions: $a}' <<<"$body")

    jq -n --argjson body "$body" '{github_org: $body}' | yq -p=json -o=yaml -
    echo ""
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
    audit_security_settings "$repo" "$apply"
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

# Audit (and, with --apply, apply) organization-level settings. Only reached
# via --org — never called from --all or a single-repo invocation, so no
# other code path requires admin:org or touches orgs/{org} at all.
audit_org() {
    local apply="$1"

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Organization: $GITHUB_ORG${NC}"
    echo -e "${BLUE}========================================${NC}"

    local settings_ok_before=$SETTINGS_OK
    local settings_missing_before=$SETTINGS_MISSING
    local settings_blocked_before=$SETTINGS_BLOCKED

    audit_org_settings "$apply"
    audit_org_actions "$apply"

    if [ "$JSON_OUTPUT" = "true" ]; then
        local org_settings_ok=$((SETTINGS_OK - settings_ok_before))
        local org_settings_missing=$((SETTINGS_MISSING - settings_missing_before))
        local org_settings_blocked=$((SETTINGS_BLOCKED - settings_blocked_before))
        local org_status="OK"
        [ $((org_settings_missing + org_settings_blocked)) -gt 0 ] && org_status="WARN"
        json_org_result=$(jq -n \
            --argjson so "$org_settings_ok" \
            --argjson sm "$org_settings_missing" \
            --argjson sb "$org_settings_blocked" \
            --arg st "$org_status" \
            '{"settings_ok": $so, "settings_missing": $sm, "settings_blocked": $sb, "status": $st}')
    fi
}

# Print summary
print_summary() {
    local apply="${1:-false}"

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Summary${NC}"
    echo -e "${BLUE}========================================${NC}"

    local total_issues=$((LABELS_MISSING + LABELS_RENAMED + LABELS_EXTRA + SETTINGS_MISSING + SETTINGS_BLOCKED + RULESET_MISSING))

    if [ "$apply" = "true" ]; then
        echo -e "Labels: ${GREEN}$LABELS_OK OK${NC}, ${YELLOW}$LABELS_MISSING created${NC}, ${YELLOW}$LABELS_RENAMED renamed${NC}, ${YELLOW}$LABELS_EXTRA extra (${LABELS_BLOCKED} skipped, in use)${NC}"
        echo -e "Settings: ${GREEN}$SETTINGS_OK OK${NC}, ${YELLOW}$SETTINGS_MISSING applied${NC}, ${RED}$SETTINGS_BLOCKED blocked (audit-only, unresolved)${NC}"
        echo -e "Rulesets: ${GREEN}$RULESET_OK OK${NC}, ${YELLOW}$RULESET_MISSING issues${NC}"
    else
        echo -e "Labels: ${GREEN}$LABELS_OK OK${NC}, ${RED}$LABELS_MISSING missing${NC}, ${YELLOW}$LABELS_RENAMED to rename${NC}, ${RED}$LABELS_EXTRA extra${NC}"
        echo -e "Settings: ${GREEN}$SETTINGS_OK OK${NC}, ${RED}$SETTINGS_MISSING wrong${NC}, ${RED}$SETTINGS_BLOCKED audit-only wrong${NC}"
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
            --argjson sb "$SETTINGS_BLOCKED" \
            --argjson ro "$RULESET_OK" \
            --argjson rm "$RULESET_MISSING" \
            --argjson repos "$json_results" \
            --argjson org "$json_org_result" \
            '{"generated": $ts, "labels_ok": $lo, "labels_missing": $lm, "labels_renamed": $lr, "labels_extra": $le, "labels_blocked": $lb, "settings_ok": $so, "settings_missing": $sm, "settings_blocked": $sb, "rulesets_ok": $ro, "rulesets_missing": $rm, "repos": $repos, "org": $org}' \
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
    local org_mode=false
    local apply=false
    local import_mode=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)
                all_repos=true
                shift
                ;;
            --org)
                org_mode=true
                shift
                ;;
            --apply)
                apply=true
                shift
                ;;
            --import)
                import_mode=true
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
    if [ "$org_mode" = "true" ] && { [ "$all_repos" = "true" ] || [ -n "$repo" ]; }; then
        echo "ERROR: --org is mutually exclusive with --all and <repo> — they are different scopes"
        exit 1
    fi

    if [ "$org_mode" = "false" ] && [ "$all_repos" = "false" ] && [ -z "$repo" ]; then
        usage
    fi

    if [ "$import_mode" = "true" ] && [ "$apply" = "true" ]; then
        echo "ERROR: --import and --apply are mutually exclusive (--import never writes)"
        exit 1
    fi

    setup_colors
    check_requirements

    if [ "$org_mode" = "true" ]; then
        require_org_scope
    fi

    if [ "$import_mode" = "true" ]; then
        if [ "$org_mode" = "true" ]; then
            import_org
        elif [ "$all_repos" = "true" ]; then
            for r in ${GITHUB_REPOS:-}; do
                import_repo "$r"
            done
        else
            import_repo "$repo"
        fi
        return 0
    fi

    if [ "$apply" = "true" ]; then
        echo -e "${YELLOW}Running in APPLY mode - changes will be made${NC}"
    else
        echo -e "${BLUE}Running in AUDIT mode (dry-run) - no changes will be made${NC}"
    fi

    # Run audits
    if [ "$org_mode" = "true" ]; then
        audit_org "$apply"
    elif [ "$all_repos" = "true" ]; then
        for r in ${GITHUB_REPOS:-}; do
            audit_repo "$r" "$apply" || true
        done
    else
        audit_repo "$repo" "$apply"
    fi

    print_summary "$apply"
}

# Sourceable for tests (scripts/test/github-settings-test.sh sources this file
# to exercise the registry/diff/payload functions directly, without a live
# `gh`) while remaining a normal, unchanged CLI when executed directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
