#!/usr/bin/env bash
# HISTORICAL — already run once on go-kure/kure. Do not re-run.
# status::* and area/* labels targeted here are themselves deprecated
# in favour of project Status and Stream fields (see docs/project-board-standard.md).
#
# One-shot migration: standardize go-kure/kure issue labels
#
# Run AFTER settings apply has created the :: labels on kure.
# Requires: gh CLI (authenticated with kure write access), python3
#
# What this does:
#   1. Migrates wrong-separator labels (effort/, priority/, status/) to :: equivalents
#   2. Renames type/docs and documentation -> type/documentation
#   3. Removes deprecated labels (consumer/wharf/crane, phase/*) from issues  # allow-term:wharf allow-term:crane
#
# After running, trigger settings.yml apply to delete the now-empty old labels.

set -euo pipefail

ORG="go-kure"
REPO="kure"

# Migrate: add new label, remove old label, for all matching issues
migrate_label() {
    local old="$1" new="$2" repo="${3:-$REPO}"
    echo "Migrating '$old' -> '$new' on $ORG/$repo..."
    local numbers
    numbers=$(gh issue list --repo "$ORG/$repo" --label "$old" --state all --limit 1000 \
        --json number --jq '.[].number')
    if [ -z "$numbers" ]; then
        echo "  (no issues found)"
        return
    fi
    while IFS= read -r n; do
        [ -z "$n" ] && continue
        echo "  #$n"
        gh api "repos/$ORG/$repo/issues/$n/labels" --method POST -f "labels[]=$new" --silent
        local encoded
        encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$old")
        gh api "repos/$ORG/$repo/issues/$n/labels/$encoded" --method DELETE --silent
    done <<<"$numbers"
}

# Remove: just remove from all matching issues (no replacement)
remove_label() {
    local label="$1" repo="${2:-$REPO}"
    echo "Removing '$label' from all $ORG/$repo issues..."
    local numbers
    numbers=$(gh issue list --repo "$ORG/$repo" --label "$label" --state all --limit 1000 \
        --json number --jq '.[].number')
    if [ -z "$numbers" ]; then
        echo "  (no issues found)"
        return
    fi
    while IFS= read -r n; do
        [ -z "$n" ] && continue
        echo "  #$n"
        local encoded
        encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$label")
        gh api "repos/$ORG/$repo/issues/$n/labels/$encoded" --method DELETE --silent
    done <<<"$numbers"
}

echo "=== Migrating wrong-separator labels to :: standard ==="
migrate_label "effort/high"       "effort::high"
migrate_label "effort/low"        "effort::low"
migrate_label "priority/critical" "priority::critical"
migrate_label "priority/high"     "priority::high"
migrate_label "priority/medium"   "priority::medium"
migrate_label "priority/low"      "priority::low"
migrate_label "status/blocked"    "status::blocked"
migrate_label "status/deferred"   "status::deferred"

echo ""
echo "=== Migrating to canonical label names ==="
migrate_label "type/docs"     "type/documentation"
migrate_label "documentation" "type/documentation"

echo ""
echo "=== Removing deprecated labels ==="
remove_label "consumer/wharf/crane"  # allow-term:wharf allow-term:crane — deprecated downstream label being deleted
remove_label "phase/3"
remove_label "phase/4"
remove_label "phase/5"

echo ""
echo "Migration complete."
echo "Next: trigger settings.yml apply to delete the now-empty old labels."
