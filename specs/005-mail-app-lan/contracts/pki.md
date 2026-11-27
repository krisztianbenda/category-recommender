# Contract: Server Certificate Scripts

Design: [research R11](../research.md#r11-naming-the-mac-mini-in-its-certificate). Run by the owner on the Mac mini, never by an AI assistant (constitution II).

## `scripts/pki/new-server-cert.sh` (new)

```text
scripts/pki/new-server-cert.sh <lan-ip> [--dns <name>]... [--dir DIR]
```

- Issues `server.key` and `server.crt` in `DIR` (default `$CATREC_PKI_DIR` or `/Users/catrec/.catrec/pki`) from the CA already there. Refuses if `ca.key` is not in `DIR`.
- Subject alternative names: `IP:<lan-ip>`, `DNS:catrec.local`, and one `DNS:` entry per `--dns`. Names must be letters, digits, `-` and `.`.
- Extended key usage `serverAuth`, 825 days, ECDSA P-256, SHA-256, as today.
- Replaces an existing server certificate. The old pair is kept as `server.crt.previous` and `server.key.previous`.
- Prints the names it wrote, then "Restart the service: sudo launchctl kickstart -k system/com.catrec.service".

Device certificates are not affected, so no device has to be set up again.

## `scripts/pki/init-ca.sh` (changed)

```text
scripts/pki/init-ca.sh <lan-ip> [--dns <name>]... [--dir DIR]
```

Creates the CA as today, then calls `new-server-cert.sh` with the same arguments. Without `--dns` the result is the same as today.
