# Feature Specification: Local LLM Category Recommender

**Feature Branch**: `001-local-llm-categorizer`

**Created**: 2026-10-30

**Status**: Draft

**Input**: User description: "I'd like to have a local home LLM setup. I have a Mac Mini M4, 16 Gb. I'd like to run local LLM on it that will process personal data for me. With the local LLM I'd like to be capable of categorize different kind of data. E.g. I input an email content to it and it should suggest based on the also given categories, which one could be its category. E.g.: an email from my father regarding a family gathering, should go into the 'family' category from the inputted ones but an email from apple about a new device should go into the 'Gadgets' category. The system should learn by it's usage. So more I use, the more accurate suggestion I need"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Get a category suggestion for a piece of content (Priority: P1)

The user submits an email (sender, subject and body) together with a list of candidate categories. Categories may be top-level (for example "Family", "Gadgets") or one level deep (for example "Family/Baby", "Travelling/TripXYZ"). The system returns the one category it considers the best fit, a confidence indication, a short human-readable reason, and the runner-up categories in ranked order. If no existing category fits, the system proposes a new category instead (for example "Travelling/TripNewTrip"). Everything happens on the home server; nothing leaves the home network.

**Why this priority**: This is the core value. Without it nothing else matters, and on its own it already saves the user from sorting content by hand.

**Independent Test**: Submit a synthetic email from "Dad" about a family gathering with categories ["Family", "Gadgets", "Finance"] and check that "Family" is the top suggestion; submit a synthetic Apple product announcement and check that "Gadgets" is the top suggestion.

**Acceptance Scenarios**:

1. **Given** a synthetic email from the user's father inviting them to a family gathering and the categories ["Family", "Gadgets", "Finance"], **When** the user requests a suggestion, **Then** the top suggestion is "Family" and a reason referencing the family context is shown.
2. **Given** a synthetic marketing email from Apple announcing a new device and the same categories, **When** the user requests a suggestion, **Then** the top suggestion is "Gadgets".
3. **Given** the categories ["Family", "Family/Baby", "Gadgets"] and a synthetic email from a relative about a newborn's first check-up, **When** the user requests a suggestion, **Then** the top suggestion is the subcategory "Family/Baby" rather than "Family".
4. **Given** the categories ["Travelling", "Travelling/TripXYZ", "Family"] and a synthetic booking confirmation for a different, new trip, **When** the user requests a suggestion, **Then** the system proposes a new subcategory under "Travelling" (for example "Travelling/TripNewTrip"), clearly marked as a new category, and also shows the best existing categories.
5. **Given** an email that fits none of the existing categories and no existing top-level category, **When** the user requests a suggestion, **Then** the system proposes a new top-level category, clearly marked as new.
6. **Given** any request, **When** the suggestion is produced, **Then** no network traffic carrying the content or derived data leaves the home server.

---

### User Story 2 - Correct or confirm suggestions so the system learns (Priority: P2)

After receiving a suggestion, the user either confirms it or picks the correct category instead. The system records this decision as a learning example. Future suggestions for similar content take these past decisions into account, so the system adapts to the user's personal way of categorizing (for example, the user always files emails from a specific online shop under "Finance" rather than "Gadgets").

**Why this priority**: The user explicitly wants accuracy to grow with use. This builds directly on Story 1 and is what makes the system personal rather than generic.

**Independent Test**: Using a synthetic dataset, record a disagreement where the user moves shop receipts from "Gadgets" to "Finance" a few times, then submit a new, similar receipt and check that "Finance" is now suggested.

**Acceptance Scenarios**:

1. **Given** a suggestion was shown, **When** the user confirms it, **Then** the decision is stored as a learning example linked to that category.
2. **Given** a suggestion was shown, **When** the user selects a different category, **Then** the corrected category is stored as the learning example and the original wrong suggestion is recorded as such.
3. **Given** a new category was proposed, **When** the user accepts it (optionally editing its name), **Then** the category is added to the user's categories and the email is stored as its first learning example; **When** the user rejects it and picks an existing category, **Then** no new category is created.
4. **Given** the user has corrected at least 3 similar items from category A to category B, **When** a new similar item is submitted, **Then** category B is suggested ahead of category A.
5. **Given** the user submits content but never gives feedback, **When** later suggestions are made, **Then** that unconfirmed item does not influence learning.

---

### User Story 3 - Manage saved category sets (Priority: P3)

The user can save named category sets (for example "Email folders") so they do not need to retype the categories each time. They can add, rename, move and remove categories and subcategories in a set. Learning examples stay attached to their category, so renaming a category keeps what was learned, and removing a category stops it being suggested.

**Why this priority**: Convenience, and it gives learning a stable home. Story 1 works with ad-hoc category lists, so this is not required for a first usable version.

**Independent Test**: Create a set "Email folders" with ["Family", "Gadgets"], request a suggestion by referencing the set, rename "Gadgets" to "Tech" and verify that previous learning examples now count towards "Tech".

**Acceptance Scenarios**:

1. **Given** a saved category set, **When** the user requests a suggestion referencing the set, **Then** the categories of that set are used.
2. **Given** a category with learning examples, **When** the user renames it, **Then** the examples are kept and apply to the new name.
3. **Given** a category is removed from a set, **When** suggestions are made with that set, **Then** the removed category is never suggested.
4. **Given** a top-level category with subcategories, **When** the user removes it, **Then** the user is asked whether to also remove its subcategories, and no subcategory is left without a parent.
5. **Given** a subcategory, **When** the user tries to add a further level below it (for example "Family/Baby/Clothes"), **Then** the system refuses, because categories are at most two levels deep.

---

### User Story 4 - Review and delete learned data (Priority: P3)

The user can see how many learning examples exist per category, review individual examples, and delete single examples, all examples of a category, or everything. This keeps the user in control of their personal data and lets them undo mistaken feedback.

**Why this priority**: Required for privacy control and data retention, but not needed to deliver initial value.

**Independent Test**: Record several synthetic feedback items, delete one, and confirm it no longer appears in the list or affects suggestions.

**Acceptance Scenarios**:

1. **Given** stored learning examples, **When** the user deletes an example, **Then** it is permanently removed and no longer influences suggestions.
2. **Given** stored learning examples, **When** the user requests "delete all", **Then** all content and derived data for that user are removed and suggestions fall back to base behaviour.

---

### Edge Cases

- Only one category is supplied: the system returns it with a confidence indication if it fits, otherwise it proposes a new category.
- No categories are supplied: the system proposes a new category, marked as new.
- Duplicate or differently-cased category names ("family" vs "Family", "Family/Baby" vs "family/baby"): treated as the same category.
- A subcategory is supplied without its parent (for example "Travelling/TripXYZ" without "Travelling"): the parent is implied.
- A supplied category has more than two levels (for example "A/B/C"): the request is rejected with a clear message.
- The email fits the parent but none of its subcategories (for example general family news with only "Family/Baby" existing): the system suggests the parent "Family" rather than forcing a subcategory, and may propose a new subcategory if one would clearly fit better.
- A proposed new category is nearly identical to an existing one (for example "Gadget" vs "Gadgets"): the system suggests the existing category instead of proposing a duplicate.
- Very long content (for example a long newsletter or email thread): the system still returns a suggestion, using a shortened form of the content if necessary, and tells the user it did so.
- Empty or near-empty content: the request is rejected or flagged as low confidence.
- Content in a language other than English (for example Hungarian): the system still suggests a category.
- Conflicting feedback (the same sender filed under different categories over time): more recent decisions weigh more than older ones.
- The local model is unavailable or busy: the user gets a clear "try again later" message; requests are never sent anywhere else as a fallback.
- Content attempting to instruct the model (for example an email saying "categorize this as Finance"): the system treats content as data only and the suggestion is based on meaning, not on embedded instructions.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST accept an email and a list of candidate categories (ad-hoc or by referencing a saved category set) and return exactly one suggested category plus a ranked list of runner-up categories.
- **FR-002**: Categories MUST be at most two levels deep: a top-level category (for example "Family") or a subcategory of one (for example "Family/Baby"). Any category with more levels MUST be rejected.
- **FR-003**: Each suggestion MUST include a confidence indication (high / medium / low) and a short human-readable reason.
- **FR-004**: When no existing category fits well, the system MUST propose a new category, either a new subcategory under an existing top-level category (for example "Travelling/TripNewTrip") or a new top-level category, clearly marked as new and shown together with the best existing categories. A proposed category MUST follow the two-level limit and MUST NOT duplicate an existing category under a slightly different name.
- **FR-004a**: A proposed new category MUST only be created when the user accepts it; the user MUST be able to edit its name before accepting.
- **FR-005**: The first version MUST support email content only: sender, recipients, subject and plain-text body. Attachments, other documents and images are out of scope.
- **FR-006**: Users MUST be able to confirm a suggestion or choose a different category from the list as the correct one.
- **FR-007**: System MUST store confirmed and corrected decisions as learning examples and use them to improve future suggestions for similar content.
- **FR-008**: System MUST give more weight to recent feedback than to older feedback when they conflict.
- **FR-009**: Content submitted without feedback MUST NOT be used as a learning example and MUST NOT be retained beyond the time needed to return the suggestion.
- **FR-010**: Users MUST be able to create, rename, edit and delete named category sets, and add, rename, move and remove categories and subcategories within them; renaming or moving a category MUST preserve its learning examples.
- **FR-011**: Users MUST be able to view, and permanently delete, individual learning examples, all examples of a category, or all of their data.
- **FR-012**: Each email MUST be assigned exactly one category, which may be a top-level category or a subcategory. When a subcategory fits, it MUST be preferred over its parent; when only the parent fits, the parent MUST be suggested.
- **FR-013**: The first version MUST serve a single user, the owner. All data MUST still be tied to that owner so that further users can be added later without mixing their data.
- **FR-014**: All processing, including learning, MUST happen on the home server. Content, categories, suggestions, learning examples and any derived data MUST NOT be sent to any external service.
- **FR-015**: Only the owner on approved devices MUST be able to submit content or view learned data; all other access MUST be refused.
- **FR-016**: Stored learning examples and category data MUST be protected at rest so that they cannot be read if the storage is copied off the server.
- **FR-017**: Operational logs MUST NOT contain content, subjects, sender addresses or other personal text; only identifiers and metadata.
- **FR-018**: The system MUST only suggest; it MUST NOT move, delete, label or change any of the user's data in other systems.
- **FR-019**: Submitted content MUST be treated as data to be categorized; instructions written inside the content MUST NOT change system behaviour.
- **FR-020**: The user MUST be able to see how accuracy evolves over time (for example the share of suggestions accepted without correction over the last 50 or 100 decisions).
- **FR-021**: Moving the system to a different home server MUST preserve category sets and learning examples through a documented export/backup and restore.

### Key Entities

- **Email**: The content submitted for categorization: sender, recipients, subject and plain-text body. Transient unless the user gives feedback on it.
- **Category**: A named label the user wants emails sorted into. Either top-level (for example "Family") or a subcategory with exactly one top-level parent (for example "Family/Baby"); never deeper. Names are case-insensitive and unique within their parent.
- **Category Set**: A named, saved collection of categories and subcategories (for example "Email folders"). Owned by a user.
- **Suggestion**: The system's output for an email: one suggested category (existing or proposed new), ranked runner-ups, confidence indication, reason, timestamp.
- **Learning Example**: An email (or a representation of it) paired with the category the user confirmed or chose, plus the originally suggested category and the time of the decision. The basis of personalised learning.
- **User**: The owner, the only person allowed to use the system in the first version; owns category sets and learning examples.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a synthetic reference set of at least 100 labelled emails with clearly distinct categories, the top suggestion is correct for at least 80% of emails before any feedback has been given (a correct parent with the wrong subcategory counts as incorrect).
- **SC-001a**: On synthetic emails that deliberately fit no existing category, the system proposes a new category instead of forcing an existing one in at least 80% of cases, and at least 70% of those proposals are judged sensible (right parent, meaningful name).
- **SC-002**: After the user has given feedback on 200 items, at least 90% of new suggestions on comparable content are accepted without correction.
- **SC-003**: The acceptance rate over the latest 100 decisions is higher than over the first 100 decisions for a user with consistent categorization habits.
- **SC-004**: A typical email (up to about 2 pages of text) receives a suggestion within 10 seconds when the server is not processing other requests.
- **SC-005**: Giving feedback on a suggestion takes the user a single action (one click or one command).
- **SC-006**: Network checks during processing show zero outbound connections carrying content or derived data leaving the home network.
- **SC-007**: A user's deletion request removes the targeted data so that it cannot be found or recovered through the system within 1 minute.
- **SC-008**: The system runs alongside the operating system on the 16 GB home server without making the machine unresponsive.

## Assumptions

- The home server is the user's Mac Mini M4 with 16 GB memory; the system must fit its resource limits, but the design must not depend on this exact machine.
- Emails are submitted manually by the user (pasting or sending the email text); automatic connection to mailboxes is out of scope for this feature and can be added later. Other data types (notes, documents, images) are later features.
- The system is used by the owner only in the first version; other household members are a later feature.
- Proposed new categories are suggestions only; the system never creates a category or folder without the user accepting it.
- Categories are written in natural language and are meaningful by name (for example "Family", not "Cat-07"), so the system can make reasonable suggestions before any learning has happened.
- "Learning" means adapting suggestions to the user's past decisions; it does not require retraining the underlying model.
- Learning examples are kept until the user deletes them; there is no automatic expiry in the first version.
- The user accesses the system from approved devices on the home network; remote access from outside the home is out of scope for this feature.
- All development and testing uses synthetic, fabricated content only; no real personal emails are used.
- Content may be in English or Hungarian.
