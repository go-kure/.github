#!/usr/bin/env bash
# state.sh — REVIEW_INCOMPLETE / REVIEW_DEGRADED persistence for
# pr-review-threads.sh.
#
# A shell variable set inside a `$(...)` subshell (e.g. the output of a curl
# helper) never reaches the parent shell. Every write path in this action runs
# inside such subshells, so both severities are tracked as files instead —
# the only thing that reliably crosses subshell boundaries in bash.
#
# Two severities, both additive (go-kure/.github#98): REVIEW_INCOMPLETE keeps
# its pre-existing meaning and stays fatal by default (the exit gate at
# pr-review-threads.sh's tail fails closed on it) — only call sites explicitly
# moved to prt_mark_degraded below become non-fatal. REVIEW_DEGRADED means
# something in the run didn't fully succeed but the rest of the review still
# produced a usable result; the run still exits 0, with the reasons rendered
# into $GITHUB_STEP_SUMMARY as a warning rather than an error. Never
# dual-mark the same event with both — see pr-review-threads.sh's absence-loop
# reconciliation comment (around its `incomplete_now` check) for why that
# would defeat the point of moving an event to degraded.
#
# Source after setting PRT_STATE_DIR (a mktemp -d, one per run) and calling
# prt_state_init.

set -uo pipefail

# prt_log MSG — operator-facing progress on stderr. stdout is reserved for
# GitHub workflow commands (::error::), which must not be interleaved with
# free text.
prt_log() { printf 'prt: %s\n' "$*" >&2; }

# prt_annotation_escape TEXT — escapes a string for use inside a GitHub
# workflow command (`::error::...`). Order matters: '%' must be escaped
# FIRST, then CR, then LF — escaping '%' last would double-escape the '%25'
# produced by the CR/LF substitutions themselves.
prt_annotation_escape() {
  local s="$1"
  s="${s//%/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

prt_state_init() {
  local dir="$1"
  PRT_INCOMPLETE_FILE="$dir/review_incomplete"
  PRT_DEGRADED_FILE="$dir/review_degraded"
  if ! : > "$PRT_INCOMPLETE_FILE"; then
    # Fail loud here rather than leaving PRT_INCOMPLETE_FILE pointed at a file
    # that doesn't exist yet: prt_mark_incomplete's own append later would
    # likely also fail and catch this (its `>>` creates-on-append too), but
    # only IF something later actually calls it — a run with zero real
    # problems would otherwise report clean success with its own incomplete-
    # state bookkeeping silently never established (codex round 1 finding,
    # go-kure/.github#60/#61).
    echo "FATAL: prt_state_init: could not create $PRT_INCOMPLETE_FILE (disk full? permissions?) — REVIEW_INCOMPLETE tracking cannot start" >&2
    exit 1
  fi
  if ! : > "$PRT_DEGRADED_FILE"; then
    # Same fail-loud reasoning as PRT_INCOMPLETE_FILE above, mirrored for the
    # degraded-severity file (go-kure/.github#98).
    echo "FATAL: prt_state_init: could not create $PRT_DEGRADED_FILE (disk full? permissions?) — REVIEW_DEGRADED tracking cannot start" >&2
    exit 1
  fi
}

# prt_mark_incomplete REASON — idempotent; safe to call from any subshell.
# Fail-closed on the append itself: if the reason can't be recorded, the
# file-based prt_is_incomplete check later would stay blind to it (the
# incomplete-file would be empty even though something is actually wrong),
# so an append failure aborts the run immediately via `exit 1` rather than
# silently continuing as if nothing happened — the same "stderr says one
# thing, exit code says another" shape dot-github#61 exists to close, just
# relocated one level down into this function's own bookkeeping.
#
# `exit`, not `return`: almost every call site is a bare top-level statement
# or the RHS of a top-level `||`, where `exit 1` terminates the whole run
# immediately. The one documented exception is diff.sh's truncation-path
# call, which runs inside prt_split_diff — itself invoked inside a $(...)
# command substitution (pr-review-threads.sh) — where `exit 1` collapses
# only that subshell; the caller-side split_rc check and prt_split_diff's
# own write_failed/return 1 contract are what close that gap, not a
# `return` here.
prt_mark_incomplete() {
  local reason="$1"
  [ -n "${PRT_INCOMPLETE_FILE:-}" ] || { echo "ERROR: prt_state_init not called" >&2; return 1; }
  if printf '%s\n' "$reason" >> "$PRT_INCOMPLETE_FILE"; then
    printf 'REVIEW_INCOMPLETE: %s\n' "$reason" >&2
  else
    echo "FATAL: failed to record REVIEW_INCOMPLETE reason (state tracking itself is broken): $reason" >&2
    exit 1
  fi
}

prt_is_incomplete() {
  [ -n "${PRT_INCOMPLETE_FILE:-}" ] || return 1
  [ -s "$PRT_INCOMPLETE_FILE" ]
}

prt_incomplete_reasons() {
  [ -n "${PRT_INCOMPLETE_FILE:-}" ] || return 0
  cat "$PRT_INCOMPLETE_FILE" 2>/dev/null || true
}

# prt_mark_degraded REASON — mirrors prt_mark_incomplete exactly (same
# idempotent-append, same fail-closed-on-append-failure contract) but for the
# non-fatal severity (go-kure/.github#98): the exit gate at the tail of
# pr-review-threads.sh checks prt_is_incomplete only, so a degraded-only run
# still exits 0. prt_mark_incomplete keeps its own current meaning and stays
# fatal by default — only call sites explicitly moved to this function
# become non-fatal; everything else in this file is unchanged.
prt_mark_degraded() {
  local reason="$1"
  [ -n "${PRT_DEGRADED_FILE:-}" ] || { echo "ERROR: prt_state_init not called" >&2; return 1; }
  if printf '%s\n' "$reason" >> "$PRT_DEGRADED_FILE"; then
    printf 'REVIEW_DEGRADED: %s\n' "$reason" >&2
  else
    echo "FATAL: failed to record REVIEW_DEGRADED reason (state tracking itself is broken): $reason" >&2
    exit 1
  fi
}

prt_is_degraded() {
  [ -n "${PRT_DEGRADED_FILE:-}" ] || return 1
  [ -s "$PRT_DEGRADED_FILE" ]
}

prt_degraded_reasons() {
  [ -n "${PRT_DEGRADED_FILE:-}" ] || return 0
  cat "$PRT_DEGRADED_FILE" 2>/dev/null || true
}
