# Contract: Service Configuration File (v1)

The service reads a YAML file whose path comes from the `CATREC_CONFIG` environment variable. The file lives **outside the repository**. A placeholder copy is committed as `deploy/config.example.yaml`. Secrets are referenced by file path, never inlined. The file is watched: `access.devices` changes apply without a restart. Other changes need a restart.

```yaml
version: 1

server:
  bindAddress: 192.168.1.10        # LAN address only; never 0.0.0.0 on an internet-facing host
  port: 8443
  tls:
    certFile: /Users/catrec/.catrec/pki/server.crt
    keyFile:  /Users/catrec/.catrec/pki/server.key     # secret
    clientCaFile: /Users/catrec/.catrec/pki/ca.crt

access:                            # hot-reloaded allowlist (Principle III)
  devices:
    - name: krisz-macbook
      fingerprintSha256: "AB:CD:..."
      user: owner
    - name: krisz-iphone
      fingerprintSha256: "12:34:..."
      user: owner

storage:
  dataDir: /Users/catrec/Library/Application Support/catrec   # must resolve outside the repo
  encryption: filevault            # filevault | external-volume | sqlcipher
  sqlcipherKeyFile: null           # required iff encryption = sqlcipher (secret)

llm:
  baseUrl: http://127.0.0.1:8081/v1    # loopback or allowlisted LAN address only
  model: qwen3-8b-instruct-q4_k_m
  maxEmailTokens: 1500
  requestTimeoutSeconds: 30

embeddings:
  baseUrl: http://127.0.0.1:8082/v1
  model: bge-m3-q8_0

learning:
  neighbours: 8
  fewShotExamples: 5
  recencyHalfLifeDays: 180
  minSimilarity: 0.5               # neighbours below this cosine similarity are ignored
  confidence: { knnAgreeShare: 0.6 }
  override: { share: 0.75, minExamples: 3 }   # past decisions win over the model (research R6)
  newCategoryDuplicateSimilarity: 0.90
  deletion:                        # suggesting deletion (specs/003-delete-suggestion)
    enabled: true
    noFitShare: 0.5                # when no label fits, deleting needs at least this share
    trashSimilarity: 0.75          # subject similarity for a trashed email from the same sender

suggestions:
  ttlSeconds: 3600

logging:
  level: info
  retentionDays: 14

backup:
  ageRecipient: "age1..."          # owner's public age key; backups are encrypted to it (R16)
```

On startup, the service validates the file and refuses to start if any of these is true:
- `storage.dataDir` resolves inside the repository working tree.
- `llm.baseUrl` or `embeddings.baseUrl` is not loopback or allowlisted.
- `storage.encryption = filevault` and FileVault is off.
- A referenced secret file is world-readable.
- `server.tls` is not set and `server.bindAddress` is not `127.0.0.1`, `::1` or `localhost`.

**Local mode** (added 2026-11-01): when `server.tls` is absent or `null`, the service serves plain HTTP on the loopback address for a single user, `owner`. `access.devices` is ignored and not watched. Only requests whose `Host` is `127.0.0.1`, `localhost` or `[::1]` with the listening port are accepted (DNS-rebinding guard). Template: `deploy/local/config.yaml.template`.
