# go-kure

Open-source Go libraries and tools for Kubernetes resource management.

| Repository | Description |
|------------|-------------|
| [kure](https://github.com/go-kure/kure) | Kubernetes resource builder library — v0.2.0-alpha |
| [launcher](https://github.com/go-kure/launcher) | OAM-native package manager / kurel CLI |

Documentation: [www.gokure.dev](https://www.gokure.dev)

## Current Focus

**kure v0.2.0** — Helm builder layer (HelmRelease, HelmRepository, RenderChart HTTP, hook utilities) feeding into launcher OAM Phase 2.

**launcher** — OAM Phase 2 (built-in handlers): helmchart component type with native FluxCD and template delivery modes.

Roadmap: [Kure Roadmap](https://github.com/orgs/go-kure/projects/1) · [OAM Runtime](https://github.com/orgs/go-kure/projects/3)
