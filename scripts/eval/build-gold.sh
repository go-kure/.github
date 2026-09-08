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
  --replace     clear existing *.json from --out first (required to rebuild in place)

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
out_dir_dirty=false
if [ -n "$(find -H "$out_dir" -maxdepth 1 -name '*.json' -print -quit)" ]; then
    [ "$replace" = true ] || die "$out_dir already holds gold documents; pass --replace to rebuild it, or use an empty directory"
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
    git_r diff --unified=0 --no-color --no-renames --diff-filter=M \
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
            in_hunk && /^-/ { if (path != "") printf "%s\t%d\n", path, lineno; lineno++ }
        '
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
blame_range() {
    local parent="$1" path="$2" start="$3" end="$4"
    git_r blame --porcelain -w -L "$start,$end" "$parent" -- "$path" 2>/dev/null \
        | awk '/^[0-9a-f]{40} / { print $1 "\t" $2 "\t" $3 }'
}

# confirm_introduction SHA PATH TEXT -- true when SHA's own diff adds exactly TEXT.
#
# This is the check that turns a blame candidate into gold. A reformat that merely
# re-indented the line shows the line as both removed and added with different leading
# whitespace, so comparing the trimmed added text against the trimmed faulty text would
# accept it; we compare the exact text and require it to appear as an addition.
# The wanted text travels through the environment, never through `awk -v`: a -v assignment
# processes escape sequences, so a faulty line containing a backslash -- a regex, a printf
# format, a Windows path -- would be compared in corrupted form and silently fail to confirm.
confirm_introduction() {
    local sha="$1" path="$2" text="$3"
    [ -n "$text" ] || return 1
    git_r show --format= --unified=0 --no-color --src-prefix=a/ --dst-prefix=b/ "$sha" -- "$path" 2>/dev/null \
        | WANT="+$text" awk '$0 == ENVIRON["WANT"] { found = 1; exit } END { exit found ? 0 : 1 }'
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

# Collapse to one row per (introducing sha, file, fix commit), keeping BOTH line spans: the
# span in the introducing commit (orig, columns 3) for the gold row, and the span in the fix's
# parent (final, column 4) for reading the faulty text. Tracking one and deriving the other is
# not possible -- intervening commits shift them by different amounts per line.
sort -u "$candidates" | awk -F'\t' '
    {
        key = $1 "\t" $2 "\t" $5 "\t" $6
        if (!(key in olo) || $3 + 0 < olo[key]) {
            olo[key] = $3 + 0
            # PAIRED with olo, never minimised on its own. The two columns are line numbers in
            # different revisions and blame does not guarantee they rise together: where the
            # parent of the fix reordered lines, the smallest orig line and the smallest final
            # line belong to DIFFERENT rows. Minimising each separately then reads the text at
            # flo for a line the gold row does not name, so confirm_introduction validates
            # evidence belonging to some other line.
            flo[key] = $4 + 0
        }
        if (!(key in ohi) || $3 + 0 > ohi[key]) ohi[key] = $3 + 0
    }
    END {
        for (k in olo)
            printf "%s\t%d\t%d\t%d\n", k, olo[k], ohi[k], flo[k]
    }
' >"$work/spans.tsv"

: >"$work/gold.ndjson"

while IFS=$'\t' read -r sha path fix parent lo hi flo; do
    [ -n "$sha" ] || continue

    if ! printf '%s\n' "$path" | grep -Eq -- "$include_re"; then
        n_dropped_path=$((n_dropped_path + 1))
        continue
    fi

    if [ $((hi - lo + 1)) -gt "$max_span" ]; then
        n_dropped_span=$((n_dropped_span + 1))
        continue
    fi

    # Confirm against the first line of the span as it stood at the fix's parent -- so the
    # PARENT-relative span (flo), never the introducing-commit span (lo) that the gold row
    # carries. Reading `${lo}p` out of `$parent:$path` picks whatever line happens to sit at
    # that offset in a different revision of the file.
    text=$(git_r show "$parent:$path" 2>/dev/null | sed -n "${flo}p")
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
# Staged in the work directory, not written straight into $out_dir: the swap below has to be
# the first thing that touches the caller's corpus, so a failure anywhere above leaves it as it
# was rather than half-replaced.
staging="$work/out"
mkdir -p "$staging" || die "cannot create $staging"

written=0
while read -r doc; do
    [ -n "$doc" ] || continue
    slug=$(printf '%s' "$doc" | jq -r '
        (.repo | gsub("[/ ]"; "-")) + "-"
        + (if .pr == null then (.head_sha[0:12]) else ("pr" + (.pr | tostring)) end)')
    printf '%s\n' "$doc" | jq . >"$staging/$slug.json" || die "cannot write $staging/$slug.json"
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

# The swap. Everything above this line is recoverable; this is the only step that touches the
# caller's corpus, and it runs only now that a complete replacement exists on disk.
if [ "$out_dir_dirty" = true ]; then
    find -H "$out_dir" -maxdepth 1 -name '*.json' -delete || die "cannot clear $out_dir"
    log "--replace: cleared the previous gold documents from $out_dir"
fi
mv -- "$staging"/*.json "$out_dir/" || die "cannot move staged documents into $out_dir"

log "wrote $written documents to $out_dir ($n_no_pr rows carried no PR/MR reference)"
