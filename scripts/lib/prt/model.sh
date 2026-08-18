#!/usr/bin/env bash
# model.sh — the two LLM calls (review, assessment), one per diff chunk,
# against the claude-max-proxy sidecar. Same backend and prompt style as the
# workflow this replaces (pr-review.yml), but JSON output instead of a
# markdown table: the review/assessment must be machine-parseable and
# fp-joinable, not just human-readable, once the diff is chunked.
#
# PRT_CURL indirection (gh.sh) is reused here too, for consistency — tests
# stub it the same way, even though model.sh itself is not exercised by the
# pure-function unit suite.
: "${PRT_CURL:=curl}"

set -uo pipefail

prt_strip_thinking() {
  awk '
    /<thinking>.*<\/thinking>/ { gsub(/<thinking>.*<\/thinking>/, ""); if (length($0) > 0) print; next }
    /<thinking>/ { skip=1; next }
    /<\/thinking>/ { sub(/.*<\/thinking>/, ""); skip=0; if (length($0) > 0) print; next }
    skip==0 { print }
  ' | sed '/./,$!d'
}

_prt_review_system_prompt() {
  cat <<'PROMPT'
You review GitHub pull requests.

ANTI-HALLUCINATION RULES:
- Only flag issues you can point to with a specific file and line from the diff.
- Do NOT flag standards violations unless the standard text appears in the PROJECT STANDARDS section below.
- Do NOT invent or assume coding standards — only cite rules explicitly provided.
  If no PROJECT STANDARDS section is present, do not flag any standards violations.
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
  local payload http_code resp content
  payload="$(jq -n \
    --arg model "$model" \
    --arg system "$system" \
    --arg user "$user" \
    --argjson max_tokens "$max_tokens" \
    '{model: $model, max_tokens: $max_tokens,
      messages: [{role: "system", content: $system}, {role: "user", content: $user}]}')"

  local tmp
  tmp="$(mktemp)"
  http_code="$("$PRT_CURL" -s -o "$tmp" -w '%{http_code}' \
    -X POST "${proxy_url}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$payload")"
  resp="$(cat "$tmp")"
  rm -f "$tmp"

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
