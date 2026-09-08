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
#   2. EVERY line of every gold row falls inside a hunk the REVIEWED diff (base_sha..head_sha)
#      actually adds. This is the one that matters. A gold row is a claim that a reviewer of
#      that diff should have flagged those lines, so a line the diff never touches is a row no
#      reviewer could ever match and every run scores it as a miss. It is invisible in the
#      output -- recall just comes out low, which is exactly what a reviewer under test is
#      expected to produce. Measured on the first corpus built by this harness: 26 of 63 rows,
#      41%, pointed outside the diff, because the blame parser kept the line number from the
#      fix's parent revision rather than from the introducing commit.
#
#      Checking the whole span rather than its first line catches the second, independent way
#      a row goes wrong: a span collapsed as min..max across non-contiguous blame runs starts
#      on a line the commit really did add and then runs on over lines belonging to other
#      commits. Both defects are fixed in build-gold.sh; this asserts the result.
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

# How many lines of LO..HI does this diff NOT add? Reads the "+start,count" side of each @@
# header. -U0 so a line only counts when the diff genuinely touches it rather than merely
# printing it as context -- with context lines a row several lines away from any change would
# pass.
#
# The WHOLE span, not just its first line. A span is a claim about every line in it, and a
# checked-first-line-only test passes a row whose remaining lines belong to someone else --
# which is exactly what a min..max collapse over non-contiguous blame runs produces. Real case,
# versions.yaml at ee027242^: one commit's two lines, orig 124 and 129, recorded as [124,129]
# with three other commits' lines in between. Line 124 is inside the diff, so the old test
# passed it while four fifths of the span named code that commit never wrote.
span_outside_diff() {
    local checkout="$1" base="$2" head="$3" file="$4" lo="$5" hi="$6"
    # --no-color because a checkout with color.ui=always emits ANSI escapes before every @@,
    # which the matcher below then never recognises -- turning "no hunks found" into "every row
    # is outside the diff" and condemning a perfectly good corpus. The other machine-parsed
    # diffs in this harness already pass it.
    #
    # --inter-hunk-context=0 because that setting (default 0, but 5 on at least one machine this
    # was built on) merges neighbouring hunks, and a merged hunk's "+start,count" spans the
    # UNCHANGED lines between the two changes. This parser marks the whole range as added, so
    # every one of those lines passes an invariant that exists to reject exactly them -- a
    # permissive oracle that reports a clean corpus and cannot be told apart from a real one.
    git -C "$checkout" diff --no-color --no-ext-diff --no-textconv -U0 --inter-hunk-context=0 "$base" "$head" -- "$file" 2>/dev/null |
        awk -v lo="$lo" -v hi="$hi" '
            /^@@/ {
                match($0, /\+[0-9]+(,[0-9]+)?/)
                spec = substr($0, RSTART + 1, RLENGTH - 1)
                n = split(spec, a, ",")
                start = a[1] + 0
                count = (n > 1 ? a[2] + 0 : 1)
                for (i = start; i < start + count; i++) added[i] = 1
            }
            END {
                out = 0
                for (l = lo + 0; l <= hi + 0; l++) if (!(l in added)) out++
                print out
            }
        '
}

violations=0
rows_total=0
rows_outside=0

for g in "${gold_files[@]}"; do
    # `type == "array"` before anything else. jq's `length`, `.[]` and `all` all work on an
    # OBJECT too, so `.gold` stored as a map keyed by row id passes every test here and the row
    # loop below iterates its values happily -- but judge.sh indexes the rows positionally
    # (`to_entries[].key` handed to `--argjson`), so the approved corpus is unusable by the very
    # scoring path this preflight exists to clear it for.
    if ! jq -e '(.gold | type) == "array" and (.gold | length) > 0 and all(.gold[]; .confirmed == true)' "$g" >/dev/null 2>&1; then
        printf 'gold is not a non-empty array of confirmed rows: %s\n' "$g"
        violations=$((violations + 1))
        continue
    fi

    # Type, not just inequality with "". `0`, `[]` and `{}` are all `!= ""` in jq, so a document
    # carrying one passes a bare emptiness test and run.sh then forwards a non-string as the
    # review title -- a prompt without the introducing commit's subject, measured against rows
    # whose prompts have one. Same class as the span check below: build-gold.sh cannot emit it,
    # a hand-edited or externally generated corpus can, and nothing else looks.
    if ! jq -e '(.intro_title | type) == "string" and (.intro_title | length) > 0' "$g" >/dev/null 2>&1; then
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

    while IFS=$'\t' read -r file lo hi; do
        rows_total=$((rows_total + 1))

        # An empty or null `file` is a violation, not something to skip past. Skipping left the
        # row out of rows_total AND out of the violation count, so a row naming no file at all --
        # unmatchable by any reviewer, which is precisely what this script rejects rows for --
        # passed the preflight without appearing anywhere in its output.
        if [ -z "$file" ] || [ "$file" = null ]; then
            printf 'row names no file: %s -> lines %s-%s\n' "$(basename -- "$g")" "$lo" "$hi"
            violations=$((violations + 1))
            continue
        fi

        # Shape before content. span_outside_diff counts the lines of lo..hi that the diff does
        # not add, so a reversed or non-numeric span makes its loop run zero times, leave the
        # counter at 0, and report the row as INSIDE the reviewed diff -- a preflight passing
        # precisely the rows it exists to catch. The row then reaches the judge as a nonsensical
        # range and sits in the denominator while being unmatchable, depressing recall.
        # build-gold.sh cannot emit one (its span collapse is ordered by construction), so this
        # guards a hand-edited or externally produced corpus, whose shape nothing else checks.
        # Each endpoint on its own, never the pair joined by a comma. Joining them makes the
        # separator indistinguishable from a comma INSIDE an endpoint, so `["1,2", "2"]` reads as
        # well-formed; `[ "1,2" -lt 1 ]` then fails its own syntax rather than the comparison, the
        # branch below is not taken, and awk's `lo+0` silently measures the row as 1..2 -- the
        # preflight passing exactly the shape it exists to reject.
        bad_span=0
        for endpoint in "$lo" "$hi"; do
            case "$endpoint" in
                '' | *[!0-9]*) bad_span=1 ;;
            esac
        done
        if [ "$bad_span" = 1 ] || [ "$lo" -lt 1 ] || [ "$hi" -lt "$lo" ]; then
            printf 'malformed span: %s -> %s:%s-%s (want 1 <= lo <= hi)\n' \
                "$(basename -- "$g")" "$file" "$lo" "$hi"
            violations=$((violations + 1))
            continue
        fi

        outside=$(span_outside_diff "$checkout" "$base" "$head" "$file" "$lo" "$hi")
        if [ "${outside:-0}" -gt 0 ]; then
            printf 'row outside the reviewed diff: %s -> %s:%s-%s (%s of %s lines; %s..%s)\n' \
                "$(basename -- "$g")" "$file" "$lo" "$hi" \
                "$outside" "$((hi - lo + 1))" "${base:0:8}" "${head:0:8}"
            rows_outside=$((rows_outside + 1))
            violations=$((violations + 1))
        fi
    done < <(jq -r '.gold[] | "\(.file)\t\(.lines[0])\t\(.lines[1])"' "$g")
done

printf '%s: %d documents, %d rows, %d rows outside the reviewed diff\n' \
    "$PROG" "${#gold_files[@]}" "$rows_total" "$rows_outside"

[ "$violations" -eq 0 ] || exit 1
