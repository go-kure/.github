# OAM Runtime

> **Version** 2.0 · **Updated** 2026-05-15

## Changelog

| Version | Date | Summary |
|---------|------|---------|
| 2.0 | 2026-05-15 | Full rewrite — reflects OAM-native architecture; removes obsolete patch-pipeline content and open questions now tracked in launcher/docs/design.md |
| 1.1 | 2026-05-14 | Add canonical source reference |
| 1.0 | 2026-05-14 | Initial document |

---

This document is an org-level summary of the OAM-native package manager implemented in
`go-kure/launcher` and shipped as the `kurel` CLI.

> **Canonical source**: [launcher/docs/design.md](https://github.com/go-kure/launcher/blob/main/docs/design.md) —
> the product repo is authoritative for detailed design decisions and the current roadmap.
>
> **Architecture context**: [kure-launcher-architecture](kure-launcher-architecture.md) —
> the layering model between kure, launcher, and downstream consumers.

---

## Vision

**Launcher** is an OAM-native package manager for Kubernetes — a semantically richer alternative
to Helm.

Where Helm templates Kubernetes manifests from Go template files and a flat `values.yaml`, launcher
models deployments using OAM concepts (Applications, Components, Traits) as its package format,
under launcher's own API group. The result is a tool where:

- Application structure is explicit and typed
- Platform implementation choices are separated from application choices
- Output is always static, GitOps-ready Kubernetes manifests

Launcher defines its own native application model under `launcher.gokure.dev/v1alpha1`. OAM is the
conceptual inspiration, not the API contract — launcher does not claim native API compatibility with
`core.oam.dev/v1beta1`.

Launcher uses the [kure](https://github.com/go-kure/kure) library for Kubernetes resource generation.

---

## The kurel Package

A **kurel package** is a bundle of OAM specs that can be instantiated with parameters. It
represents a reusable, shareable application pattern.

### Package Contents

```
my-webservice/
├── kurel.yaml          # Package metadata and parameter schema (kind: Package)
└── app.yaml            # Application template (kind: Application)
```

`kurel.yaml` declares parameters (name, type, default, required) and the package version. `app.yaml`
is a launcher Application document. The package author defines what can be varied; consumers fill
in the values.

---

## Two-Config-Set Model

Every kurel package accepts **two distinct parameter sets** at instantiation time.

### Set 1 — Platform profile

Describes *how* the platform implements each trait. Platform-specific, not application-specific.
A team managing a cluster defines one platform profile; all applications deployed to that cluster
share it.

Examples:
- Which ingress controller is in use (Nginx, Traefik, Gateway API)
- Which certificate authority backs cert-manager (Let's Encrypt, internal CA)
- Which secret store implementation is active (Vault, AWS Secrets Manager via External Secrets)
- Which GitOps engine is in use (FluxCD, ArgoCD)

### Set 2 — Application values

Describes *what* this specific application instance needs. Provided per deployment.

Examples:
- Container image and tag
- Replica count, resource requests/limits
- Feature flags
- External secret names
- Domain names

### Separation of Concerns

The split maps directly onto OAM's design intent:

- OAM Components define *what workloads exist* — application developer concern
- OAM Traits define *what platform capabilities to attach* — platform operator concern
- Trait *implementation* (how it works) is a platform profile concern, invisible to the application
  developer

When deploying multiple packages to a cluster, the platform profile is configured once per
environment. Each application provides its own values. Platform changes (e.g. switching ingress
controllers) update one profile; no individual application spec changes.

---

## Architecture

Launcher is an OAM-native build pipeline. It parses launcher-native documents, dispatches to
handler registries, and produces static Kubernetes manifests.

```
              kurel CLI
                 │
    ┌────────────▼────────────────┐
    │         OAM Parser           │
    │  app.yaml  kurel.yaml        │
    │      cluster.yaml            │
    │  (launcher.gokure.dev/       │
    │        v1alpha1)             │
    └────────────┬─────────────────┘
                 │
    ┌────────────▼────────────────┐
    │   Handler Registry +         │
    │    Build Pipeline            │
    │                              │
    │  Component handlers          │
    │  (webservice, worker,        │
    │   helmrelease, ...)          │
    │                              │
    │  Trait handlers              │
    │  (expose, certificate,       │
    │   ingress, ...)              │
    │                              │
    │  Policy interface            │
    │  (downstream enforcement)    │
    └────────────┬─────────────────┘
                 │
    ┌────────────▼────────────────┐
    │       kure library           │
    │  K8s builders + FluxCD       │
    └────────────┬─────────────────┘
                 │
         Static manifests
         (GitOps delivery)
```

Launcher generates **static Kubernetes manifests**. It does not deploy them. Consumers feed the
output into a GitOps pipeline (FluxCD, ArgoCD) or apply it directly with `kubectl`.

The **Policy interface** is the extension point for downstream consumers. Launcher ships a
`NoopPolicy` default; consumers provide their own implementation to enforce organizational
constraints (registry whitelists, resource bounds, security posture). See
[kure-launcher-architecture](kure-launcher-architecture.md) for the full extension model.

---

## Comparison with Helm

| Aspect | Helm | Launcher / kurel |
|--------|------|-----------------|
| Package format | Go templates + values.yaml | OAM Application spec + typed parameters |
| Platform vs app config | Single values.yaml | Two explicit parameter sets |
| Semantics | Arbitrary YAML generation | OAM components/traits (typed intent) |
| Platform customization | Via values + conditional templates | Via platform profile (trait implementation resolution) |
| Output | Manifests applied to cluster | Static manifests → GitOps delivery |
| Cluster runtime component | Tiller (v2) / none (v3) | None — compile-time only |
| Composability | Helm subcharts | OAM composition + parameters |

---

## Comparison with KubeVela

[KubeVela](https://kubevela.io/) is the reference OAM runtime.

| Aspect | KubeVela | Launcher / kurel |
|--------|----------|-----------------|
| Runtime model | Live reconciler (CRD controller in cluster) | Compiler (offline, static output) |
| Cluster dependency | Requires KubeVela CRDs installed | No cluster-side component |
| Audit trail | Live CRD state | Git history of generated manifests |
| GitOps | Via VelaUX or GitOps addon | Native — output is GitOps-ready |

Launcher targets teams committed to a GitOps-first workflow who want OAM semantics without a
cluster-side controller.
