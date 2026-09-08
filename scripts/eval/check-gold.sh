#!/usr/bin/env bash
# check-gold.sh -- assert a gold corpus is measurable before spending a run on it.
#
#   check-gold.sh --gold '<glob>' --checkout <repo-name>=<path> [--checkout ...]
#
# Two invariants, both of which have been violated in practice by a corpus that looked fine:
#
#   1. Every row carries `confirmed: true` and every document carries a non-empty `intro_title`.
#      A document without one has no leak-free review title available, so run.sh would fall back
#      to a neutral constant and quietly measure something different from the rest of the set.
#
#   2. Every gold row's first line falls inside a hunk the REVIEWED diff (base_sha..head_sha)
#      actually adds. This is the one that matters. A gold row is a claim that a reviewer of
#      that diff should have flagged that line, so a line the diff never touches is a row no
#      reviewer could ever match and every run scores it as a miss. It is invisible in the
#      output -- recall just comes out low, which is exactly what a reviewer under test is
#      expected to produce. Measured on the first corpus built by this harness: 26 of 63 rows,
#      41%, pointed outside the diff, because the blame parser kept the line number from the
#      fix's parent revision rather than from the introducing commit.
#
# Reports every violation rather than stopping at the first: a corpus is rebuilt as a unit, so
# the useful output is the full count, not the earliest example.
#
# exit status
#   0  every document and row satisfies both invariants
#   1  at least one violation (each is printed)
#   2  usage or environment error

set -uo pipefail

readonly PROG=${0##*/}

die() {
    printf '%s: %s\n' "$PROG" "$*" >&2
    exit 2
}

usage() {
    cat <<EOF
usage: $PROG --gold '<glob>' --checkout <repo-name>=<path> [--checkout ...]

  --gold      quoted glob matching the gold documents (expanded here, not by the caller)
  --checkout  map a gold document's "repo" field to a local checkout; repeatable
EOF
}

gold_glob=
declare -A checkouts=()

while [ $# -gt 0 ]; do
    case "$1" in
        --gold) gold_glob=${2-}; shift 2 || die "--gold needs a value" ;;
        --checkout)
            case "${2-}" in
                *=*) checkouts[${2%%=*}]=${2#*=} ;;
                *) die "--checkout wants <repo-name>=<path>, got: ${2-}" ;;
            esac
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$gold_glob" ] || die "--gold is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

gold_files=()
while IFS= read -r line; do
    [ -n "$line" ] && gold_files+=("$line")
done < <(compgen -G "$gold_glob" || true)
[ "${#gold_files[@]}" -gt 0 ] || die "no gold documents matched: $gold_glob"

# Is LINE inside a hunk this diff adds? Reads the "+start,count" side of each @@ header. -U0 so
# a line only counts when the diff genuinely touches it rather than merely printing it as
# context -- with context lines a row several lines away from any change would pass.
line_in_diff() {
    local checkout="$1" base="$2" head="$3" file="$4" line="$5"
    # --no-color because a checkout with color.ui=always emits ANSI escapes before every @@,
    # which the matcher below then never recognises -- turning "no hunks found" into "every row
    # is outside the diff" and condemning a perfectly good corpus. The other machine-parsed
    # diffs in this harness already pass it.
    git -C "$checkout" diff --no-color -U0 "$base" "$head" -- "$file" 2>/dev/null | awk -v L="$line" '
        /^@@/ {
            match($0, /\+[0-9]+(,[0-9]+)?/)
            spec = substr($0, RSTART + 1, RLENGTH - 1)
            n = split(spec, a, ",")
            start = a[1] + 0
            count = (n > 1 ? a[2] + 0 : 1)
            if (L >= start && L < start + count) found = 1
        }
        END { exit found ? 0 : 1 }
    '
}

violations=0
rows_total=0
rows_outside=0

for g in "${gold_files[@]}"; do
    if ! jq -e '(.gold | length) > 0 and all(.gold[]; .confirmed == true)' "$g" >/dev/null 2>&1; then
        printf 'unconfirmed or empty rows: %s\n' "$g"
        violations=$((violations + 1))
        continue
    fi

    if ! jq -e '(.intro_title // "") != ""' "$g" >/dev/null 2>&1; then
        printf 'no intro_title (run.sh would review it under a neutral title): %s\n' "$g"
        violations=$((violations + 1))
    fi

    # An absent mapping is an invocation fault, exactly like the unresolvable revision below --
    # the caller forgot a flag, the corpus is fine. Counting it as a violation would exit 1 and
    # say "rebuild the gold", which is both wrong and expensive, and it would contradict the
    # exit-2 contract this script documents.
    repo=$(jq -r '.repo' "$g")
    checkout=${checkouts[$repo]:-}
    [ -n "$checkout" ] || die "no --checkout for repo $repo (needed by $(basename -- "$g"))"

    base=$(jq -r '.base_sha' "$g")
    head=$(jq -r '.head_sha' "$g")

    # An unresolvable revision is an environment fault, not a bad corpus, and the two demand
    # opposite responses: one says fix the checkout, the other says rebuild the gold. Without
    # this check a shallow or stale checkout fails every `git diff` below, each row reads as
    # "outside the reviewed diff", and the script reports a corpus-wide defect -- exiting 1 and
    # prompting a rebuild that would not have helped. Checked once per document rather than per
    # row, since both revisions are document-level.
    for rev in "$base" "$head"; do
        if ! git -C "$checkout" rev-parse --verify --quiet "$rev^{commit}" >/dev/null; then
            die "$checkout cannot resolve $rev (from $(basename -- "$g")); is the checkout shallow or stale?"
        fi
    done

    while IFS=$'\t' read -r file line; do
        [ -n "$file" ] || continue
        rows_total=$((rows_total + 1))
        if ! line_in_diff "$checkout" "$base" "$head" "$file" "$line"; then
            printf 'row outside the reviewed diff: %s -> %s:%s (%s..%s)\n' \
                "$(basename -- "$g")" "$file" "$line" "${base:0:8}" "${head:0:8}"
            rows_outside=$((rows_outside + 1))
            violations=$((violations + 1))
        fi
    done < <(jq -r '.gold[] | "\(.file)\t\(.lines[0])"' "$g")
done

printf '%s: %d documents, %d rows, %d rows outside the reviewed diff\n' \
    "$PROG" "${#gold_files[@]}" "$rows_total" "$rows_outside"

[ "$violations" -eq 0 ] || exit 1
