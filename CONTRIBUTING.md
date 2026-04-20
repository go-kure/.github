# Contributing to go-kure

Thank you for your interest in contributing.

## Prerequisites

- Go 1.26+
- [mise](https://mise.jdx.dev) — tool version manager
- [gh CLI](https://cli.github.com) — GitHub operations

```bash
mise install
```

## Branch Naming

Use these prefixes: `feat/`, `fix/`, `docs/`, `chore/`

```bash
git checkout -b feat/my-feature main
```

## Commit Style

Follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` — new feature
- `fix:` — bug fix
- `docs:` — documentation only
- `chore:` — maintenance
- `build:` — build system changes
- `test:` — test additions or changes
- `ci:` — CI/CD changes

## Pull Request Requirements

- Rebase on `main` before opening a PR (no merge commits — linear history is enforced)
- CI must be green: `lint`, `test`, `build`, `rebase-check`
- All review conversations must be resolved before merge
- 0 approving reviews required, but feedback should be addressed

## Linear History

Rebase only — merge commits are rejected by branch protection. Use:

```bash
git pull --rebase
git rebase main
```

## Opening Issues

Please open an issue before submitting a PR for significant changes. Use the issue templates:
- **Bug Report** — for something that isn't working
- **Feature Request** — for new features or enhancements
