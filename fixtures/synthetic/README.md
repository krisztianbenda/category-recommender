# Synthetic fixtures

**Every email, name, address and category in this directory is fabricated.** They exist only to
test and evaluate the category recommender.

Rules (constitution, Principle II):

- Never add real emails, real names of real people, real addresses, or output produced from real data.
- Use `example.test` (or other reserved test domains) for every address.
- Brand names (for example "Apple") appear only in clearly invented marketing text.

| Directory | Used by | Content |
|-----------|---------|---------|
| `examples/` | contract tests, quickstart V1–V4 | four hand-written scenario emails |
| `reference/` | `npm run eval -- --suite reference` (SC-001) | ≥ 100 labelled emails, English + Hungarian |
| `novel/` | `--suite novel` (SC-001a) | emails that fit no category, with the expected parent |
| `injection/` | `--suite injection` (FR-019) | emails that try to instruct the model |
| `habits/` | `--suite habits` (SC-002, SC-003) | a scripted user with consistent personal habits |

`reference/`, `novel/`, `injection/` and `habits/` are produced by `generate.mjs`
(deterministic, seeded). Re-run `node fixtures/synthetic/generate.mjs` after editing templates.
