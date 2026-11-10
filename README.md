# Category Recommender

A private, local email category recommender for a home server (Mac Mini M4, 16 GB). You paste an email and your categories (up to two levels, for example `Family/Baby`). It suggests one category, or proposes a new one, using a local LLM. When you usually delete emails like it, it suggests deleting it instead. It learns from your confirmations, corrections and deletions. Nothing leaves your network.

**Quick start on this Mac** (local mode, http://127.0.0.1:8080/):

```bash
scripts/fetch-models.sh
```

```bash
scripts/run-local.sh
```

**From macOS Mail**, to get a label recommendation for the selected Gmail email and file it in two actions:

```bash
mail-app/scripts/install.sh
```

See [`mail-app/README.md`](mail-app/README.md).

- **Spec, plan and design**: [`specs/001-local-llm-categorizer/`](specs/001-local-llm-categorizer/spec.md), [`specs/002-mail-app-integration/`](specs/002-mail-app-integration/plan.md)
- **Install and operate**: [`docs/operations.md`](docs/operations.md)
- **Service code**: [`service/`](service/), Node.js + TypeScript. Run `npm ci && npm test` there.
- **Mail app code**: [`mail-app/`](mail-app/), Swift. Run `scripts/test.sh` there.
- **Project rules**: [`.specify/memory/constitution.md`](.specify/memory/constitution.md). Privacy comes first: real data never goes into this repository or to an AI assistant.
