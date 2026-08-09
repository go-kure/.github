#!/usr/bin/env bash
# govulncheck-gate.sh — turn a govulncheck JSON report into a CI verdict.
#
# Why this is a file and not ten lines inline in a workflow: an inline gate
# cannot be fixture-tested, and this is the code that decides whether a
# reachable CVE blocks a merge. scripts/test/govulncheck-gate-test.sh runs
# THIS file.
#
# Fails CLOSED. govulncheck's own exit status is not usable as the signal (in
# JSON mode it can exit 0 with reachable findings present), so the report is
# the only evidence — which means an unparseable report must be an error, never
# an empty finding set. jq's exit status is checked explicitly for that reason:
# on malformed input jq prints nothing and exits non-zero, and an unchecked
# pipeline turns a crashed scanner into a green pipeline.
#
# Usage: govulncheck-gate.sh <report.json> [allowlist]
#   <report.json>  govulncheck -format json output (JSON Lines)
#   [allowlist]    space-separated OSV IDs accepted as known risk (default none)
#
# Exit 0 — no reachable advisory outside the allowlist.
# Exit 1 — at least one unallowed reachable advisory.
# Exit 2 — the report is missing, empty or unparseable; verdict unknown.
#
# This file is duplicated verbatim in the wharf `meta` repo, which serves the
# GitLab side and cannot read this one. Change both, or they drift.

set -euo pipefail

REPORT="${1:?usage: govulncheck-gate.sh <report.json> [allowlist]}"
ALLOWLIST="${2:-}"

if [ ! -s "$REPORT" ]; then
  echo "govulncheck-gate: ERROR: '$REPORT' is missing or empty — the scan produced no report" >&2
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# OSV IDs with at least one trace frame naming a function: the vulnerable
# symbol is actually called from this module. A finding with no such frame is
# informational (dependency present, symbol never reached) and must not gate —
# that reachability distinction is the whole reason for -scan symbol.
if ! jq -r 'select(.finding? and any(.finding.trace[]?; .function != null)) | .finding.osv' \
     "$REPORT" > "$work/reachable.raw" 2> "$work/jq.err"; then
  echo "govulncheck-gate: ERROR: '$REPORT' is not parseable govulncheck JSON:" >&2
  cat "$work/jq.err" >&2
  echo "govulncheck-gate: refusing to report a verdict from an unparseable report" >&2
  exit 2
fi
sort -u "$work/reachable.raw" > "$work/reachable.txt"

printf '%s\n' "$ALLOWLIST" | tr ' ' '\n' | sed '/^$/d' | sort -u > "$work/allowed.txt"

# grep exits 1 on "no match", an ordinary outcome for either bucket. With an
# empty allowlist, -Fxf matches nothing and -Fxvf matches everything, which is
# exactly the intended "nothing is waived" behaviour.
allowed_hit=$(grep -Fxf "$work/allowed.txt" "$work/reachable.txt" || true)
unallowed=$(grep -Fxvf "$work/allowed.txt" "$work/reachable.txt" || true)

if [ -n "$allowed_hit" ]; then
  echo "govulncheck-gate: allowed reachable advisories (accepted risk):"
  printf '%s\n' "$allowed_hit"
fi

if [ -n "$unallowed" ]; then
  echo "govulncheck-gate: ERROR: unallowed reachable vulnerabilities:" >&2
  printf '%s\n' "$unallowed" >&2
  echo "" >&2
  echo "Fix: bump the Go version or the affected dependency, or add a justified" >&2
  echo "allowlist entry naming the reachable path and why no bump clears it." >&2
  exit 1
fi

echo "govulncheck-gate: no unallowed reachable vulnerabilities (allowed: ${allowed_hit:-none})."
