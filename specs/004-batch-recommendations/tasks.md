---

description: "Task list for Batch Recommendations"
---

# Tasks: Batch Recommendations

**Input**: Design documents from `/specs/004-batch-recommendations/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Included. The plan defines `BatchSessionTests`, bridge tests, the end-to-end script, the demo drive and the self-tests, and the constitution requires the outbound-network check. Write each story's tests first and see them fail.

**Data rule (constitution II)**: Every fixture, test, demo and example uses fabricated, synthetic emails and labels only (`*.example.test` addresses). Nothing here runs against the owner's real account; the one real-account check (T041) is run by the owner.

**Organization**: Tasks are grouped by user story. All paths are relative to the repository root. Only `mail-app/` and documentation change; `service/` does not.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: The user story the task belongs to (US1–US3)

---

## Phase 1: Setup

**Purpose**: Synthetic material every later task tests against

- [X] T001 [P] Add a synthetic batch of six emails to `mail-app/Sources/CategoryRecommender/DemoMail.swift` behind a `DemoMail.batch()` factory: two for `Family/Baby`, one for `Finance/Invoices`, one that gets a new-label proposal (`Travelling/Trip Porto`), one newsletter from `deals@shop.example.test` like the three in the synthetic Trash, and one with neither subject nor text. Each has a distinct Message-ID `demo-N@example.test`, a date, and `inInbox: true`. Record every Message-ID passed to `file`, `archive` and `moveToTrash`.
- [X] T002 [P] Extend the fake Mail in `mail-app/tests/mail-bridge.test.mjs` with a selection that a script can set (`selectedMessages` read and write), a viewed mailbox, messages in All Mail with copies in `INBOX`, and a Trash holding two messages from `deals@shop.example.test`, so the bridge tests below can run without Mail.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The bridge commands, the `MailSource` additions, the code moved out of `RecommenderSession`, and the batch session's core, which every story uses

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

### Tests for the foundation

- [X] T003 [P] Bridge tests in `mail-app/tests/mail-bridge.test.mjs` for [contracts/mail-bridge.md](./contracts/mail-bridge.md):
  - with two or more selected, `opening` returns at most 50 messages, newest first, each with `from` and `subject` and no `inInbox`, `latest: null`, `total` equal to the whole selection, and `viewed`; with one selected, the output is unchanged
  - `read` returns `placement` (`id`, `mailbox`, `inInbox`) and `email` per ref, and `found: false` for a gone message
  - `archive` and `trash` with `select` set the selection, and return `selectionChanged` with no menu click when the read-back differs from `messageIds`; they click when it matches; without `select` they behave as today
  - `archive` with `stillThere` and `trash` with `notInTrash` return `left`
  - `trashSimilar` with `senders` returns `bySender` keyed by lower-case address, excludes `messageIds`, and returns `inTrashIds`; `sender` alone still returns `messages`
- [X] T004 [P] Swift tests in `mail-app/Tests/MailCoreTests/SessionTests.swift`: extend `FakeMail` with `read`, select-aware `archive` and `moveToTrash`, and `trashSimilar(senders:)`, and record every Message-ID it is asked to change. Existing single-window tests must still pass unchanged after T009–T012.

### Implementation of the foundation

- [X] T005 Change `opening` in `mail-app/Resources/mail-bridge.js`: when more than one email is selected, read `dateReceived` of up to 1,000 selected emails in one property read, keep the 50 newest (`MAX_BATCH = 50`), and return light refs `{ id, mailbox, account, date, messageId, from, subject }` with no `placed()` search and no text, `latest: null`, `total` = selection length, and `viewed` = `viewedPaths(account)`. One selected: unchanged.
- [X] T006 Add the `read` command to `mail-app/Resources/mail-bridge.js`: for each `{ id, mailbox, messageId }` resolve the message, find its placement with the existing `placed()` using the given `viewed` paths, and return `{ messageId, found, placement: { id, mailbox, inInbox }, email: readEmail(...) }`; `found: false` with no other fields when it cannot be resolved. Reading never changes a message.
- [X] T007 Add selection to `archive` and `trash` in `mail-app/Resources/mail-bridge.js`: a `selectMessages(account, refs)` helper that runs `set selected messages of message viewer 1 to {message id N of mailbox … of account …}` through `NSAppleScript` (names escaped with `appleScriptText`, ids as integers, mailbox references built per path segment as `showMailbox` does), then compares `selectedMessageIds()` with `messageIds` using `sameSet`. Try `view` refs, then `placement` refs, then `showMailbox(viewed[0])` and `view` refs once more; on no match return `{ result: 'selectionChanged' }` before any click. Add `left` to `stillThere` and `notInTrash`, and make the waits 10 + 1 per email (Archive) and 15 + 1 per email (Trash).
- [X] T008 Change `trashSimilar` in `mail-app/Resources/mail-bridge.js` to accept `senders`, returning `bySender` (per lower-case address, newest first, at most `limit`, excluding `messageIds`) and `inTrashIds`; keep `sender`, `inTrash` and `messages` for the single window.
- [X] T009 [P] Add the Swift side in `mail-app/Sources/MailCore/MailSource.swift`: optional `from` and `subject` on `MailMessageRef`, optional `viewed` on `MailOpening`, new types `ReadEmail`, `SelectedEmail` (`messageId`, `view`, `placement`), `ArchiveOutcome` and `TrashOutcome` (result plus `left`), `TrashLookups` (`found`, `inTrashIds`, `bySender`), and the four protocol methods from the contract. Keep the existing methods.
- [X] T010 Implement the new methods in `mail-app/Sources/CategoryRecommender/ScriptedMail.swift`: `read` in calls of at most 5 refs with a timeout of 20 + 3 per ref, select-aware `archive` and `moveToTrash` with the existing menu titles and a timeout of 120 + 2 per email, and `trashSimilar(senders:)` with a timeout of 30 + 1 per sender. Implement them in `DemoMail.swift` too.
- [X] T011 [P] Move the label rows for a suggestion and a query (`rebuildRows`, `row`, highlight movement) out of `RecommenderSession` into a `LabelPicker` type in `mail-app/Sources/MailCore/LabelPicker.swift`, taking the catalog, a `Suggestion?`, `canTrash`, deleted keys and the query. `RecommenderSession` uses it, with no change in behaviour.
- [X] T012 [P] Move the decision-to-feedback mapping (`sendFeedback`, `addThenChoose`) into `mail-app/Sources/MailCore/Learning.swift`, and the result and error texts (`menuAdvice`, `trashProblem`, `describe`) into `mail-app/Sources/MailCore/MailAdvice.swift`. Add a parameter to skip adding a category that an earlier row already added (research R5). `RecommenderSession` uses both, with no change in behaviour.
- [X] T013 Let `RecommenderSession` in `mail-app/Sources/MailCore/RecommenderSession.swift` start from a given `MailOpening` (`start(with:)`) as well as reading it itself, so the panel reads `opening` once.
- [X] T014 Create `BatchSession` in `mail-app/Sources/MailCore/BatchSession.swift` with the Batch and Batch row fields of [data-model.md](./data-model.md): build rows from the opening (block with the existing reasons when Mail is not running, nothing is selected, or the emails are not "all in one account"); sync labels once with `LabelSync.run`; call `trashSimilar(senders:)` once in the background with every distinct sender and every Message-ID, and set each row's `inTrash` from `inTrashIds`; read rows ahead in chunks of 5 in the background, independent of the model.
- [X] T015 Add the recommendation queue to `BatchSession`: one `api.suggest` at a time, in row order, with the row's own `trash` evidence from `bySender` and `allowDelete` only when the account has a Trash and the row is not `inTrash`; rows the owner already decided go to the back; an email with neither subject nor text gets `unavailable` with the single window's message; keep the single window's one retry on `llm_unavailable`; `ensureRunning` and `noteActivity` as in the single window.
- [X] T016 Add the action executor to `BatchSession` per [data-model.md § Action](./data-model.md#action): wait for placement of every row in the action; run actions one at a time in the order given; create each new label once by `LabelText.pathKey` (FR-019); file with one `mail.file` per target using `Filing.mode`; for Gmail, archive all `move` rows in one select-aware call; move Trash rows in one select-aware call, never sending a row with `inTrash`; mark failed rows `problem` with the reason from `MailAdvice` while the others continue (FR-021); then learn each applied row through `Learning`, at once if its recommendation exists, else when it arrives (FR-022, FR-023). Validation rules: "No action covers a row in `applying`, `applied` or `done`", "Move to Trash is never sent for a row with `inTrash`, or when the account has no Trash".
- [X] T017 Route in `mail-app/Sources/CategoryRecommender/PanelController.swift`: read `opening` once, open the single window (400 × 540) with `RecommenderSession.start(with:)` when one email is selected, and the batch window (600 × 560) with a `BatchSession` when more than one is; closing cancels the queue for undecided rows and lets applied rows finish learning in the background.
- [X] T018 Create the List view in `mail-app/Sources/CategoryRecommender/BatchView.swift` per [contracts/batch-window.md § List](./contracts/batch-window.md#list): header with the count and "M more were selected and left out", one row per email (subject, sender, recommendation with confidence badge or spinner or "No recommendation", state), done rows dimmed, the highlight, and a footer with progress "N of M ready" and Keep in Inbox. Up, Down and Escape work.
- [X] T019 Log batch events in `mail-app/Sources/CategoryRecommender/EventLog.swift` callers: `batch_opened` with row count and left-out count, `batch_action` with rows applied and failed counts by reason, `batch_closed` with undecided count. Counts and durations only, never names or text.

**Checkpoint**: A batch opens with every sender and subject, recommendations fill in one by one, and nothing can be applied yet

---

## Phase 3: User Story 1 - Approve every recommendation at once (Priority: P1) 🎯 MVP

**Goal**: One action applies every ready recommendation, each email to its own label or the Trash

**Independent Test**: With `--demo --batch`, wait for all recommendations, press Command-Return, confirm, and check each synthetic email went to its own target and one decision was learned per email

### Tests for User Story 1

- [X] T020 [P] [US1] `BatchSessionTests` in `mail-app/Tests/MailCoreTests/BatchSessionTests.swift`: approve all applies only rows that are ready with a suggestion and not skipped, applying or done; waiting rows stay untouched; each row is filed under its own recommended label and learned as `confirm`; a Trash recommendation is moved and learned as `confirm`; two rows with the same new-label proposal create the label once, the first learns with `confirm` and the second with a fresh suggestion and `choose`; a failed target leaves other targets applied; `FakeMail` saw no Message-ID outside the action (SC-005); each `suggest` request body equals the one `RecommenderSession` sends for the same email (SC-006)
- [X] T021 [P] [US1] Add a batch section to `mail-app/tests/e2e.sh`: a synthetic batch through the real service with the stub model, approve all, and check each email got its own label, the service recorded one decision per email, and the app's sockets reach only this computer (SC-007)

### Implementation for User Story 1

- [X] T022 [US1] Add `approveAll()` to `mail-app/Sources/MailCore/BatchSession.swift`, building an action from every eligible row (FR-010), and a `pendingConfirmation` with file and Trash counts when the action covers more than one row and moves any to the Trash (FR-014)
- [X] T023 [US1] Add to `mail-app/Sources/CategoryRecommender/BatchView.swift` the **Approve all (N)** button and the confirmation overlay "File 8 emails and move 2 to the Trash?" (Return confirms, Escape cancels), per-row results ("Filed in path", "Moved to the Trash", notices), and the window notice for advice that applies to many rows
- [X] T024 [US1] Bind Command-Return to approve all in `mail-app/Sources/CategoryRecommender/PanelController.swift`, and close the window by itself when every row is `done` with no notice
- [X] T025 [US1] Add `--demo --batch` and `--demo --batch --snapshot path.png` (snapshot once every recommendation is ready) to `mail-app/Sources/CategoryRecommender/main.swift`

**Checkpoint**: A batch can be approved in two actions plus one confirmation (SC-001)

---

## Phase 4: User Story 2 - Decide one email at a time (Priority: P1)

**Goal**: Accept, change or trash any single row, applied to that email only

**Independent Test**: With `--demo --batch`, accept the first row with Return, pick another label for the second, Command-Delete the third, and check each email is where it was put, with one confirmation, one correction and one deletion learned, and no other email changed

### Tests for User Story 2

- [X] T026 [P] [US2] `BatchSessionTests` in `mail-app/Tests/MailCoreTests/BatchSessionTests.swift`: Return on a row files only that email and learns `confirm`; another label learns `choose`; Move to Trash on a row learns `delete` (as `confirm` when it was recommended); one row to the Trash needs no confirmation; a row decided before its recommendation is applied at once and learned when the recommendation arrives, and its recommendation was moved to the back of the queue; closing with undecided rows changes and learns nothing for them; a row whose email is gone shows `problem` and learns nothing; filed but feedback failed shows "not learned"

### Implementation for User Story 2

- [X] T027 [US2] Add `accept(row)`, `file(row, under:)`, `create(row, path:)` and `trash(row)` to `mail-app/Sources/MailCore/BatchSession.swift`, each building a one-row action (FR-011, FR-015)
- [X] T028 [US2] Add the Choose a label view to `mail-app/Sources/CategoryRecommender/BatchView.swift` per [contracts/batch-window.md § Choose a label](./contracts/batch-window.md#choose-a-label), reusing `LabelPicker` and the single window's label list: "For: subject", the row's reason and alternatives, search, Return files and returns to the list, Escape or Left with an empty search returns without changes; no label deletion
- [X] T029 [US2] Bind keys in `mail-app/Sources/CategoryRecommender/PanelController.swift` for the list: Return accepts the highlighted row, Right or Tab opens Choose a label, a letter or digit opens it with that character as the search, Command-Delete moves the row to the Trash (FR-017)
- [X] T030 [US2] Add `--demo --batch --drive report.json` to `mail-app/Sources/CategoryRecommender/main.swift`: press keys through the real event path and report highlight moves, Return applies only the highlighted row, typing opens Choose a label with the search, Command-Delete trashes one row, Escape leaves undecided emails untouched

**Checkpoint**: Every row can be decided on its own (SC-002)

---

## Phase 5: User Story 3 - Approve or redirect only some of them (Priority: P2)

**Goal**: Mark rows to approve them together, send them to one label or the Trash, or skip rows

**Independent Test**: With `--demo --batch`, mark three rows and press Return, check only those changed; mark the rest, choose one label, check all are under it with the right confirmations and corrections

### Tests for User Story 3

- [X] T031 [P] [US3] `BatchSessionTests` in `mail-app/Tests/MailCoreTests/BatchSessionTests.swift`: the scope is the marked rows if any, else the highlighted row; Return on marked rows applies each one's own recommendation and leaves unmarked rows untouched; one label for marked rows learns `confirm` where it was recommended and `choose` otherwise; a typed new label for marked rows is created once and learned per row (research R5); marked rows to the Trash need confirmation; a skipped row is left out of approve all and untouched on close; Command-A marks every row that is not done, and again unmarks all

### Implementation for User Story 3

- [X] T032 [US3] Add `marked` and `skipped` handling and the scope rule to `mail-app/Sources/MailCore/BatchSession.swift`, and make `accept`, `file`, `create` and `trash` act on the scope (FR-012, FR-013)
- [X] T033 [US3] Show marks and "Skipped" in `mail-app/Sources/CategoryRecommender/BatchView.swift`, the **Approve N marked** button, "for N marked" on the other buttons, and "For N emails" in Choose a label
- [X] T034 [US3] Bind Space (mark), Command-A (mark all, again to unmark) and Delete (skip or unskip) in `mail-app/Sources/CategoryRecommender/PanelController.swift`, and extend the drive in `mail-app/Sources/CategoryRecommender/main.swift` to report that Space marks, Return applies only the marked rows, and the confirmation appears before a multi-row Trash

**Checkpoint**: All three stories work; today's "file the whole selection under one label" is Command-A then a label

**Notes from implementation**: The analysis findings were folded in. C1: a label gone from the account is created again when filing finds it missing (`BatchSession.file`). U1: fresh suggestions for learning go through the batch's one-at-a-time `ModelGate`, in arrival order. I2: batch rows say "Mail would not select just this email" with the conversation advice (`MailAdvice.batchArchive`, `batchTrash`). P1: T011 and T012 were done one after the other.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T035 [P] Add the `selectSubset` step to `selftestLocal` in `mail-app/Resources/mail-bridge.js`, and make `syntheticMailbox` in `mail-app/Sources/CategoryRecommender/ScriptedMail.swift` write three fabricated messages (`catrec-selftest-<stamp>-1..3@example.test`); pass or fail only
- [X] T036 [P] Add the owner-run `selftestSelection` command to `mail-app/Resources/mail-bridge.js` (add it to `CHECKS`) and `--self-test-selection` to `mail-app/Sources/CategoryRecommender/main.swift`: needs three or more emails selected in the Inbox, selects the first two by `view` and by `placement` refs, reads back, restores the original selection, and reports `conversationView`, `selectView`, `selectPlacement` and `restored` as booleans or pass or fail only. It changes no email.
- [X] T037 [P] Update `README.md` (Use > macOS Mail: several emails get one recommendation each; Command-Return approves all; or decide row by row)
- [X] T038 [P] Update `mail-app/README.md`: the batch window and its keys from [contracts/batch-window.md](./contracts/batch-window.md), `--self-test-selection`, `--demo --batch`
- [X] T039 [P] Update `docs/architecture.md`: the Mail app's `BatchSession`, `LabelPicker`, `Learning` and `MailAdvice`; the bridge selecting emails before Archive and Delete; a Data row "Emails of a batch: Mail app memory, while the window is open"
- [X] T040 [P] Add a note under Story 1, scenario 4 of `specs/002-mail-app-integration/spec.md` that spec 004 replaces it
- [X] T041 (Sections 1 to 3 and the service checks passed here. Sections 4 and 5 drive the real Mail and are left to the owner.) Run [quickstart.md](./quickstart.md) sections 1 to 4 (`mail-app/scripts/test.sh`, demo snapshot and drive, `mail-app/tests/e2e.sh`, `--self-test-local`), and `cd service && npm test && npm run lint` to confirm the service is unchanged. Hand section 5 (`--self-test-selection` with Organize by Conversation on and off, then a real batch) to the owner; if selecting fails within conversations, add the advice to `mail-app/README.md`.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: none
- **Foundational (Phase 2)**: after Setup; blocks every story
- **US1 (Phase 3)**: after Foundational
- **US2 (Phase 4)**: after Foundational. Independent of US1 in the session; shares `BatchView.swift` and `PanelController.swift`, so do it after US1 when one person works on it
- **US3 (Phase 5)**: after Foundational. Its scope rule changes the actions of US2 (T027), so do it after US2
- **Polish (Phase 6)**: T035, T036 and T040 any time after Foundational; T037–T039 after the stories they describe; T041 last

### Within Phase 2

- T005–T008 are one file (`mail-bridge.js`): in order
- T009 before T010, T013, T014
- T011 and T012 before T013 and T014
- T014 → T015 → T016 (one file) → T017 → T018

### Parallel opportunities

- T001 and T002
- T003 and T004, and T009, T011, T012 alongside the bridge work T005–T008
- The test tasks at the start of each story
- T035–T040

### Parallel example: Phase 2

```text
Bridge:   T005 → T006 → T007 → T008
Swift:    T009, T011, T012 (three files) → T013 → T014 → T015 → T016 → T017 → T018
Tests:    T003 (bridge), T004 (FakeMail)
```

## Implementation Strategy

### MVP (User Story 1)

1. Setup and Foundational
2. US1: approve all with confirmation
3. Stop and validate with `--demo --batch` and the e2e batch section. This already beats today's behaviour, since each email gets its own label.

### Incremental delivery

1. + US2: fix one wrong row without leaving the batch
2. + US3: marks, skip, one label for many (restores today's "all under one label")
3. Polish: self-tests, documentation (required by Principle VII before the change is complete), and the owner's real-account check
