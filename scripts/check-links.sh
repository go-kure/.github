#!/usr/bin/env bash
# check-links.sh — Layer 1 of the documentation-sync standard: verify that every
# internal link resolves in a *rendered* site.
#
# Directory-in: the caller is responsible for building/assembling the site into a
# directory of HTML first (a Hugo build, or — for static-HTML sites like crane — just
# copying docs/ into public/). This script runs lychee over that tree with
# --root-dir, so root-relative links resolve offline against the output. External
# links are not checked here (--offline); flaky external checks belong in a separate
# non-blocking job.
#
# Usage: bash check-links.sh <built-dir>
# Requires: lychee.

set -euo pipefail

DIR="${1:?usage: check-links.sh <built-dir>}"
DIR="$(cd "$DIR" && pwd)"

command -v lychee >/dev/null 2>&1 || { echo "ERROR: lychee is required" >&2; exit 1; }

echo "=== lychee (internal links, offline) over $DIR ==="
lychee --offline --root-dir "$DIR" --no-progress "$DIR/**/*.html"
echo "check-links: OK (internal links resolve)"
