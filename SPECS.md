# 📘 SPR-001 — Sprout Architecture Specification

| Field | Value |
|-------|-------|
| **Document ID** | SPR-001 |
| **Version** | 1.0  |
| **Status** | Final |
| **Authors** | Pablo Albarrán |
| **Audience** | Core maintainers, module developers, infrastructure engineers, contributors, AI coding agents |
| **Last Updated** | 2026-07-08 |

---

## Abstract

**Sprout** is an open-source platform that provisions and operates a complete local AI Runtime with minimal user interaction. Unlike a traditional installer, Sprout does not just install software — it guarantees that every component it installs is fully configured, validated, and immediately usable.

The architecture centers on a lightweight **Core** that orchestrates the Runtime lifecycle while delegating all feature-specific logic to independent **Modules**. This lets the platform grow without ever touching the Core.

This document is the normative, single source of truth for any implementation of Sprout — human- or AI-built. Where implementation and specification disagree, **the specification prevails**.

---

# 1. Introduction

**Purpose & Scope.** This document defines the responsibilities, constraints, interfaces, lifecycle, and behavioral contracts of every architectural component in Sprout: Core, Runtime, CLI, Module system, Garden repository, provisioning workflow, OpenClaw integration, bootstrap process, and versioning strategy. It does **not** prescribe source-tree layout, internal algorithms, or UI design, except where those choices affect the architectural contract.

**Audience.** Readers should have working knowledge of Docker, container orchestration, YAML, Linux, shell scripting, and REST-based applications. No prior knowledge of OpenClaw internals is required.

## 1.1 Goals

| # | Goal | Requirement |
|---|------|-------------|
| 1 | **Ready-to-Use AI Runtime** | A clean install SHALL produce a fully operational Runtime immediately after first startup. Users MUST NOT perform manual configuration beforehand. |
| 2 | **Centralized Management** | Every Runtime operation SHALL be orchestrated exclusively by the Sprout Core, via the Sprout CLI. |
| 3 | **Unlimited Extensibility** | New capabilities SHALL ship as independent modules; the Core MUST stay implementation-agnostic. |
| 4 | **Long-Term Maintainability** | New modules, providers, databases, models, and engines SHALL be addable without modifying the Core. |

## 1.2 Non-Goals

The Core SHALL NOT implement business logic for LLM/Frontier AI providers, database engines, vector databases, MCP servers, workflow engines, productivity tools, AI models, or business applications. These belong exclusively to modules.

## 1.3 Terminology

| Term | Definition |
|------|------------|
| **Core** | Central orchestration engine responsible for the Runtime lifecycle. |
| **Runtime** | The complete operational environment managed by Sprout. |
| **Garden** | The remote module repository (metadata and definitions). |
| **Module** | An independently installable capability extending the Runtime. |
| **Provisioning** | The full install → configure → validate → activate process. |
| **Bootstrap Module** | The first module the Core auto-provisions to make the Runtime usable. |
| **Bootstrap Model** | The default local LLM installed by the Bootstrap Module. |
| **Provider** | A service capable of serving AI models (local or remote). |
| **Capability** | Any feature exposed to the user after successful provisioning. |
| **READY** | Operational state indicating a capability is fully usable. |

## 1.4 Conventions

Keywords **MUST / MUST NOT / SHALL / SHALL NOT / SHOULD / SHOULD NOT / MAY** follow RFC 2119. Unless stated otherwise, every requirement in this Specification is mandatory.

---

# 2. Sprout Vision

## 2.1 Problem Statement

Modern AI stacks combine inference runtimes, models, reverse proxies, databases, vector stores, workflow engines, secrets managers, and external providers. Each piece is easy to install in isolation, but wiring them into a stable, reproducible, production-ready environment is complex and error-prone: users must install multiple apps, configure each manually, understand networking/ports/volumes/credentials, connect services, and troubleshoot compatibility — and these steps grow harder to reproduce as the ecosystem evolves.

Sprout's answer is to treat an AI environment as **one Runtime**, not a pile of independent applications.

## 2.2 Vision & Design Philosophy

Sprout aims to be the simplest, most reliable way to provision, operate, and extend a complete AI Runtime — acting as an orchestration platform, not a mere installer. Every capability, regardless of type (model, database, vector engine, MCP server, workflow engine, provider, productivity tool, or future extension), installs the same way:

```bash
sprout install <capability>
```

This is anchored by one philosophy:

> **Every capability installed by Sprout MUST be immediately usable.**

Installation alone is not success. A capability only counts as installed once it has been **installed → configured → provisioned → validated → declared READY** — eliminating post-install manual work.

## 2.3 Project Objectives

| Objective | Requirement |
|---|---|
| Zero Manual Configuration | A freshly provisioned Runtime SHOULD need no manual setup; configuration SHALL be automatic wherever possible. |
| Consistent UX | Every capability is managed through the same CLI (`sprout install postgres`, `sprout install openai`, `sprout doctor`, `sprout update`, …). Users SHOULD never run module-specific scripts directly. |
| Unlimited Extensibility | New capabilities MUST be addable as modules, without Core changes. |
| Predictable State | The Runtime MUST expose a deterministic, persisted operational state at all times — the platform's source of truth. |
| AI-Driven Development | Contracts MUST be explicit, machine-readable, deterministic, and unambiguous enough for both humans and AI coding agents to implement. |

## 2.4 What Sprout Is / Is Not

**Is:** an AI Runtime Provisioning Platform — responsible for orchestration, lifecycle management, module provisioning, validation, automatic configuration, state management, capability discovery, dependency resolution, health checks, and recovery. It delivers *operational capabilities*, not software packages.

**Is not:** a container orchestrator, package manager, Linux distribution, Docker/Kubernetes replacement, inference engine, model repository, or application framework. Sprout integrates existing technologies into a coherent Runtime instead.

---

# 3. Architectural Principles

These principles are normative, immutable absent a formal revision of this Specification, and take precedence over any conflicting implementation detail.

| Principle | Statement |
|---|---|
| **Ready by Default** | A capability is not "installed" merely because binaries/containers exist. It MUST pass **Installation → Configuration → Provisioning → Validation → Activation** before being exposed to the user. |
| **Centralized Orchestration** | The Core is the *only* orchestrator. Every lifecycle operation MUST originate from the CLI; modules MUST NOT expose commands meant for direct user execution. |
| **Provisioning over Installation** | Provisioning is the full process (dependency resolution, install, config generation, secrets, service/provider registration, health validation, Runtime registration) needed to reach READY — not just "software present." |
| **Runtime as Source of Truth** | `runtime.yaml` and `modules.yaml` are authoritative. No module maintains independent Runtime state; only the Core writes them. |
| **Declarative Runtime** | Desired state lives in Runtime metadata, not inferred from running containers. Operations reconcile toward that state (rather than acting imperatively), so interrupted operations resume safely. |
| **Core Agnostic** | The Core contains zero logic specific to databases, models, providers, vector DBs, workflow engines, or business apps — it only supplies the orchestration framework. |
| **Bootstrap by Module** | The first-ever provisioned capability (the **Ollama Module**) is provisioned through the exact same lifecycle as any future module — proving the architecture from the first install, not special-casing it. |
| **Extensibility First** | New capabilities (PostgreSQL, Qdrant, OpenBao, n8n, MCP servers, Frontier providers, etc.) ship as modules. Core provides orchestration only; modules provide functionality. |
| **Automatic Configuration** | Sprout configures installed capabilities automatically wherever technically possible (config files, DB creation, credentials, provider registration, connectivity checks). Manual steps are limited to unavoidable external credentials/decisions. |
| **Deterministic Operations** | Same command + same Runtime state ⇒ same result. Operations SHOULD be idempotent and interrupted operations recoverable without manual cleanup. |
| **Backward Compatibility** | Existing workflows (`./sprout.sh`, `./start.sh`) SHALL remain supported unless explicitly deprecated in a future Specification revision; evolution SHOULD extend rather than replace. |
| **Separation of Responsibilities** | Core = orchestration; Garden = discovery; Module = capability; Runtime = state; CLI = user interaction; OpenClaw = AI interface; Ollama = local inference. No overlap. |
| **Simplicity over Complexity** | When multiple equivalent designs exist, prefer the one reducing operational complexity and Core responsibility — pushing complexity into modules, not the Core. |

---

# 4. Overall Architecture

Sprout is a layered platform separating orchestration (Core) from implementation (Modules), minimizing coupling so new capabilities can be added without touching existing ones.

Sprout SHALL conform to IEEE Std 1003.1-2024 (POSIX.1).

The implementation SHALL execute correctly using a POSIX-compliant shell using `/bin/sh`.

The implementation SHALL NOT require Bash-specific extensions or GNU-specific shell features as:

- Bash
- Zsh
- Fish
- Ksh
- GNU-specific shell extensions

Any implementation relying on non-POSIX shell behavior SHALL be considered non-conformant with this Specification.

```
                         User
                           │
                           ▼
                    Sprout CLI
                           │
                           ▼
                     Sprout Core
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
        ▼                  ▼                  ▼
    Runtime            Garden          Module Manager
        │                  │                  │
        │                  ▼                  ▼
        │          Module Repository      Installed Modules
        │
        ▼
   Operational Runtime
        │
        ├── Docker, Nginx, Redis, OpenClaw, Ollama, TinyLlama, …
```

## 4.1 Components

| Component | Responsibility | Constraint |
|---|---|---|
| **Sprout CLI** | Receive commands, validate input, invoke Core operations, display status/errors | Implements no provisioning logic |
| **Sprout Core** | Lifecycle orchestration, reconciliation, dependency resolution, module execution, state management, provisioning, health, recovery | No capability-specific implementation |
| **Runtime** | Operational state: infra services, installed modules, metadata, config | Must remain deterministic/reproducible |
| **Garden** | Publishes module metadata, versions, dependencies, compatibility | Holds no Runtime state |
| **Modules** | Implement individual capabilities (PostgreSQL, Ollama, Qdrant, OpenBao, n8n, MCP servers, Frontier providers, …) | Never self-orchestrate; all lifecycle ops initiated by the Core |

**Runtime composition:** *Infrastructure components* (Docker, Redis, Nginx, OpenClaw, Tailscale) are provisioned directly by the Core; *capability components* (Ollama, models, databases, vector stores, workflow engines, external providers) are provisioned through the Module system.

## 4.2 Bootstrap, Control Flow & Information Flow

On first startup the Core auto-provisions the official Bootstrap Module (**Ollama**), which installs Ollama, downloads TinyLlama, configures the local provider, onboards OpenClaw automatically, and validates the Runtime — reaching READY through the identical lifecycle any future module uses.

Every operation follows one execution path: `User → CLI → Core → Garden → Module → Provisioning → Validation → Runtime Update → READY`. Information flows in a single direction: the Core talks to Garden, Runtime, and Modules directly; **Garden never talks to the Runtime**, and **users never talk to modules**.

## 4.3 Responsibility Matrix

| Component | Owns State | User Visible |
|------------|:----------:|:------------:|
| CLI | No | Yes |
| Core | Yes | No |
| Runtime | Yes | No |
| Garden | No | No |
| Module | No | Indirectly |
| OpenClaw | No | Yes |
| Ollama | No | Indirectly |

**Constraints:** users interact only with the CLI; modules are never run directly; Garden never stores Runtime info; modules never touch Runtime state directly; new capabilities never require Core changes.

**Why this shape:** separating orchestration from implementation yields predictable Runtime behavior, independent module evolution, simpler testing, deterministic provisioning, and an AI-friendly, ever-more-stable Core as the ecosystem grows — future complexity is absorbed by modules, not the orchestration engine.

---

# 5. Core Architecture

The Core is the orchestration engine that turns user intent into deterministic Runtime operations while preserving Runtime consistency and integrity. It does **not** implement capabilities — it coordinates the lifecycle of capabilities implemented by modules — and stays lightweight, deterministic, and technology-agnostic.

## 5.1 Internal Subsystems

```
                  Sprout Core
 ┌─────────────────────────────────────────┐
 │ CLI Engine │ Runtime Manager │ Module Mgr │
 │ Garden Client │ Provisioning Engine       │
 │ State Manager │ Health Engine │ Recovery  │
 └─────────────────────────────────────────┘
```

| Subsystem | Responsibility |
|---|---|
| **CLI Engine** | Parses commands, validates parameters, invokes Core workflows, reports progress/exit codes. Contains no provisioning logic. |
| **Runtime Manager** | Runtime startup/shutdown, reconciliation, initialization, readiness, synchronization. Coordinates infrastructure before modules are provisioned. |
| **Module Manager** | Module discovery, dependency ordering, lifecycle execution, registration, removal, updates. Never implements module-specific behavior. |
| **Garden Client** | Downloads indexes, resolves modules/versions, dependency metadata, compatibility checks. Garden is read-only from the Runtime's perspective. |
| **Provisioning Engine** | Executes the lifecycle (`Install → Configure → Provision → Validate → READY`) per module; terminates immediately on a failed mandatory phase — no partial capability is ever declared READY. |
| **State Manager** | Exclusive owner of `runtime.yaml` / `modules.yaml`, Runtime metadata, lifecycle states, provisioning progress. No other component may write Runtime state. |
| **Health Engine** | Validates service availability, modules, dependencies, connectivity, providers, and overall Runtime consistency after every provisioning operation. |
| **Recovery Engine** | Detects incomplete provisioning, resumes/rolls back interrupted operations, rebuilds state, reconciles desired vs. actual state — deterministically. |

**Startup order:** `CLI → Runtime Manager → State Manager → Garden Client → Module Manager → Provisioning Engine → Health Engine → Recovery Engine → READY` (internal order may vary as long as responsibilities are preserved).

## 5.2 Constraints & Error Handling

The Core MUST NOT implement AI model management, database administration, provider logic, OpenClaw/Ollama business logic, workflow execution, vector-DB implementation, productivity-tool logic, or MCP server implementation — all of these belong exclusively to modules. Future subsystems (Event Engine, Telemetry, Plugin Engine, Scheduler, Policy Engine) MAY be added without breaking existing contracts.

On failure, the Core SHALL: stop the operation, preserve Runtime consistency, update Runtime state, report the failure, and leave the door open for recovery. **No operation may leave the Runtime in an undefined state.**

---

# 6. Runtime Architecture

The Runtime is the physical realization of the desired system state after provisioning completes: infrastructure services, installed capabilities, config files, metadata, operational state, and lifecycle information. It SHALL be **persistent** (survives restarts/reboots), **deterministic** (identical definitions ⇒ identical environments), **recoverable**, **declarative**, and **observable**.

## 6.1 Directory Structure

```text
openclaw-stack/
├── config/     — generated configuration (nginx, OpenClaw, providers, modules); regeneratable
├── runtime/    — operational artifacts, provisioning artifacts; NO user configuration
├── state/      — runtime.yaml, modules.yaml — owned exclusively by the Core
├── modules/    — one directory per installed module (postgres/, qdrant/, ollama/, …)
├── garden/     — cached Garden metadata (index.yaml); cacheable/offline-safe
├── docker-compose.yml, .env
└── start.sh, stop.sh, restart.sh, recreate.sh, logs.sh, inspect.sh, health.sh, approve-device.sh
```

Additional directories MAY be introduced later provided backward compatibility is preserved.

## 6.2 Runtime Metadata

```yaml
# runtime.yaml
status: READY
version: 1
core:
  status: READY
runtime:
  initialized: true
  provisioned: true
  validated: true
bootstrap:
  module: ollama
  status: READY
```

```yaml
# modules.yaml
modules:
  - name: ollama
    version: 1.0.0
    status: READY
  - name: postgres
    version: 17
    status: READY
```

These two files are the **only** supported Runtime metadata format.

## 6.3 State Model

```
NEW → INITIALIZING → BOOTSTRAPPING → PROVISIONING → VALIDATING → READY
```
Failure transitions MAY produce `ERROR`, `DEGRADED`, or `RECOVERING`. All states are persisted.

**Desired State** (capabilities expected to exist — from metadata, installed modules, user commands) is reconciled against **Actual State** (capabilities currently operational — from health checks, inspection, service discovery) by the Core; Actual State is always *observed*, never assumed.

## 6.4 Ownership, Integrity & Independence

| Resource | Owner |
|----------|-------|
| `runtime.yaml`, `modules.yaml`, `config/`, `modules/`, `garden/`, `docker-compose.yml`, `.env` | Core |

A Runtime is **consistent** when every READY module is installed and registered, metadata matches reality, required infrastructure is operational, and provisioning has fully completed — a Runtime SHALL never expose a partially provisioned capability as READY.

Once provisioned, the Runtime keeps operating independently of Garden availability, external repositories, or internet connectivity (except for capabilities that explicitly need them). Recovery — resuming provisioning, repeating validation, restarting services, updating metadata, cleaning temp artifacts — is idempotent and Core-driven.

---

# 7. Garden Architecture

Garden is the official Module Registry of the Sprout ecosystem: it publishes metadata about *available* modules without ever becoming part of the Runtime. It SHALL contain metadata only — no Runtime state, operational data, or user configuration — so the Core can discover, resolve, and install capabilities while staying independent of module implementations, and so new modules never require Core changes.

```
                Sprout Core
                      │
                      ▼
               Garden Client
                      │
                      ▼
                  Garden Index
                      │
      ┌───────────────┼───────────────┐
      ▼               ▼               ▼
   PostgreSQL      Ollama         Qdrant
```
*Garden provides information. The Core decides. Modules implement.*

*The Core SHALL NOT embed Module implementations.*

Instead, during stack generation, the Core SHALL:

1. Bootstrap the local Runtime.
2. Download the Garden index.
3. Resolve the module marked as `bootstrap`.
4. Resolve its complete dependency graph.
5. Download every required module into the local `modules/` directory.
6. Execute the lifecycle in dependency order through the Module Engine.

The Garden is therefore responsible only for module distribution.
Lifecycle execution, dependency resolution, validation and registration remain exclusive responsibilities of the Core.


## 7.1 Index, Cache & Resolution

Garden is published remotely; the Core syncs a **local cache** (`garden/index.yaml`) before operations needing resolution (install, update, search, info, dependency resolution) — enabling offline operation, determinism, and fewer network round-trips. The Runtime keeps working even when Garden is unreachable, using the cached index if available; with no metadata at all, the operation fails gracefully.

Garden must follow this reference implementation:

```
garden/
├── index.yaml
├── ollama/
│   ├── module.yaml
│   ├── compose.yml
│   └── module.sh
├── postgres/
├── openwebui/
└── ...
```

The index only needs to support discovery, version resolution, dependency resolution, and compatibility checks — implementation detail lives in each module's own definition:

```yaml
modules:
  - name: tinyllama
    version: 1.0.0
    description: Local model
    repository: https://github.com/paalbarr/sprout.git
    branch: garden
    path: tinyllama
    bootstrap: true
    depends:
      - ollama
  - name: ollama
    version: 1.0.0
    description: Local runtime
    repository: https://github.com/paalbarr/sprout.git
    branch: garden
    path: ollama
```

**Module resolution flow:** `sprout install tinyllama → Update Garden → Read index → Resolve module → Resolve dependencies → Download → Provision`. Users never touch Garden directly.

The dependencies are resolved recursively using the depends field until a complete installation graph is obtained. Dependency chains may contain any number of modules; circular dependencies are rejected.

**Versioning:** unless pinned, the Core provisions the latest compatible version; future revisions MAY add semver constraints, LTS releases, or experimental channels.

**Dependencies:** Garden describes the dependency graph, which the Core resolves *before* provisioning begins, in dependency order (e.g. `OpenWebUI → Ollama → Docker`). Circular dependencies are rejected.

## 7.2 Discovery, Independence & Trust

```bash
sprout search postgres      # queries metadata only, never downloads
sprout info postgres        # description, version, author, repo, dependencies, capabilities, compatibility
```

Garden describes what **can** be installed; the Runtime describes what **is** installed — the two stay fully independent. Garden metadata is refreshed automatically before resolution-dependent commands, but an update never modifies the Runtime, only the local cache.

The Core SHALL validate Garden metadata before use (schema validation, checksums, signatures, repository authenticity where applicable) — untrusted metadata is never executed. The architecture is intentionally open to future multi-repository, private/enterprise repository, signed-module, and mirror support without breaking this contract.

---

# 8. Module Architecture

Modules are Sprout's building blocks: each implements one or more capabilities that extend the Runtime without ever touching the Core. Core = orchestration; Modules = implementation.

## 8.1 Principles

| Principle | Meaning |
|---|---|
| **Self-Contained** | Encapsulates all logic needed to deliver its capability. |
| **Stateless** | Owns no Runtime state — that stays with the Core. |
| **Independent** | Never talks directly to another module; all cross-module orchestration goes through the Core. |
| **Deterministic** | Same lifecycle op + same conditions ⇒ same result. |
| **Idempotent** | Re-running an operation SHOULD NOT alter an already-achieved state. |

## 8.2 Structure, Manifest & Metadata

Each installed module gets its own directory (`modules/postgres/`, `modules/ollama/`, …); its internal implementation is private — the only public contract is the manifest, `module.yaml`:

```yaml
# required
name:
version:
description:
author:
license:

# optional
depends:
bootstrap
provides:
```

A module MAY expose one or more capabilities (a database, an AI provider, an MCP server, a workflow engine, a reverse proxy, …) — capabilities describe *what* it delivers; the Core decides *when* it's provisioned.

## 8.3 Lifecycle & API

Every module implements the same lifecycle and logical API:

```
Install → Configure → Provision → Register → Validate → READY
```
```
install() · configure() · provision()· register() validate()
start() · stop() · update() · remove() · doctor()
```

A module never reaches READY unless every prior phase succeeds, and is never invoked directly by users — only via `CLI → Core → Module Engine → Module` (e.g. `sprout install postgres`). Implementation language is intentionally unspecified.

**Dependencies:** resolved by the Core before any lifecycle op begins, in dependency order (`OpenWebUI → Ollama → Docker`); circular dependencies are rejected.

**Bootstrap Module:** is the unique module marked with bootstrap: true in the Garden index. The Core resolves its dependency graph and provisions every required module before executing the Bootstrap Module itself. The Bootstrap Module therefore represents the entry point of the Runtime, while remaining architecturally identical to every other module. Bootstrap is a role, not a module type.

However, every Bootstrap Module that provides local AI inference capabilities SHALL automatically provision and register one or more model providers into the OpenClaw Runtime as part of its lifecycle. A Bootstrap Module SHALL NOT transition to READY until every declared provider has been successfully registered, validated, and is available for inference.

## 8.4 Isolation, Registration & Versioning

Modules SHALL NOT inspect, modify, or assume another module's files, config, or lifecycle — shared behavior is coordinated only by the Core. After successful validation, the **Core** (never the module itself) registers it in the Runtime (name, version, lifecycle status, capabilities, timestamp). On a failed phase: provisioning stops, the module never reaches READY, metadata updates, and the failure is reported — recovery is a Core responsibility.

Modules version independently: updating a module never forces a Core update, and vice versa, as long as compatibility holds. The module contract itself stays stable; future revisions MAY add lifecycle ops or metadata fields, but breaking changes require a Specification revision.

The Register phase is responsible for integrating the capability provided by a module into the Runtime.
Registration MUST be idempotent.
A module SHALL expose every runtime endpoint, model, provider, credential or capability required by dependent components through the Runtime API.
For AI inference modules, Register SHALL automatically create or update the corresponding OpenClaw provider configuration
A module SHALL NOT transition to READY until Register completes successfully.

---

# 9. Provisioning Architecture

Provisioning is how the Core turns a declared capability into a fully operational Runtime component — an orchestration process, not a mere installation. Its guiding rule:

> **A capability is not installed until it is operational.**

## 9.1 Lifecycle Phases

```
Resolve → Install → Configure → Provision → Validate → Register → READY
```

| Phase | What happens |
|---|---|
| **Resolve** | Core resolves module metadata, dependencies, compatibility, and Runtime constraints. No Runtime changes yet. |
| **Install** | Module installs required components (Docker images, binaries, templates, resources). Must be repeatable. |
| **Configure** | Module generates config files, credentials, env vars, network config, service definitions. Must be deterministic. |
| **Provision** | Prepares the capability for production use — DB creation, storage init, model downloads, provider registration, user creation, API config, automatic onboarding. Must leave the capability operational. |
| **Validate** | Health checks, connectivity/API tests, authentication, service availability, Runtime integration — determines READY eligibility. |
| **Register** | Core records module identity, version, lifecycle state, capabilities, and provisioning metadata; the Runtime becomes the authoritative record. |

Each phase must fully succeed before the next begins; the lifecycle aborts immediately on any mandatory-phase failure.

**Worked examples:**

| Module | Provisioning includes | READY only after |
|---|---|---|
| Ollama | Install local inference runtime | runtime operational |
| Tinyllama | Download model, register provider, validate inference | inference succeeds |
| OpenAI Provider | Collect API key, register provider | authentication + model availability validated |
| PostgreSQL | Install, create DB, admin users, auth config | connectivity validated |

## 9.2 Operational Guarantees

- **Dependency ordering** is automatic (`OpenWebUI → Ollama → Docker`) — no manual management needed.
- **Atomicity:** provisioning is a single Runtime transaction; on failure the operation stops, metadata is updated, the incomplete state is recorded, and recovery stays possible. READY is never assigned to a partial capability.
- **Idempotency:** re-running the same workflow SHOULD produce the same state, without duplicating resources or corrupting config.
- **Recovery:** on restart, the Core determines completed/pending/failed phases and resumes from the right point, preserving consistency.
- **UX:** manual intervention is only expected where external info (credentials, API keys) is unavoidable — everything else (config generation, service init, onboarding, validation, registration) is automatic.

**Status states** (persisted): `PENDING → RESOLVING → INSTALLING → CONFIGURING → PROVISIONING → VALIDATING → REGISTERING → READY` (or `FAILED`).

This "provisioning ≠ installation" split is what makes Sprout's **Ready by Default** principle real: instead of pushing post-install configuration onto the user, the Runtime owns the whole operational lifecycle, improving reliability, reproducibility, and consistency.

---

# 10. Runtime State and Reconciliation

The Runtime is managed declaratively: users express intent via the CLI (`sprout install postgres`, `sprout remove qdrant`, `sprout update`); the Core continuously reconciles actual state toward that intent. This keeps the Runtime consistent, recoverable, and deterministic through interruptions, failures, or restarts — with **no manual synchronization ever required**.

Desired State (persisted: installed modules, versions, status, config metadata, infra requirements) is reconciled against Actual State (continuously observed via infra inspection, module presence, health checks) through:

```
Desired State → Observe Runtime → Detect Differences → Plan Actions → Execute Actions → Validate → READY
```

**Triggers:** Runtime startup, module install/remove/update, provisioning completion, recovery, explicit user request, or infrastructure failure (periodic reconciliation MAY come later).

**Drift** — actual ≠ desired (stopped services, missing containers, incomplete provisioning, failed health checks, missing dependencies, corrupted metadata) — is auto-detected, and the Core computes the *minimal* corrective action set (restart services, resume provisioning, rebuild config, reinstall missing pieces, update metadata, re-validate).

Recovery is simply a specialized reconciliation run — interrupted installs, unexpected shutdowns, reboots, container failures, and partial updates are all handled by driving the Runtime back to Desired State, reusing the same mechanism as normal provisioning. The Runtime SHOULD expose status, installed modules, provisioning/health status, and any pending drift through the CLI for observability.

Managing the Runtime this way — as "what should exist" rather than "how to create it" — trades scripted procedures for continuous convergence, which is what makes the platform deterministic, self-healing, and extensible.

---

# 11. Public Interfaces and Contracts

A contract defines *what* information is exchanged and *who* is responsible for what. Implementations may differ internally but SHALL preserve these contracts, letting Core, Runtime, Garden, and Modules evolve independently while staying interoperable.

| Contract | Purpose | Owner |
|----------|---------|-------|
| **CLI** | Public user interface — the only supported one. Internal implementation details are never exposed. | Core |
| **Module** | `module.yaml` manifest — the interface between Core and module (identity, version, description, author, repository; extensible without breaking compatibility). | Module |
| **Garden** | `garden/index.yaml` — enough metadata for discovery, version/dependency resolution, and compatibility, with no Runtime state exposed. | Garden |
| **Runtime** | `state/runtime.yaml` + `state/modules.yaml` — the authoritative, Core-only-writable operational record. | Core |

**Reference CLI surface:** `sprout install / remove / update / start / stop / restart / status / doctor / logs / inspect / search / info`.

**Compatibility & extensibility:** every contract is versioned; incompatible changes bump the version, get documented compatibility notes, and (where practical) a migration path. New optional metadata, lifecycle phases, CLI commands, or Runtime/Garden attributes may be added without invalidating existing implementations — unknown optional fields SHOULD be ignored, not rejected.

**Stability & conformance:** contracts evolve more slowly than implementations — internal details may change freely as long as public behavior, semantics, and interoperability hold. Consumers rely only on documented contracts, never on undocumented behavior. Conformance means implementing mandatory fields, respecting lifecycle semantics, preserving ownership boundaries, and maintaining compatibility guarantees; failing a public contract makes an implementation non-conformant.

## Final Statement

Sprout is a declarative, modular, deterministic Runtime platform. Its architecture separates orchestration from implementation, letting Core, Runtime, Garden, and Modules evolve independently while preserving a stable, predictable operational model — the contract on which every compliant implementation of Sprout is built.