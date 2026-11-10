# Data Model: Local LLM Category Recommender

**Feature**: [spec.md](./spec.md) | **Research**: [research.md](./research.md)

All persisted data lives in one SQLite database at a configured path outside the repository, on an encrypted volume (research R12). Every row carries `user_id`. In the first version this is always `owner` (FR-013), so more users can be added later without a migration of meaning.

## Entities

### User

| Field | Type | Rules |
|-------|------|-------|
| `id` | text, PK | `owner` in v1 |
| `created_at` | timestamp | |

Users are created from configuration (`access.devices[].user`), not through the API.

### CategorySet

| Field | Type | Rules |
|-------|------|-------|
| `id` | text (ULID), PK | |
| `user_id` | FK → User | |
| `name` | text | 1–80 chars; unique per user, case-insensitive |
| `is_default` | boolean | Exactly one default set per user, auto-created with the name `Default`. Ad-hoc requests use it. |
| `created_at`, `updated_at` | timestamp | |

### Category

| Field | Type | Rules |
|-------|------|-------|
| `id` | text (ULID), PK | |
| `set_id` | FK → CategorySet | cascade delete |
| `parent_id` | FK → Category, nullable | `null` = top-level. If set, the parent MUST itself have `parent_id = null` (max depth 2, FR-002). |
| `name` | text | 1–60 chars; must not contain `/`; trimmed |
| `name_key` | text | normalised name (lower-case, accents folded, whitespace collapsed); unique per `(set_id, parent_id)` |
| `name_embedding` | blob, nullable | used for the near-duplicate check on new-category proposals (R5) |
| `created_at`, `updated_at` | timestamp | |

**Derived**: `path` = `Parent/Child` or `Name`. It is matched case-insensitively.

**Rules**:
- *Rename* changes `name` and `name_key` only; learning examples keep pointing at the same `id` (FR-010).
- *Move* (change parent) is allowed only if the category has no children and the target is top-level.
- *Delete* of a top-level category with children requires `cascade=true`; otherwise it is rejected (no orphans). Deleting a category deletes its learning examples.
- Ad-hoc candidate lists: on feedback, any accepted path not yet in the default set is upserted there. A missing parent is created implicitly.

### LearningExample

| Field | Type | Rules |
|-------|------|-------|
| `id` | text (ULID), PK | |
| `user_id` | FK → User | |
| `set_id` | FK → CategorySet | |
| `category_id` | FK → Category, nullable | the category the user confirmed or chose; cascade delete. `null` exactly when `outcome` is `deleted` |
| `suggested_category_path` | text | what the system suggested (may be a new proposal) |
| `outcome` | enum | `confirmed` \| `corrected` \| `accepted_new` \| `deleted` (the user deleted the email instead of filing it, specs/003) |
| `sender` | text | from the email |
| `subject` | text | |
| `snippet` | text | first ≤ 600 chars of the plain-text body (used in few-shot prompts) |
| `embedding` | blob (float32, L2-normalised) | |
| `embedding_model` | text | model id; examples with a different model are re-embedded on startup |
| `decided_at` | timestamp | drives the recency weight (FR-008) |

Only created from feedback (FR-009). The full email body is never stored, only the snippet.

### Decision (accuracy history, FR-020)

| Field | Type | Rules |
|-------|------|-------|
| `id` | text (ULID), PK | |
| `user_id` | FK → User | |
| `learning_example_id` | FK → LearningExample, nullable | set to `null` when the example is deleted |
| `outcome` | enum | `confirmed` \| `corrected` \| `accepted_new` |
| `confidence` | enum | `high` \| `medium` \| `low` at suggestion time |
| `was_new_proposal` | boolean | |
| `was_delete_suggestion` | boolean | the suggestion was to delete the email (specs/003) |
| `decided_at` | timestamp | |

No content or category names: this table holds metadata only. It lets accuracy over the last N decisions be computed even after examples are deleted. "Delete all my data" removes these rows too.

### PendingSuggestion (in memory only, never persisted)

| Field | Type | Rules |
|-------|------|-------|
| `id` | ULID | returned to the client |
| `user_id` | | |
| `set_id` | | or the default set for ad-hoc requests |
| `candidates` | category paths | as supplied |
| `content_hash` | SHA-256 of the normalised email | feedback must match |
| `embedding` | float32[] | reused for the learning example |
| `result` | Suggestion | see the contract |
| `created_at` | | expires after `suggestions.ttlSeconds` (default 3600) |

## State transitions

```text
PendingSuggestion --(feedback: confirm)-------> LearningExample(outcome=confirmed)   + Decision
PendingSuggestion --(feedback: choose other)--> LearningExample(outcome=corrected)   + Decision
PendingSuggestion --(feedback: accept new)----> Category created + LearningExample(outcome=accepted_new) + Decision
PendingSuggestion --(feedback: delete)--------> LearningExample(outcome=deleted, no category) + Decision
PendingSuggestion --(TTL expires / restart)---> discarded (nothing stored)
LearningExample  --(user delete)--------------> removed; Decision.learning_example_id = null
```

## Validation rules (from the spec)

| Rule | Source |
|------|--------|
| Path depth ≤ 2; a request with `A/B/C` → 400 | FR-002, edge cases |
| Candidate paths are de-duplicated case-insensitively; `A/B` without `A` implies `A` | edge cases |
| The suggested category is always in the candidates, or `isNew=true` | FR-001, FR-004 |
| The new-category parent is an existing top-level candidate or `null`; not a near-duplicate | FR-004 |
| Email requires a non-empty subject or body (after trimming) | edge cases |
| Feedback content hash must equal the pending suggestion's hash | R7 |
| The chosen category in feedback must be a candidate or the accepted proposal (editable name, same depth rules) | FR-004a, FR-006 |

## Retention

| Data | Retention | Deletion |
|------|-----------|----------|
| Email submitted for a suggestion | in memory ≤ TTL; never on disk | automatic |
| Trashed emails sent with a suggestion (sender, subject) | for that request only; never stored | automatic |
| LearningExample | until the user deletes it | single, by category, or all (FR-011) |
| Decision | until the user deletes all data | with "delete all" |
| Category sets and categories | until the user deletes them | API |
| Logs | rotated, 14 days; no personal content | automatic |
| Backups | owner-managed, encrypted | owner |
