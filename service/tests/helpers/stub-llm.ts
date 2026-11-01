// OpenAI-compatible fake of llama-server on 127.0.0.1 for tests. Deterministic, no real model.
import http from "node:http";
import type { AddressInfo } from "node:net";

export interface ChatRequest {
  messages: { role: string; content: string }[];
  response_format?: unknown;
  [k: string]: unknown;
}

export type ChatHandler = (
  req: ChatRequest,
  ctx: { candidates: string[]; email: string },
) => unknown;

export interface StubLlm {
  /** Base URL including /v1, usable for both llm.baseUrl and embeddings.baseUrl. */
  url: string;
  port: number;
  chatCalls: ChatRequest[];
  embeddingInputs: string[];
  setChat(handler: ChatHandler): void;
  setDown(down: boolean): void;
  close(): Promise<void>;
}

const DIM = 128;

function fnv1a(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

const STOPWORDS = new Set(
  "with your from this that have will have here there what when which about into than then them they their just also please thanks hello dear".split(
    " ",
  ),
);

/** Bag-of-words hashing embedding: texts sharing (content) words get similar vectors. */
export function stubEmbedding(text: string): number[] {
  const v = new Array<number>(DIM).fill(0);
  const words =
    text
      .toLowerCase()
      .normalize("NFD")
      .replace(/\p{M}/gu, "")
      .match(/\p{L}{4,}/gu) ?? [];
  for (const w of words) if (!STOPWORDS.has(w)) v[fnv1a(w) % DIM]! += 1;
  v[DIM - 1]! += 0.01; // never a zero vector
  return v;
}

/** Extracts candidate paths and the email block from the prompt our service sends. */
export function parsePrompt(req: ChatRequest): { candidates: string[]; email: string } {
  const text = req.messages.map((m) => m.content).join("\n");
  const cat = /<categories>\n([\s\S]*?)\n<\/categories>/.exec(text)?.[1] ?? "";
  const candidates = cat
    .split("\n")
    .map((l) => /^\s*- (.+)$/.exec(l)?.[1])
    .filter((x): x is string => !!x);
  const email = /<<<EMAIL-[0-9a-f]+>>>([\s\S]*?)<<<END-[0-9a-f]+>>>/.exec(text)?.[1] ?? "";
  return { candidates, email };
}

export const defaultChat: ChatHandler = (_req, { candidates }) => ({
  isNew: false,
  category: candidates[0] ?? "Unknown",
  confidence: "medium",
  reason: "stub choice",
  ranking: candidates.slice(0, 5),
});

export async function startStubLlm(): Promise<StubLlm> {
  let handler: ChatHandler = defaultChat;
  let down = false;
  const chatCalls: ChatRequest[] = [];
  const embeddingInputs: string[] = [];

  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      const send = (status: number, obj: unknown) => {
        res.writeHead(status, { "content-type": "application/json" });
        res.end(JSON.stringify(obj));
      };
      if (down) return send(503, { error: "loading" });
      if (req.method === "GET" && req.url === "/v1/models")
        return send(200, { data: [{ id: "stub" }] });
      if (req.method === "POST" && req.url === "/v1/embeddings") {
        const { input } = JSON.parse(body) as { input: string[] };
        embeddingInputs.push(...input);
        return send(200, {
          data: input.map((t, index) => ({ index, embedding: stubEmbedding(t) })),
        });
      }
      if (req.method === "POST" && req.url === "/v1/chat/completions") {
        const parsed = JSON.parse(body) as ChatRequest;
        chatCalls.push(parsed);
        const out = handler(parsed, parsePrompt(parsed));
        const content = typeof out === "string" ? out : JSON.stringify(out);
        return send(200, { choices: [{ message: { role: "assistant", content } }] });
      }
      send(404, { error: "not found" });
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  return {
    url: `http://127.0.0.1:${port}/v1`,
    port,
    chatCalls,
    embeddingInputs,
    setChat: (h) => (handler = h),
    setDown: (d) => (down = d),
    close: () =>
      new Promise((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  };
}
