#!/usr/bin/env bash
# reconcile.sh — prt_decide_finding() / prt_decide_absent(): the pure
# decision table from the design plan. No I/O here; callers (orchestrator)
# perform the action an outcome names and update state accordingly. Kept
# pure and side-effect-free specifically so it can be unit tested exhaustively
# without mocking any network calls.
#
# Two loops, hard barrier between them, enforced by the ORCHESTRATOR, not
# here: loop 1 (prt_decide_finding) evaluates every finding this run produced
# to completion — successes and failures alike — before loop 2
# (prt_decide_absent) evaluates absence for every marked thread not matched
# this run. REVIEW_INCOMPLETE must reflect this run's write outcomes by the
# time loop 2 reads it.

set -uo pipefail

# prt_decide_finding COLLISION VERDICT THREAD_EXISTS THREAD_RESOLVED \
#                     RESOLVED_BY_BOT WITHIN_CAP
# All boolean args are the literal strings "true" or "false".
# VERDICT is one of: FALSE_POSITIVE, VALID, PARTIALLY_VALID, NONE (no
# assessment verdict matched this finding — stays open unreplied, per the
# chunking/assessment-mapping design).
#
# Prints one action word:
#   NONE       — do nothing
#   SUPPRESS   — FALSE POSITIVE, never created; render into the suppressed
#                list in the overflow/summary instead
#   REPLY_RESOLVE   — post the FALSE POSITIVE reply, then resolveReviewThread
#   REPLY_UNRESOLVE — post a recurrence reply, then unresolveReviewThread
#   CREATE     — POST a new review comment (line, falling back to file, per
#                the 422 ladder) with the identity marker embedded
#   OVERFLOW   — VALID/PARTIALLY VALID but beyond the PR-wide cap; goes into
#                the single non-gating advisory comment instead of a thread
prt_decide_finding() {
  local collision="$1" verdict="$2" thread_exists="$3" thread_resolved="$4" \
        resolved_by_bot="$5" within_cap="$6"

  # Row 1: collision beats every other row, matched or absent.
  [ "$collision" = true ] && { echo NONE; return 0; }

  if [ "$verdict" = FALSE_POSITIVE ]; then
    # Row 2: never created in the first place.
    [ "$thread_exists" != true ] && { echo SUPPRESS; return 0; }
    # Row 3: open thread exists for a now-false-positive finding.
    [ "$thread_resolved" != true ] && { echo REPLY_RESOLVE; return 0; }
    # Already resolved (by an earlier run's row 3) — nothing to do.
    echo NONE
    return 0
  fi

  # VALID / PARTIALLY_VALID / NONE (unmatched — stays open, unreplied,
  # identical handling to a not-yet-assessed finding: it either doesn't
  # exist yet (row 4/OVERFLOW) or is already gating (row 5)).
  if [ "$thread_exists" != true ]; then
    if [ "$within_cap" = true ]; then echo CREATE; else echo OVERFLOW; fi
    return 0
  fi

  # Row 5: still open — already gating, nothing to do.
  [ "$thread_resolved" != true ] && { echo NONE; return 0; }

  # Row 6: resolved, but not by the bot — a deliberate human resolution is
  # never reopened, regardless of whether the finding recurs.
  [ "$resolved_by_bot" != true ] && { echo NONE; return 0; }

  # Row 7: resolved by the bot, and the finding is back.
  echo REPLY_UNRESOLVE
}

# prt_decide_absent COLLISION HAS_HUMAN_REPLY THREAD_RESOLVED \
#                    FIRST_ABSENT_SHA CURRENT_SHA REVIEW_INCOMPLETE \
#                    UNANSWERED_MAINT_FAILURE
# FIRST_ABSENT_SHA may be "" (unset).
#
# Evaluation order below deliberately differs from the table's numeric
# listing (8,9,10,11,12,13) while implementing the identical rule set: rows
# 8-11 each state "run complete" (row 8) or are silent on REVIEW_INCOMPLETE
# but only make sense once it does not apply, and the marker/provenance
# section requires a human reply to protect a thread from ANY auto action —
# not only the row-13 case it's numbered next to. So REVIEW_INCOMPLETE and
# has_human_reply are both checked immediately after collision, before any
# first_absent_sha-based branch; every branch below still corresponds
# exactly to one numbered row, just reordered for a single unambiguous
# first-match-wins evaluation.
#
# Prints one action word:
#   NONE             — do nothing (rows 6-analog/9/11/13, or thread already
#                       resolved so absence is moot)
#   CLEAR_MARKER      — row 12: clear first_absent_sha, forcing a clean
#                       restart on a later run
#   SET_FIRST_ABSENT  — row 8: stamp first_absent_sha=<current head sha>
#   REPLY_RESOLVE      — row 10: post the auto-close reply, then
#                       resolveReviewThread
prt_decide_absent() {
  local collision="$1" has_human_reply="$2" thread_resolved="$3" \
        first_absent_sha="$4" current_sha="$5" review_incomplete="$6" \
        unanswered_maint_failure="$7"

  # Row 1: collision beats every row, matched or absent.
  [ "$collision" = true ] && { echo NONE; return 0; }

  # Row 12: this run's evidence can't be trusted — never act on absence.
  # Nothing to clear if first_absent_sha is already empty — skip the wasted
  # GET+PATCH round-trip rather than reissuing a no-op CLEAR_MARKER.
  if [ "$review_incomplete" = true ]; then
    [ -z "$first_absent_sha" ] && { echo NONE; return 0; }
    echo CLEAR_MARKER; return 0
  fi

  # Row 13: a human reply protects the thread from every absence action,
  # including the initial first_absent_sha stamp (a human already engaged;
  # let them close it, don't let a later push auto-resolve out from under
  # their conversation).
  [ "$has_human_reply" = true ] && { echo NONE; return 0; }

  # Already resolved — absence is moot, nothing left to auto-close.
  [ "$thread_resolved" = true ] && { echo NONE; return 0; }

  # Row 8: first sighting of the absence.
  [ -z "$first_absent_sha" ] && { echo SET_FIRST_ABSENT; return 0; }

  # Row 9: same-commit retry (rerun on the identical SHA) is not a second
  # absence — the marker must not be treated as if two pushes confirmed it.
  [ "$first_absent_sha" = "$current_sha" ] && { echo NONE; return 0; }

  # Row 11: a maintenance-failure reply is still unanswered (a marker-clear
  # retried 3x and still failed last run) — exclude this thread from
  # auto-resolve until a human replies to it.
  [ "$unanswered_maint_failure" = true ] && { echo NONE; return 0; }

  # Row 10: two consecutive absences on different SHAs, nothing blocking it.
  echo REPLY_RESOLVE
}
