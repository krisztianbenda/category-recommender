// Fails any outbound connection that is not to an explicitly allowed local endpoint
// (constitution quality gate: "no unexpected outbound network calls during processing").
import net from "node:net";
import tls from "node:tls";

export interface Endpoint {
  host: string;
  port: number;
}

export interface NetworkGuard {
  attempts: Endpoint[];
  violations: Endpoint[];
  uninstall(): void;
}

const LOCAL_ALIASES = new Map([
  ["localhost", "127.0.0.1"],
  ["::1", "127.0.0.1"],
  ["[::1]", "127.0.0.1"],
]);

const norm = (host: string) => LOCAL_ALIASES.get(host) ?? host;

function target(args: unknown[]): Endpoint | null {
  const [a, b] = args;
  if (typeof a === "object" && a !== null) {
    const o = a as { host?: string; port?: number | string; path?: string };
    if (o.path) return null; // unix socket / named pipe: local IPC
    return { host: norm(o.host ?? "localhost"), port: Number(o.port) };
  }
  if (typeof a === "number" || (typeof a === "string" && /^\d+$/.test(a))) {
    return { host: norm(typeof b === "string" ? b : "localhost"), port: Number(a) };
  }
  return null; // string path
}

type Connect = (...args: unknown[]) => net.Socket;

export function installNetworkGuard(allowed: () => Endpoint[]): NetworkGuard {
  const attempts: Endpoint[] = [];
  const violations: Endpoint[] = [];
  const originals = {
    netConnect: net.connect,
    netCreateConnection: net.createConnection,
    tlsConnect: tls.connect,
  };

  const guard =
    (orig: Connect): Connect =>
    (...args) => {
      const t = target(args);
      if (t) {
        attempts.push(t);
        const ok = allowed().some((e) => norm(e.host) === t.host && e.port === t.port);
        if (!ok) {
          violations.push(t);
          throw new Error(`network guard: blocked connection to ${t.host}:${t.port}`);
        }
      }
      return orig(...args);
    };

  const mutableNet = net as unknown as Record<string, Connect>;
  const mutableTls = tls as unknown as Record<string, Connect>;
  mutableNet.connect = guard(originals.netConnect as unknown as Connect);
  mutableNet.createConnection = guard(originals.netCreateConnection as unknown as Connect);
  mutableTls.connect = guard(originals.tlsConnect as unknown as Connect);

  return {
    attempts,
    violations,
    uninstall() {
      mutableNet.connect = originals.netConnect as unknown as Connect;
      mutableNet.createConnection = originals.netCreateConnection as unknown as Connect;
      mutableTls.connect = originals.tlsConnect as unknown as Connect;
    },
  };
}
