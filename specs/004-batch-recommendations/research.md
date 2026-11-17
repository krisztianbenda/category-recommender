# Research: Batch Recommendations

Decisions behind [plan.md](plan.md). Each one records what was chosen, why, and what else was considered. Findings about Mail come from the code and measurements of specs 002 and 003; the ones that still need a check on real Mail are marked **verify**.

## R1. Acting on some of the selected emails with Mail's own commands

**Problem.** Labelling is scripted per email, by id, so it can act on any subset. Taking an email out of the Inbox (Archive) and moving it to the Trash (Delete) are not: both click Mail's own menu command, which acts on Mail's selection. Today the bridge refuses unless Mail's selection is exactly the emails (`selectionChanged`). In a batch, the owner acts on one row or a few rows while many more are selected, and may click around in Mail between actions (FR-004, FR-018).

**Decision.** Before Archive or Delete, the bridge sets Mail's selection to exactly the emails of the action, reads the selection back, and clicks the command only if the Message-IDs match exactly. Otherwise nothing is clicked and the result is `selectionChanged`, as today.

- Selecting is AppleScript run in-process through `NSAppleScript`, as `showMailbox` already does for mailboxes, because JXA cannot set a viewer's selection properties: `set selected messages of message viewer 1 to {message id N of mailbox "…" of account "…", …}`. Names are escaped with the existing `appleScriptText`, and ids are integers.
- References are tried in this order until the read-back matches: the message objects Mail was showing when the batch opened (`viewId` in `viewMailbox`, which for Gmail is All Mail), then the copies that filing uses (`id` in `mailbox`). If neither matches, the bridge shows the mailbox the owner was viewing when the batch opened and tries once more.
- The read-back is the safety check, as it is today. Whatever Mail does with a selection request, the command never runs unless Mail's selection is exactly the action's emails.
- Archive and Delete for one action run once each, on all of that action's emails together, so a 20-row "approve all" clicks at most two menu commands.

**Verify.** That Mail accepts `selected messages` from a script and highlights those emails, both with **Organize by Conversation** on and off. The local self-test checks it on fabricated emails under On My Mac. An owner-run check on the real account selects two of three emails and reads the selection back, reporting pass or fail only. If Mail refuses to select single emails of a collapsed conversation, those rows report `selectionChanged` and stay labelled in the Inbox with a notice, which is today's behaviour when the selection changed.

**Alternatives considered.**

- *Ask the owner to select the emails in Mail before each action*: defeats approving with one action.
- *Script Gmail's Inbox removal directly*: 002 measured that scripted moves only add a label and that marking a copy deleted crashes Mail.
- *Act on Mail's selection only when it is a superset*: Mail's command would act on emails outside the action, which FR-018 and SC-005 forbid.

## R2. Opening a batch within one second

**Problem.** For one email, `opening` reads the newest email's text and finds, for each selected email, the copy that filing must act on (`placed`, a `whose` search by Message-ID in the viewed mailbox and the Inbox). For 50 emails that is 50 bodies and up to 100 searches, which can take many seconds on a large Inbox. SC-003 wants every row's sender and subject within one second.

**Decision.** When more than one email is selected, `opening` returns light references: the view reference, date, Message-ID, sender and subject. No body, no placement. A new bridge command, `read`, takes a few references and returns each one's placement (id, mailbox, whether it is in the Inbox) and its text. The batch reads ahead of the model in chunks of five, in the background, so every row can be acted on within seconds while recommendations take minutes. `opening` also returns the mailboxes the owner was viewing, so `read` finds the same copies even if the owner moves elsewhere in Mail later.

One email selected keeps today's `opening` exactly.

**Alternatives considered.** *Read everything in `opening`*: misses SC-003 on a large Inbox. *Read each email just before its recommendation*: an early action on a later row would wait for the model's pace.

## R3. Which emails go in the batch

**Decision.** At most 50 (FR-003). When more are selected, the bridge reads the dates of up to 1,000 selected emails in one property read and keeps the 50 newest. `total` still reports the full selection, so the window can say how many were left out. Rows are listed newest first, as an Inbox is.

**Rationale.** Today's `MAX_MESSAGES` of 200 exists for filing a whole selection under one label. With one recommendation per email, 50 already means about 12 minutes of model time at 15 seconds each. Above 1,000 selected, the oldest are not looked at, and the window says so.

## R4. The order recommendations are made in

**Decision.** One at a time, in row order, as today, because the service runs one inference at a time to fit the reference host's memory (constitution V). Rows the owner decides by hand before their recommendation go to the back of the queue: their recommendation is only needed for learning. Undecided rows therefore get their recommendations sooner.

Every decision is learned at once, so recommendations made after a decision can use it. Recommendations already shown are not made again, which would double the waiting for a small gain.

**Alternatives considered.** *Parallel requests*: the service queues them anyway, and each would wait inside the HTTP timeout. *A batch endpoint in the service*: same model time, and a new contract to version, for no gain the client cannot get by itself.

## R5. Learning when several rows share a new label

**Problem.** `accept_new` creates the category, and a later `choose` must name one of the suggestion's original candidates (HTTP contract, feedback). When two rows were recommended the same new label, or the owner types one new label for several marked rows, only the first can use `accept_new`. The others' suggestions were made before the category existed.

**Decision.** The first row sends `accept_new`. Each other row in the same action teaches through a fresh suggestion and `choose`, as the single-email window already does for a new label under a new parent (`addThenChoose`), without adding the category again. This runs after Mail has filed the emails, so the owner does not wait. The fresh suggestions join the same one-at-a-time queue, behind the rows still waiting.

**Alternatives considered.** *Let the service accept `choose` for a category added to the set after the suggestion*: a contract change in the service for a rare case. It would save one inference per extra row, and can be added later if the eval shows it matters.

## R6. Trash evidence and Trash eligibility for many emails

**Problem.** `trashSimilar` reads the Trash for one sender and says whether any of the given emails is in the Trash already. A batch has many senders, and needs to know per email whether Move to Trash is allowed (an email in the Trash must never be deleted again).

**Decision.** `trashSimilar` takes a list of senders and returns the matches per sender address. It returns `inTrashIds`, the given emails that are in the Trash already, instead of one flag (the flag stays for the single window). The batch calls it once, in the background, right after opening, with every distinct sender and every Message-ID of the batch. Matches are excluded if they are emails of the batch.

## R7. Code shared between the single-email and batch windows

**Decision.** A new `BatchSession` in `MailCore` holds the batch's state. `RecommenderSession` stays the single-email session. The parts both need move out of `RecommenderSession` into small types without changing their behaviour:

| New file | Moved from `RecommenderSession` | Used by |
|----------|-------------------------------|---------|
| `LabelPicker.swift` | the label rows for a suggestion and a search query (`rebuildRows`, highlight movement) | the single window, and the batch's "choose a label" view |
| `Learning.swift` | the mapping from a suggestion and a decision to feedback (`sendFeedback`, `addThenChoose`) | both sessions |
| `MailAdvice.swift` | the texts for archive and Trash results (`menuAdvice`, `trashProblem`, `describe`) | both sessions |

The panel reads `opening` first and then creates one session or the other, so the decision about single or batch is made once, from what Mail returned (FR-001).

**Alternatives considered.** *One session that handles one or many emails*: the single window's state (one highlighted label, one recommendation, closing after filing) would become conditional everywhere, and 002's tests would have to be rewritten.

## R8. The batch window

**Decision.** The same floating, non-activating panel, wider (600 × 560) when it holds a batch. It has two views:

- **List**: one row per email with sender, subject, the recommended action and confidence, and the row's state. A footer shows progress ("12 of 20 ready"), Keep in Inbox, and the actions.
- **Choose a label**: the single window's label list and search, for the highlighted row or the marked rows, with the row's reason and alternatives above it. Escape returns to the list.

The keyboard rule is one scope for every action: the marked rows if any are marked, else the highlighted row. Return accepts the scope's recommendations, Command-Return approves every ready row, Command-Delete moves the scope to the Trash, and typing opens Choose a label with the text as the search. The full contract is in [contracts/batch-window.md](contracts/batch-window.md).

**Rationale.** Keeps the single window's habits (Return accepts, Command-Delete trashes, typing searches) and adds only Space to mark, Backspace to skip, and Command-Return.

## R9. Time limits

The service keeps a pending suggestion for `suggestions.ttlSeconds`, an hour by default. A full batch of 50 takes about 12 minutes of model time. A decision on a suggestion that has expired is still applied in Mail, and its row says it was not learned, as the single window does for any failed feedback. No change is needed in the service.

Bridge timeouts scale with the number of emails, as `file` does today: Trash arrival waits 15 seconds plus one per email, Archive 10 plus one per email.
