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

prt_state_init() {
  local dir="$1"
  PRT_INCOMPLETE_FILE="$dir/review_incomplete"
  : > "$PRT_INCOMPLETE_FILE"
}

# prt_mark_incomplete REASON — idempotent; safe to call from any subshell.
prt_mark_incomplete() {
  local reason="$1"
  [ -n "${PRT_INCOMPLETE_FILE:-}" ] || { echo "ERROR: prt_state_init not called" >&2; return 1; }
  printf '%s\n' "$reason" >> "$PRT_INCOMPLETE_FILE"
}

# prt_state_reset — used only by reconciliation row 12 (absent thread +
# REVIEW_INCOMPLETE forces a clean restart on a LATER run). This run's own
# REVIEW_INCOMPLETE outcome is never reset mid-run — only the persisted
# marker state that gates row 12 is affected by that row's action.
prt_state_reset() {
  [ -n "${PRT_INCOMPLETE_FILE:-}" ] || { echo "ERROR: prt_state_init not called" >&2; return 1; }
  : > "$PRT_INCOMPLETE_FILE"
}

prt_is_incomplete() {
  [ -n "${PRT_INCOMPLETE_FILE:-}" ] || return 1
  [ -s "$PRT_INCOMPLETE_FILE" ]
}

prt_incomplete_reasons() {
  [ -n "${PRT_INCOMPLETE_FILE:-}" ] || return 0
  cat "$PRT_INCOMPLETE_FILE" 2>/dev/null || true
}
