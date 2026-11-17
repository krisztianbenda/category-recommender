# Quickstart: Validating Batch Recommendations

How to check that the feature works, from the fastest synthetic checks to the one check that needs the owner's real Mail. Everything except the last section uses synthetic data only (constitution II).

## Prerequisites

- macOS 14 or later, the Command Line Tools, Node.js 24 (see the [README](../../README.md#requirements)).
- `cd service && npm ci` once, for the stub service used by the end-to-end script.

## 1. Unit and bridge tests

```bash
cd mail-app && scripts/test.sh
```

Expected: all pass, including:

- `BatchSessionTests`: approve all applies only ready, unskipped rows; Return applies only the scope; marked rows filed under one label; a decision before the recommendation is learned when it arrives; one new label created once for two rows, with `accept_new` for the first and a fresh suggestion and `choose` for the second; a failed target leaves the other targets applied; closing leaves undecided rows untouched and learns nothing for them; `FakeMail` saw no Message-ID outside each action (SC-005); each email's suggestion request equals the one the single window sends for it (SC-006).
- `SessionTests`: unchanged single-window behaviour after the extraction into `LabelPicker`, `Learning` and `MailAdvice`.
- Bridge tests: batch `opening` returns the 50 newest with sender and subject and no text; `read` places and reads; `archive` and `trash` with `select` refuse when the read-back differs; `trashSimilar` with `senders` returns `bySender` and `inTrashIds`.

## 2. The window, against a synthetic Mail

```bash
cd mail-app && swift build
```

```bash
.build/debug/CategoryRecommender --demo --batch --snapshot /tmp/catrec-batch.png
```

Expected: a 600 × 560 window with six rows, each with its own recommendation, "6 of 6 ready", and **Approve all (5)** (the email with no text has none).

```bash
.build/debug/CategoryRecommender --demo --batch --drive /tmp/catrec-batch-drive.json
```

Expected: every value in the report is `true` (see [contracts/batch-window.md](contracts/batch-window.md#demo-and-checks)).

To try it by hand: `.build/debug/CategoryRecommender --demo --batch`.

## 3. End to end with the real service and a stub model

```bash
mail-app/tests/e2e.sh
```

Expected: the batch section passes. It runs a batch of synthetic emails through the real service, approves all, and checks that each email got its own label, that the service recorded one decision per email, and that the app connected only to this computer (SC-007).

## 4. Real Mail, synthetic emails

```bash
open -n "$HOME/Applications/Category Recommender.app" --args --self-test-local --out /tmp/catrec-local.json
```

Expected: `selectSubset` is `pass`, with the existing steps. This shows Mail accepts a scripted selection of some emails (research R1). It uses only fabricated emails under On My Mac.

## 5. Real account, run by the owner

Not run by an AI assistant: it touches the real account. It changes no email, only what Mail shows as selected, and its output has pass, fail and booleans only.

1. In Mail, select three or more emails in the Inbox. Try once with **View > Organize by Conversation** on, and once with it off.
2. Run:

   ```bash
   open -n "$HOME/Applications/Category Recommender.app" --args --self-test-selection --out /tmp/catrec-selection.json
   ```

Expected: `selectView` or `selectPlacement` is `pass`, and `restored` is `pass`. If both fail with conversations on, rows of collapsed conversations stay labelled in the Inbox with a notice (research R1), and the README says to turn the setting off for batches.

Then a real batch: select a few emails, press Control-Option-L, check the rows, approve all, and see each email under its label in Mail.
