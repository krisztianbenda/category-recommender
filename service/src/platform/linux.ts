/**
 * Linux has no single full-disk-encryption switch to query reliably (LUKS, ZFS, eCryptfs...).
 * Report "not verified" so that `filevault` mode fails; Linux hosts set
 * storage.encryption = external-volume after putting the data dir on an encrypted volume.
 */
export async function linuxDataDirEncrypted(_dataDir: string): Promise<boolean> {
  return false;
}
