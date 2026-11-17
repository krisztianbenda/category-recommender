# Data Model: Batch Recommendations

Everything here lives in the Mail app's memory while the batch window is open. Nothing is stored on disk, and the service's data model ([001 data-model](../001-local-llm-categorizer/data-model.md)) does not change: each decision becomes one learning example and one decision row, exactly as for a single email.

## Batch

The emails selected when the window opened (FR-004).

| Field | Meaning |
|-------|---------|
| `account` | The one account all rows belong to. A selection across accounts is blocked, as today. |
| `viewed` | Mailbox paths the owner was viewing when the batch opened. `read` and selecting in Mail use them. |
| `total` | How many emails were selected in Mail. `total - rows.count` were left out (FR-003). |
| `rows` | At most 50 batch rows, newest first. |
| `setId`, `catalog` | The category set and labels, synced once per batch. |
| `trash` | Trash matches per sender address, and whether the account has a Trash. Read once per batch. |
| `keepInInbox` | The owner's existing setting, shared with the single window. |

## Batch row

One email of the batch.

| Field | Meaning |
|-------|---------|
| `ref` | The light reference from `opening`: view reference, Message-ID, date, sender, subject. |
| `placement` | From `read`: the copy that filing acts on, and whether it is in the Inbox. Nil until read. |
| `email` | From `read`: the prepared text sent to the service. Nil until read. |
| `recommendation` | `waiting`, `thinking`, `ready(Suggestion)` or `unavailable(reason)`. |
| `inTrash` | The email is in the Trash already, so Move to Trash is neither recommended nor offered. |
| `marked` | Part of the current scope for actions. |
| `skipped` | Left out of "approve all". It stays untouched when the window closes (FR-013). |
| `state` | See below. |
| `decision` | What the owner chose, once they chose. |
| `notice` | Why it could not be applied, or what is left to do (for example "still in the Inbox"). |

### States

```text
pending ──read and recommended──▶ ready
   │                                │
   └────────── owner acts ──────────┘
                   ▼
               applying ──Mail failed──▶ problem ──owner acts again──▶ applying
                   │
               Mail done
                   ▼
               applied ──feedback sent, once the recommendation exists──▶ done
```

- **pending**: not read or not recommended yet. The owner can still decide it (FR-015).
- **ready**: has a recommendation, or `unavailable` with a reason. Only `ready` rows with a suggestion are in "approve all".
- **applying**: queued or running in Mail. Actions run one at a time, in the order the owner gave them.
- **applied**: Mail did it. Feedback is sent when the row's recommendation exists; a row decided before its recommendation waits here for it.
- **done**: applied and learned, or applied with the notice that it was not learned.
- **problem**: Mail could not apply it (gone, label removed, selection could not be set). Nothing was learned, and the row can be decided again.

A skipped row stays in `pending` or `ready`. Closing the window cancels the recommendations of rows the owner did not decide. Rows that are `applied` and waiting for their recommendation keep it running in the background until they are learned, as the single window does.

The window closes by itself when every row is `done` with no notice. Otherwise the owner closes it.

## Decision

What the owner chose for one row, and what is learned. The mapping is the single window's, moved into `Learning.swift` (research R7).

| Owner's choice | Recommendation was | Feedback |
|----------------|--------------------|----------|
| Accept (row, marked rows or approve all) | an existing label | `confirm` |
| Accept | a new label, first row of the action with it | `confirm` (`accept_new` when deletion was recommended) |
| Accept | a new label already created by an earlier row | fresh suggestion, then `choose` (research R5) |
| Accept | Move to Trash | `confirm`, which means delete |
| Another existing label | anything | `choose`, or `confirm` when it is the recommended label and deletion was not recommended |
| A typed new label, known parent, first row | anything | `accept_new` |
| A typed new label, otherwise | anything | add the category once, then a fresh suggestion and `choose` per row |
| Move to Trash | anything | `delete` |

A label outside the 300 considered by the recommender is filed but not learned, as today.

## Action

One owner action covering one or more rows. It is how FR-018 to FR-021 are applied.

| Field | Meaning |
|-------|---------|
| `rows` | The rows it covers: the scope (marked, else highlighted), or every ready, unskipped row for approve all. |
| `targets` | Per row: a label to file under, a label to create, or the Trash. |
| `needsConfirmation` | More than one row and at least one goes to the Trash (FR-014). |

Applying an action:

1. Create each new label once (by path key) (FR-019).
2. File, one bridge call per target label, with each row's filing mode (`Filing.mode`: move, copy, label only).
3. Gmail only: archive every row filed with mode `move`, in one call that selects exactly those emails first (research R1).
4. Move every Trash row to the Trash, in one call that selects exactly those emails first, after refusing rows in the Trash already.
5. Learn each row that Mail applied (FR-022, FR-023).

A failure in one step marks only the rows of that step as `problem`, and the other rows continue (FR-021). A failed archive leaves its rows labelled, `done`, with the notice that they are still in the Inbox, as the single window does.

## Validation rules

- A batch has at least 2 and at most 50 rows, all in one account.
- No action covers a row in `applying`, `applied` or `done`.
- Move to Trash is never sent for a row with `inTrash`, or when the account has no Trash.
- Mail's Archive and Delete run only when Mail's selection, read back, is exactly the action's emails (SC-005).
