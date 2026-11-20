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
#   - the config's `changelog` block mentions `disable` in any way other than the exact line
#     `disable: false` (quotes around false allowed). Any other spelling is refused, whatever it
#     means to GoReleaser (true, a template, a value on the next line, an escape, a block scalar,
#     "", yes): this decodes no YAML, and a refusal costs one edit of the caller's config.
# It reports every fault it finds, not only the first. Exit 2 on a usage error.
#
# It is a best-effort guard, line by line: a changelog block with no mention of `disable`, a
# top-level key spelled in a way that is not the plain or quoted word `changelog` (an escape is
# refused only when no plain `changelog` key exists), a flow-style document, an alias or a merge
# key are not read.
#
# Without GORELEASER_CONFIG it reads the file GoReleaser itself would pick in the current
# directory (.config/goreleaser.yml, .config/goreleaser.yaml, .goreleaser.yml, .goreleaser.yaml,
# goreleaser.yml, goreleaser.yaml, in that order); with none of them, GoReleaser runs on its
# defaults, which keep the changelog pipe.
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
    # GoReleaser's own lookup order (cmd/config.go, v2.20.3): the first file that exists wins.
    for candidate in .config/goreleaser.yml .config/goreleaser.yaml .goreleaser.yml .goreleaser.yaml goreleaser.yml goreleaser.yaml; do
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
        # Prints "ok", or "<line number>: <the first line that is not acceptable>". Comments are
        # dropped first. A top-level line whose key is changelog (quotes and spaces ignored) opens
        # the block, which ends at the next top-level line. In the block, a line that mentions
        # disable (any case) must be exactly `disable: false`, and a quoted key with an escape is
        # refused. On the key line itself, any mention of disable or an escape is refused.
        # \047 is a single quote. Plain POSIX awk (no gawk features).
        result="$(awk '
            function bare(s) { gsub(/["\047[:space:]]/, "", s); return s }
            function flag(why) { if (bad == "") bad = NR ": " why }
            { text = $0; sub(/^[[:space:]]*#.*$/, "", text); sub(/[[:space:]]+#.*$/, "", text) }
            text ~ /^[[:space:]]*$/ { next }
            $0 ~ /^[^[:space:]]/ {
                in_block = 0
                i = index(text, ":")
                key = (i > 0) ? substr(text, 1, i - 1) : text
                if (text ~ /^["\047][^:]*\\/ && esc == "") esc = NR ": " text
                if (bare(key) == "changelog") {
                    seen = 1
                    in_block = 1
                    rest = (i > 0) ? substr(text, i + 1) : ""
                    if (rest ~ /[^[:space:]]/ && (tolower(rest) ~ /disable/ || rest ~ /\\/)) flag(text)
                }
                next
            }
            in_block {
                if (tolower(text) ~ /disable/) {
                    if (text !~ /^[[:space:]]+disable:[[:space:]]+(false|"false"|\047false\047)[[:space:]]*$/) flag(text)
                } else if (text ~ /^[[:space:]]*["\047][^:]*\\/) {
                    flag(text)
                }
            }
            END {
                if (bad == "" && !seen && esc != "") bad = esc
                print (bad == "" ? "ok" : bad)
            }
        ' "$config")"
        if [ "$result" != "ok" ]; then
            echo "::error::$config: changelog.disable is set or mentioned in a form that cannot be read as 'disable: false' (line $result). GoReleaser skips its changelog step, the only step that reads --release-notes, when changelog.disable is true, and then publishes the release with an empty body. Remove changelog.disable from $config, or write it as exactly 'disable: false'."
            rc=1
        fi
    fi
fi

if [ "$rc" -eq 0 ]; then
    echo "Release notes check passed: $notes holds text and ${config:-no GoReleaser config} keeps the changelog step that loads it."
fi
exit "$rc"
