---
name: schema-descriptions
description: Add `--` line comments to a SQLite database's DDL so SQLite Graph Studio surfaces them as hover tooltips on table and column nodes. Use when the user asks to "document the schema", "annotate the tables", "explain what these columns mean", or hands you an unfamiliar database. The app reads the comments from `sqlite_master.sql` at load time — no sidecar file is involved for descriptions.
---

# schema-descriptions

You add `--` line comments to the DDL stored in `sqlite_master.sql`. SQLite Graph Studio parses those comments at load time and shows them as native macOS hover tooltips, with a tiny accent dot indicating "has description." Layout is unaffected — the cards don't grow, the view doesn't split.

The `.studio.json` sidecar is **not** used for descriptions anymore. It is still used for cluster hints (see `graph-clusters`). Descriptions live in the database itself.

## How SQLite stores comments — read this first

SQLite's `sqlite_master.sql` contains the CREATE statement as the user wrote it, with one catch:

- ✅ Comments **inside** `CREATE TABLE ( … )` are preserved.
- ✅ Comments **inside** `CREATE VIEW name AS … SELECT …` are preserved.
- ❌ Comments **before** `CREATE TABLE` or `CREATE VIEW` are silently dropped. Do not rely on them.

This determines where you put the comments.

## The placement rules the app parses

These rules are enforced by `DDLCommentParser.swift`. Stick to them or your comments won't show up.

**Column description** — one of:
1. Stacked `--` lines on the line(s) immediately before the column.
2. A trailing `-- …` comment on the same line as the column.

```sql
CREATE TABLE users (
  -- App account id; autoincrement
  id INTEGER PRIMARY KEY,
  email TEXT, -- lowercased, verified at signup
  status TEXT
);
```

**Table description** — a `--` comment block at the top of the parens, **separated from the first column by a blank line**. The blank line is mandatory; without it the comments belong to the first column instead.

```sql
CREATE TABLE users (
  -- App account roster - one row per signed-up user.
  -- Soft-deleted rows kept for 30 days then purged.

  id INTEGER PRIMARY KEY,
  email TEXT
);
```

**View description** — a `--` comment block between `AS` and the SELECT body.

```sql
CREATE VIEW active_users AS
  -- Excludes soft-deleted rows and unverified signups.
  SELECT id, email FROM users WHERE status = 'active';
```

**Where comments are dropped** — before constraint defs (PRIMARY KEY, FOREIGN KEY, CHECK, UNIQUE, CONSTRAINT, …) and outside the CREATE statement. The parser ignores them.

## How to actually add comments

SQLite has no `COMMENT ON COLUMN …` syntax — and `ALTER TABLE` cannot edit a column definition. To attach a comment to an existing table you must **recreate the table** with the comments embedded. SQLite docs call this the "12-step ALTER TABLE" pattern; here's the safe version:

```sql
BEGIN;

-- 1. Inspect the existing definition.
-- (Look at SELECT sql FROM sqlite_master WHERE name='users' first.)

-- 2. Rename the existing table.
ALTER TABLE users RENAME TO users_old;

-- 3. Create the new table with the same columns + your comments.
CREATE TABLE users (
  -- App account roster - one row per signed-up user.

  -- Surrogate key. Never reused.
  id INTEGER PRIMARY KEY,
  email TEXT UNIQUE, -- lowercased, verified at signup
  -- active | suspended | pending_verification
  status TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- 4. Copy data across.
INSERT INTO users (id, email, status, created_at)
SELECT id, email, status, created_at FROM users_old;

-- 5. Drop the old table.
DROP TABLE users_old;

COMMIT;
```

Disable foreign keys around the rebuild if other tables reference this one:

```sql
PRAGMA foreign_keys = OFF;
BEGIN;
-- … the rebuild …
COMMIT;
PRAGMA foreign_keys = ON;
PRAGMA foreign_key_check;  -- bail if anything is broken
```

You **must** preserve:
- All column types, NOT NULL, DEFAULT, CHECK, UNIQUE constraints.
- The primary key shape (including composite keys and `WITHOUT ROWID`).
- Foreign keys (re-declare them).
- Indexes and triggers (drop, recreate after the swap).

When in doubt, dump the table with `.schema <name>` and modify only the comment lines.

## New tables

If you are writing a `CREATE TABLE` that doesn't exist yet, embed the comments directly — no rebuild needed:

```sql
CREATE TABLE orders (
  -- One row per customer order. Status transitions: pending → paid → shipped → cancelled.

  id INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL REFERENCES customers(id),
  -- pending | paid | shipped | cancelled
  status TEXT NOT NULL DEFAULT 'pending',
  total_cents INTEGER NOT NULL, -- order total in cents, always > 0
  created_at TEXT NOT NULL
);
```

## Workflow

**Always ask the user for permission before modifying the database.** Describe which tables will be rebuilt and what will change, then wait for explicit confirmation before running any SQL.

1. **Read** the current DDL: `sqlite3 <db> ".schema <table>"` or `SELECT sql FROM sqlite_master WHERE name = ?`.
2. **Pull 5 sample rows** per table — concrete values often contradict what column names imply.
3. **Draft** the rebuild SQL in chat, with comments added. Show the user before executing.
4. **Ask for permission** — list the tables to be rebuilt and confirm the user wants to proceed.
5. **Run inside a transaction.** Confirm row count matches before COMMIT.
6. **Tell the user** to click **Features → Schema Notes** in the running app. That re-reads `sqlite_master` and refreshes the tooltips.
7. Skip tables that are tiny or self-explanatory. Mention which you skipped so the user isn't surprised.

## Writing good descriptions

Tooltip space is small. Aim for:

- **Tables**: 1 sentence, ~10 words. What's one row? What's the grain?
  - Good: `App account roster - one row per signed-up user. Soft-deleted kept 30 days.`
  - Bad: `This table contains users.`
- **Columns**: 3–10 words. Format, unit, source of truth, or a quirk.
  - Good: `Cents, never null`, `FK -> tenants.id, NULL for staff`, `active | suspended | pending`
  - Bad: `The user's email address.`

Skip the obvious. Don't describe `id`, `created_at`, `updated_at` unless they have a quirk. Don't speculate ("probably …"). If you'd be guessing, leave the column out.

## What not to do

- Don't write SQL comments **before** `CREATE TABLE` — they don't survive.
- Don't omit the blank line separator for table descriptions — without it the comments attach to the first column.
- Don't use `/* block comments */` — the parser only handles `--` line comments.
- Don't put descriptions in the `.studio.json` sidecar — that field was removed.
- Don't read more than 5 rows per table; this is documentation, not data exfiltration.
- Don't run the rebuild outside a transaction. A crash mid-copy loses data.
- Don't drop and recreate triggers or indexes silently — list what you're doing and ask first.
