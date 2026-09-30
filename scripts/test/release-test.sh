#!/usr/bin/env bash
# Tests for scripts/release/release.sh and scripts/release/publish-policy.sh
#
# Every case runs the real script against real git repositories: a bare
# "origin" and a working clone, both under a temporary directory, so pushes,
# tags and release branches are observed on the remote exactly as a caller's
# Release run leaves them. git-cliff is the real binary, because what
# --use-branch-tags does to a changelog after a backport is git-cliff's
# behaviour, and a stub would only restate the flag.
#
# Needs git, git-cliff and yq on PATH; no token and no network.
#
# Run: bash scripts/test/release-test.sh .

set -uo pipefail # deliberately not -e: assertions continue past failures so one
                 # run reports every problem, not just the first.

ROOT="$(cd "${1:-.}" && pwd)"
SCRIPT="$ROOT/scripts/release/release.sh"
POLICY="$ROOT/scripts/release/publish-policy.sh"
PUBLISH_WORKFLOW="$ROOT/.github/workflows/release-publish.yml"

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

for tool in git git-cliff yq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "release-test: $tool is required on PATH (git-cliff: the version pinned in .github/workflows/release.yml)" >&2
        exit 1
    fi
done
for f in "$SCRIPT" "$POLICY" "$PUBLISH_WORKFLOW"; do
    [ -f "$f" ] || { echo "release-test: $f not found" >&2; exit 1; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" user.name "release-test"
git config --file "$GIT_CONFIG_GLOBAL" user.email "release-test@example.invalid"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" advice.detachedHead false

# ── Fixtures ──────────────────────────────────────────────────────────────

# A clock one minute per step. git-cliff orders tags by commit time in whole
# seconds (then by name), so two releases made in the same second would order
# by name and could hide a backport tag that sorts last by time.
CLOCK=1767225600
tick() {
    CLOCK=$((CLOCK + 60))
    export GIT_AUTHOR_DATE="@$CLOCK +0000" GIT_COMMITTER_DATE="@$CLOCK +0000"
}

# new_fixture <name> <VERSION>: $WORK/<name>/{origin.git,work}, main pushed.
new_fixture() {
    local d="$WORK/$1"
    tick
    mkdir -p "$d/work/site/scripts"
    git init --quiet --bare "$d/origin.git"
    git -C "$d/work" init --quiet
    printf '%s\n' "$2" > "$d/work/VERSION"
    printf '# Changelog\n' > "$d/work/CHANGELOG.md"
    cat > "$d/work/cliff.toml" <<'EOF'
[changelog]
header = "# Changelog\n"
body = """
{% if version %}## [{{ version | trim_start_matches(pat="v") }}]{% else %}## [unreleased]{% endif %}
{% for commit in commits %}- {{ commit.message | split(pat="\n") | first }}
{% endfor %}
"""
trim = true

[git]
conventional_commits = true
filter_unconventional = false
tag_pattern = "v[0-9].*"
EOF
    # The caller's forbidden-terms check: fails when this marker file exists.
    cat > "$d/work/site/scripts/check-forbidden-terms.sh" <<'EOF'
#!/usr/bin/env bash
if [ -f FORBIDDEN ]; then echo "forbidden term in FORBIDDEN"; exit 1; fi
echo "forbidden-terms: OK"
EOF
    git -C "$d/work" add -A
    git -C "$d/work" commit --quiet -m "chore: initial"
    git -C "$d/work" remote add origin "$d/origin.git"
    git -C "$d/work" push --quiet origin main
}

# add_commit <name> <message>: a commit on the checked-out branch, pushed there.
add_commit() {
    local d="$WORK/$1" branch
    tick
    branch=$(git -C "$d/work" symbolic-ref --short HEAD)
    printf '%s\n' "$2" >> "$d/work/work.txt"
    git -C "$d/work" add work.txt
    git -C "$d/work" commit --quiet -m "$2"
    git -C "$d/work" push --quiet origin "$branch"
}

# checkout_remote_branch <name> <branch>
checkout_remote_branch() {
    local d="$WORK/$1"
    git -C "$d/work" fetch --quiet origin
    git -C "$d/work" checkout --quiet -B "$2" "origin/$2"
}

# run_release <name> <branch> <action> [VAR=value ...]: runs release.sh as the
# workflow does (CI=true, a real run unless DRY_RUN=1 is passed); sets OUT, RC.
# The runner's own GITHUB_* variables are cleared so an expected refusal does
# not raise an error annotation on this repository's CI run.
run_release() {
    local d="$WORK/$1" branch="$2" action="$3"
    shift 3
    tick
    : > "$d/github-output"
    OUT=$(cd "$d/work" && env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY \
        CI=true DRY_RUN=0 RELEASE_BRANCH="$branch" RELEASE_ACTION="$action" \
        RELEASE_REF_TYPE=branch GITHUB_OUTPUT="$d/github-output" "$@" \
        bash "$SCRIPT" 2>&1)
    RC=$?
}

remote_file() {  # remote_file <name> <ref> <path>
    git -C "$WORK/$1/origin.git" show "$2:$3" 2>/dev/null
}
remote_ref() {  # remote_ref <name> <ref>: the OID, or empty
    git -C "$WORK/$1/origin.git" rev-parse -q --verify "$2^{commit}" 2>/dev/null
}
output_of() {  # output_of <name>: the GITHUB_OUTPUT file
    cat "$WORK/$1/github-output"
}
# section <file content> <version without v>: one changelog section's lines.
section() {
    printf '%s\n' "$1" | awk -v h="## [$2]" '
        index($0, "## [") == 1 { on = ($0 == h); next }
        on { print }'
}

# ── main: tagging actions ─────────────────────────────────────────────────

new_fixture alpha v0.2.0-alpha.3
add_commit alpha "feat: alpha work"
run_release alpha main release
assert_eq "release on alpha: exit 0" 0 "$RC"
assert_eq "release on alpha: tags VERSION as it stands" \
    "v0.2.0-alpha.3" "$(remote_file alpha refs/tags/v0.2.0-alpha.3 VERSION)"
assert_eq "release on alpha: VERSION moves to the next number" \
    "v0.2.0-alpha.4" "$(remote_file alpha refs/heads/main VERSION)"
assert_eq "release on alpha: the tag is reported for the publish wait" \
    "tag=v0.2.0-alpha.3" "$(output_of alpha)"
assert_contains "release on alpha: CHANGELOG section at the tag" \
    "$(remote_file alpha refs/tags/v0.2.0-alpha.3 CHANGELOG.md)" "## [0.2.0-alpha.3]"
assert_eq "release on alpha: tagged commit is the release commit" \
    "release: v0.2.0-alpha.3" "$(git -C "$WORK/alpha/origin.git" log -1 --format=%s refs/tags/v0.2.0-alpha.3)"
assert_eq "release on alpha: tag is annotated" \
    "tag" "$(git -C "$WORK/alpha/origin.git" cat-file -t refs/tags/v0.2.0-alpha.3)"

new_fixture tobeta v0.2.0-alpha.3
run_release tobeta main release-as-beta
assert_eq "release-as-beta from alpha: exit 0" 0 "$RC"
assert_eq "release-as-beta from alpha: tags beta.0" \
    "v0.2.0-beta.0" "$(remote_file tobeta refs/tags/v0.2.0-beta.0 VERSION)"
assert_eq "release-as-beta from alpha: VERSION beta.1" \
    "v0.2.0-beta.1" "$(remote_file tobeta refs/heads/main VERSION)"
assert_eq "release-as-beta from alpha: no alpha tag" "" "$(remote_ref tobeta refs/tags/v0.2.0-alpha.3)"

new_fixture beta v0.2.0-beta.14
run_release beta main release-as-beta
assert_eq "release-as-beta on beta: same as release" \
    "v0.2.0-beta.14|v0.2.0-beta.15" \
    "$(remote_file beta refs/tags/v0.2.0-beta.14 VERSION)|$(remote_file beta refs/heads/main VERSION)"

new_fixture back v0.2.0-rc.1
before=$(remote_ref back refs/heads/main)
run_release back main release-as-beta
assert_eq "release-as-beta on rc: refused" 1 "$RC"
assert_contains "release-as-beta on rc: says why" "$OUT" "going back from rc to beta is refused"
assert_eq "release-as-beta on rc: main untouched" "$before" "$(remote_ref back refs/heads/main)"
assert_eq "release-as-beta on rc: no tag" "" "$(git -C "$WORK/back/origin.git" tag)"

new_fixture torc v0.2.0-beta.14
run_release torc main release-as-rc
assert_eq "release-as-rc from beta: tag rc.0, VERSION rc.1" \
    "v0.2.0-rc.0|v0.2.0-rc.1" \
    "$(remote_file torc refs/tags/v0.2.0-rc.0 VERSION)|$(remote_file torc refs/heads/main VERSION)"

new_fixture stable v0.2.0-rc.1
run_release stable main release-as-stable
assert_eq "release-as-stable: exit 0" 0 "$RC"
assert_eq "release-as-stable: tag vX.Y.Z, VERSION next patch alpha.0" \
    "v0.2.0|v0.2.1-alpha.0" \
    "$(remote_file stable refs/tags/v0.2.0 VERSION)|$(remote_file stable refs/heads/main VERSION)"
assert_eq "release-as-stable: no release branch" "" "$(remote_ref stable refs/heads/release/v0.2)"

new_fixture skip v0.2.0-beta.14
run_release skip main skip-prerelease-number
assert_eq "skip-prerelease-number: exit 0" 0 "$RC"
assert_eq "skip-prerelease-number: VERSION next number" \
    "v0.2.0-beta.15" "$(remote_file skip refs/heads/main VERSION)"
assert_eq "skip-prerelease-number: no tag" "" "$(git -C "$WORK/skip/origin.git" tag)"
assert_eq "skip-prerelease-number: no tag reported" "" "$(output_of skip)"

new_fixture mainstable v0.2.0
run_release mainstable main release
assert_eq "release with a stable VERSION on main: refused" 1 "$RC"
assert_contains "release with a stable VERSION on main: says why" "$OUT" "not a prerelease"

# ── main: starting the next line, and the release branch it creates ───────

new_fixture noline v0.2.0-beta.3
run_release noline main start-next-minor
assert_eq "start-next-minor, no stable tag: exit 0" 0 "$RC"
assert_eq "start-next-minor, no stable tag: VERSION next minor alpha.0" \
    "v0.3.0-alpha.0" "$(remote_file noline refs/heads/main VERSION)"
assert_eq "start-next-minor, no stable tag: no release branch" "" "$(remote_ref noline refs/heads/release/v0.2)"
assert_contains "start-next-minor, no stable tag: says so" "$OUT" "v0.2 has no stable tag"

new_fixture line v0.2.0-rc.1
add_commit line "feat: first feature"
run_release line main release-as-stable
add_commit line "feat: next line work"
main_before=$(git -C "$WORK/line/work" rev-parse HEAD)
run_release line main start-next-minor
assert_eq "start-next-minor after stable: exit 0" 0 "$RC"
assert_eq "start-next-minor after stable: main VERSION" \
    "v0.3.0-alpha.0" "$(remote_file line refs/heads/main VERSION)"
assert_eq "start-next-minor after stable: release branch VERSION is the next patch" \
    "v0.2.1" "$(remote_file line refs/heads/release/v0.2 VERSION)"
assert_eq "start-next-minor after stable: release branch starts at the stable tag" \
    "$(remote_ref line refs/tags/v0.2.0)" "$(remote_ref line refs/heads/release/v0.2~1)"
assert_eq "start-next-minor after stable: the branch commit changes only VERSION" \
    "VERSION" "$(git -C "$WORK/line/origin.git" diff --name-only refs/tags/v0.2.0 refs/heads/release/v0.2)"
assert_eq "start-next-minor after stable: branch commit message" \
    "chore: start release/v0.2 at v0.2.1" "$(git -C "$WORK/line/origin.git" log -1 --format=%s refs/heads/release/v0.2)"
assert_eq "start-next-minor after stable: main advanced by one commit" \
    "$main_before" "$(remote_ref line refs/heads/main~1)"
assert_eq "start-next-minor after stable: the checkout stays on main, clean" \
    "main|" "$(git -C "$WORK/line/work" symbolic-ref --short HEAD)|$(git -C "$WORK/line/work" status --porcelain)"
assert_eq "start-next-minor after stable: no tag reported" "" "$(output_of line)"

new_fixture again v0.2.0-rc.1
run_release again main release-as-stable
git -C "$WORK/again/work" push --quiet origin "refs/tags/v0.2.0^{commit}:refs/heads/release/v0.2"
branch_before=$(remote_ref again refs/heads/release/v0.2)
run_release again main start-next-minor
assert_eq "start-next-minor, branch exists: exit 0" 0 "$RC"
assert_eq "start-next-minor, branch exists: branch left as it is" \
    "$branch_before" "$(remote_ref again refs/heads/release/v0.2)"
assert_eq "start-next-minor, branch exists: main still moves" \
    "v0.3.0-alpha.0" "$(remote_file again refs/heads/main VERSION)"

new_fixture major v0.2.0-rc.1
run_release major main release-as-stable
run_release major main start-next-major
assert_eq "start-next-major after stable: main VERSION next major alpha.0" \
    "v1.0.0-alpha.0" "$(remote_file major refs/heads/main VERSION)"
assert_eq "start-next-major after stable: old line's branch created" \
    "v0.2.1" "$(remote_file major refs/heads/release/v0.2 VERSION)"

# The branch starts at the highest stable tag by number: v0.2.10, not v0.2.9.
new_fixture highest v0.2.11-alpha.0
for t in v0.2.1 v0.2.9 v0.2.10 v0.2.10-rc.0 v0.3.0-alpha.1; do
    git -C "$WORK/highest/work" tag "$t"
done
git -C "$WORK/highest/work" push --quiet origin --tags
run_release highest main start-next-minor
assert_eq "start-next-minor: branch at the highest stable tag of the line" \
    "$(remote_ref highest refs/tags/v0.2.10)|v0.2.11" \
    "$(remote_ref highest refs/heads/release/v0.2~1)|$(remote_file highest refs/heads/release/v0.2 VERSION)"

# ── release/vX.Y ──────────────────────────────────────────────────────────

# main releases once before the backport and once after it (at the end), so
# the backport tag lands, by time, between two main releases.
run_release line main release
assert_eq "main release before the backport: exit 0" 0 "$RC"
main_before=$(remote_ref line refs/heads/main)
checkout_remote_branch line release/v0.2
add_commit line "fix: backported fix"
run_release line release/v0.2 release
assert_eq "release on release/v0.2: exit 0" 0 "$RC"
assert_eq "release on release/v0.2: tags the patch" \
    "v0.2.1" "$(remote_file line refs/tags/v0.2.1 VERSION)"
assert_eq "release on release/v0.2: VERSION next patch, no prerelease" \
    "v0.2.2" "$(remote_file line refs/heads/release/v0.2 VERSION)"
assert_eq "release on release/v0.2: main untouched" "$main_before" "$(remote_ref line refs/heads/main)"
assert_eq "release on release/v0.2: tag reported" "tag=v0.2.1" "$(output_of line)"

before=$(remote_ref line refs/heads/release/v0.2)
run_release line release/v0.2 release-as-rc
assert_eq "release-as-rc on a release branch: refused" 1 "$RC"
assert_contains "release-as-rc on a release branch: says why" "$OUT" "the only action is 'release'"
assert_eq "release-as-rc on a release branch: branch untouched" "$before" "$(remote_ref line refs/heads/release/v0.2)"

new_fixture wrongline v0.2.1
git -C "$WORK/wrongline/work" push --quiet origin main:release/v0.3
checkout_remote_branch wrongline release/v0.3
run_release wrongline release/v0.3 release
assert_eq "release branch whose VERSION is another line: refused" 1 "$RC"
assert_contains "release branch whose VERSION is another line: says why" "$OUT" "does not belong on release/v0.3"

new_fixture prebranch v0.2.1-alpha.0
git -C "$WORK/prebranch/work" push --quiet origin main:release/v0.2
checkout_remote_branch prebranch release/v0.2
run_release prebranch release/v0.2 release
assert_eq "release branch with a prerelease VERSION: refused" 1 "$RC"
assert_contains "release branch with a prerelease VERSION: says why" "$OUT" "a prerelease"

# ── Branches, refs and actions the guard refuses ──────────────────────────

new_fixture feature v0.2.0-alpha.3
git -C "$WORK/feature/work" checkout --quiet -b feat/x
add_commit feature "feat: on a feature branch"
before=$(git -C "$WORK/feature/origin.git" for-each-ref)
run_release feature feat/x release
assert_eq "real run on a feature branch: refused" 1 "$RC"
assert_contains "real run on a feature branch: says how to preview" "$OUT" "Tick 'Dry run'"
assert_eq "real run on a feature branch: origin untouched" "$before" "$(git -C "$WORK/feature/origin.git" for-each-ref)"

head_before=$(git -C "$WORK/feature/work" rev-parse HEAD)
run_release feature feat/x release DRY_RUN=1
assert_eq "dry run on a feature branch: exit 0" 0 "$RC"
assert_contains "dry run on a feature branch: warns" "$OUT" "a real run is refused on this branch"
assert_contains "dry run on a feature branch: previews the tag" "$OUT" "v0.2.0-alpha.3"
assert_eq "dry run on a feature branch: origin untouched" "$before" "$(git -C "$WORK/feature/origin.git" for-each-ref)"
assert_eq "dry run on a feature branch: checkout untouched" \
    "$head_before||" \
    "$(git -C "$WORK/feature/work" rev-parse HEAD)|$(git -C "$WORK/feature/work" status --porcelain)|$(git -C "$WORK/feature/work" tag)"

run_release feature feat/x release DRY_RUN=1 RELEASE_REF_TYPE=tag
assert_eq "a tag ref: refused, dry run included" 1 "$RC"
assert_contains "a tag ref: says why" "$OUT" "runs from a branch, not from the tag"

run_release feature main bump
assert_eq "unknown action: refused" 1 "$RC"
assert_contains "unknown action: lists the actions" "$OUT" "Pick one of: release release-as-beta"

mkdir -p "$WORK/norepo"
GUARD_OUT=$(cd "$WORK/norepo" && env -u GITHUB_ACTIONS RELEASE_ACTION=release RELEASE_BRANCH=release/v0.2 \
    RELEASE_REF_TYPE=branch DRY_RUN=0 bash "$SCRIPT" --guard 2>&1)
assert_eq "--guard needs no repository: allowed case exits 0" 0 "$?"
assert_contains "--guard: allowed case" "$GUARD_OUT" "is allowed"
GUARD_OUT=$(cd "$WORK/norepo" && env -u GITHUB_ACTIONS RELEASE_ACTION=start-next-minor RELEASE_BRANCH=release/v0.2 \
    RELEASE_REF_TYPE=branch DRY_RUN=1 bash "$SCRIPT" --guard 2>&1)
assert_eq "--guard: start-next-minor on a release branch refused" 1 "$?"

# ── Dry run on main ───────────────────────────────────────────────────────

new_fixture dry v0.2.0-alpha.3
before=$(git -C "$WORK/dry/origin.git" for-each-ref)
head_before=$(git -C "$WORK/dry/work" rev-parse HEAD)
run_release dry main release DRY_RUN=1
assert_eq "dry run: exit 0" 0 "$RC"
assert_contains "dry run: says nothing changes" "$OUT" "Dry run: nothing is committed, tagged or pushed"
assert_contains "dry run: previews the tag" "$OUT" "Tag:             v0.2.0-alpha.3"
assert_contains "dry run: previews VERSION after" "$OUT" "VERSION after:   v0.2.0-alpha.4"
assert_eq "dry run: origin untouched" "$before" "$(git -C "$WORK/dry/origin.git" for-each-ref)"
assert_eq "dry run: checkout untouched, no local tag" \
    "$head_before||" \
    "$(git -C "$WORK/dry/work" rev-parse HEAD)|$(git -C "$WORK/dry/work" status --porcelain)|$(git -C "$WORK/dry/work" tag)"
assert_eq "dry run: no tag reported" "" "$(output_of dry)"

git -C "$WORK/dry/work" tag v0.2.0-alpha.3
git -C "$WORK/dry/work" push --quiet origin v0.2.0-alpha.3
git -C "$WORK/dry/work" tag -d v0.2.0-alpha.3 >/dev/null
run_release dry main release DRY_RUN=1
assert_eq "dry run on an existing tag: refused" 1 "$RC"
assert_contains "dry run on an existing tag: says so" "$OUT" "Tag v0.2.0-alpha.3 already exists on origin"

new_fixture drybranch v0.2.0-rc.1
run_release drybranch main release-as-stable
before=$(git -C "$WORK/drybranch/origin.git" for-each-ref)
run_release drybranch main start-next-minor DRY_RUN=1
assert_eq "dry run start-next-minor: exit 0" 0 "$RC"
assert_contains "dry run start-next-minor: previews the branch" "$OUT" "create release/v0.2 at v0.2.0, VERSION v0.2.1"
assert_eq "dry run start-next-minor: origin untouched" "$before" "$(git -C "$WORK/drybranch/origin.git" for-each-ref)"

# ── What stops a release before, or during, the push ──────────────────────

new_fixture terms v0.2.0-alpha.3
touch "$WORK/terms/work/FORBIDDEN"
printf 'FORBIDDEN\n' > "$WORK/terms/work/.git/info/exclude"
before=$(git -C "$WORK/terms/origin.git" for-each-ref)
run_release terms main release
assert_eq "forbidden term in the tree: refused" 1 "$RC"
assert_contains "forbidden term in the tree: says why" "$OUT" "the tree contains downstream references"
assert_eq "forbidden term in the tree: nothing pushed" "$before" "$(git -C "$WORK/terms/origin.git" for-each-ref)"

new_fixture noterms v0.2.0-alpha.3
git -C "$WORK/noterms/work" rm --quiet site/scripts/check-forbidden-terms.sh
git -C "$WORK/noterms/work" commit --quiet -m "chore: drop the check"
git -C "$WORK/noterms/work" push --quiet origin main
before=$(git -C "$WORK/noterms/origin.git" for-each-ref)
run_release noterms main release
assert_eq "no forbidden-terms check: refused" 1 "$RC"
assert_eq "no forbidden-terms check: nothing pushed" "$before" "$(git -C "$WORK/noterms/origin.git" for-each-ref)"

new_fixture stale v0.2.0-alpha.3
git clone --quiet "$WORK/stale/origin.git" "$WORK/stale/other"
printf 'x\n' > "$WORK/stale/other/other.txt"
git -C "$WORK/stale/other" add other.txt
git -C "$WORK/stale/other" commit --quiet -m "feat: landed meanwhile"
git -C "$WORK/stale/other" push --quiet origin main
before=$(git -C "$WORK/stale/origin.git" for-each-ref)
run_release stale main release
assert_eq "main moved after the run started: refused" 1 "$RC"
assert_contains "main moved after the run started: says why" "$OUT" "the branch moved after this run started"
assert_eq "main moved after the run started: nothing pushed" "$before" "$(git -C "$WORK/stale/origin.git" for-each-ref)"

new_fixture nextexists v0.2.0-alpha.3
git -C "$WORK/nextexists/work" tag v0.2.0-alpha.4
git -C "$WORK/nextexists/work" push --quiet origin v0.2.0-alpha.4
git -C "$WORK/nextexists/work" tag -d v0.2.0-alpha.4 >/dev/null
run_release nextexists main release
assert_eq "next VERSION is an existing tag: refused" 1 "$RC"
assert_contains "next VERSION is an existing tag: names it" "$OUT" "Tag v0.2.0-alpha.4 already exists on origin"

new_fixture dirty v0.2.0-alpha.3
printf 'edit\n' >> "$WORK/dirty/work/cliff.toml"
run_release dirty main release
assert_eq "uncommitted changes: refused" 1 "$RC"
assert_contains "uncommitted changes: says why" "$OUT" "uncommitted changes"

# The remote refuses one of the two refs: with --atomic the other must not land.
reject_ref() {  # reject_ref <name> <ref glob>
    cat > "$WORK/$1/origin.git/hooks/update" <<EOF
#!/bin/sh
case "\$1" in $2) echo "update hook: refusing \$1"; exit 1 ;; esac
EOF
    chmod +x "$WORK/$1/origin.git/hooks/update"
}

new_fixture atomictag v0.2.0-alpha.3
reject_ref atomictag 'refs/tags/*'
before=$(remote_ref atomictag refs/heads/main)
run_release atomictag main release
assert_eq "tag refused by the remote: release fails" 1 "$RC"
assert_eq "tag refused by the remote: main not pushed either" "$before" "$(remote_ref atomictag refs/heads/main)"
assert_eq "tag refused by the remote: no tag reported" "" "$(output_of atomictag)"

new_fixture atomicbranch v0.2.0-rc.1
run_release atomicbranch main release-as-stable
reject_ref atomicbranch 'refs/heads/release/*'
before=$(remote_ref atomicbranch refs/heads/main)
run_release atomicbranch main start-next-minor
assert_eq "release branch refused by the remote: fails" 1 "$RC"
assert_eq "release branch refused by the remote: main not pushed either" "$before" "$(remote_ref atomicbranch refs/heads/main)"

# ── CHANGELOG and release notes on both branches after a backport ─────────
#
# The `line` fixture now holds, in time order: v0.2.0 (first feature) on
# main; v0.3.0-alpha.0 (next line work) on main; v0.2.1 (backported fix) on
# release/v0.2. One more main release completes the picture.

checkout_remote_branch line main
add_commit line "feat: after backport"
run_release line main release
assert_eq "main release after a backport: exit 0" 0 "$RC"

main_log=$(remote_file line refs/heads/main CHANGELOG.md)
branch_log=$(remote_file line refs/heads/release/v0.2 CHANGELOG.md)
main_section=$(section "$main_log" 0.3.0-alpha.1)
branch_section=$(section "$branch_log" 0.2.1)

assert_contains "branch CHANGELOG: the patch holds the backport" "$branch_section" "backported fix"
assert_not_contains "branch CHANGELOG: the patch holds nothing from main" "$branch_section" "next line work"
assert_contains "main CHANGELOG: the release holds main's new work" "$main_section" "after backport"
assert_not_contains "main CHANGELOG: the backport is not re-listed" "$main_section" "backported fix"
assert_not_contains "main CHANGELOG: the previous main release is not re-listed" "$main_section" "next line work"
assert_not_contains "main CHANGELOG: v0.2.0's work is not re-listed" "$main_section" "first feature"
assert_eq "main CHANGELOG: no section for the backport tag" "" "$(printf '%s\n' "$main_log" | grep -F '## [0.2.1]')"
assert_eq "main CHANGELOG: each earlier section appears once" "1|1" \
    "$(printf '%s\n' "$main_log" | grep -cF '## [0.2.0]')|$(printf '%s\n' "$main_log" | grep -cF '## [0.3.0-alpha.0]')"

# The notes command is read from release-publish.yml, so this runs what
# Publish runs.
notes_cmd=$(yq '.jobs.goreleaser.steps[] | select(.name == "Extract release notes") | .run' "$PUBLISH_WORKFLOW")
if [ -z "$notes_cmd" ] || [ "$notes_cmd" = null ]; then
    fail "release-publish.yml: no 'Extract release notes' step in the goreleaser job"
else
    git clone --quiet "$WORK/line/origin.git" "$WORK/line/notes"
    notes_at() {  # notes_at <tag>: the notes Publish would ship for <tag>
        git -C "$WORK/line/notes" checkout --quiet "$1"
        (cd "$WORK/line/notes" && eval "$notes_cmd" >/dev/null 2>&1 && cat release-notes.md)
        rm -f "$WORK/line/notes/release-notes.md"
    }
    patch_notes=$(notes_at v0.2.1)
    assert_contains "notes for the backport: the backport" "$patch_notes" "backported fix"
    assert_not_contains "notes for the backport: not the previous release" "$patch_notes" "first feature"
    assert_not_contains "notes for the backport: nothing from main" "$patch_notes" "next line work"
    main_notes=$(notes_at v0.3.0-alpha.1)
    assert_contains "notes for the main release: main's new work" "$main_notes" "after backport"
    assert_not_contains "notes for the main release: not the backport" "$main_notes" "backported fix"
    assert_not_contains "notes for the main release: not the previous main release" "$main_notes" "next line work"
fi

# ── publish-policy.sh ─────────────────────────────────────────────────────

POLICY_REPO="$WORK/policy"
git -C "$WORK" init --quiet policy
git -C "$POLICY_REPO" commit --quiet --allow-empty -m "chore: initial"

policy() {  # policy <tags...> -- <cmd> <tag>: sets OUT, RC
    git -C "$POLICY_REPO" tag -l | xargs -r git -C "$POLICY_REPO" tag -d >/dev/null
    while [ "$1" != "--" ]; do git -C "$POLICY_REPO" tag "$1"; shift; done
    shift
    OUT=$(cd "$POLICY_REPO" && bash "$POLICY" "$@" 2>&1)
    RC=$?
}

policy v0.2.0-beta.3 v0.2.0-rc.1 v0.2.0 -- progression v0.2.0
assert_eq "progression: stable after its own rc passes" 0 "$RC"
policy v0.2.0-beta.3 v0.2.0-beta.4 -- progression v0.2.0-beta.3
assert_eq "progression: an older tag of the line fails" 1 "$RC"
assert_contains "progression: names the newer tag" "$OUT" "not greater than v0.2.0-beta.4"
policy v0.2.0 v0.3.0-alpha.4 v0.2.1 -- progression v0.2.1
assert_eq "progression: a backport ignores the newer line" 0 "$RC"
policy v0.1.10 v0.1.9 -- progression v0.1.9
assert_eq "progression: compares numbers, not text" 1 "$RC"
policy v0.2.0-rc.9 v0.2.0-rc.10 -- progression v0.2.0-rc.10
assert_eq "progression: rc.10 after rc.9 passes" 0 "$RC"
policy v1.0.0 v0.4.0-alpha.0 -- progression v0.4.0-alpha.0
assert_eq "progression: the first tag of a line passes" 0 "$RC"
policy v0.2.0 v0.2.0-rc.1 -- progression v0.2.0-rc.1
assert_eq "progression: a prerelease after its stable fails" 1 "$RC"

policy v0.2.1 v0.3.0 -- latest v0.2.1
assert_eq "latest: a backport below a newer stable is not Latest" "false" "$OUT"
policy v0.2.1 v0.3.0 v0.4.0-alpha.1 -- latest v0.3.0
assert_eq "latest: the highest stable is Latest, prereleases aside" "true" "$OUT"
policy v0.3.0 v0.4.0-rc.0 -- latest v0.4.0-rc.0
assert_eq "latest: a prerelease is never Latest" "false" "$OUT"
policy v0.9.5 v0.10.0 -- latest v0.10.0
assert_eq "latest: compares numbers, not text" "true" "$OUT"
policy v0.2.0 -- latest v0.2.0
assert_eq "latest: the only stable tag is Latest" "true" "$OUT"

policy v0.2.0 -- progression 0.2.0
assert_eq "policy: a tag outside the release format is a usage error" 2 "$RC"

# ── Result ────────────────────────────────────────────────────────────────

if [ "$failures" -gt 0 ]; then
    echo "release-test: $pass_count passed, $failures failed" >&2
    exit 1
fi
echo "release-test: $pass_count passed, 0 failed"
