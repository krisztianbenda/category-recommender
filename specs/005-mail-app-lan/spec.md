# Feature Specification: Mail App over the Home Network

**Feature Branch**: `005-mail-app-lan`

**Created**: 2026-11-27

**Status**: Draft

**Input**: User description: "Use the mail-app from another Mac on the home network (LAN mode client). The owner wants to use the Category Recommender mail-app on a MacBook while the recommender service and the local LLM run on the Mac mini at home. The service's LAN mode already exists (HTTPS with mutual TLS, per-device certificate fingerprint allowlist, pf firewall and egress rules, PKI scripts, launchd units). The mail-app today only talks to 127.0.0.1 (spec 002 FR-022) and cannot present a device certificate. This feature lets the mail-app connect to a recommender on the home network: plain HTTP stays loopback-only; HTTPS to a private LAN address is allowed only when the server's certificate chains to the owner's own CA (system roots ignored) and the app presents its device certificate from the Keychain; public addresses, redirects and proxies stay refused. With a remote service the app never starts or stops the service, shows where recommendations come from (this Mac or the Mac mini) and says clearly when the Mac mini cannot be reached; filing by hand still works while offline, but decisions made offline are not learned and are never queued to disk. A remote self-test reports pass/fail only (reachable, private address, server cert from the owner's CA, device accepted, model ready, timing). The installer can configure a remote service and leave out the local auto-start. The server certificate can carry the Mac mini's Bonjour name so the MacBook need not rely on a fixed IP. The Mac mini's own mail-app also connects with a device certificate when the service is in LAN mode. Learned data moves from local mode to the LAN install by backup and restore, keeping the same owner. Steps that touch keys, certificates or real data are done by the owner, never by an AI assistant. Out of scope: access from outside the home network (would need WireGuard), unloading the model when idle in LAN mode, several users."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - File emails on the MacBook with the Mac mini's recommendations (Priority: P1)

The recommender and its model run on the Mac mini at home. The owner reads email on the MacBook, selects one or more emails in Mail and triggers the recommender exactly as on the Mac mini: the shortcut, the menu bar icon or Mail's Services menu. The window opens with the account's labels, and the recommendations arrive from the Mac mini. Filing works as today, and each decision teaches the recommender on the Mac mini, so what the owner files on one Mac improves the recommendations on the other.

**Why this priority**: This is the feature. The MacBook has no model of its own, or not enough memory for one, so without this the owner can only sort email while sitting at the Mac mini.

**Independent Test**: Run the service in LAN mode with a stub model and certificates made for the test, set up the app as a client of it with a test device certificate, select synthetic emails in demo mode, and check that each recommendation comes from that service, that filing works, and that the decision is learned there.

**Acceptance Scenarios**:

1. **Given** the Mac mini runs the recommender in LAN mode and the MacBook is set up as its client, **When** the owner triggers the recommender on the MacBook with one email selected, **Then** the window opens with the labels at once and shows the Mac mini's recommendation when it is ready.
2. **Given** the same setup, **When** the owner selects several emails, **Then** the batch window works as it does on the Mac mini, with a recommendation for each email.
3. **Given** the owner files an email on the MacBook, **When** a similar email later arrives and is recommended on either Mac, **Then** the recommendation takes that decision into account.
4. **Given** the owner creates, renames, moves or deletes a label on the MacBook, **Then** the learning follows the label on the Mac mini as it does today on one Mac.
5. **Given** the recommender suggests moving an email to the Trash, **Then** it does so on the evidence of the owner's own behaviour from both Macs, and the MacBook's Trash is read only as today.

---

### User Story 2 - Email never goes anywhere but the owner's recommender (Priority: P1)

Whatever the network does, the app sends email content only to the recommender the owner set up: the one on this Mac, or the one on the Mac mini that proves who it is with the owner's own certificate. A device on the Wi-Fi that pretends to be the Mac mini, a public address, a redirect, a proxy or a captive portal gets nothing.

**Why this priority**: Privacy is the project's first principle. Opening the app to the network without this would trade it for convenience, so Story 1 must not ship without it.

**Independent Test**: With test certificates, point the app at a server whose certificate comes from another authority, at a public address, at plain HTTP on a private address, and at a server that redirects, and check that each is refused before any email content is sent. Check that a device certificate the service does not list is refused, and that the app says so.

**Acceptance Scenarios**:

1. **Given** the app is set up for the Mac mini, **When** a server at that address presents a certificate not issued by the owner's certificate authority, **Then** the app sends nothing to it and says the recommender could not prove who it is.
2. **Given** the configured address is a public internet address, or a name that resolves to one, **Then** the app refuses it and sends nothing.
3. **Given** the configured address is on the home network but unencrypted, **Then** the app refuses it. Unencrypted connections are only allowed to this Mac itself.
4. **Given** the recommender answers with a redirect, or the system has a proxy set, **Then** the app follows no redirect and uses no proxy.
5. **Given** the owner has removed the MacBook from the recommender's device list, **When** the owner triggers the recommender on the MacBook, **Then** the app says this Mac is not allowed, no recommendation is made, and nothing is learned.
6. **Given** a Mac that is not set up for the home network, **Then** the app behaves exactly as today and talks only to the service on this Mac.

---

### User Story 3 - Know where recommendations come from, and what happens away from home (Priority: P2)

The window and the menu say where the recommendations come from: this Mac, or the Mac mini. When the MacBook is away from home, or the Mac mini is asleep, the window says the Mac mini cannot be reached, right away. The owner can still file emails by hand, and the window says those decisions will not be learned. The app never starts a service on the MacBook, and never falls back to anything else.

**Why this priority**: Without it the owner would wait for a recommendation that cannot come, or wonder whether email went somewhere unexpected. The main value is already in Stories 1 and 2, so it follows them.

**Independent Test**: Set up the app as a client of a test service, stop the service, trigger the recommender, and check that the window says the recommender cannot be reached within a few seconds, that filing by hand works, that nothing is learned or written to disk for later, and that no service was started on this Mac.

**Acceptance Scenarios**:

1. **Given** the app is set up for the Mac mini, **When** the owner opens the window or the menu, **Then** it names the Mac mini as the source of recommendations. On a Mac set up for itself, it says this Mac.
2. **Given** the Mac mini cannot be reached, **When** the owner triggers the recommender, **Then** the window says so within 5 seconds, in plain words, and lists the labels so the owner can file by hand.
3. **Given** the owner files or deletes an email while the Mac mini cannot be reached, **Then** the email is filed or deleted as chosen, the window says the decision will not be learned, and nothing about it is kept for later.
4. **Given** the Mac mini is reachable but its model is still loading, **Then** the window says the recommender on the Mac mini is starting, and the recommendation appears when it is ready.
5. **Given** the app is set up for the Mac mini, **Then** it never starts, stops or installs a service on this Mac, and never asks another recommender or service instead.
6. **Given** the Mac mini becomes reachable again, **When** the owner triggers the recommender, **Then** recommendations work again without restarting the app.

---

### User Story 4 - Set up a Mac as a client and check it (Priority: P2)

Once the Mac mini runs the recommender in LAN mode, the owner sets up the MacBook in a few documented steps: make a device certificate for it on the Mac mini, install it on the MacBook, and install the app with the Mac mini's address. A self-test then checks the connection and reports pass or fail for each step, without any email content. The Mac mini's own app is set up the same way, with a device certificate of its own.

**Why this priority**: It turns a hand-made configuration into something the owner can repeat for a new Mac or after a reinstall. It is needed for the feature to be practical, but Stories 1 to 3 can be tested with a test configuration before it exists.

**Independent Test**: On a test machine, run the installer for a home-network recommender against a test service, run the self-test, and check that every step passes. Then break each step on purpose (stopped service, wrong authority, unlisted device, public address) and check that the self-test names the step that failed.

**Acceptance Scenarios**:

1. **Given** the owner runs the installer with the Mac mini's address and the owner's certificate authority, **Then** the app is set up for that recommender and the local service is not set up to start on this Mac.
2. **Given** the app is set up, **When** the owner runs the self-test, **Then** it reports pass or fail for each of: the recommender is reachable, its address is on the home network, it proved its identity with the owner's certificate authority, this Mac was accepted, the model is ready, and how long one recommendation of a fabricated email took.
3. **Given** a step fails, **Then** the self-test says which step failed and what to check, and the later steps are reported as not run.
4. **Given** the Mac mini's address on the home network changes, **When** the server certificate also names the Mac mini by its local network name and the app uses that name, **Then** the app keeps working without reconfiguration.
5. **Given** the Mac mini runs the recommender in LAN mode, **When** the owner uses the app on the Mac mini itself, **Then** it connects with the Mac mini's own device certificate and works as on the MacBook.
6. **Given** the owner already uses the recommender in local mode on the Mac mini, **When** they move to the LAN install by the documented backup and restore, **Then** everything learned is kept, and recommendations for the same email are the same as before the move.

### Edge Cases

- **The MacBook is on another network** (a café, the office): the Mac mini cannot be reached, and the app says so. It makes no connection to anything else.
- **The Mac mini is asleep or off**: as above. Waking it is up to the owner's energy settings, and the documentation says which ones.
- **The Mac mini's local network name resolves to a public address**, for example on a network that answers every name: the app refuses it, as for any public address.
- **The server certificate has expired, or names another host**: the app refuses it and says the recommender could not prove who it is.
- **The device certificate is missing, has expired or was revoked**: the recommender refuses the Mac, and the app says this Mac is not allowed and what to check.
- **macOS asks whether the app may use the device certificate**: the owner allows it once. After a reinstall macOS may ask again, as it does for Mail access, and the documentation says so.
- **Two Macs ask at the same time**: the Mac mini handles their requests one after another, as it does for one Mac's batch. Each window waits for its own recommendations.
- **The connection drops during a batch**: rows that already have a recommendation keep it, the others say the recommender cannot be reached, and every row can still be decided by hand. Decisions already sent are learned, later ones are not.
- **The connection drops after filing but before the decision is learned**: the email stays filed, and its row notes the decision was not learned, as today.
- **A suggestion is answered after the Mac mini restarted**: the Mac mini no longer holds it, so the decision is not learned, and the window says so, as today when a suggestion expires.
- **Both a home-network setting and a service on this Mac exist**: the setting decides. The app talks to one recommender only.
- **The owner switches a Mac back to local mode**: the app talks to this Mac's service again, and starts it on demand as today.
- **Label sync on the MacBook while the Mac mini's app also syncs the same account**: both work on the same category set for the account, as two windows on one Mac do today.
- **The web UI on the MacBook**: it already works through a browser with the device certificate installed, and this feature does not change it.

## Requirements *(mandatory)*

### Functional Requirements

**Choosing the recommender**

- **FR-001**: Each Mac's app MUST use exactly one recommender: the service on this Mac (the default, as today) or one recommender on the home network, as set up at install.
- **FR-002**: The address of the recommender, the owner's certificate authority and the name of this Mac's device certificate MUST come from settings written at install. None of them may be built into the app.

**Where content may go**

- **FR-003**: The app MUST send requests only to the configured recommender, and MUST refuse every other destination before sending anything.
- **FR-004**: Unencrypted connections MUST be used only with this Mac itself.
- **FR-005**: A recommender on the home network MUST be reached over an encrypted connection, at an address in the private ranges used by home networks, or at a local network name whose address is in those ranges. Any other address MUST be refused, including when a name resolves to it.
- **FR-006**: The app MUST trust a recommender on the home network only when its certificate was issued by the owner's own certificate authority and names the address the app connects to. Authorities the operating system trusts for websites MUST NOT be enough.
- **FR-007**: The app MUST identify itself to a recommender on the home network with this Mac's own device certificate, so that the recommender can refuse Macs that are not on its device list.
- **FR-008**: The app MUST follow no redirects, use no proxy, and keep no cache, cookies or stored credentials of the connection, whichever recommender it uses.
- **FR-009**: The private key of a device certificate MUST stay in the Mac's own secure store. The app MUST NOT copy it into its settings, logs or any file.

**With a recommender on the home network**

- **FR-010**: The app MUST NOT start, stop or install any service on this Mac.
- **FR-011**: The window and the menu MUST show where recommendations come from: this Mac, or the recommender on the home network by a name the owner recognises.
- **FR-012**: When the recommender cannot be used, the window MUST say so within 5 seconds of opening, and say which of these it is: it cannot be reached, it could not prove who it is, this Mac is not allowed, or it is starting.
- **FR-013**: While the recommender cannot be reached, the owner MUST still be able to file emails, create labels and move emails to the Trash by hand.
- **FR-014**: A decision made while the recommender cannot be reached MUST NOT be learned later, and nothing about it MUST be kept, on disk or in memory, after the window closes. The window MUST say the decision will not be learned.
- **FR-015**: The app MUST NOT fall back to another recommender or service when the configured one cannot be used.
- **FR-016**: Everything else MUST work as with the service on this Mac: one email, several emails, deleting, creating and syncing labels, and learning.

**Setting up**

- **FR-017**: The installer MUST be able to set up the app for a recommender on the home network, without setting up the local service to start on this Mac.
- **FR-018**: A self-test MUST report, as pass, fail or not run, each of: the recommender is reachable, its address is on the home network, it proved its identity with the owner's certificate authority, this Mac was accepted, the model is ready, and how long one recommendation of a fabricated email with fabricated labels took. Its output MUST contain no email content, labels or addresses of people.
- **FR-019**: The recommender's server certificate MUST be able to name the host by its local network name as well as by its address.
- **FR-020**: The app on the Mac that runs the recommender in LAN mode MUST be able to use it the same way, with that Mac's own device certificate.
- **FR-021**: Moving from local mode to the LAN install MUST keep everything learned and the owner it belongs to, through the documented backup and restore.
- **FR-022**: Every step that creates, installs or reads keys and certificates, or touches real data, MUST be documented as a step the owner does. Tools and documentation MUST NOT need an AI assistant to see them (constitution, Principle II).

**Privacy**

- **FR-023**: This replaces spec 002's FR-022. Email content, labels and recommendations MUST NOT leave the owner's home network through the integration. They go only to the configured recommender, on this Mac or on the home network.
- **FR-024**: Logs MUST contain identifiers, counts and which kind of recommender was used only, never email content, subjects, email addresses or label names.
- **FR-025**: Development and automated checks MUST use synthetic emails and labels, and certificates made for the test only.

### Key Entities

- **Recommender setting**: which recommender a Mac's app uses. Either this Mac, or one on the home network with its address, the owner's certificate authority and the name of this Mac's device certificate. Written at install and kept with the app's preferences. It holds no key.
- **Owner's certificate authority**: the owner's own authority that issues the recommender's server certificate and each Mac's device certificate. It is the only authority the app trusts for a recommender on the home network.
- **Device certificate**: proves which Mac is asking. Its private key stays in that Mac's secure store, and the recommender keeps a list of the devices it accepts, each mapped to the owner.
- **Connection status**: what the window and the menu show: this Mac, the recommender on the home network, starting, cannot be reached, could not prove who it is, or this Mac is not allowed.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On the MacBook at home, with the model loaded on the Mac mini, the first recommendation appears within 15 seconds, as on the Mac mini itself (spec 004, SC-004).
- **SC-002**: In tests, the app sends no email content to any destination other than the configured recommender, including when it is offered a server with another authority's certificate, a public address, unencrypted access on the home network, a redirect or a system proxy: 0 requests with content reach any of them.
- **SC-003**: When the recommender cannot be reached, the window says so within 5 seconds of opening, and filing an email by hand takes the same number of owner actions as today.
- **SC-004**: Once the Mac mini runs the LAN install, setting up another Mac as its client takes the owner at most 6 documented steps, and the self-test passes on the first run when they are followed.
- **SC-005**: After moving from local mode to the LAN install, recommendations on the synthetic reference set are the same as before the move, given the same learned data.
- **SC-006**: A Mac removed from the recommender's device list gets no further recommendations from its next request on, without restarting the recommender.
- **SC-007**: On a Mac set up for itself, the app behaves exactly as before: the existing tests pass unchanged, and it connects only to this Mac.

## Assumptions

- One owner with several Macs on the same home network. Every device certificate maps to the owner, so learning is shared between the Macs. Several users are out of scope.
- The Mac mini runs the hardened LAN install from the operations guide: a separate service account, device certificates, firewall rules that let only the home network in and nothing owned by the service out, and the model kept loaded at all times (about 5.6 GB of its 16 GB). Unloading the model when idle in LAN mode is out of scope.
- The service's LAN mode (encryption, the device list, revocation by configuration, the firewall rules) exists and is reused. On the service side this feature changes only how the server certificate names the host, and the documentation.
- Mail and its accounts stay on each Mac. The Mac mini never connects to the owner's mail accounts, and the app on each Mac reads and files email in that Mac's Mail only.
- The home network uses the private address ranges (for IPv4 10.0.0.0/8, 172.16.0.0/12 and 192.168.0.0/16, and the IPv6 unique local range). Access from outside the home network is out of scope; the constitution (Principle III) would require a private encrypted overlay such as WireGuard for it.
- Keeping the Mac mini awake, or letting it wake for network access, is up to the owner's energy settings. With FileVault on, the recommender is down after a restart until someone logs in at the Mac mini.
- The owner installs each device certificate in that Mac's own secure store. macOS may ask once whether the app may use it, and again after a reinstall.
- This replaces spec 002's assumption that the integration is used from one computer only. Spec 002's other rules stay as they are.
- Automatic filing without the owner's action stays out of scope (constitution, Principle V).
