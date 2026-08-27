# go-kure .github Agent Instructions

This document provides guidance for agents working on this repository.

## Project Overview

This is the `go-kure/.github` repository — the org-level governance hub for the go-kure GitHub
organization. It provides:

- **Org settings management**: Repository rules, labels, and merge policies for all go-kure repos
- **Reusable workflows**: Shared CI/CD workflows consumed by kure and launcher
- **Community files**: CONTRIBUTING, CODE_OF_CONDUCT, SECURITY, PR template (org-wide defaults)
- **Design documents**: Architecture and design decisions for the go-kure org
- **Standards reference**: How go-kure repos are configured and why

**Documentation sync is mandatory** across all go-kure repos — code and
documentation change in the same PR. This repo hosts the canon
([`docs/standards.md`](docs/standards.md) → "Documentation Sync") and the canonical
`scripts/check-doc-sync.sh`. As a docs-only repo, keep `docs/standards.md`, the
labels reference, and design docs in sync when you change them.

## Local Development

`mise tasks` lists every local check, test, and script wrapper (lint, doc-sync, action-pins,
settings audit/apply, ...); `mise run <task>` runs one, `mise run verify` runs everything CI runs.

## Repository Structure

```
.github/
├── governance/
│   └── repository-settings-policy.yaml  # Machine-readable settings policy
├── standards/
│   ├── labels.json                      # Standard issue labels
│   ├── labels.md                        # Label naming conventions
│   └── release-process.md               # Release process reference
├── scripts/
│   ├── github-settings.sh               # Settings audit/apply script
│   ├── check-doc-sync.sh                # Doc-sync Layer 2 (structure) — canonical
│   ├── check-doc-gate.sh                # Doc-sync Layer 3 (change-gate) — canonical
│   ├── check-links.sh                   # Doc-sync Layer 1 (link check) — canonical
│   ├── check-forbidden-terms.sh         # No Downstream References guard — canonical
│   ├── check-workflow-refs.sh           # Guards AGENTS.md/standards.md against dead workflow refs
│   ├── exact-array-member.sh            # Shared helper used by the check-*.sh scripts
│   ├── migrate-kure-labels.sh           # One-off label migration script
│   ├── pr-review-fail-closed-digest.sh  # Org-wide digest of fail-closed pr-review-threads runs
│   └── lib/api.sh                       # Shared HTTP API utilities
├── .github/
│   ├── workflows/                       # GitHub Actions — self-CI, org settings, and the
│   │                                     # reusable/caller workflows; see "Available reusable
│   │                                     # workflows" below for the full list, don't duplicate it here
│   └── actions/                         # Composite actions — see "Composite Actions" below
├── ISSUE_TEMPLATE/
│   ├── bug.yml
│   └── feature.yml
├── profile/
│   └── README.md                        # Org overview page
├── docs/
│   ├── standards.md                     # go-kure org standards (canonical)
│   └── design/                          # Design documents
│       ├── README.md                    # Index
│       ├── oci-layout.md
│       ├── api-stability.md
│       ├── package-structure.md
│       └── oam-runtime.md
├── docs-map.yaml                        # This repo's own doc-sync map (repo_type: docs-only)
├── CODE_OF_CONDUCT.md                   # Org-wide default
├── CONTRIBUTING.md                      # Org-wide default
├── SECURITY.md                          # Org-wide default
└── PULL_REQUEST_TEMPLATE.md             # Org-wide default
```

## Working with Repository Settings

Settings are defined in `governance/repository-settings-policy.yaml` and applied via
`scripts/github-settings.sh`. The script governs: top-level repo settings (merge methods,
wiki/issues/discussions/projects toggles, commit-title/message formats — see `SETTING_KEYS`
in the script), the `secret_scanning` / `secret_scanning_push_protection` /
`dependabot_security_updates` security trio, labels (`standards/labels.json`), and branch
rulesets (rule types are a registry in the script — `RULE_TYPE_ORDER`/`RULE_KIND` — not a
hardcoded list; adding a new rule type means adding a registry entry). See `docs/standards.md`
§ "Repository Settings" for the full governed key list, and that same script's plan file
history for what's deliberately still out of scope (environments, webhooks, Actions
permissions, collaborators, ...).

### Auditing settings

```bash
# Audit all repos (CI mode, JSON output)
./scripts/github-settings.sh --all --ci --json

# Audit a specific repo
./scripts/github-settings.sh kure --ci
```

Or via mise, which forwards every argument after `--` (`mise run settings -- --all --ci --json`).

The `settings.yml` workflow runs this automatically in audit mode on push to main (when
`governance/` or `standards/` files change) and daily at 06:00 UTC.

### Applying settings changes

1. Edit `governance/repository-settings-policy.yaml`
2. Run `./scripts/github-settings.sh --all` locally to preview changes (or `mise run settings -- --all`)
3. Commit and open a PR
4. After merge, trigger `settings.yml` manually via `workflow_dispatch` with `mode: apply`
   (`repo` defaults to `all`)

### Finding drift from live settings (`--import`)

```bash
# Print only what a repo's live settings/rulesets diverge from policy, as
# policy-shaped YAML ready to paste under github_defaults or github_repos.<repo>
./scripts/github-settings.sh kure --import

# Same, for every repo — read-only, never writes governance/*.yaml itself
./scripts/github-settings.sh --all --import
```

`--import` covers repo settings, the security trio, and rulesets only — it never touches
labels, since those are governed by `standards/labels.json`, not
`governance/repository-settings-policy.yaml`. Label drift is reported by audit mode (running
the script without `--import`) instead.

A repo with nothing to fold in prints
`# <repo>: settings/security/rulesets match policy — nothing to import`. A live
ruleset rule type the script doesn't model yet (not in the `RULE_KIND` registry) is omitted
from the printed YAML and flagged with an `unmapped_rule_types` warning on stderr instead of
being silently dropped. A policy-applicable ruleset that no longer exists on the repo (deleted
on GitHub) is flagged with a `# WARNING: policy ruleset(s) expected ... not found live
(deleted?)` comment instead of reading as a clean match; if the live-rulesets fetch itself
fails (permissions, rate limit, transient error), that check is skipped rather than reporting
every applicable ruleset as deleted, and a `could not fetch live rulesets` warning is printed
instead.

A ruleset can also be declared **repo-only**, under `github_repos.<repo>.rulesets` with no
matching `github_defaults.rulesets` entry — the normal target for pasting an `--import` dump of
an unmanaged live ruleset that shouldn't become an org-wide default. It applies only to the
repo(s) that declare it.

### Environment variables

`GITHUB_ORG` (default `go-kure`) and `GITHUB_REPOS` (default `.github kure launcher
go-kure.github.io`, space-separated) override which org/repos every mode above targets —
useful for testing against a fork or a subset of repos. `--all --apply` mutates every
repo in this list, including `go-kure.github.io`.

### Adding or changing labels

Edit `standards/labels.json`. See `standards/labels.md` for naming conventions and the category reference before adding new labels. The settings script syncs labels to all repos automatically.

## Working with Organization Settings

Distinct from repository settings above: this governs `orgs/go-kure` itself (member
privileges, new-repo security defaults, org-wide Actions permissions) via a `github_org:`
block in the same `governance/repository-settings-policy.yaml`, with no per-repo override
tier. Reached only through `--org` — every other invocation of
`scripts/github-settings.sh` (`--all`, a single repo, the daily `settings` job in
`settings.yml`) never touches this and never needs the scope below.

**Prerequisite**: `--org` requires a token with the `admin:org` scope
(`gh auth refresh -h github.com -s admin:org` locally; `secrets.SETTINGS_PAT` for the
`settings-org` job in `settings.yml`, unverified as of when this was added — check
https://github.com/settings/tokens and rotate if it doesn't have it). Without the scope,
`--org` fails fast with a named error instead of a bare 403.

```bash
# Audit organization-level settings
./scripts/github-settings.sh --org --ci

# Apply organization-level settings
./scripts/github-settings.sh --org --apply

# Print live org settings that drift from policy, as paste-ready github_org: YAML
./scripts/github-settings.sh --org --import
```

Or via mise: `mise run settings -- --org --ci` / `--org --apply` / `--org --import`.

Some fields are readable but not writable via `PATCH /orgs/{org}` (`ORG_READONLY_KEYS` in
the script — e.g. `two_factor_requirement_enabled`, set via the org/enterprise UI).
`--org --apply` audits them normally but reports `BLOCKED` instead of attempting a PATCH
that would error.

**Organization-level rulesets are not modeled.** `GET /orgs/go-kure/rulesets` returns HTTP
403 "Upgrade to GitHub Team to enable this feature" — a billing-tier limit, not a token
scope. If the org ever upgrades, the existing rule registry
(`RULE_TYPE_ORDER`/`RULE_KIND`) and `ruleset_diff` engine that already drive repo-level
rulesets are the natural starting point — org rulesets use the identical `rules` array
vocabulary, they'd just need a new endpoint and `repository_name`/`repository_property`
condition support.

## Working with Design Docs

Design docs live in `docs/design/`. Each doc tracks its own version and changelog inline.

### Adding a new design doc

1. Create `docs/design/<topic>.md` using this format:

```markdown
# [Title]

> **Version** 1.0 · **Updated** YYYY-MM-DD

## Changelog

| Version | Date | Summary |
|---------|------|---------|
| 1.0 | YYYY-MM-DD | Initial document |

---

[content]
```

2. Add a row to `docs/design/README.md`

### Updating an existing doc

1. Make the change
2. Bump the version number (patch for corrections, minor for new content)
3. Add a row to the changelog table
4. Update the version in `docs/design/README.md`

## Working with Community Files

`CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, and `PULL_REQUEST_TEMPLATE.md` are
**org-wide defaults** — GitHub applies them to any go-kure repo that does not have its own copy.

Changes here propagate to all repos automatically. Review carefully.

## Working with Reusable Workflows

Reusable workflows have `on: workflow_call` in their trigger. Caller workflows (ending in
`-caller.yml`) are the thin wrappers that live in each consumer repo and delegate to these.

### Available reusable workflows (`on: workflow_call`)

| Workflow | Consumer trigger | Purpose | Key inputs | Secrets needed |
|----------|-----------------|---------|------------|----------------|
| `auto-rebase.yml` | push to `main` (via `auto-rebase-caller.yml`) | Rebases all open PRs when main is updated | — | `AUTO_REBASE_PAT` |
| `claude.yml` | PR/issue/comment events (via `claude-caller.yml`) | @claude AI assistant on PRs and issues | — | `CLAUDE_CODE_OAUTH_TOKEN` |
| `pr-review.yml` | PR open/sync/reopen, drafts included (via `pr-review-caller.yml`; `ready_for_review` dropped once the rollout window closed — see `docs/pr-review-threads.md` § Draft PRs) | 2-pass AI code review via the `pr-review-threads` composite action; one resolvable, merge-gating PR review thread per finding (deduped by fingerprint, auto-resolved when fixed or judged a false positive). `pr-review.yml`'s own default `PR_REVIEW_THREADS_MODE` is now `enforce` (go-kure/.github#108), matching the org variable's live value since 2026-08-18. `pr-review / AI Code Review` is a required status check on kure/launcher only, deliberately excluded from `.github` — see `governance/repository-settings-policy.yaml` and `docs/standards.md` § Interim outage window | `pr_review_context` (string, optional) | `KURE_BOT_PAT` (optional — falls back to `github.token`, which can create but never resolve its own threads; see "Token and bot identity" in `docs/pr-review-threads.md`) |
| `release-create.yml` | `workflow_dispatch` | Pre-flight CI gate + git-cliff tag creation | `type` (required), `scope`, `dry_run` | `KURE_BOT_APP_ID`, `KURE_BOT_APP_PRIVATE_KEY` |
| `release-bump.yml` | `workflow_dispatch` | Bump `versions.env`/changelog without tagging a release | `scope` (required), `dry_run` | `KURE_BOT_APP_ID`, `KURE_BOT_APP_PRIVATE_KEY` |
| `release-promote.yml` | `workflow_dispatch` | Promote a prerelease (beta → rc → stable) | `to` (required: `beta`\|`rc`\|`stable`), `dry_run` | `KURE_BOT_APP_ID`, `KURE_BOT_APP_PRIVATE_KEY` |
| `release-publish.yml` | version tags (`v*`), via `release-publish.yml` caller | GoReleaser, SBOM, docs deploy, Go proxy refresh | `go_module` (required, e.g. `github.com/go-kure/kure`) | none (uses `secrets.GITHUB_TOKEN`) |

Consumer repos call these as:
```yaml
uses: go-kure/.github/.github/workflows/<name>.yml@main
secrets: inherit
```

`ci.yml`, `settings.yml` and `pr-review-digest.yml` are **not** reusable — `ci.yml` is this repo's
own self-CI (`pull_request` + `workflow_dispatch`), `settings.yml` is this repo's own org-settings
audit/apply job (push to `governance/`/`standards/` + daily schedule + `workflow_dispatch`, see
above), and `pr-review-digest.yml` is this repo's own daily org-wide scan for fail-closed
`pr-review-threads` events (schedule + `workflow_dispatch`; see
`docs/pr-review-threads.md` § Fail-closed alerting). None of the three is consumed by
kure/launcher.

### When updating a reusable workflow

- Changes take effect for **all consumer repos immediately** after merge to `main`
- Test by triggering the corresponding `-caller.yml` workflow manually before merging (or, for the
  release workflows, by running the workflow itself via `workflow_dispatch` with `dry_run: true`)
- `release-create.yml`, `release-bump.yml` and `release-promote.yml` all accept `dry_run: true` for
  a preview run. `release-publish.yml` has no `dry_run` input — it triggers on the version tag
  itself, so test changes to it via a caller repo's tag on a fork or a scratch tag first.

## Composite Actions

Step-level shared logic lives in `.github/actions/<name>/action.yml` (distinct from reusable
workflows, which are job-level). Consumer repos reference one as a step:
```yaml
- uses: go-kure/.github/.github/actions/<name>@main
```

| Action | Purpose |
|--------|---------|
| `check-forbidden-terms` | No Downstream References guard. Runs the canonical `scripts/check-forbidden-terms.sh --full-tree` against the caller's checked-out tree. Drop it into a CI job on **every** event so a pull request and the merge queue produce identical results (scan parity — see `docs/standards.md`). |
| `check-doc-sync` | Documentation-sync Layer 2 (structure). Runs `scripts/check-doc-sync.sh` against the caller's `docs-map.yaml`. Requires `yq` on `PATH` — install it in the consumer's job before this step. |
| `check-doc-gate` | Documentation-sync Layer 3 (change-gate). Runs `scripts/check-doc-gate.sh` with `base-ref`/`root`/`skip` inputs. Requires `yq` on `PATH`. |
| `check-links` | Documentation-sync Layer 1 (link check). Runs `scripts/check-links.sh` against a `built-dir` the caller has already rendered (e.g. a Hugo build). Requires `lychee` on `PATH`. |
| `pr-review-threads` | Runs `scripts/pr-review-threads.sh`: 2-pass AI review + assessment, then reconciles findings into resolvable PR review threads (create/reply/resolve/unresolve via the GraphQL API), deduped by fingerprint and auto-resolved on fix or false-positive verdict. Used only by `pr-review.yml` in this repo — a same-repo action, so it is pinned by SHA like any other (see `docs/standards.md`, "Same-repo composite actions and the pin-bump procedure"), not referenced with a relative `./` path. |

## Git Workflow

- **`main` is protected** — never commit directly to `main`
- Always create a feature branch from `main`:
  ```bash
  git checkout -b <type>/<description> main
  ```
- **Branch prefixes**: `feat/`, `fix/`, `docs/`, `chore/`, `ci:`
- **Conventional commits**: `feat:`, `fix:`, `docs:`, `chore:`, `ci:`, `build:`
- **Linear history** enforced — rebase only, no merge commits
- **Required CI**: `lint`, `test`, `build`, `rebase-check`
- Use `gh pr create` to open pull requests

## Agent gates (A1–A7)

Process rules for AI agents (Claude Code, Codex, and any other). They constrain *how* work is
done and are independent of any particular tool, harness or machine — everything below is
checkable from a clone of this repository.

| Gate | Rule |
|---|---|
| **A1** | Every factual claim in a plan or review carries a `file:line` actually read this session; anything uncitable goes in an explicit `ASSUMPTIONS` list. Recompute every number from source. Never cite your own uncommitted change as evidence of existing convention — check the base branch. |
| **A2** | Destructive operations require a *proven* dry-run, not an asserted one: print the exact command, then show the dry-run ran and what it output. A tool *accepting* `--dry-run` is not proof it honoured it. If it cannot be proven, say so and stop. Applies to `github-settings.sh --apply` and any org-settings mutation. |
| **A3** | "Stop" / "wait" means make no further edits and no further tool calls. One-line acknowledgement only. |
| **A4** | No merge-ready claim without per-item evidence. For this repo: `mise run verify` (everything CI runs — lint, checks, tests, forbidden-terms, links), plus code-and-docs in the same PR per `docs/standards.md`. |
| **A5** | Re-read your own diff for the recurring defect classes: a composite action's pin bumped without the drift-check ref that must move with it (both must reference the same commit — a stale drift-check ref reddens every consuming repo's CI independently of any single PR), `docs-map.yaml` left stale after a doc moves, and a settings-policy change applied without first previewing the drift (`github-settings.sh` dry-run output actually read, not just accepted). |
| **A6** | Any time you touch a changeset with an open PR, check for new comments or reviews since you last looked, before calling a round done. Enumerate every review thread, not just the top-level review list — a forge can carry several independent reviews over time, and an inline thread carries separate resolved/unresolved state from the review it belongs to. Per comment: push a fix commit, or state why not — silence is not a response. Mark the thread resolved once addressed. |
| **A7** | No bare internal identifier (gate ID, plan step, finding, round, run ID) in a plan, review, or comment without a short subject on first use. Every issue/PR reference is the full project path plus its sigil (`owner/repo#123`), never a bare number — except inside a comment posted on that same forge project, where the surrounding page already supplies the repo. **In this repo**, per the No Downstream References standard (`docs/standards.md`), a reference to any of the forbidden downstream repo names is never qualified even to resolve ambiguity — the qualified form is still a forbidden term. Reword to a generic functional reason and drop the number instead. |

## Questions?

Refer to:
1. `docs/standards.md` — go-kure org standards reference
2. `governance/repository-settings-policy.yaml` — machine-readable settings policy
3. `CONTRIBUTING.md` — contribution guidelines
