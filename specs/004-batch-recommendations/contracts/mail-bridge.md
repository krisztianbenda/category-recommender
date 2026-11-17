# Contract: Mail Bridge Changes

`mail-app/Resources/mail-bridge.js` is the only code that touches Mail. It is internal to the Mail app component: the Swift side (`ScriptedMail`, behind the `MailSource` protocol) is its only caller, and both ship together. The rules from 002 still hold: one JSON argument in, one JSON object out, ASCII with `\u` escapes, input parsed as data and never spliced into a script, and `CHECKS` commands that report pass, fail and counts only.

The service's HTTP API ([001 http-api](../../001-local-llm-categorizer/contracts/http-api.md)) does not change.

## `opening` (changed)

One email selected: unchanged.

More than one: the batch form. The bridge reads the dates of up to 1,000 selected emails, keeps the 50 newest, and returns light references only: no text, and no search for the copy filing acts on (research R2).

```json
{
  "selection": {
    "running": true,
    "total": 64,
    "messages": [
      {
        "id": 81234, "mailbox": "[Gmail]/All Mail", "account": "Example Gmail",
        "date": 1793000000000, "messageId": "abc@example.test",
        "from": "Shop Deals <deals@shop.example.test>", "subject": "Weekly deals 4"
      }
    ],
    "latest": null
  },
  "accounts": [{ "name": "Example Gmail", "addresses": ["owner@example.test"], "kind": "gmail" }],
  "labels": { "mailboxes": ["INBOX", "Family"], "system": ["INBOX"], "inbox": "INBOX" },
  "viewed": ["INBOX"]
}
```

- `messages` are newest first. `id` and `mailbox` name the message Mail was showing, which for Gmail is the All Mail copy. `inInbox` is absent until `read`.
- `total` is the whole selection, so `total - messages.length` were left out. A selection above 1,000 reports `total` as counted, and only the 1,000 first in Mail's order are considered.
- `viewed`: the paths of the mailboxes shown in Mail's front window, in the selection's account.

## `read` (new)

Places and reads some emails of a batch. Reading never changes a message.

```json
{
  "command": "read", "account": "Example Gmail", "viewed": ["INBOX"],
  "refs": [{ "id": 81234, "mailbox": "[Gmail]/All Mail", "messageId": "abc@example.test" }]
}
```

```json
{
  "items": [
    {
      "messageId": "abc@example.test",
      "found": true,
      "placement": { "id": 90876, "mailbox": "INBOX", "inInbox": true },
      "email": { "from": "…", "to": ["…"], "subject": "…", "body": "…" }
    }
  ]
}
```

- `placement` is found as `placed()` does today: the copy in a viewed mailbox, then in the Inbox, else the message itself.
- `found: false` when the message is gone. Then `placement` and `email` are absent.
- The Swift side sends at most 5 refs per call. Timeout: 20 seconds plus 3 per ref.

## `archive` and `trash` (changed)

Both accept an optional `select`. Without it they behave as today, so the single window is unchanged.

```json
{
  "command": "trash", "account": "Example Gmail", "titles": ["Delete"],
  "messageIds": ["abc@example.test", "def@example.test"],
  "viewed": ["INBOX"],
  "select": [
    { "messageId": "abc@example.test", "view": { "id": 81234, "mailbox": "[Gmail]/All Mail" },
      "placement": { "id": 90876, "mailbox": "INBOX" } }
  ]
}
```

With `select`, before anything else:

1. Set Mail's selection to the `view` references, read it back, and compare Message-IDs with `messageIds`.
2. If they differ, try the `placement` references.
3. If they still differ, show the first `viewed` mailbox, and try the `view` references once more.
4. If they still differ, return `{ "result": "selectionChanged" }` and click nothing.

Then the existing checks and the menu click run as today. The read-back is the only gate: Mail's command never runs unless its selection is exactly `messageIds`.

Result additions:

- `archive` with `stillThere` adds `left`: the Message-IDs still in the Inbox.
- `trash` with `notInTrash` adds `left`: the Message-IDs that did not arrive.
- Waiting for the result scales with the count: Archive 10 seconds plus one per email, Trash 15 plus one per email.

## `trashSimilar` (changed)

Accepts `senders` (a list) instead of `sender`. `sender` still works for the single window.

```json
{
  "command": "trashSimilar", "account": "Example Gmail",
  "senders": ["Shop Deals <deals@shop.example.test>", "Bank <news@bank.example.test>"],
  "messageIds": ["abc@example.test", "def@example.test"], "limit": 20
}
```

```json
{
  "found": true,
  "inTrash": false,
  "inTrashIds": [],
  "bySender": {
    "deals@shop.example.test": [{ "from": "Shop Deals <deals@shop.example.test>", "subject": "Weekly deals 3" }],
    "news@bank.example.test": []
  },
  "messages": []
}
```

- `bySender` is keyed by the lower-case sender address, as the service compares senders. Each list is newest first, at most `limit`, and leaves out the emails in `messageIds`.
- `inTrashIds`: the emails in `messageIds` that are in the Trash already. `inTrash` stays true when any is.
- `messages` is filled only for the single-sender form.
- Timeout: 30 seconds plus one per sender.

## Checks (changed and new)

- `selftestLocal` imports three fabricated emails instead of one, and adds the step `selectSubset`: select two of the three under On My Mac, read the selection back, and compare. Pass or fail only.
- `selftestSelection` (new, owner-run, real account): needs at least three emails selected in the Inbox. It selects the first two, reads back, and restores the original selection. It changes no email, only what Mail shows as selected. It reports pass, fail, a count or `error N` only: `errorsSeen` (a failing AppleScript is noticed, even when Mail's error number cannot be read), `viewers`, `sameViewer` (AppleScript sees the app's selection), `narrowItself` (Mail narrows its selection to emails it handed over itself), `selectView<Form>` and `selectPlacement<Form>` for each way of naming an email (`Nested`, `WholePath`, `MessageId`), and `restored`.

## `MailSource` (Swift) additions

```swift
func read(_ refs: [MailMessageRef], viewed: [String], account: String) async throws -> [ReadEmail]
func archive(_ emails: [SelectedEmail], viewed: [String], account: String) async throws -> ArchiveOutcome
func moveToTrash(_ emails: [SelectedEmail], viewed: [String], account: String) async throws -> TrashOutcome
func trashSimilar(senders: [String], messageIds: [String], account: String) async throws -> TrashLookups
```

`MailMessageRef` gains optional `from` and `subject`. `MailOpening` gains optional `viewed`. The existing methods stay for the single window. `DemoMail` and the tests' `FakeMail` implement the new ones with synthetic data, and `FakeMail` records every Message-ID it is asked to change, so tests can check that nothing outside an action is touched (SC-005).
