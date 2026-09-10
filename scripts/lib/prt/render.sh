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
#                     SUPPRESSED_COUNT INCOMPLETE_REASONS [DEGRADED_REASONS]
# Written to $GITHUB_STEP_SUMMARY — free, no API call, so it survives even
# when the job itself fails closed on a REVIEW_INCOMPLETE state.
# DEGRADED_REASONS (go-kure/.github#98) is optional and defaults to empty —
# a caller that hasn't sourced state.sh's prt_mark_degraded family yet still
# gets a summary, just without a REVIEW_DEGRADED section.
prt_render_summary() {
  local mode="$1" sha="$2" chunk_count="$3" findings="$4" suppressed_count="$5" incomplete_reasons="$6" degraded_reasons="${7:-}"
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
    printf -- '- Findings: %s\n' "$(jq 'length' <<< "$findings")"
    printf -- '- Suppressed (FALSE POSITIVE, no thread created): %s\n\n' "$suppressed_count"
    if [ "$(jq 'length' <<< "$findings")" -gt 0 ]; then
      printf '| fp | Severity | Category | File | Line | Verdict |\n'
      printf '|----|----------|----------|------|------|---------|\n'
      jq -r '
        def esc: tostring | gsub("\r\n"; " ") | gsub("[\n\r]"; " ") | gsub("\\|"; "\\|");
        .[] | "| `\(.fp)` | \(.severity|esc) | \(.category|esc) | \(.file|esc) | \((.line // "n/a")|esc) | \((.verdict // "n/a")|esc) |"
      ' <<< "$findings"
    fi
    if [ -n "$incomplete_reasons" ]; then
      printf '\n### REVIEW_INCOMPLETE\n\n'
      printf '%s\n' "$incomplete_reasons" | sed 's/^/- /'
    fi
    if [ -n "$degraded_reasons" ]; then
      printf '\n### REVIEW_DEGRADED\n\n'
      printf '%s\n' "$degraded_reasons" | sed 's/^/- /'
    fi
  }
}

# prt_render_overflow_comment FINDINGS_JSON [QUARANTINED_JSON] — FINDINGS_JSON
# is the array of VALID/PARTIALLY VALID findings beyond the PR-wide cap.
# QUARANTINED_JSON (optional, defaults to empty array) is the array of
# findings withheld because their fp_base collided with another finding this
# run (reconcile.sh row 1 / QUARANTINE, go-kure/.github#155) — never created
# as a thread, so this comment is their only durable home; a job summary
# expires with run retention. Both render as their own table, in one plain
# (non-resolvable) issue comment, reusing the pre-existing endpoint but now
# for overflow and quarantine, never for the whole review.
prt_render_overflow_comment() {
  local findings="$1" quarantined="${2:-[]}"
  local count qcount has_gating_row
  count="$(jq 'length' <<< "$findings")"
  qcount="$(jq 'length' <<< "$quarantined")"
  has_gating_row="$(jq 'any(.[]; .gating == true)' <<< "$quarantined")"
  {
    if [ "$count" -gt 0 ]; then
      printf '## Additional AI Review Findings (advisory — beyond the gating cap)\n\n'
      printf 'These %s finding(s) exceeded the per-PR gating cap and are not blocking, ' "$count"
      printf 'but are worth a look:\n\n'
      printf '| Severity | Category | File | Line | Issue |\n'
      printf '|----------|----------|------|------|-------|\n'
      # gsub("<!-- gokure-pr-review"; ...) neutralizes marker syntax in
      # model-generated prose, matching prt_marker_neutralize (marker.sh) —
      # this comment is posted by the same bot login prt_find_marked_comment
      # scans, so a finding whose issue text happens to quote the exact clean
      # marker (e.g. a self-review of marker.sh itself) must not make this
      # comment eligible to be matched and later overwritten by a clean-verdict
      # upsert (gmr dot-github#88 round 1).
      jq -r '
        def esc: tostring | gsub("\r\n"; " ") | gsub("[\n\r]"; " ") | gsub("\\|"; "\\|") | gsub("<!-- gokure-pr-review"; "&lt;!-- gokure-pr-review");
        .[] | "| \(.severity|esc) | \(.category|esc) | \(.file|esc) | \((.line // "n/a")|esc) | \(.issue|esc) |"
      ' <<< "$findings"
      printf '\n'
    fi
    if [ "$qcount" -gt 0 ]; then
      printf '## Withheld AI Review Findings (advisory — ambiguous fingerprint)\n\n'
      printf 'These %s finding(s) were withheld rather than posted as a review thread ' "$qcount"
      printf 'because their fingerprint (same file and category) is ambiguous, to avoid a '
      printf 'thread that could later be misattributed to the wrong finding. Ambiguity has '
      printf 'three distinct sources — see the Collision column: "this run" means another '
      printf 'finding in *this* diff currently shares the fingerprint; "persisted (earlier '
      printf 'run)" means only this run'"'"'s single finding is present, but an earlier run '
      printf 'recorded the collision on this file+category and it has not been cleared '
      printf 'since — the other finding that originally caused it may be gone; "content '
      printf 'changed (recurring defect)" means this run'"'"'s finding matched an existing '
      printf 'thread by file+category alone, but its text no longer matches what that thread '
      printf 'was opened for — likely a different, later defect at the same location. '
      printf '**Gating status varies per row** — a finding whose fingerprint already had an '
      printf 'open review thread before this collision is still merge-gating through that '
      printf 'existing thread; only a row with no matching thread is genuinely not '
      printf 'blocking:\n\n'
      printf '| Severity | Category | File | Line | Issue | Fix | Collision | Gating |\n'
      printf '|----------|----------|------|------|-------|-----|-----------|--------|\n'
      # Same esc filter, verbatim, as the overflow table above — a
      # quarantined finding is model-generated prose posted by the same bot
      # login and carries the identical marker-collision hazard.
      #
      # quarantine_reason (go-kure/.github#196) is the authoritative source
      # when present; persisted_only alone is kept as the fallback for
      # fixtures/tests predating that field (go-kure/.github#180) so their
      # binary this-run/persisted distinction still renders unchanged.
      jq -r '
        def esc: tostring | gsub("\r\n"; " ") | gsub("[\n\r]"; " ") | gsub("\\|"; "\\|") | gsub("<!-- gokure-pr-review"; "&lt;!-- gokure-pr-review");
        def collision_cell:
          if .quarantine_reason == "content_mismatch" then "content changed (recurring defect)"
          elif .quarantine_reason == "persisted" then "persisted (earlier run)"
          elif .quarantine_reason == "this_run" then "this run"
          elif .persisted_only == true then "persisted (earlier run)"
          else "this run"
          end;
        .[] | "| \(.severity|esc) | \(.category|esc) | \(.file|esc) | \((.line // "n/a")|esc) | \(.issue|esc) | \(.fix|esc) | \(collision_cell) | \(if .gating == true then "yes (existing thread)" else "no" end) |"
      ' <<< "$quarantined"
      printf '\n'
    fi
    printf -- '---\n'
    if [ "$has_gating_row" = true ] && [ "$count" -gt 0 ]; then
      # go-kure/.github#180 kure-bot round 2: the blanket "not merge-gating"
      # claim would contradict a withheld row whose own Gating column says
      # "yes (existing thread)" — a quarantined finding whose pre-collision
      # thread is still open and still blocks merge.
      printf '*Automated review — the overflow table above is advisory only, not '
      printf 'merge-gating. At least one withheld finding above IS gating, through '
      printf 'a pre-existing thread — see its Gating column.*\n'
    elif [ "$has_gating_row" = true ]; then
      # Same caveat, but a quarantine-only run (count=0) never printed the
      # overflow table above — nothing to point "above" at
      # (go-kure/.github#180 codex review, this round).
      printf '*Automated review — advisory only, not merge-gating. At least one '
      printf 'withheld finding above IS gating, through a pre-existing thread — '
      printf 'see its Gating column.*\n'
    else
      printf '*Automated review — advisory only, not merge-gating.*\n'
    fi
  }
}

# prt_render_advisory_comment FINDINGS_JSON [INCOMPLETE_REASONS] [DEGRADED_REASONS]
# — used in `advisory` mode, where NO thread is ever created; this single
# comment carries the merged review+assessment table, matching today's
# plain-comment behavior exactly. INCOMPLETE_REASONS, when non-empty, is
# rendered as a visible warning banner — advisory is the only live-wired
# mode, so if every chunk's model call failed the empty findings list must
# not read as a clean "No issues found." on the review's own output surface,
# with the failure visible only in $GITHUB_STEP_SUMMARY (dot-github#50 gmr
# finding B4). DEGRADED_REASONS (go-kure/.github#98) mirrors that same
# disclosure requirement for the run's non-fatal problems: `prt_mark_degraded`
# covers several distinct shapes (a chunk's malformed rows dropped, an
# assess-call transport fault, an assess response unparseable after
# salvage+retry, an `.assessments` join failure — leaving findings present but
# unverdicted rather than dropped — and a past run's clean-verdict comment
# failing to be superseded), so the banner text itself must stay
# degradation-neutral and defer to the reason bullets below it for the
# specific shape (round 4, go-kure/.github#101 second review pass — the
# original banner said "some rows were dropped ... reflects only the
# surviving rows" unconditionally, which was true only of the first shape and
# misdescribed the other five). The "No issues found." branch must not fire
# whenever EITHER banner is disclosed with zero surviving findings — not just
# the degraded one: a genuinely fatal (incomplete) chunk with nothing usable
# came out of it is strictly *more* severe than a degraded one, so it must
# not be the one case that still reports a clean "No issues found." (round 5,
# kure-bot pr-review AI Code Review on go-kure/.github#101 at 9b2fe22 —
# round 3's fix only extended the suppression to `degraded_reasons` and left
# the pre-existing `incomplete_reasons` zero-count case falling through to
# the plain message, inverting the intended severity ordering). A
# partial-drop chunk whose lone surviving row is then assessed
# FALSE_POSITIVE, or a chunk where nothing at all survived normalization,
# must not read as a clean bill of health either way
# (chatgpt-codex-connector[bot] review,
# github.com/go-kure/.github/pull/101#pullrequestreview-5028172237; kure-bot
# pr-review AI Code Review on go-kure/.github#101 at 9b2fe22).
prt_render_advisory_comment() {
  local findings="$1" incomplete_reasons="${2:-}" degraded_reasons="${3:-}"
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
    if [ -n "$degraded_reasons" ]; then
      printf '> **⚠ This review run was degraded** — see the reason(s) below; this may mean'
      printf ' part of this run'\''s output is incomplete, unverdicted, or dropped.\n'
      printf '%s\n' "$degraded_reasons" | sed 's/^/> - /'
      printf '\n'
    fi
    if [ "$count" -eq 0 ] && { [ -n "$incomplete_reasons" ] || [ -n "$degraded_reasons" ]; }; then
      if [ -n "$incomplete_reasons" ] && [ -n "$degraded_reasons" ]; then
        printf 'No findings to report this run — see the incomplete-run and degraded-run warnings above.\n'
      elif [ -n "$incomplete_reasons" ]; then
        printf 'No findings to report this run — see the incomplete-run warning above.\n'
      else
        printf 'No findings to report this run — see the degraded-run warning above.\n'
      fi
    elif [ "$count" -eq 0 ]; then
      printf 'No issues found.\n'
    else
      printf '| Severity | Category | File | Line | Issue | Fix |\n'
      printf '|----------|----------|------|------|-------|-----|\n'
      # A `|` or embedded newline in model-generated issue/fix text breaks
      # table structure — a bare `|` adds a phantom column, and a `\n` ends
      # the row outright, dropping every finding after it into loose prose
      # (dot-github#50 gmr findings C7/R4, folded into one shared escape
      # here since both defects live in the exact same interpolation). The
      # marker gsub neutralizes any literal quote of the clean-verdict
      # marker in issue/fix text, matching prt_marker_neutralize — this
      # comment is posted by the same bot login prt_find_marked_comment
      # scans (gmr dot-github#88 round 1).
      jq -r '
        def esc: tostring | gsub("\r\n"; " ") | gsub("[\n\r]"; " ") | gsub("\\|"; "\\|") | gsub("<!-- gokure-pr-review"; "&lt;!-- gokure-pr-review");
        .[] | "| \(.severity|esc) | \(.category|esc) | \(.file|esc) | \((.line // "n/a")|esc) | \(.issue|esc) | \(.fix|esc) |"
      ' <<< "$findings"
    fi
    printf '\n---\n*Automated review — advisory only (PR_REVIEW_THREADS_MODE=advisory). '
    printf 'No threads were created or resolved.*\n'
  }
}

# prt_render_clean_comment SHA MODEL CHUNK_COUNT — `enforce` mode's zero-
# findings verdict. Without this, a zero-finding enforce run posts nothing
# (no threads to create), which is indistinguishable on the PR page from the
# job never having run, a model response that parsed to zero findings
# without being a real review, or a stale queued run that self-suppressed —
# the same ambiguity GitLab's mr-review.yml closed 2026-08-22 ("say so when
# a review finds nothing"). Upserted (edited in place) via
# prt_find_marked_comment/prt_upsert_issue_comment — see the PRT_MODE=enforce
# call site in pr-review-threads.sh for the gating conditions (this run's
# own findings count is zero AND the run is not REVIEW_INCOMPLETE).
prt_render_clean_comment() {
  local sha="$1" model="$2" chunk_count="$3"
  cat <<EOF
## AI Code Review — Reviewed, no findings

| | |
|---|---|
| commit | \`${sha}\` |
| model | \`${model}\` |
| chunks | ${chunk_count} |

The review ran to completion and reported nothing.

---
*This comment is edited in place on every push, never appended.*

${PRT_MARKER_CLEAN}
EOF
}

# prt_render_clean_comment_superseded SHA FINDING_COUNT THREADS_WRITTEN \
#                                      SUPPRESSED_COUNT OVERFLOW_COUNT \
#                                      QUARANTINED_COUNT NONE_ANCHORED_COUNT
# — rewrites (never deletes) a prior clean-verdict comment once a later run
# on the same PR finds something. Deleting would destroy the audit trail
# that SHA really was reviewed clean.
#
# "The review threads on this PR carry the current state" is true whenever
# THREADS_WRITTEN>0 OR NONE_ANCHORED_COUNT>0 — the latter is the steady-state
# case where a finding matched an already-existing thread and needed no
# update this run, so no write happened but the existing thread still
# carries it. Keying on THREADS_WRITTEN alone (go-kure/.github#180 kure-bot
# review) misclassified that case as "no thread carries them" and pointed at
# an advisory comment that was never posted when OVERFLOW/QUARANTINED were
# also both 0.
#
# Three cases, not two (go-kure/.github#180 codex review, same round):
#   1. threads carry it, no advisory comment exists (overflow+quarantined=0)
#      — the plain "carry the current state" sentence, unconditionally true.
#   2. an advisory comment exists (overflow+quarantined>0), whether or not
#      threads also carry part of it — point at the advisory comment either
#      way; a mixed run (some anchored, some overflowed/quarantined) must
#      not let "threads carry the current state" imply that's *everything*,
#      and a threads_carry=0 run must not claim threads carry nothing while
#      staying silent about where the rest actually is.
#   3. neither: every finding this run was a suppressed false positive
#      (SUPPRESS has no durable output surface anywhere, by design — go-kure/
#      .github#180 codex review) — must not point at an advisory comment that
#      was never posted (that POST requires overflow or quarantined > 0).
prt_render_clean_comment_superseded() {
  local sha="$1" count="$2" threads_written="$3" suppressed="$4" overflow="$5" quarantined="$6" none_anchored="${7:-0}"
  local threads_carry=$((threads_written + none_anchored))
  local advisory_count=$((overflow + quarantined))
  # A finding whose CREATE failed (network error, non-422 rejection) is
  # counted in none of threads_written/suppressed/overflow/quarantined —
  # prt_mark_incomplete records it, but this function only sees counters.
  # Without this check, that finding fell through to the branch below,
  # which reads count-threads_carry-advisory_count-suppressed findings as
  # "all suppressed as false positives" — a failed write is not a
  # suppression verdict, and saying so misrepresents what the reviewer
  # decided (go-kure/.github#180 codex review, round 3).
  local unaccounted=$((count - threads_carry - advisory_count - suppressed))
  if [ "$unaccounted" -gt 0 ]; then
    cat <<EOF
## ~~AI Code Review — Reviewed, no findings~~ (superseded)

A later review of \`${sha}\` reported **${count} finding(s)**, but ${unaccounted} did not
reach any durable outcome this run (a write likely failed) — this is not the same as being
suppressed as a false positive. Check the job log for the REVIEW_INCOMPLETE reason (e.g.
"create failed" for a single finding, "failed to post overflow comment" for the whole
advisory batch) and re-run if needed.

${PRT_MARKER_CLEAN}
EOF
  elif [ "$advisory_count" -eq 0 ] && [ "$threads_carry" -gt 0 ]; then
    cat <<EOF
## ~~AI Code Review — Reviewed, no findings~~ (superseded)

A later review of \`${sha}\` reported **${count} finding(s)**. The review
threads on this PR carry the current state.

${PRT_MARKER_CLEAN}
EOF
  elif [ "$advisory_count" -gt 0 ]; then
    local lead
    if [ "$threads_carry" -gt 0 ]; then
      lead="Review threads on this PR carry part of the current state."
    else
      lead="Created or updated no review thread this run."
    fi
    cat <<EOF
## ~~AI Code Review — Reviewed, no findings~~ (superseded)

A later review of \`${sha}\` reported **${count} finding(s)**. ${lead}
${suppressed} suppressed (false positive), ${overflow} beyond the gating cap,
${quarantined} withheld (ambiguous fingerprint) — see the advisory comment
on this PR for the withheld/overflow finding bodies.

${PRT_MARKER_CLEAN}
EOF
  else
    cat <<EOF
## ~~AI Code Review — Reviewed, no findings~~ (superseded)

A later review of \`${sha}\` reported **${count} finding(s)**, but created or
updated no review thread this run: all suppressed as false positives, with
no durable output surface anywhere on this PR (suppressed findings are
never rendered, by design).

${PRT_MARKER_CLEAN}
EOF
  fi
}
