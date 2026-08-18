#!/usr/bin/env bash
# marker.sh — build/parse/replace the HTML-comment identity marker that ties a
# GitHub PR review thread back to a finding's fingerprint, across reruns.
#
# First comment on a thread this action owns carries:
#   <!-- gokure-pr-review:v1 fp=<fp>[ collision=true][ first_absent_sha=<40hex>] -->
# Every bot REPLY (never the first comment) carries a different, simpler marker:
#   <!-- gokure-pr-review:v1-note -->
# No code path ever scans both ranges with the same test — ownership questions
# ask about the first comment; has_human_reply questions ask about the rest.
#
# Prefix is org-namespaced, not reused from the sibling GitLab template's prefix —
# see docs/standards.md, "No Downstream References (MUST)".

set -uo pipefail

PRT_MARKER_NOTE='<!-- gokure-pr-review:v1-note -->'
PRT_MARKER_RE='^<!-- gokure-pr-review:v1 fp=([0-9a-f]{16}(-[0-9]+)?)( collision=true)?( first_absent_sha=([0-9a-f]{40}))? -->$'

# prt_marker_build FP [COLLISION] [FIRST_ABSENT_SHA]
# COLLISION: "true" or "" . Prints the marker line to stdout.
prt_marker_build() {
  local fp="$1" collision="${2:-}" first_absent_sha="${3:-}"
  local line="<!-- gokure-pr-review:v1 fp=${fp}"
  [ "$collision" = "true" ] && line="${line} collision=true"
  [ -n "$first_absent_sha" ] && line="${line} first_absent_sha=${first_absent_sha}"
  line="${line} -->"
  printf '%s' "$line"
}

# prt_marker_parse BODY — scans BODY line by line for the first-comment marker.
# On match, prints four TAB-separated fields to stdout: fp, collision(true|""),
# first_absent_sha(40hex|""), and the matched line's 1-based line number. Exits
# 1 (no output) if no line matches — the comment is not one this action owns.
prt_marker_parse() {
  local body="$1" line lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    if [[ "$line" =~ $PRT_MARKER_RE ]]; then
      printf '%s\t%s\t%s\t%s\n' \
        "${BASH_REMATCH[1]}" \
        "$([ -n "${BASH_REMATCH[3]:-}" ] && echo true)" \
        "${BASH_REMATCH[5]:-}" \
        "$lineno"
      return 0
    fi
  done <<< "$body"
  return 1
}

# prt_marker_has_note BODY — true if BODY (a non-first comment) carries the
# reply-note marker anywhere as its own line.
prt_marker_has_note() {
  local body="$1"
  grep -qxF "$PRT_MARKER_NOTE" <<< "$body"
}

# prt_marker_replace BODY NEW_MARKER_LINE — re-finds the OLD marker's exact
# line span and replaces ONLY that line, byte for byte, leaving every other
# line (the finding text) untouched. Never a blind whole-body overwrite —
# that shape of bug once replaced an entire finding's text with just the
# marker in the GitLab implementation this design ports from. If BODY carries
# no marker line, NEW_MARKER_LINE is appended as a new trailing line instead
# (defensive: callers should not normally hit this path).
prt_marker_replace() {
  local body="$1" new_marker="$2"
  local parsed lineno
  if parsed="$(prt_marker_parse "$body")"; then
    lineno="$(cut -f4 <<< "$parsed")"
    awk -v n="$lineno" -v repl="$new_marker" \
      'NR==n { print repl; next } { print }' <<< "$body"
  else
    printf '%s\n%s' "$body" "$new_marker"
  fi
}

# prt_marker_neutralize TEXT — HTML-entity-encodes any literal occurrence of
# the marker's identifying prefix inside model-generated prose, so a finding
# that quotes marker syntax in its own text can never be mistaken for a real
# marker by a first-occurrence line scan. Applied to finding/reply bodies
# before they are ever assembled into a comment.
prt_marker_neutralize() {
  local text="$1"
  text="${text//<!-- gokure-pr-review/\&lt;!-- gokure-pr-review}"
  printf '%s' "$text"
}
