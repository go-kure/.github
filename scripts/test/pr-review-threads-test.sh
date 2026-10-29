#!/usr/bin/env bash
# pr-review-threads-test.sh — unit tests for scripts/lib/prt/*.sh, the pure
# modules behind the pr-review-threads composite action. No network: the I/O
# module (gh.sh) is sourced only for the pieces exercised without PRT_CURL
# (freshness/rate-limit classification is covered indirectly via mocked
# curl where noted); everything else here is a pure function.
#
# Usage: pr-review-threads-test.sh [REPO_ROOT]

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
LIB="$ROOT/scripts/lib/prt"

# shellcheck source=/dev/null
source "$LIB/state.sh"
# shellcheck source=/dev/null
source "$LIB/json.sh"
# shellcheck source=/dev/null
source "$LIB/marker.sh"
# shellcheck source=/dev/null
source "$LIB/finding.sh"
# shellcheck source=/dev/null
source "$LIB/diff.sh"
# shellcheck source=/dev/null
source "$LIB/reconcile.sh"
# shellcheck source=/dev/null
source "$LIB/gh.sh"
# shellcheck source=/dev/null
source "$LIB/render.sh"

failures=0
pass_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected [$expected], got [$actual]" >&2
    failures=$((failures + 1))
  fi
}

assert_ne() {
  local desc="$1" a="$2" b="$3"
  if [ "$a" != "$b" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected [$a] != [$b]" >&2
    failures=$((failures + 1))
  fi
}

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = true ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected true, got [$cond]" >&2
    failures=$((failures + 1))
  fi
}

# ============================================================ stdin JSON collection helpers
json_left='[{"id":1}]'
json_right='[{"id":2},{"id":3}]'
json_merged="$(prt_json_concat_arrays "$json_left" "$json_right")"
assert_eq "json concat: merges two arrays" "1 2 3" "$(jq -r '[.[].id] | join(" ")' <<< "$json_merged")"

json_accumulator="$json_left"
if json_candidate="$(prt_json_concat_arrays "$json_accumulator" '{"not":"an-array"}')"; then
  json_accumulator="$json_candidate"
fi
assert_eq "json concat: malformed input fails and caller preserves the prior accumulator" \
  "$json_left" "$json_accumulator"

prt_json_concat_arrays '[]' '{}' >/dev/null 2>&1
json_bad_rc=$?
assert_eq "json concat: rejects a non-array input" "true" \
  "$([ "$json_bad_rc" -ne 0 ] && echo true || echo false)"

json_threads='[{"comments":{"nodes":[{"id":"first"}]}}]'
json_comments='[{"id":"second"},{"id":"third"}]'
json_updated="$(prt_json_append_thread_comments "$json_threads" 0 "$json_comments")"
assert_eq "json comments: appends to the selected thread" "first second third" \
  "$(jq -r '.[0].comments.nodes | map(.id) | join(" ")' <<< "$json_updated")"
prt_json_append_thread_comments "$json_threads" 1 "$json_comments" >/dev/null 2>&1
json_bad_rc=$?
assert_eq "json comments: rejects an out-of-range thread index" "true" \
  "$([ "$json_bad_rc" -ne 0 ] && echo true || echo false)"

# Each individual JSON value is above Linux's 131072-byte MAX_ARG_STRLEN.
# A real jq subprocess can consume them only if the helper keeps both off argv.
printf -v json_big_payload '%*s' 180000 ''
json_big_payload="${json_big_payload// /x}"
json_big_left="[\"$json_big_payload\"]"
json_big_right="[\"$json_big_payload\"]"
json_big_merged="$(prt_json_concat_arrays "$json_big_left" "$json_big_right")"
assert_eq "json concat: merges payloads above the kernel single-argument limit" "2 180000 180000" \
  "$(jq -r 'length as $n | [$n, (.[0]|length), (.[1]|length)] | join(" ")' <<< "$json_big_merged")"
unset json_big_payload json_big_left json_big_right json_big_merged

# prt_json_append_item validates both operands: a bare `.[0] + [.[1]]` would turn an empty
# item into [null] and succeed, which is a lost row recorded as an appended one.
json_list='[{"id":1}]'
json_one="$(prt_json_append_item "$json_list" '{"id":2}')"
assert_eq "json append_item: appends one object" "1 2" "$(jq -r '[.[].id] | join(" ")' <<< "$json_one")"
for json_bad_item in '' 'null' '[1]' '"text"' '{not json'; do
  json_out="$(prt_json_append_item "$json_list" "$json_bad_item")"
  json_bad_rc=$?
  assert_eq "json append_item: refuses the item [$json_bad_item] with no output" \
    "fail-empty" "$([ "$json_bad_rc" -ne 0 ] && [ -z "$json_out" ] && echo fail-empty || echo "rc=$json_bad_rc out=$json_out")"
done
for json_bad_list in '' 'null' '{"a":1}' '[1'; do
  json_out="$(prt_json_append_item "$json_bad_list" '{"id":2}')"
  json_bad_rc=$?
  assert_eq "json append_item: refuses the list [$json_bad_list] with no output" \
    "fail-empty" "$([ "$json_bad_rc" -ne 0 ] && [ -z "$json_out" ] && echo fail-empty || echo "rc=$json_bad_rc out=$json_out")"
done
printf -v json_big_payload '%*s' 180000 ''
json_big_payload="${json_big_payload// /x}"
json_out="$(prt_json_append_item '[]' "{\"big\":\"$json_big_payload\"}")"
assert_eq "json append_item: accepts an item above the kernel single-argument limit" "180000" \
  "$(jq -r '.[0].big | length' <<< "$json_out")"
unset json_list json_one json_bad_item json_bad_list json_out json_bad_rc json_big_payload

# prt_json_body_payload: the body travels on stdin, so a body above the limit still builds.
printf -v json_big_payload '%*s' 180000 ''
json_big_payload="${json_big_payload// /y}"
json_out="$(prt_json_body_payload "$json_big_payload" --arg in_reply_to_marker x)"
assert_eq "json body_payload: builds a payload from a body above the kernel single-argument limit" \
  "180000 x" "$(jq -r '[(.body | length), .in_reply_to_marker] | join(" ")' <<< "$json_out")"
unset json_big_payload json_out

# ============================================================ argv guard (class: unbounded value on argv)
# Linux caps ONE argument at 131072 bytes, so any `jq --arg/--argjson NAME "$var"` whose
# value can grow with a finding, a chunk, a comment body or an API response can make jq fail
# to exec on a large but legal input. Such values must travel on stdin (prt_json_* helpers,
# or a two-document `jq -s`). This guard scans the pipeline's scripts for every argument
# bound from a variable and fails on a variable that is not in the allow-list below. Adding
# a name to the list is the review step: state the measure that bounds it.
#
# Each entry is FILE:VARIABLE with its bound:
#   fp-like     16 hex characters (plus an ordinal suffix)         sha-like   40 or 64 hex characters
#   number      an index, a count, a line number or a database id  flag       the word true or false
#               (a line is rebuilt at normalization as an integer below 10^9, or null: no long spelling)
#   id-like     a login, owner, repo name or GraphQL node id or cursor (GitHub caps each far below 4 KiB)
#   const       a fixed string the script itself defines
#   config      operator configuration (a model name, a token budget, the severity rank map)
#   file        a repository path: dropped at ingress above 4096 bytes (prt_normalize_findings)
#   severity    a severity word: a value past 64 characters is reset before use
prt_guard_allow=" \
pr-review-threads.sh:chunk_idx pr-review-threads.sh:ci pr-review-threads.sh:ti pr-review-threads.sh:tpi \
pr-review-threads.sh:i pr-review-threads.sh:line pr-review-threads.sh:db_id \
pr-review-threads.sh:first_comment_db_id pr-review-threads.sh:PRT_PR_NUMBER \
pr-review-threads.sh:collision pr-review-threads.sh:gating_flag pr-review-threads.sh:has_human_reply \
pr-review-threads.sh:persisted_only_flag pr-review-threads.sh:quarantine_reason \
pr-review-threads.sh:content_fp pr-review-threads.sh:foreign_cfp pr-review-threads.sh:foreign_fp \
pr-review-threads.sh:fp pr-review-threads.sh:gating_fp_base \
pr-review-threads.sh:first_absent_sha pr-review-threads.sh:mf_sha pr-review-threads.sh:stale \
pr-review-threads.sh:PRT_HEAD_SHA \
pr-review-threads.sh:cursor pr-review-threads.sh:tcursor pr-review-threads.sh:thread_id \
pr-review-threads.sh:tid_pg pr-review-threads.sh:foreign_login pr-review-threads.sh:OWNER \
pr-review-threads.sh:REPO_NAME pr-review-threads.sh:PRT_BOT_LOGIN_GQL \
pr-review-threads.sh:file pr-review-threads.sh:owned_severity \
diff.sh:added diff.sh:removed diff.sh:path diff.sh:reason \
finding.sh:cat finding.sh:fp_base finding.sh:outside_marker \
gh.sh:bot_login gh.sh:ci gh.sh:cursor gh.sh:marker gh.sh:query gh.sh:superseded \
gh.sh:thread_id gh.sh:variables \
json.sh:index json.sh:kind \
model.sh:idx model.sh:max_tokens model.sh:model model.sh:n \
model.sh:PRT_HEAD_SHA model.sh:PRT_REVIEW_BASE_SHA model.sh:PRT_REVIEW_MATERIAL_SHA256 \
reconcile.sh:2 reconcile.sh:cap reconcile.sh:fp reconcile.sh:rank reconcile.sh:sev_rank \
reconcile.sh:this_cfp \
review-adapter.sh:chunk_count review-adapter.sh:n_chunk_failed review-adapter.sh:n_chunk_ok \
"

# prt_guard_scan FILE... — prints FILE:VARIABLE for each `--arg|--argjson NAME "$VAR"` bound
# from a variable; a command substitution prints as FILE:$( and comment lines are skipped.
prt_guard_scan() {
  local f
  for f in "$@"; do
    grep -vE '^[[:space:]]*#' "$f" |
      grep -oE -e '--(arg|argjson) +[A-Za-z_0-9]+ +"\$(\{|\()?[A-Za-z_0-9]*' |
      sed -E -e 's/.*"\$\(.*/$(/' -e 's/.*"\$\{?//' |
      sort -u | sed "s|^|$(basename "$f"):|"
  done
}

prt_guard_found="$(prt_guard_scan "$ROOT/scripts/pr-review-threads.sh" "$LIB"/*.sh "$ROOT/scripts/eval/review-adapter.sh")"
prt_guard_unknown=""
while IFS= read -r prt_guard_entry; do
  [ -z "$prt_guard_entry" ] && continue
  case "$prt_guard_allow" in
    *" $prt_guard_entry "*) ;;
    *) prt_guard_unknown="$prt_guard_unknown $prt_guard_entry" ;;
  esac
done <<< "$prt_guard_found"
assert_eq "argv guard: every variable bound with --arg/--argjson is on the allow-list (a new one needs its bound stated)" \
  "" "${prt_guard_unknown# }"
assert_eq "argv guard: the scan finds the sites (not a vacuous pass)" \
  "true" "$([ "$(wc -l <<< "$prt_guard_found")" -ge 50 ] && echo true || echo false)"

# The scanner itself: a restored `--argjson item "$item"`, a `${var}` form and a command
# substitution are each reported, and a comment mentioning the pattern is not.
prt_guard_dir="$(mktemp -d)"
cat > "$prt_guard_dir/probe.sh" <<'PROBE'
# jq --argjson in_a_comment "$ignored" is not code
jq -c --argjson item "$item" '. + [$item]' <<< "$list"
jq -c --arg body "${body}" '.' <<< "$x"
jq -c --argjson add "$(printf x)" '.' <<< "$x"
PROBE
assert_eq "argv guard: the scanner reports a restored variable argument, a braced one and a command substitution" \
  'probe.sh:$( probe.sh:body probe.sh:item' "$(prt_guard_scan "$prt_guard_dir/probe.sh" | tr '\n' ' ' | sed 's/ $//')"
rm -rf "$prt_guard_dir"
unset prt_guard_allow prt_guard_found prt_guard_unknown prt_guard_entry prt_guard_dir
unset -f prt_guard_scan

# ============================================================ fallback-value guard (class: a failure turned into a value)
# `$(jq ... || echo unknown)` turns a failed query into a word. Two failed queries then compare
# equal and a comparison of two counts reads as "covered", so a fault passes as success. A query
# whose failure matters is checked on its own status (prt_json_same_length, or `if ! x="$(jq ...)"`).
# A fallback of the empty string (a response that did not parse) is a different, deliberate shape
# and is not matched. This guard fails on a command substitution that falls back to a non-empty word.
prt_fallback_scan() { # FILE... -> FILE:LINE for each substitution that falls back to a word
  local f
  for f in "$@"; do
    grep -nE -e '\|\| *(echo|printf) +[A-Za-z0-9_]+[^;]*\)' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' |
      sed -E -e "s|^([0-9]+):.*|$(basename "$f"):\\1|"
  done
}
assert_eq "fallback guard: no pipeline script turns a failed query into a word" "" \
  "$(prt_fallback_scan "$ROOT/scripts/pr-review-threads.sh" "$LIB"/*.sh "$ROOT/scripts/eval/review-adapter.sh" | tr '\n' ' ')"
prt_fallback_dir="$(mktemp -d)"
cat > "$prt_fallback_dir/probe.sh" <<'PROBE'
n="$(jq 'length' <<< "$x" 2>/dev/null || echo unknown)"
[ "$(jq 'length' <<< "$y" 2>/dev/null || echo none)" != "$n" ]
p="$(jq -c '.' <<< "$raw" 2>/dev/null || echo '')"
# n="$(jq 'length' <<< "$x" || echo unknown)" is a comment
PROBE
assert_eq "fallback guard: the scanner reports both word fallbacks, not the empty one or the comment" \
  "probe.sh:1 probe.sh:2" "$(prt_fallback_scan "$prt_fallback_dir/probe.sh" | tr '\n' ' ' | sed 's/ $//')"
rm -rf "$prt_fallback_dir"
unset prt_fallback_dir
unset -f prt_fallback_scan

# `|| true` / `|| :` after a jq or gh call turns a failed query into success (an empty value). Each
# site is either safe because an empty value takes the failure path next (the allow-list names the
# variable and why) or must check the status itself. A new site fails this guard until it is listed.
prt_swallow_scan() { # FILE... -> FILE:VARIABLE for each jq/gh substitution that ends in || true / || :
  local f
  for f in "$@"; do
    grep -nE -e '(\bjq\b|\bgh\b|prt_gh_[a-z_]+).*\|\| *(true|:) *[)"]' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' |
      sed -E -e "s|^[0-9]+:[[:space:]]*([A-Za-z_]+)=.*|$(basename "$f"):\\1|" -e "t" -e "s|^[0-9]+:.*|$(basename "$f"):?|"
  done
}
# Allow-list, one entry per site. Each result is empty on failure and an empty value is the failure
# path of the next line: live_sha -> "no .head.sha" (rc 2); content -> "empty-content" failure;
# cur_body (three marker rewrites) -> "GET ... failed or returned an empty body", incomplete and skipped.
prt_swallow_allow="gh.sh:live_sha model.sh:content pr-review-threads.sh:cur_body pr-review-threads.sh:cur_body pr-review-threads.sh:cur_body"
assert_eq "swallow guard: every jq/gh '|| true' site is a listed one whose empty value fails the next check" \
  "$(printf '%s\n' $prt_swallow_allow | sort | tr '\n' ' ')" \
  "$(prt_swallow_scan "$ROOT/scripts/pr-review-threads.sh" "$LIB"/*.sh "$ROOT/scripts/eval/review-adapter.sh" | sort | tr '\n' ' ')"
prt_swallow_dir="$(mktemp -d)"
cat > "$prt_swallow_dir/probe.sh" <<'PROBE'
errors="$(jq -c '.errors // empty' <<< "$body" 2>/dev/null || true)"
x="$(gh api /y 2>/dev/null || :)"
  z="$(prt_gh_rest GET /z || true)"
# w="$(jq . <<< "$q" || true)" is a comment
n="$(cat "$f" 2>/dev/null || true)"
PROBE
assert_eq "swallow guard: the scanner reports jq, gh and prt_gh_ sites with their variable, not the comment or a cat" \
  "probe.sh:errors probe.sh:x probe.sh:z" "$(prt_swallow_scan "$prt_swallow_dir/probe.sh" | tr '\n' ' ' | sed 's/ $//')"
rm -rf "$prt_swallow_dir"
unset prt_swallow_dir prt_swallow_allow
unset -f prt_swallow_scan

# prt_json_same_length A B: 0 same length, 1 different, 3 when either query failed or gave no
# number (so two failures never compare equal).
assert_eq "same_length: equal arrays -> 0" "0" "$(prt_json_same_length '[1,2]' '[3,4]' >/dev/null 2>&1; echo $?)"
assert_eq "same_length: different arrays -> 1" "1" "$(prt_json_same_length '[1,2]' '[3]' >/dev/null 2>&1; echo $?)"
assert_eq "same_length: empty input is no number -> 3" "3" "$(prt_json_same_length '' '[]' >/dev/null 2>&1; echo $?)"
assert_eq "same_length: both inputs empty -> 3, not equal" "3" "$(prt_json_same_length '' '' >/dev/null 2>&1; echo $?)"
assert_eq "same_length: invalid JSON on both sides -> 3, not equal" "3" "$(prt_json_same_length '{x' '{y' >/dev/null 2>&1; echo $?)"
assert_eq "same_length: both queries failing (a local jq fault) -> 3, not equal" "3" "$(
  # shellcheck disable=SC2329,SC2317
  jq() { return 5; }
  prt_json_same_length '[1]' '[1]' >/dev/null 2>&1
  echo $?
)"

# ============================================================ fingerprint
assert_eq "fp_base is deterministic across calls" \
  "$(prt_fp_base "a/b.go" "nil-deref")" "$(prt_fp_base "a/b.go" "nil-deref")"

assert_eq "fp_base is 16 hex chars" \
  "16" "$(prt_fp_base "a/b.go" "nil-deref" | tr -d '[:space:]' | wc -c | tr -d ' ')"

assert_ne "netstring join avoids file|category ambiguity (a|b + c vs a + b|c)" \
  "$(prt_fp_base "a|b" "c")" "$(prt_fp_base "a" "b|c")"

assert_ne "different category changes fp_base" \
  "$(prt_fp_base "a/b.go" "race")" "$(prt_fp_base "a/b.go" "nil-deref")"

assert_eq "unrecognized category clamps to other" "other" "$(prt_normalize_category "made-up-category")"
assert_eq "known category passes through unchanged" "race" "$(prt_normalize_category "race")"

# go-kure/.github#196: content_fp is a second, independent fingerprint keyed
# on issue+fix (the finding's actual content), not (file, category) — used
# to detect a cross-run fp_base collision fp_base alone cannot distinguish.
assert_eq "content_fp is deterministic across calls" \
  "$(prt_content_fp "nil check missing" "add a nil guard")" \
  "$(prt_content_fp "nil check missing" "add a nil guard")"

assert_eq "content_fp is 16 hex chars" \
  "16" "$(prt_content_fp "issue text" "fix text" | tr -d '[:space:]' | wc -c | tr -d ' ')"

assert_ne "netstring join avoids issue|fix ambiguity (a|b + c vs a + b|c)" \
  "$(prt_content_fp "a|b" "c")" "$(prt_content_fp "a" "b|c")"

assert_ne "different fix text changes content_fp" \
  "$(prt_content_fp "same issue" "fix one")" "$(prt_content_fp "same issue" "fix two")"

assert_ne "different issue text changes content_fp" \
  "$(prt_content_fp "issue one" "same fix")" "$(prt_content_fp "issue two" "same fix")"

# ============================================================ ordinals / collision
single_finding='[{"file":"a.go","category":"race","line":10,"severity":"High","issue":"x","fix":"y"}]'
out="$(prt_assign_ordinals "$single_finding")"
assert_eq "single finding: collision=false" "false" "$(jq -r '.[0].collision' <<< "$out")"
assert_eq "single finding: fp has no ordinal suffix" \
  "$(prt_fp_base "a.go" "race")" "$(jq -r '.[0].fp' <<< "$out")"

pair_same='[{"file":"a.go","category":"race","line":20,"severity":"High","issue":"x","fix":"y"},
            {"file":"a.go","category":"race","line":10,"severity":"High","issue":"x2","fix":"y2"}]'
out="$(prt_assign_ordinals "$pair_same")"
assert_eq "colliding pair: both collision=true" \
  "true true" "$(jq -r '[.[].collision] | join(" ")' <<< "$out")"
assert_eq "colliding pair: ordered by line — line 10 gets base fp" \
  "true" "$(jq -r --arg base "$(prt_fp_base "a.go" "race")" '(.[] | select(.line==10) | .fp) == $base' <<< "$out")"
assert_eq "colliding pair: line 20 gets -2 suffix" \
  "true" "$(jq -r --arg base "$(prt_fp_base "a.go" "race")" '(.[] | select(.line==20) | .fp) == ($base + "-2")' <<< "$out")"

diff_cat='[{"file":"a.go","category":"race","line":10,"severity":"High","issue":"x","fix":"y"},
           {"file":"a.go","category":"nil-deref","line":10,"severity":"High","issue":"x","fix":"y"}]'
out="$(prt_assign_ordinals "$diff_cat")"
assert_eq "different category on same file/line does not collide" \
  "false false" "$(jq -r '[.[].collision] | join(" ")' <<< "$out")"

# ============================================================ normalize_findings
# rc contract (go-kure/.github#98): 0 clean, 1 .findings missing/non-array
# (nothing reviewed, stays fatal upstream), 2 shape-valid with row(s) dropped
# (degraded upstream) — see finding.sh:46-62's docstring for the full
# rationale.
good_raw='{"findings":[{"file":"a.go","category":"race","line":1,"severity":"High","issue":"i","fix":"f"}]}'
n="$(prt_normalize_findings "$good_raw")"
rc=$?
assert_eq "normalize: well-formed input returns rc 0" "0" "$rc"
assert_eq "normalize: well-formed input keeps 1 element" "1" "$(jq 'length' <<< "$n")"

bad_shape='{"findings":"not-an-array"}'
n="$(prt_normalize_findings "$bad_shape" 2>/dev/null)"
rc=$?
assert_eq "normalize: non-array .findings returns rc 1 (fatal)" "1" "$rc"
assert_eq "normalize: non-array .findings yields []" "[]" "$n"

scalar_elements='{"findings":["oops", 42, null]}'
n="$(prt_normalize_findings "$scalar_elements" 2>/dev/null)"
rc=$?
assert_eq "normalize: array-of-scalars filters down to zero (not a crash)" "0" "$(jq 'length' <<< "$n")"
assert_eq "normalize: array-of-scalars (array-shaped but EVERY row dropped) returns rc 1 (fatal total loss), not rc 2 — a non-empty .findings whose normalized result is empty must not read as a clean/degraded run (go-kure/.github#98 round 1 codex finding P1)" \
  "1" "$rc"

all_malformed_objects='{"findings":[{"file":"","category":"race","severity":"High","issue":"i","fix":"f"},{"file":"","category":"race","severity":"High","issue":"j","fix":"g"}]}'
n="$(prt_normalize_findings "$all_malformed_objects" 2>/dev/null)"
rc=$?
assert_eq "normalize: every object-shaped row malformed (empty file) still yields zero rows" "0" "$(jq 'length' <<< "$n")"
assert_eq "normalize: total loss via all-malformed objects (not just scalars) also returns rc 1, not rc 2" \
  "1" "$rc"

missing_field='{"findings":[{"file":"a.go","category":"race"}]}'
n="$(prt_normalize_findings "$missing_field" 2>/dev/null)"
assert_eq "normalize: element missing severity/issue/fix is dropped" "0" "$(jq 'length' <<< "$n")"

empty_file='{"findings":[{"file":"","category":"race","severity":"High","issue":"i","fix":"f"}]}'
n="$(prt_normalize_findings "$empty_file" 2>/dev/null)"
assert_eq "normalize: empty-string file is dropped (not == \"\" trap avoided)" "0" "$(jq 'length' <<< "$n")"

object_file='{"findings":[{"file":{"nested":true},"category":"race","severity":"High","issue":"i","fix":"f"}]}'
n="$(prt_normalize_findings "$object_file" 2>/dev/null)"
assert_eq "normalize: object .file (not string) is dropped, not misread as truthy" "0" "$(jq 'length' <<< "$n")"

# A .file over 4096 bytes is dropped at ingress: it is the one finding field later passed to
# jq as an argument, and a git path never exceeds PATH_MAX.
printf -v long_file '%*s' 5000 ''
long_file="${long_file// /d}"
long_file_raw="{\"findings\":[{\"file\":\"$long_file\",\"category\":\"race\",\"line\":1,\"severity\":\"High\",\"issue\":\"i\",\"fix\":\"f\"},{\"file\":\"ok.go\",\"category\":\"race\",\"line\":1,\"severity\":\"High\",\"issue\":\"i\",\"fix\":\"f\"}]}"
n="$(prt_normalize_findings "$long_file_raw" 2>/dev/null)"
rc=$?
assert_eq "normalize: a .file over 4096 bytes is dropped (rc 2) and the other row survives" \
  "2 ok.go" "$rc $(jq -r '[.[].file] | join(" ")' <<< "$n")"
unset long_file long_file_raw

# A local jq fault (as opposed to a bad response) is rc 3 with no output and no retry. The
# fault is injected by a `jq` function that fails when the program holds PRT_TEST_JQ_FAIL.
prt_test_fault_jq() {
  local a
  if [ -n "${PRT_TEST_JQ_FAIL:-}" ]; then
    for a in "$@"; do
      case "$a" in *"$PRT_TEST_JQ_FAIL"*) return 5 ;; esac
    done
  fi
  command jq "$@"
}
jq() { prt_test_fault_jq "$@"; }
PRT_TEST_JQ_FAIL='expected an array and one object'
n="$(prt_normalize_findings "$good_raw" 2>/dev/null)"
rc=$?
assert_eq "normalize: a local fault while rebuilding the list returns rc 3 with no output" "3 " "$rc $n"
n="$(prt_assign_ordinals "$single_finding" 2>/dev/null)"
rc=$?
assert_eq "ordinals: a local fault while rebuilding the list fails with no output" "1 " "$rc $n"
# The shape query tests the type first, so a failure of it is a fault (rc 3, never the
# retried rc 1), while a response that really has the wrong shape stays rc 1.
PRT_TEST_JQ_FAIL='(.findings | type) == "array"'
n="$(prt_normalize_findings "$good_raw" 2>/dev/null)"
rc=$?
assert_eq "normalize: a failed shape query returns rc 3 with no output (not the retried rc 1)" "3 " "$rc $n"
PRT_TEST_JQ_FAIL='(.assessments | type) == "array"'
n="$(prt_join_assessment "$single_finding" '{"assessments":[]}' 2>/dev/null)"
rc=$?
assert_eq "join: a failed shape query returns rc 2 with no output (not the degraded rc 1)" "2 " "$rc $n"
unset PRT_TEST_JQ_FAIL
n="$(prt_normalize_findings '[1,2]' 2>/dev/null)"
rc=$?
assert_eq "normalize: a top-level array is an unusable response (rc 1), not a fault" "1" "$rc"
n="$(prt_join_assessment "$single_finding" '[1]' 2>/dev/null)"
rc=$?
assert_eq "join: a top-level array is an unusable assessment (rc 1), not a fault" "1" "$rc"

# Render functions run every jq before printing: a failure returns 1 with no output, so a
# table that failed to build is never posted as an empty one (the quarantine table was).
render_q='[{"severity":"High","category":"race","file":"a.go","line":1,"issue":"i","fix":"f","gating":false}]'
render_f='[{"fp":"abcd1234abcd1234","severity":"High","category":"race","file":"a.go","line":1,"verdict":"VALID","issue":"i","fix":"f"}]'
render_x='[{"path":"big.lock","added":1,"removed":2,"reason":"lockfile"}]'
PRT_TEST_JQ_FAIL='def collision_cell'
n="$(prt_render_overflow_comment '[]' "$render_q" 2>/dev/null)"
rc=$?
assert_eq "render: a failed quarantine table returns 1 with no output" "1 " "$rc $n"
PRT_TEST_JQ_FAIL='def first_line'
n="$(prt_render_summary enforce abc 1 '[]' 1 '' '' "$render_f" '[]' 2>/dev/null)"
rc=$?
assert_eq "render: a failed suppressed table returns 1 with no output" "1 " "$rc $n"
PRT_TEST_JQ_FAIL='.[] | "| `\(.fp)`'
n="$(prt_render_summary enforce abc 1 "$render_f" 0 '' '' '[]' '[]' 2>/dev/null)"
rc=$?
assert_eq "render: a failed findings table returns 1 with no output" "1 " "$rc $n"
PRT_TEST_JQ_FAIL='| \(.fix|esc) |"'
n="$(prt_render_advisory_comment "$render_f" '' '' '[]' 2>/dev/null)"
rc=$?
assert_eq "render: a failed advisory table returns 1 with no output" "1 " "$rc $n"
PRT_TEST_JQ_FAIL='def shown'
n="$(prt_render_clean_comment abc model 1 "$render_x" 2>/dev/null)"
rc=$?
assert_eq "render: a failed excluded section fails the clean comment with no output" "1 " "$rc $n"
n="$(prt_render_summary enforce abc 1 '[]' 0 '' '' '[]' "$render_x" 2>/dev/null)"
rc=$?
assert_eq "render: a failed excluded section fails the summary with no output" "1 " "$rc $n"
PRT_TEST_JQ_FAIL='.severity'
n="$(prt_render_finding_body '{"severity":"High","category":"race","issue":"i","fix":"f"}' 'MARK' 2>/dev/null)"
rc=$?
assert_eq "render: an unreadable finding field fails the body with no output" "1 " "$rc $n"
# The job summary: a render fault appends nothing, marks the run incomplete, names why.
render_state="$(mktemp -d)"
PRT_INCOMPLETE_FILE="$render_state/incomplete"
: > "$PRT_INCOMPLETE_FILE"
PRT_TEST_JQ_FAIL='.[] | "| `\(.fp)`'
GITHUB_STEP_SUMMARY="$render_state/summary"
: > "$GITHUB_STEP_SUMMARY"
prt_write_summary enforce abc 1 "$render_f" 0 'earlier reason' '' '[]' '[]' >/dev/null 2>&1
rc=$?
assert_eq "write_summary: a render fault returns 1, appends nothing and marks the run incomplete" \
  "1 0 true" "$rc $(wc -c < "$GITHUB_STEP_SUMMARY") $(grep -qF 'job summary could not be rendered' "$PRT_INCOMPLETE_FILE" && echo true || echo false)"
unset PRT_TEST_JQ_FAIL
prt_write_summary enforce abc 1 "$render_f" 0 '' '' '[]' '[]' >/dev/null 2>&1
rc=$?
assert_eq "write_summary: the same call without the fault appends the summary" \
  "0 true" "$rc $(grep -qF 'Findings: 1' "$GITHUB_STEP_SUMMARY" && echo true || echo false)"
unset PRT_INCOMPLETE_FILE GITHUB_STEP_SUMMARY
find "$render_state" -delete
unset render_q render_f render_x render_state

# A numeric line is canonicalized at ingress to a bounded integer; anything else is no line
# (the finding becomes a file-level one). A jq 1.7 literal keeps its spelling, so 1. followed
# by 140000 zeros would otherwise reach --argjson as one oversized argument.
printf -v line_zeros '%*s' 140000 ''
line_zeros="${line_zeros// /0}"
unset PRT_TEST_JQ_FAIL
line_out=""
for line_spelling in "7" "7.0" "1.${line_zeros}" "1.5" "1e400" "-3" "12345678901" "\"7\""; do
  n="$(prt_normalize_findings "{\"findings\":[{\"file\":\"a.go\",\"category\":\"race\",\"line\":$line_spelling,\"severity\":\"High\",\"issue\":\"i\",\"fix\":\"f\"}]}" 2>/dev/null)"
  line_out="$line_out$(jq -c '.[0].line' <<< "$n" | cut -c1-12) "
done
assert_eq "normalize: a numeric line is a bounded integer or null, never a long spelling" \
  "7 7 1 null null -3 null null " "$line_out"
unset line_zeros line_out line_spelling

PRT_TEST_JQ_FAIL='no-such-program-text'
n="$(prt_normalize_findings "$good_raw" 2>/dev/null)"
rc=$?
assert_eq "normalize: with a pass-through jq the same input is rc 0 again (the fault was injected)" \
  "0 1" "$rc $(jq 'length' <<< "$n")"
unset PRT_TEST_JQ_FAIL
unset -f jq prt_test_fault_jq

partial_drop_mixed='{"findings":[{"file":"a.go","category":"race","line":1,"severity":"High","issue":"i","fix":"f"},{"file":"","category":"race","severity":"High","issue":"bad","fix":"f"}]}'
n="$(prt_normalize_findings "$partial_drop_mixed" 2>/dev/null)"
rc=$?
assert_eq "normalize: partial drop (1 good row survives, 1 malformed row dropped) keeps the good row" \
  "1" "$(jq 'length' <<< "$n")"
assert_eq "normalize: partial drop returns rc 2 (degraded), distinct from rc 1's total loss" \
  "2" "$rc"

# ============================================================ join_assessment
findings_with_fp='[{"fp":"aaaa","file":"a.go"},{"fp":"bbbb","file":"b.go"}]'
one_verdict='{"assessments":[{"fp":"aaaa","verdict":"VALID","reasoning":"looks real"}]}'
joined="$(prt_join_assessment "$findings_with_fp" "$one_verdict")"
assert_eq "join: matched fp gets its verdict" "VALID" "$(jq -r '.[] | select(.fp=="aaaa") | .verdict' <<< "$joined")"
assert_eq "join: unmatched fp stays verdict null (open, unreplied)" "null" "$(jq -r '.[] | select(.fp=="bbbb") | .verdict' <<< "$joined")"

dup_verdict='{"assessments":[{"fp":"aaaa","verdict":"VALID","reasoning":"r1"},{"fp":"aaaa","verdict":"FALSE_POSITIVE","reasoning":"r2"}]}'
joined="$(prt_join_assessment "$findings_with_fp" "$dup_verdict")"
assert_eq "join: duplicate fp in one response drops both rows, not pick-one" \
  "null" "$(jq -r '.[] | select(.fp=="aaaa") | .verdict' <<< "$joined")"

blank_reasoning='{"assessments":[{"fp":"aaaa","verdict":"VALID","reasoning":"   "}]}'
joined="$(prt_join_assessment "$findings_with_fp" "$blank_reasoning")"
assert_eq "join: whitespace-only reasoning is dropped (not a bare length check)" \
  "null" "$(jq -r '.[] | select(.fp=="aaaa") | .verdict' <<< "$joined")"

unknown_fp='{"assessments":[{"fp":"zzzz","verdict":"VALID","reasoning":"not in this chunk"}]}'
joined="$(prt_join_assessment "$findings_with_fp" "$unknown_fp")"
assert_eq "join: fp not present in this chunk's findings is dropped" \
  "0" "$(jq '[.[] | select(.verdict != null)] | length' <<< "$joined")"

bad_verdict='{"assessments":[{"fp":"aaaa","verdict":"MAYBE","reasoning":"r"}]}'
joined="$(prt_join_assessment "$findings_with_fp" "$bad_verdict")"
assert_eq "join: verdict outside the closed 3-value enum is dropped" \
  "null" "$(jq -r '.[] | select(.fp=="aaaa") | .verdict' <<< "$joined")"

# A chunk-scoped assessor cannot refute a finding whose claim rests on code it
# was not shown. A FALSE_POSITIVE that says so is no verdict: the finding stays
# open and unverdicted. Any other verdict, and any other FALSE_POSITIVE, is kept.
outside_fp='{"assessments":[{"fp":"aaaa","verdict":"FALSE_POSITIVE","reasoning":"Depends on code outside this chunk: the caller is in y.go"}]}'
joined="$(prt_join_assessment "$findings_with_fp" "$outside_fp" 2>/dev/null)"
assert_eq "join: a FALSE_POSITIVE that depends on code outside the chunk leaves the finding unverdicted" \
  "null" "$(jq -r '.[] | select(.fp=="aaaa") | .verdict' <<< "$joined")"
assert_eq "join: that finding is kept, not dropped from the joined output" \
  "2" "$(jq 'length' <<< "$joined")"
outside_fp_note="$(prt_join_assessment "$findings_with_fp" "$outside_fp" 2>&1 >/dev/null)"
assert_eq "join: the kept-open finding is named on stderr" \
  "true" "$(case "$outside_fp_note" in *"outside this chunk"*) echo true ;; *) echo false ;; esac)"
outside_valid='{"assessments":[{"fp":"aaaa","verdict":"VALID","reasoning":"depends on code outside this chunk, but the diff shows the bug"}]}'
joined="$(prt_join_assessment "$findings_with_fp" "$outside_valid" 2>/dev/null)"
assert_eq "join: a VALID verdict is kept whatever its reasoning says" \
  "VALID" "$(jq -r '.[] | select(.fp=="aaaa") | .verdict' <<< "$joined")"
plain_fp='{"assessments":[{"fp":"aaaa","verdict":"FALSE_POSITIVE","reasoning":"The guard on line 3 makes this unreachable, unlike the code outside this chunk"}]}'
joined="$(prt_join_assessment "$findings_with_fp" "$plain_fp" 2>/dev/null)"
assert_eq "join: a FALSE_POSITIVE with its own reasoning is kept" \
  "FALSE_POSITIVE" "$(jq -r '.[] | select(.fp=="aaaa") | .verdict' <<< "$joined")"

# A contradiction must not hide behind the outside-chunk filter: two rows for
# one fp are dropped as a pair, whatever either says, so the ordinary verdict
# cannot be accepted on its own once its outside-chunk twin has been filtered.
outside_dup_fp='{"assessments":[{"fp":"aaaa","verdict":"FALSE_POSITIVE","reasoning":"depends on code outside this chunk: the caller is in y.go"},{"fp":"aaaa","verdict":"FALSE_POSITIVE","reasoning":"The guard on line 3 makes this unreachable"}]}'
joined="$(prt_join_assessment "$findings_with_fp" "$outside_dup_fp" 2>/dev/null)"
assert_eq "join: {outside-chunk FALSE_POSITIVE, ordinary FALSE_POSITIVE} for one fp leaves it unverdicted" \
  "null" "$(jq -r '.[] | select(.fp=="aaaa") | .verdict' <<< "$joined")"
outside_dup_valid='{"assessments":[{"fp":"aaaa","verdict":"VALID","reasoning":"the diff shows the bug"},{"fp":"aaaa","verdict":"FALSE_POSITIVE","reasoning":"depends on code not shown in this chunk"}]}'
joined="$(prt_join_assessment "$findings_with_fp" "$outside_dup_valid" 2>/dev/null)"
assert_eq "join: {VALID, outside-chunk FALSE_POSITIVE} for one fp leaves it unverdicted" \
  "null" "$(jq -r '.[] | select(.fp=="aaaa") | .verdict' <<< "$joined")"
assert_eq "join: both findings are kept after the contradiction" "2" "$(jq 'length' <<< "$joined")"

# A local failure in any step of the join is not an unverdicted success: the
# join returns 2 with no output, so the caller can fail closed. Each step is
# failed in turn by shadowing jq for the one program that names it.
for join_step in '[.[].fp]' 'index($f)' 'group_by(.fp)' '$matched_fps'; do
  jq() { case "$*" in *"$join_step"*) return 5 ;; esac; command jq "$@"; }
  join_out="$(prt_join_assessment "$findings_with_fp" "$one_verdict" 2>/dev/null)"
  join_rc=$?
  unset -f jq
  assert_eq "join: a local failure in the step using '$join_step' returns 2" "2" "$join_rc"
  assert_eq "join: a local failure in the step using '$join_step' prints no findings" "" "$join_out"
done

# Verdicts whose reasoning together outgrow one kernel argument (128 KiB) are
# still joined: the verdict rows travel over stdin, not as a jq argument.
join_big_reasoning="$(head -c 70000 /dev/zero | tr '\0' 'r')"
join_big_raw="$(jq -cn --arg r "$join_big_reasoning" '{assessments:[{fp:"aaaa",verdict:"VALID",reasoning:$r},{fp:"bbbb",verdict:"PARTIALLY_VALID",reasoning:$r}]}')"
joined="$(prt_join_assessment "$findings_with_fp" "$join_big_raw")"
assert_eq "join: verdicts over the argument limit are still joined to both findings" \
  "VALID PARTIALLY_VALID" "$(jq -r 'map(.verdict) | join(" ")' <<< "$joined")"

# ============================================================ marker: build/parse round-trip
m="$(prt_marker_build "abcdef0123456789" "" "")"
parsed="$(prt_marker_parse "$m")"
assert_eq "marker round-trip: fp" "abcdef0123456789" "$(cut -f1 <<< "$parsed")"
assert_eq "marker round-trip: no collision by default" "" "$(cut -f2 <<< "$parsed")"
assert_eq "marker round-trip: no first_absent_sha by default" "" "$(cut -f3 <<< "$parsed")"
assert_eq "marker round-trip: no content_fp by default" "" "$(cut -f4 <<< "$parsed")"

m="$(prt_marker_build "abcdef0123456789" "true" "1111111111111111111111111111111111111111")"
parsed="$(prt_marker_parse "$m")"
assert_eq "marker round-trip: collision=true survives" "true" "$(cut -f2 <<< "$parsed")"
assert_eq "marker round-trip: first_absent_sha survives" \
  "1111111111111111111111111111111111111111" "$(cut -f3 <<< "$parsed")"
assert_eq "marker round-trip: content_fp still absent when omitted (3-arg call)" "" "$(cut -f4 <<< "$parsed")"

# go-kure/.github#196: content_fp round-trips through build/parse alongside
# every other optional field, and prt_marker_replace's own lineno lookup
# (shifted from field 4 to field 5 by this field's insertion) still finds
# the right line.
m="$(prt_marker_build "abcdef0123456789" "true" "1111111111111111111111111111111111111111" "fedcba9876543210")"
parsed="$(prt_marker_parse "$m")"
assert_eq "marker round-trip: content_fp survives alongside collision+first_absent_sha" \
  "fedcba9876543210" "$(cut -f4 <<< "$parsed")"
assert_eq "marker round-trip: fp/collision/first_absent_sha unaffected by content_fp's presence" \
  "abcdef0123456789 true 1111111111111111111111111111111111111111" \
  "$(cut -f1 <<< "$parsed") $(cut -f2 <<< "$parsed") $(cut -f3 <<< "$parsed")"

m="$(prt_marker_build "abcdef0123456789" "" "" "fedcba9876543210")"
parsed="$(prt_marker_parse "$m")"
assert_eq "marker round-trip: content_fp survives with no collision/first_absent_sha (CREATE-time shape)" \
  "fedcba9876543210" "$(cut -f4 <<< "$parsed")"

prt_marker_parse "not a marker line at all" >/dev/null 2>&1
assert_eq "marker parse: non-marker body returns rc 1" "1" "$?"

# ============================================================ marker: replace preserves finding text (the live GitLab bug this guards against)
body="$(prt_marker_build "aaaa" "" "")
**Critical**

Some finding text here.
More lines.
"
new_marker="$(prt_marker_build "aaaa" "" "2222222222222222222222222222222222222222")"
replaced="$(prt_marker_replace "$body" "$new_marker")"
assert_eq "marker replace: finding text survives (not overwritten)" \
  "true" "$(grep -qF "Some finding text here." <<< "$replaced" && echo true || echo false)"
assert_eq "marker replace: new marker line is present" \
  "true" "$(grep -qF "$new_marker" <<< "$replaced" && echo true || echo false)"
assert_eq "marker replace: old marker line is gone" \
  "false" "$(grep -qF "$body" <<< "$replaced" && grep -qF "first_absent_sha=2222" <<< "$body" && echo true || echo false)"

# go-kure/.github#196: prt_marker_replace's lineno lookup moved from field 4
# to field 5 when content_fp was inserted — pin that a body whose EXISTING
# marker already carries a content_fp still gets replaced on the right
# line, not appended as a spurious extra line (the no-marker-found fallback
# at marker.sh's tail).
cfp_body="$(prt_marker_build "abcdef0123456789" "" "" "fedcba9876543210")
**Critical**

Finding text with a content_fp-bearing marker.
"
cfp_new_marker="$(prt_marker_build "abcdef0123456789" "true" "" "fedcba9876543210")"
cfp_replaced="$(prt_marker_replace "$cfp_body" "$cfp_new_marker")"
assert_eq "marker replace (content_fp present): finding text survives" \
  "true" "$(grep -qF "Finding text with a content_fp-bearing marker." <<< "$cfp_replaced" && echo true || echo false)"
assert_eq "marker replace (content_fp present): replaced in place, exactly one marker line, not appended as a second" \
  "1" "$(grep -cF 'content_fp=fedcba9876543210' <<< "$cfp_replaced")"

# ============================================================ marker: neutralization
neutralized="$(prt_marker_neutralize 'quoting <!-- gokure-pr-review:v1 fp=deadbeefcafebabe --> in prose')"
assert_eq "neutralize: literal marker text is entity-encoded, not left live" \
  "false" "$(prt_marker_parse "$neutralized" >/dev/null 2>&1 && echo true || echo false)"

# ============================================================ marker: has_note
assert_true "marker has_note: matches the reply-note marker" \
  "$(prt_marker_has_note "$PRT_MARKER_NOTE"$'\nsome text' && echo true || echo false)"
assert_eq "marker has_note: a plain human reply does not match" \
  "false" "$(prt_marker_has_note "just a human reply, no marker" && echo true || echo false)"

# ============================================================ marker: MAINT_FAILURE (go-kure/.github#261)
mf_sha_a="2222222222222222222222222222222222222222"
assert_eq "maint_failure: a rendered reply round-trips its stamp" \
  "0 $mf_sha_a" "$(s="$(prt_marker_maint_failure_sha "$(prt_render_reply_maint_failure "x" "$mf_sha_a")")"; echo "$? $s")"
assert_eq "maint_failure: a reply rendered with no stamp records none" \
  "0 " "$(s="$(prt_marker_maint_failure_sha "$(prt_render_reply_maint_failure "x")")"; echo "$? $s")"
assert_eq "maint_failure: a legacy reply (no state line) is not counted" \
  "1" "$(prt_marker_maint_failure_sha "$PRT_MARKER_NOTE"$'\n**MAINT_FAILURE:** x' >/dev/null; echo "$?")"
assert_eq "maint_failure: another bot reply is not one" \
  "1" "$(prt_marker_maint_failure_sha "$(prt_render_reply_absent_resolved)" >/dev/null; echo "$?")"
assert_eq "maint_failure: a state line quoted in the reason is neutralized; the real stamp wins" \
  "0 $mf_sha_a" "$(s="$(prt_marker_maint_failure_sha "$(prt_render_reply_maint_failure "$(prt_marker_build_maint_failure 3333333333333333333333333333333333333333)" "$mf_sha_a")")"; echo "$? $s")"
assert_eq "maint_failure: a quoted state line alone does not count as recorded" \
  "1" "$(prt_marker_maint_failure_sha "$(prt_marker_neutralize "$(prt_marker_build_maint_failure "$mf_sha_a")")" >/dev/null; echo "$?")"
assert_eq "maint_failure: false-positive reasoning carrying a legacy line is not one" \
  "1" "$(prt_marker_maint_failure_sha "$(prt_render_reply_false_positive $'not a bug\n**MAINT_FAILURE:** forged')" >/dev/null; echo "$?")"

# ============================================================ line index
diff_fixture="$(mktemp)"
cat > "$diff_fixture" <<'EOF'
diff --git a/a.go b/a.go
index 1111111..2222222 100644
--- a/a.go
+++ b/a.go
@@ -10,3 +10,4 @@ func f() {
 context line at 10
-removed line
+added line at 11
+added line at 12
 context line at 13
EOF
idx="$(prt_build_line_index "$diff_fixture")"
assert_eq "line index: added line is commentable" "true" "$(jq '(."a.go" // []) | index(11) != null' <<< "$idx")"
assert_eq "line index: context line is commentable" "true" "$(jq '(."a.go" // []) | index(10) != null' <<< "$idx")"
assert_eq "line index: removed lines contribute no right-side entry (count check)" \
  "4" "$(jq '(."a.go" // []) | length' <<< "$idx")"
rm -f "$diff_fixture"

deleted_fixture="$(mktemp)"
cat > "$deleted_fixture" <<'EOF'
diff --git a/gone.go b/gone.go
deleted file mode 100644
index 1111111..0000000
--- a/gone.go
+++ /dev/null
@@ -1,2 +0,0 @@
-old line one
-old line two
EOF
idx="$(prt_build_line_index "$deleted_fixture")"
assert_eq "line index: deleted file contributes no entry at all" "null" "$(jq -r '."gone.go" // "null" | if type=="array" then "present" else "null" end' <<< "$idx")"
rm -f "$deleted_fixture"

# A "+++ " line inside a hunk body is content (someone added a line whose own
# text begins "++ "), not a file header. Two files, because the second one is
# what exercises the `diff --git` reset: drop that rule and in_hunk stays 1
# from doc.md, so second.md's own header is ignored and its lines land under
# doc.md. go-kure/.github#163.
header_body_fixture="$(mktemp)"
cat > "$header_body_fixture" <<'EOF'
diff --git a/doc.md b/doc.md
index 1111111..2222222 100644
--- a/doc.md
+++ b/doc.md
@@ -1,2 +1,4 @@
 one
+++ added marker
+real line
 two
diff --git a/second.md b/second.md
index 3333333..4444444 100644
--- a/second.md
+++ b/second.md
@@ -5,1 +5,2 @@
 ctx at 5
+added at 6
EOF
idx="$(prt_build_line_index "$header_body_fixture")"
assert_eq "line index: a '+++ ' body line is content, not a header" \
  "[1,2,3,4]" "$(jq -c '."doc.md" // []' <<< "$idx")"
assert_eq "line index: a '+++ ' body line mints no phantom path" \
  "false" "$(jq '(keys | index("added")) != null' <<< "$idx")"
assert_eq "line index: the file after such a hunk keeps its own path" \
  "[5,6]" "$(jq -c '."second.md" // []' <<< "$idx")"
rm -f "$header_body_fixture"

# A path git writes with a space (the +++ line ends in a tab) or quotes (a
# `"`, or a non-ASCII byte in octal) is indexed under its whole decoded name,
# the one prt_diff_files reports, not cut at the space or kept with its quotes.
name_fixture="$(mktemp)"
{
  printf '%s\n' 'diff --git a/sp ace.go b/sp ace.go' 'index 1111111..2222222 100644' '--- a/sp ace.go'$'\t'
  printf '%s\n' '+++ b/sp ace.go'$'\t' '@@ -1,1 +1,2 @@' ' keep' '+spaced'
  printf '%s\n' 'diff --git "a/qu\"ote.go" "b/qu\"ote.go"' 'index 3333333..4444444 100644' '--- "a/qu\"ote.go"'
  printf '%s\n' '+++ "b/qu\"ote.go"' '@@ -1,1 +1,2 @@' ' keep' '+quoted'
  printf '%s\n' 'diff --git "a/caf\303\251.go" "b/caf\303\251.go"' 'index 5555555..6666666 100644' '--- "a/caf\303\251.go"'
  printf '%s\n' '+++ "b/caf\303\251.go"' '@@ -1,1 +1,2 @@' ' keep' '+accent'
} > "$name_fixture"
idx="$(prt_build_line_index "$name_fixture")"
assert_eq "line index: a path with a space is indexed whole" "[1,2]" "$(jq -c '."sp ace.go" // []' <<< "$idx")"
assert_eq "line index: a git-quoted path is indexed decoded" "[1,2]" "$(jq -c '."qu\"ote.go" // []' <<< "$idx")"
assert_eq "line index: an octal-escaped path is indexed decoded" "[1,2]" "$(jq -c '."café.go" // []' <<< "$idx")"
assert_eq "line index: its paths are exactly the ones prt_diff_files reports" \
  "$(prt_diff_files "$name_fixture" | LC_ALL=C sort | tr '\n' ,)" "$(jq -r 'keys[]' <<< "$idx" | LC_ALL=C sort | tr '\n' ,)"
rm -f "$name_fixture"

# ============================================================ diff chunking
chunk_dir="$(mktemp -d)"
small_diff="$(mktemp)"
cat > "$small_diff" <<'EOF'
diff --git a/a.go b/a.go
index 1111111..2222222 100644
--- a/a.go
+++ b/a.go
@@ -1,1 +1,1 @@
-old
+new
EOF
count="$(prt_split_diff "$small_diff" 50000 "$chunk_dir")"
assert_eq "chunking: a small single-file diff produces exactly one chunk" "1" "$count"
assert_eq "chunking: the one chunk contains the file's diff --git line" \
  "true" "$(grep -qF 'diff --git a/a.go b/a.go' "$chunk_dir/chunk-000.diff" && echo true || echo false)"
rm -rf "$chunk_dir" "$small_diff"

two_file_diff="$(mktemp)"
cat > "$two_file_diff" <<'EOF'
diff --git a/a.go b/a.go
index 1111111..2222222 100644
--- a/a.go
+++ b/a.go
@@ -1,1 +1,1 @@
-old
+new
diff --git a/b.go b/b.go
index 3333333..4444444 100644
--- a/b.go
+++ b/b.go
@@ -1,1 +1,1 @@
-old2
+new2
EOF
chunk_dir="$(mktemp -d)"
# max_chars small enough that both files together don't fit one chunk, but
# each does alone — forces the file-boundary split, never mid-hunk.
count="$(prt_split_diff "$two_file_diff" 120 "$chunk_dir")"
assert_eq "chunking: two files that don't both fit produce 2 chunks" "2" "$count"
assert_eq "chunking: no chunk splits a hunk (each chunk has exactly one @@ )" \
  "true" "$(for f in "$chunk_dir"/chunk-*.diff; do [ "$(grep -c '^@@ ' "$f")" -eq 1 ] || { echo false; break; }; done; echo true)"
rm -rf "$chunk_dir" "$two_file_diff"

empty_diff="$(mktemp)"
: > "$empty_diff"
chunk_dir="$(mktemp -d)"
count="$(prt_split_diff "$empty_diff" 50000 "$chunk_dir")"
assert_eq "chunking: an empty diff produces zero chunks" "0" "$count"
rm -rf "$chunk_dir" "$empty_diff"

# ============================================================ diff chunking: write-failure hardening (dot-github#61, L7/L9/F1/F2)
# prt_split_diff is source`d directly into this test script's own shell
# (:25 above), so these two cases call it as a plain shell function with a
# controlled out_dir and assert on its own stdout/$? directly — no
# subprocess, no stubbing (new_chunk/_prt_chunk_write are nested function
# definitions redefined on every call, so no external stub could survive
# anyway — see diff.sh's own scoping note next to prt_split_diff).

# Case 10 — chunk-count propagation (L7 fold-in): point PRT_INCOMPLETE_FILE
# at an unwritable path before a diff sized to hit the hard-ceiling
# truncation path (diff.sh's single-hunk-too-big branch) — that branch's own
# prt_mark_incomplete call then hits the FATAL append-failure exit(1)
# (state.sh), which — because prt_split_diff is always the outermost/only
# command inside its caller's $(...) — collapses only that subshell's exit
# status. This is narrower than 3f's write_failed tracking (which doesn't
# see prt_mark_incomplete's own internal append at all): it guards Step 1's
# prt_mark_incomplete FATAL branch reaching the caller through the
# subshell, which 3e's split_rc check then catches.
truncation_diff="$(mktemp)"
{
  echo 'diff --git a/big.go b/big.go'
  echo 'index 1111111..2222222 100644'
  echo '--- a/big.go'
  echo '+++ b/big.go'
  echo '@@ -1,1 +1,40 @@'
  for _n in $(seq 1 40); do echo "+line $_n padding padding padding padding"; done
} > "$truncation_diff"
trunc_chunk_dir="$(mktemp -d)"
# shellcheck disable=SC2034  # read by prt_mark_incomplete in state.sh (source=/dev/null above, so shellcheck can't see the cross-file read)
PRT_INCOMPLETE_FILE="/nonexistent-dir-$$/reasons"
out="$(prt_split_diff "$truncation_diff" 10 "$trunc_chunk_dir" 2>/dev/null)"
rc=$?
assert_true "prt_split_diff: FATAL append failure inside the truncation path's own prt_mark_incomplete propagates via the caller's subshell exit status" \
  "$([ "$rc" -ne 0 ] && echo true || echo false)"
unset PRT_INCOMPLETE_FILE
rm -rf "$trunc_chunk_dir" "$truncation_diff"

# Case 11 — write-failure hardening (L9/F1/F2, the regression this case
# exists for): a genuinely non-empty diff, OUT_DIR already exists but is
# mode 555 (read+execute, no write) — mkdir -p on an already-existing
# directory succeeds regardless of its own permissions (no creation
# attempted), but every write attempt inside it fails with EACCES.
wf_chunk_dir="$(mktemp -d)"
chmod 555 "$wf_chunk_dir"
nonempty_diff="$(mktemp)"
cat > "$nonempty_diff" <<'EOF'
diff --git a/a.go b/a.go
index 1111111..2222222 100644
--- a/a.go
+++ b/a.go
@@ -1,1 +1,1 @@
-old
+new
EOF
out="$(prt_split_diff "$nonempty_diff" 50000 "$wf_chunk_dir" 2>/dev/null)"
rc=$?
assert_true "prt_split_diff: write-failure hardening — returns non-zero when OUT_DIR is unwritable" \
  "$([ "$rc" -ne 0 ] && echo true || echo false)"
assert_eq "prt_split_diff: write-failure hardening — prints no stdout at all, not even a plausible 0" \
  "" "$out"
chmod 755 "$wf_chunk_dir"
rm -rf "$wf_chunk_dir" "$nonempty_diff"

# ============================================================ go-kure/.github#173: chunk scope
# prt_diff_files: one line per touched file, in diff order. A deleted file is
# named by its old side, a new file by its new side, a binary record with no
# ---/+++ pair by its diff --git line, and a hunk body line that reads like a
# +++ header names nothing.
scope_diff="$(mktemp)"
printf '%s\n' 'diff --git a/a.go b/a.go' 'index 1111111..2222222 100644' '--- a/a.go' '+++ b/a.go' \
  '@@ -1,1 +1,2 @@' ' old' '+++ b/evil.go' \
  'diff --git a/d.go b/d.go' 'deleted file mode 100644' 'index 3333333..0000000' '--- a/d.go' '+++ /dev/null' \
  '@@ -1,1 +0,0 @@' '-gone' \
  'diff --git a/n.go b/n.go' 'new file mode 100644' 'index 0000000..4444444' '--- /dev/null' '+++ b/n.go' \
  '@@ -0,0 +1,1 @@' '+fresh' \
  'diff --git a/bin.png b/bin.png' 'index 5555555..6666666 100644' 'Binary files a/bin.png and b/bin.png differ' \
  > "$scope_diff"
assert_eq "diff_files: modified, deleted, new and binary files once each; a body +++ line is not a header" \
  "$(printf '%s\n' a.go d.go n.go bin.png)" "$(prt_diff_files "$scope_diff")"

# Paths git writes in other forms (round-1 review of the #173 change): a pure
# rename or copy names its new path only on its `rename to`/`copy to` line
# (here one holding " b/", which the diff --git line cannot split); a binary
# record's path may hold spaces; git C-quotes a path holding `"`, `\` or a
# non-ASCII byte and ends an unquoted header path holding a space with a tab.
# A path holding a control character keeps its quoted form, so the list stays
# one path per line.
printf '%s\n' 'diff --git a/x.go b/dir b/z.go' 'similarity index 100%' 'rename from x.go' 'rename to dir b/z.go' \
  'diff --git a/c.go b/c copy.go' 'similarity index 100%' 'copy from c.go' 'copy to c copy.go' \
  'diff --git a/binary image.png b/binary image.png' 'index 5555555..6666666 100644' \
  'Binary files a/binary image.png and b/binary image.png differ' \
  'diff --git a/gone file.bin b/gone file.bin' 'deleted file mode 100644' 'index 7777777..0000000' \
  'Binary files a/gone file.bin and /dev/null differ' \
  'diff --git "a/quote\"name.go" "b/quote\"name.go"' 'index 1111111..2222222 100644' \
  '--- "a/quote\"name.go"' '+++ "b/quote\"name.go"' '@@ -1,1 +1,1 @@' '-a' '+b' \
  'diff --git "a/caf\303\251.go" "b/caf\303\251.go"' 'new file mode 100644' 'index 0000000..3333333' \
  '--- /dev/null' '+++ "b/caf\303\251.go"' '@@ -0,0 +1,1 @@' '+x' \
  'diff --git "a/new\nline.go" "b/new\nline.go"' 'index 1111111..2222222 100644' \
  '--- "a/new\nline.go"' '+++ "b/new\nline.go"' '@@ -1,1 +1,1 @@' '-a' '+b' \
  'diff --git a/sp ace.go b/sp ace.go' 'index 1111111..2222222 100644' \
  $'--- a/sp ace.go\t' $'+++ b/sp ace.go\t' '@@ -1,1 +1,1 @@' '-a' '+b' \
  > "$scope_diff"
assert_eq "diff_files: rename/copy targets, binary paths with spaces, quoted, octal, control-char and tab-ended paths" \
  "$(printf '%s\n' 'dir b/z.go' 'c copy.go' 'binary image.png' 'gone file.bin' 'quote"name.go' $'caf\303\251.go' '"new\nline.go"' 'sp ace.go')" \
  "$(prt_diff_files "$scope_diff")"

# A file literally named `"new\nline.go"` (quotes and backslash included) must
# not read the same as the control-character path above and be dropped as a
# duplicate (round-2 review): it keeps git's quoting too.
printf '%s\n' 'diff --git "a/new\nline.go" "b/new\nline.go"' 'old mode 100644' 'new mode 100755' \
  'diff --git "a/\"new\\nline.go\"" "b/\"new\\nline.go\""' 'old mode 100644' 'new mode 100755' \
  > "$scope_diff"
assert_eq "diff_files: a decoded path starting with a quote does not collide with a kept quoted path" \
  "$(printf '%s\n' '"new\nline.go"' '"\"new\\nline.go\""')" \
  "$(prt_diff_files "$scope_diff")"
rm -f "$scope_diff"

assert_eq "chunk_scope: a single-chunk diff gets no scope block" \
  "" "$(source "$LIB/model.sh"; prt_chunk_scope 0 1 "x.go" "x.go")"
assert_eq "chunk_scope: chunk 1 of 2 names itself, the whole diff's files and its own" \
  "$(printf '%s\n' 'CHUNK SCOPE: this diff is split into 2 chunks; this is chunk 1 of 2.' \
      'Files in the whole diff:' '- x.go' '- y.go' 'Files in this chunk:' '- x.go' \
      'Code in the other chunks exists but is not shown here: not seeing something in this chunk says nothing about the rest of the diff.')" \
  "$(source "$LIB/model.sh"; prt_chunk_scope 0 2 "$(printf '%s\n' x.go y.go)" "x.go")"
# The whole-diff list is capped at PRT_MAX_DIFF_CHARS/10 (each line costs its
# path plus 3); the rest are counted, and a shorter path after the cut is not
# listed out of order.
assert_eq "chunk_scope: the whole-diff list stops at a tenth of PRT_MAX_DIFF_CHARS and counts the rest" \
  "$(printf '%s\n' 'Files in the whole diff:' '- aaaa.go' '- bbbb.go' '- (2 more file(s), not listed)' 'Files in this chunk:')" \
  "$(source "$LIB/model.sh"; PRT_MAX_DIFF_CHARS=270 prt_chunk_scope 0 2 "$(printf '%s\n' aaaa.go bbbb.go cccccccc.go d.go)" "aaaa.go" | sed -n '2,6p')"
assert_eq "chunk_scope: a list within the cap gets no count line" \
  "0" "$(source "$LIB/model.sh"; PRT_MAX_DIFF_CHARS=270 prt_chunk_scope 0 2 "$(printf '%s\n' aaaa.go bbbb.go)" "aaaa.go" | grep -c 'not listed')"

assert_eq "chunk_label: 0-based _chunk 1 of 3 -> chunk 2/3" "chunk 2/3" "$(prt_chunk_label '{"_chunk":1}' 3)"
assert_eq "chunk_label: single-chunk review -> empty" "" "$(prt_chunk_label '{"_chunk":0}' 1)"
assert_eq "chunk_label: no _chunk index -> empty" "" "$(prt_chunk_label '{}' 2)"

label_finding='{"severity":"High","category":"bug","issue":"i","fix":"f","file":"x.go","line":1}'
assert_eq "finding_body: a chunk label names the chunk in the footer" \
  "true" "$(prt_render_finding_body "$label_finding" "<!-- m -->" "chunk 2/3" | grep -qF 'Automated review finding from chunk 2/3 of the diff (the reviewer saw only that chunk)' && echo true || echo false)"
assert_eq "finding_body: no label keeps the plain footer" \
  "true" "$(prt_render_finding_body "$label_finding" "<!-- m -->" | grep -qF '*Automated review finding — reply to discuss' && echo true || echo false)"

# ============================================================ reconcile: prt_decide_finding
# go-kure/.github#155: row 1 used to return NONE, indistinguishable from
# every other do-nothing row — a colliding finding with no thread yet was
# silently dropped nowhere. QUARANTINE is its own outcome word specifically
# so the caller can count and render it. Both polarities: collision must
# produce QUARANTINE regardless of thread state, and the OTHER three rows
# that return NONE (immediately below, and further down: FALSE_POSITIVE
# already-resolved, VALID still-open, VALID resolved-by-human) must still
# return NONE — a fix that returns QUARANTINE unconditionally would pass
# the first assertion alone.
assert_eq "decide_finding: collision beats everything -> QUARANTINE, not NONE (thread doesn't exist yet)" \
  "QUARANTINE" "$(prt_decide_finding true VALID false false false true)"
assert_eq "decide_finding: collision beats everything -> QUARANTINE even when a thread already exists" \
  "QUARANTINE" "$(prt_decide_finding true VALID true false false true)"
# Exception to the two assertions above: a collided finding the second pass
# already rejected as a false positive, with no thread yet, still suppresses
# rather than publishing a rejected finding just because its fingerprint was
# ambiguous (go-kure/.github#180 codex review) -- but an EXISTING ambiguous
# thread stays conservative and is still quarantined regardless of verdict.
assert_eq "decide_finding: collision + FALSE_POSITIVE, no thread yet -> suppress, not quarantine" \
  "SUPPRESS" "$(prt_decide_finding true FALSE_POSITIVE false false false true)"
assert_eq "decide_finding: collision + FALSE_POSITIVE, thread already exists -> still quarantine" \
  "QUARANTINE" "$(prt_decide_finding true FALSE_POSITIVE true false false true)"
assert_eq "decide_finding: FALSE_POSITIVE, no thread yet -> suppress, never create" \
  "SUPPRESS" "$(prt_decide_finding false FALSE_POSITIVE false false false true)"
assert_eq "decide_finding: FALSE_POSITIVE, open thread -> reply+resolve" \
  "REPLY_RESOLVE" "$(prt_decide_finding false FALSE_POSITIVE true false false true)"
# go-kure/.github#177: row 3 used to ignore has_human_reply entirely, so a
# thread a human was actively defending got resolved the next time an
# assessment called the same finding a false positive -- the same
# single-sample retirement the absence pass (row 13, has_human_reply arg)
# was designed to avoid. Both polarities, per the issue's own suggested
# test: the flag explicitly true protects; the flag explicitly false (not
# just the 6-arg/omitted default tested two lines up) still resolves.
assert_eq "decide_finding: FALSE_POSITIVE, open thread, human reply -> protected, not resolved (go-kure/.github#177)" \
  "NONE" "$(prt_decide_finding false FALSE_POSITIVE true false false true true)"
assert_eq "decide_finding: FALSE_POSITIVE, open thread, no human reply -> still reply+resolve" \
  "REPLY_RESOLVE" "$(prt_decide_finding false FALSE_POSITIVE true false false true false)"
# Control: has_human_reply must NOT leak into a row it doesn't govern -- a
# thread that doesn't exist yet (row 2) has no comments to reply to, and an
# already-resolved thread (tail of row 3) has nothing left to protect
# either. If a future edit moved the check earlier than the
# thread_resolved!=true branch, these would flip from SUPPRESS/NONE to
# something else and catch it.
assert_eq "decide_finding: FALSE_POSITIVE, no thread yet, has_human_reply=true is inert -> still suppress" \
  "SUPPRESS" "$(prt_decide_finding false FALSE_POSITIVE false false false true true)"
assert_eq "decide_finding: FALSE_POSITIVE, already-resolved thread, has_human_reply=true is inert -> still none" \
  "NONE" "$(prt_decide_finding false FALSE_POSITIVE true true false true true)"
assert_eq "decide_finding: VALID, no thread, within cap -> create" \
  "CREATE" "$(prt_decide_finding false VALID false false false true)"
assert_eq "decide_finding: VALID, no thread, beyond cap -> overflow" \
  "OVERFLOW" "$(prt_decide_finding false VALID false false false false)"
assert_eq "decide_finding: VALID, thread still open -> none (already gating)" \
  "NONE" "$(prt_decide_finding false VALID true false false true)"
assert_eq "decide_finding: VALID, resolved by a human -> never reopen" \
  "NONE" "$(prt_decide_finding false VALID true true false true)"
assert_eq "decide_finding: VALID, resolved by the bot, recurs -> reply+unresolve" \
  "REPLY_UNRESOLVE" "$(prt_decide_finding false VALID true true true true)"
assert_eq "decide_finding: unmatched verdict (NONE) behaves like VALID for existence rows" \
  "CREATE" "$(prt_decide_finding false NONE false false false true)"

# ============================================================ reconcile: prt_decide_absent
assert_eq "decide_absent: collision beats everything" \
  "NONE" "$(prt_decide_absent true false false "" abc false false)"
assert_eq "decide_absent: REVIEW_INCOMPLETE with a stamped first_absent_sha -> clear it" \
  "CLEAR_MARKER" "$(prt_decide_absent false false false xyz abc true false)"
assert_eq "decide_absent: REVIEW_INCOMPLETE with no first_absent_sha -> nothing to clear" \
  "NONE" "$(prt_decide_absent false false false "" abc true false)"
assert_eq "decide_absent: human reply protects thread from every absence action" \
  "NONE" "$(prt_decide_absent false true false "" abc false false)"
assert_eq "decide_absent: already resolved -> nothing to auto-close" \
  "NONE" "$(prt_decide_absent false false true "" abc false false)"
assert_eq "decide_absent: first sighting -> set first_absent_sha" \
  "SET_FIRST_ABSENT" "$(prt_decide_absent false false false "" abc false false)"
assert_eq "decide_absent: same-commit retry is not a second absence" \
  "NONE" "$(prt_decide_absent false false false abc abc false false)"
assert_eq "decide_absent: a recorded stale stamp is re-stamped, not resolved" \
  "SET_FIRST_ABSENT" "$(prt_decide_absent false false false abc def false true)"
assert_eq "decide_absent: two absences on different SHAs -> reply+resolve" \
  "REPLY_RESOLVE" "$(prt_decide_absent false false false abc def false false)"

# ============================================================ reconcile: cap reservation (dot-github#51)
# prt_thread_stays_gating / prt_reserved_count / prt_gating_eligible /
# prt_apply_cap — the extracted, tested replacement for the orchestrator's
# former hand-copied inline jq (dot-github#51). Every case below is verified
# by hand against reconcile.sh's own equivalence table.

# --- 7-row matrix (+ null-verdict variant), one OWNED thread each, matched
# against a same-fp finding (thread_exists=true throughout) ---
# The two row1/collision cases immediately below exercise prt_decide_finding's
# QUARANTINE outcome (go-kure/.github#155) through prt_thread_stays_gating's
# own explicit QUARANTINE arm — added at the same time as QUARANTINE itself,
# per that function's own comment instructing exactly this check. Without
# that arm these fall into the default case (false, never gating) and the
# "open -> reserves" case below regresses from 1 to 0.
assert_eq "reserved_count: row1 collision, open -> reserves" \
  "1" "$(prt_reserved_count \
    '[{"fp":"r1","collision":true,"resolved":false,"resolved_by_bot":false}]' \
    '[{"fp":"r1","collision":true,"verdict":"VALID"}]')"
assert_eq "reserved_count: row1 collision, resolved -> does not reserve" \
  "0" "$(prt_reserved_count \
    '[{"fp":"r1","collision":true,"resolved":true,"resolved_by_bot":false}]' \
    '[{"fp":"r1","collision":true,"verdict":"VALID"}]')"
assert_eq "reserved_count: row2/3 FALSE_POSITIVE, open -> frees (about to resolve)" \
  "0" "$(prt_reserved_count \
    '[{"fp":"r1","collision":false,"resolved":false,"resolved_by_bot":false}]' \
    '[{"fp":"r1","collision":false,"verdict":"FALSE_POSITIVE"}]')"
assert_eq "reserved_count: FALSE_POSITIVE, already resolved -> stays free" \
  "0" "$(prt_reserved_count \
    '[{"fp":"r1","collision":false,"resolved":true,"resolved_by_bot":false}]' \
    '[{"fp":"r1","collision":false,"verdict":"FALSE_POSITIVE"}]')"
assert_eq "reserved_count: row5 open VALID -> reserves" \
  "1" "$(prt_reserved_count \
    '[{"fp":"r1","collision":false,"resolved":false,"resolved_by_bot":false}]' \
    '[{"fp":"r1","collision":false,"verdict":"VALID"}]')"
# go-kure/.github#153: a foreign row is never acted on, so it reserves
# exactly while open, whatever the verdict and whether matched or absent.
assert_eq "reserved_count #153: foreign open, matched by a FALSE_POSITIVE -> reserves (it is never resolved)" \
  "1" "$(prt_reserved_count \
    '[{"fp":"r1","foreign":true,"author":"kure-bot","resolved":false}]' \
    '[{"fp":"r1","collision":false,"verdict":"FALSE_POSITIVE"}]')"
assert_eq "reserved_count #153: foreign resolved, matched by a VALID -> does not reserve (never reopened; a new own thread competes as a CREATE)" \
  "0" "$(prt_reserved_count \
    '[{"fp":"r1","foreign":true,"author":"kure-bot","resolved":true}]' \
    '[{"fp":"r1","collision":false,"verdict":"VALID"}]')"
assert_eq "reserved_count #153: foreign open, absent -> reserves" \
  "1" "$(prt_reserved_count \
    '[{"fp":"r1","foreign":true,"author":"kure-bot","resolved":false}]' '[]')"
assert_eq "gating_eligible #153: a finding matching a foreign row is not a CREATE candidate" \
  "[]" "$(prt_gating_eligible '[{"fp":"r1","collision":false,"verdict":"VALID","severity":"High"}]' \
    '[{"fp":"r1","foreign":true,"author":"kure-bot","resolved":true}]' '{"critical":0,"high":1,"medium":2}')"
# go-kure/.github#153: prt_foreign_action, the one per-finding decision for
# foreign rows, shared by loop 1 and the cap walk. A foreign marker is
# untrusted: what is read from it may only make the run gate more. The
# helper still sets resolved_by_author for author/human rows (the
# orchestrator no longer carries it), so the cases below prove who resolved a
# row makes no difference.
prt_t153_row() { # STATE(open|author|human) CONTENT_FP [AUTHOR] [MARKER_COLLISION]
  jq -nc --arg s "$1" --arg cfp "$2" --arg a "${3:-kure-bot}" --argjson c "${4:-false}" \
    '{fp:"r1",foreign:true,author:$a,resolved:($s != "open"),resolved_by_author:($s == "author"),collision:$c,content_fp:$cfp}'
}
prt_t153_finding() { # VERDICT COLLISION
  jq -nc --arg v "$1" --argjson c "$2" '{fp:"r1",collision:$c,verdict:$v,severity:"High",issue:"i153",fix:"f153"}'
}
prt_t153_act() { prt_foreign_action "$1" "$2" | cut -f1; }
t153_cfp="$(prt_content_fp i153 f153)"
t153_other_cfp="0123456789abcdef"
assert_eq "foreign_action #153: resolved by its author, VALID recurs -> NEW (row 7's reopen becomes a new own thread)" \
  "NEW" "$(prt_t153_act "[$(prt_t153_row author "")]" "$(prt_t153_finding VALID false)")"
assert_eq "foreign_action #153: resolved by its author, PARTIALLY_VALID recurs, equal content_fp -> NEW" \
  "NEW" "$(prt_t153_act "[$(prt_t153_row author "$t153_cfp")]" "$(prt_t153_finding PARTIALLY_VALID false)")"
# R2-P1: a foreign resolution is never trusted. The marker is editable by
# its author, who can add a target fp (and drop content_fp) on an old,
# human-resolved comment of theirs: the resolution must not suppress the
# recurring finding, so it takes row 7's path like an author-resolved row.
assert_eq "foreign_action #153 (R2-P1): resolved by someone else, empty content_fp, VALID recurs -> NEW (a foreign resolution never suppresses)" \
  "NEW" "$(prt_t153_act "[$(prt_t153_row human "")]" "$(prt_t153_finding VALID false)")"
assert_eq "foreign_action #153 (R2-P1): resolved by someone else, equal content_fp, VALID recurs -> NEW" \
  "NEW" "$(prt_t153_act "[$(prt_t153_row human "$t153_cfp")]" "$(prt_t153_finding VALID false)")"
assert_eq "foreign_action #153: resolved by its author, FALSE_POSITIVE -> NONE (resolved false positive)" \
  "NONE" "$(prt_t153_act "[$(prt_t153_row author "")]" "$(prt_t153_finding FALSE_POSITIVE false)")"
assert_eq "foreign_action #153 (R2-P1): resolved by someone else, FALSE_POSITIVE -> NONE (this run's own verdict, not the marker)" \
  "NONE" "$(prt_t153_act "[$(prt_t153_row human "")]" "$(prt_t153_finding FALSE_POSITIVE false)")"
# R2-P2: a failed read returns 1, never a guessed NOMATCH. jq is shadowed to
# fail only on the fp-presence filter, so every other call still runs. The
# body is a subshell, so the shadow never outlives the call.
t153_jq_fail_any() (
  # Invoked indirectly by "$@"; the $fp is the literal jq filter text.
  # shellcheck disable=SC2329,SC2016
  jq() { case "$*" in *'any(.[]; .fp == $fp)'*) return 5 ;; esac; command jq "$@"; }
  "$@" >/dev/null 2>&1
  echo "$?"
)
assert_eq "foreign_action #153 (R2-P2): jq failure on the fp-presence check -> returns 1, not NOMATCH" \
  "1" "$(t153_jq_fail_any prt_foreign_action "[$(prt_t153_row human "")]" "$(prt_t153_finding VALID false)")"
# R3-P1: the finding's own content_fp. A failed issue/fix read, or a hash
# that is not one, would read an equal-content_fp open row as NOMATCH.
t153_fail_cfp() ( # issue|fix|hash FOREIGN FINDING
  local what="$1"; shift
  # Invoked by the prt_foreign_action call below.
  # shellcheck disable=SC2329
  jq() { case "$what $*" in "issue -r .issue"|"fix -r .fix") return 5 ;; esac; command jq "$@"; }
  # shellcheck disable=SC2329
  [ "$what" = hash ] && prt_content_fp() { echo not-a-hash; }
  prt_foreign_action "$@" >/dev/null 2>&1
  echo "$?"
)
assert_eq "foreign_action #153 (R3-P1): failed issue read, failed fix read, malformed hash -> returns 1 each, not NOMATCH" \
  "1 1 1" "$(t153_fail_cfp issue "[$(prt_t153_row open "$t153_cfp")]" "$(prt_t153_finding VALID false)") $(t153_fail_cfp fix "[$(prt_t153_row open "$t153_cfp")]" "$(prt_t153_finding VALID false)") $(t153_fail_cfp hash "[$(prt_t153_row open "$t153_cfp")]" "$(prt_t153_finding VALID false)")"
assert_eq "foreign_action #153 (R1-P1): planted collision=true on an author-resolved marker -> NEW, the flag is never read" \
  "NEW" "$(prt_t153_act "[$(prt_t153_row author "$t153_cfp" kure-bot true)]" "$(prt_t153_finding VALID false)")"
assert_eq "foreign_action #153 (R1-P1): author-resolved marker with another finding's content_fp -> NOMATCH (no-thread path), never QUARANTINE" \
  "NOMATCH" "$(prt_t153_act "[$(prt_t153_row author "$t153_other_cfp")]" "$(prt_t153_finding VALID false)")"
assert_eq "foreign_action #153: this run's own collision on an author-resolved match -> QUARANTINE (row 1)" \
  "QUARANTINE" "$(prt_t153_act "[$(prt_t153_row author "")]" "$(prt_t153_finding VALID true)")"
assert_eq "foreign_action #153 (R1-P2b): open thread with a different content_fp -> NOMATCH, the author still reported" \
  "NOMATCH"$'\t'"kure-bot" "$(prt_foreign_action "[$(prt_t153_row open "$t153_other_cfp")]" "$(prt_t153_finding VALID false)")"
assert_eq "foreign_action #153 (R1-P2b): open thread with an equal or absent content_fp -> EXISTING" \
  "EXISTING EXISTING" "$(prt_t153_act "[$(prt_t153_row open "$t153_cfp")]" "$(prt_t153_finding VALID false)") $(prt_t153_act "[$(prt_t153_row open "")]" "$(prt_t153_finding VALID false)")"
assert_eq "foreign_action #153: no foreign row with the fp -> NOMATCH, no author" \
  "NOMATCH"$'\t' "$(prt_foreign_action "[$(jq -c '.fp="r9"' <<< "$(prt_t153_row open "")")]" "$(prt_t153_finding VALID false)")"
assert_eq "foreign_action #153 (R1-P2a): an open row beats any resolved one, in any row order" \
  "EXISTING EXISTING" "$(prt_t153_act "[$(prt_t153_row author "" a1), $(prt_t153_row human "" h1), $(prt_t153_row open "" o1)]" "$(prt_t153_finding VALID false)") $(prt_t153_act "[$(prt_t153_row open "" o1), $(prt_t153_row author "" a1)]" "$(prt_t153_finding VALID false)")"
assert_eq "foreign_action #153 (R2-P1): author-resolved + human-resolved pair -> NEW in either order (no resolution suppresses)" \
  "NEW NEW" "$(prt_t153_act "[$(prt_t153_row author "" a1), $(prt_t153_row human "" h1)]" "$(prt_t153_finding VALID false)") $(prt_t153_act "[$(prt_t153_row human "" h1), $(prt_t153_row author "" a1)]" "$(prt_t153_finding VALID false)")"
assert_eq "foreign_action #153 (R1-P2a): a content-mismatched open row does not outrank a matching author-resolved one" \
  "NEW"$'\t'"a1" "$(prt_foreign_action "[$(prt_t153_row open "$t153_other_cfp" o1), $(prt_t153_row author "" a1)]" "$(prt_t153_finding VALID false)")"
# The cap walk sees every row (an open one still reserves) and releases the
# finding to the CREATE candidates exactly when loop 1 takes the no-thread path.
t153_eligible() { # FOREIGN FINDING
  prt_gating_eligible "[$2]" "$(prt_cap_foreign_rows "$1" "[$2]")" '{"critical":0,"high":1,"medium":2}' | jq -r '.[0].fp // "none"'
}
assert_eq "cap_foreign_rows #153: every row is kept" \
  "3" "$(prt_cap_foreign_rows "[$(prt_t153_row human ""), $(prt_t153_row open "$t153_other_cfp"), $(jq -c '.fp="r3"' <<< "$(prt_t153_row author "")")]" "[$(prt_t153_finding VALID false)]" | jq length)"
assert_eq "cap_foreign_rows #153: author-resolved match -> the finding is a CREATE candidate" \
  "r1" "$(t153_eligible "[$(prt_t153_row author "")]" "$(prt_t153_finding VALID false)")"
assert_eq "cap_foreign_rows #153 (R2-P1): only match resolved by someone else -> its rows tagged excludes:false, the finding a CREATE candidate" \
  "false r1" "$(prt_cap_foreign_rows "[$(prt_t153_row human "" h1)]" "[$(prt_t153_finding VALID false)]" | jq -r '.[0].excludes') $(t153_eligible "[$(prt_t153_row human "" h1)]" "$(prt_t153_finding VALID false)")"
assert_eq "cap_foreign_rows #153 (R2-P1): author-resolved + human-resolved pair -> a candidate, in either order" \
  "r1 r1" "$(t153_eligible "[$(prt_t153_row author "" a1), $(prt_t153_row human "" h1)]" "$(prt_t153_finding VALID false)") $(t153_eligible "[$(prt_t153_row human "" h1), $(prt_t153_row author "" a1)]" "$(prt_t153_finding VALID false)")"
assert_eq "cap_foreign_rows #153 (R2-P2): jq failure on the fp-presence check -> returns 1, not a silently unreleased finding" \
  "1" "$(t153_jq_fail_any prt_cap_foreign_rows "[$(prt_t153_row human "" h1)]" "[$(prt_t153_finding VALID false)]")"
assert_eq "cap_foreign_rows #153 (R1-P2a): two author-resolved rows -> one candidate" \
  "r1" "$(t153_eligible "[$(prt_t153_row author "" a1), $(prt_t153_row author "" a2)]" "$(prt_t153_finding VALID false)")"
assert_eq "cap_foreign_rows #153 (R1-P2b): open row with a different content_fp -> the finding is a candidate AND the row still reserves" \
  "r1 1" "$(t153_eligible "[$(prt_t153_row open "$t153_other_cfp")]" "$(prt_t153_finding VALID false)") $(prt_reserved_count "$(prt_cap_foreign_rows "[$(prt_t153_row open "$t153_other_cfp")]" "[$(prt_t153_finding VALID false)]")" "[$(prt_t153_finding VALID false)]")"
assert_eq "cap_foreign_rows #153: open row with an equal content_fp -> not a candidate" \
  "none" "$(t153_eligible "[$(prt_t153_row open "$t153_cfp")]" "$(prt_t153_finding VALID false)")"
assert_eq "reserved_count: row6 resolved by a human -> does not reserve" \
  "0" "$(prt_reserved_count \
    '[{"fp":"r1","collision":false,"resolved":true,"resolved_by_bot":false}]' \
    '[{"fp":"r1","collision":false,"verdict":"VALID"}]')"
assert_eq "reserved_count: row7 resolved by the bot, recurs -> reserves" \
  "1" "$(prt_reserved_count \
    '[{"fp":"r1","collision":false,"resolved":true,"resolved_by_bot":true}]' \
    '[{"fp":"r1","collision":false,"verdict":"VALID"}]')"
assert_eq "reserved_count: unassessed (verdict null) behaves like row5 -> reserves" \
  "1" "$(prt_reserved_count \
    '[{"fp":"r1","collision":false,"resolved":false,"resolved_by_bot":false}]' \
    '[{"fp":"r1","collision":false,"verdict":null}]')"

# go-kure/.github#200: a singleton content_fp mismatch (no same-run
# collision) still routes to QUARANTINE in the main loop and keeps the
# thread gating — this upfront cap walk must predict that, or it
# under-reserves and lets a later CREATE exceed the cap.
assert_eq "reserved_count: content_fp mismatch, no same-run collision -> still reserves" \
  "1" "$(prt_reserved_count \
    '[{"fp":"r1","collision":false,"resolved":false,"resolved_by_bot":false,"content_fp":"f53017535c431f00"}]' \
    '[{"fp":"r1","collision":false,"verdict":"FALSE_POSITIVE","issue":"different issue text","fix":"different fix text"}]')"
assert_eq "reserved_count: content_fp match, FALSE_POSITIVE -> frees, same as no content_fp" \
  "0" "$(prt_reserved_count \
    '[{"fp":"r1","collision":false,"resolved":false,"resolved_by_bot":false,"content_fp":"f53017535c431f00"}]' \
    '[{"fp":"r1","collision":false,"verdict":"FALSE_POSITIVE","issue":"some finding issue text","fix":"some finding fix text"}]')"
assert_eq "reserved_count: no content_fp on OWNED (pre-#196 thread) -> unverifiable, trusts match unchanged" \
  "0" "$(prt_reserved_count \
    '[{"fp":"r1","collision":false,"resolved":false,"resolved_by_bot":false}]' \
    '[{"fp":"r1","collision":false,"verdict":"FALSE_POSITIVE","issue":"different issue text","fix":"different fix text"}]')"

# go-kure/.github#148: prt_effective_collision, the predicate loop 1 and the
# cap walk share. Arguments: owned collision, this-run collision, owned
# content_fp, this finding's content_fp, owned resolved, evidence complete.
assert_eq "effective_collision: this-run multiplicity wins over a matching text" \
  "this_run" "$(prt_effective_collision true true aaaa aaaa false true)"
assert_eq "effective_collision: this-run multiplicity on a non-collided thread" \
  "this_run" "$(prt_effective_collision false true "" bbbb false true)"
assert_eq "effective_collision: stored content_fp differs -> content_mismatch (with or without a persisted flag)" \
  "content_mismatch content_mismatch" "$(prt_effective_collision true false aaaa bbbb false true) $(prt_effective_collision false false aaaa bbbb false true)"
assert_eq "effective_collision: persisted flag + identical text, open thread, complete evidence -> lift" \
  "lift" "$(prt_effective_collision true false aaaa aaaa false true)"
assert_eq "effective_collision: persisted flag, no stored content_fp -> persisted (unverifiable, never lifts)" \
  "persisted" "$(prt_effective_collision true false "" aaaa false true)"
assert_eq "effective_collision: persisted flag + identical text on a resolved thread -> persisted (only open threads lift)" \
  "persisted" "$(prt_effective_collision true false aaaa aaaa true true)"
assert_eq "effective_collision: persisted flag + identical text, incomplete evidence -> persisted" \
  "persisted persisted" "$(prt_effective_collision true false aaaa aaaa false false) $(prt_effective_collision true false aaaa aaaa false "")"
assert_eq "effective_collision: no flag, matching or absent content_fp -> none" \
  "none none" "$(prt_effective_collision false false aaaa aaaa false true) $(prt_effective_collision false false "" aaaa false true)"
assert_eq "effective_collision: only the literal 'true' sets a flag" \
  "none" "$(prt_effective_collision null null "" aaaa false true)"

# The cap walk predicts the lift, and its refusals. A bot-resolved thread
# with a persisted flag, whose finding is back with identical text: only
# open threads lift, so it stays quarantined and resolved -> reserves 0
# (lifted, row 7 would reopen it and reserve 1).
# shellcheck disable=SC2034  # read by prt_reserved_count in reconcile.sh (source=/dev/null above, so shellcheck can't see the cross-file read)
PRT_LIFT_EVIDENCE_COMPLETE=true
lift_walk_cfp="$(prt_content_fp 'lift issue' 'lift fix')"
assert_eq "reserved_count #148: persisted bot-resolved thread with its finding back -> not lifted, reserves 0" \
  "0" "$(prt_reserved_count \
    "[{\"fp\":\"r1\",\"collision\":true,\"resolved\":true,\"resolved_by_bot\":true,\"content_fp\":\"$lift_walk_cfp\"}]" \
    '[{"fp":"r1","collision":false,"verdict":"VALID","issue":"lift issue","fix":"lift fix"}]')"
assert_eq "reserved_count #148: same, no stored content_fp -> persisted, quarantined resolved -> reserves 0" \
  "0" "$(prt_reserved_count \
    '[{"fp":"r1","collision":true,"resolved":true,"resolved_by_bot":true}]' \
    '[{"fp":"r1","collision":false,"verdict":"VALID","issue":"lift issue","fix":"lift fix"}]')"
# An open thread lifted to a FALSE_POSITIVE verdict would resolve (row 3,
# non-gating) — but if loop 1's persist fails it stays quarantined and
# open, i.e. gating. The walk reserves for the worse case.
assert_eq "reserved_count #148: lifted open thread, FALSE_POSITIVE verdict -> still reserves 1 (persist may fail)" \
  "1" "$(prt_reserved_count \
    "[{\"fp\":\"r1\",\"collision\":true,\"resolved\":false,\"resolved_by_bot\":false,\"content_fp\":\"$lift_walk_cfp\"}]" \
    '[{"fp":"r1","collision":false,"verdict":"FALSE_POSITIVE","issue":"lift issue","fix":"lift fix"}]')"
assert_eq "reserved_count #148: control — non-collided open thread, FALSE_POSITIVE verdict -> reserves 0" \
  "0" "$(prt_reserved_count \
    "[{\"fp\":\"r1\",\"collision\":false,\"resolved\":false,\"resolved_by_bot\":false,\"content_fp\":\"$lift_walk_cfp\"}]" \
    '[{"fp":"r1","collision":false,"verdict":"FALSE_POSITIVE","issue":"lift issue","fix":"lift fix"}]')"

# --- Regression scenario 1: reordered severities across reruns must not
# un-reserve an already-gating thread (iteration 3/4/5's bug). 5 OWNED open
# threads matched to low-priority findings, 7 brand-new high-priority
# candidates, cap 5. ---
r1_owned='[{"fp":"o1","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o2","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o3","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o4","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o5","collision":false,"resolved":false,"resolved_by_bot":false}]'
r1_findings='[{"fp":"o1","collision":false,"verdict":"VALID","severity":"Low"},
              {"fp":"o2","collision":false,"verdict":"VALID","severity":"Low"},
              {"fp":"o3","collision":false,"verdict":"VALID","severity":"Low"},
              {"fp":"o4","collision":false,"verdict":"VALID","severity":"Low"},
              {"fp":"o5","collision":false,"verdict":"VALID","severity":"Low"},
              {"fp":"n1","collision":false,"verdict":"VALID","severity":"Critical"},
              {"fp":"n2","collision":false,"verdict":"VALID","severity":"Critical"},
              {"fp":"n3","collision":false,"verdict":"VALID","severity":"Critical"},
              {"fp":"n4","collision":false,"verdict":"VALID","severity":"Critical"},
              {"fp":"n5","collision":false,"verdict":"VALID","severity":"Critical"},
              {"fp":"n6","collision":false,"verdict":"VALID","severity":"Critical"},
              {"fp":"n7","collision":false,"verdict":"VALID","severity":"Critical"}]'
assert_eq "reserved_count: reordered-severity scenario reserves all 5 open OWNED threads" \
  "5" "$(prt_reserved_count "$r1_owned" "$r1_findings")"
# go-kure/.github#268: the 5 open threads still reserve (they stay gating),
# but they no longer hold their slots against new findings that outrank them:
# the 7 Criticals compete for the first 5 places, so exactly 5 of them get a
# thread, never all 7 (per run, growth stays within the cap).
r1_capped="$(prt_apply_cap 5 "$r1_owned" "$r1_findings")"
assert_eq "apply_cap #268: 5 open Low threads + 7 new Critical — exactly 5 new findings within_cap" \
  "5" "$(jq '[.[] | select((.fp | startswith("n")) and .within_cap == true)] | length' <<< "$r1_capped")"
assert_eq "apply_cap #268: and they are the first 5 in input order (a stable sort among equals)" \
  "n1 n2 n3 n4 n5" "$(jq -r '[.[] | select(.within_cap == true) | .fp] | join(" ")' <<< "$r1_capped")"
r1_same_sev="$(jq -c 'map(.severity = "Critical")' <<< "$r1_findings")"
assert_eq "apply_cap #268: the same 5 open threads at Critical — none of the 7 new Criticals within_cap (ties go to the open threads)" \
  "0" "$(jq '[.[] | select((.fp | startswith("n")) and .within_cap == true)] | length' <<< "$(prt_apply_cap 5 "$r1_owned" "$r1_same_sev")")"

# --- Regression scenario 2: persisted open collision thread with no
# matching finding this run, plus 5 new eligible findings, cap 5. Must
# reserve exactly 1, not be excluded from reservation entirely. ---
r2_owned='[{"fp":"c1","collision":true,"resolved":false,"resolved_by_bot":false}]'
r2_findings='[{"fp":"n1","collision":false,"verdict":"VALID","severity":"High"},
              {"fp":"n2","collision":false,"verdict":"VALID","severity":"High"},
              {"fp":"n3","collision":false,"verdict":"VALID","severity":"Medium"},
              {"fp":"n4","collision":false,"verdict":"VALID","severity":"Medium"},
              {"fp":"n5","collision":false,"verdict":"VALID","severity":"Low"}]'
assert_eq "reserved_count: persisted open collision thread reserves 1" \
  "1" "$(prt_reserved_count "$r2_owned" "$r2_findings")"
r2_capped="$(prt_apply_cap 5 "$r2_owned" "$r2_findings")"
assert_eq "apply_cap: persisted collision + 5 new -> 4 within_cap (1+4=5, not 6)" \
  "4" "$(jq '[.[] | select(.within_cap == true)] | length' <<< "$r2_capped")"

# --- Regression scenario 3: an open thread newly assessed FALSE_POSITIVE
# frees its slot for a new candidate. ---
r3_owned='[{"fp":"o1","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o2","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o3","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o4","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o5","collision":false,"resolved":false,"resolved_by_bot":false}]'
r3_findings='[{"fp":"o1","collision":false,"verdict":"VALID","severity":"Critical"},
              {"fp":"o2","collision":false,"verdict":"VALID","severity":"Critical"},
              {"fp":"o3","collision":false,"verdict":"VALID","severity":"Critical"},
              {"fp":"o4","collision":false,"verdict":"VALID","severity":"Critical"},
              {"fp":"o5","collision":false,"verdict":"FALSE_POSITIVE","severity":"Critical"},
              {"fp":"n1","collision":false,"verdict":"VALID","severity":"Critical"},
              {"fp":"n2","collision":false,"verdict":"VALID","severity":"High"},
              {"fp":"n3","collision":false,"verdict":"VALID","severity":"Medium"}]'
assert_eq "reserved_count: FALSE_POSITIVE frees a slot -> reserved drops to 4" \
  "4" "$(prt_reserved_count "$r3_owned" "$r3_findings")"
r3_capped="$(prt_apply_cap 5 "$r3_owned" "$r3_findings")"
assert_eq "apply_cap: FALSE_POSITIVE frees exactly one new finding within_cap" \
  "1" "$(jq '[.[] | select((.fp | startswith("n")) and .within_cap == true)] | length' <<< "$r3_capped")"

# --- Regression scenario 3b (go-kure/.github#177): identical to scenario 3
# except o5's thread carries a human reply -- row 3's new guard now leaves
# it open (NONE, not REPLY_RESOLVE), so it must keep reserving its slot
# instead of freeing it. A pre-registered discriminating control: this
# fixture differs from scenario 3 above by exactly one field
# (has_human_reply:true on o5), and the two arms must print DIFFERENT
# counts (5 here vs 4 above) -- a fixture that passed the same either way
# would prove nothing about the guard actually firing. ---
r3b_owned='[{"fp":"o1","collision":false,"resolved":false,"resolved_by_bot":false},
            {"fp":"o2","collision":false,"resolved":false,"resolved_by_bot":false},
            {"fp":"o3","collision":false,"resolved":false,"resolved_by_bot":false},
            {"fp":"o4","collision":false,"resolved":false,"resolved_by_bot":false},
            {"fp":"o5","collision":false,"resolved":false,"resolved_by_bot":false,"has_human_reply":true}]'
assert_eq "reserved_count: FALSE_POSITIVE with human reply -> does NOT free the slot (go-kure/.github#177)" \
  "5" "$(prt_reserved_count "$r3b_owned" "$r3_findings")"
r3b_capped="$(prt_apply_cap 5 "$r3b_owned" "$r3_findings")"
assert_eq "apply_cap: human-reply-protected FALSE_POSITIVE leaves zero new findings within_cap" \
  "0" "$(jq '[.[] | select((.fp | startswith("n")) and .within_cap == true)] | length' <<< "$r3b_capped")"

# --- Regression scenario 4: absent-but-still-open thread reserves; absent
# resolved-by-bot does NOT (codex round 1 finding P1-2 — this specific
# combination is what an unconditional prt_decide_finding call on the
# absent branch would get wrong: verdict defaults to NONE, thread_resolved
# =true, resolved_by_bot=true reaches row 7/REPLY_UNRESOLVE, which
# prt_thread_stays_gating counts as gating). A resolved_by_bot:false
# (human-resolved) absent variant is kept too, for completeness. ---
assert_eq "reserved_count: absent, still open -> reserves" \
  "1" "$(prt_reserved_count \
    '[{"fp":"a1","collision":false,"resolved":false,"resolved_by_bot":false}]' '[]')"
assert_eq "reserved_count: absent, resolved_by_bot:true -> does NOT reserve (P1-2)" \
  "0" "$(prt_reserved_count \
    '[{"fp":"a2","collision":false,"resolved":true,"resolved_by_bot":true}]' '[]')"
assert_eq "reserved_count: absent, human-resolved (resolved_by_bot:false) -> does not reserve" \
  "0" "$(prt_reserved_count \
    '[{"fp":"a3","collision":false,"resolved":true,"resolved_by_bot":false}]' '[]')"

# --- Regression scenario 5: over-reservation clamps remaining to 0, never
# negative. ---
r5_owned='[{"fp":"o1","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o2","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o3","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o4","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o5","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o6","collision":false,"resolved":false,"resolved_by_bot":false},
           {"fp":"o7","collision":false,"resolved":false,"resolved_by_bot":false}]'
r5_findings='[{"fp":"n1","collision":false,"verdict":"VALID","severity":"Medium"}]'
assert_eq "reserved_count: 7 open OWNED threads, cap 5 -> reserved is still 7 (not clamped here)" \
  "7" "$(prt_reserved_count "$r5_owned" "$r5_findings")"
r5_capped="$(prt_apply_cap 5 "$r5_owned" "$r5_findings")"
assert_eq "apply_cap: over-reservation, a new candidate the open threads are not below -> never within_cap" \
  "false" "$(jq -r '.[] | select(.fp == "n1") | .within_cap' <<< "$r5_capped")"
# go-kure/.github#268: the 7 absent threads state no severity, so they rank as
# the lowest known one (Medium); a new Critical outranks all 7.
r5_critical="$(prt_apply_cap 5 "$r5_owned" '[{"fp":"n1","collision":false,"verdict":"VALID","severity":"Critical"}]')"
assert_eq "apply_cap #268: over-reservation by threads of no stated severity, a new Critical -> within_cap" \
  "true" "$(jq -r '.[] | select(.fp == "n1") | .within_cap' <<< "$r5_critical")"

# --- go-kure/.github#268: a new finding that outranks the open threads holding
# the cap gets a thread. Cap 5. ---
t268_open() { # SEVERITY N [FIELD] -> N open owned rows; FIELD=severity puts SEVERITY on the row itself (an absent finding's thread body)
  jq -nc --arg s "$1" --argjson n "$2" --arg field "${3:-}" \
    '[range($n) | {fp:"o\(.)",collision:false,resolved:false,resolved_by_bot:false} + (if $field == "severity" then {severity:$s} else {} end)]'
}
t268_matched() { # SEVERITY N -> N findings matching t268_open's rows
  jq -nc --arg s "$1" --argjson n "$2" '[range($n) | {fp:"o\(.)",collision:false,verdict:"VALID",severity:$s}]'
}
t268_within() { # CAP OWNED FINDINGS -> the within_cap fps among the new (n*) findings
  prt_apply_cap "$1" "$2" "$3" | jq -r '[.[] | select((.fp | startswith("n")) and .within_cap == true) | .fp] | join(" ")'
}
t268_new_crit='{"fp":"n1","collision":false,"verdict":"VALID","severity":"Critical"}'
t268_new_med='{"fp":"n2","collision":false,"verdict":"VALID","severity":"Medium"}'
assert_eq "apply_cap #268: 5 open Medium threads + a new Critical -> the Critical within_cap, a new Medium not" \
  "n1" "$(t268_within 5 "$(t268_open x 5)" "$(jq -c ". + [$t268_new_crit, $t268_new_med]" <<< "$(t268_matched Medium 5)")")"
assert_eq "apply_cap #268: and the 5 Medium threads still reserve" \
  "5" "$(prt_reserved_count "$(t268_open x 5)" "$(jq -c ". + [$t268_new_crit]" <<< "$(t268_matched Medium 5)")")"
assert_eq "reserved_ranks #268: a matched thread ranks by this run's finding, an absent one by its body, unknown as the lowest known" \
  "[2,0,2,99]" "$(prt_reserved_ranks \
    '[{"fp":"m","collision":false,"resolved":false,"resolved_by_bot":false,"severity":"Critical"},{"fp":"a","collision":false,"resolved":false,"resolved_by_bot":false,"severity":"critical"},{"fp":"u","collision":false,"resolved":false,"resolved_by_bot":false},{"fp":"l","collision":false,"resolved":false,"resolved_by_bot":false,"severity":"Low"}]' \
    '[{"fp":"m","collision":false,"verdict":"VALID","severity":"Medium"}]')"
assert_eq "apply_cap #268: 5 absent threads whose bodies say Critical -> a new Critical not within_cap" \
  "" "$(t268_within 5 "$(t268_open Critical 5 severity)" "[$t268_new_crit]")"
assert_eq "apply_cap #268: 5 absent threads whose bodies say High -> a new Critical within_cap" \
  "n1" "$(t268_within 5 "$(t268_open High 5 severity)" "[$t268_new_crit]")"
t268_foreign="$(jq -nc '[range(5) | {fp:"f\(.)",foreign:true,author:"kure-bot",resolved:false,severity:"Critical"}]')"
assert_eq "apply_cap #268: 5 open foreign threads (a stated severity is untrusted) -> a new Critical within_cap, a new Medium not" \
  "n1" "$(t268_within 5 "$t268_foreign" "[$t268_new_crit, $t268_new_med]")"
assert_eq "apply_cap #268: 3 open High + 1 open Critical thread, new High, Critical, Critical, Medium -> only the two Criticals (2nd and 3rd, behind the Critical thread; the High comes 6th)" \
  "n2 n3" "$(t268_within 5 "$(jq -c '. + [{"fp":"oc","collision":false,"resolved":false,"resolved_by_bot":false}]' <<< "$(t268_open x 3)")" \
    "$(jq -c '. + [{"fp":"oc","collision":false,"verdict":"VALID","severity":"Critical"},{"fp":"n1","collision":false,"verdict":"VALID","severity":"High"},{"fp":"n2","collision":false,"verdict":"VALID","severity":"Critical"},{"fp":"n3","collision":false,"verdict":"VALID","severity":"Critical"},{"fp":"n4","collision":false,"verdict":"VALID","severity":"Medium"}]' <<< "$(t268_matched High 3)")")"
assert_eq "severity_rank #268: listed (any case), unlisted, and empty" \
  "0 1 99 2" "$(prt_severity_rank Critical '{"critical":0,"high":1,"medium":2}') $(prt_severity_rank HIGH '{"critical":0,"high":1,"medium":2}') $(prt_severity_rank Low '{"critical":0,"high":1,"medium":2}') $(prt_severity_rank '' '{"critical":0,"high":1,"medium":2}')"
assert_eq "finding_body_severity #268: reads back what prt_render_finding_body wrote" \
  "High" "$(prt_finding_body_severity "$(prt_render_finding_body '{"file":"a","category":"Bug · edge","line":1,"severity":"High","issue":"i","fix":"f","fp":"x"}' '<!-- marker -->')")"
assert_eq "finding_body_severity #268: a body without that line, or with CRLF line ends" \
  "|Medium" "$(prt_finding_body_severity $'<!-- m -->\nplain text')|$(prt_finding_body_severity $'<!-- m -->\r\n**Medium · Bug**\r\n')"
assert_eq "finding_body_severity #268: a one-line body, and a two-line body with no trailing newline" \
  "|Critical" "$(prt_finding_body_severity '**High · Bug**')|$(prt_finding_body_severity $'<!-- m -->\n**Critical · Bug**')"
# A failing text tool must not turn a stated Critical into "no severity" (which
# ranks it Medium): the read runs no subprocess at all.
# The stubs are called only if the function under test runs one of those tools.
# shellcheck disable=SC2329
assert_eq "finding_body_severity #268: still Critical when every text tool fails" \
  "Critical" "$(sed() { return 1; }; awk() { return 1; }; head() { return 1; }; tail() { return 1; }
    cut() { return 1; }; grep() { return 1; }; tr() { return 1; }
    prt_finding_body_severity $'<!-- m -->\n**Critical · Bug**\n')"

# --- prt_gating_eligible: excludes OWNED-matched fps, collisions, and
# FALSE_POSITIVE; keeps verdict:null; sorts mixed-case severities correctly
# (the N-h regression); unknown severity sorts last via // 99. ---
ge_owned='[{"fp":"h","collision":false,"resolved":false,"resolved_by_bot":false}]'
ge_findings='[{"fp":"a","collision":false,"verdict":"VALID","severity":"Medium"},
              {"fp":"b","collision":false,"verdict":"FALSE_POSITIVE","severity":"High"},
              {"fp":"c","collision":true,"verdict":"VALID","severity":"High"},
              {"fp":"d","collision":false,"verdict":null,"severity":"Low"},
              {"fp":"e","collision":false,"verdict":"VALID","severity":"HIGH"},
              {"fp":"f","collision":false,"verdict":"VALID","severity":"critical"},
              {"fp":"g","collision":false,"verdict":"PARTIALLY_VALID","severity":"Unknown"},
              {"fp":"h","collision":false,"verdict":"VALID","severity":"Medium"}]'
sev_rank='{"critical":0,"high":1,"medium":2}'
ge_out="$(prt_gating_eligible "$ge_findings" "$ge_owned" "$sev_rank")"
assert_eq "gating_eligible: excludes FALSE_POSITIVE, collision, and OWNED-matched fp; keeps null" \
  "5" "$(jq 'length' <<< "$ge_out")"
assert_eq "gating_eligible: sorted critical, HIGH(mixed-case), Medium, then unranked in original order" \
  "f e a d g" "$(jq -r '[.[].fp] | join(" ")' <<< "$ge_out")"

# --- prt_apply_cap fp-substring trap: a base fp must not read as within_cap
# just because an unrelated ordinal-suffixed sibling fp was capped (the
# IN()-vs-inside() bug, currently-untested before this). ---
trap_findings='[{"fp":"abc123","collision":false,"verdict":"VALID","severity":"Medium"},
                {"fp":"abc123-2","collision":false,"verdict":"VALID","severity":"Critical"}]'
trap_out="$(prt_apply_cap 1 '[]' "$trap_findings")"
assert_eq "apply_cap: fp-substring trap — base fp stays within_cap:false when only the sibling is capped" \
  "false" "$(jq -r '.[] | select(.fp == "abc123") | .within_cap' <<< "$trap_out")"
assert_eq "apply_cap: fp-substring trap — the sibling itself is within_cap:true" \
  "true" "$(jq -r '.[] | select(.fp == "abc123-2") | .within_cap' <<< "$trap_out")"

# OWNED itself can exceed MAX_ARG_STRLEN even when every individual row is
# modest. Cap eligibility must consume the whole collection from stdin and
# still reserve/rank exactly as it does for a small inventory.
printf -v owned_large_filler '%*s' 8000 ''
owned_large_filler="${owned_large_filler// /x}"
owned_large='['
for ((owned_i = 0; owned_i < 20; owned_i++)); do
  [ "$owned_i" -eq 0 ] || owned_large+=','
  owned_large+="{\"fp\":\"owned-$owned_i\",\"resolved\":true,\"thread_id\":\"$owned_large_filler\"}"
done
owned_large+=']'
large_cap_findings='[{"fp":"new-critical","collision":false,"verdict":"VALID","severity":"Critical"},
                     {"fp":"new-high","collision":false,"verdict":"VALID","severity":"High"},
                     {"fp":"new-medium","collision":false,"verdict":"VALID","severity":"Medium"}]'
large_cap_out="$(prt_apply_cap 2 "$owned_large" "$large_cap_findings")"
assert_eq "apply_cap: OWNED collection exceeds the kernel single-argument limit" "true" \
  "$([ "${#owned_large}" -gt 131072 ] && echo true || echo false)"
assert_eq "apply_cap: oversized OWNED collection still yields the correct cap result" "2" \
  "$(jq '[.[] | select(.within_cap == true)] | length' <<< "$large_cap_out")"
unset owned_large_filler owned_large large_cap_findings large_cap_out

# ============================================================ mode resolution (mirrors pr-review-threads.sh's own case statement)
resolve_mode() {
  local mode="$1"
  case "$mode" in
    enforce|advisory|off) echo "$mode" ;;
    *) echo "advisory" ;;
  esac
}
assert_eq "mode resolution: enforce passes through" "enforce" "$(resolve_mode enforce)"
assert_eq "mode resolution: advisory passes through" "advisory" "$(resolve_mode advisory)"
assert_eq "mode resolution: off passes through" "off" "$(resolve_mode off)"
assert_eq "mode resolution: a typo degrades to advisory, never to enforce" "advisory" "$(resolve_mode enfroce)"
assert_eq "mode resolution: empty string degrades to advisory" "advisory" "$(resolve_mode "")"

# ============================================================ gh.sh: rate-limit-as-200 classification (mocked curl)
fake_curl_ratelimited() {
  # Emulates HTTP 200 with a GraphQL errors[] body — the documented trap
  # where status code alone is not a reliable failure signal.
  local out=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    if [ "${args[$ai]}" = "-o" ]; then out="${args[$((ai + 1))]}"; fi
  done
  printf '{"data":null,"errors":[{"message":"API rate limit exceeded"}]}' > "$out"
  echo 200
}
PRT_CURL=fake_curl_ratelimited PRT_GH_TOKEN=x prt_gh_graphql 'query{viewer{login}}' '{}' >/dev/null 2>&1
assert_eq "gh.sh: HTTP 200 with errors[] is classified as failure, not success" "1" "$?"
# A failed errors[] query must not read as "no errors": the body carries a populated errors[] and
# the query that looks for it fails, so the response is not a success and its .data is not printed.
gql_fault_out="$(
  # shellcheck disable=SC2329,SC2317
  jq() {
    case "$*" in *'.errors // empty'*) return 5 ;; esac
    command jq "$@"
  }
  PRT_CURL=fake_curl_ratelimited PRT_GH_TOKEN=x prt_gh_graphql 'query{viewer{login}}' '{}' 2>/dev/null
  echo "rc=$?"
)"
assert_eq "gh.sh: a failed errors[] query is a failure, not 'no errors' (no .data printed)" "rc=1" "$gql_fault_out"
unset gql_fault_out

# go-kure/.github#256: a rate-limited isResolved re-read inside a lift's
# prt_retry must leave its Retry-After where prt_retry reads it.
fake_curl_graphql_429() {
  local out="" hdrs=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    if [ "${args[$ai]}" = "-o" ]; then out="${args[$((ai + 1))]}"; fi
    if [ "${args[$ai]}" = "-D" ]; then hdrs="${args[$((ai + 1))]}"; fi
  done
  printf 'retry-after: 17\r\n' > "$hdrs"
  printf '{"message":"secondary rate limit"}' > "$out"
  echo 429
}
assert_eq "gh.sh: a rate-limited resolved-state re-read returns 5 and keeps its Retry-After" \
  "5 17" "$(PRT_LAST_RETRY_AFTER=""; PRT_CURL=fake_curl_graphql_429 PRT_GH_TOKEN=x \
    prt_gh_rest_fresh_open T1 PATCH o/r 1 sha /x '{}' 2>/dev/null; echo "$? $PRT_LAST_RETRY_AFTER")"

# ============================================================ gh.sh: prt_freshness_check names which failure happened (C4, dot-github#61 Step 2)
fake_curl_freshness_moved() {
  local out=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    if [ "${args[$ai]}" = "-o" ]; then out="${args[$((ai + 1))]}"; fi
  done
  printf '{"head":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}' > "$out"
  echo 200
}
fresh_err="$(PRT_CURL=fake_curl_freshness_moved PRT_GH_TOKEN=x \
  prt_freshness_check owner/repo 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1 >/dev/null)"
rc=$?
assert_eq "prt_freshness_check: a genuinely moved head names expected -> live" \
  "true" "$(grep -qF 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -> bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' <<< "$fresh_err" && echo true || echo false)"
# go-kure/.github#99: a genuinely-moved head is now its OWN status (1),
# distinct from a read failure/malformed response (2) — this is the case a
# caller may safely route to prt_mark_degraded + exit 0.
assert_eq "prt_freshness_check: genuinely-moved head returns 1 (the degradable case)" "1" "$rc"

fake_curl_freshness_500() {
  local out=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    if [ "${args[$ai]}" = "-o" ]; then out="${args[$((ai + 1))]}"; fi
  done
  : > "$out"
  echo 500
}
fresh_err="$(PRT_CURL=fake_curl_freshness_500 PRT_GH_TOKEN=x \
  prt_freshness_check owner/repo 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1 >/dev/null)"
rc=$?
# go-kure/.github#99: a read failure can no longer read as "stale" (1) — it
# gets its own status (2), which stays fatal at every call site regardless
# of the genuinely-stale case's new degraded routing.
assert_eq "prt_freshness_check: read failure returns 2 (distinct from genuinely-stale, still fatal)" "2" "$rc"
assert_eq "prt_freshness_check: read failure gets its own diagnostic, distinct from the moved-head one" \
  "true" "$(grep -qF 'failed to read PR' <<< "$fresh_err" && echo true || echo false)"

fake_curl_freshness_malformed() {
  local out=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    if [ "${args[$ai]}" = "-o" ]; then out="${args[$((ai + 1))]}"; fi
  done
  # 2xx, but the body has no .head.sha at all — a malformed/unexpected
  # response shape, not a moved head (go-kure/.github#99).
  printf '{"title":"t"}' > "$out"
  echo 200
}
fresh_err="$(PRT_CURL=fake_curl_freshness_malformed PRT_GH_TOKEN=x \
  prt_freshness_check owner/repo 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1 >/dev/null)"
rc=$?
assert_eq "prt_freshness_check: a 2xx response with no .head.sha also returns 2, not 1" "2" "$rc"
assert_eq "prt_freshness_check: malformed-response diagnostic names the missing field" \
  "true" "$(grep -qF 'had no .head.sha' <<< "$fresh_err" && echo true || echo false)"

# go-kure/.github#99 codex round 1 finding: a non-empty .head.sha that is NOT
# a well-formed 40-hex SHA must not fall through to the mismatch branch and
# be misread as "genuinely moved" — it carries no guarantee a superseding
# run is actually queued, so it must return 2 (fatal), same as an empty one.
fake_curl_freshness_nonhex() {
  local out=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    if [ "${args[$ai]}" = "-o" ]; then out="${args[$((ai + 1))]}"; fi
  done
  printf '{"head":{"sha":"not-a-40-hex-sha"}}' > "$out"
  echo 200
}
fresh_err="$(PRT_CURL=fake_curl_freshness_nonhex PRT_GH_TOKEN=x \
  prt_freshness_check owner/repo 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1 >/dev/null)"
rc=$?
assert_eq "prt_freshness_check: a non-40-hex .head.sha returns 2, NOT 1 (must not read as genuinely-stale)" "2" "$rc"
assert_eq "prt_freshness_check: non-40-hex diagnostic names the malformed value" \
  "true" "$(grep -qF "not a well-formed 40-hex SHA: 'not-a-40-hex-sha'" <<< "$fresh_err" && echo true || echo false)"

# ============================================================ gh.sh: prt_gh_rest_fresh propagates a 4-way status (go-kure/.github#99)
fake_curl_fresh_write_fail() {
  # Freshness check passes (returns the expected SHA), but the wrapped
  # write itself (the PATCH) fails with a 500 — must surface as status 3,
  # distinct from either freshness outcome.
  local out="" method=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    case "${args[$ai]}" in
      -o) out="${args[$((ai + 1))]}" ;;
      -X) method="${args[$((ai + 1))]}" ;;
    esac
  done
  if [ "$method" = GET ]; then
    printf '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' > "$out"
    echo 200
  else
    : > "$out"
    echo 500
  fi
}
PRT_CURL=fake_curl_fresh_write_fail PRT_GH_TOKEN=x \
  prt_gh_rest_fresh PATCH owner/repo 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa /repos/owner/repo/pulls/comments/1 '{}' >/dev/null 2>&1
assert_eq "prt_gh_rest_fresh: fresh head but the write itself fails -> status 3 (not 1 or 2)" "3" "$?"

PRT_CURL=fake_curl_freshness_moved PRT_GH_TOKEN=x \
  prt_gh_rest_fresh PATCH owner/repo 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa /repos/owner/repo/pulls/comments/1 '{}' >/dev/null 2>&1
assert_eq "prt_gh_rest_fresh: genuinely-stale head short-circuits with status 1, write never attempted" "1" "$?"

PRT_CURL=fake_curl_freshness_500 PRT_GH_TOKEN=x \
  prt_gh_rest_fresh PATCH owner/repo 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa /repos/owner/repo/pulls/comments/1 '{}' >/dev/null 2>&1
assert_eq "prt_gh_rest_fresh: freshness read failure short-circuits with status 2, write never attempted" "2" "$?"

# ============================================================ gh.sh: prt_find_marked_comment (mocked curl, clean-verdict comment, 2026-08-22)
fake_curl_find_marked_single_page() {
  local out="" url=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    case "${args[$ai]}" in
      -o) out="${args[$((ai + 1))]}" ;;
      http://*|https://*) url="${args[$ai]}" ;;
    esac
  done
  case "$url" in
    # "&page=1", not "page=1" — "per_page=100" is itself always present in
    # every request this function makes and contains "page=1" as a bare
    # substring, so an unanchored "page=1" match would fire on every page
    # forever and this fake would never terminate the caller's pagination
    # loop (caught by a hang in this exact test during development).
    *'&page=1'*)
      cat > "$out" <<'JSON'
[
  {"id":111,"user":{"login":"other-bot"},"body":"hello <!-- gokure-pr-review:v1-clean --> world"},
  {"id":222,"user":{"login":"gokure-pr-review[bot]"},"body":"unrelated comment, no marker"},
  {"id":333,"user":{"login":"gokure-pr-review[bot]"},"body":"pre <!-- gokure-pr-review:v1-clean --> post"}
]
JSON
      ;;
    *) printf '[]' > "$out" ;;
  esac
  echo 200
}
found_id="$(PRT_CURL=fake_curl_find_marked_single_page PRT_GH_TOKEN=x \
  prt_find_marked_comment owner/repo 9 '<!-- gokure-pr-review:v1-clean -->' 'gokure-pr-review[bot]')"
assert_eq "prt_find_marked_comment: matches on marker AND bot login, skipping a same-marker comment from a different login" \
  "333" "$found_id"

# go-kure/.github#153: with a FOREIGN_OUT_FILE the same lookup still returns
# only the own comment, and lists the other login's marked comment.
find_foreign_out="$(mktemp)"
found_id="$(PRT_CURL=fake_curl_find_marked_single_page PRT_GH_TOKEN=x \
  prt_find_marked_comment owner/repo 9 '<!-- gokure-pr-review:v1-clean -->' 'gokure-pr-review[bot]' "$find_foreign_out")"
assert_eq "prt_find_marked_comment #153: with a foreign-out file -> still returns only the own comment's id" \
  "333" "$found_id"
assert_eq "prt_find_marked_comment #153: the other login's marked comment is listed as id<TAB>login, the unmarked one is not" \
  "$(printf '111\tother-bot')" "$(cat "$find_foreign_out")"

# Every page is read once a foreign-out file is given: the own match on page 1
# must not hide a foreign one on page 2. A superseded foreign comment is not
# listed; an unmarked one never is.
fake_curl_find_marked_foreign_pages() {
  local out="" url=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    case "${args[$ai]}" in
      -o) out="${args[$((ai + 1))]}" ;;
      http://*|https://*) url="${args[$ai]}" ;;
    esac
  done
  if [[ "$url" == *'&page=1'* ]]; then
    { printf '[{"id":5,"user":{"login":"gokure-pr-review[bot]"},"body":"<!-- gokure-pr-review:v1-clean -->"}'
      for ((pi = 100; pi < 199; pi++)); do
        printf ',{"id":%d,"user":{"login":"someone"},"body":"no marker here"}' "$pi"
      done
      printf ']'
    } > "$out"
  elif [[ "$url" == *'&page=2'* ]]; then
    printf '%s' '[{"id":700,"user":{"login":"kure-bot"},"body":"old\n<!-- gokure-pr-review:v1-clean -->"},{"id":701,"user":{"login":"kure-bot"},"body":"~~old~~\n<!-- gokure-pr-review:state=superseded -->\n<!-- gokure-pr-review:v1-clean -->"}]' > "$out"
  else
    printf '[]' > "$out"
  fi
  echo 200
}
: > "$find_foreign_out"
found_id="$(PRT_CURL=fake_curl_find_marked_foreign_pages PRT_GH_TOKEN=x \
  prt_find_marked_comment owner/repo 9 '<!-- gokure-pr-review:v1-clean -->' 'gokure-pr-review[bot]' "$find_foreign_out")"
assert_eq "prt_find_marked_comment #153: own match on page 1 is returned, the live foreign one on page 2 is listed, the superseded one is not" \
  "5 $(printf '700\tkure-bot')" "$found_id $(cat "$find_foreign_out")"

# R3-P2: a foreign row that cannot be enumerated or recorded is "could not
# check", never success with the own id and a short list. Own comment 88 and
# live foreign comment 99 on one page; the failure is injected into the
# foreign filter (jq shim), then into the write (the out path a directory),
# then into the page itself (not JSON).
fake_curl_find_marked_own_and_foreign() {
  local out=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    [ "${args[$ai]}" = "-o" ] && out="${args[$((ai + 1))]}"
  done
  if [ -n "${PRT_TEST_FIND_PAGE_GARBAGE:-}" ]; then
    printf 'not json' > "$out"
  else
    printf '%s' '[{"id":88,"user":{"login":"gokure-pr-review[bot]"},"body":"<!-- gokure-pr-review:v1-clean -->"},{"id":99,"user":{"login":"kure-bot"},"body":"<!-- gokure-pr-review:v1-clean -->"}]' > "$out"
  fi
  echo 200
}
find_marked_rc() ( # FOREIGN_OUT -> "rc id"
  local id rc
  id="$(PRT_CURL=fake_curl_find_marked_own_and_foreign PRT_GH_TOKEN=x \
    prt_find_marked_comment owner/repo 9 '<!-- gokure-pr-review:v1-clean -->' 'gokure-pr-review[bot]' "$1" 2>/dev/null)"
  rc=$?
  echo "$rc $id"
)
: > "$find_foreign_out"
assert_eq "prt_find_marked_comment #153 (R3-P2 control): own 88 returned, foreign 99 listed" \
  "0 88 $(printf '99\tkure-bot')" "$(find_marked_rc "$find_foreign_out") $(cat "$find_foreign_out")"
: > "$find_foreign_out"
assert_eq "prt_find_marked_comment #153 (R3-P2): the foreign filter fails -> returns 1, no id" \
  "1 " "$(
    # Invoked by find_marked_rc; the $s is the literal jq filter text.
    # shellcheck disable=SC2329,SC2016
    jq() { case "$*" in *'contains($s) | not'*) return 5 ;; esac; command jq "$@"; }
    find_marked_rc "$find_foreign_out"
  )"
find_foreign_dir="$(mktemp -d)"
assert_eq "prt_find_marked_comment #153 (R3-P2): the foreign row cannot be written -> returns 1, no id" \
  "1 " "$(find_marked_rc "$find_foreign_dir")"
rmdir "$find_foreign_dir"
assert_eq "prt_find_marked_comment (R3-P2): a page that is not JSON -> returns 1, not \"no comment yet\"" \
  "1 " "$(PRT_TEST_FIND_PAGE_GARBAGE=1 find_marked_rc "$find_foreign_out")"
unset find_foreign_dir
rm -f "$find_foreign_out"

fake_curl_find_marked_none() {
  local out=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    [ "${args[$ai]}" = "-o" ] && out="${args[$((ai + 1))]}"
  done
  printf '[]' > "$out"
  echo 200
}
found_id="$(PRT_CURL=fake_curl_find_marked_none PRT_GH_TOKEN=x \
  prt_find_marked_comment owner/repo 9 '<!-- gokure-pr-review:v1-clean -->' 'gokure-pr-review[bot]')"
find_none_rc=$?
assert_eq "prt_find_marked_comment: an empty comment list returns success (\"no comment yet\", not a failure)" \
  "0" "$find_none_rc"
assert_eq "prt_find_marked_comment: an empty comment list yields an empty id" "" "$found_id"

# Pagination: a full 100-row first page with no match must not stop the scan —
# the match lands on page 2.
fake_curl_find_marked_paginated() {
  local out="" url=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    case "${args[$ai]}" in
      -o) out="${args[$((ai + 1))]}" ;;
      http://*|https://*) url="${args[$ai]}" ;;
    esac
  done
  # "&page=N", not "page=N" — see the comment on the single-page fake above;
  # the same collision with "per_page=100" applies here.
  if [[ "$url" == *'&page=1'* ]]; then
    { printf '['
      for ((pi = 0; pi < 100; pi++)); do
        [ "$pi" -eq 0 ] || printf ','
        printf '{"id":%d,"user":{"login":"gokure-pr-review[bot]"},"body":"no marker here"}' "$pi"
      done
      printf ']'
    } > "$out"
  elif [[ "$url" == *'&page=2'* ]]; then
    printf '[{"id":999,"user":{"login":"gokure-pr-review[bot]"},"body":"<!-- gokure-pr-review:v1-clean -->"}]' > "$out"
  else
    printf '[]' > "$out"
  fi
  echo 200
}
found_id="$(PRT_CURL=fake_curl_find_marked_paginated PRT_GH_TOKEN=x \
  prt_find_marked_comment owner/repo 9 '<!-- gokure-pr-review:v1-clean -->' 'gokure-pr-review[bot]')"
assert_eq "prt_find_marked_comment: a full 100-row non-matching first page advances to page 2 instead of stopping early" \
  "999" "$found_id"

fake_curl_find_marked_fail() {
  local out=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    [ "${args[$ai]}" = "-o" ] && out="${args[$((ai + 1))]}"
  done
  : > "$out"
  echo 500
}
PRT_CURL=fake_curl_find_marked_fail PRT_GH_TOKEN=x \
  prt_find_marked_comment owner/repo 9 '<!-- gokure-pr-review:v1-clean -->' 'gokure-pr-review[bot]' >/dev/null 2>&1
assert_eq "prt_find_marked_comment: a failed paginated GET returns 1, distinct from the empty-list \"no comment yet\" case (0)" \
  "1" "$?"

# ============================================================ gh.sh: prt_upsert_issue_comment (mocked curl, clean-verdict comment, 2026-08-22)
upsert_log="$(mktemp)"
fake_curl_upsert() {
  local out="" method="" url=""
  local args=("$@")
  for ((ai = 0; ai < ${#args[@]}; ai++)); do
    case "${args[$ai]}" in
      -o) out="${args[$((ai + 1))]}" ;;
      -X) method="${args[$((ai + 1))]}" ;;
      http://*|https://*) url="${args[$ai]}" ;;
    esac
  done
  printf '%s %s\n' "$method" "$url" >> "$upsert_log"
  printf '{}' > "$out"
  echo 200
}
PRT_CURL=fake_curl_upsert PRT_GH_TOKEN=x prt_upsert_issue_comment owner/repo 9 'body text' 555 >/dev/null
PRT_CURL=fake_curl_upsert PRT_GH_TOKEN=x prt_upsert_issue_comment owner/repo 9 'body text' >/dev/null
assert_eq "prt_upsert_issue_comment: an existing id PATCHes .../issues/comments/<id>, editing in place" \
  "true" "$(grep -qF 'PATCH https://api.github.com/repos/owner/repo/issues/comments/555' "$upsert_log" && echo true || echo false)"
assert_eq "prt_upsert_issue_comment: no existing id POSTs .../issues/<pr>/comments, creating a new comment" \
  "true" "$(grep -qF 'POST https://api.github.com/repos/owner/repo/issues/9/comments' "$upsert_log" && echo true || echo false)"
rm -f "$upsert_log"

# ============================================================ render.sh: clean-verdict comment bodies (GitLab mr-review.yml parity, 2026-08-22)
clean_body="$(prt_render_clean_comment 'abc1234567890abc1234567890abc1234567890' 'claude-max' 3)"
assert_eq "prt_render_clean_comment: carries the reviewed SHA" \
  "true" "$(grep -qF 'abc1234567890abc1234567890abc1234567890' <<< "$clean_body" && echo true || echo false)"
assert_eq "prt_render_clean_comment: carries the model name" \
  "true" "$(grep -qF 'claude-max' <<< "$clean_body" && echo true || echo false)"
assert_eq "prt_render_clean_comment: carries the chunk count" \
  "true" "$(grep -qF '| chunks | 3 |' <<< "$clean_body" && echo true || echo false)"
assert_eq "prt_render_clean_comment: ends with the clean-verdict marker, so prt_find_marked_comment can find it again on the next push" \
  "$PRT_MARKER_CLEAN" "$(tail -1 <<< "$clean_body")"

superseded_body="$(prt_render_clean_comment_superseded 'def4567890def4567890def4567890def4567890' 2 2 0 0 0)"
assert_eq "prt_render_clean_comment_superseded: names the superseding SHA" \
  "true" "$(grep -qF 'def4567890def4567890def4567890def4567890' <<< "$superseded_body" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: states the finding count that superseded it" \
  "true" "$(grep -qF '2 finding(s)' <<< "$superseded_body" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: keeps the SAME marker as the original clean comment, so it is found and edited in place, not appended as a new comment" \
  "$PRT_MARKER_CLEAN" "$(tail -1 <<< "$superseded_body")"
assert_ne "prt_render_clean_comment_superseded: the superseded body is visibly distinct from a fresh clean-verdict body" \
  "$superseded_body" "$clean_body"
assert_eq "prt_render_clean_comment_superseded: threads_written>0 -> keeps 'carry the current state'" \
  "true" "$(grep -qF 'carry the current state' <<< "$superseded_body" && echo true || echo false)"

# go-kure/.github#155: threads_written=0 — every finding this run was
# suppressed/overflowed/quarantined, so no review thread exists to point at.
# "The review threads on this PR carry the current state" would be false
# here (the exact false sentence the original report was filed against);
# the zero-thread branch must state the breakdown and where to look instead.
superseded_zero_threads="$(prt_render_clean_comment_superseded 'def4567890def4567890def4567890def4567890' 3 0 1 1 1)"
assert_eq "prt_render_clean_comment_superseded: threads_written=0 -> does NOT say 'carry the current state' (criterion 4, negative half)" \
  "false" "$(grep -qF 'carry the current state' <<< "$superseded_zero_threads" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: threads_written=0 -> still names the finding count" \
  "true" "$(grep -qF '3 finding(s)' <<< "$superseded_zero_threads" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: threads_written=0 -> states the suppressed/overflow/quarantined breakdown" \
  "true" "$(grep -qF '1 suppressed' <<< "$superseded_zero_threads" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: threads_written=0 -> keeps the same clean marker" \
  "$PRT_MARKER_CLEAN" "$(tail -1 <<< "$superseded_zero_threads")"
assert_ne "prt_render_clean_comment_superseded: threads_written=0 body differs from the threads_written>0 body (criterion 4, both halves — not satisfiable by deleting the sentence unconditionally)" \
  "$superseded_zero_threads" "$superseded_body"

# go-kure/.github#180 kure-bot review: steady state — every finding this run
# matched an already-existing thread and needed no write (all NONE,
# threads_written=0), but that existing thread still carries the finding.
# Keying on threads_written alone misclassified this as "no thread carries
# them" and pointed at an advisory comment that was never posted (overflow
# and quarantined both 0 here). none_anchored>0 must take the "carry the
# current state" branch even though nothing was written this run.
superseded_none_anchored="$(prt_render_clean_comment_superseded 'def4567890def4567890def4567890def4567890' 2 0 0 0 0 2)"
assert_eq "prt_render_clean_comment_superseded: threads_written=0 but none_anchored=2 -> still says 'carry the current state' (steady state, not a loss)" \
  "true" "$(grep -qF 'carry the current state' <<< "$superseded_none_anchored" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: threads_written=0, none_anchored=2 -> does NOT emit the zero-anchor breakdown sentence" \
  "false" "$(grep -qF 'no thread on this PR carries them' <<< "$superseded_none_anchored" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: none_anchored defaults to 0 when omitted (kure-bot round 2: the prior version of this check self-compared two 6-arg calls, exercising nothing; now diffs the 6-arg call against an explicit 7-arg none_anchored=0 call so the default itself is what's under test)" \
  "$(prt_render_clean_comment_superseded 'def4567890def4567890def4567890def4567890' 3 0 1 1 1 0)" \
  "$(prt_render_clean_comment_superseded 'def4567890def4567890def4567890def4567890' 3 0 1 1 1)"

# go-kure/.github#180 codex review, two findings on the same round:
#
# (1) mixed run — some findings anchored to threads, some in the advisory
# comment (threads_written>0 AND overflow/quarantined>0). The plain "carry
# the current state" sentence would wrongly imply that's *everything*, when
# part of this run's findings are only in the separate advisory comment.
superseded_mixed="$(prt_render_clean_comment_superseded 'def4567890def4567890def4567890def4567890' 3 1 0 1 1 0)"
assert_eq "prt_render_clean_comment_superseded: mixed (threads_written=1, overflow=1, quarantined=1) -> says threads carry only PART of the state" \
  "true" "$(grep -qF 'carry part of the current state' <<< "$superseded_mixed" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: mixed -> does NOT claim threads carry the FULL current state" \
  "false" "$(grep -qF 'threads on this PR carry the current state.' <<< "$superseded_mixed" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: mixed -> still points at the advisory comment for the non-anchored part" \
  "true" "$(grep -qF 'advisory comment' <<< "$superseded_mixed" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: mixed -> states the overflow/quarantined breakdown" \
  "true" "$(grep -qF '1 beyond the gating cap' <<< "$superseded_mixed" && grep -qF '1 withheld' <<< "$superseded_mixed" && echo true || echo false)"

# (2) suppressed-only run — every finding this run was a false positive.
# SUPPRESS has no durable output surface anywhere (the overflow/advisory
# comment POST requires overflow or quarantined > 0, go-kure/.github#180
# pr-review-threads.sh:1335), so the zero-anchor breakdown branch's "See the
# advisory comment" sentence would point at a comment that was never posted.
superseded_suppressed_only="$(prt_render_clean_comment_superseded 'def4567890def4567890def4567890def4567890' 2 0 2 0 0 0)"
assert_eq "prt_render_clean_comment_superseded: suppressed-only (2 suppressed, 0 overflow, 0 quarantined, 0 anchored) -> does NOT say 'carry the current state'" \
  "false" "$(grep -qF 'carry the current state' <<< "$superseded_suppressed_only" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: suppressed-only -> does NOT point at the advisory comment (none was posted)" \
  "false" "$(grep -qF 'advisory comment' <<< "$superseded_suppressed_only" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: suppressed-only -> still names the finding count and that all were suppressed" \
  "true" "$(grep -qF '2 finding(s)' <<< "$superseded_suppressed_only" && grep -qF 'suppressed as false positives' <<< "$superseded_suppressed_only" && echo true || echo false)"

# go-kure/.github#180 codex review, round 3: a finding whose CREATE failed
# (non-422 rejection, network error) is counted in none of
# threads_written/suppressed/overflow/quarantined — count exceeds their sum.
# Before this fix, that finding fell through to the suppressed-only branch
# and was reported as "all suppressed as false positives", which is not what
# happened: the write failed, no verdict was ever rendered.
superseded_unaccounted="$(prt_render_clean_comment_superseded 'def4567890def4567890def4567890def4567890' 2 0 1 0 0 0)"
assert_eq "prt_render_clean_comment_superseded: count exceeds threads_carry+advisory_count+suppressed -> does NOT say 'all suppressed as false positives'" \
  "false" "$(grep -qF 'suppressed as false positives' <<< "$superseded_unaccounted" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: count exceeds accounted findings -> states some did not reach a durable outcome" \
  "true" "$(grep -qF 'did not' <<< "$superseded_unaccounted" && grep -qF 'not the same as being' <<< "$superseded_unaccounted" && echo true || echo false)"
# The predicate must be a substring that survives the rendered line wrap:
# render.sh splits "did not reach any durable outcome" across a newline
# ("...but N did not" / "reach any durable outcome this run..."), and grep is
# line-oriented, so the full phrase matches NO line even when the unaccounted
# branch IS taken. Keyed on the post-wrap fragment instead, and paired with a
# positive control below — a negative assertion whose predicate can never fire
# passes against the very branch it claims to exclude, asserting coverage it
# does not have (go-kure/.github#180 gmr round 1, codex lens).
assert_eq "prt_render_clean_comment_superseded: fully accounted run (count == sum of counters) -> does NOT take the unaccounted branch" \
  "false" "$(grep -qF 'reach any durable outcome' <<< "$superseded_suppressed_only" && echo true || echo false)"
# Positive control for the assertion immediately above: the same predicate must
# actually fire on the unaccounted branch, or "false" there proves nothing.
assert_eq "prt_render_clean_comment_superseded: unaccounted-branch predicate is discriminating (positive control)" \
  "true" "$(grep -qF 'reach any durable outcome' <<< "$superseded_unaccounted" && echo true || echo false)"

# go-kure/.github#180 codex review, this round: a quarantine-only run whose
# overflow/quarantine comment POST fails is REVIEW_INCOMPLETE
# (pr-review-threads.sh:1358), but the true OVERFLOW/QUARANTINED array
# lengths still get passed to this function unless the orchestrator zeroes
# them on that specific failure — args below are what the orchestrator's
# OVERFLOW_COMMENT_POSTED=false path now passes (0 0, not the true
# quarantined=1), reproducing the exact call the fixed call site makes.
# Before the fix, passing the true count (quarantined=1) here took the
# advisory_count>0 branch and falsely claimed "see the advisory comment on
# this PR" for a comment that was never posted.
superseded_overflow_post_failed="$(prt_render_clean_comment_superseded 'def4567890def4567890def4567890def4567890' 1 0 0 0 0 0)"
assert_eq "prt_render_clean_comment_superseded: overflow-comment POST failed (args zeroed) -> does NOT point at the advisory comment" \
  "false" "$(grep -qF 'advisory comment' <<< "$superseded_overflow_post_failed" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: overflow-comment POST failed (args zeroed) -> takes the unaccounted branch instead" \
  "true" "$(grep -qF 'reach any durable outcome' <<< "$superseded_overflow_post_failed" && echo true || echo false)"

# go-kure/.github#150: a superseded clean-verdict comment carries a separate
# state line directly before the identity marker, in every one of the four
# branches (unaccounted, threads-only, advisory, suppressed-only), so a
# reader can tell it from a live clean verdict without parsing the heading.
# The identity marker stays the last line (asserted per branch above), and
# the state line must never parse as a thread marker.
for superseded_case in "$superseded_unaccounted" "$superseded_body" "$superseded_mixed" "$superseded_suppressed_only"; do
  assert_eq "prt_render_clean_comment_superseded: state line sits directly before the marker ($(sed -n 3p <<< "$superseded_case" | cut -c1-40)...)" \
    "$PRT_MARKER_STATE_SUPERSEDED" "$(tail -2 <<< "$superseded_case" | head -1)"
  assert_eq "prt_render_clean_comment_superseded: identity marker is still the last line ($(sed -n 3p <<< "$superseded_case" | cut -c1-40)...)" \
    "$PRT_MARKER_CLEAN" "$(tail -1 <<< "$superseded_case")"
done
assert_eq "prt_render_clean_comment: a live clean verdict carries no superseded state line" \
  "false" "$(grep -qF "$PRT_MARKER_STATE_SUPERSEDED" <<< "$clean_body" && echo true || echo false)"
assert_eq "PRT_MARKER_STATE_SUPERSEDED: prt_marker_parse does not read the state line as a thread marker" \
  "false" "$(prt_marker_parse "$PRT_MARKER_STATE_SUPERSEDED" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "PRT_MARKER_STATE_SUPERSEDED: does not contain the clean identity marker, so the upsert lookup cannot match on it alone" \
  "false" "$(grep -qF "$PRT_MARKER_CLEAN" <<< "$PRT_MARKER_STATE_SUPERSEDED" && echo true || echo false)"

# ============================================================ render.sh: partial-review comment (go-kure/.github#151)
partial_reasons=$'review-parse-failed: chunk 0: review response was not valid JSON after retry=true (<!-- gokure-pr-review:v1-clean -->)\nchunk 1: partial-drop — one or more malformed finding row(s) dropped\nreview-parse-failed: chunk 2: review call failed (transport/proxy error, exit 7) [timeout]'
partial_body="$(prt_render_partial_comment 'abc1234567890abc1234567890abc1234567890' "$partial_reasons")"
assert_eq "prt_render_partial_comment: names the head SHA" \
  "true" "$(grep -qF 'abc1234567890abc1234567890abc1234567890' <<< "$partial_body" && echo true || echo false)"
assert_eq "prt_render_partial_comment: lists every review-parse-failed chunk, tag stripped" \
  "true true" "$(grep -qF -- '- chunk 0: review response was not valid JSON' <<< "$partial_body" && echo true || echo false) $(grep -qF -- '- chunk 2: review call failed' <<< "$partial_body" && echo true || echo false)"
assert_eq "prt_render_partial_comment: omits degraded reasons that are not parse failures" \
  "false" "$(grep -qF 'partial-drop' <<< "$partial_body" && echo true || echo false)"
assert_eq "prt_render_partial_comment: neutralizes a marker quoted inside a reason" \
  "1" "$(grep -cF '<!-- gokure-pr-review' <<< "$partial_body")"
assert_eq "prt_render_partial_comment: ends with the partial-review marker" \
  "$PRT_MARKER_PARTIAL" "$(tail -1 <<< "$partial_body")"
assert_eq "prt_render_partial_comment: carries no clean-verdict marker, so the clean lookup never finds it" \
  "false" "$(grep -qF "$PRT_MARKER_CLEAN" <<< "$partial_body" && echo true || echo false)"
partial_superseded_body="$(prt_render_partial_comment_superseded 'def4567890def4567890def4567890def4567890')"
# shellcheck disable=SC2016 # the backticks are literal markdown, not an expansion
assert_eq "prt_render_partial_comment_superseded: says the later SHA assessed every chunk" \
  "true" "$(grep -qF 'A later review of `def4567890def4567890def4567890def4567890` assessed every chunk.' <<< "$partial_superseded_body" && echo true || echo false)"
assert_eq "prt_render_partial_comment_superseded: state line directly before the marker, marker last" \
  "$PRT_MARKER_STATE_SUPERSEDED"$'\n'"$PRT_MARKER_PARTIAL" "$(tail -2 <<< "$partial_superseded_body")"
assert_eq "PRT_MARKER_PARTIAL: prt_marker_parse does not read it as a thread marker" \
  "false" "$(prt_marker_parse "$PRT_MARKER_PARTIAL" >/dev/null 2>&1 && echo true || echo false)"

# ============================================================ render.sh: prt_render_summary Line column (go-kure/.github#190)
# The job-summary table is the same content-loss class as the quarantine/
# overflow/advisory tables, even though it's ephemeral ($GITHUB_STEP_SUMMARY,
# expires with run retention) rather than durable PR-visible output.
summary_with_line="$(prt_render_summary enforce abc1234 1 '[{"fp":"deadbeef","severity":"High","category":"other","file":"y.go","line":99,"verdict":"VALID"}]' 0 '')"
assert_eq "prt_render_summary: table header carries a Line column (go-kure/.github#190)" \
  "true" "$(grep -qF '| fp | Severity | Category | File | Line | Verdict |' <<< "$summary_with_line" && echo true || echo false)"
assert_eq "prt_render_summary: row carries the finding's actual line number" \
  "true" "$(grep -qF '| y.go | 99 | VALID |' <<< "$summary_with_line" && echo true || echo false)"
summary_no_line="$(prt_render_summary enforce abc1234 1 '[{"fp":"deadbeef","severity":"High","category":"other","file":"y.go","verdict":"VALID"}]' 0 '')"
assert_eq "prt_render_summary: row with no line field renders n/a, not blank or 'null'" \
  "true" "$(grep -qF '| y.go | n/a | VALID |' <<< "$summary_no_line" && echo true || echo false)"
# kure-bot review of go-kure/.github#191: the Line column bypassed the esc filter every
# other model-sourced column uses, unlike a real defect in production (.line
# is always normalized to number-or-null by finding.sh before reaching any
# render.sh caller) but worth closing directly, since these render functions
# are tested in isolation from that guarantee. This table's esc (unlike the
# overflow/quarantine/advisory tables below) does NOT neutralize the marker
# prefix — deliberately, since $GITHUB_STEP_SUMMARY is never scanned by
# prt_find_marked_comment, so only the pipe escape (and the HTML entity
# encoding tested below) applies here.
summary_line_pipe_hazard="$(prt_render_summary enforce abc1234 1 '[{"fp":"deadbeef","severity":"High","category":"other","file":"y.go","line":"1 | injected","verdict":"VALID"}]' 0 '')"
assert_eq "prt_render_summary: Line cell escapes a literal pipe, not a phantom column (go-kure/.github#191 kure-bot)" \
  "true" "$(grep -qF '1 \| injected' <<< "$summary_line_pipe_hazard" && echo true || echo false)"

# go-kure/.github#183 part A: a suppressed finding (row 2, FALSE_POSITIVE with
# no thread) has no thread or comment, so the summary lists its content: the
# line and the first non-blank line of the issue and of the reasoning.
sup_json='[{"fp":"feedface","severity":"High","category":"other","file":"z.go","line":42,"issue":"\nfirst | line\nsecond line","fix":"f","verdict":"FALSE_POSITIVE","reasoning":"helper is routed elsewhere\nmore"}]'
summary_sup="$(prt_render_summary enforce abc1234 1 "$sup_json" 1 '' '' "$sup_json")"
assert_eq "prt_render_summary #183: a suppressed finding gets its own section" \
  "true" "$(grep -qF '### Suppressed findings (FALSE POSITIVE, no thread created)' <<< "$summary_sup" && echo true || echo false)"
assert_eq "prt_render_summary #183: the row carries fp, line, the issue's first line (pipe escaped) and the reasoning's first line" \
  "true" "$(grep -qF "| \`feedface\` | High | z.go | 42 | first \\| line | helper is routed elsewhere |" <<< "$summary_sup" && echo true || echo false)"
assert_eq "prt_render_summary #183: later lines of the issue are not rendered" \
  "false" "$(grep -qF 'second line' <<< "$summary_sup" && echo true || echo false)"
assert_eq "prt_render_summary #183: no suppressed findings -> no section" \
  "false" "$(grep -qF 'Suppressed findings' <<< "$summary_with_line" && echo true || echo false)"
# Raw HTML in a finding-derived cell would close the table it sits in, so
# both tables entity-encode &, < and > (#183 review).
html_hazard='</td></tr></tbody></table><h2>x</h2> & co'
html_json="$(jq -nc --arg h "$html_hazard" '[{fp:"feedface",severity:$h,category:$h,file:$h,line:$h,issue:$h,fix:"f",verdict:"FALSE_POSITIVE",reasoning:$h}]')"
summary_html="$(prt_render_summary enforce abc1234 1 "$html_json" 1 '' '' "$html_json")"
html_cell='&lt;/td&gt;&lt;/tr&gt;&lt;/tbody&gt;&lt;/table&gt;&lt;h2&gt;x&lt;/h2&gt; &amp; co'
assert_eq "prt_render_summary #183: findings-table cells entity-encode raw HTML" \
  "true" "$(grep -qF "| \`feedface\` | $html_cell | $html_cell | $html_cell | $html_cell | FALSE_POSITIVE |" <<< "$summary_html" && echo true || echo false)"
assert_eq "prt_render_summary #183: suppressed-table cells entity-encode raw HTML" \
  "true" "$(grep -qF "| \`feedface\` | $html_cell | $html_cell | $html_cell | $html_cell | $html_cell |" <<< "$summary_html" && echo true || echo false)"
assert_eq "prt_render_summary #183: no raw closing tag survives in the summary" \
  "false" "$(grep -qE '</(td|tr|tbody|table|h2)>' <<< "$summary_html" && echo true || echo false)"

# ============================================================ render.sh: prt_render_overflow_comment quarantined section (go-kure/.github#155)
# QUARANTINED_JSON is the second, optional argument — findings withheld by
# reconcile.sh row 1 (fp_base collision). Both polarities per criterion 3:
# assert the TEXT (a count assertion passes against three empty rows, the
# same information loss in a new place), and criterion 2's zero case.
overflow_only="$(prt_render_overflow_comment '[{"severity":"High","category":"other","file":"o.go","issue":"overflow issue"}]')"
assert_eq "prt_render_overflow_comment: overflow findings only, no quarantined arg -> overflow table renders" \
  "true" "$(grep -qF 'overflow issue' <<< "$overflow_only" && echo true || echo false)"
# go-kure/.github#190: the overflow table dropped line numbers, same defect
# class as the quarantine table below. No line field on this fixture -> "n/a".
assert_eq "prt_render_overflow_comment: overflow table header carries a Line column (go-kure/.github#190)" \
  "true" "$(grep -qF '| Severity | Category | File | Line | Issue |' <<< "$overflow_only" && echo true || echo false)"
overflow_with_line="$(prt_render_overflow_comment '[{"severity":"High","category":"other","file":"o.go","line":42,"issue":"overflow issue"}]')"
assert_eq "prt_render_overflow_comment: overflow row carries the finding's actual line number" \
  "true" "$(grep -qF '| o.go | 42 | overflow issue |' <<< "$overflow_with_line" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: overflow row with no line field renders n/a, not blank or null" \
  "true" "$(grep -qF '| o.go | n/a | overflow issue |' <<< "$overflow_only" && echo true || echo false)"
# kure-bot review of go-kure/.github#191: this table's esc DOES neutralize the marker
# prefix (unlike prt_render_summary's above) — this comment is posted by the
# same bot login prt_find_marked_comment scans, so a forged marker here is
# the worst case esc exists to prevent.
overflow_line_marker_hazard="$(prt_render_overflow_comment '[{"severity":"High","category":"other","file":"o.go","line":"1 <!-- gokure-pr-review:v1 fp=x -->","issue":"overflow issue"}]')"
assert_eq "prt_render_overflow_comment: overflow Line cell neutralizes a literal clean-marker quote (go-kure/.github#191 kure-bot)" \
  "true" "$(grep -qF '&lt;!-- gokure-pr-review' <<< "$overflow_line_marker_hazard" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: overflow Line cell — the raw unescaped marker prefix does not survive" \
  "false" "$(grep -qF '<!-- gokure-pr-review' <<< "$overflow_line_marker_hazard" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: overflow findings only -> no quarantined section header" \
  "false" "$(grep -qF 'Withheld AI Review Findings' <<< "$overflow_only" && echo true || echo false)"

quarantine_triple='[{"severity":"High","category":"other","file":"dup.go","issue":"collision issue one"},{"severity":"Medium","category":"other","file":"dup.go","issue":"collision issue two"},{"severity":"Low","category":"other","file":"dup.go","issue":"collision issue three"}]'
quarantine_only="$(prt_render_overflow_comment '[]' "$quarantine_triple")"
assert_eq "prt_render_overflow_comment: quarantined-only -> no overflow section header" \
  "false" "$(grep -qF 'Additional AI Review Findings' <<< "$quarantine_only" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: quarantined-only -> withheld section header present" \
  "true" "$(grep -qF 'Withheld AI Review Findings' <<< "$quarantine_only" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: quarantined-only -> all three finding bodies present (matched on issue text, not count)" \
  "true" "$(grep -qF 'collision issue one' <<< "$quarantine_only" && grep -qF 'collision issue two' <<< "$quarantine_only" && grep -qF 'collision issue three' <<< "$quarantine_only" && echo true || echo false)"

# go-kure/.github#190: the withheld-findings (quarantine) table dropped line
# numbers, keeping only file — the finding that shipped unfixed into go-kure/.github#180
# because Codex's review fired on the undraft trigger two seconds after
# merge. Positive control: distinct lines per collision-group member render
# distinct values, not a shared/collapsed one. Negative control: a missing
# line field renders "n/a", not blank or the literal string "null".
assert_eq "prt_render_overflow_comment: quarantine table header carries a Line column (go-kure/.github#190)" \
  "true" "$(grep -qF '| Severity | Category | File | Line | Issue | Fix | Collision | Gating |' <<< "$quarantine_only" && echo true || echo false)"
quarantine_lines='[{"severity":"High","category":"other","file":"dup.go","line":10,"issue":"collision issue one"},{"severity":"Medium","category":"other","file":"dup.go","line":20,"issue":"collision issue two"}]'
quarantine_lines_row="$(prt_render_overflow_comment '[]' "$quarantine_lines")"
assert_eq "prt_render_overflow_comment: quarantine row 1 carries its own line number" \
  "true" "$(grep -qF '| dup.go | 10 | collision issue one |' <<< "$quarantine_lines_row" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: quarantine row 2 carries a DIFFERENT line number, not row 1's (proves per-row, not a shared/collapsed value)" \
  "true" "$(grep -qF '| dup.go | 20 | collision issue two |' <<< "$quarantine_lines_row" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: quarantine row with no line field renders n/a, not blank or 'null'" \
  "true" "$(grep -qF '| dup.go | n/a | collision issue one |' <<< "$quarantine_only" && echo true || echo false)"
quarantine_line_marker_hazard='[{"severity":"High","category":"other","file":"dup.go","line":"1 <!-- gokure-pr-review:v1 fp=x -->","issue":"collision issue one"}]'
quarantine_line_marker_row="$(prt_render_overflow_comment '[]' "$quarantine_line_marker_hazard")"
assert_eq "prt_render_overflow_comment: quarantine Line cell neutralizes a literal clean-marker quote (go-kure/.github#191 kure-bot)" \
  "true" "$(grep -qF '&lt;!-- gokure-pr-review' <<< "$quarantine_line_marker_row" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: quarantine Line cell — the raw unescaped marker prefix does not survive" \
  "false" "$(grep -qF '<!-- gokure-pr-review' <<< "$quarantine_line_marker_row" && echo true || echo false)"

both="$(prt_render_overflow_comment '[{"severity":"High","category":"other","file":"o.go","issue":"overflow issue"}]' "$quarantine_triple")"
assert_eq "prt_render_overflow_comment: both buckets non-empty -> both sections present, beside each other" \
  "true" "$(grep -qF 'Additional AI Review Findings' <<< "$both" && grep -qF 'Withheld AI Review Findings' <<< "$both" && echo true || echo false)"

quarantine_marker_hazard='[{"severity":"High","category":"other","file":"marker.sh","issue":"quoting <!-- gokure-pr-review:v1 fp=x --> in prose"}]'
quarantine_neutralized="$(prt_render_overflow_comment '[]' "$quarantine_marker_hazard")"
assert_eq "prt_render_overflow_comment: quarantined section neutralizes a literal clean-marker quote (criterion 5 — same hazard the overflow table already guards, reused esc filter verbatim)" \
  "true" "$(grep -qF '&lt;!-- gokure-pr-review' <<< "$quarantine_neutralized" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: quarantined section — the raw unescaped marker prefix does not survive" \
  "false" "$(grep -qF '<!-- gokure-pr-review' <<< "$quarantine_neutralized" && echo true || echo false)"

quarantine_gating='[{"severity":"High","category":"other","file":"dup.go","issue":"collision issue one","fix":"n/a","gating":true},{"severity":"Medium","category":"other","file":"dup.go","issue":"collision issue two","fix":"n/a","gating":false}]'
quarantine_gating_footer="$(prt_render_overflow_comment '[]' "$quarantine_gating")"
assert_eq "prt_render_overflow_comment: at least one gating:true row -> footer states the contradiction, not the blanket claim (kure-bot round 2, fp=4ab69f0ddb6d86ed)" \
  "true" "$(grep -qF 'At least one withheld finding above IS gating' <<< "$quarantine_gating_footer" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: at least one gating:true row -> the blanket 'advisory only, not merge-gating.' sentence does not appear" \
  "false" "$(grep -qF '*Automated review — advisory only, not merge-gating.*' <<< "$quarantine_gating_footer" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: no gating:true row (all false) -> blanket 'advisory only, not merge-gating.' footer" \
  "true" "$(grep -qF '*Automated review — advisory only, not merge-gating.*' <<< "$quarantine_only" && echo true || echo false)"
# quarantine_gating_footer above has count=0 (no overflow findings, '[]' arg)
# and a gating:true row -- the overflow section (line 139) never rendered,
# so the footer must not point at "the overflow table above" (go-kure/.github#180
# codex review, this round: confirmed present pre-fix).
assert_eq "prt_render_overflow_comment: gating:true row but count=0 -> footer does not reference the (unrendered) overflow table" \
  "false" "$(grep -qF 'the overflow table above' <<< "$quarantine_gating_footer" && echo true || echo false)"

# persisted_only column (go-kure/.github#180 codex review, this round): a
# quarantined row can be effective-collision=true purely from a thread's
# PERSISTED marker (finding.sh:204's this-run collision=false), not from
# another finding sharing the fingerprint in the CURRENT diff — the table
# must say which, per row, not assert "in this diff" unconditionally.
quarantine_persisted='[{"severity":"High","category":"other","file":"dup.go","issue":"collision issue one","fix":"n/a","gating":false,"persisted_only":true}]'
quarantine_persisted_row="$(prt_render_overflow_comment '[]' "$quarantine_persisted")"
# Keyed on the pipe-delimited TABLE CELL, not the bare phrase: the intro
# paragraph explains both labels in prose, so it always contains the
# literal string "persisted (earlier run)" regardless of any row's actual
# value — a bare-phrase assertion would pass vacuously either way (same
# class of trap as G4, go-kure/.github#180 gmr round 1: a predicate that
# can never discriminate proves nothing about which branch rendered).
assert_eq "prt_render_overflow_comment: persisted_only:true row -> Collision cell reads 'persisted (earlier run)'" \
  "true" "$(grep -qF '| persisted (earlier run) |' <<< "$quarantine_persisted_row" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: persisted_only:true row -> Collision cell does NOT read 'this run' (negative, paired with the positive control above)" \
  "false" "$(grep -qF '| this run |' <<< "$quarantine_persisted_row" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: persisted_only:true row -> intro no longer asserts 'in this diff' unconditionally" \
  "false" "$(grep -qF 'share a fingerprint with another finding in this diff' <<< "$quarantine_persisted_row" && echo true || echo false)"
quarantine_this_run="$(prt_render_overflow_comment '[]' "$quarantine_triple")"
assert_eq "prt_render_overflow_comment: persisted_only omitted (default) -> Collision cell reads 'this run' (existing fixtures have no persisted_only field)" \
  "true" "$(grep -qF '| this run |' <<< "$quarantine_this_run" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: persisted_only omitted (default) -> Collision cell does NOT read 'persisted (earlier run)' (positive control: the row-specific predicate DOES discriminate, proven by the row above taking the other branch)" \
  "false" "$(grep -qF '| persisted (earlier run) |' <<< "$quarantine_this_run" && echo true || echo false)"

# quarantine_reason column (go-kure/.github#196 codex review): persisted_only
# alone can't distinguish a genuinely persisted collision flag from a
# content_fp mismatch -- both have collision=false this run. quarantine_reason
# is the authoritative field when present; these three rows exercise all of
# its values directly at the render layer, independent of the orchestrator
# scenario above.
quarantine_reason_triple='[
  {"severity":"High","category":"other","file":"a.go","issue":"i1","fix":"f1","gating":false,"persisted_only":false,"quarantine_reason":"this_run"},
  {"severity":"High","category":"other","file":"b.go","issue":"i2","fix":"f2","gating":false,"persisted_only":true,"quarantine_reason":"persisted"},
  {"severity":"High","category":"other","file":"c.go","issue":"i3","fix":"f3","gating":false,"persisted_only":true,"quarantine_reason":"content_mismatch"}
]'
quarantine_reason_row="$(prt_render_overflow_comment '[]' "$quarantine_reason_triple")"
assert_eq "prt_render_overflow_comment: quarantine_reason=this_run -> Collision cell reads 'this run'" \
  "true" "$(grep -qF '| a.go | n/a | i1 | f1 | this run |' <<< "$quarantine_reason_row" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: quarantine_reason=persisted -> Collision cell reads 'persisted (earlier run)'" \
  "true" "$(grep -qF '| b.go | n/a | i2 | f2 | persisted (earlier run) |' <<< "$quarantine_reason_row" && echo true || echo false)"
assert_eq "prt_render_overflow_comment: quarantine_reason=content_mismatch -> Collision cell reads 'content changed (recurring defect)', NOT 'persisted (earlier run)' even though persisted_only:true is also set on this row (quarantine_reason must win over the legacy field when both are present)" \
  "true" "$(grep -qF '| c.go | n/a | i3 | f3 | content changed (recurring defect) |' <<< "$quarantine_reason_row" && echo true || echo false)"

# ============================================================ render.sh: prt_render_advisory_comment degraded/incomplete disclosure (go-kure/.github#98 round 3, chatgpt-codex-connector[bot] review go-kure/.github#101#pullrequestreview-5028172237; round 5, kure-bot pr-review AI Code Review on go-kure/.github#101 at 9b2fe22 — the zero-count suppression round 3 added for `degraded_reasons` alone left the strictly-more-severe `incomplete_reasons`-only zero-count case still printing plain "No issues found.")
adv_clean_zero="$(prt_render_advisory_comment '[]')"
assert_eq "prt_render_advisory_comment: zero findings, no incomplete/degraded reasons -> plain 'No issues found.'" \
  "true" "$(grep -qF 'No issues found.' <<< "$adv_clean_zero" && echo true || echo false)"

# go-kure/.github#190: this is the sole output surface in advisory mode (no
# thread is ever created), same content-loss class as the quarantine table.
adv_with_line="$(prt_render_advisory_comment '[{"severity":"High","category":"other","file":"x.go","line":7,"issue":"i","fix":"f"}]')"
assert_eq "prt_render_advisory_comment: table header carries a Line column (go-kure/.github#190)" \
  "true" "$(grep -qF '| Severity | Category | File | Line | Issue | Fix |' <<< "$adv_with_line" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: row carries the finding's actual line number" \
  "true" "$(grep -qF '| x.go | 7 | i | f |' <<< "$adv_with_line" && echo true || echo false)"
adv_line_marker_hazard="$(prt_render_advisory_comment '[{"severity":"High","category":"other","file":"x.go","line":"1 <!-- gokure-pr-review:v1 fp=x -->","issue":"i","fix":"f"}]')"
assert_eq "prt_render_advisory_comment: Line cell neutralizes a literal clean-marker quote (go-kure/.github#191 kure-bot)" \
  "true" "$(grep -qF '&lt;!-- gokure-pr-review' <<< "$adv_line_marker_hazard" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: Line cell — the raw unescaped marker prefix does not survive" \
  "false" "$(grep -qF '<!-- gokure-pr-review' <<< "$adv_line_marker_hazard" && echo true || echo false)"

adv_incomplete_zero="$(prt_render_advisory_comment '[]' 'chunk 0: something fatal')"
assert_eq "prt_render_advisory_comment: zero findings + incomplete reasons -> 'No issues found.' does NOT fire (round 5: incomplete is strictly MORE severe than degraded, which already suppressed it — a fatal run must not be the one case that still reads as clean)" \
  "false" "$(grep -qF 'No issues found.' <<< "$adv_incomplete_zero" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: zero findings + incomplete reasons -> reason-neutral zero-count line instead" \
  "true" "$(grep -qF 'No findings to report this run — see the incomplete-run warning above.' <<< "$adv_incomplete_zero" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: incomplete banner wording" \
  "true" "$(grep -qF 'This review run was incomplete' <<< "$adv_incomplete_zero" && echo true || echo false)"

adv_degraded_zero="$(prt_render_advisory_comment '[]' '' 'chunk 0: partial-drop — one row dropped')"
assert_eq "prt_render_advisory_comment: zero surviving findings + degraded reasons -> 'No issues found.' does NOT fire" \
  "false" "$(grep -qF 'No issues found.' <<< "$adv_degraded_zero" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: zero surviving findings + degraded-only reasons -> degraded-specific zero-count line" \
  "true" "$(grep -qF 'No findings to report this run — see the degraded-run warning above.' <<< "$adv_degraded_zero" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: degraded banner uses distinct wording from incomplete's" \
  "true" "$(grep -qF 'This review run was degraded' <<< "$adv_degraded_zero" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: degraded banner carries the actual reason text" \
  "true" "$(grep -qF 'partial-drop — one row dropped' <<< "$adv_degraded_zero" && echo true || echo false)"

adv_degraded_nonzero="$(prt_render_advisory_comment '[{"severity":"High","category":"other","file":"x.go","issue":"i","fix":"f"}]' '' 'chunk 0: partial-drop')"
assert_eq "prt_render_advisory_comment: degraded + nonzero surviving findings -> table still rendered alongside the banner" \
  "true" "$(grep -qF '| High | other | x.go | n/a | i | f |' <<< "$adv_degraded_nonzero" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: degraded + nonzero -> banner still present" \
  "true" "$(grep -qF 'This review run was degraded' <<< "$adv_degraded_nonzero" && echo true || echo false)"

adv_both="$(prt_render_advisory_comment '[]' 'chunk 1: fatal' 'chunk 0: partial-drop')"
assert_eq "prt_render_advisory_comment: both incomplete AND degraded reasons present -> both banners render" \
  "true" "$([ "$(grep -c 'This review run was' <<< "$adv_both")" -eq 2 ] && echo true || echo false)"
assert_eq "prt_render_advisory_comment: both reasons present + zero findings -> 'No issues found.' does NOT fire" \
  "false" "$(grep -qF 'No issues found.' <<< "$adv_both" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: both reasons present + zero findings -> combined reason-neutral zero-count line naming both banners" \
  "true" "$(grep -qF 'No findings to report this run — see the incomplete-run and degraded-run warnings above.' <<< "$adv_both" && echo true || echo false)"

# round 4 (go-kure/.github#101 second review pass, chatgpt-codex-connector[bot]):
# the round-3 banner unconditionally said "some rows were dropped ... reflects
# only the surviving rows", which is only true of the partial-drop reason
# (:478) and misdescribes the other five prt_mark_degraded call sites (assess
# transport/parse/join failures at :534,570,592,605, and the unrelated
# clean-verdict-comment supersede failure at :1347) — none of which drop any
# row; four leave findings present but unverdicted, the fifth isn't about
# current findings at all. Assert the banner text itself is now
# degradation-neutral and does not assert "dropped"/"surviving" regardless of
# which reason fired.
# The suggested banner wording itself enumerates "dropped" as one of three
# generic possibilities (incomplete/unverdicted/dropped) without asserting
# any one of them happened — that mention is fine. What must NOT appear is
# the round-3 banner's specific FALSE claim that rows definitely were
# dropped and the table reflects only survivors, which was never true for
# this (assess-transport-fault) reason.
adv_degraded_nondrop="$(prt_render_advisory_comment '[{"severity":"High","category":"other","file":"x.go","issue":"i","fix":"f"}]' '' 'chunk 0: assessment call failed (transport/proxy error, exit 7); findings stay unverdicted')"
assert_eq "prt_render_advisory_comment: non-drop degraded reason (assess transport fault) -> banner does NOT assert rows WERE dropped (old wording)" \
  "false" "$(grep -qiF 'some rows were dropped' <<< "$adv_degraded_nondrop" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: non-drop degraded reason -> banner does NOT claim the table 'reflects only the surviving rows' (old wording)" \
  "false" "$(grep -qiF 'reflects only the surviving' <<< "$adv_degraded_nondrop" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: non-drop degraded reason -> banner does NOT say 'surviving rows'" \
  "false" "$(grep -qiF 'surviving rows' <<< "$adv_degraded_nondrop" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: non-drop degraded reason -> still shows the degraded banner" \
  "true" "$(grep -qF 'This review run was degraded' <<< "$adv_degraded_nondrop" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: non-drop degraded reason -> the specific reason text is carried verbatim" \
  "true" "$(grep -qF 'assessment call failed (transport/proxy error, exit 7); findings stay unverdicted' <<< "$adv_degraded_nondrop" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: non-drop degraded reason -> table still rendered (this finding was never dropped)" \
  "true" "$(grep -qF '| High | other | x.go | n/a | i | f |' <<< "$adv_degraded_nondrop" && echo true || echo false)"

adv_degraded_nondrop_zero="$(prt_render_advisory_comment '[]' '' 'chunk 0: .assessments missing/null/non-array')"
assert_eq "prt_render_advisory_comment: non-drop degraded reason + zero findings -> reason-neutral zero-count line, not 'No surviving findings'" \
  "true" "$(grep -qF 'No findings to report this run' <<< "$adv_degraded_nondrop_zero" && echo true || echo false)"
assert_eq "prt_render_advisory_comment: non-drop degraded reason + zero findings -> does NOT say 'surviving'" \
  "false" "$(grep -qiF 'surviving' <<< "$adv_degraded_nondrop_zero" && echo true || echo false)"

# ============================================================ state.sh: prt_annotation_escape (dot-github#61 Step 1)
assert_eq "annotation_escape: percent escaped first" "a%25b" "$(prt_annotation_escape 'a%b')"
assert_eq "annotation_escape: CR becomes %0D" "a%0Db" "$(prt_annotation_escape "$(printf 'a\rb')")"
assert_eq "annotation_escape: LF becomes %0A" "a%0Ab" "$(prt_annotation_escape "$(printf 'a\nb')")"
assert_eq "annotation_escape: percent-then-LF does not double-escape (order: % first, then CR/LF)" \
  "100%25 done%0Anext" "$(prt_annotation_escape "$(printf '100%% done\nnext')")"

# ============================================================ state.sh: prt_state_init fails loud on an unwritable dir (codex round 1, dot-github#60/#61)
# prt_state_init's own `: > "$PRT_INCOMPLETE_FILE"` used to be unchecked: a
# failed truncation left PRT_INCOMPLETE_FILE pointed at a file that was never
# actually created, and a run with zero later prt_mark_incomplete calls would
# report clean success with its own incomplete-state bookkeeping silently
# never established. prt_state_init calls `exit 1` directly (same
# exit-not-return contract as prt_mark_incomplete, documented at state.sh:37-53
# — this is a bare top-level call at pr-review-threads.sh:156, not inside a
# $(...) or subshell), so it must be invoked inside an explicit subshell here
# to observe its exit status without killing the test runner.
si_dir="$(mktemp -d)"
chmod 555 "$si_dir"
( prt_state_init "$si_dir" ) 2>/dev/null
si_rc=$?
assert_true "prt_state_init: exits non-zero when its dir is unwritable" \
  "$([ "$si_rc" -ne 0 ] && echo true || echo false)"
chmod 755 "$si_dir"
rm -rf "$si_dir"

# ============================================================ state.sh: prt_mark_degraded / prt_is_degraded / prt_degraded_reasons (go-kure/.github#98)
# Mirrors prt_mark_incomplete's own contract exactly (state.sh:47-73), on a
# second, non-fatal file — round-tripped directly here since neither this
# suite nor the orchestrator tests exercise prt_state_init's second file in
# isolation from a real run.
deg_dir="$(mktemp -d)"
prt_state_init "$deg_dir"
assert_eq "prt_is_degraded: false before any prt_mark_degraded call" \
  "false" "$(prt_is_degraded && echo true || echo false)"
prt_mark_degraded "first reason" 2>/dev/null
prt_mark_degraded "second reason" 2>/dev/null
assert_eq "prt_is_degraded: true after prt_mark_degraded" \
  "true" "$(prt_is_degraded && echo true || echo false)"
assert_eq "prt_degraded_reasons: both reasons recorded, one per line, in call order" \
  "$(printf 'first reason\nsecond reason')" "$(prt_degraded_reasons)"
# prt_is_incomplete must stay false — this is the additive/independent-file
# guarantee the whole mechanism rests on: marking degraded must never also
# mark incomplete.
assert_eq "prt_mark_degraded: does not also mark prt_is_incomplete (independent files)" \
  "false" "$(prt_is_incomplete && echo true || echo false)"
rm -rf "$deg_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE

# ============================================================ state.sh: prt_report_degraded_annotations (go-kure/.github#101 F8)
# Factored out of pr-review-threads.sh's tail so every fatal exit site can
# call it too — must emit identically regardless of prt_is_incomplete, since
# its whole purpose is to surface degraded reasons on a run that is ALSO
# fatal, not only on a clean-but-degraded one.
rda_dir="$(mktemp -d)"
prt_state_init "$rda_dir"
rda_out="$(prt_report_degraded_annotations 2>"$rda_dir/err")"
assert_eq "prt_report_degraded_annotations: no-op stdout when not degraded" "" "$rda_out"
assert_eq "prt_report_degraded_annotations: no-op stderr when not degraded" "" "$(cat "$rda_dir/err")"

prt_mark_degraded "assess transport fault" 2>/dev/null
rda_out="$(prt_report_degraded_annotations 2>"$rda_dir/err")"
assert_eq "prt_report_degraded_annotations: emits the ::warning annotation" \
  "true" "$(grep -qF '::warning title=PR review threads degraded::assess transport fault' <<< "$rda_out" && echo true || echo false)"
assert_eq "prt_report_degraded_annotations: emits the WARNING stderr recap" \
  "true" "$(grep -qF 'WARNING: review degraded' "$rda_dir/err" && grep -qF '  - assess transport fault' "$rda_dir/err" && echo true || echo false)"

# The regression this fixes: called from a path where prt_mark_incomplete was
# ALSO already recorded (a mixed fatal+degraded run) — must still emit.
prt_mark_incomplete "unrelated fatal reason" 2>/dev/null
rda_out="$(prt_report_degraded_annotations 2>/dev/null)"
assert_eq "prt_report_degraded_annotations: still emits when the run is also incomplete" \
  "true" "$(grep -qF '::warning title=PR review threads degraded::assess transport fault' <<< "$rda_out" && echo true || echo false)"
rm -rf "$rda_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE

# ============================================================ state.sh: prt_handle_freshness_rc / prt_all_degraded_are_stale (go-kure/.github#99)
hfr_dir="$(mktemp -d)"
prt_state_init "$hfr_dir"
prt_handle_freshness_rc 1 "fp=abc: create" 2>/dev/null
assert_eq "prt_handle_freshness_rc(1): routes to degraded, not incomplete" \
  "true false" "$(prt_is_degraded && echo true || echo false) $(prt_is_incomplete && echo true || echo false)"
assert_eq "prt_handle_freshness_rc(1): degraded reason carries the stale marker prt_all_degraded_are_stale matches on" \
  "true" "$(grep -qF 'stale head SHA (run superseded)' <<< "$(prt_degraded_reasons)" && echo true || echo false)"
assert_eq "prt_all_degraded_are_stale: true when the only degraded reason is staleness" \
  "true" "$(prt_all_degraded_are_stale && echo true || echo false)"
rm -rf "$hfr_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE

hfr_dir="$(mktemp -d)"
prt_state_init "$hfr_dir"
prt_handle_freshness_rc 2 "fp=abc: create" 2>/dev/null
assert_eq "prt_handle_freshness_rc(2): routes to incomplete (fatal), not degraded" \
  "false true" "$(prt_is_degraded && echo true || echo false) $(prt_is_incomplete && echo true || echo false)"
rm -rf "$hfr_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE

hfr_dir="$(mktemp -d)"
prt_state_init "$hfr_dir"
prt_handle_freshness_rc 3 "fp=abc: setting first_absent_sha" 2>/dev/null
assert_eq "prt_handle_freshness_rc(3): a fresh-but-failed write also routes to incomplete (fatal)" \
  "false true" "$(prt_is_degraded && echo true || echo false) $(prt_is_incomplete && echo true || echo false)"
rm -rf "$hfr_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE

hfr_dir="$(mktemp -d)"
prt_state_init "$hfr_dir"
assert_eq "prt_all_degraded_are_stale: false when not degraded at all" \
  "false" "$(prt_all_degraded_are_stale && echo true || echo false)"
prt_mark_degraded "fp=xyz: assess transport fault" 2>/dev/null
assert_eq "prt_all_degraded_are_stale: false on a non-staleness degraded reason" \
  "false" "$(prt_all_degraded_are_stale && echo true || echo false)"
prt_handle_freshness_rc 1 "fp=abc: create" 2>/dev/null
assert_eq "prt_all_degraded_are_stale: false on a MIX of staleness and other degraded reasons" \
  "false" "$(prt_all_degraded_are_stale && echo true || echo false)"
rm -rf "$hfr_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE

# ============================================================ state.sh: prt_handle_informational_freshness_rc (go-kure/.github#151)
# The partial-review comment's handler: rc 1 keeps the stale routing, every
# other status is degraded, never incomplete. rc 3 is not reachable from the
# orchestrator (prt_freshness_check returns only 0/1/2), so it is pinned here.
for ifr_rc in 2 3 99; do
  ifr_dir="$(mktemp -d)"
  prt_state_init "$ifr_dir"
  prt_handle_informational_freshness_rc "$ifr_rc" "partial-review comment" 2>/dev/null
  assert_eq "prt_handle_informational_freshness_rc($ifr_rc): routes to degraded, not incomplete" \
    "true false" "$(prt_is_degraded && echo true || echo false) $(prt_is_incomplete && echo true || echo false)"
  assert_eq "prt_handle_informational_freshness_rc($ifr_rc): reason is not a staleness reason, so no quiet stale exit" \
    "false" "$(prt_all_degraded_are_stale && echo true || echo false)"
  rm -rf "$ifr_dir"
  unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE
done
ifr_dir="$(mktemp -d)"
prt_state_init "$ifr_dir"
prt_handle_informational_freshness_rc 1 "partial-review comment" 2>/dev/null
assert_eq "prt_handle_informational_freshness_rc(1): stale head stays degraded with the stale marker" \
  "true false true" "$(prt_is_degraded && echo true || echo false) $(prt_is_incomplete && echo true || echo false) $(prt_all_degraded_are_stale && echo true || echo false)"
rm -rf "$ifr_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE ifr_dir ifr_rc

# ============================================================ state.sh: prt_resolve_review_parse_failures (go-kure/.github#107)
rpf_dir="$(mktemp -d)"
prt_state_init "$rpf_dir"
prt_resolve_review_parse_failures 3 2>/dev/null
assert_eq "prt_resolve_review_parse_failures: no-op when called with zero reasons" \
  "false false" "$(prt_is_degraded && echo true || echo false) $(prt_is_incomplete && echo true || echo false)"
rm -rf "$rpf_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE

rpf_dir="$(mktemp -d)"
prt_state_init "$rpf_dir"
prt_resolve_review_parse_failures 3 "chunk 1: review response was not valid JSON after retry=true, salvage_attempted=true (object)" 2>/dev/null
assert_eq "prt_resolve_review_parse_failures: one of three chunks failed -> degraded, not incomplete" \
  "true false" "$(prt_is_degraded && echo true || echo false) $(prt_is_incomplete && echo true || echo false)"
assert_eq "prt_resolve_review_parse_failures: degraded reason carries the load-bearing review-parse-failed tag" \
  "true" "$(grep -qF 'review-parse-failed: chunk 1:' <<< "$(prt_degraded_reasons)" && echo true || echo false)"
rm -rf "$rpf_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE

rpf_dir="$(mktemp -d)"
prt_state_init "$rpf_dir"
prt_resolve_review_parse_failures 2 "chunk 0: review call failed (transport/proxy error, exit 7)" "chunk 1: review call failed on retry (transport/proxy error, exit 7)" 2>/dev/null
assert_eq "prt_resolve_review_parse_failures: ALL chunks failed -> incomplete (fatal), not degraded" \
  "false true" "$(prt_is_degraded && echo true || echo false) $(prt_is_incomplete && echo true || echo false)"
assert_eq "prt_resolve_review_parse_failures: all-failed reasons are NOT also tagged degraded (no dual-marking)" \
  "false" "$(grep -qF 'review-parse-failed' <<< "$(prt_degraded_reasons)" && echo true || echo false)"
rm -rf "$rpf_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE

# go-kure/.github#95: the same resolver, fed a normalize-rc=1 reason (a
# shape-valid response whose .findings was rejected after its own retry)
# instead of a parse/transport reason — the resolver itself doesn't inspect
# the reason text, but this proves the rc=1 reason string routes through the
# identical fatal-vs-degraded split as any other collected failure.
rpf_dir="$(mktemp -d)"
prt_state_init "$rpf_dir"
prt_resolve_review_parse_failures 3 "chunk 1: .findings missing/null/non-array, or all rows malformed and dropped (after retry=true)" 2>/dev/null
assert_eq "prt_resolve_review_parse_failures: one-of-three normalize-rc=1 failure -> degraded, not incomplete" \
  "true false" "$(prt_is_degraded && echo true || echo false) $(prt_is_incomplete && echo true || echo false)"
assert_eq "prt_resolve_review_parse_failures: normalize-rc=1 degraded reason carries the load-bearing review-parse-failed tag" \
  "true" "$(grep -qF 'review-parse-failed: chunk 1: .findings missing/null/non-array' <<< "$(prt_degraded_reasons)" && echo true || echo false)"
rm -rf "$rpf_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE

rpf_dir="$(mktemp -d)"
prt_state_init "$rpf_dir"
prt_resolve_review_parse_failures 1 "chunk 0: .findings missing/null/non-array, or all rows malformed and dropped (after retry=true)" 2>/dev/null
assert_eq "prt_resolve_review_parse_failures: ALL chunks hit normalize-rc=1 -> incomplete (fatal), not degraded" \
  "false true" "$(prt_is_degraded && echo true || echo false) $(prt_is_incomplete && echo true || echo false)"
assert_eq "prt_resolve_review_parse_failures: all-failed normalize-rc=1 reasons are NOT also tagged degraded (no dual-marking)" \
  "false" "$(grep -qF 'review-parse-failed' <<< "$(prt_degraded_reasons)" && echo true || echo false)"
rm -rf "$rpf_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE

# A partial review-parse failure (degraded, not incomplete) with zero findings
# from the chunks that DID parse must not be eligible for the clean-verdict
# "Reviewed, no findings" comment (codex round-3 finding on go-kure/.github#109:
# pr-review-threads.sh's clean-verdict gate at the time only excluded
# prt_is_incomplete, so it still fired here and published a false-clean
# verdict over a PR with an unreviewed chunk). This mirrors the exact
# review-parse-failed grep already used for the absence-loop's incomplete_now
# fold-in (pr-review-threads.sh:1145) rather than re-deriving a new check.
rpf_dir="$(mktemp -d)"
prt_state_init "$rpf_dir"
prt_resolve_review_parse_failures 3 "chunk 2: review response was not valid JSON after retry=true, salvage_attempted=true (object)" 2>/dev/null
assert_eq "clean-verdict gate: a review-parse-failed degraded reason is detected by the same grep the gate uses" \
  "true" "$(prt_degraded_reasons | grep -q 'review-parse-failed' && echo true || echo false)"
rm -rf "$rpf_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE

rpf_dir="$(mktemp -d)"
prt_state_init "$rpf_dir"
prt_handle_freshness_rc 1 "fp=abc: create"  2>/dev/null
assert_eq "clean-verdict gate: an unrelated degraded reason (stale-superseded) does NOT match the review-parse-failed grep" \
  "false" "$(prt_degraded_reasons | grep -q 'review-parse-failed' && echo true || echo false)"
rm -rf "$rpf_dir"
unset PRT_INCOMPLETE_FILE PRT_DEGRADED_FILE

# ============================================================ orchestrator: exit-code contract (subprocess, mocked curl)
# pr-review-threads.sh itself is not exercised by the rest of this suite (its
# own header comment says so — it's wiring, not a pure function) but its
# top-level exit code IS a contract worth pinning down directly:
# pr-review-threads.sh:1381-1394's REVIEW_INCOMPLETE -> exit 1, PRT_MODE=off's exit 0 staying ahead of that
# check, and the two prt_retry-wrapped reads actually retrying. Run as a real
# subprocess (not sourced) so $? reflects the same exit path CI observes,
# against a mocked PRT_CURL exported into that subprocess's environment
# (function export is required for a child bash process to see it — a plain
# variable assignment on the invocation line is not enough on its own).
#
# fake_curl_orchestrator dispatches on URL suffix + Accept header, now also
# -X/-d, to tell every real caller apart: model.sh's proxy call always
# targets */chat/completions; the advisory/overflow comment POST always
# targets .../issues/<N>/comments; the diff-fetch curl sends Accept:
# application/vnd.github.diff; every other prt_gh_rest GET pulls/<N> call
# (initial meta fetch and every later freshness re-check) sends the plain
# +json Accept instead; GraphQL calls target */graphql (dispatched further
# by payload shape); a single review-thread comment's own GET/PATCH targets
# */pulls/comments/<id> (distinct from */pulls/<N>/comments, the create/
# reply endpoint, which stays on the catch-all "meta" arm — it's a POST
# whose response body the caller discards). These GraphQL and
# pulls/comments arms are placed ahead of the trailing catch-all —
# ordering is load-bearing, same as the diff/meta split above it.
_prt_test_owned_thread_body() {
  # Shared by the reviewThreads GraphQL response and the pulls/comments GET
  # response below, so a real GET-then-PATCH round trip (SET_FIRST_ABSENT,
  # CLEAR_MARKER) has a marker-bearing body to operate on. Not required to
  # byte-for-byte match what a real prt_marker_replace produced — only that
  # it's non-empty and carries a parseable marker.
  local marker
  # go-kure/.github#196: empty by default (unset PRT_TEST_OWNED_CONTENT_FP)
  # — every existing fixture that never sets it exercises the "thread
  # predates this field, unverifiable, trust the match" backward-compat
  # path unchanged.
  # go-kure/.github#148: PRT_TEST_OWNED_COLLISION=true plants a persisted
  # collision flag on the owned thread's marker.
  marker="$(prt_marker_build "${PRT_TEST_OWNED_FP:-deadbeefcafebabe}" "${PRT_TEST_OWNED_COLLISION:-}" "${PRT_TEST_FIRST_ABSENT_SHA:-}" "${PRT_TEST_OWNED_CONTENT_FP:-}")"
  # go-kure/.github#268: PRT_TEST_OWNED_SEVERITY renders the body in
  # prt_render_finding_body's layout (marker, then "**<severity> · <category>**"),
  # the only shape prt_finding_body_severity reads a severity from. Unset, the
  # legacy body below states none, so the thread ranks as the lowest gating
  # severity.
  if [ -n "${PRT_TEST_OWNED_SEVERITY:-}" ]; then
    printf '%s\n**%s · other**\n\nPlanted test finding.\n' "$marker" "$PRT_TEST_OWNED_SEVERITY"
    return 0
  fi
  printf '**High**\n\nPlanted test finding for empty-diff absence reconciliation.\n\n%s\n' "$marker"
}
export -f _prt_test_owned_thread_body

_prt_test_paged_threads_response() {
  local out="$1" request="$2" cursor start count has_next end_cursor filler
  cursor="$(jq -r '.variables.cursor // "null"' <<< "$request")"
  case "$cursor" in
    null) start=0; count=50; has_next=true; end_cursor=page-2 ;;
    page-2) start=50; count=50; has_next=true; end_cursor=page-3 ;;
    page-3) start=100; count=20; has_next=false; end_cursor='' ;;
    *) return 1 ;;
  esac
  printf -v filler '%*s' 2200 ''
  filler="${filler// /x}"
  jq -n --argjson start "$start" --argjson count "$count" \
    --argjson has_next "$has_next" --arg end_cursor "$end_cursor" --arg filler "$filler" '
      {data:{repository:{pullRequest:{reviewThreads:{
        pageInfo:{hasNextPage:$has_next,endCursor:(if $has_next then $end_cursor else null end)},
        nodes:[range($start; $start + $count) as $i | {
          id:("THREAD-" + ($i|tostring)), isResolved:false, isOutdated:false,
          resolvedBy:null, viewerCanResolve:true, viewerCanUnresolve:true,
          comments:{pageInfo:{hasNextPage:false,endCursor:null},
            nodes:[{id:("C-" + ($i|tostring)), databaseId:$i, body:$filler,
                    author:{login:"human-reviewer"}}]}
        }]
      }}}}}' > "$out"
}

_prt_test_paginated_comments_response() {
  local out="$1" request="$2" cursor filler first_body
  cursor="$(jq -r '.variables.cursor // "initial"' <<< "$request")"
  printf -v filler '%*s' 2200 ''
  filler="${filler// /x}"
  case "$cursor" in
    initial)
      first_body="$(_prt_test_owned_thread_body)"
      jq -n --arg first_body "$first_body" --arg filler "$filler" '
        {data:{repository:{pullRequest:{reviewThreads:{
          pageInfo:{hasNextPage:false,endCursor:null},
          nodes:[{
            id:"THREAD-COMMENTS", isResolved:false, isOutdated:false,
            resolvedBy:null, viewerCanResolve:true, viewerCanUnresolve:true,
            comments:{pageInfo:{hasNextPage:true,endCursor:"comments-2"},
              nodes:[range(0; 50) as $i | {
                id:("COMMENT-" + ($i|tostring)), databaseId:($i + 1),
                body:(if $i == 0 then $first_body
                      else "<!-- gokure-pr-review:v1-note -->\n" + $filler end),
                author:{login:"test-bot"}
              }]}
          }]
        }}}}}' > "$out"
      ;;
    comments-2)
      jq -n --arg filler "$filler" '
        {data:{node:{comments:{
          pageInfo:{hasNextPage:true,endCursor:"comments-3"},
          nodes:[range(50; 100) as $i | {
            id:("COMMENT-" + ($i|tostring)), databaseId:($i + 1),
            body:("<!-- gokure-pr-review:v1-note -->\n" + $filler),
            author:{login:"test-bot"}
          }]
        }}}}' > "$out"
      ;;
    comments-3)
      jq -n --arg filler "$filler" '
        {data:{node:{comments:{
          pageInfo:{hasNextPage:false,endCursor:null},
          nodes:[range(100; 120) as $i | {
            id:("COMMENT-" + ($i|tostring)), databaseId:($i + 1),
            body:(if $i == 119 then "late human reply\n" + $filler
                  else "<!-- gokure-pr-review:v1-note -->\n" + $filler end),
            author:{login:(if $i == 119 then "human-reviewer" else "test-bot" end)}
          }]
        }}}}' > "$out"
      ;;
    *) return 1 ;;
  esac
}

_prt_test_malformed_threads_response() {
  local out="$1"
  printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":{}}}}}}' > "$out"
}

# go-kure/.github#193 codex review fix: prt_thread_has_human_reply's own
# node(id:...) recheck query matches the SAME `*PullRequestReviewThread*`
# dispatch pattern as the pre-existing comment_page_query inventory-
# pagination re-fetch. In PRT_TEST_INVENTORY_MODE=single (the default), the
# owned thread's own inventory-build never triggers that pagination re-fetch
# (has_next=false on its one-page comment list), so single mode is exactly
# where PRT_TEST_RECHECK_MODE can control the recheck call unambiguously.
# REPLY="true" plants a human reply as the (skipped-index-0-aside) second
# comment; REPLY="false" keeps every comment marker-bearing (clean).
_prt_test_recheck_response() {
  local out="$1" reply="$2"
  local second_body
  if [ "$reply" = true ]; then
    second_body='a fresh human reply, unmarked'
  else
    second_body="<!-- gokure-pr-review:v1-note -->"$'\n'"bot follow-up, marked"
  fi
  jq -n --arg second_body "$second_body" '
    {data:{node:{comments:{
      pageInfo:{hasNextPage:false,endCursor:null},
      nodes:[
        {id:"C1", databaseId:1, body:"planted finding body", author:{login:"test-bot"}},
        {id:"C2", databaseId:2, body:$second_body, author:{login:"human-reviewer"}}
      ]
    }}}}' > "$out"
}

export -f _prt_test_paged_threads_response _prt_test_paginated_comments_response \
  _prt_test_malformed_threads_response _prt_test_recheck_response

# _prt_test_payload_ok DATA — true when DATA is a JSON object whose `.body` is
# a non-empty string: the only shape a comment write may carry. An empty or
# truncated payload must fail the request, never read as a delivered comment.
_prt_test_payload_ok() {
  jq -e '(.body | type) == "string" and (.body | length) > 0' <<< "$1" > /dev/null 2>&1
}

fake_curl_orchestrator() {
  local args=("$@") out="" accept="" url="" method="" data="" h req_body=""
  local i n=${#args[@]}
  for ((i = 0; i < n; i++)); do
    case "${args[$i]}" in
      -o) out="${args[$((i + 1))]}" ;;
      -X) method="${args[$((i + 1))]}" ;;
      -d) data="${args[$((i + 1))]}" ;;
      # prt_gh_rest sends its payload over stdin (`--data-binary @-`).
      --data-binary) [ "${args[$((i + 1))]}" = "@-" ] && data="$(cat)" ;;
      -H)
        h="${args[$((i + 1))]}"
        case "$h" in
          Accept:*) accept="${h#Accept: }" ;;
        esac
        ;;
      http://*|https://*)
        # The URL's position varies by caller — last positional for
        # prt_gh_rest and the diff-fetch curl, but BEFORE -H/-d for
        # model.sh's proxy call (-X POST "$url" -H ... -d ...) — so match by
        # shape, not position.
        url="${args[$i]}" ;;
    esac
  done

  # Every comment write, POST or PATCH, on an issue or a review thread, must carry a
  # JSON object with a non-empty string body. The check runs before any arm below
  # (logging, failure injection, counting), so no write path can record an empty or
  # truncated payload as a delivered comment.
  case "$method:$url" in
    POST:*/issues/*/comments|PATCH:*/issues/comments/*|POST:*/pulls/*/comments|PATCH:*/pulls/comments/*)
      if ! _prt_test_payload_ok "$data"; then
        echo "mock: rejected an empty or non-JSON comment payload for $method $url" >&2
        : > "$out"; echo 422; return 0
      fi
      ;;
  esac

  # Opt-in issue-comment log (go-kure/.github#151): only when a caller sets
  # PRT_TEST_ISSUE_COMMENT_LOG, so every other fixture keeps its existing
  # behavior. The listing GET serves PRT_TEST_ISSUE_COMMENTS_LIST (default
  # []); a PATCH to issues/comments/<id> and a POST to issues/<n>/comments
  # each append "METHOD <path after /issues/>" plus the body, indented, to
  # the log. The POST then falls through to the normal arm below, so the
  # issue-comment count and body-file capture still work.
  # PRT_TEST_PARTIAL_WRITE_FAIL=1 answers HTTP 500 to any write whose body
  # carries the partial-review marker (logged as "FAILED METHOD <path>"),
  # leaving the clean-verdict comment's writes untouched.
  # PRT_TEST_WRITE_FAIL_BODY_MATCH=<text> does the same for any write whose
  # body contains <text>.
  if [ -n "${PRT_TEST_ISSUE_COMMENT_LOG:-}" ]; then
    if [ "$method" != GET ] && { { [ -n "${PRT_TEST_PARTIAL_WRITE_FAIL:-}" ] \
      && grep -qF 'gokure-pr-review:v1-partial' <<< "$data"; } \
      || { [ -n "${PRT_TEST_WRITE_FAIL_BODY_MATCH:-}" ] \
      && grep -qF -- "$PRT_TEST_WRITE_FAIL_BODY_MATCH" <<< "$data"; }; }; then
      printf 'FAILED %s %s\n' "$method" "${url##*/issues/}" >> "$PRT_TEST_ISSUE_COMMENT_LOG"
      : > "$out"; echo 500; return 0
    fi
    case "$method:$url" in
      GET:*/issues/*/comments[?]*)
        # PRT_TEST_ISSUE_LIST_COUNTFILE counts listing calls; with
        # PRT_TEST_ISSUE_LIST_FAIL_AFTER=N (0 included; empty is off), every
        # listing after the Nth answers HTTP 500.
        if [ -n "${PRT_TEST_ISSUE_LIST_COUNTFILE:-}" ]; then
          local list_n
          list_n=$(( $(cat "$PRT_TEST_ISSUE_LIST_COUNTFILE" 2>/dev/null || echo 0) + 1 ))
          echo "$list_n" > "$PRT_TEST_ISSUE_LIST_COUNTFILE"
          if [ -n "${PRT_TEST_ISSUE_LIST_FAIL_AFTER:-}" ] && [ "$list_n" -gt "$PRT_TEST_ISSUE_LIST_FAIL_AFTER" ]; then
            : > "$out"; echo 500; return 0
          fi
        fi
        printf '%s' "${PRT_TEST_ISSUE_COMMENTS_LIST:-[]}" > "$out"
        echo 200
        return 0
        ;;
      PATCH:*/issues/comments/*)
        printf 'PATCH %s\n' "${url##*/issues/}" >> "$PRT_TEST_ISSUE_COMMENT_LOG"
        jq -r '.body' <<< "$data" | sed 's/^/  | /' >> "$PRT_TEST_ISSUE_COMMENT_LOG"
        printf '%s' '{"id":1}' > "$out"
        echo 200
        return 0
        ;;
      POST:*/issues/*/comments)
        printf 'POST %s\n' "${url##*/issues/}" >> "$PRT_TEST_ISSUE_COMMENT_LOG"
        jq -r '.body' <<< "$data" | sed 's/^/  | /' >> "$PRT_TEST_ISSUE_COMMENT_LOG"
        ;;
    esac
  fi

  case "$url" in
    */chat/completions)
      # The review and assess calls share this one URL — distinguish them by
      # reading the request body model.sh writes to disk and passes as
      # `-d @FILE` (the E2BIG fix, model.sh:289-299,387-392: never inline on argv),
      # so `$data` here is a `@`-prefixed path, not literal JSON. The assess
      # call's user message always contains the literal
      # "--- FINDINGS (JSON) ---" marker (model.sh:478); the review call's
      # never does.
      req_body=""
      case "$data" in
        @*) req_body="$(cat "${data#@}" 2>/dev/null || true)" ;;
      esac
      # go-kure/.github#173: PRT_TEST_MODEL_REQUEST_LOG captures each call's user message.
      [ -n "${PRT_TEST_MODEL_REQUEST_LOG:-}" ] && \
        jq -r '.messages[] | select(.role == "user") | .content' <<< "$req_body" >> "$PRT_TEST_MODEL_REQUEST_LOG"
      # go-kure/.github#156: PRT_TEST_MODEL_SYSTEM_LOG captures each call's
      # system prompt, where PROJECT STANDARDS is injected.
      [ -n "${PRT_TEST_MODEL_SYSTEM_LOG:-}" ] && \
        jq -r '.messages[] | select(.role == "system") | .content' <<< "$req_body" >> "$PRT_TEST_MODEL_SYSTEM_LOG"
      case "$req_body" in
        *'FINDINGS (JSON)'*)
          # PRT_TEST_ASSESS_* (go-kure/.github assess-resilience workstream):
          # exercises prt_model_assess's exit-status check, salvage pass and
          # bounded retry — the assessment call's mirror of the review call's
          # own resilience below. Only reachable when the review call above
          # actually produced >=1 finding (PRT_TEST_MODEL_RESPONSE_MODE=
          # clean_with_finding), since the orchestrator skips assessment for
          # an empty-findings chunk (pr-review-threads.sh:512).
          mc="$(_prt_test_bump "${PRT_TEST_ASSESS_COUNTFILE:?}")"
          if [ "${PRT_TEST_ASSESS_ALWAYS_FAIL:-0}" = 1 ]; then
            : > "$out"; echo 500; return 0
          fi
          case "${PRT_TEST_ASSESS_RESPONSE_MODE:-clean}" in
            prose)
              printf '%s' '{"choices":[{"message":{"content":"Here is the assessment:\n{\"assessments\":[{\"fp\":\"deadbeefcafebabe\",\"verdict\":\"VALID\",\"reasoning\":\"ok\"}]}\nDone."}}]}' > "$out"
              ;;
            garbage)
              printf '%s' '{"choices":[{"message":{"content":"not json at all, sorry"}}]}' > "$out"
              ;;
            bad_shape)
              # Valid JSON, wrong shape — distinct from `garbage` above:
              # exercises prt_join_assessment's own `.assessments`
              # non-array rejection (finding.sh:190-195), not the
              # jq -c '.' parse failure the salvage/retry path handles
              # (go-kure/.github#98, Case x).
              printf '%s' '{"choices":[{"message":{"content":"{\"assessments\":\"oops-not-an-array\"}"}}]}' > "$out"
              ;;
            false_positive_survivor)
              # go-kure/.github#98 round 3 (chatgpt-codex-connector[bot]
              # review, go-kure/.github#101): unlike the hardcoded
              # "deadbeefcafebabe" fp every other mode above uses (which
              # never matches a real review-call finding's own fingerprint,
              # per the round-1 F2 investigation), this mode computes the
              # REAL fp of the PRT_TEST_MODEL_RESPONSE_MODE=partial_drop
              # scenario's one surviving finding (file=x.go,
              # category=other) via prt_fp_base — sourced into this same
              # subprocess by pr-review-threads.sh itself — and verdicts it
              # FALSE_POSITIVE, so the advisory table's post-filter
              # surviving-findings count is genuinely 0, not merely
              # unverdicted.
              printf '%s' "$(jq -n --arg fp "$(prt_fp_base x.go other)" \
                '{choices:[{message:{content:({assessments:[{fp:$fp,verdict:"FALSE_POSITIVE",reasoning:"not a real issue"}]} | tojson)}}]}')" > "$out"
              ;;
            cross_chunk_fp)
              # A chunk-scoped assessor that cannot see the code a finding
              # rests on: FALSE_POSITIVE for x.go's file-backend finding
              # (category logic-error), with the reasoning the assess prompt
              # once told it to use. The finding is real; its caller is in y.go.
              printf '%s' "$(jq -n --arg fp "$(prt_fp_base x.go logic-error)" \
                '{choices:[{message:{content:({assessments:[{fp:$fp,verdict:"FALSE_POSITIVE",reasoning:"depends on code outside this chunk: the caller in y.go"}]} | tojson)}}]}')" > "$out"
              ;;
            valid_survivor)
              # go-kure/.github#153: the same real fp as false_positive_survivor,
              # verdicted VALID.
              printf '%s' "$(jq -n --arg fp "$(prt_fp_base x.go other)" \
                '{choices:[{message:{content:({assessments:[{fp:$fp,verdict:"VALID",reasoning:"real"}]} | tojson)}}]}')" > "$out"
              ;;
            garbage_then_clean)
              if [ "$mc" -le 1 ]; then
                printf '%s' '{"choices":[{"message":{"content":"not json at all, sorry"}}]}' > "$out"
              else
                printf '%s' '{"choices":[{"message":{"content":"{\"assessments\":[{\"fp\":\"deadbeefcafebabe\",\"verdict\":\"VALID\",\"reasoning\":\"ok\"}]}"}}]}' > "$out"
              fi
              ;;
            seven_valid)
              # go-kure/.github#192: VALID for the real fp of every finding
              # PRT_TEST_MODEL_RESPONSE_MODE=seven_findings returns (x.go and
              # one category each), computed like false_positive_survivor.
              local sv_cat sv_fps='[]'
              for sv_cat in nil-deref unchecked-err race sql-injection resource-leak logic-error standards-violation; do
                sv_fps="$(jq -c --arg fp "$(prt_fp_base x.go "$sv_cat")" '. + [$fp]' <<< "$sv_fps")"
              done
              printf '%s' "$(jq -n --argjson fps "$sv_fps" \
                '{choices:[{message:{content:({assessments:[$fps[] | {fp:., verdict:"VALID", reasoning:"real"}]} | tojson)}}]}')" > "$out"
              ;;
            garbage_then_fail)
              # Mixed failure mode: parse failure on the original attempt,
              # transport failure on the retry — codex round-1 finding on
              # go-kure/.github fix/prt-assess-resilience (never pushed, no
              # PR number to qualify): a transport fault on the retry call
              # was being collapsed into the "not valid JSON" branch instead
              # of being reported as its own distinct transport failure.
              if [ "$mc" -le 1 ]; then
                printf '%s' '{"choices":[{"message":{"content":"not json at all, sorry"}}]}' > "$out"
                echo 200
                return 0
              else
                : > "$out"; echo 500; return 0
              fi
              ;;
            first_ok_then_bad_shape)
              # go-kure/.github#176: call-count-aware (not run-global) mode
              # for the two-chunk "One-degraded" coverage fixture below —
              # chunk 0's assess call (mc==1) gets a clean, valid
              # `.assessments` array; chunk 1's (mc==2, and any later chunk)
              # gets the same non-array shape as `bad_shape` above. Needed
              # because `bad_shape` is one value for the whole run and would
              # degrade every chunk's assess call, not just one — the
              # acceptance criterion is specifically that one chunk fails
              # while the sibling(s) succeed.
              if [ "$mc" -le 1 ]; then
                printf '%s' '{"choices":[{"message":{"content":"{\"assessments\":[{\"fp\":\"deadbeefcafebabe\",\"verdict\":\"VALID\",\"reasoning\":\"ok\"}]}"}}]}' > "$out"
              else
                printf '%s' '{"choices":[{"message":{"content":"{\"assessments\":\"oops-not-an-array\"}"}}]}' > "$out"
              fi
              ;;
            *)
              printf '%s' '{"choices":[{"message":{"content":"{\"assessments\":[{\"fp\":\"deadbeefcafebabe\",\"verdict\":\"VALID\",\"reasoning\":\"ok\"}]}"}}]}' > "$out"
              ;;
          esac
          echo 200
          ;;
        *)
          # _prt_test_bump's return value (not discarded here, unlike the
          # other call sites below) is the running per-run model-call count,
          # used by the garbage_then_clean mode to tell the original attempt
          # from the round-2 fold-in's bounded retry apart.
          mc="$(_prt_test_bump "${PRT_TEST_MODEL_COUNTFILE:?}")"
          if [ "${PRT_TEST_MODEL_ALWAYS_FAIL:-0}" = 1 ]; then
            : > "$out"; echo 500; return 0
          fi
          # PRT_TEST_MODEL_RESPONSE_MODE (go-kure/.github#60/#61 round 2
          # fold-in): exercises the salvage pass and the bounded retry added
          # around the jq -c '.' parse in pr-review-threads.sh's chunk-review
          # loop. clean (default) is the pre-existing well-formed response
          # with no findings. clean_with_finding is the same but with one
          # well-formed finding, so a caller can drive the assess call above
          # (which the orchestrator skips entirely for an empty-findings
          # chunk). prose wraps well-formed JSON in commentary on both
          # sides — no braces missing, salvageable without ever needing the
          # retry (fact 3 in the incident record: launcher#283 run
          # 32175849548, a chattier generation wraps the JSON object in
          # prose). garbage has no '{'/'}' at all — unsalvageable, and stays
          # garbage on the retry too, every call. garbage_then_clean is
          # garbage only on call 1 (mc<=1); the retry (call 2) gets clean
          # JSON, proving the retry path actually runs and not just that
          # it's accepted in principle.
          case "${PRT_TEST_MODEL_RESPONSE_MODE:-clean}" in
            clean_with_finding)
              printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"x.go\",\"line\":1,\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"i\",\"fix\":\"f\"}]}"}}]}' > "$out"
              ;;
            per_chunk_findings)
              # go-kure/.github#173: a different finding per chunk (x.go on
              # the first review call, y.go on every later one), so a
              # two-chunk run creates a thread per chunk instead of
              # colliding two copies of one finding.
              if [ "$mc" -le 1 ]; then
                printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"x.go\",\"line\":1,\"category\":\"logic-error\",\"severity\":\"Medium\",\"issue\":\"chunk-one-issue\",\"fix\":\"g\"}]}"}}]}' > "$out"
              else
                printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"y.go\",\"line\":1,\"category\":\"logic-error\",\"severity\":\"Medium\",\"issue\":\"chunk-two-issue\",\"fix\":\"h\"}]}"}}]}' > "$out"
              fi
              ;;
            new_then_owned)
              # go-kure/.github#148: a new finding (x.go/logic-error, no
              # thread yet, so loop 1 creates one) ahead of
              # clean_with_finding's x.go/other finding, which matches the
              # owned thread. Lets a test fail the first write and watch
              # what the second finding does.
              printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"x.go\",\"line\":1,\"category\":\"logic-error\",\"severity\":\"Medium\",\"issue\":\"new-issue-text\",\"fix\":\"g\"},{\"file\":\"x.go\",\"line\":1,\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"i\",\"fix\":\"f\"}]}"}}]}' > "$out"
              ;;
            high_owned_then_new)
              # go-kure/.github#153: clean_with_finding's x.go/other finding
              # raised to High, then a Medium x.go/logic-error finding with no
              # thread. The High one outranks the new one in the cap walk, so
              # a wrongly released match takes the slot the new one needed.
              printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"x.go\",\"line\":1,\"category\":\"other\",\"severity\":\"High\",\"issue\":\"i\",\"fix\":\"f\"},{\"file\":\"x.go\",\"line\":1,\"category\":\"logic-error\",\"severity\":\"Medium\",\"issue\":\"new-issue-text\",\"fix\":\"g\"}]}"}}]}' > "$out"
              ;;
            fail_first_chunk_review)
              # go-kure/.github#176 codex review (Critical): a two-chunk run
              # where chunk 0's REVIEW call itself fails outright (transport
              # error, no retry on the original attempt — see the ":ne 0"
              # branch's own comment above it in pr-review-threads.sh) and
              # chunk 1's review call succeeds with zero findings. Both leave
              # chunk_findings empty for their index at the coverage-counting
              # loop; only CHUNK_REVIEW_FAILED distinguishes "review never
              # ran" from "no findings on a clean review". mc==1 is chunk 0's
              # one and only (unretried) review call; mc==2 is chunk 1's.
              if [ "$mc" -le 1 ]; then
                : > "$out"; echo 500; return 0
              else
                printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[]}"}}]}' > "$out"
              fi
              ;;
            no_findings_key)
              # Valid JSON, but no `.findings` key at all — the rc=1
              # ("missing/null/non-array") branch of prt_normalize_findings,
              # distinct from partial_drop below (rc=2): nothing in this
              # chunk was reviewed, stays fatal (go-kure/.github#98).
              printf '%s' '{"choices":[{"message":{"content":"{\"other\":1}"}}]}' > "$out"
              ;;
            partial_drop)
              # Valid JSON, `.findings` array-shaped, but one row is
              # malformed (empty .file) and gets dropped while the other
              # survives — the rc=2 ("partial drop") branch of
              # prt_normalize_findings: degraded, not fatal
              # (go-kure/.github#98).
              printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"x.go\",\"line\":1,\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"i\",\"fix\":\"f\"},{\"file\":\"\",\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"bad\",\"fix\":\"f\"}]}"}}]}' > "$out"
              ;;
            all_malformed)
              # go-kure/.github#95: valid JSON, `.findings` array-shaped,
              # but EVERY row is malformed (empty .file) — the rc=1 ("total
              # loss") branch of prt_normalize_findings on a response that
              # parsed fine. Malformed on every call, so this proves the
              # retry fires (call count 2) but never becomes usable — the
              # single-chunk run still exits 1.
              printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"\",\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"bad\",\"fix\":\"f\"}]}"}}]}' > "$out"
              ;;
            all_malformed_then_clean)
              # go-kure/.github#95 mirror of garbage_then_clean, but for the
              # NEW retry trigger: rc=1 (all rows malformed) on call 1,
              # clean_with_finding on call 2 — proves the retry recovers a
              # response that parsed but was normalize-rejected, not just one
              # that failed to parse at all.
              if [ "$mc" -le 1 ]; then
                printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"\",\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"bad\",\"fix\":\"f\"}]}"}}]}' > "$out"
              else
                printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"x.go\",\"line\":1,\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"i\",\"fix\":\"f\"}]}"}}]}' > "$out"
              fi
              ;;
            two_chunk_first_all_malformed)
              # go-kure/.github#95: call-count-aware (not run-global) mode
              # for the multi-chunk fixture below — malformed for calls 1
              # and 2 (chunk 0's original attempt and its bounded retry),
              # clean_with_finding from call 3 on (chunk 1, and any later
              # chunk). Reusing all_malformed (malformed on EVERY call)
              # would also poison chunk 1's single call, not just chunk 0's
              # two; this mode is needed because that variable is one value
              # for the whole run, dispatched only on the monotonic global
              # call counter above.
              if [ "$mc" -le 2 ]; then
                printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"\",\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"bad\",\"fix\":\"f\"}]}"}}]}' > "$out"
              else
                printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"y.go\",\"line\":1,\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"i2\",\"fix\":\"f2\"}]}"}}]}' > "$out"
              fi
              ;;
            two_chunk_first_all_malformed_second_empty)
              # Enforce-mode sibling of the mode above: chunk 0 still
              # exhausts its retry and degrades, but chunk 1 (call 3+)
              # returns a genuinely clean, EMPTY .findings — so the
              # clean-verdict "Reviewed, no findings" comment must NOT fire
              # over a PR with an unreviewed chunk (the review-parse-failed
              # exclusion, pr-review-threads.sh's enforce-mode gate).
              if [ "$mc" -le 2 ]; then
                printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"\",\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"bad\",\"fix\":\"f\"}]}"}}]}' > "$out"
              else
                printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[]}"}}]}' > "$out"
              fi
              ;;
            two_chunk_first_partial_drop_second_clean)
              # go-kure/.github#211: chunk 0's response is Case xii's exact
              # partial-drop shape (one malformed row dropped, one
              # survives — rc=2 is usable on the first attempt, no retry, so
              # mc==1 is chunk 0's only call); chunk 1 (mc==2) reviews
              # cleanly with one well-formed finding. Both surviving
              # findings then assess cleanly under the default
              # PRT_TEST_ASSESS_RESPONSE_MODE, so before the
              # go-kure/.github#211 fix, chunk_ok_count reached
              # chunk_count=2 here and the terminal coverage line wrongly
              # printed despite chunk 0's dropped row.
              if [ "$mc" -le 1 ]; then
                printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"x.go\",\"line\":1,\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"i\",\"fix\":\"f\"},{\"file\":\"\",\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"bad\",\"fix\":\"f\"}]}"}}]}' > "$out"
              else
                printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"y.go\",\"line\":1,\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"i2\",\"fix\":\"f2\"}]}"}}]}' > "$out"
              fi
              ;;
            collision_triple)
              # go-kure/.github#155: three findings, same file+category
              # (dup.go/other) — prt_assign_ordinals groups them on the same
              # fp_base, so all three collide (glen=3>1) regardless of
              # assessment verdict, since reconcile.sh row 1 fires before
              # verdict is ever read. Distinct issue text per finding so a
              # caller can assert all three bodies survive into the
              # withheld/advisory comment, not just a count.
              printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"dup.go\",\"line\":1,\"category\":\"other\",\"severity\":\"High\",\"issue\":\"collision issue one\",\"fix\":\"fix one\"},{\"file\":\"dup.go\",\"line\":2,\"category\":\"other\",\"severity\":\"Medium\",\"issue\":\"collision issue two\",\"fix\":\"fix two\"},{\"file\":\"dup.go\",\"line\":3,\"category\":\"other\",\"severity\":\"Low\",\"issue\":\"collision issue three\",\"fix\":\"fix three\"}]}"}}]}' > "$out"
              ;;
            seven_findings)
              # go-kure/.github#192: seven distinct findings (x.go, one
              # category each, so no fp_base collides). The two Low ones come
              # first, so only the severity sort, not response order, keeps
              # them out of the cap of 5.
              printf '%s' "$(jq -nc '
                [["nil-deref","Low"],["unchecked-err","Low"],["race","High"],["sql-injection","High"],
                 ["resource-leak","Medium"],["logic-error","High"],["standards-violation","Medium"]]
                | {findings: map({file:"x.go", line:1, category:.[0], severity:.[1],
                                  issue:("overflow-case " + .[0] + " issue"), fix:("fix " + .[0])})}
                | {choices:[{message:{content:tojson}}]}')" > "$out"
              ;;
            prose)
              printf '%s' '{"choices":[{"message":{"content":"Here you go:\n{\"findings\":[]}\nHope that helps!"}}]}' > "$out"
              ;;
            garbage)
              printf '%s' '{"choices":[{"message":{"content":"not json at all, sorry"}}]}' > "$out"
              ;;
            garbage_then_clean)
              if [ "$mc" -le 1 ]; then
                printf '%s' '{"choices":[{"message":{"content":"not json at all, sorry"}}]}' > "$out"
              else
                printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[]}"}}]}' > "$out"
              fi
              ;;
            garbage_then_fail)
              # Mixed failure mode: parse failure on the original attempt,
              # transport failure on the retry — the review-call mirror of
              # PRT_TEST_ASSESS_RESPONSE_MODE=garbage_then_fail above (Case
              # viii): confirm-round fold-in closing the identical
              # mislabeling gap on the review call's own retry.
              if [ "$mc" -le 1 ]; then
                printf '%s' '{"choices":[{"message":{"content":"not json at all, sorry"}}]}' > "$out"
                echo 200
                return 0
              else
                : > "$out"; echo 500; return 0
              fi
              ;;
            *)
              printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[]}"}}]}' > "$out"
              ;;
          esac
          echo 200
          ;;
      esac
      ;;
    */issues/*/comments)
      if ! _prt_test_payload_ok "$data"; then
        echo "mock: rejected an empty or non-JSON comment payload for $method $url" >&2
        : > "$out"; echo 422; return 0
      fi
      _prt_test_bump "${PRT_TEST_ISSUE_COMMENT_COUNTFILE:?}" >/dev/null
      # Capture the posted body verbatim when a caller wants to assert on its
      # rendered content (e.g. the advisory-comment degraded-banner test
      # below) — optional, a no-op write when the caller hasn't set it.
      if [ -n "${PRT_TEST_ISSUE_COMMENT_BODY_FILE:-}" ]; then
        jq -r '.body' <<< "$data" > "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" 2>/dev/null || true
      fi
      printf '%s' '{"id":1}' > "$out"
      echo 200
      ;;
    */issues/*/comments[?]*)
      # The comment listing GET when PRT_TEST_ISSUE_COMMENT_LOG is unset: an
      # empty list. It used to fall through to the PR metadata arm below,
      # whose object prt_find_marked_comment only read as "no comment" while
      # it swallowed its own jq failures (go-kure/.github#153 R3-P2).
      printf '%s' "${PRT_TEST_ISSUE_COMMENTS_LIST:-[]}" > "$out"
      echo 200
      ;;
    */graphql)
      _prt_test_bump "${PRT_TEST_GRAPHQL_COUNTFILE:?}" >/dev/null
      if [ "${PRT_TEST_INVENTORY_MODE:-single}" = inventory_http_error ]; then
        printf '%s' '{"hostile_inventory_payload":"must-not-reach-logs"}' > "$out"
        echo 500
        return 0
      fi
      case "$data" in
        *reviewThreads*)
          case "${PRT_TEST_INVENTORY_MODE:-single}" in
            paged_threads)
              _prt_test_paged_threads_response "$out" "$data" || return 1
              ;;
            paginated_comments)
              _prt_test_paginated_comments_response "$out" "$data" || return 1
              ;;
            malformed_threads)
              _prt_test_malformed_threads_response "$out" || return 1
              ;;
            *)
            # PRT_TEST_OWNED_RESOLVED_BY_BOT (go-kure/.github#99 round-4
            # fold-in): reports THREAD1 already resolved by the bot login
            # itself, the one owned-thread shape the default single-mode
            # mock could not previously produce — needed to reach
            # prt_decide_finding's row 7 (REPLY_UNRESOLVE), which requires
            # thread_resolved=true AND resolved_by_bot=true.
            if [ "${PRT_TEST_OWNED_RESOLVED_BY_BOT:-0}" = 1 ]; then
              resp="$(jq -n --arg body "$(_prt_test_owned_thread_body)" '
                {data:{repository:{pullRequest:{reviewThreads:{
                  pageInfo:{hasNextPage:false,endCursor:null},
                  nodes:[{
                    id:"THREAD1", isResolved:true, isOutdated:false,
                    resolvedBy:{login:"test-bot"}, viewerCanResolve:true, viewerCanUnresolve:true,
                    comments:{pageInfo:{hasNextPage:false,endCursor:null},
                      nodes:[{id:"C1", databaseId:1, body:$body, author:{login:"test-bot"}}]}
                  }]
                }}}}}')"
            else
              # PRT_TEST_OWNED_AUTHOR (go-kure/.github#153): the first
              # comment's author. Default "test-bot" matches the harness's
              # PRT_BOT_LOGIN; anything else makes the marked thread foreign.
              # PRT_TEST_THREAD1_REPLIES (go-kure/.github#261): a JSON array of
              # reply comment nodes appended after C1. C1 was created on
              # 2026-01-01; PRT_TEST_THREAD1_LAST_EDITED sets its lastEditedAt
              # (default: never edited). PRT_TEST_THREAD1_RESOLVED=1
              # (go-kure/.github#153) reports THREAD1 resolved, by
              # PRT_TEST_THREAD1_RESOLVED_BY (default "a-human").
              # PRT_TEST_THREAD2_RESOLVED_BY (go-kure/.github#153 R1-P2a):
              # when set, a second thread THREAD2 with the same marker body
              # and author, resolved by that login.
              resp="$(jq -n --arg body "$(_prt_test_owned_thread_body)" --arg author "${PRT_TEST_OWNED_AUTHOR:-test-bot}" \
                --argjson replies "${PRT_TEST_THREAD1_REPLIES:-[]}" \
                --arg edited "${PRT_TEST_THREAD1_LAST_EDITED:-}" \
                --arg resolved "${PRT_TEST_THREAD1_RESOLVED:-0}" \
                --arg resolved_by "${PRT_TEST_THREAD1_RESOLVED_BY:-a-human}" \
                --arg t2_resolved_by "${PRT_TEST_THREAD2_RESOLVED_BY:-}" '
                {data:{repository:{pullRequest:{reviewThreads:{
                  pageInfo:{hasNextPage:false,endCursor:null},
                  nodes:([{
                    id:"THREAD1", isResolved:($resolved == "1"), isOutdated:false,
                    resolvedBy:(if $resolved == "1" then {login:$resolved_by} else null end),
                    viewerCanResolve:true, viewerCanUnresolve:true,
                    comments:{pageInfo:{hasNextPage:false,endCursor:null},
                      nodes:([{id:"C1", databaseId:1, body:$body, author:{login:$author},
                        createdAt:"2026-01-01T00:00:00Z",
                        lastEditedAt:(if $edited == "" then null else $edited end)}] + $replies)}
                  }] + (if $t2_resolved_by == "" then [] else [{
                    id:"THREAD2", isResolved:true, isOutdated:false,
                    resolvedBy:{login:$t2_resolved_by},
                    viewerCanResolve:true, viewerCanUnresolve:true,
                    comments:{pageInfo:{hasNextPage:false,endCursor:null},
                      nodes:[{id:"C2", databaseId:2, body:$body, author:{login:$author},
                        createdAt:"2026-01-01T00:00:00Z", lastEditedAt:null}]}
                  }] end))
                }}}}}')"
            fi
            printf '%s' "$resp" > "$out"
              ;;
          esac
          echo 200
          ;;
        *isResolved*)
          # prt_thread_is_resolved's live re-read before a collision lift
          # (go-kure/.github#148). PRT_TEST_LIVE_RESOLVED: false (default,
          # the thread is still open), true (a human resolved it after the
          # inventory snapshot), unreadable (node:null), false_then_true (open
          # on the first read, resolved on the second: a human resolved it
          # between two lift attempts, go-kure/.github#256; any third read is
          # unreadable, so a retry that does not stop at "resolved" shows up
          # as an incomplete run).
          case "${PRT_TEST_LIVE_RESOLVED:-false}" in
            unreadable) printf '%s' '{"data":{"node":null}}' > "$out" ;;
            false_then_true)
              local live_n
              live_n="$(_prt_test_bump "${PRT_TEST_LIVE_RESOLVED_COUNTFILE:?}")"
              case "$live_n" in
                1) printf '%s' '{"data":{"node":{"isResolved":false}}}' > "$out" ;;
                2) printf '%s' '{"data":{"node":{"isResolved":true}}}' > "$out" ;;
                *) printf '%s' '{"data":{"node":null}}' > "$out" ;;
              esac
              ;;
            *) jq -n --argjson r "${PRT_TEST_LIVE_RESOLVED:-false}" '{data:{node:{isResolved:$r}}}' > "$out" ;;
          esac
          echo 200
          ;;
        *PullRequestReviewThread*)
          if [ "${PRT_TEST_INVENTORY_MODE:-single}" = paginated_comments ]; then
            _prt_test_paginated_comments_response "$out" "$data" || return 1
            echo 200
          elif [ -n "${PRT_TEST_RECHECK_MODE:-}" ]; then
            _prt_test_recheck_response "$out" "${PRT_TEST_RECHECK_MODE}"
            echo 200
          else
            printf '%s' '{"data":{"node":null}}' > "$out"
            echo 200
          fi
          ;;
        *unresolveReviewThread*)
          _prt_test_bump "${PRT_TEST_UNRESOLVE_COUNTFILE:?}" >/dev/null
          printf '%s' '{"data":{"unresolveReviewThread":{"thread":{"id":"THREAD1"}}}}' > "$out"
          echo 200
          ;;
        *resolveReviewThread*)
          _prt_test_bump "${PRT_TEST_RESOLVE_COUNTFILE:?}" >/dev/null
          printf '%s' '{"data":{"resolveReviewThread":{"thread":{"id":"THREAD1"}}}}' > "$out"
          echo 200
          ;;
        *)
          printf '%s' '{"data":{}}' > "$out"
          echo 200
          ;;
      esac
      ;;
    */pulls/comments/*)
      case "$method" in
        PATCH)
          # go-kure/.github#148: PRT_TEST_PATCH_BODY_LOG captures each
          # thread-marker rewrite's body; PRT_TEST_PATCH_FAIL=1 answers 500
          # without counting it as a PATCH; PRT_TEST_PATCH_FAIL=first answers
          # 500 to the first attempt only (go-kure/.github#256).
          [ -n "${PRT_TEST_PATCH_BODY_LOG:-}" ] && \
            jq -r '.body' <<< "$data" >> "$PRT_TEST_PATCH_BODY_LOG"
          if [ "${PRT_TEST_PATCH_FAIL:-0}" = 1 ]; then
            : > "$out"; echo 500; return 0
          fi
          if [ "${PRT_TEST_PATCH_FAIL:-0}" = first ] && \
             [ "$(_prt_test_bump "${PRT_TEST_PATCH_ATTEMPT_COUNTFILE:?}")" -eq 1 ]; then
            : > "$out"; echo 500; return 0
          fi
          _prt_test_bump "${PRT_TEST_PATCH_COUNTFILE:?}" >/dev/null
          printf '%s' '{"id":1}' > "$out"
          echo 200
          ;;
        *)
          # go-kure/.github#148: PRT_TEST_COMMENT_GET_EMPTY=1 answers the
          # pre-rewrite GET with no body.
          if [ "${PRT_TEST_COMMENT_GET_EMPTY:-0}" = 1 ]; then
            printf '%s' '{}' > "$out"
          else
            jq -n --arg b "$(_prt_test_owned_thread_body)" '{body:$b}' > "$out"
          fi
          echo 200
          ;;
      esac
      ;;
    */contents/.gitattributes[?]ref=*)
      # go-kure/.github#293: the base commit's root .gitattributes. Served
      # from PRT_TEST_BASE_GITATTRIBUTES (base64-encoded, as the contents API
      # does) only when the URL names the meta arm's base SHA, so a read at
      # any other commit (the head) finds nothing; unset answers 404, the
      # no-such-file case. PRT_TEST_BASE_ATTRS_FAIL=1 answers 500.
      if [ "${PRT_TEST_BASE_ATTRS_FAIL:-0}" = 1 ]; then
        : > "$out"; echo 500; return 0
      fi
      if [ -n "${PRT_TEST_BASE_GITATTRIBUTES:-}" ] && [ "${url##*ref=}" = 2222222222222222222222222222222222222222 ]; then
        jq -n --arg c "$(printf '%s\n' "$PRT_TEST_BASE_GITATTRIBUTES" | base64)" \
          '{type:"file", encoding:"base64", content:$c}' > "$out"
        echo 200
      else
        printf '%s' '{"message":"Not Found"}' > "$out"
        echo 404
      fi
      ;;
    *)
      if [ "$method" = POST ]; then
        case "$url" in
          */pulls/*/comments)
            # A comment write must carry a JSON object with a non-empty string body.
            if ! _prt_test_payload_ok "$data"; then
              echo "mock: rejected an empty or non-JSON comment payload for POST $url" >&2
              : > "$out"; echo 422; return 0
            fi
            case "$data" in
              *in_reply_to*)
                # PRT_TEST_REPLY_FAIL=1 answers every reply POST 500, uncounted.
                if [ "${PRT_TEST_REPLY_FAIL:-0}" = 1 ]; then
                  : > "$out"; echo 500; return 0
                fi
                _prt_test_bump "${PRT_TEST_REPLY_COUNTFILE:?}" >/dev/null
                # go-kure/.github#261: PRT_TEST_REPLY_BODY_LOG captures each reply body.
                [ -n "${PRT_TEST_REPLY_BODY_LOG:-}" ] && \
                  jq -r '.body' <<< "$data" >> "$PRT_TEST_REPLY_BODY_LOG"
                ;;
              *commit_id*)
                _prt_test_bump "${PRT_TEST_CREATE_COUNTFILE:?}" >/dev/null
                # go-kure/.github#173: PRT_TEST_CREATE_BODY_LOG captures each new thread's body.
                [ -n "${PRT_TEST_CREATE_BODY_LOG:-}" ] && \
                  jq -r '.body' <<< "$data" >> "$PRT_TEST_CREATE_BODY_LOG"
                ;;
            esac
            ;;
        esac
      fi
      case "$accept" in
        *vnd.github.diff*)
          if [ "${PRT_TEST_EMPTY_DIFF:-0}" = 1 ]; then
            : > "$out"; echo 200; return 0
          fi
          c="$(_prt_test_bump "${PRT_TEST_DIFF_COUNTFILE:?}")"
          if [ "$c" -le "${PRT_TEST_DIFF_FAIL_TIMES:-0}" ]; then
            : > "$out"; echo 502; return 0
          fi
          if [ -n "${PRT_TEST_DIFF_PATH:-}" ]; then
            # go-kure/.github#293: a caller-built diff, served verbatim.
            cat "$PRT_TEST_DIFF_PATH" > "$out"
          elif [ "${PRT_TEST_TWO_FILE_DIFF:-0}" = 1 ]; then
            # go-kure/.github#95: a second `diff --git` record (a second
            # file), served only when the caller opts in via an explicit
            # max-diff-chars override low enough to split at this record
            # boundary — prt_split_diff (diff.sh:36-50) splits first at
            # `diff --git` boundaries, so this is what lets the multi-chunk
            # fixtures below land two real chunks without tripping the
            # unrelated hard-ceiling hunk-truncation path.
            printf 'diff --git a/x.go b/x.go\nindex 1111111..2222222 100644\n--- a/x.go\n+++ b/x.go\n@@ -1,1 +1,1 @@\n-old\n+new\ndiff --git a/y.go b/y.go\nindex 3333333..4444444 100644\n--- a/y.go\n+++ b/y.go\n@@ -1,1 +1,1 @@\n-old2\n+new2\n' > "$out"
          else
            printf 'diff --git a/x.go b/x.go\nindex 1111111..2222222 100644\n--- a/x.go\n+++ b/x.go\n@@ -1,1 +1,1 @@\n-old\n+new\n' > "$out"
          fi
          echo 200
          ;;
        *)
          # meta fetch (:243) and every later freshness re-check (gh.sh:136)
          # share this same GET pulls/<N> shape — deliberately: a freshness
          # check after the meta fetch has already consumed the fail budget
          # must succeed immediately, matching how the real one-run head-SHA
          # only moves once, not repeatedly.
          c="$(_prt_test_bump "${PRT_TEST_META_COUNTFILE:?}")"
          if [ "$c" -le "${PRT_TEST_META_FAIL_TIMES:-0}" ]; then
            : > "$out"; echo 502; return 0
          fi
          # go-kure/.github#151: every GET pulls/<N> after call
          # PRT_TEST_PR_READ_FAIL_AFTER_CALL fails, so a chosen freshness
          # re-check returns 2 (PR read failed) rather than 1 (stale).
          if [ "${PRT_TEST_PR_READ_FAIL_AFTER_CALL:-0}" != 0 ] && [ "$c" -gt "${PRT_TEST_PR_READ_FAIL_AFTER_CALL}" ]; then
            : > "$out"; echo 502; return 0
          fi
          # go-kure/.github#99: call #1 is always the real meta fetch (must
          # report the real head SHA so the run's own context is sane); every
          # freshness re-check after PRT_TEST_STALE_AFTER_CALL reports a
          # DIFFERENT, but still well-formed, head SHA — simulating a
          # genuinely-superseding push mid-run, not a read failure.
          if [ "${PRT_TEST_STALE_AFTER_CALL:-0}" != 0 ] && [ "$c" -gt "${PRT_TEST_STALE_AFTER_CALL}" ]; then
            printf '{"title":"t","body":"d","head":{"sha":"%s"}}' "9999999999999999999999999999999999999999" > "$out"
          else
            printf '{"title":"t","body":"d","head":{"sha":"%s"},"base":{"sha":"2222222222222222222222222222222222222222"}}' "$PRT_HEAD_SHA" > "$out"
          fi
          echo 200
          ;;
      esac
      ;;
  esac
}
_prt_test_bump() {
  local f="$1" c
  c=$(($(cat "$f" 2>/dev/null || echo 0) + 1))
  echo "$c" > "$f"
  echo "$c"
}
export -f fake_curl_orchestrator _prt_test_bump _prt_test_payload_ok

# run_orchestrator MODE DIFF_FAIL_TIMES META_FAIL_TIMES MODEL_ALWAYS_FAIL [MAX_DIFF_CHARS] —
# prints the subprocess exit code; countfiles are left behind in the paths
# given via the PRT_TEST_*_COUNTFILE globals set by the caller. stdout/
# stderr are now captured to PRT_TEST_STDOUT_FILE/PRT_TEST_STDERR_FILE
# (also caller-set globals) instead of being discarded — #61's whole point
# is that this output now carries information worth asserting on.
# MAX_DIFF_CHARS (go-kure/.github#95, optional, 5th positional) forwards a
# PRT_MAX_DIFF_CHARS override into the subprocess — used together with the
# caller-set PRT_TEST_TWO_FILE_DIFF global (fake_curl_orchestrator's diff
# arm above) to land a genuine two-chunk run: neither knob alone can, see
# the comment at that diff arm.
run_orchestrator() {
  local mode="$1" diff_fail="$2" meta_fail="$3" model_fail="$4" max_diff_chars="${5:-50000}"
  local scratch summary rc
  scratch="$(mktemp -d)"
  summary="$(mktemp)"
  # Seeded with "0", not truncated to empty: a countfile _prt_test_bump never
  # touches this run must read back as the integer 0, not an empty string a
  # caller's `-ge`/`-eq` comparison would choke on.
  echo 0 > "$PRT_TEST_DIFF_COUNTFILE"
  echo 0 > "$PRT_TEST_META_COUNTFILE"
  echo 0 > "$PRT_TEST_MODEL_COUNTFILE"
  echo 0 > "$PRT_TEST_ASSESS_COUNTFILE"
  echo 0 > "$PRT_TEST_GRAPHQL_COUNTFILE"
  echo 0 > "$PRT_TEST_PATCH_COUNTFILE"
  echo 0 > "$PRT_TEST_RESOLVE_COUNTFILE"
  echo 0 > "$PRT_TEST_UNRESOLVE_COUNTFILE"
  echo 0 > "$PRT_TEST_CREATE_COUNTFILE"
  echo 0 > "$PRT_TEST_REPLY_COUNTFILE"
  echo 0 > "$PRT_TEST_ISSUE_COMMENT_COUNTFILE"
  [ -n "${PRT_TEST_ISSUE_COMMENT_BODY_FILE:-}" ] && : > "$PRT_TEST_ISSUE_COMMENT_BODY_FILE"
  : > "$PRT_TEST_STDOUT_FILE"
  : > "$PRT_TEST_STDERR_FILE"
  # go-kure/.github#156: $scratch is the run's working directory, i.e. the
  # caller's checkout. PRT_TEST_CALLER_FILE=<relative path> with
  # PRT_TEST_CALLER_FILE_CONTENT plants a file there. PRT_TEST_STANDARDS_FILE
  # and PRT_TEST_STANDARDS_SOURCE are forwarded only when set (set-but-empty
  # included), so a test that sets neither runs with the script's defaults.
  if [ -n "${PRT_TEST_CALLER_FILE:-}" ]; then
    mkdir -p "$scratch/$(dirname "$PRT_TEST_CALLER_FILE")"
    printf '%s\n' "${PRT_TEST_CALLER_FILE_CONTENT:-}" > "$scratch/$PRT_TEST_CALLER_FILE"
  fi
  (
    unset PRT_STANDARDS_FILE PRT_STANDARDS_SOURCE
    [ -n "${PRT_TEST_STANDARDS_FILE+set}" ] && export PRT_STANDARDS_FILE="$PRT_TEST_STANDARDS_FILE"
    [ -n "${PRT_TEST_STANDARDS_SOURCE+set}" ] && export PRT_STANDARDS_SOURCE="$PRT_TEST_STANDARDS_SOURCE"
    cd "$scratch" && \
    PRT_CURL="${PRT_TEST_CURL:-fake_curl_orchestrator}" \
    PRT_TEST_DIFF_COUNTFILE="$PRT_TEST_DIFF_COUNTFILE" \
    PRT_TEST_META_COUNTFILE="$PRT_TEST_META_COUNTFILE" \
    PRT_TEST_MODEL_COUNTFILE="$PRT_TEST_MODEL_COUNTFILE" \
    PRT_TEST_ASSESS_COUNTFILE="$PRT_TEST_ASSESS_COUNTFILE" \
    PRT_TEST_GRAPHQL_COUNTFILE="$PRT_TEST_GRAPHQL_COUNTFILE" \
    PRT_TEST_PATCH_COUNTFILE="$PRT_TEST_PATCH_COUNTFILE" \
    PRT_TEST_RESOLVE_COUNTFILE="$PRT_TEST_RESOLVE_COUNTFILE" \
    PRT_TEST_UNRESOLVE_COUNTFILE="$PRT_TEST_UNRESOLVE_COUNTFILE" \
    PRT_TEST_CREATE_COUNTFILE="$PRT_TEST_CREATE_COUNTFILE" \
    PRT_TEST_REPLY_COUNTFILE="$PRT_TEST_REPLY_COUNTFILE" \
    PRT_TEST_ISSUE_COMMENT_COUNTFILE="$PRT_TEST_ISSUE_COMMENT_COUNTFILE" \
    PRT_TEST_ISSUE_COMMENT_BODY_FILE="${PRT_TEST_ISSUE_COMMENT_BODY_FILE:-}" \
    PRT_TEST_DIFF_FAIL_TIMES="$diff_fail" \
    PRT_TEST_META_FAIL_TIMES="$meta_fail" \
    PRT_TEST_MODEL_ALWAYS_FAIL="$model_fail" \
    PRT_TEST_EMPTY_DIFF="${PRT_TEST_EMPTY_DIFF:-0}" \
    PRT_TEST_FIRST_ABSENT_SHA="${PRT_TEST_FIRST_ABSENT_SHA:-}" \
    PRT_TEST_OWNED_FP="${PRT_TEST_OWNED_FP:-deadbeefcafebabe}" \
    PRT_TEST_OWNED_CONTENT_FP="${PRT_TEST_OWNED_CONTENT_FP:-}" \
    PRT_TEST_OWNED_COLLISION="${PRT_TEST_OWNED_COLLISION:-}" \
    PRT_TEST_OWNED_SEVERITY="${PRT_TEST_OWNED_SEVERITY:-}" \
    PRT_MAX_FINDINGS_TOTAL="${PRT_TEST_MAX_FINDINGS_TOTAL:-5}" \
    PRT_TEST_PATCH_BODY_LOG="${PRT_TEST_PATCH_BODY_LOG:-}" \
    PRT_TEST_PATCH_FAIL="${PRT_TEST_PATCH_FAIL:-0}" \
    PRT_TEST_COMMENT_GET_EMPTY="${PRT_TEST_COMMENT_GET_EMPTY:-0}" \
    PRT_TEST_OWNED_RESOLVED_BY_BOT="${PRT_TEST_OWNED_RESOLVED_BY_BOT:-0}" \
    PRT_TEST_RECHECK_MODE="${PRT_TEST_RECHECK_MODE:-}" \
    PRT_TEST_LIVE_RESOLVED="${PRT_TEST_LIVE_RESOLVED:-false}" \
    PRT_TEST_LIVE_RESOLVED_COUNTFILE="$scratch/live-resolved-count" \
    PRT_TEST_PATCH_ATTEMPT_COUNTFILE="$scratch/patch-attempt-count" \
    PRT_TEST_THREAD1_REPLIES="${PRT_TEST_THREAD1_REPLIES:-[]}" \
    PRT_TEST_THREAD1_LAST_EDITED="${PRT_TEST_THREAD1_LAST_EDITED:-}" \
    PRT_TEST_THREAD1_RESOLVED="${PRT_TEST_THREAD1_RESOLVED:-0}" \
    PRT_TEST_THREAD1_RESOLVED_BY="${PRT_TEST_THREAD1_RESOLVED_BY:-a-human}" \
    PRT_TEST_THREAD2_RESOLVED_BY="${PRT_TEST_THREAD2_RESOLVED_BY:-}" \
    PRT_TEST_REPLY_BODY_LOG="${PRT_TEST_REPLY_BODY_LOG:-}" \
    PRT_TEST_CREATE_BODY_LOG="${PRT_TEST_CREATE_BODY_LOG:-}" \
    PRT_TEST_MODEL_REQUEST_LOG="${PRT_TEST_MODEL_REQUEST_LOG:-}" \
    PRT_TEST_MODEL_SYSTEM_LOG="${PRT_TEST_MODEL_SYSTEM_LOG:-}" \
    PRT_TEST_REPLY_FAIL="${PRT_TEST_REPLY_FAIL:-0}" \
    PRT_TEST_MODEL_RESPONSE_MODE="${PRT_TEST_MODEL_RESPONSE_MODE:-clean}" \
    PRT_TEST_ASSESS_RESPONSE_MODE="${PRT_TEST_ASSESS_RESPONSE_MODE:-clean}" \
    PRT_TEST_ASSESS_ALWAYS_FAIL="${PRT_TEST_ASSESS_ALWAYS_FAIL:-0}" \
    PRT_TEST_INVENTORY_MODE="${PRT_TEST_INVENTORY_MODE:-single}" \
    PRT_TEST_STALE_AFTER_CALL="${PRT_TEST_STALE_AFTER_CALL:-0}" \
    PRT_TEST_PR_READ_FAIL_AFTER_CALL="${PRT_TEST_PR_READ_FAIL_AFTER_CALL:-0}" \
    PRT_TEST_TWO_FILE_DIFF="${PRT_TEST_TWO_FILE_DIFF:-0}" \
    PRT_TEST_DIFF_PATH="${PRT_TEST_DIFF_PATH:-}" \
    PRT_TEST_BASE_GITATTRIBUTES="${PRT_TEST_BASE_GITATTRIBUTES:-}" \
    PRT_TEST_BASE_ATTRS_FAIL="${PRT_TEST_BASE_ATTRS_FAIL:-0}" \
    PRT_TEST_ISSUE_COMMENT_LOG="${PRT_TEST_ISSUE_COMMENT_LOG:-}" \
    PRT_TEST_OWNED_AUTHOR="${PRT_TEST_OWNED_AUTHOR:-test-bot}" \
    PRT_TEST_ISSUE_COMMENTS_LIST="${PRT_TEST_ISSUE_COMMENTS_LIST:-}" \
    PRT_TEST_PARTIAL_WRITE_FAIL="${PRT_TEST_PARTIAL_WRITE_FAIL:-}" \
    PRT_TEST_WRITE_FAIL_BODY_MATCH="${PRT_TEST_WRITE_FAIL_BODY_MATCH:-}" \
    PRT_TEST_ISSUE_LIST_COUNTFILE="${PRT_TEST_ISSUE_LIST_COUNTFILE:-}" \
    PRT_TEST_ISSUE_LIST_FAIL_AFTER="${PRT_TEST_ISSUE_LIST_FAIL_AFTER:-}" \
    PRT_REVIEW_BACKEND="${PRT_TEST_REVIEW_BACKEND:-}" \
    PRT_FINDINGS_FILE="${PRT_TEST_FINDINGS_FILE:-}" \
    PRT_REVIEW_BASE_SHA="${PRT_TEST_REVIEW_BASE_SHA:-}" \
    PRT_REVIEW_MATERIAL_SHA256="${PRT_TEST_REVIEW_MATERIAL_SHA256:-}" \
    PRT_ASSESS_BACKEND="${PRT_TEST_ASSESS_BACKEND:-}" \
    PRT_ASSESS_RUNNER="${PRT_TEST_ASSESS_RUNNER:-}" \
    PRT_ASSESS_RUNNER_BACKEND="${PRT_TEST_ASSESS_RUNNER_BACKEND:-}" \
    PRT_TEST_RUNNER_MODE="${PRT_TEST_RUNNER_MODE:-clean}" \
    PRT_TEST_RUNNER_LOG="${PRT_TEST_RUNNER_LOG:-}" \
    PRT_TEST_RUNNER_PROV="${PRT_TEST_RUNNER_PROV:-}" \
    PRT_ASSESS_RUNNER_ENV="${PRT_TEST_ASSESS_RUNNER_ENV:-}" \
    PRT_MODEL_BUDGET_SECONDS="${PRT_TEST_MODEL_BUDGET_SECONDS:-}" \
    PRT_ASSESS_RUNNER_SECONDS="${PRT_TEST_ASSESS_RUNNER_SECONDS:-}" \
    PRT_MAX_DIFF_CHARS="$max_diff_chars" \
    PRT_GH_TOKEN="${PRT_TEST_GH_TOKEN:-x}" PRT_REPO=owner/repo PRT_PR_NUMBER=1 \
    PRT_HEAD_SHA=1111111111111111111111111111111111111111 \
    PRT_BOT_LOGIN="test-bot[bot]" PRT_PROXY_URL="${PRT_TEST_PROXY_URL-http://proxy.invalid}" \
    PRT_ASSESS_ENABLED="${PRT_TEST_ASSESS_ENABLED:-}" \
    PRT_MODE="$mode" GITHUB_STEP_SUMMARY="$summary" \
    bash "$ROOT/scripts/pr-review-threads.sh" >"$PRT_TEST_STDOUT_FILE" 2>"$PRT_TEST_STDERR_FILE"
  )
  rc=$?
  [ -n "${PRT_TEST_SUMMARY_COPY:-}" ] && cp "$summary" "$PRT_TEST_SUMMARY_COPY"
  rm -rf "$scratch" "$summary"
  echo "$rc"
}

PRT_TEST_DIFF_COUNTFILE="$(mktemp)"
PRT_TEST_META_COUNTFILE="$(mktemp)"
PRT_TEST_MODEL_COUNTFILE="$(mktemp)"
PRT_TEST_ASSESS_COUNTFILE="$(mktemp)"
PRT_TEST_GRAPHQL_COUNTFILE="$(mktemp)"
PRT_TEST_PATCH_COUNTFILE="$(mktemp)"
PRT_TEST_RESOLVE_COUNTFILE="$(mktemp)"
PRT_TEST_UNRESOLVE_COUNTFILE="$(mktemp)"
PRT_TEST_CREATE_COUNTFILE="$(mktemp)"
PRT_TEST_REPLY_COUNTFILE="$(mktemp)"
PRT_TEST_ISSUE_COMMENT_COUNTFILE="$(mktemp)"
PRT_TEST_STDOUT_FILE="$(mktemp)"
PRT_TEST_STDERR_FILE="$(mktemp)"

rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: clean run (diff/meta/model all succeed first try) exits 0" "0" "$rc"
# Case 4 — C7 regression guard: a successful run must also be readable from
# the job log, not only a failing one.
assert_eq "orchestrator: clean run — stderr carries prt: mode= stage tracing" \
  "true" "$(grep -q '^prt: mode=' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: clean run — stderr carries prt: diff: stage tracing" \
  "true" "$(grep -q '^prt: diff:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

rc="$(run_orchestrator advisory 0 0 1)"
assert_eq "orchestrator: model call failing every chunk marks REVIEW_INCOMPLETE -> exits 1" "1" "$rc"
# Case 3 — the fail-closed exit itself must be loud, not just the exit code.
assert_eq "orchestrator: fail-closed exit — stderr carries REVIEW_INCOMPLETE:" \
  "true" "$(grep -q 'REVIEW_INCOMPLETE:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: fail-closed exit — stderr carries \"failing closed\"" \
  "true" "$(grep -q 'failing closed' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: fail-closed exit — stdout carries a ::error title= annotation" \
  "true" "$(grep -q '::error title=' "$PRT_TEST_STDOUT_FILE" && echo true || echo false)"

# ---- Cases i-iii: model-response resilience (go-kure/.github#60/#61 round
# 2 fold-in) — the salvage pass and the bounded-to-1 retry added around the
# jq -c '.' parse in pr-review-threads.sh's chunk-review loop. Asserted on
# stderr (prt_mark_incomplete's own "REVIEW_INCOMPLETE: <reason>" line and
# prt_log's per-chunk tracing), not on PRT_INCOMPLETE_FILE directly — that
# file lives under the orchestrator's own per-run mktemp -d WORKDIR and is
# removed by its EXIT trap before this subprocess returns, but stderr is
# captured to PRT_TEST_STDERR_FILE by run_orchestrator (not discarded), so
# it carries the same information out.

# Case i — prose-wrapped JSON on the (only) attempt: salvaged without ever
# needing the retry, chunk succeeds, exits 0.
PRT_TEST_MODEL_RESPONSE_MODE=prose
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: prose-wrapped JSON salvaged -> exits 0" "0" "$rc"
assert_eq "orchestrator: prose-wrapped JSON salvaged -> model called exactly once (no retry needed)" \
  "1" "$(cat "$PRT_TEST_MODEL_COUNTFILE")"
assert_eq "orchestrator: prose-wrapped JSON salvaged -> stderr carries the recovered line with salvaged=true" \
  "true" "$(grep -q 'review recovered (retried=false salvaged=true)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Case ii — garbage on the original attempt AND the bounded retry: exits 1,
# with the shape-only diagnostic present in the REVIEW_INCOMPLETE reason —
# never the response text itself (never "not json at all, sorry" verbatim).
PRT_TEST_MODEL_RESPONSE_MODE=garbage
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: garbage on original + retry -> exits 1" "1" "$rc"
assert_eq "orchestrator: garbage on original + retry -> model called exactly twice (original + 1 bounded retry)" \
  "2" "$(cat "$PRT_TEST_MODEL_COUNTFILE")"
assert_eq "orchestrator: garbage on original + retry -> REVIEW_INCOMPLETE carries retry=true, salvage_attempted=true, and the full four-field shape diagnostic" \
  "true" "$(grep -qE 'REVIEW_INCOMPLETE:.*retry=true, salvage_attempted=true \(len=[0-9]+ leading=starts-with-prose class=[a-z-]+ sha16=[0-9a-f]{16}\)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# The fixture response ("not json at all, sorry") matches no known backend
# failure phrase, so it must land in `unrecognized` — the arm that guarantees
# an unanticipated message contributes nothing to the log but its shape.
assert_eq "orchestrator: an unanticipated garbage response classifies as unrecognized" \
  "true" "$(grep -q 'class=unrecognized' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: garbage on original + retry -> REVIEW_INCOMPLETE does NOT leak the raw response text" \
  "false" "$(grep -qF 'not json at all' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Case iii — garbage on the first attempt, clean JSON on the retry: proves
# the retry path actually runs (not just accepted in principle) — exits 0.
PRT_TEST_MODEL_RESPONSE_MODE=garbage_then_clean
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: garbage then clean on retry -> exits 0" "0" "$rc"
assert_eq "orchestrator: garbage then clean on retry -> model called exactly twice (retry fired)" \
  "2" "$(cat "$PRT_TEST_MODEL_COUNTFILE")"
assert_eq "orchestrator: garbage then clean on retry -> stderr carries the recovered line with retried=true" \
  "true" "$(grep -q 'review recovered (retried=true salvaged=false)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean

# Case iii-b (go-kure/.github#95) — every row of a shape-valid `.findings`
# malformed and dropped (prt_normalize_findings rc=1) on BOTH the original
# attempt and the retry: proves the retry fires on this trigger too (model
# called exactly twice), but a response that merely parses is not enough to
# recover — it still exits 1, and must NOT log "review recovered" (the retry
# parsed fine both times, it just never became usable; the log-timing fix in
# §2 means this diagnostic only fires past the norm_rc=1 check).
PRT_TEST_MODEL_RESPONSE_MODE=all_malformed
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: all-malformed .findings on original + retry -> exits 1" "1" "$rc"
assert_eq "orchestrator: all-malformed .findings on original + retry -> model called exactly twice (original + 1 bounded retry)" \
  "2" "$(cat "$PRT_TEST_MODEL_COUNTFILE")"
assert_eq "orchestrator: all-malformed .findings on original + retry -> REVIEW_INCOMPLETE carries the retry=true reason" \
  "true" "$(grep -qF 'REVIEW_INCOMPLETE: chunk 0: .findings missing/null/non-array, or all rows malformed and dropped (after retry=true)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: all-malformed .findings on original + retry -> stderr does NOT carry a false 'review recovered' line" \
  "false" "$(grep -q 'review recovered' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean

# Case iii-c (go-kure/.github#95) — all-malformed on the original attempt,
# a genuinely clean finding on the retry: proves the retry actually
# recovers a normalize-rc=1 response, not just that it fires. Exits 0, no
# REVIEW_INCOMPLETE, and the recovered line IS present (retried=true).
PRT_TEST_MODEL_RESPONSE_MODE=all_malformed_then_clean
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: all-malformed then clean on retry -> exits 0" "0" "$rc"
assert_eq "orchestrator: all-malformed then clean on retry -> model called exactly twice (retry fired)" \
  "2" "$(cat "$PRT_TEST_MODEL_COUNTFILE")"
assert_eq "orchestrator: all-malformed then clean on retry -> no REVIEW_INCOMPLETE" \
  "false" "$(grep -qF 'REVIEW_INCOMPLETE:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: all-malformed then clean on retry -> stderr carries the recovered line with retried=true" \
  "true" "$(grep -q 'review recovered (retried=true salvaged=false)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean

# ---- Count comparisons: two failed queries must not compare equal. The run compares finding
# counts twice: before and after numbering (call 1 reads the input, call 2 the output), and
# between the assessed and the reviewed findings (calls 3 and 4). Seam: an exported jq shim,
# inherited by the orchestrator, fails `jq length` only when prt_json_same_length runs it, by
# its running call number. Before the fix there was no such helper, so no fault is injected and
# every run below exits 0.
t_len_countfile="$(mktemp)"
t_len_run() { # t_len_run FIRST_FAIL LAST_FAIL -> orchestrator exit code (calls FIRST..LAST fail)
  echo 0 > "$t_len_countfile"
  (
    # Invoked indirectly by the orchestrator.
    # shellcheck disable=SC2329,SC2317
    jq() {
      local c
      if [ "$*" = length ] && [ "${FUNCNAME[1]:-}" = prt_json_same_length ]; then
        c="$(_prt_test_bump "$PRT_TEST_LEN_COUNTFILE")"
        { [ "$c" -ge "$PRT_TEST_LEN_FIRST" ] && [ "$c" -le "$PRT_TEST_LEN_LAST" ]; } && return 5
      fi
      command jq "$@"
    }
    export -f jq
    export PRT_TEST_LEN_COUNTFILE="$t_len_countfile" PRT_TEST_LEN_FIRST="$1" PRT_TEST_LEN_LAST="$2"
    run_orchestrator advisory 0 0 0
  )
}
rc="$(t_len_run 99 99)"
assert_eq "orchestrator: count comparisons, no fault injected -> exits 0, four length queries ran" \
  "0 4" "$rc $(cat "$t_len_countfile")"
rc="$(t_len_run 1 2)"
assert_eq "orchestrator: both queries of the numbering comparison fail -> exits 1, not read as covered" "1" "$rc"
assert_eq "orchestrator: both queries of the numbering comparison fail -> the numbering fault is reported" \
  "true" "$(grep -qF 'REVIEW_INCOMPLETE: the review findings could not be numbered' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
rc="$(t_len_run 1 1)"
assert_eq "orchestrator: the first query of the numbering comparison fails alone -> exits 1" "1" "$rc"
rc="$(t_len_run 2 2)"
assert_eq "orchestrator: the second query of the numbering comparison fails alone -> exits 1" "1" "$rc"
rc="$(t_len_run 3 4)"
assert_eq "orchestrator: both queries of the assessed/reviewed comparison fail -> exits 1, not read as covered" "1" "$rc"
assert_eq "orchestrator: both queries of the assessed/reviewed comparison fail -> the mismatch is reported" \
  "true" "$(grep -qF 'REVIEW_INCOMPLETE: the assessed findings do not match the reviewed findings' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
rc="$(t_len_run 3 3)"
assert_eq "orchestrator: the first query of the assessed/reviewed comparison fails alone -> exits 1" "1" "$rc"
rc="$(t_len_run 4 4)"
assert_eq "orchestrator: the second query of the assessed/reviewed comparison fails alone -> exits 1" "1" "$rc"
rm -f "$t_len_countfile"
unset t_len_countfile
unset -f t_len_run

# ---- Cases iv-viii: assessment-call resilience (assess-resilience
# workstream) — prt_model_assess's exit-status check, and the identical
# salvage-then-retry treatment given to the review call above (Cases i-iii),
# now mirrored for the assess call. Case ix, further below, is the review
# call's own mirror of Case viii. The review call is forced to
# clean_with_finding once here and stays that way through all five cases
# below (iv-viii — the mode is never reset in between) so the assess call
# actually fires at all (pr-review-threads.sh:512 skips assessment for an
# empty-findings chunk, and every other scenario in this file leaves review
# findings empty on purpose).
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding

# Case iv — assess call itself fails at the transport layer (non-2xx/curl/
# empty-content — model.sh:407-426), on both the only attempt and would-be
# retry alike: prt_model_assess's own exit status is checked explicitly and
# reported as a transport fault, never silently parsed as empty JSON (root
# cause 2). No salvage/retry is attempted for a transport fault — there is no
# response body to salvage. go-kure/.github#98: this chunk's review DID run
# (it's the assessment that failed), so this is REVIEW_DEGRADED and exits 0,
# not the REVIEW_INCOMPLETE/exit-1 this used to be — the finding still
# carries verdict:null via the orchestrator's own fallback (unchanged).
PRT_TEST_ASSESS_ALWAYS_FAIL=1
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: assess call transport failure -> exits 0 (degraded, not fatal)" "0" "$rc"
assert_eq "orchestrator: assess call transport failure -> assess model called exactly once (no salvage/retry on a transport fault)" \
  "1" "$(cat "$PRT_TEST_ASSESS_COUNTFILE")"
assert_eq "orchestrator: assess call transport failure -> REVIEW_DEGRADED reports it as a transport/proxy error, not a parse failure" \
  "true" "$(grep -qE 'REVIEW_DEGRADED:.*assessment call failed \(transport/proxy error, exit [0-9]+\)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: assess call transport failure -> does NOT also mark REVIEW_INCOMPLETE (no dual-marking)" \
  "false" "$(grep -qF 'REVIEW_INCOMPLETE:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_ASSESS_ALWAYS_FAIL=0

# Case iv-b — round 4 (go-kure/.github#101 second review pass,
# chatgpt-codex-connector[bot]): Case iv above (assess transport fault) is
# REVIEW_DEGRADED without ever dropping a row — the chunk's one finding
# survives with verdict:null. Capture the actual posted advisory comment body
# and confirm it does not misdescribe this as a drop: the round-3 banner text
# said "some rows were dropped ... reflects only the surviving rows"
# unconditionally, which was never true for this reason.
PRT_TEST_ISSUE_COMMENT_BODY_FILE="$(mktemp)"
PRT_TEST_ASSESS_ALWAYS_FAIL=1
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: advisory + assess transport fault -> exits 0 (degraded, not fatal)" "0" "$rc"
assert_eq "orchestrator: advisory + assess transport fault -> posted comment shows the degraded-warning banner" \
  "true" "$(grep -qF 'This review run was degraded' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
assert_eq "orchestrator: advisory + assess transport fault -> posted comment does NOT assert rows WERE dropped (old wording)" \
  "false" "$(grep -qiF 'some rows were dropped' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
assert_eq "orchestrator: advisory + assess transport fault -> posted comment does NOT say 'surviving rows'" \
  "false" "$(grep -qiF 'surviving rows' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
assert_eq "orchestrator: advisory + assess transport fault -> posted comment still shows the unverdicted finding's row" \
  "true" "$(grep -qF '| Medium | other | x.go |' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
PRT_TEST_ASSESS_ALWAYS_FAIL=0
rm -f "$PRT_TEST_ISSUE_COMMENT_BODY_FILE"
unset PRT_TEST_ISSUE_COMMENT_BODY_FILE

# Case v — assess response is prose-wrapped JSON on the (only) attempt:
# salvaged without ever needing the retry, exits 0.
PRT_TEST_ASSESS_RESPONSE_MODE=prose
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: assess prose-wrapped JSON salvaged -> exits 0" "0" "$rc"
assert_eq "orchestrator: assess prose-wrapped JSON salvaged -> assess model called exactly once (no retry needed)" \
  "1" "$(cat "$PRT_TEST_ASSESS_COUNTFILE")"
assert_eq "orchestrator: assess prose-wrapped JSON salvaged -> stderr carries the recovered line with salvaged=true" \
  "true" "$(grep -q 'assess recovered (retried=false salvaged=true)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Case vi — assess response is garbage on the original attempt AND the
# bounded retry: a residual parse failure after salvage+retry still means
# the review itself ran, only the verdicts are missing — go-kure/.github#98
# moves this to REVIEW_DEGRADED, exits 0 (previously REVIEW_INCOMPLETE/exit
# 1), with the shape-only diagnostic present and the raw response text never
# leaked.
PRT_TEST_ASSESS_RESPONSE_MODE=garbage
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: assess garbage on original + retry -> exits 0 (degraded, not fatal)" "0" "$rc"
assert_eq "orchestrator: assess garbage on original + retry -> assess model called exactly twice (original + 1 bounded retry)" \
  "2" "$(cat "$PRT_TEST_ASSESS_COUNTFILE")"
assert_eq "orchestrator: assess garbage on original + retry -> REVIEW_DEGRADED carries retry=true, salvage_attempted=true, and the full four-field shape diagnostic" \
  "true" "$(grep -qE 'REVIEW_DEGRADED:.*assessment response was not valid JSON after retry=true, salvage_attempted=true \(len=[0-9]+ leading=starts-with-prose class=[a-z-]+ sha16=[0-9a-f]{16}\)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: assess garbage on original + retry -> REVIEW_DEGRADED does NOT leak the raw response text" \
  "false" "$(grep -qF 'not json at all' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Case vii — assess response is garbage on the first attempt, clean JSON on
# the retry: proves the assess retry path actually runs, not just accepted
# in principle — exits 0.
PRT_TEST_ASSESS_RESPONSE_MODE=garbage_then_clean
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: assess garbage then clean on retry -> exits 0" "0" "$rc"
assert_eq "orchestrator: assess garbage then clean on retry -> assess model called exactly twice (retry fired)" \
  "2" "$(cat "$PRT_TEST_ASSESS_COUNTFILE")"
assert_eq "orchestrator: assess garbage then clean on retry -> stderr carries the recovered line with retried=true" \
  "true" "$(grep -q 'assess recovered (retried=true salvaged=false)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Case viii — mixed failure: garbage (parse failure) on the original attempt,
# a transport fault on the retry. Guards the exact bug a codex round-1 review
# found on this branch: the retry's own exit status must be checked
# independently, or a transport fault there gets mislabeled as "not valid
# JSON" (and prt_response_shape gets computed over an empty string instead
# of not being reached at all). Case ix, immediately below, is the same
# scenario against the review call instead of the assess call.
# go-kure/.github#98: moved to REVIEW_DEGRADED, exits 0 (previously
# REVIEW_INCOMPLETE/exit 1) — same reasoning as Case iv/vi above.
PRT_TEST_ASSESS_RESPONSE_MODE=garbage_then_fail
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: assess garbage then transport-fail on retry -> exits 0 (degraded, not fatal)" "0" "$rc"
assert_eq "orchestrator: assess garbage then transport-fail on retry -> assess model called exactly twice (original + 1 bounded retry)" \
  "2" "$(cat "$PRT_TEST_ASSESS_COUNTFILE")"
assert_eq "orchestrator: assess garbage then transport-fail on retry -> REVIEW_DEGRADED reports the RETRY as a transport/proxy error, not a parse failure" \
  "true" "$(grep -qE 'REVIEW_DEGRADED:.*assessment call failed on retry \(transport/proxy error, exit [0-9]+\)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: assess garbage then transport-fail on retry -> does NOT also report it as an invalid-JSON failure" \
  "false" "$(grep -qF 'assessment response was not valid JSON' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_ASSESS_RESPONSE_MODE=clean
PRT_TEST_MODEL_RESPONSE_MODE=clean

# Case viii-b — .assessments shape rejected by prt_join_assessment
# (:604-605 in pr-review-threads.sh, distinct from Cases iv/vi/viii above:
# the assessment response here DOES parse as valid JSON, it's the
# `.assessments` field itself that's the wrong shape) — go-kure/.github#98:
# REVIEW_DEGRADED, exits 0, every finding in the chunk stays unverdicted.
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_ASSESS_RESPONSE_MODE=bad_shape
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: .assessments non-array (valid JSON, wrong shape) -> exits 0 (degraded, not fatal)" "0" "$rc"
assert_eq "orchestrator: .assessments non-array -> REVIEW_DEGRADED names the join failure" \
  "true" "$(grep -qF 'REVIEW_DEGRADED: chunk 0: .assessments missing/null/non-array' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: .assessments non-array -> does NOT also mark REVIEW_INCOMPLETE" \
  "false" "$(grep -qF 'REVIEW_INCOMPLETE:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_ASSESS_RESPONSE_MODE=clean
PRT_TEST_MODEL_RESPONSE_MODE=clean

# Case ix — review-call mirror of Case viii: garbage (parse failure) on the
# original review attempt, a transport fault on review's own retry. Round-2
# confirm-round fold-in: a full-scope codex review found this same
# mislabeling gap open on the review call's retry (only the assess call's
# retry had been fixed) — the review call's retry exit status must be
# checked independently, or a transport fault there gets mislabeled as
# "review response was not valid JSON".
PRT_TEST_MODEL_RESPONSE_MODE=garbage_then_fail
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: review garbage then transport-fail on retry -> exits 1" "1" "$rc"
assert_eq "orchestrator: review garbage then transport-fail on retry -> model called exactly twice (original + 1 bounded retry)" \
  "2" "$(cat "$PRT_TEST_MODEL_COUNTFILE")"
assert_eq "orchestrator: review garbage then transport-fail on retry -> REVIEW_INCOMPLETE reports the RETRY as a transport/proxy error, not a parse failure" \
  "true" "$(grep -qE 'REVIEW_INCOMPLETE:.*review call failed on retry \(transport/proxy error, exit [0-9]+\)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: review garbage then transport-fail on retry -> does NOT also report it as an invalid-JSON failure" \
  "false" "$(grep -qF 'review response was not valid JSON' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean

# ---- Cases xi-xii: the degraded/incomplete split at prt_normalize_findings
# itself (finding.sh:79-151, go-kure/.github#98) — a shape-valid `.findings`
# array with a malformed row dropped (rc=2) is degraded; `.findings` missing
# entirely (rc=1) stays fatal. Both share the same review-call response path
# (unlike Cases iv-viii above, which are all assess-call failures), so they
# are asserted here rather than folded into the assess-resilience block.

# Case xi — `.findings` key missing entirely: nothing in this chunk was
# reviewed at all on either attempt (this mode returns the same
# missing-key body every call, so the go-kure/.github#95 retry fires and
# still finds nothing usable) — stays fatal (unchanged fatal behavior —
# this case proves the fatal/degraded split by contrast with Case xii
# below).
PRT_TEST_MODEL_RESPONSE_MODE=no_findings_key
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: .findings missing entirely -> exits 1 (stays fatal)" "1" "$rc"
assert_eq "orchestrator: .findings missing entirely -> REVIEW_INCOMPLETE names the missing-key case" \
  "true" "$(grep -qF 'REVIEW_INCOMPLETE: chunk 0: .findings missing/null/non-array' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# go-kure/.github#95: the retry now fires on this rc=1 trigger too — model
# called exactly twice (original + 1 bounded retry), not once as before.
assert_eq "orchestrator: .findings missing entirely -> model called exactly twice (retry fired on rc=1, still unusable)" \
  "2" "$(cat "$PRT_TEST_MODEL_COUNTFILE")"
PRT_TEST_MODEL_RESPONSE_MODE=clean

# Case xii — `.findings` array-shaped, one row malformed and dropped, the
# other survives: partial-drop, degraded not fatal.
PRT_TEST_MODEL_RESPONSE_MODE=partial_drop
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: partial-drop (one malformed row dropped, rest survives) -> exits 0 (degraded, not fatal)" "0" "$rc"
assert_eq "orchestrator: partial-drop -> REVIEW_DEGRADED names it with the partial-drop marker" \
  "true" "$(grep -qF 'REVIEW_DEGRADED: chunk 0: partial-drop' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: partial-drop -> does NOT also mark REVIEW_INCOMPLETE" \
  "false" "$(grep -qF 'REVIEW_INCOMPLETE:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# go-kure/.github#95 mirror-image assertion: rc=2 must stay usable WITHOUT
# a retry — only rc=1 triggers one. Nothing before this proved an
# implementation didn't mistakenly retry on any non-zero
# prt_normalize_findings return instead of on rc=1 specifically.
assert_eq "orchestrator: partial-drop -> model called exactly once (rc=2 is usable on the first attempt, no retry)" \
  "1" "$(cat "$PRT_TEST_MODEL_COUNTFILE")"
PRT_TEST_MODEL_RESPONSE_MODE=clean

# Case xii-b — advisory mode, a partial-drop run (Case xii's exact review
# response) whose one surviving finding is then assessed FALSE_POSITIVE and
# filtered out before rendering (pr-review-threads.sh:919), so the advisory
# table's own count is 0 despite the run being REVIEW_DEGRADED — the exact
# admission-test scenario from the chatgpt-codex-connector[bot] review
# (go-kure/.github#101#pullrequestreview-5028172237): a human reading the
# posted comment must still see the run was degraded, not "No issues
# found.", or the dropped row disappears with no trace on this live surface.
PRT_TEST_ISSUE_COMMENT_BODY_FILE="$(mktemp)"
PRT_TEST_MODEL_RESPONSE_MODE=partial_drop
PRT_TEST_ASSESS_RESPONSE_MODE=false_positive_survivor
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: advisory + partial-drop + surviving finding assessed FALSE_POSITIVE -> exits 0 (degraded, not fatal)" \
  "0" "$rc"
assert_eq "orchestrator: advisory + partial-drop + all-filtered -> REVIEW_DEGRADED still recorded" \
  "true" "$(grep -qF 'REVIEW_DEGRADED: chunk 0: partial-drop' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: advisory + partial-drop + all-filtered -> posted comment does NOT say 'No issues found.'" \
  "false" "$(grep -qF 'No issues found.' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
assert_eq "orchestrator: advisory + partial-drop + all-filtered -> posted comment shows the degraded-warning banner" \
  "true" "$(grep -qF 'This review run was degraded' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
assert_eq "orchestrator: advisory + partial-drop + all-filtered -> posted comment names the partial-drop reason" \
  "true" "$(grep -qF 'partial-drop' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_ASSESS_RESPONSE_MODE=clean
rm -f "$PRT_TEST_ISSUE_COMMENT_BODY_FILE"
unset PRT_TEST_ISSUE_COMMENT_BODY_FILE

# go-kure/.github#183 part A — enforce mode, a finding assessed FALSE_POSITIVE
# with no thread (the default owned fp never matches) is suppressed (row 2):
# no thread, no reply, and the step summary lists it with its content.
PRT_TEST_SUMMARY_COPY="$(mktemp)"
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_ASSESS_RESPONSE_MODE=false_positive_survivor
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #183: suppressed finding -> exits 0, no thread created, suppressed=1" \
  "0 0 true" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE") $(grep -qE 'done:.*suppressed=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #183: the step summary lists the suppressed finding with its line, issue and reasoning" \
  "true" "$(grep -qF "| \`$(prt_fp_base x.go other)\` | Medium | x.go | 1 | i | not a real issue |" "$PRT_TEST_SUMMARY_COPY" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_ASSESS_RESPONSE_MODE=clean
rm -f "$PRT_TEST_SUMMARY_COPY"
unset PRT_TEST_SUMMARY_COPY

# Case xiii — the reconciliation this whole mechanism exists for
# (go-kure/.github#98): a partial-drop run (Case xii's exact scenario) must
# still set incomplete_now=true in the absence loop, so an owned thread this
# run's surviving finding doesn't match (PRT_TEST_OWNED_FP is deliberately
# NOT the fp the "x.go"/"other" finding above hashes to) is NOT wrongly
# auto-resolved on what would otherwise be a second-absence sighting
# (PRT_TEST_FIRST_ABSENT_SHA differs from PRT_HEAD_SHA). Without the fold-in
# at pr-review-threads.sh's absence loop, prt_decide_absent would return
# REPLY_RESOLVE here (row 10) — a malformed row's still-open thread wrongly
# read as fixed. With it, the review_incomplete=true branch
# (reconcile.sh:119-122) fires first and returns CLEAR_MARKER instead (a
# non-empty first_absent_sha forces a clean restart rather than a resolve).
PRT_TEST_MODEL_RESPONSE_MODE=partial_drop
PRT_TEST_OWNED_FP="0000000000000000"
PRT_TEST_FIRST_ABSENT_SHA="2222222222222222222222222222222222222222"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: partial-drop + owned thread absent this run -> exits 0 (degraded, not fatal)" "0" "$rc"
assert_eq "orchestrator: partial-drop + owned thread absent this run -> resolve count 0 (NOT wrongly auto-resolved)" \
  "0" "$(cat "$PRT_TEST_RESOLVE_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: partial-drop + owned thread absent this run -> PATCH count >= 1 (CLEAR_MARKER, not REPLY_RESOLVE)" \
  "true" "$([ "$(cat "$PRT_TEST_PATCH_COUNTFILE")" -ge 1 ] && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_FIRST_ABSENT_SHA=""

# ---- Cases xiv-xv (go-kure/.github#95): a genuine two-chunk run ----
# The orchestrator harness above cannot otherwise produce more than one
# chunk — PRT_TEST_TWO_FILE_DIFF (fake_curl_orchestrator's diff arm) serves
# a second `diff --git` record, and the max-diff-chars override (150,
# between the ~103-byte single-record size and the ~208-byte combined size)
# forces prt_split_diff to land the split cleanly at that record boundary
# rather than the unrelated hard-ceiling hunk-truncation path. This is what
# lets a two-chunk fixture exist at all: reusing all_malformed (malformed on
# every call, unconditionally) would also poison chunk 1's single call, so
# two_chunk_first_all_malformed/_second_empty (call-count-aware, not
# run-global) are used instead — see their definitions above.

# Case xiv — chunk 0 exhausts its retry and degrades (routed into
# review_parse_failures, tagged review-parse-failed:), chunk 1 succeeds:
# the plan's central claim ("the multi-chunk case is closed by the
# routing") had no regression test without this — an implementation that
# mistakenly dual-marks the rc=1 site (also calling prt_mark_incomplete,
# forbidden per state.sh:10-19) would fail every single-chunk fixture above
# identically whether or not the multi-chunk routing actually works.
# Combined with Case xiii's owned-thread setup: chunk 0's existing thread
# must not be read as absent this run (the incomplete_now fold-in,
# pr-review-threads.sh's absence loop, immediately before its owned-thread
# loop) even though the run itself exits 0 (degraded, not incomplete).
PRT_TEST_MODEL_RESPONSE_MODE=two_chunk_first_all_malformed
PRT_TEST_TWO_FILE_DIFF=1
PRT_TEST_OWNED_FP="0000000000000000"
PRT_TEST_FIRST_ABSENT_SHA="2222222222222222222222222222222222222222"
rc="$(run_orchestrator enforce 0 0 0 150)"
assert_eq "orchestrator: two-chunk run, chunk 0 degrades + chunk 1 succeeds -> exits 0" "0" "$rc"
assert_eq "orchestrator: two-chunk degrade -> REVIEW_DEGRADED carries the review-parse-failed tag for chunk 0" \
  "true" "$(grep -qF 'REVIEW_DEGRADED: review-parse-failed: chunk 0: .findings missing/null/non-array' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: two-chunk degrade -> stdout carries the ::warning annotation, not ::error" \
  "true false" "$(grep -q '::warning title=PR review threads degraded' "$PRT_TEST_STDOUT_FILE" && echo true || echo false) $(grep -q '::error title=' "$PRT_TEST_STDOUT_FILE" && echo true || echo false)"
assert_eq "orchestrator: two-chunk degrade -> no REVIEW_INCOMPLETE anywhere in stderr" \
  "false" "$(grep -qF 'REVIEW_INCOMPLETE:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: two-chunk degrade -> chunk 1's finding was still reviewed (model called 3x: chunk 0's original+retry, chunk 1's single call)" \
  "3" "$(cat "$PRT_TEST_MODEL_COUNTFILE")"
assert_eq "orchestrator: two-chunk degrade -> owned thread absent this run resolve count 0 (NOT wrongly auto-resolved)" \
  "0" "$(cat "$PRT_TEST_RESOLVE_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: two-chunk degrade -> PATCH count >= 1 (CLEAR_MARKER, not REPLY_RESOLVE — the incomplete_now fold-in fired)" \
  "true" "$([ "$(cat "$PRT_TEST_PATCH_COUNTFILE")" -ge 1 ] && echo true || echo false)"
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_FIRST_ABSENT_SHA=""

# Case xv — enforce-mode sibling: chunk 0 still degrades the same way, but
# chunk 1 comes back genuinely clean with ZERO findings. §3's "inherited for
# free" claim names two safety nets keyed off the review-parse-failed tag,
# not one (Case xiv above covers the first, the absence-loop fold-in) — this
# covers the second: the enforce clean-verdict gate must not post "Reviewed,
# no findings" over a PR with an unreviewed chunk just because the chunks
# that DID run happened to find nothing (the exclusion at
# pr-review-threads.sh's enforce-mode gate, docs/pr-review-threads.md's
# "Failure surface").
PRT_TEST_ISSUE_COMMENT_BODY_FILE="$(mktemp)"
PRT_TEST_MODEL_RESPONSE_MODE=two_chunk_first_all_malformed_second_empty
PRT_TEST_TWO_FILE_DIFF=1
rc="$(run_orchestrator enforce 0 0 0 150)"
assert_eq "orchestrator: two-chunk degrade + chunk 1 empty -> exits 0" "0" "$rc"
assert_eq "orchestrator: two-chunk degrade + chunk 1 empty -> REVIEW_DEGRADED carries the review-parse-failed tag" \
  "true" "$(grep -qF 'REVIEW_DEGRADED: review-parse-failed: chunk 0:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: two-chunk degrade + chunk 1 empty -> enforce mode does NOT post a clean-verdict 'Reviewed, no findings' comment" \
  "false" "$(grep -qiF 'Reviewed, no findings' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" 2>/dev/null && echo true || echo false)"
PRT_TEST_TWO_FILE_DIFF=0
PRT_TEST_MODEL_RESPONSE_MODE=clean
rm -f "$PRT_TEST_ISSUE_COMMENT_BODY_FILE"
unset PRT_TEST_ISSUE_COMMENT_BODY_FILE

# Case xv-b (go-kure/.github#151): withholding the clean verdict alone left
# the PR page silent about the unreviewed chunk. The same degraded fixture
# must now POST one partial-review comment naming the head SHA and chunk 0;
# a second degraded run that finds that comment must PATCH it rather than
# post another; and a later run that assesses every chunk must rewrite it to
# superseded. The exit code and the done: line stay what #107 made them.
PRT_TEST_ISSUE_COMMENT_LOG="$(mktemp)"
PRT_TEST_MODEL_RESPONSE_MODE=two_chunk_first_all_malformed_second_empty
PRT_TEST_TWO_FILE_DIFF=1
rc="$(run_orchestrator enforce 0 0 0 150)"
assert_eq "orchestrator: partial-review comment -> degraded run still exits 0" "0" "$rc"
assert_eq "orchestrator: partial-review comment -> POSTed exactly once, nothing PATCHed" \
  "1 0" "$(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG") $(grep -c '^PATCH ' "$PRT_TEST_ISSUE_COMMENT_LOG")"
assert_eq "orchestrator: partial-review comment -> ends with the partial-review marker" \
  "true" "$(grep -qxF "  | $PRT_MARKER_PARTIAL" "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"
assert_eq "orchestrator: partial-review comment -> names the head SHA" \
  "true" "$(grep -qF '1111111111111111111111111111111111111111' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"
assert_eq "orchestrator: partial-review comment -> names chunk 0 and its failure, without the internal tag" \
  "true false" "$(grep -qF '  | - chunk 0: .findings missing/null/non-array' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false) $(grep -qF 'review-parse-failed' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"
assert_eq "orchestrator: partial-review comment -> still no clean-verdict comment" \
  "false" "$(grep -qF 'Reviewed, no findings' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"
assert_eq "orchestrator: partial-review comment -> done: line unchanged (one degraded reason, the parse failure itself)" \
  "true" "$(grep -qE '^prt: done: .* incomplete=0 degraded=1$' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_ISSUE_COMMENTS_LIST='[{"id":77,"user":{"login":"test-bot[bot]"},"body":"earlier partial review\n<!-- gokure-pr-review:v1-partial -->"}]'
rc="$(run_orchestrator enforce 0 0 0 150)"
assert_eq "orchestrator: second degraded run -> exits 0" "0" "$rc"
assert_eq "orchestrator: second degraded run -> PATCHes the existing partial-review comment, posts nothing new" \
  "0 1" "$(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG") $(grep -c '^PATCH comments/77$' "$PRT_TEST_ISSUE_COMMENT_LOG")"
assert_eq "orchestrator: second degraded run -> the edited body is a live partial review, not superseded" \
  "true false" "$(grep -qF 'chunk 0:' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false) $(grep -qF "$PRT_MARKER_STATE_SUPERSEDED" "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"
assert_eq "orchestrator: second degraded run with no prior clean comment -> PATCHes nothing but the partial comment" \
  "1" "$(grep -c '^PATCH ' "$PRT_TEST_ISSUE_COMMENT_LOG")"

# Case xv-b2 (go-kure/.github#151 review): a zero-findings degraded run on a
# PR that already carries a clean verdict from an earlier SHA. Neither the
# clean-verdict upsert nor the findings>0 supersede runs, so without its own
# branch the old "Reviewed, no findings" stayed live, with no superseded state
# line, next to the new partial-review comment. It must be rewritten in place
# to superseded, and the partial comment must still be written.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_ISSUE_COMMENTS_LIST='[{"id":88,"user":{"login":"test-bot[bot]"},"body":"old clean\n<!-- gokure-pr-review:v1-clean -->"}]'
rc="$(run_orchestrator enforce 0 0 0 150)"
assert_eq "orchestrator: degraded run over a prior clean verdict -> exits 0" "0" "$rc"
assert_eq "orchestrator: degraded run over a prior clean verdict -> PATCHes the clean comment once and POSTs the partial comment once" \
  "1 1" "$(grep -c '^PATCH comments/88$' "$PRT_TEST_ISSUE_COMMENT_LOG") $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG")"
assert_eq "orchestrator: degraded run over a prior clean verdict -> the rewrite carries the superseded state line and says why" \
  "true true" "$(grep -qxF "  | $PRT_MARKER_STATE_SUPERSEDED" "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false) $(grep -qF 'that is not a clean verdict' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"
assert_eq "orchestrator: degraded run over a prior clean verdict -> the rewritten comment keeps the clean marker" \
  "true" "$(grep -qxF "  | $PRT_MARKER_CLEAN" "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"
assert_eq "orchestrator: degraded run over a prior clean verdict -> no new degraded reason" \
  "true" "$(grep -qE '^prt: done: .* incomplete=0 degraded=1$' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Its write failing is a degraded reason, never REVIEW_INCOMPLETE.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_WRITE_FAIL_BODY_MATCH='that is not a clean verdict'
rc="$(run_orchestrator enforce 0 0 0 150)"
PRT_TEST_WRITE_FAIL_BODY_MATCH=''
assert_eq "orchestrator: clean supersede (partial review) write fails -> exits 0" "0" "$rc"
assert_eq "orchestrator: clean supersede (partial review) write fails -> that PATCH failed, the partial comment is still POSTed" \
  "1 1" "$(grep -c '^FAILED PATCH comments/88$' "$PRT_TEST_ISSUE_COMMENT_LOG") $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG")"
assert_eq "orchestrator: clean supersede (partial review) write fails -> REVIEW_DEGRADED names it, no REVIEW_INCOMPLETE" \
  "true false" "$(grep -qF 'failed to supersede the clean-verdict comment for a partial review' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qF 'REVIEW_INCOMPLETE' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_ISSUE_COMMENTS_LIST='[{"id":77,"user":{"login":"test-bot[bot]"},"body":"earlier partial review\n<!-- gokure-pr-review:v1-partial -->"}]'

: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_TWO_FILE_DIFF=0
PRT_TEST_MODEL_RESPONSE_MODE=clean
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: later clean run -> exits 0" "0" "$rc"
assert_eq "orchestrator: later clean run -> rewrites the partial-review comment in place" \
  "1" "$(grep -c '^PATCH comments/77$' "$PRT_TEST_ISSUE_COMMENT_LOG")"
assert_eq "orchestrator: later clean run -> the rewrite says every chunk was assessed and carries the superseded state line" \
  "true true" "$(grep -qF 'assessed every chunk' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false) $(grep -qxF "  | $PRT_MARKER_STATE_SUPERSEDED" "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"
assert_eq "orchestrator: later clean run -> the superseded partial comment keeps its marker as the last line" \
  "  | $PRT_MARKER_PARTIAL" "$(tail -1 "$PRT_TEST_ISSUE_COMMENT_LOG")"

# A run that never had a partial comment must not get one on a clean run.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_ISSUE_COMMENTS_LIST=''
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: clean run with no prior partial comment -> no partial-review write" \
  "false" "$(grep -qF "$PRT_MARKER_PARTIAL" "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"

# Case xv-c (go-kure/.github#151 review): the partial-review comment is
# informational, so a PR read failure in either of its freshness checks must
# skip the write as REVIEW_DEGRADED, never REVIEW_INCOMPLETE — the extra GET
# must not fail an otherwise successful review. Each baseline run counts the
# GET pulls/<N> reads; the partial-review block makes the last two (outer
# check, then the re-check before the write), so failing every read after
# call T-2 or T-1 lands a status-2 freshness failure on exactly one of them.
# The asserted reason text names which check failed, so a failure landing
# anywhere else cannot pass these assertions.
PRT_TEST_MODEL_RESPONSE_MODE=two_chunk_first_all_malformed_second_empty
PRT_TEST_TWO_FILE_DIFF=1
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
rc="$(run_orchestrator enforce 0 0 0 150)"
pf_reads="$(cat "$PRT_TEST_META_COUNTFILE")"
assert_eq "orchestrator: partial-review freshness baseline -> exits 0 and POSTs the partial comment" \
  "0 1" "$rc $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG")"
for pf_case in "1:partial-review comment upsert" "2:partial-review comment"; do
  : > "$PRT_TEST_ISSUE_COMMENT_LOG"
  PRT_TEST_PR_READ_FAIL_AFTER_CALL=$((pf_reads - ${pf_case%%:*}))
  rc="$(run_orchestrator enforce 0 0 0 150)"
  assert_eq "orchestrator: '${pf_case#*:}' freshness read fails (status 2) -> exits 0 (degraded, not fatal)" "0" "$rc"
  assert_eq "orchestrator: '${pf_case#*:}' freshness read fails -> REVIEW_DEGRADED names the skipped write" \
    "true" "$(grep -qF "REVIEW_DEGRADED: ${pf_case#*:}: PR read failed" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
  assert_eq "orchestrator: '${pf_case#*:}' freshness read fails -> does NOT mark REVIEW_INCOMPLETE" \
    "false" "$(grep -qF 'REVIEW_INCOMPLETE' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
  assert_eq "orchestrator: '${pf_case#*:}' freshness read fails -> no partial-review comment written" \
    "0" "$(grep -c '^POST \|^PATCH ' "$PRT_TEST_ISSUE_COMMENT_LOG")"
done
PRT_TEST_PR_READ_FAIL_AFTER_CALL=0

# The supersede branch (every chunk assessed, an existing partial comment).
PRT_TEST_TWO_FILE_DIFF=0
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_ISSUE_COMMENTS_LIST='[{"id":77,"user":{"login":"test-bot[bot]"},"body":"earlier partial review\n<!-- gokure-pr-review:v1-partial -->"}]'
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
rc="$(run_orchestrator enforce 0 0 0)"
pf_reads="$(cat "$PRT_TEST_META_COUNTFILE")"
assert_eq "orchestrator: partial-review supersede baseline -> exits 0 and PATCHes comment 77" \
  "0 1" "$rc $(grep -c '^PATCH comments/77$' "$PRT_TEST_ISSUE_COMMENT_LOG")"
for pf_case in "1:partial-review supersede upsert" "2:partial-review supersede check"; do
  : > "$PRT_TEST_ISSUE_COMMENT_LOG"
  PRT_TEST_PR_READ_FAIL_AFTER_CALL=$((pf_reads - ${pf_case%%:*}))
  rc="$(run_orchestrator enforce 0 0 0)"
  assert_eq "orchestrator: '${pf_case#*:}' freshness read fails (status 2) -> exits 0 (degraded, not fatal)" "0" "$rc"
  assert_eq "orchestrator: '${pf_case#*:}' freshness read fails -> REVIEW_DEGRADED names the skipped write" \
    "true" "$(grep -qF "REVIEW_DEGRADED: ${pf_case#*:}: PR read failed" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
  assert_eq "orchestrator: '${pf_case#*:}' freshness read fails -> does NOT mark REVIEW_INCOMPLETE" \
    "false" "$(grep -qF 'REVIEW_INCOMPLETE' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
  assert_eq "orchestrator: '${pf_case#*:}' freshness read fails -> comment 77 left as it stands" \
    "0" "$(grep -c '^PATCH comments/77$' "$PRT_TEST_ISSUE_COMMENT_LOG")"
done
PRT_TEST_PR_READ_FAIL_AFTER_CALL=0
# A stale head at the same re-check keeps the superseded routing: the only
# degraded reason is the staleness one, so the run takes the quiet exit.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_STALE_AFTER_CALL=$((pf_reads - 1))
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: head moves before the partial-review supersede write -> exits 0, stale reason, quiet 'Stale run' line" \
  "0 true true" "$rc $(grep -qF 'REVIEW_DEGRADED: partial-review supersede upsert: stale head SHA (run superseded)' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qF 'Stale run: head moved; a newer run is already queued' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_STALE_AFTER_CALL=0

# The write itself failing (HTTP 500) is informational too: each of the three
# partial-comment writes (first POST, PATCH of an existing one, supersede
# PATCH) degrades the run with a reason naming the write, never marks it
# REVIEW_INCOMPLETE, and the run still exits 0.
PRT_TEST_PARTIAL_WRITE_FAIL=1
PRT_TEST_MODEL_RESPONSE_MODE=two_chunk_first_all_malformed_second_empty
PRT_TEST_TWO_FILE_DIFF=1
for pw_case in "POST:[]:failed to post the partial-review comment (HTTP 500)" \
  "PATCH:77:failed to post the partial-review comment (HTTP 500)" \
  "PATCH-supersede:77:failed to supersede the partial-review comment (HTTP 500)"; do
  pw_label="${pw_case%%:*}"
  pw_rest="${pw_case#*:}"
  pw_reason="${pw_rest#*:}"
  if [ "${pw_rest%%:*}" = 77 ]; then
    PRT_TEST_ISSUE_COMMENTS_LIST='[{"id":77,"user":{"login":"test-bot[bot]"},"body":"earlier partial review\n<!-- gokure-pr-review:v1-partial -->"}]'
  else
    PRT_TEST_ISSUE_COMMENTS_LIST='[]'
  fi
  if [ "$pw_label" = PATCH-supersede ]; then
    PRT_TEST_MODEL_RESPONSE_MODE=clean
    PRT_TEST_TWO_FILE_DIFF=0
  fi
  : > "$PRT_TEST_ISSUE_COMMENT_LOG"
  rc="$(run_orchestrator enforce 0 0 0 150)"
  assert_eq "orchestrator: partial-review $pw_label write fails (HTTP 500) -> exits 0 (degraded, not fatal)" "0" "$rc"
  assert_eq "orchestrator: partial-review $pw_label write fails -> the write was attempted and refused" \
    "1" "$(grep -c "^FAILED ${pw_label%%-*} " "$PRT_TEST_ISSUE_COMMENT_LOG")"
  assert_eq "orchestrator: partial-review $pw_label write fails -> REVIEW_DEGRADED names the failed write" \
    "true" "$(grep -qF "REVIEW_DEGRADED: $pw_reason" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
  assert_eq "orchestrator: partial-review $pw_label write fails -> does NOT mark REVIEW_INCOMPLETE" \
    "false" "$(grep -qF 'REVIEW_INCOMPLETE' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
done
unset PRT_TEST_PARTIAL_WRITE_FAIL pw_case pw_label pw_rest pw_reason

# The comment listing failing (HTTP 500) is informational as well. The
# partial-review lookup is always the run's last listing call, so a baseline
# run counts the listings and the failing run fails only that last one. On
# the degraded path the run degrades with a reason naming the listing; on the
# supersede path it only warns. Neither writes a comment, marks
# REVIEW_INCOMPLETE or exits non-zero.
PRT_TEST_ISSUE_LIST_COUNTFILE="$(mktemp)"
PRT_TEST_ISSUE_COMMENTS_LIST='[{"id":77,"user":{"login":"test-bot[bot]"},"body":"earlier partial review\n<!-- gokure-pr-review:v1-partial -->"}]'
for pl_case in degraded supersede; do
  if [ "$pl_case" = degraded ]; then
    PRT_TEST_MODEL_RESPONSE_MODE=two_chunk_first_all_malformed_second_empty
    PRT_TEST_TWO_FILE_DIFF=1
  else
    PRT_TEST_MODEL_RESPONSE_MODE=clean
    PRT_TEST_TWO_FILE_DIFF=0
  fi
  : > "$PRT_TEST_ISSUE_LIST_COUNTFILE"
  rc="$(run_orchestrator enforce 0 0 0 150)"
  pl_lists="$(cat "$PRT_TEST_ISSUE_LIST_COUNTFILE")"
  : > "$PRT_TEST_ISSUE_LIST_COUNTFILE"
  : > "$PRT_TEST_ISSUE_COMMENT_LOG"
  PRT_TEST_ISSUE_LIST_FAIL_AFTER=$((pl_lists - 1))
  rc="$(run_orchestrator enforce 0 0 0 150)"
  PRT_TEST_ISSUE_LIST_FAIL_AFTER=''
  assert_eq "orchestrator: partial-review listing fails on the $pl_case path (HTTP 500) -> exits 0" "0" "$rc"
  assert_eq "orchestrator: partial-review listing fails on the $pl_case path -> partial comment 77 not written" \
    "0" "$(grep -c '^PATCH comments/77$' "$PRT_TEST_ISSUE_COMMENT_LOG")"
  assert_eq "orchestrator: partial-review listing fails on the $pl_case path -> does NOT mark REVIEW_INCOMPLETE" \
    "false" "$(grep -qF 'REVIEW_INCOMPLETE' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
  if [ "$pl_case" = degraded ]; then
    assert_eq "orchestrator: partial-review listing fails on the degraded path -> REVIEW_DEGRADED names the listing, no partial comment posted" \
      "true 0" "$(grep -qF 'REVIEW_DEGRADED: failed to list issue comments while looking for a prior partial-review comment' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG")"
  else
    assert_eq "orchestrator: partial-review listing fails on the supersede path -> warns that the prior comment is left as it stands" \
      "true" "$(grep -qF 'WARNING: could not list issue comments — any prior partial-review comment is left as it stands.' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
  fi
done
rm -f "$PRT_TEST_ISSUE_LIST_COUNTFILE"
unset PRT_TEST_ISSUE_LIST_COUNTFILE PRT_TEST_ISSUE_LIST_FAIL_AFTER pl_case pl_lists
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_TWO_FILE_DIFF=0
unset pf_reads pf_case
rm -f "$PRT_TEST_ISSUE_COMMENT_LOG"
unset PRT_TEST_ISSUE_COMMENT_LOG PRT_TEST_ISSUE_COMMENTS_LIST

# ---- Cases xvi-xviii (go-kure/.github#176): the positive coverage marker
# ---- three polarities named in the issue's own acceptance criteria.

# Case xvi — All-good: a two-chunk run (same PRT_TEST_TWO_FILE_DIFF/
# max_diff_chars=150 fixture as Cases xiv-xv) where BOTH chunks complete
# review and assess cleanly. The terminal `coverage: M/M` line must appear
# with M equal to the `chunks=` value, and both per-chunk `i/M` markers must
# be present.
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_TWO_FILE_DIFF=1
rc="$(run_orchestrator advisory 0 0 0 150)"
assert_eq "orchestrator: all-good two-chunk run -> exits 0" "0" "$rc"
assert_eq "orchestrator: all-good two-chunk run -> chunks=2 on the diff-split line" \
  "true" "$(grep -qE '^prt: diff:.*chunks=2$' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: all-good two-chunk run -> both per-chunk i/M markers present" \
  "true true" "$(grep -qF 'prt: chunk 1/2: review ok, assess ok' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qF 'prt: chunk 2/2: review ok, assess ok' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: all-good two-chunk run -> terminal coverage: 2/2 line present, M matches chunks=" \
  "true" "$(grep -qF 'prt: coverage: 2/2 chunks review+assess ok' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_TWO_FILE_DIFF=0
PRT_TEST_MODEL_RESPONSE_MODE=clean

# Case xvii — One-degraded: same two-chunk split, chunk 0's assess call
# succeeds, chunk 1's returns the non-array `.assessments` shape
# (first_ok_then_bad_shape, defined above). No full-coverage line may
# appear, and the count of "review ok, assess ok" lines must be strictly
# less than M(=2) — the exact acceptance-criteria wording ("the count of
# assess ok lines must be strictly less than M").
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_ASSESS_RESPONSE_MODE=first_ok_then_bad_shape
PRT_TEST_TWO_FILE_DIFF=1
rc="$(run_orchestrator advisory 0 0 0 150)"
assert_eq "orchestrator: one-degraded two-chunk run -> exits 0 (degraded, not fatal)" "0" "$rc"
assert_eq "orchestrator: one-degraded two-chunk run -> chunk 1's .assessments rejection is logged, not silently swallowed" \
  "true" "$(grep -qF 'prt: chunk 1: review ok, assess FAILED (.assessments missing/null/non-array)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: one-degraded two-chunk run -> no terminal coverage line" \
  "false" "$(grep -qF 'prt: coverage:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: one-degraded two-chunk run -> exactly 1 'review ok, assess ok' line (strictly < M=2)" \
  "1" "$(grep -cF 'review ok, assess ok' "$PRT_TEST_STDERR_FILE")"
PRT_TEST_ASSESS_RESPONSE_MODE=clean
PRT_TEST_TWO_FILE_DIFF=0
PRT_TEST_MODEL_RESPONSE_MODE=clean

# Case xviii — Zero-chunk: the issue's proposed fault is `prt_split_diff`
# itself failing on a non-empty diff; the orchestrator test harness has no
# seam to inject a write failure inside the subprocess's own freshly
# mktemp'd WORKDIR (unlike Case 11's direct unit-level call to
# prt_split_diff above, which chmods a caller-supplied OUT_DIR). The
# EMPTY_DIFF=1 path exercised here instead is the one route this harness
# has to a genuinely zero-chunk run (chunk_count stays at its 0
# initialisation, the whole chunk+review+assess block — and the coverage
# guard inside it — never runs) and proves the same property the acceptance
# criterion cares about: a run that reviewed nothing never emits a line an
# `M of M` consumer check can satisfy.
PRT_TEST_EMPTY_DIFF=1
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: zero-chunk (empty diff) run -> exits 0" "0" "$rc"
assert_eq "orchestrator: zero-chunk (empty diff) run -> no terminal coverage line" \
  "false" "$(grep -qF 'prt: coverage:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: zero-chunk (empty diff) run -> no per-chunk i/M marker either" \
  "false" "$(grep -qE '^prt: chunk [0-9]+/[0-9]+:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_EMPTY_DIFF=0

# Case xix — Failed-review-with-zero-findings (go-kure/.github#176 codex
# review, Critical): same two-chunk split as xvi-xviii. Chunk 0's review
# call fails outright (transport error); chunk 1's reviews cleanly with
# ZERO findings. Before this fix, both left chunk_findings empty at the
# coverage loop and chunk_ok_count counted both as "ok" — a run where one
# chunk was never reviewed at all could still print the terminal "M/M"
# line. The fixed run must degrade (chunk 0's failure is real) and must
# NOT claim full coverage.
PRT_TEST_MODEL_RESPONSE_MODE=fail_first_chunk_review
PRT_TEST_TWO_FILE_DIFF=1
rc="$(run_orchestrator advisory 0 0 0 150)"
assert_eq "orchestrator: one chunk's review fails, sibling reviews clean with zero findings -> exits 0 (degraded, not fatal)" \
  "0" "$rc"
assert_eq "orchestrator: one chunk's review fails -> REVIEW_DEGRADED records the failed chunk" \
  "true" "$(grep -qF 'REVIEW_DEGRADED: review-parse-failed: chunk 0: review call failed' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: one chunk's review fails, sibling clean-zero -> NO terminal coverage line (this is the Critical finding's exact scenario)" \
  "false" "$(grep -qF 'prt: coverage:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_TWO_FILE_DIFF=0
PRT_TEST_MODEL_RESPONSE_MODE=clean

# Case xx (go-kure/.github#211, filed against go-kure/.github#199's own
# coverage-marker review after that PR had already merged): chunk 0
# partial-drops one malformed row (its surviving finding still assesses
# cleanly), chunk 1 reviews and assesses cleanly with no degradation at
# all. Before this fix, chunk_ok_count credited BOTH chunks (partial-drop
# is not a CHUNK_REVIEW_FAILED case) and the terminal coverage line
# wrongly printed "2/2" despite chunk 0's dropped row — CHUNK_PARTIAL_DROP
# must exclude chunk 0 from the numerator even though its own assess call
# succeeded.
PRT_TEST_MODEL_RESPONSE_MODE=two_chunk_first_partial_drop_second_clean
PRT_TEST_TWO_FILE_DIFF=1
rc="$(run_orchestrator advisory 0 0 0 150)"
assert_eq "orchestrator: chunk 0 partial-drops, chunk 1 clean -> exits 0 (degraded, not fatal)" \
  "0" "$rc"
assert_eq "orchestrator: chunk 0 partial-drops, chunk 1 clean -> REVIEW_DEGRADED names chunk 0's partial-drop" \
  "true" "$(grep -qF 'REVIEW_DEGRADED: chunk 0: partial-drop' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: chunk 0 partial-drops, chunk 1 clean -> both chunks still individually reach review ok, assess ok" \
  "true true" "$(grep -qF 'prt: chunk 1/2: review ok, assess ok' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qF 'prt: chunk 2/2: review ok, assess ok' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: chunk 0 partial-drops, chunk 1 clean -> NO terminal coverage line (go-kure/.github#211's exact defect)" \
  "false" "$(grep -qF 'prt: coverage:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_TWO_FILE_DIFF=0
PRT_TEST_MODEL_RESPONSE_MODE=clean

# Case 3a — permanent metadata-fetch failure (F3): every attempt (matching
# prt_retry 3's own attempt count) returns 502, unlike meta_fail=1 below
# which only ever exercises the transient-then-success retry path.
rc="$(run_orchestrator advisory 0 3 0)"
assert_eq "orchestrator: PR-metadata fetch failing all 3 attempts exits 1" "1" "$rc"
assert_eq "orchestrator: permanent metadata-fetch failure — stderr carries the Step 3a ERROR line" \
  "true" "$(grep -qF 'ERROR: failed to fetch PR metadata' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# PRT_MODE=off must short-circuit before any curl call at all (:176-183, ahead
# of the diff fetch at :194) — proven here by wiring in settings that would
# fail the run if the off-mode gate were ever bypassed (an always-failing
# model call, on top of a diff-fetch failure budget deliberately larger than
# the retry cap, so a non-off run would exit 1 either way).
rc="$(run_orchestrator off 99 0 1)"
assert_eq "orchestrator: PRT_MODE=off exits 0 even when everything else would fail/incomplete" "0" "$rc"
assert_eq "orchestrator: PRT_MODE=off posts nothing (no create, reply, resolve, unresolve, patch or issue comment)" \
  "0 0 0 0 0 0" "$(cat "$PRT_TEST_CREATE_COUNTFILE") $(cat "$PRT_TEST_REPLY_COUNTFILE") $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(cat "$PRT_TEST_UNRESOLVE_COUNTFILE") $(cat "$PRT_TEST_PATCH_COUNTFILE") $(cat "$PRT_TEST_ISSUE_COMMENT_COUNTFILE")"

rc="$(run_orchestrator advisory 1 0 0)"
assert_eq "orchestrator: diff-fetch retry — one mocked 502 then success still exits 0" "0" "$rc"
assert_eq "orchestrator: diff-fetch retry actually fired (mock hit more than once)" \
  "true" "$([ "$(cat "$PRT_TEST_DIFF_COUNTFILE")" -ge 2 ] && echo true || echo false)"

rc="$(run_orchestrator advisory 0 1 0)"
assert_eq "orchestrator: PR-metadata GET retry — one mocked 502 then success still exits 0" "0" "$rc"
assert_eq "orchestrator: PR-metadata GET retry actually fired (mock hit more than once)" \
  "true" "$([ "$(cat "$PRT_TEST_META_COUNTFILE")" -ge 2 ] && echo true || echo false)"

# ---- go-kure/.github#173: a chunked review names its chunk ----
# Every review and assess prompt of a two-chunk run carries "chunk i of 2"
# and the files of the whole diff, and the thread a chunk's finding opens is
# stamped with its chunk. A single-chunk run carries no scope block.
PRT_TEST_MODEL_REQUEST_LOG="$(mktemp)"
PRT_TEST_CREATE_BODY_LOG="$(mktemp)"
PRT_TEST_MODEL_RESPONSE_MODE=per_chunk_findings
PRT_TEST_TWO_FILE_DIFF=1
rc="$(run_orchestrator enforce 0 0 0 150)"
PRT_TEST_TWO_FILE_DIFF=0
assert_eq "chunk scope: two-chunk enforce run exits 0" "0" "$rc"
assert_eq "chunk scope: prompts name chunk 1 of 2 and chunk 2 of 2" \
  "true true" "$(grep -qF 'this is chunk 1 of 2.' "$PRT_TEST_MODEL_REQUEST_LOG" && echo true || echo false) $(grep -qF 'this is chunk 2 of 2.' "$PRT_TEST_MODEL_REQUEST_LOG" && echo true || echo false)"
assert_eq "chunk scope: review and assess prompts both carry it (4 calls, one block each)" \
  "4" "$(grep -cF 'CHUNK SCOPE:' "$PRT_TEST_MODEL_REQUEST_LOG")"
assert_eq "chunk scope: the whole diff's file list names both files" \
  "true" "$(grep -A2 -F 'Files in the whole diff:' "$PRT_TEST_MODEL_REQUEST_LOG" | head -3 | tr '\n' ' ' | grep -qF 'Files in the whole diff: - x.go - y.go' && echo true || echo false)"
assert_eq "chunk scope: each created thread is stamped with its own chunk" \
  "true true" "$(grep -qF 'Automated review finding from chunk 1/2 of the diff' "$PRT_TEST_CREATE_BODY_LOG" && echo true || echo false) $(grep -qF 'Automated review finding from chunk 2/2 of the diff' "$PRT_TEST_CREATE_BODY_LOG" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
: > "$PRT_TEST_MODEL_REQUEST_LOG"
: > "$PRT_TEST_CREATE_BODY_LOG"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "chunk scope: single-chunk enforce run exits 0" "0" "$rc"
assert_eq "chunk scope: a single-chunk run's prompts carry no scope block" \
  "0" "$(grep -cF 'CHUNK SCOPE:' "$PRT_TEST_MODEL_REQUEST_LOG")"
assert_eq "chunk scope: a single-chunk run's thread keeps the plain footer" \
  "true" "$(grep -qF '*Automated review finding — reply to discuss' "$PRT_TEST_CREATE_BODY_LOG" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean
rm -f "$PRT_TEST_MODEL_REQUEST_LOG" "$PRT_TEST_CREATE_BODY_LOG"
PRT_TEST_MODEL_REQUEST_LOG=""
PRT_TEST_CREATE_BODY_LOG=""

# ---- Cases 7-9: empty net diff (dot-github#60) ----
# enforce + empty diff + owned open thread + no first_absent_sha yet ->
# exit 0, PATCH count >= 1 (the SET_FIRST_ABSENT stamp via GET-then-PATCH
# on the thread's first comment), resolve count 0 (nothing to resolve on
# a first sighting), model count 0 (no chunking/review happens on an empty
# diff, per Step 3b).
PRT_TEST_EMPTY_DIFF=1
PRT_TEST_FIRST_ABSENT_SHA=""
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: enforce + empty diff + first sighting -> exits 0" "0" "$rc"
assert_eq "orchestrator: enforce + empty diff + first sighting -> PATCH count >= 1 (SET_FIRST_ABSENT)" \
  "true" "$([ "$(cat "$PRT_TEST_PATCH_COUNTFILE")" -ge 1 ] && echo true || echo false)"
assert_eq "orchestrator: enforce + empty diff + first sighting -> resolve count 0" \
  "0" "$(cat "$PRT_TEST_RESOLVE_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: enforce + empty diff + first sighting -> model count 0 (no findings pipeline on empty diff)" \
  "0" "$(cat "$PRT_TEST_MODEL_COUNTFILE" 2>/dev/null || echo 0)"

# go-kure/.github#99 kure-bot round-5 finding: this comment previously
# labeled call #1 "the meta fetch", which is wrong under an empty diff —
# pr-review-threads.sh:242's `EMPTY_DIFF != 1` guard means no meta fetch
# ever runs on this path (same reason the absence-resolve block below
# gives for its own numbering). Verified against the shared META_COUNTFILE
# (this file's `_prt_bump`d "meta fetch (:243) and every later freshness
# re-check" counter): call #1 is actually the SET_FIRST_ABSENT loop's own
# pre-mutate freshness check (pr-review-threads.sh:1184) — the first and
# only thing to touch that counter before it — and it stays fresh; call #2
# onward is the SAME check re-invoked by prt_gh_rest_fresh inside the
# retried PATCH write (gh.sh's prt_retry 3 wrapping), which now observes
# the moved head. The numeric race this pins (fresh going in, stale before
# the write commits) was always correct; only the label for call #1 was
# not — confirmed by reverting go-kure/.github#99's `1f0f28b` fix
# (prt_handle_freshness_rc's rc=1 case) and observing this block's own
# assertions go red. The run's ONLY REVIEW_DEGRADED reason is that
# staleness, so the tail exit gate must take the quiet "Stale run" path
# (exit 0, distinct log line) rather than the generic REVIEW_DEGRADED
# warning recap, and must NOT attempt the now-stale PATCH at all.
PRT_TEST_EMPTY_DIFF=1
PRT_TEST_FIRST_ABSENT_SHA=""
PRT_TEST_STALE_AFTER_CALL=1
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: staleness-only run (head moved before SET_FIRST_ABSENT write) -> exits 0" "0" "$rc"
assert_eq "orchestrator: staleness-only run -> logs the distinct 'Stale run' message" \
  "true" "$(grep -qF 'Stale run: head moved; a newer run is already queued' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: staleness-only run -> PATCH never attempted (skipped, not retried into a false success)" \
  "0" "$(cat "$PRT_TEST_PATCH_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: staleness-only run -> does NOT emit the generic REVIEW_DEGRADED warning recap" \
  "false" "$(grep -qF 'WARNING: review degraded' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_STALE_AFTER_CALL=0

# enforce + empty diff + owned open thread + first_absent_sha on a
# different commit than this run's head -> the second absence -> resolve.
PRT_TEST_EMPTY_DIFF=1
PRT_TEST_RECHECK_MODE=false  # go-kure/.github#201: the pre-resolve reply re-read finds none
PRT_TEST_FIRST_ABSENT_SHA="2222222222222222222222222222222222222222"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: enforce + empty diff + second absence on a new SHA -> exits 0" "0" "$rc"
assert_eq "orchestrator: enforce + empty diff + second absence on a new SHA -> resolve count >= 1" \
  "true" "$([ "$(cat "$PRT_TEST_RESOLVE_COUNTFILE")" -ge 1 ] && echo true || echo false)"

# ---- go-kure/.github#201: the absence auto-close re-reads replies first ----
# Same second-absence setup; only the live re-read differs. The inventory
# snapshot (no reply) is what made this row 10.
# (a) A reply landed after the snapshot -> NONE: no resolve, clean exit.
PRT_TEST_RECHECK_MODE=true
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #201: fresh reply before the absence auto-close -> exits 0, no resolve, downgrade logged" \
  "0 0 true" "$rc $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(grep -qF 'absence REPLY_RESOLVE downgraded to NONE' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# (b) The thread cannot be re-read (node:null) -> no resolve, REVIEW_INCOMPLETE.
PRT_TEST_RECHECK_MODE=
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #201: reply re-read fails before the absence auto-close -> exits 1, no resolve, reason named" \
  "1 0 true" "$rc $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(grep -qF 'could not re-check thread for a new human reply before the absence auto-close' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# (c) No reply, but the head moves during the re-read: the freshness check
# after it catches the move before the mutation (call #1 is the arm-entry
# check, call #2 the post-recheck one). Nothing written, so stale-safe.
PRT_TEST_RECHECK_MODE=false
PRT_TEST_STALE_AFTER_CALL=1
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #201: head moves during the reply re-read -> exits 0, no resolve, post-recheck staleness named" \
  "0 0 true" "$rc $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(grep -qF 'absence auto-close (post-recheck): stale head SHA' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_STALE_AFTER_CALL=0
PRT_TEST_RECHECK_MODE=
PRT_TEST_EMPTY_DIFF=0
PRT_TEST_FIRST_ABSENT_SHA=""

# go-kure/.github#99 codex round-2 confirm finding: REPLY_RESOLVE's
# resolveReviewThread mutation succeeds, then the head SHA moves before the
# post-mutation freshness re-check that gates the explanatory reply. A
# superseding run will NOT redo this: the thread is already resolved, so its
# own decision table computes NONE on that fp — the reply is lost for good
# if this is allowed to exit 0 as "stale, safe, superseded" like a
# not-yet-attempted write would be. Must stay REVIEW_INCOMPLETE (exit 1),
# not REVIEW_DEGRADED.
#   call #1 = the real meta fetch (must report the true head SHA)
#   call #2 = the pre-mutate freshness check at REPLY_RESOLVE's case entry
#             (line ~1062) -> stays fresh
#   call #3 = go-kure/.github#193 codex review round 2: the SECOND
#             pre-mutate freshness check this fix inserts immediately
#             before the mutation (after the human-reply recheck, which is
#             GraphQL-only and does not touch this REST counter) -> must
#             also stay fresh, or the mutation below would never fire and
#             this scenario's own premise (head moves AFTER the mutation)
#             would be untestable
#   call #4 = the post-mutate freshness check (line ~1036) -> goes stale
# PRT_TEST_RECHECK_MODE=false (go-kure/.github#193 fix): this scenario
# exists to pin behaviour AFTER the resolveReviewThread mutation fires, so
# the new pre-mutation recheck this fix inserts must itself report "no
# fresh reply" here, or the mutation this test is about would never be
# reached at all. Uses PRT_TEST_GRAPHQL_COUNTFILE, not PRT_TEST_META_COUNTFILE
# / PRT_TEST_STALE_AFTER_CALL, so it does not perturb the call numbering above.
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_ASSESS_RESPONSE_MODE=false_positive_survivor
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
PRT_TEST_STALE_AFTER_CALL=3
PRT_TEST_RECHECK_MODE=false
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: head moves between resolve mutation and reply freshness re-check -> exits 1 (stays fatal, NOT superseded-safe)" \
  "1" "$rc"
assert_eq "orchestrator: head moves after resolve mutation -> resolveReviewThread still fired (mutation already committed)" \
  "1" "$(cat "$PRT_TEST_RESOLVE_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: head moves after resolve mutation -> the explanatory reply is skipped, not posted" \
  "0" "$(cat "$PRT_TEST_REPLY_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: head moves after resolve mutation -> REVIEW_INCOMPLETE names the lost-reply reason, not a generic stale-superseded one" \
  "true" "$(grep -qF 'REVIEW_INCOMPLETE: fp=' "$PRT_TEST_STDERR_FILE" && grep -qF 'will not be redone by a superseding run' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: head moves after resolve mutation -> does NOT log the quiet 'Stale run' line (this is not the safe-superseded case)" \
  "false" "$(grep -qF 'Stale run: head moved; a newer run is already queued' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_ASSESS_RESPONSE_MODE=clean
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_STALE_AFTER_CALL=0

# go-kure/.github#193 codex review (round 2): the mirror image of the
# scenario above -- the head moves BEFORE the mutation this time, in the
# gap the human-reply recheck (prt_thread_has_human_reply, GraphQL-only,
# no REST call) opened between the case-entry freshness check (call #2)
# and the mutation. This is exactly the TOCTOU the round-2 finding
# reported: without the second freshness check this round adds, the
# mutation would fire anyway using a stale assessment. With it, call #3
# (the new check) goes stale and the resolve must be skipped -- the safe,
# degradable case (rc=1), not fatal, since nothing was written yet.
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_ASSESS_RESPONSE_MODE=false_positive_survivor
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
PRT_TEST_STALE_AFTER_CALL=2
PRT_TEST_RECHECK_MODE=false
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: head moves between the human-reply recheck and the resolve mutation -> exits 0 (safe, superseded, nothing written yet)" \
  "0" "$rc"
assert_eq "orchestrator: head moves before the mutation -> resolveReviewThread never fires" \
  "0" "$(cat "$PRT_TEST_RESOLVE_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: head moves before the mutation -> no explanatory reply posted either (nothing to explain, no mutation ran)" \
  "0" "$(cat "$PRT_TEST_REPLY_COUNTFILE" 2>/dev/null || echo 0)"
# Not "Stale run" (that quiet line requires EVERY degraded reason to be a
# staleness one): a REPLY_RESOLVE skipped this way lands in no observable
# state this run (no resolve, no reply, no quarantine) and also trips the
# separate go-kure/.github#155 accounting invariant, so this scenario is
# REVIEW_DEGRADED with two mixed reasons, not the pure-staleness case the
# SET_FIRST_ABSENT scenario above demonstrates.
assert_eq "orchestrator: head moves before the mutation -> the staleness IS named among the degraded reasons" \
  "true" "$(grep -qF 'reply+resolve (post-recheck): stale head SHA (run superseded), write skipped' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_ASSESS_RESPONSE_MODE=clean
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_STALE_AFTER_CALL=0
PRT_TEST_RECHECK_MODE=

# ---- go-kure/.github#193 codex review: REPLY_RESOLVE recheck-before-mutate ----
# The stale has_human_reply snapshot from inventory build is the whole
# precondition for row 3's REPLY_RESOLVE (go-kure/.github#177); a reply that
# lands between that snapshot and this mutation must re-derive the answer,
# not trust the snapshot. Same FALSE_POSITIVE-on-an-open-owned-thread setup
# as the pinning test above, varying only PRT_TEST_RECHECK_MODE.

# (a) A fresh human reply is detected on the recheck -> REPLY_RESOLVE
# downgrades to NONE: no resolve mutation, no lost-reply REVIEW_INCOMPLETE,
# a clean exit 0 logging the downgrade explicitly.
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_ASSESS_RESPONSE_MODE=false_positive_survivor
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
PRT_TEST_RECHECK_MODE=true
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: fresh reply detected before REPLY_RESOLVE mutation -> exits 0 (downgraded to NONE, not incomplete)" \
  "0" "$rc"
assert_eq "orchestrator: fresh reply detected before REPLY_RESOLVE mutation -> resolveReviewThread never fires" \
  "0" "$(cat "$PRT_TEST_RESOLVE_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: fresh reply detected before REPLY_RESOLVE mutation -> stderr logs the downgrade" \
  "true" "$(grep -qF 'REPLY_RESOLVE downgraded to NONE' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_ASSESS_RESPONSE_MODE=clean
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_RECHECK_MODE=

# (b) The recheck confirms no fresh reply -> REPLY_RESOLVE proceeds exactly
# as it did before this fix (control for (a): same setup, opposite recheck
# result).
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_ASSESS_RESPONSE_MODE=false_positive_survivor
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
PRT_TEST_RECHECK_MODE=false
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: recheck confirms no fresh reply -> exits 0" "0" "$rc"
assert_eq "orchestrator: recheck confirms no fresh reply -> resolveReviewThread still fires" \
  "1" "$(cat "$PRT_TEST_RESOLVE_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: recheck confirms no fresh reply -> stderr does NOT log a downgrade" \
  "false" "$(grep -qF 'REPLY_RESOLVE downgraded to NONE' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_ASSESS_RESPONSE_MODE=clean
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_RECHECK_MODE=

# (c) The recheck itself cannot be completed (thread refetch returns an
# unusable node, PRT_TEST_RECHECK_MODE left unset -> the default
# {"data":{"node":null}}) -> the mutation is skipped rather than risking an
# unseen reply, and this is REVIEW_INCOMPLETE, distinct from case (a)'s
# clean downgrade.
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_ASSESS_RESPONSE_MODE=false_positive_survivor
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: recheck fetch fails before REPLY_RESOLVE mutation -> exits 1 (REVIEW_INCOMPLETE)" \
  "1" "$rc"
assert_eq "orchestrator: recheck fetch fails before REPLY_RESOLVE mutation -> resolveReviewThread never fires" \
  "0" "$(cat "$PRT_TEST_RESOLVE_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: recheck fetch fails before REPLY_RESOLVE mutation -> REVIEW_INCOMPLETE names the recheck failure, not the lost-reply reason" \
  "true" "$(grep -qF 'REVIEW_INCOMPLETE: fp=' "$PRT_TEST_STDERR_FILE" && grep -qF 'could not re-check thread for a new human reply before resolving' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_ASSESS_RESPONSE_MODE=clean
PRT_TEST_OWNED_FP="deadbeefcafebabe"

# go-kure/.github#99 round-4 fold-in: the same race pinned above for
# REPLY_RESOLVE, but for its mirror-image action REPLY_UNRESOLVE (row 7 —
# resolved-by-bot thread, finding recurs). unresolveReviewThread commits,
# then the head moves before the post-mutation freshness re-check gating the
# recurrence reply. A successor's decision table now sees the thread already
# unresolved (row 5, still open — nothing to do) and never redoes this
# specific reply. Must stay REVIEW_INCOMPLETE (exit 1), not the quiet
# stale-superseded path, exactly like REPLY_RESOLVE's own pinning test
# above.
#   call #1 = the real meta fetch (must report the true head SHA)
#   call #2 = the pre-mutate freshness check (line ~1050) -> stays fresh
#   call #3 = the post-mutate freshness check (line ~1064) -> goes stale
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
PRT_TEST_OWNED_RESOLVED_BY_BOT=1
PRT_TEST_STALE_AFTER_CALL=2
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: head moves between unresolve mutation and reply freshness re-check -> exits 1 (stays fatal, NOT superseded-safe)" \
  "1" "$rc"
assert_eq "orchestrator: head moves after unresolve mutation -> unresolveReviewThread still fired (mutation already committed)" \
  "1" "$(cat "$PRT_TEST_UNRESOLVE_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: head moves after unresolve mutation -> the recurrence reply is skipped, not posted" \
  "0" "$(cat "$PRT_TEST_REPLY_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: head moves after unresolve mutation -> REVIEW_INCOMPLETE names the lost-reply reason, not a generic stale-superseded one" \
  "true" "$(grep -qF 'REVIEW_INCOMPLETE: fp=' "$PRT_TEST_STDERR_FILE" && grep -qF 'will not be redone by a superseding run' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: head moves after unresolve mutation -> does NOT log the quiet 'Stale run' line (this is not the safe-superseded case)" \
  "false" "$(grep -qF 'Stale run: head moved; a newer run is already queued' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_OWNED_RESOLVED_BY_BOT=0
PRT_TEST_STALE_AFTER_CALL=0

# go-kure/.github#99 round-4 fold-in: same race a third time, this time on
# the absence loop's own REPLY_RESOLVE (row 10 — two consecutive absences on
# different SHAs, auto-close). resolveReviewThread commits, then the head
# moves before the post-mutation freshness re-check gating the auto-close
# reply. Mirrors the two pinning tests above; only the call numbering
# differs because this scenario runs against an empty diff, which skips the
# initial meta fetch entirely (pr-review-threads.sh:242's `EMPTY_DIFF != 1`
# guard) — the absence loop's own explicit pre-mutate check becomes call #1.
# This numbering (confirmed against the shared META_COUNTFILE) is what the
# staleness-only SET_FIRST_ABSENT block above was corrected to match
# (round-5 kure-bot finding) — its own call #1 is likewise its loop's
# pre-mutate check, not a meta fetch, for this identical EMPTY_DIFF reason.
#   call #1 = the pre-mutate freshness check at the arm's entry -> stays fresh
#   call #2 = the check after the reply re-read (go-kure/.github#201) -> stays fresh
#   call #3 = the post-mutate freshness check -> goes stale
PRT_TEST_EMPTY_DIFF=1
PRT_TEST_FIRST_ABSENT_SHA="2222222222222222222222222222222222222222"
PRT_TEST_STALE_AFTER_CALL=2
PRT_TEST_RECHECK_MODE=false
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: head moves between absence-resolve mutation and reply freshness re-check -> exits 1 (stays fatal, NOT superseded-safe)" \
  "1" "$rc"
assert_eq "orchestrator: head moves after absence-resolve mutation -> resolveReviewThread still fired (mutation already committed)" \
  "1" "$(cat "$PRT_TEST_RESOLVE_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: head moves after absence-resolve mutation -> the auto-close reply is skipped, not posted" \
  "0" "$(cat "$PRT_TEST_REPLY_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: head moves after absence-resolve mutation -> REVIEW_INCOMPLETE names the lost-reply reason, not a generic stale-superseded one" \
  "true" "$(grep -qF 'REVIEW_INCOMPLETE: fp=' "$PRT_TEST_STDERR_FILE" && grep -qF 'will not be redone by a superseding run' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: head moves after absence-resolve mutation -> does NOT log the quiet 'Stale run' line (this is not the safe-superseded case)" \
  "false" "$(grep -qF 'Stale run: head moved; a newer run is already queued' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_EMPTY_DIFF=0
PRT_TEST_FIRST_ABSENT_SHA=""
PRT_TEST_STALE_AFTER_CALL=0
PRT_TEST_RECHECK_MODE=

# ---- go-kure/.github#155: a fingerprint-collided run end to end ----
# Three findings, same file+category (dup.go/other) -> all collide on
# fp_base -> reconcile.sh row 1 fires QUARANTINE for all three, regardless
# of verdict (no owned thread and no assessment match either way, so this
# also covers the report's original observation that the suppression fires
# before assessment or thread state matter at all).
PRT_TEST_ISSUE_COMMENT_BODY_FILE="$(mktemp)"
PRT_TEST_MODEL_RESPONSE_MODE=collision_triple
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: fingerprint-collided run -> exits 0 (deliberate suppression, not a failure)" "0" "$rc"
assert_eq "orchestrator: fingerprint-collided run -> stderr done: line reports quarantined=3 (criterion 2)" \
  "true" "$(grep -qE 'done:.*quarantined=3' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: fingerprint-collided run -> stderr done: line reports findings=3" \
  "true" "$(grep -qE 'done:.*findings=3' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: fingerprint-collided run -> no review comment created for any of the three (CREATE count 0 — the original defect: a thread that never exists)" \
  "0" "$(cat "$PRT_TEST_CREATE_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: fingerprint-collided run -> a durable issue comment WAS posted (the withheld findings land in the advisory comment, not nowhere)" \
  "true" "$([ "$(cat "$PRT_TEST_ISSUE_COMMENT_COUNTFILE" 2>/dev/null || echo 0)" -ge 1 ] && echo true || echo false)"
assert_eq "orchestrator: fingerprint-collided run -> the posted comment carries the withheld-findings header" \
  "true" "$(grep -qF 'Withheld AI Review Findings' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
assert_eq "orchestrator: fingerprint-collided run -> all three finding bodies reached the durable comment (criterion 3 — matched on issue text, not just a count)" \
  "true" "$(grep -qF 'collision issue one' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && grep -qF 'collision issue two' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && grep -qF 'collision issue three' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
assert_eq "orchestrator: fingerprint-collided run -> no accounting-mismatch REVIEW_DEGRADED (all three findings landed in the withheld bucket, criterion 6 invariant holds)" \
  "false" "$(grep -qF 'accounting mismatch' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# go-kure/.github#180 codex review, this round: all three findings collide
# THIS run (finding.sh:204, group length 3), so persisted_only must be
# false for every one — the Collision column must read "this run", not
# falsely "persisted (earlier run)" (which would only be correct if this
# run's own multiplicity were absent and the flag came from an owned
# thread's carried-over marker instead — no owned thread exists in this
# scenario at all).
# Keyed on the pipe-delimited TABLE CELL, not the bare phrase — see the
# render.sh unit test above for why a bare-phrase predicate here would be
# vacuous (the intro paragraph's own explanatory prose contains both
# labels unconditionally).
assert_eq "orchestrator: fingerprint-collided run (THIS-run multiplicity, no owned thread) -> Collision cell reads 'this run', not 'persisted'" \
  "true" "$(grep -qF '| this run |' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && ! grep -qF '| persisted (earlier run) |' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
# A jq fault while rendering the withheld-findings table: the three quarantined findings must
# not be posted as an empty or partial comment and read as a clean run. The run exits nonzero,
# is incomplete, and posts nothing. The fault is a `jq` on PATH that fails on that program only.
prt_orch_shim="$(mktemp -d)"
cat > "$prt_orch_shim/jq" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in *"$JQ_FAIL_MATCH"*) exit 5 ;; esac
done
exec "$REAL_JQ" "$@"
SHIM
chmod +x "$prt_orch_shim/jq"
prt_orch_real_jq="$(command -v jq)"
rc="$(PATH="$prt_orch_shim:$PATH" REAL_JQ="$prt_orch_real_jq" JQ_FAIL_MATCH='def collision_cell' run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: a failed quarantine table -> exits 1 (not 0), nothing posted" \
  "1 0" "$rc $(cat "$PRT_TEST_ISSUE_COMMENT_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: a failed quarantine table -> the body is not posted and the run names the render fault" \
  "false true" "$(grep -qF 'Withheld AI Review Findings' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false) $(grep -qF 'overflow comment could not be rendered' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: a failed quarantine table -> the done line is not incomplete=0" \
  "false" "$(grep -qE 'done:.*incomplete=0 ' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
rc="$(PATH="$prt_orch_shim:$PATH" REAL_JQ="$prt_orch_real_jq" JQ_FAIL_MATCH='no-such-program-text' run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: the same run through a pass-through shim posts the table and exits 0" \
  "0 true" "$rc $(grep -qF 'Withheld AI Review Findings' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
# The first normalization query failing on a populated chunk, while the other chunk is clean,
# is a local fault (status 3): the run is incomplete and exits nonzero, never a degraded 0.
PRT_TEST_TWO_FILE_DIFF=1
rc="$(PATH="$prt_orch_shim:$PATH" REAL_JQ="$prt_orch_real_jq" JQ_FAIL_MATCH='(.findings | type) == "array"' run_orchestrator enforce 0 0 0 100)"
assert_eq "orchestrator: a failed shape query on every chunk -> exits nonzero, never a degraded 0" \
  "true" "$([ "$rc" != 0 ] && echo true || echo false)"
assert_eq "orchestrator: a failed shape query is reported as a local fault, not a retried unusable response" \
  "true" "$(grep -qF 'local fault reading the response shape' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_TWO_FILE_DIFF=0
find "$prt_orch_shim" -delete
unset prt_orch_shim prt_orch_real_jq
PRT_TEST_MODEL_RESPONSE_MODE=clean
rm -f "$PRT_TEST_ISSUE_COMMENT_BODY_FILE"
unset PRT_TEST_ISSUE_COMMENT_BODY_FILE

# ---- go-kure/.github#192: the OVERFLOW path end to end ----
# Seven distinct VALID findings against the default cap of 5: three High and
# two Medium gate as threads, and the two Low ones (listed first by the
# model) land in the advisory overflow comment, by content. The harness's
# THREAD1 is resolved by a human, so no open thread reserves a slot (a
# foreign-authored open one would since go-kure/.github#153, see below).
PRT_TEST_ISSUE_COMMENT_BODY_FILE="$(mktemp)"
PRT_TEST_THREAD1_RESOLVED=1
PRT_TEST_MODEL_RESPONSE_MODE=seven_findings
PRT_TEST_ASSESS_RESPONSE_MODE=seven_valid
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #192: seven VALID findings, cap 5 -> exits 0, five threads created, done line reports findings=7 gating=5" \
  "0 5 true" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE") $(grep -qE 'done: findings=7 gating=5 ' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #192: the overflow comment is posted under its header" \
  "true" "$(grep -qF 'Additional AI Review Findings' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
assert_eq "orchestrator #192: both Low findings reach the overflow comment by issue text" \
  "true" "$(grep -qF 'overflow-case nil-deref issue' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && grep -qF 'overflow-case unchecked-err issue' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
assert_eq "orchestrator #192: no gating finding is in the overflow comment" \
  "0" "$(grep -cE 'overflow-case (race|sql-injection|resource-leak|logic-error|standards-violation) issue' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE")"
assert_eq "orchestrator #192: every finding accounted for (no accounting-mismatch degrade)" \
  "false" "$(grep -qF 'accounting mismatch' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# go-kure/.github#153: an OPEN thread another login opened (no finding this
# run matches it) still blocks merge, so it reserves a slot: four new threads,
# not five, and three findings overflow. Resolved, it reserves none.
PRT_TEST_THREAD1_RESOLVED=0
PRT_TEST_OWNED_AUTHOR=github-actions
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153: an open foreign thread reserves a cap slot -> exits 0, four threads created, gating=4" \
  "0 4 true" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE") $(grep -qE 'done: findings=7 gating=4 ' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_THREAD1_RESOLVED=1
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153: a resolved foreign thread reserves no slot -> five threads created" \
  "0 5" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE")"
# The resolved foreign thread now matches the High "race" finding and was
# resolved by the login that opened it, where an own thread would be
# reopened: the finding gets a new own thread, ranked like any CREATE. It
# takes one of the five slots (High), so both Low findings still overflow
# and it is not in the overflow comment.
PRT_TEST_OWNED_FP="$(prt_fp_base x.go race)"
PRT_TEST_THREAD1_RESOLVED_BY=github-actions
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153: resolved foreign thread re-matched by a recurring High finding -> its new own thread competes in the cap: five created, gating=5, no write to the foreign one" \
  "0 5 0 0 0 0 true" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE") $(cat "$PRT_TEST_PATCH_COUNTFILE") $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(cat "$PRT_TEST_UNRESOLVE_COUNTFILE") $(cat "$PRT_TEST_REPLY_COUNTFILE") $(grep -qE 'done: findings=7 gating=5 ' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #153: that finding got a thread, not an overflow row; both Low findings overflow" \
  "false true" "$(grep -qF 'overflow-case race issue' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false) $(grep -qF 'overflow-case nil-deref issue' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && grep -qF 'overflow-case unchecked-err issue' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
assert_eq "orchestrator #153: re-matched resolved foreign thread -> accounted for (no accounting-mismatch degrade)" \
  "false" "$(grep -qF 'accounting mismatch' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_THREAD1_RESOLVED_BY="a-human"
PRT_TEST_THREAD1_RESOLVED=0
PRT_TEST_OWNED_AUTHOR=test-bot
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_ASSESS_RESPONSE_MODE=clean
rm -f "$PRT_TEST_ISSUE_COMMENT_BODY_FILE"
unset PRT_TEST_ISSUE_COMMENT_BODY_FILE

# ---- go-kure/.github#268: an open thread competes for the cap by its severity ----
# Cap 3, the same seven findings (three High and two Medium gate). THREAD1 is
# an open own thread no finding matches this run, so it stays gating and ranks
# by the severity its body states, read through the inventory. Critical
# outranks every new finding: two High threads fit. Medium is outranked by all
# three High findings: three fit, where reserving a slot for every open thread
# regardless of severity gave two.
PRT_TEST_MODEL_RESPONSE_MODE=seven_findings
PRT_TEST_ASSESS_RESPONSE_MODE=seven_valid
PRT_TEST_MAX_FINDINGS_TOTAL=3
PRT_TEST_OWNED_SEVERITY=Critical
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #268: open own Critical thread absent this run, cap 3 -> two High threads created, gating=2" \
  "0 2 true" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE") $(grep -qE 'done: findings=7 gating=2 ' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_OWNED_SEVERITY=Medium
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #268: open own Medium thread absent this run, cap 3 -> all three High findings get threads, gating=3" \
  "0 3 true" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE") $(grep -qE 'done: findings=7 gating=3 ' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
unset PRT_TEST_OWNED_SEVERITY PRT_TEST_MAX_FINDINGS_TOTAL
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_ASSESS_RESPONSE_MODE=clean

# go-kure/.github#180 codex review: a quarantined finding whose fp_base
# already has an OWNED, still-open thread (from a prior run, before this run
# introduced the collision) is still merge-gating through that thread —
# reconcile.sh's prt_thread_stays_gating QUARANTINE case reserves its cap
# slot for exactly this reason. The withheld-findings table must not render
# a blanket "Not blocking" that hides this.
#
# go-kure/.github#180 codex review, round 3: gating is looked up by fp_base,
# not by whichever member's exact (possibly ordinal-suffixed) $fp happens to
# match this run — prt_assign_ordinals hands the unsuffixed fp_base to
# whichever group member currently sorts to the lowest .line, which can
# differ run to run as lines shift. An exact-$fp lookup would attach "yes
# (existing thread)" to whichever row holds the unsuffixed identity THIS
# run, misattributing a thread that may have been created for a different
# member's text. All three members share the same fp_base (dup.go/other),
# so all three must be marked gating together, not just ordinal 0.
PRT_TEST_ISSUE_COMMENT_BODY_FILE="$(mktemp)"
PRT_TEST_MODEL_RESPONSE_MODE=collision_triple
PRT_TEST_OWNED_FP="$(prt_fp_base dup.go other)"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: fingerprint-collided run, the group's fp_base matches an existing open thread -> exits 0" "0" "$rc"
assert_eq "orchestrator: quarantined findings sharing a fp_base with an existing open thread -> ALL group members marked gating together (go-kure/.github#180 codex review round 3), not just whichever row currently holds the unsuffixed identity" \
  "3" "$(grep -oF 'yes (existing thread)' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" | wc -l | tr -d ' ')"
assert_eq "orchestrator: quarantined findings sharing a gating fp_base -> no row is left marked 'no'" \
  "false" "$(grep -qF '| no |' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
assert_eq "orchestrator: quarantined finding matching an existing open thread -> its fix suggestion is rendered too" \
  "true" "$(grep -qF 'fix one' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_MODEL_RESPONSE_MODE=clean
rm -f "$PRT_TEST_ISSUE_COMMENT_BODY_FILE"
unset PRT_TEST_ISSUE_COMMENT_BODY_FILE

# criterion 2's zero-case control: a run with a real, non-colliding finding
# must report quarantined=0, not just findings=N with no assertion on the
# other counter. Without this, a counter hardcoded to the finding count would
# still pass the collision_triple assertion above (findings=3, quarantined=3)
# while being wrong for every ordinary run.
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: single non-colliding finding -> exits 0" "0" "$rc"
assert_eq "orchestrator: single non-colliding finding -> stderr done: line reports quarantined=0 (criterion 2, zero-case control)" \
  "true" "$(grep -qE 'done:.*quarantined=0' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: single non-colliding finding -> stderr done: line reports findings=1" \
  "true" "$(grep -qE 'done:.*findings=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean

# ---- go-kure/.github#196: cross-run fp_base collision via content_fp ----
# The finding under clean_with_finding is fixed: file x.go, line 1, category
# other, issue "i", fix "f" -> content_fp = prt_content_fp "i" "f".
# fp_base = prt_fp_base x.go other, matching PRT_TEST_OWNED_FP below, so the
# thread is OWNED by bare-fp match — content_fp is the only thing that can
# still tell these two runs' findings apart.
#
# Case A: the owned thread's stored content_fp does NOT match this run's
# finding (a different finding text collided onto the same fp_base in an
# earlier run). effective_collision must be forced true even though the
# owned-thread match succeeded, routing this finding into row 1 QUARANTINE —
# same observable shape as the fp_base-collision tests above (no CREATE, a
# durable withheld-findings comment), but triggered by content mismatch on a
# SINGLE finding, not by same-run multiplicity.
PRT_TEST_ISSUE_COMMENT_BODY_FILE="$(mktemp)"
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
PRT_TEST_OWNED_CONTENT_FP="25122a0a5f719e16"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: content_fp mismatch against owned thread -> exits 0 (deliberate suppression, not a failure)" "0" "$rc"
assert_eq "orchestrator: content_fp mismatch against owned thread -> stderr done: line reports quarantined=1" \
  "true" "$(grep -qE 'done:.*quarantined=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: content_fp mismatch against owned thread -> no CREATE (existing thread is not mutated)" \
  "0" "$(cat "$PRT_TEST_CREATE_COUNTFILE" 2>/dev/null || echo 0)"
assert_eq "orchestrator: content_fp mismatch against owned thread -> no resolve/unresolve on the existing thread (QUARANTINE does not touch it)" \
  "true" "$([ "$(cat "$PRT_TEST_RESOLVE_COUNTFILE" 2>/dev/null || echo 0)" -eq 0 ] && [ "$(cat "$PRT_TEST_UNRESOLVE_COUNTFILE" 2>/dev/null || echo 0)" -eq 0 ] && echo true || echo false)"
assert_eq "orchestrator: content_fp mismatch against owned thread -> finding surfaces in the withheld/advisory comment" \
  "true" "$(grep -qF 'Withheld AI Review Findings' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" 2>/dev/null && echo true || echo false)"
# go-kure/.github#196 review finding (Important): before this assertion pair,
# a content_fp mismatch (collision=false this run, no persisted collision
# flag on the thread either) rendered the Collision cell as "persisted
# (earlier run)" -- a false claim, since no thread ever carried a persisted
# collision flag in this scenario. quarantine_reason now distinguishes the
# two causes; the cell must read the new content-mismatch label, not the
# persisted one.
assert_eq "orchestrator: content_fp mismatch against owned thread -> Collision cell reads 'content changed (recurring defect)', not 'persisted (earlier run)'" \
  "true" "$(grep -qF '| content changed (recurring defect) |' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && ! grep -qF '| persisted (earlier run) |' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
PRT_TEST_OWNED_CONTENT_FP=""
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_MODEL_RESPONSE_MODE=clean
rm -f "$PRT_TEST_ISSUE_COMMENT_BODY_FILE"
unset PRT_TEST_ISSUE_COMMENT_BODY_FILE

# Case B, control: the owned thread's stored content_fp MATCHES this run's
# finding -> effective_collision stays false on content_fp grounds, normal
# reconciliation proceeds (no false quarantine just because the field is
# present and checked).
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
PRT_TEST_OWNED_CONTENT_FP="a9972e5c88f1fa3f"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: content_fp matches owned thread -> exits 0" "0" "$rc"
assert_eq "orchestrator: content_fp matches owned thread -> stderr done: line reports quarantined=0 (no false quarantine)" \
  "true" "$(grep -qE 'done:.*quarantined=0' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_OWNED_CONTENT_FP=""
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_MODEL_RESPONSE_MODE=clean

# Case C, backward-compat control: the owned thread predates go-kure/.github#196
# and carries no content_fp at all (empty, the default via
# _prt_test_owned_thread_body's `${PRT_TEST_OWNED_CONTENT_FP:-}`) -> unverifiable,
# trust the match, no false quarantine — same assertion as case B, distinct
# fixture (absent field, not a matching one).
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: owned thread predates content_fp (field absent) -> exits 0" "0" "$rc"
assert_eq "orchestrator: owned thread predates content_fp (field absent) -> stderr done: line reports quarantined=0 (pre-existing thread trusted, not retroactively quarantined)" \
  "true" "$(grep -qE 'done:.*quarantined=0' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_MODEL_RESPONSE_MODE=clean

# ---- go-kure/.github#148: lift a persisted collision on an exact content match ----
# Same fixture as the #196 cases above (clean_with_finding: x.go/other,
# issue "i", fix "f" -> content_fp a9972e5c88f1fa3f), but the owned
# thread's marker also carries a persisted collision=true.
lift_cfp="$(prt_content_fp i f)"
PRT_TEST_PATCH_BODY_LOG="$(mktemp)"
PRT_TEST_ISSUE_COMMENT_BODY_FILE="$(mktemp)"

# Lift: single finding, text identical to what the thread was created for
# -> collision=false is written onto the marker (content_fp carried, still
# the thread's own), and the finding reconciles normally: no quarantine.
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
PRT_TEST_OWNED_CONTENT_FP="$lift_cfp"
PRT_TEST_OWNED_COLLISION=true
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: persisted collision + exact content match -> exits 0" "0" "$rc"
assert_eq "orchestrator #148: persisted collision + exact content match -> quarantined=0 (lifted)" \
  "true" "$(grep -qE 'done:.*quarantined=0' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #148: lift -> exactly one marker PATCH" \
  "1" "$(cat "$PRT_TEST_PATCH_COUNTFILE")"
lift_marker="$(prt_marker_parse "$(cat "$PRT_TEST_PATCH_BODY_LOG")")"
assert_eq "orchestrator #148: lift -> the rewritten marker has collision cleared" \
  "" "$(cut -f2 <<< "$lift_marker")"
assert_eq "orchestrator #148: lift -> the rewritten marker keeps the thread's own fp and content_fp" \
  "$(prt_fp_base x.go other) $lift_cfp" "$(cut -f1 <<< "$lift_marker") $(cut -f4 <<< "$lift_marker")"
assert_eq "orchestrator #148: lift -> logged" \
  "true" "$(grep -qF 'collision lifted (content match)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Lift clears a stale absence stamp: stamped on an earlier head before the
# collision, the finding is present this run, so keeping it would let the
# next absence auto-resolve on one absence (prt_decide_absent row 10).
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_FIRST_ABSENT_SHA="2222222222222222222222222222222222222222"
rc="$(run_orchestrator enforce 0 0 0)"
lift_marker="$(prt_marker_parse "$(cat "$PRT_TEST_PATCH_BODY_LOG")")"
assert_eq "orchestrator #148: lift over a stale first_absent_sha -> one PATCH, stamp and collision cleared, content_fp kept" \
  "0 1 ||$lift_cfp" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE") $(cut -f2 <<< "$lift_marker")|$(cut -f3 <<< "$lift_marker")|$(cut -f4 <<< "$lift_marker")"
PRT_TEST_FIRST_ABSENT_SHA=""

# No lift on a text mismatch: content_mismatch still wins, no marker write.
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_OWNED_CONTENT_FP="25122a0a5f719e16"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: persisted collision + content mismatch -> quarantined=1, no PATCH" \
  "0 true 0" "$rc $(grep -qE 'done:.*quarantined=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(cat "$PRT_TEST_PATCH_COUNTFILE")"
assert_eq "orchestrator #148: persisted collision + content mismatch -> Collision cell reads 'content changed (recurring defect)'" \
  "true" "$(grep -qF '| content changed (recurring defect) |' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"

# No lift without a stored content_fp (a thread that predates
# go-kure/.github#196): unverifiable, stays persisted.
PRT_TEST_OWNED_CONTENT_FP=""
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: persisted collision, no stored content_fp -> quarantined=1, no PATCH" \
  "0 true 0" "$rc $(grep -qE 'done:.*quarantined=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(cat "$PRT_TEST_PATCH_COUNTFILE")"
assert_eq "orchestrator #148: persisted collision, no stored content_fp -> Collision cell reads 'persisted (earlier run)'" \
  "true" "$(grep -qF '| persisted (earlier run) |' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"

# Persist failure fails closed: the PATCH is refused, the finding stays
# quarantined as persisted (the flag is still on the marker), and the run
# is REVIEW_INCOMPLETE.
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_OWNED_CONTENT_FP="$lift_cfp"
PRT_TEST_PATCH_FAIL=1
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: lift persist fails -> exits 1 (REVIEW_INCOMPLETE)" "1" "$rc"
assert_eq "orchestrator #148: lift persist fails -> the lift was attempted" \
  "true" "$(grep -qF 'lifting the persisted collision flag' "$PRT_TEST_STDERR_FILE" && [ -s "$PRT_TEST_PATCH_BODY_LOG" ] && echo true || echo false)"
assert_eq "orchestrator #148: lift persist fails -> still quarantined as persisted, not lifted" \
  "true false" "$(grep -qF '| persisted (earlier run) |' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false) $(grep -qF 'collision lifted' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_PATCH_FAIL=0

# The helper's early failure fails closed too: the GET before the rewrite
# returns no body -> no PATCH, still quarantined as persisted, incomplete.
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_COMMENT_GET_EMPTY=1
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: GET before the lift returns no body -> exits 1, no PATCH" \
  "1 0" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE")"
assert_eq "orchestrator #148: GET before the lift returns no body -> still quarantined as persisted, not lifted" \
  "true false" "$(grep -qF '| persisted (earlier run) |' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false) $(grep -qF 'collision lifted' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_COMMENT_GET_EMPTY=0

# Only open threads lift: a resolved thread with a persisted flag and a
# matching text stays quarantined (two identical-text findings share
# fp_base and content_fp; lifting would hand the survivor to row 6/7).
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_OWNED_RESOLVED_BY_BOT=1
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: resolved thread, exact content match -> no PATCH, no lift, quarantined=1" \
  "0 0 false true" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE") $(grep -qF 'collision lifted' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qE 'done:.*quarantined=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_OWNED_RESOLVED_BY_BOT=0

# No lift on incomplete evidence: a dropped malformed row could have been
# the other colliding finding, so the survivor is not trusted as a singleton.
# partial_drop's survivor is x.go/other with issue "i", fix "f" — the same
# text as the thread's.
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_MODEL_RESPONSE_MODE=partial_drop
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: partial-drop run, exact content match -> no PATCH, no lift, quarantined=1" \
  "0 false true" "$(cat "$PRT_TEST_PATCH_COUNTFILE") $(grep -qF 'collision lifted' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qE 'done:.*quarantined=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #148: partial-drop run -> the run is degraded for the drop (control: the fixture really dropped a row)" \
  "true" "$(grep -qF 'partial-drop' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding

# A human can resolve the thread after the inventory snapshot. The lift
# re-reads the live state as its last step before the write: resolved now
# means no PATCH and no lift, and nothing failed; unreadable means no PATCH,
# no lift, and the run is incomplete.
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_LIVE_RESOLVED=true
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: thread resolved after the inventory -> exits 0, no PATCH, no lift, quarantined=1" \
  "0 0 false true" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE") $(grep -qF 'collision lifted' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qE 'done:.*quarantined=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #148: thread resolved after the inventory -> logged" \
  "true" "$(grep -qF 'resolved after the inventory snapshot, not lifted' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_LIVE_RESOLVED=unreadable
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: live resolved state unreadable -> exits 1, no PATCH, no lift, quarantined=1" \
  "1 0 false true" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE") $(grep -qF 'collision lifted' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qE 'done:.*quarantined=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# go-kure/.github#261: the skipped lift would also have cleared an absence
# stamp, so on a stamped thread it records the stale stamp. A lift refused
# because the thread is resolved records none (control).
PRT_TEST_REPLY_BODY_LOG="$(mktemp)"
PRT_TEST_FIRST_ABSENT_SHA="2222222222222222222222222222222222222222"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: unreadable lift on a stamped thread -> one MAINT_FAILURE reply recording the stamp" \
  "1 1 $PRT_TEST_FIRST_ABSENT_SHA" "$rc $(cat "$PRT_TEST_REPLY_COUNTFILE") $(prt_marker_maint_failure_sha "$(cat "$PRT_TEST_REPLY_BODY_LOG")")"
assert_eq "orchestrator #265: that reply names the unreadable resolved state, not a failed PATCH" \
  "true" "$(grep -qF "**MAINT_FAILURE:** the thread's resolved state could not be re-read before the marker write, so the absence marker was not cleared" "$PRT_TEST_REPLY_BODY_LOG" && echo true || echo false)"
PRT_TEST_LIVE_RESOLVED=true
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: lift refused on a resolved stamped thread -> no MAINT_FAILURE reply (control)" \
  "0 0" "$rc $(cat "$PRT_TEST_REPLY_COUNTFILE")"
PRT_TEST_FIRST_ABSENT_SHA=""
rm -f "$PRT_TEST_REPLY_BODY_LOG"
unset PRT_TEST_REPLY_BODY_LOG
PRT_TEST_LIVE_RESOLVED=false

# go-kure/.github#256: the re-read runs before every PATCH attempt, not once
# before the retry loop. The control fails the first attempt with the thread
# still open, to show the retry does reach a second PATCH that lifts.
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_PATCH_FAIL=first
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #256: first lift PATCH fails, thread still open (control) -> exits 0, the retry lifts" \
  "0 1 true" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE") $(grep -qF 'collision lifted' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_LIVE_RESOLVED=false_then_true
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #256: first lift PATCH fails, then the thread is resolved -> exits 0, no PATCH lands, no lift, quarantined=1" \
  "0 0 false true" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE") $(grep -qF 'collision lifted' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qE 'done:.*quarantined=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #256: resolved between attempts -> logged as resolved after the snapshot" \
  "true" "$(grep -qF 'resolved after the inventory snapshot, not lifted' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_LIVE_RESOLVED=false
PRT_TEST_PATCH_FAIL=0

# An earlier write in loop 1 that fails makes the run incomplete, and no
# lift may follow on it. The control runs the same two findings with no
# failure, to show the second finding does lift there.
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_MODEL_RESPONSE_MODE=new_then_owned
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: new finding then owned match, no failure (control) -> exits 0, the owned thread lifts" \
  "0 1 true" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE") $(grep -qF 'collision lifted' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
: > "$PRT_TEST_PATCH_BODY_LOG"
# The body-match write failure is wired inside the issue-comment log arm.
PRT_TEST_ISSUE_COMMENT_LOG="$(mktemp)"
PRT_TEST_WRITE_FAIL_BODY_MATCH='new-issue-text'
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: the first finding's create fails -> exits 1, no PATCH, no lift for the second" \
  "1 0 false" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE") $(grep -qF 'collision lifted' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #148: the first finding's create fails (control: the create really was refused)" \
  "true" "$(grep -qF 'FAILED POST' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"
rm -f "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_ISSUE_COMMENT_LOG=''
PRT_TEST_WRITE_FAIL_BODY_MATCH=''
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding

# This-run multiplicity beats a matching text: the group's fp_base thread
# carries collision=true and the text of its first member, but three
# findings collide this run -> this_run, no lift, no PATCH (already set).
PRT_TEST_MODEL_RESPONSE_MODE=collision_triple
PRT_TEST_OWNED_FP="$(prt_fp_base dup.go other)"
PRT_TEST_OWNED_CONTENT_FP="$(prt_content_fp 'collision issue one' 'fix one')"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: this-run collision with a matching owned text -> quarantined=3, no PATCH, no lift" \
  "0 true 0 false" "$rc $(grep -qE 'done:.*quarantined=3' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(cat "$PRT_TEST_PATCH_COUNTFILE") $(grep -qF 'collision lifted' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Absence: why the lift must be persisted. With no finding this run, loop 2
# reads the marker's own flag — collision=true blocks SET_FIRST_ABSENT
# (prt_decide_absent row 1), the lifted marker takes it.
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
PRT_TEST_OWNED_CONTENT_FP="$lift_cfp"
PRT_TEST_OWNED_COLLISION=true
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: absent finding, marker still collision=true -> no SET_FIRST_ABSENT PATCH" \
  "0 0" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE")"
PRT_TEST_OWNED_COLLISION=""
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #148: absent finding, marker lifted -> SET_FIRST_ABSENT PATCH" \
  "0 1" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE")"

# ---- go-kure/.github#252: a finding's reappearance clears its absence stamp ----
# Head A stamped the thread absent (2222...). The finding is back at this
# head, so loop 1 clears the stamp; otherwise loop 2 (which skips matched
# threads) leaves it, and the next absence resolves on one absence. Same
# x.go/other fixture, open thread, no collision, matching content_fp.
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_OWNED_COLLISION=""
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_FIRST_ABSENT_SHA="2222222222222222222222222222222222222222"
rc="$(run_orchestrator enforce 0 0 0)"
stamp_marker="$(prt_marker_parse "$(cat "$PRT_TEST_PATCH_BODY_LOG")")"
assert_eq "orchestrator #252: finding present on a stamped thread -> exits 0, one PATCH, no resolve" \
  "0 1 0" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE") $(cat "$PRT_TEST_RESOLVE_COUNTFILE")"
assert_eq "orchestrator #252: the rewritten marker drops the stamp, keeps fp, collision and content_fp" \
  "$(prt_fp_base x.go other)|||$lift_cfp" "$(cut -f1 <<< "$stamp_marker")|$(cut -f2 <<< "$stamp_marker")|$(cut -f3 <<< "$stamp_marker")|$(cut -f4 <<< "$stamp_marker")"
assert_eq "orchestrator #252: stamp clear -> logged" \
  "true" "$(grep -qF 'absence stamp cleared (finding present)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# A persisted collision keeps its flag through the stamp clear (no lift: the
# thread predates content_fp, so the lift is unverifiable).
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_OWNED_COLLISION=true
PRT_TEST_OWNED_CONTENT_FP=""
rc="$(run_orchestrator enforce 0 0 0)"
stamp_marker="$(prt_marker_parse "$(cat "$PRT_TEST_PATCH_BODY_LOG")")"
assert_eq "orchestrator #252: stamped thread with a persisted collision -> one PATCH, collision kept, stamp dropped, quarantined=1" \
  "0 1 true| true" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE") $(cut -f2 <<< "$stamp_marker")|$(cut -f3 <<< "$stamp_marker") $(grep -qE 'done:.*quarantined=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_OWNED_COLLISION=""
PRT_TEST_OWNED_CONTENT_FP="$lift_cfp"

# A failed clear leaves the stamp and marks the run incomplete; the next
# present run retries.
: > "$PRT_TEST_PATCH_BODY_LOG"
PRT_TEST_PATCH_FAIL=1
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #252: stamp clear PATCH fails -> exits 1, attempted, not logged as cleared" \
  "1 true false" "$rc $(grep -qF 'clearing a stale absence stamp' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qF 'absence stamp cleared' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_PATCH_FAIL=0

# Control: no stamp -> no extra API call on a normal run.
PRT_TEST_FIRST_ABSENT_SHA=""
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #252: finding present, no stamp (control) -> exits 0, no PATCH" \
  "0 0" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE")"

# The next absence then reads the cleared marker: it stamps this head
# (SET_FIRST_ABSENT) instead of resolving. Control: with the stale stamp
# still on the marker (the pre-fix state) the same absence resolves.
PRT_TEST_MODEL_RESPONSE_MODE=clean
: > "$PRT_TEST_PATCH_BODY_LOG"
rc="$(run_orchestrator enforce 0 0 0)"
stamp_marker="$(prt_marker_parse "$(cat "$PRT_TEST_PATCH_BODY_LOG")")"
assert_eq "orchestrator #252: absence after the clear -> stamps this head, no resolve" \
  "0 1 0 1111111111111111111111111111111111111111" "$rc $(cat "$PRT_TEST_PATCH_COUNTFILE") $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(cut -f3 <<< "$stamp_marker")"
PRT_TEST_FIRST_ABSENT_SHA="2222222222222222222222222222222222222222"
PRT_TEST_RECHECK_MODE=false
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #252: absence over an uncleared stale stamp (control) -> resolves" \
  "0 1" "$rc $(cat "$PRT_TEST_RESOLVE_COUNTFILE")"
PRT_TEST_RECHECK_MODE=
PRT_TEST_FIRST_ABSENT_SHA=""

# ---- go-kure/.github#261: a failed marker clear holds back the next absence ----
# Both clears that can fail (loop 1's stamp clear, loop 2's CLEAR_MARKER) post a
# MAINT_FAILURE reply recording the stamp they left. Row 11 then holds back an
# absence auto-resolve while the thread still carries that stamp.
mf_stamp="2222222222222222222222222222222222222222"
mf_reply_node() { # BODY [AUTHOR] -> a one-element JSON array of reply nodes, posted 2026-01-02
  jq -nc --arg b "$1" --arg a "${2:-test-bot}" '[{id:"C2", databaseId:2, body:$b, author:{login:$a}, createdAt:"2026-01-02T00:00:00Z"}]'
}
PRT_TEST_REPLY_BODY_LOG="$(mktemp)"
# (a) Loop 1: the finding is present, the stamp clear PATCH fails.
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_FIRST_ABSENT_SHA="$mf_stamp"
PRT_TEST_PATCH_FAIL=1
: > "$PRT_TEST_REPLY_BODY_LOG"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: loop-1 stamp clear fails -> exits 1, one MAINT_FAILURE reply recording the stamp" \
  "1 1 $mf_stamp" "$rc $(cat "$PRT_TEST_REPLY_COUNTFILE") $(prt_marker_maint_failure_sha "$(cat "$PRT_TEST_REPLY_BODY_LOG")")"
assert_eq "orchestrator #265: loop-1 failed PATCH -> the reply names the failed retries" \
  "true" "$(grep -qF "**MAINT_FAILURE:** clearing the absence marker failed after 3 retries" "$PRT_TEST_REPLY_BODY_LOG" && echo true || echo false)"
# (a2) The clear fails again on a later run: a reply already records the stamp.
PRT_TEST_THREAD1_REPLIES="$(mf_reply_node "$(prt_render_reply_maint_failure "clear failed" "$mf_stamp")")"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: loop-1 clear fails again, stamp already recorded -> no second reply" \
  "1 0 true" "$rc $(cat "$PRT_TEST_REPLY_COUNTFILE") $(grep -qF "already records stamp $mf_stamp" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_THREAD1_REPLIES="[]"
# (a3) The reply POST fails too: the run names the unrecorded stamp.
PRT_TEST_REPLY_FAIL=1
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: loop-1 clear and its reply both fail -> incomplete, names the stamp" \
  "1 0 true" "$rc $(cat "$PRT_TEST_REPLY_COUNTFILE") $(grep -qF "reply recording stale stamp $mf_stamp failed" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_REPLY_FAIL=0
# (b) Loop 2: an incomplete run's CLEAR_MARKER fails (Case xiii's setup).
PRT_TEST_MODEL_RESPONSE_MODE=partial_drop
PRT_TEST_OWNED_FP="0000000000000000"
: > "$PRT_TEST_REPLY_BODY_LOG"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: loop-2 CLEAR_MARKER fails -> one MAINT_FAILURE reply recording the stamp" \
  "1 $mf_stamp" "$(cat "$PRT_TEST_REPLY_COUNTFILE") $(prt_marker_maint_failure_sha "$(cat "$PRT_TEST_REPLY_BODY_LOG")")"
assert_eq "orchestrator #265: loop-2 failed PATCH -> the reply names the failed retries" \
  "true" "$(grep -qF "**MAINT_FAILURE:** clearing the absence marker failed after 3 retries" "$PRT_TEST_REPLY_BODY_LOG" && echo true || echo false)"
# (b2) and (b3): loop 2's dedupe and failed reply, as (a2) and (a3).
PRT_TEST_THREAD1_REPLIES="$(mf_reply_node "$(prt_render_reply_maint_failure "clear failed" "$mf_stamp")")"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: loop-2 CLEAR_MARKER fails again, stamp already recorded -> no second reply" \
  "0 true" "$(cat "$PRT_TEST_REPLY_COUNTFILE") $(grep -qF "already records stamp $mf_stamp" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_THREAD1_REPLIES="[]"
PRT_TEST_REPLY_FAIL=1
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: loop-2 CLEAR_MARKER and its reply both fail -> names the stamp" \
  "0 true" "$(cat "$PRT_TEST_REPLY_COUNTFILE") $(grep -qF "reply recording stale stamp $mf_stamp failed" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_REPLY_FAIL=0
PRT_TEST_PATCH_FAIL=0
# (b4) A clear skipped before its PATCH (the comment GET fails) leaves the
# stamp stale too: loop 2 records it, as does loop 1 below.
PRT_TEST_COMMENT_GET_EMPTY=1
: > "$PRT_TEST_REPLY_BODY_LOG"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: loop-2 CLEAR_MARKER skipped on a failed GET -> one MAINT_FAILURE reply recording the stamp" \
  "1 $mf_stamp" "$(cat "$PRT_TEST_REPLY_COUNTFILE") $(prt_marker_maint_failure_sha "$(cat "$PRT_TEST_REPLY_BODY_LOG")")"
assert_eq "orchestrator #265: loop-2 failed GET -> the reply names the unread comment, not a failed PATCH" \
  "true" "$(grep -qF "**MAINT_FAILURE:** the thread's first comment could not be read before the marker write, so the absence marker was not cleared" "$PRT_TEST_REPLY_BODY_LOG" && echo true || echo false)"
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
: > "$PRT_TEST_REPLY_BODY_LOG"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: loop-1 stamp clear skipped on a failed GET -> exits 1, one MAINT_FAILURE reply recording the stamp" \
  "1 1 $mf_stamp" "$rc $(cat "$PRT_TEST_REPLY_COUNTFILE") $(prt_marker_maint_failure_sha "$(cat "$PRT_TEST_REPLY_BODY_LOG")")"
assert_eq "orchestrator #265: loop-1 failed GET -> the reply names the unread comment, not a failed PATCH" \
  "true" "$(grep -qF "**MAINT_FAILURE:** the thread's first comment could not be read before the marker write, so the absence marker was not cleared" "$PRT_TEST_REPLY_BODY_LOG" && echo true || echo false)"
PRT_TEST_COMMENT_GET_EMPTY=0
# (b5) A clear skipped on a stale head (its own freshness check) also records
# the stamp. The read count before that check differs per path, so each case
# walks the offsets down from the last read and takes the first whose degraded
# reason names that check: the clear runs late in the run, so this stops after
# a few runs, and a lower offset would trip an earlier check first.
mf_stale_case() { # MODE OWNED_FP REASON_TEXT -> "<replies> <recorded stamp>" at that offset, or "none"
  local k total
  PRT_TEST_MODEL_RESPONSE_MODE="$1"; PRT_TEST_OWNED_FP="$2"
  rc="$(run_orchestrator enforce 0 0 0)"
  total="$(cat "$PRT_TEST_META_COUNTFILE")"
  for ((k = total - 1; k >= 1; k--)); do
    : > "$PRT_TEST_REPLY_BODY_LOG"
    PRT_TEST_STALE_AFTER_CALL=$k
    rc="$(run_orchestrator enforce 0 0 0)"
    PRT_TEST_STALE_AFTER_CALL=0
    if grep -qF "REVIEW_DEGRADED: $3: stale head SHA" "$PRT_TEST_STDERR_FILE"; then
      echo "$(cat "$PRT_TEST_REPLY_COUNTFILE") $(prt_marker_maint_failure_sha "$(cat "$PRT_TEST_REPLY_BODY_LOG")")"
      return 0
    fi
  done
  echo none
}
# mf_stale_case returns on the matching run, so the reply log still holds
# that run's reply for the #265 reason check.
assert_eq "orchestrator #261: loop-1 stamp clear skipped on a stale head -> one MAINT_FAILURE reply recording the stamp" \
  "1 $mf_stamp" "$(mf_stale_case clean_with_finding "$(prt_fp_base x.go other)" "fp=$(prt_fp_base x.go other): clearing a stale absence stamp ($mf_stamp)")"
assert_eq "orchestrator #265: loop-1 stale head -> the reply names the moved head, not a failed PATCH" \
  "true" "$(grep -qF "**MAINT_FAILURE:** the head moved before the marker write, so the absence marker was not cleared" "$PRT_TEST_REPLY_BODY_LOG" && echo true || echo false)"
assert_eq "orchestrator #261: loop-2 CLEAR_MARKER skipped on a stale head -> one MAINT_FAILURE reply recording the stamp" \
  "1 $mf_stamp" "$(mf_stale_case partial_drop 0000000000000000 "fp=0000000000000000: marker clear")"
assert_eq "orchestrator #265: loop-2 stale head -> the reply names the moved head, not a failed PATCH" \
  "true" "$(grep -qF "**MAINT_FAILURE:** the head moved before the marker write, so the absence marker was not cleared" "$PRT_TEST_REPLY_BODY_LOG" && echo true || echo false)"
# (b6) The freshness check before the write passes, then every PR read fails,
# so each retried write attempt fails its own freshness check and sends no
# PATCH (write status 2). Same offset walk as (b5), matched on the retried
# write's incomplete reason.
mf_read_fail_case() { # MODE OWNED_FP CONTEXT -> "<replies> <recorded stamp> <PATCHes>" at that offset, or "none"
  local k total
  PRT_TEST_MODEL_RESPONSE_MODE="$1"; PRT_TEST_OWNED_FP="$2"
  rc="$(run_orchestrator enforce 0 0 0)"
  total="$(cat "$PRT_TEST_META_COUNTFILE")"
  for ((k = total - 1; k >= 1; k--)); do
    : > "$PRT_TEST_REPLY_BODY_LOG"
    PRT_TEST_PR_READ_FAIL_AFTER_CALL=$k
    rc="$(run_orchestrator enforce 0 0 0)"
    PRT_TEST_PR_READ_FAIL_AFTER_CALL=0
    if grep -qF "REVIEW_INCOMPLETE: $3 (after up to 3 retries): PR read failed" "$PRT_TEST_STDERR_FILE"; then
      echo "$(cat "$PRT_TEST_REPLY_COUNTFILE") $(prt_marker_maint_failure_sha "$(cat "$PRT_TEST_REPLY_BODY_LOG")") $(cat "$PRT_TEST_PATCH_COUNTFILE")"
      return 0
    fi
  done
  echo none
}
assert_eq "orchestrator #261: loop-1 stamp clear, every write attempt's PR read fails -> one MAINT_FAILURE reply recording the stamp, no PATCH" \
  "1 $mf_stamp 0" "$(mf_read_fail_case clean_with_finding "$(prt_fp_base x.go other)" "fp=$(prt_fp_base x.go other): clearing a stale absence stamp ($mf_stamp)")"
assert_eq "orchestrator #265: loop-1 write status 2 -> the reply names the unread PR, not failed retries" \
  "true false" "$(grep -qF "**MAINT_FAILURE:** the PR could not be read before the last of up to 3 marker write attempts, so the absence marker was not cleared" "$PRT_TEST_REPLY_BODY_LOG" && echo true || echo false) $(grep -qF 'failed after 3 retries' "$PRT_TEST_REPLY_BODY_LOG" && echo true || echo false)"
assert_eq "orchestrator #261: loop-2 CLEAR_MARKER, every write attempt's PR read fails -> one MAINT_FAILURE reply recording the stamp, no PATCH" \
  "1 $mf_stamp 0" "$(mf_read_fail_case partial_drop 0000000000000000 "fp=0000000000000000: clearing the absence marker")"
assert_eq "orchestrator #265: loop-2 write status 2 -> the reply names the unread PR, not failed retries" \
  "true false" "$(grep -qF "**MAINT_FAILURE:** the PR could not be read before the last of up to 3 marker write attempts, so the absence marker was not cleared" "$PRT_TEST_REPLY_BODY_LOG" && echo true || echo false) $(grep -qF 'failed after 3 retries' "$PRT_TEST_REPLY_BODY_LOG" && echo true || echo false)"
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
# (c) The next complete run is an absence at a new head, over the same stamp.
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_RECHECK_MODE=false
PRT_TEST_THREAD1_REPLIES="$(mf_reply_node "$(prt_render_reply_maint_failure "clear failed" "$mf_stamp")")"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: absence over the stamp a MAINT_FAILURE reply recorded -> exits 0, no resolve, re-stamped" \
  "0 0 1 true" "$rc $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(cat "$PRT_TEST_PATCH_COUNTFILE") $(grep -qE 'absent -> SET_FIRST_ABSENT' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# (c2) The first comment was edited after the reply (a later clear or
# re-stamp landed), so the reply is retired even though the stamp still
# names the same SHA: the absence resolves.
PRT_TEST_THREAD1_LAST_EDITED="2026-01-03T00:00:00Z"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: reply older than the first comment's last edit -> retired, resolves" \
  "0 1" "$rc $(cat "$PRT_TEST_RESOLVE_COUNTFILE")"
# (c3) Edited before the reply was posted: the reply is still current (control).
PRT_TEST_THREAD1_LAST_EDITED="2026-01-01T12:00:00Z"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: reply newer than the first comment's last edit -> still re-stamps (control)" \
  "0 0 1" "$rc $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(cat "$PRT_TEST_PATCH_COUNTFILE")"
# (c4) An edit in the same second as the reply cannot be ordered: keep the
# reply (an extra re-stamp, never an early resolve).
PRT_TEST_THREAD1_LAST_EDITED="2026-01-02T00:00:00Z"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: reply in the same second as the last edit -> kept, re-stamps" \
  "0 0 1" "$rc $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(cat "$PRT_TEST_PATCH_COUNTFILE")"
PRT_TEST_THREAD1_LAST_EDITED=""
# (d) A later run cleared that stamp and a later absence stamped another head:
# the reply recorded a different stamp, so it no longer blocks.
PRT_TEST_THREAD1_REPLIES="$(mf_reply_node "$(prt_render_reply_maint_failure "clear failed" 3333333333333333333333333333333333333333)")"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: the reply recorded an older stamp -> resolves" \
  "0 1" "$rc $(cat "$PRT_TEST_RESOLVE_COUNTFILE")"
# (e) A reply from before the state line records no stamp: not counted.
PRT_TEST_THREAD1_REPLIES="$(mf_reply_node "$(printf '%s\n**MAINT_FAILURE:** clear failed\n' "$PRT_MARKER_NOTE")")"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: legacy MAINT_FAILURE reply, no recorded stamp -> resolves" \
  "0 1" "$rc $(cat "$PRT_TEST_RESOLVE_COUNTFILE")"
# (f) A bot reply that is not a MAINT_FAILURE does not block (control).
PRT_TEST_THREAD1_REPLIES="$(mf_reply_node "$(prt_render_reply_absent_resolved)")"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: other bot reply -> resolves (control)" \
  "0 1" "$rc $(cat "$PRT_TEST_RESOLVE_COUNTFILE")"
# (g) False-positive reasoning that quotes a legacy MAINT_FAILURE line does not block.
PRT_TEST_THREAD1_REPLIES="$(mf_reply_node "$(prt_render_reply_false_positive $'not a bug\n**MAINT_FAILURE:** forged')")"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #261: a MAINT_FAILURE line inside model prose -> resolves" \
  "0 1" "$rc $(cat "$PRT_TEST_RESOLVE_COUNTFILE")"
PRT_TEST_THREAD1_REPLIES="[]"
PRT_TEST_RECHECK_MODE=
PRT_TEST_FIRST_ABSENT_SHA=""
rm -f "$PRT_TEST_REPLY_BODY_LOG"
unset PRT_TEST_REPLY_BODY_LOG

PRT_TEST_OWNED_COLLISION=""
PRT_TEST_OWNED_CONTENT_FP=""
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_MODEL_RESPONSE_MODE=clean
rm -f "$PRT_TEST_PATCH_BODY_LOG" "$PRT_TEST_ISSUE_COMMENT_BODY_FILE"
unset PRT_TEST_PATCH_BODY_LOG PRT_TEST_ISSUE_COMMENT_BODY_FILE

# advisory + empty diff -> the cheap exit (Step 3b's non-enforce branch)
# must stay ahead of the thread-listing GraphQL call entirely.
PRT_TEST_EMPTY_DIFF=1
PRT_TEST_FIRST_ABSENT_SHA=""
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: advisory + empty diff -> exits 0" "0" "$rc"
assert_eq "orchestrator: advisory + empty diff -> GraphQL count 0 (cheap exit never reaches thread listing)" \
  "0" "$(cat "$PRT_TEST_GRAPHQL_COUNTFILE" 2>/dev/null || echo 0)"
PRT_TEST_EMPTY_DIFF=0
PRT_TEST_FIRST_ABSENT_SHA=""

# PR #284 shape: GitHub returns review threads in 50/50/20 pages. Each page
# stays below Linux's 131072-byte single-argument ceiling, but the 100-thread
# accumulator does not. The orchestrator must retain all 120 without ever
# passing that accumulator through execve argv.
PRT_TEST_INVENTORY_MODE=paged_threads
PRT_TEST_EMPTY_DIFF=1
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: 50/50/20 thread inventory exits 0" "0" "$rc"
assert_eq "orchestrator: 50/50/20 thread inventory retains and logs all 120 threads" \
  "true" "$(grep -q 'threads listed (pre-existing): 120, owned=0' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: 50/50/20 thread inventory never hits argv E2BIG" \
  "false" "$(grep -q 'Argument list too long' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# The 120 threads are human threads with no marker: none may count as a
# foreign-marked bot thread (go-kure/.github#153's detector keys on the marker,
# not on the author alone).
assert_eq "orchestrator: 120 unmarked human threads -> foreign_marked=0" \
  "true" "$(grep -qF 'threads listed (pre-existing): 120, owned=0, foreign_marked=0' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: 120 unmarked human threads -> no foreign-marked-threads reason" \
  "false" "$(grep -qF 'foreign-marked-threads' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# The first 50 comments plus 50/20 follow-up pages leave the combined extra
# comment accumulator above 131072 bytes. The final reply is human-authored;
# losing it would make the second-absence path incorrectly auto-resolve.
PRT_TEST_INVENTORY_MODE=paginated_comments
PRT_TEST_FIRST_ABSENT_SHA=2222222222222222222222222222222222222222
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: oversized paginated comments exit 0" "0" "$rc"
assert_eq "orchestrator: oversized paginated comments retain the owned thread" \
  "true" "$(grep -q 'threads listed (pre-existing): 1, owned=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: late human reply prevents incorrect auto-resolution" \
  "0" "$(cat "$PRT_TEST_RESOLVE_COUNTFILE")"
assert_eq "orchestrator: oversized paginated comments never hit argv E2BIG" \
  "false" "$(grep -q 'Argument list too long' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# A malformed page is an unknown inventory, never an empty inventory. It must
# render REVIEW_INCOMPLETE and stop before cap evaluation or any write path.
PRT_TEST_INVENTORY_MODE=malformed_threads
PRT_TEST_FIRST_ABSENT_SHA=''
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: malformed inventory page exits 1" "1" "$rc"
assert_eq "orchestrator: malformed inventory page records REVIEW_INCOMPLETE" \
  "true" "$(grep -q 'REVIEW_INCOMPLETE: review thread inventory failed at reviewThreads page extraction' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: malformed inventory diagnostic does not dump the payload" \
  "false" "$(grep -qF '"nodes":{}' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: malformed inventory page makes zero PATCH/create/reply/resolve/unresolve/comment writes" \
  "0 0 0 0 0 0" "$(cat "$PRT_TEST_PATCH_COUNTFILE") $(cat "$PRT_TEST_CREATE_COUNTFILE") $(cat "$PRT_TEST_REPLY_COUNTFILE") $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(cat "$PRT_TEST_UNRESOLVE_COUNTFILE") $(cat "$PRT_TEST_ISSUE_COMMENT_COUNTFILE")"

# prt_gh_graphql normally diagnoses HTTP/GraphQL errors with response content.
# Inventory callers suppress that untrusted body and replace it with the
# stage-only fail-closed diagnostic before any write path.
PRT_TEST_INVENTORY_MODE=inventory_http_error
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: inventory HTTP failure exits 1" "1" "$rc"
assert_eq "orchestrator: inventory HTTP failure emits the stage-only diagnostic" \
  "true" "$(grep -q 'review thread inventory failed at reviewThreads request' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: inventory HTTP failure does not dump the hostile payload" \
  "false" "$(grep -qF 'hostile_inventory_payload' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: inventory HTTP failure makes zero PATCH/create/reply/resolve/unresolve/comment writes" \
  "0 0 0 0 0 0" "$(cat "$PRT_TEST_PATCH_COUNTFILE") $(cat "$PRT_TEST_CREATE_COUNTFILE") $(cat "$PRT_TEST_REPLY_COUNTFILE") $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(cat "$PRT_TEST_UNRESOLVE_COUNTFILE") $(cat "$PRT_TEST_ISSUE_COMMENT_COUNTFILE")"

PRT_TEST_INVENTORY_MODE=single
PRT_TEST_EMPTY_DIFF=0
PRT_TEST_FIRST_ABSENT_SHA=''

# go-kure/.github#153: a thread whose first comment carries a valid marker
# but was opened by another login is not owned (this run may not edit another
# account's comment) and is read-only. After a bot-identity change every
# thread is foreign that way, so it surfaces as a REVIEW_DEGRADED
# foreign-marked-threads reason (exit 0, a ::warning) and a foreign_marked=
# count on the threads-listed line. With no finding matching it, the thread is
# not reconciled and the clean verdict is not withheld.
PRT_TEST_OWNED_AUTHOR=github-actions
PRT_TEST_ISSUE_COMMENT_BODY_FILE="$(mktemp)"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: foreign-marked thread -> exits 0 (degraded, not incomplete)" "0" "$rc"
assert_eq "orchestrator: foreign-marked thread -> REVIEW_DEGRADED names the count, the foreign login and the configured one" \
  "true" "$(grep -qF 'REVIEW_DEGRADED: foreign-marked-threads: 1 thread(s) carry this action'"'"'s marker but were opened by github-actions, not the configured bot login test-bot;' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: foreign-marked thread -> ::warning on stdout, no ::error" \
  "true false" "$(grep -q '::warning title=PR review threads degraded::foreign-marked-threads' "$PRT_TEST_STDOUT_FILE" && echo true || echo false) $(grep -q '::error title=' "$PRT_TEST_STDOUT_FILE" && echo true || echo false)"
assert_eq "orchestrator: foreign-marked thread -> threads-listed line counts it, and it is not owned" \
  "true" "$(grep -qF 'threads listed (pre-existing): 1, owned=0, foreign_marked=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: foreign-marked thread -> never reconciled (no PATCH/resolve/unresolve/reply)" \
  "0 0 0 0" "$(cat "$PRT_TEST_PATCH_COUNTFILE") $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(cat "$PRT_TEST_UNRESOLVE_COUNTFILE") $(cat "$PRT_TEST_REPLY_COUNTFILE")"
assert_eq "orchestrator: foreign-marked thread -> the clean verdict is still posted (the reason is not a parse failure)" \
  "true" "$(grep -qF 'Reviewed, no findings' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
PRT_TEST_OWNED_AUTHOR=test-bot
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: normal run -> threads-listed line reports foreign_marked=0" \
  "true" "$(grep -qF 'threads listed (pre-existing): 1, owned=1, foreign_marked=0' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: normal run -> no foreign-marked-threads reason" \
  "false" "$(grep -qF 'foreign-marked-threads' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
rm -f "$PRT_TEST_ISSUE_COMMENT_BODY_FILE"
unset PRT_TEST_ISSUE_COMMENT_BODY_FILE PRT_TEST_OWNED_AUTHOR

# ---- go-kure/.github#153: foreign threads and comments are read-only ----
prt_foreign_writes() {
  echo "$(cat "$PRT_TEST_CREATE_COUNTFILE") $(cat "$PRT_TEST_PATCH_COUNTFILE") $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(cat "$PRT_TEST_UNRESOLVE_COUNTFILE") $(cat "$PRT_TEST_REPLY_COUNTFILE")"
}
PRT_TEST_ISSUE_COMMENT_LOG="$(mktemp)"

# A VALID finding recurs, and its only thread was opened by another login: no
# duplicate thread, no write of any kind to the foreign one, and the run is
# not clean (no clean verdict). The thread is open, so it keeps blocking merge.
PRT_TEST_OWNED_AUTHOR=github-actions
PRT_TEST_OWNED_FP="$(prt_fp_base x.go other)"
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_ASSESS_RESPONSE_MODE=valid_survivor
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153: recurring VALID finding, only a foreign open thread -> exits 0, no CREATE/PATCH/resolve/unresolve/reply" \
  "0 0 0 0 0 0" "$rc $(prt_foreign_writes)"
assert_eq "orchestrator #153: recurring finding on a foreign thread -> logged as FOREIGN, read-only" \
  "true" "$(grep -qF -- "-> FOREIGN (thread opened by github-actions, read-only)" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #153: recurring finding on a foreign thread -> no clean verdict posted, the finding still counts" \
  "false true" "$(grep -qF 'Reviewed, no findings' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false) $(grep -qE 'done: findings=1 ' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# The foreign thread already carries it: not re-posted to the overflow
# comment either (the cap leaves it out of the CREATE candidates, which
# without loop 1's foreign skip would route it to OVERFLOW).
assert_eq "orchestrator #153: recurring finding on a foreign thread -> no issue comment posted (no overflow copy)" \
  "0" "$(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG")"
assert_eq "orchestrator #153: recurring finding on a foreign thread -> accounted for (no accounting-mismatch degrade)" \
  "false" "$(grep -qF 'accounting mismatch' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #153: the foreign-marked-threads reason says the threads are read-only and block merge while open" \
  "true" "$(grep -qF 'they are read-only to this run: none of them is resolved, reopened, replied to or re-stamped; while one is open, a matching finding gets no new thread' "$PRT_TEST_STDERR_FILE" && grep -qF 'blocks merge until a human resolves it' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Whatever the verdict: a FALSE_POSITIVE on a foreign thread is not resolved
# and gets no reply (an owned thread would be auto-resolved).
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_ASSESS_RESPONSE_MODE=false_positive_survivor
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153: FALSE_POSITIVE on a foreign open thread -> no resolve, no reply, no write at all" \
  "0 0 0 0 0 0" "$rc $(prt_foreign_writes)"

# Resolved foreign thread: the finding is treated as an own thread resolved
# by the bot would be (prt_decide_finding rows 1, 7, or the resolved
# FALSE_POSITIVE branch), whoever resolved it, and the foreign thread itself
# is never written to.
#
# R2-P1: resolved by a human (someone other than its opener), no content_fp
# on the marker, VALID finding recurs. A foreign resolution is not trusted:
# its author can edit the marker onto any old resolved comment of theirs, so
# the finding gets a new own thread (gating), not nothing.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_ASSESS_RESPONSE_MODE=valid_survivor
PRT_TEST_THREAD1_RESOLVED=1
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153 (R2-P1): VALID finding recurs on a foreign thread a human resolved -> exactly one new own thread, no write to the foreign one" \
  "0 1 0 0 0 0" "$rc $(prt_foreign_writes)"
assert_eq "orchestrator #153 (R2-P1): human-resolved foreign match -> logged as a new own thread, then CREATE, no overflow copy, no clean verdict" \
  "true true 0 false" "$(grep -qF 'read-only; resolved and the finding recurs: new own thread instead of a reopen' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qE -- "fp=$(prt_fp_base x.go other) -> CREATE" "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG") $(grep -qF 'Reviewed, no findings' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"
# Resolved by the login that opened it (its own auto-resolve), VALID finding
# recurs: an own thread would be reopened (row 7), so a new own thread is
# created instead, and the foreign one is left as it is. This also closes the
# route where a participant opens and resolves a marker-bearing thread to stop
# a recurring finding from gating.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_THREAD1_RESOLVED_BY=github-actions
PRT_TEST_CREATE_BODY_LOG="$(mktemp)"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153: VALID finding recurs on a foreign thread its author resolved -> exactly one new own thread, no PATCH/resolve/unresolve/reply" \
  "0 1 0 0 0 0" "$rc $(prt_foreign_writes)"
assert_eq "orchestrator #153: the new thread carries this run's own marker for the finding's fp" \
  "true" "$(grep -qF "$(prt_fp_base x.go other)" "$PRT_TEST_CREATE_BODY_LOG" && echo true || echo false)"
assert_eq "orchestrator #153: logged as a new own thread instead of a reopen, then CREATE" \
  "true true" "$(grep -qF 'resolved and the finding recurs: new own thread instead of a reopen' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qE -- "fp=$(prt_fp_base x.go other) -> CREATE" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #153: new own thread for a resolved foreign match -> accounted for, no overflow copy" \
  "false 0" "$(grep -qF 'accounting mismatch' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG")"
assert_eq "orchestrator #153: the foreign-marked-threads reason says a resolved one, by anyone, is not trusted and a recurring finding gets a new thread" \
  "true" "$(grep -qF 'once it is resolved, by anyone, a recurring finding gets a new thread from this login (a foreign resolution is not trusted: its marker is editable by its author), and a human resolves that one' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
rm -f "$PRT_TEST_CREATE_BODY_LOG"
unset PRT_TEST_CREATE_BODY_LOG
# Resolved by its author, but the finding is now a FALSE_POSITIVE: an own
# thread would stay resolved (resolved + FALSE_POSITIVE -> NONE), so nothing.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_ASSESS_RESPONSE_MODE=false_positive_survivor
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153: FALSE_POSITIVE on a foreign thread its author resolved -> no CREATE, no write at all" \
  "0 0 0 0 0 0 true" "$rc $(prt_foreign_writes) $(grep -qF 'read-only; resolved, not reopened' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# R1-P1: a foreign marker is untrusted. A participant plants a matching
# marker with collision=true and resolves it under the same login: the flag
# is never read, so the recurring VALID finding gets a new own thread, not a
# non-gating QUARANTINE.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_ASSESS_RESPONSE_MODE=valid_survivor
PRT_TEST_OWNED_COLLISION=true
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153 (R1-P1): planted collision=true marker resolved by its author -> CREATE, not QUARANTINE, no write to it" \
  "0 1 0 0 0 0 false" "$rc $(prt_foreign_writes) $(grep -qE -- "fp=$(prt_fp_base x.go other) -> QUARANTINE" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# Same with another finding's content_fp on the planted marker: not this
# finding, so the no-thread path, never quarantine.
PRT_TEST_OWNED_COLLISION=""
PRT_TEST_OWNED_CONTENT_FP="0123456789abcdef"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153 (R1-P1): planted marker with another finding's content_fp, resolved by its author -> CREATE, not QUARANTINE" \
  "0 1 0 0 0 0 false" "$rc $(prt_foreign_writes) $(grep -qE -- "fp=$(prt_fp_base x.go other) -> QUARANTINE" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_OWNED_CONTENT_FP=""
# R1-P2a: two resolved foreign threads for the same fp. Author-resolved
# first, human-resolved second: one decision (no foreign resolution is
# trusted, so NEW), and the cap walk agrees (one CREATE within the cap, no
# overflow copy).
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_THREAD2_RESOLVED_BY="a-human"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153 (R1-P2a/R2-P1): author-resolved + human-resolved pair -> exactly one new own thread, no overflow copy, no write to either" \
  "0 1 0 0 0 0 0 false" "$rc $(prt_foreign_writes) $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG") $(grep -qF 'read-only; resolved, not reopened' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #153 (R1-P2a): the pair is decided once and accounted for" \
  "1 false" "$(grep -c -- "fp=$(prt_fp_base x.go other) -> FOREIGN" "$PRT_TEST_STDERR_FILE") $(grep -qF 'accounting mismatch' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# Both author-resolved: one replacement own thread, with a slot (CREATE, not
# OVERFLOW).
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_THREAD2_RESOLVED_BY=github-actions
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153 (R1-P2a): two author-resolved threads -> exactly one replacement own thread within the cap, no overflow, no write" \
  "0 1 0 0 0 0 0" "$rc $(prt_foreign_writes) $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG")"
PRT_TEST_THREAD2_RESOLVED_BY=""
PRT_TEST_THREAD1_RESOLVED_BY="a-human"
PRT_TEST_THREAD1_RESOLVED=0
# R1-P2b: an OPEN foreign thread whose marker content_fp differs is not this
# finding: the finding takes the no-thread path (CREATE), never quarantine,
# and the foreign thread is still not written to.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_OWNED_CONTENT_FP="0123456789abcdef"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153 (R1-P2b): open foreign thread with a different content_fp -> CREATE, no QUARANTINE, no write to it" \
  "0 1 0 0 0 0 false true" "$rc $(prt_foreign_writes) $(grep -qE -- "fp=$(prt_fp_base x.go other) -> QUARANTINE" "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qF 'has a different content fingerprint: not this finding' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# Equal content_fp: the existing thread, as before.
PRT_TEST_OWNED_CONTENT_FP="$(prt_content_fp i f)"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153 (R1-P2b): open foreign thread with an equal content_fp -> no CREATE, read-only" \
  "0 0 0 0 0 0 true" "$rc $(prt_foreign_writes) $(grep -qF -- "-> FOREIGN (thread opened by github-actions, read-only)" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_OWNED_CONTENT_FP=""

# R2-P3: prt_foreign_action fails in loop 1 after the cap walk ran it on the
# same input (open foreign thread, so the cap walk decided EXISTING and left
# the finding out of the CREATE candidates). The NOMATCH fallback alone would
# route the finding to a non-gating OVERFLOW and exit 0; the run must be
# REVIEW_INCOMPLETE instead. Seam: an exported jq shim, inherited by the
# orchestrator subprocess, fails the row-selection filter only prt_foreign_action
# uses, from its second call on (call 1 is the cap walk, call 2 loop 1), so
# the cap walk succeeds and only loop 1's decision fails.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
t153_jq_sel_countfile="$(mktemp)"
echo 0 > "$t153_jq_sel_countfile"
rc="$(
  # Invoked indirectly by the orchestrator; the $cfp is the literal jq filter text.
  # shellcheck disable=SC2329,SC2016
  jq() {
    case "$*" in
      *'.content_fp == $cfp'*)
        [ "$(_prt_test_bump "$PRT_TEST_JQ_SEL_COUNTFILE")" -ge 2 ] && return 5 ;;
    esac
    command jq "$@"
  }
  export -f jq
  export PRT_TEST_JQ_SEL_COUNTFILE="$t153_jq_sel_countfile"
  run_orchestrator enforce 0 0 0
)"
assert_eq "orchestrator #153 (R2-P3): foreign-thread decision fails in loop 1 only -> exits 1, REVIEW_INCOMPLETE names the fp" \
  "1 true" "$rc $(grep -qF "REVIEW_INCOMPLETE: foreign-thread decision failed for fp=$(prt_fp_base x.go other)" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #153 (R2-P3): the cap walk's call succeeded (no cap abort) and loop 1's was the failing one" \
  "false 2" "$(grep -qF 'review inventory cap evaluation failed' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(cat "$t153_jq_sel_countfile")"
rm -f "$t153_jq_sel_countfile"
unset t153_jq_sel_countfile

# R3-P1: the cap walk's own read of the finding's issue text fails. Cap 2; a
# High finding matches the open foreign thread (equal content_fp), a Medium
# one needs a thread. Control first: the open thread reserves one slot, the
# High finding stays on it, the Medium one gets the other.
PRT_TEST_MODEL_RESPONSE_MODE=high_owned_then_new
PRT_TEST_OWNED_CONTENT_FP="$(prt_content_fp i f)"
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
rc="$(PRT_MAX_FINDINGS_TOTAL=2 run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153 (R3-P1 control): cap 2, High finding on an open foreign thread, Medium new one -> one CREATE, no overflow copy" \
  "0 1 0 0 0 0 0" "$rc $(prt_foreign_writes) $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG")"
# Injected: an empty issue text hashes to another content_fp, the cap walk
# reads the High finding as NOMATCH and gives it the free slot, and loop 1
# (which reads it fine) keeps it on the foreign thread while the Medium one
# overflows. The failed read must abort the walk instead. Seam: the first
# `jq -r .issue` of the run is the cap walk's (no owned row carries a
# content_fp, and loop 1 runs after it).
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
t153_jq_issue_countfile="$(mktemp)"
echo 0 > "$t153_jq_issue_countfile"
rc="$(
  # Invoked indirectly by the orchestrator.
  # shellcheck disable=SC2329
  jq() {
    case "$*" in
      '-r .issue')
        [ "$(_prt_test_bump "$PRT_TEST_JQ_ISSUE_COUNTFILE")" -eq 1 ] && return 5 ;;
    esac
    command jq "$@"
  }
  export -f jq
  export PRT_TEST_JQ_ISSUE_COUNTFILE="$t153_jq_issue_countfile"
  PRT_MAX_FINDINGS_TOTAL=2 run_orchestrator enforce 0 0 0
)"
assert_eq "orchestrator #153 (R3-P1): issue read fails in the cap walk -> exits 1, cap evaluation aborted as REVIEW_INCOMPLETE, no write" \
  "1 true 0 0 0 0 0 0" "$rc $(grep -qF 'REVIEW_INCOMPLETE: review inventory cap evaluation failed' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(prt_foreign_writes) $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG")"
assert_eq "orchestrator #153 (R3-P1): the injected failure was the cap walk's only issue read" \
  "1" "$(cat "$t153_jq_issue_countfile")"
rm -f "$t153_jq_issue_countfile"
unset t153_jq_issue_countfile
# R4-P1: reading the foreign marker's content_fp fails while the inventory is
# built. An empty content_fp would let the thread match a finding it was not
# opened for; the inventory must fail instead, before any write.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
rc="$(
  # Invoked indirectly by the orchestrator.
  # shellcheck disable=SC2329
  cut() { [ "$*" = "-f4" ] && return 5; command cut "$@"; }
  export -f cut
  PRT_MAX_FINDINGS_TOTAL=2 run_orchestrator enforce 0 0 0
)"
assert_eq "orchestrator #153 (R4-P1): foreign content_fp read fails -> exits 1, inventory fails at the foreign row, no write" \
  "1 true 0 0 0 0 0 0" "$rc $(grep -qF 'review thread inventory failed at foreign-row construction' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(prt_foreign_writes) $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG")"
PRT_TEST_OWNED_CONTENT_FP=""
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding

# The finding is gone and the foreign thread carries an absence stamp from an
# earlier head: an owned thread would be resolved here (second absence). A
# foreign one gets no resolve, no reply and no marker rewrite.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_ASSESS_RESPONSE_MODE=clean
PRT_TEST_FIRST_ABSENT_SHA=2222222222222222222222222222222222222222
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153: foreign thread whose finding is absent, stamped at an earlier head -> no resolve, reply or PATCH" \
  "0 0 0 0 0 0" "$rc $(prt_foreign_writes)"
assert_eq "orchestrator #153: absence handling never looks at a foreign thread" \
  "false" "$(grep -qF 'absent ->' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# Unstamped: no SET_FIRST_ABSENT stamp is written either.
PRT_TEST_FIRST_ABSENT_SHA=''
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153: foreign thread whose finding is absent, unstamped -> not stamped (no PATCH)" \
  "0 0 0 0 0 0" "$rc $(prt_foreign_writes)"
PRT_TEST_OWNED_FP="deadbeefcafebabe"
PRT_TEST_OWNED_AUTHOR=test-bot

# Clean-verdict lookup finds only another login's clean comment: it is left
# untouched, a new own comment is posted, and it is counted and reported.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_ISSUE_COMMENTS_LIST='[{"id":99,"user":{"login":"github-actions[bot]"},"body":"old clean\n<!-- gokure-pr-review:v1-clean -->"}]'
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153: only a foreign clean comment -> exits 0, POSTs one new own clean comment, never PATCHes the foreign one" \
  "0 1 0 true" "$rc $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG") $(grep -c '^PATCH ' "$PRT_TEST_ISSUE_COMMENT_LOG") $(grep -qF 'Reviewed, no findings' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"
assert_eq "orchestrator #153: only a foreign clean comment -> counted in the log and as a foreign-marked-comments reason naming its login" \
  "true true" "$(grep -qF 'marked comments by another login (live): 1' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qF 'REVIEW_DEGRADED: foreign-marked-comments: 1 comment(s) carry this action'"'"'s clean-verdict or partial-review marker but were posted by github-actions[bot], not the configured bot login test-bot[bot];' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator #153: foreign-marked-comments is a ::warning, no ::error" \
  "true false" "$(grep -q '::warning title=PR review threads degraded::foreign-marked-comments' "$PRT_TEST_STDOUT_FILE" && echo true || echo false) $(grep -q '::error title=' "$PRT_TEST_STDOUT_FILE" && echo true || echo false)"

# Own and foreign clean comments both present: the own one is edited in place,
# the foreign one is still only counted.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_ISSUE_COMMENTS_LIST='[{"id":99,"user":{"login":"github-actions[bot]"},"body":"old clean\n<!-- gokure-pr-review:v1-clean -->"},{"id":88,"user":{"login":"test-bot[bot]"},"body":"own clean\n<!-- gokure-pr-review:v1-clean -->"}]'
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153: own and foreign clean comments -> PATCHes only the own one, POSTs nothing, counts the foreign one" \
  "0 1 0 0 true" "$rc $(grep -c '^PATCH comments/88$' "$PRT_TEST_ISSUE_COMMENT_LOG") $(grep -c '^PATCH comments/99$' "$PRT_TEST_ISSUE_COMMENT_LOG") $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG") $(grep -qF 'foreign-marked-comments: 1 comment(s)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# R3-P2: the same two comments, but enumerating the foreign one fails (jq
# shim on the foreign filter only). The lookup must not succeed with 88
# alone: the clean-verdict lookup reports the listing failure as
# REVIEW_INCOMPLETE (no write), and the foreign count is reported as
# incomplete instead of reading as zero.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
rc="$(
  # Invoked indirectly by the orchestrator; the $s is the literal jq filter text.
  # shellcheck disable=SC2329,SC2016
  jq() { case "$*" in *'contains($s) | not'*) return 5 ;; esac; command jq "$@"; }
  export -f jq
  run_orchestrator enforce 0 0 0
)"
assert_eq "orchestrator #153 (R3-P2): foreign comment enumeration fails -> exits 1, REVIEW_INCOMPLETE names the listing, no comment written" \
  "1 true 0 0" "$rc $(grep -qF 'REVIEW_INCOMPLETE: failed to list issue comments while looking for a prior clean-verdict comment' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -c '^PATCH ' "$PRT_TEST_ISSUE_COMMENT_LOG") $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG")"
assert_eq "orchestrator #153 (R3-P2): the foreign count is reported as incomplete, not as zero" \
  "true true false" "$(grep -qF 'marked comments by another login (live): 0 or more (a listing failed)' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qF 'REVIEW_DEGRADED: foreign-marked-comments-unread:' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qxF 'prt: marked comments by another login (live): 0' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# R4-P2: every listing succeeds, but counting the foreign comments fails. The
# count must be reported as incomplete, never as zero.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
rc="$(
  # Invoked indirectly by the orchestrator.
  # shellcheck disable=SC2329
  awk() { case "$*" in *'seen[$1]++'*) return 5 ;; esac; command awk "$@"; }
  export -f awk
  run_orchestrator enforce 0 0 0
)"
assert_eq "orchestrator #153 (R4-P2): counting the foreign comments fails -> exits 0, count reported as incomplete with the degraded reason, not as zero" \
  "0 true true false" "$rc $(grep -qF 'marked comments by another login (live): 0 or more (a listing failed)' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qF 'REVIEW_DEGRADED: foreign-marked-comments-unread:' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qxF 'prt: marked comments by another login (live): 0' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# R6-P2: the head moves before the clean-verdict lookup, so no lookup runs
# and nothing is listed. A live foreign comment exists; the log must not
# report an exact zero.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_ISSUE_COMMENTS_LIST='[{"id":99,"user":{"login":"github-actions[bot]"},"body":"old clean\n<!-- gokure-pr-review:v1-clean -->"}]'
run_orchestrator enforce 0 0 0 > /dev/null
t153_reads="$(cat "$PRT_TEST_META_COUNTFILE")"
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
# The last three PR reads are the clean lookup's freshness check, its
# pre-write re-check and the partial-review supersede check.
PRT_TEST_STALE_AFTER_CALL=$((t153_reads - 3))
rc="$(run_orchestrator enforce 0 0 0)"
PRT_TEST_STALE_AFTER_CALL=0
assert_eq "orchestrator #153 (R6-P2): head moves before any comment lookup -> exits 0, no write, count reported as not counted, never as zero" \
  "0 0 true false" "$rc $(grep -c '^\(POST\|PATCH\) ' "$PRT_TEST_ISSUE_COMMENT_LOG") $(grep -qF 'marked comments by another login (live): not counted (no comment lookup ran this run)' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qxF 'prt: marked comments by another login (live): 0' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
unset t153_reads

# A foreign comment already superseded reads as stale by its own text: not
# counted, no reason.
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
PRT_TEST_ISSUE_COMMENTS_LIST='[{"id":99,"user":{"login":"github-actions[bot]"},"body":"~~old~~\n<!-- gokure-pr-review:state=superseded -->\n<!-- gokure-pr-review:v1-clean -->"}]'
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator #153: only a superseded foreign clean comment -> not counted, no reason, own comment still POSTed" \
  "0 true false 1" "$rc $(grep -qF 'marked comments by another login (live): 0' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qF 'foreign-marked-comments' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -c '^POST ' "$PRT_TEST_ISSUE_COMMENT_LOG")"

rm -f "$PRT_TEST_ISSUE_COMMENT_LOG"
unset PRT_TEST_ISSUE_COMMENT_LOG PRT_TEST_ISSUE_COMMENTS_LIST
unset -f prt_foreign_writes

# ---- go-kure/.github#156: where the standards document is read from ----
# The run's working directory stands in for the caller's checkout; the
# script's own tree ($ROOT) for the action's. Each case plants a caller file
# carrying a sentinel, so a read from the wrong checkout shows up in the
# system prompt either way. The model log holds both calls' system prompts
# only when the review finds something; the default review finds nothing, so
# there is one (review) call per run here.
PRT_TEST_MODEL_SYSTEM_LOG="$(mktemp)"
prt_std_action_line='# go-kure Org Standards'
prt_std_sentinel='CALLER-STANDARDS-SENTINEL-156'
prt_std_has() { grep -qF -- "$1" "$PRT_TEST_MODEL_SYSTEM_LOG" && echo true || echo false; }

# Default source (action): the caller's same-named file is NOT read.
PRT_TEST_CALLER_FILE=docs/standards.md
PRT_TEST_CALLER_FILE_CONTENT="$prt_std_sentinel"
: > "$PRT_TEST_MODEL_SYSTEM_LOG"
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator #156: default standards source reads the action's docs/standards.md, not the caller's file of the same name" \
  "0 true true false" "$rc $(prt_std_has 'PROJECT STANDARDS:') $(prt_std_has "$prt_std_action_line") $(prt_std_has "$prt_std_sentinel")"

# Explicit action: identical to the default.
PRT_TEST_STANDARDS_SOURCE=action
: > "$PRT_TEST_MODEL_SYSTEM_LOG"
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator #156: standards-source=action reads the action's checkout" \
  "0 true false" "$rc $(prt_std_has "$prt_std_action_line") $(prt_std_has "$prt_std_sentinel")"

# caller: a caller-relative path that does not exist in the action's tree.
PRT_TEST_STANDARDS_SOURCE=caller
PRT_TEST_STANDARDS_FILE=policy/review-rules.md
PRT_TEST_CALLER_FILE=policy/review-rules.md
: > "$PRT_TEST_MODEL_SYSTEM_LOG"
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator #156: standards-source=caller reads the caller's file, and not the action's standards" \
  "0 true true false" "$rc $(prt_std_has 'PROJECT STANDARDS:') $(prt_std_has "$prt_std_sentinel") $(prt_std_has "$prt_std_action_line")"

# caller with the default path: the caller's docs/standards.md, not the action's.
unset PRT_TEST_STANDARDS_FILE
PRT_TEST_CALLER_FILE=docs/standards.md
: > "$PRT_TEST_MODEL_SYSTEM_LOG"
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator #156: standards-source=caller with the default path reads the caller's docs/standards.md" \
  "0 true false" "$rc $(prt_std_has "$prt_std_sentinel") $(prt_std_has "$prt_std_action_line")"

# caller, file missing: no standards at all (never the action's), and logged.
PRT_TEST_STANDARDS_FILE=missing/standards.md
: > "$PRT_TEST_MODEL_SYSTEM_LOG"
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator #156: standards-source=caller with a missing file sends no PROJECT STANDARDS and logs it" \
  "0 false true" "$rc $(prt_std_has 'PROJECT STANDARDS:') $(grep -qF "standards file 'missing/standards.md' not found in the caller checkout" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Empty standards file disables it in caller mode too, even with a file there.
PRT_TEST_STANDARDS_FILE=''
: > "$PRT_TEST_MODEL_SYSTEM_LOG"
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator #156: an empty standards file disables PROJECT STANDARDS under standards-source=caller" \
  "0 false false" "$rc $(prt_std_has 'PROJECT STANDARDS:') $(prt_std_has "$prt_std_sentinel")"
PRT_TEST_STANDARDS_SOURCE=action
: > "$PRT_TEST_MODEL_SYSTEM_LOG"
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator #156: an empty standards file disables PROJECT STANDARDS under standards-source=action" \
  "0 false" "$rc $(prt_std_has 'PROJECT STANDARDS:')"

# An unknown source is a configuration error: exit 1 before any network call.
unset PRT_TEST_STANDARDS_FILE
PRT_TEST_STANDARDS_SOURCE=callr
: > "$PRT_TEST_MODEL_SYSTEM_LOG"
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator #156: an unknown standards source exits 1 naming the value, before the diff fetch or any model call" \
  "1 true 0 0" "$rc $(grep -qF "ERROR: PRT_STANDARDS_SOURCE must be 'action' or 'caller', got 'callr'" "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(cat "$PRT_TEST_DIFF_COUNTFILE") $(cat "$PRT_TEST_MODEL_COUNTFILE")"
# Except in off mode: the incident escape hatch exits 0 before the check.
rc="$(run_orchestrator off 0 0 0)"
assert_eq "orchestrator #156: off mode still exits 0 with an unknown standards source" "0" "$rc"
assert_eq "orchestrator #156: off mode with an unknown standards source posts nothing" \
  "0 0 0 0 0 0" "$(cat "$PRT_TEST_CREATE_COUNTFILE") $(cat "$PRT_TEST_REPLY_COUNTFILE") $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(cat "$PRT_TEST_UNRESOLVE_COUNTFILE") $(cat "$PRT_TEST_PATCH_COUNTFILE") $(cat "$PRT_TEST_ISSUE_COMMENT_COUNTFILE")"

rm -f "$PRT_TEST_MODEL_SYSTEM_LOG"

# go-kure/.github#156: the cases above set PRT_STANDARDS_* directly, so they
# cannot see the wiring in front of the script. Each input must be declared
# by pr-review.yml (workflow_call, with today's default), bound to the job
# env, passed to the action, declared by the action, and bound to the PRT_
# variable the script reads. Exact lines at their indentation, so a line in
# another block cannot stand in for the one checked.
prt_wf="$ROOT/.github/workflows/pr-review.yml"
prt_act="$ROOT/.github/actions/pr-review-threads/action.yml"
prt_has_line() { grep -qxF -- "$2" "$1" && echo true || echo false; }
prt_input_default() { # FILE INDENT NAME -> the input block's default: value
  awk -v hdr="$2$3:" -v ind="${#2}" '
    $0 == hdr { inb = 1; next }
    inb && match($0, /^ */) && RLENGTH <= ind { exit }
    inb && $1 == "default:" { sub(/^ *default: */, ""); print; exit }
  ' "$1"
}
prt_wiring() { # INPUT JOB_ENV PRT_VAR
  # \${{ }} is literal workflow text, not a shell expansion.
  printf '%s %s %s %s %s' \
    "$(prt_input_default "$prt_wf" '      ' "$1")" \
    "$(prt_has_line "$prt_wf" "      $2: \${{ inputs.$1 }}")" \
    "$(prt_has_line "$prt_wf" "          $1: \${{ env.$2 }}")" \
    "$(prt_input_default "$prt_act" '  ' "$1")" \
    "$(prt_has_line "$prt_act" "        $3: \${{ inputs.$1 }}")"
}
assert_eq "wiring #156: standards-file declared by pr-review.yml, bound to its env, passed to the action, declared there and bound to PRT_STANDARDS_FILE" \
  "'docs/standards.md' true true \"docs/standards.md\" true" "$(prt_wiring standards-file PR_REVIEW_STANDARDS_FILE PRT_STANDARDS_FILE)"
assert_eq "wiring #156: standards-source declared by pr-review.yml (default action), bound to its env, passed to the action, declared there and bound to PRT_STANDARDS_SOURCE" \
  "'action' true true \"action\" true" "$(prt_wiring standards-source PR_REVIEW_STANDARDS_SOURCE PRT_STANDARDS_SOURCE)"

# The job checks out the head it attributes its results
# to. Under pull_request the default ref is the temporary merge commit, at
# depth 1; the head step takes the PR head and the full history, so a later
# step can compute a merge base. Exact lines inside the checkout step only.
prt_checkout_step() { # the "Checkout repository" step of pr-review.yml, up to the next step
  awk '
    $0 == "      - name: Checkout repository" { inb = 1; print; next }
    inb && /^      - name: / { exit }
    inb { print }
  ' "$prt_wf"
}
prt_checkout="$(prt_checkout_step)"
# shellcheck disable=SC2016  # ${{ }} is literal workflow text, not a shell expansion
assert_eq "wiring checkout: the checkout step takes the PR head SHA" "true" \
  "$(printf '%s\n' "$prt_checkout" | grep -qxF -- '          ref: ${{ github.event.pull_request.head.sha }}' && echo true || echo false)"
assert_eq "wiring checkout: the checkout step takes the full history" "true" \
  "$(printf '%s\n' "$prt_checkout" | grep -qxF -- '          fetch-depth: 0' && echo true || echo false)"
unset prt_checkout
unset -f prt_checkout_step
unset prt_wf prt_act
unset -f prt_has_line prt_input_default prt_wiring
unset PRT_TEST_MODEL_SYSTEM_LOG PRT_TEST_STANDARDS_SOURCE PRT_TEST_STANDARDS_FILE PRT_TEST_CALLER_FILE PRT_TEST_CALLER_FILE_CONTENT
unset -f prt_std_has

rm -f "$PRT_TEST_DIFF_COUNTFILE" "$PRT_TEST_META_COUNTFILE" "$PRT_TEST_MODEL_COUNTFILE" \
      "$PRT_TEST_ASSESS_COUNTFILE" \
      "$PRT_TEST_GRAPHQL_COUNTFILE" "$PRT_TEST_PATCH_COUNTFILE" "$PRT_TEST_RESOLVE_COUNTFILE" \
      "$PRT_TEST_UNRESOLVE_COUNTFILE" "$PRT_TEST_CREATE_COUNTFILE" "$PRT_TEST_REPLY_COUNTFILE" \
      "$PRT_TEST_ISSUE_COMMENT_COUNTFILE" \
      "$PRT_TEST_STDOUT_FILE" "$PRT_TEST_STDERR_FILE"

# ============================================================ model.sh: oversized payload must not hit argv E2BIG
# Linux caps a SINGLE argv entry at MAX_ARG_STRLEN = 32 pages = 131072 bytes,
# independent of ARG_MAX and of any ulimit. _prt_call_proxy used to pass the
# whole JSON body as `-d "$payload"`, so a large diff chunk made execve fail
# with E2BIG; curl never ran, http_code came back empty, and the failure was
# misreported as "proxy returned HTTP " (go-kure/launcher run 32224453949).
#
# The stub MUST be a real executable on disk, not a shell function: a function
# is called in-process and never execve'd, so a function stub passes even
# against the broken `-d "$payload"` form and would make this test vacuous.
# shellcheck source=/dev/null
source "$LIB/model.sh"

prt_e2big_dir="$(mktemp -d)"
cat > "$prt_e2big_dir/fake-curl" <<'FAKECURL'
#!/usr/bin/env bash
# Minimal curl stand-in: honours -o <file> and prints a status like
# -w '%{http_code}', and records the request body size so the test can prove
# the whole payload survived the trip.
set -uo pipefail
out=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
# -d @FILE: read the body from the file, which is the point of the fix.
case "$body" in
  @*) body="$(cat "${body#@}")" ;;
esac
printf '%s' "${#body}" > "$PRT_TEST_BODYLEN_FILE"
printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[]}"}}]}' > "$out"
printf '200'
FAKECURL
chmod +x "$prt_e2big_dir/fake-curl"

export PRT_TEST_BODYLEN_FILE="$prt_e2big_dir/bodylen"

# 300000 chars: above MAX_ARG_STRLEN (131072) and inside the range diff.sh can
# actually emit — its hard ceiling is PRT_HARD_CEILING_MULT (4) x a 50000 soft
# limit = 200000 for the chunk diff alone, before the system prompt is added.
prt_big_user="$(head -c 300000 /dev/zero | tr '\0' 'x')"
prt_e2big_out="$(PRT_CURL="$prt_e2big_dir/fake-curl" \
  _prt_call_proxy "http://proxy.invalid" "m" 1500 "sys" "$prt_big_user" 2>"$prt_e2big_dir/err")"
prt_e2big_rc=$?

assert_eq "model: 300KB payload does not fail (argv E2BIG regression)" "0" "$prt_e2big_rc"
assert_eq "model: 300KB payload returns the parsed content" '{"findings":[]}' "$prt_e2big_out"
assert_eq "model: 300KB payload emits no stderr diagnostic" "" "$(cat "$prt_e2big_dir/err")"
# The JSON body wraps the 300000-char user string, so it is strictly larger.
assert_eq "model: full body reached curl, not a truncated one" "true" \
  "$([ "$(cat "$PRT_TEST_BODYLEN_FILE")" -gt 300000 ] && echo true || echo false)"

# A curl that cannot run at all must be reported as a local failure, not as a
# proxy response carrying a blank status.
cat > "$prt_e2big_dir/broken-curl" <<'BROKENCURL'
#!/usr/bin/env bash
exit 7
BROKENCURL
chmod +x "$prt_e2big_dir/broken-curl"

prt_brk_err="$(PRT_CURL="$prt_e2big_dir/broken-curl" \
  _prt_call_proxy "http://proxy.invalid" "m" 1500 "sys" "hi" 2>&1 >/dev/null)"
assert_eq "model: curl exec failure names curl, not the proxy" "true" \
  "$(case "$prt_brk_err" in *"curl failed (exit 7"*) echo true ;; *) echo false ;; esac)"
assert_eq "model: curl exec failure does not claim an HTTP status" "true" \
  "$(case "$prt_brk_err" in *"proxy returned HTTP"*) echo false ;; *) echo true ;; esac)"

unset PRT_TEST_BODYLEN_FILE
rm -rf "$prt_e2big_dir"

# ============================================================ model.sh: file review backend (PRT_REVIEW_BACKEND=file)
# The review call can be served from a findings file a separate review step
# already produced, instead of the proxy. The switch sits in prt_model_review,
# one level above _prt_call_proxy (which has no chunk to assign by): it
# returns, per chunk, only the findings that belong to that chunk, and refuses
# an artifact whose provenance record does not match this run. With the
# variable unset nothing changes: the proxy path runs as before.
prt_fb_dir="$(mktemp -d)"
mkdir -p "$prt_fb_dir/chunks" "$prt_fb_dir/art"

# A fake curl on disk that counts its invocations (a function stub would never
# be execve'd; see the E2BIG block above).
cat > "$prt_fb_dir/fake-curl" <<'FAKECURL2'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
printf 'x' >> "$PRT_TEST_CURL_COUNT_FILE"
printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[{\"file\":\"proxy.go\",\"line\":1,\"category\":\"other\",\"severity\":\"High\",\"issue\":\"i\",\"fix\":\"f\"}]}"}}]}' > "$out"
printf '200'
FAKECURL2
chmod +x "$prt_fb_dir/fake-curl"
export PRT_TEST_CURL_COUNT_FILE="$prt_fb_dir/curl-count"

# Two chunks. big.go is split across them (hunk 1 = new lines 1-2 in chunk 0,
# hunk 2 = new lines 50-52 in chunk 1), as diff.sh does for an oversized file.
cat > "$prt_fb_dir/chunks/chunk-000.diff" <<'CHUNK0'
diff --git a/a.go b/a.go
index 1111111..2222222 100644
--- a/a.go
+++ b/a.go
@@ -1,3 +1,4 @@
 package a
+var x = 1
 func f() {}
 func g() {}
diff --git a/big.go b/big.go
index 3333333..4444444 100644
--- a/big.go
+++ b/big.go
@@ -1,2 +1,2 @@
-old
+new
 keep
CHUNK0
cat > "$prt_fb_dir/chunks/chunk-001.diff" <<'CHUNK1'
diff --git a/big.go b/big.go
index 3333333..4444444 100644
--- a/big.go
+++ b/big.go
@@ -50,2 +50,3 @@
 ctx
+added
 ctx2
diff --git a/c.go b/c.go
index 5555555..6666666 100644
--- a/c.go
+++ b/c.go
@@ -1 +1,2 @@
 line
+more
CHUNK1

prt_fb_head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
prt_fb_base="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
prt_fb_mat="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

# Findings, by where they must land:
#   a.go:2   -> chunk 0 (inside its hunk)        big.go:51 -> chunk 1 (inside its second hunk)
#   big.go:1 -> chunk 0 (inside its first hunk)  big.go:30 -> chunk 0 (in no hunk: first chunk holding the file)
#   c.go null -> chunk 1 (file-level, only chunk) ghost.go:3 -> chunk 0 (in no chunk: first chunk, never dropped)
prt_fb_write_findings() {
  cat > "$prt_fb_dir/art/findings.json" <<'FINDINGS'
{"format":"review-findings-v1","findings":[
 {"file":"a.go","line":2,"severity":"high","category":"logic-error","issue":"i1","fix":"f1","klass":"blocking","claim":"c1"},
 {"file":"big.go","line":51,"severity":"high","category":"race","issue":"i2","fix":"f2","klass":"blocking","claim":"c2"},
 {"file":"big.go","line":1,"severity":"low","category":"nil-deref","issue":"i3","fix":"f3","klass":"wording","claim":"c3"},
 {"file":"big.go","line":30,"severity":"low","category":"other","issue":"i4","fix":"f4","klass":"wording","claim":"c4"},
 {"file":"c.go","line":null,"severity":"high","category":"unchecked-err","issue":"i5","fix":"f5","klass":"blocking","claim":"c5"},
 {"file":"ghost.go","line":3,"severity":"low","category":"resource-leak","issue":"i6","fix":"f6","klass":"citation","claim":"c6"}
]}
FINDINGS
}
prt_fb_write_provider() {
  jq -n --arg head "$prt_fb_head" --arg base "$prt_fb_base" --arg mat "$prt_fb_mat" \
    '{format:"review-run-v1", outcome:"completed", backend:"x", identity:{root:"/r", head:$head, base:$base, material_sha256:$mat, input_sha256:"d", add_dirs:[]}}' \
    > "$prt_fb_dir/art/provider.json"
}
prt_fb_write_findings
prt_fb_write_provider

# One chunk's answer, as prt_model_review would print it for chunk IDX.
prt_fb_review() {
  PRT_CHUNK_DIR="$prt_fb_dir/chunks" PRT_FINDINGS_FILE="$prt_fb_dir/art/findings.json" \
    PRT_HEAD_SHA="$prt_fb_head" PRT_REVIEW_BASE_SHA="$prt_fb_base" PRT_REVIEW_MATERIAL_SHA256="$prt_fb_mat" \
    PRT_CURL="$prt_fb_dir/fake-curl" PRT_LAST_MODEL_FAILURE_FILE="$prt_fb_dir/failure" \
    prt_model_review "http://proxy.invalid" "m" 1500 "$(cat "$prt_fb_dir/chunks/chunk-$(printf '%03d' "$1").diff")" \
    "title" "desc" "" "" "" "" "" "$1"
}
prt_fb_keys() { jq -r '.findings | map(.file + ":" + (.line | tostring)) | sort | join(",")' <<< "$1"; }

# 1. Default off: the proxy path runs, through curl, once.
: > "$prt_fb_dir/curl-count"
prt_fb_off_out="$(PRT_CURL="$prt_fb_dir/fake-curl" PRT_LAST_MODEL_FAILURE_FILE="$prt_fb_dir/failure" \
  prt_model_review "http://proxy.invalid" "m" 1500 "diff" "t" "d" "" "" "" "" "" "0")"
assert_eq "file backend: backend unset still calls the proxy once" "1" "$(wc -c < "$prt_fb_dir/curl-count" | tr -d ' ')"
assert_eq "file backend: backend unset returns the proxy's content" "proxy.go:1" "$(prt_fb_keys "$prt_fb_off_out")"

# 2/3. Each chunk gets exactly its own findings; every finding lands once.
: > "$prt_fb_dir/curl-count"
prt_fb_out0="$(PRT_REVIEW_BACKEND="file" prt_fb_review 0)"; prt_fb_rc0=$?
prt_fb_out1="$(PRT_REVIEW_BACKEND="file" prt_fb_review 1)"; prt_fb_rc1=$?
assert_eq "file backend: chunk 0 rc" "0" "$prt_fb_rc0"
assert_eq "file backend: chunk 1 rc" "0" "$prt_fb_rc1"
assert_eq "file backend: chunk 0 holds the findings inside its hunks, the in-file miss and the file in no chunk" \
  "a.go:2,big.go:1,big.go:30,ghost.go:3" "$(prt_fb_keys "$prt_fb_out0")"
assert_eq "file backend: chunk 1 holds big.go's second hunk and the file-level finding of c.go" \
  "big.go:51,c.go:null" "$(prt_fb_keys "$prt_fb_out1")"
assert_eq "file backend: six findings in, six answered across the chunks, none twice" "6" \
  "$(jq -s '[.[].findings[] | .issue] | unique | length' <<< "$prt_fb_out0 $prt_fb_out1")"
assert_eq "file backend: an answered finding keeps the six fields the normalizer reads" "true" \
  "$(jq -s 'all(.[].findings[]; (keys - ["file","line","severity","category","issue","fix"]) == [])' <<< "$prt_fb_out0 $prt_fb_out1")"
assert_eq "file backend: the answer normalizes clean (rc 0)" "0" \
  "$(prt_normalize_findings "$prt_fb_out0" >/dev/null 2>&1; echo $?)"
# 4. The proxy is never reached in file mode.
assert_eq "file backend: curl is never invoked" "0" "$(wc -c < "$prt_fb_dir/curl-count" | tr -d ' ')"

# 4b. A chunk with nothing assigned answers a clean empty review.
jq -c '.findings |= map(select(.file == "a.go"))' "$prt_fb_dir/art/findings.json" > "$prt_fb_dir/art/findings.one"
cp "$prt_fb_dir/art/findings.json" "$prt_fb_dir/art/findings.all"
cp "$prt_fb_dir/art/findings.one" "$prt_fb_dir/art/findings.json"
assert_eq "file backend: a chunk with no findings answers an empty list" '{"findings":[]}' \
  "$(PRT_REVIEW_BACKEND="file" prt_fb_review 1 | jq -c '.')"
cp "$prt_fb_dir/art/findings.all" "$prt_fb_dir/art/findings.json"

# 6. A retry of the same chunk gets the same answer (the orchestrator retries).
assert_eq "file backend: a second call for the same chunk returns the same answer" \
  "$(jq -S -c '.' <<< "$prt_fb_out0")" "$(PRT_REVIEW_BACKEND="file" prt_fb_review 0 | jq -S -c '.')"

# 6b. A file split across chunks is found by its whole path: one with a space
# (git ends the +++ path with a tab) and one git quotes (a `"` in the name).
# The line index used to cut the first at the space and keep the quotes of the
# second, so a finding in the later hunk fell back to the first chunk.
prt_fb_sp_hunk() { # NAME-AS-DIFF-HEADER-PAIR HUNK-HEADER: one file section
  printf '%s\n%s\n' "diff --git $1" "index 1111111..2222222 100644"
  printf '%s\n%s\n' "--- $2" "+++ $3"
  printf '%s\n%s\n%s\n%s\n' "$4" "-old" "+new" " keep"
}
mkdir -p "$prt_fb_dir/chunks-sp"
{
  prt_fb_sp_hunk 'a/sp ace.go b/sp ace.go' 'a/sp ace.go'$'\t' 'b/sp ace.go'$'\t' '@@ -1,2 +1,2 @@'
  prt_fb_sp_hunk '"a/qu\"ote.go" "b/qu\"ote.go"' '"a/qu\"ote.go"' '"b/qu\"ote.go"' '@@ -1,2 +1,2 @@'
} > "$prt_fb_dir/chunks-sp/chunk-000.diff"
{
  prt_fb_sp_hunk 'a/sp ace.go b/sp ace.go' 'a/sp ace.go'$'\t' 'b/sp ace.go'$'\t' '@@ -50,2 +50,2 @@'
  prt_fb_sp_hunk '"a/qu\"ote.go" "b/qu\"ote.go"' '"a/qu\"ote.go"' '"b/qu\"ote.go"' '@@ -50,2 +50,2 @@'
} > "$prt_fb_dir/chunks-sp/chunk-001.diff"
cat > "$prt_fb_dir/art/findings-sp.json" <<'FINDINGS'
{"format":"review-findings-v1","findings":[
 {"file":"sp ace.go","line":1,"severity":"high","category":"other","issue":"s1","fix":"f","klass":"blocking","claim":"c"},
 {"file":"sp ace.go","line":51,"severity":"high","category":"other","issue":"s2","fix":"f","klass":"blocking","claim":"c"},
 {"file":"qu\"ote.go","line":1,"severity":"high","category":"other","issue":"q1","fix":"f","klass":"blocking","claim":"c"},
 {"file":"qu\"ote.go","line":51,"severity":"high","category":"other","issue":"q2","fix":"f","klass":"blocking","claim":"c"}
]}
FINDINGS
prt_fb_review_dir() { # CHUNK_DIR FINDINGS_FILE IDX — like prt_fb_review, other fixtures
  PRT_CHUNK_DIR="$1" PRT_FINDINGS_FILE="$2" \
    PRT_HEAD_SHA="$prt_fb_head" PRT_REVIEW_BASE_SHA="$prt_fb_base" PRT_REVIEW_MATERIAL_SHA256="$prt_fb_mat" \
    PRT_CURL="$prt_fb_dir/fake-curl" PRT_LAST_MODEL_FAILURE_FILE="$prt_fb_dir/failure" \
    PRT_REVIEW_BACKEND="file" prt_model_review "http://proxy.invalid" "m" 1500 "diff" "t" "d" "" "" "" "" "" "$3"
}
prt_fb_sp0="$(prt_fb_review_dir "$prt_fb_dir/chunks-sp" "$prt_fb_dir/art/findings-sp.json" 0)"
prt_fb_sp1="$(prt_fb_review_dir "$prt_fb_dir/chunks-sp" "$prt_fb_dir/art/findings-sp.json" 1)"
assert_eq "file backend: a spaced and a git-quoted path split across chunks, first hunks stay in chunk 0" \
  'qu"ote.go:1,sp ace.go:1' "$(prt_fb_keys "$prt_fb_sp0")"
assert_eq "file backend: a spaced and a git-quoted path split across chunks, second hunks go to chunk 1" \
  'qu"ote.go:51,sp ace.go:51' "$(prt_fb_keys "$prt_fb_sp1")"

# 6c. A chunk whose line index is bigger than one argv entry may be (131072
# bytes on Linux) is still served: nothing large goes through jq's command line.
mkdir -p "$prt_fb_dir/chunks-big"
{
  printf '%s\n' 'diff --git a/huge.txt b/huge.txt' 'index 1111111..2222222 100644' '--- a/huge.txt' '+++ b/huge.txt' '@@ -0,0 +1,30000 @@'
  seq 30000 | sed 's/^/+/'
} > "$prt_fb_dir/chunks-big/chunk-000.diff"
cat > "$prt_fb_dir/art/findings-big.json" <<'FINDINGS'
{"format":"review-findings-v1","findings":[
 {"file":"huge.txt","line":29999,"severity":"high","category":"other","issue":"h1","fix":"f","klass":"blocking","claim":"c"}
]}
FINDINGS
prt_fb_big="$(prt_fb_review_dir "$prt_fb_dir/chunks-big" "$prt_fb_dir/art/findings-big.json" 0)"; prt_fb_big_rc=$?
assert_eq "file backend: a line index larger than one argv entry is served (rc)" "0" "$prt_fb_big_rc"
assert_eq "file backend: a line index larger than one argv entry is served (finding)" "huge.txt:29999" "$(prt_fb_keys "$prt_fb_big")"
rm -rf "$prt_fb_dir/chunks-sp" "$prt_fb_dir/chunks-big" "$prt_fb_dir/art/findings-sp.json" "$prt_fb_dir/art/findings-big.json"
unset prt_fb_sp0 prt_fb_sp1 prt_fb_big prt_fb_big_rc
unset -f prt_fb_sp_hunk prt_fb_review_dir

# 5. Refusals: rc 1 and a closed-vocabulary reason, never a guess.
prt_fb_refuse() { # DESC REASON  (the artifact has been broken by the caller)
  local desc="$1" reason="$2" rc
  : > "$prt_fb_dir/failure"
  PRT_REVIEW_BACKEND="file" prt_fb_review 0 >/dev/null 2>&1; rc=$?
  assert_eq "file backend refusal: $desc: rc" "1" "$rc"
  assert_eq "file backend refusal: $desc: reason" "$reason" "$(cat "$prt_fb_dir/failure")"
}
prt_fb_restore() { cp "$prt_fb_dir/art/findings.all" "$prt_fb_dir/art/findings.json"; prt_fb_write_provider; }

rm -f "$prt_fb_dir/art/findings.json"
prt_fb_refuse "findings file missing" "findings-file-missing"
prt_fb_restore
printf 'not json' > "$prt_fb_dir/art/findings.json"
prt_fb_refuse "findings file is not JSON" "findings-file-malformed"
prt_fb_restore
jq -c '.findings = "x"' "$prt_fb_dir/art/findings.all" > "$prt_fb_dir/art/findings.json"
prt_fb_refuse "findings is not an array" "findings-file-malformed"
prt_fb_restore
jq -c '.format = "other"' "$prt_fb_dir/art/findings.all" > "$prt_fb_dir/art/findings.json"
prt_fb_refuse "findings format is not review-findings-v1" "findings-file-malformed"
prt_fb_restore
jq -c '.findings[0] |= del(.file)' "$prt_fb_dir/art/findings.all" > "$prt_fb_dir/art/findings.json"
prt_fb_refuse "a finding without a file" "findings-file-malformed"
prt_fb_restore
# Every field the normalizer needs is checked before any chunk is served: a row the normalizer
# would drop must refuse the run, not vanish while another chunk's empty answer reads as success.
jq -c '.findings[0] = {file:"a.go", line:2}' "$prt_fb_dir/art/findings.all" > "$prt_fb_dir/art/findings.json"
prt_fb_refuse "a finding with only a file and a line" "findings-file-malformed"
prt_fb_restore
for prt_fb_field in severity category issue fix; do
  jq -c --arg k "$prt_fb_field" '.findings[0] |= del(.[$k])' "$prt_fb_dir/art/findings.all" > "$prt_fb_dir/art/findings.json"
  prt_fb_refuse "a finding without $prt_fb_field" "findings-file-malformed"
  prt_fb_restore
  jq -c --arg k "$prt_fb_field" '.findings[0][$k] = 5' "$prt_fb_dir/art/findings.all" > "$prt_fb_dir/art/findings.json"
  prt_fb_refuse "a finding whose $prt_fb_field is a number" "findings-file-malformed"
  prt_fb_restore
done
unset prt_fb_field
jq -c '.findings[0].file = ("a" * 4097)' "$prt_fb_dir/art/findings.all" > "$prt_fb_dir/art/findings.json"
prt_fb_refuse "a finding whose file name is longer than 4096 bytes" "findings-file-malformed"
prt_fb_restore
rm -f "$prt_fb_dir/art/provider.json"
prt_fb_refuse "provenance record missing" "provenance-mismatch"
prt_fb_restore
printf '{bad' > "$prt_fb_dir/art/provider.json"
prt_fb_refuse "provenance record is not JSON" "provenance-mismatch"
prt_fb_restore
jq -c '.identity.head = "dddddddddddddddddddddddddddddddddddddddd"' "$prt_fb_dir/art/provider.json" > "$prt_fb_dir/art/p.tmp" && mv "$prt_fb_dir/art/p.tmp" "$prt_fb_dir/art/provider.json"
prt_fb_refuse "stale head" "provenance-mismatch"
prt_fb_restore
jq -c '.identity.base = "dddddddddddddddddddddddddddddddddddddddd"' "$prt_fb_dir/art/provider.json" > "$prt_fb_dir/art/p.tmp" && mv "$prt_fb_dir/art/p.tmp" "$prt_fb_dir/art/provider.json"
prt_fb_refuse "different base" "provenance-mismatch"
prt_fb_restore
jq -c '.identity.material_sha256 = "e"' "$prt_fb_dir/art/provider.json" > "$prt_fb_dir/art/p.tmp" && mv "$prt_fb_dir/art/p.tmp" "$prt_fb_dir/art/provider.json"
prt_fb_refuse "different material digest" "provenance-mismatch"
prt_fb_restore
jq -c '.identity.material_sha256 = null' "$prt_fb_dir/art/provider.json" > "$prt_fb_dir/art/p.tmp" && mv "$prt_fb_dir/art/p.tmp" "$prt_fb_dir/art/provider.json"
prt_fb_refuse "no material digest recorded" "provenance-mismatch"
prt_fb_restore
jq -c '.outcome = "incomplete"' "$prt_fb_dir/art/provider.json" > "$prt_fb_dir/art/p.tmp" && mv "$prt_fb_dir/art/p.tmp" "$prt_fb_dir/art/provider.json"
prt_fb_refuse "review did not complete" "provenance-mismatch"
prt_fb_restore
jq -c '.format = "review-run-v0"' "$prt_fb_dir/art/provider.json" > "$prt_fb_dir/art/p.tmp" && mv "$prt_fb_dir/art/p.tmp" "$prt_fb_dir/art/provider.json"
prt_fb_refuse "unknown provenance format" "provenance-mismatch"
prt_fb_restore

# Misconfiguration fails closed too, and says so.
: > "$prt_fb_dir/failure"
PRT_REVIEW_BACKEND=carrier-pigeon prt_fb_review 0 >/dev/null 2>&1; prt_fb_rc=$?
assert_eq "file backend: an unknown backend value is refused (rc)" "1" "$prt_fb_rc"
assert_eq "file backend: an unknown backend value is refused (reason)" "backend-config" "$(cat "$prt_fb_dir/failure")"
: > "$prt_fb_dir/failure"
PRT_REVIEW_BACKEND="file" PRT_CHUNK_DIR="$prt_fb_dir/chunks" PRT_FINDINGS_FILE="" PRT_HEAD_SHA="$prt_fb_head" \
  PRT_LAST_MODEL_FAILURE_FILE="$prt_fb_dir/failure" prt_model_review "http://proxy.invalid" "m" 1500 "d" "t" "d" "" "" "" "" "" "0" >/dev/null 2>&1; prt_fb_rc=$?
assert_eq "file backend: file mode without a findings path is refused (rc)" "1" "$prt_fb_rc"
assert_eq "file backend: file mode without a findings path is refused (reason)" "backend-config" "$(cat "$prt_fb_dir/failure")"
: > "$prt_fb_dir/failure"
PRT_REVIEW_BACKEND="file" prt_fb_review "" >/dev/null 2>&1; prt_fb_rc=$?
assert_eq "file backend: file mode without a chunk index is refused (rc)" "1" "$prt_fb_rc"

unset PRT_TEST_CURL_COUNT_FILE
rm -rf "$prt_fb_dir"

# The orchestrator's own wiring: it must set PRT_CHUNK_DIR and hand each review
# call its chunk index, or file mode refuses every chunk. Two files, two chunks
# (the same fixture as the two-chunk cases above); one finding per file.
prt_fo_dir="$(mktemp -d)"
cat > "$prt_fo_dir/findings.json" <<'FOFINDINGS'
{"format":"review-findings-v1","findings":[
 {"file":"x.go","line":1,"severity":"high","category":"logic-error","issue":"issue-for-x","fix":"fix-x","klass":"blocking","claim":"cx"},
 {"file":"y.go","line":1,"severity":"high","category":"race","issue":"issue-for-y","fix":"fix-y","klass":"blocking","claim":"cy"}
]}
FOFINDINGS
jq -n '{format:"review-run-v1", outcome:"completed", backend:"x", identity:{root:"/r", head:"1111111111111111111111111111111111111111", base:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", material_sha256:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", input_sha256:"d", add_dirs:[]}}' \
  > "$prt_fo_dir/provider.json"
PRT_TEST_REVIEW_BACKEND="file"
PRT_TEST_FINDINGS_FILE="$prt_fo_dir/findings.json"
PRT_TEST_REVIEW_BASE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PRT_TEST_REVIEW_MATERIAL_SHA256="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PRT_TEST_TWO_FILE_DIFF=1
PRT_TEST_CREATE_BODY_LOG="$(mktemp)"
rc="$(run_orchestrator enforce 0 0 0 150)"
assert_eq "file backend, orchestrator: two chunks served from the findings file -> exits 0" "0" "$rc"
assert_eq "file backend, orchestrator: no proxy review call was made" "0" "$(cat "$PRT_TEST_MODEL_COUNTFILE")"
assert_eq "file backend, orchestrator: no chunk refused (no REVIEW_INCOMPLETE, no REVIEW_DEGRADED)" \
  "false false" "$(grep -qF 'REVIEW_INCOMPLETE:' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qF 'REVIEW_DEGRADED:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "file backend, orchestrator: each chunk's own finding became a thread (one for x.go, one for y.go)" \
  "true true" "$(grep -qF 'issue-for-x' "$PRT_TEST_CREATE_BODY_LOG" && echo true || echo false) $(grep -qF 'issue-for-y' "$PRT_TEST_CREATE_BODY_LOG" && echo true || echo false)"
# A malformed row must not vanish behind an empty second chunk: the file holds one row naming
# only a file and a line (the normalizer would drop it) and nothing for the second chunk, which
# then answers an empty review. Both chunks refuse, so the run fails closed.
cp "$prt_fo_dir/findings.json" "$prt_fo_dir/findings.good"
printf '%s' '{"format":"review-findings-v1","findings":[{"file":"x.go","line":1}]}' > "$prt_fo_dir/findings.json"
rc="$(run_orchestrator enforce 0 0 0 150)"
assert_eq "file backend, orchestrator: a malformed row plus an empty second chunk fails closed -> exits 1" "1" "$rc"
assert_eq "file backend, orchestrator: the refusal names findings-file-malformed" \
  "true" "$(grep -qF 'findings-file-malformed' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "file backend, orchestrator: it is not read as a degraded review" \
  "false" "$(grep -qF 'REVIEW_DEGRADED:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
cp "$prt_fo_dir/findings.good" "$prt_fo_dir/findings.json"
# A record for another run refuses every chunk, and the refusal is the reason, not a proxy error.
jq '.identity.head ="9999999999999999999999999999999999999999"' "$prt_fo_dir/provider.json" > "$prt_fo_dir/provider.tmp" && mv "$prt_fo_dir/provider.tmp" "$prt_fo_dir/provider.json"
rc="$(run_orchestrator enforce 0 0 0 150)"
assert_eq "file backend, orchestrator: a record for another head fails closed -> exits 1" "1" "$rc"
assert_eq "file backend, orchestrator: the refusal names provenance-mismatch" \
  "true" "$(grep -qF 'provenance-mismatch' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
unset PRT_TEST_REVIEW_BACKEND PRT_TEST_FINDINGS_FILE PRT_TEST_REVIEW_BASE_SHA PRT_TEST_REVIEW_MATERIAL_SHA256 PRT_TEST_CREATE_BODY_LOG
PRT_TEST_TWO_FILE_DIFF=0
rm -rf "$prt_fo_dir"

# A findings file whose findings together exceed the kernel's single-argument
# limit (131072 bytes) must reach the report intact. 6 findings of ~24 KiB
# each are ~144 KiB: before findings travelled over stdin the accumulator
# append failed with "Argument list too long", the accumulator emptied, and
# the run read as a clean review of the chunk.
prt_fo_dir="$(mktemp -d)"
jq -n '{format:"review-findings-v1", findings:[range(0;6) | {file:"x.go", line:1, severity:"high", category:"logic-error", issue:("many-findings-" + tostring + " " + ("y" * 24000)), fix:"fix", klass:"blocking", claim:("c" + tostring)}]}' \
  > "$prt_fo_dir/findings.json"
jq -n '{format:"review-run-v1", outcome:"completed", backend:"x", identity:{root:"/r", head:"1111111111111111111111111111111111111111", base:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", material_sha256:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", input_sha256:"d", add_dirs:[]}}' \
  > "$prt_fo_dir/provider.json"
PRT_TEST_REVIEW_BACKEND="file"
PRT_TEST_FINDINGS_FILE="$prt_fo_dir/findings.json"
PRT_TEST_REVIEW_BASE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PRT_TEST_REVIEW_MATERIAL_SHA256="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PRT_TEST_CREATE_BODY_LOG="$(mktemp)"
PRT_TEST_ISSUE_COMMENT_BODY_FILE="$(mktemp)"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "file backend, orchestrator: 6 findings over the argv limit still finish the run -> exits 0" "0" "$rc"
assert_eq "file backend, orchestrator: all 6 findings reach the report (none lost to an oversized argument)" \
  "true" "$(grep -qF 'done: findings=6 ' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "file backend, orchestrator: the chunk is logged with all 6 findings" \
  "true" "$(grep -qF 'review ok (6 findings)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# The delivered payloads, not just the run's own log, must carry every finding:
# five become threads, the sixth is in the overflow comment. A zero-length or
# truncated payload (the mock now refuses those) cannot satisfy this.
assert_eq "file backend, orchestrator: every one of the 6 findings is in a delivered comment payload" \
  "6" "$(cat "$PRT_TEST_CREATE_BODY_LOG" "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" | grep -o 'many-findings-[0-9]' | sort -u | wc -l | tr -d ' ')"
assert_eq "file backend, orchestrator: the delivered payloads hold all the finding text (>= 6 x 24000 bytes)" \
  "true" "$([ "$(cat "$PRT_TEST_CREATE_BODY_LOG" "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" | wc -c)" -ge 144000 ] && echo true || echo false)"
assert_eq "file backend, orchestrator: the mock refused no comment payload" \
  "false" "$(grep -qF 'mock: rejected' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
rm -f "$PRT_TEST_CREATE_BODY_LOG" "$PRT_TEST_ISSUE_COMMENT_BODY_FILE"
unset PRT_TEST_CREATE_BODY_LOG PRT_TEST_ISSUE_COMMENT_BODY_FILE
unset PRT_TEST_REVIEW_BACKEND PRT_TEST_FINDINGS_FILE PRT_TEST_REVIEW_BASE_SHA PRT_TEST_REVIEW_MATERIAL_SHA256
rm -rf "$prt_fo_dir"
# (end of the many-findings case)

# A comment body of multi-byte characters can pass the kernel's 128 KiB limit
# on one argument while staying under GitHub's 65,536-character cap: 50,000
# three-byte characters are 150,000 bytes. Such a body must reach the thread
# intact, not be lost to a payload that failed to build.
prt_fo_dir="$(mktemp -d)"
jq -n '{format:"review-findings-v1", findings:[{file:"x.go", line:1, severity:"high", category:"logic-error", issue:("multibyte-marker " + ("漢" * 50000)), fix:"fix", klass:"blocking", claim:"cm"}]}' \
  > "$prt_fo_dir/findings.json"
jq -n '{format:"review-run-v1", outcome:"completed", backend:"x", identity:{root:"/r", head:"1111111111111111111111111111111111111111", base:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", material_sha256:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", input_sha256:"d", add_dirs:[]}}' \
  > "$prt_fo_dir/provider.json"
PRT_TEST_REVIEW_BACKEND="file"
PRT_TEST_FINDINGS_FILE="$prt_fo_dir/findings.json"
PRT_TEST_REVIEW_BASE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PRT_TEST_REVIEW_MATERIAL_SHA256="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PRT_TEST_CREATE_BODY_LOG="$(mktemp)"
# The curl stand-in MUST be an executable on disk (see the model.sh E2BIG case below): a
# shell function is never execve'd, so it would accept a payload restored to argv (`-d "$payload"`)
# and make this case vacuous. The wrapper hands the request to the exported mock function.
cat > "$prt_fo_dir/curl" <<'EXECCURL'
#!/usr/bin/env bash
fake_curl_orchestrator "$@"
EXECCURL
chmod +x "$prt_fo_dir/curl"
PRT_TEST_CURL="$prt_fo_dir/curl"
rc="$(run_orchestrator enforce 0 0 0)"
unset PRT_TEST_CURL
assert_eq "multi-byte body over the argv limit: the run exits 0" "0" "$rc"
assert_eq "multi-byte body over the argv limit: no request failed to exec" \
  "false" "$(grep -qiE 'argument list too long|cannot execute' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "multi-byte body over the argv limit: the thread payload carries the finding" \
  "true" "$(grep -qF 'multibyte-marker' "$PRT_TEST_CREATE_BODY_LOG" && echo true || echo false)"
assert_eq "multi-byte body over the argv limit: all 50,000 characters are delivered" \
  "true" "$([ "$(LC_ALL=C.UTF-8 wc -m < "$PRT_TEST_CREATE_BODY_LOG")" -ge 50000 ] && echo true || echo false)"
assert_eq "multi-byte body over the argv limit: the mock refused no comment payload" \
  "false" "$(grep -qF 'mock: rejected' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
rm -f "$PRT_TEST_CREATE_BODY_LOG"
unset PRT_TEST_CREATE_BODY_LOG PRT_TEST_REVIEW_BACKEND PRT_TEST_FINDINGS_FILE PRT_TEST_REVIEW_BASE_SHA PRT_TEST_REVIEW_MATERIAL_SHA256
rm -rf "$prt_fo_dir"
# (end of the multi-byte body case)

# A local failure while joining the verdicts must fail the run closed: the
# findings are not reported as an unverdicted success, REVIEW_INCOMPLETE is
# raised and no full-coverage line is logged. The failure is injected by a jq
# on PATH that fails for the join's duplicate-fp program only.
prt_fo_dir="$(mktemp -d)"
cat > "$prt_fo_dir/findings.json" <<'FOFINDINGS'
{"format":"review-findings-v1","findings":[
 {"file":"x.go","line":1,"severity":"high","category":"logic-error","issue":"issue-for-x","fix":"fix-x","klass":"blocking","claim":"cx"}
]}
FOFINDINGS
jq -n '{format:"review-run-v1", outcome:"completed", backend:"x", identity:{root:"/r", head:"1111111111111111111111111111111111111111", base:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", material_sha256:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", input_sha256:"d", add_dirs:[]}}' \
  > "$prt_fo_dir/provider.json"
mkdir "$prt_fo_dir/bin"
prt_fo_real_jq="$(command -v jq)"
printf '%s\n' '#!/bin/bash' \
  "case \"\$*\" in *'group_by(.fp)'*) exit 5 ;; esac" \
  "exec \"$prt_fo_real_jq\" \"\$@\"" > "$prt_fo_dir/bin/jq"
chmod +x "$prt_fo_dir/bin/jq"
PRT_TEST_REVIEW_BACKEND="file"
PRT_TEST_FINDINGS_FILE="$prt_fo_dir/findings.json"
PRT_TEST_REVIEW_BASE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PRT_TEST_REVIEW_MATERIAL_SHA256="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
rc="$(PATH="$prt_fo_dir/bin:$PATH" run_orchestrator enforce 0 0 0)"
assert_eq "join fault injected: the run fails closed -> exits 1" "1" "$rc"
assert_eq "join fault injected: the failing step is the join's verdict check" \
  "true" "$(grep -qF 'prt_join_assessment: local fault checking the verdicts' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "join fault injected: REVIEW_INCOMPLETE is raised" \
  "true" "$(grep -qF 'REVIEW_INCOMPLETE:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "join fault injected: no full-coverage line is logged" \
  "false" "$(grep -qF 'coverage:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
unset PRT_TEST_REVIEW_BACKEND PRT_TEST_FINDINGS_FILE PRT_TEST_REVIEW_BASE_SHA PRT_TEST_REVIEW_MATERIAL_SHA256
rm -rf "$prt_fo_dir"
# (end of the join fault case)

# A finding the file-backend review assigned to one chunk can rest on code in
# another chunk (here x.go's caller is in y.go). The assessor sees only its own
# chunk, so it cannot verify such a finding and must not refute it: the
# finding stays open and unverdicted. A FALSE_POSITIVE that says it depends on
# code outside the chunk would otherwise suppress the thread of a finding
# nobody checked (or resolve the thread it already has).
prt_fo_dir="$(mktemp -d)"
cat > "$prt_fo_dir/findings.json" <<'FOFINDINGS'
{"format":"review-findings-v1","findings":[
 {"file":"x.go","line":1,"severity":"high","category":"logic-error","issue":"issue-for-x","fix":"fix-x","klass":"blocking","claim":"cx"},
 {"file":"y.go","line":1,"severity":"high","category":"race","issue":"issue-for-y","fix":"fix-y","klass":"blocking","claim":"cy"}
]}
FOFINDINGS
jq -n '{format:"review-run-v1", outcome:"completed", backend:"x", identity:{root:"/r", head:"1111111111111111111111111111111111111111", base:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", material_sha256:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", input_sha256:"d", add_dirs:[]}}' \
  > "$prt_fo_dir/provider.json"
PRT_TEST_REVIEW_BACKEND="file"
PRT_TEST_FINDINGS_FILE="$prt_fo_dir/findings.json"
PRT_TEST_REVIEW_BASE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PRT_TEST_REVIEW_MATERIAL_SHA256="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PRT_TEST_TWO_FILE_DIFF=1
PRT_TEST_ASSESS_RESPONSE_MODE=cross_chunk_fp
PRT_TEST_CREATE_BODY_LOG="$(mktemp)"
rc="$(run_orchestrator enforce 0 0 0 150)"
assert_eq "cross-chunk assessment: the run exits 0" "0" "$rc"
assert_eq "cross-chunk assessment: both chunks were assessed" "2" "$(cat "$PRT_TEST_ASSESS_COUNTFILE")"
assert_eq "cross-chunk assessment: a FALSE_POSITIVE that depends on code outside the chunk does not suppress the finding" \
  "true true" "$(grep -qF 'issue-for-x' "$PRT_TEST_CREATE_BODY_LOG" && echo true || echo false) $(grep -qF 'issue-for-y' "$PRT_TEST_CREATE_BODY_LOG" && echo true || echo false)"
PRT_TEST_ASSESS_RESPONSE_MODE=clean
PRT_TEST_TWO_FILE_DIFF=0
unset PRT_TEST_REVIEW_BACKEND PRT_TEST_FINDINGS_FILE PRT_TEST_REVIEW_BASE_SHA PRT_TEST_REVIEW_MATERIAL_SHA256 PRT_TEST_CREATE_BODY_LOG
rm -rf "$prt_fo_dir"
# (end of the cross-chunk assessment case)

# ============================================================ assessment switch (PRT_ASSESS_ENABLED)
# Off is an opt-in for the advisory pilot: the review runs from a findings file
# and nothing else needs the proxy. Default on, so nothing changes for a caller
# that never sets it. Enforce keeps assessment, and a value that is neither
# true nor false is refused, never read as the default.
prt_as_dir="$(mktemp -d)"
cat > "$prt_as_dir/findings.json" <<'ASFINDINGS'
{"format":"review-findings-v1","findings":[
 {"file":"x.go","line":1,"severity":"high","category":"logic-error","issue":"issue-for-x","fix":"fix-x","klass":"blocking","claim":"cx"},
 {"file":"y.go","line":1,"severity":"high","category":"race","issue":"issue-for-y","fix":"fix-y","klass":"blocking","claim":"cy"}
]}
ASFINDINGS
jq -n '{format:"review-run-v1", outcome:"completed", backend:"x", identity:{root:"/r", head:"1111111111111111111111111111111111111111", base:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", material_sha256:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", input_sha256:"d", add_dirs:[]}}' \
  > "$prt_as_dir/provider.json"
PRT_TEST_REVIEW_BACKEND="file"
PRT_TEST_FINDINGS_FILE="$prt_as_dir/findings.json"
PRT_TEST_REVIEW_BASE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PRT_TEST_REVIEW_MATERIAL_SHA256="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PRT_TEST_TWO_FILE_DIFF=1
PRT_TEST_SUMMARY_COPY="$(mktemp)"

# File review, assessment off, no proxy at all: runs, makes no model call of any kind.
PRT_TEST_ASSESS_ENABLED="false"
PRT_TEST_PROXY_URL=""
rc="$(run_orchestrator advisory 0 0 0 150)"
assert_eq "assess off, file backend, no proxy URL: exits 0" "0" "$rc"
assert_eq "assess off: no review call and no assess call was made" \
  "0 0" "$(cat "$PRT_TEST_MODEL_COUNTFILE") $(cat "$PRT_TEST_ASSESS_COUNTFILE")"
assert_eq "assess off: the coverage line says the chunks were not assessed" \
  "true" "$(grep -qE 'coverage: 2/2 chunks review ok, not assessed' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "assess off: the coverage line never claims 'review+assess ok'" \
  "false" "$(grep -qF 'review+assess ok' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "assess off: no chunk reported as failed (no REVIEW_INCOMPLETE, no REVIEW_DEGRADED)" \
  "false false" "$(grep -qF 'REVIEW_INCOMPLETE:' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qF 'REVIEW_DEGRADED:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "assess off: both findings are still reported, each with verdict n/a" \
  "true true" "$(grep -qE '\| x\.go \| 1 \| n/a \|' "$PRT_TEST_SUMMARY_COPY" && echo true || echo false) $(grep -qE '\| y\.go \| 1 \| n/a \|' "$PRT_TEST_SUMMARY_COPY" && echo true || echo false)"

# Assessment on (unset or true) with no proxy: still refused, the proxy is needed for it.
for prt_as_val in "" "true"; do
  PRT_TEST_ASSESS_ENABLED="$prt_as_val"
  rc="$(run_orchestrator advisory 0 0 0 150)"
  assert_eq "assess '${prt_as_val:-unset}', file backend, no proxy URL: fails closed" "1" "$rc"
  assert_eq "assess '${prt_as_val:-unset}', no proxy URL: the error names PRT_PROXY_URL" \
    "true" "$(grep -qF 'PRT_PROXY_URL is required' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
done

# Assessment off but the review still goes to the proxy: the proxy is still required.
PRT_TEST_ASSESS_ENABLED="false"
PRT_TEST_REVIEW_BACKEND=""
rc="$(run_orchestrator advisory 0 0 0 150)"
assert_eq "assess off, proxy review backend, no proxy URL: fails closed" "1" "$rc"
assert_eq "assess off, proxy review backend, no proxy URL: the error names PRT_PROXY_URL" \
  "true" "$(grep -qF 'PRT_PROXY_URL is required' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Assessment off with the proxy review: the review is served, assess is never called.
PRT_TEST_PROXY_URL="http://proxy.invalid"
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
PRT_TEST_ISSUE_COMMENT_BODY_FILE="$(mktemp)"
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "assess off, proxy review backend: exits 0" "0" "$rc"
assert_eq "assess off, proxy review backend: review called, assess never (the review returned a finding)" \
  "true 0" "$([ "$(cat "$PRT_TEST_MODEL_COUNTFILE")" -ge 1 ] && echo true || echo false) $(cat "$PRT_TEST_ASSESS_COUNTFILE")"
# The posted advisory comment is the surface a reader sees: it must say the
# findings were not assessed, not only the job summary and the log.
assert_eq "assess off: the posted advisory comment discloses that assessment was off, above a non-empty table" \
  "true true" "$(grep -qF 'Assessment was switched off for this run' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false) $(grep -qF '| Severity | Category | File | Line | Issue | Fix |' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
PRT_TEST_ASSESS_ENABLED=""
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "assess unset, same review: the assess call is made (the switch is what skips it)" \
  "1" "$(cat "$PRT_TEST_ASSESS_COUNTFILE")"
# The negative check below only means something if a comment was posted: the
# harness empties the capture before each run, so an aborted run leaves it empty.
assert_eq "assess unset, same review: the run exits 0 and a comment was posted (capture holds its heading)" \
  "0 true" "$rc $(grep -qF '## AI Code Review (advisory mode' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
assert_eq "assess unset, same review: the posted comment carries no not-assessed notice" \
  "false" "$(grep -qF 'Assessment was switched off' "$PRT_TEST_ISSUE_COMMENT_BODY_FILE" && echo true || echo false)"
rm -f "$PRT_TEST_ISSUE_COMMENT_BODY_FILE"
unset PRT_TEST_ISSUE_COMMENT_BODY_FILE
PRT_TEST_MODEL_RESPONSE_MODE=clean
PRT_TEST_ASSESS_ENABLED="false"
PRT_TEST_REVIEW_BACKEND="file"
PRT_TEST_PROXY_URL=""

# Enforce keeps assessment: turning it off there is refused, with the reason.
PRT_TEST_ASSESS_ENABLED="false"
rc="$(run_orchestrator enforce 0 0 0 150)"
assert_eq "assess off in enforce mode: fails closed" "1" "$rc"
assert_eq "assess off in enforce mode: the error says enforce keeps assessment" \
  "true" "$(grep -qF 'PRT_ASSESS_ENABLED=false is not allowed in enforce mode' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# A value that is neither true nor false is refused, not read as the default.
PRT_TEST_ASSESS_ENABLED="maybe"
PRT_TEST_PROXY_URL="http://proxy.invalid"
rc="$(run_orchestrator advisory 0 0 0 150)"
assert_eq "assess 'maybe': fails closed" "1" "$rc"
assert_eq "assess 'maybe': the error names PRT_ASSESS_ENABLED" \
  "true" "$(grep -qF 'PRT_ASSESS_ENABLED must be true or false' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# PRT_MODE=off stays the escape hatch: a misconfigured switch does not stop it.
rc="$(run_orchestrator off 0 0 0 150)"
assert_eq "mode off with assess 'maybe': still exits 0 (off short-circuits before the switch is validated)" "0" "$rc"
assert_eq "mode off with assess 'maybe': no switch error was printed" \
  "false" "$(grep -qF 'PRT_ASSESS_ENABLED must be true or false' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "mode off with assess 'maybe': posts nothing (no create, reply, resolve, unresolve, patch or issue comment)" \
  "0 0 0 0 0 0" "$(cat "$PRT_TEST_CREATE_COUNTFILE") $(cat "$PRT_TEST_REPLY_COUNTFILE") $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(cat "$PRT_TEST_UNRESOLVE_COUNTFILE") $(cat "$PRT_TEST_PATCH_COUNTFILE") $(cat "$PRT_TEST_ISSUE_COMMENT_COUNTFILE")"
# The same with no proxy URL at all (a findings-file caller): off must not ask for it either.
PRT_TEST_PROXY_URL=""
rc="$(run_orchestrator off 0 0 0 150)"
assert_eq "mode off, file backend, assess 'maybe', no proxy URL: still exits 0" "0" "$rc"
assert_eq "mode off, file backend, assess 'maybe', no proxy URL: no PRT_PROXY_URL error" \
  "false" "$(grep -qF 'PRT_PROXY_URL is required' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "mode off, file backend, assess 'maybe', no proxy URL: posts nothing (no create, reply, resolve, unresolve, patch or issue comment)" \
  "0 0 0 0 0 0" "$(cat "$PRT_TEST_CREATE_COUNTFILE") $(cat "$PRT_TEST_REPLY_COUNTFILE") $(cat "$PRT_TEST_RESOLVE_COUNTFILE") $(cat "$PRT_TEST_UNRESOLVE_COUNTFILE") $(cat "$PRT_TEST_PATCH_COUNTFILE") $(cat "$PRT_TEST_ISSUE_COMMENT_COUNTFILE")"
PRT_TEST_PROXY_URL="http://proxy.invalid"

# The rendered advisory comment itself: the notice shows with findings and with none.
adv_as_rows="$(prt_render_advisory_comment '[{"severity":"High","category":"other","file":"x.go","line":7,"issue":"i","fix":"f"}]' "" "" "[]" true)"
assert_eq "prt_render_advisory_comment: assess-skipped flag puts the notice above the table" \
  "true" "$(awk '/Assessment was switched off/ {n=NR} /\| Severity \|/ {t=NR} END {print (n && t && n < t) ? "true" : "false"}' <<< "$adv_as_rows")"
adv_as_zero="$(prt_render_advisory_comment '[]' "" "" "[]" true)"
assert_eq "prt_render_advisory_comment: assess-skipped flag shows the notice even with no findings" \
  "true" "$(grep -qF 'Assessment was switched off for this run' <<< "$adv_as_zero" && echo true || echo false)"
adv_as_default="$(prt_render_advisory_comment '[{"severity":"High","category":"other","file":"x.go","line":7,"issue":"i","fix":"f"}]')"
assert_eq "prt_render_advisory_comment: without the flag there is no notice" \
  "false" "$(grep -qF 'Assessment was switched off' <<< "$adv_as_default" && echo true || echo false)"

unset PRT_TEST_REVIEW_BACKEND PRT_TEST_FINDINGS_FILE PRT_TEST_REVIEW_BASE_SHA PRT_TEST_REVIEW_MATERIAL_SHA256 PRT_TEST_ASSESS_ENABLED PRT_TEST_PROXY_URL
rm -f "$PRT_TEST_SUMMARY_COPY"
unset PRT_TEST_SUMMARY_COPY
PRT_TEST_TWO_FILE_DIFF=0
rm -rf "$prt_as_dir"

# ============================================================ assessment served by the runner (PRT_ASSESS_BACKEND=runner)
# The assess call goes to a review-run process instead of the proxy. A stub
# review-run stands in: it records argv, stdin and environment per call, reads
# the findings the orchestrator sent (the line after the FINDINGS marker) and
# answers one verdict per fp. Everything after the call (salvage, retry, join,
# degrade) is the proxy path's own code, so the cases here only show the switch.
prt_ar_dir="$(mktemp -d)"
cat > "$prt_ar_dir/review-run" <<'ARSTUB'
#!/usr/bin/env bash
set -u
log="${PRT_TEST_RUNNER_LOG:?}"
args=("$@")
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --) shift; break ;;
    --backend|--root|--base|--seconds|--sandbox|--effort|--add-dir) shift 2 ;;
    *) shift ;;
  esac
done
req="$(cat)"
n=$(($(cat "$log.count" 2>/dev/null || echo 0) + 1))
echo "$n" > "$log.count"
printf '%s\n' "${args[@]}" > "$log.argv.$n"
printf '%s' "$req" > "$log.stdin.$n"
env > "$log.env.$n"
mode="${PRT_TEST_RUNNER_MODE:-clean}"
# The real runner refuses an output directory that already holds a result.
if [ -e "$out/review.md" ] || { [ -d "$out" ] && [ -n "$(ls -A "$out")" ]; }; then exit 64; fi
case "$mode" in
  exit[0-9]*) exit "${mode#exit}" ;;
  garbage_then_exit4) if [ "$n" -ge 2 ]; then exit 4; fi; mode=garbage ;;
  garbage_then_clean) if [ "$n" -ge 2 ]; then mode=clean; else mode=garbage; fi ;;
esac
verdict=VALID
[ "$mode" = false_positive ] && verdict=FALSE_POSITIVE
fps="$(sed -n '/^--- FINDINGS (JSON) ---$/{n;p;}' <<< "$req" | jq -c '[.[].fp]')"
good="$(jq -n -c --argjson fps "$fps" --arg v "$verdict" \
  '{assessments: [$fps[] | {fp: ., verdict: $v, reasoning: "stub"}]}')"
mkdir -p "$out"
case "$mode" in
  nofile) exit 0 ;;
  empty) : > "$out/review.md" ;;
  garbage) printf 'not json at all, sorry' > "$out/review.md" ;;
  prose) printf 'Here is the assessment:\n%s\nDone.' "$good" > "$out/review.md" ;;
  bad_shape) printf '{"assessments":"oops-not-an-array"}' > "$out/review.md" ;;
  *) printf '%s' "$good" > "$out/review.md" ;;
esac
# A faithful provenance record; the prov_* modes break exactly one field.
in_sha="$(printf '%s' "$req" | sha256sum | cut -d' ' -f1)"
p_head="${PRT_HEAD_SHA:-}"; p_base="${PRT_REVIEW_BASE_SHA:-}"; p_mat="${PRT_REVIEW_MATERIAL_SHA256:-}"
p_format=review-run-v1; p_outcome=completed
case "${PRT_TEST_RUNNER_PROV:-}" in
  head) p_head=0000000000000000000000000000000000000000 ;;
  base) p_base=0000000000000000000000000000000000000000 ;;
  material) p_mat=0000000000000000000000000000000000000000000000000000000000000000 ;;
  input) in_sha=0000000000000000000000000000000000000000000000000000000000000000 ;;
  format) p_format=review-run-v0 ;;
  outcome) p_outcome=incomplete ;;
esac
if [ "${PRT_TEST_RUNNER_PROV:-}" = missing ]; then exit 0; fi
if [ "${PRT_TEST_RUNNER_PROV:-}" = malformed ]; then printf 'not json' > "$out/provider.json"; exit 0; fi
jq -n --arg f "$p_format" --arg o "$p_outcome" --arg h "$p_head" --arg b "$p_base" --arg m "$p_mat" --arg i "$in_sha" \
  '{format:$f, outcome:$o, identity:{head:$h, base:$b, material_sha256:$m, input_sha256:$i}}' > "$out/provider.json"
exit 0
ARSTUB
chmod 755 "$prt_ar_dir/review-run"
PRT_TEST_RUNNER_LOG="$prt_ar_dir/log"
PRT_TEST_ASSESS_RUNNER="$prt_ar_dir/review-run"
PRT_TEST_ASSESS_RUNNER_BACKEND="codex"
PRT_TEST_REVIEW_BASE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PRT_TEST_REVIEW_MATERIAL_SHA256="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding
# The runner sees a scrubbed environment: only these (non-secret) test variables
# are passed through to the stub, besides the always-passed PATH and HOME.
PRT_TEST_ASSESS_RUNNER_ENV="PRT_TEST_RUNNER_LOG PRT_TEST_RUNNER_MODE PRT_TEST_RUNNER_PROV PRT_HEAD_SHA PRT_REVIEW_BASE_SHA PRT_REVIEW_MATERIAL_SHA256"
prt_ar_calls() { cat "$PRT_TEST_RUNNER_LOG.count" 2>/dev/null || echo 0; }

# A VALID verdict from the runner: the finding gets its thread, the proxy never assesses.
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_ASSESS_BACKEND="runner"
PRT_TEST_RUNNER_MODE=clean
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "assess runner, VALID: exits 0 and the finding gets its thread" "0 1" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE")"
assert_eq "assess runner: one runner call, no proxy assess call" "1 0" "$(prt_ar_calls) $(cat "$PRT_TEST_ASSESS_COUNTFILE")"
assert_eq "assess runner: the review still came from the proxy (review call made)" \
  "true" "$([ "$(cat "$PRT_TEST_MODEL_COUNTFILE")" -ge 1 ] && echo true || echo false)"
assert_eq "assess runner: the coverage line says review+assess ok" \
  "true" "$(grep -qE 'coverage: 1/1 chunks review\+assess ok' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "assess runner: the run is not degraded" \
  "false" "$(grep -qF 'REVIEW_DEGRADED:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# A FALSE_POSITIVE verdict from the runner is honoured: no thread, suppressed.
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_RUNNER_MODE=false_positive
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "assess runner, FALSE_POSITIVE: exits 0, no thread created, suppressed=1" \
  "0 0 true" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE") $(grep -qE 'done:.*suppressed=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "assess runner, FALSE_POSITIVE: still no proxy assess call" "1 0" "$(prt_ar_calls) $(cat "$PRT_TEST_ASSESS_COUNTFILE")"

# Unset keeps the proxy: the runner is never called.
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_ASSESS_BACKEND=""
PRT_TEST_RUNNER_MODE=clean
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "assess backend unset: the proxy assesses, the runner is never called" \
  "0 1 0" "$rc $(cat "$PRT_TEST_ASSESS_COUNTFILE") $(prt_ar_calls)"

# An unknown backend is refused at start, not read as the default, and nothing is called.
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_ASSESS_BACKEND="carrier-pigeon"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "assess backend 'carrier-pigeon': fails closed before any call" \
  "1 0 0 0" "$rc $(cat "$PRT_TEST_MODEL_COUNTFILE") $(cat "$PRT_TEST_ASSESS_COUNTFILE") $(prt_ar_calls)"
assert_eq "assess backend 'carrier-pigeon': the error names PRT_ASSESS_BACKEND" \
  "true" "$(grep -qF 'PRT_ASSESS_BACKEND must be empty or runner' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# The runner without a backend to run is a configuration error, caught at start.
PRT_TEST_ASSESS_BACKEND="runner"
PRT_TEST_ASSESS_RUNNER_BACKEND=""
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "assess runner without PRT_ASSESS_RUNNER_BACKEND: fails closed before any call" \
  "1 0 0 0" "$rc $(cat "$PRT_TEST_MODEL_COUNTFILE") $(cat "$PRT_TEST_ASSESS_COUNTFILE") $(prt_ar_calls)"
assert_eq "assess runner without PRT_ASSESS_RUNNER_BACKEND: the error names it" \
  "true" "$(grep -qF 'PRT_ASSESS_RUNNER_BACKEND is required' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Failure parity with the proxy path: whatever goes wrong with the runner, the run
# is degraded, never fatal, and the findings stay unverdicted (still blocking).
PRT_TEST_ASSESS_BACKEND="runner"
PRT_TEST_ASSESS_RUNNER_BACKEND="codex"
prt_ar_failure_case() { # label mode expected-exit expected-reason
  rm -f "$PRT_TEST_RUNNER_LOG".*
  PRT_TEST_RUNNER_MODE="$2"
  rc="$(run_orchestrator advisory 0 0 0)"
  assert_eq "assess runner $1: exits 0 (degraded, not fatal)" "0" "$rc"
  assert_eq "assess runner $1: one runner call, no proxy call" "1 0" "$(prt_ar_calls) $(cat "$PRT_TEST_ASSESS_COUNTFILE")"
  assert_eq "assess runner $1: degraded as an assessment transport failure (exit $3)" \
    "true" "$(grep -qF "assessment call failed (transport/proxy error, exit $3)" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
  assert_eq "assess runner $1: the failure reason is $4" \
    "true" "$(grep -qF "[$4]" "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
  assert_eq "assess runner $1: not reported as an incomplete review" \
    "false" "$(grep -qF 'REVIEW_INCOMPLETE' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
}
prt_ar_failure_case "quota (exit 3)" exit3 1 runner-quota
prt_ar_failure_case "launch failure (exit 4)" exit4 1 runner-launch
prt_ar_failure_case "incomplete (exit 2)" exit2 1 runner-incomplete
prt_ar_failure_case "usage/over-limit (exit 64)" exit64 1 runner-usage
prt_ar_failure_case "unexpected exit (7)" exit7 1 runner-failed
prt_ar_failure_case "no review.md" nofile 1 runner-no-output
prt_ar_failure_case "empty review.md" empty 1 runner-empty

# A malformed answer is retried once with a fresh output directory, then degrades.
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_RUNNER_MODE=garbage
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "assess runner, garbage twice: exits 0, runner called twice" "0 2" "$rc $(prt_ar_calls)"
assert_eq "assess runner, garbage twice: degraded as not valid JSON after retry" \
  "true" "$(grep -qF 'assessment response was not valid JSON after retry=true' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "assess runner, garbage twice: the raw text is not echoed" \
  "false" "$(grep -qF 'not json at all' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Garbage then a clean answer: the retry recovers.
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_RUNNER_MODE=garbage_then_clean
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "assess runner, garbage then clean: recovered, thread created, two calls" \
  "0 1 2" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE") $(prt_ar_calls)"
assert_eq "assess runner, garbage then clean: not degraded" \
  "false" "$(grep -qF 'REVIEW_DEGRADED:' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Garbage then a runner failure on the retry.
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_RUNNER_MODE=garbage_then_exit4
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "assess runner, garbage then launch failure: exits 0, two calls" "0 2" "$rc $(prt_ar_calls)"
assert_eq "assess runner, garbage then launch failure: degraded on retry" \
  "true" "$(grep -qF 'assessment call failed on retry' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# Prose around the JSON is salvaged, as on the proxy path.
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_RUNNER_MODE=prose
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "assess runner, prose-wrapped JSON: salvaged, one call, thread created" \
  "0 1 1" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE") $(prt_ar_calls)"

# Valid JSON of the wrong shape degrades the chunk.
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_RUNNER_MODE=bad_shape
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "assess runner, bad shape: exits 0 and degrades" \
  "0 true" "$rc $(grep -qF '.assessments missing/null/non-array' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_RUNNER_MODE=clean

# In enforce the unverdicted finding still gets its thread (null counts as VALID).
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_RUNNER_MODE=exit3
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "assess runner quota in enforce: exits 0, the unverdicted finding is still posted" \
  "0 1" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE")"
PRT_TEST_RUNNER_MODE=clean

# Provenance: the runner's record must tie the answer to this head, this base, this
# material and the exact request sent. Any mismatch is refused, never read.
export PRT_TEST_RUNNER_PROV
prt_ar_prov_case() { # label prov-mode
  rm -f "$PRT_TEST_RUNNER_LOG".*
  PRT_TEST_RUNNER_PROV="$2"
  rc="$(run_orchestrator advisory 0 0 0)"
  assert_eq "assess runner provenance, $1: exits 0 (degraded, not fatal), one call" "0 1" "$rc $(prt_ar_calls)"
  assert_eq "assess runner provenance, $1: refused as provenance-mismatch" \
    "true" "$(grep -qF '[provenance-mismatch]' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
  assert_eq "assess runner provenance, $1: the verdicts are not used" \
    "false" "$(grep -qE 'coverage: [0-9]+/[0-9]+ chunks review\+assess ok' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
}
PRT_TEST_RUNNER_MODE=clean
prt_ar_prov_case "other head" head
prt_ar_prov_case "other base" base
prt_ar_prov_case "other material" material
prt_ar_prov_case "other input (request not the one sent)" input
prt_ar_prov_case "wrong format" format
prt_ar_prov_case "outcome not completed" outcome
prt_ar_prov_case "no provider.json" missing
prt_ar_prov_case "unparseable provider.json" malformed
PRT_TEST_RUNNER_PROV=""

# The faithful record passes, and the material hash must be configured.
rm -f "$PRT_TEST_RUNNER_LOG".*
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "assess runner provenance, faithful record: accepted, thread created" "0 1" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE")"
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_REVIEW_MATERIAL_SHA256=""
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "assess runner without PRT_REVIEW_MATERIAL_SHA256: no runner call, degraded as backend-config" \
  "0 0 true" "$rc $(prt_ar_calls) $(grep -qF '[backend-config]' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_REVIEW_MATERIAL_SHA256="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

# The runner reads untrusted PR text and runs with no sandbox, so it must never
# hold a token that can write to the PR: the child gets a scrubbed environment.
PRT_TEST_GH_TOKEN="sentinel-posting-token"
export GITHUB_TOKEN="sentinel-github-token" GH_TOKEN="sentinel-gh-token" \
  OPENAI_API_KEY="sentinel-model-key" PRT_AR_UNRELATED="sentinel-unrelated"
PRT_TEST_ASSESS_RUNNER_ENV="$PRT_TEST_ASSESS_RUNNER_ENV OPENAI_API_KEY"
rm -f "$PRT_TEST_RUNNER_LOG".*
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "assess runner scrub: the run succeeds with the scrubbed environment" "0 1 1" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE") $(prt_ar_calls)"
assert_eq "assess runner scrub: the posting token is not in the orchestrator's own output" \
  "true" "$(grep -qF 'sentinel-posting-token' "$PRT_TEST_STDERR_FILE" "$PRT_TEST_STDOUT_FILE" && echo leak || echo true)"
assert_eq "assess runner scrub: no token value reaches the runner's environment" \
  "0" "$(grep -c 'sentinel-posting-token\|sentinel-github-token\|sentinel-gh-token' "$PRT_TEST_RUNNER_LOG.env.1")"
assert_eq "assess runner scrub: no token variable name reaches it either" \
  "0" "$(grep -cE '^(PRT_GH_TOKEN|GITHUB_TOKEN|GH_TOKEN)=' "$PRT_TEST_RUNNER_LOG.env.1")"
assert_eq "assess runner scrub: an unrelated variable is dropped" \
  "0" "$(grep -c 'sentinel-unrelated' "$PRT_TEST_RUNNER_LOG.env.1")"
assert_eq "assess runner scrub: PATH, HOME and the named model key are kept" \
  "1 1 1" "$(grep -c '^PATH=' "$PRT_TEST_RUNNER_LOG.env.1") $(grep -c '^HOME=' "$PRT_TEST_RUNNER_LOG.env.1") $(grep -c '^OPENAI_API_KEY=sentinel-model-key$' "$PRT_TEST_RUNNER_LOG.env.1")"

# The request travels on stdin; the prompt argument is a fixed instruction.
assert_eq "assess runner request: the findings are on stdin" \
  "true" "$(grep -qF -- '--- FINDINGS (JSON) ---' "$PRT_TEST_RUNNER_LOG.stdin.1" && echo true || echo false)"
assert_eq "assess runner request: argv carries no findings and stays small" \
  "true" "$(! grep -qF 'FINDINGS' "$PRT_TEST_RUNNER_LOG.argv.1" && [ "$(wc -c < "$PRT_TEST_RUNNER_LOG.argv.1")" -lt 600 ] && echo true || echo false)"
assert_eq "assess runner request: backend, base and no-sandbox flags are passed" \
  "1 1 1" "$(grep -cxF codex "$PRT_TEST_RUNNER_LOG.argv.1") $(grep -cxF "$PRT_TEST_REVIEW_BASE_SHA" "$PRT_TEST_RUNNER_LOG.argv.1") $(grep -cxF none "$PRT_TEST_RUNNER_LOG.argv.1")"

# A pass-through list that names a posting token is refused at start, before any call.
for prt_ar_name in GITHUB_TOKEN GH_TOKEN PRT_GH_TOKEN; do
  rm -f "$PRT_TEST_RUNNER_LOG".*
  PRT_TEST_ASSESS_RUNNER_ENV="OPENAI_API_KEY $prt_ar_name"
  rc="$(run_orchestrator enforce 0 0 0)"
  assert_eq "assess runner scrub, pass-through names $prt_ar_name: fails closed before any call" \
    "1 0 0 0" "$rc $(cat "$PRT_TEST_MODEL_COUNTFILE") $(cat "$PRT_TEST_ASSESS_COUNTFILE") $(prt_ar_calls)"
  assert_eq "assess runner scrub, pass-through names $prt_ar_name: the error names PRT_ASSESS_RUNNER_ENV" \
    "true" "$(grep -qF 'PRT_ASSESS_RUNNER_ENV' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
done
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_ASSESS_RUNNER_ENV="OPENAI_API_KEY BAD-NAME"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "assess runner scrub, a malformed name in the list: fails closed before any call" \
  "1 0" "$rc $(prt_ar_calls)"
PRT_TEST_ASSESS_RUNNER_ENV="PRT_TEST_RUNNER_LOG PRT_TEST_RUNNER_MODE PRT_TEST_RUNNER_PROV PRT_HEAD_SHA PRT_REVIEW_BASE_SHA PRT_REVIEW_MATERIAL_SHA256"
unset GITHUB_TOKEN GH_TOKEN OPENAI_API_KEY PRT_AR_UNRELATED PRT_TEST_GH_TOKEN prt_ar_name

# PRT_MODE=off stays the escape hatch whatever this says.
PRT_TEST_ASSESS_BACKEND="carrier-pigeon"
rc="$(run_orchestrator off 0 0 0)"
assert_eq "mode off with assess backend 'carrier-pigeon': still exits 0" "0" "$rc"

# Review from a findings file and assessment from the runner: nothing needs the
# proxy, so enforce runs with assessment on and no proxy URL at all.
prt_ar_ff="$(mktemp -d)"
cat > "$prt_ar_ff/findings.json" <<'ARFINDINGS'
{"format":"review-findings-v1","findings":[
 {"file":"x.go","line":1,"severity":"high","category":"logic-error","issue":"issue-for-x","fix":"fix-x","klass":"blocking","claim":"cx"},
 {"file":"y.go","line":1,"severity":"high","category":"race","issue":"issue-for-y","fix":"fix-y","klass":"blocking","claim":"cy"}
]}
ARFINDINGS
jq -n '{format:"review-run-v1", outcome:"completed", backend:"x", identity:{root:"/r", head:"1111111111111111111111111111111111111111", base:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", material_sha256:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", input_sha256:"d", add_dirs:[]}}' \
  > "$prt_ar_ff/provider.json"
PRT_TEST_REVIEW_BACKEND="file"
PRT_TEST_FINDINGS_FILE="$prt_ar_ff/findings.json"
PRT_TEST_TWO_FILE_DIFF=1
PRT_TEST_PROXY_URL=""
PRT_TEST_ASSESS_BACKEND="runner"
PRT_TEST_ASSESS_RUNNER_BACKEND="codex"
PRT_TEST_RUNNER_MODE=clean
rm -f "$PRT_TEST_RUNNER_LOG".*
rc="$(run_orchestrator enforce 0 0 0 150)"
assert_eq "enforce, file review, runner assess, no proxy URL: exits 0, both findings get a thread" \
  "0 2" "$rc $(cat "$PRT_TEST_CREATE_COUNTFILE")"
assert_eq "enforce, file review, runner assess, no proxy URL: one runner call per chunk, no proxy call" \
  "2 0 0" "$(prt_ar_calls) $(cat "$PRT_TEST_MODEL_COUNTFILE") $(cat "$PRT_TEST_ASSESS_COUNTFILE")"
assert_eq "enforce, file review, runner assess, no proxy URL: coverage says review+assess ok" \
  "true" "$(grep -qE 'coverage: 2/2 chunks review\+assess ok' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# The runner call shares the run's model deadline with the proxy calls: it is
# clamped to what is left, and refused when too little is left, so slow chunks
# cannot eat the time reserved for posting the findings.
prt_ar_seconds() { sed -n '/^--seconds$/{n;p;}' "$PRT_TEST_RUNNER_LOG.argv.${1:-1}"; }
rm -f "$PRT_TEST_RUNNER_LOG".*
rc="$(run_orchestrator advisory 0 0 0 150)"
assert_eq "assess runner deadline, default budget: each call gets the 600s default" \
  "0 2 600 600" "$rc $(prt_ar_calls) $(prt_ar_seconds 1) $(prt_ar_seconds 2)"
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_MODEL_BUDGET_SECONDS=100
rc="$(run_orchestrator advisory 0 0 0 150)"
assert_eq "assess runner deadline, 100s budget: the call is clamped to what is left" \
  "0 2 true true" "$rc $(prt_ar_calls) \
$([ "$(prt_ar_seconds 1)" -ge 90 ] && [ "$(prt_ar_seconds 1)" -le 100 ] && echo true || echo false) \
$([ "$(prt_ar_seconds 2)" -ge 1 ] && [ "$(prt_ar_seconds 2)" -le 100 ] && echo true || echo false)"
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_MODEL_BUDGET_SECONDS=10
rc="$(run_orchestrator advisory 0 0 0 150)"
assert_eq "assess runner deadline, budget below the floor: no runner call, run still exits 0" "0 0" "$rc $(prt_ar_calls)"
assert_eq "assess runner deadline, budget below the floor: degraded as deadline-exhausted" \
  "true" "$(grep -qF '[deadline-exhausted]' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
rm -f "$PRT_TEST_RUNNER_LOG".*
PRT_TEST_MODEL_BUDGET_SECONDS=""
PRT_TEST_ASSESS_RUNNER_SECONDS=soon
rc="$(run_orchestrator advisory 0 0 0 150)"
assert_eq "assess runner, non-numeric PRT_ASSESS_RUNNER_SECONDS: no runner call, degraded as backend-config" \
  "0 0 true" "$rc $(prt_ar_calls) $(grep -qF '[backend-config]' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_ASSESS_RUNNER_SECONDS=""

# The review still needs the proxy when it is not a findings file.
PRT_TEST_REVIEW_BACKEND=""
rc="$(run_orchestrator enforce 0 0 0 150)"
assert_eq "enforce, proxy review, runner assess, no proxy URL: fails closed on the review's need" "1" "$rc"
assert_eq "enforce, proxy review, runner assess, no proxy URL: the error names PRT_PROXY_URL" \
  "true" "$(grep -qF 'PRT_PROXY_URL is required' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# And the assessment needs it when it stays on the proxy.
PRT_TEST_REVIEW_BACKEND="file"
PRT_TEST_ASSESS_BACKEND=""
rc="$(run_orchestrator enforce 0 0 0 150)"
assert_eq "enforce, file review, proxy assess, no proxy URL: fails closed on the assessment's need" "1" "$rc"
assert_eq "enforce, file review, proxy assess, no proxy URL: the error names PRT_PROXY_URL" \
  "true" "$(grep -qF 'PRT_PROXY_URL is required' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_TWO_FILE_DIFF=0
unset PRT_TEST_REVIEW_BACKEND PRT_TEST_FINDINGS_FILE PRT_TEST_PROXY_URL
rm -rf "$prt_ar_ff"

unset PRT_TEST_ASSESS_BACKEND PRT_TEST_ASSESS_RUNNER PRT_TEST_ASSESS_RUNNER_BACKEND PRT_TEST_RUNNER_MODE PRT_TEST_RUNNER_LOG \
  PRT_TEST_REVIEW_BASE_SHA PRT_TEST_REVIEW_MATERIAL_SHA256 PRT_TEST_RUNNER_PROV PRT_TEST_ASSESS_RUNNER_ENV \
  PRT_TEST_MODEL_BUDGET_SECONDS PRT_TEST_ASSESS_RUNNER_SECONDS
PRT_TEST_MODEL_RESPONSE_MODE=clean
rm -rf "$prt_ar_dir"

# ============================================================ model.sh: unparseable-response diagnostic (go-kure/.github#81)
# Every PR in this repo went red with `len=57 leading=starts-with-prose` and
# nothing else — enough to know a fixed prose string came back, not enough to
# tell quota from auth from an overloaded backend from a real model refusal.
# These cover the two fields added to close that gap, and the invariant that
# neither may echo the response.

# --- prt_response_class: each arm reaches its class ---
assert_eq "response class: usage-limit prose is backend-limit" "backend-limit" \
  "$(prt_response_class "You've reached your usage limit. Please try again later.")"
assert_eq "response class: 'limit reached' variant is backend-limit" "backend-limit" \
  "$(prt_response_class "Claude AI usage limit reached|1755808200")"
# The live 2026-09-04 outage string, VERBATIM — a paraphrase is exactly what
# let this gap through the first time. Matched by the "session limit" phrase.
assert_eq "response class: the observed session-limit notice is backend-limit" "backend-limit" \
  "$(prt_response_class "You've hit your session limit · resets 10:10am (UTC)")"
# The SHAPE match, asserted independently: the window word here is deliberately
# NOT "session", so this can only pass via "limit · resets". Without a separate
# case the two new alternatives would be covered by one assertion that passes
# for either reason, and either could rot unnoticed.
assert_eq "response class: an unseen window variant still matches on shape" "backend-limit" \
  "$(prt_response_class "You've hit your weekly limit · resets Monday at 9am (UTC)")"
assert_eq "response class: credit balance is backend-billing" "backend-billing" \
  "$(prt_response_class "Your credit balance is too low to access the Anthropic API")"
assert_eq "response class: overloaded is backend-overloaded" "backend-overloaded" \
  "$(prt_response_class "Overloaded")"
assert_eq "response class: auth failure is backend-auth" "backend-auth" \
  "$(prt_response_class "Could not resolve credentials for the upstream account")"
assert_eq "response class: unknown model is backend-model" "backend-model" \
  "$(prt_response_class "invalid model: claude-opus-4")"
assert_eq "response class: context overflow is backend-context" "backend-context" \
  "$(prt_response_class "prompt is too long: maximum context is 200000 tokens")"
assert_eq "response class: a genuine refusal is model-refusal, not a backend fault" "model-refusal" \
  "$(prt_response_class "I am sorry, I will not review that content.")"

# Classification is case-insensitive: the backend does not promise a casing.
assert_eq "response class: matching is case-insensitive" "backend-limit" \
  "$(prt_response_class "USAGE LIMIT EXCEEDED")"

# --- the invariant: an unanticipated message leaks nothing ---
# The whole reason this is a closed enum rather than a substring dump. If this
# ever fails, the "never log raw model responses" rule in
# docs/pr-review-threads.md "Failure surface" has been broken.
prt_secret_response="SECRETTOKEN-abc123 leaked internal detail nobody should see"
assert_eq "response class: an unmatched response classifies as unrecognized" "unrecognized" \
  "$(prt_response_class "$prt_secret_response")"
assert_eq "response class: output never contains any of the response text" "true" \
  "$(case "$(prt_response_class "$prt_secret_response")" in *SECRETTOKEN*|*leaked*) echo false ;; *) echo true ;; esac)"
assert_eq "response shape: full diagnostic never contains the response text" "true" \
  "$(case "$(prt_response_shape "$prt_secret_response")" in *SECRETTOKEN*|*leaked*) echo false ;; *) echo true ;; esac)"

# Every class the function can emit is a member of the declared enum.
prt_class_leak=false
for prt_probe in "usage limit" "session limit" "limit · resets" "credit balance" "overloaded" \
                 "api key" "unknown model" \
                 "context length" "i cannot" "nothing matches this at all"; do
  prt_got="$(prt_response_class "$prt_probe")"
  case " $PRT_RESPONSE_CLASSES " in
    *" $prt_got "*) ;;
    *) prt_class_leak=true ;;
  esac
done
assert_eq "response class: every emitted class is a member of PRT_RESPONSE_CLASSES" "false" "$prt_class_leak"

# --- prt_response_fingerprint: stable, content-sensitive, fixed width ---
assert_eq "response fingerprint: identical content gives an identical hash" \
  "$(prt_response_fingerprint "same body")" "$(prt_response_fingerprint "same body")"
assert_ne "response fingerprint: different content gives a different hash" \
  "$(prt_response_fingerprint "body a")" "$(prt_response_fingerprint "body b")"
assert_eq "response fingerprint: 16 hex chars, matching prt_fp_base's width" "16" \
  "$(printf '%s' "$(prt_response_fingerprint "anything")" | wc -c | tr -d ' ')"
# Two DIFFERENT responses of the SAME length — the exact ambiguity #81 could
# not resolve from len= alone, and the reason a fingerprint was added.
assert_ne "response fingerprint: distinguishes equal-length distinct responses" \
  "$(prt_response_fingerprint "aaaaaaaaaa")" "$(prt_response_fingerprint "bbbbbbbbbb")"

# --- prt_response_shape: the pre-existing fields still behave ---
assert_eq "response shape: brace-leading content still reports starts-with-brace" "true" \
  "$(case "$(prt_response_shape '{"findings":[]}')" in *"leading=starts-with-brace"*) echo true ;; *) echo false ;; esac)"
assert_eq "response shape: fence-leading content still reports starts-with-fence" "true" \
  "$(case "$(prt_response_shape '```json')" in *"leading=starts-with-fence"*) echo true ;; *) echo false ;; esac)"
assert_eq "response shape: leading whitespace is trimmed before classifying" "true" \
  "$(case "$(prt_response_shape '   {"a":1}')" in *"leading=starts-with-brace"*) echo true ;; *) echo false ;; esac)"
assert_eq "response shape: len counts the untrimmed content" "true" \
  "$(case "$(prt_response_shape '  {}')" in *"len=4 "*) echo true ;; *) echo false ;; esac)"
# The #81 signature end to end: what that job log would print today.
assert_eq "response shape: emits all four fields" "true" \
  "$(case "$(prt_response_shape "You've reached your usage limit. Please try again.")" in
       *"len="*"leading=starts-with-prose"*"class=backend-limit"*"sha16="*) echo true ;;
       *) echo false ;;
     esac)"

# ============================================================ excluded files (go-kure/.github#293)
# Lockfiles by exact basename, and files the BASE commit's .gitattributes marks
# linguist-generated, leave the reviewed diff and are named in every verdict.
# A hunk over the hard ceiling in any other file still fails the run, and a
# linguist-generated entry the PR head adds is never honoured.
xf_dir="$(mktemp -d)"
# One added line longer than the 200000-char hard ceiling (4 x the default
# 50000 soft limit), so a single hunk must truncate if it reaches the chunker.
xf_big="$(head -c 210000 /dev/zero | tr '\0' 'x')"
# xf_rec PATH LINE... — one modified-file record: one removed line, then LINE... added.
xf_rec() {
  local p="$1"
  shift
  printf 'diff --git a/%s b/%s\nindex 1111111..2222222 100644\n--- a/%s\n+++ b/%s\n@@ -1,1 +1,%s @@\n-old\n' "$p" "$p" "$p" "$p" "$#"
  printf '+%s\n' "$@"
}

# --- prt_exclude_files: which records leave the diff, and what is reported ---
{
  xf_rec web/package-lock.json a b
  xf_rec go.mod 'require x v1'
  xf_rec gen/api.pb.go y
  printf 'diff --git a/go.sum b/go.sum\ndeleted file mode 100644\nindex 3333333..0000000\n--- a/go.sum\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-x\n-y\n'
  xf_rec docs/readme.md z
} > "$xf_dir/mixed.diff"
printf 'gen/** linguist-generated\n*.md linguist-generated=false\n' > "$xf_dir/attrs"
xf_out="$(prt_exclude_files "$xf_dir/mixed.diff" "$xf_dir/attrs" "$xf_dir/kept.diff")"
assert_eq "exclude: rc 0 on a readable diff" "0" "$?"
assert_eq "exclude: lockfiles by basename and base-marked generated files leave, in diff order, with +/- counts" \
  '[{"path":"web/package-lock.json","added":2,"removed":1,"reason":"lockfile"},{"path":"gen/api.pb.go","added":1,"removed":1,"reason":"linguist-generated"},{"path":"go.sum","added":0,"removed":2,"reason":"lockfile"}]' \
  "$(jq -c . <<< "$xf_out")"
assert_eq "exclude: go.mod and a file set linguist-generated=false stay, byte for byte" \
  "$(xf_rec go.mod 'require x v1'; xf_rec docs/readme.md z)" "$(cat "$xf_dir/kept.diff")"

prt_exclude_files "$xf_dir/mixed.diff" "" "$xf_dir/kept2.diff" > "$xf_dir/out2"
assert_eq "exclude: with no base attributes only the fixed lockfile list leaves" \
  '["web/package-lock.json","go.sum"]' "$(jq -c 'map(.path)' "$xf_dir/out2")"

# The list is spelled out, not read from PRT_EXCLUDED_BASENAMES, so a name
# dropped from (or added to) the fixed list fails here.
{
  for xf_name in package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock go.sum Cargo.lock poetry.lock uv.lock composer.lock Gemfile.lock; do
    xf_rec "sub/$xf_name" l
  done
  for xf_name in go.mod package.json Cargo.toml xpackage-lock.json package-lock.json.bak yarn.lock/notes; do xf_rec "sub/$xf_name" l; done
} > "$xf_dir/names.diff"
prt_exclude_files "$xf_dir/names.diff" "" "$xf_dir/kept3.diff" > "$xf_dir/out3"
assert_eq "exclude: every listed basename leaves, and nothing that only resembles one" \
  "10 ${#PRT_EXCLUDED_BASENAMES[@]} sub/go.mod sub/package.json sub/Cargo.toml sub/xpackage-lock.json sub/package-lock.json.bak sub/yarn.lock/notes" \
  "$(jq 'length' "$xf_dir/out3") 10 $(prt_diff_files "$xf_dir/kept3.diff" | tr '\n' ' ' | sed 's/ $//')"

# --- the excluded-files section and the clean verdict that carries it ---
xf_clean="$(prt_render_clean_comment "$(printf '1%.0s' {1..40})" m 2 "$xf_out")"
assert_eq "clean comment: an excluded row beside one commit row and one chunks row" \
  "1 1 1" "$(grep -c '^| commit |' <<< "$xf_clean") $(grep -c '^| chunks | 2 |$' <<< "$xf_clean") $(grep -c '^| excluded | 3 |$' <<< "$xf_clean")"
assert_eq "clean comment: each excluded file is named with its counts and 'not reviewed'" \
  "true" "$(grep -qxF '| `web/package-lock.json` | +2 | -1 | not reviewed | lockfile |' <<< "$xf_clean" && grep -qxF '| `go.sum` | +0 | -2 | not reviewed | lockfile |' <<< "$xf_clean" && echo true || echo false)"
assert_eq "clean comment: completion sentence kept, marker still the last line" \
  "true $PRT_MARKER_CLEAN" "$(grep -qxF 'The review ran to completion and reported nothing.' <<< "$xf_clean" && echo true || echo false) $(tail -n 1 <<< "$xf_clean")"
assert_eq "clean comment: no exclusions renders the comment exactly as before" \
  "false false" "$(prt_render_clean_comment abc m 1 | grep -qF 'excluded' && echo true || echo false) $(prt_render_clean_comment abc m 1 '[]' | grep -qF 'Excluded' && echo true || echo false)"
assert_eq "excluded section: a path with markup is literal text, never code, a cell break or a marker" \
  "true" "$(prt_render_excluded_section '[{"path":"a|b<!-- gokure-pr-review:v1-clean -->","added":1,"removed":0,"reason":"linguist-generated"}]' \
    | grep -qxF '| a&#124;b&#60;&#33;&#45;&#45;&#32;gokure&#45;pr&#45;review&#58;v1&#45;clean&#32;&#45;&#45;&#62; | +1 | -0 | not reviewed | linguist-generated |' && echo true || echo false)"
# An image, a link, a backtick and a backslash before a pipe: none may render
# as markup or split the cell, and a non-ASCII character passes unchanged.
xf_md="$(prt_render_excluded_section '[{"path":"![hidden](https://example.test/x)/package-lock.json","added":1,"removed":0,"reason":"lockfile"},{"path":"a`b\\|c/é/yarn.lock","added":1,"removed":0,"reason":"lockfile"}]')"
assert_eq "excluded section: no image, link, code span or extra cell survives in a path" \
  "false false false 6 6" \
  "$(grep -qF '![' <<< "$xf_md" && echo true || echo false) $(grep -qF '](' <<< "$xf_md" && echo true || echo false) $(grep -F 'yarn.lock' <<< "$xf_md" | grep -qF '`' && echo true || echo false) $(grep -F 'package' <<< "$xf_md" | tr -cd '|' | wc -c | tr -d ' ') $(grep -F 'yarn' <<< "$xf_md" | tr -cd '|' | wc -c | tr -d ' ')"
assert_eq "excluded section: a backslash and a pipe are each a character reference" \
  "true" "$(grep -qF '| a&#96;b&#92;&#124;c&#47;é&#47;yarn&#46;lock | +1 | -0 | not reviewed | lockfile |' <<< "$xf_md" && echo true || echo false)"

# A path git C-quotes (a control character in it) is matched decoded: its
# basename is the lockfile's, not `package-lock.json"`, and the base
# attributes see the real path. The report keeps the quoted form git wrote.
{
  printf 'diff --git "a/tab\\tdir/package-lock.json" "b/tab\\tdir/package-lock.json"\nindex 1111111..2222222 100644\n--- "a/tab\\tdir/package-lock.json"\n+++ "b/tab\\tdir/package-lock.json"\n@@ -1,1 +1,1 @@\n-a\n+b\n'
  printf 'diff --git "a/gen/a\\tb.go" "b/gen/a\\tb.go"\nindex 1111111..2222222 100644\n--- "a/gen/a\\tb.go"\n+++ "b/gen/a\\tb.go"\n@@ -1,1 +1,1 @@\n-a\n+b\n'
  xf_rec keep.go k
} > "$xf_dir/quoted.diff"
printf 'gen/** linguist-generated\n' > "$xf_dir/attrs-gen"
prt_exclude_files "$xf_dir/quoted.diff" "$xf_dir/attrs-gen" "$xf_dir/kept4.diff" > "$xf_dir/out4"
assert_eq "exclude: quoted paths are matched decoded and reported as git quoted them" \
  '[{"path":"\"tab\\tdir/package-lock.json\"","reason":"lockfile"},{"path":"\"gen/a\\tb.go\"","reason":"linguist-generated"}] keep.go' \
  "$(jq -c 'map({path, reason})' "$xf_dir/out4") $(prt_diff_files "$xf_dir/kept4.diff")"

# --- end to end, through the real script ---
PRT_TEST_ISSUE_COMMENT_LOG="$xf_dir/comments.log"
PRT_TEST_MODEL_REQUEST_LOG="$xf_dir/model.log"

# 1. An over-ceiling lockfile next to an ordinary file: the run passes, the
#    lockfile never reaches the model and the clean verdict lists it.
{ xf_rec web/package-lock.json "$xf_big"; xf_rec x.go new; } > "$xf_dir/lock-and-code.diff"
PRT_TEST_DIFF_PATH="$xf_dir/lock-and-code.diff"
: > "$PRT_TEST_ISSUE_COMMENT_LOG"; : > "$PRT_TEST_MODEL_REQUEST_LOG"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "e2e #293: over-ceiling lockfile beside code -> exits 0, nothing truncated" \
  "0 false" "$rc $(grep -qF 'hard ceiling' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "e2e #293: the model saw x.go and none of the lockfile" \
  "true false" "$(grep -qF '+++ b/x.go' "$PRT_TEST_MODEL_REQUEST_LOG" && echo true || echo false) $(grep -qF 'package-lock.json' "$PRT_TEST_MODEL_REQUEST_LOG" && echo true || echo false)"
assert_eq "e2e #293: the clean verdict reviews 1 chunk and names the lockfile as not reviewed" \
  "true true true" "$(grep -qxF '  | | chunks | 1 |' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false) $(grep -qxF '  | | excluded | 1 |' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false) $(grep -qxF '  | | `web/package-lock.json` | +1 | -1 | not reviewed | lockfile |' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"

# 2. A lockfile-only over-ceiling change passes and is listed, with no chunk
#    reviewed and the run degraded: a consumer must not read it as reviewed.
xf_rec web/package-lock.json "$xf_big" > "$xf_dir/lock-only.diff"
PRT_TEST_DIFF_PATH="$xf_dir/lock-only.diff"
: > "$PRT_TEST_ISSUE_COMMENT_LOG"; : > "$PRT_TEST_MODEL_REQUEST_LOG"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "e2e #293: lockfile-only over-ceiling -> exits 0, model never called" \
  "0 0" "$rc $(wc -l < "$PRT_TEST_MODEL_REQUEST_LOG" | tr -d ' ')"
assert_eq "e2e #293: lockfile-only -> clean verdict says chunks 0 and lists the lockfile" \
  "true true" "$(grep -qxF '  | | chunks | 0 |' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false) $(grep -qxF '  | | `web/package-lock.json` | +1 | -1 | not reviewed | lockfile |' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"
assert_eq "e2e #293: lockfile-only -> REVIEW_DEGRADED names the unreviewed diff" \
  "true" "$(grep -qF 'REVIEW_DEGRADED: every file in this diff was excluded' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "e2e #293: lockfile-only, advisory -> degraded banner, no 'No issues found.', lockfile listed" \
  "0 true false true" "$rc $(grep -qF 'This review run was degraded' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false) $(grep -qF 'No issues found.' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false) $(grep -qF '| `web/package-lock.json` | +1 | -1 | not reviewed | lockfile |' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"

# 3. An over-ceiling hunk in a file that is not excluded still fails closed.
xf_rec web/app.js "$xf_big" > "$xf_dir/code-big.diff"
PRT_TEST_DIFF_PATH="$xf_dir/code-big.diff"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "e2e #293: over-ceiling hunk in a reviewed file -> exits 1, REVIEW_INCOMPLETE names the ceiling" \
  "1 true" "$rc $(grep -qF 'REVIEW_INCOMPLETE: diff chunking: a single hunk exceeded the 200000-char hard ceiling' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# 4. A linguist-generated entry the PR head adds is ignored: the base has no
#    .gitattributes (404), so the over-ceiling file is reviewed and fails.
{ printf 'diff --git a/.gitattributes b/.gitattributes\nnew file mode 100644\nindex 0000000..1111111\n--- /dev/null\n+++ b/.gitattributes\n@@ -0,0 +1 @@\n+gen/** linguist-generated\n'
  xf_rec gen/big.go "$xf_big"; } > "$xf_dir/head-attrs.diff"
PRT_TEST_DIFF_PATH="$xf_dir/head-attrs.diff"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "e2e #293: head-only linguist-generated -> nothing excluded, exits 1 on the ceiling" \
  "1 true true" "$rc $(grep -qF 'excluded from review: 0 file(s)' "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -qF 'hard ceiling' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
# The base has no .gitattributes: a 404 is "no file", not a failed read, so
# nothing warns and no failed attempt is reported (a retried read would print
# prt_gh_rest's HTTP 404 line once per attempt).
assert_eq "e2e #293: a 404 for the base .gitattributes -> no warning, no failed attempt" \
  "false 0" "$(grep -qF '.gitattributes could not be read' "$PRT_TEST_STDOUT_FILE" "$PRT_TEST_STDERR_FILE" && echo true || echo false) $(grep -cF 'contents/.gitattributes' "$PRT_TEST_STDERR_FILE")"

# 5. The same entry on the base commit is honoured: the file is excluded and named.
xf_rec gen/big.go "$xf_big" > "$xf_dir/gen-big.diff"
{ cat "$xf_dir/gen-big.diff"; xf_rec x.go new; } > "$xf_dir/gen-and-code.diff"
PRT_TEST_DIFF_PATH="$xf_dir/gen-and-code.diff"
PRT_TEST_BASE_GITATTRIBUTES='gen/** linguist-generated'
: > "$PRT_TEST_ISSUE_COMMENT_LOG"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "e2e #293: base linguist-generated -> exits 0 and names the file as not reviewed" \
  "0 true" "$rc $(grep -qxF '  | | `gen/big.go` | +1 | -1 | not reviewed | linguist-generated |' "$PRT_TEST_ISSUE_COMMENT_LOG" && echo true || echo false)"

# 6. A failed base read fails safe: nothing beyond the lockfile list is
#    excluded, a warning says so, and the over-ceiling file fails the run.
PRT_TEST_BASE_ATTRS_FAIL=1
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "e2e #293: base .gitattributes read fails -> warning, file reviewed, exits 1 on the ceiling" \
  "1 true true" "$rc $(grep -qF '::warning title=PR review threads::the base commit'\''s .gitattributes could not be read' "$PRT_TEST_STDOUT_FILE" && echo true || echo false) $(grep -qF 'hard ceiling' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
unset PRT_TEST_BASE_ATTRS_FAIL PRT_TEST_BASE_GITATTRIBUTES PRT_TEST_DIFF_PATH PRT_TEST_ISSUE_COMMENT_LOG PRT_TEST_MODEL_REQUEST_LOG
rm -rf "$xf_dir"

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
