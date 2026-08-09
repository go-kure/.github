#!/usr/bin/env bash
# check-action-pins-test.sh — fixture tests for scripts/check-action-pins.sh.
#
# The checker is the enforcement point for the org's SHA-pinning rule
# (governance/repository-settings-policy.yaml, actions.sha_pinning_required).
# CVE-2025-30066 moved a tag onto a poisoned commit in tj-actions/changed-files,
# which this repo's consumers used by tag. A checker that silently passes is
# worse than no checker, so its own behaviour is pinned by these fixtures.
#
# Usage: check-action-pins-test.sh [REPO_ROOT]

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
CHECKER="$ROOT/scripts/check-action-pins.sh"

failures=0
pass_count=0

# Runs the checker against a throwaway repo containing exactly one workflow file,
# written as REAL multi-line workflow YAML — not a single-line flow mapping, which
# the checker's line-anchored regex would never match and so could never test it.
# Invoked via `bash "$CHECKER"` rather than executed directly, so the fixture never
# depends on the checker's executable bit (a freshly `git add`ed script is 0644;
# this file's own creation step never sets +x, deliberately — bash doesn't need it).
# An empty $content creates no .github/workflows directory at all, exercising the
# checker's handling of a repo that ships no workflows, not merely an empty one.
# Echoes the exit code.
run_fixture() {
  local content="$1" dir
  dir="$(mktemp -d)"
  if [ -n "$content" ]; then
    mkdir -p "$dir/.github/workflows"
    printf '%s\n' "$content" > "$dir/.github/workflows/fixture.yml"
  fi
  bash "$CHECKER" "$dir" >/dev/null 2>&1
  local rc=$?
  rm -rf "$dir"
  echo "$rc"
}

assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected rc=$expected, got rc=$actual" >&2
    failures=$((failures + 1))
  fi
}

SHA=3d3c42e5aac5ba805825da76410c181273ba90b1

fixture_pinned() { cat <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$SHA # v7
EOF
}

fixture_bare_tag() { cat <<'EOF'
jobs:
  a:
    steps:
      - uses: actions/checkout@v7
EOF
}

fixture_cve_action() { cat <<'EOF'
jobs:
  a:
    steps:
      - uses: tj-actions/changed-files@v47
EOF
}

fixture_third_party_main() { cat <<'EOF'
jobs:
  a:
    steps:
      - uses: some-vendor/act@main
EOF
}

fixture_first_party_reusable_workflow() { cat <<'EOF'
jobs:
  a:
    uses: go-kure/.github/.github/workflows/ci.yml@main
EOF
}

fixture_first_party_composite_action() { cat <<'EOF'
jobs:
  a:
    steps:
      - uses: go-kure/.github/.github/actions/check-links@main
EOF
}

fixture_local_action() { cat <<'EOF'
jobs:
  a:
    steps:
      - uses: ./.github/actions/check-links
EOF
}

fixture_docker_ref() { cat <<'EOF'
jobs:
  a:
    steps:
      - uses: "docker://alpine:3.21"
EOF
}

fixture_subpath_pinned() { cat <<EOF
jobs:
  a:
    steps:
      - uses: anchore/sbom-action/download-syft@$SHA # v0
EOF
}

fixture_near_miss() { cat <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@${SHA:0:39}
EOF
}

fixture_run_block_no_false_positive() { cat <<'EOF'
jobs:
  a:
    steps:
      - run: |
          echo hello
EOF
}

assert_rc "40-hex SHA pin passes" 0 \
  "$(run_fixture "$(fixture_pinned)")"

assert_rc "bare tag fails" 1 \
  "$(run_fixture "$(fixture_bare_tag)")"

assert_rc "the CVE-2025-30066 action by tag fails" 1 \
  "$(run_fixture "$(fixture_cve_action)")"

assert_rc "third-party @main fails" 1 \
  "$(run_fixture "$(fixture_third_party_main)")"

assert_rc "first-party reusable workflow @main is allowed (policy exempts it)" 0 \
  "$(run_fixture "$(fixture_first_party_reusable_workflow)")"

assert_rc "first-party composite action @main fails (policy does NOT exempt it)" 1 \
  "$(run_fixture "$(fixture_first_party_composite_action)")"

assert_rc "local ./ action is allowed" 0 \
  "$(run_fixture "$(fixture_local_action)")"

assert_rc "docker:// ref is allowed" 0 \
  "$(run_fixture "$(fixture_docker_ref)")"

assert_rc "sub-path action with SHA passes" 0 \
  "$(run_fixture "$(fixture_subpath_pinned)")"

assert_rc "39-hex near-miss fails" 1 \
  "$(run_fixture "$(fixture_near_miss)")"

# A run: block's shell text is not mistaken for a ref, for the shape of shell text
# this org actually writes. Known, documented limitation (see check-action-pins.sh's
# header): a block-scalar line that happens to itself start with `uses:` would still
# false-positive — verified absent across dot-github/kure/launcher's real workflows
# (`grep` for a run-block line starting `uses:` returns nothing); a full YAML parser
# to close that gap unconditionally is out of scope for this checker.
assert_rc "ordinary run: block does not false-positive" 0 \
  "$(run_fixture "$(fixture_run_block_no_false_positive)")"

assert_rc "repo with no .github/workflows directory at all passes" 0 "$(run_fixture '')"

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
