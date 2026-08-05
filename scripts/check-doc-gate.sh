#!/usr/bin/env bash
# check-doc-gate.sh — Layer 3 of the documentation-sync standard: when mapped code
# changes, its mapped docs MUST change in the same MR/PR.
#
# Two complementary gates, both driven by docs-map.yaml:
#
#   1. Package gate — for every packages[] entry, if a non-test .go file directly in
#      that package dir changed, the entry's README (and/or its guides) must change.
#   2. review_mappings gate — for every review_mappings[] entry that carries BOTH an
#      explicit `change:` glob AND a `docs:` list, if any changed file matches the
#      glob, at least one of the mapped docs must change. Entries lacking that
#      machine-field pair (legacy display rows with `reference`/scalar `guides`) are
#      presentation-only and ignored here.
#
# All paths — changed files, globs, READMEs, docs — are repo-root-relative, even when
# the map lives under site/ (the map's *location* is independent of what it points to).
#
# The trigger is intentionally coarse ("mapped code changed", not a true API diff);
# the maintainer-restricted `docs-skip` escape hatch handles false positives.
#
# Trivial-touch warning (advisory, non-blocking): when a mapping IS satisfied but the
# only touched mapped doc(s) have a whitespace/blank-only diff, emit a machine-greppable
# `doc-gate: WARN trivial-touch …` line. This surfaces the "touched the doc just to pass
# the gate" case for reviewer judgement; it never fails the build (false positives — a
# genuinely whitespace-only code change paired with a typo fix — exist by design).
#
# Usage: bash check-doc-gate.sh <base-ref> [ROOT] [--skip=true|false]
#   <base-ref>  ref to diff against (e.g. origin/main)
#   ROOT        repo root (default: git toplevel)
#   --skip      when true, bypass the gate (CI passes this from the docs-skip label).

set -euo pipefail

SKIP=false
ARGS=()
for a in "$@"; do
  case "$a" in
    --skip=*) SKIP="${a#--skip=}" ;;
    *) ARGS+=("$a") ;;
  esac
done
BASE="${ARGS[0]:?usage: check-doc-gate.sh <base-ref> [ROOT] [--skip=...]}"
ROOT="${ARGS[1]:-$(git rev-parse --show-toplevel)}"
ROOT="$(cd "$ROOT" && pwd)"

if [[ "$SKIP" == "true" ]]; then
  echo "doc-gate: bypassed via maintainer docs-skip label."
  exit 0
fi

command -v yq >/dev/null 2>&1 || { echo "ERROR: yq (mikefarah v4) is required" >&2; exit 1; }

if [[ -f "$ROOT/docs-map.yaml" ]]; then MAP="$ROOT/docs-map.yaml"
elif [[ -f "$ROOT/site/docs-map.yaml" ]]; then MAP="$ROOT/site/docs-map.yaml"
else echo "ERROR: docs-map.yaml not found under $ROOT (or $ROOT/site)" >&2; exit 1
fi

changed_set="$(git -C "$ROOT" diff --name-only "${BASE}...HEAD")"
doc_changed() { grep -qxF "$1" <<<"$changed_set"; }
# Repo-root-relative glob match against the changed set (e.g. "internal/foo/**").
glob_changed() {
  local pat="$1" f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    # shellcheck disable=SC2053
    [[ "$f" == $pat ]] && return 0
  done <<<"$changed_set"
  return 1
}
# Is a changed doc's diff byte-trivial (only whitespace / blank-line churn)? Returns 0
# when trivial. A newly added or deleted file is NOT trivial (its lines are real
# additions/removals). --quiet exits 0 when, after ignoring whitespace and blank lines,
# no differences remain.
doc_trivial() {
  git -C "$ROOT" diff --quiet --ignore-all-space --ignore-blank-lines \
    "${BASE}...HEAD" -- "$1"
}

violations=0
warnings=0
# Advisory: a satisfied mapping whose only touched doc(s) are whitespace-only.
warn_trivial() {
  echo "doc-gate: WARN trivial-touch — $1 changed, but its only touched mapped doc(s) [$2] have a whitespace/blank-only diff; a reviewer should confirm the prose still matches the code." >&2
  warnings=$((warnings + 1))
}

# 1. Package gate.
while IFS= read -r path; do
  [[ -n "$path" && "$path" != "null" ]] || continue
  # Source files directly in this package dir (not nested subpackages, which are
  # their own map entries), excluding tests. `path: .` (a root package) needs its
  # own pattern: git diff --name-only reports a root file as "foo.go", never
  # "./foo.go", so "^${path}/[^/]+\.go$" can never match it — every root-package
  # change would silently skip the gate otherwise.
  if [[ "$path" == "." ]]; then
    src_pattern='^[^/]+\.go$'
  else
    src_pattern="^${path}/[^/]+\.go\$"
  fi
  src="$(grep -E "$src_pattern" <<<"$changed_set" | grep -v '_test\.go$' || true)"
  [[ -n "$src" ]] || continue

  readme="$(yq ".packages[] | select(.path==\"$path\") | .readme" "$MAP")"
  ok=0; nontrivial=0; matched=()
  if [[ -n "$readme" && "$readme" != "null" ]] && doc_changed "$readme"; then
    ok=1; matched+=("$readme"); doc_trivial "$readme" || nontrivial=1
  fi
  while IFS= read -r g; do
    [[ -n "$g" && "$g" != "null" ]] || continue
    gp="site/content/${g}.md"
    if doc_changed "$gp"; then
      ok=1; matched+=("$gp"); doc_trivial "$gp" || nontrivial=1
    fi
  done < <(yq ".packages[] | select(.path==\"$path\") | .guides[]?" "$MAP")

  if [[ $ok -ne 1 ]]; then
    echo "FAIL: $path source changed but its docs did not (expected a change to $readme or its mapped guides)"
    violations=$((violations + 1))
  elif [[ $nontrivial -eq 0 && ${#matched[@]} -gt 0 ]]; then
    warn_trivial "$path source" "${matched[*]}"
  fi
done < <(yq '.packages[]?.path' "$MAP")

# 2. review_mappings gate (machine-field opt-in: needs `change` glob AND `docs` list).
n_rm="$(yq '.review_mappings | length' "$MAP" 2>/dev/null || echo 0)"
[[ "$n_rm" == "null" ]] && n_rm=0
for ((i = 0; i < n_rm; i++)); do
  change="$(yq ".review_mappings[$i].change" "$MAP")"
  has_docs="$(yq ".review_mappings[$i] | has(\"docs\")" "$MAP")"
  [[ -n "$change" && "$change" != "null" && "$has_docs" == "true" ]] || continue
  glob_changed "$change" || continue

  ok=0; nontrivial=0; matched=()
  while IFS= read -r d; do
    [[ -n "$d" && "$d" != "null" ]] || continue
    if doc_changed "$d"; then
      ok=1; matched+=("$d"); doc_trivial "$d" || nontrivial=1
    fi
  done < <(yq ".review_mappings[$i].docs[]?" "$MAP")

  if [[ $ok -ne 1 ]]; then
    docs_list="$(yq -o=csv ".review_mappings[$i].docs" "$MAP" 2>/dev/null || true)"
    echo "FAIL: code matching '$change' changed but none of its mapped docs did (expected one of: $docs_list)"
    violations=$((violations + 1))
  elif [[ $nontrivial -eq 0 && ${#matched[@]} -gt 0 ]]; then
    warn_trivial "code matching '$change'" "${matched[*]}"
  fi
done

if [[ $warnings -gt 0 ]]; then
  echo "doc-gate: $warnings trivial-touch warning(s) above — advisory only, does not fail the gate." >&2
fi

if [[ $violations -gt 0 ]]; then
  echo "doc-gate: $violations mapping(s) changed without doc updates." >&2
  echo "Update the mapped README/doc in this MR, or apply the maintainer-restricted 'docs-skip' label." >&2
  exit 1
fi
echo "doc-gate: OK"
