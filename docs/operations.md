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

**Upgrading**: the service upgrades its database when it starts. The upgrade for suggesting deletion copies the table of learned examples, which keeps everything learned. To be able to go back to an older version, take a [backup](#backup-and-restore-fr-021) first.

### Mail integration

To file emails from macOS Mail under Gmail labels, install the menu bar app: `mail-app/scripts/install.sh`. It starts this service on demand, so you don't need to run `run-local.sh` yourself. It can also move an email to the Trash, and suggests that when you usually delete emails like it. See [`mail-app/README.md`](../mail-app/README.md).

To use it from another Mac, such as a MacBook, the recommender needs the hardened LAN setup below: see [Use the Mail app from another Mac](#use-the-mail-app-from-another-mac).

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

The rest of this guide covers a separate install for use from other devices on your network, for example the Mail app on your MacBook. It uses a non-admin `catrec` service user, device certificates (mTLS) and pf egress rules. You don't need it for local mode.

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

2. **PKI**: use the Mac Mini's LAN address, and its Bonjour name (System Settings > General > Sharing, at the bottom: "Local hostname"), so other Macs can find it even when the address changes.

   ```bash
   sudo -u catrec scripts/pki/init-ca.sh 192.168.1.10 --dns krisz-mac-mini.local
   ```

   `--dns` can be given more than once. The server certificate always names `catrec.local` as well, and is valid for 825 days.

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

Import the resulting `devices/krisz-phone.p12` on the device. For a browser, also install `ca.crt` as a trusted root, so it trusts the server. The Mail app doesn't need that: it trusts only `ca.crt`, and only for the recommender. Paste the printed lines into `access.devices` in the config. The change applies within a second, with no restart.

**Revoke a device:** delete its entry from `access.devices`. It is refused from the next request on. To retire the certificate completely, also delete `devices/<name>.crt`/`.p12`.

**Rotate the CA** (if `ca.key` may have leaked):
1. Move the old `pki/` away.
2. Run `init-ca.sh` again.
3. Re-issue every device.
4. Replace `access.devices`.
5. Restart: `sudo launchctl kickstart -k system/com.catrec.service`.

Keep `ca.key` offline (an encrypted USB stick) once your devices are issued. Bring it back to add a device or renew the server certificate.

**Renew the server certificate** before its 825 days are up, or when the Mac mini's address or name changes. With `ca.key` back in the PKI directory:

```bash
sudo -u catrec scripts/pki/new-server-cert.sh 192.168.1.10 --dns krisz-mac-mini.local
```

```bash
sudo launchctl kickstart -k system/com.catrec.service
```

The CA and the device certificates stay the same, so no device needs anything new. The old certificate is kept as `server.crt.previous`.

## Use the Mail app from another Mac

The Mail app on your MacBook can use the recommender and the model on the Mac mini, over your home network only. The email goes from the MacBook to the Mac mini over HTTPS with mutual TLS, and nowhere else. The Mac mini proves itself with a certificate from your CA, and the MacBook with its device certificate. Design: [`specs/005-mail-app-lan/`](../specs/005-mail-app-lan/spec.md).

It needs the hardened LAN setup above on the Mac mini. In LAN mode the model stays loaded, so the Mac mini uses about as much memory as when the service is busy.

### On the Mac mini, once

1. **If you used local mode until now**, keep what it learned: set `backup.ageRecipient` in `~/.catrec/config.yaml` to your public age key, stop `run-local.sh`, and take a backup.

   ```bash
   cd service && npm run build && CATREC_CONFIG=~/.catrec/config.yaml node dist/src/cli/index.js backup ~/catrec-local.age
   ```

2. **Install the hardened LAN setup** ([Install from scratch](#install-from-scratch)), with `--dns` in the PKI step. Do the list below for the Mac mini's own Mail app first: installed for local mode, it would try to start local mode, whose ports the LAN setup now uses.
3. **Restore the backup** into it, as in [Backup and restore](#backup-and-restore-fr-021). Everything you taught it belongs to the user `owner`, and so do your devices in `access.devices`, so it stays yours.
4. **Energy**: in System Settings > Energy, turn on **Prevent automatic sleeping when the display is off** and **Wake for network access**, or:

   ```bash
   sudo pmset -a sleep 0 womp 1
   ```

5. **FileVault and restarts**: after a restart, nothing starts until the Mac mini's FileVault password is entered on it, the recommender included. For a planned restart, `sudo fdesetup authrestart` unlocks it once.

### For each Mac, the Mac mini included

1. On the Mac mini, issue the Mac a device certificate:

   ```bash
   sudo -u catrec scripts/pki/new-device.sh krisz-macbook
   ```

2. On the Mac mini, paste the printed entry into `access.devices` in the config.
3. Copy `devices/krisz-macbook.p12` and `ca.crt` (never `ca.key`) to the Mac, with AirDrop or a USB stick.
4. On the Mac, open the `.p12` in Finder and enter its password. It goes into the login keychain.
5. On the Mac, install the Mail app for the Mac mini:

   ```bash
   mail-app/scripts/install.sh --remote https://krisz-mac-mini.local:8443 --ca ~/Downloads/ca.crt --device krisz-macbook --name "Mac mini"
   ```

6. On the Mac, check the connection. Allow Local Network access, and the keychain's request to use the device certificate (**Always Allow**), when macOS asks.

   ```bash
   open -n "$HOME/Applications/Category Recommender.app" --args --self-test-remote --out /tmp/catrec-remote.json
   ```

   Expect `"ok": true` in `/tmp/catrec-remote.json`. A failed step has a hint. The report has no address and no content.

The installer copies `ca.crt` to `~/Library/Application Support/Category Recommender/` and never reads or imports a `.p12` or a key. On that Mac, the app never starts a service: neither `node` nor `llama-server` is needed there. To go back to the recommender on that Mac, run `mail-app/scripts/install.sh` without options.

**Revoke a Mac**: delete its entry from `access.devices`. From the next request, its Mail app says the Mac mini does not accept it.

**Away from home**, the app says the Mac mini can't be reached. You can still file emails by hand, but those decisions are not learned, and nothing is queued for later. Reaching it from outside the home network would need a WireGuard overlay, which is not part of this setup.

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
