#!/usr/bin/env bash
# build-gold.sh -- derive an evaluation gold set from a repository's bug-fix history.
#
# For each `fix:` commit F, the lines F deletes or rewrites are the faulty lines. Blaming
# those lines at F^ names the commit that last touched them; that commit, and the pull
# request that carried it, is what a reviewer should have flagged.
#
# `git blame` names the commit that LAST TOUCHED a line, not the one that introduced the
# defect: a reformat, a rename or a whitespace pass in between makes an innocent change the
# accused. So a candidate only enters the gold set once `confirm_introduction` shows the
# blamed commit's own diff ADDS that exact line text. Everything else is dropped and counted.
#
# Output: one JSON document per introducing pull request, written to --out, of the shape
#   {repo, pr, head_sha, base_sha, gold: [{file, lines, fix_commit, note, confirmed}]}
# consumed by scripts/eval/run.sh.

set -uo pipefail

readonly PROG=${0##*/}

die() {
    printf '%s: %s\n' "$PROG" "$*" >&2
    exit 2
}

log() { printf '%s: %s\n' "$PROG" "$*" >&2; }

usage() {
    cat <<'EOF'
usage: build-gold.sh --repo <path> --repo-name <owner/name> --out <dir>
                     [--since <git-date>] [--max-fixes <n>] [--grep <regex>]

  --repo        path to a git checkout to mine
  --repo-name   the name recorded in the output, e.g. go-kure/kure
  --out         directory for the per-PR JSON documents (created if absent)
  --since       only consider fix commits newer than this (default: 2 years ago)
  --max-fixes   stop after this many fix commits (default: 200)
  --grep        subject pattern selecting fix commits (default: ^fix(\(|:| ))
  --include     ERE a gold file path must match (default: source extensions)
  --max-span    drop a gold row wider than this many lines (default: 20)
  --replace     clear --out's existing documents FOR THIS --repo-name first (required to
                rebuild in place). Other repositories' documents are never touched, so a
                corpus spanning several is built by running this once per repository.

exit status
  0  gold rows written
  1  no gold rows survived confirmation
  2  usage or environment error
EOF
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------

repo=
repo_name=
out_dir=
since='2 years ago'
max_fixes=200
subject_re='^fix(\(|:| )'

# A gold row must be something a code reviewer could plausibly have flagged. Prose files are
# excluded by default: a fix that rewords a CHANGELOG entry produces a perfectly well-formed
# gold row against which no reviewer can score, and a set full of them measures documentation
# editing rather than code review.
include_re='\.(go|sh|bash|mjs|js|ts|py|rb|rs|java|c|h|cc|cpp|yaml|yml|json|tf|sql)$'

# A wide blame span means the fix rewrote a block, not that it repaired a located defect;
# the "faulty line" is then an artefact of the rewrite's boundaries. Twenty lines is the
# default cut -- generous enough for a function, tight enough to stay a finding.
max_span=20

# Opt-in to rebuilding into a directory that already holds gold. Off by default because the
# failure it guards is silent: a merged corpus measures fine and reports a number.
replace=false

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) repo=${2-}; shift 2 || die "--repo needs a value" ;;
        --repo-name) repo_name=${2-}; shift 2 || die "--repo-name needs a value" ;;
        --out) out_dir=${2-}; shift 2 || die "--out needs a value" ;;
        --since) since=${2-}; shift 2 || die "--since needs a value" ;;
        --max-fixes) max_fixes=${2-}; shift 2 || die "--max-fixes needs a value" ;;
        --grep) subject_re=${2-}; shift 2 || die "--grep needs a value" ;;
        --include) include_re=${2-}; shift 2 || die "--include needs a value" ;;
        --max-span) max_span=${2-}; shift 2 || die "--max-span needs a value" ;;
        --replace) replace=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$repo" ] || die "--repo is required"
[ -n "$repo_name" ] || die "--repo-name is required"
[ -n "$out_dir" ] || die "--out is required"
[ -d "$repo/.git" ] || [ -f "$repo/.git" ] || die "not a git checkout: $repo"
command -v jq >/dev/null 2>&1 || die "jq is required"
case "$max_fixes" in ''|*[!0-9]*) die "--max-fixes must be a number" ;; esac
case "$max_span" in ''|*[!0-9]*) die "--max-span must be a number" ;; esac

mkdir -p "$out_dir" || die "cannot create $out_dir"

# One builder per output directory, held from before the dirty probe until after the swap.
#
# Without it two --replace runs interleave: both see documents and set out_dir_dirty, the first
# moves them aside, the second's probe now finds an empty directory, and both install. The later
# install overwrites the slugs they share and leaves the earlier run's unique slugs in place --
# the mixed corpus --replace exists to prevent, assembled by the very flag meant to prevent it,
# with nothing on disk recording that it happened. The staging directory's pid suffix keeps the
# two runs from writing over each other's files; it says nothing about the sequence of probe,
# move-aside and install, which is what actually has to be serialised.
#
# Non-blocking: a second builder is a mistake to report, not a queue to join. A build costs
# model calls and the caller almost certainly meant to point it somewhere else.
command -v flock >/dev/null 2>&1 || die "flock is required"
exec 9>"$out_dir/.build.lock" || die "cannot open the build lock in $out_dir"
flock -n 9 || die "another build-gold.sh is building $out_dir; wait for it or use a different --out"

# A rebuild writes one file per surviving candidate and overwrites by slug, so it never removes
# a document the new sweep no longer produces. Change --since, --include, --max-span or the
# history itself and the dropped candidates' files stay behind, where run.sh's gold glob picks
# them up as if they were current -- a corpus that is part one sweep and part another, with
# nothing on disk saying so. Refuse rather than silently merge; --replace is the explicit opt-in.
#
# REFUSE here, DELETE at the end. The mining between this point and the emission loop can die
# on a bad revision or confirm zero rows, and clearing the directory now would leave the caller
# with no corpus at all and nothing to fall back on -- destroying the old measurement inputs to
# produce none. The new documents are staged in the work directory and swapped in only once at
# least one exists.
#
# -H because --out may be a symlink to the real corpus directory, and a bare `find` neither
# follows nor descends a symlink named on the command line: it would report no documents, skip
# both the refusal and the deletion, and then the writes would go through the link anyway --
# leaving the previous sweep's files beside the new ones for run.sh's glob to measure as one
# corpus. -H follows the command-line argument only, which is exactly the path in question.
#
# Scoped to THIS repository's documents, by the `.repo` each one carries. The stale-candidate
# hazard described above is real within a repository and does not exist between two: a corpus
# spans several repositories, their documents share no slug, and a sweep of one says nothing
# about another's. Judging the directory as a whole made a multi-repo corpus unbuildable --
# the second --repo-name refused, and --replace cleared the first one's documents.
#
# By content and not by filename prefix: the slug is the repo name with `/` and space replaced
# by `-` (see the emitter below), so `go-kure/kure` and a `go-kure/kure-tools` would produce
# `go-kure-kure-*` and `go-kure-kure-tools-*`, and a prefix glob for the first matches the
# second. `.repo` is the field the emitter actually wrote; nothing has to be inferred from it.
# A document with no readable `.repo` is treated as another repository's -- left alone rather
# than swept, since deleting what cannot be identified is the one unrecoverable choice here.
#
# One jq per file rather than one batched call: a batched jq aborts on the first unparseable
# input, and the files it had not reached yet would read as "not ours" -- the same silent
# under-sweep this function exists to prevent, in the other direction.
repo_docs() {
    find -H "$out_dir" -maxdepth 1 -name '*.json' -print0 |
        while IFS= read -r -d '' f; do
            [ "$(jq -r '.repo // empty' "$f" 2>/dev/null)" = "$repo_name" ] || continue
            printf '%s\0' "$f"
        done
}

out_dir_dirty=false
if [ -n "$(repo_docs | tr -d '\0')" ]; then
    [ "$replace" = true ] || die "$out_dir already holds gold documents for $repo_name; pass --replace to rebuild them, or use an empty directory"
    out_dir_dirty=true
fi

git_r() { git -C "$repo" "$@"; }

# ---------------------------------------------------------------------------
# candidate extraction
# ---------------------------------------------------------------------------

# removed_lines FIX -- emit "path<TAB>lineno" for every line FIX deletes or rewrites,
# numbered in FIX^ (the pre-image). Binary and pure-addition hunks contribute nothing,
# which is deliberate: a fix that only ADDS missing code has no faulty line to blame.
# `--src-prefix`/`--dst-prefix` are passed explicitly because a user's `diff.noprefix=true`
# otherwise emits `+++ path` instead of `+++ b/path`, and the parser below silently matches
# nothing -- a clean exit reporting zero candidates, indistinguishable from a repo with no fixes.
removed_lines() {
    local fix="$1"
    git_r diff --unified=0 --inter-hunk-context=0 --no-color --no-ext-diff --no-textconv --no-renames --diff-filter=M \
        --src-prefix=a/ --dst-prefix=b/ "$fix^" "$fix" -- \
        | awk '
            # The header rules are position-gated, not pattern-gated. Inside a hunk every body
            # line carries a +/- prefix, so a removed SQL or Lua comment `-- note` arrives as
            # `--- note` and an added `++ b/x` as `+++ b/x`. Matching those as headers anywhere
            # would swallow the removed line without advancing lineno -- shifting every later
            # removed line in the hunk by one and blaming an innocent line -- or silently
            # reassign path mid-file. `in_hunk` closes both: headers precede the first @@ of a
            # file, body lines follow it, and `diff --git` reopens the header region.
            /^diff --git / { in_hunk = 0; path = ""; next }
            !in_hunk && /^--- / { next }
            !in_hunk && /^\+\+\+ b\// { path = substr($0, 7); next }
            /^@@ / {
                # @@ -old_start[,old_count] +new_start[,new_count] @@
                match($0, /-[0-9]+(,[0-9]+)?/)
                spec = substr($0, RSTART + 1, RLENGTH - 1)
                n = split(spec, a, ",")
                lineno = a[1] + 0
                in_hunk = 1
                next
            }
            # A context line occupies an old-file line number just as a removed one does, so it
            # must advance lineno. Only an ADDED line does not exist in the old file. Under a
            # strict -U0 a hunk carries no context, but the caller does not own the repository
            # this runs against: `diff.interHunkContext` (default 0, but 5 on at least one
            # machine this was built on) merges neighbouring hunks and puts the unchanged lines
            # between them into the body. Advancing only on `-` then under-counts by exactly
            # those lines and blames a line the fix never touched -- measured on a two-change
            # file, the second removal was reported at old line 3 instead of 6. The explicit
            # --inter-hunk-context=0 above makes that config irrelevant; this rule makes the
            # parser correct regardless of it, which is the half that survives someone adding
            # another diff flag later.
            in_hunk && /^[- ]/ { if (/^-/ && path != "") printf "%s\t%d\n", path, lineno; lineno++ }
        '
}

# ws_sensitive PATH -- true when a whitespace-only edit to PATH can change what it means.
#
# Indentation is syntax in these formats, so "whitespace-only" does not imply "harmless" the way
# it does in a braces-and-semicolons language: reindenting a Python block moves statements between
# scopes, and reindenting a YAML key moves it between mappings. Both extensions are in the default
# include set (see include_re), so this is a shape the corpus really can contain.
ws_sensitive() {
    case "$1" in
        *.py | *.yaml | *.yml) return 0 ;;
        *) return 1 ;;
    esac
}

# blame_range PARENT PATH START END -- emit "sha<TAB>orig_lineno<TAB>final_lineno" per line.
#
# Both numbers are load-bearing and they are not interchangeable. A porcelain header reads
# `<sha> <orig-lineno> <final-lineno> [<n>]`: `orig` locates the line in the blamed commit's own
# file, `final` locates it in PARENT, the fix's pre-image. The harness needs one of each --
# `final` to read the faulty text out of PARENT, `orig` for the gold row, because run.sh reviews
# the introducing commit's own diff and a judge shown a line number from the wrong revision is
# being asked about a line that is not in what the reviewer saw. Keeping only `final` conflated
# the two silently whenever a later commit inserted or deleted lines above the defect.
#
# `-w` because blame otherwise stops at a reindent, and confirm_introduction cannot catch that
# case: a whitespace-only edit rewrites the line, so blame credits the formatting commit, and
# that commit's diff really does add the reindented text verbatim -- exactly what the check
# tests for. The result is a gold row accusing an innocent formatting change, and a harness
# reviewing a whitespace diff for a defect it does not contain. `-w` walks through to the real
# introduction instead.
#
# Except where whitespace is semantic. There `-w` walks past the commit that BROKE the file: a fix
# repairing an indentation bug in Python or YAML has an introducing commit whose only change was
# whitespace, and `-w` is documented as ignoring exactly that ("ignore whitespace differences",
# `git blame -h`). Blame then names an older revision, the row's head_sha points at a diff from
# before the defect existed, and check-gold.sh cannot tell -- the span really is inside that older
# diff. For those formats the attribution stays exact, and confirm_introduction matches it. The
# two settings must always agree about whitespace; which way they agree is what varies.
blame_range() {
    local parent="$1" path="$2" start="$3" end="$4"
    local wflag=(-w)
    ws_sensitive "$path" && wflag=()
    git_r blame --porcelain "${wflag[@]}" --no-textconv -L "$start,$end" "$parent" -- "$path" 2>/dev/null \
        | awk '/^[0-9a-f]{40} / { print $1 "\t" $2 "\t" $3 }'
}

# confirm_introduction SHA PATH TEXT -- true when SHA's own diff adds EVERY line of TEXT, up to
# whitespace, and removes none of them. TEXT is newline-separated: one entry per line of the span.
#
# This is the check that turns a blame candidate into gold: blame names the commit that last
# touched a line, and this asserts that commit actually ADDED it. TEXT is read from the fix's
# parent, a different revision, so the comparison is a genuine cross-check rather than a
# restatement of what blame already said.
#
# EVERY line, because a gold row is a claim about its whole span and the span is a run of lines,
# not one line. Checking only the first let a two-line row be confirmed by evidence covering half
# of it: a first line that was merely reindented confirms against the older commit, while an
# adjacent second line whose INTERIOR whitespace a later commit changed is walked past by `-w` and
# attributed to that same older commit. Measured on a `.js` two-line span -- commit C adds
# `const label = "a b";`, commit D tightens it to `"ab"`, the fix touches both lines -- the row
# was written naming C, which never wrote the line in the form the row points at, and
# check-gold.sh cannot object because C's diff does add both lines. The interior-exact comparison
# below already rejects that line on its own; it simply was never asked about it.
#
# Whitespace-insensitive exactly where blame_range passes `-w`, because the two must agree; for a
# whitespace-sensitive path both go exact instead, so a reindent is attributed to the commit that
# performed it rather than walked past.
#
# Insensitive at the EDGES only -- leading and trailing runs -- never interior. Interior spacing
# can carry meaning in any language, not just the indentation-sensitive ones: `"a b"` becoming
# `"ab"` is a whitespace-only edit that changes a string literal, and a `-w` blame walks straight
# past it to the older, correct addition. Squashing all whitespace out of the comparison then
# CONFIRMS that older commit, and check-gold.sh cannot object because its diff really did add the
# line. Comparing interior spacing exactly turns that case into a dropped row instead of a wrongly
# attributed one -- the conservative failure, and the only one available without parsing every
# language. Edge whitespace stays ignored because that is the reformat class `-w` exists for:
# reindentation, and trailing-space trimming, neither of which changes a token in any format in
# the default include set.
#
# When a
# line is re-indented between its introduction and the fix, `-w` correctly walks past the
# formatting commit to the real introducer -- but that introducer's diff contains the
# PRE-reindent spelling, while TEXT carries the post-reindent one. An exact comparison then
# fails for every such line, and the row is dropped as unconfirmed: silently, and biased toward
# code nobody has reformatted. Two settings that disagree about whitespace cannot both be right;
# `-w` is the one that has a reason (see blame_range), so this follows it.
#
# Relaxing the comparison alone would reopen what the exact check was guarding, so the guard is
# restated directly instead of relied on as a side effect. A reformat shows the line as BOTH
# removed and added, differing only in indentation -- under a whitespace-insensitive comparison
# both sides match, so "it appears as an addition" stops rejecting it. Measured: a control case
# that the exact check rejected was confirmed once the comparison was loosened and nothing else
# changed. A commit therefore confirms only when it adds a whitespace-equivalent line and does
# NOT also remove one; a genuine introduction adds the line with no counterpart to remove.
# The wanted text travels through the environment, never through `awk -v`: a -v assignment
# processes escape sequences, so a faulty line containing a backslash -- a regex, a printf
# format, a Windows path -- would be compared in corrupted form and silently fail to confirm.
confirm_introduction() {
    local sha="$1" path="$2" text="$3"
    [ -n "$text" ] || return 1
    local exact=0
    ws_sensitive "$path" && exact=1
    git_r show --format= --unified=0 --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$sha" -- "$path" 2>/dev/null \
        | WANT="$text" EXACT="$exact" awk '
            function squash(s) {
                if (exact) return s
                sub(/^[ \t]+/, "", s)
                sub(/[ \t]+$/, "", s)
                return s
            }
            BEGIN {
                exact = (ENVIRON["EXACT"] == "1")
                # One entry per line of the span. A blank entry is unconfirmable, so it fails the
                # whole row rather than being skipped -- `bad` rather than a bare `exit 1`,
                # because an exit in BEGIN still runs END, whose own exit would override it.
                n = split(ENVIRON["WANT"], raw, "\n")
                for (i = 1; i <= n; i++) {
                    w = squash(raw[i])
                    if (w == "") { bad = 1; exit 1 }
                    want[w] = 1
                }
                if (n == 0) { bad = 1; exit 1 }
            }
            # Position-gated exactly as removed_lines already gates its own headers, and for the
            # reason its comment gives: `+++` and `---` are file headers only BEFORE the first @@
            # of a file. Matching them anywhere swallowed body lines that merely begin that way --
            # a C or C++ `++i;` is added as `+++i;` and `--i;` is removed as `---i;`, and those
            # extensions are in the default include set. The added case never set `added`, so a
            # valid pre-increment defect was dropped as unconfirmed and vanished from the gold set;
            # the removed case never set `removed`, which is worse, because `added && !removed`
            # then confirms a line the same commit also deleted. A removed line reading `-- note`
            # renders as `--- note`, so requiring the trailing space of a header is necessary but
            # not sufficient -- hence in_hunk, the same fix already applied to the sibling parser.
            /^diff --git / { in_hunk = 0; next }
            !in_hunk && /^(--- |\+\+\+ )/ { next }
            /^@@ / { in_hunk = 1; next }
            in_hunk && /^\+/ { w = squash(substr($0, 2)); if (w in want) added[w] = 1; next }
            in_hunk && /^-/  { w = squash(substr($0, 2)); if (w in want) removed[w] = 1 }
            END {
                if (bad) exit 1
                # Every wanted line added by this commit, and none of them also removed. One
                # unconfirmed line fails the row: a span is a single claim, so partial evidence
                # for it is no evidence.
                for (w in want) if (!(w in added) || (w in removed)) exit 1
                exit 0
            }
        '
}

# pr_for_commit SHA -- the pull/merge request number, or empty when none is recoverable.
#
# Three shapes are recognised: a GitHub squash-merge subject ending in "(#123)", a GitHub
# merge commit "Merge pull request #123 from ...", and GitLab's "See merge request grp/proj!123"
# trailer. A repository configured to rebase without emitting that trailer -- at least one of
# the private GitLab repositories this harness was built against is -- leaves no reference in
# git at all, so the number is genuinely unavailable rather than merely unmatched.
#
# That is NOT a reason to drop the row. The harness replays the diff base_sha..head_sha through
# the reviewer; the number is provenance for whoever reads the gold file, never an input. Rows
# without one are kept with `pr: null` and identified by their short head SHA.
pr_for_commit() {
    local sha="$1" subject body
    subject=$(git_r log -1 --format=%s "$sha" 2>/dev/null) || return 0
    case "$subject" in
        *'(#'*')')
            printf '%s\n' "$subject" | sed -n 's/.*(#\([0-9][0-9]*\))[^)]*$/\1/p'
            return 0
            ;;
        'Merge pull request #'*)
            printf '%s\n' "$subject" | sed -n 's/^Merge pull request #\([0-9][0-9]*\) .*/\1/p'
            return 0
            ;;
    esac
    body=$(git_r log -1 --format=%b "$sha" 2>/dev/null) || return 0
    printf '%s\n' "$body" | sed -n 's/.*[Ss]ee merge request [^!]*!\([0-9][0-9]*\).*/\1/p' | head -1
}

# ---------------------------------------------------------------------------
# main sweep
# ---------------------------------------------------------------------------

work=$(mktemp -d "${TMPDIR:-/tmp}/build-gold.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$work"' EXIT

candidates=$work/candidates.tsv
: >"$candidates"

n_fixes=0
n_rows=0
n_dropped_unconfirmed=0
n_no_pr=0
n_dropped_path=0
n_dropped_span=0

log "mining $repo_name for fix commits since $since"

while read -r fix; do
    [ -n "$fix" ] || continue
    n_fixes=$((n_fixes + 1))

    # A merge commit has no single pre-image to blame against.
    if [ "$(git_r rev-list --no-walk --count --merges "$fix")" != "0" ]; then
        continue
    fi

    parent=$(git_r rev-parse --verify --quiet "$fix^") || continue

    # Group this fix's removed lines into contiguous per-file ranges, so blame runs
    # once per range rather than once per line.
    removed_lines "$fix" | sort -u -t"$(printf '\t')" -k1,1 -k2,2n \
        | awk -F'\t' '
            {
                if ($1 != path || $2 != prev + 1) {
                    if (path != "") printf "%s\t%d\t%d\n", path, start, prev
                    path = $1; start = $2
                }
                prev = $2
            }
            END { if (path != "") printf "%s\t%d\t%d\n", path, start, prev }
        ' >"$work/ranges.tsv"

    while IFS=$'\t' read -r path start end; do
        [ -n "$path" ] || continue
        blame_range "$parent" "$path" "$start" "$end" \
            | while IFS=$'\t' read -r sha orig_lineno final_lineno; do
                [ -n "$sha" ] || continue
                printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$sha" "$path" "$orig_lineno" "$final_lineno" "$fix" "$parent"
            done
    done <"$work/ranges.tsv" >>"$candidates"

    [ "$n_fixes" -ge "$max_fixes" ] && break
done < <(git_r log --no-merges --format=%H --since="$since" --extended-regexp --grep="$subject_re")

log "scanned $n_fixes fix commits; $(wc -l <"$candidates") blame candidates"

# ---------------------------------------------------------------------------
# confirmation and emission
# ---------------------------------------------------------------------------

# Collapse to one row per CONTIGUOUS RUN of lines sharing an (introducing sha, file, fix
# commit), keeping BOTH line spans: the span in the introducing commit (orig, column 3) for the
# gold row, and the span in the fix's parent (final, column 4) for reading the faulty text.
# Tracking one and deriving the other is not possible -- intervening commits shift them by
# different amounts per line.
#
# Per run, not per key: several commits routinely interleave inside one blamed range, so a
# single commit's lines are not one block. Real case, versions.yaml at ee027242^: b5e10f79
# introduced exactly two lines, orig 124 and orig 129, with three other commits' lines sitting
# between them. min..max over the whole key records [124,129] -- a six-line span for a two-line
# contribution, claiming four lines b5e10f79 never wrote. Two consequences, both silent: the
# --max-span drop test measures the inflated width and keeps rewrites it was meant to reject,
# and the gold row asks the reviewer to flag lines whose defect belongs to a different commit,
# scoring a correct review as a partial miss. Splitting on a gap in orig gives [124,124] and
# [129,129], each an interval the commit genuinely owns.
#
# Sorted by key then numeric orig so a run is detectable in one pass; the run's first record
# carries the smallest orig, which keeps flo paired with olo below.
sort -u -t"$(printf '\t')" -k1,1 -k2,2 -k5,5 -k6,6 -k3,3n "$candidates" | awk -F'\t' '
    {
        k = $1 "\t" $2 "\t" $5 "\t" $6
        # A gap of more than one line ends the run, as does a change of key. An exact repeat of
        # orig does neither -- it is the same line reached twice, not a new interval.
        if (k != key || $3 + 0 > ohi + 1) {
            if (key != "") printf "%s\t%d\t%d\t%s\n", key, olo, ohi, flist
            key = k
            olo = $3 + 0
            ohi = $3 + 0
            # EVERY paired final line, comma-joined, not just the first. Confirmation has to read
            # the text of each line the span claims, and the two columns cannot be derived from
            # one another (see the pairing note below), so the whole list travels with the row.
            flist = $4 + 0
            # Its first element stays PAIRED with olo, never minimised on its own. The two columns
            # are line numbers in different revisions and blame does not guarantee they rise
            # together: where the parent of the fix reordered lines, the smallest orig line and
            # the smallest final line belong to DIFFERENT rows. Minimising each separately then
            # reads the text at that number for a line the gold row does not name, so
            # confirm_introduction validates evidence belonging to some other line. Sorting by
            # orig puts that pairing here, and appending in that order keeps the rest of the list
            # paired too.
        } else if ($3 + 0 > ohi) {
            ohi = $3 + 0
            flist = flist "," ($4 + 0)
        }
    }
    END { if (key != "") printf "%s\t%d\t%d\t%s\n", key, olo, ohi, flist }
' >"$work/spans.tsv"

: >"$work/gold.ndjson"

while IFS=$'\t' read -r sha path fix parent lo hi flist; do
    [ -n "$sha" ] || continue

    if ! printf '%s\n' "$path" | grep -Eq -- "$include_re"; then
        n_dropped_path=$((n_dropped_path + 1))
        continue
    fi

    if [ $((hi - lo + 1)) -gt "$max_span" ]; then
        n_dropped_span=$((n_dropped_span + 1))
        continue
    fi

    # Confirm against EVERY line of the span as it stood at the fix's parent -- so the
    # PARENT-relative line numbers (flist), never the introducing-commit span (lo..hi) that the
    # gold row carries. Reading `${lo}p` out of `$parent:$path` would pick whatever line happens
    # to sit at that offset in a different revision of the file.
    #
    # The blob is read once and all wanted lines pulled out of it in one pass, rather than once
    # per line: a span may hold up to --max-span lines and this loop runs per candidate.
    #
    # awk exits non-zero when it printed fewer lines than were asked for, which is a span naming
    # a line past the end of the file at that revision -- unconfirmable, and silently so if the
    # short result were simply handed on, since confirm_introduction would then check a subset
    # and pass. Counted with a `seen` guard so a repeated line number is asked for once.
    text=$(git_r show "$parent:$path" 2>/dev/null | awk -v list="$flist" '
        BEGIN {
            n = split(list, a, ",")
            for (i = 1; i <= n; i++) if (!(a[i] in seen)) { seen[a[i]] = 1; want[a[i] + 0] = 1; need++ }
        }
        (FNR in want) { print; got++ }
        END { exit (need > 0 && got == need) ? 0 : 1 }
    ') || text=
    if ! confirm_introduction "$sha" "$path" "$text"; then
        n_dropped_unconfirmed=$((n_dropped_unconfirmed + 1))
        continue
    fi

    # Looked up only for rows that survive, so the reported no-reference count describes the
    # gold set that was written rather than every candidate considered.
    pr=$(pr_for_commit "$sha")
    [ -n "$pr" ] || n_no_pr=$((n_no_pr + 1))

    base=$(git_r rev-parse --verify --quiet "$sha^") || continue
    note=$(git_r log -1 --format=%s "$fix")

    # The INTRODUCING commit's own subject, which is what a reviewer of base..head would have
    # seen. `note` is the FIX commit's subject and must never reach the reviewer: mined with
    # --grep '^fix', it names the defect by construction ("fix(nats): reply.replyWithError not
    # s.replyWithError in bootstrap.render schema-version rejection" is a real one), so using it
    # as the review title hands over the answer and measures a reviewer that was told where to
    # look. It stays in the document for the judge and for whoever reads the gold file.
    intro_title=$(git_r log -1 --format=%s "$sha")

    jq -cn \
        --arg repo "$repo_name" --arg pr "$pr" \
        --arg head "$sha" --arg base "$base" --arg intro_title "$intro_title" \
        --arg file "$path" --arg fix "$fix" --arg note "$note" \
        --argjson lo "$lo" --argjson hi "$hi" \
        '{repo: $repo, pr: (if $pr == "" then null else ($pr | tonumber) end),
          head_sha: $head, base_sha: $base, intro_title: $intro_title,
          gold: [{file: $file, lines: [$lo, $hi], fix_commit: $fix,
                  note: $note, confirmed: true}]}' >>"$work/gold.ndjson"
    n_rows=$((n_rows + 1))
done <"$work/spans.tsv"

log "confirmed $n_rows rows; dropped $n_dropped_unconfirmed unconfirmed, $n_dropped_path off-path, $n_dropped_span over --max-span"

if [ "$n_rows" -eq 0 ]; then
    log "no gold rows survived confirmation"
    exit 1
fi

# Merge rows introduced by the same change into one document. Grouping is on head_sha, not
# on `pr`: the PR number is optional (see pr_for_commit), and grouping on a null would collapse
# every reference-less change in the repo into a single document.
# Staged, not written straight into $out_dir: the swap below has to be the first thing that
# touches the caller's corpus, so a failure anywhere above leaves it as it was rather than
# half-replaced.
#
# Staged INSIDE $out_dir rather than in $work, because $work lives under TMPDIR and the two can
# be on different filesystems. A cross-device `mv` is a copy followed by an unlink, not a
# rename: it can exhaust space or fail on a bad sector halfway through, after the deletion below
# has already removed the previous corpus -- destroying the old documents to install a partial
# new set, which is the exact failure the staging exists to prevent. Inside the destination
# every move is a same-filesystem rename, which cannot fail for space.
#
# The name is dot-prefixed so it never matches the *.json globs above or run.sh's gold glob, and
# pid-suffixed so a stale directory from a killed run is never mistaken for this one's. Serialising
# concurrent builders is the lock's job, not the name's.
staging="$out_dir/.staging.$$"
rm -rf "$staging"
mkdir -p "$staging" || die "cannot create $staging"
# Swept on every exit path from here on, including a die between this line and the swap.
trap 'rm -rf "$work" "$staging"' EXIT

written=0
# The names this run installs, recorded here because the install consumes them: a partially
# failed `mv` leaves the moved ones out of the staging directory, so afterwards there is no
# other list of what landed. restore_and_die below removes exactly these and nothing else.
staged_names=()
while read -r doc; do
    [ -n "$doc" ] || continue
    slug=$(printf '%s' "$doc" | jq -r '
        (.repo | gsub("[/ ]"; "-")) + "-"
        + (if .pr == null then (.head_sha[0:12]) else ("pr" + (.pr | tostring)) end)')
    printf '%s\n' "$doc" | jq . >"$staging/$slug.json" || die "cannot write $staging/$slug.json"
    staged_names+=("$slug.json")
    written=$((written + 1))
done < <(jq -s -c '
    group_by(.repo + "@" + .head_sha)
    | map({repo: .[0].repo, pr: .[0].pr,
           head_sha: .[0].head_sha, base_sha: .[0].base_sha,
           intro_title: .[0].intro_title,
           gold: (map(.gold[]) | unique_by(.file + ":" + (.lines | tostring)))})
    | .[]
' "$work/gold.ndjson")

[ "$written" -gt 0 ] || die "no documents were staged; leaving $out_dir untouched"

# The slug is not injective across repositories: `gsub("[/ ]"; "-")` maps `acme/widgets-api` and
# `acme-widgets/api` to the same `acme-widgets-api`, so with the same PR number they claim one
# filename. Scoping the sweep by `.repo` means the other repository's document is deliberately
# NOT moved aside -- correct on its own terms -- and the install below would then overwrite it
# in place, dropping gold rows from a repository this run was never asked to touch, with nothing
# in the output saying so. Refuse instead, before anything has been moved: a corpus that cannot
# hold both is a naming problem for a human, not a merge for this script to attempt.
#
# Checked here rather than at the top because the staged names are not known until the emission
# loop has run; nothing has been touched yet either way.
# The unreadable case gets its own message. It is the same refusal -- this script does not
# delete what it cannot identify, here any more than in repo_docs -- but the remedy is the
# opposite one, and a collision message would send the caller to rename a repository or split
# the corpus when what is actually there is one corrupt file to remove. Refusing with the wrong
# reason is worse than refusing: it is a refusal the caller cannot act on.
for n in "${staged_names[@]}"; do
    [ -e "$out_dir/$n" ] || continue
    owner=$(jq -r '.repo // empty' "$out_dir/$n" 2>/dev/null)
    [ "$owner" = "$repo_name" ] || {
        [ -n "$owner" ] ||
            die "$out_dir/$n exists but has no readable .repo, and this run wants that name; remove or repair that document, then re-run"
        die "$out_dir/$n already belongs to $owner, not $repo_name; two repositories slug to the same filename -- give this one its own --out"
    }
done

# The swap. Everything above this line is recoverable; this is the only step that touches the
# caller's corpus, and it runs only now that a complete replacement exists on disk.
#
# The old documents are moved aside rather than deleted, and restored if any install fails. The
# renames are same-filesystem and so cannot fail for space, but a read-only remount or a
# permissions change between the probe at the top of the script and here still can, and the one
# outcome that must not happen is a caller left with neither corpus.
backup="$out_dir/.superseded.$$"

# Put the previous corpus back and abort with REASON. Clears whatever the failed install did
# land first, so the caller gets the old corpus whole rather than mixed with part of the new
# one. If the restore itself fails, say where the documents actually are -- a message naming a
# directory the caller can move back by hand is worth more than a tidy one that loses them.
#
# By staged NAME, not by a `.repo` sweep. What a failed install leaves is a partial SET, not a
# partial file: staging lives inside $out_dir, so each `mv` is a same-filesystem rename and every
# document that landed is whole. The staged names are the exact record of which ones those were,
# so undoing the install needs no parsing and no reasoning about what else the directory holds.
# The scoped sweep is for the caller's corpus; this is for this run's own writes.
restore_and_die() {
    for n in "${staged_names[@]}"; do
        rm -f -- "$out_dir/$n"
    done
    if find -H "$backup" -maxdepth 1 -name '*.json' -exec mv -t "$out_dir" -- {} +; then
        rmdir "$backup" 2>/dev/null
        die "$1; restored the previous corpus"
    fi
    die "$1, AND the previous corpus could not be restored; it is in $backup"
}

if [ "$out_dir_dirty" = true ]; then
    mkdir -p "$backup" || die "cannot create $backup; $out_dir is unchanged"
    repo_docs | xargs -0 -r mv -t "$backup" -- ||
        restore_and_die "cannot move the previous gold documents aside"
    log "--replace: moved the previous $repo_name documents aside"
fi

if ! mv -- "$staging"/*.json "$out_dir/"; then
    [ "$out_dir_dirty" = true ] || die "cannot install the staged documents into $out_dir"
    restore_and_die "cannot install the staged documents into $out_dir"
fi

if [ "$out_dir_dirty" = true ]; then
    rm -rf "$backup" || log "warning: cannot remove $backup"
fi

log "wrote $written documents to $out_dir ($n_no_pr rows carried no PR/MR reference)"
