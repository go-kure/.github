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
| Repository settings | Modified | Modified | Modified | Applied by this repo's `settings.yml` workflow |

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
centrally by this repo's `settings.yml` workflow. The source of truth is
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

## Project Management

GitHub Projects roadmaps across all go-kure repos follow a shared field model and view set.

- [Project board standard](project-board-standard.md) — field model, views, and label policy for GitHub Projects roadmaps

## Proposing Changes

To change go-kure-specific standards:

1. Open an issue in the affected repo (or here if it's an org-wide change)
2. Document the rationale and which repos are affected
3. Update this file and `governance/repository-settings-policy.yaml` as needed after agreement
