# Architecture

How the category recommender is put together: its components, how a suggestion is made, how it learns, and where data lives. For the reasons behind each decision, see the plans under [`specs/`](../specs/). For running it, see [`operations.md`](operations.md).

This document is kept current with the code (constitution, Principle VII). A change that adds, removes or moves a component, a contract or a place where data is stored updates it in the same change.

## Overview

In local mode everything runs on one computer and talks over loopback only.

```text
 Browser (web UI)        macOS Mail
        │                    ▲
        │                    │ Apple Events (JXA via osascript)
        │              ┌─────┴──────────┐
        │              │   mail-app     │  Swift menu bar app
        │              └─────┬──────────┘
        │ HTTP/JSON          │ HTTP/JSON
        ▼                    ▼
 ┌───────────────────────────────────────┐
 │  service  (Node.js + TypeScript)      │  127.0.0.1:8080
 │  API · suggestion pipeline · learning │
 └──────┬───────────────┬────────────┬───┘
        │ chat          │ embeddings │
        ▼               ▼            ▼
  llama-server     llama-server    SQLite
  LLM  :8081       bge-m3 :8082    ~/.catrec/data
```

| Component | Where | Language | Role |
|-----------|-------|----------|------|
| Service | [`service/`](../service/) | Node.js 24, TypeScript | JSON API, static web UI, suggestion pipeline, learning, storage, admin CLI |
| Mail app | [`mail-app/`](../mail-app/) | Swift, JavaScript for Automation | Menu bar client: reads the selected email and the account's labels from Mail, asks the service, files or trashes the email |
| Model servers | external (`llama.cpp`) | n/a | Two `llama-server` processes: an instruction model for classification and bge-m3 for embeddings |
| Deployment | [`deploy/`](../deploy/), [`scripts/`](../scripts/) | Bash, config | Local-mode runner, model download, and the optional hardened LAN setup (launchd or systemd, firewall rules, PKI) |

In LAN mode the service and the models still run on one computer, the Mac mini. The Mail app can also run on the owner's other Macs and use it over the home network, through HTTPS with mutual TLS. The email goes from that Mac to the Mac mini, and nowhere else:

```text
 MacBook                                      Mac mini
 ┌──────────────┐  HTTPS, mutual TLS         ┌──────────────────────────────┐
 │ macOS Mail   │  home network only         │ service :8443 (LAN mode)     │
 │ mail-app ────┼───────────────────────────▶│ llama-server ×2 · SQLite     │
 └──────────────┘  owner's CA, device cert   │ macOS Mail · mail-app        │
                                             └──────────────────────────────┘
```

The components share no code. They communicate over documented contracts:

- Service HTTP API: [`specs/001-local-llm-categorizer/contracts/http-api.md`](../specs/001-local-llm-categorizer/contracts/http-api.md)
- Configuration file: [`specs/001-local-llm-categorizer/contracts/config.md`](../specs/001-local-llm-categorizer/contracts/config.md)
- Model output: [`specs/001-local-llm-categorizer/contracts/llm-suggestion.schema.json`](../specs/001-local-llm-categorizer/contracts/llm-suggestion.schema.json)
- Model runtime: the OpenAI-compatible chat and embeddings endpoints of `llama-server`, so models and runtimes can be swapped through configuration.

## Service

One process serves the API and the static web UI. Its layout under `service/src/`:

| Directory | Responsibility |
|-----------|----------------|
| `main.ts`, `app.ts`, `context.ts` | Start-up: config, platform checks, store, server |
| `config/` | Loads and validates the YAML config, watches the device allowlist |
| `api/` | Fastify server, routes and JSON schemas for the HTTP contract |
| `security/` | Local mode (loopback and `Host` guard) and LAN mode (mTLS fingerprint allowlist) |
| `categories/` | Category sets, the two-level path rules, normalisation |
| `suggest/` | The suggestion pipeline, including the deletion decision |
| `learning/` | Learning examples, the in-memory index, kNN vote, feedback, accuracy statistics |
| `llm/` | OpenAI-compatible client for chat and embeddings, a serial queue, the base-URL guard |
| `pending/` | In-memory cache of suggestions that await feedback, with a time limit |
| `store/` | SQLite schema, migrations and repositories |
| `logging/` | `pino` with allowlist-based redaction |
| `platform/` | OS-specific checks (macOS, Linux) behind one interface |
| `cli/` | `catrec backup` and `catrec restore` |

`service/web/` holds the static UI (plain HTML, CSS and JavaScript modules, no build step). `service/tests/` holds unit, contract and integration tests that run against a stub model, end-to-end tests that start the built service and replay a synthetic session against it, plus the `eval` harness that runs against the real local models with synthetic fixtures.

### How a suggestion is made

`POST /v1/suggestions` runs the pipeline in [`service/src/suggest/pipeline.ts`](../service/src/suggest/pipeline.ts). Nothing in it writes to disk.

1. **Candidates**: the categories come with the request or from a stored category set.
2. **Truncate**: the email is cut to the configured token budget.
3. **Embed**: the embedding server turns the email into a vector.
4. **Retrieve**: a recency-weighted nearest-neighbour search over the owner's past decisions finds similar emails and how they were filed or deleted.
5. **Prompt**: the candidates and the nearest past decisions (as few-shot examples) go to the LLM. The email is passed as data, and the prompt tells the model not to follow instructions in it.
6. **Validate**: the model's JSON answer is checked against the schema and the candidates. A proposed new category that duplicates an existing one is mapped to it, and an unusable answer is given low confidence.
7. **Confidence and ranking**: confidence is computed in code from the model's answer and how far the past decisions agree with it. A strong habit in past decisions overrides the model.
8. **Deletion**: decided in code, never by the model (see below).
9. **Pending cache**: the suggestion is kept in memory until the owner answers or it expires.

Inference runs one request at a time through a queue, to fit the memory of the reference host.

### How it learns

There is no fine-tuning. `POST /v1/suggestions/{id}/feedback` stores the owner's answer (confirm, correct or delete) as a learning example: sender, subject, a snippet of at most 600 characters, the embedding and the chosen category. Later suggestions retrieve these examples, so learning takes effect at once, and deleting an example removes its influence at once.

Each answer is also recorded as a decision without content, for the accuracy statistics.

### Suggesting deletion

A suggestion has an action: `file` or `delete`. [`service/src/suggest/deletion.ts`](../service/src/suggest/deletion.ts) suggests deleting from two kinds of evidence, both the owner's own behaviour:

- learned deletions among the email's nearest past decisions;
- emails in the Trash from the same sender with a similar subject, which the client sends with the request. The service compares them and keeps nothing.

The thresholds are configuration (`learning.deletion`). Design: [`specs/003-delete-suggestion/plan.md`](../specs/003-delete-suggestion/plan.md).

## Mail app

A menu bar app with no third-party dependencies, in two targets:

| Target | Responsibility |
|--------|----------------|
| `Sources/MailCore/` | No UI: label and folder mapping, syncing them to a category set per account (following labels that were moved or renamed), the HTTP client for the service, and the session state: `RecommenderSession` for one email, `BatchSession` for several. Both use `LabelPicker` (the label list), `Learning` (decisions to feedback) and `MailAdvice` (what the window says) |
| `Sources/CategoryRecommender/` | The app: menu bar item, floating window, hot key, running the Mail bridge, starting and stopping the service on demand |

`Resources/mail-bridge.js` is the only code that touches Mail. It is JavaScript for Automation run through `osascript`: it reads the selected email, lists mailboxes, files an email, moves one to the Trash with Mail's own commands, and counts which mailboxes hold given emails. Input is passed as data, never spliced into a script.

The app is a client of the service's HTTP API and holds no learned data of its own.

### Using a recommender on another Mac

By default the app talks to the service on its own Mac over loopback, and starts and stops it on demand. Set up for a recommender on the home network, it connects to that one over HTTPS instead and never starts or stops a service. `ServiceClient` then does three checks before any content leaves the Mac:

- **Address** (`Destination`): plain HTTP only to loopback. HTTPS only to a private address (10/8, 172.16/12, 192.168/16, fc00::/7) or a `.local` or `.home.arpa` name, and a name must resolve to the home network and to no public IPv4 address. Everything else, redirects and proxies are refused before a request is made.
- **Server** (`RecommenderTrust`): the server's certificate must chain to the owner's own CA and name the host. The authorities macOS trusts for websites do not count.
- **This Mac**: it proves itself with its device certificate from the keychain, which the owner's CA must have issued. The key stays in the keychain.

The window and the menu say where recommendations come from ("Recommendations from Mac mini") and say so plainly when it can't be reached. Filing by hand still works then, but is not learned, and nothing is queued. `--self-test-remote` reports pass or fail for each step of the connection. Design: [`specs/005-mail-app-lan/plan.md`](../specs/005-mail-app-lan/plan.md), the settings in [`specs/005-mail-app-lan/contracts/client-settings.md`](../specs/005-mail-app-lan/contracts/client-settings.md).

Mail does not report that a label was moved or renamed: the old label is gone and a new one appears. Each sync pairs them on evidence (same name in a new place, a renamed parent's children, or the new label holding emails learned for the old one) and renames or moves the category in place, so its learning stays. Design: the Sync section of [`specs/002-mail-app-integration/plan.md`](../specs/002-mail-app-integration/plan.md).

### Several emails at once

With more than one email selected, the window lists them and recommends for each separately, through the same `POST /v1/suggestions`, one request at a time. The bridge opens a batch with each email's sender and subject only, so the list appears at once, and reads the emails' text five at a time in the background. The Trash is read once for every sender in the batch. Labelling acts on each email by its id. Mail's Archive and Delete act on Mail's selection, so the bridge first selects exactly the emails of the owner's action, reads the selection back, and clicks the command only if it matches. Each decision is learned for its own email. Design: [`specs/004-batch-recommendations/plan.md`](../specs/004-batch-recommendations/plan.md), and the bridge's batch commands in [`specs/004-batch-recommendations/contracts/mail-bridge.md`](../specs/004-batch-recommendations/contracts/mail-bridge.md).

## Data

| Data | Where | Kept |
|------|-------|------|
| Email being classified | Service memory | Until the suggestion is answered or expires |
| Emails of a batch (up to 50) | Mail app memory | While the window is open, or until their decision is learned |
| Learning examples: sender, subject, snippet, embedding, category | SQLite in the data directory | Until the owner deletes them |
| Categories and category sets | SQLite | Until the owner deletes them |
| Decisions (no content) | SQLite | See the retention table in the data model |
| Trashed emails' senders and subjects | Service memory | For the duration of one request |
| Learned emails' senders and subjects, to find a renamed label | Mail app memory | For one sync, only when a label with learned decisions is gone |
| Logs | Data and log directories | Identifiers and counts only, rotated |
| Preferences of the Mail app, including which recommender to use (`baseURL`, `caCertificate`, `deviceCertificate`, `recommenderName`) | `UserDefaults` | Until uninstall |
| Copy of the owner's CA certificate (public), on a Mac that uses a recommender on the home network | `~/Library/Application Support/Category Recommender/` | Until uninstall |
| That Mac's device certificate and key | The owner's login keychain, imported by the owner | Until the owner removes it |

The data directory is a configured path outside the repository (`~/.catrec/data` in local mode), and the service refuses to start with a data directory inside it. All rows are scoped by user. The full model is in [`specs/001-local-llm-categorizer/data-model.md`](../specs/001-local-llm-categorizer/data-model.md).

## Access modes

- **Local mode** (default): plain HTTP on `127.0.0.1` for one owner. Requests whose `Host` is not a loopback name are rejected.
- **LAN mode** (optional, built): HTTPS with mutual TLS and a per-device fingerprint allowlist that is reloaded on change. `deploy/` holds the service definitions and firewall rules, and `scripts/pki/` creates the certificates. The server certificate names the Mac mini's address and its Bonjour names (`init-ca.sh --dns`, `new-server-cert.sh`).
- **The Mail app in LAN mode**: on every Mac, the Mac mini included, the app trusts only the owner's CA for the server, presents its own device certificate, and accepts only addresses on the home network (see [Using a recommender on another Mac](#using-a-recommender-on-another-mac)). Removing a device from the allowlist cuts that Mac off.

The service is never exposed to the internet in either mode.

## Privacy boundaries

These follow from the [constitution](../.specify/memory/constitution.md) and shape the structure above:

- All inference is local. The LLM client only accepts loopback or allowlisted base URLs, and an integration test fails on any unexpected outbound connection.
- Downloading models (`scripts/fetch-models.sh`) is the only step that uses the internet, and it has no access to the data.
- Real emails, labels, folders and learned data never enter the repository. Tests, the demo mode of the Mail app and the evaluation use the fabricated emails in [`fixtures/synthetic/`](../fixtures/synthetic/README.md).
- The Mail app sends email content only to the owner's recommender: the service on its own Mac, or the owner's service on the home network after it proved itself with the owner's CA. Never to any other address.
- Logs never contain email content, subjects, addresses or category names.

## Repository layout

```text
service/            the recommender service and web UI
mail-app/           the macOS Mail menu bar app
fixtures/synthetic/ fabricated emails for tests and evaluation
deploy/             config examples, launchd and systemd units, firewall rules
scripts/            run-local.sh, fetch-models.sh, PKI helpers, the commit message check
docs/               architecture, operations, dependencies
specs/              spec, plan, contracts and tasks per feature
.specify/           Spec Kit templates and the constitution
.github/workflows/  CI: tests, end-to-end tests, duplication and pull request title checks
.githooks/          the commit-msg hook (git config core.hooksPath .githooks)
package.json        repository-wide checks (commit messages, code duplication), not a component
```
