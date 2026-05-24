# Issue Label Conventions

This document defines the label taxonomy and naming conventions for all go-kure repositories. The canonical label list is in [`labels.json`](labels.json).

> **Deprecated labels**: `area/*` and `status::*` are kept for historical compatibility on existing closed issues. **Do not apply them to new or open issues.** Use the Stream and Status project fields instead (see [project-board-standard.md](../docs/project-board-standard.md)).

## Naming Convention

Two separator styles are used, depending on label semantics:

| Separator | Style | Semantics | Example |
|-----------|-------|-----------|---------|
| `/` | `category/value` | **Categorical** — multiple labels from different categories can stack on one issue | `type/epic`, `area/helm` |
| `::` | `category::value` | **Enumerated** — at most one label per category on any issue | `priority::high`, `status::in-progress` |

**`/` labels are multi-select** — an issue can have `type/epic` AND `area/helm` AND `upstream/kure` simultaneously.

**`::` labels are single-select** — at most one label per category. Applying a second `priority::` label is a mistake. Note: `status::` and `priority::` are deprecated for new issues in repos that use project fields — see the deprecation note above.

## Category Reference

### Enumerated (`::`) — pick one per category

| Category | Values | Meaning |
|----------|--------|---------|
| `status::` **(deprecated)** | `deferred`, `blocked`, `needs-review`, `in-progress` | Replaced by project Status field (`status::blocked` → Status=Blocked; `status::deferred` → Milestone=Later). Kept for historical compatibility on closed issues only. |
| `priority::` | `critical`, `high`, `medium`, `low` | Relative urgency — valid for repos that use labels instead of a Priority project field (see [project board standard](../docs/project-board-standard.md)) |
| `effort::` | `low`, `medium`, `high` | Implementation complexity |

### Categorical (`/`) — apply as many as apply

| Category | Values | Meaning |
|----------|--------|---------|
| `type/` | `bug`, `chore`, `ci`, `design`, `documentation`, `epic`, `feature`, `refactor`, `roadmap`, `security`, `testing`, `upgrade`, `breaking-change` | What kind of issue it is |
| `area/` **(deprecated)** | `cli`, `core`, `docs`, `flux`, `helm`, `k8s`, `layout` | Replaced by the Stream project field. Kept for historical compatibility on closed issues only. |
| `upstream/` | `kure` | Blocked on an upstream repo |

**Special labels** (no category prefix): `dependencies`, `github_actions`, `go` — used by Dependabot and GitHub automation.

### `type/roadmap` vs `type/epic`

- `type/roadmap` — program-level master tracking issue spanning multiple phases or repos (gold `#D4AF37`)
- `type/epic` — phase or milestone group issue within a roadmap (blue `#0052CC`)

An issue can have both if it serves both roles, but a tracking issue that is purely tactical should use only `type/epic`.

## Adding New Labels

Before adding a label to `labels.json`:

1. **Check existing labels** — can an existing label express the same thing?
2. **Choose the right separator** — is this categorical (multiple can apply → `/`) or enumerated (only one per category → `::`)?
3. **Follow color conventions** — match existing labels in the same category for visual grouping
4. **If in doubt, relabel issues** — it is better to relabel issues to use existing labels than to expand the standard for a one-off

Changes to `labels.json` take effect across all repos only after the `settings.yml` workflow is triggered manually with `mode=apply`.
