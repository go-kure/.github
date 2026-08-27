# go-kure Org Standards

This is the canonical standards reference for all `go-kure/*` repositories. It describes how
go-kure repos are configured and where they diverge from the workspace defaults.

## Why go-kure is Different

The go-kure repos are:

1. **Public open-source projects** — must accommodate external contributors
2. **Hosted on GitHub** — use GitHub Actions, not GitLab CI. Dependency updates are Renovate
   in `kure` and `launcher` (via the shared preset hosted here); only this repo is on
   Dependabot, and only for `github-actions`. See [Dependency Management](#dependency-management).
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
| Dependency updates  | Same | Same | Modified | Renovate (shared preset hosted here); `.github` itself stays on Dependabot |
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
| Tool   | Renovate       | Renovate                 | Renovate                 | Dependabot         |
| Config | `renovate.json`| `renovate.json`          | `renovate.json`          | `.github/dependabot.yml` (github-actions only — no Go deps) |

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

`.github` itself stays on Dependabot: it has no Go code and no `renovate.json`, and
the Renovate runner skips repos without one.

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
cannot bump it — it is maintained by hand:

    uses: go-kure/.github/.github/actions/check-action-pins@1793023365e5af6923e9bb6b424fcea1dca1279e # main

Enabling `sha_pinning_required` covers actions from this organization too — a
`go-kure/.github/.github/actions/x@main` reference is rejected at runtime just
like a third-party one. Reusable workflows (`go-kure/.github/.github/workflows/
x.yml@main`) are exempt by GitHub's own rule and deliberately stay on `main`;
`scripts/check-action-pins.sh` draws the same line.

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

1. **PR1** lands the action and its delegate scripts, with the workflow pinned to a
   40-hex placeholder SHA (all zeros is fine) and an inline comment marking it as a
   placeholder pending PR2. `check-pin-bump.sh` treats "no prior pin on the base ref"
   as the documented bootstrap exception and passes trivially — there is nothing to
   compare the bump against yet.
2. After PR1 merges, **PR2** replaces the placeholder with the real, now-final SHA of
   the merged commit on `main`.

**Interim outage window, disclosed rather than discovered:** the moment PR1 merges to
`main`, every consumer that calls the wrapping reusable workflow at `@main` (e.g.
`kure`/`launcher`'s `pr-review.yml`) picks up the new code immediately — including the
placeholder SHA. Until PR2 lands, the composite-action step fails to resolve for every
PR in those consumers, and the job it's part of now fails outright (`pr-review.yml` fails
closed as of Phase 2 Task 5 — `continue-on-error: true` was removed once the failure
surface was hardened).

**As of go-kure/.github#108, `pr-review / AI Code Review` IS a required status check on
kure and launcher** (`governance/repository-settings-policy.yaml`'s kure `&queue_protection`
anchor, aliased by launcher) — so this window now blocks every PR on both of them until PR2
lands; land PR2 immediately after PR1 merges, do not let the window span a working day.
`.github` itself is deliberately excluded from this required check for exactly this reason:
`.github` is where the bootstrap/pin-bump PRs themselves land, and PR2 — the PR that fixes
the placeholder pin — would otherwise have to pass its own now-required check under normal
enforcement while that check is still broken by the placeholder it exists to fix. The
`PR_REVIEW_THREADS_MODE=off` escape hatch below could unblock a single stuck PR2 the same
way it covers any other incident, but routing every ordinary pin-bump PR through an incident
toggle isn't a workable default — excluding the required check is the actual fix, `off` stays
the fallback for a genuine outage. kure/launcher have no equivalent problem: their fix always
lands in a different repo (`.github`) than the one enforcing the check, so the requirement
there gates a genuinely independent signal, not the fix's own PR.

**`PR_REVIEW_THREADS_MODE=off` now covers this window too — with one open caveat.** The
mode is checked twice: inside the script (as before), and, since a live review finding on
`.github#56`, in the `pr-review` job's own `if:` (`.github/workflows/pr-review.yml`) —
`vars.PR_REVIEW_THREADS_MODE != 'off'` skips checkout, Setup tools, AND the composite
action step entirely when set, so an unresolvable action SHA is never reached. Historical
note, from *before* this job-level check existed: kure#669 hit exactly this ("Unable to
resolve action `go-kure/.github@0000...0`", confirmed live 2026-08-18) while a bootstrap
pin-bump PR was open-but-unmerged — at that time `off` genuinely could not have helped.
**V2 resolved (2026-08-18):** `vars.PR_REVIEW_THREADS_MODE` inside the called reusable
workflow resolves against the **caller's** repository (kure/launcher), not this one —
GitHub docs: "For reusable workflows, the variables from the caller workflow's repository
are used. Variables from the repository that contains the called workflow are not made
available to the caller workflow."
(docs.github.com/en/actions/reference/workflows-and-actions/variables). Practical consequence: today
`PR_REVIEW_THREADS_MODE` is an **org**-level variable, visible identically everywhere, so
this doesn't change anything in the common case — but during an incident, a **repo-level**
override must be set on the affected consumer (kure or launcher), not on `.github`; setting
it only here has no effect on their jobs. See `docs/pr-review-threads-live-findings.md` for
the full V2-V7 record, still land PR2 immediately as backup rather than relying on `off`
alone to hold the window open indefinitely.

Every later PR that touches the action's delegate code needs the same two-PR sequence as
the bootstrap, not a single PR: rebase-merge still rewrites the commit's SHA on landing, so
no SHA known while the PR is open can be the one that ends up on `main`. The first PR lands the code changes and bumps the pin to a new 40-hex placeholder SHA
(distinct from the prior real pin, with an inline comment marking it as pending); the
second bumps it to the real merged SHA. Unlike the bootstrap, `check-pin-bump.sh` requires
the pin to visibly *move* on the first PR (there is a prior pin to compare against here,
unlike the bootstrap's "no prior pin" exception) — leaving the previous pin in place would
fail that check, so the placeholder step is mandatory, not optional. Dependabot cannot open this PR for you — it doesn't track same-repo paths as
a dependency, so this stays a manual, two-PR habit for every change to the delegate code.

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
| `security.dependabot_security_updates`         | `enabled` |

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
   escape hatch.

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
