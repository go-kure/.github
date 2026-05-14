# API Stability Contract

> **Version** 1.0 · **Updated** 2026-05-14

## Changelog

| Version | Date | Summary |
|---------|------|---------|
| 1.0 | 2026-05-14 | Initial document |

---

This document describes the stability guarantees for the `go-kure/kure` and `go-kure/launcher`
modules — what callers can rely on, when things can break, and how breaking changes are
communicated.

---

## Module Boundaries

The stability contract applies at module granularity:

| Module | Path | Stability regime |
|--------|------|-----------------|
| kure | `github.com/go-kure/kure` | See below |
| launcher | `github.com/go-kure/launcher` | See below |

---

## v0.x: Pre-release

Both modules are currently pre-v1. The stability rules for pre-release are:

- Breaking changes are allowed in any minor bump (`v0.Y.0`).
- Patch releases (`v0.Y.Z` where Z > 0) are bugfix only — no breaking changes.
- Pre-release tags (`v0.Y.Z-alpha.N`, `-beta.N`, `-rc.N`) carry no stability guarantees at all.

"Breaking" means any change that requires callers to update their code: removed or renamed
exports, changed function signatures, changed struct fields, changed interface methods, changed
package paths.

## v1.0 and Beyond

Once a module reaches v1.0:

- Breaking changes require a major version bump (`vN+1`).
- The module path carries the major version suffix for v2+: `github.com/go-kure/kure/v2`.
- Minor bumps (`v1.Y.0`) add new functionality without breaking existing callers.
- Patch releases (`v1.Y.Z`) are bugfix only.

---

## What Is a Public API

The public API of a module is everything in `pkg/` that is exported (capitalized identifier) and
not explicitly marked experimental.

### pkg/ — stable API

All exported symbols in `pkg/` are part of the public API and subject to the stability guarantee
for the current version regime.

### internal/ — not a public API

Packages under `internal/` are an implementation detail. Go's visibility rules already enforce
this. There are no stability guarantees on internal packages across versions.

### cmd/ in kure — demo only

The `cmd/` directory in kure contains demo tooling (`cmd/kure/`). It is not a stable API. It may
be removed or changed at any time.

### cmd/ in launcher — kurel CLI

The `kurel` CLI (`cmd/kurel/`) is a versioned product. Its command-line interface follows the same
stability rules as the module version: no breaking flag/subcommand changes in patch releases,
breaking changes require a minor bump in v0.x or a major bump in v1+.

---

## Experimental Packages

Packages or symbols that are not yet stable within a nominally stable module are marked with a
doc comment:

```go
// Experimental: this API is not yet stable and may change in a minor release.
```

Experimental symbols may be changed or removed in minor releases regardless of the overall module
version. They graduate to stable when the comment is removed.

---

## Deprecation Policy

When a symbol needs to be removed:

1. **Announce in CHANGELOG**: note the symbol as deprecated and what replaces it.
2. **Keep for one minor release**: the deprecated symbol remains functional.
3. **Remove in the next minor release** (v0.x) or the next major release (v1+).

Deprecated symbols are marked with a `// Deprecated:` doc comment pointing to the replacement:

```go
// Deprecated: use NewFoo instead. Will be removed in v0.5.
func OldFoo() {}
```

---

## Module Path Stability

The module path is stable for the lifetime of a major version:

- kure v0.x and v1.x: `github.com/go-kure/kure`
- kure v2+: `github.com/go-kure/kure/v2`
- launcher v0.x and v1.x: `github.com/go-kure/launcher`
- launcher v2+: `github.com/go-kure/launcher/v2`

The module path will not change within a major version for any other reason.
