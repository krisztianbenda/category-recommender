---

description: "Task list for Mail App over the Home Network"
---

# Tasks: Mail App over the Home Network

**Input**: Design documents from `/specs/005-mail-app-lan/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Included. The plan defines `DestinationTests`, `RecommenderTrustTests`, `LiveServiceTests` against LAN mode, the end-to-end script and two service tests, and the constitution requires the outbound-network check. Write each story's tests first and see them fail.

**Data and secrets rule (constitution II)**: Every test, fixture and example uses synthetic emails and labels, and certificates and keychains made by the test in a temporary directory. Nothing here reads a real key, certificate, config or data directory. The one real-hardware check (T042) is run by the owner.

**Organization**: Tasks are grouped by user story. All paths are relative to the repository root. `service/src/` does not change; `mail-app/`, `scripts/pki/`, `service/tests/` and the documentation do.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: The user story the task belongs to (US1–US4)

---

## Phase 1: Setup

**Purpose**: Test-made certificates that every later test uses

- [X] T001 [P] Add `mail-app/Tests/MailCoreTests/TestPKI.swift`: a helper that runs `openssl` (through `Process`) in a fresh temporary directory and makes, ECDSA P-256 and SHA-256 as `scripts/pki/` does: a CA; a server certificate from it with `subjectAltName=IP:127.0.0.1,DNS:localhost,DNS:test-mini.local` and `extendedKeyUsage=serverAuth`; a second, unrelated CA with its own server certificate for the same names; and a client certificate from the first CA. Certificates are valid for 30 days; expiry is tested by evaluating trust at a later date (T004), so nothing has to be back-dated and the commands work with both OpenSSL and macOS's LibreSSL. It returns the PEM data and DER-decoded `SecCertificate`s, and deletes the directory on `cleanup()`.
- [X] T002 [P] Extend `mail-app/Tests/stub-service.mts`: besides today's local-mode service and redirector, start a second instance of the real service in LAN mode on `127.0.0.1`, port 0, with `createTestPki()` from `service/tests/helpers/certs.ts` (`server.tls` set to its files, `access.devices` holding one device `e2e-mac` mapped to user `owner`). Issue a second client certificate `e2e-unlisted` that is not in `access.devices`. Write both client certificates as `.p12` files with `openssl pkcs12 -export -legacy` and a fixed test password into the PKI's temporary directory. Start an impostor HTTPS server on `127.0.0.1` with a certificate from a separate `createTestPki()` that counts every request it receives (`/hits` is not reachable through TLS, so expose the count on a plain HTTP side port). Add `lan`, `caFile`, `deviceP12`, `unlistedP12`, `p12Password`, `impostor` and `impostorHits` to the printed JSON line. Clean everything up on exit.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The address rule, the trust handling, the client's new error cases and the settings, which every story uses

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

### Tests for the foundation

- [X] T003 [P] Add `mail-app/Tests/MailCoreTests/DestinationTests.swift` covering every row of [research R3](./research.md#r3-which-addresses-the-app-accepts): `http` and `https` on `127.0.0.1`, `::1` and `localhost` allowed without trust; `https` on `10.1.2.3`, `172.16.0.1`, `172.31.255.255`, `192.168.1.10` and `fd12::1` allowed only with trust; `172.15.0.1`, `172.32.0.1`, `8.8.8.8`, `2001:db8::1`, `169.254.1.1` and `fe80::1` refused; `http://192.168.1.10` refused even with trust; `https://mini.local` and `https://mini.home.arpa` allowed with trust, `https://mini.example.com` and `https://mini` refused; any URL with user info refused; schemes other than `http` and `https` refused. Add resolution cases with an injected resolver: a `.local` name that resolves only to private addresses passes, one with any public address fails, and one that does not resolve fails.
- [X] T004 [P] Add `mail-app/Tests/MailCoreTests/RecommenderTrustTests.swift` using `TestPKI`: a PEM file with one certificate decodes; a PEM with no certificate or two certificates is rejected; server trust for the first CA's server certificate passes for `127.0.0.1` and `test-mini.local`; it fails for another host name, for the second CA's server certificate, and for the first CA's server certificate evaluated at a date 60 days ahead (expired).
- [X] T005 [P] Extend `mail-app/Tests/MailCoreTests/ServiceClientTests.swift`: with the existing `URLProtocol` stub, a client whose base URL is refused by `Destination` throws `ServiceError.destinationRefused` from `init` and the stub records 0 requests; a `403` answer with error code `forbidden` maps to `ServiceError.notAllowed`; every existing loopback test passes unchanged with `notLoopback` renamed to `destinationRefused`.

### Implementation of the foundation

- [X] T006 [P] Add `mail-app/Sources/MailCore/Destination.swift`: `public enum Destination` with `static func check(_ url: URL, trusted: Bool) -> Bool` implementing the table of research R3 (IPv4 ranges 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16; IPv6 fc00::/7; names ending in `.local` or `.home.arpa`; no user info; `http` only to loopback), and `static func resolvesPrivately(_ host: String, resolver: (String) -> [String]?) -> Bool` with a default resolver built on `getaddrinfo` that returns every address, so that the name passes only when it resolves and every address is loopback or in those ranges. IP literals skip resolution.
- [X] T007 [P] Add `mail-app/Sources/MailCore/RecommenderTrust.swift`: `public struct RecommenderTrust` with the owner's CA (`init(caPEM: Data) throws`, exactly one `-----BEGIN CERTIFICATE-----` block, base64 to DER, `SecCertificateCreateWithData`), `func evaluate(_ trust: SecTrust, host: String, at date: Date? = nil) -> Bool` (`SecTrustSetPolicies` with `SecPolicyCreateSSL(true, host)`, `SecTrustSetAnchorCertificates` with the CA, `SecTrustSetAnchorCertificatesOnly(true)`, `SecTrustSetVerifyDate` when a date is given, for tests only, `SecTrustEvaluateWithError`), and `func deviceIdentity(label: String) -> SecIdentity?` (a `SecItemCopyMatching` query for `kSecClassIdentity` with `kSecAttrLabel`, all matches, keeping only one whose certificate evaluates as issued by the CA with the basic X.509 policy). An optional keychain file path, used only when `CATREC_KEYCHAIN` is set, adds `kSecMatchSearchList` with that keychain opened by `SecKeychainOpen`. Nothing here copies or exports a key.
- [X] T008 Change `mail-app/Sources/MailCore/ServiceClient.swift`: rename `ServiceError.notLoopback` to `destinationRefused` and add `untrusted`, `notAllowed` and `noDeviceCertificate`; `init(baseURL:trust:deviceLabel:protocolClasses:)` checks `Destination.check(baseURL, trusted: trust != nil && deviceLabel != nil)` and every request URL the same way; replace `RefuseRedirects` with a `SessionDelegate` that refuses redirects, answers `NSURLAuthenticationMethodServerTrust` with `RecommenderTrust.evaluate` (cancelling and remembering the task as untrusted when it fails), and answers `NSURLAuthenticationMethodClientCertificate` with `URLCredential(identity:certificates:persistence: .forSession)` from `deviceIdentity(label:)`, remembering a missing identity; map errors in `send`: a task the delegate marked untrusted → `untrusted`, missing identity → `noDeviceCertificate`, `NSURLErrorClientCertificateRejected` or `NSURLErrorClientCertificateRequired` → `notAllowed`, a `403` with code `forbidden` → `notAllowed`, other transport errors → `unreachable`. Keep the ephemeral configuration, no cache, no cookies, no credential storage, empty proxy dictionary and `waitsForConnectivity = false`. Add `public var isRemote: Bool` (trust configured or base URL not loopback).
- [X] T009 Change `mail-app/Sources/CategoryRecommender/AppSettings.swift`: read `caCertificate`, `deviceCertificate` and `recommenderName` from `UserDefaults` with the overrides `CATREC_CA_FILE`, `CATREC_DEVICE_CERT` and `CATREC_KEYCHAIN` ([contracts/client-settings.md](./contracts/client-settings.md)); derive the display name ("this Mac" for loopback without a CA; otherwise `recommenderName`, or the host without `.local` with `-` replaced by spaces).
- [X] T010 Change the start-up in `mail-app/Sources/CategoryRecommender/main.swift` (around today's `ServiceClient(baseURL:)` guard): apply the three start-up rules of the settings contract, build `RecommenderTrust` from the CA file when one is set, create the client with it and the device label, and exit with status 2 and one line on stderr naming the failed rule: "Refused: the recommender's address is not on this Mac or the home network.", "A recommender on the home network needs caCertificate and deviceCertificate.", or "caCertificate is not a readable certificate file.". Rename the uses of `notLoopback` across `mail-app/Sources/`.

**Checkpoint**: `mail-app/scripts/test.sh` passes, including T003–T005, and the app still runs in local mode exactly as before.

---

## Phase 3: User Story 1 - File emails on the MacBook with the Mac mini's recommendations (Priority: P1) 🎯 MVP

**Goal**: The app on one Mac files emails with recommendations, and teaches, a recommender that runs elsewhere in LAN mode.

**Independent Test**: `mail-app/Tests/e2e.sh` runs `LiveServiceTests` and a batch drive against the LAN-mode stub service with a test device certificate, and both pass.

### Tests for User Story 1

- [X] T011 [P] [US1] Extend `mail-app/Tests/MailCoreTests/LiveServiceTests.swift`: when `CATREC_TEST_LAN_URL`, `CATREC_TEST_CA_FILE`, `CATREC_TEST_DEVICE_CERT` and `CATREC_KEYCHAIN` are set, run the same flow as the loopback live test against the LAN service: health is ready, a synthetic category set is created, a synthetic email gets a suggestion, `confirm` feedback is accepted, and `learnedEmails` for that category returns the email's sender and subject. Skip when the variables are absent, as the loopback test does.
- [X] T012 [US1] Extend `mail-app/Tests/e2e.sh`: after reading the stub's JSON, create a throwaway keychain in `$WORK` (`security create-keychain -p <test password>`, `security unlock-keychain`, `security set-keychain-settings` without a timeout, `security import <deviceP12> -k … -P <p12Password> -A`), delete it in `cleanup`, and run `test.sh --filter LiveServiceTests` again with the LAN variables of T011. Never add the keychain to the user's search list.

### Implementation for User Story 1

- [X] T013 [US1] Change `mail-app/Sources/CategoryRecommender/Backend.swift`: take `remote: Bool`; when remote, `launch` is ignored, `start()`, `stop()` and the idle timer are never used, and `ensureRunning` checks health once and rethrows its error at once, or, when health answers but is not ready, calls `onStarting` and polls as today until ready or 240 s (research R5). Wire `remote: client.isRemote` and `launch: nil` when remote in `mail-app/Sources/CategoryRecommender/main.swift`.
- [X] T014 [P] [US1] Change `mail-app/Resources/Info.plist`: add `NSLocalNetworkUsageDescription` ("Category Recommender asks the recommender on your home network, such as your Mac mini, which label fits an email. Nothing goes beyond your home network."), and change `NSAppleEventsUsageDescription`'s last sentence to "It stays on this computer, or goes to your own recommender on your home network."
- [X] T015 [US1] Extend `mail-app/Tests/e2e.sh`: run the batch drive (`--demo --batch --drive`) a second time with `CATREC_BASE_URL`, `CATREC_CA_FILE`, `CATREC_DEVICE_CERT` and `CATREC_KEYCHAIN` set for the LAN service, and check the report has no `false` and the log has no personal-looking content, as the loopback run does.

**Checkpoint**: Story 1 works end to end against a LAN-mode service with test certificates.

---

## Phase 4: User Story 2 - Email never goes anywhere but the owner's recommender (Priority: P1)

**Goal**: Every destination other than the configured, proven recommender gets nothing.

**Independent Test**: The end-to-end script shows that the impostor received 0 requests, that an unlisted device is refused, and that the running app connects only to the configured address and port.

### Tests for User Story 2

- [X] T016 [P] [US2] Extend `mail-app/Tests/MailCoreTests/LiveServiceTests.swift`: when `CATREC_TEST_IMPOSTOR_URL` is set, a client for it with the test CA throws `ServiceError.untrusted` from `health()` and from `suggest`, and afterwards the impostor's hit count (`CATREC_TEST_IMPOSTOR_HITS_URL`, plain HTTP) is 0. When `CATREC_TEST_UNLISTED_CERT` names an identity in the test keychain, a client using it throws `ServiceError.notAllowed`. When the device label names no identity, the client throws `ServiceError.noDeviceCertificate`.
- [X] T017 [US2] Extend `mail-app/Tests/e2e.sh`: import `unlistedP12` into the throwaway keychain too, pass the impostor and unlisted variables to the T016 run, and extend the socket check: run the app against the LAN service and fail if `lsof` shows any connection other than to `127.0.0.1` on the LAN service's port.

### Implementation for User Story 2

- [X] T018 [US2] In `mail-app/Sources/MailCore/ServiceClient.swift`, run `Destination.resolvesPrivately` for a host name (not an IP literal) before `health()` and before the first request of each window, on a background queue, and throw `destinationRefused` when it fails. Cache the result for 60 seconds so a batch does not resolve the name per email.
- [X] T019 [US2] Make sure `ServiceClientTests` cover T008's error mapping for a client-certificate rejection by adding a `URLProtocol` stub that fails with `NSURLErrorClientCertificateRejected`, expecting `notAllowed`, and one that fails with `NSURLErrorCannotConnectToHost`, expecting `unreachable`, in `mail-app/Tests/MailCoreTests/ServiceClientTests.swift`.

**Checkpoint**: Stories 1 and 2 together are the MVP: usable from the MacBook and safe.

---

## Phase 5: User Story 3 - Know where recommendations come from, and what happens away from home (Priority: P2)

**Goal**: The menu and the windows name the recommender, and say at once when it cannot be used; filing by hand keeps working.

**Independent Test**: With a fake backend that throws each failure cause, both windows show the matching message naming the recommender, filing by hand works, and no feedback is sent.

### Tests for User Story 3

- [X] T020 [P] [US3] Extend `mail-app/Tests/MailCoreTests/SessionTests.swift`: with `MailAdvice.recommender` set to a named recommender ("Mac mini") and a fake backend whose `ensureRunning` throws `ServiceError.unreachable`, the single window's recommendation becomes `.unavailable` with "The Mac mini can't be reached. You can still file by hand, but it won't be learned."; filing a label then files it in the fake Mail and sends no feedback. Repeat for `untrusted`, `notAllowed` and `noDeviceCertificate` with the messages of [data-model.md](./data-model.md#connection-status). With `MailAdvice.recommender` as this Mac, the existing messages are unchanged.
- [X] T021 [P] [US3] Extend `mail-app/Tests/MailCoreTests/BatchSessionTests.swift`: with the same fake backend, every row shows the unreachable message, each row can still be filed by hand, and no feedback is sent.

### Implementation for User Story 3

- [X] T022 [US3] Change `mail-app/Sources/MailCore/MailAdvice.swift`: add `public enum RecommenderPlace { case thisMac; case named(String) }` and a `public static var recommender: RecommenderPlace = .thisMac` set once at start-up by `main.swift`; phrase `describe` for `unreachable`, `untrusted`, `notAllowed`, `noDeviceCertificate`, `destinationRefused` and `llm_unavailable` with the recommender's name as in [data-model.md](./data-model.md#connection-status); keep today's texts for `.thisMac`. Add a `startingText` used for the `startingModel` state: "The recommender on <name> is starting…" when named, today's text otherwise.
- [X] T023 [US3] Use `MailAdvice.startingText` wherever the `startingModel` state is shown in `mail-app/Sources/CategoryRecommender/PanelView.swift` and `mail-app/Sources/CategoryRecommender/BatchView.swift`.
- [X] T024 [US3] Add a first, disabled menu item "Recommendations from the <name>" (or "Recommendations from this Mac") followed by a separator, in `mail-app/Sources/CategoryRecommender/AppDelegate.swift`.
- [X] T025 [US3] Log `recommender_remote` once at start-up when the client is remote, and add the cause (`unreachable`, `untrusted`, `not_allowed`, `no_device_certificate`) to the existing failure events, with no address, in `mail-app/Sources/CategoryRecommender/main.swift` and the sessions' existing log calls.

**Checkpoint**: Stories 1–3 work; the owner always sees where recommendations come from.

---

## Phase 6: User Story 4 - Set up a Mac as a client and check it (Priority: P2)

**Goal**: A repeatable setup: server certificate with the Bonjour name, an installer option, a self-test, and moving learning from local mode.

**Independent Test**: The self-test passes against the LAN stub and names the failing step for the impostor, the unlisted device and a stopped service; the PKI and migration tests pass.

### Tests for User Story 4

- [X] T026 [P] [US4] Add `service/tests/integration/pki-scripts.test.ts` (Vitest): run `scripts/pki/init-ca.sh 192.168.1.10 --dns test-mini.local --dir <tmp>` and check with `openssl x509 -noout -ext subjectAltName` that the server certificate has `IP Address:192.168.1.10`, `DNS:catrec.local` and `DNS:test-mini.local`, `serverAuth` and 825 days; run `scripts/pki/new-server-cert.sh 192.168.1.11 --dir <tmp>` and check the new names, that `server.crt.previous` exists and that `ca.crt` is unchanged; check it refuses a directory without `ca.key`, and refuses a `--dns` name with characters other than letters, digits, `-` and `.`. Everything happens in a temporary directory outside the repository.
- [X] T027 [P] [US4] Add `service/tests/integration/lan-migration.test.ts` (Vitest), following `backup.test.ts` with its fake `age`: in a local-mode app, create a synthetic category set and learn three synthetic decisions; back up; restore into a fresh data directory; start a LAN-mode app on that directory with `createTestPki()` and one device mapped to `owner`; over mTLS, check the category set and its example counts are the same, and that a suggestion for each of the three synthetic emails names the same category as before the move (SC-005).
- [X] T028 [US4] Extend `mail-app/Tests/e2e.sh`: run `CategoryRecommender --self-test-remote --out <file>` with the LAN variables and expect `"ok": true` with six `pass` steps and a `timingMs`; against the impostor expect `identity` to fail and later steps `not_run`; with the unlisted device expect `accepted` to fail; against a closed port on `127.0.0.1` expect `reachable` to fail. Check that no output contains `127.0.0.1`, `localhost`, `test-mini` or any word of the fabricated email.

### Implementation for User Story 4

- [X] T029 [US4] Add `mail-app/Sources/CategoryRecommender/RemoteSelfTest.swift` implementing [contracts/self-test-remote.md](./contracts/self-test-remote.md): the steps `address`, `reachable` (a TCP connection with `NWConnection` or `URLSession` stream within 5 s), `identity`, `accepted`, `model` and `timing` (one `POST /v1/suggestions` with a fabricated email from `DemoMail` and inline `categories`, never a category set and never feedback), stopping at the first failure; the fixed hints; local mode reported as in the contract. Add a `suggest(email:categories:)` call for inline categories to `mail-app/Sources/MailCore/ServiceClient.swift` for it. Run it from `--self-test-remote` in `mail-app/Sources/CategoryRecommender/main.swift`, writing to `--out` like the other self-tests.
- [X] T030 [P] [US4] Add `scripts/pki/new-server-cert.sh` per [contracts/pki.md](./contracts/pki.md): arguments `<lan-ip> [--dns <name>]... [--dir DIR]`, refuses without `ca.key`, validates names, keeps the old pair as `.previous`, issues the server certificate with `IP:<lan-ip>`, `DNS:catrec.local` and every `--dns` name, prints the names and the restart command.
- [X] T031 [US4] Change `scripts/pki/init-ca.sh` to create the CA as today and then call `new-server-cert.sh` with the IP, every `--dns` and `--dir`, instead of issuing the server certificate itself. Without `--dns` the output is the same as today.
- [X] T032 [P] [US4] Add `--no-local-service` to `mail-app/scripts/build-app.sh`: skip finding `node` and `llama-server` and do not write `install.json`.
- [X] T033 [US4] Add `--remote <url> --ca <pem> --device <name> [--name <label>]` to `mail-app/scripts/install.sh` per [contracts/client-settings.md](./contracts/client-settings.md#installer): require `https://` and all three of `--remote`, `--ca` and `--device` together; copy the PEM to `~/Library/Application Support/Category Recommender/recommender-ca.pem`; write the four preferences with `defaults write com.catrec.mail`; build with `--no-local-service`. Without `--remote`, `defaults delete` the four keys and remove the copy, then install as today. Never read or import a `.p12`. Print the self-test command at the end.

**Checkpoint**: All four stories work, and the owner's setup is scripted.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T034 [P] Update `docs/architecture.md` (constitution VII): the overview shows the Mail app on several Macs as clients of one service; Access modes describe the client's side of LAN mode (CA pinning, device certificate, address rule); the Mail app section and the Data table add the new preferences and the CA copy; Privacy boundaries say the Mail app sends content only to the owner's recommender on this Mac or the home network.
- [X] T035 [P] Update `docs/operations.md`: a new section "Use the Mail app from another Mac" with quickstart part 2 and its commands; `--dns` in the PKI step of "Install from scratch"; renewing the server certificate with `new-server-cert.sh` before 825 days; moving from local mode by backup and restore; energy settings; FileVault and restarts.
- [X] T036 [P] Update `mail-app/README.md`: a section "Use it on another Mac"; Privacy rewritten for the two modes ("The app only talks to the service on this Mac, or to your own recommender on your home network…"); troubleshooting rows for "can't be reached", "could not prove who it is", "does not accept this Mac", "device certificate is not installed", the Local Network prompt and the keychain prompt after a reinstall; `--self-test-remote` next to the other self-tests.
- [X] T037 [P] Update `README.md` where it says everything runs on one computer, with one line about using the Mail app from another Mac on the home network, linking to the operations guide.
- [X] T038 [P] Add a note under FR-022 in `specs/002-mail-app-integration/spec.md`: "Replaced by spec 005, FR-023: the integration may also use the owner's recommender on the home network."
- [X] T039 Run `mail-app/scripts/test.sh` and `mail-app/Tests/e2e.sh`, and fix any failure.
- [X] T040 Run `cd service && npm test && npm run lint`, and fix any failure.
- [X] T041 Run `npm run check:duplication` at the repository root and remove any duplication it reports in the new code.
- [ ] T042 Owner only, never an AI assistant: follow quickstart part 2 on the real Mac mini and MacBook, run `--self-test-remote` on each Mac, and record pass or fail (no addresses, no content) in the pull request.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: none. T001 and T002 can run in parallel.
- **Foundational (Phase 2)**: T003–T005 need T001; T006 and T007 can run in parallel; T008 needs T006 and T007; T009 then T010 need T008.
- **User stories (Phases 3–6)**: all need Phase 2. US1 (T011–T015) needs T002 for the end-to-end parts. US2 builds on US1's end-to-end setup (T012). US3 needs only Phase 2. US4's PKI and migration tests (T026, T027, T030, T031) need nothing from the other stories; its self-test (T028, T029) needs T012 and T013.
- **Polish (Phase 7)**: after the stories it documents. T039–T041 last; T042 after merge-ready.

### Within Each User Story

- Tests first, and see them fail.
- `MailCore` before the app target, the app before the end-to-end script.

### Parallel Opportunities

- T001 ∥ T002; T003 ∥ T004 ∥ T005; T006 ∥ T007.
- US3 (T020–T025) can run alongside US1 and US2 once Phase 2 is done.
- In US4, T026 ∥ T027 ∥ T030 ∥ T032, independent of the Swift work.
- T034–T038 in parallel.

## Parallel Example: User Story 4

```text
Task: "T026 service/tests/integration/pki-scripts.test.ts"
Task: "T027 service/tests/integration/lan-migration.test.ts"
Task: "T030 scripts/pki/new-server-cert.sh"
Task: "T032 mail-app/scripts/build-app.sh --no-local-service"
```

## Implementation Strategy

### MVP First (User Stories 1 and 2)

1. Phase 1 and Phase 2.
2. Phase 3 (US1) and Phase 4 (US2) together: US1 must not ship without US2's guarantees (spec, story 2).
3. Stop and validate: `e2e.sh` passes against the LAN stub, the impostor gets nothing.

### Incremental Delivery

1. MVP as above.
2. US3: the owner sees where recommendations come from and what happens away from home.
3. US4: the scripted setup and the self-test, then the owner's real check (T042).
4. Polish: documentation and the final checks.

## Implementation notes

- T018: the check is `Destination.resolvesToHomeNetwork`. A name passes when it resolves to at least one home-network address and to no public IPv4 address, because Bonjour also answers with the Mac's IPv6 link-local and global addresses ([research R3](./research.md#r3-which-addresses-the-app-accepts)).
- T020 and T021: the window tests for a named recommender are in `mail-app/Tests/MailCoreTests/RemoteMessagesTests.swift` (`RemoteWindowTests`). They name the recommender through a task-local override (`MailAdvice.$testPlace`), so they run side by side with the other window tests.
- T025: the app had no failure events to extend. When the first health check of a recommender on the home network fails, it logs `recommender_<cause>`: `unreachable`, `untrusted`, `not_allowed`, `no_device_certificate`, `refused` or `failed`. No address.
- T041: `.jscpd.json` ignores `.claude/**`, so in a worktree under `.claude/worktrees/` the check finds no files. Run it with a copy of the config without that entry.
