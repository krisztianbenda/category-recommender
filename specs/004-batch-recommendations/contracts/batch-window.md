# Contract: Batch Window

What the owner sees and can do when the recommender is triggered with more than one email selected. The single-email window ([002](../../002-mail-app-integration/spec.md)) does not change.

## Window

The same floating panel as the single window: it does not activate the app, so Mail stays the active app while the panel has the keyboard. It is 600 × 560 points for a batch, at the top right of the screen.

It has two views: **List** and **Choose a label**. An overlay can sit on top of either for a confirmation.

## List

Header: "N emails", and "M more were selected and left out" when the batch was capped.

One row per email, newest first:

| Part | Shows |
|------|-------|
| Mark | A check box, on when the row is marked |
| Email | Subject (one line), sender (one line, secondary) |
| Recommendation | The label path, "New: path", or "Move to Trash", with a confidence badge (high, medium, low). A spinner while waiting, or "No recommendation" with the reason on hover |
| State | Nothing while undecided; "Skipped"; "Applying…"; "Filed in path" or "Moved to the Trash" when done; the notice when there is one |

Done rows stay in the list, dimmed, so the owner can see what happened. A problem row stays undimmed with its reason.

Footer:

- Progress: "12 of 20 ready".
- Keep in Inbox: the same setting as the single window, shown only for accounts where it applies.
- Buttons: **Approve all (12)** (Command-Return), **Choose label…** (→), **Move to Trash** (Command-Delete). When rows are marked, the last two read "for 3 marked", and a fourth button **Approve 3 marked** (Return) appears.

## Scope

Every action except approve all acts on the **scope**: the marked rows if any row is marked, else the highlighted row. Approve all acts on every row that is ready, has a recommendation, and is not skipped, applying or done. Neither includes rows that are already applying or done.

## Keys in the list

| Key | Action |
|-----|--------|
| Up, Down | Move the highlight. |
| Space | Mark or unmark the highlighted row. |
| Command-A | Mark every row that is not done. Again: unmark all. |
| Return | Accept the scope's recommendations. Rows in the scope without one are left as they are, and the footer says how many. |
| Command-Return | Approve all. |
| Right, Tab | Choose a label for the scope. |
| Any letter or digit | Choose a label for the scope, with that character as the search. |
| Command-Delete | Move the scope to the Trash. |
| Delete (Backspace) | Skip or unskip the scope. |
| Escape | Close the window. Undecided emails are left as they are. |

## Choose a label

The single window's label list and search, for the scope. Above the list: "For: subject" or "For 3 emails", and, for one row with a recommendation, its reason and alternatives (FR-008).

| Key | Action |
|-----|--------|
| Type | Search the labels, or name a new one. |
| Up, Down | Move the highlight. |
| Return | File the scope under the highlighted label, or create it. Back to the list. |
| Command-N | New label, with the search as its name. |
| Command-Delete | Move the scope to the Trash. Edits the text while there is any, as in the single window. |
| Escape, Left with an empty search | Back to the list, without changing anything. |

Deleting a label is not offered here (spec, Assumptions).

### New label

Opened with **New label…** next to the search, or Command-N. It takes the place of the search and the list, like Mail's own New Mailbox (FR-011):

- **Name**: starts as the search. "Trips/Lis" starts as "Lis" inside Trips when Trips is a label.
- **Location**: **Top level**, or any label, to make a sub-label of it. A label deeper than two levels sits in the recommender as `Work/Clients › Acme`, as when it is made in Mail.
- Below them, what Return will do: "Creates “Trips/Lisbon” and files the 3 emails under it." If a label of that name is there already, with case and accents folded as the service does, it files under that one instead of making a second. One of the account's own mailboxes, such as Inbox, is refused.

| Key | Action |
|-----|--------|
| Type | Edit the name. |
| Up, Down | Move the location: Top level first, then the labels in the list's order. |
| Return | Create the label and file the scope under it (FR-019: once for all of them). Back to the list. |
| Escape | Back to the search and the list, as they were. |

## Confirmation

Shown before any action that covers more than one row and moves at least one to the Trash (FR-014):

> File 8 emails and move 2 to the Trash?

Return confirms, Escape cancels. One row to the Trash, as in the single window, needs no confirmation.

## Notices

- Per row: why it was not applied, or "Not learned: reason", or "Labelled, but still in the Inbox".
- Once per window, above the footer: advice that applies to many rows, for example the Accessibility setting, with the same text as the single window.

## Closing

- The window closes by itself when every row is done with no notice.
- Escape or the close button closes it at any time. Recommendations still being made for undecided rows stop. Rows already applied and waiting for their recommendation finish learning in the background.

## Demo and checks

- `--demo --batch`: a synthetic batch of six emails (two for one label, one for another, one new-label proposal, one newsletter like three in the synthetic Trash, one with no text).
- `--demo --batch --snapshot path.png`: draws the window when every recommendation is ready.
- `--demo --batch --drive report.json`: presses keys through the real event path against the synthetic Mail and reports what happened: highlight moves, Space marks, Return applies only the scope, Command-Return applies only ready rows, the confirmation appears before a multi-row Trash, Escape leaves undecided emails untouched.
