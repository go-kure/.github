#!/usr/bin/env bash
# check-label-docs-test.sh — fixture tests for scripts/check-label-docs.sh.
#
# The checker is the only thing standing between standards/labels.json and
# standards/labels.md drifting apart unnoticed (labels.md is hand-maintained
# prose, no generated block). A checker that silently passes is worse than
# no checker, so its own behaviour is pinned by these fixtures — every
# extraction edge (empty cell, unbackticked prefix, a renamed heading, a
# field-shifting stray pipe) must FAIL, never silently skip.
#
# Usage: check-label-docs-test.sh [REPO_ROOT]
#
# shellcheck disable=SC2016 # file-wide: the fixtures below are full of
# single-quoted sed patterns matching literal backtick-quoted label names
# (e.g. 's/`type\/` | ...) — none of them are meant to expand.

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
CHECKER="$ROOT/scripts/check-label-docs.sh"

failures=0
pass_count=0

# Runs the checker against a throwaway repo containing exactly the given
# standards/labels.json and standards/labels.md content. Echoes "rc\tstdout+stderr"
# joined by a literal tab so callers can assert on both exit code and message
# shape (e.g. a fatal error prints no "FAIL:" line) from one invocation.
run_fixture() {
  local json="$1" md="$2" dir out rc
  dir="$(mktemp -d)"
  mkdir -p "$dir/standards"
  if [ -n "$json" ]; then
    printf '%s\n' "$json" > "$dir/standards/labels.json"
  fi
  if [ -n "$md" ]; then
    printf '%s\n' "$md" > "$dir/standards/labels.md"
  fi
  out="$(bash "$CHECKER" "$dir" 2>&1)"
  rc=$?
  rm -rf "$dir"
  printf '%d\t%s' "$rc" "$out"
}

assert_rc() {
  local desc="$1" expected="$2" result="$3" actual
  actual="${result%%$'\t'*}"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected rc=$expected, got rc=$actual" >&2
    failures=$((failures + 1))
  fi
}

# Asserts the fixture's combined output contains no "FAIL:" line — the
# fatal-input shape (malformed/missing labels.json or .md, no rows found)
# is a single "check-label-docs: <reason>" line, never a drift violation.
assert_no_fail_lines() {
  local desc="$1" result="$2" out
  out="${result#*$'\t'}"
  if grep -q '^FAIL:' <<<"$out"; then
    echo "FAIL: $desc — expected no 'FAIL:' lines (fatal shape), got: $out" >&2
    failures=$((failures + 1))
  else
    pass_count=$((pass_count + 1))
  fi
}

# --- baseline fixture: two namespaces, one unnamespaced label, one prose
# color line, both `###` subheadings present. Every test below mutates
# exactly one thing away from this. ---

base_json() { cat <<'EOF'
{
  "labels": [
    {"name": "type/bug", "color": "#d73a4a", "description": "Something isn't working"},
    {"name": "type/chore", "color": "#c5def5", "description": "Maintenance"},
    {"name": "status::blocked", "color": "#d93f0b", "description": "[deprecated] Use Status=Blocked instead"},
    {"name": "status::deferred", "color": "#fef2c0", "description": "[deprecated] Use Milestone=Later instead"},
    {"name": "dependencies", "color": "#0366d6", "description": "Dependency updates"}
  ]
}
EOF
}

base_md() { cat <<'EOF'
# Issue Label Conventions

## Category Reference

### Categorical

| Category | Values | Meaning |
|---|---|---|
| `type/` | `bug`, `chore` | What kind of issue it is |

### Enumerated

| Category | Values | Meaning |
|---|---|---|
| `status::` **(deprecated)** | `blocked`, `deferred` | Replaced by project fields |

`type/bug` renders as `#d73a4a`.

Special labels: `dependencies` — used by Dependabot.
EOF
}

# ---------------------------------------------------------------------------
# 1. baseline + real repo regression anchor
# ---------------------------------------------------------------------------
assert_rc "baseline in sync" 0 "$(run_fixture "$(base_json)" "$(base_md)")"
assert_rc "the real repo's labels.json/labels.md parse and agree" 0 "$(run_fixture "$(cat "$ROOT/standards/labels.json")" "$(cat "$ROOT/standards/labels.md")")"

# ---------------------------------------------------------------------------
# 2. label in json, absent from its row (json->doc)
# ---------------------------------------------------------------------------
json_type_plus_one() { base_json | jq -c '.labels += [{"name":"type/epic","color":"#0052cc","description":"Epic"}]'; }
assert_rc "value added to json only, not in the doc row" 1 "$(run_fixture "$(json_type_plus_one)" "$(base_md)")"

# ---------------------------------------------------------------------------
# 3. entire new namespace in json, no row at all
# ---------------------------------------------------------------------------
json_new_namespace() { base_json | jq -c '.labels += [{"name":"priority::high","color":"#b60205","description":"Urgent"}]'; }
assert_rc "new namespace in json, no labels.md row" 1 "$(run_fixture "$(json_new_namespace)" "$(base_md)")"

# ---------------------------------------------------------------------------
# 4. value in doc row, absent from json (doc->json)
# ---------------------------------------------------------------------------
md_type_plus_epic() { base_md | sed 's/`type\/` | `bug`, `chore`/`type\/` | `bug`, `chore`, `epic`/'; }
assert_rc "value enumerated in labels.md, not in json" 1 "$(run_fixture "$(base_json)" "$(md_type_plus_epic)")"

# ---------------------------------------------------------------------------
# 5. row for a namespace with zero json labels
# ---------------------------------------------------------------------------
md_extra_row() { cat <<'EOF'
# Issue Label Conventions

## Category Reference

### Categorical

| Category | Values | Meaning |
|---|---|---|
| `type/` | `bug`, `chore` | What kind of issue it is |
| `scope/` | `launcher` | Not in json at all |

### Enumerated

| Category | Values | Meaning |
|---|---|---|
| `status::` **(deprecated)** | `blocked`, `deferred` | Replaced by project fields |

`type/bug` renders as `#d73a4a`.

Special labels: `dependencies` — used by Dependabot.
EOF
}
assert_rc "labels.md row for a namespace absent from json" 1 "$(run_fixture "$(base_json)" "$(md_extra_row)")"

# ---------------------------------------------------------------------------
# 6. unnamespaced label never backticked anywhere; substring-only match also fails
# ---------------------------------------------------------------------------
md_no_dependencies_mention() { base_md | sed '/Special labels/d'; }
assert_rc "unnamespaced json label never backticked in the doc" 1 "$(run_fixture "$(base_json)" "$(md_no_dependencies_mention)")"

md_dependencies_substring_only() { base_md | sed 's/`dependencies`/`dependencies-extra`/'; }
assert_rc "unnamespaced label only present as a substring token" 1 "$(run_fixture "$(base_json)" "$(md_dependencies_substring_only)")"

# ---------------------------------------------------------------------------
# 7. deprecation is a namespace-level property
# ---------------------------------------------------------------------------
json_status_all_dep() { base_json; }  # baseline already has both status::* marked [deprecated]
md_status_marked() { base_md; }        # baseline already marks the row **(deprecated)**
assert_rc "all-deprecated in json, marked in doc" 0 "$(run_fixture "$(json_status_all_dep)" "$(md_status_marked)")"

md_status_unmarked() { base_md | sed 's/`status::` \*\*(deprecated)\*\*/`status::`/'; }
assert_rc "all-deprecated in json, unmarked in doc (the defect this issue is about)" 1 \
  "$(run_fixture "$(json_status_all_dep)" "$(md_status_unmarked)")"

json_status_none_dep() { base_json | jq -c '(.labels[] | select(.name | startswith("status::")) | .description) |= ltrimstr("[deprecated] ")'; }
assert_rc "none-deprecated in json, still marked in doc (half-finished un-deprecation)" 1 \
  "$(run_fixture "$(json_status_none_dep)" "$(md_status_marked)")"
assert_rc "none-deprecated in json, unmarked in doc" 0 \
  "$(run_fixture "$(json_status_none_dep)" "$(md_status_unmarked)")"

json_status_partial_dep() { base_json | jq -c '(.labels[] | select(.name == "status::deferred") | .description) = "Use Milestone=Later instead"'; }
assert_rc "partially deprecated namespace in json, marked in doc" 1 "$(run_fixture "$(json_status_partial_dep)" "$(md_status_marked)")"
assert_rc "partially deprecated namespace in json, unmarked in doc" 1 "$(run_fixture "$(json_status_partial_dep)" "$(md_status_unmarked)")"

json_deprecated_mid_description() { base_json | jq -c '(.labels[] | select(.name | startswith("type/")) | .description) |= ("Old name; [deprecated] " + .)'; }
md_type_marked() { base_md | sed 's/`type\/` | `bug`, `chore`/`type\/` **(deprecated)** | `bug`, `chore`/'; }
assert_rc "[deprecated] mid-description (not startswith) does not satisfy a doc row marked deprecated" 1 \
  "$(run_fixture "$(json_deprecated_mid_description)" "$(md_type_marked)")"

# ---------------------------------------------------------------------------
# 8. inline color cross-checks
# ---------------------------------------------------------------------------
assert_rc "color matches, case-insensitive (json is #d73a4a, doc line 2 is fine)" 0 "$(run_fixture "$(base_json)" "$(base_md)")"

md_color_mismatch() { base_md | sed 's/#d73a4a/#d73a4b/'; }
assert_rc "color in doc differs from json" 1 "$(run_fixture "$(base_json)" "$(md_color_mismatch)")"

md_color_no_label_on_line() { base_md | sed 's/`type\/bug` renders as `#d73a4a`\./Rendering uses `#d73a4a` for the primary bug color./'; }
assert_rc "color on a line naming zero labels" 1 "$(run_fixture "$(base_json)" "$(md_color_no_label_on_line)")"

md_color_ambiguous() { base_md | sed 's/`type\/bug` renders as `#d73a4a`\./`type\/bug` and `type\/chore` both render as `#d73a4a`./'; }
assert_rc "color on a line naming two labels is ambiguous" 1 "$(run_fixture "$(base_json)" "$(md_color_ambiguous)")"

md_color_same_label_twice() { base_md | sed 's/`type\/bug` renders as `#d73a4a`\./`type\/bug` is `#d73a4a`; apply `type\/bug` to new bug reports./'; }
assert_rc "color line naming the same label twice is not ambiguous" 0 "$(run_fixture "$(base_json)" "$(md_color_same_label_twice)")"

md_issue_shaped_hex_not_a_color() { base_md | sed 's/`type\/bug` renders as `#d73a4a`\./See issue #4212 for background./'; }
assert_rc "an issue-number-shaped #4212 (not 6 hex digits) is not read as a color" 0 \
  "$(run_fixture "$(base_json)" "$(md_issue_shaped_hex_not_a_color)")"

md_color_in_fence() { base_md | sed 's/`type\/bug` renders as `#d73a4a`\./```\n`type\/roadmap` example color: #ffffff\n```/'; }
assert_rc "a color inside a fenced block is skipped, not flagged" 0 "$(run_fixture "$(base_json)" "$(md_color_in_fence)")"

# ---------------------------------------------------------------------------
# 9. extraction edge cases — every one must FAIL, never silently skip
# ---------------------------------------------------------------------------
md_heading_renamed() { base_md | sed 's/## Category Reference/## Label Categories/'; }
result_heading_renamed="$(run_fixture "$(base_json)" "$(md_heading_renamed)")"
assert_rc "'## Category Reference' heading renamed (fatal, not a silent empty pass)" 1 "$result_heading_renamed"
assert_no_fail_lines "heading-renamed fatal shape has no FAIL: lines" "$result_heading_renamed"

md_rows_deleted() { cat <<'EOF'
# Issue Label Conventions

## Category Reference

### Categorical

### Enumerated

Nothing here.
EOF
}
result_rows_deleted="$(run_fixture "$(base_json)" "$(md_rows_deleted)")"
assert_rc "headings present, all rows deleted (fatal)" 1 "$result_rows_deleted"
assert_no_fail_lines "no-rows fatal shape has no FAIL: lines" "$result_rows_deleted"

md_empty_values_cell() { base_md | sed 's/`type\/` | `bug`, `chore`/`type\/` |/'; }
assert_rc "empty values cell" 1 "$(run_fixture "$(base_json)" "$(md_empty_values_cell)")"

md_straggler() { base_md | sed 's/`type\/` | `bug`, `chore`/`type\/` | `bug`, chore/'; }
assert_rc "non-backticked straggler in a values cell" 1 "$(run_fixture "$(base_json)" "$(md_straggler)")"

md_unbackticked_prefix() { base_md | sed 's/`type\/` | `bug`, `chore`/type\/ | `bug`, `chore`/'; }
assert_rc "unbackticked prefix is unparsable, not skipped" 1 "$(run_fixture "$(base_json)" "$(md_unbackticked_prefix)")"

md_duplicate_row() { base_md | sed '/`type\/` | `bug`, `chore`/{p}'; }
assert_rc "duplicate row for the same namespace" 1 "$(run_fixture "$(base_json)" "$(md_duplicate_row)")"

md_stray_pipe() { base_md | sed 's/`bug`, `chore` | What kind/`bug`, `cho|re` | What kind/'; }
assert_rc "a stray '|' inside a values cell shifts fields (fail-closed, not a crash)" 1 "$(run_fixture "$(base_json)" "$(md_stray_pipe)")"

# ---------------------------------------------------------------------------
# 10. fatal input shapes
# ---------------------------------------------------------------------------
result_empty_labels="$(run_fixture '{"labels": []}' "$(base_md)")"
assert_rc "empty labels array is fatal" 1 "$result_empty_labels"
assert_no_fail_lines "empty-labels fatal shape has no FAIL: lines" "$result_empty_labels"

result_malformed_json="$(run_fixture '{not valid json' "$(base_md)")"
assert_rc "malformed JSON is fatal" 1 "$result_malformed_json"
assert_no_fail_lines "malformed-JSON fatal shape has no FAIL: lines" "$result_malformed_json"

result_missing_md="$(run_fixture "$(base_json)" "")"
assert_rc "missing labels.md is fatal" 1 "$result_missing_md"
assert_no_fail_lines "missing-doc fatal shape has no FAIL: lines" "$result_missing_md"

result_missing_json="$(run_fixture "" "$(base_md)")"
assert_rc "missing labels.json is fatal" 1 "$result_missing_json"
assert_no_fail_lines "missing-json fatal shape has no FAIL: lines" "$result_missing_json"

# ---------------------------------------------------------------------------
# 11. area/ open-namespace growth path: a new label added to both, in sync
# ---------------------------------------------------------------------------
json_plus_area() { base_json | jq -c '.labels += [{"name":"area/oam","color":"#5319e7","description":"OAM component/trait model"}]'; }
md_plus_area() { base_md | sed 's/### Enumerated/### Categorical (area)\n\n| Category | Values | Meaning |\n|---|---|---|\n| `area\/` | `oam` | Subsystem |\n\n### Enumerated/'; }
assert_rc "a new area/ label added to both files stays in sync" 0 "$(run_fixture "$(json_plus_area)" "$(md_plus_area)")"

# ---------------------------------------------------------------------------
# 12. one flat `##`-scoped table, two namespaces, mixed deprecation — proves
# extraction is per-row keyed on the column-1 token, not per-section
# ---------------------------------------------------------------------------
md_flat_mixed_deprecation() { cat <<'EOF'
# Issue Label Conventions

## Category Reference

| Category | Values | Meaning |
|---|---|---|
| `type/` | `bug`, `chore` | What kind of issue it is |
| `status::` **(deprecated)** | `blocked`, `deferred` | Replaced by project fields |

`type/bug` renders as `#d73a4a`.

Special labels: `dependencies` — used by Dependabot.
EOF
}
assert_rc "one flat section, two namespaces, one deprecated one not" 0 "$(run_fixture "$(base_json)" "$(md_flat_mixed_deprecation)")"

# ---------------------------------------------------------------------------
# 13. an unnamespaced label documented only in prose, no table row at all
# ---------------------------------------------------------------------------
assert_rc "unnamespaced label present only as prose, no row needed" 0 "$(run_fixture "$(base_json)" "$(base_md)")"

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
