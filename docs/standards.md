# go-kure Org Standards

This is the canonical standards reference for all `go-kure/*` repositories. It describes how
go-kure repos are configured and where they diverge from the workspace defaults.

## Why go-kure is Different

The go-kure repos are:

1. **Public open-source projects** — must accommodate external contributors
2. **Hosted on GitHub** — use GitHub Actions, not GitLab CI. Dependency updates are Renovate
   across all three repos here, via the shared preset this repo hosts and also extends on
   itself. `go-kure.github.io` — not a member of this table, see below — is the org's one
   remaining Dependabot repo. See [Dependency Management](#dependency-management).
3. **Released independently** — separate cadence from the downstream platform

## Organization Members

| Local dir     | GitHub repo         | Role                                                    |
|---------------|---------------------|---------------------------------------------------------|
| `kure/`       | `go-kure/kure`      | Kubernetes resource library (Go)                        |
| `launcher/`   | `go-kure/launcher`  | kurel CLI / OAM-native package manager (Go)             |
| `dot-github/` | `go-kure/.github`   | Org-wide community files + settings automation (Shell)  |

## Applicable Standards

| Standard            | kure     | launcher | .github  | Notes |
|---------------------|----------|----------|----------|-------|
| Agentic files       | Yes      | Yes      | Yes      | `.claude/CLAUDE.md` + `AGENTS.md` required in each repo |
| mise.toml           | Yes      | Yes      | N/A      | Same Go + golangci-lint versions as `meta/versions.env` |
| golangci-lint       | Modified | Yes      | N/A      | kure relaxes two linters during migration; launcher uses the full set |
| Container builds    | No       | No       | N/A      | kure is a library; launcher ships binaries via GoReleaser, no container |
| CI/CD               | Modified | Modified | Modified | GitHub Actions; kure + launcher call shared workflows hosted here |
| Dependency updates  | Same | Same | Same | Renovate (shared preset hosted here); `.github` extends its own preset — see [Dependency Management](#dependency-management) |
| Repository settings | Modified | Modified | Modified | Applied by this repo's `settings.yml` workflow |

## CI Platform

| Aspect           | Workspace Default    | kure                        | launcher                    | .github                     |
|------------------|----------------------|-----------------------------|-----------------------------|-----------------------------|
| Platform         | GitLab CI            | GitHub Actions              | GitHub Actions              | GitHub Actions              |
| Config file      | `.gitlab-ci.yml`     | `.github/workflows/*.yml`   | `.github/workflows/*.yml`   | `.github/workflows/*.yml`   |
| Shared workflows | `meta/ci-templates/` | Callers to `go-kure/.github`| Callers to `go-kure/.github`| Hosts the shared workflows  |

kure and launcher stay thin — each repo has only caller workflows that delegate to the reusable
workflows here.

## Dependency Management

| Aspect | Workspace Default  | kure                     | launcher                 | .github            |
|--------|----------------|--------------------------|--------------------------|--------------------|
| Tool   | Renovate       | Renovate                 | Renovate                 | Renovate           |
| Config | `renovate.json`| `renovate.json`          | `renovate.json`          | `renovate.json` (self-extends the preset it hosts) |

### Shared Renovate preset

`renovate/shared.json` in this repo is the org-wide Renovate preset. Consumer repos
extend it with:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["github>go-kure/.github//renovate/shared"]
}
```

What it encodes:

- **Grouping** — mise toolchain, Go minors and patches split (so patch groups stay
  automerge-eligible), and ecosystem groups (kubernetes, sigs.k8s.io, fluxcd,
  cloudnative-pg) that follow upstream release cadence.
- **Every major update requires dependency-dashboard approval**, across every manager
  currently in use (`gomod`, `mise`, `dockerfile`, `github-actions`, `npm`) plus
  `customManagers` regex/jsonata entries (matched via `custom.*`) — not a blanket
  guarantee for a manager Renovate could enable in the future but this preset does
  not yet list. Majors routinely need coordinated changes (import paths, config
  migration) that an auto-created PR cannot carry.
- **The Go toolchain is pinned and gated**: the `go` dep (mise + gomod + a
  custom-managed `go`, if any repo ever adds one) and the `golang` container image
  require dashboard approval and carry an `allowedVersions` ceiling that tracks
  Go's two-release support window. The ceiling is lifted deliberately when the next
  Go major ships, never by a bot.
- **Automerge** only for mise minor/patch/digest and gomod patch/digest, and never
  for `github.com/go-kure/**` — cross-repo bumps carry release-ordering constraints
  (launcher must not lead the kure release it imports; see launcher's
  `check-kure-dep-sync` guard).
- **Vulnerability alerts** — `vulnerabilityAlerts.enabled: true` raises a PR for a known-CVE
  dependency immediately, bypassing `minimumReleaseAge`/schedule/`dependencyDashboardApproval`
  gates (Renovate's own default for the block already does this; nothing here restates it).
  `addLabels: ["security"]` marks the PR without disturbing whichever automerge lane it lands
  in. `osvVulnerabilityAlerts: true` additionally consults the offline osv.dev database — the
  only alert source for GitLab-hosted consumer repos, since GitHub's own Dependabot-alert
  integration this preset also benefits from is platform-specific to repos hosted here. OSV
  covers gomod/npm/pypi/maven/… datasources; it does not cover `docker`, `dockerfile`,
  `github-actions`, `mise` or other non-package-manager pins.

- **Go `testdata` trees are out of scope** — a top-level `ignorePaths` entry `**/testdata/**`
  drops every file under a `testdata/` directory before any manager extracts it, backed by a
  `packageRules` entry matching the same paths with `enabled: false`. Renovate's inherited
  `:ignoreModulesAndTests` default skips `examples/`, `test/`, `tests/` and `__fixtures__/` but
  not Go's `testdata/`, so a fixture a default manager happens to match (a `values.yaml` with a
  placeholder image, via `helm-values`) drew a permanent "Package lookup failures" block on a
  consumer's Dependency Dashboard, and a fixture with a real image would draw a genuine bump PR
  rewriting it away from its expected output. `ignorePaths` is the guarantee and the rule is the
  fallback, not the other way round: a vulnerability alert appends a synthetic rule after every
  authored one whose `force` block sets `enabled: true`, so a vulnerable dependency in a fixture
  that reached package rules would be looked up and PR'd despite the rule (verified on Renovate
  44.14.10, 44.42.0 and 44.65.3; the lane-policy test pins it). `ignorePaths` is not mergeable —
  a value set in a preset or a consumer replaces the inherited list rather than extending it —
  so the preset restates the inherited entries in full. `:ignoreModulesAndTests` also ships a
  manager-level override, `nuget.ignorePaths` (it keeps `test/` and `tests/` in scope for NuGet),
  and Renovate merges that over the top-level list for that manager, so the preset restates the
  NuGet list too, with the same entry added; the lane-policy test fails if the installed
  Renovate's own lists ever carry an entry the restated copies lack, and separately if any
  manager-level override, inherited or authored, stops dropping a `testdata/` file. The rule is
  what still applies where a consumer's own list replaced the preset's: a consumer's top-level
  `ignorePaths` replaces the top-level list for every manager without an override, and a
  consumer's `nuget.ignorePaths` replaces the restated NuGet one (a top-level consumer value
  leaves the preset's `nuget` block intact, since manager objects merge rather than replace).
  There, `enabled: false` skips the lookup, with no warning and no PR, while the dependency
  still appears under the dashboard's detected dependencies.

- **Lane labels** — every PR gets exactly one of `unattended` (Renovate merges it once checks
  pass — do not review, merge, or close it) or `needs-human` (blocked on a human). Set via
  `labels`, never `addLabels`: `labels` is a scalar that the last matching rule overwrites, while
  `addLabels` unions across every matching rule and can never be removed by a later one — building
  this on `addLabels` would let a rule advertise "this will automerge" and a later
  `automerge: false` rule leave the label in place regardless. See [Labels](../standards/labels.md)
  for the label definitions.

Repos add repo-specific rules (e.g. `postUpgradeTasks` running the repo's own
`scripts/sync-versions.sh generate` so generated docs move in the same commit as the
version bump) in their own `renovate.json` on top of the preset.

#### Policy test

`scripts/test/renovate-lane-policy-test.mjs`, run by `mise run test` and the required `test` CI
context, runs Renovate's own `applyPackageRules` resolver over a matrix of representative
dependency-update paths — one or more per `packageRules` entry — and asserts each resolves to
exactly one lane label. It also asserts, structurally over the config itself, that no rule sets a
lane via `addLabels`, that every `automerge: false` rule sets `needs-human`, and that every
`automerge: true` rule sets `unattended`. A `packageRules` entry with no matrix case exercising it
is a hard failure, so a new rule cannot go unverified by omission. A separate matrix covers the
`vulnerabilityAlerts` path, which bypasses `packageRules` entirely via a synthetic rule Renovate
injects at fetch time.

The test runs against the installed `renovate` package's own rule resolver, not a reimplementation
of Renovate's semantics — pinned in `scripts/test/renovate-version`, read by both `mise run test`
and the `test` CI job. Nothing bumps this pin automatically; raise it deliberately when adopting a
newer Renovate major, in step with `CI_RENOVATE_IMAGE` on the workspace side so the version this
test resolves against does not drift from what actually runs the config.

This preset and the workspace-default preset that GitLab repos consume are **asserted
equivalent** by an automated parity check on the workspace side, which runs on every pipeline
there and goes red on drift. Equivalence is asserted after normalizing the differences the two
platforms force: the GitLab-CI ↔ GitHub-Actions manager swap, the matching `groupName` rename,
and the downstream first-party matcher entries this public copy cannot carry. Everything that is
policy — which rules exist, in what order, with which `automerge`, `allowedVersions` and
`dependencyDashboardApproval` flags — must match.

This copy is deliberately the narrower of the two: it is public and upstream-only, so it carries
no matcher naming any downstream module (see § No Downstream References). A downstream consumer
adds its own first-party matchers, including any automerge exclusion for them, on top. The parity
check strips exactly those entries before comparing, and no others — so any divergence beyond the
platform-imposed ones still fails.

**Practical consequence:** a change to `renovate/shared.json` very likely needs a matching change
on the workspace side, or that side's pipeline breaks. Landing one without the other is not a
silent no-op.

Correction, recorded so it is not reintroduced: a previous revision of this paragraph claimed
that no such parity check existed, and that equivalence had already lapsed by more than a manager
swap. **Both claims were wrong.** The check does exist, and it was green immediately before the
upstream-only change above — that change is what broke it, and the resulting red pipeline is what
surfaced the error. The earlier claim was made after searching for the check by a similar name,
finding a different script that compares a different pair of files, and concluding from its
absence that nothing compared the presets.

`.github` now onboards itself onto Renovate too, via a `renovate.json` that
self-extends the preset hosted here — closing a real gap: this repo's own
mise-pinned tools (actionlint, shellcheck, yq, lychee, node) had no updater of
any kind while it stayed Dependabot-only, since Dependabot has no mise
ecosystem and cannot read a bare version file. No bot-side change was needed:
the runner's `--autodiscover-filter=go-kure/*` already matches this repo, and
the same PAT already reaches it. `go-kure.github.io` (not a member of this
table — it hosts rendered site content, not application code) is the one
repo left in the org on Dependabot, for its single `github-actions` ecosystem.

### GitHub Actions pinning

Every third-party action is pinned to a full 40-character commit SHA, with the
tag kept as a trailing comment so Dependabot still bumps it:

    uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7

A tag is a mutable pointer. In March 2025 (CVE-2025-30066) an attacker moved the
tags of `tj-actions/changed-files` onto a poisoned commit and ~23,000 repositories
executed it. `scripts/check-action-pins.sh` fails CI on any unpinned ref;
`actions.sha_pinning_required` in `governance/repository-settings-policy.yaml`
enforces the same rule at the org level, independently.

Exempt: `./local-action` paths, `docker://` refs, and first-party *reusable
workflow* refs (`go-kure/*/.github/workflows/x.yml@main`), which are governed
by this org's branch protection. First-party *composite action* refs
(`go-kure/*/.github/actions/x@main`) are **not** exempt — see below.

Consumer repos run the same checker as a composite action — do not vendor a copy.
Pin it like any other action. This organization publishes no tags on `.github`, so
the ref is a `main` commit with `# main` as the trailing comment, and Dependabot
cannot bump it — it is maintained by hand. The SHA below is an example of the
shape, not a recommendation: it predates the `FIRST_PARTY_WORKFLOW_RE` override
described further down, so a consumer that relies on the override must pin a
`main` commit at or after the one that merged go-kure/.github#154 — take the
current one from `gh api repos/go-kure/.github/commits/main --jq .sha`:

    uses: go-kure/.github/.github/actions/check-action-pins@1793023365e5af6923e9bb6b424fcea1dca1279e # main

Enabling `sha_pinning_required` covers actions from this organization too — a
`go-kure/.github/.github/actions/x@main` reference is rejected at runtime just
like a third-party one. Reusable workflows (`go-kure/.github/.github/workflows/
x.yml@main`) are exempt by GitHub's own rule and deliberately stay on `main`;
`scripts/check-action-pins.sh` draws the same line.

The exemption is go-kure-only by default. A consumer organization that publishes its
own reusable workflows widens it by setting `FIRST_PARTY_WORKFLOW_RE` in the checker's
environment — on the composite-action step (`env:`) or the local task — for example
`'^(go-kure|acme)/[^/]+/\.github/workflows/[^@]+@'`. The pattern is consulted only for
refs of the reusable-workflow shape (`owner/repo/.github/workflows/file.yml@ref` — a
`.yml`/`.yaml` file directly under `.github/workflows/`, since a composite action can live
in any directory but only such a file can be a reusable workflow), which is fixed in the
checker, so it can only narrow *which* reusable workflows count as first-party — even a
permissive `'^acme/'` cannot exempt a composite or plain action.
Because an override weakens a security check, the checker prints
`NOTE: FIRST_PARTY_WORKFLOW_RE override in effect: <pattern>` on stderr whenever a
non-default pattern is active, so a widened run is visible in the log.

**Known gap:** Dependabot rewrites the trailing tag comment together with the SHA
when it bumps a pin, but has documented edge cases where it resolves to an
untagged branch-HEAD commit and leaves the comment stale
(dependabot/dependabot-core#14716, #13466, #7912). `check-action-pins.sh` only
verifies the ref is a 40-hex SHA — it cannot detect a comment that no longer
names the commit's actual tag. Treat a suspicious version comment as a reason
to check the SHA by hand, not as ground truth.

**Same-repo composite actions and the pin-bump procedure.** A first-party composite
action that lives in this repo (e.g. `.github/actions/pr-review-threads/`) is pinned
by SHA in `.github/workflows/pr-review.yml` exactly like any other action above — but
because the action and its consumer both live here, a PR can edit the action's
delegate code without touching the pin at all, silently leaving the pinned reference
running stale code until someone remembers to bump it by hand.

`scripts/check-pin-bump.sh` closes that gap in CI: it diffs the PR against its base
ref, and if any of `.github/actions/pr-review-threads/**`, `scripts/pr-review-threads.sh`,
or `scripts/lib/prt/**` changed, it fails unless `.github/workflows/pr-review.yml`'s
pinned SHA also changed. It only checks that the pin *moved*, not that it points at a
reachable commit — see the bootstrap note below for why.

Bootstrapping a same-repo action is a two-PR sequence, because this repo merges via
rebase, which rewrites every commit's SHA — so no SHA known while the PR is open can
ever be the SHA that ends up on `main`:

1. **PR1** lands the action and its delegate scripts. Prefer landing them **without** wiring
   up a `uses:` call site at all: `check-pin-bump.sh`'s "no prior pin on the base ref"
   bootstrap exception passes trivially whether or not a pin line exists yet
   (`scripts/check-pin-bump.sh:59` returns OK before ever looking for one), so PR2 can add
   the `uses:` line for the first time, pointing straight at PR1's real merged SHA — no
   placeholder, no outage window, in one atomic step.
   **Only if PR1 must also activate the call site** (wiring up `uses:` immediately) is a
   placeholder needed, and only then is all-zeros (or any other 40-hex value) genuinely the
   right choice: the action does not exist at any commit reachable from `main` yet, so
   all-zeros, `main`'s own tip, and every earlier `main` commit alike fail to resolve the
   action's path for the whole PR1-to-PR2 window — activating early is what creates this
   cost, not bootstrapping itself; see the non-bootstrap rule below for the case that *can*
   avoid it while still activating in PR1.
2. After PR1 merges, **PR2** adds or replaces the `uses:` line with the real, now-final SHA
   of the merged commit on `main`.

**No PR to this repo that modifies the composite action can ever be validated live by its own
CI.** The reusable-workflow pin (`pr-review-caller.yml`'s `uses: go-kure/.github/.github/workflows/pr-review.yml@main`)
resolves the entire called workflow's content — including every nested action pin — from `main`
at call time, not from the calling branch: this is true for every PR on this repo, self-referential
by construction, not a bug in a given PR. A PR editing `.github/actions/pr-review-threads/**`,
`scripts/pr-review-threads.sh` or `scripts/lib/prt/**` therefore has its own reconciliation
mechanics (quarantine outcomes, the accounting invariant, thread create/resolve) run against
`main`'s pre-merge code on every CI pass it gets, never its own. This was confirmed live on #180:
its own CI log printed `main`'s real SHA instead of the branch's own placeholder pin. The local
test suite plus a static review lens (`nah run codex`) are not a lesser substitute while this gap
exists — they are the only coverage this class of PR gets before merge.

**Operational constraints on the PR1-to-PR2 window.** `pr-review / AI Code Review` is a required
check on kure and launcher (deliberately not on `.github` itself — see
`governance/repository-settings-policy.yaml`'s comment for why), so whatever the placeholder does
for that window — resolves stale code, or fails to resolve at all in the bootstrap case — is live
on every PR to *both* consumer repos, not just this one. **PR2 must land as soon as possible after
PR1 merges; the window must not span a working day.** If it must stay open longer than that, or the
placeholder breaks review outright, and *only this pin window* needs to pause (not a genuine
org-wide incident — see `docs/pr-review-threads.md`, "Incident procedure" for that broader case),
set a **repository-level** override of `PR_REVIEW_THREADS_MODE=off` on **each affected caller**
(kure, launcher — both, since the placeholder is live on every PR to both the moment PR1 merges,
per the constraint above) rather than the org-level variable, which would silence review on every
repository in the org instead of just the ones this window actually touches. A repo-level override
set on `.github` itself is not meaningless — the reusable workflow resolves this variable against
the **caller's** repository (full mechanics: `docs/pr-review-threads.md`, "Incident procedure"),
and `.github` is itself a caller via its own `pr-review-caller.yml` — so such an override does
affect `.github`'s own PR reviews, it just has no effect on kure's or launcher's.
**After PR2 lands, a consumer PR whose required check already failed during the
window needs a fresh run to pick up the fix** — GitHub resolves a reusable-workflow `uses:` line
once per run and re-running only the failed job reuses that same stale resolution; re-run every
job (or push a new commit) rather than just the failed one.

Every later PR that touches the action's delegate code needs the same two-PR sequence as
the bootstrap, not a single PR: rebase-merge still rewrites the commit's SHA on landing, so
no SHA known while the PR is open can be the one that ends up on `main`. The first PR lands
the code changes and bumps the pin to **the branch's own base-ref tip SHA** (never all-zeros,
and never an arbitrary earlier real SHA — with an inline comment marking it as pending); the
second bumps it to the real merged SHA. Unlike the bootstrap, `check-pin-bump.sh` requires the
pin to visibly *move* on the first PR — the current pin at `main` is not itself a valid
placeholder value, since leaving it in place would fail that check (there is a prior pin to
compare against here, unlike the bootstrap's "no prior pin" exception); the base-ref tip always
satisfies this too, since `main` advances with every merge. Dependabot cannot open this PR
for you — it doesn't track same-repo paths as a dependency, so this stays a manual, two-PR
habit for every change to the delegate code.

**The base-ref tip is content-identical to the current pin only under a normal, non-interleaved
sequence** — one delegate-code change in flight at a time, each completing its own PR1/PR2 pair
before the next starts. `check-pin-bump.sh` compares pin *strings*, not trees, and only across
one PR's own base...head range: if a second delegate-code PR branches from `main` before an
earlier one's PR2 has landed, and picks that earlier PR1's merged-but-not-yet-repinned tip as
its own base-ref tip, the guarantee breaks — that tip carries code `check-pin-bump.sh` never
compared against the still-live placeholder pin, because the comparison it ran belonged to the
first PR, not the second. Keep same-repo delegate-code PRs serialized (one in flight at a time)
to preserve the guarantee; do not rely on it across overlapping PRs. The guarantee also covers
only the file-scoped delegate-code paths `check-pin-bump.sh` diffs — it says nothing about
`docs/standards.md` itself, which the action reads from its pinned checkout and injects into
its model prompts (`scripts/pr-review-threads.sh:255-260`, `scripts/lib/prt/model.sh:494,524`
inject it as `PROJECT STANDARDS:`). Once PR1 pins the base-ref tip, that pin — and everything the
action reads from it, including `docs/standards.md` — is fixed for the whole PR1-to-PR2 window;
the actual risk is *earlier*: an unrelated, docs-only commit landing between the previous real pin
and the moment PR1 selects its base-ref tip is invisible to the delegate-path guard, so the newly
selected tip's `docs/standards.md` content can silently differ from what the previous pin carried,
changing review behavior even though the delegate code stayed content-identical.

Serialization protects delegate-code *content*, not the *interface* between the action and its
caller: `.github/workflows/pr-review.yml`'s own call site is not pinned — consumers pull it live
from `main` via `@main` — so if PR1 changes the action's inputs/outputs
(`.github/actions/pr-review-threads/action.yml`) and updates
that call site in the same commit, the live call site and the still-pinned old action version go
out of sync for the whole PR1-to-PR2 window regardless of serialization — PR2 only re-points the
pin at PR1's already-merged SHA, it carries no code change of its own, so an interface change
introduced *in* PR2 would never actually ship. Instead: land the interface change on the action
side in PR1 (with the old interface still honored, so the still-pinned base-ref tip and the new
call site can coexist), and defer updating the call site to *use* the new interface until PR2,
once the pin points at a commit that actually has it.

### Pin-impact-ack (consumer-side gate on this repo's own pin)

The inverse direction from the rest of this section: kure and launcher each pin `go-kure/.github`
itself by SHA (same convention as any other action), and each runs its own `pin-impact` CI job —
defined in **that consumer's own `.github/workflows/ci.yml`, not centrally here** — that gates a
pin bump on what it actually touches. `scripts/check-pin-impact.sh` (lives in the consumer repo)
diffs the old and new SHA, and intersects the changed files with the paths that repo's own `uses:`
lines actually reference — "changed" and "consumed" are different sets; a file like
`standards/labels.md` routinely shows up changed but not consumed, since it's governance prose, not
something either repo's CI executes. A changed-and-consumed path (in practice, almost always
`scripts/check-doc-gate.sh`, the one script kure/launcher invoke directly rather than via a
composite action) fails the job and blocks merge until a human reviews the diff and adds the
`pin-impact-ack` label.

**Gotcha: acking via `gh run rerun` on a stale run silently fails.** The job's `strip-ack` step
removes `pin-impact-ack` on genuine new pushes, so an ack from a prior commit can't silently cover
a later, unreviewed diff — but its `if:` condition reads `github.event.action`, which is frozen at
whatever triggered that run *originally* (`synchronize` or `reopened`). Re-running an old failed
run replays that same frozen condition and strips a freshly-added ack again, before the gate step
re-checks it — even though nothing was actually pushed. The job then fails exactly as before, which
reads as "the ack didn't take." **It did — re-running the stale run undid it.** Add (or re-add) the
label and leave the resulting fresh `labeled`-triggered run alone instead; that event's `action` is
`labeled`, so `strip-ack`'s condition correctly skips it and the ack survives to the gate check.

**This gotcha, too, is scoped to same-repository PRs.** `strip-ack`'s `if:` also requires the PR's
head repository to equal the current repository, so it never runs at all on a fork PR — but that's
moot: the gate step separately forces `PIN_IMPACT_ACK=false` unconditionally for forks, regardless
of labels. A fork PR has no acknowledgment path at all.

### Vulnerability gating (govulncheck)

`scripts/govulncheck-gate.sh` turns a `govulncheck -format json` report into a CI verdict:

- **Exit 0** — no reachable advisory outside the allowlist.
- **Exit 1** — at least one unallowed *reachable* advisory (a trace frame names a
  function that is actually called — not merely a required-but-unused dependency).
- **Exit 2** — the report is missing, empty, or unparseable. This is a distinct,
  fail-**closed** outcome: an unparseable report is treated as an unknown verdict,
  never as "no findings". A crashed or truncated scan must not read as clean.

Consumer repos run it as a composite action, pinned the same way as
`check-action-pins` above:

    uses: go-kure/.github/.github/actions/govulncheck-gate@1793023365e5af6923e9bb6b424fcea1dca1279e # main

It takes inputs `report`, default `govulncheck.json`; `allowlist`, a space-separated list of
OSV IDs, default empty — do not vendor a copy. Every allowlist entry must carry a
written justification (the reachable path, and why no version bump clears it) in the
comment above it in the consuming workflow; an entry with no justification is a bug,
not a waiver.

This script is duplicated verbatim in the `meta` repo for the GitLab side, which
cannot read files from this repo (`include:` transports YAML only). Change both, or
they drift.

## Container Builds

Not applicable. kure is a library with no binary output. launcher ships binaries via GoReleaser,
not container images. `.github` is not an application.

## golangci-lint Configuration

| Aspect     | Workspace Default   | kure                | launcher        | .github |
|------------|-----------------|---------------------|-----------------|---------|
| Strictness | Full linter set | Relaxed (migration) | Full linter set | N/A     |

Linters currently disabled in kure pending migration:
- `exhaustive` — many switch statements need updating
- `errorlint` — error wrapping migration in progress

Target: enable all standard linters by Q2 2026.

## Repository Settings

Settings (labels, rulesets, branch protection, merge policy) for all go-kure repos are managed
centrally by this repo's `settings.yml` workflow, driven by `scripts/github-settings.sh`. The
source of truth is `governance/repository-settings-policy.yaml`; per-repo overrides (e.g. kure's
`has_discussions`, kure/launcher's merge-queue ruleset override) live under that file's
`github_repos` section. Each key below is checked bidirectionally against policy by
`scripts/check-settings-doc.sh` in CI — a key here with no policy match, or vice versa, fails the
build.

Four repositories are governed: `.github`, `kure`, `launcher` and `go-kure.github.io`.
The Pages content repository is governed for settings and labels but is deliberately
outside `main-protection`: its default branch is written directly by the `kure` and
`launcher` docs-deploy workflows and by its own sitemap job, and it runs none of the
status checks that ruleset requires.

Another organization can run `scripts/github-settings.sh` unchanged against its own files
("thin consumer"): check out this repository, then set `GITHUB_ORG`, `GITHUB_REPOS_DEFAULT`
(the consumer's full governed set — policy `repos:` scopes are validated against it),
`LABELS_FILE` and `POLICY_FILE` in the environment. `GITHUB_REPOS` still narrows a single
run. The script's `--help` lists all five variables. This repository's own `settings.yml`
sets none of them. A consumer's labels file never passes `check-label-docs.sh`, so the script
validates its shape itself before touching anything: a non-empty `labels` array whose entries
carry a name, a description and a `#RRGGBB` colour, no duplicate names, `repos:` scopes
naming only governed repos, and every governed repo left with at least one applicable label.
An empty file, or one scoped entirely away from a repo, is refused rather than read as "delete
every live label there". The policy gets the same treatment: `github_repos` keys must be
governed repos and the fields inside each override must exist in `github_defaults` (an
unknown field is never read and the default would be applied instead), and `security:` blocks
carry only the three keys under "Security" below, each `enabled` or `disabled`, because the
audit applies any other value as `disabled` — for `dependabot_security_updates` that is a live
DELETE, so a typo is refused up front rather than applied. These are targeted preflights for
the mistakes that mutate something, not a schema for the policy file; go-kure/.github#161
tracks closed-schema validation of every tier.

A ruleset normally has a `github_defaults.rulesets` entry (optionally scoped to specific repos
via `repos:`, per-repo fields overridden under `github_repos.<repo>.rulesets`). It can also be
declared **repo-only**, entirely under `github_repos.<repo>.rulesets` with no
`github_defaults` counterpart — the usual target for pasting an `./scripts/github-settings.sh
--import` dump of an unmanaged live ruleset that's intentionally repo-specific rather than an
org-wide default. A repo-only ruleset applies solely to the repo(s) that declare it.

### Top-level settings

| Setting                            | Default               |
|-------------------------------------|-----------------------|
| `allow_rebase_merge`                | `true`                |
| `allow_squash_merge`                | `false`               |
| `allow_merge_commit`                | `false`               |
| `delete_branch_on_merge`            | `true`                |
| `allow_update_branch`               | `true`                |
| `has_wiki`                          | `false`               |
| `allow_auto_merge`                  | `true` (org-wide; kure/launcher still land via the merge queue) |
| `has_projects`                      | `true`                |
| `has_issues`                        | `true`                |
| `has_discussions`                   | `false` (kure: `true`) |
| `has_downloads`                     | `false`               |
| `is_template`                       | `false`               |
| `allow_forking`                     | `true`                |
| `web_commit_signoff_required`       | `false`               |
| `merge_commit_title`                | `MERGE_MESSAGE` (inert while `allow_merge_commit` is `false`) |
| `merge_commit_message`              | `PR_TITLE` (inert while `allow_merge_commit` is `false`) |
| `squash_merge_commit_title`         | `COMMIT_OR_PR_TITLE`  |
| `squash_merge_commit_message`       | `COMMIT_MESSAGES`     |

### Security

| Setting                                      | Default    |
|-----------------------------------------------|-----------|
| `security.secret_scanning`                    | `enabled` |
| `security.secret_scanning_push_protection`     | `enabled` |
| `security.dependabot_security_updates`         | `enabled` (overridden to `disabled` on `.github`, `kure`, `launcher`) |

`dependabot_security_updates` stays `enabled` by default for `go-kure.github.io`, the org's one
remaining Dependabot repo (see [Dependency Management](#dependency-management)) — it has no
`renovate.json` and no other source of vulnerability alerts. The three repos that extend the
shared Renovate preset override it to `disabled`: Renovate's `vulnerabilityAlerts` lane
(`osvVulnerabilityAlerts` + `addLabels: ["security"]`) already covers them, proven duplicate by
go-kure/kure#742 (Dependabot) and go-kure/kure#743 (Renovate `[security]`) opening for the same
grpc bump within hours of each other.

### Rulesets (branch protection)

| Ruleset                                            | Enforcement | Scope             |
|-----------------------------------------------------|-------------|-------------------|
| `main-protection`                                    | `active`    | .github, kure, launcher |
| `Code Quality Copilot review for default branch`      | `disabled`  | kure, launcher only |

## Organization Settings

Organization-level settings (`orgs/go-kure`) are managed separately from the per-repo settings
above, and only when `scripts/github-settings.sh` is run with `--org` — every other invocation
(`--all`, a single repo, the daily `settings.yml` run) never touches these and never needs a token
with the `admin:org` scope. Source of truth is the `github_org:` block in
`governance/repository-settings-policy.yaml`, which has no per-repo override tier (an organization
has no per-repo variants). Each key below is checked bidirectionally against policy by
`scripts/check-settings-doc.sh` in CI, same as the repository tables above.

Four settings are audit-only: readable via `GET /orgs/{org}` but not writable via
`PATCH /orgs/{org}`, so `--org --apply` reports drift on them but never attempts to fix it — marked
below.

**Organization-level rulesets are not modeled.** `GET /orgs/go-kure/rulesets` returns HTTP 403
"Upgrade to GitHub Team to enable this feature" — a billing-tier limit, not a token scope. Nothing
in this script reads or writes them.

### Organization settings

| Setting                                                          | Default  |
|-------------------------------------------------------------------|----------|
| `default_repository_permission`                                   | `read`   |
| `members_can_create_repositories`                                  | `true`   |
| `members_can_create_public_repositories`                           | `true`   |
| `members_can_create_private_repositories`                          | `true`   |
| `members_can_create_internal_repositories`                         | `false`  |
| `members_can_fork_private_repositories`                            | `false`  |
| `members_can_delete_repositories`                                  | `true`   |
| `members_can_change_repo_visibility`                               | `true`   |
| `members_can_delete_issues`                                        | `false`  |
| `members_can_invite_outside_collaborators`                         | `true`   |
| `members_can_create_pages`                                         | `true`   |
| `members_can_create_public_pages`                                  | `true`   |
| `members_can_create_private_pages`                                 | `true`   |
| `members_can_create_teams`                                         | `true`   |
| `has_organization_projects`                                        | `true`   |
| `has_repository_projects`                                          | `true`   |
| `readers_can_create_discussions`                                   | `true`   |
| `members_can_view_dependency_insights`                             | `true`   |
| `display_commenter_full_name_setting_enabled`                      | `false`  |
| `deploy_keys_enabled_for_repositories`                             | `false`  |
| `web_commit_signoff_required`                                      | `false`  |
| `dependabot_alerts_enabled_for_new_repositories`                   | `false`  |
| `dependabot_security_updates_enabled_for_new_repositories`         | `false`  |
| `dependency_graph_enabled_for_new_repositories`                    | `false`  |
| `secret_scanning_enabled_for_new_repositories`                     | `false`  |
| `secret_scanning_push_protection_enabled_for_new_repositories`     | `false`  |
| `secret_scanning_push_protection_custom_link_enabled`              | `false`  |
| `secret_scanning_validity_checks_enabled`                          | `false`  |
| `two_factor_requirement_enabled` (audit-only)                      | `true`   |
| `advanced_security_enabled_for_new_repositories` (audit-only)      | `false`  |
| `default_repository_branch` (audit-only)                           | `main`   |
| `members_allowed_repository_creation_type` (audit-only, deprecated by GitHub) | `all` |

The eight `*_enabled_for_new_repositories` defaults are recorded as `false` above because that is
live reality today — a repo added to `GITHUB_REPOS` inherits repo-level policy regardless, but any
other new repo in the org starts with these off. Tightening them is a deliberate follow-up change,
not something the initial `github_org:` block did.

### Organization Actions permissions

| Setting                                | Default |
|-----------------------------------------|---------|
| `actions.enabled_repositories`           | `all`   |
| `actions.allowed_actions`                | `all`   |
| `actions.sha_pinning_required`           | `false` |
| `actions.default_workflow_permissions`   | `read`  |
| `actions.can_approve_pull_request_reviews` | `false` |

## PR CI Health

A second, independent job in `settings.yml` (`pr-ci-health`, `scripts/pr-ci-health.sh`) — separate
from the settings audit above, because settings drift and PR/CI health are different failure
classes and either one should be visible without needing the other to also be red. It runs on the
same daily schedule and `workflow_dispatch`, queries every repo in `GITHUB_REPOS` for open,
non-draft PRs via GraphQL, and fails (posting a table to the step summary) if any PR's combined
`statusCheckRollup` is `FAILURE` or `ERROR` — a red run here is meant to be the notification itself,
there is no separate alerting path. It only reads; it never comments, labels, or otherwise touches
a PR.

Two things it deliberately does not do, both because there is no verified mechanism to key on yet
rather than because they were judged unimportant:

- **No "on hold via the Dependency Dashboard" exclusion.** Renovate has no distinct, API-visible
  state for a PR it is deliberately holding back — such a PR simply doesn't exist as an open PR
  yet, so nothing here needs to special-case it. If Renovate-authored PRs turn out to be a real
  source of noise once this has run for a while, that is the evidence to design a targeted
  exclusion from, not a guess made up front.
- **No pagination.** Only the first 100 open PRs per repo are scanned; a repo that exceeds that gets
  a warning in the step summary rather than a silent truncation.

## Release Process

| Aspect       | kure                    | launcher                | .github |
|--------------|-------------------------|-------------------------|---------|
| Releases     | GitHub releases         | GitHub releases         | N/A     |
| Tool         | GoReleaser + git-cliff  | GoReleaser + git-cliff  | N/A     |
| Changelog    | `CHANGELOG.md` + cliff  | `CHANGELOG.md` + cliff  | N/A     |
| Version tags | `vX.Y.Z`                | `vX.Y.Z`                | N/A     |

See [`standards/release-process.md`](../standards/release-process.md) for the canonical
tag-driven release procedure that the repo-local `scripts/release.sh` cite.

## What Stays the Same

The following standards apply identically to kure and launcher (not applicable to `.github`):

- Agentic file structure (`.claude/CLAUDE.md`, `AGENTS.md`)
- `mise.toml` configuration (Go version, golangci-lint version)
- Go coding standards (error handling via `pkg/errors`, import grouping)
- Testing patterns (table-driven tests, race-detector enabled)
- Documentation structure (README per package, AGENTS.md, DEVELOPMENT.md)

`.github` follows only the agentic-file requirement.

## Documentation Sync (MUST)

Documentation MUST stay in sync with the code it describes, enforced in CI. This is
the go-kure canon of the shared documentation-sync standard.

1. **Same PR.** Any code change updates, in the same PR, every doc that describes
   it: the package `README.md`, affected guides, the docs site (`site/content` and
   generated mounts), and root docs (`docs/`).
2. **Removals repoint everything.** Removing or renaming a package or symbol
   removes or repoints every reference — reverse-mapping tables, mount scripts, site
   nav, cross-doc links. A 404 in the published site is a CI failure.
3. **Single normative source.** Each repo with a docs site declares its code↔docs
   mapping in one `docs-map.yaml`. The AGENTS.md reverse-mapping table, the site
   mount configuration, and the navigation are generated from or validated against
   it — never hand-maintained as the authority. The reference implementation and
   schema live in [`go-kure/kure`](https://github.com/go-kure/kure) at
   `site/docs-map.yaml` + `site/scripts/`.
4. **Links resolve.** All internal/intra-repo links MUST resolve in rendered output.
5. **API change touches its docs.** A change to a mapped package's source MUST touch
   its mapped `README.md`/guide(s) in the same PR, unless a maintainer applies the
   escape hatch. A narrower, code-level exemption also exists for a single line inside
   a machine-generated file — see the Enforcement table below.

### `docs-map.yaml` schema

```yaml
repo_type: go-library          # go-library | go-service | docs-only
docs_only: false               # true for docs/governance repos (no package coverage)
code_roots: [pkg]              # dirs scanned for public packages (omit when docs_only)
packages:                      # every public package appears exactly once
  - path: pkg/example
    readme: pkg/example/README.md
    guides: [guides/library-usage]
    mount: {target: api-reference/example.md, title: Example, weight: 70, group: Resource Operations, desc: One-liner}
  - path: pkg/internalish
    readme: pkg/internalish/README.md
    mounted: false
    reason: Why this is intentionally unpublished.
extra_mounts:
  - {source: docs/quickstart.md, target: getting-started/quickstart.md, title: Quickstart, weight: 10}
review_mappings:
  # Enforced by Layer 3 (check-doc-gate.sh): requires BOTH `change` (a repo-root-
  # relative glob) and `docs` (a list of repo-root-relative paths, not display text).
  # If any changed file matches `change`, at least one path in `docs` must also
  # change in the same PR.
  - change: "scripts/gen-versions-toml.sh"
    docs: [guides/dependency-updates.md]
  # Display-only row: `reference`/scalar `guides` (with no `docs` list) render in the
  # generated reverse-mapping table but are NOT enforced — Layer 3 skips any entry
  # missing the `change`+`docs` pair above. Use this for links a human should follow
  # up on but that don't map to one specific doc file.
  - {change: "`.github/workflows/`", reference: "—", guides: "`contributing/github-workflows`"}
```

### Enforcement

| Layer | What | Blocking |
|-------|------|----------|
| 1 — Links | Link-check the **rendered** site (build first, then check published output) | Yes (internal) |
| 2 — Structure | [`check-doc-sync.sh`](../scripts/check-doc-sync.sh) validates map ↔ filesystem ↔ generated tables | Yes |
| 3 — Change-gate | Mapped-package source change requires its mapped doc to change | Yes |
| 4 — Prose | Agent/human review that prose reflects code | No (advisory) |

Layers 1–3 guarantee links resolve, structure is consistent, and docs are touched;
they cannot verify prose accuracy (Layer 4). **Escape hatch (Layer 3):** a
maintainer-restricted `docs-skip` PR label, not a self-applied commit trailer.

**Generated-line exemption (Layer 3, narrower).** A line inside a file carrying Go's
standard `// Code generated ... DO NOT EDIT.` header
([go.dev/s/generatedcode](https://go.dev/s/generatedcode)) is exempt from the package
gate when every line a diff touches already existed, already marked
`// doc-gate:trivial`, in the base revision, **and** the edit changes only the
value, not the declaration itself — e.g. a version const whose value is
propagated automatically from an upstream pin with no human documentation decision
behind the change. A hunk that inserts a brand-new line has no old side to check and
is never exempt this way, however the new line is marked; the same is true of a
brand-new generated file, whose only hunk is always an insertion, and of a pure
deletion, which has no new side to check. Renaming or otherwise changing the
identity of an already-marked declaration is exempt from neither this nor either
of the insertion/deletion cases — a 1:1 line swap that changes what a marked
constant is called still carries a real documentation decision, even though the
old and new line counts match and both lines are marked. The marker is
trusted only inside a file carrying that header, and only for the lines a
diff actually touched. The header itself is a textual convention, not a verified
fact — a PR author can add it to hand-written source — so unlike the `docs-skip`
label this is not an unforgeable maintainer action; what it buys instead is that
faking it still costs one full doc-gate PR (the base-side check below rejects a
line's first marking, same as for a genuinely generated file), and the header's
appearance on a previously-ordinary file is a visible, diffable event a reviewer
can catch, not a silent one. See `trivial_change()` in
[`check-doc-gate.sh`](../scripts/check-doc-gate.sh) for the exact mechanics.

**Generated-row exemption (Layer 3, marker-free).** The marker form above assumes a
`const X = "value"` declaration and cannot apply to a Go struct-literal table row —
there is no top-level `=` to compare, so any value change fails the whole line even
when it is pure provenance churn (e.g. a Renovate version bump propagated into every
row's `ModuleVersion` field). For a file carrying the generated-code header, a 1:1
row replacement is exempt with no marker at all when every difference between the
old and new line is confined to a **declared provenance field** (`ModuleVersion` is
the only one today) and that field's value is a quoted string appearing exactly once
on the line. Anything else different on the line — a renamed `Kind`, a flipped
`Namespaced`, or any other field — fails the row, same as an unmarked line would; a
row add or remove still fails the hunk-size guard before this check ever runs; and a
file missing the generated-code header is never eligible, exactly as for the marker
form. This path is independent of the marker form — it is never a fallback that
loosens the marker check, only an alternative recognizer for a shape the marker
syntax cannot express. The match is anchored to a struct-literal key position
(immediately preceded by `{` or `,`), so a longer field name
(`MinimumModuleVersion`) can't be mistaken for the declared field, and it only
runs against the CODE portion of the line — everything before the line's first
`//` or `/*`, whichever comes first — so neither a full-line comment nor a
comment trailing real code on the same line can supply a fake match. This
recognizer is regex-based, not a Go parser: it doesn't track whether that
comment marker itself sits inside an open string literal (a false split there
only makes the check reject a row it should have accepted, never the reverse),
and it doesn't exclude a field-shaped string inside a string literal spanning
the whole match (e.g. a backtick raw string whose contents happen to read like
`{ModuleVersion: "..."}`), nor a multi-line `/* */` block comment wrapping a
row across two separate diff lines. No `PROVENANCE_FIELDS` entry is or has been
such a string in this org's generated tables; closing these residual gaps would
mean maintaining a second Go tokenizer for risks with no known instance, so
they are accepted rather than chased. See
`trivial_provenance_row()` in [`check-doc-gate.sh`](../scripts/check-doc-gate.sh)
for the exact mechanics, and `scripts/test/check-doc-gate-test.sh` for the fixture
coverage (both this path and regression coverage for the marker path).

`.github` (docs-only) runs only map validity, link checks, the agentic-file rule,
and the PR docs checkbox.

## No Downstream References (MUST)

go-kure repos are **upstream, open-source** projects. They MUST NOT name the **downstream,
closed-source** platform or its components in tracked source, docs, comments, tests, or
identifiers. Downstream consumers depend on go-kure; the reverse coupling must not leak.

**Forbidden terms** (case-insensitive, whole word):

- `crane`, `harbor`, `barge`, `rudder` — downstream platform components <!-- allow-term:crane allow-term:harbor allow-term:barge allow-term:rudder -->
- `wharf` / `wharf.zone` — the downstream platform and its label / DNS zone <!-- allow-term:wharf -->

**What to do with an existing reference:**

- **Incidental mention** (e.g. "so crane can validate") → reword to a generic role such as <!-- allow-term:crane -->
  "a downstream consumer" or "the downstream platform runtime".
- **Whole downstream-specific section** (a mapping, migration guide, or ownership table that
  documents the *downstream's* behaviour) → move it to the downstream repo; keep only the
  upstream contract, described abstractly.
- **Functional identifier** (an annotation key, label, registry host, or constant carrying a
  downstream name) → rename to the repo's own namespace (e.g. `launcher.gokure.dev/…`) and
  coordinate a lockstep change with any downstream repo that shares the literal.

**Escape hatch:** a term that is legitimate for an unrelated reason (e.g. the
`go-containerregistry` tool literally named `crane`, or this standard defining the term list) <!-- allow-term:crane -->
carries an `allow-term:<word>` pragma on the same line or an immediately adjacent line.

### Enforcement

The check is [`scripts/check-forbidden-terms.sh`](../scripts/check-forbidden-terms.sh), run in CI via
the shared [`check-forbidden-terms`](../.github/actions/check-forbidden-terms) composite action (a
vendored copy of the script may also exist for non-CI tooling such as release scripts):

| Mode | When | Blocking |
|------|------|----------|
| `--full-tree` | `pull_request` / `push` / `schedule` / `merge_group` — fails on any un-pragma'd hit | Yes |

**Scan parity (MUST):** CI MUST run the guard with `--full-tree` on **every** event, so a pull request
and the merge queue see identical results. A diff-scoped (`--diff`) check MUST NOT gate CI — it passes
a PR on pre-existing hits that the merge queue's `--full-tree` scan then rejects, diverging the two.
`--diff` remains a local/dev convenience only.

Scope, by path prefix: `docs/`, `site/content/`, `pkg/**`, `cmd/**`, `scripts/**`,
`.github/workflows/**`, `.github/actions/**`. Plus, by extension anywhere in the tree:
`**/*.md` and **every tracked `**/*.{json,yml,yaml,toml}`**. The guard script excludes itself.

The extension arm matters more than it looks. The scope used to be a path allowlist alone, and
`renovate/shared.json` — a root-level config file naming the downstream platform in six places —
matched none of its prefixes. The `forbidden-terms` job therefore ran, reported OK, and never
opened it, six times, in a public repository (go-kure/.github#79, fixed in #82). Matching by
extension means a new config file is in scope the moment it is added, rather than the next time
someone remembers to extend a prefix list.

The step-by-step remediation runbook — usable for a first sweep of any upstream repo — is in
[`docs/no-downstream-references.md`](no-downstream-references.md).

## Project Management

Planning runs on labels alone — see [`standards/labels.md`](../standards/labels.md). GitHub
Projects roadmaps were tried and retired 2026-08-27; the boards themselves are scheduled for
deletion after their field values are migrated to labels (see
[project board standard](project-board-standard.md) for status).

- [Project board standard](project-board-standard.md) — retired; kept as a dated status record

## Proposing Changes

To change go-kure-specific standards:

1. Open an issue in the affected repo (or here if it's an org-wide change)
2. Document the rationale and which repos are affected
3. Update this file and `governance/repository-settings-policy.yaml` as needed after agreement
