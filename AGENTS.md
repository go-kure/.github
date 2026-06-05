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

## Repository Structure

```
.github/
├── governance/
│   └── repository-settings-policy.yaml  # Machine-readable settings policy
├── standards/
│   ├── labels.json                      # Standard issue labels
│   └── labels.md                        # Label naming conventions
├── scripts/
│   ├── github-settings.sh               # Settings audit/apply script
│   └── lib/api.sh                       # Shared HTTP API utilities
├── .github/
│   └── workflows/                       # GitHub Actions (CI + reusable)
│       ├── ci.yml                       # Self-CI: lint, test, build
│       ├── release.yml                  # Reusable: GoReleaser release
│       ├── release-create.yml           # Reusable: create release tag
│       ├── auto-rebase.yml              # Reusable: rebase open PRs
│       ├── auto-rebase-caller.yml       # Calls auto-rebase on main push
│       ├── pr-review.yml                # Reusable: AI code review
│       ├── pr-review-caller.yml         # Calls pr-review on PR events
│       ├── claude.yml                   # Reusable: @claude assistant
│       ├── claude-caller.yml            # Calls claude on PR/issue mentions
│       ├── audit-settings.yml           # Scheduled: audit org settings
│       └── apply-settings.yml           # Manual: apply org settings
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
├── CODE_OF_CONDUCT.md                   # Org-wide default
├── CONTRIBUTING.md                      # Org-wide default
├── SECURITY.md                          # Org-wide default
└── PULL_REQUEST_TEMPLATE.md             # Org-wide default
```

## Working with Org Settings

Settings are defined in `governance/repository-settings-policy.yaml` and applied via
`scripts/github-settings.sh`.

### Auditing settings

```bash
# Audit all repos (CI mode, JSON output)
./scripts/github-settings.sh --all --ci --json

# Audit a specific repo
./scripts/github-settings.sh kure --ci
```

The `audit-settings.yml` workflow runs this automatically on push to main (when `governance/` or
`standards/` files change) and weekly on Mondays.

### Applying settings changes

1. Edit `governance/repository-settings-policy.yaml`
2. Run `./scripts/github-settings.sh --all` locally to preview changes
3. Commit and open a PR
4. After merge, trigger `apply-settings.yml` manually with `dry_run: false`

### Adding or changing labels

Edit `standards/labels.json`. See `standards/labels.md` for naming conventions and the category reference before adding new labels. The settings script syncs labels to all repos automatically.

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

### Available reusable workflows

| Workflow | Consumer trigger | Purpose | Key inputs | Secrets needed |
|----------|-----------------|---------|------------|----------------|
| `auto-rebase.yml` | push to `main` | Rebases all open PRs when main is updated | — | `AUTO_REBASE_PAT` |
| `claude.yml` | PR/issue/comment events | @claude AI assistant on PRs and issues | — | `CLAUDE_CODE_OAUTH_TOKEN` |
| `pr-review.yml` | PR open/sync/ready | 2-pass AI code review; posts advisory comment | `pr_review_context` (string, optional) | none (uses cluster sidecar) |
| `release-create.yml` | `workflow_dispatch` | Pre-flight CI gate + git-cliff tag creation | `type` (required), `scope`, `dry_run` | `RELEASE_APP_ID`, `RELEASE_APP_PRIVATE_KEY` |
| `release.yml` | version tags (`v*`) | GoReleaser, SBOM, docs deploy, Go proxy refresh | `go_module` (required, e.g. `github.com/go-kure/kure`) | `RELEASE_APP_ID`, `RELEASE_APP_PRIVATE_KEY` |

Consumer repos call these as:
```yaml
uses: go-kure/.github/.github/workflows/<name>.yml@main
secrets: inherit
```

### When updating a reusable workflow

- Changes take effect for **all consumer repos immediately** after merge to `main`
- Test by triggering the corresponding `-caller.yml` workflow manually before merging
- For `release.yml` or `release-create.yml`, test with `dry_run: true` first

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

## Questions?

Refer to:
1. `docs/standards.md` — go-kure org standards reference
2. `governance/repository-settings-policy.yaml` — machine-readable settings policy
3. `CONTRIBUTING.md` — contribution guidelines
