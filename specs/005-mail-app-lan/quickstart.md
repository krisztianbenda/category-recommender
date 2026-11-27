# Quickstart: Mail App over the Home Network

Two ways to check the feature: the synthetic checks anyone can run (and CI runs), and the owner's own setup, which touches real keys and is never run by an AI assistant.

## 1. Synthetic checks (development and CI)

Prerequisites: macOS 14 or later, the Command Line Tools, Node.js 24, `openssl`. No model, no real Mail, no real certificates.

```bash
mail-app/scripts/test.sh
```

Expect the new unit tests to pass: the address rule for every row of [research R3](research.md#r3-which-addresses-the-app-accepts), the trust check against test-made certificates (good chain, other CA, expired, wrong name), and the error messages of [research R4](research.md#r4-what-the-window-says-when-the-recommender-cannot-be-used).

```bash
mail-app/Tests/e2e.sh
```

Besides today's checks, expect:

- `LiveServiceTests` passing against the service in LAN mode (`https://127.0.0.1`, throwaway PKI, test device certificate from a throwaway keychain).
- `--self-test-remote` reporting all six steps as `pass` against that service ([contract](contracts/self-test-remote.md)).
- The same self-test reporting `identity: fail` against the impostor server, and `accepted: fail` with a device that is not on the list.
- The running app connecting to the configured address only.

```bash
cd service && npm test
```

Expect the new tests for `new-server-cert.sh` (the names in the certificate) and for moving learning from local mode to LAN mode (same recommendations after a restore, synthetic data).

## 2. The owner's setup

Done once on the Mac mini, then once per Mac. Commands are in the operations guide's "Use the Mail app from another Mac" section; this list is the order.

**On the Mac mini (once)**

1. If you use local mode today, take a backup of what was learned (`catrec backup`).
2. Install the hardened LAN setup from the operations guide. For the PKI, pass the Mac mini's Bonjour name: `scripts/pki/init-ca.sh <lan-ip> --dns <name>.local`.
3. Restore the backup into the LAN install (`catrec restore`).
4. Energy settings: prevent automatic sleeping, and turn on Wake for network access.

**For each Mac, including the Mac mini itself** (SC-004: at most 6 steps)

1. On the Mac mini: `sudo -u catrec scripts/pki/new-device.sh <device-name>`.
2. On the Mac mini: paste the printed entry into `access.devices` in the config.
3. Copy `devices/<device-name>.p12` and `ca.crt` to the Mac (AirDrop or a USB stick).
4. On the Mac: open the `.p12` and enter its password, so it goes into the login keychain.
5. On the Mac: `mail-app/scripts/install.sh --remote https://<name>.local:8443 --ca ca.crt --device <device-name> --name "Mac mini"`.
6. On the Mac: run the remote self-test, and allow Local Network access and the keychain prompt when macOS asks.

```bash
open -n "$HOME/Applications/Category Recommender.app" --args --self-test-remote --out /tmp/catrec-remote.json
```

Expect `"ok": true`. If a step fails, its hint says what to check. The file has no address and no content, so it is safe to share.

**Then check by hand**

- Select an email in Mail on the MacBook, press Control-Option-L: the menu and the window say the recommendations come from the Mac mini, and one appears within 15 seconds.
- Turn off Wi-Fi on the MacBook and open the window again: within 5 seconds it says the Mac mini can't be reached, and you can still file by hand.
- Remove the MacBook's entry from `access.devices`: the next window says the Mac mini does not accept this Mac. Put it back.
