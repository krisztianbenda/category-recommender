-- Deletion as a decision (specs/003-delete-suggestion). A learning example can record that the
-- owner deleted the email instead of filing it; such an example has no category.
-- SQLite cannot change a column or a CHECK in place, so learning_examples is rebuilt
-- (https://sqlite.org/lang_altertable.html#otheralter). migrate() runs this with foreign keys off
-- and checks them before it commits.

CREATE TABLE learning_examples_new (
  id                      TEXT PRIMARY KEY,
  user_id                 TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  set_id                  TEXT NOT NULL REFERENCES category_sets(id) ON DELETE CASCADE,
  category_id             TEXT REFERENCES categories(id) ON DELETE CASCADE,
  suggested_category_path TEXT NOT NULL,
  outcome                 TEXT NOT NULL CHECK (outcome IN ('confirmed', 'corrected', 'accepted_new', 'deleted')),
  sender                  TEXT NOT NULL,
  subject                 TEXT NOT NULL,
  snippet                 TEXT NOT NULL CHECK (length(snippet) <= 600),
  embedding               BLOB NOT NULL,
  embedding_model         TEXT NOT NULL,
  decided_at              TEXT NOT NULL,
  CHECK ((outcome = 'deleted') = (category_id IS NULL))
);

INSERT INTO learning_examples_new
  (id, user_id, set_id, category_id, suggested_category_path, outcome, sender, subject, snippet,
   embedding, embedding_model, decided_at)
SELECT id, user_id, set_id, category_id, suggested_category_path, outcome, sender, subject, snippet,
   embedding, embedding_model, decided_at
FROM learning_examples;

DROP TABLE learning_examples;
ALTER TABLE learning_examples_new RENAME TO learning_examples;

CREATE INDEX learning_examples_set ON learning_examples(set_id);
CREATE INDEX learning_examples_category ON learning_examples(category_id);
CREATE INDEX learning_examples_user_decided ON learning_examples(user_id, decided_at);

-- Accuracy history: whether the suggestion was to delete the email (metadata only).
ALTER TABLE decisions ADD COLUMN was_delete_suggestion INTEGER NOT NULL DEFAULT 0
  CHECK (was_delete_suggestion IN (0, 1));
