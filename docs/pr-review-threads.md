# PR review threads

The mechanism behind the `pr-review` reusable workflow (`.github/workflows/pr-review.yml`):
resolvable, merge-gating PR review threads instead of a single wall-of-text review comment.
An AI review chunks the PR diff, reviews and fact-checks each chunk, fingerprints the
resulting findings, and reconciles them against the PR's actual GitHub review threads —
creating, replying to, resolving, and reopening them as the PR changes across pushes.

This is the design/operations reference the code cites but didn't yet have:
`scripts/lib/prt/gh.sh:13` and `scripts/pr-review-threads.sh:7` both point here.

## Components

- `.github/workflows/pr-review.yml` — the reusable workflow. Owns the job's required inputs
  (`pr_review_context`), the runner (`autops-kube-kure`, in-cluster access to the review
  backend), and the env defaults documented in its own header comment.
- `.github/actions/pr-review-threads/action.yml` — a composite action, same repo. Binds its
  inputs to `PRT_*` env vars and execs the orchestrator script. Inputs never get interpolated
  into `run:` via `${{ }}` — untrusted strings (PR body, model output) go through `env:` only,
  never through shell-parsed YAML substitution.
- `scripts/pr-review-threads.sh` — the orchestrator. Fetches the diff and PR metadata, chunks
  the diff, runs the two-pass model call (review, then assess) per chunk, computes the PR-wide
  gating cap, and reconciles findings against existing threads via two loops: one over this
  run's findings, one over existing threads no longer matched by any finding (an "absence"
  pass that handles auto-resolve when an issue is fixed).
- `scripts/lib/prt/*.sh` — the modules it sources: `state.sh` (REVIEW_INCOMPLETE tracking),
  `gh.sh` (all GitHub I/O — REST, GraphQL, retry, freshness), `diff.sh` (chunking, the
  commentable-line index), `finding.sh` (fingerprinting, ordinal/collision assignment),
  `marker.sh` (the HTML-comment marker embedded in each thread's first comment, carrying the
  fingerprint across runs), `render.sh` (job summary and comment bodies), `model.sh` (the two
  LLM calls), `reconcile.sh` (the pure decision tables — `prt_decide_finding` /
  `prt_decide_absent` — that loops 1 and 2 execute, plus the PR-wide gating-cap functions
  `prt_thread_stays_gating` / `prt_reserved_count` / `prt_gating_eligible` / `prt_apply_cap`
  that derive the cap reservation *by calling* the decision table above, rather than
  re-implementing it — the orchestrator's cap block is a single call to `prt_apply_cap`).
- `scripts/test/pr-review-threads-test.sh` — the unit suite. Every pure module function is
  covered directly; the orchestrator script itself is covered by a handful of subprocess-level
  exit-code tests (mocked `curl`), not by exercising the full reconciliation flow end to end —
  that only happens against a real PR.

## Modes

`PRT_MODE` (env `PR_REVIEW_THREADS_MODE`, org/repo variable `vars.PR_REVIEW_THREADS_MODE`
overrides the workflow's own default) is one of three values. An unrecognized value degrades to
`advisory`, never to `enforce` — a typo must fail toward the safe side of a gate
(`pr-review-threads.sh:79-87`).

- **`off`** — the incident escape hatch. Short-circuits to `exit 0` immediately after state
  init, before any network call (`pr-review-threads.sh:93-99`). See "Incident procedure" below.
- **`advisory`** (default) — zero thread creates or mutations. One plain (non-resolvable) issue
  comment per run with the merged findings table. This is the staged-rollout mechanism itself:
  advisory mode proves the pipeline works against real PRs without ever blocking a merge.
- **`enforce`** — findings become resolvable, merge-gating review threads: created on first
  sighting, replied-to-and-resolved when the model calls a finding a false positive or the issue
  disappears from the diff, reopened (reply + unresolve) if a bot-resolved thread's issue
  recurs. A thread a *human* resolved is never reopened. A PR-wide cap
  (`PRT_MAX_FINDINGS_TOTAL`, default 5) bounds how many threads can be gating at once; findings
  beyond the cap go into one overflow comment instead of a thread. Threads whose decision outcome
  remains gating reserve first (regardless of severity rank) before new findings compete for what
  remains — an open thread newly assessed `FALSE_POSITIVE` is currently gating but deliberately
  frees its slot rather than reserving it.

## The two-PR pin-bump requirement

`.github/workflows/pr-review.yml` pins the composite action by commit SHA
(`go-kure/.github/.github/actions/pr-review-threads@<sha>`), like every other action reference
in this repo. But the action and its caller both live in *this* repo, so a PR can edit the
delegate code (`.github/actions/pr-review-threads/**`, `scripts/pr-review-threads.sh`,
`scripts/lib/prt/**`) without ever touching that pin — leaving the pinned reference running
stale code until someone remembers to bump it by hand.

`scripts/check-pin-bump.sh` closes that gap in CI (`check:pin-bump` in `mise.toml`, wired into
`mise run check`): any PR that touches the delegate paths above must also move the pin in
`.github/workflows/pr-review.yml`, or the check fails. Because this repo merges via rebase
(which rewrites every commit's SHA on landing), a pin bump can never be a single PR for a
delegate-code change — no SHA known while a PR is open can be the SHA that ends up on `main`.
It is always a two-PR sequence:

1. **PR1** lands the code change and bumps the pin to a new 40-hex **placeholder** SHA, distinct
   from the prior real pin, with an inline comment marking it pending.
2. **PR2**, opened as soon as possible after PR1 merges, replaces the placeholder with the real
   merged SHA of PR1's commit on `main`.

Full procedure, the bootstrap special case, and the interim-outage-window caveat between PR1 and
PR2, including the V2 caller/callee resolution: `docs/standards.md:91-158` ("GitHub Actions
pinning" → "Same-repo composite actions and the pin-bump procedure").

## Failure surface

Every write (create/reply/resolve/unresolve/marker edit) is preceded by a freshness check
(`prt_freshness_check`, `gh.sh:106-121`) that re-fetches the PR's live head SHA and refuses to
write against a stale one — the run's real wall-clock spans multiple model calls, so the PR can
move underneath it. A write that can't complete (a failed create, a stale-head skip, a malformed
model response, a listing failure) is recorded via `prt_mark_incomplete` (`state.sh:19-23`) into
the `REVIEW_INCOMPLETE` state, rendered as its own section in the job summary
(`render.sh:109-112`) and, since this run, checked at exit: a non-empty `REVIEW_INCOMPLETE`
state makes the top-level script exit 1 instead of 0 (`pr-review-threads.sh:787` area) — "the
review could not run to completion" is now distinguishable from "the review ran and found
nothing" by exit code alone, not only by a human reading the summary. GitHub curl calls carry
`--connect-timeout 10 --max-time 120`; the model proxy call carries `--connect-timeout 10
--max-time 300` — a per-call ceiling so one hung call can't alone consume the job's
`timeout-minutes: 20` budget (see the comment at `scripts/lib/prt/model.sh` next to that value
for the arithmetic). The two GitHub reads that used to have no retry at all — the initial diff
fetch and the initial PR-metadata fetch — are now wrapped in `prt_retry` (`gh.sh:145-172`), the
same retry helper every write path already used.

## Incident procedure

Set the **org** variable `PR_REVIEW_THREADS_MODE=off`. It is checked twice: the `pr-review` job's
own `if:` (`vars.PR_REVIEW_THREADS_MODE != 'off'`) skips the whole job — checkout, Setup tools,
and the composite action step — before anything can fail; the script also checks
`vars.PR_REVIEW_THREADS_MODE || env.PR_REVIEW_THREADS_MODE` as a second, redundant short-circuit
before any GitHub or model call, in case the job-level check is ever bypassed. Between the two,
`off` covers every failure mode after the workflow starts: GitHub API rate-limiting, the model
proxy being down, a review-script bug, a checkout failure, a Setup-tools `apt-get` failure, or an
unresolvable composite-action pin. **Which repo's variable applies (V2, resolved 2026-08-18):**
`vars.PR_REVIEW_THREADS_MODE` inside this called reusable workflow resolves against the **caller's**
repository (kure/launcher), not this one — GitHub docs: "For reusable workflows, the variables from
the caller workflow's repository are used. Variables from the repository that contains the called
workflow are not made available to the caller workflow." So during an
incident, set the variable on the **affected consumer** (kure or launcher); setting a repo-level
override only on `.github` has no effect on their jobs. The **org**-level variable (today's default)
is unaffected by this — it's visible identically everywhere. Full record:
`docs/pr-review-threads-live-findings.md`. Unset the variable (or set it back to
`advisory`/`enforce`) to resume.

## What this does not cover

Live-PR verification of the specific behaviors this doc describes (the V1-V7 spike questions —
context-string identity across `merge_group`, thread staleness/deleted-file edge cases, whether
`resolvedBy` is null when the bot itself resolves a thread, whether `mode: off` actually reaches
the script as `off` through the action input) is tracked separately in
`docs/pr-review-threads-live-findings.md`, filled in once those spikes run.
