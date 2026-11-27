# Research: Mail App over the Home Network

Each decision below resolves an open point of the plan. The service side of LAN mode exists already ([`service/src/security/access.ts`](../../service/src/security/access.ts), [`scripts/pki/`](../../scripts/pki/), [`deploy/macos/`](../../deploy/macos/)); the research is about the client.

## R1. How the app decides it is talking to the owner's recommender

**Decision**: For a recommender on the home network, the app trusts exactly one certificate authority: the owner's, read from the CA certificate file named in its settings. During the TLS handshake it replaces the system's anchors with that one certificate (anchors only, no system roots), evaluates the server's chain with the SSL policy for the host it connects to, and cancels the connection if the evaluation fails. The request body is only sent after the handshake, so a server that fails gets nothing. The error is `ServiceError.untrusted`.

**Rationale**: The service already has a server certificate signed by the owner's CA, with the LAN address and a DNS name in its subject alternative names, `serverAuth` and a validity of 825 days, which is what macOS requires of TLS server certificates. Pinning the CA rather than the server certificate survives a renewal of the server certificate. Ignoring system roots means a certificate bought from a public authority for any name is worthless against the app (FR-006).

**Alternatives considered**:
- Pin the server certificate's fingerprint: breaks at every renewal, and the app would need a new setting each time.
- Install the CA as a trusted root on the Mac and use the system's evaluation: the CA would then be trusted for every app and website on the Mac, and a public authority would still be accepted for the recommender.

## R2. How the app proves which Mac is asking

**Decision**: The owner imports the device's `.p12` (made by `scripts/pki/new-device.sh`) into the login keychain by opening it. The app looks the identity up by its label, which is the device name the script puts in the `.p12`, and checks that the identity's certificate was issued by the pinned CA (R1), so another identity with the same label is never used. It answers the server's client-certificate challenge with that identity, for this session only. If there is no such identity the error is `ServiceError.noDeviceCertificate`.

**Rationale**: The private key stays in the keychain and never passes through the app's settings or files (FR-009). The service's allowlist already maps the certificate's fingerprint to the owner, and revoking a device is already a config edit (SC-006).

The app is signed ad hoc (`mail-app/scripts/build-app.sh`), so macOS ties the keychain's "Always Allow" to this build. After a rebuild or reinstall, macOS asks once more whether the app may use the key. The README says so, as it does for Mail access and Accessibility.

**Alternatives considered**:
- The app imports the `.p12` itself: it would have to ask for and handle the `.p12` password.
- A key file next to the settings: a key outside the keychain, readable by anything running as the owner.
- A shared token instead of a certificate: the service does not support it, and constitution III asks for per-device authentication with revocation by configuration, which the certificates already give.

## R3. Which addresses the app accepts

**Decision**: One pure function, `Destination.check`, decides before any request:

| Base URL | Allowed when |
|----------|--------------|
| `http://` or `https://` on `127.0.0.1`, `::1` or `localhost` | always (today's rule) |
| `https://` on an IPv4 literal in 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16, or an IPv6 literal in fc00::/7 | a CA certificate and a device certificate are set up |
| `https://` on a name ending in `.local` or `.home.arpa` | as above, and the name resolves to at least one address in those ranges and to no public IPv4 address |
| anything else, including `http://` to a private address, link-local addresses, other names, user info in the URL | never |

Names are resolved with `getaddrinfo` before the client's requests (cached for a minute), and again for the self-test. The TLS check of R1 is the guarantee; the address rule is a second wall that also catches a mistyped setting early, with a clear message.

Found while building it: Bonjour answers for a `.local` name include the Mac's IPv6 link-local address, and its global IPv6 address when the internet provider gives IPv6. A rule that every answer must be private would refuse nearly every real `.local` name. So IPv6 answers alone never fail a name, but a public IPv4 answer does. The service listens on its IPv4 LAN address only, and whichever address the system picks, R1 still has to pass.

**Rationale**: `.local` is what Bonjour gives every Mac, and `.home.arpa` is the name space reserved for home networks (RFC 8375). The private ranges are the ones the pf rules in [`deploy/macos/pf/catrec.conf`](../../deploy/macos/pf/catrec.conf) let in. Link-local addresses change and need scope ids, so they are not worth supporting.

The system resolves the name again when it connects, so in theory it could get another answer. Any server it then reaches still has to pass R1, so nothing is sent to it.

**Alternatives considered**: check the connection's remote address after the fact (`URLSessionTaskMetrics`): too late, because the request has been sent by then. Allow any name: a public DNS name would pass the rule and only R1 would stop it.

## R4. What the window says when the recommender cannot be used

**Decision**: The client maps failures to four cases, and the window's messages name the recommender ("the Mac mini" or "this Mac"):

| Cause | Error | Message (remote) |
|-------|-------|------------------|
| No connection, timeout, no route, host not found | `unreachable` | "The Mac mini can't be reached. You can still file by hand, but it won't be learned." |
| Server trust failed (R1) | `untrusted` | "The Mac mini could not prove who it is, so nothing was sent." |
| TLS refused the client certificate, or `403 forbidden` from the service | `notAllowed` | "The Mac mini does not accept this Mac. Check its device list." |
| Health answers, model not ready | (existing `startingModel`) | "The recommender on the Mac mini is starting…" |
| Device certificate not in the keychain | `noDeviceCertificate` | "This Mac's device certificate is not installed." |
| Address refused (R3) | `destinationRefused` (renamed from `notLoopback`) | "Refused: the recommender's address is not on this Mac or the home network." |

Health uses a 5 second timeout, as today, and the client does not wait for connectivity, so an unreachable Mac mini is reported within 5 seconds (FR-012, SC-003).

**Rationale**: The sessions already show `.unavailable(message)` and keep the label list, so filing by hand works with no change (FR-013). A decision made without a suggestion is already dropped: `RecommenderSession.learn` only sends feedback when a suggestion arrives, and nothing is written to disk. The batch window does the same. So FR-014 needs the message only, and no new state.

## R5. Starting and stopping the service

**Decision**: `Backend` gets a remote flag, set when a CA certificate is configured or the base URL is not loopback ([data-model.md](data-model.md#recommender-setting)). In remote mode it has no launch information, never starts or stops a process and never schedules the idle stop. `ensureRunning` checks health once: an error is thrown at once (R4); health that answers but is not ready calls `onStarting` and waits as today, up to 240 s.

**Rationale**: FR-010 and FR-015. In LAN mode launchd keeps the service and models running (`KeepAlive`), so waiting is only needed after the Mac mini restarts.

## R6. Where the app shows its recommender

**Decision**: The menu bar menu gets a first, disabled item, "Recommendations from the Mac mini" or "Recommendations from this Mac". The single and batch windows show the same words in their existing status line while a recommendation is pending or unavailable. The name comes from the setting `recommenderName`; without it, from the host (`Krisz-Mac-mini.local` becomes "Krisz Mac mini").

**Rationale**: FR-011 with the smallest change to the windows, which already have a status line.

## R7. Settings

**Decision**: The app's existing `UserDefaults` domain `com.catrec.mail` gets three keys next to the existing `baseURL`: `caCertificate` (path to a copy of the owner's CA certificate), `deviceCertificate` (the identity's label) and `recommenderName`. The installer copies the CA certificate to `~/Library/Application Support/Category Recommender/recommender-ca.pem`. Environment variables override them for tests, as `CATREC_BASE_URL` does today: `CATREC_CA_FILE`, `CATREC_DEVICE_CERT`, and, for tests only, `CATREC_KEYCHAIN` (a keychain file to search instead of the user's). Contract: [contracts/client-settings.md](contracts/client-settings.md).

**Rationale**: FR-002 and constitution IV: nothing about the host is in the code. The CA certificate is public, but it is copied rather than referenced so that moving the PKI folder on the Mac mini cannot break the MacBook.

## R8. macOS Local Network permission

**Decision**: Add `NSLocalNetworkUsageDescription` to `Resources/Info.plist`, and change `NSAppleEventsUsageDescription`, which says "Everything stays on this computer", to name the home network. The README and the self-test's hint for a failed "reachable" step point to System Settings > Privacy & Security > Local Network.

**Rationale**: Since macOS 15, an app that connects to devices on the local network needs the owner's permission, and asks once. Without the usage description the prompt has no explanation. Loopback is not affected, so local mode is unchanged.

## R9. The remote self-test

**Decision**: `--self-test-remote --out <file>` runs six steps in order and stops at the first failure, reporting later steps as `not_run`: `address` (R3), `reachable` (a TCP connection within 5 s), `identity` (R1), `accepted` (`GET /v1/health` with the device certificate returns 200), `model` (health is `ok`), `timing` (one `POST /v1/suggestions` with a fabricated email and inline fabricated `categories`, so no category set is created; the pending suggestion expires on its own and nothing is learned). The output has results, hints and the time in milliseconds only, no address and no content. Contract: [contracts/self-test-remote.md](contracts/self-test-remote.md).

**Rationale**: FR-018 and SC-004. The existing self-tests write JSON to `--out` and report pass or fail only, so the owner can share the result without sharing anything personal.

## R10. Installing a client

**Decision**: `mail-app/scripts/install.sh --remote <url> --ca <file> --device <name> [--name <label>]` writes the settings of R7 and builds the app without `install.json`, so the app has no way to start a local service. `build-app.sh` gets `--no-local-service`, which skips looking for `llama-server`, which a MacBook does not have. `install.sh` without `--remote` removes the remote settings and installs as today.

**Rationale**: FR-017. The installer stays the one documented step.

## R11. Naming the Mac mini in its certificate

**Decision**: Split the server-certificate half of `scripts/pki/init-ca.sh` into `scripts/pki/new-server-cert.sh <lan-ip> [--dns <name>]...`, which issues a server certificate from the existing CA, with the IP, `catrec.local` and every `--dns` name. `init-ca.sh` creates the CA and calls it, and passes `--dns` through. The owner gives the Mac mini's Bonjour name (System Settings > General > Sharing > Local hostname).

**Rationale**: FR-019 and story 4, scenario 4: with the Bonjour name in the certificate the MacBook can use `https://<name>.local:8443` and survive a new DHCP address. The same script renews the server certificate before its 825 days run out, without re-issuing any device.

**Alternatives considered**: a DHCP reservation on the router only. It still works (the IP stays in the certificate), and the operations guide mentions it, but it depends on the router.

## R12. The Mac mini's own app

**Decision**: In LAN mode the service listens on the LAN address only, so the Mac mini's app is set up like the MacBook's, with its own device certificate (`new-device.sh mac-mini`) and the same URL. A connection to its own LAN address goes over the loopback interface, and the pf rules let it in because the source address is in the LAN range. The egress block applies to the `catrec` user only, not to the owner's app.

**Rationale**: FR-020. Constitution III says every connection is authenticated once the service listens beyond loopback, so a second, unauthenticated loopback listener is not an option.

## R13. Moving the learning from local mode

**Decision**: Use the existing `catrec backup` in local mode (with `backup.ageRecipient` set in `~/.catrec/config.yaml`) and `catrec restore` into the LAN install's data directory, as the operations guide already describes for a new host. Rows are scoped by user, local mode's user is `owner`, and `new-device.sh` maps every device to `owner`, so nothing needs rewriting. An integration test checks this on synthetic data (SC-005).

## R14. Testing without real certificates or a real network

**Decision**:
- **Swift unit tests**: `Destination.check` for every row of R3; PEM parsing; trust evaluation (R1) against certificates the test makes with `openssl` in a temporary directory (a good chain, another CA, an expired certificate, a wrong name); the error mapping of R4.
- **End to end** (`mail-app/Tests/e2e.sh`, CI on macOS): `stub-service.mts` also starts the real service in LAN mode on `127.0.0.1` with a throwaway PKI from `service/tests/helpers/certs.ts`, and an impostor HTTPS server with a certificate from another CA. The script imports the test device `.p12` into a throwaway keychain file (`security create-keychain`, `security import -A`) that the app searches through `CATREC_KEYCHAIN`. It runs `LiveServiceTests` against the LAN service, the remote self-test (all pass), the self-test against the impostor (`identity` fails) and with an unlisted device (`accepted` fails), and checks that the running app connects only to the configured address.
- **Service**: a test for `new-server-cert.sh` (the SANs it writes), and the migration test of R13.

`https://127.0.0.1` exercises R1 and R2 for real. The private-address rows of R3 are covered by the unit tests, because CI has no stable LAN address.

**Rationale**: constitution II and FR-025: only certificates made for the test, only synthetic emails, nothing in the user's own keychain.

## R15. Logs

**Decision**: The app's event log gets `recommender_remote` at start-up (no address), and the existing failure events carry the cause from R4 (`unreachable`, `untrusted`, `not_allowed`). The service's logging does not change.
