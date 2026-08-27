# Project Board Standard — Status

Defined 2026-05-24 (`1753afe`) as the field model, views, and label policy for GitHub Projects
roadmaps across go-kure repositories. Retired 2026-08-27 — see `standards/labels.md` for the
superseding authority. Kept as a plain status record rather than deleted: it recorded a real
decision, and the record of why it didn't work is still useful. Last updated 2026-08-27.

## Why retired

The field model below was never adopted. As of 2026-08-27: `go-kure/projects/4` (Launcher
Roadmap) held 44 open items — 34 carried only the auto-add default `Status=Todo`, 10 carried a
`Stream` value, none carried `Priority`. `go-kure/projects/1` (Kure Roadmap) held 247 items, only
3 open. Milestones were equally half-used: 15 of 44 open launcher issues and 3 of 4 open kure
issues carried `Now`/`Next`/`Later`. `area/*`, which this standard marked deprecated in favour of
the Stream field, stayed in active use instead — 32 of 44 open launcher issues carried an
`area/*` label. Practice never followed the standard; the standard is what changed.

The four Projects v2 boards this document governed — `1` Kure Roadmap, `2` Documentation
Versioning, `3` OAM Runtime, `4` Launcher Roadmap — are scheduled for deletion after this change
merges, once their field values are migrated to labels (a one-way forge operation, run only on
explicit go-ahead — not part of this change). `area/*` is un-deprecated and restored as an open
per-repo namespace (`standards/labels.md`); planning runs on labels alone as of this change,
regardless of when the boards themselves are actually deleted.

---

*The original standard follows, as written, for historical reference.*

This document defines the field model, views, and label policy for GitHub Projects roadmaps across all go-kure repositories.

The launcher roadmap (go-kure/projects/4) is the reference implementation. The kure roadmap (go-kure/projects/1) follows the same model.

---

## Field Model

| Field | Type | Required | Notes |
|---|---|---|---|
| Status | single-select (built-in) | Yes | Todo · In Progress · In Review · Done · Blocked |
| Stream | single-select (custom) | Yes | Values are repo-specific — see below |
| Milestone | built-in (GitHub) | Yes | Now · Next · Later — planning bucket |
| Priority | single-select (custom) | Optional | Repos may use the Priority field OR priority/* labels — not both |

### Milestone values

| Value | Meaning |
|---|---|
| Now | Active — in progress or immediately up next |
| Next | Planned — queued after Now work completes |
| Later | Deferred — future or low-priority, not yet scheduled |

Every open issue must have exactly one of Now / Next / Later set as its GitHub milestone.

### Stream values (per-repo)

| Repo | Stream values |
|---|---|
| go-kure/launcher | OAM · CLI · Distribution · Architecture |
| go-kure/kure | Core · Kubernetes · FluxCD · CLI |

### Priority (per-repo)

| Repo | Mechanism |
|---|---|
| go-kure/kure | Priority custom field (P1-Critical through P5-Deferred) — canonical. Do not apply priority/* labels to new issues. |
| go-kure/launcher | priority/* labels — no Priority field currently |

---

## Standard Views

Each roadmap should have the following views:

| View | Filter / grouping |
|---|---|
| Roadmap | Open items, grouped by Stream |
| \<Repo-name\> | Stream = \<primary-stream\>, open |
| Design | label = type/design, open |
| Now | Milestone = Now |
| Next | Milestone = Next |
| Cross-repo blockers | Status = Blocked |
| Untriaged | no Stream OR no Milestone, open |

---

## Auto-add Workflow

Configure the project's "Auto-add to project" workflow with:

```
is:issue is:open repo:<org>/<repo>
```

This ensures new issues appear on the board automatically without manual triage.

---

## Label Policy

`area/*` issue labels are **deprecated** in favour of the Stream project field.

| Replaced by | Labels |
|---|---|
| Stream project field | `area/cli`, `area/core`, `area/docs`, `area/flux`, `area/helm`, `area/k8s`, `area/layout` |

**Policy for deprecated labels:**

- Do **not** apply `area/*` to new or open issues.
- Do **not** delete the labels — they are kept for historical compatibility on closed issues.
- When triaging a new issue: set the GitHub milestone (Now / Next / Later), then set Stream on the project item.

`status/*` was previously listed here as deprecated in favour of the Status project field and the
Later milestone, but that replacement was never actually adopted in practice — see
go-kure/.github#119's investigation into dormant project boards. `status/*`, `priority/*`,
`effort/*` and `type/*` labels remain active and valid for new issues (go-kure/.github#121).
