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
- **`scripts/release-state.sh`** (in `go-kure/.github`, not the release repos) — read-only:
  reports what a tag's publish run actually did. See the next section.

Both are typically invoked through `mise run release …`.

## Determining what a release actually did

When a tag's publish run goes wrong, the first question is always the same: did it publish,
partly publish, or never publish — and what is the safe recovery? Answering that by reading
the run page is unreliable, because six separate facts have to be held at once and each one
is a route to a confidently wrong conclusion. **`scripts/release-state.sh` answers it
instead**, and lives in `go-kure/.github` alongside the shared publish workflow:

```bash
scripts/release-state.sh go-kure/kure v0.2.0-beta.11
scripts/release-state.sh --state-only go-kure/launcher v0.1.0-alpha.21
```

It prints the evidence it used, a recommended action, and exactly one of:

| State | Meaning |
|-------|---------|
| `published` | the publishing job concluded success and the release object exists |
| `partial` | the release exists, but the publishing job did not succeed on its most recent attempt |
| `never-published` | no release object and no successful publishing job |
| `contradictory` | a release object exists that no recorded attempt produced |
| `no-run-found` | no workflow run for this tag at all |

Exit status is `0` when a state was determined and `1` when it was not. **A failed API call
yields no state** — it reports `undetermined` and exits `1`, because "never published" and
"the API did not answer" are different claims, and a recovery path that collapses them
re-publishes a release that may already exist.

Three things the script does that reading the run page by hand does not:

- **It queries every attempt, not the latest.** `gh run view --json jobs` reports only the
  most recent attempt, which is frequently not the attempt that published. A re-run that
  fails early shows `goreleaser: skipped` while an earlier attempt's release stands.
- **It never uses the asset count as an oracle.** How many assets a complete release carries
  is decided by that tag's own `.goreleaser.yml`; for a library repo the correct count is
  zero. The count is reported as evidence and is not an input to the verdict.
- **It distinguishes a carried-forward job row from one that ran.** A re-run copies
  non-rerun jobs forward unchanged, so an attempt's job list mixes attempts, and the
  conclusions are identical either way — only the timestamps separate them.

The recovery advice always names the **full** `gh run rerun <id>` and warns against
`--failed` or single-job re-runs, which pin the reusable workflow to the first attempt's
commit and so silently skip any fix merged to it since.

Every one of those behaviours is pinned by a case in `scripts/test/release-state-test.sh`,
which stubs `gh` and needs no token and no network. A new fact about how GitHub reports
release runs belongs there as a failing test, not as a new paragraph in a runbook.

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
