import fs from "node:fs";
import { readConfigFile } from "./load.js";
import { parseDevices, type DeviceEntry } from "./schema.js";

export interface AllowedDevice {
  name: string;
  user: string;
}

/** Live device allowlist (constitution III): revocation by config edit, no restart. */
export class AccessList {
  private byFingerprint: Map<string, AllowedDevice>;

  constructor(devices: DeviceEntry[]) {
    this.byFingerprint = AccessList.index(devices);
  }

  private static index(devices: DeviceEntry[]): Map<string, AllowedDevice> {
    return new Map(devices.map((d) => [d.fingerprintSha256, { name: d.name, user: d.user }]));
  }

  lookup(fingerprint: string): AllowedDevice | undefined {
    return this.byFingerprint.get(fingerprint.toUpperCase());
  }

  replace(devices: DeviceEntry[]): void {
    this.byFingerprint = AccessList.index(devices);
  }

  get size(): number {
    return this.byFingerprint.size;
  }
}

export interface WatchHandle {
  close(): void;
}

/**
 * Polls the config file and swaps the allowlist atomically on change.
 * Polling (not fs.watch) survives editors that replace the file. An invalid file keeps the
 * previous allowlist.
 */
export function watchAccessList(
  file: string,
  list: AccessList,
  onError: (errorCode: string) => void,
  intervalMs = 500,
): WatchHandle {
  const listener = (curr: fs.Stats, prev: fs.Stats) => {
    if (curr.mtimeMs === prev.mtimeMs && curr.size === prev.size) return;
    try {
      const raw = readConfigFile(file) as { access?: { devices?: unknown } } | null;
      const problems: string[] = [];
      const devices = parseDevices(raw?.access?.devices, problems);
      if (problems.length) {
        onError("access_config_invalid");
        return;
      }
      list.replace(devices);
    } catch {
      onError("access_config_unreadable");
    }
  };
  fs.watchFile(file, { interval: intervalMs }, listener);
  return { close: () => fs.unwatchFile(file, listener) };
}
