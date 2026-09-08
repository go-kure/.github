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
| `check-gold.sh` | Asserts a corpus is measurable before a run is spent on it |
| `parse-reviews.sh` | Turns a corpus of adjudicated review ledgers into one CSV |

## The reviewer must never be told the answer

A gold document records both the **introducing** commit and the **fix** that repaired it, and
only one of them may reach the reviewer.

`intro_title` is the introducing commit's own subject and is what `run.sh` passes as the review
title — what a reviewer of that change would genuinely have seen. `note` is the fix commit's
subject and stays server-side, for the judge and for whoever reads the corpus. Because the mining
selects on `--grep '^fix'`, `note` names the defect by construction: `fix(nats):
reply.replyWithError not s.replyWithError in bootstrap.render schema-version rejection` is a real
one. Passing it as the title of the pre-fix diff measures how well a model can act on a hint.

This is not hypothetical — the harness did exactly that on its first full run, on all 43
documents, and the resulting baseline was withdrawn. A document with no `intro_title` (any corpus
built before the field existed) gets a neutral constant, never the note.

## The standards doc is read at the revision production reads it at

`PROJECT STANDARDS` is part of the reviewer's system prompt, and a rule that is absent from it
forces every finding citing that rule to `FALSE_POSITIVE` (`lib/prt/model.sh:253-256`). So the
revision of `docs/standards.md` the harness forwards is not a detail — it moves recall, silently,
through the publication filter below.

Production does not read the working tree. `pr-review.yml` pins the composite action to a SHA and
the action resolves `standards-file` inside its own pinned checkout (`action.yml:72-78`), so the
reviewer under measurement sees `docs/standards.md` **as of that pin**, not as of your branch.
`run.sh` resolves it the same way, in this order:

1. `--standards <path>` if given (an explicit A/B of a proposed standards change);
2. `docs/standards.md` at the SHA `.github/workflows/pr-review.yml` pins its action to, read out
   of git rather than the tree;
3. the working tree's copy, with a warning — the fallback when the pinned commit is not fetched.

A measurement taken under 3 is not comparable to one taken under 2 whenever the two differ. The
log line says which one ran; record it beside the number.

## Run `check-gold.sh` before spending a run

```sh
./check-gold.sh --gold 'eval/gold/*.json' --checkout go-kure/kure=<path>
```

It asserts every row is `confirmed`, every document has an `intro_title`, and — the one that
matters — that **every line of every gold row falls inside a hunk the reviewed diff actually
adds**.

A row pointing outside that diff is a defect no reviewer could ever match, and it is invisible
in the output: recall simply comes out low, which is what a reviewer under test is expected to
produce anyway. On the first corpus this harness built, **26 of 63 rows (41%) pointed outside
the reviewed diff** because blame's post-fix line number was stored where the introducing
commit's was needed. Both line numbers are now carried separately.

The check reads the whole span, not its first line, because a row can start on a line the
commit did add and then run on over lines it did not — see the next section.

## Why the gold set needs confirming

`git blame` names the commit that **last touched** a line, not the one that introduced the
defect. A reformat, a rename or a whitespace pass in between makes an innocent change the
accused. `build-gold.sh` therefore keeps a candidate only when the blamed commit's own diff
adds that exact line text, and drops and counts everything else. It also drops rows outside
source files and rows whose blame span is wider than `--max-span`: a wide span means the fix
rewrote a block rather than repairing a located defect, so the "faulty line" is an artefact
of the rewrite's boundaries.

**A row is one contiguous run of lines, not one commit's whole footprint in a file.** Several
commits routinely interleave inside a blamed range, so collapsing a commit's lines to
`min..max` records a hull over other people's code. In `versions.yaml` at one kure fix, a
commit that introduced exactly two lines — 124 and 129, with three other commits' lines between
them — was recorded as `[124,129]`, claiming four lines it never wrote; another was recorded as
`[69,80]` for seven lines of actual contribution. Both effects are silent: `--max-span` measures
the inflated width and keeps rewrites it was meant to drop, and the row asks the reviewer to
flag code whose defect belongs to a different commit. Emitting one row per contiguous run fixes
both, and yields **more** gold, not less — on one 12-fix slice of kure, 22 rows across 19
documents became 60 rows across 22, because narrower spans clear `--max-span` where the hull
did not.

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
ask for. Those abort. The distinction is carried in the exit code, not inferred: `review-adapter.sh`
and `judge.sh` reserve **exit 2** for a setup fault and **exit 1** for "the backend gave me nothing
usable", and `run.sh` aborts on the first and excludes on the second. Folding them together would
let a deterministic fault spend one exclusion per document and arrive as a shrunken denominator
rather than an error.

A reviewer or judge that cannot produce a usable answer is the **backend being
nondeterministic** — the property this harness exists to quantify. Measured on the first live
subset run: of 12 documents, one came back with a finding the normalizer rejected and one lost
its connection mid-run, and each aborted the whole three-run measurement. Over 43 documents
times 3 runs, the chance of at least one such event approaches certainty, so an aborting
harness would never produce the number it was built for.

**Partial failure counts as failure.** A diff split into several chunks can have one chunk come
back unusable while another succeeds; the adapter still exits 0, because the findings it did get
are real. But the document's gold rows are judged as a whole, so a row sitting in the chunk that
never got an answer would be scored as a miss by a reviewer that never read it — the same error
one level down, biased by exactly the failure rate this section exists to tolerate. The adapter
reports `chunks_failed` and `run.sh` excludes any document with a non-zero count. Restricting the
denominator to the reviewed chunks would be better and is not available: chunks are byte ranges
of a diff, gold rows are file/line pairs in a revision, and nothing maps one to the other.

**Truncation is the same event with a zero failure count.** When one hunk alone exceeds the hard
ceiling, the chunker truncates its body, records `REVIEW_INCOMPLETE` and still returns a usable
chunk; the model answers it, so `chunks_failed` stays `0` while the discarded tail is diff the
reviewer never received. `run.sh` therefore also excludes any document whose adapter output
carries a non-empty `incomplete` array.

## The reviewer is scored on what it publishes

Two suppressions sit between a finding and a human, and both are unconditional in production, so
the harness applies both before judging:

- **`FALSE_POSITIVE`** — the assess pass discards these before they become threads. Crediting one
  would score a defect against a reviewer whose own second pass had already withdrawn it.
- **`collision`** — `prt_assign_ordinals` sets this on *every* member of a group sharing a file
  and a category, and the decide table's first row returns `NONE` for each. Nothing publishes
  them.

Filtering one and not the other measures neither the engine nor the product. The consequence is
worth stating plainly: an engine emitting several findings per file and category scores lower
here. That is a real property of the delivered system — those findings are withheld today — not
a scoring artefact. An engine meant to be judged *before* the thread lifecycle needs a flag and a
paragraph here, not a silent removal of the filter.

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
