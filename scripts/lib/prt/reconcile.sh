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
#                     RESOLVED_BY_BOT WITHIN_CAP [HAS_HUMAN_REPLY]
# All boolean args are the literal strings "true" or "false".
# VERDICT is one of: FALSE_POSITIVE, VALID, PARTIALLY_VALID, NONE (no
# assessment verdict matched this finding — stays open unreplied, per the
# chunking/assessment-mapping design).
# HAS_HUMAN_REPLY defaults to "false" when omitted (matching prt_apply_cap's
# own SEV_RANK default a few lines down), so every existing call site keeps
# its current behavior unless it supplies the real value — only row 3 below
# reads it.
#
# Prints one action word:
#   NONE       — do nothing
#   QUARANTINE — fp_base collides with another finding this run; withheld
#                because the fingerprint is ambiguous — never created, and
#                never silently dropped: rendered into the withheld section
#                of the overflow/advisory comment instead (go-kure/.github#155)
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
        resolved_by_bot="$5" within_cap="$6" has_human_reply="${7:-false}"

  # Row 1: collision beats every other row, matched or absent — withheld
  # (QUARANTINE) rather than reconciled normally, whether or not a thread
  # already exists for it (go-kure/.github#155: this used to be NONE, which
  # for a finding with no thread yet was indistinguishable from every other
  # do-nothing row and left the finding's body nowhere).
  #
  # Exception: an unthreaded finding the second pass already rejected as a
  # false positive still follows row 2 (SUPPRESS), not QUARANTINE — a
  # non-collided unthreaded false positive is never published, and a
  # collision doesn't make a rejected finding worth publishing either
  # (go-kure/.github#180 codex review). An *existing* ambiguous thread stays
  # conservative and is quarantined regardless of verdict.
  if [ "$collision" = true ]; then
    [ "$thread_exists" != true ] && [ "$verdict" = FALSE_POSITIVE ] && { echo SUPPRESS; return 0; }
    echo QUARANTINE
    return 0
  fi

  if [ "$verdict" = FALSE_POSITIVE ]; then
    # Row 2: never created in the first place.
    [ "$thread_exists" != true ] && { echo SUPPRESS; return 0; }
    # Row 3: open thread exists for a now-false-positive finding — but a
    # human reply protects it from this automated resolve, mirroring
    # prt_decide_absent's row 13 (go-kure/.github#177: this branch used to
    # ignore has_human_reply entirely, so a thread a human was actively
    # defending got resolved out from under them the next time an assessment
    # called the finding a false positive). No reply is posted in that case
    # either — posting "false positive, closing" into a thread a human just
    # engaged with is still the automated action the guard exists to
    # prevent, just split into two writes instead of one.
    if [ "$thread_resolved" != true ]; then
      [ "$has_human_reply" = true ] && { echo NONE; return 0; }
      echo REPLY_RESOLVE
      return 0
    fi
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

# prt_effective_collision OWNED_COLLISION THIS_RUN_COLLISION OWNED_CFP THIS_CFP
#                         OWNED_RESOLVED EVIDENCE_COMPLETE
# For a finding matched to an OWNED thread, prints which collision source
# applies, first match wins:
#   this_run         — this run's own multiplicity (finding.sh group length>1)
#   content_mismatch — the thread's stored content_fp differs from this
#                      finding's (go-kure/.github#196)
#   lift             — the thread carries a persisted collision flag, is
#                      open, this run's evidence is complete, and this run's
#                      single finding has exactly the text the thread was
#                      created for (go-kure/.github#148)
#   persisted        — the thread carries a persisted collision flag that is
#                      not lifted: no stored content_fp, a resolved thread,
#                      or incomplete evidence
#   none             — no collision
# Only open threads lift: the lift exists so loop 2 can auto-resolve the
# thread, which a resolved thread does not need, and two findings with
# identical text at different lines share fp_base and content_fp — lifting
# a human-resolved thread would hand the survivor to row 6, which shows it
# nowhere, where quarantine keeps it as a visible withheld row.
# EVIDENCE_COMPLETE is false on a run with a dropped row or an unparsed
# chunk, which can hide the other colliding finding (PRT_LIFT_EVIDENCE_COMPLETE
# in pr-review-threads.sh).
# this_run, content_mismatch and persisted mean prt_decide_finding gets
# collision=true; lift and none mean false. Only "true" counts as set for
# either collision flag. An empty OWNED_CFP (a thread that predates
# content_fp) never mismatches and never lifts.
#
# lift is safe because a thread is only ever created by CREATE, which row 1
# makes unreachable for a colliding finding: every owned thread was opened
# for one non-colliding finding, and its content_fp is that finding's text.
# A later singleton with the same fp and identical text is that same
# finding, so the ambiguity the persisted flag guards against is gone. The
# caller persists collision=false onto the thread's marker; until that write
# succeeds the thread stays quarantined.
#
# Shared by loop 1 (pr-review-threads.sh) and the upfront cap walk
# (prt_reserved_count below), so the cap walk predicts the outcome loop 1
# reaches instead of re-deriving it.
prt_effective_collision() {
  local owned_collision="$1" this_run_collision="$2" owned_cfp="$3" this_cfp="$4" \
        owned_resolved="$5" evidence_complete="$6"
  [ "$this_run_collision" = true ] && { echo this_run; return 0; }
  if [ -n "$owned_cfp" ] && [ "$owned_cfp" != "$this_cfp" ]; then
    echo content_mismatch; return 0
  fi
  if [ "$owned_collision" = true ]; then
    if [ -n "$owned_cfp" ] && [ "$owned_resolved" != true ] && [ "$evidence_complete" = true ]; then
      echo lift; return 0
    fi
    echo persisted; return 0
  fi
  echo none
}

# prt_foreign_action FOREIGN_JSON FINDING_JSON -> "ACTION<TAB>AUTHOR"
# go-kure/.github#153: the one decision for a finding that has no own thread
# but whose fp appears on foreign rows (marker, opened by another login).
# Loop 1 and the cap walk (prt_cap_foreign_rows) both call this, so they
# always act on the same selected row.
#
# A foreign marker is untrusted input: whatever is read from it may only
# make this run gate more (keep a thread gating, open a new one), never less
# (quarantine, withhold, leave alone). So:
# - the marker's collision flag is never read. A collision for a
#   foreign-matched finding comes only from this run's own findings (the
#   finding's own .collision, finding.sh's in-run fingerprint groups);
# - the marker's content_fp is read only to say "this thread is not this
#   finding": a row whose content_fp is present and differs from the
#   finding's is not a match, so the finding takes the no-thread path;
# - a resolved foreign row never suppresses a finding, whoever resolved it.
#   Its author can edit the marker onto any old resolved comment of theirs
#   (adding a target fp, dropping content_fp), so a foreign resolution is
#   not trusted the way a human resolution of an own thread is (row 6);
# - among the rows that do match, precedence is fixed:
#   1. any OPEN row: the existing thread, read-only and gating     EXISTING
#   2. else (every match resolved, by its opener or anyone else): what an
#      own bot-resolved thread would get. Row 7's reopen becomes a new
#      own thread instead                                           NEW |
#      (row 1 on a this-run collision, the resolved FALSE_POSITIVE  QUARANTINE |
#      branch otherwise: this run's own verdict, not the marker)    NONE
#   No matching row at all                                         NOMATCH
# NEW and NOMATCH mean the finding takes the normal no-thread path
# (CREATE within the cap, OVERFLOW beyond it). AUTHOR is the login of the
# row that decided (for NOMATCH, of a content-mismatched row with the same
# fp, or empty when no foreign row has the fp at all). Returns 1 when any
# read fails, never a guessed action.
prt_foreign_action() {
  local foreign="$1" finding="$2" fp has verdict collision issue fix this_cfp sel cls author action
  fp="$(jq -r '.fp' <<< "$finding" 2>/dev/null)" || return 1
  has="$(jq --arg fp "$fp" 'any(.[]; .fp == $fp)' <<< "$foreign" 2>/dev/null)" || return 1
  case "$has" in
    true) ;;
    false) printf 'NOMATCH\t\n'; return 0 ;;
    *) return 1 ;;
  esac
  verdict="$(jq -r '.verdict // "NONE"' <<< "$finding" 2>/dev/null)" || return 1
  collision="$(jq -r '.collision // false' <<< "$finding" 2>/dev/null)" || return 1
  # A failed read here would hash the wrong text: the content_fp check below
  # would then call a matching row "not this finding" and release it.
  issue="$(jq -r '.issue' <<< "$finding" 2>/dev/null)" || return 1
  fix="$(jq -r '.fix' <<< "$finding" 2>/dev/null)" || return 1
  this_cfp="$(prt_content_fp "$issue" "$fix")" || return 1
  [[ "$this_cfp" =~ ^[0-9a-f]{16}$ ]] || return 1
  sel="$(jq -r --arg fp "$fp" --arg cfp "$this_cfp" '
    [.[] | select(.fp == $fp)] as $all
    | [$all[] | select((.content_fp // "") == "" or .content_fp == $cfp)] as $m
    | if ($m | length) == 0 then "nomatch\t\($all[0].author)"
      elif any($m[]; .resolved != true) then
        "open\t\([$m[] | select(.resolved != true)][0].author)"
      else "resolved\t\($m[0].author)" end
  ' <<< "$foreign" 2>/dev/null)" || return 1
  cls="${sel%%$'\t'*}"
  author="${sel#*$'\t'}"
  case "$cls" in
    nomatch) action=NOMATCH ;;
    open) action=EXISTING ;;
    resolved)
      action="$(prt_decide_finding "$collision" "$verdict" true true true false false)"
      [ "$action" = REPLY_UNRESOLVE ] && action=NEW
      ;;
    *) return 1 ;;
  esac
  printf '%s\t%s\n' "$action" "$author"
}

# prt_cap_foreign_rows FOREIGN_JSON FINDINGS_JSON -> JSON array
# The foreign rows the cap walk sees: all of them, so every open one still
# reserves its slot in prt_reserved_count (it blocks merge, matched or not).
# For each finding whose prt_foreign_action is NEW or NOMATCH (a resolved
# match included, whoever resolved it), the rows carrying its fp are tagged
# excludes:false, so prt_gating_eligible keeps that finding as a CREATE
# candidate competing for a rank slot, exactly as loop 1 will treat it. Rows
# for EXISTING, NONE and QUARANTINE findings keep excluding their finding
# (no thread is created for it). Returns 1 when any read fails: a skipped
# finding would stay excluded, and loop 1 could then send it to a
# non-gating OVERFLOW with slots free.
prt_cap_foreign_rows() {
  local foreign="$1" findings="$2" release='[]' f fp has action rows
  if [ "$(jq 'length' <<< "$foreign" 2>/dev/null)" = 0 ]; then
    echo "$foreign"
    return 0
  fi
  rows="$(jq -c '.[]' <<< "$findings" 2>/dev/null)" || return 1
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    fp="$(jq -r '.fp' <<< "$f" 2>/dev/null)" || return 1
    has="$(jq --arg fp "$fp" 'any(.[]; .fp == $fp)' <<< "$foreign" 2>/dev/null)" || return 1
    case "$has" in
      true) ;;
      false) continue ;;
      *) return 1 ;;
    esac
    action="$(prt_foreign_action "$foreign" "$f")" || return 1
    case "${action%%$'\t'*}" in
      NEW|NOMATCH) release="$(jq -c --arg fp "$fp" '. + [$fp]' <<< "$release" 2>/dev/null)" || return 1 ;;
    esac
  done <<< "$rows"
  jq -c --argjson rel "$release" \
    'map(. as $r | if any($rel[]; . == $r.fp) then . + {excludes: false} else . end)' \
    <<< "$foreign" 2>/dev/null
}

# prt_decide_absent COLLISION HAS_HUMAN_REPLY THREAD_RESOLVED \
#                    FIRST_ABSENT_SHA CURRENT_SHA REVIEW_INCOMPLETE \
#                    STAMP_KNOWN_STALE
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
#   NONE             — do nothing (rows 6-analog/9/13, or thread already
#                       resolved so absence is moot)
#   CLEAR_MARKER      — row 12: clear first_absent_sha, forcing a clean
#                       restart on a later run
#   SET_FIRST_ABSENT  — rows 8 and 11: stamp first_absent_sha=<current head sha>
#   REPLY_RESOLVE      — row 10: post the auto-close reply, then
#                       resolveReviewThread
prt_decide_absent() {
  local collision="$1" has_human_reply="$2" thread_resolved="$3" \
        first_absent_sha="$4" current_sha="$5" review_incomplete="$6" \
        stamp_known_stale="$7"

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

  # Row 11: a marker clear failed after 3 retries and its MAINT_FAILURE reply
  # recorded the stamp the thread still carries (go-kure/.github#261) — that
  # stamp is stale, so it is not the first of two absences. This absence is:
  # re-stamp at the current head, exactly as row 8 does. The reply's stamp no
  # longer matches afterwards, so the next absence on another head resolves
  # through row 10. A re-stamp that fails leaves the stale stamp, and the
  # next run retries it here. A human reply already stopped this at row 13.
  [ "$stamp_known_stale" = true ] && { echo SET_FIRST_ABSENT; return 0; }

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
#   lifted collision (go-kure/.github#148)              -> the rows below, and
#     also gating whenever open, in case loop 1's persist of the lift fails
#   verdict FALSE_POSITIVE                              -> row 2/3: never gating,
#     unless a human has replied (go-kure/.github#177): then row 3 returns
#     NONE and the thread stays open, gating
#   currently open (non-collision, non-FALSE_POSITIVE)  -> row 5: gating
#   currently resolved, resolved_by_bot                 -> row 7: gating (reopens)
#   currently resolved, not by bot                       -> row 6: never gating
#   foreign row (go-kure/.github#153: marker, but opened by another login;
#     the orchestrator passes these after OWNED, tagged foreign:true)
#                                                       -> gating iff open,
#     matched or absent: no row of the decision table ever acts on it. Rows
#     whose finding loop 1 sends down the no-thread path (prt_foreign_action
#     NEW or NOMATCH) are tagged excludes:false by prt_cap_foreign_rows, so
#     that finding is a rank candidate below while an open row still reserves
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
    # QUARANTINE (go-kure/.github#155): row 1 fires before thread_exists is
    # even read, so an OWNED thread that predates the collision and is still
    # open must keep reserving its slot exactly as it did when this was
    # NONE — the mechanism doesn't touch the thread, it only stops future
    # resolve/reopen, so an unresolved thread here still blocks merge for
    # real. Same predicate as the NONE row above, spelled out separately so
    # it survives the next split of NONE's meanings.
    QUARANTINE) [ "$thread_resolved" != true ] && echo true || echo false ;;
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
  local count=0 row rows

  jq -e 'type == "array"' <<< "$owned" >/dev/null 2>&1 || return 1
  jq -e 'type == "array"' <<< "$findings" >/dev/null 2>&1 || return 1
  rows="$(jq -c '.[]' <<< "$owned" 2>/dev/null)" || return 1

  while IFS= read -r row; do
    [ -z "$row" ] && continue
    local fp match foreign gating=false
    fp="$(jq -er '.fp | select(type == "string")' <<< "$row" 2>/dev/null)" || return 1
    match="$(jq -c --arg fp "$fp" '[.[] | select(.fp == $fp)] | .[0] // null' <<< "$findings" 2>/dev/null)" || return 1
    foreign="$(jq -r '.foreign // false' <<< "$row" 2>/dev/null)" || return 1

    if [ "$foreign" = true ]; then
      # go-kure/.github#153: a thread another login opened. This run never
      # resolves or reopens it, matched or absent, so it gates exactly while
      # it is open. Anything but a literal true counts as open.
      local f_resolved
      f_resolved="$(jq -r '.resolved' <<< "$row" 2>/dev/null)" || return 1
      [ "$f_resolved" != true ] && gating=true
    elif [ "$match" = null ]; then
      # Absent this run (loop-2 territory) — counted directly, mirroring the
      # original inline jq's `$f == null` branch exactly. Does NOT call
      # prt_decide_finding; see the rationale block above.
      local resolved
      resolved="$(jq -r '.resolved' <<< "$row" 2>/dev/null)" || return 1
      [ "$resolved" != true ] && gating=true
    else
      local o_collision f_collision eff_collision verdict resolved rbb hhr action
      o_collision="$(jq -r '.collision' <<< "$row" 2>/dev/null)" || return 1
      f_collision="$(jq -r '.collision // false' <<< "$match" 2>/dev/null)" || return 1
      # Same predicate loop 1 uses (prt_effective_collision above), so this
      # walk cannot drift from it. go-kure/.github#200: a content_fp mismatch
      # routes to QUARANTINE, which keeps the OWNED thread gating exactly like
      # a same-run collision; predicting otherwise under-reserves by one and
      # lets a later CREATE exceed PRT_MAX_FINDINGS_TOTAL. go-kure/.github#148:
      # a lift is predicted as no collision, plus the persist-failure guard
      # after prt_decide_finding below. "" (a thread that predates
      # go-kure/.github#196, never a literal "null" — content_fp is built via
      # jq --arg) never mismatches and never lifts.
      local owned_content_fp match_content_fp="" source
      owned_content_fp="$(jq -r '.content_fp' <<< "$row" 2>/dev/null)" || return 1
      [ "$owned_content_fp" = null ] && owned_content_fp=""
      if [ -n "$owned_content_fp" ]; then
        local match_issue match_fix
        match_issue="$(jq -r '.issue' <<< "$match" 2>/dev/null)" || return 1
        match_fix="$(jq -r '.fix' <<< "$match" 2>/dev/null)" || return 1
        match_content_fp="$(prt_content_fp "$match_issue" "$match_fix")"
      fi
      local o_resolved
      o_resolved="$(jq -r '.resolved' <<< "$row" 2>/dev/null)" || return 1
      source="$(prt_effective_collision "$o_collision" "$f_collision" "$owned_content_fp" "$match_content_fp" "$o_resolved" "${PRT_LIFT_EVIDENCE_COMPLETE:-false}")"
      case "$source" in
        lift|none) eff_collision=false ;;
        *) eff_collision=true ;;
      esac
      # verdict defaults to NONE when the matched finding's own .verdict is
      # absent/null — mirrors pr-review-threads.sh's assessment join, where
      # an unmatched-by-assessment finding stays verdict null.
      verdict="$(jq -r '.verdict // "NONE"' <<< "$match" 2>/dev/null)" || return 1
      resolved="$(jq -r '.resolved' <<< "$row" 2>/dev/null)" || return 1
      rbb="$(jq -r '.resolved_by_bot' <<< "$row" 2>/dev/null)" || return 1
      # go-kure/.github#177: a FALSE_POSITIVE thread with a human reply now
      # stays open (row 3's guard, above) instead of resolving — this walk
      # must read the row's real has_human_reply, or a reserved slot for
      # exactly that thread goes uncounted and a later CREATE can exceed the
      # cap by one.
      hhr="$(jq -r '.has_human_reply' <<< "$row" 2>/dev/null)" || return 1
      # within_cap=false: never read on this path (thread_exists=true, rows
      # 1/5/6/7 all ignore it) — see prt_decide_finding's own comment.
      action="$(prt_decide_finding "$eff_collision" "$verdict" true "$resolved" "$rbb" false "$hhr")"
      [ "$(prt_thread_stays_gating "$action" "$resolved")" = true ] && gating=true
      # A lift only takes effect once loop 1 persists it; if that write
      # fails, loop 1 quarantines instead, and a quarantined thread gates
      # iff open. Reserve when either outcome gates — over-reserving by one
      # for this run is the safe direction (an open FALSE_POSITIVE thread
      # would otherwise be predicted to resolve while a failed persist keeps
      # it gating, letting a later CREATE exceed the cap).
      if [ "$source" = lift ] && [ "$resolved" != true ]; then
        gating=true
      fi
    fi

    [ "$gating" = true ] && count=$((count + 1))
  done <<< "$rows"

  echo "$count"
}

# prt_gating_eligible FINDINGS_JSON OWNED_JSON SEV_RANK_JSON -> sorted JSON array
# Only genuinely new findings (no OWNED match at all) ever need a rank slot.
# A foreign row in OWNED_JSON (go-kure/.github#153) excludes its finding the
# same way: loop 1 opens no thread for it. The exception is a row tagged
# excludes:false (prt_cap_foreign_rows): its finding does take the no-thread
# path, so it stays a candidate. Owned rows never carry the tag.
prt_gating_eligible() {
  local findings="$1" owned="$2" sev_rank="$3"
  # Lowercase keys: the rank lookup below normalizes .severity through
  # ascii_downcase first, so a model returning off-canonical casing
  # ("critical", "HIGH") still ranks correctly instead of falling to // 99
  # and sorting below a correctly-cased Medium (dot-github#50 gmr finding N-h).
  printf '%s\n%s\n' "$findings" "$owned" |
    jq -ces --argjson rank "$sev_rank" '
      if length == 2 and all(.[]; type == "array") then
        .[0] as $findings
        | .[1] as $owned
        | [ $findings[]
            | select((.verdict == "VALID" or .verdict == "PARTIALLY_VALID" or .verdict == null)
                     and (.collision != true))
            | . as $f
            | select(($owned | map(select(.fp == $f.fp and .excludes != false)) | length) == 0)
          ]
        | sort_by($rank[.severity | ascii_downcase] // 99)
      else
        error("findings and owned must be arrays")
      end
    ' 2>/dev/null
}

# prt_apply_cap CAP OWNED_JSON FINDINGS_JSON [SEV_RANK_JSON] -> findings JSON
# with within_cap annotated on every row. SEV_RANK defaults here so the
# orchestrator does not have to pass it, but stays overridable for tests.
prt_apply_cap() {
  local cap="$1" owned="$2" findings="$3" sev_rank="${4:-}"
  [ -z "$sev_rank" ] && sev_rank='{"critical":0,"high":1,"medium":2}'

  local reserved remaining eligible capped_fps
  reserved="$(prt_reserved_count "$owned" "$findings")" || return 1
  remaining="$(jq -n --argjson n "$cap" --argjson r "$reserved" '[($n - $r), 0] | max' 2>/dev/null)" || return 1
  eligible="$(prt_gating_eligible "$findings" "$owned" "$sev_rank")" || return 1
  capped_fps="$(jq -c --argjson n "$remaining" '[limit($n; .[])] | map(.fp)' <<< "$eligible" 2>/dev/null)" || return 1

  printf '%s\n%s\n' "$findings" "$capped_fps" |
    jq -ces '
      if length == 2 and all(.[]; type == "array") then
        .[0] as $findings
        | .[1] as $capped
        # IN(), not [x] | inside(y) — jq inside() on strings is substring
        # containment, not array-element equality: `["fp"] | inside(["fp-2"])` is
        # true. A base fingerprint would then read as "within cap" whenever an
        # unrelated ordinal-suffixed sibling fp happened to be capped.
        | $findings | map(. + {within_cap: (.fp | IN($capped[]))})
      else
        error("findings and capped fingerprints must be arrays")
      end
    ' 2>/dev/null
}
