# kure + launcher Architecture

> **Version** 1.0 · **Updated** 2026-05-15

## Changelog

| Version | Date | Summary |
|---------|------|---------|
| 1.0 | 2026-05-15 | Initial document — establishes kure/launcher layering model and extension contracts |

---

This document describes the architectural relationship between the two go-kure repositories and
the principles that govern what belongs in each.

---

## The Two Layers

The go-kure project is structured as two distinct layers:

```
downstream consumers
        │
        ▼
   launcher (OAM runtime)
        │
        ▼
    kure (library)
```

**kure** (`github.com/go-kure/kure`) is an unopinionated Go library for programmatically building
Kubernetes resources. It provides building blocks — it does not make decisions about what
application patterns look like.

**launcher** (`github.com/go-kure/launcher`) is an opinionated OAM-inspired package manager and
runtime built on kure. It defines a specific model for describing applications and generating
manifests from them.

The dependency is strictly one-directional: launcher imports kure; kure has no dependency on
launcher.

---

## kure — Unopinionated Foundation

### What kure provides

| Package | Role |
|---------|------|
| `pkg/kubernetes/` | Go builders for Kubernetes and CRD resource types (Deployment, Service, HelmRelease, Certificate, etc.) |
| `pkg/stack/` | Domain model: `ApplicationConfig` interface, `Application`, `Bundle`, `Node`, `Cluster` |
| `pkg/stack/fluxcd/` | FluxCD workflow: `OCIRepository`, `Kustomization` generation, `ManifestLayout` |
| `pkg/stack/argocd/` | ArgoCD workflow equivalent |
| `pkg/errors/`, `pkg/logger/`, `pkg/io/` | Foundational utilities |
| `pkg/gvk/` | GroupVersionKind utilities |

The central abstraction is `ApplicationConfig`:

```go
type ApplicationConfig interface {
    Generate(*Application) ([]*client.Object, error)
}
```

Any code that implements this interface can participate in kure's `Bundle` → `Generate()` →
manifest pipeline, and in the FluxCD/ArgoCD layout workflows.

### What kure does NOT provide

kure does not define what a "webservice", "helmrelease", "certificate", or any other
application-level component looks like. It provides the `ApplicationConfig` interface and the
K8s builders; it does not provide implementations that combine them into named application
patterns.

**Why this matters for library design.** If kure defined a `WebserviceConfig`, it would need to
decide: does it include a `ServiceAccount`? Topology spread constraints? Sidecars? Each
downstream consumer has different answers. Putting the composed abstraction in the library
couples all consumers to kure's version of that answer — either forcing them to post-process
generated objects (brittle), or requiring kure to grow to accommodate every consumer's needs.
kure avoids this by providing composable primitives and leaving composition to consumers.

The same applies to layout: kure provides the FluxCD workflow primitives (`CreateLayoutWithResources`,
`ManifestLayout`, `Kustomization` builders). It does not define *how many* OCI artifacts to
produce, or what the directory hierarchy looks like. Each consumer implements its own layout
using these primitives.

---

## launcher — Open-Source OAM Runtime

### What launcher provides

launcher defines a complete application model under `launcher.gokure.dev/v1alpha1`:

| Document | Kind | Role |
|----------|------|------|
| `app.yaml` | `Application` | OAM-inspired application spec (components + traits + policies) |
| `kurel.yaml` | `Package` | Package metadata and parameter schema |
| `cluster.yaml` | `ClusterProfile` | Platform capability definitions (how traits are implemented) |

launcher implements:

- **Component handlers** — transform OAM component specs into `ApplicationConfig` implementations
  (webservice, worker, helmrelease, daemonset, statefulset, cronjob, postgresql)
- **Trait handlers** — add or mutate resources associated with a component
  (expose, certificate, external-secret, ingress, httproute, configmap, networkpolicy,
  cilium-networkpolicy, pvc, scaler, volsync)
- **OAM runtime** — handler registry, transform pipeline, parameter resolution
- **Policy interface** — extension point for downstream enforcement (see below)
- **Monolithic layout** — simple FluxCD delivery: single OCI artifact, one `Kustomization` per
  bundle; implemented using `kure/pkg/stack/fluxcd` primitives

### The Policy interface

launcher defines a `Policy` interface in `pkg/oam/policy.go`:

```go
type Policy interface {
    ValidateImage(ref string) error
    ValidateReplicas(n int32) error
    ValidateResources(req corev1.ResourceRequirements) error
    ValidateStorage(size resource.Quantity) error
    ValidatePodSpec(spec *corev1.PodSpec) error
    ValidateCapability(traitType string) error
    DefaultReplicas() *int32
    DefaultResources() *corev1.ResourceRequirements
    // ...
}
```

All component and trait handlers accept an optional `Policy`. launcher ships `NoopPolicy` as
the default (all validations pass; no defaults applied). Downstream consumers provide their own
`Policy` implementation to enforce organizational constraints — registry whitelists, resource
bounds, security posture, capability allow/deny lists.

A Policy implementation is registered at the pipeline level and applies uniformly to all
handlers. Consumers do not need to replace individual handlers to add enforcement.

### What launcher does NOT do

launcher does not implement:

- Multi-OCI artifact splitting — each consumer defines its own delivery layout
- Platform component catalog Flux emission (Kustomizations for infrastructure components)
- EnvironmentPolicy enforcement — that is the downstream consumer's responsibility
- Cluster bootstrap sequences

These are deliberately left to downstream consumers, which combine launcher's OAM handling
with kure's layout primitives to build their own delivery pipelines.

---

## Downstream Consumers

A downstream consumer of this stack:

1. **Imports launcher** for OAM types, all built-in component and trait handlers, and the
   `Policy` interface
2. **Imports kure** (`pkg/stack/fluxcd`) for layout primitives when implementing a delivery
   layout that goes beyond launcher's monolithic default
3. **Implements `Policy`** with its own enforcement rules (registry whitelist, resource bounds,
   security constraints, etc.)
4. **Implements its own layout** using kure's `CreateLayoutWithResources`, `ManifestLayout`,
   and Kustomization/OCIRepository builders
5. **Registers additional handlers** for component or trait types not covered by launcher's
   built-in set

As launcher matures and adds richer layouts and additional handlers, consumers can adopt
launcher's implementations by replacing their own — the `Policy` interface and the handler
registry make this a mechanical change.

---

## Cross-References

- [package-structure](package-structure.md) — where code lives in each repository
- [oam-runtime](oam-runtime.md) — launcher's OAM model and kurel package format
- [launcher/docs/design.md](https://github.com/go-kure/launcher/blob/main/docs/design.md) — authoritative launcher design
- [kure/docs/ARCHITECTURE.md](https://github.com/go-kure/kure/blob/main/docs/ARCHITECTURE.md) — authoritative kure architecture
