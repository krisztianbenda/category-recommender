import path from "node:path";
import { configPathFromEnv, loadConfig } from "./config/load.js";
import { ConfigError } from "./config/schema.js";
import { assertStorageEncrypted, EncryptionRequiredError } from "./platform/encryption.js";
import { createLogger } from "./logging/logger.js";
import { createApp } from "./app.js";

async function main(): Promise<void> {
  const configFile = configPathFromEnv();
  const config = loadConfig(configFile);
  await assertStorageEncrypted(config.storage.encryption, config.storage.dataDir);
  const logger = createLogger({
    level: config.logging.level,
    dir: path.join(config.storage.dataDir, "logs"),
    retentionDays: config.logging.retentionDays,
  });
  const app = await createApp(config, { logger, configFile });
  await app.listen();
  logger.info({ count: app.ctx.access.size }, "catrec service listening");

  const shutdown = async () => {
    await app.close();
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((err: unknown) => {
  // Startup errors are configuration problems; their messages contain no personal data.
  if (err instanceof ConfigError || err instanceof EncryptionRequiredError) {
    process.stderr.write(`${err.message}\n`);
  } else {
    process.stderr.write(`catrec failed to start: ${(err as Error).name}\n`);
  }
  process.exit(1);
});
