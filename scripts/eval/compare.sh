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
b_assess=$(jq -r 'if has("assess") then (.assess | tostring) else "unknown" end' "$baseline")
c_assess=$(jq -r 'if has("assess") then (.assess | tostring) else "unknown" end' "$candidate")
if [ "$b_assess" != "$c_assess" ]; then
    die "one result assessed and the other did not (assess=$b_assess vs assess=$c_assess); these results are not comparable"
fi
[ "$b_assess" != "unknown" ] || die "assess is missing from at least one result; re-measure with a run.sh that records it"

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
