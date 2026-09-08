#!/usr/bin/env bash
# run.sh -- measure a reviewer against the gold set, several times, and report the spread.
#
# One "run" reviews every gold document once and judges the result. The harness does at least
# three runs because a single number here is not a measurement: an independent study of this
# method put the run-to-run noise floor at ~6 goldens out of 136 labelled bugs, which is
# larger than most differences anyone would want to act on. --max-spread is the gate that
# stops a too-noisy result being quoted as a baseline.
#
# WHAT THIS REPORTS, AND WHAT IT DELIBERATELY DOES NOT
#
# It reports GOLD-MATCH RECALL and a count of uncredited findings. It does not report
# precision, and the missing metric is a property of the gold set rather than an omission.
# The gold set is mined from commits that fixed a bug, so it contains only defects somebody
# eventually filed. A reviewer that names a real defect nobody ever fixed produces an
# uncredited finding, and scoring that as a false positive would punish the better reviewer
# and invert the Phase 2 comparison this harness exists to decide. Recall is sound under this
# construction; precision is not, so it is not printed. See eval/README.md.
#
# usage
#   run.sh --gold '<glob>' --engine chat --runs 3 --max-spread <f> --out <file>
#          --checkout <repo-name>=<path> [--readme <file>] [--no-assess]
#
# Per-run stdout is one line:
#   run=N R=<recall> matched=<n>/<denom> uncredited=<n> excluded=<n>/<docs> docs=<n>/<rows> rows
#
# Both exclusion units are printed because they are not interchangeable: exclusion happens per
# document, but --max-excluded gates the row fraction, which is the one that bounds how much of
# the corpus the recall actually describes.
#
# The denominator is the gold rows of the documents that RETURNED a verdict this run, not the
# whole gold set. A document the reviewer or judge could not produce a usable answer for is
# excluded from both sides of the fraction rather than scored as a miss -- see do_run.
# The summary line is `mean_r=<f> spread=<f> runs=<n>`.
#
# exit status
#   0  measured, and the spread is within --max-spread
#   1  a run failed (reviewer or judge produced no usable verdict)
#   2  usage error, including --runs < 3 or a gold row without `confirmed: true`
#   3  the spread exceeds --max-spread: the result is too noisy to quote

set -uo pipefail

readonly PROG=${0##*/}

die() {
    printf '%s: %s\n' "$PROG" "$*" >&2
    exit 2
}

log() { printf '%s: %s\n' "$PROG" "$*" >&2; }

usage() {
    cat <<'EOF'
usage: run.sh --gold '<glob>' --engine <chat> --runs <n> --out <file>
              --checkout <repo-name>=<path> [--max-spread <f>] [--readme <file>] [--no-assess]

  --gold        glob matching the gold documents (quote it; this script expands it)
  --engine      chat (the shipped diff-only reviewer). service arrives with Phase 2b.
  --runs        how many times to repeat the whole measurement; minimum 3
  --checkout    map a gold document's `repo` to a local clone; repeatable
  --out         write the summary JSON here
  --max-spread  refuse (exit 3) when max(R) - min(R) exceeds this
  --max-excluded  fraction of gold ROWS a run may lose to reviewer/judge failure before it
                  stops being measurable (default 0.15). Rows, not documents: exclusion
                  happens per document, but documents carry between one and a dozen rows
                  each, so only a row fraction bounds how much of the corpus is lost.
  --readme      rewrite this file's `baseline mean_r=` line from the measured result
  --standards   org standards doc to forward; default is docs/standards.md at the SHA the
                shipped workflow pins its action to, which is what production reads
  --context     map a gold document's `repo` to the project-context string that repository's
                own workflow passes production as PRT_PROJECT_CONTEXT; repeatable, empty for
                any repo not named, and NEVER inherited from the environment. The whole
                mapping's digest is recorded and compare.sh gates on it
  --no-assess   skip the reviewer's assessment pass. Measures the review call alone, which is
                NOT the shipped product; the result records assess:false and compare.sh
                refuses to compare it against an assessed one

exit status
  0  measured      1  a run failed      2  usage error      3  spread too wide
EOF
}

gold_glob=
engine=chat
runs=0
out_file=
max_spread=
# 0.15 is a ceiling on how much of the gold set may vanish before a run stops describing it, not
# a target, and it is read as a fraction of gold ROWS (see the gate below). Its origin is the
# first live subset, where one document of 12 was excluded -- 0.083 of the documents, comfortably
# inside the ceiling, which is the shape wanted: one flaky response passes, a systemic backend
# fault does not. That event's ROW fraction was never recorded, so this default is inherited
# rather than re-derived; re-measure it once a run reports excluded_rows_max over a full corpus.
# Carried across because a fat document is worth several thin ones, so if the two fractions
# diverge here the row one is the larger, and inheriting it errs toward refusing a run.
max_excluded=0.15
readme_file=
standards_override=
# Assessment is ON by default, because production always runs it: pr-review-threads.sh:507-518
# loops over every chunk unconditionally, and reconcile.sh never publishes a FALSE_POSITIVE. A
# single-pass measurement therefore credits the reviewer with findings its own second pass would
# have withdrawn, and the filter further down -- which drops FALSE_POSITIVE precisely to avoid
# that -- becomes a no-op with nothing to say so. The flag used to be opt-in and the documented
# baseline command omitted it, so the number that Phase 2 is judged against measured half the
# shipped pipeline.
assess=true
assess_flag=(--assess)
# Keyed by repo, exactly like `checkouts`, because the value IS per repository: each consumer
# passes its own `pr_review_context` to the reusable workflow, and the three live ones differ
# (a Go library, a CLI package manager, this workflows repo). A corpus spanning two of them
# reviewed under one string measures at least one under a prompt production never sends.
# Never defaulted from PRT_PROJECT_CONTEXT -- see the --context forward in do_run. An inherited
# value would enter both prompts and be recorded nowhere.
declare -A contexts=()
declare -A context_warned=()
declare -A checkouts=()

while [ $# -gt 0 ]; do
    case "$1" in
        --gold) gold_glob=${2-}; shift 2 || die "--gold needs a value" ;;
        --engine) engine=${2-}; shift 2 || die "--engine needs a value" ;;
        --runs) runs=${2-}; shift 2 || die "--runs needs a value" ;;
        --out) out_file=${2-}; shift 2 || die "--out needs a value" ;;
        --max-spread) max_spread=${2-}; shift 2 || die "--max-spread needs a value" ;;
        --max-excluded) max_excluded=${2-}; shift 2 || die "--max-excluded needs a value" ;;
        --readme) readme_file=${2-}; shift 2 || die "--readme needs a value" ;;
        --standards) standards_override=${2-}; shift 2 || die "--standards needs a value" ;;
        --no-assess) assess=false; assess_flag=(); shift ;;
        --context)
            case "${2-}" in
                *=*) contexts["${2%%=*}"]="${2#*=}" ;;
                *) die "--context wants <repo-name>=<string>, got: ${2-}" ;;
            esac
            shift 2 || die "--context needs a value"
            ;;
        --checkout)
            case "${2-}" in
                *=*) checkouts["${2%%=*}"]="${2#*=}" ;;
                *) die "--checkout wants <repo-name>=<path>, got: ${2-}" ;;
            esac
            shift 2 || die "--checkout needs a value"
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$gold_glob" ] || die "--gold is required"
[ -n "$out_file" ] || die "--out is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

case "$runs" in ''|*[!0-9]*) die "--runs must be a number" ;; esac
# Three is a floor, not a default: a run count below it cannot produce a spread that means
# anything, and a spread is the only thing separating a real difference from judge noise.
[ "$runs" -ge 3 ] || die "--runs must be at least 3 (got $runs); a spread needs repetition"

case "$engine" in
    chat) ;;
    service) die "engine 'service' arrives with the review service (Phase 2b); not built yet" ;;
    *) die "unknown engine: $engine" ;;
esac

# require_number NAME VALUE -- die unless VALUE is something jq will accept as a number.
#
# A `case` glob is NOT sufficient here, and the difference is a gate that fails open. The
# pattern `''|*[!0-9.]*` admits `.5`, `1.2.3` and a bare `.`; `jq --argjson m .5` then aborts
# with "Invalid JSON text" and prints nothing, so a later `[ "$(jq …)" = "true" ]` compares the
# empty string, reads false, and the gate silently passes a result it exists to reject. The
# only validator that agrees with the consumer is the consumer's own parser.
require_number() {
    jq -e -n --argjson v "$2" '(. // $v) | type == "number"' >/dev/null 2>&1 \
        || die "$1 must be a number (got: $2)"
}

if [ -n "$max_spread" ]; then
    require_number --max-spread "$max_spread"
fi

require_number --max-excluded "$max_excluded"
jq -e -n --argjson m "$max_excluded" '$m >= 0 and $m <= 1' >/dev/null \
    || die "--max-excluded is a fraction of the gold rows, so it must be within 0..1 (got $max_excluded)"

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || die "cannot resolve script dir"
adapter="$here/review-adapter.sh"
judge="$here/judge.sh"
[ -x "$adapter" ] || die "not executable: $adapter"
[ -x "$judge" ] || die "not executable: $judge"

# ---------------------------------------------------------------------------
# gold inputs
# ---------------------------------------------------------------------------

# The glob is expanded here rather than by the caller's shell so the usage line above can be
# copied verbatim (quoted) without the caller's cwd deciding what gets measured.
gold_files=()
while IFS= read -r line; do
    [ -n "$line" ] && gold_files+=("$line")
done < <(compgen -G "$gold_glob" || true)

[ "${#gold_files[@]}" -gt 0 ] || die "no gold documents matched: $gold_glob"

# Hold a SHARED lock on every corpus directory for the whole run.
#
# build-gold.sh takes an EXCLUSIVE lock on `<corpus>/.build.lock`, which serialises builder
# against builder but says nothing about a reader. Its --replace swap cannot be atomic -- the
# previous documents are moved aside and the new ones installed one by one -- so a measurement
# starting mid-swap sees an empty or half-installed corpus. That does not fail: the glob simply
# matches fewer files, and the run reports a recall over whatever subset existed at that instant,
# with a gold_tree that faithfully digests it. A wrong number with correct provenance.
#
# The fds are deliberately never closed: they are released when the script exits, which is
# exactly how long the corpus has to stay still, since each run re-reads every document.
command -v flock >/dev/null 2>&1 || die "flock is required"
declare -A corpus_dirs=()
for g in "${gold_files[@]}"; do
    d=$(dirname -- "$g")
    [ -z "${corpus_dirs[$d]:-}" ] || continue
    corpus_dirs[$d]=1
    # Opened for append rather than read so the lock exists even for a corpus that build-gold.sh
    # never wrote; an absent lock file would otherwise mean a build could create one and start
    # swapping while this run believed it had nothing to wait for.
    exec {lock_fd}>>"$d/.build.lock" || die "cannot open the build lock in $d"
    flock -s -w 600 "$lock_fd" \
        || die "timed out waiting for a build to finish in $d; it holds $d/.build.lock"
done

# Re-expand and compare. The window between the glob above and the locks just taken is small but
# real, and it is the one a --replace swap would land in. Comparing the two expansions is what
# turns a silently shrunken corpus into an error.
gold_recheck=()
while IFS= read -r line; do
    [ -n "$line" ] && gold_recheck+=("$line")
done < <(compgen -G "$gold_glob" || true)
if [ "${gold_files[*]}" != "${gold_recheck[*]}" ]; then
    die "the gold corpus changed while this run was starting (${#gold_files[@]} documents, then ${#gold_recheck[@]}); a build was in progress -- re-run it"
fi

# Every row must carry `confirmed: true`. A blame candidate that was never confirmed accuses
# whichever commit last touched the line, which may be a reformat; measuring recall against
# it measures nothing.
for g in "${gold_files[@]}"; do
    jq -e '(.gold | length) > 0 and all(.gold[]; .confirmed == true)' "$g" >/dev/null \
        || die "gold document has unconfirmed or empty rows: $g"
done

gold_total=0
for g in "${gold_files[@]}"; do
    gold_total=$((gold_total + $(jq '.gold | length' "$g")))
done
log "${#gold_files[@]} gold documents, $gold_total gold rows, engine=$engine, runs=$runs"

# gold_tree identifies the INPUTS, not the checkout: two results are comparable only when they
# read the same gold bytes, and compare.sh refuses to compare across differing values.
#
# It is computed from the files actually read, never from `git rev-parse HEAD:./`. The committed
# tree hash answers a different question -- what the corpus looks like in git -- and the two
# diverge exactly when it matters most: build-gold.sh writes into a working tree, so the normal
# build-then-run sequence measures uncommitted or modified documents while HEAD still names the
# previous corpus. Two runs over different bytes would then carry the same gold_tree and compare
# as though they were comparable. Hashing the content cannot drift from what was measured.
#
# Sorted by path so the value does not depend on glob expansion order, and the path is included
# in the digest so moving a document between files is a different corpus.
#
# The path recorded is relative to the corpus root -- the longest directory prefix common to
# every matched file -- not the basename and not the absolute path. Each of the other two is
# wrong in one direction. A basename cannot tell `a/x.json` from `b/x.json`, so a glob spanning
# subdirectories digests two different selections identically and compare.sh calls them
# comparable; an absolute path makes the digest depend on where the repository happens to be
# checked out, so the same corpus measured on two machines would refuse to compare. When every
# file sits in one directory the relative path IS the basename, so the value is unchanged from
# the single-directory case this has always been used for.
gold_abs=()
for g in "${gold_files[@]}"; do
    a=$(realpath -e -- "$g") || die "cannot resolve gold path: $g"
    gold_abs+=("$a")
done
corpus_root=$(printf '%s\n' "${gold_abs[@]}" | awk -F/ '
    NR == 1 { n = NF - 1; for (i = 1; i <= n; i++) p[i] = $i; next }
    {
        if (NF - 1 < n) n = NF - 1
        for (i = 1; i <= n; i++) if ($i != p[i]) { n = i - 1; break }
    }
    END { out = ""; for (i = 1; i <= n; i++) if (p[i] != "") out = out "/" p[i]; print out }
') || die "cannot determine the corpus root"
[ -n "$corpus_root" ] || corpus_root=/

gold_dir=$(cd -- "$(dirname -- "${gold_files[0]}")" && pwd)
gold_sha=$(git -C "$gold_dir" rev-parse HEAD 2>/dev/null || echo unknown)
#
# Each file's digest is checked on its own. Inside a command substitution used as an argument,
# a failed `sha256sum <"$g"` -- an unreadable file, a vanished one -- contributes an empty
# string and printf still succeeds, so the outer `|| die` only ever sees the exit status of the
# trailing `cut`. The corpus would then be stamped with a gold_tree digesting a blank where a
# document should have been, and two runs that read different bytes would compare as equal.
gold_digests=$(
    for a in "${gold_abs[@]}"; do
        h=$(sha256sum <"$a") || exit 1
        rel=${a#"${corpus_root%/}"/}
        printf '%s  %s\n' "${h%% *}" "$rel"
    done
) || die "cannot digest the gold corpus"
gold_tree=$(printf '%s\n' "$gold_digests" | LC_ALL=C sort | sha256sum | cut -d' ' -f1) ||
    die "cannot digest the gold corpus"

workdir=$(mktemp -d "${TMPDIR:-/tmp}/eval-run.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$workdir"' EXIT

# The standards doc, at the revision the SHIPPED workflow reads it from -- which is not this
# working tree.
#
# The action resolves standards-file relative to its OWN checkout, and the workflow pins that
# action to a SHA (.github/workflows/pr-review.yml). So production reads docs/standards.md as
# of the pin, while an unqualified read here takes whatever is checked out, including work in
# progress. The difference is not cosmetic: a rule absent from PROJECT STANDARDS forces every
# finding citing it to FALSE_POSITIVE (lib/prt/model.sh), and this harness now filters those
# before judging -- so an edit to standards.md on this branch silently moves measured recall
# without touching the reviewer at all. Two runs meant to differ only by engine would differ by
# their standards doc instead.
#
# Resolution order: --standards wins; otherwise the blob at the pinned SHA; otherwise the
# working tree, with a warning naming what was used. Each arm logs, because "which standards
# did that number see" is not recoverable from the output afterwards.
repo_root="$here/../.."
standards_file=
# Which arm resolved it, recorded in the summary JSON alongside a digest of the bytes. Without
# both, two results are indistinguishable when they read different documents: the pinned arm and
# the working-tree fallback differ by exactly the edit under review, and compare.sh could
# otherwise declare a fallback run and a pinned run comparable because their gold_tree matches.
# The digest is the authority (it detects an edited working tree under an unchanged label); the
# source string is what makes a mismatch readable when it fires.
standards_source=none
if [ -n "$standards_override" ]; then
    standards_file=$standards_override
    [ -f "$standards_file" ] || die "no standards doc at $standards_file"
    standards_source="override:$(basename -- "$standards_file")"
    log "standards: $standards_file (--standards)"
else
    standards_pin=$(awk 'match($0, /pr-review-threads@[0-9a-f]{40}/) {
                             print substr($0, RSTART + 18, 40); exit }' \
                    "$repo_root/.github/workflows/pr-review.yml" 2>/dev/null)
    if [ -n "$standards_pin" ] &&
        git -C "$repo_root" cat-file -e "$standards_pin:docs/standards.md" 2>/dev/null; then
        standards_file="$workdir/standards.md"
        if git -C "$repo_root" show "$standards_pin:docs/standards.md" >"$standards_file" 2>/dev/null; then
            standards_source="pin:$standards_pin"
            log "standards: docs/standards.md at the pinned action ${standards_pin:0:8}"
        else
            standards_file=
        fi
    fi
    if [ -z "$standards_file" ]; then
        standards_file="$repo_root/docs/standards.md"
        if [ -f "$standards_file" ]; then
            standards_source=worktree
            log "warning: reading docs/standards.md from the working tree, not the action pin${standards_pin:+ ($standards_pin unavailable -- fetch it for a faithful measurement)}"
        else
            log "warning: no standards doc found; standards-violation findings will assess as FALSE_POSITIVE"
        fi
    fi
fi

# Digest the bytes actually forwarded, not the path they came from. A missing doc digests as the
# literal string `none` rather than being omitted: an absent key would read as "an older run that
# did not record this" and compare.sh would have to guess, whereas `none` is a positive statement
# that the reviewer got no standards at all -- a condition that forces every standards-violation
# finding to FALSE_POSITIVE and so is precisely what must not be silently compared against a run
# that had one.
standards_sha=none
if [ -n "$standards_file" ] && [ -f "$standards_file" ]; then
    standards_sha=$(sha256sum <"$standards_file") || die "cannot digest $standards_file"
    standards_sha=${standards_sha%% *}
fi

# The project-context string is the third input to a prompt, alongside the standards doc and the
# repository's own AGENTS.md/CLAUDE.md: production forwards a per-repository value
# (`action.yml:105` -> `PRT_PROJECT_CONTEXT`) into both the review and the assess call. Two runs
# over the same gold tree with different context strings are not comparable, and nothing in the
# numbers shows it -- so it is digested here for the same reason the standards doc is. `none`
# rather than an absent key, so an older result and an explicitly empty one stay distinguishable.
#
# The WHOLE mapping is digested, not one string: with a per-repo map, a digest of any single entry
# would call two runs comparable while a second repository's prompt differed between them. Sorted
# and NUL-delimited so the digest depends on the mapping's content alone -- not on flag order, and
# not on a separator that could appear inside a repo name or a context string.
context_sha=none
if [ "${#contexts[@]}" -gt 0 ]; then
    context_sha=$(
        while IFS= read -r -d '' repo; do
            printf '%s\0%s\0' "$repo" "${contexts[$repo]}"
        done < <(printf '%s\0' "${!contexts[@]}" | sort -z) | sha256sum
    ) || die "cannot digest --context"
    context_sha=${context_sha%% *}
fi

# show_blob CHECKOUT REV PATH -- print PATH's contents at REV, following in-tree symlinks.
#
# `git show <rev>:<path>` on a symlink prints the LINK TARGET, not the file: a repository whose
# .claude/CLAUDE.md points at ../AGENTS.md yields the literal string "../AGENTS.md" (verified).
# Production reads the working tree with `cat`, which follows the link, so without this the
# harness feeds a one-line path where the shipped reviewer gets a whole standards document --
# and it fails silently, because a 12-byte context file is still a context file.
#
# PATH is walked one component at a time, because a symlink is just as likely to sit in a
# DIRECTORY component as at the leaf. Git stores `.claude -> config` as a link blob, so no tree
# path `.claude/CLAUDE.md` exists at all and a whole-path lookup returns nothing -- silently
# dropping a context file that production's `cat` reads straight through the link. Resolving
# only the leaf would leave that case measuring a reviewer given less than the shipped one gets.
#
# `..` is resolved BY THE WALK, in traversal order, never collapsed lexically beforehand. The two
# disagree whenever a cancelled component does not exist or is not a directory: production's `cat`
# hands `missing/../real.md` to the kernel, which stats `missing`, gets ENOENT and reads nothing,
# while a lexical collapse yields `real.md` and reads it -- the harness feeding the reviewer a
# document the shipped one never sees. Walking it component by component is the same order the
# kernel uses, and it costs nothing extra here because every component is already looked up.
#
# A `..` that would leave the repository root FAILS rather than clamping at it. Clamping silently
# rewrites what the link means: a root `AGENTS.md -> ../shared.md` names a file OUTSIDE the
# checkout, which production's `cat` follows (`pr-review-threads.sh:250-253`) and which git cannot
# store as a tree entry; clamped it becomes `shared.md`, so the harness would read an unrelated
# in-repository file of that name. Wrong context is worse than absent context, because absent
# context is at least visible as a shorter prompt.
#
# Bounded rather than recursive: a symlink cycle in a historical tree would otherwise hang the
# run, and no legitimate case needs more than a hop or two. Returns 1 if the path does not
# resolve to a regular blob, leaving the caller to treat the context as absent.
# is_traversable MODE -- true when a `.` or `..` may step through a component of this mode.
#
# A tree, obviously. A GITLINK (160000) too, and that is the non-obvious half: an uninitialised
# submodule is still a real, empty DIRECTORY in a working tree -- git creates it during checkout
# -- so production's `cat sub/../real.md` reads the file (verified: `[ -f sub/../real.md ]` is
# true in a fresh clone with the submodule unfetched, which is what actions/checkout produces by
# default). Rejecting 160000 here would drop context the shipped reviewer receives, which is the
# same silent divergence the `.` and trailing-separator checks exist to close, in the opposite
# direction. Traversal only: the final-mode test below still admits regular blobs alone, so a
# gitlink named AS the context file remains absent -- correctly, since its contents are not in
# this tree and the checked-out directory is empty.
is_traversable() {
    case "$1" in
        040000 | 160000) return 0 ;;
        *) return 1 ;;
    esac
}

show_blob() {
    local checkout="$1" rev="$2" path="$3"
    local hops=0 mode='' target comp parent resolved='' rest="$path"

    # A trailing separator is an assertion that the path names a DIRECTORY -- `real.md/` is not
    # `real.md`, and production's `[ -f ]` rejects it before reading (`pr-review-threads.sh:250-253`).
    # The walk skips empty components, so without this the separator simply evaporates and a link
    # `AGENTS.md -> real.md/` would hand the reviewer a document production never opens. A
    # directory is never a context file, so the assertion is always fatal here; it is checked at
    # both points a path enters the walk.
    case "$rest" in */) return 1 ;; esac

    while [ -n "$rest" ]; do
        comp=${rest%%/*}
        if [ "$comp" = "$rest" ]; then rest=''; else rest=${rest#*/}; fi
        [ -n "$comp" ] || continue

        if [ "$comp" = "." ]; then
            # `.` asserts that what precedes it is a DIRECTORY, exactly as a trailing separator
            # does one line up: the kernel's stat("real.md/.") is ENOTDIR, and production's
            # `[ -f ]` rejects the path before reading it. Skipping every `.` unconditionally
            # kept the already-resolved regular-file mode and then emitted that blob, so a
            # historical link `AGENTS.md -> real.md/.` handed the reviewer a document production
            # never opens -- the same defect as the trailing separator, one component earlier.
            # An empty `resolved` is the repository root, which IS a directory, so a leading
            # `./AGENTS.md` stays legal.
            [ -z "$resolved" ] || is_traversable "$mode" || return 1
            continue
        fi

        if [ "$comp" = ".." ]; then
            # Nothing to leave means the link escapes the repository root; leaving something that
            # is not a tree is the kernel's ENOTDIR. `mode` is the component just resolved, so it
            # is set whenever `resolved` is non-empty.
            [ -n "$resolved" ] || return 1
            is_traversable "$mode" || return 1
            if [ "${resolved%/*}" = "$resolved" ]; then resolved=''; else resolved=${resolved%/*}; fi
            mode=040000
            continue
        fi

        resolved=${resolved:+$resolved/}$comp

        mode=$(git -C "$checkout" ls-tree "$rev" -- "$resolved" 2>/dev/null | awk '{print $1; exit}')
        [ -n "$mode" ] || return 1
        [ "$mode" = 120000 ] || continue

        hops=$((hops + 1))
        [ "$hops" -lt 16 ] || return 1
        target=$(git -C "$checkout" show "$rev:$resolved" 2>/dev/null) || return 1
        case "$target" in
            /*) return 1 ;;  # absolute link: nothing in the tree to resolve it against
        esac

        # Re-queue the target rather than adopting it as an already-resolved prefix: a target
        # may itself traverse a link (`.claude -> alias/subdir` with `alias -> real`), and
        # treating it as one settled path looks `alias/subdir` up whole, finds no such tree
        # entry, and drops the context file. Pushing its components back onto the walk gives
        # them the same per-component resolution the original path got, to any depth. The hop
        # budget spans the whole walk, so a cycle still terminates rather than re-queueing
        # forever.
        parent=$resolved
        if [ "${parent%/*}" = "$parent" ]; then parent=''; else parent=${parent%/*}; fi
        # Spliced in raw, `..` and all: the walk above resolves those against the tree in order.
        # Re-walking the parent components is safe and costs a few `ls-tree` calls -- any symlink
        # among them would have restarted the walk when it was first reached, so everything in
        # `parent` is a plain tree entry by construction.
        rest=${parent:+$parent/}$target${rest:+/$rest}
        case "$rest" in */) return 1 ;; esac  # see the entry check: a link target may carry one too
        resolved=''
        mode=''
    done

    # A tree, a gitlink or an empty walk is not a context file; only a regular blob is.
    case "$mode" in
        100644 | 100755) git -C "$checkout" show "$rev:$resolved" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# one run
# ---------------------------------------------------------------------------

# do_run RUN_INDEX -- prints "matched<TAB>uncredited<TAB>denominator<TAB>excluded".
# Returns 1 only on a setup fault; a model-side failure excludes one document instead.
#
# The two failure kinds are not the same event and must not share an exit path. A missing
# --checkout, an unresolvable revision or an empty diff is deterministic: it fails identically
# on every run, so continuing would measure a gold set the caller did not ask for. Those still
# abort.
#
# A reviewer or judge failure is the backend being nondeterministic, which is the property this
# harness exists to quantify. Measured on the first live subset run: one document in 12 came
# back with a finding that normalize rejected, and one lost its connection mid-run -- and each
# killed the whole three-run measurement, so the harness could not produce the number it was
# built for. Over 43 documents times 3 runs the chance of at least one such event approaches
# certainty.
#
# An excluded document leaves the DENOMINATOR as well as the numerator: scoring its gold rows
# as missed would be the same error the adapter refuses to make when it exits 1 rather than
# reporting an empty finding set -- "no signal" is not "no defects". Exclusions are counted and
# reported per run, and --max-excluded gates the fraction, because a result assembled from a
# shifting subset of the gold set stops being comparable to one that read all of it.
do_run() {
    local run_idx="$1"
    local matched=0 uncredited=0 denom=0 excluded=0
    # WHICH documents were excluded, not just how many. A count cannot answer the question
    # compare.sh has to ask -- see the coverage gate there.
    local -a excluded_docs=()
    local g repo checkout diff_file findings_file judge_input verdict_file rows child_rc
    local chunks_failed agents_file claude_md_file
    local -a context_flag
    local v_matched v_uncredited

    for g in "${gold_files[@]}"; do
        repo=$(jq -r '.repo' "$g")
        checkout=${checkouts[$repo]:-}
        [ -n "$checkout" ] || { log "no --checkout for repo $repo (gold: $g)"; return 1; }

        local base head title
        base=$(jq -r '.base_sha' "$g")
        head=$(jq -r '.head_sha' "$g")

        # The INTRODUCING commit's subject, and never `.gold[0].note`. `note` is the FIX
        # commit's subject, mined with --grep '^fix', so it names the defect by construction --
        # "fix(nats): reply.replyWithError not s.replyWithError in bootstrap.render
        # schema-version rejection" was a real title handed to the reviewer. Passing it as the
        # title of the pre-fix diff tells the reviewer the answer and measures how well it can
        # copy a hint, which is not recall. A gold set built before intro_title existed has no
        # leak-free title available, so it gets a neutral constant rather than a silent fallback
        # to the note. Blank counts as missing, and blank means no non-whitespace character, not
        # merely the empty string: `"   "` has length 3, is not a commit subject, and would review
        # the diff under three spaces -- neither the real title nor the neutral constant. The type
        # test comes first because `test` on a number is an error, not a false.
        title=$(jq -r 'if (.intro_title | type) == "string" and (.intro_title | test("\\S"))
                       then .intro_title else "change under review" end' "$g")

        diff_file="$workdir/run$run_idx-$(basename "$g" .json).diff"
        # --src-prefix/--dst-prefix explicitly: a user's diff.noprefix=true otherwise emits
        # headers the chunker's file-boundary split cannot see, silently collapsing the whole
        # diff into one record.
        git -C "$checkout" diff --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ "$base" "$head" \
            >"$diff_file" 2>/dev/null \
            || { log "cannot diff $base..$head in $checkout"; return 1; }
        [ -s "$diff_file" ] || { log "empty diff for $g"; return 1; }

        rows=$(jq '.gold | length' "$g")

        # Both children reserve exit 2 for a setup fault (their own `die`) and exit 1 for "the
        # backend gave me nothing usable". Only the second is an exclusion; folding exit 2 into
        # it would let a deterministic harness fault -- a malformed diff, an unreadable gold
        # file -- burn one exclusion per document and land as a shrunken denominator instead of
        # an error, which is the same "no signal scored as no defects" mistake one level up.
        # Repo guidance, as the shipped reviewer gets it. pr-review-threads.sh loads AGENTS.md
        # and .claude/CLAUDE.md into the system prompt, so a harness that omits them measures a
        # context-free reviewer and then ranks engines by a prompt nothing in CI ever sends --
        # and the rule-guided configuration is precisely the one published work finds largest,
        # so the omission suppresses the effect most likely to differentiate candidates.
        #
        # Read at the REVIEWED revision, not from the checkout's worktree: these documents are
        # years of commits ahead of most gold documents, and feeding today's standards to a
        # review of an old commit measures the reviewer against rules its author could not have
        # followed. Absent files simply yield no flag; the adapter treats them as optional.
        context_flag=()
        agents_file="$workdir/run$run_idx-$(basename "$g" .json).agents.md"
        if show_blob "$checkout" "$head" AGENTS.md >"$agents_file" 2>/dev/null \
            && [ -s "$agents_file" ]; then
            context_flag+=(--agents "$agents_file")
        fi
        claude_md_file="$workdir/run$run_idx-$(basename "$g" .json).claude.md"
        if show_blob "$checkout" "$head" .claude/CLAUDE.md >"$claude_md_file" 2>/dev/null \
            && [ -s "$claude_md_file" ]; then
            context_flag+=(--claude-md "$claude_md_file")
        fi

        # The org standards doc, from THIS repository rather than the reviewed checkout --
        # pr-review-threads.sh resolves PRT_STANDARDS_FILE relative to its own script dir, not
        # the target repo, because the standards live here and apply to every consumer.
        #
        # Omitting it silently deletes findings rather than merely weakening the prompt, and it
        # does so through the assessment pass, which runs by default: the assess prompt marks a
        # standards-violation finding FALSE_POSITIVE when the rule it cites is absent from the
        # standards section, and the filter added alongside this then drops it before judging.
        # With no standards supplied, every rule is absent, so a whole finding category can be
        # assessed away and scored as a miss against a reviewer that named it correctly.
        [ -f "$standards_file" ] && context_flag+=(--standards "$standards_file")

        # This document's OWN repository's context, not a run-wide one: production gives each
        # consumer the string that consumer passes to the reusable workflow, so a corpus spanning
        # two of them must too.
        #
        # ALWAYS passed, even empty. The adapter defaults this from PRT_PROJECT_CONTEXT
        # (review-adapter.sh:69), so leaving it off does not mean "no context" -- it means
        # whatever the operator's shell happens to export, entering both the review and the
        # assess prompt (pr-review-threads.sh:329,518) and changing the findings without
        # appearing anywhere in the result. Passing it explicitly is what makes context_sha
        # above a true statement about the run rather than a guess.
        #
        # An unmapped repo is logged rather than fatal: not every repo a gold document names has
        # a self-hosted reviewer, so an empty context can be the truthful value. Silence is what
        # is not acceptable -- a forgotten --context reads exactly like a repo that has none.
        # Once per repo for the whole measurement, not once per document per run: a 12-document
        # corpus over 3 runs would otherwise print the same line 36 times, which is how a real
        # warning stops being read.
        if [ -z "${contexts[$repo]+set}" ] && [ -z "${context_warned[$repo]+set}" ]; then
            context_warned[$repo]=1
            log "no --context for repo $repo; reviewing it with an empty project context"
        fi
        context_flag+=(--context "${contexts[$repo]:-}")

        findings_file="$workdir/run$run_idx-$(basename "$g" .json).findings.json"
        child_rc=0
        "$adapter" --diff "$diff_file" --title "$title" --out "$findings_file" \
            "${context_flag[@]}" "${assess_flag[@]}" || child_rc=$?
        if [ "$child_rc" -ge 2 ]; then
            log "setup fault from the reviewer adapter on $g (exit $child_rc)"
            return 1
        fi
        if [ "$child_rc" -ne 0 ]; then
            log "excluding $g: reviewer produced no usable findings"
            excluded=$((excluded + 1))
            excluded_docs+=("${g#"${corpus_root%/}"/}")
            continue
        fi

        # A partially reviewed document cannot be scored. The adapter exits 0 as long as ONE
        # chunk succeeded, but this document's gold rows are judged as a whole, so a row living
        # in a chunk the model never answered for would be counted as a miss by a reviewer that
        # never saw it -- the same "no signal scored as no defects" error the exit-1 path above
        # exists to prevent, just at sub-document granularity, and biased downward by exactly
        # the model failure rate --max-excluded is there to tolerate. Restricting the denominator
        # to successfully reviewed chunks was the alternative; it needs a chunk-to-gold-row map
        # that does not exist (chunks are byte ranges of a diff, gold rows are file/line pairs
        # in a revision), so excluding the document is the honest option available.
        chunks_failed=$(jq -er '.chunks_failed // 0' "$findings_file" 2>/dev/null) || chunks_failed=0
        if [ "$chunks_failed" -gt 0 ]; then
            log "excluding $g: $chunks_failed of $(jq -r '.chunks // 0' "$findings_file") chunks produced no usable review"
            excluded=$((excluded + 1))
            excluded_docs+=("${g#"${corpus_root%/}"/}")
            continue
        fi

        # Truncation is the same error wearing different clothes, and chunks_failed does not see
        # it. When one hunk alone exceeds the hard ceiling, prt_split_diff truncates its body,
        # records REVIEW_INCOMPLETE and still hands back a usable chunk (lib/prt/diff.sh); the
        # model answers that chunk, so nothing failed and chunks_failed stays 0 -- while the
        # discarded tail is diff the reviewer never received. Judging the document whole then
        # scores any gold row in that tail as a miss. Same remedy, same reason: exclude it from
        # both sides of the fraction rather than counting unseen code against the reviewer.
        n_incomplete=$(jq -er '(.incomplete // []) | length' "$findings_file" 2>/dev/null) || n_incomplete=0
        if [ "$n_incomplete" -gt 0 ]; then
            log "excluding $g: the diff was truncated before review ($n_incomplete marker(s))"
            excluded=$((excluded + 1))
            excluded_docs+=("${g#"${corpus_root%/}"/}")
            continue
        fi

        # Judge what the shipped reviewer would actually have published, which is narrower than
        # what it emitted in two independent ways.
        #
        # FALSE_POSITIVE: the production path suppresses these before they ever become threads
        # (pr-review-threads.sh), so crediting one here would score a defect against a reviewer
        # whose own second pass had already discarded it -- flattering the two-pass config for
        # findings it withheld. Under --no-assess no verdicts exist and that arm is a silent
        # no-op, which is why assessment is the default and the result records which it was.
        #
        # collision: prt_assign_ordinals sets it on EVERY member of a group sharing a file and a
        # category (finding.sh, `collision: ($glen > 1)`), and reconcile.sh's row 1 returns NONE
        # for each of them before any other rule is consulted. Nothing publishes them. Crediting
        # them would count defects no human is ever shown, and it would do so inconsistently
        # with the FALSE_POSITIVE filter one line above -- the two suppressions are equally
        # unconditional in production, so filtering one and not the other measures neither the
        # engine nor the product.
        #
        # This does mean an engine that emits several findings per file and category scores
        # lower. That is a real property of the delivered system rather than an artefact: those
        # findings are genuinely withheld today. If the harness is ever pointed at an engine
        # meant to be judged before the thread lifecycle, this is the line to revisit, and it
        # needs a flag and a README paragraph rather than a silent removal.
        judge_input="$workdir/run$run_idx-$(basename "$g" .json).judged.json"
        jq '.findings |= map(select(
                ((.verdict // "") != "FALSE_POSITIVE") and (.collision != true)))' \
            "$findings_file" >"$judge_input" \
            || { log "cannot filter assessed findings for $g"; return 1; }

        verdict_file="$workdir/run$run_idx-$(basename "$g" .json).verdict.json"
        child_rc=0
        "$judge" --findings "$judge_input" --gold "$g" --out "$verdict_file" || child_rc=$?
        if [ "$child_rc" -ge 2 ]; then
            log "setup fault from the judge on $g (exit $child_rc)"
            return 1
        fi
        if [ "$child_rc" -ne 0 ]; then
            log "excluding $g: judge produced no usable verdict"
            excluded=$((excluded + 1))
            excluded_docs+=("${g#"${corpus_root%/}"/}")
            continue
        fi

        # Read both counts before touching any accumulator: the arithmetic cannot fail loudly
        # on its own. An empty substitution makes `$((matched + ))` a syntax error that leaves
        # `matched` at its old value, and a JSON `null` arrives as a bare word bash evaluates
        # to 0 -- so a judge that exits 0 while writing an unusable verdict would understate
        # recall as a miss from a document it never scored. `select(type == "number")` treats
        # every non-number the same way, and any non-zero jq status (false, null, or a read
        # error) lands in the same branch deliberately: all of them mean "no usable verdict".
        # The denominator moves only after both reads succeed, so such a document leaves both
        # sides of the fraction like every other exclusion.
        v_matched=$(jq -er '.matched | select(type == "number")' "$verdict_file" 2>/dev/null) \
            || v_matched=
        v_uncredited=$(jq -er '.uncredited | select(type == "number")' "$verdict_file" 2>/dev/null) \
            || v_uncredited=
        if [ -z "$v_matched" ] || [ -z "$v_uncredited" ]; then
            log "excluding $g: verdict file carries no numeric .matched/.uncredited"
            excluded=$((excluded + 1))
            excluded_docs+=("${g#"${corpus_root%/}"/}")
            continue
        fi

        denom=$((denom + rows))
        matched=$((matched + v_matched))
        uncredited=$((uncredited + v_uncredited))
    done

    # The document list rides in a fifth field as compact JSON: it is the one field whose values
    # come from the filesystem, so no character-delimited join is safe against a path that
    # contains the delimiter, while `jq -c` cannot emit a tab and the record stays readable by
    # the same `IFS=$'\t' read` as before.
    local docs_json='[]'
    if [ "${#excluded_docs[@]}" -gt 0 ]; then
        docs_json=$(printf '%s\n' "${excluded_docs[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))') ||
            die "cannot record the excluded-document list"
    fi
    printf '%d\t%d\t%d\t%d\t%s' "$matched" "$uncredited" "$denom" "$excluded" "$docs_json"
}

# ---------------------------------------------------------------------------
# repeat, then summarise
# ---------------------------------------------------------------------------

recalls=()
uncrediteds=()
excludeds=()
excluded_row_counts=()
excluded_doc_lists=()

for ((run = 1; run <= runs; run++)); do
    result=$(do_run "$run") || exit 1
    IFS=$'\t' read -r matched uncredited denom excluded excluded_docs_json <<<"$result"

    # Every document excluded leaves no denominator, so recall is undefined rather than zero.
    # Dividing here would print 0 and read as "the reviewer found nothing", which is the one
    # conclusion the data cannot support.
    [ "$denom" -gt 0 ] || die "run $run: every gold document was excluded; nothing to measure"

    # Gate on ROWS, not documents. Gold rows are not spread evenly: the mining yields one row for
    # a one-line fix and a dozen for a refactor, so a single excluded document can carry a large
    # share of the measured defects. Counting documents, 1 of 12 is 0.083 and passes; if that one
    # held 40 of 91 rows the run just measured half the corpus and reported a recall over the
    # rest as though it described the whole. Rows are what the denominator is made of, so rows are
    # what the ceiling has to be expressed in. `denom` is the rows of the documents that survived,
    # hence gold_total - denom is exactly the rows this run lost.
    excluded_rows=$((gold_total - denom))
    excluded_frac=$(jq -n --argjson e "$excluded_rows" --argjson n "$gold_total" '$e / $n')
    # Same three-way status handling as the --max-spread gate below: `if jq -e` alone folds a
    # jq that aborted into the "within limit" branch, which is a gate that fails open.
    jq -e -n --argjson f "$excluded_frac" --argjson m "$max_excluded" '$f > $m' >/dev/null
    case $? in
        0) die "run $run: excluded $excluded_rows of $gold_total gold rows ($excluded_frac, from $excluded of ${#gold_files[@]} documents), over --max-excluded $max_excluded" ;;
        1) ;;
        *) die "run $run: could not compare exclusion fraction $excluded_frac against --max-excluded $max_excluded" ;;
    esac
    excluded_row_counts+=("$excluded_rows")
    excluded_doc_lists+=("$excluded_docs_json")

    recall=$(jq -n --argjson m "$matched" --argjson t "$denom" '$m / $t')
    recalls+=("$recall")
    uncrediteds+=("$uncredited")
    excludeds+=("$excluded")
    printf 'run=%d R=%s matched=%d/%d uncredited=%d excluded=%d/%d docs=%d/%d rows\n' \
        "$run" "$recall" "$matched" "$denom" "$uncredited" \
        "$excluded" "${#gold_files[@]}" "$excluded_rows" "$gold_total"
done

summary=$(jq -n \
    --argjson r "$(printf '%s\n' "${recalls[@]}" | jq -sc '.')" \
    --argjson u "$(printf '%s\n' "${uncrediteds[@]}" | jq -sc '.')" \
    --argjson e "$(printf '%s\n' "${excludeds[@]}" | jq -sc '.')" \
    --argjson x "$(printf '%s\n' "${excluded_row_counts[@]}" | jq -sc '.')" \
    '{mean_r: (($r | add) / ($r | length)),
      spread: (($r | max) - ($r | min)),
      uncredited: (($u | add) / ($u | length)),
      excluded_max: ($e | max),
      excluded_total: ($e | add),
      excluded_rows_max: ($x | max)}')

mean_r=$(jq -r '.mean_r' <<<"$summary")
spread=$(jq -r '.spread' <<<"$summary")
mean_uncredited=$(jq -r '.uncredited' <<<"$summary")
# Carried into the persisted JSON, not left in this shell variable. A recall figure is only
# interpretable next to how much of the corpus produced it, and the run lines that print the
# exclusions scroll past -- the file is what a later reader, and compare.sh, actually have.
excluded_docs_max=$(jq -r '.excluded_max' <<<"$summary")
excluded_rows_max=$(jq -r '.excluded_rows_max' <<<"$summary")

# Coverage, PER RUN and not merged across runs. mean_r is the mean of matched_i/denom_i over the
# runs, so what has to match between two results is the multiset of per-run denominators -- and a
# union cannot express that. A baseline that excluded hard.json in one repetition of three and a
# candidate that excluded it in all three produce the identical union, while the candidate's mean
# is taken over two more shrunken denominators: exactly the inflated recall the coverage gate
# exists to reject, passing the gate. Each run's list is sorted so the comparison does not depend
# on the order the documents were visited in.
excluded_per_run=$(printf '%s\n' "${excluded_doc_lists[@]}" | jq -sc 'map(sort)') ||
    die "cannot summarise the excluded-document lists"

# The union stays, as the readable one-glance summary of what a result did not measure. It is not
# what compare.sh gates on -- see above.
excluded_docs_union=$(jq -nc --argjson r "$excluded_per_run" '$r | add // [] | unique') ||
    die "cannot summarise the excluded-document lists"

printf 'mean_r=%s spread=%s runs=%d\n' "$mean_r" "$spread" "$runs"

out_json=$(jq -n \
    --arg engine "$engine" \
    --arg gold_sha "$gold_sha" \
    --arg gold_tree "$gold_tree" \
    --arg standards_sha "$standards_sha" \
    --arg standards_source "$standards_source" \
    --arg context_sha "$context_sha" \
    --argjson assess "$assess" \
    --argjson runs "$runs" \
    --argjson mean_r "$mean_r" \
    --argjson spread "$spread" \
    --argjson uncredited "$mean_uncredited" \
    --argjson gold_total "$gold_total" \
    --argjson gold_docs "${#gold_files[@]}" \
    --argjson excluded_docs_max "$excluded_docs_max" \
    --argjson excluded_rows_max "$excluded_rows_max" \
    --argjson excluded_docs "$excluded_docs_union" \
    --argjson excluded_per_run "$excluded_per_run" \
    --argjson per_run "$(printf '%s\n' "${recalls[@]}" | jq -sc '.')" \
    '{engine: $engine, gold_sha: $gold_sha, gold_tree: $gold_tree, gold_total: $gold_total,
      standards_sha: $standards_sha, standards_source: $standards_source,
      context_sha: $context_sha, assess: $assess, gold_docs: $gold_docs,
      excluded_docs_max: $excluded_docs_max, excluded_rows_max: $excluded_rows_max,
      excluded_docs: $excluded_docs, excluded_per_run: $excluded_per_run,
      runs: $runs, mean_r: $mean_r, spread: $spread, uncredited: $uncredited,
      per_run_recall: $per_run}') || die "cannot build summary JSON"

printf '%s\n' "$out_json" >"$out_file" || die "cannot write $out_file"
log "wrote $out_file"

# ---------------------------------------------------------------------------
# the noise gate -- BEFORE the README write, not after
# ---------------------------------------------------------------------------

# Order matters. exit 3 means "too noisy to quote", so a result that trips it must not have
# already been written into the README as the quotable baseline. The JSON is written above
# either way: that is the record of the measurement, including a failed one.
if [ -n "$max_spread" ]; then
    # `jq -e` so a comparison that could not be evaluated exits non-zero instead of printing
    # nothing: with `[ "$(jq …)" = "true" ]` an aborted jq compares the empty string, reads
    # false, and the gate passes the result it exists to reject. Exit status 1 means "within
    # spread"; anything else means jq itself failed, which is not a verdict.
    jq -e -n --argjson s "$spread" --argjson m "$max_spread" '$s > $m' >/dev/null
    case $? in
        0)
            log "spread $spread exceeds --max-spread $max_spread; this result is too noisy to quote"
            exit 3
            ;;
        1) ;;
        *) die "could not compare spread $spread against --max-spread $max_spread" ;;
    esac
fi

# ---------------------------------------------------------------------------
# the README baseline line
# ---------------------------------------------------------------------------

# GENERATED, never hand-written. The witness for "the baseline is in the README" is a
# whole-line match against `jq -er .mean_r`, and a hand-maintained line drifts from the JSON
# the moment either is edited alone -- while still matching if the drift is a prefix. Writing
# it from the same value the witness reads is what makes the witness mean something.
if [ -n "$readme_file" ]; then
    [ -f "$readme_file" ] || die "no such README: $readme_file"
    # Validate before writing: an absent or non-numeric mean_r would otherwise be written as
    # the literal string "null", which a substring witness would happily accept.
    jq -e '(.mean_r | type) == "number"' <<<"$out_json" >/dev/null \
        || die "mean_r is missing or not a number; refusing to write $readme_file"
    line="baseline mean_r=$mean_r"
    tmp="$workdir/readme"
    if grep -q '^baseline mean_r=' "$readme_file"; then
        LINE="$line" awk '/^baseline mean_r=/ { print ENVIRON["LINE"]; next } { print }' \
            "$readme_file" >"$tmp" || die "cannot rewrite $readme_file"
    else
        cat "$readme_file" >"$tmp" || die "cannot read $readme_file"
        printf '\n%s\n' "$line" >>"$tmp" || die "cannot append to $readme_file"
    fi
    cat "$tmp" >"$readme_file" || die "cannot write $readme_file"
    log "$readme_file now carries: $line"
fi
