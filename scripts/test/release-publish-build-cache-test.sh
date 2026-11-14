#!/usr/bin/env bash
# release-publish-build-cache-test.sh — the Test job of Release / Publish restores the build cache
# that CI warms on main (go-kure/.github#289).
#
# The Test job ran cold: setup-go keyed its cache on the Go version and go.sum, restored a 7 KB
# entry for good and never saved a larger one. The job now turns that cache off and restores the
# source-aware build cache that the CI test jobs of kure and launcher save on main.
#
# The contract is one equality: the steps of the Test job from "Read Go version from mise.toml" to the
# end of the job, "Run tests" included, are exactly EXPECTED below. That fixes the Go version read, setup-go with its own
# cache off, one restore of ~/.cache/go-build with the three keys that CI saves under, no other
# input on the restore, no condition, the order, and the test step with its environment (a GOCACHE
# there would bypass the restored cache). One more fact is read beside it: the job holds
# no other cache step, because only main writes the shared cache. Comments, blank lines and the
# action pins (a Renovate bump) are not compared.
#
# Each case below changes one thing in a copy of the workflow and must fail.
#
# Usage: release-publish-build-cache-test.sh [REPO_ROOT]

# shellcheck disable=SC2016  # the single-quoted ${{ }} strings are GitHub expressions, not shell
set -uo pipefail  # not -e: report every case, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
WF="$ROOT/.github/workflows/release-publish.yml"

failures=0
pass_count=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

EXPECTED="$(
  cat <<'EOF'
      - name: Read Go version from mise.toml
        id: go-version
        run: |
          GO_VER=$(grep '^go = ' mise.toml | sed 's/go = "\(.*\)"/\1/')
          echo "version=$GO_VER" >> "$GITHUB_OUTPUT"
      - name: Set up Go
        uses: actions/setup-go@PIN
        with:
          go-version: ${{ steps.go-version.outputs.version }}
          cache: false
      - name: Restore Go build cache
        id: gocache
        uses: actions/cache/restore@PIN
        with:
          path: ~/.cache/go-build
          key: ${{ runner.os }}-${{ runner.arch }}-go-${{ steps.go-version.outputs.version }}-gocache-test-race-cover-deps-${{ hashFiles('go.mod', 'go.sum') }}-src-${{ hashFiles('**/*.go', 'go.mod', 'go.sum', 'Makefile', '**/testdata/**') }}
          restore-keys: |
            ${{ runner.os }}-${{ runner.arch }}-go-${{ steps.go-version.outputs.version }}-gocache-test-race-cover-deps-${{ hashFiles('go.mod', 'go.sum') }}-
            ${{ runner.os }}-${{ runner.arch }}-go-${{ steps.go-version.outputs.version }}-gocache-test-race-cover-
      - name: Log Go build cache restore
        run: |
          echo "cache-hit=${{ steps.gocache.outputs.cache-hit }}"
          echo "primary-key=${{ steps.gocache.outputs.cache-primary-key }}"
          echo "matched-key=${{ steps.gocache.outputs.cache-matched-key }}"
      - name: Run tests
        env:
          CGO_ENABLED: "1"
        run: go test -v -race -timeout 25m ./...
EOF
)"

# normal_job FILE — the lines of the "test:" job, without comments, blank lines and action pins.
# The job ends at the next line at job or top-level indent.
normal_job() {
  awk '
    /^  test:[[:space:]]*(#.*)?$/ { in_job = 1; next }
    in_job && (/^[^ #]/ || /^  [^ #]/) { exit }
    in_job { print }
  ' "$1" | grep -vE '^[[:space:]]*(#.*)?$' | sed -E 's/@[0-9a-f]{40} # v[0-9][0-9.]*$/@PIN/'
}

# contract FILE — print one FAIL line per broken fact, return 1 if any.
contract() {
  local f="$1" rc=0 job block
  if [ ! -s "$f" ]; then
    echo "FAIL: $f is missing or empty"
    return 1
  fi
  job="$(normal_job "$f")"
  if [ -z "$job" ]; then
    echo "FAIL: no test job in $f"
    return 1
  fi
  block="$(awk '/^      - name: Read Go version from mise.toml$/ { p = 1 } p' <<<"$job")"
  if [ "$block" != "$EXPECTED" ]; then
    echo "FAIL: the steps from the Go version read to the end of the job are not the expected ones"
    diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$block") | head -n 6
    rc=1
  fi
  if [ "$(grep -cE '^ +(- )?uses: actions/cache(/[a-z]+)?@' <<<"$job")" != 1 ]; then
    echo "FAIL: the test job has a cache step besides the one restore; only main writes the shared cache"
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

STEPS="the steps from the Go version read to the end of the job are not the expected"
CACHE="has a cache step besides the one restore"

expect_pass "release-publish.yml restores the build cache in the test job" "$WF"

# A new pin of an action is not a change of the contract.
sed -E 's/^(        uses: actions\/cache\/restore)@[0-9a-f]{40} # v6$/\1@0123456789abcdef0123456789abcdef01234567 # v7/' "$WF" > "$tmp/repin"
expect_pass "a new pin of the restore action" "$tmp/repin"

# One change per case, each inside the compared block.
sed '0,/^          cache: false$/s//          cache: true/' "$WF" > "$tmp/cache-true"
expect_fail "setup-go with its own cache on" "$STEPS" "$tmp/cache-true"

sed 's#uses: actions/cache/restore@[0-9a-f]\{40\} \# v6#run: true#' "$WF" > "$tmp/no-restore"
expect_fail "no restore step" "$STEPS" "$tmp/no-restore"

sed 's#path: ~/.cache/go-build#path: ~/go/pkg/mod#' "$WF" > "$tmp/other-path"
expect_fail "a restore of another path" "$STEPS" "$tmp/other-path"

sed 's#gocache-test-race-cover#gocache-validate#g' "$WF" > "$tmp/other-name"
expect_fail "a key that names another cache" "$STEPS" "$tmp/other-name"

sed 's#\${{ runner.os }}#WrongOS#g' "$WF" > "$tmp/wrong-os"
expect_fail "a key with the wrong OS" "$STEPS" "$tmp/wrong-os"

sed "s#hashFiles('go.mod', 'go.sum')#hashFiles('nonexistent')#g" "$WF" > "$tmp/wrong-hash"
expect_fail "a key with a dependency hash of nothing" "$STEPS" "$tmp/wrong-hash"

sed 's/^\( *\)restore-keys: |$/\1restore-key: |/' "$WF" > "$tmp/misspelled-restore-keys"
expect_fail "a misspelled restore-keys input" "$STEPS" "$tmp/misspelled-restore-keys"

sed 's/^\( *\)path: ~\/.cache\/go-build$/\1lookup-only: true\n&/' "$WF" > "$tmp/lookup-only"
expect_fail "a lookup-only restore" "$STEPS" "$tmp/lookup-only"

sed 's/^\( *\)path: ~\/.cache\/go-build$/\1fail-on-cache-miss: true\n&/' "$WF" > "$tmp/fail-on-miss"
expect_fail "a restore that fails on a cache miss" "$STEPS" "$tmp/fail-on-miss"

sed "s/^\( *\)id: gocache\$/&\n\1if: github.ref == 'refs\/heads\/main'/" "$WF" > "$tmp/restore-if"
expect_fail "a restore with a branch condition" "$STEPS" "$tmp/restore-if"

# The restore and its log step move below the step that runs the tests.
awk '
  /^      # setup-go.s own cache is off/ { hold = 1 }
  /^      # -timeout applies to each test binary/ { hold = 0 }
  hold { block = block $0 "\n"; next }
  { print }
  /run: go test/ { printf "\n%s", block }
' "$WF" > "$tmp/restore-after-tests"
expect_fail "a restore that runs after the tests" "$STEPS" "$tmp/restore-after-tests"

# The restore, its comment and its log step move above the Go version read.
awk '
  /^      # setup-go.s own cache is off/ { hold = 1 }
  /^      # -timeout applies to each test binary/ { hold = 0 }
  hold { block = block $0 "\n"; next }
  { lines[++n] = $0 }
  END {
    for (i = 1; i <= n; i++) {
      if (lines[i] ~ /^      - name: Read Go version from mise.toml$/) printf "%s", block
      print lines[i]
    }
  }
' "$WF" > "$tmp/restore-before-version"
expect_fail "a restore that runs before the Go version is read" "$STEPS" "$tmp/restore-before-version"

# A save step after the tests also trips the equality; the cache-step count names the reason.
awk '
  /^  validate:$/ && !done {
    print "      - uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6"
    print "        with:"
    print "          path: ~/.cache/go-build"
    print "          key: x"
    print ""
    done = 1
  }
  { print }
' "$WF" > "$tmp/with-save"
expect_fail "a save step after the tests" "$CACHE" "$tmp/with-save"

# The test step gets its own Go cache directory.
sed 's/^\( *\)CGO_ENABLED: "1"$/&\n\1GOCACHE: ${{ runner.temp }}\/go-build/' "$WF" > "$tmp/gocache-env"
expect_fail "a GOCACHE in the test step" "$STEPS" "$tmp/gocache-env"

# The restore moves into a later job, whose header carries a comment.
awk '
  /- name: Restore Go build cache/ && !done {
    print "  extra2: # later job"
    print "    runs-on: ubuntu-latest"
    print "    steps:"
    done = 1
  }
  { print }
' "$WF" > "$tmp/other-job"
expect_fail "a restore that sits in another job" "$STEPS" "$tmp/other-job"

: > "$tmp/empty"
expect_fail "an empty workflow file" "missing or empty" "$tmp/empty"

if [ "$failures" -eq 0 ]; then
  echo "release-publish-build-cache-test: OK ($pass_count cases)"
  exit 0
fi
echo "release-publish-build-cache-test: FAILED ($failures failed, $pass_count passed)"
exit 1
