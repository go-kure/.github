# Reviewer evaluation harness

Measures how much a code reviewer actually catches, reproducibly, so that a change to the
reviewer can be judged against a number instead of an impression.

The harness lives here because it is generic. **The gold data does not**: it names private
merge requests and belongs in a private repository alongside the checkouts it refers to.

## The metric, and the one this construction cannot support

The harness reports **gold-match recall** and a **count of uncredited findings**. It does not
report precision, and that is a decision, not an omission.

The gold set is mined from commits that fixed a bug. It therefore contains only defects
somebody eventually filed and repaired. A reviewer that names a real defect nobody ever
fixed produces a finding that matches no gold row — and scoring that as a false positive
would mark the better reviewer down for finding more. Recall is sound under this
construction. Precision is not, so it is never printed and the word is not used.

That count is still reported, because its volume is worth watching: a reviewer whose
uncredited count triples while its recall stays flat is getting noisier. It is a signal for a
human, never a gate. `compare.sh` prints it and does not gate on it.

**It is called `uncredited`, not `unmatched`, and the difference is real.** Once a gold row is
matched, `judge.sh` stops judging further findings against it — recall counts rows caught, not
how many findings caught each — so a *second* finding describing that same row is never judged
and lands in this count too. Calling the field "unmatched" would assert something the harness
did not measure. Judging those extra pairs would spend model calls to refine a number that
gates nothing, so the honest name is the cheaper correct answer.

## The pieces

| Script | What it does |
|---|---|
| `build-gold.sh` | Mines a repository's `fix:` history into gold rows and confirms each one |
| `review-adapter.sh` | Runs the shipped diff-only reviewer over one diff, posting nothing |
| `judge.sh` | Decides which gold rows a set of findings caught |
| `run.sh` | Repeats the whole measurement N times and reports mean recall and spread |
| `compare.sh` | Decides whether one result beats another by more than their combined noise |
| `parse-reviews.sh` | Turns a corpus of adjudicated review ledgers into one CSV |

## Why the gold set needs confirming

`git blame` names the commit that **last touched** a line, not the one that introduced the
defect. A reformat, a rename or a whitespace pass in between makes an innocent change the
accused. `build-gold.sh` therefore keeps a candidate only when the blamed commit's own diff
adds that exact line text, and drops and counts everything else. It also drops rows outside
source files and rows whose blame span is wider than `--max-span`: a wide span means the fix
rewrote a block rather than repairing a located defect, so the "faulty line" is an artefact
of the rewrite's boundaries.

`run.sh` refuses to measure against any gold row not carrying `confirmed: true`.

## Judge hygiene, including the parts that are not available

Matching a finding to a gold row needs a model, and a model asked "are these the same
issue?" is a biased instrument. Three controls are implemented:

- **Position-swapped, twice.** GPT-4-class judges flip their verdict on roughly a third of
  pairs when the order changes, so a single-order verdict is not evidence.
- **Disagreement is no match.** Both orders must agree. This biases recall downward, which
  is the safe direction: a harsh baseline cannot manufacture an improvement.
- **Provenance hidden.** Neither side is labelled "reviewer" or "known defect". A judge told
  which one is ground truth agrees with it.

Two further controls the literature asks for are **not available through this backend** and
are recorded here rather than asserted. The proxy ignores the request's `model` field and
routes every call through the Claude Code CLI on the Max subscription, and that CLI exposes
no temperature control. So neither **temperature 0** nor a **pinned judge model** can be
enforced; `--judge-model` is recorded for provenance and not obeyed. The remaining control
for judge variance is repetition, which is what `--runs` and the reported spread are for.

## What happens when the reviewer fails on one document

Two failure kinds reach `run.sh`, and they are not the same event.

A missing `--checkout`, an unresolvable revision or an empty diff is a **setup fault**: it fails
identically on every run, so continuing would silently measure a gold set the caller did not
ask for. Those abort.

A reviewer or judge that cannot produce a usable answer is the **backend being
nondeterministic** — the property this harness exists to quantify. Measured on the first live
subset run: of 12 documents, one came back with a finding the normalizer rejected and one lost
its connection mid-run, and each aborted the whole three-run measurement. Over 43 documents
times 3 runs, the chance of at least one such event approaches certainty, so an aborting
harness would never produce the number it was built for.

Such a document is **excluded from both sides of the fraction**, never scored as a miss.
Counting its gold rows against the reviewer would repeat the error the adapter refuses to make
when it exits 1 rather than emitting an empty finding set: *no signal is not no defects.* Each
run therefore reports its own denominator and its exclusion count, and `--max-excluded`
(default 0.15) refuses a run that lost more of the gold set than that — a result assembled from
a shifting subset stops being comparable to one that read all of it.

## Why three runs, and why the spread gates

An independent measurement of this method put the run-to-run noise floor at roughly six
goldens out of 136 labelled bugs. That is larger than most differences anyone would want to
act on, so a single number here is not a measurement. `run.sh` refuses `--runs` below three,
and `--max-spread` refuses (exit 3) to write a baseline whose own spread is wider than the
noise floor recorded for that gold set.

`compare.sh` applies the same discipline to a comparison: a candidate wins only when its
mean recall clears the baseline's by more than **both** spreads added together, and only
when both results measured the same gold tree.

## Typical use

```sh
# 1. build gold rows from a repository's fix history (private destination)
./build-gold.sh --repo ../../that-repo --repo-name group/that-repo \
                --out "$EVAL/gold" --max-fixes 200

# 2. measure the shipped reviewer, three times, writing the baseline
PRT_PROXY_URL=http://localhost:3456 \
./run.sh --gold "$EVAL/gold/*.json" --engine chat --runs 3 \
         --checkout group/that-repo=../../that-repo \
         --max-spread 0.05 --out "$EVAL/baseline.json" --readme "$EVAL/README.md"

# 3. later, compare a candidate reviewer against it
./compare.sh "$EVAL/baseline.json" "$EVAL/candidate.json"
```

The `baseline mean_r=` line in the README is **generated** by `run.sh` from the same value a
reader would check it against. A hand-written line drifts from the JSON the moment either is
edited alone, while still satisfying a loose check — which is how a baseline claim becomes
decorative.

## The ledger corpus

`parse-reviews.sh` is secondary and separate: it measures the *adjudication*, not the
reviewer. It reads plan-loop findings ledgers and the verification blocks of review files
into one CSV, so rates that have been quoted from hand counts become reproducible.

Two cautions are built into it. The ledger table header has more than twenty spellings
across the corpus, so parsing is header-driven rather than positional; a positional parser
read a seventh of the rows and silently mislabelled the rest. And the verification blocks
are prose, so that half is a heuristic that captures the first line of each limb: treat its
counts as a floor.
