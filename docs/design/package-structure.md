# Package Structure

> **Version** 1.0 · **Updated** 2026-05-14

## Changelog

| Version | Date | Summary |
|---------|------|---------|
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
│       ├── generators/   # Application generators (including kurelpackage generator)
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
caller (Crane, launcher, or an external user) needs to import directly.

A symbol belongs in `internal/` when it implements a resource builder or utility that callers
access only through `pkg/`. The majority of resource builders live here.

### cmd/kure — demo only

The `cmd/kure/` CLI is a demo and testing tool for the library. It is not a production tool and
carries no stability guarantee. It will be removed or simplified once `pkg/stack/generators/` and
launcher cover its use cases.

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
│   ├── errors/           # Error wrapping (mirrors kure pattern)
│   ├── launcher/         # Package launcher core: load → resolve → patch → validate → build
│   ├── logger/           # Structured logging (mirrors kure pattern)
│   ├── oam/              # OAM types (package spec, platform profile, application values)
│   └── patch/            # JSONPath-based patching: TOML/YAML parsing, strategic merge
├── docs/
│   └── design.md         # Full design document and vision
└── site/                 # Documentation site
```

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
| kurel package generator (kure → kurel output) | kure (`pkg/stack/generators/kurelpackage`) |
| OAM package format and runtime | launcher |
| Two-config-set model (platform profile + app values) | launcher |
| Parameter resolution and patch application | launcher (`pkg/patch`) |
| kurel CLI | launcher |

### The kurelpackage generator stays in kure

`pkg/stack/generators/kurelpackage/` is a kure generator — it produces kurel package structure as
output from a kure Application. This is a kure concern (generating artifacts from the kure domain
model), not a launcher concern. It remains in kure.

---

## Where does new code go?

**Goes in kure when**:
- It is a Kubernetes resource builder (for a CRD operator or core K8s type)
- It is a utility the domain model depends on (GVK, serialization, layout)
- It adds or modifies the Cluster → Node → Bundle → Application model

**Goes in launcher when**:
- It is part of the OAM package format or runtime
- It is part of the kurel CLI or its commands
- It handles the platform profile / application values split
- It is a patch or composition mechanism for kurel packages

**Does not belong in either**:
- Wharf platform types (EnvironmentPolicy, ClusterProfile, etc.) — those live in the Wharf
  platform repos (`go-kure/launcher` hosts the OAM Runtime sub-project, but the Wharf-specific
  resource types stay in the Wharf workspace)
