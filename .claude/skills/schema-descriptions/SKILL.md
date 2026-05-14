---
name: schema-descriptions
description: Add table and column descriptions to a SQLite Graph Studio sidecar file so they surface as hover tooltips on schema graph nodes. Use when the user asks to "document the schema", "annotate the tables", "explain what these columns mean", or hands you an unfamiliar database.
---

# schema-descriptions

You write descriptions to `<db>.sqlite.studio.json`, next to the database file. SQLite Graph Studio reads this sidecar at load time and when the user clicks **Features -> Schema Notes**. The database DDL is not modified.

Descriptions are intentionally a sidecar so users can edit them directly without rebuilding SQLite tables.

## Inputs you need

Before writing the file, gather:

1. **The database path.** Ask the user if not obvious. The sidecar lives next to it (for example, `app.sqlite` -> `app.sqlite.studio.json`).
2. **The schema.** Run `sqlite3 <db> ".tables"` and `sqlite3 <db> ".schema"` or inspect existing schema docs. You need exact table and column names.
3. **Small samples only when useful.** Pull up to 5 rows for unclear tables or columns. Do not inspect more data than needed for documentation.

## Output format

Preserve any existing `clusters` block. Add or replace only the `tables` entries you are documenting.

```json
{
  "version": 1,
  "tables": {
    "users": {
      "description": "App account roster - one row per signed-up user.",
      "columns": {
        "email": "Lowercased login email.",
        "status": "active | suspended | pending"
      }
    },
    "orders": {
      "description": "Customer purchase record, one row per checkout.",
      "columns": {
        "total_cents": "Order total in cents.",
        "created_at": "UTC timestamp from checkout."
      }
    }
  },
  "clusters": []
}
```

Field rules:

- `tables` - object keyed by exact case-sensitive table or view name.
- `description` - optional table-level description shown when hovering the table name.
- `columns` - optional object keyed by exact case-sensitive column name.
- Unknown table or column names are ignored by the app, so verify spelling before writing.

## Workflow

1. Read `<db>.sqlite.studio.json` if it already exists.
2. List the schema with `sqlite3` or by reading existing schema docs.
3. Draft concise table and column descriptions.
4. Write the sidecar JSON, preserving unrelated fields such as `clusters`.
5. Tell the user to click **Features -> Schema Notes** in the running app to reload the sidecar.

## Writing good descriptions

Tooltip space is small. Aim for:

- **Tables**: 1 sentence, about 10 words. State the table grain: what one row represents.
  - Good: `App account roster - one row per signed-up user.`
  - Bad: `This table contains users.`
- **Columns**: 3-10 words. Include format, unit, source of truth, or a quirk.
  - Good: `Cents, never null`, `FK -> tenants.id, NULL for staff`, `active | suspended | pending`
  - Bad: `The user's email address.`

Skip obvious columns like `id`, `created_at`, and `updated_at` unless they have a real quirk. Do not speculate. If you would be guessing, leave the field out.

## What not to do

- Don't modify SQLite DDL or add SQL comments. Descriptions belong in the sidecar.
- Don't overwrite existing `clusters`.
- Don't invent table or column names.
- Don't read more than 5 sample rows per table.
- Don't commit the sidecar without asking. Some users want it gitignored.