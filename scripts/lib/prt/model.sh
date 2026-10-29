#!/usr/bin/env bash
# model.sh — the two LLM calls (review, assessment), one per diff chunk,
# against the claude-max-proxy sidecar. Same backend and prompt style as the
# workflow this replaces (pr-review.yml), but JSON output instead of a
# markdown table: the review/assessment must be machine-parseable and
# fp-joinable, not just human-readable, once the diff is chunked.
#
# PRT_CURL indirection (gh.sh) is reused here too, for consistency — tests
# stub it the same way. Most of model.sh is still outside the pure-function
# unit suite, but _prt_call_proxy is not: its argv/E2BIG regression test stubs
# PRT_CURL with a real executable on disk, because a shell-function stub is
# never execve'd and so cannot reproduce the fault it guards.
: "${PRT_CURL:=curl}"

# PRT_LAST_MODEL_FAILURE — short, closed-vocabulary reason code for the LAST
# failure _prt_call_proxy produced (curl-exit-N, http-NNN, empty-content,
# deadline-exhausted, payload-build, local-tempdir), _prt_call_file produced
# (backend-config, local-tempdir, payload-build, findings-file-missing,
# findings-file-malformed, provenance-mismatch; PRT_REVIEW_BACKEND=file) or
# _prt_call_runner produced (backend-config, local-tempdir, deadline-exhausted,
# runner-incomplete, runner-quota, runner-launch, runner-usage, runner-failed,
# runner-no-output, runner-empty, provenance-mismatch; PRT_ASSESS_BACKEND=runner). Read by callers in
# pr-review-threads.sh to annotate a bare "exit 1" with which of several
# unrelated causes actually fired — same cross-file pattern as
# PRT_LAST_RETRY_AFTER/PRT_LAST_RATELIMIT_REMAINING in gh.sh.
#
# Every real caller invokes prt_model_review/prt_model_assess (and so
# _prt_call_proxy) via command substitution — `raw="$(prt_model_review ...)"`
# — which forks a subshell to run the function. A plain variable assignment
# made inside that subshell never propagates back to the caller: the
# PRT_LAST_MODEL_FAILURE the orchestrator reads after the substitution
# returns is untouched by the call it's supposedly describing, so every
# annotated failure rendered "[unknown]" regardless of the real cause
# (go-kure/.github#128 round 1). The variable is kept for any direct,
# non-subshell caller — none of the current tests in
# scripts/test/pr-review-threads-test.sh are one; both existing
# _prt_call_proxy call sites there are themselves command-substitution-
# wrapped — but the value that actually survives a command substitution is
# the file at PRT_LAST_MODEL_FAILURE_FILE,
# if the caller set one — a real filesystem write is unaffected by subshell
# scoping. _prt_set_model_failure keeps both in sync from one call site.
# shellcheck disable=SC2034 # read by callers in pr-review-threads.sh, not within this file
PRT_LAST_MODEL_FAILURE=""

_prt_set_model_failure() {
  # shellcheck disable=SC2034 # read by callers in pr-review-threads.sh, not within this file
  PRT_LAST_MODEL_FAILURE="$1"
  [ -n "${PRT_LAST_MODEL_FAILURE_FILE:-}" ] && printf '%s' "$1" > "$PRT_LAST_MODEL_FAILURE_FILE"
  return 0
}

# PRT_LAST_MODEL_CALLS — the number of raw HTTP attempts the LAST
# _prt_call_proxy invocation actually issued (0, 1 or 2): 0 when it refused
# before curl ever ran (payload-build, local-tempdir, or deadline-exhausted on
# attempt 1), 2 only when attempt 1 hit the connect-class retry (curl exit 6
# or 7) and attempt 2 then ran. A caller counting "model calls" for cost
# purposes (judge.sh's judge_calls) must read this after every
# _prt_call_proxy invocation, not assume 1: that internal retry is invisible
# from the outside otherwise, and undercounts real API usage whenever it
# fires and succeeds (go-kure/.github#184 review finding). Same file-based
# survival as PRT_LAST_MODEL_FAILURE_FILE above, for the same reason: every
# real caller invokes this via command substitution, so a plain variable
# never reaches back out of that subshell.
# shellcheck disable=SC2034 # read by callers in judge.sh, not within this file
PRT_LAST_MODEL_CALLS=""

_prt_set_model_calls() {
  # shellcheck disable=SC2034 # read by callers in judge.sh, not within this file
  PRT_LAST_MODEL_CALLS="$1"
  [ -n "${PRT_LAST_MODEL_CALLS_FILE:-}" ] && printf '%s' "$1" > "$PRT_LAST_MODEL_CALLS_FILE"
  return 0
}

set -uo pipefail

prt_strip_thinking() {
  awk '
    /<thinking>.*<\/thinking>/ { gsub(/<thinking>.*<\/thinking>/, ""); if (length($0) > 0) print; next }
    /<thinking>/ { skip=1; next }
    /<\/thinking>/ { sub(/.*<\/thinking>/, ""); skip=0; if (length($0) > 0) print; next }
    skip==0 { print }
  ' | sed '/./,$!d' | prt_strip_fence
}

# prt_strip_fence — the system prompt forbids markdown code fences, but drop
# a leading/trailing ``` or ```json line if the model emits one anyway,
# rather than losing the whole chunk to a jq parse failure.
prt_strip_fence() {
  sed -e '1{/^```/d}' -e '${/^```$/d}'
}

# prt_extract_json_braces CONTENT — salvage pass for a parse failure
# (go-kure/.github#60/#61 round 2 fold-in, launcher#283 run 32175849548): a
# chattier generation on this backend can wrap the JSON object in prose
# ("Here you go:\n{...}\nHope that helps!"), which prt_strip_fence above
# doesn't handle — it only strips a fenced-code-block marker that is itself
# the first/last line, not prose before or after the JSON. Prints the
# substring from the first '{' to the last '}' in CONTENT and returns 0; if
# either brace is absent, prints nothing and returns 1. A no-op (round-trips
# to the same content) when CONTENT is already clean JSON. Plain
# parameter-expansion substring extraction — no new dependency, same idiom
# as the pattern-based trims above.
prt_extract_json_braces() {
  local content="$1" before after middle
  before="${content%%\{*}"
  [ "${#before}" -lt "${#content}" ] || return 1
  after="${content##*\}}"
  [ "${#after}" -lt "${#content}" ] || return 1
  middle="${content#"$before"}"
  middle="${middle%"$after"}"
  printf '%s' "$middle"
}

# PRT_RESPONSE_CLASSES — the closed enum prt_response_class clamps to, in the
# same spirit as PRT_CATEGORIES in finding.sh. Listed here so the complete set
# of strings the diagnostic can ever print is readable in one place.
PRT_RESPONSE_CLASSES="backend-limit backend-billing backend-overloaded backend-auth backend-model backend-context model-refusal unrecognized"

# prt_response_class CONTENT — classify an unparseable response against a
# FIXED, in-repo phrase list. Prints exactly one member of
# PRT_RESPONSE_CLASSES.
#
# THIS IS NOT A BACK DOOR FOR LOGGING THE RESPONSE, and the distinction is
# the whole reason it is written this way. Every string this function can
# emit is a literal in the case arms below — none of it comes from the
# response. A response matching nothing prints `unrecognized`, so an
# unanticipated message cannot leak a single byte through this path. That
# keeps docs/pr-review-threads.md's "Failure surface" invariant ("never
# logged: PRT_GH_TOKEN, raw model responses, comment bodies — only
# fingerprints, actions, and outcomes") intact.
#
# go-kure/.github#81 is why it exists: every PR in this repo went red with
# `len=57 leading=starts-with-prose`, which says a fixed prose string came
# back but not whether the cause was quota, auth, an overloaded backend or a
# genuine model refusal — four problems with four different owners and four
# different fixes. The issue's suggested first step was to log the raw body;
# that would settle it and also break the invariant above, so the class is
# the part of that answer which can be published in a job log.
#
# The backend is a claude-max-proxy sidecar running on the host's Claude Max
# credentials (.github/workflows/pr-review.yml:4-10), which has 5-hour and
# weekly usage limits and returns HTTP 200 with the limit notice as the
# message content — so it arrives here as "model output", not as the non-2xx
# branch below that already logs a bounded body. `backend-limit` is the
# first class for that reason.
#
# The literal observed live on 2026-09-04, when the whole org went red for
# ~30 minutes, is:
#
#     You've hit your session limit · resets 10:10am (UTC)
#
# 53 bytes, HTTP 200, byte-identical from both proxy replicas and across
# every repo and chunk until the window reset. It matched NONE of the
# phrases on the original list, so the one outage this function was written
# for was reported as `unrecognized` — and answering "which of the four
# problems is it?" then took VPN access, a `kubectl exec` into a proxy pod,
# a hand-made POST, and a sha256 to tie the reply back to the CI
# fingerprint. Hence two additions: the observed literal, and `limit ·
# resets` for the SHAPE of that notice family, so a variant naming a
# different window does not need a second incident to teach us its wording.
# The `·` is U+00B7 (bytes c2 b7); neither byte is in A-Z, so the `tr`
# below leaves it intact and the match holds. (That multi-byte character is
# also why the incident logged len=53 for a 52-CHARACTER string: the runner
# has no UTF-8 locale, so `${#content}` counts bytes.)
prt_response_class() {
  local lc c candidate
  lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in
    *"usage limit"*|*"rate limit"*|*"session limit"*|*"too many requests"*|*"quota"*|*"limit reached"*|*"limit · resets"*) candidate='backend-limit' ;;
    *"credit balance"*|*"billing"*|*"insufficient funds"*|*"payment"*)               candidate='backend-billing' ;;
    *"overloaded"*|*"capacity"*|*"temporarily unavailable"*|*"try again later"*)     candidate='backend-overloaded' ;;
    *"authentication"*|*"unauthorized"*|*"api key"*|*"forbidden"*|*"credentials"*)   candidate='backend-auth' ;;
    *"unknown model"*|*"invalid model"*|*"model not found"*)                         candidate='backend-model' ;;
    *"context length"*|*"maximum context"*|*"too many tokens"*)                      candidate='backend-context' ;;
    *"i can't"*|*"i cannot"*|*"i'm sorry"*|*"i am sorry"*|*"i'm unable"*)            candidate='model-refusal' ;;
    *)                                                                               candidate='unrecognized' ;;
  esac
  # Clamp to the closed enum, exactly as prt_normalize_category does
  # (finding.sh:38-45). Belt-and-braces against a future edit that adds a
  # case arm printing something not in PRT_RESPONSE_CLASSES: this function's
  # contract with the "never log the response" invariant is that its output
  # is drawn from a fixed set, so the set is enforced here rather than left
  # as a property of the case arms that a later edit could quietly break.
  for c in $PRT_RESPONSE_CLASSES; do
    if [ "$c" = "$candidate" ]; then printf '%s' "$c"; return 0; fi
  done
  printf 'unrecognized'
}

# prt_response_fingerprint CONTENT — 16 hex chars of the content's sha256,
# the same idiom and width as prt_fp_base (finding.sh:31-36).
#
# A hash is explicitly on the permitted side of the "Failure surface" list
# ("only fingerprints, actions, and outcomes") and it answers the one
# question length alone cannot: whether the backend is returning the SAME
# fixed string on every call. #81 had to infer that from `len=57` recurring
# across four runs — suggestive, but two different 57-byte responses are
# entirely possible, so the inference was never proof. Equal fingerprints
# across runs settle it; differing ones redirect the investigation to
# something diff-dependent.
prt_response_fingerprint() {
  printf '%s' "$1" | sha256sum | cut -c1-16
}

# prt_response_shape CONTENT — shape-only diagnostic for a response that
# stayed unparseable after retry and salvage: length, a leading-character
# class, the closed-enum class above, and a fingerprint — never the response
# text itself. Never logging raw model responses or comment bodies is a
# standing rule for this whole action (see docs/pr-review-threads.md
# "Failure surface"); a shape summary is not the content. Leading whitespace
# is trimmed before classifying.
prt_response_shape() {
  local content="$1" trimmed lead
  trimmed="${content#"${content%%[![:space:]]*}"}"
  case "$trimmed" in
    '{'*)   lead='starts-with-brace' ;;
    '```'*) lead='starts-with-fence' ;;
    *)      lead='starts-with-prose' ;;
  esac
  printf 'len=%d leading=%s class=%s sha16=%s' \
    "${#content}" "$lead" "$(prt_response_class "$content")" "$(prt_response_fingerprint "$content")"
}

_prt_review_system_prompt() {
  cat <<'PROMPT'
You review GitHub pull requests.

ANTI-HALLUCINATION RULES:
- Only flag issues you can point to with a specific file and line from the diff.
- Do NOT flag standards violations unless the standard text appears in one of the ADDITIONAL
  PROJECT CONTEXT / PROJECT DOCUMENTATION (AGENTS.md) / PROJECT NOTES / PROJECT STANDARDS sections
  below.
- Do NOT invent or assume coding standards — only cite rules explicitly provided.
  If none of those sections is present, do not flag any standards violations.
- If unsure whether something is a real issue, skip it. Precision matters more than recall.
- Never reference documentation, files, or code not present in this diff chunk or the context provided.
- This is one CHUNK of a larger diff. Only report on code actually shown in this chunk.

RULES:
- Report ONLY: bugs, security issues, incorrect error handling, logic errors, standards violations.
- Do NOT comment on: style preferences, naming opinions, missing tests, documentation,
  code organization, or performance unless it causes a bug.
- Do NOT suggest adding complexity (interfaces, abstractions, design patterns) unless
  the current code has a concrete defect.
- Do NOT duplicate what linters already enforce.
- Max 5 findings in this chunk, ranked by severity (Critical > High > Medium).

CATEGORY must be exactly one of: nil-deref, unchecked-err, race, sql-injection,
resource-leak, logic-error, standards-violation, other.

OUTPUT FORMAT: respond with ONLY a single JSON object, no markdown fences, no prose
before or after:
{"findings": [
  {"file": "path/from/diff", "line": 42, "category": "nil-deref",
   "severity": "Critical", "issue": "one-sentence description",
   "fix": "one-sentence suggested fix"}
]}
An empty diff chunk or a clean chunk: {"findings": []}
PROMPT
}

_prt_assess_system_prompt() {
  cat <<'PROMPT'
You fact-check AI-generated code review findings against the actual diff chunk
and the full project context provided below.

The findings were produced by an automated system that sometimes hallucinates —
it may reference code that does not exist in the diff, misunderstand language
idioms, or flag correct patterns as bugs.

Use the PROJECT CONTEXT (if provided) to understand the project's architecture,
design decisions, coding patterns, and interfaces.

For each finding (identified by its "fp" field — echo it back exactly, do not
invent or modify it):
1. Verify the referenced file, line, and code actually exist in this diff chunk.
2. Cross-reference claims against the project context.
3. Classify as: VALID, PARTIALLY_VALID, or FALSE_POSITIVE.

STANDARDS VERIFICATION: when a finding claims a "standards violation", check
whether the cited standard actually appears in the PROJECT STANDARDS section
below. If not, classify as FALSE_POSITIVE with reason "cited standard not
found in project standards".

OUTPUT FORMAT: respond with ONLY a single JSON object, no markdown fences, no
prose before or after:
{"assessments": [
  {"fp": "<the finding's fp field, verbatim>", "verdict": "VALID",
   "reasoning": "brief explanation"}
]}
PROMPT
}

# _prt_call_proxy PROXY_URL MODEL MAX_TOKENS SYSTEM USER — prints the raw
# model content string (expected JSON) on success, empty on failure.
_prt_call_proxy() {
  local proxy_url="$1" model="$2" max_tokens="$3" system="$4" user="$5"
  local http_code resp content

  # NOTHING large goes through argv here — not into jq, not into curl. Linux
  # caps a SINGLE argv entry at MAX_ARG_STRLEN = 32 pages = 131072 bytes,
  # independent of ARG_MAX and of any ulimit, so both `--arg user "$user"` and
  # `-d "$payload"` make execve fail with E2BIG once a chunk gets big enough.
  # A chunk can legitimately reach ~200 KB — diff.sh's hard ceiling is
  # PRT_HARD_CEILING_MULT (4) x PRT_MAX_DIFF_CHARS (50000), and only a single
  # hunk above THAT is truncated — and the system prompt adds the project's
  # AGENTS.md on top, so the soft 50000 limit was never the bound that
  # mattered here.
  #
  # The two sites fail at different thresholds, which is why the live incident
  # only showed one of them: the payload is strictly larger than the user
  # string it wraps, so curl (`-d "$payload"`) tripped first while jq's
  # `--arg user` still fit (go-kure/launcher run 32224453949, chunk 3 —
  # reported as `curl: Argument list too long`). A slightly larger chunk fails
  # in jq instead, one line earlier, with the same cause and a different name.
  # Both are fixed together; fixing only the reported one moves the fault
  # rather than removing it.
  local dir sysf userf req tmp
  _prt_set_model_failure ""
  _prt_set_model_calls 0
  dir="$(mktemp -d)"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo "prt_model: could not create a temp dir for the request" >&2
    _prt_set_model_failure "local-tempdir"
    return 1
  fi
  sysf="$dir/system"; userf="$dir/user"; req="$dir/request"; tmp="$dir/response"
  # Pre-create the response file: curl writes it via -o, but if curl never runs
  # at all (the E2BIG case this function exists to survive) the `cat "$tmp"`
  # below would otherwise fail noisily on a missing path. `mktemp` used to
  # create it as a side effect; naming it inside $dir does not.
  : > "$tmp"
  printf '%s' "$system" > "$sysf"
  printf '%s' "$user" > "$userf"

  # --rawfile reads a file verbatim as a JSON string, so the two unbounded
  # values never appear on jq's command line. printf '%s' writes them without
  # a trailing newline, so what jq reads is byte-identical to the arguments.
  jq -n \
    --arg model "$model" \
    --rawfile system "$sysf" \
    --rawfile user "$userf" \
    --argjson max_tokens "$max_tokens" \
    '{model: $model, max_tokens: $max_tokens,
      messages: [{role: "system", content: $system}, {role: "user", content: $user}]}' \
    > "$req" || {
      echo "prt_model: failed to build request payload" >&2
      _prt_set_model_failure "payload-build"
      rm -rf "$dir"
      return 1
    }

  # --max-time is derived from a RUN-LEVEL deadline, not a fixed value.
  # go-kure/.github#128, from opsmaster's claude-proxy investigation
  # (2026-08-30): a fixed 300s ceiling sat BELOW the workload's own p95
  # (measured 315s over 1066 live calls, 5.3% of calls ran long), so ~1 in 20
  # model calls was killed by curl mid-generation with no application fault
  # at all — indistinguishable in the job log from a real network/proxy
  # outage ("transport/proxy error, exit 1"), because that IS what it was,
  # just self-inflicted by too tight a client-side deadline.
  #
  # PRT_MODEL_DEADLINE_EPOCH is set once by pr-review-threads.sh at the start
  # of the run (its own comment there has the budget math against
  # timeout-minutes: 20). Recomputing budget_left on every call means a
  # multi-chunk PR's later calls get less headroom than its first — the
  # aggregate still can't blow the job budget — while a single-chunk PR (the
  # common case, and every failure seen 2026-08-30 was one) gets the full
  # ceiling below. A caller that never sets a run deadline (hypothetically,
  # a direct unit test of this function — none currently in this repo's
  # suite; see the note below) is meant to fall back to `now + 300` fresh on
  # EVERY call.
  #
  # That fallback must land in a call-local variable, not mutate the shared
  # PRT_MODEL_DEADLINE_EPOCH via `:=` (go-kure/.github#128 round 2, kure-bot):
  # unlike PRT_MODEL_TIMEOUT_FLOOR/CEILING/PRT_MODEL_CONNECT_RETRY_DELAY below
  # — fixed constants, so `:=` into the global is a harmless one-time default
  # — this one is a function of `now`, so mutating the global freezes the
  # FIRST call's `now + 300` there; every later call in the same shell that
  # never sets PRT_MODEL_DEADLINE_EPOCH (a hypothetical direct, non-subshell
  # caller, per the note above) would then reuse that stale value instead of
  # computing a fresh one, and a call made more than ~270s after the first
  # would spuriously hit the deadline-exhausted refusal below.
  local now budget_left max_time deadline
  now="$(date +%s)"
  deadline="${PRT_MODEL_DEADLINE_EPOCH:-$((now + 300))}"
  : "${PRT_MODEL_TIMEOUT_FLOOR:=30}"
  # 900s ceiling: the measured 8-day p99 was 557s and ZERO of 1066 calls
  # exceeded 900s — high enough to absorb the whole observed tail, not so
  # high a single call could still eat the entire job budget.
  : "${PRT_MODEL_TIMEOUT_CEILING:=900}"

  # Connect-class transport faults (curl exit 6 DNS, 7 connection refused)
  # get ONE short-backoff retry here, inside the call itself: this is the
  # "proxy pod momentarily out of the Service" mode the workflow's own
  # comment records (.github/workflows/pr-review.yml:4-10), and a retry a
  # few seconds later plausibly lands on a live replica. Exit 28 (curl's
  # generic --max-time/--connect-timeout timeout — usually the call
  # connected and ran past --max-time, but curl's own docs don't guarantee
  # that; it can also fire on a slow connect that never quite hit 6/7) is
  # deliberately excluded: retrying it re-spends budget on a call already
  # shown to be this slow, for the same result either way. The deadline
  # above is the correct control for that case, not a retry here.
  : "${PRT_MODEL_CONNECT_RETRY_DELAY:=3}"
  local curl_rc=0 attempt
  for attempt in 1 2; do
    # Recomputed on EVERY attempt, not once before the loop: attempt 1's own
    # runtime (up to --connect-timeout) plus PRT_MODEL_CONNECT_RETRY_DELAY's
    # sleep can together burn most or all of the remaining budget before
    # attempt 2 ever runs curl. Reusing attempt 1's stale max_time here would
    # let attempt 2 run with a ceiling computed against a deadline that has
    # already passed by the time it starts (go-kure/.github#128 round 1,
    # codex-lens finding — reproduced live: budget already exhausted by the
    # time attempt 2 started, yet the retry still ran with attempt 1's
    # leftover max_time instead of being refused).
    now="$(date +%s)"
    budget_left=$((deadline - now))
    if [ "$budget_left" -lt "$PRT_MODEL_TIMEOUT_FLOOR" ]; then
      # Refuse to START (or retry) a call that the run's own deadline says
      # can't finish, rather than issuing it with a near-zero/stale
      # --max-time and reporting whatever curl does with that as a
      # transport fault.
      echo "prt_model: run deadline exhausted before attempt $attempt (${budget_left}s left, floor ${PRT_MODEL_TIMEOUT_FLOOR}s) — refusing call" >&2
      _prt_set_model_failure "deadline-exhausted"
      # $attempt itself hasn't run curl yet on this iteration -- attempt-1 is
      # how many already have (0 on the first iteration, 1 if this fires on
      # the connect-retry's second attempt).
      _prt_set_model_calls $((attempt - 1))
      # Every other failure path in this function removes $dir before
      # returning (the payload-build failure above, and the post-loop
      # branches below); mirror that here rather than falling through to
      # the post-loop cleanup, since this return happens from inside the
      # loop, before curl ever runs for this attempt.
      rm -rf "$dir"
      return 1
    fi
    max_time=$budget_left
    [ "$max_time" -gt "$PRT_MODEL_TIMEOUT_CEILING" ] && max_time="$PRT_MODEL_TIMEOUT_CEILING"

    curl_rc=0
    http_code="$("$PRT_CURL" -s -o "$tmp" -w '%{http_code}' \
      --connect-timeout 10 --max-time "$max_time" \
      -X POST "${proxy_url}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d @"$req")" || curl_rc=$?
    case "$curl_rc" in
      6 | 7)
        if [ "$attempt" -eq 1 ]; then
          sleep "$PRT_MODEL_CONNECT_RETRY_DELAY"
          continue
        fi
        ;;
    esac
    break
  done
  # $attempt only reaches 2 by falling through the connect-retry `continue`
  # above, so at this point it already equals the number of curl invocations
  # this call actually made -- no separate counter to keep in sync.
  _prt_set_model_calls "$attempt"
  resp="$(cat "$tmp")"
  rm -rf "$dir"

  # Separated from the non-2xx branch on purpose: a curl that never produced a
  # status at all is a transport/exec fault, not a proxy response, and must not
  # be reported as one. The empty-http_code case previously fell through here.
  if [ "$curl_rc" -ne 0 ]; then
    echo "prt_model: curl failed (exit $curl_rc, http_code='$http_code')" >&2
    echo "$resp" | head -c 500 >&2
    _prt_set_model_failure "curl-exit-$curl_rc"
    return 1
  fi

  if [[ ! "$http_code" =~ ^2[0-9]{2}$ ]]; then
    echo "prt_model: proxy returned HTTP $http_code" >&2
    echo "$resp" | head -c 500 >&2
    _prt_set_model_failure "http-$http_code"
    return 1
  fi

  content="$(jq -r '.choices[0].message.content // empty' <<< "$resp" 2>/dev/null || true)"
  if [ -z "$content" ]; then
    echo "prt_model: empty response content" >&2
    _prt_set_model_failure "empty-content"
    return 1
  fi
  prt_strip_thinking <<< "$content"
}

# prt_chunk_scope INDEX COUNT ALL_FILES CHUNK_FILES — the scope block both
# prompts of a chunked review carry (go-kure/.github#173). A chunk's reviewer
# sees only its own slice, and "not in this chunk" reads the same as "not in
# the diff" from inside it; this names the chunk and every file of the whole
# diff, so a missing helper can be recognised as merely out of view. Empty
# when COUNT is 1 or less: a single chunk is the whole diff. INDEX is
# 0-based; the text numbers chunks from 1. ALL_FILES and CHUNK_FILES are
# newline-separated (prt_diff_files).
# The whole-diff list goes into every chunk's two prompts, so it is capped at
# a tenth of PRT_MAX_DIFF_CHARS; the files past the cap are counted, not
# named. The chunk's own list needs no cap: its paths are in the chunk.
prt_chunk_scope() {
  local idx="$1" count="$2" all="$3" mine="$4"
  [ "$count" -gt 1 ] 2>/dev/null || return 0
  printf 'CHUNK SCOPE: this diff is split into %s chunks; this is chunk %s of %s.\n' "$count" "$((idx + 1))" "$count"
  printf 'Files in the whole diff:\n'
  printf '%s\n' "$all" | awk -v max="$(( ${PRT_MAX_DIFF_CHARS:-50000} / 10 ))" '
    $0 == "" { next }
    !omitted && used + length($0) + 3 <= max { print "- " $0; used += length($0) + 3; next }
    { omitted++ }
    END { if (omitted) printf "- (%d more file(s), not listed)\n", omitted }'
  printf 'Files in this chunk:\n'
  printf '%s\n' "$mine" | sed '/^$/d; s/^/- /'
  printf '%s\n' "Code in the other chunks exists but is not shown here: not seeing something in this chunk says nothing about the rest of the diff."
}

# _prt_call_file CHUNK_IDX — the review call served from a findings file a
# separate review step already produced (PRT_REVIEW_BACKEND=file), instead of
# the proxy. Prints {"findings":[...]} holding only the findings assigned to
# chunk CHUNK_IDX, in the six fields prt_normalize_findings reads; no model is
# called. Reads, all from the environment:
#   PRT_FINDINGS_FILE            the findings file (review-findings-v1); its
#                                sibling provider.json (review-run-v1) is the
#                                provenance record
#   PRT_CHUNK_DIR                the chunk files the orchestrator split
#   PRT_HEAD_SHA, PRT_REVIEW_BASE_SHA, PRT_REVIEW_MATERIAL_SHA256
#                                what the record must say it reviewed
# Every refusal returns 1 with a closed-vocabulary reason in the failure file,
# like _prt_call_proxy's: backend-config (an input this mode needs is not
# set), local-tempdir (no scratch directory), payload-build (the selection
# could not be built), findings-file-missing, findings-file-malformed,
# provenance-mismatch.
# The record names the commits and the digest of the base..head diff the review
# read; it names no repository, so the repository cannot be checked here.
#
# A finding goes to exactly one chunk, first match in this order: the first
# chunk whose commentable new-file lines hold (file, line); else the first
# chunk whose diff touches the file; else chunk 0, so a finding is never
# dropped for naming a file this review does not show. A file-level finding
# (null line) takes the second rule.
_prt_call_file() {
  local idx="$1" findings_file="${PRT_FINDINGS_FILE:-}" chunk_dir="${PRT_CHUNK_DIR:-}" \
        provider chunk_file tmp n=0
  _prt_set_model_failure ""
  _prt_set_model_calls 0
  if [ -z "$findings_file" ] || [ -z "$chunk_dir" ] || ! [[ "$idx" =~ ^[0-9]+$ ]] \
     || [ -z "${PRT_HEAD_SHA:-}" ] || [ -z "${PRT_REVIEW_BASE_SHA:-}" ] \
     || [ -z "${PRT_REVIEW_MATERIAL_SHA256:-}" ]; then
    _prt_set_model_failure "backend-config"
    return 1
  fi
  if [ ! -f "$findings_file" ]; then
    _prt_set_model_failure "findings-file-missing"
    return 1
  fi
  # Every field the normalizer (prt_normalize_findings) needs is checked here, for every
  # chunk's call and before any chunk is served: a row it would drop must refuse the run, not
  # vanish while another chunk's empty answer reads as success.
  if ! jq -e '
        .format == "review-findings-v1" and (.findings | type) == "array"
        and all(.findings[]; type == "object" and (.file | type) == "string" and (.file | length) > 0
                             and (.file | utf8bytelength) <= 4096
                             and (.line == null or (.line | type) == "number")
                             and (.severity | type) == "string" and (.category | type) == "string"
                             and (.issue | type) == "string" and (.fix | type) == "string")
      ' "$findings_file" >/dev/null 2>&1; then
    _prt_set_model_failure "findings-file-malformed"
    return 1
  fi
  provider="$(dirname "$findings_file")/provider.json"
  if [ ! -f "$provider" ] || ! jq -e \
        --arg head "$PRT_HEAD_SHA" --arg base "$PRT_REVIEW_BASE_SHA" --arg mat "$PRT_REVIEW_MATERIAL_SHA256" '
        .format == "review-run-v1" and .outcome == "completed"
        and .identity.head == $head and .identity.base == $base and .identity.material_sha256 == $mat
      ' "$provider" >/dev/null 2>&1; then
    _prt_set_model_failure "provenance-mismatch"
    return 1
  fi
  # Nothing large goes through argv: a chunk's line index can pass 128 KiB (the
  # single-argument cap, see _prt_call_proxy), so each chunk's index and file
  # list are written to files, joined into one record per chunk, and read back
  # with --slurpfile.
  tmp="$(mktemp -d)"
  if [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
    _prt_set_model_failure "local-tempdir"
    return 1
  fi
  : > "$tmp/chunks.jsonl"
  for chunk_file in "$chunk_dir"/chunk-*.diff; do
    [ -f "$chunk_file" ] || continue
    if ! prt_build_line_index "$chunk_file" > "$tmp/index.json" \
       || ! prt_diff_files "$chunk_file" | jq -R -s -c 'split("\n") | map(select(length > 0))' > "$tmp/files.json" \
       || ! jq -c -n --argjson n "$n" --slurpfile index "$tmp/index.json" --slurpfile files "$tmp/files.json" \
            '{idx: $n, index: $index[0], files: $files[0]}' >> "$tmp/chunks.jsonl"; then
      rm -rf "$tmp"
      _prt_set_model_failure "backend-config"
      return 1
    fi
    n=$((n + 1))
  done
  jq -c --argjson want "$idx" --slurpfile chunks "$tmp/chunks.jsonl" '
    {findings: [.findings[] | . as $f
      | (([$chunks[] | select($f.line != null and ((.index[$f.file] // []) | any(. == $f.line))) | .idx] | .[0])
         // ([$chunks[] | select(.files | any(. == $f.file)) | .idx] | .[0])
         // 0) as $at
      | select($at == $want)
      | {file, line, severity, category, issue, fix}]}
  ' "$findings_file" || {
    rm -rf "$tmp"
    _prt_set_model_failure "payload-build"
    return 1
  }
  rm -rf "$tmp"
}

# prt_model_review PROXY_URL MODEL MAX_TOKENS CHUNK_DIFF PR_TITLE PR_DESC \
#                   PROJECT_CONTEXT PROJECT_AGENTS PROJECT_CLAUDE_MD PROJECT_STANDARDS \
#                   [CHUNK_SCOPE [CHUNK_IDX]]
# CHUNK_SCOPE (prt_chunk_scope, go-kure/.github#173) is empty for a
# single-chunk diff; otherwise it goes ahead of the diff with the rule that
# a claim depending on code outside the chunk is omitted, never reported.
# PRT_REVIEW_BACKEND selects the source of the answer: unset or empty, the
# proxy (default); "file", _prt_call_file, which needs CHUNK_IDX; any other
# value is refused (backend-config), never read as the default. The switch
# sits here, not in _prt_call_proxy, because only this level knows the chunk.
prt_model_review() {
  local proxy_url="$1" model="$2" max_tokens="$3" chunk_diff="$4" \
        pr_title="$5" pr_desc="$6" project_context="$7" project_agents="$8" \
        project_claude_md="$9" project_standards="${10}" chunk_scope="${11:-}" \
        chunk_idx="${12:-}"
  local system user scope_block=""
  case "${PRT_REVIEW_BACKEND:-}" in
    "") ;;
    file) _prt_call_file "$chunk_idx"; return $? ;;
    *) _prt_set_model_failure "backend-config"; return 1 ;;
  esac
  system="$(_prt_review_system_prompt)"
  [ -n "$project_context" ] && system="${system}"$'\n\nADDITIONAL PROJECT CONTEXT:\n'"${project_context}"
  [ -n "$project_agents" ] && system="${system}"$'\n\nPROJECT DOCUMENTATION (AGENTS.md):\n'"${project_agents}"
  [ -n "$project_claude_md" ] && system="${system}"$'\n\nPROJECT NOTES (.claude/CLAUDE.md):\n'"${project_claude_md}"
  [ -n "$project_standards" ] && system="${system}"$'\n\nPROJECT STANDARDS:\n'"${project_standards}"
  [ -n "$chunk_scope" ] && scope_block="${chunk_scope}
Do not report a finding whose claim depends on code that is not shown in this chunk (for example a
helper defined in another file of the diff): omit it. Report only what this chunk itself shows.

"
  user="Review this diff chunk.

Title: ${pr_title}
Description: ${pr_desc}

${scope_block}Diff chunk:
\`\`\`
${chunk_diff}
\`\`\`"
  _prt_call_proxy "$proxy_url" "$model" "$max_tokens" "$system" "$user"
}

# prt_model_assess PROXY_URL MODEL MAX_TOKENS CHUNK_DIFF FINDINGS_WITH_FP_JSON \
#                   PR_TITLE PROJECT_CONTEXT PROJECT_AGENTS PROJECT_CLAUDE_MD PROJECT_STANDARDS \
#                   [CHUNK_SCOPE]
# CHUNK_SCOPE as for prt_model_review: a finding whose claim rests on code
# outside the chunk cannot be checked here, neither confirmed nor refuted, so
# the assessor leaves it out and it stays open (prt_join_assessment drops a
# FALSE_POSITIVE that says it depends on code outside the chunk).
prt_model_assess() {
  local proxy_url="$1" model="$2" max_tokens="$3" chunk_diff="$4" findings_json="$5" \
        pr_title="$6" project_context="$7" project_agents="$8" project_claude_md="$9" \
        project_standards="${10}" chunk_scope="${11:-}"
  local system user scope_block=""
  system="$(_prt_assess_system_prompt)"
  [ -n "$project_context" ] && system="${system}"$'\n\nPROJECT CONTEXT:\n'"${project_context}"
  [ -n "$project_agents" ] && system="${system}"$'\n\nPROJECT CONTEXT:\n'"${project_agents}"
  [ -n "$project_claude_md" ] && system="${system}"$'\n\nPROJECT NOTES (.claude/CLAUDE.md):\n'"${project_claude_md}"
  # This is the ONLY place PROJECT STANDARDS is ever populated on GitHub
  # (go-kure/.github); the assess system prompt's own "STANDARDS
  # VERIFICATION" clause already told the model to check a section by this
  # exact name before this change existed to fill it — with no populator,
  # every standards-violation finding failed that check unconditionally and
  # was always marked FALSE_POSITIVE. See docs/pr-review-threads.md.
  [ -n "$project_standards" ] && system="${system}"$'\n\nPROJECT STANDARDS:\n'"${project_standards}"
  [ -n "$chunk_scope" ] && scope_block="${chunk_scope}
A finding whose claim depends on code that is not shown in this chunk cannot be verified from it, and
cannot be refuted from it either: leave it out of the assessments. Do not classify it FALSE_POSITIVE; it
stays open for a person to judge.

"
  user="Assess these findings against the actual diff chunk and project context.

PR Title: ${pr_title}

${scope_block}--- FINDINGS (JSON) ---
${findings_json}

--- DIFF CHUNK ---
\`\`\`
${chunk_diff}
\`\`\`"
  # PRT_ASSESS_BACKEND selects the source of the answer, as PRT_REVIEW_BACKEND
  # does for the review: unset or empty, the proxy; "runner", _prt_call_runner;
  # any other value is refused (backend-config), never read as the default.
  case "${PRT_ASSESS_BACKEND:-}" in
    "") _prt_call_proxy "$proxy_url" "$model" "$max_tokens" "$system" "$user" ;;
    runner) _prt_call_runner "${system}"$'\n\n'"${user}" ;;
    *) _prt_set_model_failure "backend-config"; return 1 ;;
  esac
}

# _prt_call_runner REQUEST — the assess call served by a review-run process
# (PRT_ASSESS_BACKEND=runner) instead of the proxy. Prints the answer body
# review-run returned, verbatim, so the caller's parse, salvage, retry and join
# are the proxy path's own. REQUEST (the assess system prompt, the project
# context, the findings with their fp and the chunk diff) goes to the runner on
# standard input through a file, never through argv: a chunk can pass the 128 KiB
# single-argument cap (see _prt_call_proxy). The prompt argument is a fixed
# instruction. Reads, all from the environment:
#   PRT_ASSESS_RUNNER_BACKEND    review-run --backend value (required)
#   PRT_ASSESS_RUNNER            the review-run executable (default: review-run)
#   PRT_ASSESS_RUNNER_ROOT       the checkout it reads (default: the working directory)
#   PRT_ASSESS_RUNNER_SECONDS    its deadline (default: 600), clamped to what is left of
#                                PRT_MODEL_DEADLINE_EPOCH; a call is refused when less
#                                than PRT_MODEL_TIMEOUT_FLOOR remains (deadline-exhausted)
#   PRT_REVIEW_BASE_SHA          the PR's base commit (required)
#   PRT_HEAD_SHA, PRT_REVIEW_MATERIAL_SHA256   the identity its record must carry (required)
#   PRT_ASSESS_RUNNER_ENV        extra variable names the runner may inherit (the model
#                                key); it runs under `env -i`, see _prt_runner_env_build
# Every refusal returns 1 with a closed-vocabulary reason in the failure file:
# backend-config (an input this mode needs is not set), local-tempdir,
# runner-incomplete (review-run exit 2), runner-quota (3), runner-launch (4),
# runner-usage (64, includes an input over its ceiling), runner-failed (any other
# non-zero exit), runner-no-output (it exited 0 and left no review.md),
# runner-empty (review.md holds nothing), provenance-mismatch (provider.json
# does not tie the answer to this head, base, material and request),
# deadline-exhausted (the run's model deadline leaves too little time).
# _prt_runner_env_build — fills PRT_RUNNER_ENV_ARGS with NAME=value words for
# `env -i`. The runner reads untrusted PR text and runs without a sandbox, so it
# gets PATH, HOME, TMPDIR, LANG, LC_ALL and the names listed in
# PRT_ASSESS_RUNNER_ENV (any whitespace separates them, newlines included; the
# model key lives there), nothing else. Returns 1, with the reason in
# PRT_RUNNER_ENV_ERROR, for a posting-token name, a name that is not a plain
# identifier (refused, never dropped) and a listed name that is not set: a
# variable the runner needs but never receives would surface later as an opaque
# runner failure. The five defaults are skipped when unset.
# shellcheck disable=SC2034 # PRT_RUNNER_ENV_ERROR is read by pr-review-threads.sh at start, not within this file
_prt_runner_env_build() {
  local name extra=() IFS=$' \t\n'
  PRT_RUNNER_ENV_ARGS=()
  PRT_RUNNER_ENV_ERROR=""
  read -rd '' -a extra <<< "${PRT_ASSESS_RUNNER_ENV:-}" || true
  for name in PATH HOME TMPDIR LANG LC_ALL; do
    if [ -n "${!name+x}" ]; then
      PRT_RUNNER_ENV_ARGS+=("$name=${!name}")
    fi
  done
  for name in ${extra[@]+"${extra[@]}"}; do
    case "$name" in
      PRT_GH_TOKEN|GITHUB_TOKEN|GH_TOKEN)
        PRT_RUNNER_ENV_ERROR="PRT_ASSESS_RUNNER_ENV must not name a posting token ($name)"
        return 1 ;;
    esac
    if ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      PRT_RUNNER_ENV_ERROR="PRT_ASSESS_RUNNER_ENV holds a name that is not a plain variable name"
      return 1
    fi
    if [ -z "${!name+x}" ]; then
      PRT_RUNNER_ENV_ERROR="PRT_ASSESS_RUNNER_ENV lists $name, which is not set"
      return 1
    fi
    PRT_RUNNER_ENV_ARGS+=("$name=${!name}")
  done
}

_prt_call_runner() {
  local request="$1" runner backend root seconds tmp out req_sha rc=0
  _prt_set_model_failure ""
  _prt_set_model_calls 0
  runner="${PRT_ASSESS_RUNNER:-review-run}"
  backend="${PRT_ASSESS_RUNNER_BACKEND:-}"
  root="${PRT_ASSESS_RUNNER_ROOT:-$PWD}"
  seconds="${PRT_ASSESS_RUNNER_SECONDS:-600}"
  if [ -z "$backend" ] || [ -z "${PRT_REVIEW_BASE_SHA:-}" ] \
     || [ -z "${PRT_HEAD_SHA:-}" ] || [ -z "${PRT_REVIEW_MATERIAL_SHA256:-}" ]; then
    _prt_set_model_failure "backend-config"
    return 1
  fi
  if ! _prt_runner_env_build || ! [[ "$seconds" =~ ^[0-9]+$ ]] || [ "$seconds" -lt 1 ]; then
    _prt_set_model_failure "backend-config"
    return 1
  fi
  # Same run deadline as the proxy calls (_prt_call_proxy): a call that cannot
  # finish in what is left is refused, and any other is clamped to it, so slow
  # chunks cannot eat the time reserved for posting the findings.
  local now budget_left
  now="$(date +%s)"
  budget_left=$(( ${PRT_MODEL_DEADLINE_EPOCH:-$((now + 300))} - now ))
  : "${PRT_MODEL_TIMEOUT_FLOOR:=30}"
  if [ "$budget_left" -lt "$PRT_MODEL_TIMEOUT_FLOOR" ]; then
    echo "prt_model: run deadline exhausted before runner call (${budget_left}s left, floor ${PRT_MODEL_TIMEOUT_FLOOR}s) — refusing call" >&2
    _prt_set_model_failure "deadline-exhausted"
    return 1
  fi
  if [ "$seconds" -gt "$budget_left" ]; then
    seconds="$budget_left"
  fi
  tmp="$(mktemp -d)"
  if [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
    _prt_set_model_failure "local-tempdir"
    return 1
  fi
  if ! printf '%s' "$request" > "$tmp/request"; then
    rm -rf "$tmp"
    _prt_set_model_failure "local-tempdir"
    return 1
  fi
  out="$tmp/out"
  env -i "${PRT_RUNNER_ENV_ARGS[@]}" \
    "$runner" --backend "$backend" --root "$root" --base "$PRT_REVIEW_BASE_SHA" \
    --seconds "$seconds" --sandbox none --out "$out" \
    -- "Perform the assessment described on the standard input. Answer with only the JSON object it asks for." \
    < "$tmp/request" > /dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -rf "$tmp"
    case "$rc" in
      2) _prt_set_model_failure "runner-incomplete" ;;
      3) _prt_set_model_failure "runner-quota" ;;
      4) _prt_set_model_failure "runner-launch" ;;
      64) _prt_set_model_failure "runner-usage" ;;
      *) _prt_set_model_failure "runner-failed" ;;
    esac
    return 1
  fi
  if [ ! -s "$out/review.md" ]; then
    if [ -e "$out/review.md" ]; then
      _prt_set_model_failure "runner-empty"
    else
      _prt_set_model_failure "runner-no-output"
    fi
    rm -rf "$tmp"
    return 1
  fi
  # The record must tie this answer to this head, base, material and the exact
  # request sent; a stale or foreign output directory fails here, not downstream.
  req_sha="$(sha256sum < "$tmp/request" | cut -d' ' -f1)"
  if [ ! -f "$out/provider.json" ] || ! jq -e \
        --arg head "$PRT_HEAD_SHA" --arg base "$PRT_REVIEW_BASE_SHA" \
        --arg mat "$PRT_REVIEW_MATERIAL_SHA256" --arg inp "$req_sha" '
        .format == "review-run-v1" and .outcome == "completed"
        and .identity.head == $head and .identity.base == $base
        and .identity.material_sha256 == $mat and .identity.input_sha256 == $inp
      ' "$out/provider.json" >/dev/null 2>&1; then
    rm -rf "$tmp"
    _prt_set_model_failure "provenance-mismatch"
    return 1
  fi
  cat "$out/review.md"
  rm -rf "$tmp"
}
