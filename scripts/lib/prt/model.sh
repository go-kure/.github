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
# deadline-exhausted, payload-build, local-tempdir). Read by callers in
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
prt_response_class() {
  local lc c candidate
  lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in
    *"usage limit"*|*"rate limit"*|*"too many requests"*|*"quota"*|*"limit reached"*) candidate='backend-limit' ;;
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
  # go-kure/.github#(this fix), from opsmaster's claude-proxy investigation
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
  # ceiling below. Callers that never set a run deadline (every direct unit
  # test of this function) are meant to fall back to `now + 300` fresh on
  # EVERY call.
  #
  # That fallback must land in a call-local variable, not mutate the shared
  # PRT_MODEL_DEADLINE_EPOCH via `:=` (go-kure/.github#128 round 2, kure-bot):
  # unlike PRT_MODEL_TIMEOUT_FLOOR/CEILING/PRT_MODEL_CONNECT_RETRY_DELAY below
  # — fixed constants, so `:=` into the global is a harmless one-time default
  # — this one is a function of `now`, so mutating the global freezes the
  # FIRST call's `now + 300` there; every later call in the same shell that
  # never sets PRT_MODEL_DEADLINE_EPOCH (exactly the direct, non-subshell unit
  # test callers named above) would then reuse that stale value instead of
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

# prt_model_review PROXY_URL MODEL MAX_TOKENS CHUNK_DIFF PR_TITLE PR_DESC \
#                   PROJECT_CONTEXT PROJECT_AGENTS PROJECT_CLAUDE_MD PROJECT_STANDARDS
prt_model_review() {
  local proxy_url="$1" model="$2" max_tokens="$3" chunk_diff="$4" \
        pr_title="$5" pr_desc="$6" project_context="$7" project_agents="$8" \
        project_claude_md="$9" project_standards="${10}"
  local system user
  system="$(_prt_review_system_prompt)"
  [ -n "$project_context" ] && system="${system}"$'\n\nADDITIONAL PROJECT CONTEXT:\n'"${project_context}"
  [ -n "$project_agents" ] && system="${system}"$'\n\nPROJECT DOCUMENTATION (AGENTS.md):\n'"${project_agents}"
  [ -n "$project_claude_md" ] && system="${system}"$'\n\nPROJECT NOTES (.claude/CLAUDE.md):\n'"${project_claude_md}"
  [ -n "$project_standards" ] && system="${system}"$'\n\nPROJECT STANDARDS:\n'"${project_standards}"
  user="Review this diff chunk.

Title: ${pr_title}
Description: ${pr_desc}

Diff chunk:
\`\`\`
${chunk_diff}
\`\`\`"
  _prt_call_proxy "$proxy_url" "$model" "$max_tokens" "$system" "$user"
}

# prt_model_assess PROXY_URL MODEL MAX_TOKENS CHUNK_DIFF FINDINGS_WITH_FP_JSON \
#                   PR_TITLE PROJECT_CONTEXT PROJECT_AGENTS PROJECT_CLAUDE_MD PROJECT_STANDARDS
prt_model_assess() {
  local proxy_url="$1" model="$2" max_tokens="$3" chunk_diff="$4" findings_json="$5" \
        pr_title="$6" project_context="$7" project_agents="$8" project_claude_md="$9" \
        project_standards="${10}"
  local system user
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
  user="Assess these findings against the actual diff chunk and project context.

PR Title: ${pr_title}

--- FINDINGS (JSON) ---
${findings_json}

--- DIFF CHUNK ---
\`\`\`
${chunk_diff}
\`\`\`"
  _prt_call_proxy "$proxy_url" "$model" "$max_tokens" "$system" "$user"
}
