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
assert_contains "validate_policy's error names the empty labels file" "$empty_out" "declares no labels"

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

# go-kure/.github#108: pr-review / AI Code Review is now a required context on
# kure/launcher (the queue_protection override), deliberately NOT on .github
# (org default) — see governance/repository-settings-policy.yaml's inline
# comment and docs/standards.md's "Interim outage window" section.
assert_eq "kure main-protection payload requires pr-review context" "true" \
    "$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks | map(.context) | index("pr-review / AI Code Review") != null' <<<"$main_payload")"

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

# ---- build_ruleset_import_jq: strips API-only pull_request fields, flags
# an injected unmodeled rule type instead of silently dropping it. ----

import_filter=$(build_ruleset_import_jq)
imported=$(jq "$import_filter" <<<"$main_live_match")
assert_eq "import strips dismissal_restriction from pull_request" "null" \
    "$(jq -r '.rules.pull_request.dismissal_restriction // "null"' <<<"$imported")"
assert_eq "import maps required_status_checks to policy shape" '{"contexts":["lint","test","build","pr-review / AI Code Review"],"strict":false}' \
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
consumer_scope_json=$(jq '.github_defaults.rulesets["main-protection"].repos = ["alpha"] | .github_defaults.rulesets[$c].repos = ["alpha"] | .github_repos = {}' --arg c "$COPILOT" <<<"$POLICY_JSON")
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

# ---- ruleset_covers_main: audit_rulesets migrates classic branch protection
# away only when an applicable branch ruleset reaches main (go-kure/.github#154
# review finding: a consumer policy with no such ruleset must not lose
# unmanaged classic protection on --apply with nothing replacing it). ----

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
    "Question Include": {target: "branch", conditions: {ref_name: {include: ["refs/heads/mai?"]}}, rules: {deletion: true}},
    "All But Star": {target: "branch", conditions: {ref_name: {include: ["~ALL"], exclude: ["refs/*"]}}, rules: {deletion: true}},
    "Copilot Only": {target: "branch", conditions: {ref_name: {include: ["refs/heads/main"]}}, rules: {copilot_code_review: {review_on_push: true, review_draft_pull_requests: false}}},
    "Copilot Plus Deletion": {target: "branch", conditions: {ref_name: {include: ["refs/heads/main"]}}, rules: {copilot_code_review: {review_on_push: true, review_draft_pull_requests: false}, deletion: true}}
}' <<<"$POLICY_JSON")

# Stubbed like get_github_labels below: the live default branch is whatever
# COVERS_DEFAULT_BRANCH says (main unless a test sets it; empty = unreadable).
# shellcheck disable=SC2317 # invoked indirectly via ruleset_covers_main
repo_default_branch() { printf '%s' "${COVERS_DEFAULT_BRANCH-main}"; }

# Echoes ruleset_covers_main's exit code for kure over the named rulesets.
covers_rc() {
    (POLICY_JSON="$covers_json" ruleset_covers_main "kure" "$@") >/dev/null 2>&1
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
# `refs/*` never reaches refs/heads/main as an include; only `**` does. On the
# exclude side the same `*` is read as wide as possible, so `refs/*` counts as
# possibly removing main. Both directions err towards "not covered".
assert_eq "a single-star include (refs/*) is not trusted to reach main" "1" "$(covers_rc "Star Include")"
assert_eq "a double-star include (refs/**) reaches main" "0" "$(covers_rc "Double Star Include")"
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

rm -rf "$drift_fixture_dir"
trap - EXIT
unset -f get_github_labels

echo ""
echo "github-settings-test: $pass_count passed, $failures failed"
if [ "$failures" -gt 0 ]; then
    exit 1
fi
