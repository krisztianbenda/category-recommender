// Copies non-TS runtime assets next to the compiled output (dist/).
import fs from "node:fs";
import path from "node:path";

const copies = [
  ["src/store/migrations", "dist/src/store/migrations", (f) => f.endsWith(".sql")],
  ["src/llm", "dist/src/llm", (f) => f.endsWith(".json")],
  ["web", "dist/web", (f) => /\.(html|js|css)$/.test(f)],
];
for (const [from, to, keep] of copies) {
  fs.mkdirSync(to, { recursive: true });
  for (const f of fs.readdirSync(from).filter(keep))
    fs.copyFileSync(path.join(from, f), path.join(to, f));
}
