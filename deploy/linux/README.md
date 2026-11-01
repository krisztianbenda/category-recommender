# Linux deployment (documented alternative, constitution IV)

The service code is identical on Linux. Only these host pieces differ from macOS:

| macOS | Linux |
|-------|-------|
| launchd units (`deploy/macos/launchd`) | systemd units in this directory |
| pf anchor (`deploy/macos/pf/catrec.conf`) | `nftables-catrec.conf` (`meta skuid catrec` egress drop) |
| FileVault (`storage.encryption: filevault`) | LUKS/ZFS-encrypted volume for the data dir, with `storage.encryption: external-volume` |
| Metal | CUDA/Vulkan/CPU build of llama.cpp (adjust `--n-gpu-layers`) |

Steps (as root):

1. `useradd --system --home /var/lib/catrec --shell /usr/sbin/nologin catrec`
2. Put the data dir on an encrypted volume; `install -d -o catrec -m 700 /var/lib/catrec`.
3. `scripts/fetch-models.sh --dir /opt/catrec/models` (as an admin, not as catrec).
4. Build the service (`npm ci && npm run build` in `service/`) and copy `dist`, `node_modules` and `package.json` to `/opt/catrec/service`.
5. Copy the units to `/etc/systemd/system/`, then `systemctl daemon-reload && systemctl enable --now catrec-llm catrec-embeddings catrec-service`.
6. `nft -f deploy/linux/nftables-catrec.conf`, and include it from `/etc/nftables.conf` so it persists.
