#!/usr/bin/env bash
# release.sh — the release script of every go-kure repository. The shared
# Release workflow (.github/workflows/release.yml) runs it in a checkout of the
# repository being released, at this repository's own commit, so a caller
# carries no copy of it. Nothing here is specific to one repository.
#
# One action per run (RELEASE_ACTION), on the branch the run was started from
# (RELEASE_BRANCH):
#
#   on main — VERSION is a prerelease, vX.Y.Z-alpha|beta|rc.N
#     release                  tag VERSION as it stands; VERSION -> the next number
#     release-as-beta|rc       move to that stage (.0) and tag it; a VERSION already
#                              at that stage is tagged as it stands, like `release`
#     release-as-stable        tag vX.Y.Z; VERSION -> vX.Y.(Z+1)-alpha.0
#     start-next-minor|major   no tag; VERSION -> the next line's alpha.0. When the
#                              line being left has a stable tag and no release
#                              branch yet, also create release/vX.Y at its highest
#                              stable tag, with VERSION set to the next patch.
#     skip-prerelease-number   no tag; VERSION -> the next number (recovery)
#
#   on release/vX.Y — VERSION is the next stable patch, vX.Y.Z
#     release                  tag vX.Y.Z; VERSION -> vX.Y.(Z+1)
#
# Going back a stage (rc -> beta) is refused. A real run is refused on any other
# branch; a dry run previews from any branch and changes nothing.
#
# Every push is one atomic `git push`: the branch and its new tag, or main and a
# new release branch, land together or not at all.
#
# Environment:
#   RELEASE_ACTION         one of the actions above (default: release)
#   RELEASE_BRANCH         the branch being released (default: the checked-out one)
#   RELEASE_REF_TYPE       `branch` or `tag`, the workflow's github.ref_type
#                          (default: branch)
#   DRY_RUN                1 = preview only (default: 0)
#   CI                     `true` = set the bot identity, require HEAD to be the
#                          branch's tip on origin, and push
#   FORBIDDEN_TERMS_CHECK  the repository's own check, run on the tree before
#                          every push (default: site/scripts/check-forbidden-terms.sh)
#
# Usage:
#   release.sh            run RELEASE_ACTION
#   release.sh --guard    check the branch and the action only; needs no checkout
#
# Guide: https://github.com/go-kure/.github/blob/main/standards/release-process.md
# Tests: scripts/test/release-test.sh

set -euo pipefail
# Keep set -e inside $(...) too; bash turns it off there by default.
shopt -s inherit_errexit

VERSION_FILE=VERSION
CHANGELOG_FILE=CHANGELOG.md
REMOTE=origin
GUIDE="https://github.com/go-kure/.github/blob/main/standards/release-process.md"
ACTIONS="release release-as-beta release-as-rc release-as-stable start-next-minor start-next-major skip-prerelease-number"

DRY_RUN="${DRY_RUN:-0}"
RELEASE_ACTION="${RELEASE_ACTION:-release}"
RELEASE_BRANCH="${RELEASE_BRANCH:-}"
RELEASE_REF_TYPE="${RELEASE_REF_TYPE:-branch}"
FORBIDDEN_TERMS_CHECK="${FORBIDDEN_TERMS_CHECK:-site/scripts/check-forbidden-terms.sh}"

# ── Logging ───────────────────────────────────────────────────────────────

log_info() { printf 'INFO: %s\n' "$1"; }
log_ok()   { printf 'OK: %s\n' "$1"; }
log_warn() { printf 'WARN: %s\n' "$1"; }
# Both lines go to stderr: die also runs inside $(...), which would capture a
# stdout annotation. The runner reads workflow commands from both streams.
die() {
    printf 'ERROR: %s\n' "$1" >&2
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        printf '::error::%s See %s\n' "$1" "$GUIDE" >&2
    fi
    exit 1
}

# ── Versions ──────────────────────────────────────────────────────────────

NUM='(0|[1-9][0-9]*)'
VERSION_RE="^v${NUM}\.${NUM}\.${NUM}(-(alpha|beta|rc)\.${NUM})?\$"

# parse_version <v>: sets V_MAJOR V_MINOR V_PATCH, and V_TYPE V_NUM (empty for
# a stable version).
parse_version() {
    [[ "$1" =~ $VERSION_RE ]] \
        || die "Invalid version '$1': expected vX.Y.Z or vX.Y.Z-alpha|beta|rc.N"
    V_MAJOR=${BASH_REMATCH[1]}
    V_MINOR=${BASH_REMATCH[2]}
    V_PATCH=${BASH_REMATCH[3]}
    V_TYPE=${BASH_REMATCH[5]}
    V_NUM=${BASH_REMATCH[6]}
}

stage_order() {
    case "$1" in
        alpha) echo 0 ;;
        beta)  echo 1 ;;
        rc)    echo 2 ;;
    esac
}

read_version() {
    [ -f "$VERSION_FILE" ] || die "No $VERSION_FILE file at the repository root"
    tr -d '[:space:]' < "$VERSION_FILE"
}

is_release_branch() {
    [[ "$1" =~ ^release/v${NUM}\.${NUM}$ ]]
}

# ── Checks ────────────────────────────────────────────────────────────────

guard() {
    case " $ACTIONS " in
        *" $RELEASE_ACTION "*) ;;
        *) die "Unknown action '$RELEASE_ACTION'. Pick one of: $ACTIONS." ;;
    esac
    case "$DRY_RUN" in
        0|1) ;;
        *) die "DRY_RUN must be 0 or 1, got '$DRY_RUN'." ;;
    esac
    [ "$RELEASE_REF_TYPE" = branch ] \
        || die "Release runs from a branch, not from the $RELEASE_REF_TYPE '$RELEASE_BRANCH'. In 'Use workflow from', pick main or a release/vX.Y branch."
    [ -n "$RELEASE_BRANCH" ] || die "No branch to release: RELEASE_BRANCH is empty."
    if is_release_branch "$RELEASE_BRANCH"; then
        [ "$RELEASE_ACTION" = release ] \
            || die "On $RELEASE_BRANCH the only action is 'release', which releases the next patch. '$RELEASE_ACTION' runs on main."
    elif [ "$RELEASE_BRANCH" != main ]; then
        [ "$DRY_RUN" = 1 ] \
            || die "A release runs only from main or a release/vX.Y branch, not from '$RELEASE_BRANCH'. Tick 'Dry run' to preview from here."
        log_warn "Dry run from '$RELEASE_BRANCH': a real run is refused on this branch."
    fi
}

validate_git_state() {
    if ! git diff --quiet || ! git diff --cached --quiet; then
        die "The working tree has uncommitted changes."
    fi
    if [ -n "$(git ls-files --others --exclude-standard)" ]; then
        log_warn "Untracked files present (not part of the release)"
    fi
}

# A replacement is a local directory exactly when no version follows its
# target: Go requires one after a module path and refuses one after a
# directory. So the target, quoted (escapes included) or bare, is skipped and
# the rest of the line checked, which needs no path decoding. Only replace
# directives use =>, on their own line or inside a replace ( ) block, so every
# line is checked; a // outside quotes ends it.
check_local_replaces() {
    [ -f go.mod ] || return 0
    if awk '
        {
            line = ""; quoted = 0
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (!quoted && substr($0, i, 2) == "//") break
                if (c == "\"") quoted = !quoted
                else if (quoted && c == "\\") { line = line c; i++; c = substr($0, i, 1) }
                line = line c
            }
            if (!match(line, /=>[ \t]*/)) next
            rest = substr(line, RSTART + RLENGTH)
            if (substr(rest, 1, 1) == "\"") {
                for (i = 2; i <= length(rest); i++) {
                    c = substr(rest, i, 1)
                    if (c == "\\") i++
                    else if (c == "\"") break
                }
                rest = substr(rest, i + 1)
            } else {
                sub(/^[^ \t\r]*/, "", rest)
            }
            if (rest !~ /[^ \t\r]/) found = 1
        }
        END { exit !found }' go.mod; then
        die "go.mod has a local replace directive; remove it before releasing."
    fi
}

# check_tag_absent <tag> [hint]: runs in a dry run too, so a preview fails on a
# collision instead of promising a release the real run cannot make.
check_tag_absent() {
    local tag="$1" hint="${2:-}" remote
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        die "Tag $tag already exists in this checkout.${hint:+ $hint}"
    fi
    remote=$(git ls-remote --tags "$REMOTE" "refs/tags/$tag") \
        || die "Could not list the tags on $REMOTE."
    [ -z "$remote" ] || die "Tag $tag already exists on $REMOTE.${hint:+ $hint}"
}

remote_branch_exists() {
    local out
    out=$(git ls-remote --heads "$REMOTE" "refs/heads/$1") \
        || die "Could not list the branches on $REMOTE."
    [ -n "$out" ]
}

# highest_stable_tag <vX.Y>: the highest vX.Y.Z tag on the remote, or nothing.
highest_stable_tag() {
    local line="$1" refs
    refs=$(git ls-remote --tags --refs "$REMOTE") || die "Could not list the tags on $REMOTE."
    printf '%s\n' "$refs" \
        | sed -n 's#^[0-9a-f]*[[:space:]]*refs/tags/##p' \
        | { grep -E "^${line//./\\.}\.${NUM}\$" || true; } \
        | sort -V | tail -n 1
}

# ── CI ────────────────────────────────────────────────────────────────────

setup_ci() {
    log_info "CI: configuring the release bot's git identity"
    git config user.name "kure-release-bot"
    git config user.email "kure-release-bot@noreply"

    git fetch --quiet --no-tags "$REMOTE" "refs/heads/$RELEASE_BRANCH" \
        || die "Could not fetch $RELEASE_BRANCH from $REMOTE."
    local head tip
    head=$(git rev-parse HEAD)
    tip=$(git rev-parse FETCH_HEAD)
    [ "$head" = "$tip" ] \
        || die "HEAD ($head) is not the tip of $RELEASE_BRANCH on $REMOTE ($tip): the branch moved after this run started. Start the release again."
    log_ok "HEAD is the tip of $RELEASE_BRANCH"
}

# A release pushes past the merge queue, so the tree it pushes, generated
# CHANGELOG included, is checked here instead.
check_forbidden_terms() {
    [ -f "$FORBIDDEN_TERMS_CHECK" ] \
        || die "No $FORBIDDEN_TERMS_CHECK: every release checks the tree for downstream references before it pushes."
    log_info "Checking the tree for downstream references"
    bash "$FORBIDDEN_TERMS_CHECK" --full-tree \
        || die "Release stopped before pushing: the tree contains downstream references (output above). Fix the source or the cliff.toml postprocessor."
}

set_output() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
    fi
}

# push <extra refspec>...: the release branch plus every extra ref, atomically.
push() {
    local refspecs=("HEAD:refs/heads/$RELEASE_BRANCH" "$@")
    if [ "${CI:-}" != true ]; then
        log_warn "Not in CI: nothing pushed. To publish: git push --atomic $REMOTE ${refspecs[*]}"
        return
    fi
    check_forbidden_terms
    log_info "Pushing ${refspecs[*]}"
    git push --atomic "$REMOTE" "${refspecs[@]}" || die "The push was refused; nothing was published."
    log_ok "Pushed ${refspecs[*]}"
}

# ── Plan ──────────────────────────────────────────────────────────────────

# plan <tag> <next VERSION> <release branch note>: the one summary a run prints,
# and, in a workflow, the job summary on the run's page.
plan() {
    local tag="$1" next="$2" branch_note="$3" title
    if [ "$DRY_RUN" = 1 ]; then title="Dry run: nothing is committed, tagged or pushed"; else title="Release"; fi
    printf '\n%s\n' "$title"
    printf '  %-16s %s\n' \
        "Branch:" "$RELEASE_BRANCH" \
        "Action:" "$RELEASE_ACTION" \
        "VERSION now:" "$CURRENT" \
        "Tag:" "${tag:-none}" \
        "VERSION after:" "$next" \
        "Release branch:" "$branch_note"
    printf '\n'
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        # The backticks are literal Markdown code spans, not command substitution.
        # shellcheck disable=SC2016
        {
            printf '### %s\n\n' "$title"
            printf '| | |\n|---|---|\n'
            printf '| Branch | `%s` |\n' "$RELEASE_BRANCH"
            printf '| Action | `%s` |\n' "$RELEASE_ACTION"
            printf '| VERSION now | `%s` |\n' "$CURRENT"
            printf '| Tag | `%s` |\n' "${tag:-none}"
            printf '| VERSION after | `%s` |\n' "$next"
            printf '| Release branch | %s |\n' "$branch_note"
        } >> "$GITHUB_STEP_SUMMARY"
    fi
}

# ── Git writes ────────────────────────────────────────────────────────────

write_version() {
    printf '%s\n' "$1" > "$VERSION_FILE"
}

commit_version() {
    write_version "$1"
    git add "$VERSION_FILE"
    git commit --quiet -m "$2"
    log_ok "Committed: $2"
}

# make_branch_commit <tag> <version> <branch>: sets BRANCH_COMMIT to a commit on
# top of <tag> whose only change is VERSION, built without touching this
# checkout's working tree. It is called directly, never inside $(...), so a
# failed step stops the release here instead of pushing a half-built branch.
make_branch_commit() {
    local tag="$1" version="$2" branch="$3" base blob tree index
    BRANCH_COMMIT=""
    git fetch --quiet --no-tags "$REMOTE" "refs/tags/$tag:refs/tags/$tag" \
        || die "Could not fetch tag $tag from $REMOTE."
    base=$(git rev-parse --verify "refs/tags/$tag^{commit}") \
        || die "Tag $tag does not point at a commit."
    git cat-file -e "$base:$VERSION_FILE" 2>/dev/null \
        || die "Tag $tag has no $VERSION_FILE file, so $branch cannot start from it."
    blob=$(printf '%s\n' "$version" | git hash-object -w --stdin) \
        || die "Could not store the $VERSION_FILE of $branch."
    index="$(git rev-parse --absolute-git-dir)/release-branch-index"
    rm -f "$index"
    if ! GIT_INDEX_FILE="$index" git read-tree "$base" \
        || ! GIT_INDEX_FILE="$index" git update-index --cacheinfo "100644,$blob,$VERSION_FILE" \
        || ! tree=$(GIT_INDEX_FILE="$index" git write-tree); then
        rm -f "$index"
        die "Could not build the tree of $branch."
    fi
    rm -f "$index"
    BRANCH_COMMIT=$(git commit-tree "$tree" -p "$base" -m "chore: start $branch at $version") \
        || die "Could not create the first commit of $branch."
    git cat-file -e "$BRANCH_COMMIT^{commit}" 2>/dev/null \
        || die "git commit-tree returned '$BRANCH_COMMIT', not a commit."
}

# cut_release <tag> <next VERSION> <commit message for the VERSION bump>
cut_release() {
    local tag="$1" next="$2" bump_msg="$3"
    plan "$tag" "$next" "unchanged"
    check_tag_absent "$tag" "If it was released already, skip-prerelease-number moves VERSION past it."
    # A release never leaves VERSION naming a tag that already exists.
    check_tag_absent "$next"
    if [ "$DRY_RUN" = 1 ]; then
        log_ok "Dry run complete: a real run tags $tag and sets VERSION to $next."
        return
    fi
    validate_git_state
    check_local_replaces

    [ "$tag" = "$CURRENT" ] || write_version "$tag"
    log_info "Generating the CHANGELOG section for $tag"
    # Only the new section is rendered, below the header, so published sections
    # are never re-rendered through a later cliff.toml. --use-branch-tags keeps
    # a tag made on another branch (a backport) out of this branch's changelog.
    git-cliff --unreleased --use-branch-tags --tag "$tag" --prepend "$CHANGELOG_FILE"
    git add "$VERSION_FILE" "$CHANGELOG_FILE"
    git commit --quiet -m "release: $tag"
    git tag -a "$tag" -m "Release $tag"
    log_ok "Committed and tagged $tag"
    commit_version "$next" "$bump_msg"

    push "refs/tags/$tag"
    if [ "${CI:-}" = true ]; then
        set_output tag "$tag"
    fi
    log_ok "Release $tag complete."
}

# start_next_line <next VERSION>
start_next_line() {
    local next="$1" line="v$V_MAJOR.$V_MINOR" stable branch note branch_version="" create=false
    branch="release/$line"
    stable=$(highest_stable_tag "$line")
    if [ -z "$stable" ]; then
        note="none: $line has no stable tag"
    elif remote_branch_exists "$branch"; then
        note="$branch exists already, left as it is"
    else
        parse_version "$stable"
        branch_version="v$V_MAJOR.$V_MINOR.$((V_PATCH + 1))"
        create=true
        note="create $branch at $stable, VERSION $branch_version"
    fi
    plan "" "$next" "$note"
    check_tag_absent "$next"
    [ -z "$branch_version" ] || check_tag_absent "$branch_version"
    if [ "$DRY_RUN" = 1 ]; then
        log_ok "Dry run complete: a real run sets VERSION to $next${branch_version:+ and creates $branch}."
        return
    fi
    validate_git_state

    commit_version "$next" "chore: start next cycle: $next"
    if [ "$create" = true ]; then
        make_branch_commit "$stable" "$branch_version" "$branch"
        push "$BRANCH_COMMIT:refs/heads/$branch"
    else
        push
    fi
    log_ok "VERSION is now $next${branch_version:+; $branch starts at $branch_version}."
}

# ── Actions ───────────────────────────────────────────────────────────────

require_prerelease() {
    [ -n "$V_TYPE" ] \
        || die "VERSION is $CURRENT, not a prerelease. On main, start-next-minor or start-next-major begins a new line."
}

run_main() {
    local base="v$V_MAJOR.$V_MINOR.$V_PATCH" target
    case "$RELEASE_ACTION" in
        release)
            require_prerelease
            cut_release "$CURRENT" "$base-$V_TYPE.$((V_NUM + 1))" \
                "chore: bump version: $CURRENT -> $base-$V_TYPE.$((V_NUM + 1))"
            ;;
        release-as-beta|release-as-rc)
            require_prerelease
            target=${RELEASE_ACTION#release-as-}
            if [ "$(stage_order "$target")" -lt "$(stage_order "$V_TYPE")" ]; then
                die "VERSION is $CURRENT: going back from $V_TYPE to $target is refused. To restart at $target, begin a new line with start-next-minor first."
            fi
            if [ "$target" = "$V_TYPE" ]; then
                cut_release "$CURRENT" "$base-$V_TYPE.$((V_NUM + 1))" \
                    "chore: bump version: $CURRENT -> $base-$V_TYPE.$((V_NUM + 1))"
            else
                cut_release "$base-$target.0" "$base-$target.1" \
                    "chore: bump version: $base-$target.0 -> $base-$target.1"
            fi
            ;;
        release-as-stable)
            require_prerelease
            cut_release "$base" "v$V_MAJOR.$V_MINOR.$((V_PATCH + 1))-alpha.0" \
                "chore: start next cycle: v$V_MAJOR.$V_MINOR.$((V_PATCH + 1))-alpha.0"
            ;;
        start-next-minor)
            start_next_line "v$V_MAJOR.$((V_MINOR + 1)).0-alpha.0"
            ;;
        start-next-major)
            start_next_line "v$((V_MAJOR + 1)).0.0-alpha.0"
            ;;
        skip-prerelease-number)
            require_prerelease
            local next="$base-$V_TYPE.$((V_NUM + 1))"
            plan "" "$next" "unchanged"
            check_tag_absent "$next"
            if [ "$DRY_RUN" = 1 ]; then
                log_ok "Dry run complete: a real run sets VERSION to $next."
                return
            fi
            validate_git_state
            commit_version "$next" "chore: bump prerelease: $CURRENT -> $next"
            push
            log_ok "VERSION is now $next."
            ;;
    esac
}

run_release_branch() {
    [ "$RELEASE_ACTION" = release ] \
        || die "VERSION is $CURRENT, a stable version: only 'release' applies, which releases it as the next patch."
    [ -z "$V_TYPE" ] \
        || die "VERSION on $RELEASE_BRANCH is $CURRENT, a prerelease. A release branch carries the next stable patch, vX.Y.Z."
    if is_release_branch "$RELEASE_BRANCH" && [ "$RELEASE_BRANCH" != "release/v$V_MAJOR.$V_MINOR" ]; then
        die "VERSION is $CURRENT, which does not belong on $RELEASE_BRANCH."
    fi
    local next="v$V_MAJOR.$V_MINOR.$((V_PATCH + 1))"
    cut_release "$CURRENT" "$next" "chore: bump version: $CURRENT -> $next"
}

main() {
    if [ "${1:-}" = --guard ]; then
        guard
        log_ok "'$RELEASE_ACTION' on $RELEASE_BRANCH is allowed (DRY_RUN=$DRY_RUN)."
        return
    fi
    [ $# -eq 0 ] || die "Usage: release.sh [--guard] (the action comes from RELEASE_ACTION)"
    if [ -z "$RELEASE_BRANCH" ]; then
        RELEASE_BRANCH=$(git symbolic-ref --quiet --short HEAD) \
            || die "HEAD is detached: set RELEASE_BRANCH to the branch being released."
    fi
    guard
    if [ "${CI:-}" = true ] && [ "$DRY_RUN" != 1 ]; then
        setup_ci
    fi

    CURRENT=$(read_version)
    parse_version "$CURRENT"
    # A release branch by name, or, in a dry run from another branch, one by
    # content: a stable VERSION only ever sits on a release branch.
    if is_release_branch "$RELEASE_BRANCH" || { [ "$RELEASE_BRANCH" != main ] && [ -z "$V_TYPE" ]; }; then
        run_release_branch
    else
        run_main
    fi
}

main "$@"
