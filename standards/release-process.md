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

The first two are typically invoked through `mise run release …`. `release-state.sh` is not:
it lives in `go-kure/.github` rather than in the release repos, and is run directly from a
checkout of that repository.

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
| `published` | the publishing job concluded success in **some** attempt, and the release object exists |
| `partial` | the release exists and the publishing job **ran**, but never concluded success in any attempt — it failed or was cancelled, so the release may be incomplete |
| `never-published` | no release object and no successful publishing job |
| `contradictory` | the run record and the release object disagree, in **either** direction: a release exists that the job never ran to produce, or the job succeeded and the release is gone |
| `no-run-found` | no workflow run for this tag at all **and no release object** |

**`published` deliberately keys on "some attempt", not "the most recent attempt".** A re-run that
fails in `test` skips the publishing job while the earlier attempt's release still stands, so
keying on the latest attempt would report a shipped release as unpublished and invite a re-publish.
That is the same conflation the whole script exists to prevent, so `partial` means *never
succeeded*, not *most recently failed*.

Both directions of `contradictory` print their own recommended action, because the operator's next
move differs: a release that nothing produced must not be deleted, while a success whose release
object has vanished must not be re-run. The state word stays the same so a caller's `case` needs
only the five branches.

**An empty run record is `no-run-found` only when there is no release to contradict.** Runs age
out, so a tag published long enough ago reaches "a release exists and the run record holds no run
at all" with nothing wrong — and that is the first direction of `contradictory`, reached by a
shorter route, not an absence of information. Reporting `no-run-found` there would send the
operator to check whether the tag was pushed, which is the wrong question for a release that
demonstrably exists, and would drop the do-not-delete warning.

Exit status is `0` when a state was determined and `1` when it was not. **A failed API call
yields no state** — it reports `undetermined` and exits `1`, because "never published" and
"the API did not answer" are different claims, and a recovery path that collapses them
re-publishes a release that may already exist.

**A publish that is still running also yields no state**, and reports `undetermined` for the same
reason: every state in the table is a statement about a *finished* publish. This one is called out
separately because it is the case where acting on a wrong answer does the most damage — two of the
five states recommend a re-run, and the one moment a re-run must not happen is while the job is
still going. The evidence block names the run and attempt that is in flight, and the advice says to
wait rather than to re-run.

This outranks an earlier success, and that is the one place where "a success in some attempt wins"
does not apply. A success settles what the *past* attempts did; a job running now is about the
future, and GoReleaser re-uploads to the same release object — so an attempt in flight can still
turn a complete release into an incomplete one. The evidence block records the earlier success
explicitly, so the answer is "wait", never "the release is missing".

**A hole in the run record yields no state either, but only when nothing else showed a success.**
A `404` on the *release object* is a fact about publishing; a `404` on a run, an attempt or an
attempt's job list is not — the record was deleted or aged out, and what it contained is exactly
what the negative states claim was never there. So a gap plus no observed success reports
`undetermined`; a gap alongside a success observed elsewhere still reports `published`, because a
missing record cannot un-see a success that was read. The evidence block names each part that
could not be read.

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
