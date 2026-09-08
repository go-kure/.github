#!/usr/bin/env bash
# check-gold.sh -- assert a gold corpus is measurable before spending a run on it.
#
#   check-gold.sh --gold '<glob>' --checkout <repo-name>=<path> [--checkout ...]
#
# Three invariants, the first two of which have been violated in practice by a corpus that
# looked fine:
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
#   3. base_sha is head_sha's first parent -- the reviewed diff is the introducing commit
#      itself, which is what makes invariant 2 a meaningful test rather than a tautology
#      satisfiable by widening the diff. Rationale in full at the check.
#
# Reports every violation rather than stopping at the first: a corpus is rebuilt as a unit, so
# the useful output is the full count, not the earliest example.
#
# exit status
#   0  every document and row satisfies all three invariants
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
    # Non-blank, not merely non-empty: "   " has length 3 and is not a commit subject. It would
    # reach the reviewer verbatim as the review title -- neither the real one nor the neutral
    # constant -- because run.sh's fallback tests the same way this does.
    if ! jq -e '(.intro_title | type) == "string" and (.intro_title | test("\\S"))' "$g" >/dev/null 2>&1; then
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

    # base_sha must be head_sha's first parent, because that identity is what makes the rows
    # measurable at all. build-gold.sh derives it exactly that way -- the reviewed diff IS the
    # introducing commit -- and every gold row is a line that commit introduced. Widen base_sha
    # to an older ancestor and the reviewed diff still contains those lines, so the hunk check
    # below still passes, while the reviewer is now shown unrelated changes it is scored against
    # nothing for; narrow or move it sideways and the rows fall outside, which reports as a
    # corpus-wide "outside the reviewed diff" and sends the reader to rebuild gold that is fine.
    # Neither shape is reachable from the builder, and both are one hand-edit away.
    #
    # `^` and not `^1`: they mean the same first parent, and `^` is what build-gold.sh writes.
    # A root commit has no parent, so build-gold.sh drops that candidate before emitting -- a
    # document claiming one is malformed here rather than resolvable, and rev-parse below fails
    # closed.
    want_base=$(git -C "$checkout" rev-parse --verify --quiet "$head^" || true)
    if [ "$want_base" != "$(git -C "$checkout" rev-parse --verify "$base")" ]; then
        printf 'base_sha is not head_sha^ (%s vs %s): %s\n' \
            "$base" "${want_base:-<none>}" "$(basename -- "$g")"
        violations=$((violations + 1))
    fi

    while IFS=$'\t' read -r ok file lo hi; do
        rows_total=$((rows_total + 1))

        # The producer classifies each row before emitting it, and it does so because the naive
        # form (`"\(.file)\t\(.lines[0])\t\(.lines[1])"`) is not TOTAL: `.lines` stored as a
        # scalar makes jq abort mid-stream while indexing it. That abort happens inside a process
        # substitution, whose status the shell never sees, so the loop simply ends early -- the
        # script then reports fewer rows than the document holds and exits 0. A document with one
        # such row was passing this preflight while `run.sh` kept the row in its denominator.
        #
        # It also settles the type questions the old shape could not ask. `jq -r` renders every
        # scalar as text, so `.file: 0` arrives as the string `0` and matches a checkout that
        # happens to contain a path named `0` -- passing here, then never matching in judge.sh,
        # which compares the JSON values without coercion. `.file: null` arrives as the literal
        # `null`, and an all-empty row arrives as two bare tabs that `read` (tab is IFS
        # whitespace) collapses into three empty variables.
        if [ "$ok" != ok ]; then
            printf 'malformed gold row: %s -> %s\n' "$(basename -- "$g")" "$file"
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
        # The producer above now guarantees both endpoints are JSON numbers; it does not guarantee
        # they are integers, ordered, or >= 1, which is what this second layer is for.
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
    done < <(jq -r '
        # .note is validated with the same weight as .file and .lines because the judge gives it
        # the same weight: it is interpolated as the gold rows entire defect description
        # (judge.sh:217-219). A row whose note is null or blank reaches the judge as
        # "Defect: null" and can never pair, so it sits in the denominator as a guaranteed miss
        # -- the preflight passing a row that silently depresses recall. build-gold.sh always
        # writes the fix commit subject here, so this guards a hand-edited corpus.
        .gold[] |
        if (.file | type) == "string" and (.file | length) > 0
           and (.lines | type) == "array" and (.lines | length) == 2
           and all(.lines[]; type == "number")
           and (.note | type) == "string" and (.note | test("\\S"))
        then "ok\t\(.file)\t\(.lines[0])\t\(.lines[1])"
        else "bad\t\(tojson)"
        end' "$g")
done

printf '%s: %d documents, %d rows, %d rows outside the reviewed diff\n' \
    "$PROG" "${#gold_files[@]}" "$rows_total" "$rows_outside"

[ "$violations" -eq 0 ] || exit 1
