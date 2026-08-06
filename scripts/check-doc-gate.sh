#!/usr/bin/env bash
# check-doc-gate.sh — Layer 3 of the documentation-sync standard: when mapped code
# changes, its mapped docs MUST change in the same MR/PR.
#
# Two complementary gates, both driven by docs-map.yaml:
#
#   1. Package gate — for every packages[] entry, if a non-test .go file directly in
#      that package dir changed, the entry's README (and/or its guides) must change.
#      Also covers packages REMOVED from the map between base and head: if a
#      package's old source path still shows real changes, its old docs must too.
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

# -c core.quotePath=false: without it, git's factory default (true) renders any
# non-ASCII filename as a quoted, octal-escaped literal (e.g. "café.md" becomes
# the literal string "caf\303\251.md", quotes included) — every doc_changed /
# glob_changed comparison against the real path would then silently never match.
# This machine's own git config happens to override the default, which is
# exactly why pinning it explicitly here matters instead of trusting whatever
# the running environment has configured.
#
# --no-renames: without it, a pure rename (content-identical git-mv) reports only
# the new path, and the old path never appears in changed_set at all — the 1b.
# removed-package loop below would then silently skip checking the old docs for a
# renamed-away package, and it depends on whichever machine happens to run this
# (git's diff.renames default is off, but a dev machine or CI image can override
# it). Pin the behavior instead of inheriting the environment's config.
changed_set="$(git -c core.quotePath=false -C "$ROOT" diff --no-renames --name-only "${BASE}...HEAD")"
doc_changed() { grep -qxF "$1" <<<"$changed_set"; }
# Repo-root-relative glob match against the changed set (e.g. "internal/foo/**").
# "**" crosses path separators (recursive) and — like gitignore/rsync doublestar
# semantics — can match zero directory levels: "**/*.go" matches a root-level
# "root.go", and "foo/**/bar" matches "foo/bar" with nothing in between. A bare
# "*" does not cross "/" (e.g. "scripts/*.sh" matches "scripts/x.sh" but not
# "scripts/lib/x.sh"). Bash's own `[[ == pattern ]]` gets none of this (a lone
# "*" always matches "/" too, and there's no zero-level concept), so translate
# to a regex instead of relying on shell glob matching.
glob_to_regex() {
  local pat="$1"
  pat="$(printf '%s' "$pat" | sed -e 's/[.[\^$+?(){}|]/\\&/g')"
  # Order matters: the two-sided "**/" / "/**" forms (which absorb an adjacent
  # slash and can match zero directory levels) must be handled before the
  # generic lone "**" and single "*" translations below.
  pat="${pat//\*\*\//$'\x02'}"
  pat="${pat//\/\*\*/$'\x03'}"
  pat="${pat//\*\*/$'\x01'}"
  pat="${pat//\*/[^/]*}"
  pat="${pat//$'\x02'/(.*/)?}"
  pat="${pat//$'\x03'/(/.*)?}"
  pat="${pat//$'\x01'/.*}"
  printf '^%s$' "$pat"
}
glob_changed() {
  local regex f
  regex="$(glob_to_regex "$1")"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$f" =~ $regex ]] && return 0
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

# 1b. Package gate for packages REMOVED from the map. The loop above only sees
# HEAD's docs-map.yaml, so a package deleted or renamed out of the map between
# BASE and HEAD is invisible to it — its old source files can be deleted (or
# moved away) without ever checking that its old README/guides also changed,
# letting stale docs survive a removal. Diff the map itself: for any package
# path present at BASE but absent at HEAD, if its old source path still shows
# real changes (near-certainly deletions), its old docs must show a change too.
#
# The map file's own location at BASE isn't necessarily HEAD's location — a PR
# that both moves docs-map.yaml (root <-> site/) AND removes a package in the
# same change would have the git-show below silently find nothing at the wrong
# path, skipping this whole check. Try both locations, same as the original
# HEAD-side resolution above.
base_map="$(git -C "$ROOT" show "${BASE}:docs-map.yaml" 2>/dev/null || true)"
[[ -n "$base_map" ]] || base_map="$(git -C "$ROOT" show "${BASE}:site/docs-map.yaml" 2>/dev/null || true)"
if [[ -n "$base_map" ]]; then
  while IFS= read -r bpath; do
    [[ -n "$bpath" && "$bpath" != "null" ]] || continue
    still_mapped="$(yq ".packages[] | select(.path==\"$bpath\") | .path" "$MAP")"
    [[ -z "$still_mapped" || "$still_mapped" == "null" ]] || continue

    if [[ "$bpath" == "." ]]; then
      src_pattern='^[^/]+\.go$'
    else
      src_pattern="^${bpath}/[^/]+\.go\$"
    fi
    src="$(grep -E "$src_pattern" <<<"$changed_set" | grep -v '_test\.go$' || true)"
    [[ -n "$src" ]] || continue

    # Require the README specifically, not "readme OR any one guide" — a
    # removed package's README is package-exclusive (check-doc-sync.sh already
    # requires every package to name one, mounted or not) so its fate on
    # removal is unambiguous. guides[] are deliberately NOT required here: they
    # are commonly shared across multiple packages (kure's own docs-map.yaml
    # has guides/flux-workflow mapped from 3 separate packages) — removing one
    # of several packages that reference a still-valid shared guide should not
    # force that guide to change too. check-doc-sync.sh's own guide-target
    # existence check (Layer 2) already catches an orphaned guide reference
    # independently, if one becomes unreferenced entirely.
    old_readme="$(echo "$base_map" | yq ".packages[] | select(.path==\"$bpath\") | .readme")"
    ok=0
    if [[ -n "$old_readme" && "$old_readme" != "null" ]] && doc_changed "$old_readme"; then
      ok=1
    fi

    if [[ $ok -ne 1 ]]; then
      echo "FAIL: $bpath was removed from docs-map.yaml and its old source changed, but its old README (${old_readme:-<none>}) did not — repoint or update it in this PR"
      violations=$((violations + 1))
    fi
  done < <(echo "$base_map" | yq '.packages[]?.path')
fi

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
