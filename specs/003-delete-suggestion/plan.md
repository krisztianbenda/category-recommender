# Implementation Plan: Suggest Deleting an Email

**Branch**: `003-delete-suggestion` | **Date**: 2026-11-09 | **Spec**: [spec.md](spec.md)

## Summary

A suggestion gets an `action`: `file`, as before, or `delete`. The service decides on deletion in code, from two kinds of evidence: learned deletions among the email's nearest past decisions, and trashed emails from the same sender whose subject is similar. The model is unchanged and never chooses deletion. The Mail app reads the account's Trash when the window opens, sends the trashed emails' senders and subjects with the request, and moves an email to the Trash with Mail's own Delete command. The web UI offers deletion too.

## Constitution Check

| Principle | Status | How |
|-----------|--------|-----|
| I. Privacy and data locality | Pass | Trashed emails' senders and subjects go only to the service on loopback, and are compared there and dropped. Nothing new leaves the computer. |
| I. Read-only data sources | Pass, owner approved | Moving an email to the Trash is a write to Mail, requested by the owner in this feature. It needs an explicit action each time, and goes to the Trash, which Gmail keeps for 30 days. |
| II. Assistant boundary | Pass | Tests, demo and the end-to-end script use synthetic emails. `--diagnose` adds counts only: whether the Trash was found and how many emails it holds. |
| III. Access control | Pass | Unchanged. |
| IV. Portability | Pass | Thresholds are configuration (`learning.deletion`). Mail-specific code stays in `mail-app/`. |
| V. Simplicity and memory | Pass | No new service, model or datastore. One more embedding request batch per suggestion, only with trashed emails to compare. |
| V. No automatic changes | Pass | Nothing is deleted without the owner's action. Deleting needs Mail's selection to be exactly the emails, refuses emails already in the Trash, and checks they arrived there. |
| Logs | Pass | New log fields are counts and the action name only. |

### Privacy note (required: personal data from a new place)

The Mail app now reads the Trash: for emails from the selected email's sender, their sender and subject, never their text. It sends at most 20 to `127.0.0.1` with the suggestion request. The service embeds the subjects to compare them and keeps nothing: they are not in the pending suggestion, the database or the logs. A learned deletion is stored like any learning example (sender, subject, a 600-character snippet, the embedding), only for emails the owner deleted through the recommender, and can be deleted under Learned data.

## Key decisions

### Deletion is decided in code, not by the model

The model's output contract stays as it is. A model asked whether to delete would answer from its general sense of what is junk, not from what this owner deletes. The model's part is to say whether a label fits: a new-label proposal, an unusable answer or low confidence count as "no label fits".

| Rule | When | Confidence |
|------|------|------------|
| Habit | deletion evidence ≥ `learning.override.minExamples` and its share ≥ `learning.override.share` | high if no label fits, else medium |
| No label fits | share ≥ `learning.deletion.noFitShare` (0.5) | medium with enough examples, else low |

The share is the deletion evidence's weight against the weight of the similar emails the owner filed. A filing suggestion where deleting is at least `noFitShare` likely is capped at medium confidence.

### Evidence

- **Learned deletions**: a learning example with no category and outcome `deleted`. It competes with filed examples for the nearest `neighbours` places, so the share reflects the email's real neighbourhood. Deleted examples are never shown to the model as few-shot examples, because it can only choose labels.
- **The Trash**: only emails from the same sender address are read, so the sender carries no information and only subjects are compared (embedding cosine ≥ `learning.deletion.trashSimilarity`, 0.75 for bge-m3). This keeps a bank's statements apart from its promotions. At most `neighbours` matches count, each with its similarity as weight.

### Opting in

The request carries `allowDelete`. A client that does not send it, such as an older Mail app, never receives `action: "delete"`, so its "confirm" can never mean delete. With a suggestion to delete, `confirm` means delete, and filing under the named label is `choose`.

### Storage

Migration `002_deletions.sql` rebuilds `learning_examples` so that `category_id` can be null, exactly when `outcome = 'deleted'` (a CHECK constraint). SQLite can only do this by copying the table, so `migrate()` now runs migrations with foreign keys off and runs `foreign_key_check` before each commit. Without that, dropping the old table would set `decisions.learning_example_id` to null. `decisions` gets `was_delete_suggestion`. A decision's outcome stays `confirmed` or `corrected`: it is confirmed when the owner did what was suggested.

### Moving to the Trash in Mail

Mail's scripting cannot be trusted to delete Gmail emails: marking one deleted made Mail crash in 002. Like archiving, the app clicks Mail's own command, **Edit > Delete**, through System Events, after checking that Mail's selection is exactly the emails. Then it waits for them to appear in the Trash.

- **Finding the Trash**: Mail's own Trash (`trash mailbox`) holds one mailbox per account. Gmail's usual Trash names are the fallback. Without a Trash, nothing is deleted, because Mail's Delete might then erase.
- **In the Trash already**: Mail's Delete there erases for good, so the bridge refuses, and the window neither recommends nor offers it.
- **Keys**: Return on the recommended row, or Command-Delete as in Finder. Command-Delete edits the text while there is any in the search field.

| Result | Window |
|--------|--------|
| `trashed` | learns, closes |
| `notAllowed` | asks for Accessibility, or to remove and add the app again if the switch is on: the app is signed ad hoc, so an entry from an earlier install looks on but no longer applies; nothing learned |
| `systemEventsNotAllowed` | asks for System Events under Automation; nothing learned |
| `commandUnavailable` | Mail's Delete was missing or greyed out: says to click the email in Mail's list; nothing learned |
| `selectionChanged`, `notInTrash` | says so; nothing learned |
| `alreadyInTrash`, `noTrash` | says so; turns the action off |

## Project Structure

```text
service/src/suggest/deletion.ts             the rules, the reason text, Trash matching
service/src/suggest/pipeline.ts             evidence, decision, response fields
service/src/learning/knn.ts                 learned deletions as neighbours
service/src/learning/feedback.ts            "delete" decision
service/src/store/migrations/002_deletions.sql
service/web/                                Delete / Delete instead, Learned data
mail-app/Resources/mail-bridge.js           trashSimilar, trash
mail-app/Sources/MailCore/RecommenderSession.swift
mail-app/Sources/CategoryRecommender/       Trash row, footer button, Command-Delete
```

## Verification

- Service: unit tests for the rules and Trash matching, kNN with deleted neighbours, the migration on a 001 database, and contract tests over HTTP with the stub model.
- Mail app: session tests with a fake Mail, bridge tests with a fake Mail that has a localised Trash, client tests, and the end-to-end script against the real service.
- Window: a demo snapshot with a synthetic newsletter (`--demo --newsletter`), and real key events through `--drive`.
- Not verified here: Mail's Delete and the Trash lookup on the real Gmail account. The owner can check the lookup with `--diagnose` (`trashFound`, `trashFoundThroughMail`, `trashMessages`), then delete one email from the window and see it in the Trash.
