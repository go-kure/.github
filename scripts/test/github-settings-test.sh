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

rm -rf "$drift_fixture_dir"
trap - EXIT
unset -f get_github_labels

echo ""
echo "github-settings-test: $pass_count passed, $failures failed"
if [ "$failures" -gt 0 ]; then
    exit 1
fi
