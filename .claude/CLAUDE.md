# Claude Instructions for go-kure .github

## Primary Reference

**Read `AGENTS.md` first** - it contains comprehensive instructions for working with this
repository, including:
- Repository structure
- How to work with org settings, design docs, and community files
- Workflow guidelines

## Context Files

When working on this repo, load these files for context:
- `AGENTS.md` - Agent instructions and development guide
- `governance/repository-settings-policy.yaml` - Settings policy
- `docs/standards.md` - go-kure org standards (incl. the mandatory documentation-sync standard)

## Documentation Sync

- Code and documentation changes must be in the same PR (mandatory, CI-enforced; org canon is `docs/standards.md` → "Documentation Sync", which this repo hosts along with the canonical `scripts/check-doc-sync.sh`)

## Quick Commands

```bash
# Audit org settings (all repos, CI mode)
./scripts/github-settings.sh --all --ci --json

# Audit a specific repo
./scripts/github-settings.sh kure

# Apply settings (dry run — preview only)
./scripts/github-settings.sh --all

# Apply settings for real
./scripts/github-settings.sh --all --apply
```

## Commits

Follow conventional commits:
- `feat:` - New features or docs
- `fix:` - Bug fixes
- `chore:` - Maintenance
- `ci:` - Workflow changes
- `docs:` - Documentation

## Git Workflow

`main` is protected — always create a feature branch before making changes:

```bash
git checkout -b <type>/<description> main
# make changes, commit
git push -u origin <type>/<description>
gh pr create
```

Required checks: `lint`, `test`, `build`, `rebase-check`. See `AGENTS.md` § Git Workflow for full
details.
