#!/usr/bin/env bash
# check-release-notes.sh — refuse a Release / Publish run whose release notes would never reach
# the GitHub release (go-kure/.github#470).
#
#   check-release-notes.sh NOTES_FILE [GORELEASER_CONFIG]
#
# GoReleaser loads `--release-notes FILE` only inside its changelog pipe, and skips that whole
# pipe when the config sets `changelog.disable: true`. The file is then never read and the
# release body is a single newline, with every step of the run green. This script exits 1 when
#   - NOTES_FILE is missing, or holds only whitespace (git-cliff succeeded and wrote nothing), or
#   - the config sets changelog.disable to true, or to anything it cannot read before the run
#     (a template such as "{{ .Env.X }}").
# It reports every fault it finds, not only the first. Exit 2 on a usage error.
#
# Without GORELEASER_CONFIG it reads .goreleaser.yaml, then .goreleaser.yml, in the current
# directory; with neither, GoReleaser runs on its defaults, which keep the changelog pipe.
#
# What it cannot prove: that GitHub shows the body. It reads two files. The first real release
# after a caller drops `changelog.disable` is the end-to-end proof.
#
# Tests: scripts/test/release-notes-contract-test.sh

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: check-release-notes.sh NOTES_FILE [GORELEASER_CONFIG]" >&2
    exit 2
fi
notes="$1"
config="${2:-}"
if [ -z "$config" ]; then
    for candidate in .goreleaser.yaml .goreleaser.yml; do
        if [ -e "$candidate" ]; then
            config="$candidate"
            break
        fi
    done
fi

rc=0

if [ ! -e "$notes" ]; then
    echo "::error::the release notes file $notes is missing, so GoReleaser has no notes to publish."
    rc=1
elif ! grep -q '[^[:space:]]' "$notes"; then
    echo "::error::the release notes file $notes is empty (no text besides whitespace), so the release would be published with an empty body."
    rc=1
fi

if [ -n "$config" ]; then
    if [ ! -e "$config" ]; then
        echo "::error::the GoReleaser config $config is missing."
        rc=1
    else
        # The value of changelog.disable: the direct child `disable:` of the top-level `changelog:`
        # key, or the `disable:` inside an inline `changelog: {...}` map. Prints the value with
        # comments and quotes removed, or "absent". Plain POSIX awk (no gawk features).
        value="$(awk '
            function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
            function unquote(s) {
                if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2)
                return s
            }
            function scalar(s) { sub(/[[:space:]]+#.*$/, "", s); return unquote(trim(s)) }
            BEGIN { val = "absent" }
            /^[^[:space:]#]/ {
                in_block = 0
                if ($0 ~ /^changelog:/) {
                    rest = $0
                    sub(/^changelog:/, "", rest)
                    sub(/[[:space:]]+#.*$/, "", rest)
                    rest = trim(rest)
                    if (rest == "") {
                        in_block = 1
                        base = -1
                    } else if (match(rest, /disable:[[:space:]]*[^,}[:space:]]+/)) {
                        v = substr(rest, RSTART, RLENGTH)
                        sub(/^disable:[[:space:]]*/, "", v)
                        val = unquote(v)
                    }
                }
                next
            }
            in_block && !/^[[:space:]]*(#.*)?$/ {
                match($0, /^[[:space:]]*/)
                if (base < 0) base = RLENGTH
                if (RLENGTH == base && $0 ~ /^[[:space:]]+disable:/ && val == "absent") {
                    v = $0
                    sub(/^[[:space:]]+disable:/, "", v)
                    val = scalar(v)
                }
            }
            END { print val }
        ' "$config")"
        case "$value" in
            absent | false | False | FALSE) ;;
            true | True | TRUE)
                echo "::error::$config sets changelog.disable to true. GoReleaser then skips its changelog step, the only step that reads --release-notes, and publishes the release with an empty body. Remove the changelog.disable setting from $config."
                rc=1
                ;;
            *)
                echo "::error::changelog.disable in $config is '$value', which cannot be read before the run. Set it to false or remove it: GoReleaser skips the step that reads --release-notes when it is true."
                rc=1
                ;;
        esac
    fi
fi

if [ "$rc" -eq 0 ]; then
    echo "Release notes check passed: $notes holds text and ${config:-no GoReleaser config} keeps the changelog step that loads it."
fi
exit "$rc"
