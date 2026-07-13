# Runbook: Remove Downstream References from an Upstream Repo

A reusable procedure for sweeping a go-kure (upstream, open-source) repository free of
references to the downstream, closed-source platform, and keeping it that way. The rule and
term list are in [`standards.md`](standards.md) § No Downstream References.

Applies to any upstream repo — `launcher`, `kure`, or a new one. Run it once per repo, then
rely on the CI guard for regressions.

## 1. Sweep

Run the guard in full-tree mode (it reports `file:line` for every hit), or grep directly:

```bash
# From the repo root — same scope the guard uses:
bash scripts/check-forbidden-terms.sh --full-tree
# or, ad hoc (allow-term:wharf allow-term:crane allow-term:barge allow-term:harbor allow-term:rudder):
rg -niE '\b(wharf|crane|barge|harbor|rudder)\b' \
   docs/ site/content/ pkg/ cmd/ scripts/ .github/workflows/ ./**/*.md
```

## 2. Classify each hit

- **Incidental mention** — prose that names a downstream tool where a role would do.
- **Whole downstream section** — a mapping / migration guide / ownership table describing the
  downstream's behaviour, which belongs in the downstream repo.
- **Functional identifier** — an annotation key, label, registry host, or Go constant whose
  string embeds a downstream name (a runtime contract, not just prose).

## 3. Act

| Class | Action |
|-------|--------|
| Incidental | Reword to a generic role ("a downstream consumer", "the downstream runtime"). |
| Whole section | Move the content to the downstream repo (separate MR); leave only the abstract upstream contract. |
| Functional identifier | Rename to the repo's own namespace; **coordinate a lockstep change** with any downstream repo that hard-codes the same literal (see below). |

Legitimate, unrelated uses (e.g. go-containerregistry's `crane`) get an adjacent <!-- allow-term:crane -->
`allow-term:<word>` pragma instead of a reword.

### Lockstep identifier renames

A shared literal (e.g. an annotation key both repos read) has no compile-time coupling — only
the string. To rename it safely:

1. Prepare both MRs (upstream rename + downstream rename) and get both approved.
2. Land them together as one window; one owner watches both pipelines.
3. Pause releases/deploys of both repos until both are green.
4. If either side fails, revert whichever side already landed so both repos share one literal
   again, then retry.

## 4. Guard

Wire `check-forbidden-terms.sh` into CI:

- `pull_request` → `--diff origin/<base>` (needs `fetch-depth: 0` or an explicit base fetch).
- `push` / `schedule` / `merge_group` → `--full-tree` (avoids merge-queue base-ref edge cases;
  safe once the sweep is clean).
- Add `.github/workflows/**` to any path filter gating the job, so workflow-only regressions
  are still caught.

Keep the repo's own agentic files (`AGENTS.md`, `.claude/CLAUDE.md`) generic — link to this
standard rather than inlining the term list, or the guard trips on itself.

## 5. Verify

- `check-forbidden-terms.sh --full-tree` passes (only pragma'd hits remain).
- Build/test green; if a functional identifier changed, the downstream repo's tests are green
  too.
- Smoke-test the guard: add a forbidden term to a doc → `--diff` fails; add an adjacent
  `allow-term` pragma → passes.

## 6. Repeat

Run steps 1–5 for the next upstream repo. The guard script is shared, so only the CI wiring
and the sweep are per-repo.
