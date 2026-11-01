-- Initial schema. Source: specs/001-local-llm-categorizer/data-model.md

CREATE TABLE users (
  id         TEXT PRIMARY KEY,
  created_at TEXT NOT NULL
);

-- name: 1–80 chars; unique per user, case-insensitive (name_key). Exactly one default set per user.
CREATE TABLE category_sets (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
  name_key   TEXT NOT NULL,
  is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (user_id, name_key)
);
CREATE UNIQUE INDEX category_sets_one_default ON category_sets(user_id) WHERE is_default = 1;

-- name: 1–60 chars, must not contain '/'; name_key unique per (set_id, parent_id); max depth 2.
CREATE TABLE categories (
  id             TEXT PRIMARY KEY,
  set_id         TEXT NOT NULL REFERENCES category_sets(id) ON DELETE CASCADE,
  parent_id      TEXT REFERENCES categories(id) ON DELETE CASCADE,
  name           TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 60 AND instr(name, '/') = 0),
  name_key       TEXT NOT NULL,
  name_embedding BLOB,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);
CREATE UNIQUE INDEX categories_name_unique ON categories(set_id, coalesce(parent_id, ''), name_key);
CREATE INDEX categories_set ON categories(set_id);

CREATE TRIGGER categories_max_depth_insert BEFORE INSERT ON categories
WHEN NEW.parent_id IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'max depth 2')
  WHERE (SELECT parent_id FROM categories WHERE id = NEW.parent_id) IS NOT NULL;
  SELECT RAISE(ABORT, 'parent must be in the same set')
  WHERE (SELECT set_id FROM categories WHERE id = NEW.parent_id) IS NOT NEW.set_id;
END;

CREATE TRIGGER categories_max_depth_update BEFORE UPDATE OF parent_id ON categories
WHEN NEW.parent_id IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'max depth 2')
  WHERE (SELECT parent_id FROM categories WHERE id = NEW.parent_id) IS NOT NULL;
  SELECT RAISE(ABORT, 'max depth 2')
  WHERE EXISTS (SELECT 1 FROM categories WHERE parent_id = NEW.id);
  SELECT RAISE(ABORT, 'parent must be in the same set')
  WHERE (SELECT set_id FROM categories WHERE id = NEW.parent_id) IS NOT NEW.set_id;
END;

-- Only created from feedback. snippet: first ≤ 600 chars of the plain-text body.
CREATE TABLE learning_examples (
  id                      TEXT PRIMARY KEY,
  user_id                 TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  set_id                  TEXT NOT NULL REFERENCES category_sets(id) ON DELETE CASCADE,
  category_id             TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  suggested_category_path TEXT NOT NULL,
  outcome                 TEXT NOT NULL CHECK (outcome IN ('confirmed', 'corrected', 'accepted_new')),
  sender                  TEXT NOT NULL,
  subject                 TEXT NOT NULL,
  snippet                 TEXT NOT NULL CHECK (length(snippet) <= 600),
  embedding               BLOB NOT NULL,
  embedding_model         TEXT NOT NULL,
  decided_at              TEXT NOT NULL
);
CREATE INDEX learning_examples_set ON learning_examples(set_id);
CREATE INDEX learning_examples_category ON learning_examples(category_id);
CREATE INDEX learning_examples_user_decided ON learning_examples(user_id, decided_at);

-- Accuracy history: metadata only, no content and no category names.
CREATE TABLE decisions (
  id                  TEXT PRIMARY KEY,
  user_id             TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  learning_example_id TEXT REFERENCES learning_examples(id) ON DELETE SET NULL,
  outcome             TEXT NOT NULL CHECK (outcome IN ('confirmed', 'corrected', 'accepted_new')),
  confidence          TEXT NOT NULL CHECK (confidence IN ('high', 'medium', 'low')),
  was_new_proposal    INTEGER NOT NULL CHECK (was_new_proposal IN (0, 1)),
  decided_at          TEXT NOT NULL
);
CREATE INDEX decisions_user_decided ON decisions(user_id, decided_at);
