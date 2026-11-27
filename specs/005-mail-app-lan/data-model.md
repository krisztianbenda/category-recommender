# Data Model: Mail App over the Home Network

Nothing new is stored by the service. The Mail app stores three more preferences. Everything else is held in memory for one connection or one self-test.

## Recommender setting

What one Mac's app connects to. Read once at start-up from `UserDefaults` (`com.catrec.mail`), with environment overrides for tests ([contracts/client-settings.md](contracts/client-settings.md)).

| Field | Source key | Rules |
|-------|------------|-------|
| `baseURL` | `baseURL` / `CATREC_BASE_URL` | Default `http://127.0.0.1:8080`. Must pass `Destination.check` (research R3), or the app refuses to start, as today |
| `caCertificate` | `caCertificate` / `CATREC_CA_FILE` | Path to a PEM file with one certificate. Required when `baseURL` is not loopback. Read at start-up; a missing or unreadable file is a start-up error that names the setting |
| `deviceCertificate` | `deviceCertificate` / `CATREC_DEVICE_CERT` | Label of the identity in the keychain. Required when `baseURL` is not loopback. Never a key or a path to one |
| `recommenderName` | `recommenderName` | Optional. Shown in the menu and the windows. Default: the host name without `.local`, with `-` as spaces; "this Mac" for loopback |

Derived:

- **Kind**: `local` when `baseURL` is loopback and no CA is set, `remote` otherwise. `Backend` never starts or stops a service when remote (research R5).
- A loopback `https://` URL with a CA and a device certificate is `remote` too: this is what the end-to-end test uses, and it behaves exactly like a Mac mini on the LAN apart from the address.

## Trust material (in memory)

| Item | Held as | Lifetime |
|------|---------|----------|
| Owner's CA | One certificate, decoded from the PEM file | App lifetime |
| Device identity | A reference to the keychain identity, found by label and checked to be issued by the CA | Looked up for each TLS handshake. The key itself never leaves the keychain |

## Connection status

What the menu and the windows show. Computed from the last health check and the last request's error.

```text
              health ok
   ┌──────────────────────────────┐
   ▼                              │
 ready ──request fails──▶ unreachable | untrusted | notAllowed | noDeviceCertificate
   ▲                              │
   │        health answers,       │ next window opens:
   │        model not ready       │ health is checked again
   └──────── starting ◀───────────┘
```

| State | Window | Learning |
|-------|--------|----------|
| `ready` | Recommendation as today | As today |
| `starting` | "The recommender on <name> is starting…" | Decisions made now are learned when the recommendation arrives, as today |
| `unreachable` | "<name> can't be reached. You can still file by hand, but it won't be learned." | None. Nothing is kept for later |
| `untrusted` | "<name> could not prove who it is, so nothing was sent." | None |
| `notAllowed` | "<name> does not accept this Mac. Check its device list." | None |
| `noDeviceCertificate` | "This Mac's device certificate is not installed." | None |

No state is persisted. Each window starts with a fresh health check, so the app recovers by itself when the Mac mini is back (story 3, scenario 6).

## Self-test report

Written by `--self-test-remote` to the `--out` file. Format: [contracts/self-test-remote.md](contracts/self-test-remote.md).

| Field | Meaning |
|-------|---------|
| `ok` | Every step passed |
| `steps[]` | `{ name, result, hint? }` in a fixed order: `address`, `reachable`, `identity`, `accepted`, `model`, `timing` |
| `result` | `pass`, `fail` or `not_run` (after a failure) |
| `hint` | A fixed sentence for a failed step. Never an address, a certificate field or any content |
| `timingMs` | Duration of the `timing` step, when it ran |

## Service side

No change. The device allowlist (`access.devices`) already maps each device's certificate fingerprint to a user, and every device of this feature maps to `owner`, the user of local mode, so learning moved by backup and restore (research R13) belongs to the same owner.
