#!/usr/bin/env bash
# release-publish-build-cache-test.sh — the Test job of Release / Publish restores the build cache
# that CI warms on main (go-kure/.github#289).
#
# The Test job ran cold: setup-go keyed its cache on the Go version and go.sum, restored a 7 KB
# entry for good and never saved a larger one. The job now turns that cache off and restores the
# source-aware build cache that the CI test jobs of kure and launcher save on main. This test
# asserts these facts about the Test job in .github/workflows/release-publish.yml:
#   1. setup-go has its own cache off,
#   2. one actions/cache/restore step restores ~/.cache/go-build,
#   3. its key and its restore keys use the name that the CI test jobs save under,
#   4. the job never saves a cache (only main writes the shared cache).
# Each assertion also runs against a mutated copy that must fail, so a check that agrees with
# everything is caught.
#
# Usage: release-publish-build-cache-test.sh [REPO_ROOT]

# shellcheck disable=SC2016  # the single-quoted ${{ }} strings are GitHub expressions, not shell
set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
WF="$ROOT/.github/workflows/release-publish.yml"

failures=0
pass_count=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The keys that the CI test jobs of kure and launcher save under, as one line each.
KEY_NAME='${{ runner.os }}-${{ runner.arch }}-go-${{ steps.go-version.outputs.version }}-gocache-test-race-cover-'
KEY_DEPS="${KEY_NAME}deps-\${{ hashFiles('go.mod', 'go.sum') }}-"
KEY_EXACT="${KEY_DEPS}src-\${{ hashFiles('**/*.go', 'go.mod', 'go.sum', 'Makefile', '**/testdata/**') }}"

# test_job FILE — the lines of the "test:" job: from "  test:" up to the next job at the same indent.
test_job() {
  awk '
    /^  test:[[:space:]]*(#.*)?$/ { in_job = 1; print; next }
    in_job && (/^[^ #]/ || /^  [^ #]/) { exit }
    in_job { print }
  ' "$1"
}

# restore_step — read a job on stdin, print the step that uses actions/cache/restore: from its "- "
# line up to the next step at the same indent.
restore_step() {
  awk '
    /^      - / { if (found) exit; step = "" }
    { step = step $0 "\n" }
    /^ +(- )?uses: actions\/cache\/restore@/ { found = 1 }
    END { if (found) printf "%s", step }
  '
}

# contract FILE — print one FAIL line per broken fact, return 1 if any.
contract() {
  local f="$1" rc=0 job trimmed want_tiers have_tiers
  if [ ! -s "$f" ]; then
    echo "FAIL: $f is missing or empty"
    return 1
  fi
  job="$(test_job "$f")"
  if [ -z "$job" ]; then
    echo "FAIL: no test job in $f"
    return 1
  fi
  if ! grep -qE '^ +cache: false$' <<<"$job"; then
    echo "FAIL: setup-go in the test job does not turn its own cache off"
    rc=1
  fi
  if grep -qE '^ +cache: true$' <<<"$job"; then
    echo "FAIL: the test job still turns on the cache of setup-go"
    rc=1
  fi
  if ! grep -qE '^ +(- )?uses: actions/cache/restore@' <<<"$job"; then
    echo "FAIL: the test job has no actions/cache/restore step"
    rc=1
  fi
  # The inputs below are read from the restore step's own lines: the action ignores a
  # misspelled input, and a matching line elsewhere in the job proves nothing.
  # shellcheck disable=SC2001  # the substitution must run on every line, which ${var//} cannot do
  trimmed="$(restore_step <<<"$job" | sed 's/^ *//')"
  if ! grep -Fxq 'path: ~/.cache/go-build' <<<"$trimmed"; then
    echo "FAIL: the restore step does not restore ~/.cache/go-build"
    rc=1
  fi
  if ! grep -Fxq "key: ${KEY_EXACT}" <<<"$trimmed"; then
    echo "FAIL: the restore key is not the key the CI test jobs save (OS, architecture, Go version, dependency hash and source hash)"
    rc=1
  fi
  # The lines after "restore-keys: |" must be exactly the two tiers, in that order.
  want_tiers="$(printf '%s\n%s' "${KEY_DEPS}" "${KEY_NAME}")"
  have_tiers="$(awk '/^restore-keys: \|$/ { in_keys = 1; next } in_keys && NF { print }' <<<"$trimmed")"
  if [ "$have_tiers" != "$want_tiers" ]; then
    echo "FAIL: the restore-keys input of the restore step is not the dependency tier followed by the cache name tier"
    rc=1
  fi
  if grep -qE '^ +(- )?uses: actions/cache(/save)?@' <<<"$job"; then
    echo "FAIL: the test job saves a cache; only main writes the shared cache"
    rc=1
  fi
  return "$rc"
}

expect_pass() {
  local name="$1" out
  shift
  if out="$(contract "$@")"; then
    pass_count=$((pass_count + 1))
    echo "PASS  $name"
  else
    echo "FAIL: $name: expected a pass, got:"
    echo "$out"
    failures=$((failures + 1))
  fi
}

# expect_fail NAME WANTED_TEXT FILE
expect_fail() {
  local name="$1" want="$2" out
  shift 2
  if out="$(contract "$@")"; then
    echo "FAIL: $name: expected a failure, got a pass"
    failures=$((failures + 1))
  elif ! grep -qF -- "$want" <<<"$out"; then
    echo "FAIL: $name: expected '$want', got:"
    echo "$out"
    failures=$((failures + 1))
  else
    pass_count=$((pass_count + 1))
    echo "PASS  $name"
  fi
}

expect_pass "release-publish.yml restores the build cache in the test job" "$WF"

# setup-go turns its cache back on.
sed '0,/^          cache: false$/s//          cache: true/' "$WF" > "$tmp/cache-true"
expect_fail "setup-go with its own cache on" "still turns on the cache of setup-go" "$tmp/cache-true"

# The restore step goes: its uses line becomes a no-op step name.
sed 's#uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 \# v6#run: true#' "$WF" > "$tmp/no-restore"
expect_fail "no actions/cache/restore step" "no actions/cache/restore step" "$tmp/no-restore"

# The restore reads another path.
sed 's#path: ~/.cache/go-build#path: ~/go/pkg/mod#' "$WF" > "$tmp/other-path"
expect_fail "a restore of another path" "does not restore ~/.cache/go-build" "$tmp/other-path"

# The key names another cache.
sed 's#gocache-test-race-cover#gocache-validate#g' "$WF" > "$tmp/other-name"
expect_fail "a key that names another cache" "restore key is not the key the CI test jobs save" "$tmp/other-name"

# The dependency tier of the restore keys goes.
awk '/-gocache-test-race-cover-deps-.*-$/ && !/key:/ { next } { print }' "$WF" > "$tmp/no-deps-tier"
expect_fail "no restore key at the dependency hash" "restore-keys input of the restore step" "$tmp/no-deps-tier"

# The name tier of the restore keys goes.
awk '/-gocache-test-race-cover-$/ { next } { print }' "$WF" > "$tmp/no-name-tier"
expect_fail "no restore key at the cache name" "restore-keys input of the restore step" "$tmp/no-name-tier"

# The job gains a save step.
awk '
  /^  validate:$/ && !done {
    print "      - uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6"
    print "        with:"
    print "          path: ~/.cache/go-build"
    print ""
    done = 1
  }
  { print }
' "$WF" > "$tmp/with-save"
expect_fail "a save step in the test job" "the test job saves a cache" "$tmp/with-save"

# The OS part of every key is wrong.
sed 's#\${{ runner.os }}#WrongOS#g' "$WF" > "$tmp/wrong-os"
expect_fail "a key with the wrong OS" "restore key is not the key the CI test jobs save" "$tmp/wrong-os"

# A hash expression matches no file.
sed "s#hashFiles('go.mod', 'go.sum')#hashFiles('nonexistent')#g" "$WF" > "$tmp/wrong-hash"
expect_fail "a key with a dependency hash of nothing" "restore key is not the key the CI test jobs save" "$tmp/wrong-hash"

# The source hash covers other files.
sed "s#hashFiles('\*\*/\*.go', #hashFiles(#" "$WF" > "$tmp/wrong-src"
expect_fail "a key with a source hash that skips Go files" "restore key is not the key the CI test jobs save" "$tmp/wrong-src"

# The restore moves into a later job whose name holds a digit.
awk '
  /- name: Restore Go build cache/ && !done {
    print "  extra2:"
    print "    runs-on: ubuntu-latest"
    print "    steps:"
    done = 1
  }
  { print }
' "$WF" > "$tmp/other-job"
expect_fail "a restore that sits in another job" "no actions/cache/restore step" "$tmp/other-job"

# The same move, with a comment or trailing spaces after the job name.
sed 's/^  extra2:$/  extra2: # later job/' "$tmp/other-job" > "$tmp/other-job-comment"
expect_fail "a restore in a job whose header has a comment" "no actions/cache/restore step" "$tmp/other-job-comment"
sed 's/^  extra2:$/  extra2:   /' "$tmp/other-job" > "$tmp/other-job-spaces"
expect_fail "a restore in a job whose header has trailing spaces" "no actions/cache/restore step" "$tmp/other-job-spaces"

# The restore-keys input is misspelled, so the action ignores it.
sed 's/^\( *\)restore-keys: |$/\1restore-key: |/' "$WF" > "$tmp/misspelled-restore-keys"
expect_fail "a misspelled restore-keys input" "restore-keys input of the restore step" "$tmp/misspelled-restore-keys"

# The key lines sit in a step that is not the restore step.
awk '
  /^ +restore-keys: \|$/ && !done { print "      - name: Other"; print "        run: true"; done = 1 }
  { print }
' "$WF" > "$tmp/keys-in-other-step"
expect_fail "restore keys that sit in another step" "restore-keys input of the restore step" "$tmp/keys-in-other-step"

: > "$tmp/empty"
expect_fail "an empty workflow file" "missing or empty" "$tmp/empty"

if [ "$failures" -eq 0 ]; then
  echo "release-publish-build-cache-test: OK ($pass_count cases)"
  exit 0
fi
echo "release-publish-build-cache-test: FAILED ($failures failed, $pass_count passed)"
exit 1
