// OS adapter for encryption at rest (constitution IV: OS-specific code behind an interface).
import type { EncryptionMode } from "../config/schema.js";
import { macosFileVaultOn } from "./macos.js";
import { linuxDataDirEncrypted } from "./linux.js";

export interface EncryptionChecker {
  checkDataDirEncrypted(dataDir: string): Promise<boolean>;
}

export function platformChecker(platform: NodeJS.Platform = process.platform): EncryptionChecker {
  if (platform === "darwin") return { checkDataDirEncrypted: () => macosFileVaultOn() };
  return { checkDataDirEncrypted: (dir) => linuxDataDirEncrypted(dir) };
}

export class EncryptionRequiredError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EncryptionRequiredError";
  }
}

/** Refuses to start unless data at rest is protected as configured. */
export async function assertStorageEncrypted(
  mode: EncryptionMode,
  dataDir: string,
  checker: EncryptionChecker = platformChecker(),
): Promise<void> {
  switch (mode) {
    case "filevault":
      if (!(await checker.checkDataDirEncrypted(dataDir))) {
        throw new EncryptionRequiredError(
          "storage.encryption is 'filevault' but full-disk encryption is off. Turn on FileVault, " +
            "or set storage.encryption to 'external-volume' if the data dir is on another encrypted volume.",
        );
      }
      return;
    case "external-volume":
      // The owner asserts the data dir is on an encrypted volume; nothing to verify portably.
      return;
    case "sqlcipher":
      throw new EncryptionRequiredError(
        "storage.encryption 'sqlcipher' is not available in this build (needs better-sqlite3-multiple-ciphers). " +
          "Use 'filevault' or 'external-volume'.",
      );
  }
}
