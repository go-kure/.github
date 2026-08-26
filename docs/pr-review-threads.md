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
  `json.sh` (stdin-only transforms for unbounded reconciliation collections), `gh.sh` (all
  GitHub I/O — REST, GraphQL, retry, freshness), `diff.sh` (chunking, the
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

## Token and bot identity

`pr-review.yml` wires `github-token: ${{ secrets.KURE_BOT_PAT || github.token }}` and
`bot-login: ${{ secrets.KURE_BOT_PAT != '' && 'kure-bot' || 'github-actions[bot]' }}` into the
`pr-review-threads` composite action. `bot-login` is how `scripts/pr-review-threads.sh` matches a
thread's first-comment author to decide whether a thread is "ours" to reconcile — it must always
match whichever identity `github-token` actually authors comments as.

**Why not just `github.token`:** `GITHUB_TOKEN` (and any GitHub App installation token) gets
`viewerCanResolve:false` on review threads it authors, even with `pull-requests: write` granted.
This is a categorical rejection of bot/App actor types by `resolveReviewThread`, not a scope gap —
see go-kure/.github#68 and the V6/V7 rows in `docs/pr-review-threads-live-findings.md` for the live
evidence (a GitHub App token created a comment successfully as `kure-bot[bot]` but still got
`viewerCanResolve:false` on that same thread). In `enforce` mode this means absence-resolve passes
fail closed forever — the thread blocks merge and nothing can ever auto-resolve it.

**The fix:** `KURE_BOT_PAT`, a fine-grained PAT owned by a dedicated human machine-user account
(`kure-bot`), set as an org secret with visibility limited to `.github`, `kure`, `launcher`. A
human-owned PAT is not subject to the bot/App restriction — a live probe confirmed
`viewerCanResolve:true` and a successful `resolveReviewThread` on a thread the PAT authored itself.
It reaches `pr-review.yml` via `pr-review-caller.yml`'s `secrets: inherit`; any repo where the
secret isn't set falls back to `github.token`/`github-actions[bot]`, i.e. today's create-but-never-
resolve behavior — this is a degrade, not a hard failure.

**Gotcha, if this secret ever needs regenerating:** a fine-grained PAT's "Repository access: All
repositories" is scoped to repos the token's **resource owner** account owns, not to org repos
that account merely has collaborator access to. `KURE_BOT_PAT` must be created with the **`go-kure`
org itself** selected as resource owner (available in the token-creation resource-owner dropdown
once the org's Settings → Personal access tokens policy allows fine-grained PAT access — it does).
Creating it with `kure-bot`'s personal account as resource owner produces a token that
authenticates fine but gets 403 `Resource not accessible by personal access token` on every write
to an org repo, with no repo picker even offered for org repos.

## Modes

`PRT_MODE` (env `PR_REVIEW_THREADS_MODE`, org/repo variable `vars.PR_REVIEW_THREADS_MODE`
overrides the workflow's own default) is one of three values. An unrecognized value degrades to
`advisory`, never to `enforce` — a typo must fail toward the safe side of a gate
(`pr-review-threads.sh:103-111`).

- **`off`** — the incident escape hatch. Short-circuits to `exit 0` immediately after state
  init, before any network call (`pr-review-threads.sh:123-130`). See "Incident procedure" below.
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
PR2, including the V2 caller/callee resolution: `docs/standards.md:116-221` ("GitHub Actions
pinning" → "Same-repo composite actions and the pin-bump procedure").

## Failure surface

Every write (create/reply/resolve/unresolve/marker edit) is preceded by a freshness check
(`prt_freshness_check`, `gh.sh:115-132`) that re-fetches the PR's live head SHA and refuses to
write against a stale one — the run's real wall-clock spans multiple model calls, so the PR can
move underneath it. `prt_freshness_check` names which of its three failure paths fired (read
failure, empty `.head.sha`, or a genuinely moved head printed as `expected -> live`) on stderr,
rather than returning 1 silently for all three alike (go-kure/.github#61).

Two independent, additive severities track a run's problems, both file-backed for the same reason
(a shell variable set inside a `$(...)` subshell never reaches the parent shell, and every write
path in this action runs inside one): `REVIEW_INCOMPLETE` (`prt_mark_incomplete`,
`state.sh:83-92`) and `REVIEW_DEGRADED` (`prt_mark_degraded`, `state.sh:111-120`, go-kure/.github#98).
Both share the same contract — the reason is echoed to stderr immediately (`REVIEW_INCOMPLETE:
<reason>` / `REVIEW_DEGRADED: <reason>`, not only written to the state file), and if the state
file itself can't be appended to, the marking call fails closed with `exit 1` on the spot rather
than silently tracking nothing. They differ only in what the run does with them: a write that
can't complete at all (a failed create, a stale-head skip, a listing failure, or a model response
so broken nothing in that chunk was reviewed) is `REVIEW_INCOMPLETE` and fails the run closed;
something that didn't fully succeed but still left a usable result (see the assessment-call and
partial-finding-drop cases below) is `REVIEW_DEGRADED` and lets the run exit 0. **Never
dual-mark the same event with both** — `prt_mark_incomplete`'s file is read unconditionally by the
exit gate below, so dual-marking a degraded event would force `exit 1` regardless, defeating the
point of moving it to degraded.

Both are rendered as their own section in the job summary (`render.sh:87-121`) and checked at
exit (`pr-review-threads.sh`'s tail): a non-empty `REVIEW_INCOMPLETE` state makes the top-level
script print every reason to stderr (prefixed `  - `) and as capped `::error title=...::` workflow
annotations (escaped via `prt_annotation_escape`, `state.sh`), then exit 1 instead of 0 — "the
review could not run to completion" is distinguishable from "the review ran and found nothing" by
exit code *and* job-log output, not only by a human reading the summary by hand. A non-empty
`REVIEW_DEGRADED` state (checked independently, never gating the exit code) prints the same way but
as `::warning title=...::` annotations and a `WARNING:` stderr line, since the run is not failing.

The model-review call (`prt_model_review`, `model.sh:305-325`) has its exit status checked
independently on **either** call — the original attempt and the one bounded retry alike: a
non-zero return (transport/proxy fault — curl failure, non-2xx, or empty response content,
`model.sh:286-299`) is recorded as `review call failed (transport/proxy error, exit N)` (`...
failed on retry (...)` if it's the retry attempt that faulted), with no parse attempted at all for
that call — this closes, on the review call's own retry, the same mislabeling gap a codex review
found and fixed for the assess call's retry first (see below): a transport fault there was
originally being collapsed into the "not valid JSON" branch instead of reported as its own kind of
failure. It also gets one bounded retry — not `prt_retry`'s usual 3, each call already costs 40-60s
against the job's `timeout-minutes: 20` budget — when a 2xx response fails the `jq -c '.'` parse
(`pr-review-threads.sh:237-309`), with a salvage attempt interposed ahead of that retry:
`prt_extract_json_braces` (`model.sh:33-53`) takes the substring from the first `{` to the last
`}` in the raw content and re-parses that, a no-op on already-clean JSON and a fix for a chattier
generation that wraps the JSON object in prose (`prt_strip_fence`, `model.sh:26-31`, only strips a
fenced-code-block marker that is itself the first/last line, not surrounding prose). This closes a
live incident: launcher#283 run 32175849548 hit `chunk 0: review response was not valid JSON` ->
`prt_mark_incomplete` -> fail-closed exit, then succeeded on a same-head-SHA retry 39s later.
Raising `PRT_MAX_TOKENS` or checking for `finish_reason == "length"` cannot fix this against the
current model-proxy backend — it hard-codes `maxTokens` server-side and `finish_reason` is
unconditionally `"stop"` on its non-streaming path. If both the retry and the salvage still fail
to parse, the `REVIEW_INCOMPLETE` reason for that chunk carries a shape-only diagnostic
(`prt_response_shape`) — never the response text itself, consistent with the "never logged" list
below. It has four fields:

| Field | Meaning |
|---|---|
| `len=` | content length in bytes, untrimmed |
| `leading=` | `starts-with-brace` / `starts-with-fence` / `starts-with-prose`, after trimming leading whitespace |
| `class=` | one member of `PRT_RESPONSE_CLASSES` (`prt_response_class`) |
| `sha16=` | 16 hex chars of the content's sha256 (`prt_response_fingerprint`), the same idiom and width as `prt_fp_base` |

`class=` and `sha16=` were added for go-kure/.github#81, where every PR in this repo went red with
`len=57 leading=starts-with-prose` and nothing more. That is enough to know a fixed prose string
came back, and not enough to tell a quota stop from an auth failure from an overloaded backend
from a genuine model refusal — four problems with four different owners. The backend is a
claude-max-proxy sidecar running on the host's Claude Max credentials, which has 5-hour and weekly
usage limits and returns **HTTP 200** with the limit notice as the message content, so it arrives
as "model output" rather than through the non-2xx branch that already logs a bounded body.

`class=` is a **closed enum**, not a substring of the response: every value it can print is a
literal in `prt_response_class`'s case arms, and anything unmatched prints `unrecognized`, so an
unanticipated message cannot leak a byte through it. The issue's own suggested first step — log
the raw body — would have answered the question and broken the invariant below; the class is the
part of that answer publishable in a job log. `sha16=` settles the other half: whether the backend
returns the *same* fixed string every time. #81 had to infer that from `len=57` recurring across
four runs, which is suggestive but not proof, since two distinct 57-byte responses are entirely
possible. Equal fingerprints across runs prove it; differing ones redirect the investigation to
something diff-dependent.

The model-assess call (`prt_model_assess`, `model.sh:329-357`) gets the identical salvage-then-retry
treatment (`pr-review-threads.sh:336-413`), for the same reason: it shares the backend and the
same prose-wrapping failure mode, so it gets the same recovery, not a lesser one. Before this, a
non-2xx/curl/empty-content failure from `prt_model_assess` was indistinguishable from a 2xx response
that simply wasn't parseable JSON — both fell through into an empty `assess_raw` and the same
`REVIEW_INCOMPLETE` wording (the review call above had this same flaw on its own retry path until a
later fold-in closed it there too). The two are now reported separately, on **either** call — the
original attempt and the one bounded retry alike, checked independently: a non-zero return from
`prt_model_assess` (transport/proxy fault — curl failure, non-2xx, or empty response content,
`model.sh:286-299`) is recorded as `assessment call failed (transport/proxy error, exit N)` (`...
failed on retry (...)` if it's the retry attempt that faulted), with no parse attempted at all for
that call. A 2xx response that still fails
`jq -c '.'` after both the salvage pass and the one bounded retry is recorded as `assessment
response was not valid JSON after retry=.../salvage_attempted=true (<shape>)`, using the same
`prt_response_shape` diagnostic as the review call above — never the response text itself. Either
way, the chunk's findings stay unverdicted (`verdict: null, reasoning: null`) rather than being
dropped. Unlike a review-call failure (which means the chunk wasn't reviewed at all and stays
`REVIEW_INCOMPLETE`), every one of these four assess-call failure shapes — the original attempt's
transport fault, the retry's transport fault, a residual parse failure surviving salvage+retry, and
`prt_join_assessment` rejecting a shape-valid-but-wrong-shaped `.assessments` field (distinct code
path, same outcome) — means the chunk's review itself succeeded; only the verdicts are missing. All
four are `REVIEW_DEGRADED` (go-kure/.github#98), not `REVIEW_INCOMPLETE`: the run exits 0, with the
verdict-less findings still surfaced rather than the whole run failing closed over a problem that
didn't cost the review itself.

Both are covered by the unit suite, including an explicit assertion that neither `prt_response_class`
nor `prt_response_shape` ever echoes any part of the response, and that every emitted class is a
member of the declared enum.

`prt_normalize_findings` (`finding.sh:79-151`) draws the same fatal/degraded line one level up, on
the review call's own `.findings` field, via a three-way exit status (go-kure/.github#98): `0`
clean, `1` when `.findings` itself is missing/null/non-array, OR it was array-shaped but every
element was malformed and dropped (a non-empty `.findings` array whose normalized result is empty
is total loss, not partial degradation — go-kure/.github#98 round 1 codex finding P1) — either way
nothing usable came out of the chunk (`REVIEW_INCOMPLETE`), `2` when `.findings` was array-shaped and one or more
individual rows were malformed and dropped while the rest survived (`REVIEW_DEGRADED`, reason text
`chunk N: partial-drop — ...`). The two used to share one exit code and one message; splitting them
needed a second change beyond the exit code, because `prt_normalize_findings` returning nonzero
also exists so a dropped row's *existing* review thread isn't read as absent this run
(`finding.sh:134-139`) — the absence loop's `incomplete_now` (`pr-review-threads.sh`, immediately
before its owned-thread loop) derives from `prt_is_incomplete` alone, so a partial-drop chunk that
now only calls `prt_mark_degraded` would stop setting it. The fix folds the `partial-drop` reason
directly into that check (`prt_degraded_reasons | grep -q 'partial-drop'`) rather than dual-marking:
`prt_decide_absent`'s `review_incomplete=true` branch (`reconcile.sh:111-114`) then still forces
`CLEAR_MARKER`/`NONE` instead of `SET_FIRST_ABSENT`/`REPLY_RESOLVE` for that thread, exactly as it
would for a true `REVIEW_INCOMPLETE` run, without the run itself failing closed.

`advisory` mode's single issue comment (`prt_render_advisory_comment`, `render.sh:186-234`)
discloses both severities on its own live output surface, not only in `$GITHUB_STEP_SUMMARY`: a
non-empty `advisory_incomplete_reasons` or `advisory_degraded_reasons`
(`pr-review-threads.sh:756-767`, gathered via `prt_is_incomplete`/`prt_incomplete_reasons` and
`prt_is_degraded`/`prt_degraded_reasons` respectively) renders its own warning banner ahead of the
findings table, worded to distinguish the two ("this review run was incomplete" vs "this review
run was degraded"). The degraded banner is deliberately degradation-neutral prose ("see the
reason(s) below; this may mean part of this run's output is incomplete, unverdicted, or dropped")
rather than a blanket "rows were dropped" claim: `prt_mark_degraded` covers six call sites
(`pr-review-threads.sh:334,379,413,435,448,1151`), only one of which (`:334`, a chunk's malformed
finding rows dropped) is actually a drop — the other five leave findings present but unverdicted
(an assess-call transport fault or unparseable response, an `.assessments` join failure) or are
unrelated to the current run's findings at all (`:1151`, a past run's clean-verdict comment failing
to be superseded). The banner intro no longer overrides those per-reason bullets (rendered
verbatim below it) with a claim that is only true for one of the six (round 4, go-kure/.github#101
second review pass, `chatgpt-codex-connector[bot]`). Critically, the "No issues found." shortcut
only fires when the surviving-findings count is zero **and** neither an incomplete nor a degraded
reason is being disclosed: a partial-drop chunk (`REVIEW_DEGRADED`) whose surviving findings are
then all assessed `FALSE_POSITIVE` still has `count == 0`, and printing a plain "No issues found."
there would read as a clean bill of health despite a row having been silently dropped
(chatgpt-codex-connector[bot] review, go-kure/.github#101, found post-merge-ready in round 3); the
zero-count-and-degraded branch prints "No findings to report this run — see the degraded-run
warning above." instead of the prior "No surviving findings" wording, for the same
drop-neutrality reason. Round 3's fix, however, only extended this suppression to
`degraded_reasons` and left the pre-existing zero-count-and-incomplete case falling through to the
plain "No issues found." unchanged — inverting the intended severity ordering, since
`REVIEW_INCOMPLETE` (nothing usable came out of a chunk at all) is strictly *more* severe than
`REVIEW_DEGRADED`, yet was the one case still reporting a clean result (kure-bot pr-review AI Code
Review on go-kure/.github#101 at `9b2fe22`, round 5). The suppression now fires whenever *either*
reason is present with zero surviving findings, printing "No findings to report this run — see the
incomplete-run warning above.", "...the degraded-run warning above.", or "...the incomplete-run and
degraded-run warnings above." depending on which banner(s) were actually rendered.

The clean-verdict-comment supersede failure (`pr-review-threads.sh`, the `total_findings_this_run
-gt 0` branch) is also `REVIEW_DEGRADED` rather than `REVIEW_INCOMPLETE`, matching the asymmetry
already established two branches above it in the same `if` (a listing failure there was
deliberately never `prt_mark_incomplete` either): both are best-effort tidy-up of a *past* run's
comment, not this run's primary output. The freshness-gated skips immediately around it stay
`REVIEW_INCOMPLETE` — out of scope here, tracked separately (go-kure/.github#99).

**What this does not fix:** a finding whose verdict stays `null` — whether from an assess-call
failure above, an unmatched `fp`, or a duplicate-verdict contradiction (`finding.sh:174-235`) —
still reaches `prt_decide_finding`'s `NONE` branch (`reconcile.sh:57-62`) and still becomes a
`CREATE`d, merge-gating thread needing manual resolution. Only this run's own exit code/severity
changes; a `null`-verdict finding is exactly as gating after this change as before it.

Every run that reaches the main body also emits `prt_log` stage tracing to stderr (`prt:
mode=...`, `prt: diff: <n> bytes, chunks=<n>`, per-chunk review/assess outcome, `prt: threads
listed: N, owned=M`, a `prt: fp=<fp> -> <action>` line per reconciliation decision, and a closing
`prt: done: findings=N gating=N suppressed=N incomplete=N degraded=N` line) — a successful run used to print
nothing at all between the workflow's own log markers, indistinguishable at a glance from a job
that hung (go-kure/.github#61). An early exit ahead of the first `prt_log` call — the `off`-mode
short-circuit, a non-2xx diff fetch, or a PR-metadata fetch failure — still prints its own `ERROR`/
mode line but not the full stage sequence or the closing `prt: done` line; those exits are already
unambiguous on their own (a non-zero exit code plus one explicit `ERROR:` line), so the tracing
gap there doesn't reintroduce the silent-hang shape #61 exists to close. Never logged:
`PRT_GH_TOKEN`, raw model responses, comment bodies — only fingerprints, actions, and outcomes.
The unparseable-response diagnostic above stays on the permitted side of that line by
construction: `len=`/`leading=` are shape, `sha16=` is a fingerprint, and `class=` is drawn from a
closed in-repo enum rather than from the response. Adding a field that prints response bytes —
even a truncated prefix — is the change this list forbids.

All unbounded reconciliation collections obey one additional invariant: thread pages, paginated
comment nodes, the combined `THREADS` and `OWNED` inventories, and the findings/ownership inputs to
cap eligibility reach `jq` through stdin, never through `--argjson` on external-process argv.
`json.sh` validates both array inputs and prints a replacement accumulator only on success; callers
keep the previous accumulator until that succeeds. Page extraction, array shape, concatenation,
pagination flags/cursors, nested comment updates, ownership-row construction, and cap evaluation
are all checked explicitly despite the orchestrator's deliberate lack of `set -e`. Any failure
prints a stage-only diagnostic (never the payload), records `REVIEW_INCOMPLETE`, renders the
summary, and exits 1. Inventory failures stop before cap evaluation; cap failures stop before any
GitHub write.

This closes go-kure/launcher run 32254563691: PR #284 returned review threads in 50/50/20 pages;
after the first 100 threads, the accumulator exceeded Linux's 131072-byte single-argument limit,
the next `jq --argjson` failed with `Argument list too long`, and the unchecked assignment replaced
the inventory with empty output, leaving the logged thread count blank. The regression suite now
replays that page shape, a comment inventory above the same limit with a late human reply, and an
oversized `OWNED` cap input. This removes argv-size failures; it does not bound total memory or
runtime for pathological PR histories.

GitHub curl calls carry `--connect-timeout 10 --max-time 120`; the model proxy call carries
`--connect-timeout 10 --max-time 300` — a per-call ceiling so one hung call can't alone consume
the job's `timeout-minutes: 20` budget (see the comment at `scripts/lib/prt/model.sh` next to
that value for the arithmetic). The two GitHub reads that used to have no retry at all — the
initial diff fetch and the initial PR-metadata fetch — are wrapped in `prt_retry`
(`gh.sh:156-183`), the same retry helper every write path already used; a permanent (retry-
budget-exhausted) PR-metadata fetch failure now prints its own `ERROR: failed to fetch PR
metadata` line before exiting 1, instead of relying solely on `prt_gh_rest`'s generic HTTP-status
line to explain the exit.

Neither the request payload nor the two strings it wraps ever go through `argv`
(`_prt_call_proxy`, `model.sh:218-300`): the system and user strings reach `jq` via `--rawfile`
from a temp dir, and the assembled body reaches curl via `-d @FILE`. Linux caps a *single* argv
entry at `MAX_ARG_STRLEN` = 32 pages = 131072 bytes, independent of `ARG_MAX` and of any
`ulimit`, and a chunk can legitimately exceed that: `prt_split_diff`'s hard ceiling is
`PRT_HARD_CEILING_MULT` (4) x `PRT_MAX_DIFF_CHARS` (50000) = 200000 chars for the chunk diff
alone (`diff.sh:21,32`), before the system prompt adds the project's `AGENTS.md` on top — so the
soft 50000 limit is not the bound that matters. Both call sites had to change, and they fail at
different sizes, which is why the live incident only exposed one: the payload is strictly larger
than the user string it wraps, so curl's `-d "$payload"` tripped first (`curl: Argument list too
long`) while jq's `--arg user` still fit. go-kure/launcher run 32224453949 chunk 3 hit exactly
this and fell into the non-2xx branch with an *empty* status, printing `proxy returned HTTP `
with no number — naming the proxy for a fault that never left the runner. A curl that fails to
produce a status at all is now reported separately as `prt_model: curl failed (exit N,
http_code='')`, ahead of the non-2xx branch, so a transport or exec fault is no longer
indistinguishable from a proxy response.

The regression test for this (`pr-review-threads-test.sh`, "model.sh: oversized payload") stubs
`PRT_CURL` with a **real executable on disk**, not a shell function: a function stub is called
in-process and never `execve`'d, so it cannot reproduce `E2BIG` and would pass against the broken
form, making the test vacuous.

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

## Draft PRs

The review runs on draft PRs (2026-08-19), by design — parity with the downstream GitLab CI
template this workflow was backported from, which reviews every merge-request pipeline with no
draft condition. Draft blocks merge, not review: a draft PR gets the same 2-pass review as a
ready one — resolvable threads under `enforce` (live via the `PR_REVIEW_THREADS_MODE` org
variable as of 2026-08-22, ahead of `pr-review.yml`'s own header comment — see the STALE note
there) or one plain issue comment per run under `advisory` (see § Modes above) — so review
feedback is available throughout development instead of only after the PR is marked ready.

Consumer callers keep `ready_for_review` in their own `types:` alongside the removed draft gate
(see `pr-review-caller.yml`), even though it is redundant once every consumer's rollout has
landed: this workflow is pinned `@main` in each caller, so the no-longer-draft-gated behavior only
takes effect once *this* PR merges — an async window in which a consumer PR whose own branch
already dropped the type, then marked ready with no further push, would get no re-trigger at all.
Keeping it costs one redundant run at ready-time once every consumer has picked up the merge.

## GitLab (mr-review) parity

This workflow was backported from the downstream platform's `meta/ci-templates/mr-review.yml`. Checked
against that original on 2026-08-22 (investigating go-kure/kure#684, which surfaced no findings
on either side and prompted the comparison):

- **Standards injection — fixed.** GitLab's reviewer gets `standards/cross-repo.md` and
  `standards/golangci-lint.md` fetched from the downstream platform's `meta` repo (`MR_REVIEW_STANDARDS_FILES`).
  This workflow had no equivalent — `PROJECT_AGENTS`/`PROJECT_CLAUDE_MD` only, both repo-local.
  Worse: `model.sh`'s assess system prompt already instructed the model to verify a
  `standards-violation` finding against a "PROJECT STANDARDS" section, and nothing ever populated
  one — every such finding failed that check unconditionally and was silently downgraded to
  `FALSE_POSITIVE`. Fixed by `PRT_STANDARDS_FILE` (default `docs/standards.md`, this repo's own
  go-kure-org standards doc — the direct counterpart to GitLab's two files), resolved against
  *this* checkout via `PRT_SCRIPT_DIR`, not the caller's, since the doc lives here, not in
  kure/launcher. See `pr-review-threads.sh`'s `PRT_SCRIPT_DIR` comment and `model.sh`'s
  `project_standards` parameter.
- **Review token budget — investigated, NOT bumped; the doc's own claim wins.** GitLab bumped
  `MR_REVIEW_MAX_TOKENS` 1500→2000 "to fit structured JSON findings with fix prose"; this
  workflow's `PR_REVIEW_MAX_TOKENS` is still 1500. Left alone: § Failure surface above already
  documents that the shared claude-max-proxy backend hard-codes `maxTokens` server-side and
  ignores the request value entirely, so raising it here would be a no-op against the live
  backend, identical to GitLab's presumed-but-unverified rationale for its own bump against the
  same backend. Neither side's token knob does anything today; not a divergence worth closing.
- **Deliberate, not gaps** — chunk size (`PR_REVIEW_MAX_DIFF_CHARS` 50000 vs GitLab's 400000) and
  the PR-wide findings cap (`PR_REVIEW_MAX_FINDINGS_TOTAL`, 5, GitLab has none): thread-noise and
  per-call-latency controls this workflow's `enforce` mode needed that GitLab's older note-only
  history never did. §9's `backend_unavailable()` denylist has no GitHub-side counterpart, but
  §9b (`REVIEW_NO_STRUCTURED_OUTPUT`, unconditional fail-closed on unparseable output regardless
  of cause) covers the same purpose without GitLab's lagging phrase-list. No Mattermost webhook
  equivalent exists on this org.

## What this does not cover

Live-PR verification of the specific behaviors this doc describes (the V1-V7 spike questions —
context-string identity across `merge_group`, thread staleness/deleted-file edge cases, whether
`resolvedBy` is null when the bot itself resolves a thread, whether `mode: off` actually reaches
the script as `off` through the action input) is tracked separately in
`docs/pr-review-threads-live-findings.md`, filled in once those spikes run.
