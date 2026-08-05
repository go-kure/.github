#!/usr/bin/env bash
# check-links.sh — Layer 1 of the documentation-sync standard: verify that every
# internal link resolves in a *rendered* site.
#
# Directory-in: the caller is responsible for building/assembling the site into a
# directory of HTML first (a Hugo build, or — for pre-rendered static-HTML sites —
# just copying docs/ into public/). This script runs lychee over that tree with
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
# --include-fragments is deliberately NOT enabled: without it, lychee only checks
# that the target document exists, not that a #fragment anchor within it does — a
# link to a missing heading/ID passes silently. That gap is real, but the fix isn't
# just adding the flag. Verified against lychee 0.24.2 (latest, checked 2026-08-05):
# --include-fragments fails to resolve fragments through directory→index.html
# rewriting — a link to "/dir/#anchor" or "/dir#anchor" reports "Cannot find
# fragment" even when the anchor genuinely exists in dir/index.html, while the
# identical link with an explicit "/dir/index.html#anchor" resolves correctly. Since
# Hugo's default pretty-URL output is exactly the directory-style form, enabling the
# flag as-is turns this into false positives on essentially every internal anchor
# link in a Hugo-built site (reproduced against kure's real site: 4 false failures,
# all on directory-style URLs with an anchor that does exist). Re-evaluate once
# lychee fixes this (github.com/lycheeverse/lychee) or once callers can normalize
# built HTML to explicit index.html links before this script runs.
lychee --offline --root-dir "$DIR" --no-progress "$DIR/**/*.html"
echo "check-links: OK (internal links resolve)"
