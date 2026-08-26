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
good_raw='{"findings":[{"file":"a.go","category":"race","line":1,"severity":"High","issue":"i","fix":"f"}]}'
n="$(prt_normalize_findings "$good_raw")"
rc=$?
assert_eq "normalize: well-formed input returns rc 0" "0" "$rc"
assert_eq "normalize: well-formed input keeps 1 element" "1" "$(jq 'length' <<< "$n")"

bad_shape='{"findings":"not-an-array"}'
n="$(prt_normalize_findings "$bad_shape" 2>/dev/null)"
rc=$?
assert_eq "normalize: non-array .findings returns rc 1" "1" "$rc"
assert_eq "normalize: non-array .findings yields []" "[]" "$n"

scalar_elements='{"findings":["oops", 42, null]}'
n="$(prt_normalize_findings "$scalar_elements" 2>/dev/null)"
assert_eq "normalize: array-of-scalars filters down to zero (not a crash)" "0" "$(jq 'length' <<< "$n")"

missing_field='{"findings":[{"file":"a.go","category":"race"}]}'
n="$(prt_normalize_findings "$missing_field" 2>/dev/null)"
assert_eq "normalize: element missing severity/issue/fix is dropped" "0" "$(jq 'length' <<< "$n")"

empty_file='{"findings":[{"file":"","category":"race","severity":"High","issue":"i","fix":"f"}]}'
n="$(prt_normalize_findings "$empty_file" 2>/dev/null)"
assert_eq "normalize: empty-string file is dropped (not == \"\" trap avoided)" "0" "$(jq 'length' <<< "$n")"

object_file='{"findings":[{"file":{"nested":true},"category":"race","severity":"High","issue":"i","fix":"f"}]}'
n="$(prt_normalize_findings "$object_file" 2>/dev/null)"
assert_eq "normalize: object .file (not string) is dropped, not misread as truthy" "0" "$(jq 'length' <<< "$n")"

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

# ============================================================ marker: build/parse round-trip
m="$(prt_marker_build "abcdef0123456789" "" "")"
parsed="$(prt_marker_parse "$m")"
assert_eq "marker round-trip: fp" "abcdef0123456789" "$(cut -f1 <<< "$parsed")"
assert_eq "marker round-trip: no collision by default" "" "$(cut -f2 <<< "$parsed")"
assert_eq "marker round-trip: no first_absent_sha by default" "" "$(cut -f3 <<< "$parsed")"

m="$(prt_marker_build "abcdef0123456789" "true" "1111111111111111111111111111111111111111")"
parsed="$(prt_marker_parse "$m")"
assert_eq "marker round-trip: collision=true survives" "true" "$(cut -f2 <<< "$parsed")"
assert_eq "marker round-trip: first_absent_sha survives" \
  "1111111111111111111111111111111111111111" "$(cut -f3 <<< "$parsed")"

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

# ============================================================ marker: neutralization
neutralized="$(prt_marker_neutralize 'quoting <!-- gokure-pr-review:v1 fp=deadbeefcafebabe --> in prose')"
assert_eq "neutralize: literal marker text is entity-encoded, not left live" \
  "false" "$(prt_marker_parse "$neutralized" >/dev/null 2>&1 && echo true || echo false)"

# ============================================================ marker: has_note
assert_true "marker has_note: matches the reply-note marker" \
  "$(prt_marker_has_note "$PRT_MARKER_NOTE"$'\nsome text' && echo true || echo false)"
assert_eq "marker has_note: a plain human reply does not match" \
  "false" "$(prt_marker_has_note "just a human reply, no marker" && echo true || echo false)"

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

# ============================================================ reconcile: prt_decide_finding
assert_eq "decide_finding: collision beats everything" \
  "NONE" "$(prt_decide_finding true VALID false false false true)"
assert_eq "decide_finding: FALSE_POSITIVE, no thread yet -> suppress, never create" \
  "SUPPRESS" "$(prt_decide_finding false FALSE_POSITIVE false false false true)"
assert_eq "decide_finding: FALSE_POSITIVE, open thread -> reply+resolve" \
  "REPLY_RESOLVE" "$(prt_decide_finding false FALSE_POSITIVE true false false true)"
assert_eq "decide_finding: FALSE_POSITIVE, already-resolved thread -> none" \
  "NONE" "$(prt_decide_finding false FALSE_POSITIVE true true false true)"
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
assert_eq "decide_absent: unanswered maint failure blocks auto-resolve" \
  "NONE" "$(prt_decide_absent false false false abc def false true)"
assert_eq "decide_absent: two absences on different SHAs -> reply+resolve" \
  "REPLY_RESOLVE" "$(prt_decide_absent false false false abc def false false)"

# ============================================================ reconcile: cap reservation (dot-github#51)
# prt_thread_stays_gating / prt_reserved_count / prt_gating_eligible /
# prt_apply_cap — the extracted, tested replacement for the orchestrator's
# former hand-copied inline jq (dot-github#51). Every case below is verified
# by hand against reconcile.sh's own equivalence table.

# --- 7-row matrix (+ null-verdict variant), one OWNED thread each, matched
# against a same-fp finding (thread_exists=true throughout) ---
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
r1_capped="$(prt_apply_cap 5 "$r1_owned" "$r1_findings")"
assert_eq "apply_cap: reordered-severity scenario — zero of the 7 new findings within_cap" \
  "0" "$(jq '[.[] | select((.fp | startswith("n")) and .within_cap == true)] | length' <<< "$r1_capped")"

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
r3_findings='[{"fp":"o1","collision":false,"verdict":"VALID"},
              {"fp":"o2","collision":false,"verdict":"VALID"},
              {"fp":"o3","collision":false,"verdict":"VALID"},
              {"fp":"o4","collision":false,"verdict":"VALID"},
              {"fp":"o5","collision":false,"verdict":"FALSE_POSITIVE"},
              {"fp":"n1","collision":false,"verdict":"VALID","severity":"Critical"},
              {"fp":"n2","collision":false,"verdict":"VALID","severity":"High"},
              {"fp":"n3","collision":false,"verdict":"VALID","severity":"Medium"}]'
assert_eq "reserved_count: FALSE_POSITIVE frees a slot -> reserved drops to 4" \
  "4" "$(prt_reserved_count "$r3_owned" "$r3_findings")"
r3_capped="$(prt_apply_cap 5 "$r3_owned" "$r3_findings")"
assert_eq "apply_cap: FALSE_POSITIVE frees exactly one new finding within_cap" \
  "1" "$(jq '[.[] | select((.fp | startswith("n")) and .within_cap == true)] | length' <<< "$r3_capped")"

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
r5_findings='[{"fp":"n1","collision":false,"verdict":"VALID","severity":"Critical"}]'
assert_eq "reserved_count: 7 open OWNED threads, cap 5 -> reserved is still 7 (not clamped here)" \
  "7" "$(prt_reserved_count "$r5_owned" "$r5_findings")"
r5_capped="$(prt_apply_cap 5 "$r5_owned" "$r5_findings")"
assert_eq "apply_cap: over-reservation clamps remaining to 0, new candidate never within_cap" \
  "false" "$(jq -r '.[] | select(.fp == "n1") | .within_cap' <<< "$r5_capped")"

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
assert_eq "prt_freshness_check: a genuinely moved head names expected -> live" \
  "true" "$(grep -qF 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -> bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' <<< "$fresh_err" && echo true || echo false)"

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
assert_eq "prt_freshness_check: read failure still returns 1 (fail-closed unchanged)" "1" "$rc"
assert_eq "prt_freshness_check: read failure gets its own diagnostic, distinct from the moved-head one" \
  "true" "$(grep -qF 'failed to read PR' <<< "$fresh_err" && echo true || echo false)"

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

superseded_body="$(prt_render_clean_comment_superseded 'def4567890def4567890def4567890def4567890' 2)"
assert_eq "prt_render_clean_comment_superseded: names the superseding SHA" \
  "true" "$(grep -qF 'def4567890def4567890def4567890def4567890' <<< "$superseded_body" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: states the finding count that superseded it" \
  "true" "$(grep -qF '2 finding(s)' <<< "$superseded_body" && echo true || echo false)"
assert_eq "prt_render_clean_comment_superseded: keeps the SAME marker as the original clean comment, so it is found and edited in place, not appended as a new comment" \
  "$PRT_MARKER_CLEAN" "$(tail -1 <<< "$superseded_body")"
assert_ne "prt_render_clean_comment_superseded: the superseded body is visibly distinct from a fresh clean-verdict body" \
  "$superseded_body" "$clean_body"

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
# — this is a bare top-level call at pr-review-threads.sh:115, not inside a
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

# ============================================================ orchestrator: exit-code contract (subprocess, mocked curl)
# pr-review-threads.sh itself is not exercised by the rest of this suite (its
# own header comment says so — it's wiring, not a pure function) but its
# top-level exit code IS a contract worth pinning down directly: :1127's
# REVIEW_INCOMPLETE -> exit 1, PRT_MODE=off's exit 0 staying ahead of that
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
  marker="$(prt_marker_build "${PRT_TEST_OWNED_FP:-deadbeefcafebabe}" "" "${PRT_TEST_FIRST_ABSENT_SHA:-}")"
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

export -f _prt_test_paged_threads_response _prt_test_paginated_comments_response \
  _prt_test_malformed_threads_response

fake_curl_orchestrator() {
  local args=("$@") out="" accept="" url="" method="" data="" h req_body=""
  local i n=${#args[@]}
  for ((i = 0; i < n; i++)); do
    case "${args[$i]}" in
      -o) out="${args[$((i + 1))]}" ;;
      -X) method="${args[$((i + 1))]}" ;;
      -d) data="${args[$((i + 1))]}" ;;
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

  case "$url" in
    */chat/completions)
      # The review and assess calls share this one URL — distinguish them by
      # reading the request body model.sh writes to disk and passes as
      # `-d @FILE` (the E2BIG fix, model.sh:255-265: never inline on argv),
      # so `$data` here is a `@`-prefixed path, not literal JSON. The assess
      # call's user message always contains the literal
      # "--- FINDINGS (JSON) ---" marker (model.sh:349); the review call's
      # never does.
      req_body=""
      case "$data" in
        @*) req_body="$(cat "${data#@}" 2>/dev/null || true)" ;;
      esac
      case "$req_body" in
        *'FINDINGS (JSON)'*)
          # PRT_TEST_ASSESS_* (go-kure/.github assess-resilience workstream):
          # exercises prt_model_assess's exit-status check, salvage pass and
          # bounded retry — the assessment call's mirror of the review call's
          # own resilience below. Only reachable when the review call above
          # actually produced >=1 finding (PRT_TEST_MODEL_RESPONSE_MODE=
          # clean_with_finding), since the orchestrator skips assessment for
          # an empty-findings chunk (pr-review-threads.sh:320).
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
            garbage_then_clean)
              if [ "$mc" -le 1 ]; then
                printf '%s' '{"choices":[{"message":{"content":"not json at all, sorry"}}]}' > "$out"
              else
                printf '%s' '{"choices":[{"message":{"content":"{\"assessments\":[{\"fp\":\"deadbeefcafebabe\",\"verdict\":\"VALID\",\"reasoning\":\"ok\"}]}"}}]}' > "$out"
              fi
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
      _prt_test_bump "${PRT_TEST_ISSUE_COMMENT_COUNTFILE:?}" >/dev/null
      printf '%s' '{"id":1}' > "$out"
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
            resp="$(jq -n --arg body "$(_prt_test_owned_thread_body)" '
              {data:{repository:{pullRequest:{reviewThreads:{
                pageInfo:{hasNextPage:false,endCursor:null},
                nodes:[{
                  id:"THREAD1", isResolved:false, isOutdated:false,
                  resolvedBy:null, viewerCanResolve:true, viewerCanUnresolve:true,
                  comments:{pageInfo:{hasNextPage:false,endCursor:null},
                    nodes:[{id:"C1", databaseId:1, body:$body, author:{login:"test-bot"}}]}
                }]
              }}}}}')"
            printf '%s' "$resp" > "$out"
              ;;
          esac
          echo 200
          ;;
        *PullRequestReviewThread*)
          if [ "${PRT_TEST_INVENTORY_MODE:-single}" = paginated_comments ]; then
            _prt_test_paginated_comments_response "$out" "$data" || return 1
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
          _prt_test_bump "${PRT_TEST_PATCH_COUNTFILE:?}" >/dev/null
          printf '%s' '{"id":1}' > "$out"
          echo 200
          ;;
        *)
          jq -n --arg b "$(_prt_test_owned_thread_body)" '{body:$b}' > "$out"
          echo 200
          ;;
      esac
      ;;
    *)
      if [ "$method" = POST ]; then
        case "$url" in
          */pulls/*/comments)
            case "$data" in
              *in_reply_to*) _prt_test_bump "${PRT_TEST_REPLY_COUNTFILE:?}" >/dev/null ;;
              *commit_id*) _prt_test_bump "${PRT_TEST_CREATE_COUNTFILE:?}" >/dev/null ;;
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
          printf 'diff --git a/x.go b/x.go\nindex 1111111..2222222 100644\n--- a/x.go\n+++ b/x.go\n@@ -1,1 +1,1 @@\n-old\n+new\n' > "$out"
          echo 200
          ;;
        *)
          # meta fetch (:190) and every later freshness re-check (gh.sh:115)
          # share this same GET pulls/<N> shape — deliberately: a freshness
          # check after the meta fetch has already consumed the fail budget
          # must succeed immediately, matching how the real one-run head-SHA
          # only moves once, not repeatedly.
          c="$(_prt_test_bump "${PRT_TEST_META_COUNTFILE:?}")"
          if [ "$c" -le "${PRT_TEST_META_FAIL_TIMES:-0}" ]; then
            : > "$out"; echo 502; return 0
          fi
          printf '{"title":"t","body":"d","head":{"sha":"%s"}}' "$PRT_HEAD_SHA" > "$out"
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
export -f fake_curl_orchestrator _prt_test_bump

# run_orchestrator MODE DIFF_FAIL_TIMES META_FAIL_TIMES MODEL_ALWAYS_FAIL —
# prints the subprocess exit code; countfiles are left behind in the paths
# given via the PRT_TEST_*_COUNTFILE globals set by the caller. stdout/
# stderr are now captured to PRT_TEST_STDOUT_FILE/PRT_TEST_STDERR_FILE
# (also caller-set globals) instead of being discarded — #61's whole point
# is that this output now carries information worth asserting on.
run_orchestrator() {
  local mode="$1" diff_fail="$2" meta_fail="$3" model_fail="$4"
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
  : > "$PRT_TEST_STDOUT_FILE"
  : > "$PRT_TEST_STDERR_FILE"
  (
    cd "$scratch" && \
    PRT_CURL=fake_curl_orchestrator \
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
    PRT_TEST_DIFF_FAIL_TIMES="$diff_fail" \
    PRT_TEST_META_FAIL_TIMES="$meta_fail" \
    PRT_TEST_MODEL_ALWAYS_FAIL="$model_fail" \
    PRT_TEST_EMPTY_DIFF="${PRT_TEST_EMPTY_DIFF:-0}" \
    PRT_TEST_FIRST_ABSENT_SHA="${PRT_TEST_FIRST_ABSENT_SHA:-}" \
    PRT_TEST_OWNED_FP="${PRT_TEST_OWNED_FP:-deadbeefcafebabe}" \
    PRT_TEST_MODEL_RESPONSE_MODE="${PRT_TEST_MODEL_RESPONSE_MODE:-clean}" \
    PRT_TEST_ASSESS_RESPONSE_MODE="${PRT_TEST_ASSESS_RESPONSE_MODE:-clean}" \
    PRT_TEST_ASSESS_ALWAYS_FAIL="${PRT_TEST_ASSESS_ALWAYS_FAIL:-0}" \
    PRT_TEST_INVENTORY_MODE="${PRT_TEST_INVENTORY_MODE:-single}" \
    PRT_GH_TOKEN=x PRT_REPO=owner/repo PRT_PR_NUMBER=1 \
    PRT_HEAD_SHA=1111111111111111111111111111111111111111 \
    PRT_BOT_LOGIN="test-bot[bot]" PRT_PROXY_URL="http://proxy.invalid" \
    PRT_MODE="$mode" GITHUB_STEP_SUMMARY="$summary" \
    bash "$ROOT/scripts/pr-review-threads.sh" >"$PRT_TEST_STDOUT_FILE" 2>"$PRT_TEST_STDERR_FILE"
  )
  rc=$?
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

# ---- Cases iv-viii: assessment-call resilience (assess-resilience
# workstream) — prt_model_assess's exit-status check, and the identical
# salvage-then-retry treatment given to the review call above (Cases i-iii),
# now mirrored for the assess call. Case ix, further below, is the review
# call's own mirror of Case viii. The review call is forced to
# clean_with_finding once here and stays that way through all five cases
# below (iv-viii — the mode is never reset in between) so the assess call
# actually fires at all (pr-review-threads.sh:320 skips assessment for an
# empty-findings chunk, and every other scenario in this file leaves review
# findings empty on purpose).
PRT_TEST_MODEL_RESPONSE_MODE=clean_with_finding

# Case iv — assess call itself fails at the transport layer (non-2xx/curl/
# empty-content — model.sh:286-299), on both the only attempt and would-be
# retry alike: prt_model_assess's own exit status is checked explicitly and
# reported as a transport fault, never silently parsed as empty JSON (root
# cause 2). No salvage/retry is attempted for a transport fault — there is no
# response body to salvage.
PRT_TEST_ASSESS_ALWAYS_FAIL=1
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: assess call transport failure -> exits 1" "1" "$rc"
assert_eq "orchestrator: assess call transport failure -> assess model called exactly once (no salvage/retry on a transport fault)" \
  "1" "$(cat "$PRT_TEST_ASSESS_COUNTFILE")"
assert_eq "orchestrator: assess call transport failure -> REVIEW_INCOMPLETE reports it as a transport/proxy error, not a parse failure" \
  "true" "$(grep -qE 'REVIEW_INCOMPLETE:.*assessment call failed \(transport/proxy error, exit [0-9]+\)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
PRT_TEST_ASSESS_ALWAYS_FAIL=0

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
# bounded retry: exits 1, residual failure still calls prt_mark_incomplete
# (unchanged — degrading this to non-fatal is out of scope here), with the
# shape-only diagnostic present and the raw response text never leaked.
PRT_TEST_ASSESS_RESPONSE_MODE=garbage
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: assess garbage on original + retry -> exits 1" "1" "$rc"
assert_eq "orchestrator: assess garbage on original + retry -> assess model called exactly twice (original + 1 bounded retry)" \
  "2" "$(cat "$PRT_TEST_ASSESS_COUNTFILE")"
assert_eq "orchestrator: assess garbage on original + retry -> REVIEW_INCOMPLETE carries retry=true, salvage_attempted=true, and the full four-field shape diagnostic" \
  "true" "$(grep -qE 'REVIEW_INCOMPLETE:.*assessment response was not valid JSON after retry=true, salvage_attempted=true \(len=[0-9]+ leading=starts-with-prose class=[a-z-]+ sha16=[0-9a-f]{16}\)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: assess garbage on original + retry -> REVIEW_INCOMPLETE does NOT leak the raw response text" \
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
PRT_TEST_ASSESS_RESPONSE_MODE=garbage_then_fail
rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: assess garbage then transport-fail on retry -> exits 1" "1" "$rc"
assert_eq "orchestrator: assess garbage then transport-fail on retry -> assess model called exactly twice (original + 1 bounded retry)" \
  "2" "$(cat "$PRT_TEST_ASSESS_COUNTFILE")"
assert_eq "orchestrator: assess garbage then transport-fail on retry -> REVIEW_INCOMPLETE reports the RETRY as a transport/proxy error, not a parse failure" \
  "true" "$(grep -qE 'REVIEW_INCOMPLETE:.*assessment call failed on retry \(transport/proxy error, exit [0-9]+\)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: assess garbage then transport-fail on retry -> does NOT also report it as an invalid-JSON failure" \
  "false" "$(grep -qF 'assessment response was not valid JSON' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
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

# Case 3a — permanent metadata-fetch failure (F3): every attempt (matching
# prt_retry 3's own attempt count) returns 502, unlike meta_fail=1 below
# which only ever exercises the transient-then-success retry path.
rc="$(run_orchestrator advisory 0 3 0)"
assert_eq "orchestrator: PR-metadata fetch failing all 3 attempts exits 1" "1" "$rc"
assert_eq "orchestrator: permanent metadata-fetch failure — stderr carries the Step 3a ERROR line" \
  "true" "$(grep -qF 'ERROR: failed to fetch PR metadata' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# PRT_MODE=off must short-circuit before any curl call at all (:123-130, ahead
# of the diff fetch at :149) — proven here by wiring in settings that would
# fail the run if the off-mode gate were ever bypassed (an always-failing
# model call, on top of a diff-fetch failure budget deliberately larger than
# the retry cap, so a non-off run would exit 1 either way).
rc="$(run_orchestrator off 99 0 1)"
assert_eq "orchestrator: PRT_MODE=off exits 0 even when everything else would fail/incomplete" "0" "$rc"

rc="$(run_orchestrator advisory 1 0 0)"
assert_eq "orchestrator: diff-fetch retry — one mocked 502 then success still exits 0" "0" "$rc"
assert_eq "orchestrator: diff-fetch retry actually fired (mock hit more than once)" \
  "true" "$([ "$(cat "$PRT_TEST_DIFF_COUNTFILE")" -ge 2 ] && echo true || echo false)"

rc="$(run_orchestrator advisory 0 1 0)"
assert_eq "orchestrator: PR-metadata GET retry — one mocked 502 then success still exits 0" "0" "$rc"
assert_eq "orchestrator: PR-metadata GET retry actually fired (mock hit more than once)" \
  "true" "$([ "$(cat "$PRT_TEST_META_COUNTFILE")" -ge 2 ] && echo true || echo false)"

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

# enforce + empty diff + owned open thread + first_absent_sha on a
# different commit than this run's head -> the second absence -> resolve.
PRT_TEST_EMPTY_DIFF=1
PRT_TEST_FIRST_ABSENT_SHA="2222222222222222222222222222222222222222"
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: enforce + empty diff + second absence on a new SHA -> exits 0" "0" "$rc"
assert_eq "orchestrator: enforce + empty diff + second absence on a new SHA -> resolve count >= 1" \
  "true" "$([ "$(cat "$PRT_TEST_RESOLVE_COUNTFILE")" -ge 1 ] && echo true || echo false)"

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
  "true" "$(grep -q 'threads listed: 120, owned=0' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
assert_eq "orchestrator: 50/50/20 thread inventory never hits argv E2BIG" \
  "false" "$(grep -q 'Argument list too long' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# The first 50 comments plus 50/20 follow-up pages leave the combined extra
# comment accumulator above 131072 bytes. The final reply is human-authored;
# losing it would make the second-absence path incorrectly auto-resolve.
PRT_TEST_INVENTORY_MODE=paginated_comments
PRT_TEST_FIRST_ABSENT_SHA=2222222222222222222222222222222222222222
rc="$(run_orchestrator enforce 0 0 0)"
assert_eq "orchestrator: oversized paginated comments exit 0" "0" "$rc"
assert_eq "orchestrator: oversized paginated comments retain the owned thread" \
  "true" "$(grep -q 'threads listed: 1, owned=1' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
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
for prt_probe in "usage limit" "credit balance" "overloaded" "api key" "unknown model" \
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

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
