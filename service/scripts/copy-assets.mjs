// Copies non-TS runtime assets next to the compiled output (dist/).
import fs from "node:fs";
import path from "node:path";

// dist/web holds only copied assets, so it is cleared first (removed pages must not be served).
const copies = [
  ["src/store/migrations", "dist/src/store/migrations", (f) => f.endsWith(".sql"), false],
  ["src/llm", "dist/src/llm", (f) => f.endsWith(".json"), false],
  ["web", "dist/web", (f) => /\.(html|js|css)$/.test(f), true],
];
for (const [from, to, keep, clean] of copies) {
  if (clean) fs.rmSync(to, { recursive: true, force: true });
  fs.mkdirSync(to, { recursive: true });
  for (const f of fs.readdirSync(from).filter(keep))
    fs.copyFileSync(path.join(from, f), path.join(to, f));
}
