# Package Structure

> **Version** 1.2 · **Updated** 2026-05-15

## Changelog

| Version | Date | Summary |
|---------|------|---------|
| 1.2 | 2026-05-15 | Remove generators from kure tree; update launcher to OAM-era structure; add cross-reference to kure-launcher-architecture.md |
| 1.1 | 2026-05-14 | Correct launcher tree (remove phantom packages); clarify platform profile vs ClusterProfile |
| 1.0 | 2026-05-14 | Initial document |

---

This document describes how code is organized across the go-kure repositories and how to decide
where new code belongs.

---

## kure

`github.com/go-kure/kure` — a Go library for programmatically building Kubernetes resources used
by GitOps tools.

```
kure/
├── pkg/                  # Public API — stable exports for library callers
│   ├── errors/           # Error wrapping (use instead of fmt.Errorf)
│   ├── gvk/              # GroupVersionKind utilities
│   ├── io/               # YAML serialization
│   ├── kubernetes/       # Public K8s resource builders (core, FluxCD, MetalLB, ExternalSecrets)
│   ├── logger/           # Structured logging
│   └── stack/            # Core domain model (Cluster → Node → Bundle → Application)
│       ├── argocd/       # ArgoCD workflow
│       ├── fluxcd/       # FluxCD workflow
│       └── layout/       # Manifest layout tree (ManifestLayout, WriteToTar)
├── internal/             # Implementation detail — not accessible to external callers
│   ├── certmanager/      # cert-manager resource builders
│   ├── cnpg/             # CloudNativePG resource builders
│   ├── externalsecrets/  # External Secrets resource builders
│   ├── fluxcd/           # FluxCD resource builders
│   ├── gvk/              # Internal GVK utilities
│   ├── kubernetes/       # Core K8s resource builders
│   ├── metallb/          # MetalLB resource builders
│   └── validation/       # Internal validation utilities
├── cmd/
│   └── kure/             # Demo CLI — showcases the library; not a production tool
├── examples/             # Sample configurations
└── docs/                 # Documentation
```

### pkg/ vs internal/ decision rule for kure

A symbol belongs in `pkg/` when it is part of the library's public contract — something a library
caller (a downstream consumer, launcher, or an external user) needs to import directly.

A symbol belongs in `internal/` when it implements a resource builder or utility that callers
access only through `pkg/`. The majority of resource builders live here.

### cmd/kure — demo only

The `cmd/kure/` CLI is a demo and testing tool for the library. It is not a production tool and
carries no stability guarantee.

---

## launcher

`github.com/go-kure/launcher` — the kurel CLI and OAM-native package manager runtime.

```
launcher/
├── cmd/
│   └── kurel/            # kurel CLI entrypoint (main package)
├── pkg/
│   ├── cmd/
│   │   └── kurel/        # kurel command implementations (cobra commands)
│   ├── oam/              # OAM types, parser, handler registry, build pipeline
│   │   └── builtin/
│   │       ├── components/  # Built-in component handlers (webservice, worker, helmrelease, ...)
│   │       └── traits/      # Built-in trait handlers (expose, certificate, ingress, ...)
│   └── patch/            # JSONPath-based patching: TOML/YAML parsing, strategic merge
├── docs/
│   └── design.md         # Full design document and vision (canonical)
└── site/                 # Documentation site
```

launcher does not have its own `pkg/errors` or `pkg/logger` — it imports those from
`github.com/go-kure/kure/pkg/errors` and `github.com/go-kure/kure/pkg/logger`.

---

## Relationship between kure and launcher

The dependency is strictly one-directional: **launcher imports kure; kure has no dependency on
launcher**.

```
launcher → kure
```

kure is a library. launcher is an application (CLI tool). They have separate release cadences,
separate repos, and separate versioning.

| Concern | Lives in |
|---------|----------|
| Kubernetes resource construction | kure (`pkg/kubernetes`) |
| GitOps engine (FluxCD, ArgoCD) | kure (`pkg/stack/fluxcd`, `pkg/stack/argocd`) |
| Manifest layout tree, OCI packaging | kure (`pkg/stack/layout`) |
| OAM package format and runtime | launcher (`pkg/oam`) |
| Component handlers (webservice, worker, ...) | launcher (`pkg/oam/builtin/components`) |
| Trait handlers (expose, certificate, ...) | launcher (`pkg/oam/builtin/traits`) |
| Policy interface + NoopPolicy | launcher (`pkg/oam`) |
| Parameter resolution and patch application | launcher (`pkg/patch`) |
| kurel CLI | launcher |

---

## Where does new code go?

**Goes in kure when**:
- It is a Kubernetes resource builder (for a CRD operator or core K8s type)
- It is a utility the domain model depends on (GVK, serialization, layout)
- It adds or modifies the Cluster → Node → Bundle → Application model

**Goes in launcher when**:
- It is part of the OAM package format or runtime
- It is a component or trait handler
- It is part of the kurel CLI or its commands
- It handles the platform profile / application values split
- It is a patch or composition mechanism for kurel packages

**Does not belong in either**:
- Downstream CRD types (EnvironmentPolicy, ApplicationGroup, etc.) — those live in the downstream platform
  repos. Note: the kurel *platform profile* (the parameter set expressing trait implementation
  choices, e.g. which ingress controller is installed) is a different concept that *does* live in
  launcher, despite similar naming. See [oam-runtime](oam-runtime.md) §Two-Config-Set Model.

---

## Cross-References

- [kure-launcher-architecture](kure-launcher-architecture.md) — the layering model between kure,
  launcher, and downstream consumers (external tools)
- [oam-runtime](oam-runtime.md) — OAM-native package manager design (kurel)
