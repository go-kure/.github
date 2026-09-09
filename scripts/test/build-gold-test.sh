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
# Summary
# ---------------------------------------------------------------------------

printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$pass_count" "$failures"
[ "$failures" -eq 0 ]
