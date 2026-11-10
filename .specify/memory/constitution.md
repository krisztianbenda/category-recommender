<!--
Sync Impact Report
- Version: 3.0.0 → 3.1.0 (MINOR: new principle and expanded workflow gates)
- Added: Principle VII. Living Documentation
- Changed: Development Workflow & Quality Gates (documentation gate, no personal content in commits)
- Removed: none
- Templates: .specify/templates/tasks-template.md ✅ updated; plan-template.md ✅ no change
  needed (gates are derived from this file); spec-template.md ✅ no change needed
- Docs: README.md ✅ rewritten; docs/architecture.md ✅ added; LICENSE ✅ added (MIT)
- Approved by the owner on 2026-11-10
-->

# Category Recommender Constitution

## Core Principles

### I. Privacy & Data Locality (NON-NEGOTIABLE)

The system processes personal data (emails, files and any future data types) for one household.
That data, and every category, label, embedding, summary or other value derived from it, MUST
stay on hardware the owner controls.

- Personal data and derived data MUST NOT be sent to any third-party service: no cloud LLM
  or embedding APIs, no SaaS, no telemetry, analytics or crash reporting, and no remote logging.
- All inference MUST run on local LLMs and models served by a runtime under the owner's control
  on the home network.
- Model downloads and other internet-facing setup steps MUST be separate from, and have no
  access to, personal data.
- Telemetry, analytics and update checks in dependencies, model runtimes and container images
  MUST be turned off when they are known about. A full phone-home audit and OS-level egress
  denial are deferred hardening (see below).
- Data sources MUST be accessed read-only unless a feature explicitly needs write access and
  the owner approves it.

Rationale: privacy is the project's top priority. Anything that has left the network cannot be
pulled back. This principle is about never sharing data; defence-in-depth against a breach is
added in stages (see Deferred Hardening).

### II. AI-Assistant & Secrets Boundary (NON-NEGOTIABLE)

Development assistants such as Claude Code count as third parties under Principle I.

- AI assistants MUST NOT read, receive or process real personal data, real categories or
  recommendations, production databases, logs that contain personal content, or model outputs
  produced from real data.
- AI assistants MUST NOT read secrets: `.env` files, credentials, keys, certificates, tokens or
  any secret store. Secrets MUST live outside tracked source. Only placeholder examples
  (`*.example`) may be committed.
- Real data and secrets MUST NOT be stored inside the repository working tree. Runtime data
  directories MUST be configured paths outside the repo.
- Development, tests and debugging with an assistant MUST use synthetic or fabricated fixtures
  only.
- These rules MUST be enforced by tooling (assistant permission deny rules, `.gitignore`,
  directory layout), not only by convention.

Rationale: the codebase is developed with AI help, but the data it handles must never reach
that help.

### III. Staged Access Control

Access rules scale with how far the service is exposed. The project starts in local mode and
adds controls only when it is reached from more places.

- **Local mode** (the default): the service binds to a loopback address only and serves a
  single owner. Per-device authentication and TLS are not required. It MUST reject requests
  whose `Host` is not a loopback name (DNS-rebinding guard).
- **LAN mode**: before the service listens on anything other than loopback, every connection
  MUST be authenticated per device against an allowlist that denies by default, traffic MUST be
  encrypted in transit, and revocation MUST work through configuration alone.
- Services MUST NOT be exposed directly to the public internet in any mode. Remote access, if
  ever provided, MUST go through a private encrypted overlay (for example WireGuard).
- Data MUST be scoped by user in the data model from the start, so that adding family members
  later does not need a migration of existing rows.

Rationale: a single owner on one machine does not need zero-trust networking yet, but opening
the service to the network without it would expose private data.

### IV. Portability Through Configuration

Replacing the home server, or adding or removing a device, MUST need only reconfiguration and
data migration, never code changes.

- Host-specific values (paths, addresses, ports, model names, enrolled devices) MUST come from
  configuration. They MUST NOT be hard-coded.
- Deployment MUST be reproducible from the repository plus a configuration bundle plus secrets,
  using scripted or containerized setup.
- The LLM runtime MUST be reached through an abstraction (a local HTTP API such as an
  OpenAI-compatible endpoint), so that models and runtimes can be swapped.
- OS- or hardware-specific code (for example macOS or Apple Silicon) MUST be isolated behind an
  interface with a documented alternative.
- Backup, restore and migration to a new host MUST be documented and tested.

Rationale: the Mac Mini is today's host, not a permanent dependency.

### V. Resource-Aware Simplicity

The reference host is a 16 GB Mac Mini that serves both the application and local LLMs.

- Model choices and concurrency MUST fit within the host's memory, with headroom for the OS and
  services. Plans MUST state the expected memory footprint.
- Prefer single-node, batch or queued processing over always-on parallel inference.
- Start with the simplest design that works: YAGNI applies. New services, datastores or
  infrastructure MUST be justified in the plan's complexity tracking.
- Recommendations are suggestions. The system MUST NOT move, delete or modify user data
  automatically without explicit user confirmation.

Rationale: limited hardware and a single maintainer reward small, understandable systems.

### VI. Polyglot by Contract

Node.js (TypeScript recommended) is the default language for all components. Python or Go MAY be
used for a component only where performance or the ecosystem clearly justifies it, for example
CPU-heavy parsing, ML or embedding tooling, or a long-running high-throughput worker.

- Adopting Python or Go for a component MUST be justified in that feature's plan, with the
  performance or capability reason. A measurement or benchmark against a Node.js baseline is
  preferred.
- Components MUST communicate over explicit, versioned contracts (HTTP/JSON, gRPC or a
  documented file format). They MUST NOT share internal code across languages.
- Each component MUST be buildable, testable and runnable on its own.
- Each language in use MUST follow its standard tooling for formatting, linting, dependency
  pinning and tests.
- A new language or framework MUST be recorded in the plan with its purpose.

Rationale: one default stack keeps the system simple and is the owner's learning focus. Clear
boundaries let a faster language be dropped in later where it pays off.

### VII. Living Documentation

The repository is public. Its documentation MUST describe the code as it is, in the same change
that alters it.

- `README.md` MUST say what the project is and how to install and use it. A change to
  prerequisites, install steps, commands, default paths or user-visible behaviour MUST update
  it in the same change.
- `docs/architecture.md` MUST describe the components, their contracts, the suggestion and
  learning flow, and where data is stored. A change that adds, removes, renames or moves a
  component, a contract or a data store MUST update it in the same change.
- `LICENSE` MUST be present and MUST match the licence named in `README.md` and in package
  metadata.
- Documentation MUST follow Principle II: examples use synthetic data only, and never real
  labels, folders, addresses or learned data.
- A change is not complete until these documents are accurate. Plans and task lists MUST
  include the documentation updates the feature needs.

Rationale: other people can now read, install and build on the project. Documentation that
lags behind the code misleads them, and it is cheapest to fix while the change is fresh.

## Security & Data Handling Requirements

- Logs MUST NOT contain message bodies, file contents, subjects, addresses or other personal
  content. Log identifiers and metadata only.
- Every data type MUST have a defined retention policy and a way for its owner to delete it.
- Third-party dependencies MUST be pinned.
- Secrets MUST be supplied at runtime from files or a secret store outside the repository.
- Personal data at rest SHOULD sit on an encrypted volume (for example FileVault). This is
  recommended, not enforced, until the hardening below is taken on.

## Deferred Hardening

The following are intentionally not required yet. Each one becomes a MUST through a MINOR
amendment when the owner decides it is needed, and LAN mode (Principle III) requires the access
items before it is enabled.

- OS-level outbound egress denial for services that touch personal data (for example `pf` or
  `nftables` rules and a dedicated service user).
- A reviewed network-behaviour audit of every dependency before it is added.
- Enforced encryption at rest (startup checks, database-level encryption) and encrypted backups.
- mTLS or equivalent per-device authentication, and TLS on the LAN (already required for LAN
  mode).

Existing implementations of these items MAY stay in the repository and MAY be used, but plans
are not required to provide them.

## Development Workflow & Quality Gates

- Every `/speckit-plan` MUST pass a Constitution Check covering data locality, the
  assistant boundary, the access mode in use, portability, the memory budget and the
  documentation to update.
- Every change MUST leave `README.md`, `docs/architecture.md` and `LICENSE` accurate
  (Principle VII). Reviews MUST check this.
- Everything committed is published. Personal content (real labels, folders, addresses,
  learned data, configuration with personal values) MUST NOT be committed.
- Tests and examples MUST use synthetic fixtures only. Real data MUST NOT appear in tests,
  issues, commits or prompts.
- Each component MUST include an automated check that it makes no unexpected outbound network
  calls during processing.
- Changes that expose the service beyond loopback, add a new place where personal data is
  stored, or add a component that talks to the network MUST include a short privacy note in
  the spec or plan.

## Governance

This constitution supersedes other project practices. Principles I and II cannot be weakened by
any spec, plan or task. Amending them requires a MAJOR version bump and the owner's explicit
approval.

- Amendments: proposed through `/speckit-constitution`, with a Sync Impact Report and an
  approval by the owner.
- Versioning: MAJOR for removing or redefining principles, MINOR for added or materially
  expanded guidance, PATCH for clarifications.
- Compliance: every spec, plan, task list and review MUST check conformance. Violations MUST be
  fixed or justified in the plan's complexity tracking. Violations of Principles I and II cannot
  be justified.

**Version**: 3.1.0 | **Ratified**: 2026-10-30 | **Last Amended**: 2026-11-10
