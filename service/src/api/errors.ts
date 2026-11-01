// Error envelope: { error: { code, message } }. Messages are fixed strings: never echo content.
export type ErrorCode =
  | "invalid_request"
  | "forbidden"
  | "not_found"
  | "content_mismatch"
  | "suggestion_expired"
  | "conflict"
  | "llm_unavailable"
  | "internal";

export class AppError extends Error {
  constructor(
    public readonly code: ErrorCode,
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "AppError";
  }
}

export const invalid = (message: string) => new AppError("invalid_request", 400, message);
export const notFound = (message = "not found") => new AppError("not_found", 404, message);
export const conflict = (message: string) => new AppError("conflict", 409, message);

export function envelope(code: ErrorCode, message: string) {
  return { error: { code, message } };
}
