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
(`pr-review-threads.sh:80-88`).

- **`off`** — the incident escape hatch. Short-circuits to `exit 0` immediately after state
  init, before any network call (`pr-review-threads.sh:100-107`). See "Incident procedure" below.
- **`advisory`** (default) — zero thread creates or mutations. One plain (non-resolvable) issue
  comment per run with the merged findings table. This is the staged-rollout mechanism itself:
  advisory mode proves the pipeline works against real PRs without ever blocking a merge.
- **`enforce`** — findings become resolvable, merge-gating review threads: created on first
  sighting, replied-to-and-resolved when the model calls a finding a false positive or the issue
  disappears from the diff (including when the *whole* net diff goes empty — see below), reopened
  (reply + unresolve) if a bot-resolved thread's issue recurs. A thread a *human* resolved is
  never reopened. A PR-wide cap
  (`PRT_MAX_FINDINGS_TOTAL`, default 5) bounds how many *new* threads can start gating per run;
  findings beyond what's left of the cap go into one overflow comment instead of a thread.
  Threads whose decision outcome remains gating — or, for a thread absent from this run's
  findings, that simply stays open — reserve first (regardless of severity rank) before new
  findings compete for what remains; an open thread newly assessed `FALSE_POSITIVE` is currently
  gating but deliberately frees its slot rather than reserving it. The cap only ever gates *new*
  candidates: it never forces an already-gating thread closed, so if more threads are already
  reserved than the cap allows (all `remaining` clamps to 0, never negative) the total gating
  count for that run can still exceed `PRT_MAX_FINDINGS_TOTAL` — the cap bounds growth, not the
  standing total.

  An empty net diff against base (e.g. a file added then deleted again within the same PR) is
  reviewed in `enforce` as zero findings rather than short-circuiting ahead of thread listing and
  both reconciliation loops (go-kure/.github#60) — a gating thread whose file was reverted this
  way can otherwise never be seen as absent and never auto-resolves. `advisory`/`off` keep the
  cheap `exit 0` on an empty diff, since neither ever creates or reconciles a thread. Auto-resolve
  from absence still takes **two** separate runs at two different head SHAs, not one: the first
  empty-diff run stamps a `first_absent_sha` marker; only a later run — empty diff or not — whose
  head has moved past that SHA replies and resolves. This mirrors the existing two-push behavior
  for a finding the model itself calls a false positive; an empty diff does not shortcut it to one
  push.

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
(`prt_freshness_check`, `gh.sh:115-132`) that re-fetches the PR's live head SHA and refuses to
write against a stale one — the run's real wall-clock spans multiple model calls, so the PR can
move underneath it. `prt_freshness_check` names which of its three failure paths fired (read
failure, empty `.head.sha`, or a genuinely moved head printed as `expected -> live`) on stderr,
rather than returning 1 silently for all three alike (go-kure/.github#61). A write that can't
complete (a failed create, a stale-head skip, a malformed model response, a listing failure) is
recorded via `prt_mark_incomplete` (`state.sh:54-63`) into the `REVIEW_INCOMPLETE` state: the
reason is echoed to stderr as `REVIEW_INCOMPLETE: <reason>` immediately (not only written to the
state file), and if the state file itself can't be appended to, `prt_mark_incomplete` fails
closed with `exit 1` on the spot rather than silently tracking nothing. `REVIEW_INCOMPLETE`
reasons are also rendered as their own section in the job summary (`render.sh:109-112`) and
checked at exit: a non-empty `REVIEW_INCOMPLETE` state makes the top-level script print every
reason to stderr (prefixed `  - `) and as capped `::error title=...::` workflow annotations
(escaped via `prt_annotation_escape`, `state.sh`), then exit 1 instead of 0
(`pr-review-threads.sh:778`) — "the review could not run to completion" is now distinguishable
from "the review ran and found nothing" by exit code *and* job-log output, not only by a human
reading the summary by hand.

Every run that reaches the main body also emits `prt_log` stage tracing to stderr (`prt:
mode=...`, `prt: diff: <n> bytes, chunks=<n>`, per-chunk review/assess outcome, `prt: threads
listed: N, owned=M`, a `prt: fp=<fp> -> <action>` line per reconciliation decision, and a closing
`prt: done: findings=N gating=N suppressed=N incomplete=N` line) — a successful run used to print
nothing at all between the workflow's own log markers, indistinguishable at a glance from a job
that hung (go-kure/.github#61). An early exit ahead of the first `prt_log` call — the `off`-mode
short-circuit, a non-2xx diff fetch, or a PR-metadata fetch failure — still prints its own `ERROR`/
mode line but not the full stage sequence or the closing `prt: done` line; those exits are already
unambiguous on their own (a non-zero exit code plus one explicit `ERROR:` line), so the tracing
gap there doesn't reintroduce the silent-hang shape #61 exists to close. Never logged:
`PRT_GH_TOKEN`, raw model responses, comment bodies — only fingerprints, actions, and outcomes.

GitHub curl calls carry `--connect-timeout 10 --max-time 120`; the model proxy call carries
`--connect-timeout 10 --max-time 300` — a per-call ceiling so one hung call can't alone consume
the job's `timeout-minutes: 20` budget (see the comment at `scripts/lib/prt/model.sh` next to
that value for the arithmetic). The two GitHub reads that used to have no retry at all — the
initial diff fetch and the initial PR-metadata fetch — are wrapped in `prt_retry`
(`gh.sh:156-183`), the same retry helper every write path already used; a permanent (retry-
budget-exhausted) PR-metadata fetch failure now prints its own `ERROR: failed to fetch PR
metadata` line before exiting 1, instead of relying solely on `prt_gh_rest`'s generic HTTP-status
line to explain the exit.

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
