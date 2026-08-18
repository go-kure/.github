#!/usr/bin/env bash
# render.sh — build the markdown bodies posted to GitHub: thread bodies,
# reply bodies, the job-summary, and the overflow/advisory comment.
#
# Every piece of model- or finding-derived prose is run through
# prt_marker_neutralize (marker.sh) before being combined with a real
# marker, so a finding that happens to quote marker syntax in its own text
# can never be mistaken for the real marker by a later parse.

set -uo pipefail

# prt_render_finding_body FINDING_JSON MARKER_LINE — FINDING_JSON has file,
# category, line, severity, issue, fix, fp. Marker is the FIRST line
# (parsers key off "first line of the first comment").
prt_render_finding_body() {
  local finding="$1" marker="$2"
  local severity category issue fix
  severity="$(jq -r '.severity' <<< "$finding")"
  category="$(jq -r '.category' <<< "$finding")"
  issue="$(jq -r '.issue' <<< "$finding")"
  fix="$(jq -r '.fix' <<< "$finding")"
  issue="$(prt_marker_neutralize "$issue")"
  fix="$(prt_marker_neutralize "$fix")"
  cat <<EOF
$marker
**${severity} · ${category}**

${issue}

**Suggested fix:** ${fix}

---
*Automated review finding — reply to discuss, or resolve this thread once addressed.*
EOF
}

# prt_render_reply_false_positive REASONING
prt_render_reply_false_positive() {
  local reasoning
  reasoning="$(prt_marker_neutralize "$1")"
  cat <<EOF
${PRT_MARKER_NOTE}
**Assessment: FALSE POSITIVE.** ${reasoning}

Resolving this thread automatically.
EOF
}

# prt_render_reply_recurrence — posted before an UNresolve.
prt_render_reply_recurrence() {
  cat <<EOF
${PRT_MARKER_NOTE}
This finding recurs in the current diff. Reopening this thread.
EOF
}

# prt_render_reply_absent_resolved — posted before an auto-resolve on
# two-consecutive-absence.
prt_render_reply_absent_resolved() {
  cat <<EOF
${PRT_MARKER_NOTE}
This finding no longer appears in the diff across two consecutive review
runs on different commits. Resolving this thread automatically.
EOF
}

# prt_render_reply_maint_failure REASON — posted when a marker write (e.g.
# clearing first_absent_sha) failed after retries; structurally independent
# of the marker itself, so the audit trail survives even when the edit did
# not.
prt_render_reply_maint_failure() {
  local reason
  reason="$(prt_marker_neutralize "$1")"
  cat <<EOF
${PRT_MARKER_NOTE}
**MAINT_FAILURE:** ${reason}

This thread is excluded from further automated resolve/reopen until a
maintainer replies here.
EOF
}

# prt_render_summary MODE SOURCE_SHA CHUNK_COUNT FINDINGS_JSON \
#                     INCOMPLETE_REASONS
# Written to $GITHUB_STEP_SUMMARY — free, no API call, the audit surface
# that survives even under continue-on-error: true.
prt_render_summary() {
  local mode="$1" sha="$2" chunk_count="$3" findings="$4" incomplete_reasons="$5"
  {
    printf '## PR Review Threads (%s mode)\n\n' "$mode"
    printf -- '- Source SHA: %s\n' "$sha"
    # `--` required on every one of these: a format string starting with `-`
    # is parsed by bash's printf builtin as an option (`-v var`), not text —
    # `printf '- Diff chunks reviewed: %s\n' 3` fails outright with
    # "printf: - : invalid option" and, under this script's set -uo pipefail
    # (deliberately not -e), silently drops just that one summary line
    # rather than aborting (dot-github#50 gmr finding iter5-codex #2).
    printf -- '- Diff chunks reviewed: %s\n' "$chunk_count"
    printf -- '- Findings: %s\n\n' "$(jq 'length' <<< "$findings")"
    if [ "$(jq 'length' <<< "$findings")" -gt 0 ]; then
      printf '| fp | Severity | Category | File | Verdict | Action |\n'
      printf '|----|----------|----------|------|---------|--------|\n'
      jq -r '
        def esc: tostring | gsub("\r\n"; " ") | gsub("[\n\r]"; " ") | gsub("\\|"; "\\|");
        .[] | "| `\(.fp)` | \(.severity|esc) | \(.category|esc) | \(.file|esc) | \((.verdict // "n/a")|esc) | \((.action // "n/a")|esc) |"
      ' <<< "$findings"
    fi
    if [ -n "$incomplete_reasons" ]; then
      printf '\n### REVIEW_INCOMPLETE\n\n'
      printf '%s\n' "$incomplete_reasons" | sed 's/^/- /'
    fi
  }
}

# prt_render_overflow_comment FINDINGS_JSON — FINDINGS_JSON is the array of
# VALID/PARTIALLY VALID findings beyond the PR-wide cap. One plain (non-
# resolvable) issue comment, reusing the pre-existing endpoint but now only
# for overflow, never for the whole review.
prt_render_overflow_comment() {
  local findings="$1"
  local count
  count="$(jq 'length' <<< "$findings")"
  {
    printf '## Additional AI Review Findings (advisory — beyond the gating cap)\n\n'
    printf 'These %s finding(s) exceeded the per-PR gating cap and are not blocking, ' "$count"
    printf 'but are worth a look:\n\n'
    printf '| Severity | Category | File | Issue |\n'
    printf '|----------|----------|------|-------|\n'
    jq -r '
      def esc: tostring | gsub("\r\n"; " ") | gsub("[\n\r]"; " ") | gsub("\\|"; "\\|");
      .[] | "| \(.severity|esc) | \(.category|esc) | \(.file|esc) | \(.issue|esc) |"
    ' <<< "$findings"
    printf '\n---\n*Automated review — advisory only, not merge-gating.*\n'
  }
}

# prt_render_advisory_comment FINDINGS_JSON [INCOMPLETE_REASONS] — used in
# `advisory` mode, where NO thread is ever created; this single comment
# carries the merged review+assessment table, matching today's plain-comment
# behavior exactly. INCOMPLETE_REASONS, when non-empty, is rendered as a
# visible warning banner — advisory is the only live-wired mode, so if every
# chunk's model call failed the empty findings list must not read as a clean
# "No issues found." on the review's own output surface, with the failure
# visible only in $GITHUB_STEP_SUMMARY (dot-github#50 gmr finding B4).
prt_render_advisory_comment() {
  local findings="$1" incomplete_reasons="${2:-}"
  local count
  count="$(jq 'length' <<< "$findings")"
  {
    printf '## AI Code Review (advisory mode — %s finding(s))\n\n' "$count"
    if [ -n "$incomplete_reasons" ]; then
      printf '> **⚠ This review run was incomplete** — some or all chunks failed to review.'
      printf ' The finding count/table below reflects only what succeeded; it is not a clean bill of health.\n'
      printf '%s\n' "$incomplete_reasons" | sed 's/^/> - /'
      printf '\n'
    fi
    if [ "$count" -eq 0 ]; then
      printf 'No issues found.\n'
    else
      printf '| Severity | Category | File | Issue | Fix |\n'
      printf '|----------|----------|------|-------|-----|\n'
      # A `|` or embedded newline in model-generated issue/fix text breaks
      # table structure — a bare `|` adds a phantom column, and a `\n` ends
      # the row outright, dropping every finding after it into loose prose
      # (dot-github#50 gmr findings C7/R4, folded into one shared escape
      # here since both defects live in the exact same interpolation).
      jq -r '
        def esc: tostring | gsub("\r\n"; " ") | gsub("[\n\r]"; " ") | gsub("\\|"; "\\|");
        .[] | "| \(.severity|esc) | \(.category|esc) | \(.file|esc) | \(.issue|esc) | \(.fix|esc) |"
      ' <<< "$findings"
    fi
    printf '\n---\n*Automated review — advisory only (PR_REVIEW_THREADS_MODE=advisory). '
    printf 'No threads were created or resolved.*\n'
  }
}
