# Issue Label Conventions

This document defines the label taxonomy and naming conventions for all go-kure repositories. The canonical label list is in [`labels.json`](labels.json).

No label category is deprecated as of 2026-08-27. `area/*`'s deprecation (superseded by GitHub
Projects v2 Stream fields) and the `::` separator convention (superseded by `/`, single-select by
convention only) were both retired the same day — see [project-board-standard.md](../docs/project-board-standard.md)
and go-kure/.github#121.

## Naming Convention

Every label follows `category/value` — one separator, applied uniformly.

**All labels are multi-select** — an issue can have `type/epic` AND `area/helm` AND
`upstream/kure` simultaneously. GitHub has no built-in per-category exclusivity, on this repo or
any other: applying two `priority/*` labels to one issue is never rejected. `status/`, `priority/`
and `effort/` are single-value **by convention only** — pick at most one per category because it
keeps triage meaningful, not because anything enforces it. (This repo previously used a second
separator, `category::value`, to signal that convention. It never carried any enforcement either,
so it bought nothing `/` doesn't already give — dropped 2026-08-27, see go-kure/.github#121.)

## Category Reference

| Category | Values | Meaning |
|----------|--------|---------|
| `status/` | `deferred`, `blocked`, `needs-review`, `in-progress` | Current triage state — single-value by convention |
| `priority/` | `critical`, `high`, `medium`, `low` | Relative urgency — single-value by convention; valid for repos that use labels instead of a Priority project field (see [project board standard](../docs/project-board-standard.md)) |
| `effort/` | `low`, `medium`, `high` | Implementation complexity — single-value by convention |
| `type/` | `bug`, `chore`, `ci`, `design`, `documentation`, `epic`, `feature`, `refactor`, `roadmap`, `security`, `testing`, `upgrade`, `breaking-change` | What kind of issue it is |
| `area/` | `cli`, `core`, `docs`, `flux`, `helm`, `k8s`, `layout`, `oam`, `distribution` | Subsystem or component the issue touches |
| `upstream/` | `kure` | Blocked on an upstream repo |
| `scope/` | `launcher`, `downstream` | Whether the change reaches a surface an external consumer already imports |

**`area/` is an open per-repo namespace.** Unlike the other categories above, a repo may create
a new `area/<component>` label directly to unblock triage, without landing a change here first —
the set of subsystems a repo has is repo-specific and grows over time. The obligation: **back-fill
the new label into both `labels.json` and this row's value list, in the same unit of work that
introduces it.** `labels.json` alone is not enough — `scripts/check-label-docs.sh` compares the
`area/` row above against `labels.json` in both directions and fails CI if a value is in one but
not the other. A label that exists only on a live repo and never in this file is exactly the
undeclared-label state `scripts/github-settings.sh`'s settings audit reports as `EXTRA` — the
tooling has no way to tell "deliberately repo-specific" apart from a typo except by what this file
records. The audit also compares a name-matched label's live color and description against this
file and reports drift (`WRONG` on audit, `UPDATING` on `--apply`) — editing an `area/` label's
description here reaches every repo that already has the label, not just new creations. Colour is fixed for the whole namespace at `#5319E7` (see `area/oam` above), so the
author never chooses one. A value used by only one repo (as `area/oam` and `area/distribution`
currently are) should carry a `repos` scope in `labels.json` — see "Repo-scoped labels" below —
so the settings audit doesn't require it org-wide.

**Special labels** (no category prefix): `dependencies`, `github_actions`, `go` — used by Dependabot and GitHub automation.

**Process labels** (no category prefix): `docs-skip` `#FBCA04` — maintainer-only PR label that bypasses the documentation-sync CI gate (see the Documentation Sync standard in [`../docs/standards.md`](../docs/standards.md)). Not for self-application. The colour is deliberately **not** the `area/` namespace purple it carried until 2026-08-28: a process label that repaints itself as a subsystem is unreadable in a label list, and the audit now rewrites live colour, so a wrong value here reaches every repo.

**Repo-scoped labels.** A label in `labels.json` may carry an optional `repos` array
(e.g. `docs-skip` → `["launcher"]`). The settings audit then requires that label only on
the listed repos, and flags it as extra if it appears on any other repo. Labels without a
`repos` field apply to every repo.

**Renovate labels** (no category prefix): `needs-human`, `unattended` — applied by the
shared Renovate preset ([`renovate/shared.json`](../renovate/shared.json)) to flag whether an
update needs human review or is eligible for automerge. Scoped to
`["kure", "launcher", ".github"]`, the repos that extend the shared preset (`.github` extends
its own copy of the preset it hosts) — do not add them without `repos` scoping, since
`go-kure.github.io` still carries no `renovate.json` and the daily settings audit would flag
the labels as extra on it — deleted only if a maintainer later dispatches settings in `apply`
mode (audit alone never deletes; see `scripts/github-settings.sh`'s label-reconciliation step).

### `type/roadmap` vs `type/epic`

- `type/roadmap` — program-level master tracking issue spanning multiple phases or repos (gold `#D4AF37`)
- `type/epic` — phase or milestone group issue within a roadmap (blue `#0052CC`)

An issue can have both if it serves both roles, but a tracking issue that is purely tactical should use only `type/epic`.

### `scope/launcher` vs `scope/downstream`

`scope/downstream` applies when the change reaches a surface an external consumer *already*
imports — a library's public engine API, a builtin/handler that consumer registers directly, or a
type name it has reserved or shadowed. A brand-new surface nobody has claimed yet is
`scope/launcher`, even if a consumer will eventually adopt it.

Not enumerated: a single issue can be `scope/launcher` (it is this repo's own decision to make)
and `scope/downstream` (a consumer's registration or behavior depends on the outcome) at once.

## Adding New Labels

Before adding a label to `labels.json`:

1. **Check existing labels** — can an existing label express the same thing?
2. **Choose or create the right `category/` namespace** — does an existing namespace fit, or does this need a new one?
3. **Follow color conventions** — match existing labels in the same category for visual grouping
4. **If in doubt, relabel issues** — it is better to relabel issues to use existing labels than to expand the standard for a one-off

Changes to `labels.json` take effect across all repos only after the `settings.yml` workflow is triggered manually with `mode=apply`.
