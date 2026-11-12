// One JSON request to the service, for tests. Synthetic data only.
import { request, type Dispatcher } from "undici";

export interface Response<T = unknown> {
  status: number;
  body: T;
}

export interface CallOptions {
  /** For mTLS: an undici Agent with the client certificate. */
  dispatcher?: Dispatcher;
  headers?: Record<string, string>;
}

export async function callJson<T = unknown>(
  method: string,
  url: string,
  body?: unknown,
  opts: CallOptions = {},
): Promise<Response<T>> {
  const res = await request(url, {
    method: method as "GET",
    dispatcher: opts.dispatcher,
    headers: {
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
      ...opts.headers,
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.body.text();
  return { status: res.statusCode, body: (text ? JSON.parse(text) : undefined) as T };
}
