// Allowlist-redacting logger (constitution: logs carry identifiers and metadata only).
// Only the keys below are ever serialised; everything else, including request bodies, email
// fields and category names, is dropped. Messages passed to the logger must be constant strings.
import path from "node:path";
import pino, { type DestinationStream, type Logger as PinoLogger } from "pino";

export const ALLOWED_LOG_KEYS = [
  "reqId",
  "route",
  "method",
  "status",
  "durationMs",
  "model",
  "confidence",
  "isNew",
  "sizeBytes",
  "count",
  "suggestionId",
  "learningExampleId",
  "categoryId",
  "setId",
  "errorCode",
] as const;

export type LogKey = (typeof ALLOWED_LOG_KEYS)[number];
export type LogFields = Partial<Record<LogKey, string | number | boolean | null>>;

const allowed = new Set<string>(ALLOWED_LOG_KEYS);

export function redact(obj: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (!allowed.has(k)) continue;
    // Only scalars: an object under an allowed key could still smuggle content.
    if (v === null || typeof v === "number" || typeof v === "boolean") out[k] = v;
    else if (typeof v === "string") out[k] = v.slice(0, 64);
  }
  return out;
}

export interface Logger {
  debug(fields: LogFields, msg: string): void;
  info(fields: LogFields, msg: string): void;
  warn(fields: LogFields, msg: string): void;
  error(fields: LogFields, msg: string): void;
}

export interface LoggerOptions {
  level: string;
  /** Directory for rotated log files. Ignored when `destination` is given. */
  dir?: string;
  retentionDays?: number;
  /** For tests: write to this stream instead of rotated files. */
  destination?: DestinationStream;
}

function wrap(p: PinoLogger): Logger {
  const call = (level: "debug" | "info" | "warn" | "error") => (fields: LogFields, msg: string) =>
    p[level](fields as Record<string, unknown>, msg);
  return { debug: call("debug"), info: call("info"), warn: call("warn"), error: call("error") };
}

export function createLogger(opts: LoggerOptions): Logger {
  const base: pino.LoggerOptions = {
    level: opts.level,
    base: undefined, // no pid/hostname
    formatters: { log: redact },
    timestamp: pino.stdTimeFunctions.isoTime,
  };
  if (opts.destination) return wrap(pino(base, opts.destination));
  if (!opts.dir) return wrap(pino(base, pino.destination(2)));
  const transport = pino.transport({
    target: "pino-roll",
    options: {
      file: path.join(opts.dir, "catrec"),
      extension: ".log",
      frequency: "daily",
      dateFormat: "yyyy-MM-dd",
      mkdir: true,
      limit: { count: opts.retentionDays ?? 14 },
    },
  });
  return wrap(pino(base, transport));
}

/** A logger that drops everything (tests that do not inspect logs). */
export const silentLogger: Logger = {
  debug: () => {},
  info: () => {},
  warn: () => {},
  error: () => {},
};
