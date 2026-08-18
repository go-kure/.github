#!/usr/bin/env bash
# state.sh — REVIEW_INCOMPLETE persistence for pr-review-threads.sh.
#
# A shell variable set inside a `$(...)` subshell (e.g. the output of a curl
# helper) never reaches the parent shell. Every write path in this action runs
# inside such subshells, so REVIEW_INCOMPLETE is tracked as a file instead —
# the only thing that reliably crosses subshell boundaries in bash.
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
