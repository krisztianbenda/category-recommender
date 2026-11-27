# Implementation Plan: Mail App over the Home Network

**Branch**: `005-mail-app-lan` | **Date**: 2026-11-27 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/005-mail-app-lan/spec.md`

## Summary

The Mail app can use a recommender on the home network instead of the service on its own Mac. The service side exists: LAN mode serves HTTPS with mutual TLS, accepts only the devices in its allowlist, and the hardened install keeps the models loaded behind pf rules. The client gains what it lacks. It trusts only the owner's CA for a remote recommender, presents this Mac's device certificate from the keychain, and accepts only loopback or private home-network addresses. With a remote recommender it never starts or stops a service, names the recommender in the menu and the windows, and says at once when it cannot be reached; filing by hand keeps working and nothing is learned or kept for later. A remote self-test, an installer option and a server-certificate script with the Mac mini's Bonjour name complete the setup. The service's code, its HTTP contract and the web UI do not change.

## Technical Context

**Language/Version**: Swift 6.3 toolchain in Swift 5 language mode (`mail-app/`), Bash (install and PKI scripts), TypeScript on Node.js 24 (test harness only). Unchanged.

**Primary Dependencies**: None new. Foundation's `URLSession` and the Security framework (`SecTrust`, `SecIdentity`, keychain queries) for the client; `openssl` for the PKI scripts and tests, as today.

**Storage**: Three more Mail app preferences in `UserDefaults` and one copy of the owner's CA certificate (public) in `~/Library/Application Support/Category Recommender/`. No key outside the keychain. Nothing new in the service's database.

**Testing**: Swift Testing (new `DestinationTests`, `RecommenderTrustTests`; `LiveServiceTests` also against LAN mode), `mail-app/Tests/e2e.sh` with a throwaway PKI and keychain, Vitest for the PKI script and the local-to-LAN migration in `service/tests/integration/`. All synthetic.

**Target Platform**: macOS 14 or later. Server: the reference Mac mini M4 with 16 GB running the hardened LAN install. Clients: any Mac on the same home network, including the Mac mini.

**Project Type**: Desktop client of the existing HTTP API, plus deployment scripts.

**Performance Goals**: First recommendation within 15 s on the MacBook with the model loaded (SC-001). "Can't be reached" within 5 s (SC-003). The network adds milliseconds; the model's time dominates.

**Constraints**: Content only to the configured recommender (FR-003). Encrypted connections only, except to loopback (FR-004). Only the owner's CA, never system roots (FR-006). Private key stays in the keychain (FR-009). No email content on disk or in logs. One model request at a time on the Mac mini, shared by every Mac.

**Scale/Scope**: One owner, a handful of Macs, one recommender.

No open questions remain: [research.md](research.md) resolves each one. Two findings need a check on real hardware, through the owner's self-test: the Local Network prompt (R8), and the keychain prompt after a rebuild (R2).

## Constitution Check

*Checked before research and again after the design. Both pass.*

| Principle | Status | How |
|-----------|--------|-----|
| I. Privacy and data locality | Pass | Content goes only to the owner's recommender, on this Mac or on hardware the owner controls on the home network, over TLS, after the server proves it holds a certificate from the owner's CA. Public addresses, redirects and proxies are refused. FR-023 replaces spec 002's "this computer only" with "the owner's home network only", which is what the principle asks. |
| I. Read-only data sources | Pass, unchanged | The writes to Mail are the ones approved in 002, 003 and 004, on an owner's action. |
| II. Assistant boundary | Pass | Real PKI, `.p12` files, the config and the backup are the owner's steps (quickstart part 2). Tests make throwaway certificates and a throwaway keychain, and use synthetic emails. The self-test output has no address, certificate field or content. |
| III. Staged access control | Pass | LAN mode already authenticates every device against a deny-by-default allowlist, encrypts, and revokes by configuration. The client adds the other half: it authenticates the server. Nothing is exposed to the internet; access from outside the home network stays out of scope, as the principle requires an overlay for it. |
| IV. Portability | Pass | Address, CA and device name are settings written by the installer. The PKI scripts take the host's address and names as arguments. |
| V. Simplicity and memory | Pass | No new service, datastore or protocol. The Mac mini's memory is the hardened install's: both models loaded at all times, about 7 GB of 16 GB. Requests from several Macs share the existing one-at-a-time queue. |
| V. No automatic changes | Pass, unchanged | Nothing is filed or deleted without an owner action. |
| VI. Polyglot by contract | Pass | No new language. The client and the service still share only the HTTP contract. |
| VII. Living documentation | Pass | `docs/architecture.md`, `docs/operations.md`, `mail-app/README.md` and `README.md` are updated in this change (see Documentation). |
| Logs | Pass | Kind of recommender and failure causes only, no address (research R15). |
| Quality gate: outbound check | Pass | Unit tests for the address rule; `e2e.sh` checks that the app connects only to the configured address, and that an impostor gets nothing. |

### Privacy note

Today the app sends email text to `127.0.0.1` only. With this feature, a Mac set up for the Mac mini sends the same requests (the email's sender, subject and text, the Trash's senders and subjects, the account's labels, and the owner's decisions) to the Mac mini over the home network. They are encrypted, and only sent after the Mac mini has proved it holds a certificate from the owner's CA. The Mac mini keeps what the service keeps today. Nothing goes beyond the home network: off it, the app cannot reach the Mac mini and sends nothing anywhere else.

## Key decisions

Details and alternatives are in [research.md](research.md).

| Topic | Decision | Research |
|-------|----------|----------|
| Trusting the recommender | The owner's CA as the only anchor, SSL policy for the host, cancel on failure | R1 |
| Proving the Mac | The `.p12` in the login keychain, found by label and checked against the CA | R2 |
| Addresses | Loopback; or HTTPS to private IPv4, IPv6 ULA, `.local` or `.home.arpa` that resolve to those | R3 |
| Messages | Four failure causes, each naming the recommender; label list stays usable | R4 |
| Service start and stop | Never, when remote | R5 |
| Where it shows | A menu item and the windows' status line | R6 |
| Settings | Three new `UserDefaults` keys, environment overrides for tests | R7, [contract](contracts/client-settings.md) |
| macOS permission | `NSLocalNetworkUsageDescription` | R8 |
| Self-test | Six steps, pass, fail or not run, no content | R9, [contract](contracts/self-test-remote.md) |
| Installer | `--remote --ca --device --name`, no local service | R10, [contract](contracts/client-settings.md#installer) |
| Server certificate | `new-server-cert.sh` with `--dns` names, used by `init-ca.sh` | R11, [contract](contracts/pki.md) |
| The Mac mini's own app | Its own device certificate, same URL | R12 |
| Learning from local mode | Existing backup and restore, same user `owner` | R13 |
| Tests | Throwaway PKI and keychain; LAN mode on `https://127.0.0.1` | R14 |

## Project Structure

### Documentation (this feature)

```text
specs/005-mail-app-lan/
├── spec.md
├── plan.md                    this file
├── research.md                R1–R15
├── data-model.md              settings, trust material, connection status, self-test report
├── quickstart.md              synthetic checks and the owner's setup
├── contracts/
│   ├── client-settings.md     preferences, overrides, installer options
│   ├── self-test-remote.md    the self-test's output
│   └── pki.md                 new-server-cert.sh and init-ca.sh
├── checklists/requirements.md
└── tasks.md                   /speckit-tasks
```

### Source Code (repository root)

```text
mail-app/
├── Resources/Info.plist                         NSLocalNetworkUsageDescription, Apple Events text
├── Sources/MailCore/
│   ├── Destination.swift                        new: the address rule (R3)
│   ├── RecommenderTrust.swift                   new: CA from PEM, server trust, device identity (R1, R2)
│   ├── ServiceClient.swift                      uses Destination and RecommenderTrust; new error cases
│   └── MailAdvice.swift                         messages that name the recommender (R4)
├── Sources/CategoryRecommender/
│   ├── AppSettings.swift                        new keys and overrides (R7)
│   ├── Backend.swift                            remote mode: never start or stop (R5)
│   ├── AppDelegate.swift                        "Recommendations from …" menu item (R6)
│   ├── RemoteSelfTest.swift                     new: --self-test-remote (R9)
│   └── main.swift                               wiring, start-up checks
├── Tests/MailCoreTests/
│   ├── DestinationTests.swift                   new
│   ├── RecommenderTrustTests.swift              new, with test-made certificates
│   └── LiveServiceTests.swift                   also against LAN mode
├── Tests/stub-service.mts                       also LAN mode with a throwaway PKI, and an impostor
├── Tests/e2e.sh                                 throwaway keychain, remote self-test, socket check
└── scripts/install.sh, build-app.sh             --remote, --no-local-service (R10)

scripts/pki/
├── new-server-cert.sh                           new (R11)
└── init-ca.sh                                   CA, then new-server-cert.sh

service/tests/
└── integration/
    ├── pki-scripts.test.ts                      new: names in the server certificate
    └── lan-migration.test.ts                    new: local-mode backup restored for a LAN-mode device

docs/architecture.md, docs/operations.md, mail-app/README.md, README.md
```

**Structure Decision**: The existing two components. The client changes stay in `mail-app/`, split so that the address rule and the trust handling are small files in `MailCore` that can be tested without UI. The service's source does not change; only its scripts and tests do.

## Documentation

| File | Change |
|------|--------|
| `docs/architecture.md` | Overview: the Mail app on several Macs as clients of one service, local or LAN mode. Access modes: the client's side of LAN mode. Mail app: the address rule and trust. Privacy boundaries: "on the home network" for the Mail app |
| `docs/operations.md` | New section "Use the Mail app from another Mac" (quickstart part 2 with commands), `new-server-cert.sh` and `--dns` in the PKI step, renewing the server certificate, energy settings, FileVault and restarts |
| `mail-app/README.md` | New section "Use it on another Mac", Privacy rewritten for the two modes, troubleshooting rows for each failure cause, the Local Network and keychain prompts, `--self-test-remote` |
| `README.md` | If it says everything runs on one Mac, add the home-network option in one line |

## Complexity Tracking

No violations to justify.
