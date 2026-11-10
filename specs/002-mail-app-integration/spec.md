# Feature Specification: Mail App Integration

**Feature Branch**: `002-mail-app-integration`

**Created**: 2026-11-05

**Status**: Draft

**Input**: User description: "Integration with the macOS Mail app for the owner's Gmail account: read the chosen email, import the account's folders/labels into the existing local category recommender, run the existing algorithm on the email and recommend a label from the available ones, or create a new label or delete one, all a few clicks away. Everything runs locally; no data reaches any third party."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - File the chosen email under the recommended label (Priority: P1)

The owner selects an email in Mail and triggers the recommender from Mail with one action. A small window shows the recommended label from the Gmail account, how confident the recommendation is and why. One more action files the email under that label. If the recommendation is wrong, the owner picks another label from the same window.

**Why this priority**: This is the whole point of the feature. It replaces copying an email into the web page by hand, and it delivers value even with no other story.

**Independent Test**: With a Gmail account in Mail and some labels, select a synthetic email, trigger the recommender, accept the recommendation, and check the email now has that label and the service recorded the decision.

**Acceptance Scenarios**:

1. **Given** an email from the Gmail account is selected in Mail, **When** the owner triggers the recommender, **Then** a window appears at once with the email's subject and all labels, and a recommendation appears when ready.
2. **Given** a recommendation is shown, **When** the owner accepts it, **Then** the email is filed under that label, the decision is recorded for learning, and the window closes.
3. **Given** a recommendation is shown, **When** the owner picks a different label, **Then** the email is filed under the chosen label and the correction is recorded for learning.
4. **Given** several emails or a whole conversation are selected, **When** the owner accepts a label, **Then** all selected emails get the label, and the recommendation is based on the most recent one.
5. **Given** the owner has chosen "keep in Inbox", **When** a label is applied, **Then** the email gets the label and stays in the Inbox, and this choice is remembered.

---

### User Story 2 - Labels stay in step with the account (Priority: P1)

The owner never maintains a category list. The recommender uses the labels that exist in the Gmail account at that moment, excluding Gmail's system folders (Inbox, Sent, Drafts, Spam, Trash, All Mail, Starred, Important).

**Why this priority**: A recommendation is only useful if it names a label that really exists. Without this, Story 1 cannot work.

**Independent Test**: Add a label to the synthetic account, trigger the recommender, and check the new label is in the list. Remove one, trigger again, and check it is gone.

**Acceptance Scenarios**:

1. **Given** the recommender has never run, **When** it is triggered for the first time, **Then** all of the account's labels are imported without further action.
2. **Given** a label was added in Mail or Gmail, **When** the recommender is next triggered, **Then** that label can be recommended.
3. **Given** a label with no learned decisions was removed, **When** the recommender is next triggered, **Then** it is no longer offered.
4. **Given** a label with learned decisions was removed, **When** the recommender is next triggered, **Then** it is not offered as a label to file under, its learned decisions are kept, and the owner is told and can choose to forget them.
5. **Given** labels nested deeper than the recommender's two levels, **When** they are imported, **Then** each can still be recommended and applied to the correct label.

---

### User Story 3 - Create or delete a label on the spot (Priority: P2)

From the same window the owner can accept a newly proposed label, type a new one, or delete an existing one, without opening the account settings or a browser.

**Why this priority**: Labels evolve. Creating one while reading the email that needs it is when the owner actually thinks of it. It is not needed for the first filed email, so it follows Stories 1 and 2.

**Independent Test**: Trigger the recommender on a synthetic email, create a label from the window, check it exists in the account and the email is filed under it. Delete that label from the window, confirm, and check it is gone.

**Acceptance Scenarios**:

1. **Given** the recommender proposes a new label, **When** the owner accepts it, **Then** the label is created in the account, the email is filed under it, and the decision is recorded.
2. **Given** the owner types a new label name, **When** they confirm, **Then** the label is created in the account and the email is filed under it.
3. **Given** the owner types the name of an existing label, **When** they confirm, **Then** the existing label is used and no duplicate is created.
4. **Given** the owner asks to delete a label, **When** the confirmation appears, **Then** it names the label, says how many emails it holds, and says the emails themselves are kept. Nothing is deleted until the owner confirms.
5. **Given** the owner confirms, **When** Mail asks for its own confirmation and the owner gives it, **Then** the label is removed from the account and is no longer recommended.
6. **Given** the owner declines in Mail, **Then** the label and what was learned for it stay.

---

### User Story 4 - The recommender is ready when needed (Priority: P2)

The owner does not have to start anything in a terminal. Triggering the recommender starts the local model if it is not running. The model's memory is released after it has been idle for a while.

**Why this priority**: "A few clicks away" fails if the first step is opening a terminal. It is an enabler of Story 1 but not a precondition for testing it.

**Independent Test**: With nothing running, trigger the recommender, and check that a recommendation arrives without any other step. Wait past the idle period and check the model processes have stopped.

**Acceptance Scenarios**:

1. **Given** the local model is not running, **When** the recommender is triggered, **Then** the window says the model is starting, and the recommendation appears when it is ready, with no other action.
2. **Given** the model was started by the recommender and has been idle past the idle period, **Then** it is stopped and its memory released.
3. **Given** the owner started the service on their own, **Then** the recommender uses it and never stops it.
4. **Given** the model is starting or unavailable, **When** the window is open, **Then** the owner can still file the email by picking a label by hand.

### Edge Cases

- **No email selected or Mail not open**: the window says so. Nothing else happens.
- **Email from another account**: the window says only the Gmail account is supported and does not process the email.
- **No Gmail account in Mail**: the window explains this.
- **Permission to control Mail not granted**: the window says what to allow and where.
- **Email with no text, or only a subject**: recommend from what is there. If there is neither subject nor text, the owner picks by hand.
- **Very long email**: it is shortened, and the window shows that it was.
- **Prompt injection inside an email**: handled by the existing algorithm; the email text only ever influences the choice of label.
- **Email selected from All Mail or another Gmail system folder**: only add the label, because moving out of those folders can have destructive side effects in Gmail.
- **Applying a label fails** (offline, label removed meanwhile): the email stays where it was, the window shows the error, and no learning is recorded.
- **Label applied but recording the decision fails**: the email stays filed, and the window notes that this decision was not learned.
- **Recommended label no longer exists**: treat as a new-label proposal, so that accepting it creates the label.
- **Two labels that differ only in accents or case**: both remain usable where the account allows them; the recommender never merges them silently.
- **More labels than the recommender can consider at once**: the owner is told how many were not imported.

## Requirements *(mandatory)*

### Functional Requirements

**Trigger and reading**

- **FR-001**: The owner MUST be able to trigger the recommender for the email selected in Mail with one action: a keyboard shortcut, a Mail menu entry or a menu bar icon.
- **FR-002**: The system MUST read the selected email's sender, recipients, subject and text from Mail without changing the email, and without marking it as read.
- **FR-003**: The system MUST handle only emails of the owner's Gmail account, and MUST detect that account without requiring its details to be typed in.

**Labels**

- **FR-004**: The system MUST import the account's labels each time it is triggered, adding new ones without any action by the owner.
- **FR-005**: The system MUST exclude Gmail's system folders from the labels that can be recommended.
- **FR-006**: The system MUST map every imported label back to the exact label in the account, including labels deeper than two levels.
- **FR-007**: The system MUST NOT discard learned decisions because a label disappeared without the owner's confirmation.

**Recommendation**

- **FR-008**: The system MUST produce the recommendation using the existing local recommendation service and its learning, not a separate algorithm.
- **FR-009**: The window MUST show the recommended label, its confidence, the reason, the closest alternatives and all other labels, and MUST let the owner search the labels by typing.
- **FR-010**: The owner MUST be able to file under a label without waiting for the recommendation to finish.

**Applying**

- **FR-011**: The system MUST change an email only after an explicit action by the owner.
- **FR-012**: Accepting a label MUST take one action: a click, or the Return key for the highlighted label.
- **FR-013**: The owner MUST be able to choose whether filing also removes the email from the Inbox. The default is to remove it, and the choice MUST be remembered. If the email cannot be removed from the Inbox, the window MUST say so and why.
- **FR-014**: Every label applied through the window MUST be recorded as a confirmation or correction, so that the recommender learns from it.
- **FR-015**: For an email that is not in the Inbox, filing MUST only add the label.

**Creating and deleting labels**

- **FR-016**: The owner MUST be able to create a label from the window, optionally under a parent, and file the email under it in one flow.
- **FR-017**: The owner MUST be able to start deleting a label from the window, after a confirmation that names the label and says how many emails it holds. The deletion itself MUST be confirmed in Mail. A completed deletion MUST also remove the label from the recommender.
- **FR-018**: Deleting a label MUST NOT delete the emails it holds.

**Availability**

- **FR-019**: The system MUST start the local service and models on demand, and MUST stop those it started after an idle period the owner can change.
- **FR-020**: The system MUST NOT stop a service it did not start.
- **FR-021**: The integration MUST start at login, so that the trigger always works, and MUST be possible to remove completely.

**Privacy**

- **FR-022**: Email content, labels and recommendations MUST NOT leave this computer through the integration. It MUST only talk to the recommendation service on this computer, and MUST refuse any other destination.
- **FR-023**: The integration MUST NOT store email content on disk. Its logs MUST contain only identifiers and metadata.
- **FR-024**: Development and automated checks MUST use synthetic emails and labels only, and MUST NOT show real emails, labels or recommendations to an AI assistant.

### Key Entities

- **Gmail account**: the single account handled; identified automatically in Mail.
- **Label**: a Gmail label, seen in Mail as a mailbox. May be nested, with no depth limit.
- **Category set**: the recommender's copy of the account's labels. Labels map to categories; learned decisions attach to categories.
- **Selected email**: the sender, recipients, subject and text of the most recent selected email, held in memory only while the window is open.
- **Recommendation**: the existing service's suggestion: a label or a new-label proposal, plus confidence, reason and alternatives.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Filing the selected email under the recommended label takes at most 2 owner actions in total: one trigger and one accept.
- **SC-002**: Filing under another visible label, or creating a new label, takes at most 4 owner actions. Deleting a label takes at most 4 owner actions including both confirmations when the owner has allowed the app to use Mail's menu, and at most 6 otherwise.
- **SC-003**: The window appears within 1 second of the trigger, with the email's subject and the labels.
- **SC-004**: With the model already loaded, a recommendation for a typical email appears within 15 seconds on the reference computer.
- **SC-005**: A label added to the account can be recommended the next time the recommender is triggered, with no action by the owner.
- **SC-006**: During a full recommendation and filing, the integration makes no network connection to anything other than this computer.
- **SC-007**: On the synthetic reference set, recommendations made through the integration are as accurate as those from the service directly, because the same algorithm is used.

## Assumptions

- Mail on this computer already has the owner's Gmail account configured and syncing. Mail's own connection to Gmail is the existing path for email, and this feature adds no new one.
- Filing means what Gmail does when you label and archive: the label is added and the email leaves the Inbox. It stays in All Mail. Deleting a label keeps the emails in All Mail. Removing a label other than the Inbox is out of scope, because Mail cannot do it by script.
- A renamed label appears as one removed label and one new label, as the account does not expose renames. Learned decisions stay with the old name until the owner forgets them.
- One owner and one computer; the service runs in local mode. Using the integration from another computer is out of scope.
- Automatic filing of incoming email is out of scope: the owner triggers every recommendation (constitution V).
- Recommending which labels to delete is out of scope. Deletion is the owner's decision, offered from the window.
- Other mail apps, other accounts and Gmail's web interface are out of scope.
