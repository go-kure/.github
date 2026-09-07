#!/usr/bin/env bash
# review-adapter-test.sh — end-to-end tests for scripts/eval/review-adapter.sh.
#
# The adapter is the evaluation harness's `chat` engine: it drives the real
# scripts/lib/prt/* code path and the real model-proxy protocol. Only the proxy
# itself is mocked, via PRT_CURL pointed at a script on disk — model.sh:8-13
# requires a real executable there, not a shell function, because the call
# happens inside a command substitution in a separate process.
#
# Usage: review-adapter-test.sh [REPO_ROOT]

set -uo pipefail  # not -e: report every assertion, not just the first failure

# Both of these are checked explicitly because `set -e` is off above: an unchecked failure
# leaves the variable empty and every path built from it silently reroots at `/`.
ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)" || { echo "no such directory: ${1:-.}" >&2; exit 2; }
ADAPTER="$ROOT/scripts/eval/review-adapter.sh"
[ -f "$ADAPTER" ] || { echo "not found: $ADAPTER" >&2; exit 2; }

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

# Checked before the trap is installed, so a failed mktemp cannot leave the trap holding an
# empty path -- and so no fixture below is written to `/sample.diff` or `/stub`.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/review-adapter-test.XXXXXX")" \
  || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/sample.diff" <<'DIFF'
diff --git a/handler.go b/handler.go
index 1111111..2222222 100644
--- a/handler.go
+++ b/handler.go
@@ -10,3 +10,4 @@ func Handle(r *Request) error {
 	cfg, err := Load(r.Path)
+	return cfg.Apply()
 }
DIFF

# The curl stub. It receives the real argv (…-o RESPONSE_FILE… -d @REQUEST_FILE),
# wraps the Nth reply body in a chat-completions envelope at the -o path and prints
# an HTTP status, exactly as curl does. Reply bodies come from files so no test has
# to embed shell inside a generated script:
#   STUB_DIR/reply-1, reply-2, …  the model `content` string for each successive call
#   STUB_DIR/calls                call counter, written back after each call
#   STUB_HTTP                     status to print (default 200)
#   STUB_EXIT                     when non-zero, exit with it and write nothing
cat > "$WORK/curl-stub" <<'STUB'
#!/usr/bin/env bash
set -u
out=
prev=
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done

if [ "${STUB_EXIT:-0}" -ne 0 ]; then
  echo "${STUB_HTTP:-000}"
  exit "$STUB_EXIT"
fi

n=$(cat "$STUB_DIR/calls" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$STUB_DIR/calls"

reply="$STUB_DIR/reply-$n"
[ -f "$reply" ] || reply="$STUB_DIR/reply-1"

jq -n --rawfile c "$reply" '{choices: [{message: {content: $c}}]}' > "$out"
echo "${STUB_HTTP:-200}"
STUB
chmod +x "$WORK/curl-stub"

STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR"

REVIEW_JSON='{"findings":[{"file":"handler.go","category":"unchecked-err","line":11,"severity":"high","issue":"err is discarded","fix":"return err"}]}'

# reset_stub — clear the call counter and every canned reply from the last case.
reset_stub() {
  rm -f "$STUB_DIR"/reply-* "$STUB_DIR/calls"
}

run_adapter() {
  STUB_DIR="$STUB_DIR" PRT_CURL="$WORK/curl-stub" PRT_PROXY_URL=http://stub \
    bash "$ADAPTER" --diff "$WORK/sample.diff" --title "test PR" "$@" 2>"$WORK/err"
}

# --- happy path: findings survive normalize and carry a fingerprint ---
reset_stub
printf '%s' "$REVIEW_JSON" > "$STUB_DIR/reply-1"
out="$(run_adapter)"
rc=$?
assert_eq "happy path: exit 0" "0" "$rc"
assert_eq "happy path: one finding" "1" "$(jq '.findings | length' <<<"$out")"
assert_eq "happy path: engine is chat" "chat" "$(jq -r .engine <<<"$out")"
assert_eq "happy path: file preserved" "handler.go" "$(jq -r '.findings[0].file' <<<"$out")"
assert_eq "happy path: line preserved as a number" "11" "$(jq -r '.findings[0].line' <<<"$out")"
assert_eq "happy path: fingerprint assigned" "true" \
  "$(jq -r '.findings[0].fp | (type == "string" and (length == 16))' <<<"$out")"
assert_eq "happy path: no degradation recorded" "0" "$(jq '.degraded | length' <<<"$out")"

# The adapter must not invent keys downstream would silently drop: normalize rebuilds
# every row as exactly these six, plus the identity pair prt_assign_ordinals adds.
assert_eq "shape: exactly the normalized keys plus fp/collision" \
  "category collision file fix fp issue line severity" \
  "$(jq -r '.findings[0] | keys | join(" ")' <<<"$out")"

# --- assess pass: the verdict must join back onto the finding by fp ---
fp="$(jq -r '.findings[0].fp' <<<"$out")"
reset_stub
printf '%s' "$REVIEW_JSON" > "$STUB_DIR/reply-1"
jq -nc --arg fp "$fp" \
  '{assessments: [{fp: $fp, verdict: "FALSE_POSITIVE", reasoning: "cfg is checked below"}]}' \
  > "$STUB_DIR/reply-2"
assessed="$(run_adapter --assess)"
assert_eq "assess: verdict joined by fp" "FALSE_POSITIVE" \
  "$(jq -r '.findings[0].verdict' <<<"$assessed")"
assert_eq "assess: two proxy calls made" "2" "$(cat "$STUB_DIR/calls")"

# --- prose-wrapped JSON is salvaged, not lost ---
reset_stub
printf 'Here is my review:\n%s\nHope that helps.\n' "$REVIEW_JSON" > "$STUB_DIR/reply-1"
salvaged="$(run_adapter)"
assert_eq "salvage: prose-wrapped findings recovered" "1" \
  "$(jq '.findings | length' <<<"$salvaged")"

# --- a total transport failure is exit 1, never a clean empty review ---
reset_stub
printf '%s' "$REVIEW_JSON" > "$STUB_DIR/reply-1"
failed="$(STUB_EXIT=22 run_adapter)"
rc=$?
assert_eq "total failure: exit 1" "1" "$rc"
assert_eq "total failure: prints no findings document" "" "$failed"

# --- an empty findings array is a legitimate review, not a failure ---
reset_stub
printf '%s' '{"findings":[]}' > "$STUB_DIR/reply-1"
empty="$(run_adapter)"
rc=$?
assert_eq "clean empty: exit 0" "0" "$rc"
assert_eq "clean empty: zero findings" "0" "$(jq '.findings | length' <<<"$empty")"

# --- a malformed row is dropped and the run is marked degraded, not failed ---
reset_stub
printf '%s' '{"findings":[{"file":"handler.go","category":"unchecked-err","line":11,"severity":"high","issue":"i","fix":"f"},{"file":42}]}' \
  > "$STUB_DIR/reply-1"
mixed="$(run_adapter)"
rc=$?
assert_eq "mixed rows: exit 0" "0" "$rc"
assert_eq "mixed rows: only the valid row survives" "1" "$(jq '.findings | length' <<<"$mixed")"
assert_eq "mixed rows: degradation recorded" "1" "$(jq '.degraded | length' <<<"$mixed")"

# --- an unknown category is clamped to the closed enum, not passed through ---
reset_stub
printf '%s' '{"findings":[{"file":"handler.go","category":"made-up","line":11,"severity":"high","issue":"i","fix":"f"}]}' \
  > "$STUB_DIR/reply-1"
clamped="$(run_adapter)"
assert_eq "category: unknown value clamped to other" "other" \
  "$(jq -r '.findings[0].category' <<<"$clamped")"

# --- a diff that splits into no chunk is a setup fault (exit 2), not an empty review ---
# prt_split_diff answers `0` with exit 0 here, so the review loop never runs; without the
# guard the adapter would exit 0 with `findings: []` from a reviewer that was never called.
# A canned reply is staged deliberately: if a call were made, the assertions below would see
# a populated document rather than an ambiguous empty one.
reset_stub
printf '%s' "$REVIEW_JSON" > "$STUB_DIR/reply-1"
: > "$WORK/nochunk.diff"
nochunk="$(STUB_DIR="$STUB_DIR" PRT_CURL="$WORK/curl-stub" PRT_PROXY_URL=http://stub \
  bash "$ADAPTER" --diff "$WORK/nochunk.diff" --title "test PR" 2>"$WORK/err")"
rc=$?
assert_eq "no chunks: exit 2 (setup fault, not an exclusion)" "2" "$rc"
assert_eq "no chunks: prints no findings document" "" "$nochunk"
assert_eq "no chunks: made no proxy call" "0" "$(cat "$STUB_DIR/calls" 2>/dev/null || echo 0)"

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
