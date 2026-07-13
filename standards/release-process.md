# Release Process Standard

Canonical release process for `go-kure/*` repositories (`kure`, `launcher`). This is the
reference the repo-local `scripts/release.sh` and `scripts/release-trigger.sh` cite.

## Model

Releases are **tag-driven** and changelog-first:

- A single `VERSION` file at the repo root holds the current version (`vX.Y.Z` or a
  pre-release such as `vX.Y.Z-alpha.N`).
- [`git-cliff`](https://git-cliff.org/) generates `CHANGELOG.md` from Conventional Commit
  messages (`feat:`, `fix:`, `chore:`, …), configured by `cliff.toml`.
- Pushing a `vX.Y.Z` tag triggers the release workflow, which runs
  [GoReleaser](https://goreleaser.com/) to build binaries and publish a GitHub release.

## Release types

| Type | Effect |
|------|--------|
| `alpha` / `beta` / `rc` | Cut or advance a pre-release on the current line |
| `stable` | Promote the current pre-release to a final `vX.Y.Z` |
| `bump <minor\|major\|prerelease>` | Start a new version line |

`auto` (default) infers the next step from the `VERSION` file.

## Scripts

- **`scripts/release.sh <type>`** — the automation: computes the next version, regenerates
  the changelog, creates the release commit and tag. `DRY_RUN=1` previews without writing.
  In CI (`CI` set) it also configures the bot git identity and pushes.
- **`scripts/release-trigger.sh`** — the human entry point: shows a dry-run preview and, with
  `--do-it`, triggers the release via CI. `promote` and `bump` subcommands mirror the types
  above.

Both are typically invoked through `mise run release …`.

## CI, tags, and identity

- The release workflow runs tests, validates the tag and changelog, runs GoReleaser, then
  performs post-release steps (e.g. module-proxy refresh).
- Version tags are `vX.Y.Z`. Pre-releases use `-alpha.N` / `-beta.N` / `-rc.N` suffixes.
- Release commits are pushed by the **`kure-release-bot`** GitHub App, which is the authorized
  branch-protection bypass actor for release commits. Repo automation must reuse this identity
  rather than minting a new one (a new actor needs governance + app authorization).

## Divergence from the workspace default

GitLab workspace repos drive releases through shared CI templates; go-kure repos are released
independently on GitHub with the scripts above. See [`docs/standards.md`](../docs/standards.md)
§ Release Process for the per-repo matrix.
