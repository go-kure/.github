# go-kure Org Standards

This is the canonical standards reference for all `go-kure/*` repositories. It describes how
go-kure repos are configured and where they diverge from the wharf workspace defaults.

## Why go-kure is Different

The go-kure repos are:

1. **Public open-source projects** — must accommodate external contributors
2. **Hosted on GitHub** — use GitHub Actions and Dependabot (not GitLab CI and Renovate)
3. **Released independently** — separate cadence from the Wharf platform

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
| Dependency updates  | Modified | Modified | Modified | Dependabot (GitHub native), not Renovate |
| Repository settings | Modified | Modified | Modified | Applied by this repo's `apply-settings.yml` workflow |

## CI Platform

| Aspect           | Wharf Default        | kure                        | launcher                    | .github                     |
|------------------|----------------------|-----------------------------|-----------------------------|-----------------------------|
| Platform         | GitLab CI            | GitHub Actions              | GitHub Actions              | GitHub Actions              |
| Config file      | `.gitlab-ci.yml`     | `.github/workflows/*.yml`   | `.github/workflows/*.yml`   | `.github/workflows/*.yml`   |
| Shared workflows | `meta/ci-templates/` | Callers to `go-kure/.github`| Callers to `go-kure/.github`| Hosts the shared workflows  |

kure and launcher stay thin — each repo has only caller workflows that delegate to the reusable
workflows here.

## Dependency Management

| Aspect | Wharf Default  | kure                     | launcher                 | .github            |
|--------|----------------|--------------------------|--------------------------|--------------------|
| Tool   | Renovate       | Dependabot               | Dependabot               | Dependabot         |
| Config | `renovate.json`| `.github/dependabot.yml` | `.github/dependabot.yml` | N/A (no Go deps)   |

## Container Builds

Not applicable. kure is a library with no binary output. launcher ships binaries via GoReleaser,
not container images. `.github` is not an application.

## golangci-lint Configuration

| Aspect     | Wharf Default   | kure                | launcher        | .github |
|------------|-----------------|---------------------|-----------------|---------|
| Strictness | Full linter set | Relaxed (migration) | Full linter set | N/A     |

Linters currently disabled in kure pending migration:
- `exhaustive` — many switch statements need updating
- `errorlint` — error wrapping migration in progress

Target: enable all standard linters by Q2 2026.

## Repository Settings

Settings (labels, rulesets, branch protection, merge policy) for all go-kure repos are managed
centrally by this repo's `apply-settings.yml` workflow. The source of truth is
`governance/repository-settings-policy.yaml`.

| Setting           | All go-kure repos |
|-------------------|-------------------|
| Merge method      | Rebase only       |
| Branch protection | GitHub rulesets   |
| Auto-merge        | Disabled          |
| Wiki              | Disabled          |

## Release Process

| Aspect       | kure                    | launcher                | .github |
|--------------|-------------------------|-------------------------|---------|
| Releases     | GitHub releases         | GitHub releases         | N/A     |
| Tool         | GoReleaser + git-cliff  | GoReleaser + git-cliff  | N/A     |
| Changelog    | `CHANGELOG.md` + cliff  | `CHANGELOG.md` + cliff  | N/A     |
| Version tags | `vX.Y.Z`                | `vX.Y.Z`                | N/A     |

## What Stays the Same

The following standards apply identically to kure and launcher (not applicable to `.github`):

- Agentic file structure (`.claude/CLAUDE.md`, `AGENTS.md`)
- `mise.toml` configuration (Go version, golangci-lint version)
- Go coding standards (error handling via `pkg/errors`, import grouping)
- Testing patterns (table-driven tests, race-detector enabled)
- Documentation structure (README per package, AGENTS.md, DEVELOPMENT.md)

`.github` follows only the agentic-file requirement.

## Project Management

GitHub Projects roadmaps across all go-kure repos follow a shared field model and view set.

- [Project board standard](project-board-standard.md) — field model, views, and label policy for GitHub Projects roadmaps

## Proposing Changes

To change go-kure-specific standards:

1. Open an issue in the affected repo (or here if it's an org-wide change)
2. Document the rationale and which repos are affected
3. Update this file and `governance/repository-settings-policy.yaml` as needed after agreement
