#!/usr/bin/env bash
# judge-test.sh — tests for scripts/eval/judge.sh's judge_once retry and failure-reason
# recording (go-kure/.github#179).
#
# Same PRT_CURL-stub pattern as review-adapter-test.sh: a real executable on disk, since
# _prt_call_proxy runs it inside a command substitution in a separate process.
#
# Usage: judge-test.sh [REPO_ROOT]

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)" || { echo "no such directory: ${1:-.}" >&2; exit 2; }
JUDGE="$ROOT/scripts/eval/judge.sh"
[ -f "$JUDGE" ] || { echo "not found: $JUDGE" >&2; exit 2; }

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

assert_match() {
  local desc="$1" pattern="$2" actual="$3"
  if [[ "$actual" == *"$pattern"* ]]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected to find [$pattern] in [$actual]" >&2
    failures=$((failures + 1))
  fi
}

assert_not_match() {
  local desc="$1" pattern="$2" actual="$3"
  if [[ "$actual" != *"$pattern"* ]]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — did not expect to find [$pattern] in [$actual]" >&2
    failures=$((failures + 1))
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/judge-test.XXXXXX")" \
  || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# One gold row and one same-file finding: the only shape that reaches stage 2 at all.
cat > "$WORK/gold.json" <<'JSON'
{"repo":"x","pr":1,"head_sha":"abc","base_sha":"def",
 "gold":[{"file":"handler.go","lines":[10,12],"note":"err is discarded","confirmed":true}]}
JSON
cat > "$WORK/findings.json" <<'JSON'
{"findings":[{"file":"handler.go","line":11,"issue":"err is discarded","fix":"return err","fp":"abc123"}]}
JSON

# The curl stub — identical contract to review-adapter-test.sh's.
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

if [ -f "$STUB_DIR/exit-$n" ]; then
  echo "${STUB_HTTP:-000}"
  exit "$(cat "$STUB_DIR/exit-$n")"
fi

reply="$STUB_DIR/reply-$n"
[ -f "$reply" ] || reply="$STUB_DIR/reply-1"

jq -n --rawfile c "$reply" '{choices: [{message: {content: $c}}]}' > "$out"
echo "${STUB_HTTP:-200}"
STUB
chmod +x "$WORK/curl-stub"

STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR"

reset_stub() {
  rm -f "$STUB_DIR"/reply-* "$STUB_DIR"/exit-* "$STUB_DIR/calls"
}

run_judge() {
  STUB_DIR="$STUB_DIR" PRT_CURL="$WORK/curl-stub" PRT_PROXY_URL=http://stub \
    bash "$JUDGE" --findings "$WORK/findings.json" --gold "$WORK/gold.json" \
    2>"$WORK/err"
}

# --- happy path: both position orders agree, one call each ---
reset_stub
printf '%s' '{"same": true}' > "$STUB_DIR/reply-1"
printf '%s' '{"same": true}' > "$STUB_DIR/reply-2"
out="$(run_judge)"
rc=$?
assert_eq "happy path: exit 0" "0" "$rc"
assert_eq "happy path: matched" "1" "$(jq -r .matched <<<"$out")"
assert_eq "happy path: judge_calls is 2, not a hardcoded pair count" "2" \
  "$(jq -r .judge_calls <<<"$out")"

# --- a not-json reply on order 1's first attempt recovers on the internal retry ---
#
# This is also the regression case for the _JUDGE_ONCE_CALLS-via-file fix: each call site is
# `v1=$(judge_once ...)`, a command substitution, so a plain variable judge_once sets is gone
# the instant that subshell exits. If judge_calls silently fell back to +1 per call site
# instead of the real per-attempt count, this assertion is the one that would have caught it —
# 3 raw proxy calls happened (order 1: 2 attempts, order 2: 1), and judge_calls must say so.
reset_stub
printf '%s' 'not json at all' > "$STUB_DIR/reply-1"
printf '%s' '{"same": true}' > "$STUB_DIR/reply-2"
printf '%s' '{"same": true}' > "$STUB_DIR/reply-3"
retried="$(run_judge)"
rc=$?
assert_eq "retry recovers: exit 0" "0" "$rc"
assert_eq "retry recovers: matched" "1" "$(jq -r .matched <<<"$retried")"
assert_eq "retry recovers: 3 raw proxy calls were made" "3" "$(cat "$STUB_DIR/calls")"
assert_eq "retry recovers: judge_calls reflects all 3, not one per call site" "3" \
  "$(jq -r .judge_calls <<<"$retried")"

# --- both attempts unparseable: exhausted after one retry, reason is "not-json" ---
reset_stub
printf '%s' 'still not json' > "$STUB_DIR/reply-1"
printf '%s' 'still not json either' > "$STUB_DIR/reply-2"
failed="$(run_judge)"
rc=$?
assert_eq "not-json exhausted: exit 1" "1" "$rc"
assert_eq "not-json exhausted: prints no partial verdict" "" "$failed"
assert_eq "not-json exhausted: made exactly 2 calls (bounded to one retry)" "2" \
  "$(cat "$STUB_DIR/calls")"
assert_match "not-json exhausted: reason recorded" "not-json:" "$(cat "$WORK/err")"
assert_match "not-json exhausted: reason is a shape summary" "len=" "$(cat "$WORK/err")"
# The standing "never log raw model responses" rule (docs/pr-review-threads.md "Failure
# surface") applies here too: A/B are a finding's and a gold row's own defect text.
assert_not_match "not-json exhausted: raw response text is not logged" "still not json either" \
  "$(cat "$WORK/err")"

# --- a well-formed non-object reply is its own distinct reason, not folded into not-json ---
reset_stub
printf '%s' '[1,2,3]' > "$STUB_DIR/reply-1"
printf '%s' '[4,5,6]' > "$STUB_DIR/reply-2"
notobj="$(run_judge)"
rc=$?
assert_eq "not-object exhausted: exit 1" "1" "$rc"
assert_eq "not-object exhausted: prints no partial verdict" "" "$notobj"
assert_match "not-object exhausted: reason recorded" "not-object:" "$(cat "$WORK/err")"

# --- a well-formed object with no boolean .same is its own distinct reason ---
reset_stub
printf '%s' '{"verdict":"maybe"}' > "$STUB_DIR/reply-1"
printf '%s' '{"verdict":"still maybe"}' > "$STUB_DIR/reply-2"
noboolean="$(run_judge)"
rc=$?
assert_eq "no-boolean-same exhausted: exit 1" "1" "$rc"
assert_eq "no-boolean-same exhausted: prints no partial verdict" "" "$noboolean"
assert_match "no-boolean-same exhausted: reason recorded" "no-boolean-same:" "$(cat "$WORK/err")"

# --- disagreement across the position swap is scored as no match, at the cost of both calls ---
reset_stub
printf '%s' '{"same": true}' > "$STUB_DIR/reply-1"
printf '%s' '{"same": false}' > "$STUB_DIR/reply-2"
disagree="$(run_judge)"
rc=$?
assert_eq "disagreement: exit 0" "0" "$rc"
assert_eq "disagreement: no match" "0" "$(jq -r .matched <<<"$disagree")"
assert_eq "disagreement: still cost both calls" "2" "$(jq -r .judge_calls <<<"$disagree")"

# --- order 1 alone says no: order 2 is skipped entirely, at half the cost ---
reset_stub
printf '%s' '{"same": false}' > "$STUB_DIR/reply-1"
skip="$(run_judge)"
rc=$?
assert_eq "order1-no: exit 0" "0" "$rc"
assert_eq "order1-no: no match" "0" "$(jq -r .matched <<<"$skip")"
assert_eq "order1-no: only 1 call made" "1" "$(cat "$STUB_DIR/calls")"
assert_eq "order1-no: judge_calls is 1, not a hardcoded 2" "1" "$(jq -r .judge_calls <<<"$skip")"

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
