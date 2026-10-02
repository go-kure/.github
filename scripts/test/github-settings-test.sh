#!/usr/bin/env bash
# github-settings-test.sh — function-level regression tests for the rule
# registry / ruleset diff engine / import filter in scripts/github-settings.sh.
#
# Why not a full mock-`gh` end-to-end harness: audit_labels() reads the
# real standards/labels.json (35 live labels) with no override hook, so an
# end-to-end mock would either have to mirror that file exactly (fragile —
# breaks on unrelated label changes) or fake it too (then it's not testing
# the real audit path anyway). This instead sources github-settings.sh
# directly (the BASH_SOURCE guard at its end keeps `main` from auto-running)
# and drives the registry/diff/payload functions with crafted JSON fixtures
# — no network, no `gh` token, no coupling to label drift. This is also
# exactly where this unit of work's real bugs lived: silent rule deletion
# on apply, the yq spaces-in-key parse failure, false settings drift.
#
# Usage: github-settings-test.sh [REPO_ROOT]

set -uo pipefail # deliberately not -e: assertions continue past failures to report all of them

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"

# shellcheck source=/dev/null
source "$ROOT/scripts/github-settings.sh"

# github-settings.sh's own `set -euo pipefail` runs at source time and
# silently adds -e to THIS shell too (source shares the current shell, it
# doesn't sandbox options) — without undoing it, the first assertion whose
# right-hand side returns non-zero would abort this whole test script with
# no error message, well before checking the last one.
set +e

# main() normally calls this before touching any function that echoes
# ${RED}/${GREEN}/etc — under the inherited `set -u`, an unset color
# variable is itself a hard error, not just a missing color code.
# shellcheck disable=SC2034 # read by setup_colors(), defined in the
# sourced (source=/dev/null) github-settings.sh, invisible to this file's lint.
CI_MODE=true
setup_colors

POLICY_FILE="$ROOT/governance/repository-settings-policy.yaml"
POLICY_JSON="$(yq -oj '.' "$POLICY_FILE")"
COPILOT="Code Quality Copilot review for default branch"

failures=0
pass_count=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $desc"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        failures=$((failures + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "PASS: $desc"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc — expected to find: $needle"
        echo "  in: $haystack"
        failures=$((failures + 1))
    fi
}

# ---- validate_policy ----
# validate_policy() calls `exit` on failure, so it must run in a subshell
# here or it would kill the whole test run.

if (validate_policy) >/dev/null 2>&1; then
    echo "PASS: validate_policy accepts the real policy file"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: validate_policy rejects the real policy file (should accept it)"
    failures=$((failures + 1))
fi

bogus_policy_json=$(jq '.github_defaults.rulesets["main-protection"].rules.bogus_type = true' <<<"$POLICY_JSON")
bogus_out=$( (POLICY_JSON="$bogus_policy_json" validate_policy) 2>&1 )
bogus_rc=$?
if [ "$bogus_rc" -ne 0 ]; then
    echo "PASS: validate_policy exits non-zero on an unmodeled rule type"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: validate_policy should reject an unmodeled rule type"
    failures=$((failures + 1))
fi
assert_contains "validate_policy's error names the offending rule type" "$bogus_out" "bogus_type"

# The labels file's repos: scopes are validated against the same governed
# repo set as ruleset scopes (go-kure/.github#154 round-6 finding): a typo
# there silently un-expects the label on the intended repo and lets --apply
# delete a live copy as EXTRA.
labels_scope_fixture="$(mktemp)"
printf '%s\n' '{"labels": [{"name": "area/x", "color": "#000000", "description": "d", "repos": ["kure", "nope-repo"]}]}' >"$labels_scope_fixture"
scope_out=$( (LABELS_FILE="$labels_scope_fixture" validate_policy) 2>&1 )
scope_rc=$?
rm -f "$labels_scope_fixture"
assert_eq "validate_policy exits non-zero on a labels-file repos: scope naming an unknown repo" "1" "$([ "$scope_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "validate_policy's error names the unknown label scope repo" "$scope_out" "unknown repo(s): nope-repo"

# A misspelled github_repos key is never looked up and silently falls back
# to github_defaults (round-7 finding); duplicate label names in a consumer
# file would be POSTed twice (round-7 finding).
typo_policy_json=$(jq '.github_repos.alpah = {has_discussions: true}' <<<"$POLICY_JSON")
typo_out=$( (POLICY_JSON="$typo_policy_json" validate_policy) 2>&1 )
typo_rc=$?
assert_eq "validate_policy exits non-zero on a github_repos key naming an unknown repo" "1" "$([ "$typo_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "validate_policy's error names the unknown override key" "$typo_out" "unknown repo(s): alpah"

dup_labels_fixture="$(mktemp)"
printf '%s\n' '{"labels": [{"name": "area/x", "color": "#000000", "description": "d"}, {"name": "area/x", "color": "#111111", "description": "e"}]}' >"$dup_labels_fixture"
dup_out=$( (LABELS_FILE="$dup_labels_fixture" validate_policy) 2>&1 )
dup_rc=$?
rm -f "$dup_labels_fixture"
assert_eq "validate_policy exits non-zero on duplicate label names in the labels file" "1" "$([ "$dup_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "validate_policy's error names the duplicated label" "$dup_out" "duplicate label name(s): area/x"

# An empty or malformed labels file must be refused before any mutation:
# `{"labels": []}` makes every live label EXTRA and --apply deletes them all
# (round-8 finding); an entry without a colour would fail at the API mid-apply.
empty_labels_fixture="$(mktemp)"
printf '%s\n' '{"labels": []}' >"$empty_labels_fixture"
empty_out=$( (LABELS_FILE="$empty_labels_fixture" validate_policy) 2>&1 )
empty_rc=$?
rm -f "$empty_labels_fixture"
assert_eq "validate_policy exits non-zero on a labels file declaring no labels" "1" "$([ "$empty_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "validate_policy's error names the empty labels list" "$empty_out" "labels: fewer than 1 item(s)"

malformed_labels_fixture="$(mktemp)"
printf '%s\n' '{"labels": [{"name": "area/x", "description": "d"}]}' >"$malformed_labels_fixture"
malformed_out=$( (LABELS_FILE="$malformed_labels_fixture" validate_policy) 2>&1 )
malformed_rc=$?
rm -f "$malformed_labels_fixture"
assert_eq "validate_policy exits non-zero on a label entry without a colour" "1" "$([ "$malformed_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "validate_policy's error names the malformed labels file" "$malformed_out" "is malformed"

repos_string_fixture="$(mktemp)"
printf '%s\n' '{"labels": [{"name": "area/x", "color": "#000000", "description": "d", "repos": "kure"}]}' >"$repos_string_fixture"
repos_string_out=$( (LABELS_FILE="$repos_string_fixture" validate_policy) 2>&1 )
repos_string_rc=$?
rm -f "$repos_string_fixture"
assert_eq "validate_policy exits non-zero on a repos: scope that is a string, not a list" "1" "$([ "$repos_string_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "validate_policy's error on a string repos: scope is the shape error, not a raw jq failure" "$repos_string_out" "is malformed"

# security: values are a closed enum (round-13 finding): audit_security_settings
# applies anything that is not exactly "enabled" as disabled, so a typo in a
# consumer policy would DELETE automated security fixes instead of being
# rejected. Checked on the defaults tier, on a per-repo override, for a YAML
# boolean (`enabled: true` is not the string "enabled") and for a misspelled
# key, which is never looked up.
sec_typo_json=$(jq '.github_repos.kure.security.dependabot_security_updates = "enabeld"' <<<"$POLICY_JSON")
sec_typo_out=$( (POLICY_JSON="$sec_typo_json" validate_policy) 2>&1 )
sec_typo_rc=$?
assert_eq "validate_policy exits non-zero on a misspelled security value in a per-repo override" "1" "$([ "$sec_typo_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "validate_policy's error names the offending security block" "$sec_typo_out" "github_repos.kure"

sec_bool_json=$(jq '.github_defaults.security.secret_scanning = true' <<<"$POLICY_JSON")
sec_bool_out=$( (POLICY_JSON="$sec_bool_json" validate_policy) 2>&1 )
sec_bool_rc=$?
assert_eq "validate_policy exits non-zero on a boolean security value in github_defaults" "1" "$([ "$sec_bool_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "validate_policy's error names the defaults security block" "$sec_bool_out" "github_defaults"

sec_key_json=$(jq '.github_defaults.security.secret_scaning = "enabled"' <<<"$POLICY_JSON")
sec_key_rc=$( (POLICY_JSON="$sec_key_json" validate_policy) >/dev/null 2>&1; echo $? )
assert_eq "validate_policy exits non-zero on a misspelled security key" "1" "$([ "$sec_key_rc" -ne 0 ] && echo 1 || echo 0)"

sec_ok_json=$(jq '.github_repos.kure.security = {secret_scanning: "disabled", dependabot_security_updates: "enabled"}' <<<"$POLICY_JSON")
sec_ok_rc=$( (POLICY_JSON="$sec_ok_json" validate_policy) >/dev/null 2>&1; echo $? )
assert_eq "validate_policy accepts a per-repo security override that uses the enum" "0" "$sec_ok_rc"

# A labels file that is non-empty but leaves one governed repo with no
# applicable label (round-14 finding) reproduces the empty-file outcome for
# that repo: every live label EXTRA, deleted by --apply unless in use.
scoped_away_fixture="$(mktemp)"
printf '%s\n' '{"labels": [{"name": "area/x", "color": "#000000", "description": "d", "repos": ["kure"]}]}' >"$scoped_away_fixture"
scoped_away_out=$( (LABELS_FILE="$scoped_away_fixture" validate_policy) 2>&1 )
scoped_away_rc=$?
rm -f "$scoped_away_fixture"
assert_eq "validate_policy exits non-zero on a labels file scoped away from a governed repo" "1" "$([ "$scoped_away_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "validate_policy's error names the repo left without labels" "$scoped_away_out" "no applicable label"
assert_contains "and it is the unscoped repo, not the scoped one" "$scoped_away_out" "launcher"

# A field inside a per-repo override that github_defaults does not declare
# is never read (round-14 finding): the exact lookup misses it and the
# default is applied instead of the intended override.
field_typo_json=$(jq '.github_repos.kure.allow_merge_comit = true' <<<"$POLICY_JSON")
field_typo_out=$( (POLICY_JSON="$field_typo_json" validate_policy) 2>&1 )
field_typo_rc=$?
assert_eq "validate_policy exits non-zero on a misspelled field inside a github_repos override" "1" "$([ "$field_typo_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "validate_policy's error names the repo and the unknown field" "$field_typo_out" "kure.allow_merge_comit"

field_ok_json=$(jq '.github_repos.launcher.allow_merge_commit = true' <<<"$POLICY_JSON")
field_ok_rc=$( (POLICY_JSON="$field_ok_json" validate_policy) >/dev/null 2>&1; echo $? )
assert_eq "validate_policy accepts an override field that github_defaults declares" "0" "$field_ok_rc"

# ---- go-kure/.github#161: the policy and labels files are closed schemas.
# The schemas' key sets must be the script's registries exactly: a key the
# schema admits but the script does not read is the silent-fallback defect
# the schema exists to refuse, and a registry key the schema refuses makes
# a valid policy unloadable. ----

policy_schema_json=$(cat "$POLICY_SCHEMA_FILE")
setting_keys_json=$(bash_array_to_json "${SETTING_KEYS[@]}" | jq -c 'sort')
assert_eq "schema: github_defaults declares exactly SETTING_KEYS plus security, actions and rulesets" "$setting_keys_json" \
    "$(jq -c '.definitions.defaults.properties | keys - ["security", "actions", "rulesets"] | sort' <<<"$policy_schema_json")"
assert_eq "schema: github_defaults requires exactly SETTING_KEYS plus security and rulesets" "$setting_keys_json" \
    "$(jq -c '.definitions.defaults.required - ["security", "rulesets"] | sort' <<<"$policy_schema_json")"
assert_eq "schema: github_defaults requires security and rulesets" "true" \
    "$(jq -c '.definitions.defaults.required | index("security") != null and index("rulesets") != null' <<<"$policy_schema_json")"
assert_eq "schema: github_defaults declares actions but does not require it (opt-in)" "true" \
    "$(jq -c '.definitions.defaults | (.properties | has("actions")) and (.required | index("actions") == null)' <<<"$policy_schema_json")"
assert_eq "schema: a repo override declares exactly SETTING_KEYS plus security, actions and rulesets" "$setting_keys_json" \
    "$(jq -c '.definitions.repo_override.properties | keys - ["security", "actions", "rulesets"] | sort' <<<"$policy_schema_json")"
assert_eq "schema: a repo override requires nothing" "null" \
    "$(jq -c '.definitions.repo_override.required' <<<"$policy_schema_json")"
assert_eq "schema: defaults and overrides type each setting the same way" "true" \
    "$(jq -c '.definitions | (.defaults.properties | del(.rulesets, .security, .actions)) == (.repo_override.properties | del(.rulesets, .security, .actions))' <<<"$policy_schema_json")"

org_keys_json=$(bash_array_to_json "${ORG_SETTING_KEYS[@]}" "${ORG_READONLY_KEYS[@]}" | jq -c 'sort')
assert_eq "schema: github_org declares exactly ORG_SETTING_KEYS + ORG_READONLY_KEYS plus actions" "$org_keys_json" \
    "$(jq -c '.definitions.org.properties | keys - ["actions"] | sort' <<<"$policy_schema_json")"
assert_eq "schema: github_org requires every one of them plus actions" "$org_keys_json" \
    "$(jq -c '.definitions.org.required - ["actions"] | sort' <<<"$policy_schema_json")"
actions_keys_json=$(bash_array_to_json "${ORG_ACTIONS_PERMISSIONS_KEYS[@]}" "${ORG_ACTIONS_WORKFLOW_KEYS[@]}" | jq -c 'sort')
assert_eq "schema: github_org.actions declares exactly the two actions key lists" "$actions_keys_json" \
    "$(jq -c '.definitions.org.properties.actions.properties | keys | sort' <<<"$policy_schema_json")"
assert_eq "schema: github_org.actions requires every key (both endpoints are PUT full-replace)" "$actions_keys_json" \
    "$(jq -c '.definitions.org.properties.actions.required | sort' <<<"$policy_schema_json")"

rule_types_json=$(bash_array_to_json "${RULE_TYPE_ORDER[@]}" | jq -c 'sort')
assert_eq "schema: rules declares exactly RULE_TYPE_ORDER" "$rule_types_json" \
    "$(jq -c '.definitions.rules.properties | keys | sort' <<<"$policy_schema_json")"
assert_eq "RULE_KIND covers exactly RULE_TYPE_ORDER" "$rule_types_json" \
    "$(bash_array_to_json "${!RULE_KIND[@]}" | jq -c 'sort')"
rule_kind_shape_ok=true
for t in "${RULE_TYPE_ORDER[@]}"; do
    want=object
    [ "$(rule_kind "$t")" = "flag" ] && want=boolean
    got=$(jq -r --arg t "$t" '.definitions.rules.properties[$t].type' <<<"$policy_schema_json")
    if [ "$got" != "$want" ]; then
        echo "  rule $t: schema type $got, RULE_KIND wants $want"
        rule_kind_shape_ok=false
    fi
done
assert_eq "schema: a flag rule is a boolean and every other rule a parameters object" "true" "$rule_kind_shape_ok"
assert_eq "schema: security declares exactly the three keys audit_security_settings reads" \
    '["dependabot_security_updates","secret_scanning","secret_scanning_push_protection"]' \
    "$(jq -c '.definitions.security.properties | keys | sort' <<<"$policy_schema_json")"
assert_eq "schema: the defaults security block types the same three keys and requires them all" "true" \
    "$(jq -c '.definitions | .security_defaults.properties == .security.properties
        and (.security_defaults.required | sort) == (.security.properties | keys | sort)' <<<"$policy_schema_json")"
# go-kure/.github#158: the repo actions block is pinned to the two repo
# registries the same way, at both tiers.
repo_actions_keys_json=$(bash_array_to_json "${REPO_ACTIONS_PERMISSIONS_KEYS[@]}" "${REPO_ACTIONS_WORKFLOW_KEYS[@]}" | jq -c 'sort')
assert_eq "schema: a repo override's actions declares exactly REPO_ACTIONS_*_KEYS" "$repo_actions_keys_json" \
    "$(jq -c '.definitions.actions.properties | keys | sort' <<<"$policy_schema_json")"
assert_eq "schema: a repo override's actions requires nothing" "null" \
    "$(jq -c '.definitions.actions.required' <<<"$policy_schema_json")"
assert_eq "schema: the defaults actions block types the same keys and requires them all" "true" \
    "$(jq -c '.definitions | .actions_defaults.properties == .actions.properties
        and (.actions_defaults.required | sort) == (.actions.properties | keys | sort)' <<<"$policy_schema_json")"
assert_eq "schema: github_defaults and repo overrides reference the two actions definitions" "true" \
    "$(jq -c '.definitions | .defaults.properties.actions["$ref"] == "#/definitions/actions_defaults"
        and .repo_override.properties.actions["$ref"] == "#/definitions/actions"' <<<"$policy_schema_json")"

# Every level the piecemeal checks never reached (the issue's list): each
# misspelled or mistyped entry is refused, and the error names its path.
schema_reject() {
    local desc="$1" expr="$2" needle="$3" json out rc
    json=$(jq "$expr" <<<"$POLICY_JSON")
    out=$( (POLICY_JSON="$json" validate_policy) 2>&1 )
    rc=$?
    assert_eq "validate_policy refuses $desc" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
    assert_contains "and names it: $desc" "$out" "$needle"
}
schema_reject "a top-level key outside the three tiers" '.github_defualts = {}' \
    "github_defualts: unknown key"
schema_reject "an unmodeled rule type" '.github_defaults.rulesets["main-protection"].rules.bogus_type = true' \
    "github_defaults.rulesets.main-protection.rules.bogus_type: unknown key"
schema_reject "a misspelled pull_request parameter" '.github_defaults.rulesets["main-protection"].rules.pull_request.required_approving_reviews = 1' \
    "rules.pull_request.required_approving_reviews: unknown key"
schema_reject "a review count given as a string" '.github_defaults.rulesets["main-protection"].rules.pull_request.required_approving_review_count = "1"' \
    "required_approving_review_count: expected integer, got string"
schema_reject "contexts given as a string, not a list" '.github_defaults.rulesets["main-protection"].rules.required_status_checks.contexts = "lint"' \
    "required_status_checks.contexts: expected array, got string"
schema_reject "a duplicated required context" '.github_defaults.rulesets["main-protection"].rules.required_status_checks.contexts += ["lint"]' \
    "required_status_checks.contexts: items are not unique"
schema_reject "a misspelled bypass actor field" '.github_repos.kure.rulesets["main-protection"].bypass_actors[0].bypass_mod = "always"' \
    "github_repos.kure.rulesets.main-protection.bypass_actors[0].bypass_mod: unknown key"
schema_reject "bypass_actors on a github_defaults ruleset (never read there)" '.github_defaults.rulesets["main-protection"].bypass_actors = []' \
    "github_defaults.rulesets.main-protection.bypass_actors: unknown key"
schema_reject "repos: on a github_repos ruleset (never read there)" '.github_repos.kure.rulesets["release-protection"].repos = ["kure"]' \
    "github_repos.kure.rulesets.release-protection.repos: unknown key"
schema_reject "a misspelled ref_name condition" '.github_defaults.rulesets["main-protection"].conditions.ref_name.inculde = ["refs/heads/x"]' \
    "conditions.ref_name.inculde: unknown key"
schema_reject "a lower-case merge queue method" '.github_repos.kure.rulesets["main-protection"].rules.merge_queue.merge_method = "rebase"' \
    "merge_queue.merge_method: \"rebase\" is not one of"
# Merge queue sizes and minutes carry the rulesets API's own bounds.
schema_reject "a merge queue build size above the API's 100" '.github_repos.kure.rulesets["main-protection"].rules.merge_queue.max_entries_to_build = 101' \
    "merge_queue.max_entries_to_build: 101 is above the maximum 100"
schema_reject "a merge queue check timeout above the API's 360 minutes" '.github_repos.kure.rulesets["main-protection"].rules.merge_queue.check_response_timeout_minutes = 361' \
    "merge_queue.check_response_timeout_minutes: 361 is above the maximum 360"
schema_reject "a merge queue minimum group size above the API's 100" '.github_repos.kure.rulesets["main-protection"].rules.merge_queue.min_entries_to_merge = 101' \
    "merge_queue.min_entries_to_merge: 101 is above the maximum 100"
schema_reject "a merge queue maximum group size above the API's 100" '.github_repos.kure.rulesets["main-protection"].rules.merge_queue.max_entries_to_merge = 101' \
    "merge_queue.max_entries_to_merge: 101 is above the maximum 100"
schema_reject "a merge queue group wait above the API's 360 minutes" '.github_repos.kure.rulesets["main-protection"].rules.merge_queue.min_entries_to_merge_wait_minutes = 361' \
    "merge_queue.min_entries_to_merge_wait_minutes: 361 is above the maximum 360"
# Bypass actors the rulesets API refuses, though each is the schema's shape.
schema_reject "a DeployKey bypass actor in pull_request mode" '.github_repos.kure.rulesets["main-protection"].bypass_actors = [{actor_id: null, actor_type: "DeployKey", bypass_mode: "pull_request"}]' \
    'github_repos["kure"].rulesets["main-protection"].bypass_actors[0]: bypass_mode pull_request is not applicable to actor_type DeployKey'
schema_reject "pull_request bypass mode on a tag ruleset" '.github_repos.kure.rulesets["main-protection"].target = "tag" | .github_repos.kure.rulesets["main-protection"].bypass_actors = [{actor_id: 5, actor_type: "Team", bypass_mode: "pull_request"}]' \
    'bypass_actors[0]: bypass_mode pull_request applies only to a branch ruleset (target is tag)'
schema_reject "pull_request bypass mode on a ruleset whose github_defaults target is push" '.github_defaults.rulesets["main-protection"].target = "push" | .github_repos.kure.rulesets["main-protection"].bypass_actors = [{actor_id: 5, actor_type: "Team", bypass_mode: "pull_request"}]' \
    'bypass_actors[0]: bypass_mode pull_request applies only to a branch ruleset (target is push)'
schema_reject "a Team bypass actor with a null actor_id" '.github_repos.kure.rulesets["main-protection"].bypass_actors = [{actor_id: null, actor_type: "Team", bypass_mode: "always"}]' \
    'bypass_actors[0]: actor_id is required for actor_type Team'
# The same modes stay accepted where the API accepts them.
bypass_ok_json=$(jq '.github_repos.kure.rulesets["main-protection"].bypass_actors = [{actor_id: 5, actor_type: "Team", bypass_mode: "pull_request"}, {actor_id: null, actor_type: "DeployKey", bypass_mode: "always"}, {actor_id: null, actor_type: "OrganizationAdmin", bypass_mode: "exempt"}]' <<<"$POLICY_JSON")
bypass_ok_out=$( (POLICY_JSON="$bypass_ok_json" validate_policy) 2>&1 )
assert_eq "validate_policy accepts pull_request mode for a Team on a branch ruleset, and null actor_id for DeployKey and OrganizationAdmin" "0" "$?"
assert_eq "with no bypass actor error" "0" "$(grep -c 'rulesets API refuses' <<<"$bypass_ok_out")"
schema_reject "an invalid ruleset enforcement" '.github_defaults.rulesets["main-protection"].enforcement = "on"' \
    "main-protection.enforcement: \"on\" is not one of"
schema_reject "an invalid squash commit title" '.github_defaults.squash_merge_commit_title = "PR_TITEL"' \
    "github_defaults.squash_merge_commit_title: \"PR_TITEL\" is not one of"
schema_reject "a SETTING_KEYS entry missing from github_defaults" 'del(.github_defaults.has_wiki)' \
    "github_defaults: missing required key \"has_wiki\""
schema_reject "a github_org.actions key left out (would be PUT as null)" 'del(.github_org.actions.sha_pinning_required)' \
    "github_org.actions: missing required key \"sha_pinning_required\""
schema_reject "a misspelled security key under .github" '.github_repos[".github"].security.secret_scaning = "enabled"' \
    'github_repos[".github"].security.secret_scaning: unknown key'
# The defaults must declare every security key: the audit skips one no tier
# declares, so an omission would stop governing it without a word.
schema_reject "github_defaults without a security block" 'del(.github_defaults.security)' \
    'github_defaults: missing required key "security"'
schema_reject "a null github_defaults security block" '.github_defaults.security = null' \
    "github_defaults.security: expected object, got null"
schema_reject "github_defaults security without dependabot_security_updates" 'del(.github_defaults.security.dependabot_security_updates)' \
    'github_defaults.security: missing required key "dependabot_security_updates"'

# go-kure/.github#158: the repo actions block. Optional as a whole, closed,
# typed; declared in github_defaults it must set all three keys, or the
# omitted one would stay unmanaged on every repo without an override.
ACTIONS_DEFAULTS='{sha_pinning_required: true, default_workflow_permissions: "read", can_approve_pull_request_reviews: false}'
schema_reject "a default_workflow_permissions outside read|write" ".github_defaults.actions = $ACTIONS_DEFAULTS | .github_defaults.actions.default_workflow_permissions = \"admin\"" \
    'github_defaults.actions.default_workflow_permissions: "admin" is not one of'
schema_reject "a string sha_pinning_required in an override" '.github_repos.kure.actions = {sha_pinning_required: "true"}' \
    "github_repos.kure.actions.sha_pinning_required: expected boolean, got string"
schema_reject "a misspelled actions key in an override" '.github_repos.kure.actions = {sha_pining_required: true}' \
    "github_repos.kure.actions.sha_pining_required: unknown key"
schema_reject "allowed_actions in a repo actions block (not managed per repo)" '.github_repos.kure.actions = {allowed_actions: "all"}' \
    "github_repos.kure.actions.allowed_actions: unknown key"
schema_reject "a github_defaults actions block missing a key" ".github_defaults.actions = $ACTIONS_DEFAULTS | del(.github_defaults.actions.can_approve_pull_request_reviews)" \
    'github_defaults.actions: missing required key "can_approve_pull_request_reviews"'
actions_ok_json=$(jq ".github_defaults.actions = $ACTIONS_DEFAULTS | .github_repos.kure.actions = {sha_pinning_required: false}" <<<"$POLICY_JSON")
(POLICY_JSON="$actions_ok_json" validate_policy) >/dev/null 2>&1
assert_eq "validate_policy accepts a full defaults actions block with a partial override" "0" "$?"
override_only_json=$(jq '.github_repos.kure.actions = {default_workflow_permissions: "write"}' <<<"$POLICY_JSON")
(POLICY_JSON="$override_only_json" validate_policy) >/dev/null 2>&1
assert_eq "validate_policy accepts an override actions block with no defaults block" "0" "$?"
assert_eq "this repo's own policy declares no actions block (Actions permissions not managed yet)" "null" \
    "$(jq -c '[.github_defaults.actions, (.github_repos // {} | .[] | .actions?)] | map(select(. != null)) | if length == 0 then null else . end' <<<"$POLICY_JSON")"

# Every actor type the rulesets API accepts passes, User included, and the
# payload carries it unchanged.
user_actor_json=$(jq '.github_repos.kure.rulesets["release-protection"].bypass_actors = [{actor_id: 123, actor_type: "User", bypass_mode: "always"}]' <<<"$POLICY_JSON")
user_actor_out=$( (POLICY_JSON="$user_actor_json" validate_policy) 2>&1 )
assert_eq "validate_policy accepts a User bypass actor" "0" "$?"
assert_eq "with no schema error" "0" "$(grep -c 'actor_type' <<<"$user_actor_out")"
assert_eq "the payload carries the User bypass actor unchanged" '[{"actor_id":123,"actor_type":"User","bypass_mode":"always"}]' \
    "$(POLICY_JSON="$user_actor_json" build_ruleset_payload kure release-protection | jq -Sc '.bypass_actors')"

# A file of the wrong shape skips the semantic checks instead of crashing
# them: a string repos: scope would otherwise reach `.repos[]`.
scope_string_json=$(jq '.github_defaults.rulesets["main-protection"].repos = "kure"' <<<"$POLICY_JSON")
scope_string_out=$( (POLICY_JSON="$scope_string_json" validate_policy) 2>&1 )
scope_string_rc=$?
assert_eq "validate_policy refuses a string repos: scope with exit 1" "1" "$scope_string_rc"
assert_contains "with the schema error" "$scope_string_out" "main-protection.repos: expected array, got string"
assert_eq "and no jq error from the scope check it skipped" "0" "$(grep -c 'jq: error' <<<"$scope_string_out")"

# The labels schema reaches every field too.
label_colour_fixture="$(mktemp)"
printf '%s\n' '{"labels": [{"name": "area/x", "colour": "#000000", "color": "#000000", "description": "d"}]}' >"$label_colour_fixture"
label_colour_out=$( (LABELS_FILE="$label_colour_fixture" validate_policy) 2>&1 )
label_colour_rc=$?
rm -f "$label_colour_fixture"
assert_eq "validate_policy refuses an unknown key on a label" "1" "$([ "$label_colour_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "and names it" "$label_colour_out" "labels[0].colour: unknown key"

# A schema this validator cannot apply is an error, never a pass.
bad_schema_fixture="$(mktemp)"
printf '%s\n' '{"type": "object", "patternProperties": {"^x": true}}' >"$bad_schema_fixture"
bad_schema_out=$( (POLICY_SCHEMA_FILE="$bad_schema_fixture" validate_policy) 2>&1 )
bad_schema_rc=$?
rm -f "$bad_schema_fixture"
assert_eq "validate_policy fails when the policy schema uses an unsupported keyword" "1" "$([ "$bad_schema_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "and says the check could not run" "$bad_schema_out" "could not check"
assert_contains "naming the keyword" "$bad_schema_out" "unsupported keyword(s) patternProperties"

# The same for the labels schema: a check that could not run is not reported
# as a malformed labels file.
bad_labels_schema_fixture="$(mktemp)"
printf '%s\n' '{"type": "object", "patternProperties": {"^x": true}}' >"$bad_labels_schema_fixture"
bad_labels_schema_out=$( (LABELS_SCHEMA_FILE="$bad_labels_schema_fixture" validate_policy) 2>&1 )
bad_labels_schema_rc=$?
rm -f "$bad_labels_schema_fixture"
assert_eq "validate_policy fails when the labels schema uses an unsupported keyword" "1" "$([ "$bad_labels_schema_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "and says the labels check could not run" "$bad_labels_schema_out" "could not check $LABELS_FILE"
assert_eq "and does not call the labels file malformed" "0" "$(grep -cF -- "is malformed" <<<"$bad_labels_schema_out")"

# ---- ruleset_applies scoping ----

if ruleset_applies "kure" "$COPILOT"; then
    echo "PASS: Copilot ruleset applies to kure"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: Copilot ruleset should apply to kure"
    failures=$((failures + 1))
fi

if ! ruleset_applies ".github" "$COPILOT"; then
    echo "PASS: Copilot ruleset does not apply to .github"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: Copilot ruleset should not apply to .github"
    failures=$((failures + 1))
fi

# main-protection is repos:-scoped. Assert every managed repo individually:
# scoping it to fewer repos than intended would silently leave an existing
# branch protection unmanaged, and no other assertion would notice.
for managed_repo in .github kure launcher; do
    if ruleset_applies "$managed_repo" "main-protection"; then
        echo "PASS: main-protection applies to $managed_repo"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: main-protection should apply to $managed_repo"
        failures=$((failures + 1))
    fi
done

# go-kure.github.io is a Pages content repo: the kure/launcher deploy-docs
# workflows and its own gen-sitemap-index job write main directly, and it runs
# none of the lint/test/build/rebase-check contexts this ruleset requires.
if ! ruleset_applies "go-kure.github.io" "main-protection"; then
    echo "PASS: main-protection does not apply to go-kure.github.io"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: main-protection must not apply to go-kure.github.io (bots write main directly)"
    failures=$((failures + 1))
fi

# release-protection covers the release/vX.Y branches that only kure and
# launcher cut (go-kure/.github#237).
for scope_repo in kure launcher; do
    if ruleset_applies "$scope_repo" "release-protection"; then
        echo "PASS: release-protection applies to $scope_repo"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: release-protection should apply to $scope_repo"
        failures=$((failures + 1))
    fi
done
for scope_repo in .github go-kure.github.io; do
    if ! ruleset_applies "$scope_repo" "release-protection"; then
        echo "PASS: release-protection does not apply to $scope_repo"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: release-protection should not apply to $scope_repo"
        failures=$((failures + 1))
    fi
done

# GitHub refuses a ruleset that has a merge queue and a wildcard ref (HTTP
# 422, "Wildcard ref names are not supported when merge queue is enabled"),
# and --apply used to report that as FAILED yet still exit 0 — so
# main-protection with release/* added passed CI and never applied on
# kure/launcher (go-kure/.github#237). --apply now exits 1 on it
# (go-kure/.github#242), but only at apply time, after merge; this check
# catches it in CI instead. Check every ruleset the policy would send.
queue_wildcards=""
mapfile -t policy_ruleset_names < <(ruleset_names)
for scope_repo in .github kure launcher go-kure.github.io; do
    for scope_name in "${policy_ruleset_names[@]}"; do
        ruleset_applies "$scope_repo" "$scope_name" || continue
        hit=$(build_ruleset_payload "$scope_repo" "$scope_name" | jq -r '
            select(any(.rules[]; .type == "merge_queue"))
            | .conditions.ref_name.include[]
            | select(test("[*?\\[]") or . == "~ALL")')
        if [ -n "$hit" ]; then
            queue_wildcards+="$scope_repo/$scope_name: $hit"$'\n'
        fi
    done
done
assert_eq "no ruleset with a merge queue matches a wildcard ref" "" "$queue_wildcards"

for scope_repo in kure launcher; do
    release_payload=$(build_ruleset_payload "$scope_repo" "release-protection")
    assert_eq "$scope_repo release-protection payload rule types (no merge_queue)" \
        "deletion,non_fast_forward,pull_request,required_linear_history,required_status_checks" \
        "$(jq -r '[.rules[].type] | sort | join(",")' <<<"$release_payload")"
    assert_eq "$scope_repo release-protection covers release/* only" '["refs/heads/release/*"]' \
        "$(jq -c '.conditions.ref_name.include' <<<"$release_payload")"
    assert_eq "$scope_repo release-protection requires up-to-date branches (strict)" "true" \
        "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.strict_required_status_checks_policy' <<<"$release_payload")"
    assert_eq "$scope_repo release-protection lets a branch be created from a tag" "true" \
        "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.do_not_enforce_on_create' <<<"$release_payload")"
    assert_eq "$scope_repo release-protection requires main's checks" '["build","lint","pr-review / AI Code Review","test"]' \
        "$(jq -c '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context] | sort' <<<"$release_payload")"
    assert_eq "$scope_repo release-protection lets the release bot push" '[{"actor_id":2882845,"actor_type":"Integration","bypass_mode":"always"}]' \
        "$(jq -Sc '.bypass_actors' <<<"$release_payload")"
done

# ---- build_ruleset_payload: the direct regression test for the core bug
# this unit of work exists to fix — a payload builder that only knew 6
# hardcoded rule types silently dropped anything else (e.g. copilot_code_review)
# on the next full-replace PUT. If this payload doesn't carry exactly the
# Copilot rule, --apply would still delete it today. ----

copilot_payload=$(build_ruleset_payload "kure" "$COPILOT")
assert_eq "Copilot payload has exactly 1 rule" "1" "$(jq '.rules | length' <<<"$copilot_payload")"
assert_eq "Copilot payload rule type" "copilot_code_review" "$(jq -r '.rules[0].type' <<<"$copilot_payload")"
assert_eq "Copilot payload enforcement" "disabled" "$(jq -r '.enforcement' <<<"$copilot_payload")"
assert_eq "Copilot payload target" "branch" "$(jq -r '.target' <<<"$copilot_payload")"
assert_eq "Copilot payload conditions" '~DEFAULT_BRANCH' "$(jq -r '.conditions.ref_name.include[0]' <<<"$copilot_payload")"
assert_eq "Copilot payload rule parameters" \
    '{"review_draft_pull_requests":true,"review_on_push":true}' \
    "$(jq -Sc '.rules[0].parameters' <<<"$copilot_payload")"

main_payload=$(build_ruleset_payload "kure" "main-protection")
assert_eq "kure main-protection payload has 6 rules" "6" \
    "$(jq '.rules | length' <<<"$main_payload")"
assert_eq "kure main-protection payload rule types" \
    "deletion,merge_queue,non_fast_forward,pull_request,required_linear_history,required_status_checks" \
    "$(jq -r '[.rules[].type] | sort | join(",")' <<<"$main_payload")"

# go-kure/.github#108: pr-review / AI Code Review is now a required context on
# kure/launcher (the queue_protection override), deliberately NOT on .github
# (org default) — see governance/repository-settings-policy.yaml's inline
# comment and docs/standards.md's "Same-repo composite actions and the
# pin-bump procedure" section.
assert_eq "kure main-protection payload requires pr-review context" "true" \
    "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks | map(.context) | index("pr-review / AI Code Review") != null' <<<"$main_payload")"

# A policy that does not name do_not_enforce_on_create leaves it to the API
# default: the payload must not send it.
assert_eq "kure main-protection payload leaves do_not_enforce_on_create unset" "false" \
    "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters | has("do_not_enforce_on_create")' <<<"$main_payload")"

launcher_payload=$(build_ruleset_payload "launcher" "main-protection")
assert_eq "launcher main-protection payload requires pr-review context" "true" \
    "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks | map(.context) | index("pr-review / AI Code Review") != null' <<<"$launcher_payload")"

github_main_payload=$(build_ruleset_payload ".github" "main-protection")
assert_eq ".github main-protection payload has no merge_queue (no override)" \
    "deletion,non_fast_forward,pull_request,required_linear_history,required_status_checks" \
    "$(jq -r '[.rules[].type] | sort | join(",")' <<<"$github_main_payload")"
assert_eq ".github main-protection keeps rebase-check context" "true" \
    "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks | map(.context) | index("rebase-check") != null' <<<"$github_main_payload")"
assert_eq ".github main-protection does NOT require pr-review context" "false" \
    "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks | map(.context) | index("pr-review / AI Code Review") != null' <<<"$github_main_payload")"

# ---- ruleset_diff: the comparison engine shared by audit_rulesets and
# ruleset_has_drift. Crafted "live API" fixtures, no gh needed. ----

copilot_live_match=$(jq -n --arg t "$COPILOT" '{
    id: 19397361, name: $t, target: "branch", enforcement: "disabled",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    bypass_actors: [],
    rules: [{type: "copilot_code_review", parameters: {review_on_push: true, review_draft_pull_requests: true}}]
}')

diff_clean=$(ruleset_diff "kure" "$COPILOT" "$copilot_live_match")
diff_clean_bad=$(awk -F'\t' '$1 != "OK"' <<<"$diff_clean")
assert_eq "clean Copilot ruleset produces zero non-OK diff records" "" "$diff_clean_bad"

copilot_live_dropped=$(jq '.rules = []' <<<"$copilot_live_match")
diff_dropped=$(ruleset_diff "kure" "$COPILOT" "$copilot_live_dropped")
assert_contains "a dropped copilot_code_review rule is reported MISSING" "$diff_dropped" "$(printf 'MISSING\trules.copilot_code_review')"

main_live_match=$(jq -n '{
    id: 12903081, name: "main-protection", target: "branch", enforcement: "active",
    conditions: {ref_name: {include: ["refs/heads/main"], exclude: []}},
    bypass_actors: [{actor_id: 2882845, actor_type: "Integration", bypass_mode: "always"}],
    rules: [
        {type: "deletion"}, {type: "non_fast_forward"}, {type: "required_linear_history"},
        {type: "pull_request", parameters: {
            required_approving_review_count: 0, dismiss_stale_reviews_on_push: false,
            require_code_owner_review: false, require_last_push_approval: false,
            required_review_thread_resolution: true,
            dismissal_restriction: {enabled: false}, required_reviewers: []
        }},
        {type: "required_status_checks", parameters: {
            strict_required_status_checks_policy: false,
            required_status_checks: [{context: "lint"}, {context: "test"}, {context: "build"}, {context: "pr-review / AI Code Review"}],
            do_not_enforce_on_create: false
        }},
        {type: "merge_queue", parameters: {
            merge_method: "REBASE", grouping_strategy: "ALLGREEN",
            min_entries_to_merge: 1, max_entries_to_merge: 1, max_entries_to_build: 1,
            min_entries_to_merge_wait_minutes: 0, check_response_timeout_minutes: 60
        }}
    ]
}')

diff_main_clean=$(ruleset_diff "kure" "main-protection" "$main_live_match")
diff_main_clean_bad=$(awk -F'\t' '$1 != "OK"' <<<"$diff_main_clean")
assert_eq "clean kure main-protection (with API-only pull_request extras) produces zero non-OK records" "" "$diff_main_clean_bad"

main_live_strict_drift=$(jq '(.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy) = true' <<<"$main_live_match")
diff_main_strict=$(ruleset_diff "kure" "main-protection" "$main_live_strict_drift")
assert_contains "a strict=true drift on kure is reported WRONG" "$diff_main_strict" "$(printf 'WRONG\trules.required_status_checks.strict\tfalse\ttrue')"

# release/* moved to release-protection (go-kure/.github#237); a live
# main-protection still covering it must read as drift, not as clean.
main_live_with_release=$(jq '.conditions.ref_name.include += ["refs/heads/release/*"]' <<<"$main_live_match")
diff_main_with_release=$(ruleset_diff "kure" "main-protection" "$main_live_with_release")
assert_contains "a main-protection still covering release/* is reported WRONG" "$diff_main_with_release" "$(printf 'WRONG\tconditions')"

release_live_match=$(jq -n '{
    id: 1, name: "release-protection", target: "branch", enforcement: "active",
    conditions: {ref_name: {include: ["refs/heads/release/*"], exclude: []}},
    bypass_actors: [{actor_id: 2882845, actor_type: "Integration", bypass_mode: "always"}],
    rules: [
        {type: "deletion"}, {type: "non_fast_forward"}, {type: "required_linear_history"},
        {type: "pull_request", parameters: {
            required_approving_review_count: 0, dismiss_stale_reviews_on_push: false,
            require_code_owner_review: false, require_last_push_approval: false,
            required_review_thread_resolution: true,
            dismissal_restriction: {enabled: false}, required_reviewers: []
        }},
        {type: "required_status_checks", parameters: {
            strict_required_status_checks_policy: true,
            required_status_checks: [{context: "lint"}, {context: "test"}, {context: "build"}, {context: "pr-review / AI Code Review"}],
            do_not_enforce_on_create: true
        }}
    ]
}')

for release_repo in kure launcher; do
    diff_release_clean=$(ruleset_diff "$release_repo" "release-protection" "$release_live_match")
    diff_release_clean_bad=$(awk -F'\t' '$1 != "OK"' <<<"$diff_release_clean")
    assert_eq "clean $release_repo release-protection produces zero non-OK records" "" "$diff_release_clean_bad"
done

release_live_with_queue=$(jq '.rules += [$m]' --argjson m "$(jq -c '.rules[] | select(.type == "merge_queue")' <<<"$main_live_match")" <<<"$release_live_match")
diff_release_queue=$(ruleset_diff "kure" "release-protection" "$release_live_with_queue")
assert_contains "a merge_queue on release-protection is reported EXTRA" "$diff_release_queue" "$(printf 'EXTRA\trules.merge_queue')"

release_live_enforced_on_create=$(jq '(.rules[] | select(.type == "required_status_checks") | .parameters.do_not_enforce_on_create) = false' <<<"$release_live_match")
diff_release_on_create=$(ruleset_diff "kure" "release-protection" "$release_live_enforced_on_create")
assert_contains "checks enforced on branch creation are reported WRONG on release-protection" "$diff_release_on_create" \
    "$(printf 'WRONG\trules.required_status_checks.do_not_enforce_on_create\ttrue\tfalse')"

# do_not_enforce_on_create: false is the API default. A policy declaring it
# (here as kure's override of the inherited true) is clean whether the API
# echoes false or omits the key, and a live true is drift against it, as it is
# against main-protection, which leaves it unset.
explicit_false_json=$(jq '.github_repos.kure.rulesets["release-protection"].rules.required_status_checks.do_not_enforce_on_create = false' <<<"$POLICY_JSON")
assert_eq "a repo override of the inherited do_not_enforce_on_create: true sends false" "false" \
    "$(POLICY_JSON="$explicit_false_json" build_ruleset_payload "kure" "release-protection" | jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.do_not_enforce_on_create')"
release_live_omitted=$(jq '(.rules[] | select(.type == "required_status_checks") | .parameters) |= del(.do_not_enforce_on_create)' <<<"$release_live_match")
for live in "$release_live_enforced_on_create" "$release_live_omitted"; do
    diff_explicit_false=$(POLICY_JSON="$explicit_false_json" ruleset_diff "kure" "release-protection" "$live")
    assert_eq "explicit do_not_enforce_on_create: false produces zero non-OK records" "" \
        "$(awk -F'\t' '$1 != "OK"' <<<"$diff_explicit_false")"
done
diff_false_live_true=$(POLICY_JSON="$explicit_false_json" ruleset_diff "kure" "release-protection" "$release_live_match")
assert_contains "a live do_not_enforce_on_create: true against a policy false is reported WRONG" "$diff_false_live_true" \
    "$(printf 'WRONG\trules.required_status_checks.do_not_enforce_on_create\tfalse\ttrue')"
main_live_create_exempt=$(jq '(.rules[] | select(.type == "required_status_checks") | .parameters.do_not_enforce_on_create) = true' <<<"$main_live_match")
diff_main_create_exempt=$(ruleset_diff "kure" "main-protection" "$main_live_create_exempt")
assert_contains "a live do_not_enforce_on_create: true where policy leaves it unset is reported WRONG" "$diff_main_create_exempt" \
    "$(printf 'WRONG\trules.required_status_checks.do_not_enforce_on_create\tfalse\ttrue')"

# ---- build_ruleset_import_jq: strips API-only pull_request fields, flags
# an injected unmodeled rule type instead of silently dropping it. ----

import_filter=$(build_ruleset_import_jq)
imported=$(jq "$import_filter" <<<"$main_live_match")
assert_eq "import strips dismissal_restriction from pull_request" "null" \
    "$(jq -r '.rules.pull_request.dismissal_restriction // "null"' <<<"$imported")"
assert_eq "import maps required_status_checks to policy shape" '{"contexts":["lint","test","build","pr-review / AI Code Review"],"do_not_enforce_on_create":false,"strict":false}' \
    "$(jq -Sc '.rules.required_status_checks' <<<"$imported")"
assert_eq "import keeps a live do_not_enforce_on_create: true" "true" \
    "$(jq "$import_filter" <<<"$release_live_match" | jq -r '.rules.required_status_checks.do_not_enforce_on_create')"
assert_eq "import reads a live ruleset without do_not_enforce_on_create as false" "false" \
    "$(jq "$import_filter" <<<"$release_live_omitted" | jq -r '.rules.required_status_checks.do_not_enforce_on_create')"
assert_eq "import reports no unmapped rule types for a fully-modeled ruleset" "[]" \
    "$(jq -c '.unmapped_rule_types' <<<"$imported")"

main_live_with_unmodeled=$(jq '.rules += [{type: "code_scanning", parameters: {code_scanning_tools: []}}]' <<<"$main_live_match")
imported_unmodeled=$(jq "$import_filter" <<<"$main_live_with_unmodeled")
assert_eq "import flags an injected unmodeled rule type" '["code_scanning"]' \
    "$(jq -c '.unmapped_rule_types' <<<"$imported_unmodeled")"

# #279: a live ruleset with no rules (empty or absent .rules) imports as one
# with every flag false and no parameterized rule, keeping its other fields.
for rules_case in empty absent; do
    if [ "$rules_case" = empty ]; then
        live_no_rules=$(jq '.rules = []' <<<"$main_live_match")
    else
        live_no_rules=$(jq 'del(.rules)' <<<"$main_live_match")
    fi
    imported_no_rules_rc=0
    imported_no_rules=$(jq "$import_filter" <<<"$live_no_rules" 2>&1) || imported_no_rules_rc=$?
    assert_eq "#279: import of a ruleset with $rules_case rules succeeds" "0" "$imported_no_rules_rc"
    assert_eq "#279: $rules_case rules import with no parameterized rule and every flag false" "[]" \
        "$(jq -c '[.rules | to_entries[] | select(.value != false) | .key]' <<<"$imported_no_rules" 2>&1)"
    assert_eq "#279: $rules_case rules report no unmapped rule types" "[]" \
        "$(jq -c '.unmapped_rule_types' <<<"$imported_no_rules" 2>&1)"
    assert_eq "#279: $rules_case rules keep enforcement, target and bypass actors" \
        "$(jq -c '[.enforcement, .target, (.bypass_actors // [])]' <<<"$main_live_match")" \
        "$(jq -c '[.enforcement, .target, .bypass_actors]' <<<"$imported_no_rules" 2>&1)"
done
# The audit side reads the same live ruleset: an absent .rules reports every
# expected rule MISSING, with no jq error.
diff_no_rules=$(ruleset_diff "kure" "main-protection" "$(jq 'del(.rules)' <<<"$main_live_match")" 2>&1)
assert_contains "#279: ruleset_diff reports an expected rule MISSING when .rules is absent" "$diff_no_rules" \
    "$(printf 'MISSING\trules.pull_request\t-\t-')"
assert_eq "#279: ruleset_diff prints no jq error when .rules is absent" "0" \
    "$(grep -c 'Cannot iterate' <<<"$diff_no_rules")"

# ---- org_policy_json: no override tier, straight read of .github_org ----

assert_eq "org_policy_json resolves a top-level scalar" "read" \
    "$(org_policy_json default_repository_permission | jq -r '.')"
assert_eq "org_policy_json resolves a nested actions key" '"all"' \
    "$(org_policy_json actions.allowed_actions)"
assert_eq "org_policy_json resolves a false-valued key to false, not null" "false" \
    "$(org_policy_json members_can_create_internal_repositories)"
assert_eq "org_policy_json returns null for an absent key" "null" \
    "$(org_policy_json this_key_does_not_exist)"

# ---- validate_policy on github_org: same bidirectional-parity and enum
# checks as the repo tier, exercised the same way (temporarily override
# POLICY_JSON for one subshell call — bash gives a shell function its own
# copy of a var-prefixed assignment for the call's duration, same pattern
# the bogus_policy_json test above already relies on). ----

org_extra_key_json=$(jq '.github_org.bogus_org_key = true' <<<"$POLICY_JSON")
org_extra_out=$( (POLICY_JSON="$org_extra_key_json" validate_policy) 2>&1 )
org_extra_rc=$?
if [ "$org_extra_rc" -ne 0 ]; then
    echo "PASS: validate_policy rejects a github_org key not in ORG_SETTING_KEYS/ORG_READONLY_KEYS"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: validate_policy should reject an unmodeled github_org key"
    failures=$((failures + 1))
fi
assert_contains "validate_policy's github_org error names the offending key" "$org_extra_out" "bogus_org_key"

org_missing_key_json=$(jq 'del(.github_org.web_commit_signoff_required)' <<<"$POLICY_JSON")
org_missing_rc=$( (POLICY_JSON="$org_missing_key_json" validate_policy) >/dev/null 2>&1; echo $? )
if [ "$org_missing_rc" -ne 0 ]; then
    echo "PASS: validate_policy rejects an ORG_SETTING_KEYS entry missing from github_org"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: validate_policy should reject a governed org key absent from github_org"
    failures=$((failures + 1))
fi

org_bad_enum_json=$(jq '.github_org.actions.allowed_actions = "nonsense"' <<<"$POLICY_JSON")
org_bad_enum_out=$( (POLICY_JSON="$org_bad_enum_json" validate_policy) 2>&1 )
org_bad_enum_rc=$?
if [ "$org_bad_enum_rc" -ne 0 ]; then
    echo "PASS: validate_policy rejects an invalid github_org.actions enum value"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: validate_policy should reject actions.allowed_actions=nonsense"
    failures=$((failures + 1))
fi
assert_contains "validate_policy's actions-enum error names the offending key" "$org_bad_enum_out" "allowed_actions"

# ---- ruleset_names_missing: the set-difference behind --import's "policy
# ruleset expected but not found live (deleted?)" warning. ----

assert_eq "ruleset_names_missing detects a live-deleted ruleset" '["b"]' \
    "$(ruleset_names_missing '["a","b","c"]' '["a","c"]')"
assert_eq "ruleset_names_missing returns empty when nothing is missing" '[]' \
    "$(ruleset_names_missing '["a","b"]' '["a","b","c"]')"

# ---- bash_array_to_json: printf on a zero-element bash array still emits
# one blank line, which jq turns into [""] instead of [] unless guarded.
# Regression test for a review-caught bug in the first version of this
# helper's call sites (empty applicable_names + non-empty existing names
# produced a spurious "" entry in ruleset_names_missing's output). ----

assert_eq "bash_array_to_json returns [] for zero elements (printf blank-line guard)" "[]" \
    "$(bash_array_to_json)"
assert_eq "bash_array_to_json converts a populated array" '["a","b"]' \
    "$(bash_array_to_json a b)"
assert_eq "ruleset_names_missing via the real empty-array construction path returns [] (not [\"\"])" '[]' \
    "$(ruleset_names_missing "$(bash_array_to_json)" "$(bash_array_to_json "Some Live Ruleset")")"

# ---- ruleset_diff: bypass_actors must compare the full actor object (id,
# actor_type, bypass_mode), not just actor_id — a live actor with the same
# id but a widened bypass_mode is real drift, and the id-only comparison
# used to miss it entirely. ----

main_live_mode_drift=$(jq '(.bypass_actors[0].bypass_mode) = "pull_request"' <<<"$main_live_match")
diff_main_mode_drift=$(ruleset_diff "kure" "main-protection" "$main_live_mode_drift")
assert_contains "a bypass_mode-only drift (same actor_id) is reported WRONG" "$diff_main_mode_drift" "$(printf 'WRONG\tbypass_actors')"

copilot_live_unexpected_actor=$(jq '.bypass_actors = [{actor_id: 1, actor_type: "Integration", bypass_mode: "always"}]' <<<"$copilot_live_match")
diff_copilot_unexpected_actor=$(ruleset_diff "kure" "$COPILOT" "$copilot_live_unexpected_actor")
assert_contains "a live bypass actor where policy expects none is reported WRONG" "$diff_copilot_unexpected_actor" "$(printf 'WRONG\tbypass_actors')"

# ---- validate_policy: GITHUB_REPOS narrowed to a subset for a single run
# (documented behavior) must not misreport policy-known repos: scope entries
# (e.g. Copilot's repos: [kure, launcher]) as unknown. ----

subset_rc=$( (GITHUB_REPOS=".github" validate_policy) >/dev/null 2>&1; echo $? )
if [ "$subset_rc" -eq 0 ]; then
    echo "PASS: validate_policy accepts the real policy under a GITHUB_REPOS=.github subset"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: validate_policy should not reject known repos: scope entries omitted from a GITHUB_REPOS subset"
    failures=$((failures + 1))
fi

typo_scope_json=$(jq '.github_defaults.rulesets["main-protection"].repos = ["totally-bogus-repo"]' <<<"$POLICY_JSON")
typo_out=$( (POLICY_JSON="$typo_scope_json" GITHUB_REPOS=".github" validate_policy) 2>&1 )
typo_rc=$?
if [ "$typo_rc" -ne 0 ]; then
    echo "PASS: validate_policy still rejects a genuine repos: scope typo under a GITHUB_REPOS subset"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: validate_policy should still catch a repo name not in GITHUB_REPOS_DEFAULT or GITHUB_REPOS"
    failures=$((failures + 1))
fi
assert_contains "validate_policy's scope-typo error names the offending repo" "$typo_out" "totally-bogus-repo"

# ---- Thin-consumer overrides: GITHUB_REPOS_DEFAULT, LABELS_FILE and
# POLICY_FILE are read from the environment at source time (the go-kure
# values are only defaults), so another org can run the script unchanged
# against its own files. Sourced in a fresh bash so this file's own sourcing
# above (which already fixed the globals) does not mask the default path. ----

# shellcheck disable=SC2016 # single-quoted on purpose: the child bash expands these after sourcing, not this shell
consumer_env=$(env -u GITHUB_REPOS GITHUB_ORG=other-org GITHUB_REPOS_DEFAULT="alpha beta" LABELS_FILE=/x/labels.json POLICY_FILE=/x/policy.yaml \
    bash -c 'source "$1" && printf "%s|%s|%s|%s|%s" "$GITHUB_ORG" "$GITHUB_REPOS_DEFAULT" "$GITHUB_REPOS" "$LABELS_FILE" "$POLICY_FILE"' _ "$ROOT/scripts/github-settings.sh")
assert_eq "env overrides win for org, repo set, labels file and policy file; GITHUB_REPOS follows GITHUB_REPOS_DEFAULT" \
    "other-org|alpha beta|alpha beta|/x/labels.json|/x/policy.yaml" "$consumer_env"

# shellcheck disable=SC2016 # single-quoted on purpose: same reason as above
default_env=$(env -u GITHUB_ORG -u GITHUB_REPOS -u GITHUB_REPOS_DEFAULT -u LABELS_FILE -u POLICY_FILE \
    bash -c 'source "$1" && printf "%s|%s|%s|%s" "$GITHUB_ORG" "$GITHUB_REPOS_DEFAULT" "${LABELS_FILE#"$REPO_ROOT"/}" "${POLICY_FILE#"$REPO_ROOT"/}"' _ "$ROOT/scripts/github-settings.sh")
assert_eq "with nothing set, the go-kure defaults still apply" \
    "go-kure|.github kure launcher go-kure.github.io|standards/labels.json|governance/repository-settings-policy.yaml" "$default_env"

# A consumer's policy scopes rulesets to ITS repos; validate_policy must judge
# them against the overridden GITHUB_REPOS_DEFAULT, not the go-kure set.
consumer_scope_json=$(jq '.github_defaults.rulesets |= map_values(.repos = ["alpha"]) | .github_repos = {}' <<<"$POLICY_JSON")
# A consumer brings its own labels file too; its repos: scopes are judged
# against the same overridden set (check 4b), so go-kure's file (scoped to
# kure/launcher) would be — correctly — rejected here.
consumer_labels_fixture="$(mktemp)"
printf '%s\n' '{"labels": [{"name": "area/x", "color": "#000000", "description": "d", "repos": ["alpha"]}, {"name": "security", "color": "#000000", "description": "d"}]}' >"$consumer_labels_fixture"
consumer_scope_rc=$( (POLICY_JSON="$consumer_scope_json" LABELS_FILE="$consumer_labels_fixture" GITHUB_REPOS_DEFAULT="alpha beta" GITHUB_REPOS="alpha" validate_policy) >/dev/null 2>&1; echo $? )
rm -f "$consumer_labels_fixture"
if [ "$consumer_scope_rc" -eq 0 ]; then
    echo "PASS: validate_policy accepts repos: scopes drawn from an overridden GITHUB_REPOS_DEFAULT"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: validate_policy should validate repos: scopes against the overridden GITHUB_REPOS_DEFAULT"
    failures=$((failures + 1))
fi

# ---- ruleset_names / ruleset_applies: a ruleset declared only under
# github_repos.<repo>.rulesets (no github_defaults counterpart — e.g. an
# --import dump of an unmanaged live ruleset pasted as directed) must be
# discoverable and scoped to just that repo. ----

repo_only_json=$(jq '.github_repos.kure.rulesets["Repo-Only Ruleset"] = {target: "branch", enforcement: "active", conditions: {}, rules: {}}' <<<"$POLICY_JSON")

names_with_repo_only=$(POLICY_JSON="$repo_only_json" ruleset_names)
assert_contains "ruleset_names includes a repo-only ruleset with no github_defaults entry" "$names_with_repo_only" "Repo-Only Ruleset"

if (POLICY_JSON="$repo_only_json" ruleset_applies "kure" "Repo-Only Ruleset"); then
    echo "PASS: a repo-only ruleset applies to the repo that declares it"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: a repo-only ruleset should apply to the repo that declares it"
    failures=$((failures + 1))
fi

if ! (POLICY_JSON="$repo_only_json" ruleset_applies "launcher" "Repo-Only Ruleset"); then
    echo "PASS: a repo-only ruleset does not apply to a repo that doesn't declare it"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: a repo-only ruleset should not apply anywhere it isn't explicitly declared"
    failures=$((failures + 1))
fi

# ---- ruleset_covers_branch: audit_rulesets migrates classic branch
# protection away only when an applicable branch ruleset reaches the branch
# (go-kure/.github#154 review finding: a consumer policy with no such ruleset
# must not lose unmanaged classic protection on --apply with nothing replacing
# it). Most cases below judge main with main as the default branch. ----

covers_json=$(jq '.github_repos.kure.rulesets = {
    "Main Literal": {target: "branch", conditions: {ref_name: {include: ["refs/heads/main"]}}, rules: {deletion: true}},
    "Default Branch": {target: "branch", conditions: {ref_name: {include: ["~DEFAULT_BRANCH"]}}, rules: {deletion: true}},
    "Dev Only": {target: "branch", conditions: {ref_name: {include: ["refs/heads/dev"]}}, rules: {deletion: true}},
    "Tags": {target: "tag", conditions: {ref_name: {include: ["refs/tags/*"]}}, rules: {deletion: true}},
    "Disabled Main": {target: "branch", enforcement: "disabled", conditions: {ref_name: {include: ["refs/heads/main"]}}, rules: {deletion: true}},
    "Evaluate Main": {target: "branch", enforcement: "evaluate", conditions: {ref_name: {include: ["refs/heads/main"]}}, rules: {deletion: true}},
    "All But Main": {target: "branch", conditions: {ref_name: {include: ["~ALL"], exclude: ["refs/heads/main"]}}, rules: {deletion: true}},
    "All But Default": {target: "branch", conditions: {ref_name: {include: ["~ALL"], exclude: ["~DEFAULT_BRANCH"]}}, rules: {deletion: true}},
    "No Rules": {target: "branch", conditions: {ref_name: {include: ["refs/heads/main"]}}, rules: {}},
    "False Rules": {target: "branch", conditions: {ref_name: {include: ["refs/heads/main"]}}, rules: {deletion: false}},
    "Glob Include": {target: "branch", conditions: {ref_name: {include: ["refs/heads/ma*"]}}, rules: {deletion: true}},
    "All But Glob": {target: "branch", conditions: {ref_name: {include: ["~ALL"], exclude: ["refs/heads/ma*"]}}, rules: {deletion: true}},
    "All But Releases": {target: "branch", conditions: {ref_name: {include: ["~ALL"], exclude: ["refs/heads/release/*"]}}, rules: {deletion: true}},
    "Dotted Near Miss": {target: "branch", conditions: {ref_name: {include: ["refs/heads/main.x"]}}, rules: {deletion: true}},
    "Bracket Exclude": {target: "branch", conditions: {ref_name: {include: ["~ALL"], exclude: ["refs/heads/ma[!x]n"]}}, rules: {deletion: true}},
    "Bracket Include": {target: "branch", conditions: {ref_name: {include: ["refs/heads/ma[i]n"]}}, rules: {deletion: true}},
    "Star Include": {target: "branch", conditions: {ref_name: {include: ["refs/*"]}}, rules: {deletion: true}},
    "Double Star Include": {target: "branch", conditions: {ref_name: {include: ["refs/**"]}}, rules: {deletion: true}},
    "Heads Double Star Include": {target: "branch", conditions: {ref_name: {include: ["refs/heads/**"]}}, rules: {deletion: true}},
    "Recursive Include": {target: "branch", conditions: {ref_name: {include: ["refs/**/main"]}}, rules: {deletion: true}},
    "All But Recursive Main": {target: "branch", conditions: {ref_name: {include: ["~ALL"], exclude: ["refs/heads/**/main"]}}, rules: {deletion: true}},
    "Question Include": {target: "branch", conditions: {ref_name: {include: ["refs/heads/mai?"]}}, rules: {deletion: true}},
    "All But Star": {target: "branch", conditions: {ref_name: {include: ["~ALL"], exclude: ["refs/*"]}}, rules: {deletion: true}},
    "Copilot Only": {target: "branch", conditions: {ref_name: {include: ["refs/heads/main"]}}, rules: {copilot_code_review: {review_on_push: true, review_draft_pull_requests: false}}},
    "Copilot Plus Deletion": {target: "branch", conditions: {ref_name: {include: ["refs/heads/main"]}}, rules: {copilot_code_review: {review_on_push: true, review_draft_pull_requests: false}, deletion: true}}
}' <<<"$POLICY_JSON")

# Stubbed like get_github_labels below: the live default branch is whatever
# COVERS_DEFAULT_BRANCH says (main unless a test sets it; empty = unreadable).
# shellcheck disable=SC2317 # invoked indirectly via audit_rulesets
repo_default_branch() { printf '%s' "${COVERS_DEFAULT_BRANCH-main}"; }

# Echoes ruleset_covers_branch's exit code for kure's main branch over the
# named rulesets, with the default branch the stub above reports.
covers_rc() {
    (POLICY_JSON="$covers_json" ruleset_covers_branch "kure" main "$(repo_default_branch kure)" "$@") >/dev/null 2>&1
    echo $?
}

# The same for an explicit branch and default branch (go-kure/.github#160:
# the protected branch is the repo's default branch, not always main).
covers_branch_rc() { # BRANCH DEFAULT_BRANCH NAME...
    local branch="$1" def="$2"
    shift 2
    (POLICY_JSON="$covers_json" ruleset_covers_branch "kure" "$branch" "$def" "$@") >/dev/null 2>&1
    echo $?
}

assert_eq "a branch ruleset including refs/heads/main covers main" "0" "$(covers_rc "Main Literal")"
assert_eq "a branch ruleset including ~DEFAULT_BRANCH covers main" "0" "$(covers_rc "Default Branch")"
assert_eq "a branch ruleset on another branch does not cover main" "1" "$(covers_rc "Dev Only")"
assert_eq "a tag ruleset never covers main, whatever it includes" "1" "$(covers_rc "Tags")"
assert_eq "no applicable ruleset at all does not cover main" "1" "$(covers_rc)"
assert_eq "one covering ruleset among non-covering ones is enough" "0" "$(covers_rc "Tags" "Dev Only" "Main Literal")"
assert_eq "a disabled ruleset on main enforces nothing and does not cover it" "1" "$(covers_rc "Disabled Main")"
assert_eq "an evaluate-mode ruleset on main enforces nothing and does not cover it" "1" "$(covers_rc "Evaluate Main")"
assert_eq "~ALL with main excluded again does not cover main" "1" "$(covers_rc "All But Main")"
assert_eq "a disabled main ruleset next to an active one still covers (the active one counts)" "0" "$(covers_rc "Disabled Main" "Main Literal")"
assert_eq "~ALL with the default branch excluded does not cover main when the default branch is main" "1" "$(covers_rc "All But Default")"
assert_eq "an active main ruleset that declares no rules restricts nothing and does not cover main" "1" "$(covers_rc "No Rules")"
assert_eq "a rules-less main ruleset beside a real one still covers (the real one counts)" "0" "$(covers_rc "No Rules" "Main Literal")"
assert_eq "a flag rule declared false is omitted from the payload and does not count as a rule" "1" "$(covers_rc "False Rules")"

# Ref-name conditions are fnmatch patterns (round-7 finding): a glob that
# matches main counts, in the include and in the exclude list; a glob that
# does not match main is inert; regex metacharacters in a ref are literal.
assert_eq "a glob include matching main covers main" "0" "$(covers_rc "Glob Include")"
assert_eq "~ALL with a glob exclude matching main does not cover main" "1" "$(covers_rc "All But Glob")"
assert_eq "~ALL with a glob exclude that does not match main still covers main" "0" "$(covers_rc "All But Releases")"
assert_eq "a dotted near-miss (refs/heads/main.x) is literal and does not cover main" "1" "$(covers_rc "Dotted Near Miss")"
# Bracket expressions are fnmatch too but are not translated; they fail closed
# on both sides (round-8 finding): an exclude with one may remove main, an
# include with one is never trusted to reach it.
assert_eq "~ALL with a bracket-expression exclude that matches main does not cover main" "1" "$(covers_rc "Bracket Exclude")"
assert_eq "a bracket-expression include is not trusted to cover main" "1" "$(covers_rc "Bracket Include")"
# A single `*` does not cross `/` in GitHub's fnmatch (round-9 finding), so
# `refs/*` never reaches refs/heads/main as an include. On the exclude side the
# same `*` is read as wide as possible, so `refs/*` counts as possibly removing
# main. Both directions err towards "not covered".
assert_eq "a single-star include (refs/*) is not trusted to reach main" "1" "$(covers_rc "Star Include")"
# `**` crosses `/` only as a whole `**/` segment, which matches zero or more
# directories (File.fnmatch with FNM_PATHNAME; #160 round 1). A trailing `**`
# is a plain `*`, so refs/** does not reach refs/heads/main but refs/heads/**
# does. A `**/` in an exclude matches zero directories too, so
# refs/heads/**/main removes main itself.
assert_eq "a trailing double-star include (refs/**) stays in one segment and does not reach main" "1" "$(covers_rc "Double Star Include")"
assert_eq "a trailing double-star include in the last segment (refs/heads/**) reaches main" "0" "$(covers_rc "Heads Double Star Include")"
assert_eq "a recursive include (refs/**/main) reaches main" "0" "$(covers_rc "Recursive Include")"
assert_eq "~ALL with a recursive exclude (refs/heads/**/main) does not cover main" "1" "$(covers_rc "All But Recursive Main")"
assert_eq "a ? include matching one character of main covers main" "0" "$(covers_rc "Question Include")"
assert_eq "~ALL with a single-star exclude (refs/*) is read as possibly removing main" "1" "$(covers_rc "All But Star")"
# Only a rule that blocks a push or a merge counts (round-10 finding): a
# ruleset whose sole emitted rule is copilot_code_review is review automation
# and replaces no branch protection.
assert_eq "a main ruleset carrying only copilot_code_review does not cover main" "1" "$(covers_rc "Copilot Only")"
assert_eq "copilot_code_review beside a protective rule still covers main" "0" "$(covers_rc "Copilot Plus Deletion")"

# ~DEFAULT_BRANCH is resolved against the live repo, never assumed to be main
# (go-kure/.github#154 round-4 finding): on a repo whose default branch is
# something else, a ~DEFAULT_BRANCH ruleset protects that branch, not main.
assert_eq "~DEFAULT_BRANCH does not cover main when the default branch is master" "1" "$(COVERS_DEFAULT_BRANCH=master covers_rc "Default Branch")"
assert_eq "a literal refs/heads/main include still covers main whatever the default branch" "0" "$(COVERS_DEFAULT_BRANCH=master covers_rc "Main Literal")"
assert_eq "~ALL minus ~DEFAULT_BRANCH covers main when the default branch is master" "0" "$(COVERS_DEFAULT_BRANCH=master covers_rc "All But Default")"
assert_eq "an unreadable default branch resolves ~DEFAULT_BRANCH to not-main (fail closed)" "1" "$(COVERS_DEFAULT_BRANCH='' covers_rc "Default Branch")"
assert_eq "an unreadable default branch with ~DEFAULT_BRANCH excluded from ~ALL does not cover main (round-5: the exclude is undecidable too)" "1" "$(COVERS_DEFAULT_BRANCH='' covers_rc "All But Default")"
assert_eq "an unreadable default branch leaves a literal refs/heads/main ruleset covering main" "0" "$(COVERS_DEFAULT_BRANCH='' covers_rc "Main Literal")"
# The predicate judges whichever branch it is given (go-kure/.github#160).
assert_eq "~DEFAULT_BRANCH covers master when master is the default branch" "0" "$(covers_branch_rc master master "Default Branch")"
assert_eq "a literal refs/heads/main include does not cover master" "1" "$(covers_branch_rc master master "Main Literal")"
assert_eq "~ALL minus ~DEFAULT_BRANCH does not cover master when master is the default branch" "1" "$(covers_branch_rc master master "All But Default")"
assert_eq "a glob include (refs/heads/ma*) covers master too" "0" "$(covers_branch_rc master master "Glob Include")"
unset -f repo_default_branch

# ---- print_summary: blocked (audit-only) org settings drift must be
# reported separately from applied drift under --apply, not folded into the
# "applied" count (nothing was actually written for a blocked key). ----

summary_out=$( (SETTINGS_OK=5 SETTINGS_MISSING=2 SETTINGS_BLOCKED=1 JSON_OUTPUT=false print_summary true) 2>&1 )
assert_contains "print_summary (--apply) keeps the applied count exclusive of blocked settings" "$summary_out" "2 applied"
assert_contains "print_summary (--apply) reports blocked settings separately" "$summary_out" "1 blocked (audit-only, unresolved)"

# ---- print_summary: a label DUPLICATE (old and new spelling coexisting —
# go-kure/.github#122's launcher status::deferred/status/deferred case) must
# fail an audit run's exit status, not just print a line nobody's exit-code
# check reads. This is the regression guard for #122's second review round:
# LABELS_BLOCKED already fed total_issues via SETTINGS_BLOCKED-shaped logic,
# but the newer LABELS_DUPLICATE counter did not, until this fix. ----

dup_audit_rc=$( (LABELS_DUPLICATE=1 JSON_OUTPUT=false print_summary false) >/dev/null 2>&1; echo $? )
if [ "$dup_audit_rc" -eq 1 ]; then
    echo "PASS: print_summary (audit) exits non-zero when a label DUPLICATE is present"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: print_summary (audit) should exit 1 on a label DUPLICATE, got rc=$dup_audit_rc"
    failures=$((failures + 1))
fi

dup_audit_out=$( (LABELS_DUPLICATE=1 JSON_OUTPUT=false print_summary false) 2>&1 )
assert_contains "print_summary (audit) reports the duplicate count" "$dup_audit_out" "1 duplicate"

# --apply can't auto-fix a DUPLICATE (it needs a human to pick which issues
# move where — see the DUPLICATE echo at github-settings.sh:871), so an
# apply run intentionally still exits 0 on one; the daily audit-mode cron
# is the real gate. Pin that as a decision, not a silent gap.
dup_apply_rc=$( (LABELS_DUPLICATE=1 JSON_OUTPUT=false print_summary true) >/dev/null 2>&1; echo $? )
if [ "$dup_apply_rc" -eq 0 ]; then
    echo "PASS: print_summary (--apply) still exits 0 on an unresolved duplicate (audit mode is the gate)"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: print_summary (--apply) unexpectedly changed exit behavior on a label DUPLICATE, got rc=$dup_apply_rc"
    failures=$((failures + 1))
fi

# ---- print_summary: label metadata DRIFT (go-kure/.github#125 — a
# name-matched label whose live color/description no longer matches
# labels.json) must fail an audit run's exit status, the same way DUPLICATE
# does above. ----

drift_audit_rc=$( (LABELS_DRIFT=1 JSON_OUTPUT=false print_summary false) >/dev/null 2>&1; echo $? )
if [ "$drift_audit_rc" -eq 1 ]; then
    echo "PASS: print_summary (audit) exits non-zero when label metadata DRIFT is present"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: print_summary (audit) should exit 1 on label metadata DRIFT, got rc=$drift_audit_rc"
    failures=$((failures + 1))
fi

drift_audit_out=$( (LABELS_DRIFT=1 JSON_OUTPUT=false print_summary false) 2>&1 )
assert_contains "print_summary (audit) reports the drift count" "$drift_audit_out" "1 metadata drift"

# Unlike DUPLICATE, --apply *can* auto-fix DRIFT (audit_labels PATCHes the
# label before print_summary ever runs) — so print_summary exiting 0 here
# reflects that the fix already happened, not an unresolved gap the way the
# DUPLICATE case above is. Pin the exit code and the reworded summary text.
drift_apply_rc=$( (LABELS_DRIFT=1 JSON_OUTPUT=false print_summary true) >/dev/null 2>&1; echo $? )
if [ "$drift_apply_rc" -eq 0 ]; then
    echo "PASS: print_summary (--apply) exits 0 on label metadata DRIFT (already patched by audit_labels)"
    pass_count=$((pass_count + 1))
else
    echo "FAIL: print_summary (--apply) unexpectedly changed exit behavior on label metadata DRIFT, got rc=$drift_apply_rc"
    failures=$((failures + 1))
fi

drift_apply_out=$( (LABELS_DRIFT=1 JSON_OUTPUT=false print_summary true) 2>&1 )
assert_contains "print_summary (--apply) reports the drift count as updated" "$drift_apply_out" "1 metadata updated"

# ---- url_encode_label: the '/' case is the only one that matters here, and
# it is the one urllib.parse.quote()'s default safe='/' silently skips. Every
# label this repo governs outside the special/process ones is namespaced, so a
# no-op encoder looks correct on every casual reading. Pin the slash. ----

assert_eq "url_encode_label percent-encodes the namespace slash" \
    "area%2Fcli" "$(url_encode_label 'area/cli')"
assert_eq "url_encode_label leaves an unnamespaced label alone" \
    "docs-skip" "$(url_encode_label 'docs-skip')"
assert_eq "url_encode_label encodes the legacy '::' separator's neighbours safely" \
    "status%3A%3Ablocked" "$(url_encode_label 'status::blocked')"

# ---------------------------------------------------------------------------
# audit_labels() metadata-drift detection — a new seam, not an existing
# pattern. audit_labels() calls get_github_labels() (real gh api call) and
# reads $LABELS_FILE (real standards/labels.json, 42 live labels, no
# override hook previously existed for either). Two levers make this
# testable without touching the network:
#   - LABELS_FILE is a plain global var; the source-and-call harness above
#     already relies on later-definition-wins for functions, and the same
#     applies to reassigning a global after sourcing.
#   - get_github_labels is a plain bash function; redefining it AFTER
#     sourcing github-settings.sh shadows the original, because bash looks
#     up a function by name at CALL time, not at definition time. audit_labels
#     calls it as a bare `get_github_labels "$repo"`, so it picks up whichever
#     definition is current when audit_labels actually runs.
# Both levers are restored after each fixture via a trap-free explicit
# reset, since these are the only tests in the file that touch them.
# ---------------------------------------------------------------------------

drift_fixture_dir="$(mktemp -d)"
trap 'rm -rf "$drift_fixture_dir"' EXIT
DRIFT_LABELS_FILE="$drift_fixture_dir/labels.json"
cat >"$DRIFT_LABELS_FILE" <<'EOF'
{"labels": [{"name": "test/foo", "color": "#AABBCC", "description": "expected desc"}]}
EOF

# run_audit_labels_fixture LIVE_ROW — stubs get_github_labels to return
# exactly one \x1f-delimited row, points LABELS_FILE at the one-label
# fixture above, resets the counters this test cares about, runs
# audit_labels in audit mode (no real API calls — LIVE_ROW already IS the
# "existing" state), and echoes "LABELS_OK,LABELS_DRIFT\toutput".
# Deliberately NOT run inside a `$(...)` command substitution: that forks a
# subshell, and LABELS_OK/LABELS_DRIFT would increment only in the
# subshell's copy — invisible to this function's caller once it returns.
# audit_labels runs directly in the current shell instead, with its output
# redirected to a temp file, so the real global counters are what the
# caller reads back.
run_audit_labels_fixture() {
    local live_row="$1" out_file
    # shellcheck disable=SC2317 # invoked indirectly via audit_labels -> get_github_labels
    get_github_labels() { printf '%s\n' "$live_row"; }
    out_file="$(mktemp)"
    # shellcheck disable=SC2034 # read by audit_labels() via global scope, defined in the sourced github-settings.sh, invisible to this file's lint
    LABELS_FILE="$DRIFT_LABELS_FILE"
    LABELS_OK=0
    LABELS_DRIFT=0
    audit_labels "drift-test-repo" "false" >"$out_file" 2>&1
    printf '%s,%s\t%s' "$LABELS_OK" "$LABELS_DRIFT" "$(cat "$out_file")"
    rm -f "$out_file"
}

# The fixture color is #AABBCC, not a digits-only hex: every case below has to
# distinguish a casing difference from a real one, and 112233 lowercased is
# still 112233 — a digits-only fixture makes the normalization cases pass
# whether or not the comparison lowercases anything at all.
#
# color differs only — 112233 vs the fixture's AABBCC is a REAL difference in
# either casing, so this isolates the color half of the comparison.
result="$(run_audit_labels_fixture $'test/foo\x1f112233\x1fexpected desc')"
assert_eq "color-only drift is detected, not counted OK" "0,1" "${result%%$'\t'*}"
assert_contains "color-only drift prints WRONG" "${result#*$'\t'}" "WRONG: test/foo"

# description differs only
result="$(run_audit_labels_fixture $'test/foo\x1faabbcc\x1fstale desc')"
assert_eq "description-only drift is detected" "0,1" "${result%%$'\t'*}"

# both differ
result="$(run_audit_labels_fixture $'test/foo\x1f112233\x1fstale desc')"
assert_eq "drift in both color and description is still just one drifted label" "0,1" "${result%%$'\t'*}"

# Exact match, and the normalization pin in one: this is the real-world pairing
# — the GitHub API returns colors lowercased ('5319e7') while labels.json
# stores them uppercase ('#5319E7'). Drop either `tr` call in audit_labels and
# aabbcc stops matching AABBCC, so this assertion flips to drift and fails.
result="$(run_audit_labels_fixture $'test/foo\x1faabbcc\x1fexpected desc')"
assert_eq "a lowercase live color matches the uppercase standard (no false drift)" "1,0" "${result%%$'\t'*}"

# live description missing entirely (API returns null -> get_github_labels
# emits "" for that field) — must read as drift against a non-empty expected
# description, not as a parse failure.
result="$(run_audit_labels_fixture $'test/foo\x1faabbcc\x1f')"
assert_eq "an empty/null live description is drift, not a crash" "0,1" "${result%%$'\t'*}"

# The other casing direction — a live value that already matches the standard's
# casing must not be treated as drift either, so neither side is assumed to
# arrive in a particular case.
result="$(run_audit_labels_fixture $'test/foo\x1fAABBCC\x1fexpected desc')"
assert_eq "an uppercase live color matches the uppercase standard" "1,0" "${result%%$'\t'*}"

# ---------------------------------------------------------------------------
# Rename-map keys vs a labels file that does not declare the target
# (go-kure/.github#154 review finding). The extra-label loop used to skip every
# LABEL_RENAME_MAP key unconditionally, so a consumer whose labels file omits
# type/bug never saw a live `bug` label reported at all — not a rename
# candidate, not extra. Same harness as above; echoes "LABELS_EXTRA\toutput".
# ---------------------------------------------------------------------------
run_audit_labels_extra_fixture() {
    local live_row="$1" labels_file="$2" out_file
    # shellcheck disable=SC2317 # invoked indirectly via audit_labels -> get_github_labels
    get_github_labels() { printf '%s\n' "$live_row"; }
    out_file="$(mktemp)"
    # shellcheck disable=SC2034 # read by audit_labels() via global scope
    LABELS_FILE="$labels_file"
    LABELS_EXTRA=0
    audit_labels "drift-test-repo" "false" >"$out_file" 2>&1
    printf '%s\t%s' "$LABELS_EXTRA" "$(cat "$out_file")"
    rm -f "$out_file"
}

RENAME_UNDECLARED_FILE="$drift_fixture_dir/labels-no-target.json"
cat >"$RENAME_UNDECLARED_FILE" <<'EOF'
{"labels": [{"name": "test/foo", "color": "#AABBCC", "description": "expected desc"}]}
EOF
RENAME_DECLARED_FILE="$drift_fixture_dir/labels-with-target.json"
cat >"$RENAME_DECLARED_FILE" <<'EOF'
{"labels": [{"name": "type/bug", "color": "#D73A4A", "description": "Something is broken"}]}
EOF
RENAME_SCOPED_ELSEWHERE_FILE="$drift_fixture_dir/labels-target-elsewhere.json"
cat >"$RENAME_SCOPED_ELSEWHERE_FILE" <<'EOF'
{"labels": [{"name": "type/bug", "color": "#D73A4A", "description": "Something is broken", "repos": ["some-other-repo"]}]}
EOF

result="$(run_audit_labels_extra_fixture $'bug\x1fd73a4a\x1fdefault' "$RENAME_UNDECLARED_FILE")"
assert_eq "a rename-map key whose target the labels file omits is EXTRA" "1" "${result%%$'\t'*}"
assert_contains "the stranded old name is printed as EXTRA" "${result#*$'\t'}" "EXTRA: bug"

result="$(run_audit_labels_extra_fixture $'bug\x1fd73a4a\x1fdefault' "$RENAME_DECLARED_FILE")"
assert_eq "a rename-map key whose target is declared stays a rename candidate, not extra" "0" "${result%%$'\t'*}"
assert_contains "the declared target produces the RENAME line" "${result#*$'\t'}" "RENAME: bug -> type/bug"

result="$(run_audit_labels_extra_fixture $'bug\x1fd73a4a\x1fdefault' "$RENAME_SCOPED_ELSEWHERE_FILE")"
assert_eq "a target scoped to another repo does not shield the old name on this one" "1" "${result%%$'\t'*}"

# A labels file that declares BOTH the rename source and its target (a
# consumer standard keeping `bug` alongside `type/bug`) makes the source a
# required label, not a legacy one: it must audit as OK and never be renamed
# away, and the target is then plainly missing (created, not renamed onto).
RENAME_BOTH_DECLARED_FILE="$drift_fixture_dir/labels-source-and-target.json"
cat >"$RENAME_BOTH_DECLARED_FILE" <<'EOF'
{"labels": [{"name": "bug", "color": "#D73A4A", "description": "default"}, {"name": "type/bug", "color": "#D73A4A", "description": "Something is broken"}]}
EOF

result="$(run_audit_labels_extra_fixture $'bug\x1fd73a4a\x1fdefault' "$RENAME_BOTH_DECLARED_FILE")"
assert_eq "a rename source the labels file itself declares is not extra" "0" "${result%%$'\t'*}"
assert_contains "the declared source audits as OK, not as a rename candidate" "${result#*$'\t'}" "OK: bug"
assert_contains "its declared target is then MISSING rather than RENAME" "${result#*$'\t'}" "MISSING: type/bug"

# Label names are compared literally, never as regexes (go-kure/.github#154
# round-4 finding): a declared `release/1.0` must not be satisfied by a live
# `release/1x0` — the old grep -x match then looked the metadata up under a
# name that was never fetched and aborted the whole audit under set -u.
REGEX_NAME_FILE="$drift_fixture_dir/labels-regex-name.json"
cat >"$REGEX_NAME_FILE" <<'EOF'
{"labels": [{"name": "release/1.0", "color": "#AABBCC", "description": "expected desc"}]}
EOF

result="$(run_audit_labels_extra_fixture $'release/1x0\x1faabbcc\x1fexpected desc' "$REGEX_NAME_FILE")"
assert_eq "a live name that only regex-matches the declared one is EXTRA" "1" "${result%%$'\t'*}"
assert_contains "the declared name is then plainly MISSING" "${result#*$'\t'}" "MISSING: release/1.0"
assert_contains "and the near-miss live name is EXTRA" "${result#*$'\t'}" "EXTRA: release/1x0"

# The live-name list is fed to grep with printf, never echo (go-kure/.github#154
# round-12 finding): when the only live label is named `-n`, `echo "$list"`
# treats it as an option and prints nothing, so the declared `-n` was reported
# MISSING and --apply would have tried to create a label that already exists.
OPTION_NAME_FILE="$drift_fixture_dir/labels-option-name.json"
cat >"$OPTION_NAME_FILE" <<'EOF'
{"labels": [{"name": "-n", "color": "#AABBCC", "description": "expected desc"}]}
EOF

result="$(run_audit_labels_extra_fixture $'-n\x1faabbcc\x1fexpected desc' "$OPTION_NAME_FILE")"
assert_eq "a live label named -n is not EXTRA" "0" "${result%%$'\t'*}"
assert_contains "and audits as OK against its declaration, not MISSING" "${result#*$'\t'}" "OK: -n"

# ---------------------------------------------------------------------------
# Apply-mode write failures (go-kure/.github#242). Every write used to swallow
# its error: the ruleset and classic-protection paths printed FAILED and moved
# on, the label and settings writes were bare `gh api` calls that --all runs
# under `|| true`, and print_summary returned 0 in apply mode regardless. A
# `gh` function stub (later-definition-wins, same lever as get_github_labels
# above) answers every GET and fails every --method write; each write site
# must then record the failure, and print_summary true must return 1 and name
# it. Each scenario runs in a subshell so APPLY_FAILURES and the stubs cannot
# leak into the next one; the subshell prints the recorded failures.
# ---------------------------------------------------------------------------

# fail_writes_gh — the stub. GETs: the rulesets list returns $STUB_RULESETS,
# classic protection exists, the issue-count query returns 0, and every other
# read returns {}. Anything carrying --method (all writes here) fails.
fail_writes_gh() {
    # shellcheck disable=SC2317,SC2329 # invoked indirectly by the functions under test
    gh() {
        case " $* " in
            *" --method "*) echo "HTTP 422: stub write refused" >&2; return 1 ;;
            *"issue list"*) echo 0 ;;
            *"/rulesets?includes_parents=false"*) printf '%s\n' "${STUB_RULESETS:-[]}" ;;
            *"/branches/main/protection"*) return 0 ;;
            *) echo '{}' ;;
        esac
    }
}

apply_failures_of() {
    printf '%s\n' "${APPLY_FAILURES[@]}"
}

ruleset_create_out="$( (fail_writes_gh; STUB_RULESETS='[]'; APPLY_FAILURES=(); apply_ruleset kure main-protection >/dev/null 2>&1; apply_failures_of) )"
assert_eq "a failed ruleset POST is recorded" "kure: create ruleset 'main-protection'" "$ruleset_create_out"

ruleset_update_out="$( (fail_writes_gh; STUB_RULESETS='[{"name":"main-protection","id":7}]'; APPLY_FAILURES=(); apply_ruleset kure main-protection >/dev/null 2>&1; apply_failures_of) )"
assert_eq "a failed ruleset PUT is recorded" "kure: update ruleset 'main-protection'" "$ruleset_update_out"

classic_out="$( (fail_writes_gh; APPLY_FAILURES=(); remove_classic_branch_protection kure main >/dev/null 2>&1; apply_failures_of) )"
assert_eq "a failed classic-protection DELETE is recorded" "kure: remove classic branch protection on main" "$classic_out"

# ---------------------------------------------------------------------------
# Classic protection is deleted only after the replacement ruleset is live
# (go-kure/.github#160). audit_rulesets used to DELETE classic protection
# before POSTing the ruleset, on the policy's word alone: a failed POST left
# the branch with no protection at all, and even a good one left a window.
# classic_order_gh is a stateful stub over files in $CO_DIR:
#   classic  — classic protection on $CO_BRANCH exists while this file does;
#   listing  — what the rulesets list returns ([] until a POST succeeds);
#   log      — every write, in order ("POST", "DELETE <branch>").
# $CO_LIVE is the full ruleset the live re-read returns once it exists.
# STUB_POST_FAIL=1 refuses the POST; CO_LIST_FAIL=1 fails every list read.
# CO_DECODE=1 percent-decodes each path as the server would, and records the
# path as sent in $CO_DIR/paths.
# ---------------------------------------------------------------------------

classic_order_gh() {
    # shellcheck disable=SC2317,SC2329 # invoked indirectly by the functions under test
    gh() {
        local path="$2" method=GET a prev=""
        for a in "$@"; do
            [ "$prev" = "--method" ] && method="$a"
            prev="$a"
        done
        if [ "${CO_DECODE:-0}" = 1 ]; then
            # Decode the path as the server does, after recording what was sent.
            echo "$method $path" >>"$CO_DIR/paths"
            path=$(printf '%b' "${path//[%]/\\x}")
        fi
        case "$method $path" in
            "GET "*"/branches/$CO_BRANCH/protection") [ -e "$CO_DIR/classic" ] ;;
            "DELETE "*"/branches/$CO_BRANCH/protection") echo "DELETE $CO_BRANCH" >>"$CO_DIR/log"; rm -f "$CO_DIR/classic" ;;
            "GET "*"/branches/"*"/protection") return 1 ;;
            "GET "*"/rulesets?includes_parents=false")
                [ "${CO_LIST_FAIL:-0}" = 1 ] && { echo "HTTP 500" ; return 1; }
                cat "$CO_DIR/listing" ;;
            "POST "*"/rulesets")
                cat >/dev/null
                [ "${STUB_POST_FAIL:-0}" = 1 ] && { echo "HTTP 422: stub POST refused" >&2; return 1; }
                echo POST >>"$CO_DIR/log"
                jq -c '[{name: .name, id: 7}]' <<<"$CO_LIVE" >"$CO_DIR/listing" ;;
            "GET "*"/rulesets/7") printf '%s\n' "$CO_LIVE" ;;
            *) echo '{}' ;;
        esac
    }
}

co_policy_main=$(jq '.github_defaults.rulesets = {} | .github_repos = {kure: {rulesets: {
    "Main Literal": {target: "branch", conditions: {ref_name: {include: ["refs/heads/main"]}}, rules: {deletion: true}}}}}' <<<"$POLICY_JSON")
co_policy_default=$(jq '.github_defaults.rulesets = {} | .github_repos = {kure: {rulesets: {
    "Default Branch": {target: "branch", conditions: {ref_name: {include: ["~DEFAULT_BRANCH"]}}, rules: {deletion: true}}}}}' <<<"$POLICY_JSON")
co_live_main='{"id":7,"name":"Main Literal","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/main"],"exclude":[]}},"rules":[{"type":"deletion"}]}'

# Runs audit_rulesets kure with APPLY ($1) in a fresh state dir and prints
# three tab-separated fields: the write log (comma-joined), whether classic
# protection still exists, and the recorded apply failures (|-joined).
# Inputs via env: CO_POLICY, CO_LIVE, CO_BRANCH, CO_DEFAULT (the default
# branch the stub reports; empty = unreadable), STUB_POST_FAIL, CO_LIST_FAIL.
# The audit's own output goes to $CO_OUT for assert_contains, and
# "<RULESET_MISSING> <print_summary exit status>" to $CO_STATS, so a test can
# check that a kept protection really fails the run and what counts as drift.
CO_OUT="$(mktemp)"
CO_STATS="$(mktemp)"
CO_PATHS="$(mktemp)"
run_classic_order() {
    (
        CO_DIR="$(mktemp -d)"
        echo '[]' >"$CO_DIR/listing"
        : >"$CO_DIR/log"
        : >"$CO_DIR/classic"
        classic_order_gh
        # shellcheck disable=SC2317,SC2329 # invoked indirectly via audit_rulesets
        repo_default_branch() { printf '%s' "${CO_DEFAULT-main}"; }
        POLICY_JSON="$CO_POLICY"
        APPLY_FAILURES=()
        # shellcheck disable=SC2034 # read by print_summary via global scope
        RULESET_MISSING=0 RULESET_OK=0 LABELS_MISSING=0 LABELS_RENAMED=0 LABELS_EXTRA=0 LABELS_DUPLICATE=0 LABELS_DRIFT=0 SETTINGS_MISSING=0 SETTINGS_BLOCKED=0
        audit_rulesets kure "$1" >"$CO_OUT" 2>&1
        local summary_rc=0
        JSON_OUTPUT=false REPORT_ONLY=false print_summary "$1" >/dev/null 2>&1 || summary_rc=$?
        echo "$RULESET_MISSING $summary_rc" >"$CO_STATS"
        cat "$CO_DIR/paths" >"$CO_PATHS" 2>/dev/null || : >"$CO_PATHS"
        printf '%s\t%s\t%s\n' \
            "$(paste -sd, "$CO_DIR/log")" \
            "$([ -e "$CO_DIR/classic" ] && echo kept || echo gone)" \
            "$(IFS='|'; echo "${APPLY_FAILURES[*]}")"
        rm -rf "$CO_DIR"
    )
}

co_summary_rc() { cut -d' ' -f2 "$CO_STATS"; }
co_ruleset_issues() { cut -d' ' -f1 "$CO_STATS"; }

co="$(CO_POLICY="$co_policy_main" CO_LIVE="$co_live_main" CO_BRANCH=main run_classic_order true)"
assert_eq "#160: on --apply the ruleset is POSTed first, then classic protection is deleted" \
    "POST,DELETE main	gone	" "$co"
assert_eq "#160: a completed migration passes the apply run" "0" "$(co_summary_rc)"

co="$(CO_POLICY="$co_policy_main" CO_LIVE="$co_live_main" CO_BRANCH=main STUB_POST_FAIL=1 run_classic_order true)"
assert_eq "#160: a failed ruleset POST keeps classic protection and fails the apply run" \
    "	kept	kure: create ruleset 'Main Literal'|kure: classic branch protection on main kept, replacement ruleset not live" "$co"
assert_contains "#160: and says why it was kept" "$(cat "$CO_OUT")" "replacement ruleset not live"
assert_eq "#160: the kept protection fails the apply run (print_summary exit 1)" "1" "$(co_summary_rc)"

co="$(CO_POLICY="$co_policy_main" CO_LIVE="${co_live_main/\"active\"/\"disabled\"}" CO_BRANCH=main run_classic_order true)"
assert_eq "#160: a POSTed ruleset that is not live-active (disabled) does not replace classic protection" \
    "POST	kept	kure: classic branch protection on main kept, replacement ruleset not live" "$co"
assert_eq "#160: a POSTed but disabled replacement fails the apply run" "1" "$(co_summary_rc)"

co="$(CO_POLICY="$co_policy_main" CO_LIVE="${co_live_main/\"deletion\"/\"copilot_code_review\"}" CO_BRANCH=main run_classic_order true)"
assert_eq "#160: a live ruleset with no protective rule does not replace classic protection" \
    "POST	kept	kure: classic branch protection on main kept, replacement ruleset not live" "$co"
assert_eq "#160: a non-protective replacement fails the apply run" "1" "$(co_summary_rc)"

co="$(CO_POLICY="$co_policy_main" CO_LIVE="$co_live_main" CO_BRANCH=main CO_LIST_FAIL=1 run_classic_order true)"
assert_eq "#160: an unreadable rulesets list keeps classic protection on --apply" \
    "	kept	kure: classic branch protection on main kept, replacement ruleset not live" "$co"
assert_contains "#160: and still reports it" "$(cat "$CO_OUT")" "LEGACY"
assert_eq "#160: an unreadable listing fails the apply run" "1" "$(co_summary_rc)"

co="$(CO_POLICY="$co_policy_main" CO_LIVE="$co_live_main" CO_BRANCH=main run_classic_order false)"
assert_eq "#160: audit mode writes nothing" "	kept	" "$co"
assert_contains "#160: audit mode reports the leftover classic protection" "$(cat "$CO_OUT")" "LEGACY: Classic branch protection on main still exists"
# Two issues: the missing ruleset and the leftover classic protection.
assert_eq "#160: audit mode counts the leftover classic protection as drift" "2" "$(co_ruleset_issues)"
assert_eq "#160: and the audit fails" "1" "$(co_summary_rc)"

# The default branch is resolved once and drives the probe, the coverage
# checks and the delete (go-kure/.github#160 follow-up from #154 round 11).
co_live_default="${co_live_main//Main Literal/Default Branch}"
co_live_default="${co_live_default//refs\/heads\/main/~DEFAULT_BRANCH}"
co="$(CO_POLICY="$co_policy_default" CO_LIVE="$co_live_default" CO_BRANCH=master CO_DEFAULT=master run_classic_order true)"
assert_eq "#160: classic protection on a non-main default branch is migrated on that branch" \
    "POST,DELETE master	gone	" "$co"
assert_eq "#160: and that apply run succeeds" "0" "$(co_summary_rc)"
co="$(CO_POLICY="$co_policy_main" CO_LIVE="$co_live_main" CO_BRANCH=master CO_DEFAULT=master run_classic_order true)"
assert_eq "#160: a main-only ruleset never replaces classic protection on a master default branch" \
    "POST	kept	" "$co"
assert_contains "#160: that case is reported as kept, not as drift" "$(cat "$CO_OUT")" "no policy ruleset targets master"
assert_eq "#160: and does not fail the apply run" "0" "$(co_summary_rc)"
co="$(CO_POLICY="$co_policy_main" CO_LIVE="$co_live_main" CO_BRANCH=master CO_DEFAULT=master run_classic_order false)"
# One issue only: the missing ruleset. The kept classic protection adds none.
assert_eq "#160: in audit mode the uncovered classic protection is not counted as drift" "1" "$(co_ruleset_issues)"

# The branch is percent-encoded in the protection paths (#160 round 3). gh
# sends a path as given and the server decodes it: a default branch named
# `%6dain`, covered by ~DEFAULT_BRANCH, would probe and DELETE classic
# protection on `main`, which no ruleset covers.
co="$(CO_POLICY="$co_policy_default" CO_LIVE="$co_live_default" CO_BRANCH=main CO_DEFAULT='%6dain' CO_DECODE=1 run_classic_order true)"
assert_eq "#160: a default branch that decodes to another branch never touches that branch's protection" \
    "POST	kept	" "$co"
assert_contains "#160: the probe sends the branch percent-encoded" "$(cat "$CO_PATHS")" "GET repos/$GITHUB_ORG/kure/branches/%256dain/protection"
co="$(CO_POLICY="$co_policy_default" CO_LIVE="$co_live_default" CO_BRANCH='rel/a%b' CO_DEFAULT='rel/a%b' CO_DECODE=1 run_classic_order true)"
assert_eq "#160: a default branch with / and % is probed and migrated on itself" \
    "POST,DELETE rel/a%b	gone	" "$co"
assert_contains "#160: its DELETE path encodes / and %" "$(cat "$CO_PATHS")" "DELETE repos/$GITHUB_ORG/kure/branches/rel%2Fa%25b/protection"

# The real repo_default_branch, not the stub: on an HTTP error gh prints the
# error body to stdout and exits non-zero, and that body must not become the
# branch name (#160 round 2).
rdb_out="$(
    # shellcheck disable=SC2329 # stub for the sourced helper below
    gh() { printf '%s\n' '{"message":"Resource not accessible by integration","status":"403"}'; return 1; }
    source "$ROOT/scripts/github-settings.sh"
    repo_default_branch kure
)"
assert_eq "#160: repo_default_branch returns nothing when gh fails, even with output" "" "$rdb_out"
rdb_out="$(
    # shellcheck disable=SC2329 # stub for the sourced helper below
    gh() { printf '%s\n' 'trunk'; }
    source "$ROOT/scripts/github-settings.sh"
    repo_default_branch kure
)"
assert_eq "#160: repo_default_branch returns the branch when gh succeeds" "trunk" "$rdb_out"

# An unreadable default branch is a failure, never a guess (#160 round 1): it
# used to fall back to main, so classic protection on a master default branch
# was never probed and both modes reported nothing.
co="$(CO_POLICY="$co_policy_default" CO_LIVE="$co_live_default" CO_BRANCH=master CO_DEFAULT='' run_classic_order true)"
assert_eq "#160: an unreadable default branch deletes nothing and fails the apply run" \
    "POST	kept	kure: default branch unreadable, classic branch protection not checked" "$co"
assert_contains "#160: and says so" "$(cat "$CO_OUT")" "Could not read the default branch of"
assert_eq "#160: print_summary (--apply) exits 1 on the unreadable default branch" "1" "$(co_summary_rc)"
co="$(CO_POLICY="$co_policy_main" CO_LIVE="$co_live_main" CO_BRANCH=main CO_DEFAULT='' run_classic_order true)"
assert_eq "#160: an unreadable default branch is not guessed as main either" \
    "POST	kept	kure: default branch unreadable, classic branch protection not checked" "$co"
co="$(CO_POLICY="$co_policy_main" CO_LIVE="$co_live_main" CO_BRANCH=main CO_DEFAULT='' run_classic_order false)"
assert_eq "#160: audit mode counts the unreadable default branch" "2" "$(co_ruleset_issues)"
assert_eq "#160: and the audit fails" "1" "$(co_summary_rc)"
rm -f "$CO_OUT" "$CO_STATS" "$CO_PATHS"

# One labels file drives all four label writes: test/foo drifts (PATCH),
# type/bug is renamed from a live `bug` (PATCH new_name), test/new is missing
# (POST), and the live `junk` label is extra and unused (DELETE).
APPLY_LABELS_FILE="$drift_fixture_dir/labels-apply.json"
cat >"$APPLY_LABELS_FILE" <<'EOF'
{"labels": [{"name": "test/foo", "color": "#AABBCC", "description": "expected desc"}, {"name": "type/bug", "color": "#D73A4A", "description": "Something is broken"}, {"name": "test/new", "color": "#000000", "description": "new"}]}
EOF
labels_out="$(
    (
        fail_writes_gh
        # shellcheck disable=SC2317,SC2329 # invoked indirectly via audit_labels
        get_github_labels() { printf '%s\n' $'test/foo\x1f112233\x1fstale desc' $'bug\x1fd73a4a\x1fdefault' $'junk\x1f000000\x1fx'; }
        # shellcheck disable=SC2034 # read by audit_labels() via global scope
        LABELS_FILE="$APPLY_LABELS_FILE"
        APPLY_FAILURES=()
        audit_labels label-repo true >/dev/null 2>&1
        apply_failures_of
    )
)"
assert_contains "a failed label metadata PATCH is recorded" "$labels_out" "label-repo: update label test/foo"
assert_contains "a failed label rename is recorded" "$labels_out" "label-repo: rename label bug -> type/bug"
assert_contains "a failed label create is recorded" "$labels_out" "label-repo: create label test/new"
assert_contains "a failed label delete is recorded" "$labels_out" "label-repo: delete label junk"
assert_eq "exactly the four failed label writes are recorded" "4" "$(grep -c . <<<"$labels_out")"

# The settings writes: every read returns {}, so each governed key differs
# from policy and apply mode attempts (and fails) the write. go-kure.github.io
# keeps github_defaults' dependabot_security_updates: enabled, which a {}
# read reports as disabled, so its automated-security-fixes PUT is attempted
# too (kure overrides it to disabled, which {} already matches).
settings_out="$( (fail_writes_gh; APPLY_FAILURES=(); audit_repo_settings go-kure.github.io true >/dev/null 2>&1; audit_security_settings go-kure.github.io true >/dev/null 2>&1; apply_failures_of) )"
assert_contains "a failed repository settings PATCH is recorded" "$settings_out" "go-kure.github.io: apply repository settings ("
assert_contains "a failed security settings PATCH is recorded" "$settings_out" "go-kure.github.io: apply security settings ("
assert_contains "a failed automated-security-fixes write is recorded" "$settings_out" "go-kure.github.io: set security.dependabot_security_updates to enabled"

# The automated-security-fixes method follows policy: enabling is a PUT,
# disabling a DELETE. This stub accepts every write, prints the method of the
# automated-security-fixes call, and answers every read with $STUB_REPO_JSON.
# go-kure.github.io wants enabled and reads disabled; kure wants disabled and
# reads enabled.
dsu_method_of() {
    (
        # shellcheck disable=SC2317,SC2329 # invoked indirectly by audit_security_settings
        gh() {
            case " $* " in
                *"/automated-security-fixes "*"--method "*)
                    local prev=""
                    for a in "$@"; do
                        [ "$prev" = --method ] && echo "DSU $a"
                        prev="$a"
                    done
                    ;;
                *" --method "*) return 0 ;;
                *) printf '%s\n' "$STUB_REPO_JSON" ;;
            esac
        }
        APPLY_FAILURES=()
        audit_security_settings "$1" true 2>/dev/null | grep '^DSU '
    )
}
assert_eq "enabling dependabot security updates is a PUT" "DSU PUT" \
    "$(STUB_REPO_JSON='{}' dsu_method_of go-kure.github.io)"
assert_eq "disabling dependabot security updates is a DELETE" "DSU DELETE" \
    "$(STUB_REPO_JSON='{"security_and_analysis":{"dependabot_security_updates":{"status":"enabled"}}}' dsu_method_of kure)"

# ---------------------------------------------------------------------------
# Repository Actions permissions (go-kure/.github#158). act_gh stubs the two
# endpoints with crafted live bodies ($ACT_PERMS, $ACT_WF), logs every call
# to $ACT_LOG and every PUT's path and body to $ACT_PUTS, fails a GET whose
# body is the word FAIL (printing an error body, as gh does), and fails every
# PUT when ACT_PUT_FAIL=1. run_repo_actions REPO APPLY POLICY runs
# audit_repo_actions in a subshell under that policy and prints
# "OK=<n> MISSING=<n>", the PUTs, the recorded apply failures, then the
# audit output, one section per line group.
# ---------------------------------------------------------------------------
ACT_LOG="$drift_fixture_dir/act-calls.log"
ACT_PUTS="$drift_fixture_dir/act-puts.log"
act_gh() {
    # shellcheck disable=SC2317,SC2329 # invoked indirectly by the functions under test
    gh() {
        printf '%s\n' "$*" >>"$ACT_LOG"
        local body
        case " $* " in
            *" --method PUT "*)
                printf 'PUT %s %s\n' "${2#"repos/$GITHUB_ORG/"}" "$(jq -Sc .)" >>"$ACT_PUTS"
                [ "${ACT_PUT_FAIL:-0}" = 1 ] && { echo "HTTP 422: stub write refused" >&2; return 1; }
                return 0
                ;;
            *"/actions/permissions/workflow "*) body="$ACT_WF" ;;
            *"/actions/permissions "*) body="$ACT_PERMS" ;;
            *"/rulesets?includes_parents=false "*) body="${ACT_RULESETS:-[]}" ;;
            *"/rulesets/"*) body="${ACT_RULESET:-"{}"}" ;;
            *" repos/$GITHUB_ORG/kure "*) body="${ACT_SETTINGS:-"{}"}" ;;
            *) body='{}' ;;
        esac
        if [ "$body" = FAIL ]; then
            printf '%s\n' '{"message":"Resource not accessible by integration","status":"403"}'
            return 1
        fi
        printf '%s\n' "$body"
    }
}
ACT_OUT="$drift_fixture_dir/act-out.log"
run_repo_actions() {
    local repo="$1" apply="$2" policy="$3"
    : >"$ACT_LOG"
    : >"$ACT_PUTS"
    (
        act_gh
        POLICY_JSON="$policy"
        APPLY_FAILURES=()
        SETTINGS_OK=0
        SETTINGS_MISSING=0
        # Not in a command substitution: the counters and APPLY_FAILURES
        # must be set in this subshell, where they are read back below.
        audit_repo_actions "$repo" "$apply" >"$ACT_OUT" 2>&1
        echo "OK=$SETTINGS_OK MISSING=$SETTINGS_MISSING"
        cat "$ACT_PUTS"
        for f in "${APPLY_FAILURES[@]}"; do echo "FAILURE $f"; done
        cat "$ACT_OUT"
    )
}
ACT_LIVE_PERMS='{"enabled": true, "allowed_actions": "selected", "selected_actions_url": "https://example.invalid/x", "sha_pinning_required": false}'
ACT_LIVE_WF='{"default_workflow_permissions": "write", "can_approve_pull_request_reviews": false}'
act_policy=$(jq ".github_defaults.actions = $ACTIONS_DEFAULTS" <<<"$POLICY_JSON")

# No actions block anywhere: neither endpoint is called and nothing prints —
# a policy without the block is unaffected.
act_out="$(ACT_PERMS="$ACT_LIVE_PERMS" ACT_WF="$ACT_LIVE_WF" run_repo_actions kure true "$POLICY_JSON")"
assert_eq "#158: no actions block: no Actions endpoint is read or written" "" "$(cat "$ACT_LOG")"
assert_eq "#158: no actions block: nothing is counted" "OK=0 MISSING=0" "$(head -n1 <<<"$act_out")"
assert_eq "#158: no actions block: nothing is printed" "1" "$(grep -c . <<<"$act_out")"

# Audit mode: sha_pinning_required (false live, true wanted) and
# default_workflow_permissions (write live, read wanted) drift;
# can_approve_pull_request_reviews matches. Nothing is written.
act_out="$(ACT_PERMS="$ACT_LIVE_PERMS" ACT_WF="$ACT_LIVE_WF" run_repo_actions kure false "$act_policy")"
assert_eq "#158: audit counts one match and two drifts" "OK=1 MISSING=2" "$(head -n1 <<<"$act_out")"
assert_contains "#158: audit reports sha_pinning_required drift" "$act_out" "WRONG: actions.sha_pinning_required = false (should be true)"
assert_contains "#158: audit reports default_workflow_permissions drift" "$act_out" "WRONG: actions.default_workflow_permissions = write (should be read)"
assert_contains "#158: audit reports the matching key OK" "$act_out" "OK: actions.can_approve_pull_request_reviews = false"
assert_eq "#158: audit writes nothing" "" "$(cat "$ACT_PUTS")"

# Apply mode: one PUT per drifted endpoint. The permissions body resends the
# live enabled and allowed_actions (never selected_actions_url, a read-only
# field) and changes only sha_pinning_required.
act_out="$(ACT_PERMS="$ACT_LIVE_PERMS" ACT_WF="$ACT_LIVE_WF" run_repo_actions kure true "$act_policy")"
assert_eq "#158: apply PUTs the permissions endpoint with live enabled/allowed_actions and the policy sha_pinning_required" \
    'PUT kure/actions/permissions {"allowed_actions":"selected","enabled":true,"sha_pinning_required":true}' \
    "$(grep '^PUT kure/actions/permissions ' "$ACT_PUTS")"
assert_eq "#158: apply PUTs the workflow endpoint with both keys" \
    'PUT kure/actions/permissions/workflow {"can_approve_pull_request_reviews":false,"default_workflow_permissions":"read"}' \
    "$(grep '^PUT kure/actions/permissions/workflow ' "$ACT_PUTS")"
assert_contains "#158: apply prints what it sets" "$act_out" "SETTING: actions.sha_pinning_required to true (was: false)"
assert_eq "#158: a successful apply records no failure" "0" "$(grep -c '^FAILURE ' <<<"$act_out")"

# A per-repo override wins over the default: kure turns pinning off, so its
# live false matches and only the workflow endpoint is written.
act_override=$(jq '.github_repos.kure.actions = {sha_pinning_required: false}' <<<"$act_policy")
act_out="$(ACT_PERMS="$ACT_LIVE_PERMS" ACT_WF="$ACT_LIVE_WF" run_repo_actions kure true "$act_override")"
assert_contains "#158: the override's value is what is compared" "$act_out" "OK: actions.sha_pinning_required = false"
assert_eq "#158: an endpoint with no drift is not written" "PUT kure/actions/permissions/workflow" \
    "$(cut -d' ' -f1,2 "$ACT_PUTS")"
# ...and the other repos keep the default.
act_out="$(ACT_PERMS="$ACT_LIVE_PERMS" ACT_WF="$ACT_LIVE_WF" run_repo_actions launcher false "$act_override")"
assert_contains "#158: a repo without the override keeps the default" "$act_out" "WRONG: actions.sha_pinning_required = false (should be true)"

# An override with no defaults block manages just its own key on its own
# repo: only that endpoint is read, the workflow PUT resends the live value
# of the key it does not manage, and other repos read nothing.
act_only=$(jq '.github_repos.kure.actions = {default_workflow_permissions: "read"}' <<<"$POLICY_JSON")
act_out="$(ACT_PERMS="$ACT_LIVE_PERMS" ACT_WF='{"default_workflow_permissions": "write", "can_approve_pull_request_reviews": true}' run_repo_actions kure true "$act_only")"
assert_eq "#158: an override-only key reads only its own endpoint" "0" "$(grep -cE 'actions/permissions( |$)' "$ACT_LOG")"
assert_eq "#158: the workflow PUT resends the unmanaged key as read live" \
    'PUT kure/actions/permissions/workflow {"can_approve_pull_request_reviews":true,"default_workflow_permissions":"read"}' \
    "$(cat "$ACT_PUTS")"
act_out="$(ACT_PERMS="$ACT_LIVE_PERMS" ACT_WF="$ACT_LIVE_WF" run_repo_actions launcher true "$act_only")"
assert_eq "#158: a repo the override does not name reads nothing" "" "$(cat "$ACT_LOG")"

# A failed read is a failure in both modes, never a clean or a guessed
# comparison: audit counts it, apply records it and writes nothing to that
# endpoint (the other endpoint is still audited).
act_out="$(ACT_PERMS=FAIL ACT_WF="$ACT_LIVE_WF" run_repo_actions kure false "$act_policy")"
assert_eq "#158: an unreadable endpoint counts as drift in audit mode" "OK=1 MISSING=2" "$(head -n1 <<<"$act_out")"
assert_contains "#158: and says which endpoint and keys" "$act_out" "FAILED: Could not read repos/$GITHUB_ORG/kure/actions/permissions — actions.sha_pinning_required not audited"
# The summary's exit status comes from the counters this audit run left, in
# the same subshell; the matching-live control shows the status can be 0.
act_audit_rc() {
    (
        act_gh
        POLICY_JSON="$act_policy"
        ACT_PERMS="$1"
        ACT_WF="$2"
        LABELS_MISSING=0 LABELS_RENAMED=0 LABELS_EXTRA=0 LABELS_DUPLICATE=0 LABELS_DRIFT=0
        SETTINGS_OK=0 SETTINGS_MISSING=0 SETTINGS_BLOCKED=0 RULESET_MISSING=0
        APPLY_FAILURES=()
        JSON_OUTPUT=false
        audit_repo_actions kure false
        print_summary false
    ) >/dev/null 2>&1
    echo "$?"
}
act_match_perms='{"enabled": true, "allowed_actions": "all", "sha_pinning_required": true}'
act_match_wf='{"default_workflow_permissions": "read", "can_approve_pull_request_reviews": false}'
assert_eq "#158: and fails the audit (the workflow endpoint matches)" "1" "$(act_audit_rc FAIL "$act_match_wf")"
assert_eq "#158: control: matching live values pass the audit" "0" "$(act_audit_rc "$act_match_perms" "$act_match_wf")"
act_out="$(ACT_PERMS=FAIL ACT_WF=FAIL run_repo_actions kure true "$act_policy")"
assert_contains "#158: apply records an unreadable permissions endpoint" "$act_out" "FAILURE kure: actions/permissions unreadable, Actions permissions not audited"
assert_contains "#158: apply records an unreadable workflow endpoint" "$act_out" "FAILURE kure: actions/permissions/workflow unreadable, Actions permissions not audited"
assert_eq "#158: apply writes nothing after a failed read" "" "$(cat "$ACT_PUTS")"
# A 200 whose body is not the endpoint's shape is unreadable too: {} would
# otherwise compare every key against null.
act_out="$(ACT_PERMS='{}' ACT_WF='[]' run_repo_actions kure true "$act_policy")"
assert_eq "#158: a body of the wrong shape is a failed read, not drift to apply" "2" "$(grep -c '^FAILURE .*unreadable' <<<"$act_out")"
assert_eq "#158: and nothing is written on it" "" "$(cat "$ACT_PUTS")"

# A refused PUT is recorded per endpoint.
act_out="$(ACT_PERMS="$ACT_LIVE_PERMS" ACT_WF="$ACT_LIVE_WF" ACT_PUT_FAIL=1 run_repo_actions kure true "$act_policy")"
assert_contains "#158: a failed permissions PUT is recorded" "$act_out" "FAILURE kure: apply actions/permissions (sha_pinning_required)"
assert_contains "#158: a failed workflow PUT is recorded" "$act_out" "FAILURE kure: apply actions/permissions/workflow (default_workflow_permissions)"

# --import captures the live value of each drifted managed key into an
# actions block; a failed read warns and suppresses "nothing to import".
run_import_actions() {
    local repo="$1" policy="$2"
    : >"$ACT_LOG"
    (
        act_gh
        POLICY_JSON="$policy"
        import_repo "$repo" 2>&1
    )
}
imp_out="$(ACT_PERMS="$ACT_LIVE_PERMS" ACT_WF="$ACT_LIVE_WF" run_import_actions kure "$act_policy")"
assert_eq "#158: --import writes the drifted live values into an actions block" \
    '{"default_workflow_permissions":"write","sha_pinning_required":false}' \
    "$(grep -v '^#' <<<"$imp_out" | yq -oj -I0 '.kure.actions' | jq -Sc .)"
imp_out="$(ACT_PERMS="$ACT_LIVE_PERMS" ACT_WF="$ACT_LIVE_WF" run_import_actions kure "$POLICY_JSON")"
assert_eq "#158: --import without an actions block reads no Actions endpoint" "0" "$(grep -c 'actions/permissions' "$ACT_LOG")"
assert_eq "#158: and prints no actions block" "null" "$(grep -v '^#' <<<"$imp_out" | yq -oj -I0 '.kure.actions')"
# #279: an override cannot remove a parameterized rule an applicable
# github_defaults ruleset declares, so a live ruleset lacking one is left out
# of the YAML and the import exits 1, instead of being offered as paste-ready.
imp_rs_live='{"id": 7, "name": "main-protection", "target": "branch", "enforcement": "active", "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}}, "bypass_actors": [], "rules": []}'
imp_out="$(ACT_RULESETS='[{"id": 7}]' ACT_RULESET="$imp_rs_live" run_import_actions kure "$POLICY_JSON")"
imp_rc=$?
assert_contains "#279: --import warns that a rule-less ruleset cannot drop the default pull_request and required_status_checks rules" "$imp_out" \
    "# WARNING: ruleset 'main-protection' omitted from import: it has no live [\"pull_request\",\"required_status_checks\"] rule(s) that github_defaults declares"
assert_eq "#279: and leaves that ruleset out of the YAML" "null" \
    "$(grep -v '^#' <<<"$imp_out" | yq -oj -I0 '.kure.rulesets["main-protection"]')"
assert_eq "#279: and exits 1" "1" "$imp_rc"
assert_eq "#279: and does not report nothing to import" "0" "$(grep -c 'nothing to import' <<<"$imp_out")"
# The drift check must not close its pipe early: where SIGPIPE is ignored
# (CI runners, mise) the diff's later writes would print "Broken pipe".
imp_out="$( (trap '' PIPE; ACT_RULESETS='[{"id": 7}]' ACT_RULESET="$imp_rs_live" run_import_actions kure "$POLICY_JSON") )"
assert_eq "#279: importing a drifted ruleset with SIGPIPE ignored prints no Broken pipe" "0" "$(grep -c 'Broken pipe' <<<"$imp_out")"
imp_rs_full=$(jq -c '.rules = [{type: "pull_request", parameters: {required_approving_review_count: 1, dismiss_stale_reviews_on_push: false, require_code_owner_review: false, require_last_push_approval: false, required_review_thread_resolution: false}}, {type: "required_status_checks", parameters: {required_status_checks: [{context: "lint"}], strict_required_status_checks_policy: true}}]' <<<"$imp_rs_live")
imp_out="$(ACT_RULESETS='[{"id": 7}]' ACT_RULESET="$imp_rs_full" run_import_actions kure "$POLICY_JSON")"
imp_rc=$?
assert_eq "#279: control: a drifted ruleset that keeps every default parameterized rule draws no such warning" "0" \
    "$(grep -c 'override cannot remove' <<<"$imp_out")"
assert_contains "#279: control: and is imported" "$imp_out" "required_approving_review_count: 1"
assert_eq "#279: control: and exits 0" "0" "$imp_rc"
# A defaults ruleset whose repos: scope excludes the repo is not applied
# there, so a repo-only rule-less copy is expressible and imported as is.
imp_scoped=$(jq '.github_defaults.rulesets["release-protection"].repos = ["launcher"]' <<<"$POLICY_JSON")
imp_rs_rel='{"id": 8, "name": "release-protection", "target": "branch", "enforcement": "active", "conditions": {"ref_name": {"include": ["refs/heads/release/*"], "exclude": []}}, "bypass_actors": [], "rules": []}'
imp_out="$(ACT_RULESETS='[{"id": 8}]' ACT_RULESET="$imp_rs_rel" run_import_actions kure "$imp_scoped")"
imp_rc=$?
assert_eq "#279: a rule-less ruleset on a repo outside the defaults' repos: scope draws no such warning" "0" \
    "$(grep -c 'override cannot remove' <<<"$imp_out")"
assert_eq "#279: and is imported" "active" \
    "$(grep -v '^#' <<<"$imp_out" | yq -r '.kure.rulesets["release-protection"].enforcement')"
assert_eq "#279: and exits 0" "0" "$imp_rc"
imp_out="$(ACT_PERMS=FAIL ACT_WF="$ACT_LIVE_WF" run_import_actions kure "$act_policy")"
assert_contains "#158: --import warns on an unreadable endpoint" "$imp_out" "# WARNING: could not read actions/permissions for kure — actions.sha_pinning_required drift skipped this run"
assert_eq "#158: and does not print sha_pinning_required as captured" "null" \
    "$(grep -v '^#' <<<"$imp_out" | yq -oj -I0 '.kure.actions.sha_pinning_required')"
# With every other section matching, a failed actions read alone must not
# read as "nothing to import". The policy stub manages all three keys and
# matches the readable workflow endpoint exactly, so the unreadable
# permissions endpoint is the only thing standing between this run and
# "nothing to import" (the control below proves the line does print when it
# is readable and matches).
imp_match() {
    (
        act_gh
        # shellcheck disable=SC2317,SC2329 # replaces the sourced helpers for this one call
        gh_policy_json() {
            case "$2" in
                actions.sha_pinning_required) echo true ;;
                actions.default_workflow_permissions) echo '"read"' ;;
                actions.can_approve_pull_request_reviews) echo true ;;
                *) echo null ;;
            esac
        }
        # shellcheck disable=SC2317,SC2329
        gh_policy_value() { echo null; }
        # shellcheck disable=SC2317,SC2329
        ruleset_names() { :; }
        ACT_WF='{"default_workflow_permissions": "read", "can_approve_pull_request_reviews": true}'
        import_repo kure 2>&1
    )
}
assert_eq "#158: control: --import with every section readable and matching says nothing to import" "1" \
    "$(ACT_PERMS='{"enabled": true, "sha_pinning_required": true}' imp_match | grep -c 'nothing to import')"
assert_eq "#158: --import with only a failed actions read never says nothing to import" "0" \
    "$(ACT_PERMS=FAIL imp_match | grep -c 'nothing to import')"
# #279: with no other drift, a ruleset left out because an override cannot
# express it must not read as "nothing to import" either.
imp_only_ruleset() {
    (
        act_gh
        # shellcheck disable=SC2317,SC2329 # replaces the sourced helpers for this one call
        gh_policy_json() { echo null; }
        # shellcheck disable=SC2317,SC2329
        gh_policy_value() { echo null; }
        # shellcheck disable=SC2317,SC2329
        ruleset_names() { echo main-protection; }
        import_repo kure 2>&1
    )
}
imp_out="$(ACT_RULESETS='[{"id": 7}]' ACT_RULESET="$imp_rs_live" imp_only_ruleset)"
assert_contains "#279: an omitted ruleset as the only drift is still warned about" "$imp_out" "override cannot remove"
assert_eq "#279: and never says nothing to import" "0" "$(grep -c 'nothing to import' <<<"$imp_out")"
imp_out="$(ACT_RULESETS='[{"id": 7}]' ACT_RULESET="$imp_rs_full" imp_only_ruleset)"
assert_eq "#279: control: a drifted expressible ruleset as the only drift is imported" "1" \
    "$(grep -c 'required_approving_review_count: 1' <<<"$imp_out")"

# The exit status carries the same verdict: an unread section is an
# incomplete import (1), whether or not anything drifted; a complete one is 0.
import_rc() { if "$@" >/dev/null 2>&1; then echo 0; else echo 1; fi; }
assert_eq "#158: control: --import with every section readable and matching exits 0" "0" \
    "$(ACT_PERMS='{"enabled": true, "sha_pinning_required": true}' import_rc imp_match)"
assert_eq "#158: --import with readable drift exits 0" "0" \
    "$(ACT_PERMS="$ACT_LIVE_PERMS" ACT_WF="$ACT_LIVE_WF" import_rc run_import_actions kure "$act_policy")"
assert_eq "#158: --import with a failed actions read exits 1" "1" \
    "$(ACT_PERMS=FAIL import_rc imp_match)"
assert_eq "#158: --import with a failed actions read and drift elsewhere exits 1" "1" \
    "$(ACT_PERMS=FAIL ACT_WF="$ACT_LIVE_WF" import_rc run_import_actions kure "$act_policy")"
assert_eq "#158: --import with a failed rulesets read exits 1" "1" \
    "$(ACT_PERMS='{"enabled": true, "sha_pinning_required": true}' ACT_RULESETS=FAIL import_rc imp_match)"
assert_eq "#158: --import with one unreadable ruleset exits 1" "1" \
    "$(ACT_PERMS='{"enabled": true, "sha_pinning_required": true}' ACT_RULESETS='[{"id": 7}]' ACT_RULESET=FAIL import_rc imp_match)"
assert_eq "#158: --import with unreadable repository settings exits 1" "1" \
    "$(ACT_PERMS='{"enabled": true, "sha_pinning_required": true}' ACT_SETTINGS=FAIL import_rc imp_match)"
# Through main itself, called as a plain command: inside `if`/`||` bash
# ignores errexit for everything main runs, which would hide exactly the
# unchecked failures these cases exist to catch.
main_import_rc() {
    (
        act_gh
        # shellcheck disable=SC2317,SC2329 # replaces the sourced helpers for this one call
        check_requirements() { :; }
        # shellcheck disable=SC2317,SC2329
        gh_policy_json() { echo null; }
        # shellcheck disable=SC2317,SC2329
        gh_policy_value() { echo null; }
        # shellcheck disable=SC2317,SC2329
        ruleset_names() { :; }
        GITHUB_REPOS="kure"
        main "$@"
    ) >/dev/null 2>&1
    echo "$?"
}
assert_eq "#158: control: main --import on a readable repo exits 0" "0" "$(main_import_rc --import kure)"
assert_eq "#158: main --import with unreadable settings exits 1" "1" "$(ACT_SETTINGS=FAIL main_import_rc --import kure)"
assert_eq "#158: main --import --all with one unreadable ruleset exits 1" "1" \
    "$(ACT_RULESETS='[{"id": 7}]' ACT_RULESET=FAIL main_import_rc --import --all)"
# A readable ruleset the import transform cannot convert (a rule that is not
# an object). A ruleset with no rules converts since #279.
act_unconvertible='{"id": 7, "name": "unmanaged", "target": "branch", "enforcement": "active", "rules": [1]}'
assert_eq "#158: main --import with an unconvertible ruleset fails" "nonzero" \
    "$(rc="$(ACT_RULESETS='[{"id": 7}]' ACT_RULESET="$act_unconvertible" main_import_rc --import kure)"; [ "$rc" -ne 0 ] && echo nonzero || echo "$rc")"
assert_eq "#158: main --import --all with an unconvertible ruleset fails" "nonzero" \
    "$(rc="$(ACT_RULESETS='[{"id": 7}]' ACT_RULESET="$act_unconvertible" main_import_rc --import --all)"; [ "$rc" -ne 0 ] && echo nonzero || echo "$rc")"
# --all keeps going after a repo whose import aborted.
assert_eq "#158: main --import --all imports the next repo after an aborted one" "2" \
    "$(
        (
            act_gh
            # shellcheck disable=SC2317,SC2329 # replaces the sourced helpers for this one call
            check_requirements() { :; }
            # shellcheck disable=SC2317,SC2329
            gh_policy_json() { echo null; }
            # shellcheck disable=SC2317,SC2329
            gh_policy_value() { echo null; }
            # shellcheck disable=SC2317,SC2329
            ruleset_names() { :; }
            GITHUB_REPOS="kure launcher"
            ACT_RULESETS='[{"id": 7}]' ACT_RULESET="$act_unconvertible" main --import --all 2>/dev/null
        ) | grep -c '^# ---- drift from policy'
    )"

org_out="$( (fail_writes_gh; APPLY_FAILURES=(); audit_org_settings true >/dev/null 2>&1; audit_org_actions true >/dev/null 2>&1; apply_failures_of) )"
assert_contains "a failed organization settings PATCH is recorded" "$org_out" "org go-kure: apply organization settings ("
assert_contains "a failed Actions permissions PUT is recorded" "$org_out" "org go-kure: apply Actions permissions"
assert_contains "a failed Actions workflow permissions PUT is recorded" "$org_out" "org go-kure: apply Actions workflow permissions"

# print_summary: apply mode returns 1 and lists each failure; with none it
# still returns 0, and audit mode's own rule is unchanged.
apply_fail_rc=$( (APPLY_FAILURES=("kure: create label test/new" "kure: update ruleset 'main-protection'"); JSON_OUTPUT=false print_summary true) >/dev/null 2>&1; echo $?)
assert_eq "print_summary (--apply) returns 1 when a write failed" "1" "$apply_fail_rc"
apply_fail_out=$( (APPLY_FAILURES=("kure: create label test/new" "kure: update ruleset 'main-protection'"); JSON_OUTPUT=false print_summary true) 2>&1)
assert_contains "print_summary (--apply) counts the failed writes" "$apply_fail_out" "2 apply-mode write(s) failed"
assert_contains "print_summary (--apply) names the failed label write" "$apply_fail_out" "FAILED: kure: create label test/new"
assert_contains "print_summary (--apply) names the failed ruleset write" "$apply_fail_out" "FAILED: kure: update ruleset 'main-protection'"
apply_ok_rc=$( (APPLY_FAILURES=(); LABELS_MISSING=3 JSON_OUTPUT=false print_summary true) >/dev/null 2>&1; echo $?)
assert_eq "print_summary (--apply) returns 0 when every write went through" "0" "$apply_ok_rc"
audit_fail_ignored_rc=$( (APPLY_FAILURES=("kure: create label x"); JSON_OUTPUT=false print_summary false) >/dev/null 2>&1; echo $?)
assert_eq "print_summary (audit) ignores APPLY_FAILURES (audit mode never writes)" "0" "$audit_fail_ignored_rc"

# Audit exit policy (go-kure/.github#178). --report-only (push runs) lists
# the drift, warns and exits 0. --warn-label-drift (the daily run) turns
# label colour/description drift into a warning; every other class still
# fails, EXTRA labels included.
report_rc=$( (REPORT_ONLY=true RULESET_MISSING=2 LABELS_EXTRA=1 JSON_OUTPUT=false print_summary false) >/dev/null 2>&1; echo $?)
assert_eq "--report-only exits 0 on drift" "0" "$report_rc"
report_out=$( (REPORT_ONLY=true RULESET_MISSING=2 LABELS_EXTRA=1 JSON_OUTPUT=false print_summary false) 2>&1)
assert_contains "--report-only still prints the drift" "$report_out" "2 wrong"
assert_contains "--report-only warns with the failing count" "$report_out" "::warning::3 drift issue(s) found; not failing (--report-only)"
manual_out=$( (REPORT_ONLY=true LABELS_DUPLICATE=1 SETTINGS_BLOCKED=1 RULESET_MISSING=1 JSON_OUTPUT=false print_summary false) 2>&1)
assert_contains "the audit names the drift --apply cannot fix" "$manual_out" "2 of them (duplicate labels, audit-only settings) --apply cannot fix: reconcile those by hand"
fixable_out=$( (RULESET_MISSING=1 JSON_OUTPUT=false print_summary false) 2>&1)
assert_eq "no manual-reconciliation line when --apply can fix everything" "0" "$(grep -c 'cannot fix' <<< "$fixable_out")"
plain_ruleset_rc=$( (RULESET_MISSING=2 JSON_OUTPUT=false print_summary false) >/dev/null 2>&1; echo $?)
assert_eq "a plain audit still exits 1 on ruleset drift" "1" "$plain_ruleset_rc"

drift_only_rc=$( (WARN_LABEL_DRIFT=true LABELS_DRIFT=3 JSON_OUTPUT=false print_summary false) >/dev/null 2>&1; echo $?)
assert_eq "--warn-label-drift exits 0 on label metadata drift alone" "0" "$drift_only_rc"
drift_only_out=$( (WARN_LABEL_DRIFT=true LABELS_DRIFT=3 JSON_OUTPUT=false print_summary false) 2>&1)
assert_contains "--warn-label-drift warns with the drift count" "$drift_only_out" "::warning::3 label(s) with colour/description drift (warning only, --warn-label-drift)"
assert_contains "--warn-label-drift still prints the drift" "$drift_only_out" "3 metadata drift"
for cls in LABELS_EXTRA LABELS_MISSING LABELS_RENAMED LABELS_DUPLICATE SETTINGS_MISSING SETTINGS_BLOCKED RULESET_MISSING; do
    cls_rc=$( (printf -v "$cls" 1; WARN_LABEL_DRIFT=true LABELS_DRIFT=1 JSON_OUTPUT=false print_summary false) >/dev/null 2>&1; echo $?)
    assert_eq "--warn-label-drift still exits 1 on $cls" "1" "$cls_rc"
done
plain_drift_rc=$( (LABELS_DRIFT=1 JSON_OUTPUT=false print_summary false) >/dev/null 2>&1; echo $?)
assert_eq "a plain audit still exits 1 on label metadata drift" "1" "$plain_drift_rc"
both_rc=$( (REPORT_ONLY=true WARN_LABEL_DRIFT=true LABELS_DRIFT=1 SETTINGS_MISSING=1 JSON_OUTPUT=false print_summary false) >/dev/null 2>&1; echo $?)
assert_eq "both flags: exits 0" "0" "$both_rc"
both_out=$( (REPORT_ONLY=true WARN_LABEL_DRIFT=true LABELS_DRIFT=1 SETTINGS_MISSING=1 JSON_OUTPUT=false print_summary false) 2>&1)
assert_contains "both flags: the report-only count excludes label metadata drift" "$both_out" "::warning::1 drift issue(s) found"
apply_flag_rc=$( (APPLY_FAILURES=("kure: update label x"); WARN_LABEL_DRIFT=true LABELS_DRIFT=1 JSON_OUTPUT=false print_summary true) >/dev/null 2>&1; echo $?)
assert_eq "--warn-label-drift leaves the apply-failure exit alone" "1" "$apply_flag_rc"
apply_flag_out=$( (WARN_LABEL_DRIFT=true LABELS_DRIFT=1 JSON_OUTPUT=false print_summary true) 2>&1)
apply_flag_warned=$(grep -c 'warning only, --warn-label-drift' <<< "$apply_flag_out")
assert_eq "--warn-label-drift prints no drift warning in apply mode (apply already patched it)" "0" "$apply_flag_warned"

# The CLI itself: `--all --apply` keeps going past a repo whose write failed
# (audit_repo runs under `|| true` there) and still exits 1 at the end. The
# audit is stubbed; the flag parsing, the loop and the print_summary call are
# the real main().
main_log="$(mktemp)"
main_rc=$( (
    setup_colors() { :; }
    check_requirements() { :; }
    audit_repo() {
        echo "audited $1" >> "$main_log"
        [ "$1" = first ] || return 0
        record_apply_failure "first: create label test/new"
        return 1
    }
    APPLY_FAILURES=()
    GITHUB_REPOS="first second" JSON_OUTPUT=false main --all --apply
) >/dev/null 2>&1; echo $?)
assert_eq "--all --apply exits 1 when a write failed" "1" "$main_rc"
assert_eq "--all --apply audits every repo after a failed write" "audited first
audited second" "$(cat "$main_log")"
rm -f "$main_log"

# The CLI flags reach print_summary, and --report-only refuses --apply
# before anything is audited.
for case in "RULESET_MISSING 1" "RULESET_MISSING 0 --report-only" "RULESET_MISSING 1 --warn-label-drift" \
    "LABELS_DRIFT 1" "LABELS_DRIFT 0 --warn-label-drift"; do
    read -r cls want flag <<< "$case"
    flag_rc=$( (
        setup_colors() { :; }
        check_requirements() { :; }
        audit_repo() { printf -v "$cls" 1; }
        # shellcheck disable=SC2086 # $flag is empty or one flag
        GITHUB_REPOS="first" JSON_OUTPUT=false main --all $flag
    ) >/dev/null 2>&1; echo $?)
    assert_eq "main --all ${flag:-(no flag)} exits $want on $cls" "$want" "$flag_rc"
done
refused_log="$(mktemp)"
refused_out=$( (
    setup_colors() { :; }
    check_requirements() { :; }
    audit_repo() { echo "audited $1" >> "$refused_log"; }
    GITHUB_REPOS="first" JSON_OUTPUT=false main --all --report-only --apply
) 2>&1; echo "rc=$?")
assert_contains "--report-only --apply is refused" "$refused_out" "--report-only and --apply are mutually exclusive"
assert_contains "--report-only --apply exits 1" "$refused_out" "rc=1"
assert_eq "--report-only --apply audits nothing" "" "$(cat "$refused_log")"
rm -f "$refused_log"

rm -rf "$drift_fixture_dir"
trap - EXIT
unset -f get_github_labels

echo ""
echo "github-settings-test: $pass_count passed, $failures failed"
if [ "$failures" -gt 0 ]; then
    exit 1
fi
