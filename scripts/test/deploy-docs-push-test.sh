#!/usr/bin/env bash
# Tests for scripts/release/deploy-docs-push.sh
#
# Every case runs the real script against real git repositories under a
# temporary directory: a bare "source" remote carrying the release tags and the
# caller's clone of it, and a bare "pages" remote with the deploying clone and a
# second clone standing in for another slot's deploy. The root decision is the
# real publish-policy.sh next to the script; one case replaces it with a stub
# that prints neither true nor false.
#
# A rejected push is a real race, not a mock: a hook in the deploying clone lets
# the other slot's deploy land on the pages remote, either after this push has
# read the remote's tip (the remote refuses the update) or before it starts (git
# refuses it). A pre-receive hook on the pages remote stands in for a refusal
# that no retry can fix.
#
# No case covers an unresolvable policy pin: the action runs the policy that sits
# next to the script at the action's own commit, so there is no pin to resolve.
# A pin that does not resolve fails when the runner downloads the action, before
# any step runs.
#
# Needs git on PATH; no token and no network.
#
# Run: bash scripts/test/deploy-docs-push-test.sh .

set -uo pipefail # deliberately not -e: assertions continue past failures so one
                 # run reports every problem, not just the first.

ROOT="$(cd "${1:-.}" && pwd)"
SCRIPT="$ROOT/scripts/release/deploy-docs-push.sh"
POLICY="$ROOT/scripts/release/publish-policy.sh"

failures=0
pass_count=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    shift
    local line
    for line in "$@"; do printf '      %s\n' "$line" >&2; done
    failures=$((failures + 1))
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass_count=$((pass_count + 1))
    else
        fail "$label" "expected: $expected" "actual:   $actual"
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) pass_count=$((pass_count + 1)) ;;
        *) fail "$label" "expected to contain: $needle" "actual output:" "$haystack" ;;
    esac
}

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) fail "$label" "expected NOT to contain: $needle" "actual output:" "$haystack" ;;
        *) pass_count=$((pass_count + 1)) ;;
    esac
}

command -v git >/dev/null 2>&1 || { echo "deploy-docs-push-test: git is required on PATH" >&2; exit 1; }
for f in "$SCRIPT" "$POLICY"; do
    [ -f "$f" ] || { echo "deploy-docs-push-test: $f not found" >&2; exit 1; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" user.name "deploy-docs-push-test"
git config --file "$GIT_CONFIG_GLOBAL" user.email "deploy-docs-push-test@example.invalid"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" advice.detachedHead false

# ── Fixtures ──────────────────────────────────────────────────────────────

# new_case <name> <tag>...: $WORK/<name>/ with
#   source.git, srcwork   the caller's remote and a clone that pushes tags to it
#   source                the caller's checkout (tags as of now)
#   pages.git             the pages remote: kure/ root "root seed", slot kure/v1.1
#   target, other         the deploying clone, and another slot's deploy
#   build/slot, build/root  the builds for the slot and the root
new_case() {
    local d="$WORK/$1" tag
    shift
    mkdir -p "$d/build/slot" "$d/build/root"
    git init --quiet --bare "$d/source.git"
    git init --quiet "$d/srcwork"
    printf 'source\n' > "$d/srcwork/README"
    git -C "$d/srcwork" add -A
    git -C "$d/srcwork" commit --quiet -m "chore: initial"
    for tag in "$@"; do git -C "$d/srcwork" tag "$tag"; done
    git -C "$d/srcwork" remote add origin "$d/source.git"
    git -C "$d/srcwork" push --quiet origin main --tags
    git clone --quiet "$d/source.git" "$d/source"

    git init --quiet --bare "$d/pages.git"
    git init --quiet "$d/seed"
    mkdir -p "$d/seed/kure/v1.1" "$d/seed/launcher"
    printf 'root seed\n' > "$d/seed/kure/index.html"
    printf 'v1.1 seed\n' > "$d/seed/kure/v1.1/index.html"
    printf 'launcher seed\n' > "$d/seed/launcher/index.html"
    git -C "$d/seed" add -A
    git -C "$d/seed" commit --quiet -m "seed"
    git -C "$d/seed" push --quiet "$d/pages.git" main
    git clone --quiet "$d/pages.git" "$d/target"
    git clone --quiet "$d/pages.git" "$d/other"
}

# builds <name> <label>: the slot and root builds for <label>.
builds() {
    local d="$WORK/$1"
    printf 'slot %s\n' "$2" > "$d/build/slot/index.html"
    printf 'root %s\n' "$2" > "$d/build/root/index.html"
}

# push_tag <name> <tag>: a tag lands on the source remote, not in the caller's
# checkout.
push_tag() {
    local d="$WORK/$1"
    git -C "$d/srcwork" tag "$2"
    git -C "$d/srcwork" push --quiet origin "$2"
}

# racer <name> [hook]: a hook in the deploying clone. On each of the first
# RACE_LIMIT runs it lands another slot's deploy (kure/v9.<n>/) on the pages
# remote, and pushes RACE_TAG to the source remote when set. The default
# pre-push hook does this after the push has read the remote's tip, so the
# remote refuses the update (`remote rejected`, worded differently across git
# versions); a post-commit hook does it
# before the push starts, so git refuses it (`fetch first`). The count of runs
# is kept in <name>/push-count.
racer() {
    local d="$WORK/$1" hook="${2:-pre-push}"
    cat > "$d/target/.git/hooks/$hook" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${0##*/}" != pre-push ] || cat >/dev/null
unset $(git rev-parse --local-env-vars)
n=$(( $(cat "$RACE_DIR/push-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$RACE_DIR/push-count"
[ "$n" -le "$RACE_LIMIT" ] || exit 0
git -C "$RACE_DIR/other" fetch --quiet origin
git -C "$RACE_DIR/other" reset --quiet --hard origin/main
mkdir -p "$RACE_DIR/other/kure/v9.$n"
echo "other $n" > "$RACE_DIR/other/kure/v9.$n/index.html"
git -C "$RACE_DIR/other" add -A
git -C "$RACE_DIR/other" commit --quiet -m "deploy: other slot $n"
git -C "$RACE_DIR/other" push --quiet origin HEAD:main
# With RACE_FETCH set, the deploying clone learns the other deploy's commit,
# so git refuses the push as non-fast-forward rather than fetch first.
[ -z "${RACE_FETCH:-}" ] || git -C "$RACE_DIR/target" fetch --quiet origin
if [ -n "${RACE_TAG:-}" ]; then
    git -C "$RACE_DIR/srcwork" tag "$RACE_TAG"
    git -C "$RACE_DIR/srcwork" push --quiet origin "$RACE_TAG"
fi
EOF
    chmod +x "$d/target/.git/hooks/$hook"
}

# deploy <name> <slot> <label> <set_latest> [extra args...]: runs the script as
# the action does, with no backoff and at most 3 attempts; sets OUT and RC.
# SCRIPT_UNDER_TEST overrides which copy runs.
deploy() {
    local d="$WORK/$1" slot="$2" label="$3" set_latest="$4"
    shift 4
    OUT=$(RACE_DIR="$d" RACE_LIMIT="${RACE_LIMIT:-0}" RACE_TAG="${RACE_TAG:-}" RACE_FETCH="${RACE_FETCH:-}" \
        bash "${SCRIPT_UNDER_TEST:-$SCRIPT}" --source "$d/source" --target "$d/target" \
        --site-subdir kure --slot "$slot" --label "$label" --set-latest "$set_latest" \
        --slot-site "$d/build/slot" --root-site "$d/build/root" \
        --max-attempts 3 --backoff 0 "$@" 2>&1)
    RC=$?
}

pages_file() {  # pages_file <name> <path>: the file on the pages remote's main
    git -C "$WORK/$1/pages.git" show "main:$2" 2>/dev/null
}
pages_tip() {  # pages_tip <name>: the pages remote's main OID
    git -C "$WORK/$1/pages.git" rev-parse main
}
pages_subject() {  # pages_subject <name>: the subject of the pages remote's tip
    git -C "$WORK/$1/pages.git" log -1 --format=%s main
}

# ── 1. still the highest stable tag: slot and root ────────────────────────

new_case latest v1.1.0 v1.2.0
builds latest v1.2.0
deploy latest v1.2 v1.2.0 true
assert_eq "still latest: exit 0" 0 "$RC"
assert_eq "still latest: the slot is written" "slot v1.2.0" "$(pages_file latest kure/v1.2/index.html)"
assert_eq "still latest: the root is written" "root v1.2.0" "$(pages_file latest kure/index.html)"
assert_eq "still latest: another slot is kept" "v1.1 seed" "$(pages_file latest kure/v1.1/index.html)"
assert_eq "still latest: another site is kept" "launcher seed" "$(pages_file latest launcher/index.html)"
assert_eq "still latest: CNAME" "www.gokure.dev" "$(pages_file latest CNAME)"
assert_eq "still latest: .nojekyll" "blob" "$(git -C "$WORK/latest/pages.git" cat-file -t main:.nojekyll 2>/dev/null)"
assert_contains "still latest: the commit names the root" "$(pages_subject latest)" "+ /kure/ (latest) from kure@"

# The same deploy again finds nothing to change.
before=$(pages_tip latest)
deploy latest v1.2 v1.2.0 true
assert_eq "no changes: exit 0" 0 "$RC"
assert_contains "no changes: says so" "$OUT" "No changes to deploy"
assert_eq "no changes: nothing pushed" "$before" "$(pages_tip latest)"

# ── 2. a newer stable tag landed after Publish decided: slot only ─────────

new_case newer v1.1.0 v1.2.0
push_tag newer v1.3.0
builds newer v1.2.0
deploy newer v1.2 v1.2.0 true
assert_eq "newer tag: exit 0" 0 "$RC"
assert_eq "newer tag: the slot is written" "slot v1.2.0" "$(pages_file newer kure/v1.2/index.html)"
assert_eq "newer tag: the root is untouched" "root seed" "$(pages_file newer kure/index.html)"
assert_contains "newer tag: logs why" "$OUT" "left the /kure/ root untouched: v1.2.0 is no longer the highest stable tag"
assert_eq "newer tag: the tags were fetched into the source checkout" "v1.3.0" \
    "$(git -C "$WORK/newer/source" tag --list v1.3.0)"
assert_not_contains "newer tag: the commit does not name the root" "$(pages_subject newer)" "(latest)"

# ── 3. set_latest false: never the root, and no policy call ───────────────

new_case nolatest v1.1.0 v1.2.0
builds nolatest v1.2.0
deploy nolatest v1.2 v1.2.0 false
assert_eq "set_latest false: exit 0" 0 "$RC"
assert_eq "set_latest false: the slot is written" "slot v1.2.0" "$(pages_file nolatest kure/v1.2/index.html)"
assert_eq "set_latest false: the root is untouched although still latest" "root seed" \
    "$(pages_file nolatest kure/index.html)"
# `dev` is no release tag: the policy would fail on it, so a pass shows it is not run.
builds nolatest dev
deploy nolatest dev dev false --root-site "$WORK/nolatest/no-such-root"
assert_eq "set_latest false, dev: exit 0 without a root build" 0 "$RC"
assert_eq "set_latest false, dev: the slot is written" "slot dev" "$(pages_file nolatest kure/dev/index.html)"
assert_eq "set_latest false, dev: the release slot is kept" "slot v1.2.0" "$(pages_file nolatest kure/v1.2/index.html)"

# ── 4. a policy error fails the deploy, nothing pushed ────────────────────

new_case policyerr v1.1.0 v1.2.0
builds policyerr dev
before=$(pages_tip policyerr)
deploy policyerr dev dev true
assert_eq "policy error: exit 1" 1 "$RC"
assert_contains "policy error: names the failure" "$OUT" "publish-policy.sh latest 'dev' failed (exit 2)"
assert_eq "policy error: nothing pushed" "$before" "$(pages_tip policyerr)"

# A policy that prints neither true nor false is an error too.
mkdir -p "$WORK/stub"
cp "$SCRIPT" "$WORK/stub/deploy-docs-push.sh"
printf '#!/usr/bin/env bash\necho maybe\n' > "$WORK/stub/publish-policy.sh"
new_case stubbed v1.2.0
builds stubbed v1.2.0
before=$(pages_tip stubbed)
SCRIPT_UNDER_TEST="$WORK/stub/deploy-docs-push.sh" deploy stubbed v1.2 v1.2.0 true
assert_eq "policy prints neither: exit 1" 1 "$RC"
assert_contains "policy prints neither: names the output" "$OUT" "printed 'maybe', expected true or false"
assert_eq "policy prints neither: nothing pushed" "$before" "$(pages_tip stubbed)"

# ── 4b. the root is built only from the tag the label names ───────────────
# The policy ranks a well-formed label without checking that it is a tag, or
# that the source checkout is that tag (go-kure/.github#251). Case 1 is the
# control: a real tag at HEAD writes the root.

# A well-formed label that is no tag: the policy says true, the root is refused.
new_case notag v1.1.0 v1.2.0
builds notag v1.3.0
before=$(pages_tip notag)
deploy notag v1.3 v1.3.0 true
assert_eq "label not a tag: exit 1" 1 "$RC"
assert_contains "label not a tag: names the failure" "$OUT" "label 'v1.3.0' is not a tag in $WORK/notag/source; not writing the /kure/ root"
assert_eq "label not a tag: nothing pushed" "$before" "$(pages_tip notag)"

# The label is a tag, but the checkout is a later commit (a dispatch from main
# with the label of the latest release).
new_case offtag v1.1.0 v1.2.0
printf 'later\n' >> "$WORK/offtag/srcwork/README"
git -C "$WORK/offtag/srcwork" commit --quiet -am "feat: later"
git -C "$WORK/offtag/srcwork" push --quiet origin main
git -C "$WORK/offtag/source" pull --quiet origin main
builds offtag v1.2.0
before=$(pages_tip offtag)
deploy offtag v1.2 v1.2.0 true
head_full=$(git -C "$WORK/offtag/source" rev-parse HEAD)
tag_full=$(git -C "$WORK/offtag/source" rev-parse 'v1.2.0^{commit}')
assert_eq "HEAD not the tag: exit 1" 1 "$RC"
assert_contains "HEAD not the tag: names the mismatch" "$OUT" "HEAD ${head_full} is not tag v1.2.0's commit ${tag_full}; not writing the /kure/ root (dispatch with --ref v1.2.0)"
assert_eq "HEAD not the tag: nothing pushed" "$before" "$(pages_tip offtag)"

# set_latest false never reaches the check: the same checkout deploys its slot.
deploy offtag v1.2 v1.2.0 false
assert_eq "HEAD not the tag, set_latest false: exit 0" 0 "$RC"
assert_eq "HEAD not the tag, set_latest false: the slot is written" "slot v1.2.0" "$(pages_file offtag kure/v1.2/index.html)"
assert_eq "HEAD not the tag, set_latest false: the root is untouched" "root seed" "$(pages_file offtag kure/index.html)"

# A tag deleted on origin after the checkout: the checkout still has it, the
# pruning fetch drops it, and the root is refused as for a label that is no tag.
new_case deleted v1.1.0 v1.2.0
git -C "$WORK/deleted/srcwork" push --quiet origin :refs/tags/v1.2.0
builds deleted v1.2.0
before=$(pages_tip deleted)
assert_eq "tag deleted on origin: the checkout still has it (control)" "v1.2.0" "$(git -C "$WORK/deleted/source" tag --list v1.2.0)"
deploy deleted v1.2 v1.2.0 true
assert_eq "tag deleted on origin: exit 1" 1 "$RC"
assert_contains "tag deleted on origin: names the failure" "$OUT" "label 'v1.2.0' is not a tag in $WORK/deleted/source; not writing the /kure/ root"
assert_eq "tag deleted on origin: nothing pushed" "$before" "$(pages_tip deleted)"

# An annotated tag at HEAD peels to its commit: the root is written.
new_case annotated v1.1.0
git -C "$WORK/annotated/srcwork" tag -a v1.2.0 -m "release v1.2.0"
git -C "$WORK/annotated/srcwork" push --quiet origin v1.2.0
builds annotated v1.2.0
deploy annotated v1.2 v1.2.0 true
assert_eq "annotated tag at HEAD: exit 0" 0 "$RC"
assert_eq "annotated tag at HEAD: the root is written" "root v1.2.0" "$(pages_file annotated kure/index.html)"

# ── 5. one rejected push, then a retry that keeps the other slot ──────────

new_case retry v1.1.0 v1.2.0
builds retry v1.2.0
racer retry
RACE_LIMIT=1 deploy retry v1.2 v1.2.0 true
assert_eq "one rejection: exit 0" 0 "$RC"
assert_contains "one rejection: the rejection is reported" "$OUT" "push to main rejected (attempt 1/3)"
assert_eq "one rejection: two pushes" 2 "$(cat "$WORK/retry/push-count")"
assert_eq "one rejection: the other slot's deploy is kept" "other 1" "$(pages_file retry kure/v9.1/index.html)"
assert_eq "one rejection: the slot is written" "slot v1.2.0" "$(pages_file retry kure/v1.2/index.html)"
assert_eq "one rejection: the root is written" "root v1.2.0" "$(pages_file retry kure/index.html)"
assert_eq "one rejection: the other slot's commit is the parent" "deploy: other slot 1" \
    "$(git -C "$WORK/retry/pages.git" log -1 --format=%s main~1)"

# The retry takes the root decision again: a newer tag that lands meanwhile
# leaves the root alone although the first attempt had written it.
new_case retrytag v1.1.0 v1.2.0
builds retrytag v1.2.0
racer retrytag
RACE_LIMIT=1 RACE_TAG=v1.3.0 deploy retrytag v1.2 v1.2.0 true
assert_eq "rejection, then a newer tag: exit 0" 0 "$RC"
assert_eq "rejection, then a newer tag: the other slot's deploy is kept" "other 1" \
    "$(pages_file retrytag kure/v9.1/index.html)"
assert_eq "rejection, then a newer tag: the slot is written" "slot v1.2.0" \
    "$(pages_file retrytag kure/v1.2/index.html)"
assert_eq "rejection, then a newer tag: the root is untouched" "root seed" \
    "$(pages_file retrytag kure/index.html)"
assert_contains "rejection, then a newer tag: logs why" "$OUT" "v1.2.0 is no longer the highest stable tag"

# ── 6. always rejected: fails after the last attempt ──────────────────────

new_case rejected v1.1.0 v1.2.0
builds rejected v1.2.0
racer rejected
RACE_LIMIT=99 deploy rejected v1.2 v1.2.0 true
assert_eq "always rejected: exit 1" 1 "$RC"
assert_contains "always rejected: says so" "$OUT" "push to main still rejected after 3 attempts"
assert_eq "always rejected: exactly the bounded number of pushes" 3 "$(cat "$WORK/rejected/push-count")"
assert_eq "always rejected: the slot never landed" "" "$(pages_file rejected kure/v1.2/index.html)"
assert_eq "always rejected: the root is untouched" "root seed" "$(pages_file rejected kure/index.html)"
assert_eq "always rejected: every other deploy is kept" "other 3" "$(pages_file rejected kure/v9.3/index.html)"

# ── 6b. the branch moved before the push started: git's own refusal ───────

new_case fetchfirst v1.1.0 v1.2.0
builds fetchfirst v1.2.0
racer fetchfirst post-commit
RACE_LIMIT=1 deploy fetchfirst v1.2 v1.2.0 true
assert_eq "fetch first: exit 0" 0 "$RC"
assert_contains "fetch first: the rejection is reported" "$OUT" "push to main rejected (attempt 1/3)"
assert_eq "fetch first: two commits" 2 "$(cat "$WORK/fetchfirst/push-count")"
assert_eq "fetch first: the other slot's deploy is kept" "other 1" "$(pages_file fetchfirst kure/v9.1/index.html)"
assert_eq "fetch first: the slot is written" "slot v1.2.0" "$(pages_file fetchfirst kure/v1.2/index.html)"

# The same race when the deploying clone already has the other deploy's
# commit: git refuses the push as non-fast-forward.
new_case nonff v1.1.0 v1.2.0
builds nonff v1.2.0
racer nonff post-commit
RACE_LIMIT=1 RACE_FETCH=1 deploy nonff v1.2 v1.2.0 true
assert_eq "non-fast-forward: exit 0" 0 "$RC"
assert_contains "non-fast-forward: the rejection is reported" "$OUT" "push to main rejected (attempt 1/3)"
assert_eq "non-fast-forward: the other slot's deploy is kept" "other 1" "$(pages_file nonff kure/v9.1/index.html)"
assert_eq "non-fast-forward: the slot is written" "slot v1.2.0" "$(pages_file nonff kure/v1.2/index.html)"

# ── 6c. refused for a reason other than a moved branch: no retry ──────────

new_case declined v1.1.0 v1.2.0
builds declined v1.2.0
before=$(pages_tip declined)
cat > "$WORK/declined/pages.git/hooks/pre-receive" <<EOF
#!/usr/bin/env bash
cat >/dev/null
n=\$(( \$(cat "$WORK/declined/receive-count" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$WORK/declined/receive-count"
echo "declined by the test" >&2
exit 1
EOF
chmod +x "$WORK/declined/pages.git/hooks/pre-receive"
deploy declined v1.2 v1.2.0 true
assert_eq "hook declines: exit 1" 1 "$RC"
assert_contains "hook declines: names the refusal" "$OUT" \
    "push to main failed ([remote rejected] (pre-receive hook declined)) although the branch did not move; not retrying"
assert_eq "hook declines: exactly one push" 1 "$(cat "$WORK/declined/receive-count")"
assert_not_contains "hook declines: no retry is announced" "$OUT" "rejected (attempt"
assert_eq "hook declines: nothing pushed" "$before" "$(pages_tip declined)"

# A push that reaches no remote reports no status at all.
new_case nopush v1.2.0
builds nopush v1.2.0
before=$(pages_tip nopush)
git -C "$WORK/nopush/target" config remote.origin.pushurl "$WORK/nopush/no-such.git"
deploy nopush v1.2 v1.2.0 false
assert_eq "unreachable push URL: exit 1" 1 "$RC"
assert_contains "unreachable push URL: names the git exit" "$OUT" "(no push status, git exit 128); not retrying"
assert_not_contains "unreachable push URL: no retry is announced" "$OUT" "rejected (attempt"
assert_eq "unreachable push URL: nothing pushed" "$before" "$(pages_tip nopush)"

# ── 7. refused inputs ─────────────────────────────────────────────────────

new_case inputs v1.2.0
builds inputs v1.2.0
before=$(pages_tip inputs)
deploy inputs ../v1.2 v1.2.0 false
assert_eq "slot with a path: exit 1" 1 "$RC"
assert_contains "slot with a path: says so" "$OUT" "slot '../v1.2' is not a single path segment"
deploy inputs next v1.2.0 true
assert_eq "slot a root write would delete: exit 1" 1 "$RC"
assert_contains "slot a root write would delete: says so" "$OUT" "slot 'next' is neither 'dev' nor a 'v*' version slot"
deploy inputs next v1.2.0 false
assert_eq "slot a root write would delete, set_latest false: exit 1" 1 "$RC"
deploy inputs v1.2 v1.2.0 true --root-site "$WORK/inputs/no-such-root"
assert_eq "missing root build with set_latest true: exit 1" 1 "$RC"
assert_contains "missing root build with set_latest true: says so" "$OUT" "no-such-root' not found"
deploy inputs v1.2 v1.2.0 yes
assert_eq "set_latest not a boolean: exit 1" 1 "$RC"
mkdir -p "$WORK/inputs/target/build"
deploy inputs v1.2 v1.2.0 false --slot-site "$WORK/inputs/target/build"
assert_eq "build inside the target: exit 1" 1 "$RC"
assert_contains "build inside the target: says so" "$OUT" "is inside the target checkout"
deploy inputs v1.2 v1.2.0 false --max-attempts 0
assert_eq "zero attempts: exit 1" 1 "$RC"
assert_eq "refused inputs: nothing pushed" "$before" "$(pages_tip inputs)"

# ── Result ────────────────────────────────────────────────────────────────

if [ "$failures" -gt 0 ]; then
    echo "deploy-docs-push-test: $pass_count passed, $failures failed" >&2
    exit 1
fi
echo "deploy-docs-push-test: $pass_count passed, 0 failed"
