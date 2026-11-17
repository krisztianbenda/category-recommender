# Implementation Plan: Batch Recommendations

**Branch**: `004-batch-recommendations` | **Date**: 2026-11-11 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/004-batch-recommendations/spec.md`

## Summary

When more than one email is selected, the Mail app opens a batch window instead of filing them all under one recommendation. Each email is a row with its own recommendation, made one after another through the existing `POST /v1/suggestions`, and learned through the existing feedback endpoint. The owner approves all ready rows, the marked rows, or one row at a time, or files rows under a label of their choice, or moves them to the Trash. Labelling acts per email by id. Archive and Delete still click Mail's own commands, so the bridge first sets Mail's selection to exactly the action's emails, and clicks only if the selection reads back exactly. The service, its contract and the web UI do not change.

## Technical Context

**Language/Version**: Swift 6.3 toolchain in Swift 5 language mode (`mail-app/`); JavaScript for Automation and a few lines of AppleScript through `NSAppleScript` (the Mail bridge). Unchanged from 002.

**Primary Dependencies**: None new. AppKit, SwiftUI, `osascript`.

**Storage**: None new. Up to 50 emails are held in the Mail app's memory while the batch window is open. Learning goes to the service's existing database, one example per decision.

**Testing**: Swift Testing (`BatchSessionTests`, existing `SessionTests`), Node's test runner for the bridge with a fake Mail, `tests/e2e.sh` against the real service with a stub model, demo snapshot and keyboard drive, `--self-test-local` on fabricated emails, and an owner-run `--self-test-selection`.

**Target Platform**: macOS 14 or later, reference Mac mini M4 with 16 GB.

**Project Type**: Desktop client of the existing local HTTP API.

**Performance Goals**: Batch window with every sender and subject within 1 s (SC-003). First recommendation within 15 s with the model loaded, 20 emails within 5 minutes (SC-004).

**Constraints**: Loopback only. No email content on disk or in logs. The model runs one request at a time. Mail's Archive and Delete act only on Mail's selection, so a scripted selection with a read-back check is the gate for every action that uses them (research R1).

**Scale/Scope**: One owner, one account per batch, at most 50 emails per batch, up to 300 labels considered (unchanged).

No open questions remain: [research.md](research.md) resolves each unknown. Two findings about Mail need a check on real Mail before release, through the self-tests below: that a scripted selection of some emails works, and how it behaves with conversations.

## Constitution Check

*Checked before research and again after the design. Both pass.*

| Principle | Status | How |
|-----------|--------|-----|
| I. Privacy and data locality | Pass | No new destination. The app sends each email to the service on `127.0.0.1` as the single window does. |
| I. Read-only data sources | Pass, approved in 002 and 003 | The writes to Mail are the ones already approved: add a label, Archive, move to the Trash. Each runs on an explicit owner action. New: the app changes which emails Mail shows as selected, which is not a change to any email. |
| II. Assistant boundary | Pass | Tests, the demo, the end-to-end script and the local self-test use synthetic emails. The real-account check is run by the owner and reports pass or fail only. |
| III. Access control | Pass | Local mode, unchanged. |
| IV. Portability | Pass | Everything Mac-specific stays in `mail-app/`, behind the service's HTTP contract. The batch limit is a constant of the client, not a host value. |
| V. Simplicity and memory | Pass | No new service, datastore or model. Inference stays one at a time. The Mail app holds at most 50 prepared emails, at most about 5 MB. The models' 7 GB is unchanged. |
| V. No automatic changes | Pass | Nothing changes without an owner action that covers that email. Approve all is such an action, and moving more than one email to the Trash needs a confirmation that gives the counts. Undecided emails are never touched. |
| VI. Polyglot by contract | Pass | No new language. Swift is justified in 002. The service contract is unchanged; the bridge changes are documented in [contracts/mail-bridge.md](contracts/mail-bridge.md). |
| VII. Living documentation | Pass | `README.md`, `docs/architecture.md` and `mail-app/README.md` are updated in this change (see Documentation). `LICENSE` is unchanged. |
| Logs | Pass | New events carry counts and durations only: batch size, rows applied, rows failed, by reason. |
| Quality gate: outbound check | Pass | The existing client refuses non-loopback addresses. `tests/e2e.sh` runs a batch and checks the app's sockets. |

### Privacy note

Today the app reads the text of the newest selected email only. A batch reads the text of up to 50 selected emails, in the background, into memory, and sends each to the service on `127.0.0.1` for its recommendation. It writes none of it to disk. Closing the window drops it, except for emails already filed and waiting to be learned, which are dropped once learned, as in the single window. The service stores a learning example only for emails the owner decided on, as it does today. The Trash is read as in 003, for every sender in the batch in one call: senders and subjects only.

## Key decisions

Details and alternatives are in [research.md](research.md).

| Topic | Decision | Research |
|-------|----------|----------|
| Archive and Delete for some of the selected emails | The bridge selects exactly the action's emails in Mail, reads the selection back, and clicks only if it matches | R1 |
| Window within 1 s | A batch `opening` returns sender, subject and references only. A new `read` command places and reads emails five at a time in the background | R2 |
| Batch size | The 50 newest of the selection; the window says how many were left out | R3 |
| Order | One recommendation at a time, in row order; rows decided by hand go to the back of the queue | R4 |
| The same new label on several rows | `accept_new` for the first row; a fresh suggestion and `choose` for the others, after filing | R5 |
| Trash evidence | One `trashSimilar` call with every sender; per-email `inTrashIds` | R6 |
| Code | A new `BatchSession`; the single window's label list, feedback mapping and messages move into shared files | R7 |
| Window | 600 × 560, List and Choose a label; one scope rule for every key | R8, [contract](contracts/batch-window.md) |
| Time limits | None to change: the service keeps a suggestion for an hour | R9 |

Applying an action is described in [data-model.md](data-model.md#action): create new labels once, file per target label, archive once, trash once, then learn row by row. A failed step affects only its rows.

## Project Structure

### Documentation (this feature)

```text
specs/004-batch-recommendations/
├── spec.md
├── plan.md                  this file
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── mail-bridge.md       bridge command changes
│   └── batch-window.md      the window: views, rows, keys, confirmation
├── checklists/requirements.md
└── tasks.md                 /speckit-tasks
```

### Source code

```text
mail-app/
├── Resources/
│   └── mail-bridge.js                    batch opening, read, select before archive and trash,
│                                         trashSimilar with senders, selftestLocal selectSubset,
│                                         selftestSelection
├── Sources/
│   ├── MailCore/
│   │   ├── BatchSession.swift            new: rows, read-ahead, recommendation queue, scope,
│   │   │                                 actions, learning
│   │   ├── LabelPicker.swift             new, moved from RecommenderSession: label rows and highlight
│   │   ├── Learning.swift                new, moved from RecommenderSession: decision to feedback
│   │   ├── MailAdvice.swift              new, moved from RecommenderSession: result and error texts
│   │   ├── RecommenderSession.swift      uses the three files above; starts from a given opening
│   │   └── MailSource.swift              read, select-aware archive and trash, trashSimilar(senders:);
│   │                                     MailMessageRef from and subject, MailOpening viewed
│   └── CategoryRecommender/
│       ├── BatchView.swift               new: List, Choose a label, confirmation, notices
│       ├── PanelController.swift         reads opening, opens the single or batch window, keys
│       ├── ScriptedMail.swift            the new bridge commands
│       ├── DemoMail.swift                a synthetic batch of six emails
│       └── main.swift                    --batch, --self-test-selection, batch drive
├── Tests/MailCoreTests/
│   ├── BatchSessionTests.swift           new
│   └── SessionTests.swift                FakeMail gains the new methods and records every Message-ID
└── tests/
    ├── mail-bridge.test.mjs              batch opening, read, select, trashSimilar senders
    └── e2e.sh                            a batch through the real service
```

**Structure Decision**: The feature is entirely in the existing `mail-app/` component. `service/` and its HTTP contract do not change, so the web UI and older Mail app builds are unaffected.

## Documentation

Required by Principle VII, in the same change:

| Document | Update |
|----------|--------|
| `README.md` | Use > macOS Mail: select several emails to get one recommendation each, approve all with Command-Return or decide row by row. |
| `mail-app/README.md` | The batch window and its keys; `--self-test-selection`; `--demo --batch`; the note about Organize by Conversation if the owner's check shows it matters. |
| `docs/architecture.md` | Mail app: `BatchSession` and the shared files; the bridge selects emails before Archive and Delete. Data: the emails of a batch, in the Mail app's memory while the window is open. |
| `specs/002-mail-app-integration/spec.md` | A note under Story 1, scenario 4, that spec 004 replaces it. |

## Verification

- **Synthetic, automatic**: `scripts/test.sh`, `tests/e2e.sh`, the batch demo snapshot and keyboard drive ([quickstart.md](quickstart.md) sections 1 to 3). They cover SC-001, SC-002 and SC-005 to SC-007 with synthetic data, and SC-003 for the window itself.
- **Real Mail, synthetic emails**: `--self-test-local` with `selectSubset` (quickstart section 4).
- **Real account, owner-run**: `--self-test-selection` with conversations on and off, then one real batch (quickstart section 5). This is the check for research R1 on Gmail, and for SC-003 and SC-004 on the owner's own Inbox.
- **Not verified by the assistant**: anything on the real account, by Principle II.

## Complexity Tracking

No violations. Swift for the Mail app was justified in [002](../002-mail-app-integration/plan.md#complexity-tracking), and this feature adds no language, service or datastore.
