# Category Recommender

A private email category recommender that runs entirely on your own Mac. Give it an email and your categories (up to two levels, for example `Family/Baby`) and it suggests one category, or proposes a new one, using a local LLM. When you usually delete emails like it, it suggests deleting it instead. It learns from your confirmations, corrections and deletions.

Nothing leaves your computer: there are no cloud APIs, no telemetry, and the only step that uses the internet is downloading the models.

You can use it in two ways:

- **Web UI** at `http://127.0.0.1:8080/`: paste an email, get a suggestion, confirm or correct it.
- **macOS Mail**: a menu bar app that recommends a label or folder for the selected email and files it in two actions (a shortcut, then Return).

## Requirements

- macOS 14 or later on Apple Silicon. 16 GB of memory is enough: the default models use about 7 GB while loaded. Linux is a documented alternative for the service (see [`deploy/linux/`](deploy/linux/README.md)).
- [Homebrew](https://brew.sh), for Node.js 24 and `llama.cpp`.
- About 6 GB of disk space for the models.
- For the Mail app only: the Command Line Tools (`xcode-select --install`).

## Install

1. Get the code:

   ```bash
   git clone https://github.com/krisztianbenda/category-recommender.git && cd category-recommender
   ```

2. Install the runtime:

   ```bash
   brew install llama.cpp node@24
   ```

3. Download the models into `/opt/catrec/models`. Each file is checked against a pinned SHA-256. Create the directory first if it does not exist, or pass `--dir` and set `CATREC_MODELS_DIR` to use another place.

   ```bash
   sudo install -d -o "$USER" /opt/catrec/models
   ```

   ```bash
   scripts/fetch-models.sh
   ```

4. Optional, to use it from macOS Mail:

   ```bash
   mail-app/scripts/install.sh
   ```

   This puts **Category Recommender** in `~/Applications` and starts it at login. macOS asks for two permissions the first time. See [`mail-app/README.md`](mail-app/README.md#install).

## Use

### Web UI

Start the service and both model servers (Ctrl+C stops all three):

```bash
scripts/run-local.sh
```

The first run installs the service's dependencies, builds it, and creates `~/.catrec/config.yaml`. Then open <http://127.0.0.1:8080/>.

1. Create a category set with your categories, or type them with the email.
2. Paste an email (sender, subject, text) and ask for a suggestion.
3. Confirm the suggestion, pick another category, or delete. Each answer is learned, and the next similar email gets a better suggestion.
4. See and delete what was learned under **Learned data**.

To use the smaller, faster model, start with `--llm-file qwen3-4b-instruct-q4_k_m.gguf` and set `llm.model` in the config to match.

### macOS Mail

1. Select an email in Mail.
2. Press **Control-Option-L**, or click the tag icon in the menu bar.
3. Press **Return** to file it under the recommended label, or pick another one.

The app starts the service by itself and stops it after 30 minutes without use, so you don't need `run-local.sh`. It works with Gmail labels and with folders of iCloud, Exchange and other accounts. All keys and options are in [`mail-app/README.md`](mail-app/README.md#use).

### Where your data is

| What | Where |
|------|-------|
| Config | `~/.catrec/config.yaml` |
| Learned data (SQLite) and service logs | `~/.catrec/data/` |
| Model server logs | `~/.catrec/logs/` |
| Models | `/opt/catrec/models` |

Your data is never stored inside this repository. To delete everything learned, use **Learned data > Delete all my data** in the web UI, or stop the service and remove `~/.catrec/data`.

### Uninstall

```bash
mail-app/scripts/uninstall.sh
```

Then remove `~/.catrec` and `/opt/catrec/models`.

## Documentation

| Document | What it covers |
|----------|----------------|
| [`docs/architecture.md`](docs/architecture.md) | Components, how a suggestion is made, how it learns, where data lives |
| [`docs/operations.md`](docs/operations.md) | Running, evaluating, backup and restore, switching models, the hardened LAN setup |
| [`docs/dependencies.md`](docs/dependencies.md) | Every dependency and model, and what it does on the network |
| [`mail-app/README.md`](mail-app/README.md) | The Mail app: install, use, troubleshooting |
| [`specs/`](specs/) | Spec, plan and contracts for each feature |
| [`.specify/memory/constitution.md`](.specify/memory/constitution.md) | Project rules. Privacy comes first |

## Development

Turn on the repository's git hooks once per clone. The `commit-msg` hook rejects messages that are not [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), such as `feat(web): keep typed content when switching tabs`:

```bash
git config core.hooksPath .githooks
```

Run the checks that CI runs:

```bash
npm ci && npm test && npm run check:duplication
```

```bash
cd service && npm ci && npm run lint && npm test && npm run test:e2e
```

```bash
mail-app/scripts/test.sh && mail-app/Tests/e2e.sh
```

- `main` only changes through pull requests, which are squash-merged. A pull request can be merged when the **CI result** and **PR title** checks pass; no review is required. The title becomes the commit message on `main`, so it must be a Conventional Commit too.
- CI ([`.github/workflows/`](.github/workflows/)) runs the service's lint and tests, the end-to-end tests, the commit message check, and a code duplication check that fails above 0.15% ([`.jscpd.json`](.jscpd.json)). The Mail app's tests run on macOS when a pull request changes `mail-app/`, `service/`, `.github/` or `.nvmrc`, and always on `main`.
- `npm run test:e2e` builds the service and replays a short synthetic session ([`fixtures/synthetic/e2e/`](fixtures/synthetic/e2e/session.json)) against it with a stub model: suggestions, feedback, learned habits, deletion, a restart and deleting all data.
- `service/` is Node.js 24 and TypeScript. `npm run lint` checks formatting and lint rules.
- `mail-app/` is Swift, with no third-party packages.
- Tests and examples use only the fabricated emails in [`fixtures/synthetic/`](fixtures/synthetic/README.md). Never add real emails, labels, addresses or learned data to the repository, an issue or a prompt to an AI assistant.
- Features are specified and planned with [Spec Kit](https://github.com/github/spec-kit) under `specs/`.
- A change that affects installing, using or the structure of the code updates this README and `docs/architecture.md` in the same change (constitution, Principle VII).

## License

[MIT](LICENSE)
