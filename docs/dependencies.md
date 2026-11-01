# Dependencies and network review

The constitution's Security section says every dependency must be pinned and reviewed for network behaviour before it is added. All npm versions are exact pins in `service/package.json`, and the full tree is locked in `service/package-lock.json` (install with `npm ci`).

"Network behaviour" below means what the package does **at runtime inside the service**. None of the runtime dependencies make outbound connections on their own. The only outbound HTTP the service makes is to the two loopback `llama-server` endpoints. This is enforced by the base-URL guard (`service/src/llm/client.ts`), by the `pf`/nftables egress rules, and by the network-guard test (`service/tests/integration/network-guard.test.ts`).

## Runtime (npm)

| Package | Version | Purpose | Network behaviour |
|---------|---------|---------|-------------------|
| fastify | 5.12.7 | HTTPS server, routing, JSON-schema validation | Listens only; no outbound calls, no telemetry |
| better-sqlite3 | 13.0.3 | SQLite storage (native addon) | None. The install script (`node-gyp rebuild`) is only needed when no prebuilt binary matches |
| pino | 10.4.0 | Structured logging | Writes to local files only |
| pino-roll | 4.0.0 | Daily log rotation, keeps `logging.retentionDays` files (runs in a pino worker thread) | Local files only |
| yaml | 2.9.1 | Config parsing | None |
| ulid | 3.0.2 | Sortable ids | None |
| undici | 8.12.3 | HTTP client for the local LLM runtime | Connects only where told; our code allows loopback only |
| ajv | 8.20.0 | Validates LLM output against the JSON schema | None (schemas are local; no remote `$ref` loading) |

## Development only (never deployed)

| Package | Version | Purpose | Network behaviour |
|---------|---------|---------|-------------------|
| typescript | 5.9.3 | Compiler | None |
| tsx | 4.23.15 | Runs TS directly (dev, eval) | None. Its esbuild postinstall only verifies the local binary |
| vitest | 5.0.5 | Test runner | None (no telemetry) |
| eslint, @eslint/js, typescript-eslint, globals | 10.14.0, 10.0.1, 8.72.1, 17.13.0 | Linting | None |
| prettier | 3.9.10 | Formatting | None |
| @types/node, @types/better-sqlite3 | 24.19.2, 9.6.0 | Type definitions | None |

## External tools

| Tool | Purpose | Network behaviour / hardening |
|------|---------|-------------------------------|
| llama.cpp `llama-server` | Local inference (generation + embeddings) | No telemetry. Bound to `127.0.0.1`. Do **not** use its `-hf` / `--hf-repo` download flags in service units: models are fetched separately by `scripts/fetch-models.sh` |
| openssl / LibreSSL | Local CA and device certificates (`scripts/pki/`), test certificates | None |
| age | Backup encryption (`catrec backup` / `restore`); binary overridable with `CATREC_AGE_BIN` | None |
| tar, shasum, curl | Backup bundling; model checksums; model download (`fetch-models.sh` only) | curl: only the URLs pinned in `scripts/models.lock` |

## Models

Pinned download URLs and SHA-256 checksums live in `scripts/models.lock`, and `scripts/fetch-models.sh` reads them. That script is the only step that touches the internet. It refuses to run as `catrec`, never reads the data directory, and verifies every download against the recorded hash.

Checksums are recorded on the first `--pin` run (trust on first use) and must be reviewed against the publisher before committing. **Status 2026-10-30: all four entries are still `UNPINNED`.**
