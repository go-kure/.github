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

# prt_response_shape CONTENT — shape-only diagnostic for a response that
# stayed unparseable after retry and salvage: length and a leading-character
# class, never the response text itself. Never logging raw model responses
# or comment bodies is a standing rule for this whole action (see
# docs/pr-review-threads.md "Failure surface"); a shape summary is not the
# content. Leading whitespace is trimmed before classifying.
prt_response_shape() {
  local content="$1" trimmed
  trimmed="${content#"${content%%[![:space:]]*}"}"
  case "$trimmed" in
    '{'*) printf 'len=%d leading=starts-with-brace' "${#content}" ;;
    '```'*) printf 'len=%d leading=starts-with-fence' "${#content}" ;;
    *) printf 'len=%d leading=starts-with-prose' "${#content}" ;;
  esac
}

_prt_review_system_prompt() {
  cat <<'PROMPT'
You review GitHub pull requests.

ANTI-HALLUCINATION RULES:
- Only flag issues you can point to with a specific file and line from the diff.
- Do NOT flag standards violations unless the standard text appears in one of the ADDITIONAL
  PROJECT CONTEXT / PROJECT DOCUMENTATION (AGENTS.md) / PROJECT NOTES sections below.
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
  dir="$(mktemp -d)"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo "prt_model: could not create a temp dir for the request" >&2
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
    > "$req" || { echo "prt_model: failed to build request payload" >&2; rm -rf "$dir"; return 1; }

  # --connect-timeout 10 --max-time 300: a per-call ceiling, not a claim the
  # whole run fits the job's 20-minute budget (.github/workflows/pr-review.yml
  # timeout-minutes: 20 = 1200s). Up to 5 diff chunks x 2 calls (review +
  # assess) = up to 10 model calls sharing that budget; 10 x 300s = 3000s can
  # exceed it if every call maxes out. 300s bounds any single hung call so it
  # alone can't consume the whole job; the job-level timeout is the backstop
  # for the aggregate, not this per-call value.
  local curl_rc=0
  http_code="$("$PRT_CURL" -s -o "$tmp" -w '%{http_code}' \
    --connect-timeout 10 --max-time 300 \
    -X POST "${proxy_url}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d @"$req")" || curl_rc=$?
  resp="$(cat "$tmp")"
  rm -rf "$dir"

  # Separated from the non-2xx branch on purpose: a curl that never produced a
  # status at all is a transport/exec fault, not a proxy response, and must not
  # be reported as one. The empty-http_code case previously fell through here.
  if [ "$curl_rc" -ne 0 ]; then
    echo "prt_model: curl failed (exit $curl_rc, http_code='$http_code')" >&2
    echo "$resp" | head -c 500 >&2
    return 1
  fi

  if [[ ! "$http_code" =~ ^2[0-9]{2}$ ]]; then
    echo "prt_model: proxy returned HTTP $http_code" >&2
    echo "$resp" | head -c 500 >&2
    return 1
  fi

  content="$(jq -r '.choices[0].message.content // empty' <<< "$resp" 2>/dev/null || true)"
  [ -n "$content" ] || { echo "prt_model: empty response content" >&2; return 1; }
  prt_strip_thinking <<< "$content"
}

# prt_model_review PROXY_URL MODEL MAX_TOKENS CHUNK_DIFF PR_TITLE PR_DESC \
#                   PROJECT_CONTEXT PROJECT_AGENTS PROJECT_CLAUDE_MD
prt_model_review() {
  local proxy_url="$1" model="$2" max_tokens="$3" chunk_diff="$4" \
        pr_title="$5" pr_desc="$6" project_context="$7" project_agents="$8" project_claude_md="$9"
  local system user
  system="$(_prt_review_system_prompt)"
  [ -n "$project_context" ] && system="${system}"$'\n\nADDITIONAL PROJECT CONTEXT:\n'"${project_context}"
  [ -n "$project_agents" ] && system="${system}"$'\n\nPROJECT DOCUMENTATION (AGENTS.md):\n'"${project_agents}"
  [ -n "$project_claude_md" ] && system="${system}"$'\n\nPROJECT NOTES (.claude/CLAUDE.md):\n'"${project_claude_md}"
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
#                   PR_TITLE PROJECT_CONTEXT PROJECT_AGENTS PROJECT_CLAUDE_MD
prt_model_assess() {
  local proxy_url="$1" model="$2" max_tokens="$3" chunk_diff="$4" findings_json="$5" \
        pr_title="$6" project_context="$7" project_agents="$8" project_claude_md="$9"
  local system user
  system="$(_prt_assess_system_prompt)"
  [ -n "$project_context" ] && system="${system}"$'\n\nPROJECT CONTEXT:\n'"${project_context}"
  [ -n "$project_agents" ] && system="${system}"$'\n\nPROJECT CONTEXT:\n'"${project_agents}"
  [ -n "$project_claude_md" ] && system="${system}"$'\n\nPROJECT NOTES (.claude/CLAUDE.md):\n'"${project_claude_md}"
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
