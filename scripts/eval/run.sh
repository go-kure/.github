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
# It reports GOLD-MATCH RECALL and a count of unmatched findings. It does not report
# precision, and the missing metric is a property of the gold set rather than an omission.
# The gold set is mined from commits that fixed a bug, so it contains only defects somebody
# eventually filed. A reviewer that names a real defect nobody ever fixed produces an
# unmatched finding, and scoring that as a false positive would punish the better reviewer
# and invert the Phase 2 comparison this harness exists to decide. Recall is sound under this
# construction; precision is not, so it is not printed. See eval/README.md.
#
# usage
#   run.sh --gold '<glob>' --engine chat --runs 3 --max-spread <f> --out <file>
#          --checkout <repo-name>=<path> [--readme <file>] [--assess]
#
# Per-run stdout is one line: `run=N R=<recall> matched=<n>/<gold_total> unmatched=<n>`.
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

if [ -n "$max_spread" ]; then
    case "$max_spread" in
        ''|*[!0-9.]*) die "--max-spread must be a number" ;;
    esac
fi

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

# gold_sha identifies the INPUTS, not the checkout: two results are comparable only when they
# read the same gold tree. Taken from the first gold file's own repository.
gold_dir=$(cd -- "$(dirname -- "${gold_files[0]}")" && pwd)
gold_sha=$(git -C "$gold_dir" rev-parse HEAD 2>/dev/null || echo unknown)
gold_tree=$(git -C "$gold_dir" rev-parse "HEAD:./" 2>/dev/null || echo unknown)

workdir=$(mktemp -d "${TMPDIR:-/tmp}/eval-run.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$workdir"' EXIT

# ---------------------------------------------------------------------------
# one run
# ---------------------------------------------------------------------------

# do_run RUN_INDEX -- prints "matched<TAB>unmatched"; returns 1 if any document failed.
do_run() {
    local run_idx="$1"
    local matched=0 unmatched=0 g repo checkout diff_file findings_file verdict_file

    for g in "${gold_files[@]}"; do
        repo=$(jq -r '.repo' "$g")
        checkout=${checkouts[$repo]:-}
        [ -n "$checkout" ] || { log "no --checkout for repo $repo (gold: $g)"; return 1; }

        local base head title
        base=$(jq -r '.base_sha' "$g")
        head=$(jq -r '.head_sha' "$g")
        title=$(jq -r '.gold[0].note // "change under review"' "$g")

        diff_file="$workdir/run$run_idx-$(basename "$g" .json).diff"
        # --src-prefix/--dst-prefix explicitly: a user's diff.noprefix=true otherwise emits
        # headers the chunker's file-boundary split cannot see, silently collapsing the whole
        # diff into one record.
        git -C "$checkout" diff --no-color --src-prefix=a/ --dst-prefix=b/ "$base" "$head" \
            >"$diff_file" 2>/dev/null \
            || { log "cannot diff $base..$head in $checkout"; return 1; }
        [ -s "$diff_file" ] || { log "empty diff for $g"; return 1; }

        findings_file="$workdir/run$run_idx-$(basename "$g" .json).findings.json"
        if ! "$adapter" --diff "$diff_file" --title "$title" --out "$findings_file" \
            "${assess_flag[@]}"; then
            log "reviewer produced no usable findings for $g"
            return 1
        fi

        verdict_file="$workdir/run$run_idx-$(basename "$g" .json).verdict.json"
        if ! "$judge" --findings "$findings_file" --gold "$g" --out "$verdict_file"; then
            log "judge failed for $g"
            return 1
        fi

        matched=$((matched + $(jq '.matched' "$verdict_file")))
        unmatched=$((unmatched + $(jq '.unmatched' "$verdict_file")))
    done

    printf '%d\t%d' "$matched" "$unmatched"
}

# ---------------------------------------------------------------------------
# repeat, then summarise
# ---------------------------------------------------------------------------

recalls=()
unmatcheds=()

for ((run = 1; run <= runs; run++)); do
    result=$(do_run "$run") || exit 1
    matched=${result%%$'\t'*}
    unmatched=${result##*$'\t'}
    recall=$(jq -n --argjson m "$matched" --argjson t "$gold_total" '$m / $t')
    recalls+=("$recall")
    unmatcheds+=("$unmatched")
    printf 'run=%d R=%s matched=%d/%d unmatched=%d\n' \
        "$run" "$recall" "$matched" "$gold_total" "$unmatched"
done

summary=$(jq -n \
    --argjson r "$(printf '%s\n' "${recalls[@]}" | jq -sc '.')" \
    --argjson u "$(printf '%s\n' "${unmatcheds[@]}" | jq -sc '.')" \
    '{mean_r: (($r | add) / ($r | length)),
      spread: (($r | max) - ($r | min)),
      unmatched: (($u | add) / ($u | length))}')

mean_r=$(jq -r '.mean_r' <<<"$summary")
spread=$(jq -r '.spread' <<<"$summary")
mean_unmatched=$(jq -r '.unmatched' <<<"$summary")

printf 'mean_r=%s spread=%s runs=%d\n' "$mean_r" "$spread" "$runs"

out_json=$(jq -n \
    --arg engine "$engine" \
    --arg gold_sha "$gold_sha" \
    --arg gold_tree "$gold_tree" \
    --argjson runs "$runs" \
    --argjson mean_r "$mean_r" \
    --argjson spread "$spread" \
    --argjson unmatched "$mean_unmatched" \
    --argjson gold_total "$gold_total" \
    --argjson per_run "$(printf '%s\n' "${recalls[@]}" | jq -sc '.')" \
    '{engine: $engine, gold_sha: $gold_sha, gold_tree: $gold_tree, gold_total: $gold_total,
      runs: $runs, mean_r: $mean_r, spread: $spread, unmatched: $unmatched,
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
    if [ "$(jq -n --argjson s "$spread" --argjson m "$max_spread" '$s > $m')" = "true" ]; then
        log "spread $spread exceeds --max-spread $max_spread; this result is too noisy to quote"
        exit 3
    fi
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
