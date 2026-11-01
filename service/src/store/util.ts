import { monotonicFactory } from "ulid";

const ulid = monotonicFactory();

export const newId = (): string => ulid();

export const nowIso = (): string => new Date().toISOString();

export function toBlob(v: Float32Array): Buffer {
  return Buffer.from(v.buffer, v.byteOffset, v.byteLength);
}

export function fromBlob(b: Buffer): Float32Array {
  const copy = b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
  return new Float32Array(copy);
}
