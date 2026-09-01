#!/usr/bin/env bash
# check-doc-gate.sh — Layer 3 of the documentation-sync standard: when mapped code
# changes, its mapped docs MUST change in the same MR/PR.
#
# Two complementary gates, both driven by docs-map.yaml:
#
#   1. Package gate — for every packages[] entry, if a non-test .go file directly in
#      that package dir changed, the entry's README (and/or its guides) must change —
#      UNLESS every line the diff touched is marked "// doc-gate:trivial" (see
#      trivial_change() below): a value that changes with no human documentation
#      decision behind it, e.g. a generated version const propagated from an upstream
#      pin bump. Line-level, not file-level — a generated file can mix trivial and
#      non-trivial content, and only the former is exempt.
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

# Fail loudly on malformed YAML instead of letting it surface as silent
# under-enforcement. Every query below runs inside a process substitution or a
# `2>/dev/null || <fallback>` guard for its OWN reason (an absent field, an
# empty array); none of those are equipped to distinguish "field absent" from
# "file unparseable", so a broken map degrades to "nothing to check" rather
# than a hard failure — reaching "doc-gate: OK" without enforcing anything.
yq . "$MAP" >/dev/null 2>&1 || { echo "ERROR: $MAP is not valid YAML" >&2; exit 1; }

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
# Escape a literal path for interpolation into an ERE. A mapped package path is
# arbitrary directory-name text, not a glob — without this, an ERE
# metacharacter in the path (e.g. "pkg/foo+bar", where "+" means "one or more
# of the preceding char") changes what the pattern matches, and the package
# silently stops being checked.
regex_escape() {
  printf '%s' "$1" | sed -e 's/[.[\^$+*?(){}|]/\\&/g'
}
# Is a changed doc's diff byte-trivial (only whitespace / blank-line churn)? Returns 0
# when trivial. A newly added or deleted file is NOT trivial (its lines are real
# additions/removals). --quiet exits 0 when, after ignoring whitespace and blank lines,
# no differences remain.
doc_trivial() {
  git -C "$ROOT" diff --quiet --ignore-all-space --ignore-blank-lines \
    "${BASE}...HEAD" -- "$1"
}
# Is $1, at HEAD, a machine-generated file per the standard Go "Code
# generated ... DO NOT EDIT." header convention (https://go.dev/s/generatedcode)?
# trivial_change() below trusts the doc-gate:trivial marker ONLY inside a file
# this returns true for.
#
# The convention allows the marker line to be preceded by other leading
# comments (a license header, a //go:build constraint) as long as it appears
# before the package clause — scan that whole leading region, not line 1
# alone, or a standards-compliant generated file with a header above the
# marker would be wrongly rejected (go-kure/.github#136 review). Stop at the
# first `package ` line: Go syntax requires exactly one, near the top of
# every file, so normal files stop the scan long before it. The 50-line cap
# is a backstop against a pathological file, not a real limit.
#
# Why gate on this header at all: docs/standards.md's Layer-3 escape hatch is
# explicitly "a maintainer-restricted docs-skip PR label, not a self-applied
# commit trailer" (:541-543). A marker any PR author could drop into
# hand-written source to bypass the gate on their own change would be exactly
# that self-applied trailer in inline-comment form — go-kure/.github#136
# review caught this in the first version of this function, which trusted the
# marker in any file. Gating on the generated-code header instead means the
# only way a line can ever carry the marker is for someone to add it to the
# *generator* — a separate, ordinarily-reviewed change to shared script code,
# not a unilateral annotation on the very diff it's meant to exempt.
is_generated_file() {
  local line n=0
  while IFS= read -r line && ((n++ < 50)); do
    [[ "$line" =~ ^//\ Code\ generated\ .*\ DO\ NOT\ EDIT\.$ ]] && return 0
    [[ "$line" == package\ * ]] && return 1
  done < <(git -C "$ROOT" show "HEAD:$1" 2>/dev/null)
  return 1
}
# Does every line this diff actually touched in $1, at HEAD *and* at BASE,
# carry an explicit "// doc-gate:trivial" marker? A generated const whose
# *value* changes on every upstream pin bump (mise.toml's go version,
# propagated through sync-go-version.sh into pkg/versions/versions_gen.go's
# GoVersion) carries no human documentation decision — unlike the rest of
# that same file's generated content (Dependency.SupportedRange/Min/Max),
# which DOES warrant a paired README update (go-kure/kure's 748c782 + 517e554
# is the real pair that proves it: a genuine supported-range widening,
# correctly caught and fixed).
# Line-level, not whole-file: the two kinds of change live in the same
# generated file, so a whole-file "is this generated" exemption would have
# silently swallowed the SupportedRange case too — go-kure/kure#734 is where
# a first cut of this check got that wrong, caught by testing against real
# history before it shipped.
#
# -U0 (zero context) so each hunk's line range is exactly what changed, with
# nothing to misparse as "touched". A pure-deletion hunk (new-side count 0)
# has no line left to carry a marker — fails closed (not trivial); that's the
# right default when this function can't tell.
#
# Base-side check, not just new-side: a hunk that replaces an unmarked line
# with a differently-marked one would otherwise read as trivial purely
# because the new side looks right, regardless of what the old side actually
# said — go-kure/.github#136 review caught this too. The one case this
# rejects on purpose is the very first commit that adds the marker to a
# previously-unmarked generated line: that one SHOULD cost a real doc touch
# once, since it's the maintainer decision this mechanism otherwise assumes
# was already made.
#
# Pure insertions (old-side count 0 — no line being replaced) are rejected
# for the identical reason, one layer deeper: a brand-new marked line has no
# old side to check at all, so it would otherwise sail through with zero
# evidence a maintainer, rather than this PR's own diff, put the marker
# there — indistinguishable from the self-applied trailer the generated-file
# gate exists to rule out in the first place (go-kure/.github#136 review,
# round 4). Only a line that already existed, already marked, in the merge
# base is trusted to have its *value* change for free; new marked surface —
# a new field, a newly inserted line, a brand-new generated file — always
# costs the doc touch once, same as the first-marking case above.
#
# saw_hunk guards the loop's own default: with zero `@@` lines to read (a
# mode-only change, or any other content-identical diff `-U0` renders with no
# hunks at all — go-kure/.github#136 review found this via a chmod +x
# reproduction), the while loop body never runs and falls through to the
# unconditional success below. That's fail-*open* on exactly the "can't
# tell" case the surrounding comments say should fail closed, so require at
# least one real hunk before trusting the loop's silence.
#
# Old-side reads use the merge-base, not $BASE's own tip: the diff below is
# three-dot (`${BASE}...HEAD`), which git defines as diffing
# merge-base($BASE,HEAD) against HEAD — so the hunk's old-side line numbers
# are only valid against that merge-base's content. $BASE is typically a
# moving ref (origin/main in the documented usage); reading "${BASE}:$f" once
# it has advanced past the merge-base misaddresses old-side lines and can
# reject a genuinely trivial change (go-kure/.github#136 review).
#
# Both blobs are read once, up front, rather than once per line: the
# original per-line `git show | sed` pair re-read the whole file from git on
# every iteration, which is needless I/O for a hunk with many marked lines
# (go-kure/.github#136 review) — this script runs as a shared CI gate across
# every go-kure repo via composite action, not just against the small,
# single-const diffs it was written against.
trivial_change() {
  local f="$1" hunk oldstart oldcount newstart newcount i saw_hunk=0 mb
  is_generated_file "$f" || return 1
  mb="$(git -C "$ROOT" merge-base "$BASE" HEAD)"
  local -a new_lines old_lines
  mapfile -t new_lines < <(git -C "$ROOT" show "HEAD:$f" 2>/dev/null)
  mapfile -t old_lines < <(git -C "$ROOT" show "$mb:$f" 2>/dev/null)
  while IFS= read -r hunk; do
    [[ "$hunk" =~ ^@@\ -([0-9]+)(,([0-9]+))?\ \+([0-9]+)(,([0-9]+))?\ @@ ]] || continue
    saw_hunk=1
    oldstart="${BASH_REMATCH[1]}"
    oldcount="${BASH_REMATCH[3]:-1}"
    newstart="${BASH_REMATCH[4]}"
    newcount="${BASH_REMATCH[6]:-1}"
    [[ "$newcount" -gt 0 ]] || return 1
    [[ "$oldcount" -gt 0 ]] || return 1
    for ((i = 0; i < newcount; i++)); do
      [[ "${new_lines[newstart + i - 1]-}" == *'// doc-gate:trivial'* ]] || return 1
    done
    for ((i = 0; i < oldcount; i++)); do
      [[ "${old_lines[oldstart + i - 1]-}" == *'// doc-gate:trivial'* ]] || return 1
    done
  done < <(git -C "$ROOT" diff -U0 "${BASE}...HEAD" -- "$f" | grep -E '^@@ ')
  [[ "$saw_hunk" == 1 ]]
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
  # their own map entries), excluding tests and lines a maintainer has marked
  # trivial. `path: .` (a root package) needs its own pattern: git diff
  # --name-only reports a root file as "foo.go", never "./foo.go", so
  # "^${path}/[^/]+\.go$" can never match it — every root-package change would
  # silently skip the gate otherwise.
  if [[ "$path" == "." ]]; then
    src_pattern='^[^/]+\.go$'
  else
    src_pattern="^$(regex_escape "$path")/[^/]+\.go\$"
  fi
  src=""
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$f" == *_test.go ]] && continue
    trivial_change "$f" && continue
    src+="$f"$'\n'
  done < <(grep -E "$src_pattern" <<<"$changed_set" || true)
  src="${src%$'\n'}"
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
  # Same fail-loud requirement as the HEAD-side $MAP above: a malformed BASE map
  # would otherwise degrade every query below to "no packages", silently
  # skipping this whole check rather than failing it.
  echo "$base_map" | yq . >/dev/null 2>&1 || { echo "ERROR: docs-map.yaml at ${BASE} is not valid YAML" >&2; exit 1; }
  while IFS= read -r bpath; do
    [[ -n "$bpath" && "$bpath" != "null" ]] || continue
    still_mapped="$(yq ".packages[] | select(.path==\"$bpath\") | .path" "$MAP")"
    [[ -z "$still_mapped" || "$still_mapped" == "null" ]] || continue

    if [[ "$bpath" == "." ]]; then
      src_pattern='^[^/]+\.go$'
    else
      src_pattern="^$(regex_escape "$bpath")/[^/]+\.go\$"
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

# 2b. review_mappings gate for entries REMOVED from the map — mirrors 1b for
# packages, same rationale: a PR that both deletes (or retargets) the
# enforcement row AND changes code that row used to cover would otherwise
# never be checked at all, since section 2 above only reads HEAD's map. That
# makes "delete the review_mappings row" a way to dodge the same-PR
# documentation requirement it exists to enforce.
if [[ -n "$base_map" ]]; then
  n_rm_base="$(echo "$base_map" | yq '.review_mappings | length' 2>/dev/null || echo 0)"
  [[ "$n_rm_base" == "null" ]] && n_rm_base=0
  for ((i = 0; i < n_rm_base; i++)); do
    base_change="$(echo "$base_map" | yq ".review_mappings[$i].change")"
    base_has_docs="$(echo "$base_map" | yq ".review_mappings[$i] | has(\"docs\")")"
    [[ -n "$base_change" && "$base_change" != "null" && "$base_has_docs" == "true" ]] || continue

    # Still present at HEAD (same `change` value)? Section 2 above already
    # covers it — only act on rows that genuinely disappeared or retargeted.
    still_present="$(yq ".review_mappings[]? | select(.change==\"$base_change\") | .change" "$MAP")"
    [[ -z "$still_present" || "$still_present" == "null" ]] || continue

    glob_changed "$base_change" || continue

    ok=0
    while IFS= read -r d; do
      [[ -n "$d" && "$d" != "null" ]] || continue
      doc_changed "$d" && { ok=1; break; }
    done < <(echo "$base_map" | yq ".review_mappings[$i].docs[]?")

    if [[ $ok -ne 1 ]]; then
      docs_list="$(echo "$base_map" | yq -o=csv ".review_mappings[$i].docs" 2>/dev/null || true)"
      echo "FAIL: the review mapping for '$base_change' was removed from docs-map.yaml and matching code changed, but none of its old docs (${docs_list:-<none>}) did — repoint or update them in this PR"
      violations=$((violations + 1))
    fi
  done
fi

if [[ $warnings -gt 0 ]]; then
  echo "doc-gate: $warnings trivial-touch warning(s) above — advisory only, does not fail the gate." >&2
fi

if [[ $violations -gt 0 ]]; then
  echo "doc-gate: $violations mapping(s) changed without doc updates." >&2
  echo "Update the mapped README/doc in this MR, or apply the maintainer-restricted 'docs-skip' label." >&2
  exit 1
fi
echo "doc-gate: OK"
