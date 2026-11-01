# Operations guide

How to install, run, maintain and move the category recommender on the home server. Design background: [`specs/001-local-llm-categorizer/`](../specs/001-local-llm-categorizer/plan.md).

**Golden rule (constitution I and II):** real emails and the data directory never go into the repository, a test, an issue or an AI assistant. Use the synthetic fixtures for anything you debug with help.

## Local mode (current setup)

Runs on this computer as your own user. It uses plain HTTP on `127.0.0.1` only, with no service user, certificates or firewall rules. Nothing else on the network can reach it.

Prerequisites: `brew install llama.cpp node@24`. Models are in `/opt/catrec/models` (`scripts/fetch-models.sh`).

**Start** (Ctrl+C stops the service and both model servers):

```bash
scripts/run-local.sh
```

Then open <http://127.0.0.1:8080/>. To use the smaller model, add `--llm-file qwen3-4b-instruct-q4_k_m.gguf`, and set `llm.model` in the config to match.

| What | Where |
|------|-------|
| Config (created on first run) | `~/.catrec/config.yaml` |
| Data (SQLite + service logs) | `~/.catrec/data/` |
| Model server logs | `~/.catrec/logs/` |

**Evaluation**: start the service as above, then in a second terminal:

```bash
cd service && CATREC_CONFIG=~/.catrec/config.yaml npm run eval -- --suite reference,novel,injection,habits --report ../eval-report.md
```

**Delete everything learned**: Learned data → Delete all my data in the UI, or stop the service and `rm -rf ~/.catrec/data`.

### Removing the hardened setup

If you installed the launchd/`catrec` setup described below, remove it before using local mode. Local mode needs ports 8080–8082 free.

```bash
for u in service embeddings llm pf; do sudo launchctl bootout system /Library/LaunchDaemons/com.catrec.$u.plist; sudo rm -f /Library/LaunchDaemons/com.catrec.$u.plist; done
```

```bash
sudo sed -i '' '/anchor "catrec"/d' /etc/pf.conf && sudo rm -f /etc/pf.anchors/catrec && sudo pfctl -f /etc/pf.conf
```

```bash
sudo rm -rf /opt/catrec/service /var/log/catrec && sudo sysadminctl -deleteUser catrec
```

`-deleteUser` also deletes `/Users/catrec`, which holds the certificates, config and data. Keep `/opt/catrec/models`, because local mode uses it.

## Hardened LAN setup (later)

The rest of this guide covers a separate install for use from other devices on your network. It uses a non-admin `catrec` service user, device certificates (mTLS) and pf egress rules. You don't need it for local mode.

## Layout on the Mac Mini

| What | Where | Owner / mode |
|------|-------|--------------|
| Service code | `/opt/catrec/service` | root, read-only |
| Models | `/opt/catrec/models/*.gguf` | admin, 644 |
| Config | `/Users/catrec/.catrec/config.yaml` | catrec, 600 |
| PKI (CA, server, device certs) | `/Users/catrec/.catrec/pki/` | catrec, 600 for keys |
| Data (SQLite + logs) | `/Users/catrec/Library/Application Support/catrec/` | catrec, 700 |
| launchd units | `/Library/LaunchDaemons/com.catrec.*.plist` | root |
| Egress rules | `/etc/pf.anchors/catrec` (+ anchor lines in `/etc/pf.conf`) | root |
| Process logs | `/var/log/catrec/` | catrec |

## Install from scratch

Prerequisites: FileVault on (`fdesetup status`), Homebrew, `brew install llama.cpp node@24 age`.

1. **Models** (the only step that uses the internet; run as your admin user):

   ```bash
   scripts/fetch-models.sh --pin
   ```

   The first run records SHA-256 checksums in `scripts/models.lock`. Compare them with the publisher's pages, then commit the lock file. Later runs (without `--pin`) verify every file.

2. **PKI**: use the Mac Mini's LAN address.

   ```bash
   sudo -u catrec scripts/pki/init-ca.sh 192.168.1.10
   ```

   (Run `setup.sh` first if the `catrec` user does not exist yet, or run the PKI script as your admin user with `--dir` and then `chown -R catrec` the directory.)

3. **Config**: copy `deploy/config.example.yaml` to `/Users/catrec/.catrec/config.yaml`, fill in `server.bindAddress`, the TLS paths and `backup.ageRecipient`, then `chown catrec` it and `chmod 600` it. The contract is in [`contracts/config.md`](../specs/001-local-llm-categorizer/contracts/config.md).

4. **Install the services and egress rules**:

   ```bash
   sudo deploy/macos/setup.sh --config /Users/catrec/.catrec/config.yaml
   ```

5. **Add your devices** (see below), then open `https://<lan-ip>:8443/` on that device.

Check:

```bash
sudo launchctl list | grep catrec
```

```bash
curl --cacert ca.crt --cert device.pem https://<lan-ip>:8443/v1/health
```

## Devices

**Add a device:**

```bash
sudo -u catrec scripts/pki/new-device.sh krisz-phone
```

Import the resulting `devices/krisz-phone.p12` on the device. Also install `ca.crt` as a trusted root, so the browser trusts the server. Paste the printed lines into `access.devices` in the config. The change applies within a second, with no restart.

**Revoke a device:** delete its entry from `access.devices`. It is refused from the next request on. To retire the certificate completely, also delete `devices/<name>.crt`/`.p12`.

**Rotate the CA** (if `ca.key` may have leaked):
1. Move the old `pki/` away.
2. Run `init-ca.sh` again.
3. Re-issue every device.
4. Replace `access.devices`.
5. Restart: `sudo launchctl kickstart -k system/com.catrec.service`.

Keep `ca.key` offline (an encrypted USB stick) once your devices are issued.

## Egress check (constitution I)

```bash
sudo pfctl -a catrec -vvsr
```

The `block drop out` rules' packet counters should stay at 0. Anything above 0 means something owned by `catrec` tried to reach the outside, and pf dropped it. Investigate with `sudo tcpdump -n -e -ttt -i pflog0`.

macOS updates sometimes rewrite `/etc/pf.conf`. After an OS update, check that it still contains the `anchor "catrec"` lines (re-run `setup.sh` if not).

## Switching the model

1. Fetch the new model: add a line to `scripts/models.lock`, then run `scripts/fetch-models.sh --pin`.
2. Point the LLM unit at it: `sudo deploy/macos/setup.sh --llm-file <file>.gguf`.
3. Set `llm.model` in the config to the file name without `.gguf`, then restart the service.
4. Re-run the evaluation (below) and record the result in the validation log.

If you change the **embedding** model, set `embeddings.model` and restart. All learning examples are re-embedded automatically at startup.

## Backup and restore (FR-021)

**Backup** (the service may keep running; SQLite's online backup is consistent):

```bash
sudo -u catrec env CATREC_CONFIG=/Users/catrec/.catrec/config.yaml node /opt/catrec/service/dist/src/cli/index.js backup /Volumes/BackupDisk/catrec-$(date +%F).age
```

The file is encrypted to `backup.ageRecipient`. Keep the matching age identity (private key) somewhere else.

**Restore** (stop the service first):

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.catrec.service.plist
```

```bash
sudo -u catrec env CATREC_CONFIG=/Users/catrec/.catrec/config.yaml node /opt/catrec/service/dist/src/cli/index.js restore /Volumes/BackupDisk/catrec-2026-10-30.age --identity ~/age-identity.txt
```

```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/com.catrec.service.plist
```

Add `--force` to replace an existing database; the old one is kept next to it as `catrec.db.before-restore-<time>`. The backup's config is saved as `restored-config.yaml` in the data dir, for reference.

## Moving to a new host

You need only the repository, a config bundle, secrets and a backup. No code changes.
1. Install from scratch on the new host (Linux: [`deploy/linux/README.md`](../deploy/linux/README.md)).
2. Copy the PKI directory and `config.yaml`, then adjust the host-specific values (`bindAddress`, paths).
3. Restore the latest backup.

## Evaluation and validation log

The evaluation uses synthetic fixtures only, and a throwaway data dir, never the real one:

```bash
cd service && CATREC_CONFIG=/Users/catrec/.catrec/config.yaml npm run eval -- --suite reference,novel,injection,habits --report ../eval-report.md
```

`eval-report.md` is git-ignored and hidden from AI assistants. Copy only the numbers into the log below.

### Validation log

| Date | Model | SC-001 | SC-001a | SC-002 | SC-003 | SC-004 p95 | SC-008 | Notes |
|------|-------|--------|---------|--------|--------|------------|--------|-------|
| 2026-10-30 | stub (dev machine) | n/a | n/a | n/a | n/a | n/a | n/a | Implementation complete; harness verified against the stub only. Real-model run pending on the Mac Mini. |

## Uninstall (and delete all data)

```bash
for u in service embeddings llm pf; do sudo launchctl bootout system /Library/LaunchDaemons/com.catrec.$u.plist; sudo rm /Library/LaunchDaemons/com.catrec.$u.plist; done
```

```bash
sudo rm -rf "/Users/catrec/Library/Application Support/catrec" /Users/catrec/.catrec /var/log/catrec /opt/catrec /etc/pf.anchors/catrec
```

Then remove the two `catrec` anchor lines from `/etc/pf.conf`, and delete the user with `sudo sysadminctl -deleteUser catrec`. To delete only your learned data and keep the service, use **Learned data → Delete all my data** in the UI.
