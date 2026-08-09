#!/usr/bin/env bash
# govulncheck-gate-test.sh — fixture tests for scripts/govulncheck-gate.sh.
#
# The gate decides red vs green from two things: which findings count as
# reachable, and how the allowlist splits them. Both have sharp edges (grep
# exits 1 on no-match; an empty allowlist makes -Fxf match nothing and -Fxvf
# match everything; jq exits non-zero on malformed input and prints nothing,
# which reads as "clean" unless checked). A silent regression here turns the
# gate into a no-op that still prints a green line.
#
# These tests invoke the script itself. A test that reimplemented the filter
# would stay green after the real gate was deleted, which is the specific
# failure this file exists to rule out.
#
# Usage: govulncheck-gate-test.sh [REPO_ROOT]

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
GATE="$ROOT/scripts/govulncheck-gate.sh"

failures=0
pass_count=0

assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected rc=$expected, got rc=$actual" >&2
    failures=$((failures + 1))
  fi
}

run_gate() {  # usage: run_gate <fixture-file> [allowlist] ; echoes the exit code
  bash "$GATE" "$1" "${2:-}" >/dev/null 2>&1
  echo $?
}

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# Reachable: at least one trace frame names a function, so the vulnerable
# symbol is actually called.
cat > "$FIX/reachable.json" <<'EOF'
{"finding":{"osv":"GO-2026-0001","trace":[{"module":"m","function":"Vuln"}]}}
EOF

# Informational: the module is required but no vulnerable symbol is reached.
cat > "$FIX/informational.json" <<'EOF'
{"finding":{"osv":"GO-2026-0002","trace":[{"module":"m"}]}}
EOF

cat > "$FIX/both.json" <<'EOF'
{"finding":{"osv":"GO-2026-0001","trace":[{"module":"m","function":"Vuln"}]}}
{"finding":{"osv":"GO-2026-0002","trace":[{"module":"m"}]}}
EOF

# A scan that produced output but not valid JSON — a crashed or killed
# govulncheck, a runner OOM mid-write, a proxy error page. Must NOT be
# mistaken for "no findings".
printf '{"finding":{"osv":"GO-2026-0001","trace":[{"module' > "$FIX/truncated.json"

: > "$FIX/empty.json"

assert_rc "reachable + empty allowlist blocks"                1 "$(run_gate "$FIX/reachable.json")"
assert_rc "reachable + matching allowlist passes"             0 "$(run_gate "$FIX/reachable.json" "GO-2026-0001")"
assert_rc "informational-only never blocks"                   0 "$(run_gate "$FIX/informational.json")"
assert_rc "mixed: only the reachable one blocks"              1 "$(run_gate "$FIX/both.json")"
assert_rc "allowlist for an absent advisory masks nothing"    1 "$(run_gate "$FIX/reachable.json" "GO-2026-9999")"
assert_rc "multi-entry allowlist covering the finding passes" 0 "$(run_gate "$FIX/both.json" "GO-2026-0001 GO-2026-0002")"
assert_rc "truncated JSON is an error, not a clean result"    2 "$(run_gate "$FIX/truncated.json")"
assert_rc "empty report is an error, not a clean result"      2 "$(run_gate "$FIX/empty.json")"
assert_rc "missing report file is an error"                   2 "$(run_gate "$FIX/does-not-exist.json")"

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
