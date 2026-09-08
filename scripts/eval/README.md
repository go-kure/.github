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

`note` therefore carries the whole defect description the judge sees, so `check-gold.sh` requires
it to be a non-blank string, with the same weight it gives `file` and `lines`. A row whose note is
null reaches the judge as `Defect: null`, cannot pair with any finding, and sits in the denominator
as a guaranteed miss — a corpus that silently measures lower recall. `build-gold.sh` always writes
one; the check guards a hand-edited corpus.

**Known approximation: `intro_title` is a commit subject, production passes a PR title.** The
shipped reviewer fetches the pull request and forwards `.title`; the miner has only git, so it
records the introducing commit's subject. The two coincide for a squash merge (GitHub composes
that subject from the PR title) and diverge for a rebased or multi-commit PR. Closing the gap
needs a forge call per row, which the miner deliberately does not make — it runs offline and
against private GitLab repositories where the PR number is not recoverable from git at all. On
the repositories mined so far that limitation is total rather than partial: `pr_for_commit`
recognises a squash subject, a merge-commit subject and a GitLab `See merge request` trailer, and
**none of the last 50 subjects in either mined repository is any of the three**, so all 43
documents of the first corpus carry `pr: null`. A PR-title lookup would therefore change no row
of it. Revisit if a squash-merging repository is ever added to the mining set.

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

A measurement taken under 3 is not comparable to one taken under 2 whenever the two differ, so
neither the log line nor the operator's memory is relied on for that: the summary records the
resolved digest and `compare.sh` enforces it. See "The number depends on the standards document"
below.

## The checkout is allowed to lie about its own bytes

Every git read here is a claim about a coordinate space — a line number in a blob — and a
repository's own `.gitattributes` can change what git prints without changing the blob. Two
settings do it, they are independent, and each has produced a wrong number in this harness:

- an **external diff driver** replaces the patch entirely, so the output carries no `@@` headers
  and every hunk parser reads it as "no hunks" — silence, not an error;
- a **textconv filter** transforms the content before diffing, so line numbers refer to the
  transformed text while `git blame` and `git show <rev>:<path>` still speak in the real blob's.
  Measured on a fixture whose filter duplicates every line, the same one-line change reports
  `@@ -5,2` with the filter and `@@ -3` without it. `--no-ext-diff` does **not** disable it; they
  are separate switches.

So every `git diff` and every patch-form `git show` in this harness passes **both**
`--no-ext-diff` and `--no-textconv`, and `git blame` passes `--no-textconv` explicitly even though
its default is already off — the pairing is the invariant, and a default is not a statement of
intent. Blob-form `git show <rev>:<path>` is raw regardless (verified), so it needs neither.

A symlink is the same class of problem one level up. `git show` on one prints the link target
rather than the file, while production reads the working tree with `cat` and follows it
(`pr-review-threads.sh:250-253`), so `run.sh` walks the path component by component and resolves
links itself. A target that climbs above the repository root — a root `AGENTS.md -> ../shared.md`
— makes the harness **refuse** the context rather than clamp the `..` at the root: clamping
resolves it to an unrelated in-repository `shared.md` and feeds the reviewer a document production
never showed it. Absent context is visible as a shorter prompt; wrong context is not visible at
all.

The same rule decides how `..` is resolved: **in traversal order, against the tree, never collapsed
as text first**. The two readings part company whenever a cancelled component does not exist or is
not a directory. `AGENTS.md -> missing/../real.md` is the case — the kernel stats `missing` for
production's `cat`, gets ENOENT and reads nothing, while a lexical collapse yields `real.md` and
reads it. Walking it is the same order the kernel uses and costs nothing extra, because every
component is already being looked up to find the links in the first place.

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

**`--max-excluded` is a fraction of gold ROWS, not of documents.** Rows are what the denominator
is made of, and they are not spread evenly across documents: the mining yields one row for a
one-line fix and a dozen for a refactor. A document-count ceiling therefore does not bound how
much of the corpus a run may lose. Worked case, run against both versions of the gate: a 2-document
corpus holding 1 and 9 rows, with the 9-row document excluded, is `0.5` by documents — inside a
`0.6` ceiling, so the run passes and prints a recall computed over **one** of ten gold rows — and
`0.9` by rows, which the ceiling refuses. Each run's line reports both (`excluded=1/2 docs=9/10
rows`) and the summary carries `excluded_rows_max`.

## Blame and confirmation must agree about whitespace

`blame` runs with `-w` on purpose: without it a reformat between introduction and fix is credited
as the introducer, and the harness ends up reviewing a whitespace diff for a defect it does not
contain. Confirmation then compares the fix-parent's text against the introducing commit's added
lines — and if that comparison is whitespace-*sensitive* while blame's is not, every re-indented
line is dropped as unconfirmed. Silently, and biased toward code nobody has reformatted. On a
12-fix slice of one repository that cost **14 of 16** unconfirmed drops: 91 rows became 105 across
20 → 21 documents once the two agreed.

Relaxing the comparison is not sufficient on its own, and the control case is the reason. A
reformat shows its line as both removed and added, differing only in indentation, so under a
whitespace-insensitive comparison "it appears as an addition" stops rejecting it — measured, on a
fixture the exact comparison had rejected. Confirmation therefore requires the commit to add a
whitespace-equivalent line **and not also remove one**; a genuine introduction has no counterpart
to remove.

It must do so for **every line of the span**, not the first. A gold row is one claim about a run of
lines, so evidence covering part of it is no evidence: a first line that was merely reindented
confirms against the older commit while an adjacent line whose *interior* whitespace a later commit
changed is walked past by `-w` and credited to that same older commit. Measured on a two-line
JavaScript span — one commit adds `const label = "a b";`, a later one tightens it to `"ab"`, the
fix touches both — the row was written naming a commit that never wrote the line it points at, and
`check-gold.sh` could not object, because that commit's diff does add both lines. The interior-exact
comparison above already rejects that line; it was simply never asked about it. One unconfirmed line
now fails the whole row.

Which way they agree depends on the file. In Python and YAML — both in the default include set —
indentation is syntax, so a whitespace-only edit is a real edit: reindenting moves a statement
between scopes or a key between mappings. `-w` is documented as ignoring exactly that, so on a fix
that repairs an indentation bug it walks *past* the commit that broke the file, and the row's
`head_sha` then names a diff from before the defect existed. `check-gold.sh` cannot catch it — the
span genuinely is inside that older diff. For those extensions both settings go exact instead. The
invariant is that they agree, not that they ignore whitespace.

## A measurement holds the corpus still while it reads it

`build-gold.sh --replace` cannot swap atomically — it moves the previous documents aside and
installs the new ones one at a time — so a measurement starting mid-swap matches fewer files and
reports a recall over whatever subset existed at that instant. Nothing fails: the run's own
`gold_tree` faithfully digests the partial corpus, which is a wrong number carrying correct
provenance.

`run.sh` therefore takes a **shared** lock on each corpus directory's `.build.lock` — the same
file `build-gold.sh` locks exclusively — and holds it for the whole run, then re-expands the glob
and refuses if the match set moved while the locks were being taken. Builders were already
serialised against each other; this is the reader half.

## The number depends on the standards document, so both are recorded

`run.sh` writes `standards_sha` (a digest of the bytes actually forwarded) and `standards_source`
(`pin:<sha>`, `worktree`, `override:<name>`, or `none`) into the summary, and `compare.sh` refuses
two results whose digests differ, exactly as it refuses two different gold trees.

Neither check is redundant with the other. The pinned arm and the working-tree fallback name the
same path, so only a digest separates them; and a run that found no standards document at all
digests as the literal `none`, which is a positive statement rather than a missing key — a reviewer
given no `PROJECT STANDARDS` assesses every standards-violation finding as `FALSE_POSITIVE`, and
that run must not be quietly compared against one that had the document.

The same argument covers the project-context string, with one extra turn. Production forwards a
value into both the review and the assess prompt (each consumer's `pr_review_context` input reaches
the script as `PRT_PROJECT_CONTEXT`), and that value is **per repository** — the three live
consumers describe a Go library, a CLI package manager and this workflows repo, and none of the
three strings would be right for the other two. So `--context` is a repeatable `repo=string`
mapping, matching `--checkout`, applied per gold document; `context_sha` digests the whole sorted
mapping rather than any one entry, because a single-entry digest would call two runs comparable
while a second repository's prompt differed between them.

Neither is the flag merely optional. The adapter defaults the value from `PRT_PROJECT_CONTEXT` in
its own environment, so `run.sh` passes `--context` on every invocation — with the empty string for
a repo the mapping does not name — rather than letting whatever the operator's shell exports enter
the prompt unrecorded. A repo with no mapping is logged once, since not every repository a gold
document names has a self-hosted reviewer and an empty context can be the truthful value; what is
never acceptable is silence, because a forgotten flag reads exactly like a repo that has none.

## The reviewer is scored on what it publishes

Two suppressions sit between a finding and a human, and both are unconditional in production, so
the harness applies both before judging:

- **`FALSE_POSITIVE`** — the assess pass discards these before they become threads. Crediting one
  would score a defect against a reviewer whose own second pass had already withdrawn it. **The
  assessment pass therefore runs by default**: production loops it over every chunk
  unconditionally, so a single-pass measurement inflates recall for the same reviewer while the
  filter above sits there as a no-op with nothing to announce it. `--no-assess` exists for
  measuring the review call in isolation; the result records `assess: false` and `compare.sh`
  refuses to compare it against an assessed one.
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

It also requires both results to have scored the **same rows**, not merely the same corpus.
Recall is `matched/denom`, and an excluded document leaves both sides of that fraction — so a
candidate that cannot answer on the hardest documents is not scored 0 on them, it stops being
asked. A baseline at 70/100 and a candidate that dropped those 15 rows and scored 70/85 read as
0.70 against 0.82, a 0.12 "win" that is entirely the shrunken denominator, and both can have zero
spread. `--max-excluded` does not close this: it caps how much of the corpus one run may drop, not
whether two runs dropped the same part. So `run.sh` records `excluded_per_run` — the documents it
did not measure, per repetition — and `compare.sh` refuses when the two do not match.

**Per repetition, not merged across them.** `mean_r` is the mean of `matched/denom` over the runs,
so what has to match is the multiset of per-run denominators. A union cannot express that: a
baseline that dropped one hard document in a single repetition of three and a candidate that
dropped it in all three share the identical union, while the candidate's mean is taken over two
more shrunken denominators — the same inflated recall, one level down. The comparison sorts within
each run and across runs, so it is insensitive to visit order and to which repetition dropped what,
and sensitive only to how many did. `excluded_docs` is kept alongside as the readable union; it is
not what the gate reads.

## Typical use

```sh
# 1. build gold rows from a repository's fix history (private destination)
./build-gold.sh --repo ../../that-repo --repo-name group/that-repo \
                --out "$EVAL/gold" --max-fixes 200

# 2. verify the corpus is measurable BEFORE paying for a run: this is the only check that
#    every gold span is inside the reviewed diff, and a row outside it is a guaranteed miss
#    that no reviewer can score against
./check-gold.sh --gold "$EVAL/gold/*.json" --checkout group/that-repo=../../that-repo

# 3. measure the shipped reviewer, three times, writing the baseline
#    (both model passes run by default; --no-assess measures the review call alone, which is
#     not the shipped product, and compare.sh refuses to compare the two)
#    --context is NOT optional dressing: copy the `pr_review_context:` string verbatim, because
#    production puts it in both prompts. Read it off the workflow that CALLS pr-review.yml, never
#    off pr-review.yml itself -- in a consumer repo the caller is usually that repo's own
#    .github/workflows/pr-review.yml, but in this repository it is pr-review-caller.yml, since
#    here pr-review.yml IS the reusable workflow and declares an empty default. Copying that empty
#    default measures a prompt production never sends, and run.sh cannot warn about it: the
#    unmapped-repo line fires on a MISSING --context, not on one mapped to "". One per repo the
#    corpus spans.
PRT_PROXY_URL=http://localhost:3456 \
./run.sh --gold "$EVAL/gold/*.json" --engine chat --runs 3 \
         --checkout group/that-repo=../../that-repo \
         --context "group/that-repo=<pr_review_context from that repo's workflow>" \
         --max-spread 0.05 --out "$EVAL/baseline.json" --readme "$EVAL/README.md"

# 4. later, compare a candidate reviewer against it
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
