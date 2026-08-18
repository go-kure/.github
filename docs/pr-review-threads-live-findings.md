# PR review threads — live-PR findings

Recorded answers to the empirically-verified-facts block cited by
`scripts/lib/prt/gh.sh:13-21`, and to the V1-V7 spike questions from the Phase 2 plan. Each row
is a question that can only be answered by observing a real PR/merge-queue run against GitHub —
not by reading the code or the docs. This file is the scaffold; **do not fill in an answer
without having actually run the spike.** Rows stay `PENDING` until then.

V1 is answered by Phase 2 Task 4 (requires `merge_group:` wired into a real merge queue — see
Task 3). V2-V7 are answered by Phase 2 Task 5, run against a `.github` scratch PR once
`continue-on-error: true` is removed from `pr-review.yml`.

| # | Question | Answer | Recorded | Evidence |
|---|----------|--------|----------|----------|
| V1 | Is the required-check context string (`pr-review / AI Code Review`) byte-identical on a `merge_group` run as on a `pull_request` run? | PENDING — not yet run (Phase 2 Task 4/5) | | |
| V2 | Does `vars.PR_REVIEW_THREADS_MODE` resolve inside a *called* reusable workflow, and against which repo (caller's or callee's)? | PENDING — not yet run (Phase 2 Task 4/5) | | |
| V3 | Does an outdated-but-unresolved review thread still block merge? | PENDING — not yet run (Phase 2 Task 4/5) | | |
| V4 | Does a review thread anchored on a since-deleted file still block merge? | PENDING — not yet run (Phase 2 Task 4/5) | | |
| V5 | What does `POST /pulls/{n}/comments` actually return (status + body) for an out-of-diff `line`, and for `subject_type: file` on a path not present in the PR? | PENDING — not yet run (Phase 2 Task 4/5) | | |
| V6 | Is GraphQL's `resolvedBy` null when the **bot** itself resolves a thread (vs. a human)? | PENDING — not yet run (Phase 2 Task 4/5) | | |
| V7 | Does `mode: off` actually reach the script as `off` through the composite action's `mode` input, given `action.yml` only documents `enforce`/`advisory` as its default/example values? | PENDING — not yet run (Phase 2 Task 4/5) | | |

Columns: **Recorded** is the date the answer was actually observed and written here (not the date
this scaffold was created). **Evidence** is a pointer to what was observed — a workflow run URL,
a Checks API response, a specific PR/thread/comment — not a restatement of the answer.

Once filled in, cross-reference the corresponding facts already asserted (and marked
"unverified"/"until a live spike") at:

- `scripts/lib/prt/gh.sh:13-21` — the rate-limit-as-HTTP-200 and resolve-permission facts already
  recorded there predate this table; V6 extends that block once answered.
- `scripts/pr-review-threads.sh:330` — the `resolvedBy` fail-closed comment cites V6 directly.
