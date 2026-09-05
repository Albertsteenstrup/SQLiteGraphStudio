---
name: schema-descriptions
description: Add table and column descriptions to a SQLite Graph Studio sidecar file so they surface as hover tooltips on schema graph nodes, table grids, and query result headers. Use when the user asks to "document the schema", "annotate the tables", "explain what these columns mean", or hands you an unfamiliar database.
---

# schema-descriptions

You write descriptions to `<document>.studio.json`, beside the opened database file or PostgreSQL connection document. SQLite Graph Studio reads this sidecar at load time and when the user clicks **Relayout**. The notes appear when hovering schema graph nodes, table names and headers in table grids, and matching query result headers. The database DDL is not modified.

Descriptions are intentionally a sidecar so users can edit them directly without changing the database schema.

## Database documents and read-only discovery

Append `.studio.json` to the complete opened filename. A SQLite file uses `app.sqlite.studio.json`; a PostgreSQL connection document uses `catalog.postgres.studio.json` or `catalog.pgstudio.studio.json`. Keep the sidecar beside that document, even when another document connects to the same database. Never put credentials in the sidecar or modify the connection document.

For PostgreSQL, use the app's exact schema-qualified table IDs, such as `public.orders`, everywhere a table is referenced. This includes `tables` keys, cluster membership, and story playback `tables`, `focus`, `expand`, and `relation.table`. Keep column names exact and unqualified. Do not remove the schema or split IDs on dots: schema, table, and column names can themselves contain dots. When writing discovery SQL, quote the schema and object separately, for example `"public"."orders"`.

For SQLite, inspect schema with `sqlite3 -readonly <db> ".tables"` and `sqlite3 -readonly <db> ".schema"`, or use existing schema documentation. For PostgreSQL, use a schema export or an already authorized connection that enforces read-only transactions. Inspect `pg_catalog` or `information_schema` with SELECT queries; include table/view names, columns, and declared foreign keys. Do not run DDL, migrations, data changes, or arbitrary database functions. Inspect at most five sample rows per table when their meaning is otherwise unclear.

The app loads local metadata when the document opens. **Relayout** reloads notes and groups and rebuilds graph positions; **Features -> Stories** reloads the story list. Cluster colours are used for graph groups, table borders, and the table picker. Local sidecar and skill edits do not enable database writes.

## Inputs you need

Before writing the file, gather:

1. **The opened database file or PostgreSQL document path.** Ask the user if not obvious. The sidecar lives next to it (for example, `app.sqlite` -> `app.sqlite.studio.json`).
2. **The schema.** Use the read-only discovery workflow above. You need exact table and column names.
3. **Small samples only when useful.** Pull up to 5 rows for unclear tables or columns. Do not inspect more data than needed for documentation.

## Output format

Preserve any existing `clusters` block. Add or replace only the `tables` entries you are documenting.

```json
{
  "version": 1,
  "tables": {
    "users": {
      "description": "auth.users -- App account roster, one row per signed-up user.",
      "columns": {
        "email": "Lowercased login email.",
        "status": "active | suspended | pending"
      }
    },
    "orders": {
      "description": "billing.orders -- Customer purchase record, one row per checkout.",
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

- `tables` - object keyed by exact case-sensitive table or view ID; use schema-qualified PostgreSQL IDs such as `public.orders`.
- `description` - optional table-level description shown verbatim when hovering the table name.
- `columns` - optional object keyed by exact case-sensitive column name.
- Unknown table or column names are ignored by the app, so verify spelling before writing.

## Workflow

1. Read `<document>.studio.json` if it already exists.
2. List the schema using read-only schema discovery or existing schema docs.
3. Draft concise table and column descriptions.
4. Write the sidecar JSON, preserving unrelated fields such as `clusters`.
5. Tell the user to click **Relayout** in the running app to reload the sidecar and rebuild the layout. Query headers match full table IDs such as `public.orders.total`; unqualified column notes appear only when the column can be resolved unambiguously.

## Writing good descriptions

Tooltip space is small. Aim for:

- **Tables**: `cluster_name.table_id -- short description`, preserving the full table ID (for example `commerce.public.orders -- One row per checkout.`). State the table grain: what one row represents. Use an existing cluster id when present; use `unclustered` only when the table is not in any cluster.
  - Good: `authoring.comments -- Reader comments, with replies linked to parent comments.`
  - Bad: `This table contains users.`
- **Columns**: 3-10 words. Include format, unit, source of truth, or a quirk.
  - Good: `Cents, never null`, `FK -> tenants.id, NULL for staff`, `active | suspended | pending`
  - Bad: `The user's email address.`

Skip obvious columns like `id`, `created_at`, and `updated_at` unless they have a real quirk. Do not speculate. If you would be guessing, leave the field out.

## What not to do

- Don't modify database DDL or add SQL comments. Descriptions belong in the sidecar.
- Don't overwrite existing `clusters`.
- Don't invent table or column names.
- Don't read more than 5 sample rows per table.
- Don't commit the sidecar without asking. Some users want it gitignored.
