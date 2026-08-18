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
#
# This file also owns the PR-wide gating-cap budget derived from the decision
# table above (prt_thread_stays_gating / prt_reserved_count /
# prt_gating_eligible / prt_apply_cap, below). Those four use jq — the rest
# of this file deliberately doesn't, since prt_decide_finding/prt_decide_absent
# are plain string-comparison decision tables with no JSON to walk.

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

# --- PR-wide severity cap: bound the number of gating (currently open, or
# about to become open/reopened) review threads to PRT_MAX_FINDINGS_TOTAL.
#
# Rewritten in iteration 6 (dot-github#50 gmr finding iter6-codex#1) after 3
# successive narrower fixes each left a gap. The root cause common to all of
# them: WITHIN_CAP is read ONLY in prt_decide_finding's thread_exists=false
# branch (row 4) — rows 1, 5, 6, 7 never consult it. So an OWNED-matched
# finding never needs to WIN a rank slot; it only needs its thread's fate
# (stays open / stays resolved / reopens) counted against the budget BEFORE
# any row-4 candidate is allowed to compete for what's left. Ranking existing
# threads (every prior version of this block did that, by excluding some fp
# set from the eligible-for-rank list) is provably insufficient: a reserved
# thread that ranks outside the top N still stays gating (rows 1-open/5/7
# ignore rank), so it silently stopped reserving anything the moment
# cap-worth of higher-priority candidates existed — confirmed by two
# independent counterexamples: (a) severity reordering across reruns can
# rank an already-gating thread below new candidates even with an unchanged
# finding set, and (b) a persisted open collision thread (previously
# excluded from ranking entirely, unconditionally) never reserved a slot at
# all. Fix: compute the reserved count by walking OWNED (every currently-known
# bot thread, matched or not against this run's findings) and asking "does
# prt_decide_finding's outcome for this thread leave it gating after this
# run?" (prt_thread_stays_gating) — mirroring this file's own row order, not
# approximating it via rank. "Gating" below means the intended terminal
# outcome of that row, not a guarantee the mutation behind it succeeds (a
# failed REPLY_RESOLVE/REPLY_UNRESOLVE leaves a thread reserved-as-non-gating
# or vice versa for this run only; it self-heals next run via
# REVIEW_INCOMPLETE and the freshness gate, dot-github#50 gmr finding
# N2-iter6):
#   thread absent from this run's findings -> gating iff currently open
#     (approximation, safe in the over-reserving direction only: a thread
#     already on its SECOND consecutive absence this run resolves via row
#     10/REPLY_RESOLVE and stops gating, but first_absent_sha persists
#     across runs in the marker so that can't be told apart here from a
#     first-ever absence without re-deriving loop 2's own state; treating
#     both as still-gating can only under-utilize the cap for this one run,
#     never exceed it, dot-github#50 gmr finding N1-iter6). This branch does
#     NOT call prt_decide_finding — routing it through prt_decide_finding
#     with a defaulted NONE verdict is a real divergence: with
#     thread_resolved=true, resolved_by_bot=true it reaches row 7
#     (REPLY_UNRESOLVE), which prt_thread_stays_gating counts as gating —
#     this branch never does, for any resolved absent thread, regardless of
#     who resolved it (codex round 1 finding P1-1).
#   effective collision (this run's or persisted)      -> row 1: gating iff open
#   verdict FALSE_POSITIVE                              -> row 2/3: never gating
#     (already resolved, or about to become resolved via REPLY_RESOLVE)
#   currently open (non-collision, non-FALSE_POSITIVE)  -> row 5: gating
#   currently resolved, resolved_by_bot                 -> row 7: gating (reopens)
#   currently resolved, not by bot                       -> row 6: never gating
# Only genuinely NEW findings (no OWNED match at all) ever need a rank slot —
# they're the only candidates row 4 can CREATE — so prt_gating_eligible is
# restricted to exactly that set, and remaining = max(0, CAP -
# reserved_count) bounds how many of them can be within_cap. Re-derived by
# hand: 12 findings, cap 5, nothing fixed between reruns -> run 1 creates 5
# (reserved=0, 5 of 12 new candidates ranked in); run 2, same or reordered
# severities -> reserved=5 (the 5 open threads, regardless of rank),
# remaining=0, none of the other 7 compete -> still 5 gating, unconditionally.
# A persisted open collision thread + 5 new eligible findings, cap 5 ->
# reserved=1, remaining=4 -> 1+4=5, not 6. ---

# prt_thread_stays_gating ACTION THREAD_RESOLVED -> true/false
# ACTION is a prt_decide_finding outcome for an OWNED (thread_exists=true)
# row. THREAD_RESOLVED is that row's *current* (pre-action) resolved state.
prt_thread_stays_gating() {
  local action="$1" thread_resolved="$2"
  case "$action" in
    REPLY_UNRESOLVE) echo true ;;
    REPLY_RESOLVE) echo false ;;
    NONE) [ "$thread_resolved" != true ] && echo true || echo false ;;
    # CREATE/OVERFLOW/SUPPRESS: unreachable when thread_exists=true (every
    # OWNED row this function is called for) — spelled out explicitly
    # rather than falling into this default by coincidence. This does NOT
    # fail loud: an unrecognized action still echoes false, rc 0, same as
    # the real non-gating case, so a future decision-table change that
    # breaks the thread_exists=true invariant would silently undercount
    # here rather than error. Check this function first if the reserved
    # count looks wrong after adding a new prt_decide_finding action word.
    *) echo false ;;
  esac
}

# prt_reserved_count OWNED_JSON FINDINGS_JSON -> integer
# Walks OWNED (bash loop; jq per row). See the rationale block above for the
# per-branch mapping to prt_decide_finding's rows.
prt_reserved_count() {
  local owned="$1" findings="$2"
  local count=0 row

  while IFS= read -r row; do
    [ -z "$row" ] && continue
    local fp match gating=false
    fp="$(jq -r '.fp' <<< "$row")"
    match="$(jq -c --arg fp "$fp" '[.[] | select(.fp == $fp)] | .[0] // null' <<< "$findings")"

    if [ "$match" = null ]; then
      # Absent this run (loop-2 territory) — counted directly, mirroring the
      # original inline jq's `$f == null` branch exactly. Does NOT call
      # prt_decide_finding; see the rationale block above.
      local resolved
      resolved="$(jq -r '.resolved' <<< "$row")"
      [ "$resolved" != true ] && gating=true
    else
      local o_collision f_collision eff_collision verdict resolved rbb action
      o_collision="$(jq -r '.collision' <<< "$row")"
      f_collision="$(jq -r '.collision // false' <<< "$match")"
      eff_collision=false
      { [ "$o_collision" = true ] || [ "$f_collision" = true ]; } && eff_collision=true
      # verdict defaults to NONE when the matched finding's own .verdict is
      # absent/null — mirrors pr-review-threads.sh's assessment join, where
      # an unmatched-by-assessment finding stays verdict null.
      verdict="$(jq -r '.verdict // "NONE"' <<< "$match")"
      resolved="$(jq -r '.resolved' <<< "$row")"
      rbb="$(jq -r '.resolved_by_bot' <<< "$row")"
      # within_cap=false: never read on this path (thread_exists=true, rows
      # 1/5/6/7 all ignore it) — see prt_decide_finding's own comment.
      action="$(prt_decide_finding "$eff_collision" "$verdict" true "$resolved" "$rbb" false)"
      [ "$(prt_thread_stays_gating "$action" "$resolved")" = true ] && gating=true
    fi

    [ "$gating" = true ] && count=$((count + 1))
  done < <(jq -c '.[]' <<< "$owned")

  echo "$count"
}

# prt_gating_eligible FINDINGS_JSON OWNED_JSON SEV_RANK_JSON -> sorted JSON array
# Only genuinely new findings (no OWNED match at all) ever need a rank slot.
prt_gating_eligible() {
  local findings="$1" owned="$2" sev_rank="$3"
  # Lowercase keys: the rank lookup below normalizes .severity through
  # ascii_downcase first, so a model returning off-canonical casing
  # ("critical", "HIGH") still ranks correctly instead of falling to // 99
  # and sorting below a correctly-cased Medium (dot-github#50 gmr finding N-h).
  jq -c --argjson rank "$sev_rank" --argjson owned "$owned" '
    [ .[] | select((.verdict == "VALID" or .verdict == "PARTIALLY_VALID" or .verdict == null)
                   and (.collision != true))
      | . as $f
      | select(($owned | map(select(.fp == $f.fp)) | length) == 0)
    ]
    | sort_by($rank[.severity | ascii_downcase] // 99)
  ' <<< "$findings"
}

# prt_apply_cap CAP OWNED_JSON FINDINGS_JSON [SEV_RANK_JSON] -> findings JSON
# with within_cap annotated on every row. SEV_RANK defaults here so the
# orchestrator does not have to pass it, but stays overridable for tests.
prt_apply_cap() {
  local cap="$1" owned="$2" findings="$3" sev_rank="${4:-}"
  [ -z "$sev_rank" ] && sev_rank='{"critical":0,"high":1,"medium":2}'

  local reserved remaining eligible capped_fps
  reserved="$(prt_reserved_count "$owned" "$findings")"
  remaining="$(jq -n --argjson n "$cap" --argjson r "$reserved" '[($n - $r), 0] | max')"
  eligible="$(prt_gating_eligible "$findings" "$owned" "$sev_rank")"
  capped_fps="$(jq -c --argjson n "$remaining" '[limit($n; .[])] | map(.fp)' <<< "$eligible")"

  jq -c --argjson capped "$capped_fps" '
    # IN(), not [x] | inside(y) — jq inside() on strings is substring
    # containment, not array-element equality: `["fp"] | inside(["fp-2"])` is
    # true. A base fingerprint would then read as "within cap" whenever an
    # unrelated ordinal-suffixed sibling fp happened to be capped.
    map(. + {within_cap: (.fp | IN($capped[]))})
  ' <<< "$findings"
}
