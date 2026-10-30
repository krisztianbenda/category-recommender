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
- Services that touch personal data MUST run with outbound internet egress denied by default.
  Any exception (for example a model download) MUST be explicit, documented, and carried out by
  a step that has no access to personal data.
- Dependencies, model runtimes and container images MUST be checked for phone-home behaviour,
  and that behaviour MUST be disabled before they are adopted.
- Data sources MUST be accessed read-only unless a feature explicitly needs write access and
  the owner approves it.

Rationale: privacy is the project's top priority. Anything that has left the network cannot be
pulled back.

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

### III. Zero-Trust Access

Only explicitly approved devices and users may connect to the home server.

- Every connection MUST be authenticated per device and per user against an allowlist. All
  access is denied by default.
- All traffic MUST be encrypted in transit, including traffic on the LAN.
- Services MUST NOT be exposed directly to the public internet. Remote access, if provided,
  MUST go through a private encrypted overlay (for example WireGuard) whose control plane is
  self-hosted or cannot see payload data.
- Authorization MUST be scoped per user: a family member sees only their own data unless it is
  explicitly shared.
- Revoking a device or user MUST be possible through configuration alone and MUST take effect
  without redeploying code.

Rationale: on a home server, the network boundary is the main line of defence for private data.

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

## Security & Data Handling Requirements

- Personal data and derived data at rest MUST be stored encrypted, or on encrypted volumes.
- Logs MUST NOT contain message bodies, file contents, subjects, addresses or other personal
  content. Log identifiers and metadata only.
- Every data type MUST have a defined retention policy and a way for its owner to delete it.
- Third-party dependencies MUST be pinned and reviewed for network behaviour before they are
  added.
- Secrets MUST be supplied at runtime from files or a secret store outside the repository.

## Development Workflow & Quality Gates

- Every `/speckit-plan` MUST pass a Constitution Check covering data locality, the
  assistant boundary, access control, portability and the memory budget.
- Tests and examples MUST use synthetic fixtures only. Real data MUST NOT appear in tests,
  issues, commits or prompts.
- Each component MUST include an automated check that it makes no unexpected outbound network
  calls during processing.
- Changes that touch authentication, network exposure or data storage MUST include a written
  privacy and security note in the spec or plan.

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

**Version**: 2.0.0 | **Ratified**: 2026-10-30 | **Last Amended**: 2026-10-30
