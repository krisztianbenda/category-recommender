# Contract: Mail App Recommender Settings and Installer

How a Mac's Mail app is told which recommender to use. Design: [research R7 and R10](../research.md#r7-settings).

## Preferences

`UserDefaults` domain `com.catrec.mail`, written by `mail-app/scripts/install.sh`. The owner can also set them with `defaults write com.catrec.mail <key> <value>` and restart the app.

| Key | Type | Local mode | Remote |
|-----|------|------------|--------|
| `baseURL` | string | absent (means `http://127.0.0.1:8080`) | `https://<host>:<port>`, for example `https://krisz-mac-mini.local:8443` |
| `caCertificate` | string, absolute path | absent | Path to the PEM copy of the owner's CA certificate |
| `deviceCertificate` | string | absent | Label of this Mac's identity in the keychain, the `<device-name>` given to `new-device.sh` |
| `recommenderName` | string | absent | What the menu calls the recommender, for example `Mac mini` |

Existing keys (`keepInInbox`, `idleMinutes`) are unchanged. `idleMinutes` has no effect in remote mode.

Rules, checked at start-up. The app exits with status 2 and one line on stderr if any fails, as it does today for a refused address:

1. `baseURL` passes `Destination.check` ([research R3](../research.md#r3-which-addresses-the-app-accepts)).
2. A `baseURL` that is not loopback needs both `caCertificate` and `deviceCertificate`.
3. `caCertificate` is a readable PEM file with one certificate.

A missing identity in the keychain is not a start-up error: the window and the self-test report it (`noDeviceCertificate`), because the owner may import the `.p12` after installing.

## Environment overrides (tests and development)

| Variable | Overrides | Notes |
|----------|-----------|-------|
| `CATREC_BASE_URL` | `baseURL` | Exists today |
| `CATREC_CA_FILE` | `caCertificate` | |
| `CATREC_DEVICE_CERT` | `deviceCertificate` | |
| `CATREC_KEYCHAIN` | where the identity is searched | Tests only: a keychain file made by the test. Without it, the user's keychains are searched |

## Installer

```text
mail-app/scripts/install.sh                                     # local mode, as today
mail-app/scripts/install.sh --remote <url> --ca <pem> --device <name> [--name <label>]
```

| Option | Effect |
|--------|--------|
| `--remote <url>` | Writes `baseURL`. The URL must be `https://` |
| `--ca <pem>` | Copies the file to `~/Library/Application Support/Category Recommender/recommender-ca.pem` and writes `caCertificate` |
| `--device <name>` | Writes `deviceCertificate` |
| `--name <label>` | Writes `recommenderName` |

With `--remote`, the app is built with `build-app.sh --no-local-service`: no `install.json`, so the app cannot start a local service, and `node` and `llama-server` are not needed on that Mac. Without `--remote`, the installer deletes the four keys and the CA copy, and installs as today.

The installer never reads, copies or imports a `.p12` or any key. Importing the device certificate is the owner's step (open the `.p12` in Finder).
