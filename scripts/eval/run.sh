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
#          --checkout <repo-name>=<path> [--readme <file>] [--assess]
#
# Per-run stdout is one line:
#   run=N R=<recall> matched=<n>/<denominator> uncredited=<n> excluded=<n>/<documents>
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
              --checkout <repo-name>=<path> [--max-spread <f>] [--readme <file>] [--assess]

  --gold        glob matching the gold documents (quote it; this script expands it)
  --engine      chat (the shipped diff-only reviewer). service arrives with Phase 2b.
  --runs        how many times to repeat the whole measurement; minimum 3
  --checkout    map a gold document's `repo` to a local clone; repeatable
  --out         write the summary JSON here
  --max-spread  refuse (exit 3) when max(R) - min(R) exceeds this
  --max-excluded  fraction of gold documents a run may lose to reviewer/judge failure
                  before it stops being measurable (default 0.15)
  --readme      rewrite this file's `baseline mean_r=` line from the measured result
  --assess      also run the reviewer's assessment pass

exit status
  0  measured      1  a run failed      2  usage error      3  spread too wide
EOF
}

gold_glob=
engine=chat
runs=0
out_file=
max_spread=
# 0.15 is a ceiling on how much of the gold set may vanish before a run stops describing it,
# not a target. Set from the first live subset: 1 document of 12 excluded is 0.083, so a
# single flaky response stays inside the gate while a systemic backend fault does not.
max_excluded=0.15
readme_file=
assess_flag=()
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
        --assess) assess_flag=(--assess); shift ;;
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
    || die "--max-excluded is a fraction of the gold documents, so it must be within 0..1 (got $max_excluded)"

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
gold_dir=$(cd -- "$(dirname -- "${gold_files[0]}")" && pwd)
gold_sha=$(git -C "$gold_dir" rev-parse HEAD 2>/dev/null || echo unknown)
gold_tree=$(
    for g in "${gold_files[@]}"; do
        printf '%s  %s\n' "$(sha256sum <"$g" | cut -d' ' -f1)" "$(basename -- "$g")"
    done | LC_ALL=C sort | sha256sum | cut -d' ' -f1
) || die "cannot digest the gold corpus"

workdir=$(mktemp -d "${TMPDIR:-/tmp}/eval-run.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$workdir"' EXIT

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
        # to the note.
        title=$(jq -r '.intro_title // "change under review"' "$g")

        diff_file="$workdir/run$run_idx-$(basename "$g" .json).diff"
        # --src-prefix/--dst-prefix explicitly: a user's diff.noprefix=true otherwise emits
        # headers the chunker's file-boundary split cannot see, silently collapsing the whole
        # diff into one record.
        git -C "$checkout" diff --no-color --src-prefix=a/ --dst-prefix=b/ "$base" "$head" \
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
        if git -C "$checkout" show "$head:AGENTS.md" >"$agents_file" 2>/dev/null \
            && [ -s "$agents_file" ]; then
            context_flag+=(--agents "$agents_file")
        fi
        claude_md_file="$workdir/run$run_idx-$(basename "$g" .json).claude.md"
        if git -C "$checkout" show "$head:.claude/CLAUDE.md" >"$claude_md_file" 2>/dev/null \
            && [ -s "$claude_md_file" ]; then
            context_flag+=(--claude-md "$claude_md_file")
        fi

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
            continue
        fi

        # Under --assess, judge what the shipped reviewer would actually have published. The
        # production path suppresses FALSE_POSITIVE findings before they ever become threads
        # (pr-review-threads.sh), so crediting one here would score a defect against a reviewer
        # whose own second pass had already discarded it -- flattering the two-pass config for
        # findings it withheld. Without --assess no verdicts exist and this is a no-op copy,
        # which is why it is unconditional rather than branching on the flag.
        judge_input="$workdir/run$run_idx-$(basename "$g" .json).judged.json"
        jq '.findings |= map(select((.verdict // "") != "FALSE_POSITIVE"))' \
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
            continue
        fi

        denom=$((denom + rows))
        matched=$((matched + v_matched))
        uncredited=$((uncredited + v_uncredited))
    done

    printf '%d\t%d\t%d\t%d' "$matched" "$uncredited" "$denom" "$excluded"
}

# ---------------------------------------------------------------------------
# repeat, then summarise
# ---------------------------------------------------------------------------

recalls=()
uncrediteds=()
excludeds=()

for ((run = 1; run <= runs; run++)); do
    result=$(do_run "$run") || exit 1
    IFS=$'\t' read -r matched uncredited denom excluded <<<"$result"

    # Every document excluded leaves no denominator, so recall is undefined rather than zero.
    # Dividing here would print 0 and read as "the reviewer found nothing", which is the one
    # conclusion the data cannot support.
    [ "$denom" -gt 0 ] || die "run $run: every gold document was excluded; nothing to measure"

    excluded_frac=$(jq -n --argjson e "$excluded" --argjson n "${#gold_files[@]}" '$e / $n')
    # Same three-way status handling as the --max-spread gate below: `if jq -e` alone folds a
    # jq that aborted into the "within limit" branch, which is a gate that fails open.
    jq -e -n --argjson f "$excluded_frac" --argjson m "$max_excluded" '$f > $m' >/dev/null
    case $? in
        0) die "run $run: excluded $excluded of ${#gold_files[@]} documents ($excluded_frac), over --max-excluded $max_excluded" ;;
        1) ;;
        *) die "run $run: could not compare exclusion fraction $excluded_frac against --max-excluded $max_excluded" ;;
    esac

    recall=$(jq -n --argjson m "$matched" --argjson t "$denom" '$m / $t')
    recalls+=("$recall")
    uncrediteds+=("$uncredited")
    excludeds+=("$excluded")
    printf 'run=%d R=%s matched=%d/%d uncredited=%d excluded=%d/%d\n' \
        "$run" "$recall" "$matched" "$denom" "$uncredited" "$excluded" "${#gold_files[@]}"
done

summary=$(jq -n \
    --argjson r "$(printf '%s\n' "${recalls[@]}" | jq -sc '.')" \
    --argjson u "$(printf '%s\n' "${uncrediteds[@]}" | jq -sc '.')" \
    --argjson e "$(printf '%s\n' "${excludeds[@]}" | jq -sc '.')" \
    '{mean_r: (($r | add) / ($r | length)),
      spread: (($r | max) - ($r | min)),
      uncredited: (($u | add) / ($u | length)),
      excluded_max: ($e | max),
      excluded_total: ($e | add)}')

mean_r=$(jq -r '.mean_r' <<<"$summary")
spread=$(jq -r '.spread' <<<"$summary")
mean_uncredited=$(jq -r '.uncredited' <<<"$summary")

printf 'mean_r=%s spread=%s runs=%d\n' "$mean_r" "$spread" "$runs"

out_json=$(jq -n \
    --arg engine "$engine" \
    --arg gold_sha "$gold_sha" \
    --arg gold_tree "$gold_tree" \
    --argjson runs "$runs" \
    --argjson mean_r "$mean_r" \
    --argjson spread "$spread" \
    --argjson uncredited "$mean_uncredited" \
    --argjson gold_total "$gold_total" \
    --argjson per_run "$(printf '%s\n' "${recalls[@]}" | jq -sc '.')" \
    '{engine: $engine, gold_sha: $gold_sha, gold_tree: $gold_tree, gold_total: $gold_total,
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
