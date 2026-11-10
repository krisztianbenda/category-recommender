# Implementation Plan: Mail App Integration

**Branch**: `002-mail-app-integration` | **Date**: 2026-11-05 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/002-mail-app-integration/spec.md`

## Summary

A small menu bar app, a new component in `mail-app/`, is the owner's entry point. A keyboard shortcut, the Mail menu or the menu bar icon opens a floating window for the email selected in Mail. It reads the email and the Gmail account's labels from Mail, keeps a category set in step with those labels, asks the existing service for a suggestion, and files the email on one key press. Labels can be created or deleted from the same window. The recommendation algorithm, learning and storage stay in `service/`; the service does not change.

## Technical Context

**Language/Version**: Swift 6.3 toolchain in Swift 5 language mode (UI and orchestration); JavaScript for Automation (Mail access); Bash (install scripts).

**Primary Dependencies**: None beyond macOS: AppKit, SwiftUI, Carbon (hot key), `/usr/bin/osascript`. No third-party packages. Builds with the Command Line Tools; Xcode is not needed.

**Storage**: None new. Preferences (keep in Inbox, idle minutes) in `UserDefaults`. Email content stays in memory while the window is open. All learned data stays in the service's existing database.

**Testing**: Swift Testing for the core library; Node's built-in test runner with a fake Mail for the bridge script; an end-to-end script that runs the real service with a stub model against synthetic fixtures; a self-test that exercises real Mail on synthetic, local-only mailboxes.

**Target Platform**: macOS 14 or later on the reference Mac mini M4, 16 GB.

**Project Type**: Desktop client of the existing local HTTP API.

**Performance Goals**: Window within 1 s (SC-003). Recommendation within 15 s with a loaded model (SC-004).

**Constraints**: Loopback only. No email content on disk or in logs. No AI assistant sees real data (constitution II), which limits how live testing is done (see below).

**Scale/Scope**: One owner, one Gmail account, up to 300 labels in the recommender at once.

## Constitution Check

| Principle | Status | How |
|-----------|--------|-----|
| I. Privacy and data locality | Pass | The app talks only to the service on loopback and refuses other addresses, redirects and proxies. Mail's own Gmail connection is the only path to Google, and it already exists. |
| II. Assistant boundary | Pass | The Gmail connector available to the assistant is not used. Automated checks use synthetic data. Diagnostic output carries counts and pass or fail only. The assistant never starts the app against the real account without the owner's approval, and sees no names or text from it. |
| III. Access control | Pass | Local mode only; the service's bind address and Host check are unchanged. |
| IV. Portability | Pass | Paths and the service address come from install-time configuration. Everything Mac-specific is in `mail-app/`, behind the service's HTTP contract. The documented alternative on another OS is the existing web UI. |
| V. Simplicity and memory | Pass | No new service or datastore. The models load on demand and are stopped after an idle period, so the 5.6 GB footprint is not permanent. The app itself is small. |
| V. No automatic changes | Pass | Nothing is filed, created or deleted without a click or key press. Removed labels with learned decisions are kept until the owner says otherwise. |
| VI. Polyglot by contract | Justified deviation | See Complexity Tracking. |
| Quality gate: outbound check | Pass | A test asserts the client refuses non-loopback addresses and redirects; the end-to-end script checks the running app's sockets. |

### Privacy note (required: new component that uses the network)

The app reads email text from Mail into memory, sends it to `127.0.0.1` and drops it when the window closes or the background decision is recorded. It writes no email content to disk. Its log has event codes, counts and timings only. The URL session is ephemeral, with no cache, cookies, proxy or redirects. Learning examples are stored by the service exactly as they are for the web UI, and can be deleted the same way.

## Key decisions

### Integrating with Mail: Apple Events, not a Mail extension

Mail extensions (MailKit) cannot add a command that acts on the selected message, and cannot file into a specific mailbox. Mail plug-ins are no longer supported. Mail's scripting dictionary covers everything needed: the selection, message text, account mailboxes, move, copy, and creating and deleting mailboxes. In Gmail, a mailbox is a label, so these operations are label operations.

### Reaching Mail: JavaScript for Automation run through `osascript`

The bridge is `mail-app/Resources/mail-bridge.js`. It takes one JSON argument and prints one JSON result. It runs in a child process, so a slow Mail cannot freeze the window. Input and output are kept to ASCII with `\u` escapes, so text cannot be corrupted by encoding defaults or interpreted as code. The Automation permission belongs to this app, not to a terminal or to Claude.

### Deleting a label: through Mail's own command

Mail's scripting cannot delete a mailbox: the command fails with `-10000` on any account, a [long-standing problem](https://www.macscripter.net/t/cannot-delete-mail-mailboxes/70073). Direct IMAP would need the owner's Gmail credentials and a new connection, and so is rejected. Instead the app selects the label in Mail, reads the selection back, and clicks **Delete Mailbox…** in Mail's menu through System Events. Mail then shows its own confirmation, which names the mailbox, so the last check is Mail's and a wrong selection cannot delete silently. The click needs the Accessibility permission. Without it, the window asks the owner to choose the command in Mail's menu. Either way, the app waits for the label to disappear before forgetting its category.

### How Mail lists Gmail mailboxes

Found by counting on the real account, and not what Mail's documentation suggests. A selected Gmail email reports `[Gmail]/All Mail` as its mailbox even when it is shown in the Inbox, because Mail stores Gmail emails once, in All Mail. Filing therefore finds the copy in the mailbox being viewed, or else in the Inbox, by Message-ID, and moves that one. An account lists every mailbox at its top level, nested ones under their short name, and lists them again under their parent. Gmail's system folders are children of a `[Gmail]` parent that is not listed, and their names follow Gmail's language, so a list of names cannot recognise them. Full paths therefore come from each mailbox's chain of containers.

### Filing semantics in Gmail

Measured on the real account with a test email, as the owner approved:

- **Move**: Mail's scripted `move` only adds the label. JXA, AppleScript and setting the mailbox property all behave this way, and the Inbox copy stays even after a sync.
- **Delete flag**: setting `deleted status` on the old copy makes Mail abort inside its message-transfer code, as it tries to move the copy to Trash.
- **Archive**: Mail's own **Archive** command is the reliable way out of the Inbox.

| Source | Action | Gmail effect |
|--------|--------|--------------|
| Inbox, default | Copy, then Mail's Archive on exactly the filed emails | Adds the label, removes the Inbox label |
| Inbox, "Keep in Inbox" on | Copy | Adds the label |
| A label, All Mail or another system folder | Copy | Adds the label; other labels stay |

Archive runs only if Mail's selection is exactly the filed emails. It needs the Accessibility permission. Without it, the email keeps the label, stays in the Inbox, and the window says why.

### Labels and categories

The service allows two levels and 60-character names. Gmail does not. A mapping in the client handles the gap: `A/B/C` becomes the category `A/B › C`, and the client keeps the exact mailbox name for each category. Labels that collide after the service's accent folding get a ` (2)` suffix rather than being merged. The list is capped at 300 labels, which keeps the prompt within the model's 8192-token context. Any extra labels stay available for filing by hand, and the window says how many the recommender is not considering.

### Sync

Sync runs on each trigger and is a diff, so category ids and their learning survive. A missing label with no learned decisions is removed. A missing label with learned decisions is kept and reported, and the owner can forget it (constitution V: no automatic deletion of learned data). The set is named `Gmail: <address>`, which survives renaming the account in Mail.

### Decisions and learning

| What the owner does | Feedback sent |
|---------------------|---------------|
| Accepts the recommended label | `confirm` |
| Picks another imported label | `choose` |
| Accepts a proposal or types a new label under a known parent | `accept_new` |
| Types a new label under a new parent | Adds the category, requests a fresh suggestion, then `choose`, because `accept_new` only allows known parents by contract |
| Files by hand before the recommendation is ready | Files at once; the feedback is sent in the background when the recommendation arrives |

Mail is changed first and learning second, so a failed filing teaches nothing.

### Starting the service

The app runs `scripts/run-local.sh` when `/v1/health` does not answer, and stops it after the idle period (default 30 minutes, `defaults write com.catrec.mail idleMinutes`). If the owner started the service, the app uses it and never stops it. The script's last step changes so that SIGTERM stops everything.

### Testing without real data

The assistant may not see real emails, labels or recommendations, so real-account checks are split:

- **Synthetic, automatic**: unit tests, bridge tests with a fake Mail, end-to-end against the real service with synthetic fixtures, and window snapshots from a demo mode using a synthetic mail source.
- **Real Mail, synthetic data**: `--self-test-local` runs inside the app against "On My Mac" mailboxes and one fabricated message, reporting pass or fail only. Since scripts cannot delete mailboxes, it leaves those mailboxes behind and reuses them on later runs.
- **Real account, owner approved**: `--diagnose` reports counts only. `--self-test-gmail` is an owner-run check on the owner's chosen email: it creates temporary labels, adds one to the email, and moves the email to another and back. The owner then deletes the labels from the window, which checks that an email survives its label being deleted.

## Project Structure

```text
specs/002-mail-app-integration/   spec, plan, tasks
mail-app/
├── Package.swift
├── README.md
├── Resources/
│   ├── Info.plist                app metadata, Mail Services entry
│   └── mail-bridge.js            Mail access (JXA)
├── Sources/
│   ├── MailCore/                 no UI: labels, sync, HTTP client, session state
│   └── CategoryRecommender/      menu bar app, window, hot key, bridge runner, backend
├── Tests/MailCoreTests/          Swift Testing
├── tests/                        bridge tests (node --test), end-to-end script
└── scripts/                      build, test, install, uninstall
```

## Complexity Tracking

| Violation | Why needed | Simpler alternative rejected because |
|-----------|------------|--------------------------------------|
| Swift, outside constitution VI's Node.js, Python and Go | A floating window, a global hot key, a menu bar icon and a Mail Services entry need AppKit. It is a separate component, buildable and testable alone, that uses the service only through its versioned HTTP contract | **Electron**: about 200 MB and a large dependency tree, against principle V and the audit concerns of principle I. **Web UI in a browser tab**: takes the owner out of Mail for each email, and leaves the service or the browser needing Mail permissions. **Script with `choose from list` dialogs**: no progress indication during inference, no search, and no way to offer create or delete alongside a list, so "a few clicks" fails with many labels |

Principle VI names Node.js, Python and Go only. Recording Swift here is what the principle asks of a new language, but the owner may want a MINOR amendment that names a native client language for OS-specific UI.
