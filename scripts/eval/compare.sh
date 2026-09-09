#!/usr/bin/env bash
# compare.sh -- decide whether a candidate reviewer actually beats the baseline.
#
#   compare.sh <baseline.json> <candidate.json>
#
# Exit 0 only when the candidate's mean recall clears the baseline's by more than the two
# results' own noise combined:
#
#   mean_r(candidate) - mean_r(baseline) > spread(baseline) + spread(candidate)
#
# Adding the two spreads rather than comparing against either alone is the point. Each spread
# is that configuration's own measured run-to-run variation, so a difference smaller than
# their sum is inside the range either measurement could have produced by itself. This is a
# deliberately conservative gate: it will refuse some real improvements, and refusing a real
# improvement costs one more measurement round, while accepting a fake one flips a default
# engine on evidence that was never there.
#
# Both uncredited-finding counts are printed beside the verdict but do NOT enter it. They are
# not precision (see run.sh's header): a reviewer that finds more real, never-filed defects
# raises that count while getting better, so gating on it would select for silence.
#
# Both files must have measured the SAME gold tree, been given the SAME standards document, and
# run the SAME number of model passes. A comparison across two different gold sets is not a
# comparison, and neither is one across two standards revisions or across an assessed and an
# unassessed run -- all three are invisible in the numbers, which is why they are checked here
# rather than left to whoever reads the output.
#
# exit status
#   0  the candidate wins by more than the combined spread
#   1  it does not
#   2  usage error, or the two results are not comparable

set -uo pipefail

readonly PROG=${0##*/}

die() {
    printf '%s: %s\n' "$PROG" "$*" >&2
    exit 2
}

[ $# -eq 2 ] || die "usage: compare.sh <baseline.json> <candidate.json>"
command -v jq >/dev/null 2>&1 || die "jq is required"

baseline=$1
candidate=$2
[ -f "$baseline" ] || die "no such file: $baseline"
[ -f "$candidate" ] || die "no such file: $candidate"

for f in "$baseline" "$candidate"; do
    jq -e '(.mean_r | type) == "number" and (.spread | type) == "number"' "$f" >/dev/null \
        || die "$f has no numeric mean_r/spread"
done

b_tree=$(jq -r '.gold_tree // "unknown"' "$baseline")
c_tree=$(jq -r '.gold_tree // "unknown"' "$candidate")
if [ "$b_tree" != "$c_tree" ]; then
    die "different gold trees ($b_tree vs $c_tree); these results are not comparable"
fi
[ "$b_tree" != "unknown" ] || die "gold_tree is unknown in at least one result; cannot prove comparability"

# The gold set is only half of what a number depends on. The other half is the standards doc the
# reviewer was given: a rule absent from PROJECT STANDARDS forces every finding citing it to
# FALSE_POSITIVE (`lib/prt/model.sh:253-256`), which this harness filters out before judging, so
# two runs over an identical gold tree can differ in recall alone because one read the pinned
# revision and the other fell back to an edited working tree. Digest, not label: the fallback and
# the pin carry the same path and different bytes, so a path comparison would pass both.
b_std=$(jq -r '.standards_sha // "unknown"' "$baseline")
c_std=$(jq -r '.standards_sha // "unknown"' "$candidate")
if [ "$b_std" != "$c_std" ]; then
    die "different standards documents ($(jq -r '.standards_source // "?"' "$baseline") ${b_std:0:12} vs $(jq -r '.standards_source // "?"' "$candidate") ${c_std:0:12}); these results are not comparable"
fi
[ "$b_std" != "unknown" ] || die "standards_sha is missing from at least one result; re-measure with a run.sh that records it"

# The third input to a number is how many passes it measured. Production always assesses
# (`pr-review-threads.sh:507-518`) and never publishes a FALSE_POSITIVE, so an unassessed run
# credits findings the shipped pipeline withdraws -- a strictly higher recall for the same
# reviewer. Comparing one against an assessed run reads that gap as an engine difference.
# Same argument one input further along: production forwards a per-repository project-context
# string into both model calls (`action.yml:105` -> PRT_PROJECT_CONTEXT), so two runs given
# different context strings were given different prompts.
b_ctx=$(jq -r '.context_sha // "unknown"' "$baseline")
c_ctx=$(jq -r '.context_sha // "unknown"' "$candidate")
if [ "$b_ctx" != "$c_ctx" ]; then
    die "different project contexts (${b_ctx:0:12} vs ${c_ctx:0:12}); these results are not comparable"
fi
[ "$b_ctx" != "unknown" ] || die "context_sha is missing from at least one result; re-measure with a run.sh that records it"

b_assess=$(jq -r 'if has("assess") then (.assess | tostring) else "unknown" end' "$baseline")
c_assess=$(jq -r 'if has("assess") then (.assess | tostring) else "unknown" end' "$candidate")
if [ "$b_assess" != "$c_assess" ]; then
    die "one result assessed and the other did not (assess=$b_assess vs assess=$c_assess); these results are not comparable"
fi
[ "$b_assess" != "unknown" ] || die "assess is missing from at least one result; re-measure with a run.sh that records it"

# Identical inputs are still not enough: the two results must also have SCORED the same rows.
# Recall is matched/denom, and run.sh builds denom from the documents that survived
# (`run.sh:757`) -- an excluded document leaves both sides of the fraction. So a candidate that
# fails to answer on the corpus's hardest documents does not score 0 on them, it stops being
# asked: baseline 70/100 = 0.70 against a candidate that excluded those same 15 rows and scored
# 70/85 = 0.82, both with zero spread, and the verdict below reads a 0.12 win. `--max-excluded`
# does not close this -- it caps how much of the corpus a run may drop (0.15 by default), it
# does not require two runs to drop the SAME part.
#
# Compare the sets, not the counts: two results can each exclude three documents and have
# measured different rows.
#
# And compare them PER RUN, never merged. mean_r is the mean of matched_i/denom_i over the
# repetitions, so what must match is the multiset of per-run denominators. A union cannot express
# that: a baseline that excluded hard.json in one run of three and a candidate that excluded it in
# all three share the identical union, while the candidate's mean is taken over two more shrunken
# denominators -- the same inflated recall this gate exists to reject, one level down.
#
# `map(sort) | sort` compares the multiset: within a run the visit order is irrelevant, and
# between runs only how many repetitions dropped which documents matters, not which repetition.
b_excl=$(jq -cS 'if has("excluded_per_run") then (.excluded_per_run | map(sort) | sort) else "unknown" end' "$baseline")
c_excl=$(jq -cS 'if has("excluded_per_run") then (.excluded_per_run | map(sort) | sort) else "unknown" end' "$candidate")
if [ "$b_excl" != "$c_excl" ]; then
    die "different scoring coverage (excluded per run $b_excl vs $c_excl); these results measured different rows and are not comparable"
fi
[ "$b_excl" != '"unknown"' ] || die "excluded_per_run is missing from at least one result; re-measure with a run.sh that records it"

# denominator_stable is run.sh's own within-config signal (go-kure/.github#179): the equality
# check above only catches two configs whose per-run exclusions DIFFER from each other -- two
# configs that happen to exclude the identical uneven pattern would pass it while each one's own
# spread is still partly a judge failure, not reviewer variance. A result missing the field
# predates that fix and is refused the same way a missing excluded_per_run already is above --
# "unknown" is not evidence of stability.
b_stable=$(jq -r 'if has("denominator_stable") then (.denominator_stable | tostring) else "unknown" end' "$baseline")
c_stable=$(jq -r 'if has("denominator_stable") then (.denominator_stable | tostring) else "unknown" end' "$candidate")
[ "$b_stable" != "unknown" ] && [ "$c_stable" != "unknown" ] \
    || die "denominator_stable is missing from at least one result; re-measure with a run.sh that records it"
# Require the literal boolean true, not merely "not false" -- a present but malformed value
# (null, a stray string, a schema-drifted field) would otherwise stringify to something that is
# neither "unknown" nor "false" and fall through the two checks above straight into the winner
# calculation below, which is exactly the fail-closed gate this field exists to enforce.
if [ "$b_stable" != "true" ] || [ "$c_stable" != "true" ]; then
    die "denominator_stable is not true (baseline=$b_stable, candidate=$c_stable); spread may include documents excluded unevenly across that config's own runs and cannot be attributed to reviewer variance -- re-measure until both are stable before gating"
fi

b_engine=$(jq -r '.engine' "$baseline")
c_engine=$(jq -r '.engine' "$candidate")

read -r b_r b_s b_u < <(jq -r '[.mean_r, .spread, .uncredited] | @tsv' "$baseline")
read -r c_r c_s c_u < <(jq -r '[.mean_r, .spread, .uncredited] | @tsv' "$candidate")

delta=$(jq -n --argjson a "$c_r" --argjson b "$b_r" '$a - $b')
threshold=$(jq -n --argjson a "$b_s" --argjson b "$c_s" '$a + $b')

printf '%-10s mean_r=%s spread=%s uncredited=%s\n' "$b_engine" "$b_r" "$b_s" "$b_u"
printf '%-10s mean_r=%s spread=%s uncredited=%s\n' "$c_engine" "$c_r" "$c_s" "$c_u"
printf 'delta=%s threshold=%s (spread %s + spread %s)\n' \
    "$delta" "$threshold" "$b_s" "$c_s"

if [ "$(jq -n --argjson d "$delta" --argjson t "$threshold" '$d > $t')" = "true" ]; then
    printf 'VERDICT: %s beats %s by more than the combined spread\n' "$c_engine" "$b_engine"
    exit 0
fi

printf 'VERDICT: %s does not clear the combined spread; not a measured improvement\n' "$c_engine"
exit 1
