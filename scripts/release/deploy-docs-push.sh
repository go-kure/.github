#!/usr/bin/env bash
# deploy-docs-push.sh — write one docs build into a checkout of the pages
# repository and push it. The deploy-docs-push composite action
# (.github/actions/deploy-docs-push) runs it for the callers' Deploy Docs
# workflow, at this repository's own commit, so a caller carries no copy.
#
# A caller's Deploy Docs runs one deploy per version slot at a time, not one
# overall, so deploys of different slots write the same pages repository at the
# same time. Two things follow, and this script handles both:
#
#   - Publish decided whether this release replaces the site root ("latest")
#     when it ran. By the time this deploy writes, a newer stable tag may exist,
#     and an older release's deploy landing last would put its docs back at the
#     root. So when the root was requested, the decision is taken again right
#     before the root is written, from freshly fetched tags, with the rule
#     Publish uses: publish-policy.sh `latest <label>`, the copy next to this
#     script. The re-check only narrows: a deploy that did not ask for the root
#     never writes it. A policy error fails the deploy.
#   - The push can be rejected because another slot's deploy landed first. Each
#     attempt therefore starts from the pages branch's current tip, writes this
#     deploy's content on it (another slot's content stays as that tip has it),
#     takes the root decision again, and pushes. A push rejected because the
#     branch moved (`fetch first`, `non-fast-forward`, or a `remote rejected`
#     when the branch's tip is no longer the one this attempt started from) is
#     retried up to --max-attempts times in all; then the deploy fails. Any
#     other push failure fails the deploy at once.
#
# Usage:
#   deploy-docs-push.sh --source DIR --target DIR --site-subdir NAME
#       --slot SLOT --label LABEL --set-latest true|false --slot-site DIR
#       [--root-site DIR] [--cname HOST] [--max-attempts N] [--backoff SECONDS]
#
#   --source        the caller's checkout; its `origin` tags decide the root,
#                   and its HEAD names the deploy commit
#   --target        the pages repository checkout, on its branch, with an
#                   `origin` it can push to
#   --site-subdir   the caller's directory in the pages repository (one path
#                   segment, e.g. `kure`)
#   --slot          <site-subdir>/<slot>/ is replaced (one path segment: `dev`
#                   or starting with `v`, the names a root write keeps)
#   --label         the version label; a release tag when the root is requested
#   --set-latest    `true` asks for the root; `false` never writes it
#   --slot-site     the build for the slot
#   --root-site     the build for the root (required with --set-latest true)
#   --cname         written to CNAME (default www.gokure.dev)
#   --max-attempts  push attempts before failing (default 5)
#   --backoff       seconds to wait after a rejected push (default 5)
#
# The root write keeps the version directories: everything directly under
# <site-subdir>/ except `dev` and `v*` is replaced by the root build.
#
# Tests: scripts/test/deploy-docs-push-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
    echo "::error::deploy-docs-push: $*" >&2
    exit 1
}

usage() {
    echo "usage: deploy-docs-push.sh --source DIR --target DIR --site-subdir NAME --slot SLOT --label LABEL --set-latest true|false --slot-site DIR [--root-site DIR] [--cname HOST] [--max-attempts N] [--backoff SECONDS]" >&2
    exit 64
}

# abs_dir <dir>: the directory as an absolute path, or die.
abs_dir() {
    [[ -d "$1" ]] || die "directory '$1' not found"
    (cd "$1" && pwd -P)
}

# inside <path> <dir>: whether <path> is <dir> or below it.
inside() {
    [[ "$1/" == "$2/"* ]]
}

src="" target="" site="" slot="" label="" set_latest="" slot_site="" root_site=""
cname="www.gokure.dev" max_attempts=5 backoff=5
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || usage
    case "$1" in
        --source) src="$2" ;;
        --target) target="$2" ;;
        --site-subdir) site="$2" ;;
        --slot) slot="$2" ;;
        --label) label="$2" ;;
        --set-latest) set_latest="$2" ;;
        --slot-site) slot_site="$2" ;;
        --root-site) root_site="$2" ;;
        --cname) cname="$2" ;;
        --max-attempts) max_attempts="$2" ;;
        --backoff) backoff="$2" ;;
        *) usage ;;
    esac
    shift 2
done

[[ -n "$src" && -n "$target" && -n "$slot_site" ]] || usage
# Both name directories that `rm -rf` replaces: one plain path segment each.
segment_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
[[ "$site" =~ $segment_re ]] || die "site subdir '$site' is not a single path segment (letters, digits, '.', '_', '-'; not starting with '.')"
[[ "$slot" =~ $segment_re ]] || die "slot '$slot' is not a single path segment (letters, digits, '.', '_', '-'; not starting with '.')"
# A root write replaces everything under <site-subdir>/ except `dev` and `v*`,
# so any other slot would be deleted by this deploy's root write or the next.
[[ "$slot" == dev || "$slot" == v* ]] || die "slot '$slot' is neither 'dev' nor a 'v*' version slot; a root write would delete it"
[[ -n "$label" ]] || die "empty label"
[[ "$set_latest" == true || "$set_latest" == false ]] || die "set-latest must be true or false, got '$set_latest'"
[[ -n "$cname" ]] || die "empty cname"
[[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || die "max-attempts must be a positive integer, got '$max_attempts'"
[[ "$backoff" =~ ^[0-9]+$ ]] || die "backoff must be a non-negative integer, got '$backoff'"

src="$(abs_dir "$src")"
target="$(abs_dir "$target")"
slot_site="$(abs_dir "$slot_site")"
if [[ "$set_latest" == true ]]; then
    [[ -n "$root_site" ]] || die "root-site is required with set-latest true"
    root_site="$(abs_dir "$root_site")"
else
    root_site=""
fi
# Every attempt resets and cleans the target, which would delete a build kept
# inside it.
for d in "$slot_site" "$root_site"; do
    if [[ -n "$d" ]] && inside "$d" "$target"; then
        die "build directory '$d' is inside the target checkout, which every attempt cleans"
    fi
done

branch="$(git -C "$target" symbolic-ref --quiet --short HEAD)" || die "$target is not on a branch"
source_sha="$(git -C "$src" rev-parse --short HEAD)" || die "cannot read HEAD of $src"

decision_file="$(mktemp)"
trap 'rm -f "$decision_file"' EXIT

git -C "$target" config user.name "github-actions[bot]"
git -C "$target" config user.email "github-actions[bot]@users.noreply.github.com"

site_dir="$target/$site"
for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    echo "Attempt ${attempt}/${max_attempts}: starting from origin/${branch}..."
    # Start from the pages branch's current tip, so what another slot's deploy
    # pushed meanwhile is kept, and this deploy's content is written again on
    # top of it: a rebase by regenerating rather than replaying.
    git -C "$target" fetch --quiet origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" \
        || die "could not fetch ${branch} from the pages repository"
    git -C "$target" reset --quiet --hard "refs/remotes/origin/${branch}"
    git -C "$target" clean --quiet -ffdx

    # Deployment infrastructure files.
    printf '%s\n' "$cname" >"$target/CNAME"
    touch "$target/.nojekyll"

    echo "Deploying to /${site}/${slot}/..."
    mkdir -p "$site_dir"
    rm -rf "${site_dir:?}/${slot}"
    cp -R "$slot_site" "$site_dir/${slot}"

    root_written=false
    if [[ "$set_latest" == true ]]; then
        # Decide again from the tags as they are now: Publish's decision may be
        # stale, and a retry must not reuse the previous attempt's answer.
        git -C "$src" fetch --quiet --force origin '+refs/tags/*:refs/tags/*' \
            || die "could not fetch tags into $src; not deciding the /${site}/ root from stale tags"
        # The policy reads the tags of its working directory.
        cd "$src"
        set +e
        bash "$SCRIPT_DIR/publish-policy.sh" latest "$label" >"$decision_file"
        policy_rc=$?
        set -e
        [[ "$policy_rc" -eq 0 ]] || die "publish-policy.sh latest '$label' failed (exit $policy_rc); not deciding the /${site}/ root"
        decision="$(<"$decision_file")"
        case "$decision" in
            true)
                echo "Deploying to /${site}/ (latest stable)..."
                find "$site_dir" -mindepth 1 -maxdepth 1 -not -name 'dev' -not -name 'v*' -exec rm -rf {} +
                cp -R "$root_site/." "$site_dir/"
                root_written=true
                ;;
            false)
                echo "::notice::deploy-docs-push: left the /${site}/ root untouched: ${label} is no longer the highest stable tag"
                ;;
            *)
                die "publish-policy.sh latest '$label' printed '${decision}', expected true or false"
                ;;
        esac
    fi

    git -C "$target" add -A
    if git -C "$target" diff --staged --quiet; then
        echo "No changes to deploy"
        exit 0
    fi
    if [[ "$root_written" == true ]]; then
        msg="deploy: ${label} → /${site}/${slot}/ + /${site}/ (latest) from ${site}@${source_sha}"
    else
        msg="deploy: ${label} → /${site}/${slot}/ from ${site}@${source_sha}"
    fi
    git -C "$target" commit --quiet -m "$msg"
    push_rc=0
    push_out="$(git -C "$target" push --porcelain --quiet origin "HEAD:refs/heads/${branch}")" || push_rc=$?
    if ((push_rc == 0)); then
        echo "Deployed: ${msg}"
        exit 0
    fi
    # Only a push refused because the pages branch moved is worth writing again;
    # anything else (a hook or protection rule, credentials, the network) fails
    # the same way on every attempt.
    push_status="$(printf '%s\n' "$push_out" | awk -F'\t' -v ref="HEAD:refs/heads/${branch}" '$1 == "!" && $2 == ref { print $3 }')"
    case "$push_status" in
        "[rejected] (fetch first)" | "[rejected] (non-fast-forward)")
            ;;
        "[remote rejected] "*)
            # The branch moved after the remote advertised its tip, or the remote
            # refused for another reason. git words the first differently across
            # versions (`failed to update ref`, `incorrect old value provided`),
            # so the tip decides, not the text: only a moved tip is a race.
            remote_tip="$(git -C "$target" ls-remote --exit-code origin "refs/heads/${branch}")" \
                || die "push to ${branch} failed (${push_status}) and the branch's tip could not be read; not retrying"
            if [[ "${remote_tip%%[[:space:]]*}" == "$(git -C "$target" rev-parse HEAD~1)" ]]; then
                die "push to ${branch} failed (${push_status}) although the branch did not move; not retrying"
            fi
            ;;
        *)
            die "push to ${branch} failed (${push_status:-no push status, git exit ${push_rc}}); not retrying: only a push rejected because the branch moved is retried"
            ;;
    esac
    if ((attempt < max_attempts)); then
        echo "::warning::deploy-docs-push: push to ${branch} rejected (attempt ${attempt}/${max_attempts}); writing again on the new tip in ${backoff}s"
        sleep "$backoff"
    fi
done
die "push to ${branch} still rejected after ${max_attempts} attempts"
