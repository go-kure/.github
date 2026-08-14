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

github_main_payload=$(build_ruleset_payload ".github" "main-protection")
assert_eq ".github main-protection payload has no merge_queue (no override)" \
    "deletion,non_fast_forward,pull_request,required_linear_history,required_status_checks" \
    "$(jq -r '[.rules[].type] | sort | join(",")' <<<"$github_main_payload")"
assert_eq ".github main-protection keeps rebase-check context" "true" \
    "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks | map(.context) | index("rebase-check") != null' <<<"$github_main_payload")"

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
            required_status_checks: [{context: "lint"}, {context: "test"}, {context: "build"}],
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

# ---- build_ruleset_import_jq: strips API-only pull_request fields, flags
# an injected unmodeled rule type instead of silently dropping it. ----

import_filter=$(build_ruleset_import_jq)
imported=$(jq "$import_filter" <<<"$main_live_match")
assert_eq "import strips dismissal_restriction from pull_request" "null" \
    "$(jq -r '.rules.pull_request.dismissal_restriction // "null"' <<<"$imported")"
assert_eq "import maps required_status_checks to policy shape" '{"contexts":["lint","test","build"],"strict":false}' \
    "$(jq -Sc '.rules.required_status_checks' <<<"$imported")"
assert_eq "import reports no unmapped rule types for a fully-modeled ruleset" "[]" \
    "$(jq -c '.unmapped_rule_types' <<<"$imported")"

main_live_with_unmodeled=$(jq '.rules += [{type: "code_scanning", parameters: {code_scanning_tools: []}}]' <<<"$main_live_match")
imported_unmodeled=$(jq "$import_filter" <<<"$main_live_with_unmodeled")
assert_eq "import flags an injected unmodeled rule type" '["code_scanning"]' \
    "$(jq -c '.unmapped_rule_types' <<<"$imported_unmodeled")"

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

# ---- print_summary: blocked (audit-only) org settings drift must be
# reported separately from applied drift under --apply, not folded into the
# "applied" count (nothing was actually written for a blocked key). ----

summary_out=$( (SETTINGS_OK=5 SETTINGS_MISSING=2 SETTINGS_BLOCKED=1 JSON_OUTPUT=false print_summary true) 2>&1 )
assert_contains "print_summary (--apply) keeps the applied count exclusive of blocked settings" "$summary_out" "2 applied"
assert_contains "print_summary (--apply) reports blocked settings separately" "$summary_out" "1 blocked (audit-only, unresolved)"

echo ""
echo "github-settings-test: $pass_count passed, $failures failed"
if [ "$failures" -gt 0 ]; then
    exit 1
fi
