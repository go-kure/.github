#!/usr/bin/env bash
# build-gold-test.sh — tests for scripts/eval/build-gold.sh over a synthetic repository.
#
# Builds a real git repository rather than mocking git: build-gold.sh's whole job is
# reading blame and diffs, so a mock would test the mock. The repository is tiny and the
# whole file runs in about a second.
#
# Usage: build-gold-test.sh [REPO_ROOT]

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)" || { echo "no such directory: ${1:-.}" >&2; exit 2; }
BUILD="$ROOT/scripts/eval/build-gold.sh"
[ -f "$BUILD" ] || { echo "not found: $BUILD" >&2; exit 2; }

failures=0
pass_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected [$expected], got [$actual]" >&2
    failures=$((failures + 1))
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/build-gold-test.XXXXXX")" \
  || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# A repository where ONE pull request carries TWO defect-introducing commits.
#
# This is the shape that used to lose a document. Documents are grouped on head_sha, so
# these two commits are two documents; the filename used to be keyed on the PR number,
# which both share, so the second overwrote the first and left nothing on disk saying so
# (go-kure/.github#172). Both commit subjects end in "(#42)", the GitHub squash-merge
# form pr_for_commit recognises.
# ---------------------------------------------------------------------------

REPO="$WORK/repo"
mkdir -p "$REPO" || { echo "mkdir failed" >&2; exit 2; }
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.invalid
git -C "$REPO" config user.name  Test

# Base: a file whose lines are all introduced by an innocent first commit.
printf 'package main\n\nfunc a() int {\n\treturn 0\n}\n' > "$REPO/a.go"
git -C "$REPO" add a.go
git -C "$REPO" commit -q -m 'feat: initial'

# Introducing commit 1 of PR 42 — appends a function with a defect on its return line.
printf '\nfunc b() int {\n\treturn 1\n}\n' >> "$REPO/a.go"
git -C "$REPO" add a.go
git -C "$REPO" commit -q -m 'feat(b): add b (#42)'
intro1=$(git -C "$REPO" rev-parse HEAD)

# Introducing commit 2 of the SAME PR 42 — appends another, in a separate commit.
printf '\nfunc c() int {\n\treturn 2\n}\n' >> "$REPO/a.go"
git -C "$REPO" add a.go
git -C "$REPO" commit -q -m 'feat(c): add c (#42)'
intro2=$(git -C "$REPO" rev-parse HEAD)

# The fix rewrites one line from EACH introducing commit, so blame at fix^ names both.
printf 'package main\n\nfunc a() int {\n\treturn 0\n}\n\nfunc b() int {\n\treturn 10\n}\n\nfunc c() int {\n\treturn 20\n}\n' > "$REPO/a.go"
git -C "$REPO" add a.go
git -C "$REPO" commit -q -m 'fix(bc): correct the return values'

OUT="$WORK/gold"
build_log=$("$BUILD" --repo "$REPO" --repo-name test/repo --out "$OUT" --max-fixes 10 2>&1)
build_rc=$?

assert_eq "build-gold exits 0 on a repository with confirmable rows" "0" "$build_rc"

on_disk=$(find "$OUT" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
assert_eq "one PR carrying two introducing commits yields two documents, not one" \
  "2" "$on_disk"

# The regression proper: the two documents must be distinguishable ON DISK. Asserting the
# filenames carry the head_sha, not the shared PR number, is what fails if the naming key
# ever goes back to being coarser than the grouping key.
assert_eq "the first introducing commit has its own file" \
  "1" "$(find "$OUT" -maxdepth 1 -name "*${intro1:0:12}.json" | wc -l | tr -d ' ')"
assert_eq "the second introducing commit has its own file" \
  "1" "$(find "$OUT" -maxdepth 1 -name "*${intro2:0:12}.json" | wc -l | tr -d ' ')"
assert_eq "no document is named after the shared PR number" \
  "0" "$(find "$OUT" -maxdepth 1 -name '*pr42.json' | wc -l | tr -d ' ')"

# `pr` is provenance and stays in the content even though it no longer names the file.
assert_eq "both documents still record the PR number they came from" \
  "42 42" "$(jq -s -r '[.[].pr] | sort | map(tostring) | join(" ")' "$OUT"/*.json)"

# The end-of-run summary is the only record an operator gets, and the one number that can
# be checked without trusting this script's own counters is the artefact itself. These two
# assertions are the counter-vs-payload check: they compare the log line against the files.
reported_docs=$(sed -n 's/.*installed \([0-9]*\) documents.*/\1/p' <<<"$build_log" | tail -1)
reported_rows=$(sed -n 's/.*installed [0-9]* documents (\([0-9]*\) rows).*/\1/p' <<<"$build_log" | tail -1)
assert_eq "the reported document count equals what is on disk" "$on_disk" "$reported_docs"
assert_eq "the reported row count equals what is on disk" \
  "$(jq -s '[.[].gold[]] | length' "$OUT"/*.json)" "$reported_rows"

# ---------------------------------------------------------------------------
# confirmed_offsets: a duplicated token confirms an untouched interior line by TEXT alone, and
# the POSITION gate must be what rejects it (go-kure/.github#171).
#
# Real case this reproduces: pkg/kubernetes/fluxcd/create.go orig lines 128-130, where 128 and
# 130 are genuinely added and 129 sits in an untouched gap between two hunks -- but 129's own
# short text happened to recur inside an added line elsewhere in the same commit's diff, so the
# old whole-span, text-only check confirmed all three as one row.
#
# Tested by extracting confirmed_offsets and ws_sensitive VERBATIM out of build-gold.sh rather
# than through the end-to-end pipeline: `git blame` correctly refuses to attribute genuinely
# untouched content to the commit that touched its neighbours (confirmed by hand against several
# constructions while writing this test), so this exact shape cannot be provoked through normal
# git history without deliberately re-implementing whatever internal diff-alignment choice
# produced it in the real repository. Extracting the function verbatim (not a hand-copied
# reimplementation) means any future edit to the real function is exercised here unchanged --
# there is nothing to keep in sync by hand.
extract_func() {
  awk -v fn="$2" '$0 ~ "^" fn "\\(\\) \\{" { p = 1 } p { print } p && /^}/ { exit }' "$1"
}
eval "$(extract_func "$BUILD" ws_sensitive)"
eval "$(extract_func "$BUILD" confirmed_offsets)"

REPO2="$WORK/repo2"
mkdir -p "$REPO2"
git -C "$REPO2" init -q -b main
git -C "$REPO2" config user.email t@example.invalid
git -C "$REPO2" config user.name  Test

# Filler lines (F5-F8) keep the two real edits far from the far-away duplicate at position 9,
# so git's diff algorithm has no local ambiguity to resolve near position 3 -- without them, an
# earlier version of this fixture had a NEARBY duplicate and git's own LCS chose to represent
# position 3 as freshly inserted instead of unchanged, which shifted the gap this test needs to
# a different position than the one being asserted.
printf 'L1\nOLD2\nECHO\nOLD4\nF5\nF6\nF7\nF8\nOLD9\nL10\n' > "$REPO2/f.txt"
git -C "$REPO2" add f.txt
git -C "$REPO2" commit -q -m base

# Position 3 ("ECHO") is untouched by this commit -- it stays out of every hunk below. Position
# 9, in an unrelated hunk far away, happens to be rewritten to the SAME text "ECHO" -- the
# duplicate that lets a text-only check confirm position 3 by accident.
printf 'L1\nHELLO\nECHO\nWORLD2\nF5\nF6\nF7\nF8\nECHO\nL10\n' > "$REPO2/f.txt"
git -C "$REPO2" add f.txt
git -C "$REPO2" commit -q -m intro
sha2=$(git -C "$REPO2" rev-parse HEAD)

git_r() { git -C "$REPO2" "$@"; }

# The candidate span as build-gold.sh's own collapse would have assembled it, IF blame had
# (wrongly, as real blame does not here) attributed all three lines to sha2: orig 2..4, text
# read in orig order.
offsets="$(confirmed_offsets "$sha2" f.txt 2 "$(printf 'HELLO\nECHO\nWORLD2')")"
assert_eq "position 2 (genuinely added) confirms" "1" \
  "$(grep -c '^2$' <<<"$offsets")"
assert_eq "position 3 (untouched, text-duplicate only) does NOT confirm" "0" \
  "$(grep -c '^3$' <<<"$offsets")"
assert_eq "position 4 (genuinely added) confirms" "1" \
  "$(grep -c '^4$' <<<"$offsets")"
assert_eq "exactly two offsets survive, not three" "2" \
  "$(grep -c . <<<"$offsets")"

# ---------------------------------------------------------------------------
# The text-extraction awk inside the main loop: a flist naming the same final line number twice
# (legitimate -- final_lineno need not rise in step with orig_lineno, so two different orig
# positions can map to one final line) must not spuriously fail confirmation. Extracted verbatim
# from between its two delimiting markers, since it is an inline awk program rather than a named
# bash function and so cannot go through extract_func above.
extract_awk_block() {
  awk -v start='text=$(git_r show "$parent:$path"' -v stop="') || text=" '
    index($0, start) { p = 1; next }
    p && index($0, stop) { exit }
    p
  ' "$1"
}
extract_program="$(extract_awk_block "$BUILD")"
[ -n "$extract_program" ] || { echo "FAIL: could not extract the text-extraction awk block from $BUILD" >&2; failures=$((failures + 1)); }

blob=$'L1\nA\nB\nC'
dup_out="$(printf '%s\n' "$blob" | awk -v list="2,4,2" "$extract_program")"
dup_rc=$?
assert_eq "duplicate flist entry: exit 0, not spuriously dropped" "0" "$dup_rc"
assert_eq "duplicate flist entry: prints each occurrence in flist's own order" \
  "$(printf 'A\nC\nA')" "$dup_out"

# ---------------------------------------------------------------------------
# emit_runs/emit_run: the same confirmed-offsets gap (2 and 4 survive, 3 does not) must become
# TWO gold rows, [2,2] and [4,4] -- never a reconstructed [2,4] -- and both must carry the exact
# same fix_commit, note and provenance. Extracted verbatim for the same reason as above.
# ---------------------------------------------------------------------------
eval "$(extract_func "$BUILD" emit_run)"
eval "$(extract_func "$BUILD" emit_runs)"

work="$WORK/emit-work"
mkdir -p "$work"
: >"$work/gold.ndjson"
# emit_run/emit_runs read these by name from their caller's scope (they are extracted verbatim
# out of build-gold.sh's own main loop, where the same variables are set once per candidate
# row) -- shellcheck cannot see that dynamic-scope use through the eval above.
# shellcheck disable=SC2034
n_rows=0
# shellcheck disable=SC2034
repo_name="test/repo" pr="7" sha="$sha2" base="deadbeef" intro_title="feat: add stuff" \
  path="f.txt" fix="feedface" note="fix: correct stuff"

emit_runs "$offsets"

assert_eq "two rows were written, not one reconstructed span" "2" \
  "$(wc -l <"$work/gold.ndjson" | tr -d ' ')"
assert_eq "row 1 lines is [2,2]" "[2,2]" "$(sed -n 1p "$work/gold.ndjson" | jq -c '.gold[0].lines')"
assert_eq "row 2 lines is [4,4]" "[4,4]" "$(sed -n 2p "$work/gold.ndjson" | jq -c '.gold[0].lines')"
assert_eq "row 1 keeps fix_commit" "feedface" \
  "$(sed -n 1p "$work/gold.ndjson" | jq -r '.gold[0].fix_commit')"
assert_eq "row 2 keeps the SAME fix_commit as row 1, not a different one" "feedface" \
  "$(sed -n 2p "$work/gold.ndjson" | jq -r '.gold[0].fix_commit')"
assert_eq "row 1 keeps the note" "fix: correct stuff" \
  "$(sed -n 1p "$work/gold.ndjson" | jq -r '.gold[0].note')"
assert_eq "row 2 keeps the SAME note as row 1" "fix: correct stuff" \
  "$(sed -n 2p "$work/gold.ndjson" | jq -r '.gold[0].note')"
assert_eq "row 2 keeps head_sha (provenance), same as row 1" "$sha2" \
  "$(sed -n 2p "$work/gold.ndjson" | jq -r '.head_sha')"

printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$pass_count" "$failures"
[ "$failures" -eq 0 ]
