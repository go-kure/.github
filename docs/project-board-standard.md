# Project Board Standard

This document defines the field model, views, and label policy for GitHub Projects roadmaps across all go-kure repositories.

The launcher roadmap (go-kure/projects/4) is the reference implementation. The kure roadmap (go-kure/projects/1) follows the same model.

---

## Field Model

| Field | Type | Required | Notes |
|---|---|---|---|
| Status | single-select (built-in) | Yes | Todo · In Progress · In Review · Done · Blocked |
| Stream | single-select (custom) | Yes | Values are repo-specific — see below |
| Milestone | built-in (GitHub) | Yes | Now · Next · Later — planning bucket |
| Priority | single-select (custom) | Optional | Repos may use the Priority field OR priority::* labels — not both |

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
| go-kure/kure | Priority custom field (P1-Critical through P5-Deferred) — canonical. Do not apply priority::* labels to new issues. |
| go-kure/launcher | priority::* labels — no Priority field currently |

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

`area/*` and `status::*` issue labels are **deprecated** in favour of project fields.

| Replaced by | Labels |
|---|---|
| Stream project field | `area/cli`, `area/core`, `area/docs`, `area/flux`, `area/helm`, `area/k8s`, `area/layout` |
| Project Status field | `status::blocked`, `status::needs-review`, `status::in-progress` |
| Milestone = Later | `status::deferred` |

**Policy for deprecated labels:**

- Do **not** apply `area/*` or `status::*` to new or open issues.
- Do **not** delete the labels — they are kept for historical compatibility on closed issues.
- When triaging a new issue, set Stream and Status on the project item instead.

`effort::*` and `type/*` labels remain active and valid for new issues.
