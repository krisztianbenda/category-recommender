// OpenAI-compatible client for the local runtime (llama.cpp llama-server). Loopback only:
// there is no fallback endpoint, ever (constitution I).
import { request } from "undici";
import { isLoopbackUrl } from "../config/load.js";

export class LlmUnavailableError extends Error {
  constructor(message = "local model runtime unavailable") {
    super(message);
    this.name = "LlmUnavailableError";
  }
}

export class LlmOutputError extends Error {
  constructor(message = "model output was not valid JSON") {
    super(message);
    this.name = "LlmOutputError";
  }
}

export class NonLocalEndpointError extends Error {
  constructor() {
    super("refusing to call a non-loopback model endpoint");
    this.name = "NonLocalEndpointError";
  }
}

export interface ChatMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

interface EndpointOptions {
  baseUrl: string;
  model: string;
  timeoutMs: number;
}

function endpoint(baseUrl: string, path: string): string {
  if (!isLoopbackUrl(baseUrl)) throw new NonLocalEndpointError();
  return `${baseUrl.replace(/\/+$/, "")}/${path}`;
}

/** llama-server serves /apply-template at its root, next to the OpenAI-style /v1 routes. */
function serverRoot(baseUrl: string): string {
  return baseUrl.replace(/\/+$/, "").replace(/\/v1$/, "");
}

async function postJson(url: string, body: unknown, timeoutMs: number): Promise<unknown> {
  let res;
  try {
    res = await request(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      headersTimeout: timeoutMs,
      bodyTimeout: timeoutMs,
    });
  } catch {
    throw new LlmUnavailableError();
  }
  // 503 = still loading, 429 = busy. Any other 5xx comes from a running server that failed on
  // this request (for example its output parser), so it is an unusable answer, not an outage.
  if (res.statusCode === 503 || res.statusCode === 429) {
    await res.body.dump();
    throw new LlmUnavailableError();
  }
  if (res.statusCode >= 500) {
    await res.body.dump();
    throw new LlmOutputError(`model runtime failed on this request (${res.statusCode})`);
  }
  if (res.statusCode >= 400) {
    await res.body.dump();
    throw new LlmUnavailableError(`model runtime rejected the request (${res.statusCode})`);
  }
  try {
    return await res.body.json();
  } catch {
    throw new LlmUnavailableError();
  }
}

async function ping(baseUrl: string, timeoutMs: number): Promise<boolean> {
  try {
    const res = await request(endpoint(baseUrl, "models"), {
      method: "GET",
      headersTimeout: timeoutMs,
      bodyTimeout: timeoutMs,
    });
    await res.body.dump();
    return res.statusCode < 400;
  } catch {
    return false;
  }
}

export class LlmClient {
  constructor(private readonly opts: EndpointOptions) {
    endpoint(opts.baseUrl, ""); // validate eagerly
  }

  get model(): string {
    return this.opts.model;
  }

  /**
   * Completion constrained to `schema`; returns the parsed JSON object. The prompt is rendered with
   * the model's own chat template (/apply-template) and generated through the plain completions
   * endpoint, because llama-server's chat-output parser rejects some valid constrained answers
   * ("does not match the expected peg-native format").
   */
  async chat(messages: ChatMessage[], schema: object, maxTokens = 400): Promise<unknown> {
    const { prompt } = (await postJson(
      endpoint(serverRoot(this.opts.baseUrl), "apply-template"),
      { messages, chat_template_kwargs: { enable_thinking: false } },
      this.opts.timeoutMs,
    )) as { prompt?: string };
    if (typeof prompt !== "string") throw new LlmOutputError("model runtime returned no prompt");
    const res = (await postJson(
      endpoint(this.opts.baseUrl, "completions"),
      {
        model: this.opts.model,
        prompt,
        temperature: 0,
        max_tokens: maxTokens,
        cache_prompt: true,
        json_schema: schema,
      },
      this.opts.timeoutMs,
    )) as { choices?: { text?: string }[] };
    const content = res.choices?.[0]?.text;
    if (typeof content !== "string") throw new LlmOutputError("model returned no content");
    try {
      return JSON.parse(stripThinking(content));
    } catch {
      throw new LlmOutputError();
    }
  }

  health(): Promise<boolean> {
    return ping(this.opts.baseUrl, 2000);
  }
}

/** Some models emit an empty <think></think> block even with thinking disabled. */
function stripThinking(s: string): string {
  return s.replace(/<think>[\s\S]*?<\/think>/g, "").trim();
}

export function l2normalise(v: Float32Array): Float32Array {
  let sum = 0;
  for (const x of v) sum += x * x;
  const norm = Math.sqrt(sum) || 1;
  const out = new Float32Array(v.length);
  for (let i = 0; i < v.length; i++) out[i] = v[i]! / norm;
  return out;
}

export interface Embedder {
  readonly model: string;
  embed(texts: string[]): Promise<Float32Array[]>;
}

export class EmbeddingsClient implements Embedder {
  constructor(private readonly opts: EndpointOptions) {
    endpoint(opts.baseUrl, "");
  }

  get model(): string {
    return this.opts.model;
  }

  async embed(texts: string[]): Promise<Float32Array[]> {
    if (texts.length === 0) return [];
    const res = (await postJson(
      endpoint(this.opts.baseUrl, "embeddings"),
      { model: this.opts.model, input: texts },
      this.opts.timeoutMs,
    )) as { data?: { index?: number; embedding?: number[] }[] };
    const data = res.data;
    if (!Array.isArray(data) || data.length !== texts.length) {
      throw new LlmUnavailableError("embedding runtime returned an unexpected response");
    }
    const sorted = [...data].sort((a, b) => (a.index ?? 0) - (b.index ?? 0));
    return sorted.map((d) => {
      if (!Array.isArray(d.embedding)) throw new LlmUnavailableError("embedding missing");
      return l2normalise(Float32Array.from(d.embedding));
    });
  }

  health(): Promise<boolean> {
    return ping(this.opts.baseUrl, 2000);
  }
}

export function cosine(a: Float32Array, b: Float32Array): number {
  // Inputs are L2-normalised, so the dot product is the cosine similarity.
  let dot = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) dot += a[i]! * b[i]!;
  return dot;
}
