# Issue Label Conventions

This document defines the label taxonomy and naming conventions for all go-kure repositories. The canonical label list is in [`labels.json`](labels.json).

> **Deprecated labels**: `area/*` is kept for historical compatibility on existing closed issues. **Do not apply it to new or open issues.** Use the Stream project field instead (see [project-board-standard.md](../docs/project-board-standard.md)).

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
| `area/` **(deprecated)** | `cli`, `core`, `docs`, `flux`, `helm`, `k8s`, `layout` | Replaced by the Stream project field. Kept for historical compatibility on closed issues only. |
| `upstream/` | `kure` | Blocked on an upstream repo |
| `scope/` | `launcher`, `downstream` | Whether the change reaches a surface an external consumer already imports |

**Special labels** (no category prefix): `dependencies`, `github_actions`, `go` — used by Dependabot and GitHub automation.

**Process labels** (no category prefix): `docs-skip` — maintainer-only PR label that bypasses the documentation-sync CI gate (see the Documentation Sync standard in [`../docs/standards.md`](../docs/standards.md)). Not for self-application.

**Repo-scoped labels.** A label in `labels.json` may carry an optional `repos` array
(e.g. `docs-skip` → `["launcher"]`). The settings audit then requires that label only on
the listed repos, and flags it as extra if it appears on any other repo. Labels without a
`repos` field apply to every repo.

**Renovate labels** (no category prefix): `needs-human`, `unattended` — applied by the
shared Renovate preset ([`renovate/shared.json`](../renovate/shared.json)) to flag whether an
update needs human review or is eligible for automerge. Scoped to `["kure", "launcher"]`,
the two repos that extend the shared preset — do not add them without `repos` scoping, since
`.github` and `go-kure.github.io` carry no `renovate.json`.

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
