# Category Recommender

A private, local email category recommender for a home server (Mac Mini M4, 16 GB). You paste an email and your categories (up to two levels, for example `Family/Baby`). It suggests one category, or proposes a new one, using a local LLM. It learns from your confirmations and corrections. Nothing leaves your network.

- **Spec, plan and design**: [`specs/001-local-llm-categorizer/`](specs/001-local-llm-categorizer/spec.md)
- **Install and operate**: [`docs/operations.md`](docs/operations.md)
- **Service code**: [`service/`](service/), Node.js + TypeScript. Run `npm ci && npm test` there.
- **Project rules**: [`.specify/memory/constitution.md`](.specify/memory/constitution.md). Privacy comes first: real data never goes into this repository or to an AI assistant.
