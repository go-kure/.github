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
source "$LIB/marker.sh"
# shellcheck source=/dev/null
source "$LIB/finding.sh"
# shellcheck source=/dev/null
source "$LIB/diff.sh"
# shellcheck source=/dev/null
source "$LIB/reconcile.sh"
# shellcheck source=/dev/null
source "$LIB/gh.sh"

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
# (:23 above), so these two cases call it as a plain shell function with a
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
# — this is a bare top-level call at pr-review-threads.sh:92, not inside a
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
# top-level exit code IS a contract worth pinning down directly: :787's
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

fake_curl_orchestrator() {
  local args=("$@") out="" accept="" url="" method="" data="" h
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
      # _prt_test_bump's return value (not discarded here, unlike the other
      # call sites below) is the running per-run model-call count, used by
      # the garbage_then_clean mode to tell the original attempt from the
      # round-2 fold-in's bounded retry apart.
      mc="$(_prt_test_bump "${PRT_TEST_MODEL_COUNTFILE:?}")"
      if [ "${PRT_TEST_MODEL_ALWAYS_FAIL:-0}" = 1 ]; then
        : > "$out"; echo 500; return 0
      fi
      # PRT_TEST_MODEL_RESPONSE_MODE (go-kure/.github#60/#61 round 2
      # fold-in): exercises the salvage pass and the bounded retry added
      # around the jq -c '.' parse in pr-review-threads.sh's chunk-review
      # loop. clean (default) is the pre-existing well-formed response.
      # prose wraps well-formed JSON in commentary on both sides — no braces
      # missing, salvageable without ever needing the retry (fact 3 in the
      # incident record: launcher#283 run 32175849548, a chattier generation
      # wraps the JSON object in prose). garbage has no '{'/'}' at all —
      # unsalvageable, and stays garbage on the retry too, every call.
      # garbage_then_clean is garbage only on call 1 (mc<=1); the retry
      # (call 2) gets clean JSON, proving the retry path actually runs and
      # not just that it's accepted in principle.
      case "${PRT_TEST_MODEL_RESPONSE_MODE:-clean}" in
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
        *)
          printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[]}"}}]}' > "$out"
          ;;
      esac
      echo 200
      ;;
    */issues/*/comments)
      printf '%s' '{"id":1}' > "$out"
      echo 200
      ;;
    */graphql)
      _prt_test_bump "${PRT_TEST_GRAPHQL_COUNTFILE:?}" >/dev/null
      case "$data" in
        *reviewThreads*)
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
          # meta fetch (:125) and every later freshness re-check (gh.sh:114)
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
  echo 0 > "$PRT_TEST_GRAPHQL_COUNTFILE"
  echo 0 > "$PRT_TEST_PATCH_COUNTFILE"
  echo 0 > "$PRT_TEST_RESOLVE_COUNTFILE"
  : > "$PRT_TEST_STDOUT_FILE"
  : > "$PRT_TEST_STDERR_FILE"
  (
    cd "$scratch" && \
    PRT_CURL=fake_curl_orchestrator \
    PRT_TEST_DIFF_COUNTFILE="$PRT_TEST_DIFF_COUNTFILE" \
    PRT_TEST_META_COUNTFILE="$PRT_TEST_META_COUNTFILE" \
    PRT_TEST_MODEL_COUNTFILE="$PRT_TEST_MODEL_COUNTFILE" \
    PRT_TEST_GRAPHQL_COUNTFILE="$PRT_TEST_GRAPHQL_COUNTFILE" \
    PRT_TEST_PATCH_COUNTFILE="$PRT_TEST_PATCH_COUNTFILE" \
    PRT_TEST_RESOLVE_COUNTFILE="$PRT_TEST_RESOLVE_COUNTFILE" \
    PRT_TEST_DIFF_FAIL_TIMES="$diff_fail" \
    PRT_TEST_META_FAIL_TIMES="$meta_fail" \
    PRT_TEST_MODEL_ALWAYS_FAIL="$model_fail" \
    PRT_TEST_EMPTY_DIFF="${PRT_TEST_EMPTY_DIFF:-0}" \
    PRT_TEST_FIRST_ABSENT_SHA="${PRT_TEST_FIRST_ABSENT_SHA:-}" \
    PRT_TEST_OWNED_FP="${PRT_TEST_OWNED_FP:-deadbeefcafebabe}" \
    PRT_TEST_MODEL_RESPONSE_MODE="${PRT_TEST_MODEL_RESPONSE_MODE:-clean}" \
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
PRT_TEST_GRAPHQL_COUNTFILE="$(mktemp)"
PRT_TEST_PATCH_COUNTFILE="$(mktemp)"
PRT_TEST_RESOLVE_COUNTFILE="$(mktemp)"
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
assert_eq "orchestrator: garbage on original + retry -> REVIEW_INCOMPLETE carries retry=true, salvage_attempted=true, and a leading-char shape class" \
  "true" "$(grep -qE 'REVIEW_INCOMPLETE:.*retry=true, salvage_attempted=true \(len=[0-9]+ leading=starts-with-prose\)' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"
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

# Case 3a — permanent metadata-fetch failure (F3): every attempt (matching
# prt_retry 3's own attempt count) returns 502, unlike meta_fail=1 below
# which only ever exercises the transient-then-success retry path.
rc="$(run_orchestrator advisory 0 3 0)"
assert_eq "orchestrator: PR-metadata fetch failing all 3 attempts exits 1" "1" "$rc"
assert_eq "orchestrator: permanent metadata-fetch failure — stderr carries the Step 3a ERROR line" \
  "true" "$(grep -qF 'ERROR: failed to fetch PR metadata' "$PRT_TEST_STDERR_FILE" && echo true || echo false)"

# PRT_MODE=off must short-circuit before any curl call at all (:93-99, ahead
# of the diff fetch at :103) — proven here by wiring in settings that would
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

rm -f "$PRT_TEST_DIFF_COUNTFILE" "$PRT_TEST_META_COUNTFILE" "$PRT_TEST_MODEL_COUNTFILE" \
      "$PRT_TEST_GRAPHQL_COUNTFILE" "$PRT_TEST_PATCH_COUNTFILE" "$PRT_TEST_RESOLVE_COUNTFILE" \
      "$PRT_TEST_STDOUT_FILE" "$PRT_TEST_STDERR_FILE"

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
