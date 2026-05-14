# OAM Runtime

> **Version** 1.1 · **Updated** 2026-05-14

## Changelog

| Version | Date | Summary |
|---------|------|---------|
| 1.1 | 2026-05-14 | Add canonical source reference |
| 1.0 | 2026-05-14 | Initial document |

---

This document is an org-level summary of the OAM-native package manager implemented in
`go-kure/launcher` and shipped as the `kurel` CLI.

> **Canonical source**: [launcher/docs/design.md](https://github.com/go-kure/launcher/blob/main/docs/design.md) —
> the product repo is authoritative for detailed design decisions and the current roadmap.

---

## Vision

**Launcher** is an OAM-native package manager for Kubernetes — a semantically richer alternative
to Helm.

Where Helm templates Kubernetes manifests from Go template files and a flat `values.yaml`, launcher
models deployments using the [Open Application Model (OAM)](https://oam.dev/) as its package
format. The result is a tool where:

- Application structure is explicit and typed
- Platform implementation choices are separated from application choices
- Output is always static, GitOps-ready Kubernetes manifests

Launcher uses the [kure](https://github.com/go-kure/kure) library for Kubernetes resource
generation.

---

## The kurel Package

A **kurel package** is a bundle of OAM specs that can be instantiated with parameters. It
represents a reusable, shareable application pattern.

### Package contents

```
my-webservice/
├── kurel.yaml          # Package metadata and parameter schema
├── app.yaml            # OAM Application template (parameterized)
└── patches/            # Optional composition patches
```

`app.yaml` is a standard OAM Application document with parameter placeholders. The package author
defines what can be varied; consumers fill in the values.

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

### Separation of concerns

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

```
┌─────────────────────────────────────────────┐
│                kurel CLI                    │
│           (launcher/cmd/kurel)              │
└──────────────────────┬──────────────────────┘
                       │
         ┌─────────────▼──────────────┐
         │     launcher runtime       │
         │  (launcher/pkg/launcher)   │
         │                            │
         │  load → resolve → patch    │
         │       → validate → build   │
         └─────────────┬──────────────┘
                       │
         ┌─────────────▼──────────────┐
         │       patch engine         │
         │   (launcher/pkg/patch)     │
         │  TOML/YAML/JSONPath/SMP    │
         └─────────────┬──────────────┘
                       │
         ┌─────────────▼──────────────┐
         │       kure library         │
         │  (github.com/go-kure/kure) │
         │  K8s builders + GitOps     │
         └────────────────────────────┘
```

Launcher generates **static Kubernetes manifests**. It does not deploy them. Consumers feed the
output into a GitOps pipeline (FluxCD, ArgoCD) or apply it directly with `kubectl`.

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
| Composability | Helm subcharts | OAM composition + patches |

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

---

## Roadmap

**Phase 0 (complete): Extraction and housekeeping**
- Moved prototype code from kure into launcher
- Established module structure and CI

**Phase 1: OAM-native package format**
- Define kurel package spec (`kurel.yaml` schema)
- Define OAM Application template parameterization
- Define platform profile contract
- Implement parameter resolution for both sets

**Phase 2: Conditional composition**
- OAM policy-based conditional inclusion
- Patch composition on top of OAM Application base

**Phase 3: Package distribution**
- OCI-based package publishing and pulling
- Package versioning

---

## Open Questions

1. **Conditional inclusion syntax** — OAM does not natively support conditional sections.
   Proposed: use OAM `PolicyDefinition` with kurel-specific policy types. Needs design.

2. **Platform profile format** — How do platform operators express trait implementations? Options:
   YAML file, OAM WorkloadDefinition overrides, capability map. Needs design.

3. **Trait resolution contract** — How does the launcher runtime map "this component requests
   IngressTrait" to the concrete K8s objects to generate, given a platform profile? This is the
   core runtime design question.
