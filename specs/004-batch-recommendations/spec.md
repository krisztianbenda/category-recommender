# Feature Specification: Batch Recommendations

**Feature Branch**: `004-batch-recommendations`

**Created**: 2026-11-11

**Status**: Draft

**Input**: User description: "Batch recommendations in the Mail app. Today, when several emails are selected in Mail, the recommender suggests one label based on the most recent email and files all of them under it. Instead, when the owner selects multiple emails and triggers the recommender, it should recommend a category (label, new label, or Move to Trash) for each email separately. The owner reviews the list and can approve all recommendations at once, approve only some of them, or decide one by one: accept, pick a different label, or move to Trash for each email individually. Emails the owner does not decide on are left untouched. Every decision is learned as a confirmation or correction, as with a single email."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Approve every recommendation at once (Priority: P1)

The owner selects several emails in Mail, for example a morning's worth of the Inbox, and triggers the recommender as for one email. The window lists the selected emails, one row each, with its sender and subject. Each row fills in with its own recommendation as soon as it is ready: a label, a new label, or Move to Trash, with how confident it is. When the owner is happy with what they see, one action applies every recommendation that is ready, and each email goes where its row says.

**Why this priority**: This is the time saver. Sorting a full Inbox one email at a time takes two actions per email. With this, the owner checks a list and approves it with one action.

**Independent Test**: With a synthetic account, select five synthetic emails that belong under three different labels, trigger the recommender, wait for all five recommendations, approve all, and check that each email is under its own recommended label and that five decisions were learned.

**Acceptance Scenarios**:

1. **Given** several emails from one account are selected in Mail, **When** the owner triggers the recommender, **Then** a window appears at once with one row per email, showing its sender and subject, and each row shows its own recommendation when it is ready.
2. **Given** some recommendations are ready and others are not, **When** the owner looks at the window, **Then** it shows how many are ready out of how many, and which rows are still waiting.
3. **Given** recommendations are ready, **When** the owner approves all, **Then** each email with a ready recommendation is filed under its recommended label, or moved to the Trash if that was recommended, and each decision is learned as a confirmation.
4. **Given** the owner approves all while some rows are still waiting, **Then** only the ready rows are applied. The waiting rows stay in the window and are not changed.
5. **Given** the recommendations to approve include moving emails to the Trash, **When** the owner is about to approve all, **Then** the window says how many emails will be filed and how many moved to the Trash before anything changes.
6. **Given** a recommendation proposes a new label for two of the emails, **When** the owner approves all, **Then** the label is created once and both emails are filed under it.
7. **Given** every row has been applied, **Then** the window closes.

---

### User Story 2 - Decide one email at a time (Priority: P1)

Some recommendations are wrong, or the owner is unsure about one. The owner moves through the rows and, for each email, accepts the recommendation, picks another label, creates a label, or moves the email to the Trash. Each decision is applied to that email only, at once, and the rest of the list stays as it was.

**Why this priority**: Approving everything is only safe if fixing one wrong row is easy. Without this, a single bad recommendation forces the owner back to filing emails one by one.

**Independent Test**: Select three synthetic emails, trigger the recommender, and for the first accept the recommendation, for the second pick a different label, and for the third move it to the Trash. Check that each email is where the owner put it, that one confirmation, one correction and one deletion were learned, and that no other email changed.

**Acceptance Scenarios**:

1. **Given** a row's recommendation is ready, **When** the owner accepts that row, **Then** that email alone is filed under the recommended label, the decision is learned as a confirmation, and the row shows it is done.
2. **Given** a row's recommendation is wrong, **When** the owner picks another label for that row, **Then** that email alone is filed under the chosen label and the decision is learned as a correction.
3. **Given** any row, **When** the owner chooses Move to Trash for it, **Then** that email alone is moved to the Trash and the deletion is learned, as a confirmation if deletion was recommended and as a correction otherwise.
4. **Given** a row whose recommendation is not ready yet, **When** the owner picks a label or Move to Trash for it, **Then** it is applied at once, and the decision is learned when the recommendation arrives.
5. **Given** the owner wants to look closer at one email, **When** they open its row, **Then** they see the same detail as for a single email: the reason, the closest alternatives and all labels, with search by typing.
6. **Given** the owner has decided some rows, **When** they close the window, **Then** the emails they did not decide on are left exactly as they were and nothing is learned for them.
7. **Given** the owner can work from the keyboard for one email, **Then** they can do so for a batch too: move between rows, accept the highlighted row, and approve all, without the mouse.

---

### User Story 3 - Approve or redirect only some of them (Priority: P2)

The owner marks a few rows, for example the ones they are sure about, and applies only those. Or they mark several rows and send them all to one label of their choice, as the app does today for a multiple selection.

**Why this priority**: It covers the middle ground between "all" and "one", and it keeps today's way of filing several emails under one label. Stories 1 and 2 already deliver the main value, so it follows them.

**Independent Test**: Select six synthetic emails, mark three, approve the marked rows, and check that only those three changed. Then mark the remaining three, choose one label for them, and check all three are under it and three corrections or confirmations were learned.

**Acceptance Scenarios**:

1. **Given** several rows are marked, **When** the owner approves the marked rows, **Then** each marked email with a ready recommendation gets its own recommendation, and unmarked rows are not changed.
2. **Given** several rows are marked, **When** the owner chooses one label for them, **Then** all marked emails are filed under that label, and each decision is learned as a confirmation where that label was recommended for the email and as a correction otherwise.
3. **Given** several rows are marked, **When** the owner chooses Move to Trash for them, **Then** the window says how many emails will be moved to the Trash, and only after the owner confirms are they moved.
4. **Given** the owner wants to leave an email out of "approve all", **When** they skip its row, **Then** approving all no longer applies to it, and it is left untouched when the window closes.

### Edge Cases

- **One email selected**: the window works exactly as it does today for a single email.
- **Several emails of one conversation selected**: each email is its own row and gets its own recommendation, like any other selected email.
- **Emails from different accounts selected**: the window says only emails from one account can be handled at a time, and nothing is processed. This is the same as today.
- **More emails selected than the batch limit**: the most recent emails up to the limit are included, the window says how many were left out, and those are not changed.
- **Mail's selection changes after the window opened**: the batch stays as it was when the window opened. Actions apply only to the emails in the batch, and never to other emails that are selected in Mail now.
- **An email in the batch was moved, filed or deleted elsewhere while the window was open**: its row says it can no longer be found, and it is not changed or learned.
- **A selected email is in the Trash already**: Move to Trash is neither recommended nor offered for it, as for a single email. Approving all files it if a label is recommended.
- **Applying fails for some rows during approve all** (an email has gone, a label was removed meanwhile, Mail is busy): the rows that succeeded are done and learned, the rows that failed stay in the window with the reason, and nothing is learned for them.
- **Filing succeeded but learning the decision failed**: the email stays filed, and its row notes that this decision was not learned.
- **The model is starting or becomes unavailable**: the owner can still decide every row by hand. Rows without a recommendation are not included in approve all.
- **The recommendation for one email fails** (empty email, unusable answer): that row says so, and the owner can pick a label for it by hand.
- **The same new label is proposed with different spelling for several emails**: proposals that name the same label are treated as one, so the label is created once.
- **The owner deletes a label from the account while the window is open**: rows recommending it treat it as a new-label proposal, as for a single email.
- **The window is closed while recommendations are still being made**: making the remaining recommendations stops, and nothing is changed or learned for undecided emails.
- **The owner leaves the window open for a long time**: decisions made while the window is open are still learned, as for a single email left open for the same time.
- **Prompt injection in one email**: it can only influence that email's own recommendation, never another row's.

## Requirements *(mandatory)*

### Functional Requirements

**Opening a batch**

- **FR-001**: When more than one email is selected and the owner triggers the recommender, the system MUST open a batch window with one row per selected email. When one email is selected, the existing single-email window MUST be used.
- **FR-002**: The batch window MUST appear with every row's sender and subject without waiting for any recommendation.
- **FR-003**: A batch MUST contain at most 50 emails. If more are selected, the system MUST include the 50 most recent and tell the owner how many were left out.
- **FR-004**: The batch MUST be fixed when the window opens. Later changes to Mail's selection MUST NOT add emails to it or remove emails from it.

**Recommendations**

- **FR-005**: The system MUST make a separate recommendation for each email in the batch, with the same algorithm, labels, learning and deletion evidence as for a single email.
- **FR-006**: Each row MUST show its recommendation as soon as it is ready, without waiting for the other rows.
- **FR-007**: The window MUST show how many recommendations are ready out of how many.
- **FR-008**: Each row MUST show the recommended action (a label, a new label, or Move to Trash) and its confidence. The owner MUST be able to see that row's reason, alternatives and all labels.

**Deciding**

- **FR-009**: The system MUST change an email only after an explicit action by the owner that covers that email: approving all, approving marked rows, or deciding that row.
- **FR-010**: The owner MUST be able to approve every ready recommendation with one action. Rows that are not ready, already done or skipped MUST NOT be affected.
- **FR-011**: The owner MUST be able to accept, change or reject the recommendation of any single row, by choosing a label, creating a label or choosing Move to Trash, and that decision MUST be applied to that email only.
- **FR-012**: The owner MUST be able to mark several rows and then approve their recommendations, file them all under one chosen label, or move them all to the Trash.
- **FR-013**: The owner MUST be able to skip a row, so that approving all leaves it out.
- **FR-014**: Before an action that covers more than one email and moves any of them to the Trash, the window MUST say how many will be filed and how many moved to the Trash, and nothing MUST change until the owner confirms.
- **FR-015**: The owner MUST be able to decide a row before its recommendation is ready.
- **FR-016**: Emails the owner did not decide on MUST be left unchanged when the window closes, and nothing MUST be learned for them.
- **FR-017**: The owner MUST be able to move between rows, accept a row and approve all from the keyboard.

**Applying**

- **FR-018**: Every action MUST apply only to the emails it covers, never to other emails selected in Mail, and filing and moving to the Trash MUST follow the same rules as for a single email: the owner's "keep in Inbox" choice, labels only for emails outside the Inbox, and no Move to Trash for emails already in the Trash.
- **FR-019**: When several emails in one action need the same new label, the system MUST create that label once.
- **FR-020**: Each applied row MUST show that it is done and what was done. A row that could not be applied MUST show why and stay open for a decision.
- **FR-021**: When one row of a multi-row action fails, the other rows of that action MUST still be applied.

**Learning**

- **FR-022**: Every applied decision MUST be learned for its own email, as a confirmation when the owner took that email's recommendation, as a correction when they chose otherwise, and as a learned deletion when the email was moved to the Trash.
- **FR-023**: A decision MUST be learned only after Mail has carried it out, so that a failed action teaches nothing.

**Privacy**

- **FR-024**: The batch MUST follow the same privacy rules as a single email: content stays on this computer, is held in memory only while the window is open, is never written to disk by the integration, and logs contain only identifiers and counts.
- **FR-025**: Development and automated checks MUST use synthetic emails and labels only.

### Key Entities

- **Batch**: the emails selected when the window opened, at most 50, from one account. Held in memory only while the window is open.
- **Batch row**: one email of the batch with its recommendation, whether it is marked or skipped, and its state: waiting, ready, failed, done, or could not be applied.
- **Decision**: what the owner did with one row: filed under a label (recommended or not), filed under a new label, or moved to the Trash. Each one is learned on its own, as for a single email.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Applying every recommendation of a batch takes at most 2 owner actions in total (the trigger, then approve all once the recommendations are ready), plus 1 confirmation when the batch includes moving emails to the Trash.
- **SC-002**: With the batch window open, correcting one row to another visible label takes at most 3 owner actions (choose the row, open its labels, pick one), without affecting any other row.
- **SC-003**: The batch window appears within 1 second of the trigger, with every row's sender and subject.
- **SC-004**: With the model already loaded, the first recommendation appears within 15 seconds, and a batch of 20 typical emails has all its recommendations within 5 minutes on the reference computer.
- **SC-005**: In tests, no email outside the action the owner took is ever changed, including emails selected in Mail that are not in the batch.
- **SC-006**: On the synthetic reference set, each email's recommendation in a batch is the same as the recommendation it gets when it is the only email selected, given the same learned data.
- **SC-007**: During a batch, the integration makes no network connection to anything other than this computer.

## Assumptions

- This feature is for the macOS Mail app. The web UI handles one pasted email at a time and does not change.
- This replaces today's behaviour for several selected emails, which files them all under the label recommended for the most recent one. The owner can still do that by marking all rows and choosing one label (Story 3).
- One owner, one computer, local mode, and one account per batch, as for a single email. The account can use Gmail labels or folders; filing means what it means for a single email in that kind of account.
- Recommendations are made one after another, as today, to fit the memory of the reference computer. A batch takes roughly as long as recommending each email on its own. The 50-email limit keeps a batch within a few minutes of waiting and within the window's space.
- A decision made during a batch is learned at once, so recommendations made after it can use it. Recommendations already shown are not made again.
- Each email of a conversation is decided on its own. Gmail's conversation view in a browser may show labels per conversation, but Mail applies them per email.
- Deleting a label from the batch window is out of scope. The owner does it from the single-email window, as today.
- Automatic filing without the owner's action is out of scope (constitution, Principle V).
