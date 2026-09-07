#!/usr/bin/env bash
# check-action-pins.sh — Guard against a mutable third-party GitHub Actions ref.
#
# CVE-2025-30066 (March 2025): an attacker moved the v-tags of
# tj-actions/changed-files onto a poisoned commit; ~23k repositories that pinned
# by tag executed it and leaked secrets into CI logs. A tag is a mutable pointer;
# a commit SHA is not. This script fails CI on any third-party `uses:` that is
# not a full 40-hex commit SHA.
#
# Allowed unpinned forms, and why:
#   ./path                    — an action inside this repo; same commit as the caller.
#   docker://image:tag        — not a git ref; image pinning is a container concern.
#   go-kure/*/.github/workflows/x.yml@ref
#                             — a first-party REUSABLE WORKFLOW. GitHub's own
#                               sha_pinning_required policy exempts reusable
#                               workflows; this checker matches that boundary
#                               exactly rather than inventing a stricter one.
#                               First-party COMPOSITE ACTIONS are not exempt.
#
# Known limitation: this is a line-anchored grep, not a YAML parser. A `run: |`
# block scalar whose shell text happens to start a line with `uses:` would be
# misdetected as an actions ref. Verified absent across every real workflow in
# this org today; closing the gap unconditionally needs a YAML parser, which is
# out of scope here. If a future script legitimately needs a `run:` line shaped
# like that, indent it so it is not first-on-line, or extend this checker then.
#
# Usage: check-action-pins.sh [REPO_ROOT]
# Exits non-zero and lists every unpinned reference.

set -euo pipefail

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"

errors=0
fail() { echo "FAIL: $*" >&2; errors=$((errors + 1)); }

# Reusable workflows are exempt from GitHub's sha_pinning_required policy
# ("Reusable workflows can still be referenced by tag"), so this checker
# exempts them too — deliberately mirroring the policy rather than being
# stricter than it. First-party *composite actions* are NOT exempt from
# that policy and are NOT exempt here.
# Overridable so a consumer org can admit its own reusable workflows at a
# mutable ref (e.g. '^(go-kure|other-org)/[^/]+/\.github/workflows/[^@]+@');
# the default stays go-kure-only, so nothing changes for this org's callers.
# The override can only ever narrow WHICH reusable workflows are first-party:
# it is consulted solely for refs of the reusable-workflow shape below, so a
# permissive pattern ('^acme/') still cannot exempt a composite or plain
# action from that owner. The shape requires a workflow FILE directly under
# .github/workflows/ (a .yml/.yaml name, no further path segments): a
# composite action can live in any directory, including
# .github/workflows/<dir>, and only a file there can be a reusable workflow.
# An override widens a security check, so it is never silent: the active
# pattern is printed whenever it differs from the default, and a run under a
# weakened exemption is never indistinguishable from a clean one.
REUSABLE_WORKFLOW_SHAPE='^[^/@]+/[^/@]+/\.github/workflows/[^/@]+\.ya?ml@'
DEFAULT_FIRST_PARTY_WORKFLOW_RE='^go-kure/[^/]+/\.github/workflows/[^@]+@'
FIRST_PARTY_WORKFLOW_RE="${FIRST_PARTY_WORKFLOW_RE:-$DEFAULT_FIRST_PARTY_WORKFLOW_RE}"
if [ "$FIRST_PARTY_WORKFLOW_RE" != "$DEFAULT_FIRST_PARTY_WORKFLOW_RE" ]; then
  echo "NOTE: FIRST_PARTY_WORKFLOW_RE override in effect: $FIRST_PARTY_WORKFLOW_RE" >&2
fi

checked=0
while IFS= read -r -d '' file; do
  # Strip a trailing `# comment` before matching so the `# v7` provenance
  # comment on a correct pin can never be read as part of the ref.
  while IFS= read -r ref; do
    checked=$((checked + 1))
    case "$ref" in
      ./*|docker://*) continue ;;
    esac
    if [[ "$ref" =~ $REUSABLE_WORKFLOW_SHAPE ]] && [[ "$ref" =~ $FIRST_PARTY_WORKFLOW_RE ]]; then continue; fi
    if [[ ! "$ref" =~ @[0-9a-f]{40}$ ]]; then
      fail "$(basename "$file"): unpinned action ref '$ref' (pin to a 40-char commit SHA, keep the tag as a trailing comment)"
    fi
  done < <(
    grep -hoE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^#]+' "$file" \
      | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//; s/[[:space:]]+$//; s/^["'"'"']//; s/["'"'"']$//' \
      || true
  )
done < <(find "$ROOT/.github" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null)

if [ "$errors" -gt 0 ]; then
  echo "check-action-pins: $errors unpinned ref(s) across $checked checked" >&2
  exit 1
fi
echo "check-action-pins: OK ($checked refs checked)"
