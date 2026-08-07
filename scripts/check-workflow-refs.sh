#!/usr/bin/env bash
# check-workflow-refs.sh — Guard against AGENTS.md / docs/standards.md naming a
# GitHub Actions workflow file that does not exist.
#
# go-kure/.github#33: AGENTS.md named a nonexistent apply-settings.yml workflow
# and a dry_run input it never had. The same defect had already been fixed once
# in a downstream consumer's copy of this guidance and recurred here — this
# script is the fix that makes it recur no further: it fails CI instead of a
# human catching it.
#
# Scans AGENTS.md and docs/standards.md for backtick-quoted bare workflow
# filenames (e.g. `settings.yml`) and asserts each exists under
# .github/workflows/. Bare filename only — not `.github/dependabot.yml` or
# `.gitlab-ci.yml`, which are other repos' config referenced by full/relative
# path or a leading dot, not workflow files this repo owns.
#
# Usage: check-workflow-refs.sh [REPO_ROOT]
# Exits non-zero and lists every unresolved reference.

set -euo pipefail

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
WORKFLOWS_DIR="$ROOT/.github/workflows"

errors=0
fail() { echo "FAIL: $*" >&2; errors=$((errors + 1)); }

DOCS=(
  "$ROOT/AGENTS.md"
  "$ROOT/docs/standards.md"
)

checked=0
for doc in "${DOCS[@]}"; do
  [[ -f "$doc" ]] || continue
  # Bare filename: starts with a letter/digit, no path separator, ends in .yml.
  # Excludes path-prefixed or dot-prefixed refs to other repos' config
  # (.github/dependabot.yml, .gitlab-ci.yml) and prose fragments (-caller.yml).
  # shellcheck disable=SC2016 # the grep regex below is single-quoted on purpose:
  # it's a literal pattern matching markdown backticks, not a string meant to
  # expand $doc.
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    checked=$((checked + 1))
    if [[ ! -f "$WORKFLOWS_DIR/$ref" ]]; then
      fail "$doc references workflow '$ref', not found at .github/workflows/$ref"
    fi
  done < <(grep -oE '`[a-zA-Z0-9][a-zA-Z0-9_-]*\.yml`' "$doc" | tr -d '`' | sort -u)
done

if [[ $errors -gt 0 ]]; then
  echo "check-workflow-refs: $errors violation(s)." >&2
  exit 1
fi
echo "check-workflow-refs: OK ($checked workflow reference(s) checked)."
