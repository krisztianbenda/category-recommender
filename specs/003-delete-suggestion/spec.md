# Feature Specification: Suggest Deleting an Email

**Feature Branch**: `003-delete-suggestion`

**Created**: 2026-11-09

**Status**: Implemented

**Input**: User description: "Make it possible to suggest the email deletion. Currently the recommendation is a targeted folder/label but if an email fits nowhere (most probably similars were deleted previously or even can be found at the Trash), suggest to delete the mail itself."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An email like the ones I delete is suggested for the Trash (Priority: P1)

The owner selects an email in Mail and opens the recommender, as for filing. If the owner deletes emails like this one, the recommendation is to move it to the Trash, and says why. One action moves it to the Trash. The label it would otherwise go to is right below, so filing it instead is also one action.

**Why this priority**: This is the feature. Some emails belong nowhere, and filing them under a poor label is worse than deleting them.

**Independent Test**: With three similar synthetic emails from one sender in the Trash, select a fourth from that sender, open the recommender, and check that "Move to Trash" is recommended. Accept it and check the email is in the Trash and the decision was learned.

**Acceptance Scenarios**:

1. **Given** similar emails from the same sender are in the Trash, **When** no label fits the email well, **Then** moving it to the Trash is recommended, and the reason says how many similar emails are in the Trash.
2. **Given** the owner deleted similar emails through the recommender before, **When** the recommender is opened, **Then** moving to the Trash is recommended, and the reason says how many similar emails were deleted.
3. **Given** moving to the Trash is recommended, **When** the owner accepts it, **Then** the email is moved to the Trash with Mail's own Delete command, the deletion is learned, and the window closes.
4. **Given** moving to the Trash is recommended, **When** the owner picks a label instead, **Then** the email is filed and the recommender learns that this kind of email is kept.
5. **Given** the owner keeps filing similar emails, **Then** deletion is no longer recommended for them.

---

### User Story 2 - Delete any email from the window (Priority: P1)

Whatever is recommended, the owner can move the email to the Trash from the same window. The recommender learns from it.

**Why this priority**: Without it, the recommender never learns which emails the owner deletes, except from the Trash.

**Independent Test**: Open the recommender on a synthetic email with a label recommendation, choose Move to Trash, and check the email is in the Trash and the deletion is learned.

**Acceptance Scenarios**:

1. **Given** a label is recommended, **When** the owner chooses Move to Trash, **Then** the email is moved to the Trash and the decision is learned as a correction.
2. **Given** the recommendation is not ready yet, **When** the owner moves the email to the Trash, **Then** it is moved at once, and the decision is learned when the recommendation arrives.

### Edge Cases

- **The selected email is in the Trash already**: Mail's Delete there erases it for good, so moving to the Trash is neither recommended nor offered.
- **Mail shows no Trash for the account**: nothing is recommended for deletion and nothing is deleted.
- **Mail's selection changed after the window opened**: nothing is deleted, and the window says why.
- **The app may not use Mail's menus (Accessibility)**: nothing is deleted, and the window says what to allow.
- **Mail's Delete ran but the email did not arrive in the Trash**: nothing is learned, and the window tells the owner to check Mail's Trash setting.
- **A trashed email from the same sender is about something else** (for example a statement and a promotion from one bank): only trashed emails whose subject is about the same thing count.
- **No evidence at all**: deletion is never recommended just because no label fits. The model alone never decides on deletion.
- **A client that does not know about deletion** (an older app, the web UI before this change): never receives a suggestion to delete.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST be able to recommend moving an email to the Trash instead of a label.
- **FR-002**: It MUST recommend deletion only on evidence from the owner's own behaviour: similar emails the owner deleted through the recommender, or similar emails from the same sender that are in the Trash.
- **FR-003**: When a label fits, deletion MUST need as much evidence as the owner's habits need to override the model's label. When no label fits, deletion MUST be at least as likely as filing among the similar emails.
- **FR-004**: A suggestion to delete MUST say why, and MUST still name the label the email would go to if kept.
- **FR-005**: The owner MUST be able to move the selected email to the Trash from the window in one action, whatever is recommended.
- **FR-006**: Moving to the Trash MUST use Mail's own Delete command, only on exactly the selected emails, and never on an email already in the Trash.
- **FR-007**: Every deletion from the window MUST be learned, as a confirmation if deletion was recommended and as a correction otherwise. Filing an email that was recommended for deletion MUST be learned as a correction.
- **FR-008**: The integration MUST read only the sender and subject of emails in the Trash, and the service MUST NOT store them.
- **FR-009**: A learned deletion MUST be visible and deletable under Learned data, like any learned decision.
- **FR-010**: Accuracy statistics MUST report how many deletions were suggested and how many were accepted.

### Key Entities

- **Learned deletion**: a learning example with no category, recording that the owner deleted an email like this one.
- **Trashed email**: sender and subject of an email in the account's Trash, read when the window opens and used only for that recommendation.

## Success Criteria *(mandatory)*

- **SC-001**: Moving an email to the Trash when that is recommended takes at most 2 owner actions: one trigger and one accept.
- **SC-002**: On synthetic data, an email like three emails from its sender in the Trash is recommended for deletion, and an email from that sender about something else is not.
- **SC-003**: No email already in the Trash is ever deleted again by the integration.

## Assumptions

- The Trash is Gmail's Trash as Mail shows it. Mail moves an email there with its own Delete command when the account is set to move deleted messages to the Trash, which is Mail's default for Gmail.
- Gmail empties its Trash after 30 days, so the Trash is evidence of recent deletions only. Learned deletions last until the owner deletes them.
- The owner triggers every recommendation and every deletion (constitution V). Nothing is deleted automatically.
