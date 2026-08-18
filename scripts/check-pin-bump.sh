#!/usr/bin/env bash
# check-pin-bump.sh — CI guard: a PR that touches the pr-review-threads
# composite action's delegate code (action.yml, scripts/pr-review-threads.sh,
# scripts/lib/prt/**) must also bump the pinned SHA that
# .github/workflows/pr-review.yml references it by — otherwise CI validates
# code that the pinned reference never actually runs (see docs/standards.md,
# "GitHub Actions pinning").
#
# The bootstrap PR (this action's first landing) is the one documented
# manual exception: there is no prior pin to compare against, so this check
# passes trivially when BASE_REF's pr-review.yml has no matching pin line at
# all to diff against.
#
# Usage: check-pin-bump.sh BASE_REF [REPO_ROOT]

set -euo pipefail

BASE_REF="${1:?usage: check-pin-bump.sh BASE_REF [REPO_ROOT]}"
ROOT="${2:-.}"
cd "$ROOT"

DELEGATE_PATHS=(
  ".github/actions/pr-review-threads"
  "scripts/pr-review-threads.sh"
  "scripts/lib/prt"
)

# A bad/unreachable BASE_REF must fail loudly, not fall through to the
# "nothing changed" path below — `git diff` on an unresolvable ref exits
# non-zero with its error on stderr, which the `|| true` two lines down
# would otherwise silently swallow and read as an empty (all-clear) diff.
git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null || {
  echo "check-pin-bump: FAIL — BASE_REF '${BASE_REF}' does not resolve to a commit (fetch it first?)." >&2
  exit 1
}

changed="$(git diff --name-only "${BASE_REF}...HEAD" -- "${DELEGATE_PATHS[@]}" 2>/dev/null || true)"
if [ -z "$changed" ]; then
  echo "check-pin-bump: no pr-review-threads delegate code changed, OK."
  exit 0
fi

WORKFLOW=".github/workflows/pr-review.yml"

# extract_pin REF — REF="" reads the working tree; otherwise a git ref.
extract_pin() {
  local ref="$1" content
  if [ -z "$ref" ]; then
    content="$(cat "$WORKFLOW" 2>/dev/null || true)"
  else
    content="$(git show "${ref}:${WORKFLOW}" 2>/dev/null || true)"
  fi
  printf '%s\n' "$content" | grep -oE 'actions/pr-review-threads@[0-9a-f]{40}' | head -1 || true
}

old_pin="$(extract_pin "$BASE_REF")"
new_pin="$(extract_pin "")"

if [ -z "$old_pin" ]; then
  echo "check-pin-bump: no prior pin on ${BASE_REF} (bootstrap PR) — OK."
  exit 0
fi

if [ -z "$new_pin" ]; then
  echo "check-pin-bump: FAIL — $WORKFLOW no longer pins actions/pr-review-threads to a SHA." >&2
  exit 1
fi

if [ "$old_pin" = "$new_pin" ]; then
  echo "check-pin-bump: FAIL — delegate code changed but the pin in $WORKFLOW was not bumped:" >&2
  printf '%s\n' "$changed" | sed 's/^/  - /' >&2
  echo "See docs/standards.md, 'GitHub Actions pinning' > 'Same-repo composite actions and the pin-bump procedure.'" >&2
  exit 1
fi

echo "check-pin-bump: OK (pin changed from ${old_pin} to ${new_pin})."
