# Implementation Plan: Local LLM Category Recommender

**Branch**: `001-local-llm-categorizer` | **Date**: 2026-10-30 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-local-llm-categorizer/spec.md`

## Summary

The owner submits an email and candidate categories (at most two levels, for example `Family/Baby`). The system returns exactly one suggested category with a confidence level, a short reason and ranked runners-up, or proposes a new category when nothing fits. Confirmations and corrections become learning examples that make later suggestions more personal.

**Technical approach**:
- One Node.js/TypeScript service on the Mac Mini, reachable only over mutual TLS from allow-listed devices.
- Two local `llama.cpp` servers on loopback: an ~8B multilingual instruction model for classification and bge-m3 for embeddings.
- "Learning" is retrieval-augmented few-shot prompting plus a recency-weighted kNN vote over past decisions. There is no fine-tuning, so it learns instantly and deletions take effect at once.
- Data is stored in SQLite on a FileVault-encrypted volume, outside the repo.
- Outbound traffic is denied for the service user by a `pf` anchor and checked by an automated network-guard test.

Details: [research.md](./research.md).

## Technical Context

**Language/Version**: Node.js 24 LTS, TypeScript 5.x (strict). No Python or Go (see Constitution Check VI).

**Primary Dependencies**:
- Fastify (HTTPS, mTLS, JSON schema validation), `better-sqlite3`, `pino`, `yaml`, `ulid`, `undici` (LLM client)
- Ajv (validating LLM output against [llm-suggestion.schema.json](./contracts/llm-suggestion.schema.json))
- External runtime: `llama.cpp` `llama-server` (Metal)
- Tools: `openssl` (PKI), `age` (backups)

**Storage**: SQLite (WAL) at a configured path outside the repo, on a FileVault volume. SQLCipher is an option via config ([research R12](./research.md#r12-storage-and-encryption-at-rest)). Embeddings are float32 BLOBs, searched brute-force in memory.

**Testing**:
- Vitest for unit and contract tests (stub LLM)
- Integration tests with a network guard
- `npm run eval` harness against real local models with synthetic fixtures only

**Target Platform**: macOS on Apple Silicon (Mac Mini M4, 16 GB) under launchd. Linux and systemd are a documented alternative. OS-specific code (FileVault check, launchd, pf) is isolated in `service/src/platform/` and `deploy/macos/`.

**Project Type**: Single self-hosted web service (JSON API plus a small static web UI) with CLI admin commands.

**Performance Goals**: ≤ 10 s per suggestion for an email up to ~2 pages (SC-004), one request at a time (queued); kNN retrieval < 50 ms for ≤ 50k examples.

**Constraints**:
- ~7.1 GB total memory for this feature (LLM 5.0 + KV 1.2 + embeddings 0.6 + service 0.3), leaving ~9 GB for the OS.
- No outbound egress.
- No personal content in logs.
- Content is transient unless the owner gives feedback.

**Scale/Scope**: 1 user (owner), a handful of devices, roughly 10–100 suggestions per day, up to ~50k learning examples over the years, about 2 UI screens.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design (below).*

| Principle / gate | How this plan complies | Status |
|------------------|------------------------|--------|
| **I. Privacy & data locality** | All inference is on local `llama-server` instances bound to `127.0.0.1`. The LLM client only accepts loopback or allowlisted base URLs. A `pf` anchor denies egress for user `catrec`. No telemetry dependencies. Model download is a separate admin step with no data access (R1, R14). Data sources are read-only: the system never touches mailboxes (FR-018). | ✅ |
| **II. AI-assistant & secrets boundary** | The data dir and secrets live outside the repo, and startup refuses a data dir inside the repo. `.claude/settings.json` already denies `.env`, keys, `secrets/`, `credentials/` and `data/`. **Planned addition**: deny rules for `*.db`, `*.db-wal`, `*.age`, `*.p12`, `eval-report.md` and the `catrec` home dir; `.gitignore` the same. Fixtures and the eval harness are synthetic only. | ✅ (with planned tooling additions) |
| **III. Zero-trust access** | mTLS with per-device certificates plus a fingerprint allowlist (hot-reloaded, so revocation needs no redeploy). The service binds to the LAN only and is never internet-exposed. TLS is used on the LAN. All rows are scoped by `user_id` (R13). | ✅ |
| **IV. Portability** | All host values come from [config](./contracts/config.md). The runtime is reached through the OpenAI-compatible API. macOS specifics sit behind `platform/` with a Linux alternative. A backup and restore runbook is tested (R16). | ✅ |
| **V. Resource-aware simplicity** | Memory budget stated (~7.1 GB). One inference slot with a queue. One process for the app, no extra datastores or vector DB, no fine-tuning. Suggestions never modify user data. | ✅ |
| **VI. Polyglot by contract** | Node.js/TypeScript only. `llama.cpp` is an external runtime behind an HTTP contract, not project code. | ✅ |
| Security: encryption at rest | FileVault is enforced at startup; SQLCipher is an option. | ✅ |
| Security: logs | Allowlist-based redaction. Bodies, subjects, addresses and category names are never logged, and a test enforces it (R15). | ✅ |
| Security: retention and deletion | A retention table is in [data-model.md](./data-model.md#retention). Delete single, by category, or all. | ✅ |
| Security: pinned and reviewed dependencies | `package-lock.json` plus `npm ci`. Model URLs and checksums are pinned. A dependency network review is part of the tasks. | ✅ |
| Quality gate: no outbound calls check | Network-guard integration test (R14 layer 3). | ✅ |
| Privacy & security note required (touches auth, network exposure, storage) | See the section below. | ✅ |

**Result**: PASS. No violations, so Complexity Tracking stays empty.

### Privacy & Security Note

- **Data handled**: email sender, recipients, subject and body (transient); snippets ≤ 600 chars, sender, subject and embeddings for confirmed examples (persisted); category names (persisted).
- **Exposure surface**: one HTTPS port on the LAN, mTLS only. The `llama-server` ports are loopback only.
- **Threats considered**:
  - Rogue LAN device: blocked by mTLS and the allowlist.
  - Stolen disk or backup: FileVault, and backups encrypted with `age`.
  - A dependency phoning home: blocked by pf egress deny and caught by the guard test.
  - Prompt injection in an email: bounded to a wrong suggestion, mitigated by R8.
  - An AI assistant seeing data: the data lives outside the repo and deny rules apply.
- **Residual risk**:
  - The admin user on the Mac can read the data. This is accepted, since the owner is the admin.
  - Snippets are stored in clear text inside the encrypted volume. Accepted; SQLCipher is available if needed.

## Project Structure

### Documentation (this feature)

```text
specs/001-local-llm-categorizer/
├── plan.md              # This file
├── research.md          # Phase 0
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   ├── http-api.md
│   ├── config.md
│   └── llm-suggestion.schema.json
├── checklists/requirements.md
└── tasks.md             # Phase 2 (/speckit-tasks; not created here)
```

### Source Code (repository root)

```text
service/                         # the only code component (Node.js + TypeScript)
├── package.json
├── src/
│   ├── main.ts                  # bootstrap: config → platform checks → store → server
│   ├── config/                  # load + validate YAML, watch access.devices
│   ├── platform/                # OS adapters: encryption check (macOS fdesetup / Linux), paths
│   ├── security/                # mTLS fingerprint allowlist, user resolution
│   ├── api/                     # Fastify routes per contracts/http-api.md, JSON schemas
│   ├── categories/              # sets, tree rules (depth ≤ 2), normalisation, duplicate check
│   ├── suggest/                 # pipeline: truncate → embed → retrieve → prompt → LLM → validate → rank/confidence
│   ├── learning/                # examples, kNN vote with recency, decisions/accuracy stats
│   ├── llm/                     # OpenAI-compatible client (chat + embeddings), queue, base-URL guard
│   ├── store/                   # SQLite schema, migrations, repositories
│   ├── pending/                 # in-memory PendingSuggestion cache with TTL
│   ├── logging/                 # pino with allowlist redaction
│   └── cli/                     # catrec backup | restore | eval
├── web/                         # static UI: paste email, see suggestion, confirm/correct, manage sets
└── tests/
    ├── unit/
    ├── contract/                # API contract tests with stub LLM
    ├── integration/             # network guard, log redaction, mTLS
    └── eval/                    # harness runners (real local models)

fixtures/synthetic/              # fabricated emails only: reference/, novel/, injection/, habits/, examples/
deploy/
├── config.example.yaml
├── macos/                       # setup.sh, launchd plists, pf anchor
└── linux/                       # systemd units + nftables (documented alternative)
scripts/
├── fetch-models.sh              # pinned URLs + SHA-256; no data access
└── pki/                         # init-ca.sh, new-device.sh
docs/operations.md               # install, revoke device, backup/restore, migrate host
```

**Structure Decision**: A single project. There is one deployable component (`service/`), and the UI is static files served by the same process, so a separate frontend project would add complexity for no gain. `deploy/` and `scripts/` hold host-specific and one-off tooling, which keeps the service code portable.

## Complexity Tracking

No constitution violations, so nothing to justify.
