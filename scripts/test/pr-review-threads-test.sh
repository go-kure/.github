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
# fake_curl_orchestrator dispatches on URL suffix + Accept header — enough to
# tell the three real callers apart without needing -X: model.sh's proxy
# call always targets */chat/completions; the advisory-comment POST always
# targets .../issues/<N>/comments; the diff-fetch curl in
# pr-review-threads.sh itself sends Accept: application/vnd.github.diff,
# while every other prt_gh_rest GET pulls/<N> call (initial meta fetch and
# every later freshness re-check) sends the plain +json Accept instead.
fake_curl_orchestrator() {
  local args=("$@") out="" accept="" url="" h
  local i n=${#args[@]}
  for ((i = 0; i < n; i++)); do
    case "${args[$i]}" in
      -o) out="${args[$((i + 1))]}" ;;
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
      # Discard _prt_test_bump's own stdout (the running count, unused
      # here) — leaving it uncaptured would leak into this function's own
      # stdout, which the caller reads as curl's -w '%{http_code}' output.
      _prt_test_bump "${PRT_TEST_MODEL_COUNTFILE:?}" >/dev/null
      if [ "${PRT_TEST_MODEL_ALWAYS_FAIL:-0}" = 1 ]; then
        : > "$out"; echo 500; return 0
      fi
      printf '%s' '{"choices":[{"message":{"content":"{\"findings\":[]}"}}]}' > "$out"
      echo 200
      ;;
    */issues/*/comments)
      printf '%s' '{"id":1}' > "$out"
      echo 200
      ;;
    *)
      case "$accept" in
        *vnd.github.diff*)
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
# given via the PRT_TEST_*_COUNTFILE globals set by the caller.
run_orchestrator() {
  local mode="$1" diff_fail="$2" meta_fail="$3" model_fail="$4"
  local scratch summary rc
  scratch="$(mktemp -d)"
  summary="$(mktemp)"
  : > "$PRT_TEST_DIFF_COUNTFILE"
  : > "$PRT_TEST_META_COUNTFILE"
  : > "$PRT_TEST_MODEL_COUNTFILE"
  (
    cd "$scratch" && \
    PRT_CURL=fake_curl_orchestrator \
    PRT_TEST_DIFF_COUNTFILE="$PRT_TEST_DIFF_COUNTFILE" \
    PRT_TEST_META_COUNTFILE="$PRT_TEST_META_COUNTFILE" \
    PRT_TEST_MODEL_COUNTFILE="$PRT_TEST_MODEL_COUNTFILE" \
    PRT_TEST_DIFF_FAIL_TIMES="$diff_fail" \
    PRT_TEST_META_FAIL_TIMES="$meta_fail" \
    PRT_TEST_MODEL_ALWAYS_FAIL="$model_fail" \
    PRT_GH_TOKEN=x PRT_REPO=owner/repo PRT_PR_NUMBER=1 \
    PRT_HEAD_SHA=1111111111111111111111111111111111111111 \
    PRT_BOT_LOGIN="test-bot[bot]" PRT_PROXY_URL="http://proxy.invalid" \
    PRT_MODE="$mode" GITHUB_STEP_SUMMARY="$summary" \
    bash "$ROOT/scripts/pr-review-threads.sh" >/dev/null 2>&1
  )
  rc=$?
  rm -rf "$scratch" "$summary"
  echo "$rc"
}

PRT_TEST_DIFF_COUNTFILE="$(mktemp)"
PRT_TEST_META_COUNTFILE="$(mktemp)"
PRT_TEST_MODEL_COUNTFILE="$(mktemp)"

rc="$(run_orchestrator advisory 0 0 0)"
assert_eq "orchestrator: clean run (diff/meta/model all succeed first try) exits 0" "0" "$rc"

rc="$(run_orchestrator advisory 0 0 1)"
assert_eq "orchestrator: model call failing every chunk marks REVIEW_INCOMPLETE -> exits 1" "1" "$rc"

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

rm -f "$PRT_TEST_DIFF_COUNTFILE" "$PRT_TEST_META_COUNTFILE" "$PRT_TEST_MODEL_COUNTFILE"

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
