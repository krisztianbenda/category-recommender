# Quickstart & Validation Guide: Local LLM Category Recommender

This guide proves the feature works end to end on the home server. It uses **synthetic fixtures only** (constitution Principle II): never paste real emails while an AI assistant is involved.

Contracts: [http-api.md](./contracts/http-api.md), [config.md](./contracts/config.md), [llm-suggestion.schema.json](./contracts/llm-suggestion.schema.json). Data: [data-model.md](./data-model.md).

## Prerequisites

- Mac Mini (Apple Silicon, 16 GB), macOS with **FileVault on** (`fdesetup status`).
- Node.js 24 LTS, `llama.cpp` (`llama-server`), `openssl`, `age`.
- A dedicated non-admin macOS user `catrec` (created by `deploy/macos/setup.sh`).
- About 7 GB of free disk space for the models.

## 1. One-time setup (admin user)

```bash
scripts/fetch-models.sh            # downloads pinned GGUF files and verifies SHA-256; never touches the data dir
```

```bash
scripts/pki/init-ca.sh             # local CA + server certificate, written outside the repo
```

```bash
scripts/pki/new-device.sh krisz-macbook   # client cert (.p12) + prints its fingerprint
```

```bash
deploy/macos/setup.sh              # creates user catrec, data dir, launchd units, pf egress anchor
```

Copy `deploy/config.example.yaml` to the path in `CATREC_CONFIG`, fill in the LAN address and the device fingerprint, and import the `.p12` into the device's keychain.

Expected: `launchctl list | grep catrec` shows three running services, and `curl --cert ... https://<lan-ip>:8443/v1/health` returns `"status":"ok"`.

## 2. Automated checks (development machine, no models needed)

```bash
cd service && npm ci && npm test
```

This covers unit tests, contract tests against the [HTTP API](./contracts/http-api.md) with a stub LLM, and the **network guard** test (the full suggest → feedback flow must make no outbound connection other than the configured local runtime). It also runs the log redaction test.

## 3. Scenario validation (home server, real local models, synthetic data)

| # | Scenario | How | Expected |
|---|----------|-----|----------|
| V1 | Family vs Gadgets (US1-1, US1-2) | `POST /v1/suggestions` with `fixtures/synthetic/examples/dad-lunch.json`, then `apple-launch.json`, categories `["Family","Gadgets","Finance"]` | `Family`, then `Gadgets` |
| V2 | Subcategory preferred (US1-3) | `newborn-checkup.json` with `["Family","Family/Baby","Gadgets"]` | `Family/Baby` |
| V3 | New subcategory proposed (US1-4) | `new-trip-booking.json` with `["Travelling","Travelling/TripXYZ","Family"]` | `isNew: true`, parent `Travelling`, confidence `low` |
| V4 | Depth limit (FR-002) | candidates include `Family/Baby/Clothes` | `400 invalid_request` |
| V5 | Learning (US2-4) | `npm run eval -- --suite habits` | after 3 corrections Shop → `Finance`, the next shop receipt is suggested `Finance` |
| V6 | Accept new category (US2-3) | feedback `accept_new` on V3 | category appears in `GET /v1/category-sets/{default}` |
| V7 | Rename keeps learning (US3-2) | rename `Gadgets` → `Tech`, then `GET /v1/learning-examples?categoryId=` | same examples, path `Tech` |
| V8 | Delete (US4, SC-007) | `DELETE /v1/learning-examples/{id}`, then repeat its suggestion | the example is gone and the kNN contribution no longer appears |
| V9 | Prompt injection (FR-019) | `npm run eval -- --suite injection` | no suggestion follows embedded instructions |
| V10 | Unknown device (FR-015) | call with a certificate whose fingerprint is not in the allowlist, then remove a listed device | rejected; the removed device is rejected within seconds, without a restart |
| V11 | No egress (SC-006) | while running `npm run eval`, check `sudo pfctl -a catrec -vvsr` counters and `nettop -p <pids>` | zero outbound connections to non-local addresses |
| V12 | Expired suggestion (R7) | restart the service, then send feedback for an old `suggestionId` | `410 suggestion_expired` |

## 4. Quality targets (evaluation harness)

```bash
npm run eval -- --suite reference,novel,habits --report ../eval-report.md
```

Pass criteria:

- **reference**: top-1 accuracy ≥ 80% (SC-001)
- **novel**: new-category proposal rate ≥ 80% and sensible ≥ 70% (SC-001a)
- **habits**: acceptance ≥ 90% after 200 decisions, and last-100 > first-100 (SC-002, SC-003)
- **latency**: p95 ≤ 10 s for emails up to ~2 pages (SC-004)
- **memory**: peak total RSS of the three processes ≤ 8 GB (SC-008)

If latency fails, switch `llm.model` to the 4B fallback in config and re-run (research R9).

## 5. Backup & restore drill (FR-021)

```bash
catrec backup ~/catrec-backup.age
```

```bash
catrec restore ~/catrec-backup.age     # on a fresh data dir or a new host
```

Expected: the category sets, examples and accuracy stats are identical after the restore.
