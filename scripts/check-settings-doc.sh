#!/usr/bin/env bash
# check-settings-doc.sh — Guard against docs/standards.md's "Repository
# Settings" section and governance/repository-settings-policy.yaml drifting
# apart.
#
# scripts/github-settings.sh's validate_policy() already asserts SETTING_KEYS
# agrees with github_defaults' scalar keys; this script closes the remaining
# side of the triangle (script <-> policy <-> docs) by checking the docs
# table against policy directly, in both directions:
#   - a key/ruleset in policy but not documented (silently ungoverned-looking)
#   - a key/ruleset documented but not in policy (stale, e.g. after a rename)
#
# Usage: check-settings-doc.sh [REPO_ROOT]
# Exits non-zero and lists every mismatch.

set -euo pipefail

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
POLICY_FILE="$ROOT/governance/repository-settings-policy.yaml"
DOC_FILE="$ROOT/docs/standards.md"

errors=0
fail() { echo "FAIL: $*" >&2; errors=$((errors + 1)); }

for tool in yq jq; do
  command -v "$tool" &>/dev/null || {
    echo "check-settings-doc: $tool is required but not installed" >&2
    exit 1
  }
done

[[ -f "$POLICY_FILE" ]] || { echo "check-settings-doc: policy file not found: $POLICY_FILE" >&2; exit 1; }
[[ -f "$DOC_FILE" ]] || { echo "check-settings-doc: docs file not found: $DOC_FILE" >&2; exit 1; }

POLICY_JSON="$(yq -oj '.' "$POLICY_FILE")"

# Extract the backtick-quoted first column of every markdown table row
# between a "### <heading>" line and the next "##"/"###" heading (or EOF).
extract_section() {
  local heading="$1"
  # shellcheck disable=SC2016 # single-quoted on purpose: literal regexes
  # matching markdown backticks, not strings meant to expand.
  # Two greps below can legitimately find zero matches (e.g. an empty
  # section) — grep's exit 1 on no-match would otherwise abort the whole
  # script here under pipefail; `|| true` makes "nothing found" a normal,
  # empty result instead of a script-ending error.
  sed -n "/^### ${heading}\$/,/^##/{/^### ${heading}\$/d; /^##/d; p}" "$DOC_FILE" \
    | grep -oE '^\| *`[^`]+`' \
    | grep -oE '`[^`]+`' \
    | tr -d '`' \
    | sort -u || true
}

documented_settings="$(extract_section 'Top-level settings')"
documented_security="$(extract_section 'Security')"
# sed here uses BRE (no -E): bare ( ) are literal, \( \) would mean a
# capture group — so the heading's literal parens must NOT be escaped.
documented_rulesets="$(extract_section 'Rulesets (branch protection)')"
documented_org="$(extract_section 'Organization settings')"
documented_org_actions="$(extract_section 'Organization Actions permissions')"

policy_settings="$(jq -r '
  .github_defaults
  | to_entries
  | map(select((.value | type) != "object" and (.value | type) != "array"))
  | .[].key
' <<<"$POLICY_JSON" | sort -u)"

policy_security="$(jq -r '.github_defaults.security // {} | keys[] | "security." + .' <<<"$POLICY_JSON" | sort -u)"

policy_rulesets="$(jq -r '.github_defaults.rulesets // {} | keys[]' <<<"$POLICY_JSON" | sort -u)"

policy_org="$(jq -r '
  .github_org // {}
  | to_entries
  | map(select((.value | type) != "object" and (.value | type) != "array"))
  | .[].key
' <<<"$POLICY_JSON" | sort -u)"

policy_org_actions="$(jq -r '.github_org.actions // {} | keys[] | "actions." + .' <<<"$POLICY_JSON" | sort -u)"

compare() {
  local label="$1" documented="$2" policy="$3"
  local only_doc only_policy
  only_doc="$(comm -23 <(echo "$documented") <(echo "$policy") | sed '/^$/d')"
  only_policy="$(comm -13 <(echo "$documented") <(echo "$policy") | sed '/^$/d')"
  if [[ -n "$only_doc" ]]; then
    while IFS= read -r k; do
      fail "$label: '$k' is documented in docs/standards.md but not declared in policy"
    done <<<"$only_doc"
  fi
  if [[ -n "$only_policy" ]]; then
    while IFS= read -r k; do
      fail "$label: '$k' is declared in policy but not documented in docs/standards.md"
    done <<<"$only_policy"
  fi
}

compare "top-level settings" "$documented_settings" "$policy_settings"
compare "security settings" "$documented_security" "$policy_security"
compare "rulesets" "$documented_rulesets" "$policy_rulesets"
compare "organization settings" "$documented_org" "$policy_org"
compare "organization Actions permissions" "$documented_org_actions" "$policy_org_actions"

if [[ $errors -gt 0 ]]; then
  echo "check-settings-doc: $errors violation(s)." >&2
  exit 1
fi

total=$(($(wc -l <<<"$policy_settings") + $(wc -l <<<"$policy_security") + $(wc -l <<<"$policy_rulesets") + $(wc -l <<<"$policy_org") + $(wc -l <<<"$policy_org_actions")))
echo "check-settings-doc: OK ($total governed setting(s)/ruleset(s) match docs)."
