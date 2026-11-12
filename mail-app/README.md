# Mail integration

File the email selected in macOS Mail under the label or folder the local recommender suggests, in two actions: a shortcut, then Return. It works with every account in Mail: Gmail accounts by their labels, and iCloud, Exchange and other accounts by their folders. When you usually delete emails like it, the recommendation is to move it to the Trash instead. It can also create or delete a label from the same window. Everything runs on this Mac.

Design: [`specs/002-mail-app-integration/`](../specs/002-mail-app-integration/plan.md), and [`specs/003-delete-suggestion/`](../specs/003-delete-suggestion/plan.md) for deleting.

## Install

You need the Command Line Tools (`xcode-select --install`), Node.js 24, `llama.cpp` and the models. See [Local mode](../docs/operations.md#local-mode-current-setup) for the last three.

```bash
mail-app/scripts/install.sh
```

This puts **Category Recommender** in `~/Applications` and starts it at login, as a tag icon in the menu bar. macOS asks for permission twice:

1. **When the app first reads from Mail:** choose **Allow**.
2. **When the app first archives an email, moves one to the Trash, or deletes a label:** macOS asks to let it use Mail's menus. Choose **Allow**, then turn on **Category Recommender** under System Settings > Privacy & Security > Accessibility. Without this, filing adds the label but leaves the email in the Inbox, moving to the Trash does nothing, and deleting a label takes two more clicks in Mail.

After you reinstall, macOS treats the app as new, so allow both again. For Accessibility, remove the old entry with **−** and add the app again. Turning the old entry off and on is not enough: it still belongs to the earlier install, even though it looks on.

## Use

1. Select an email in Mail, in any of your accounts. The window shows that account's labels or folders.
2. Press **Control-Option-L**, click the **tag icon** in the menu bar, or choose **Mail > Services > Recommend a Label**.
3. The window opens at once with your labels. The recommendation appears at the top when it is ready.

| To | Do this |
|----|---------|
| File under the recommended label | Press **Return**, or click it |
| File under another label | Click it, or use the arrow keys and press **Return** |
| Find a label | Type part of its name. Accents and case don't matter |
| Create a label | Type its name, such as `Trips/Lisbon`, and press **Return**. This also files the email under it |
| Accept a proposed new label | Press **Return** on the row that says **Create** |
| Move the email to the Trash | Press **Return** when **Move to Trash** is recommended. Otherwise press **Command-Delete**, or click **Move to Trash** at the bottom |
| Delete a label | Right-click it and choose **Delete label...**, or use the trash icon when you hover over it. Choose **Delete in Mail...**, then confirm in Mail |
| Keep the email in the Inbox | Tick **Keep in Inbox**. The setting is remembered |
| Close without changing anything | Press **Esc** |

You don't have to wait for the recommendation. If you file early, the decision is still learned when the recommendation arrives. If the model isn't running, it starts by itself, which takes a little while the first time. It stops after 30 minutes without use, which frees about 5.6 GB of memory. To change that, use:

```bash
defaults write com.catrec.mail idleMinutes -int 60
```

If you started `scripts/run-local.sh` yourself, the app uses that service and never stops it.

## Deleting emails

The recommendation is **Move to Trash**, in red, when you usually delete emails like this one. The reason says why, for example "3 similar emails from this sender are in the Trash". The label it would otherwise go to is right below it, so you can still file it with one click.

The evidence is your own behaviour, never the model's opinion:

- **Emails you deleted from this window.** They are learned like filed emails, and you can see and delete them under **Learned data** in the web UI.
- **Emails in your Trash from the same sender**, if their subject is about the same thing. A bank's statements and its offers count separately. The app reads only their sender and subject, and the recommender does not keep them.

When a label fits, it takes at least 3 such emails, and deleting has to be at least three times as common as filing among similar emails. When no label fits, one is enough, as long as you delete such emails at least as often as you file them.

Command-Delete works as in Finder. While there is text in the search field, it edits the text instead.

## Accounts

Each account in Mail has its own labels or folders and its own learning, so what you file in one account does not affect recommendations in another. You can have any number of accounts of each type. Emails under On My Mac can't be filed, and neither can a selection that spans accounts.

| Account | Filing | Keep in Inbox | Deleting a label or folder |
|---------|--------|---------------|----------------------------|
| Gmail | Adds the label and archives the email | Adds the label only | The emails stay in All Mail |
| iCloud, Exchange, other | Files a copy in the folder, and the email stays where it is | Not shown: it always stays | **Mail deletes the emails in it** |

## What happens in iCloud, Exchange and other folder accounts

An email is in exactly one folder, and the window says "folder" where it says "label" for Gmail.

- **Filing** puts a copy of the email in the folder, and the email stays where it is, so you take it out of the Inbox yourself. The window says **Files a copy** where Gmail accounts have **Keep in Inbox**. Moving is off for now: a scripted move once took an email out of the Inbox, and Mail never showed it again in any folder.
- **Moving to the Trash** works as in Gmail, and how long the Trash keeps it is up to the account.
- **Deleting a folder** deletes the emails in it. The window says so before it hands over to Mail, and Mail asks again.
- The account's own Inbox, Sent, Drafts, Junk and Trash are left out, whatever they are called in your language, as are Archive, Notes and Exchange's Conversation History and Sync Issues. A folder inside the Inbox appears as `Inbox › Projects`.

## What happens in Gmail

Mail shows each Gmail label as a mailbox.

- **Filing an email from the Inbox** adds the label, then uses Mail's own **Archive** command to take it out of the Inbox. It stays in All Mail. The app only archives if what's selected in Mail is exactly the email or emails it just filed.
- **Keep in Inbox** adds the label only.
- **Filing an email you're viewing in a label, in All Mail or elsewhere** adds the new label only. Its other labels stay, because Mail can't remove a label by script.
- **Moving to the Trash** uses Mail's own **Delete** command, like pressing Delete in Mail. Gmail keeps it in the Trash for 30 days. The app only deletes if what's selected in Mail is exactly the email or emails in the window, and checks that they arrived in the Trash. It never deletes an email that is in the Trash already, because Delete there erases it for good. If Mail shows no Trash for the account, nothing is deleted.
- **Deleting a label** removes the label. Its emails stay in All Mail and keep their other labels. A label with sub-labels can't be deleted until the sub-labels are gone.

Why filing works this way: in Gmail, Mail's scripted "move" only adds a label. Marking the old copy as deleted makes Mail crash, because it tries to move the copy to Trash. Archiving is what you'd do by hand, and Mail handles it.

Mail doesn't let apps delete a mailbox directly, so the app selects the label in Mail and opens Mail's own **Delete Mailbox...** command, and Mail asks you to confirm. Without the Accessibility permission, the window tells you to choose **Mailbox > Delete Mailbox...** yourself. Selecting the label also changes which mailbox Mail is showing.

## Labels and learning

Labels and folders are read from Mail every time you open the window, and the account's system folders are left out. They are kept in one category set per account, named `Gmail: <your address>` for Gmail and `Mail: <your address>` for other accounts, which you can also see in the web UI. Each filing teaches the recommender, the same way as in the web UI.

- **Removed labels**: if a label is removed outside this window and it has learned decisions, those decisions are kept. The window tells you, and **Forget** removes them.
- **Moved and renamed labels**: what was learned for a label follows it when you move or rename it in Gmail or Mail. Mail doesn't say that a label moved: it shows the old one gone and a new one. The app treats them as the same label when one of these is true:
  - It has the same name in another place: under another parent, at the top level, or under a parent for the first time. For example, `Family/Baby` moved to `Kids/Baby` or to `Baby`.
  - It's a parent whose sub-labels now sit under one new parent. For example, `Family` renamed to `Home`. The sub-labels come along.
  - The new label holds emails that were learned for the old one. This is how a label with a new name is recognised. For example, `Family/Baby` renamed to `Family/Newborn`.

  Otherwise, for example when two labels have the same name or a new label holds none of those emails, the old label is treated as removed.
- **Deep labels**: the recommender allows two levels, so `Work/Clients/Acme` appears as `Work/Clients › Acme`. It is still filed under the right label.
- **Many labels**: the recommender considers the first 300, alphabetically. The window tells you if there are more, and you can still pick them by hand.

## Privacy

- The app only talks to the service on this Mac. It refuses any other address, redirects and proxies.
- Email text stays in memory, and it is gone when the window closes or the decision has been recorded. What the service stores when you file or delete an email is the same as for the web UI.
- From the Trash, the app reads only the sender and subject of emails from the selected email's sender, at most 20. They go to the service with the request and are not stored.
- `~/.catrec/logs/mail-app.log` has event names and times only.
- Mail's own connection to Gmail is the only path to Google, and this app adds none.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Mail access is off" | System Settings > Privacy & Security > Automation: turn on **Mail** under **Category Recommender** |
| "macOS does not let Category Recommender use Mail's menus" | Allow the app under System Settings > Privacy & Security > Accessibility. If it is on already, the entry is from before a reinstall: remove it with **−** and add the app again. Until then, press Control-Command-A (archive) or Delete in Mail |
| "macOS does not let Category Recommender use System Events" | System Settings > Privacy & Security > Automation: turn on **System Events** under **Category Recommender** |
| "Mail's Archive command was not available" or "Mail's Delete command was not available" | The command was greyed out in Mail. Click the email in Mail's message list, and try again |
| "Mail did not put it in the Trash" | In Mail > Settings > Accounts > your Gmail account > Mailbox Behaviors, turn on moving deleted messages to the Trash mailbox, and check the email in Mail |
| Move to Trash is greyed out | The email is in the Trash already, Mail shows no Trash for the account, or Mail did not give the email an ID |
| The shortcut does nothing | Mail must be the active app. The shortcut is only active then, so it doesn't take the combination from other apps. The menu bar icon works anywhere |
| No entry under Mail > Services | System Settings > Keyboard > Keyboard Shortcuts > Services: turn on **Recommend a Label** |
| "The local service stopped while starting" | Run `scripts/run-local.sh` in a terminal to see why |
| The permission prompt comes back | Reinstalling can make macOS treat the app as new. Choose **Allow** again |

To check Mail access without sharing any content, the app can report counts only, or run its checks and report pass or fail only:

```bash
open -n "$HOME/Applications/Category Recommender.app" --args --diagnose --out /tmp/catrec-diagnose.json
```

```bash
open -n "$HOME/Applications/Category Recommender.app" --args --self-test-local --out /tmp/catrec-local.json
```

`--diagnose` also reports, for each account, whether it is Gmail (`gmail`), whether its Inbox was found (`inboxFound`), whether the Trash was found (`trashFound`), whether through Mail's own Trash (`trashFoundThroughMail`), and how many emails it holds (`trashMessages`).

`--self-test-local` uses mailboxes under On My Mac and one fabricated message. Mail doesn't let scripts delete mailboxes, so `catrec-selftest` and `Import` stay under On My Mac until you delete them. Later runs reuse them.

`--self-test-account` tests the real account on one email you select in the Inbox. In a folder account it creates the folder `catrec-selftest-folder` with a `child` folder under it, puts a copy of the email in `catrec-selftest-folder` and moves the copy to `child`. Your email itself stays in the Inbox and is never moved. The folders stay, holding the copy, for you to delete from the window. In Gmail it creates the label `catrec-selftest-labelled` with a `child` label under it, and files the email under `child`. It then archives the email with Mail's command and puts it back in the Inbox. The labels stay for you to delete from the window. That also tests that an email survives its label being deleted.

## Uninstall

```bash
mail-app/scripts/uninstall.sh
```

Your labels and what the recommender has learned stay. Delete learned data under **Learned data** in the web UI.

## Develop

`scripts/test.sh` runs the unit tests and the bridge tests. `tests/e2e.sh` runs the real service with a stub model, and checks the running app only connects to this Mac. All of these use synthetic data. Run the app with `.build/debug/CategoryRecommender --demo` to try the window against a synthetic Mail. Add `--newsletter` for an email like three in the synthetic Trash, which is recommended for deletion.

```text
Resources/mail-bridge.js      everything that talks to Mail
Sources/MailCore/             labels, sync, HTTP client, session state (no UI)
Sources/CategoryRecommender/  menu bar app, window, shortcut, service start and stop
```
