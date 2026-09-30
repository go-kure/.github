#!/usr/bin/env bash
# publish-policy.sh — the two decisions Release / Publish makes about a tag,
# from the repository's tags. Run in a checkout that has every tag fetched.
#
#   publish-policy.sh progression <tag>
#       Exit 0 when <tag> is greater, in semver order, than every other tag of its
#       own line (vX.Y); exit 1 naming the highest one it is not greater than.
#       Other lines do not count, so a backport v0.2.1 passes next to
#       v0.3.0-alpha.4, and a stable tag is greater than its own prereleases
#       (v0.2.0 > v0.2.0-rc.1, which `sort -V` gets backwards).
#
#   publish-policy.sh latest <tag>
#       Print `true` when <tag> is a stable tag and no higher stable tag exists,
#       otherwise `false`. Publish sets both the docs site's `latest` and GitHub's
#       Latest release from it, so publishing a backport, or re-publishing an older
#       stable tag, leaves both pointers on the newest stable release.
#
# Only tags in the release format count: vX.Y.Z and vX.Y.Z-alpha|beta|rc.N.
# Exit 2 on a usage error or a <tag> not in that format.
#
# Tests: scripts/test/release-test.sh

set -euo pipefail
export LC_ALL=C

NUM='(0|[1-9][0-9]*)'
VERSION_RE="^v${NUM}\.${NUM}\.${NUM}(-(alpha|beta|rc)\.${NUM})?\$"

usage() {
    echo "Usage: publish-policy.sh progression|latest <tag>" >&2
    exit 2
}

# key <tag>: a fixed-width string that sorts, byte by byte, in semver order.
# A prerelease sorts below the stable version it leads to.
key() {
    [[ "$1" =~ $VERSION_RE ]] || return 1
    local stable=1 stage=0 num=0
    if [ -n "${BASH_REMATCH[5]}" ]; then
        stable=0
        case "${BASH_REMATCH[5]}" in
            alpha) stage=0 ;;
            beta)  stage=1 ;;
            rc)    stage=2 ;;
        esac
        num=${BASH_REMATCH[6]}
    fi
    printf '%09d.%09d.%09d.%d.%d.%09d\n' \
        "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "$stable" "$stage" "$num"
}

line_of() {
    [[ "$1" =~ $VERSION_RE ]]
    printf 'v%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

is_stable() {
    [[ "$1" =~ $VERSION_RE ]] && [ -z "${BASH_REMATCH[5]}" ]
}

[ $# -eq 2 ] || usage
cmd="$1"
tag="$2"
tag_key=$(key "$tag") || { echo "publish-policy.sh: '$tag' is not a release tag (vX.Y.Z or vX.Y.Z-alpha|beta|rc.N)" >&2; exit 2; }

tags=$(git tag --list 'v*')

case "$cmd" in
    progression)
        line=$(line_of "$tag")
        worst="" worst_key=""
        while IFS= read -r other; do
            if [ -z "$other" ] || [ "$other" = "$tag" ]; then continue; fi
            other_key=$(key "$other") || continue
            [ "$(line_of "$other")" = "$line" ] || continue
            if [[ ! "$other_key" < "$tag_key" ]] && [[ -z "$worst_key" || "$other_key" > "$worst_key" ]]; then
                worst="$other" worst_key="$other_key"
            fi
        done <<< "$tags"
        if [ -n "$worst" ]; then
            echo "Tag $tag is not greater than $worst, an existing tag of the same line ($line)."
            exit 1
        fi
        echo "Tag $tag is greater than every other $line tag."
        ;;
    latest)
        if ! is_stable "$tag"; then
            echo false
            exit 0
        fi
        while IFS= read -r other; do
            if [ -z "$other" ] || [ "$other" = "$tag" ]; then continue; fi
            is_stable "$other" || continue
            other_key=$(key "$other")
            if [[ "$other_key" > "$tag_key" ]]; then
                echo false
                exit 0
            fi
        done <<< "$tags"
        echo true
        ;;
    *)
        usage
        ;;
esac
