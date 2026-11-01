import { execFile } from "node:child_process";

/** True when `fdesetup status` reports FileVault is on. */
export function macosFileVaultOn(): Promise<boolean> {
  return new Promise((resolve) => {
    execFile("/usr/bin/fdesetup", ["status"], { timeout: 5000 }, (err, stdout) => {
      if (err) return resolve(false);
      resolve(/FileVault is On\./.test(stdout));
    });
  });
}
