---
name: database-preview
description: Show proposed SQLite or PostgreSQL table, field and relation changes in SQLite Graph Studio before implementing them. Use only when the user explicitly asks to preview schema changes visually; uses a compact change plan and cached schema metadata without executing migrations.
---

# Database preview

Show intended schema changes before writing migrations or changing a database.
Create a `.sgpreview` from one captured baseline and a small JSON plan. The app
uses the same blue/red borders, field counts, New/Removed badges and relation
diffs as schema review, with a persistent **Proposed · not applied** label.

Run this only when the user asks for a visual preview; it opens Graph Studio, and
many coding sessions on one machine may be working at once. Graph Studio replaces
the tab of an earlier preview from the same tool and `--session`, so iterating on a
plan updates one tab instead of opening another.

## Keep iterations cheap

Find the executable inside a built `SQLiteGraphStudio.app`, normally
`/Applications/SQLiteGraphStudio.app/Contents/MacOS/SQLiteGraphStudio` or the
SQLiteGraphStudio project's `dist/SQLiteGraphStudio.app/Contents/MacOS/SQLiteGraphStudio`.
Set `studio` to that executable and `bundle` to its containing `.app`.

Reuse a captured snapshot JSON or an actual `.sgreview` file. With `.sgreview`,
choose `--side after` for its resulting schema or `--side before` for its original
schema. Check the reported `baseRef` against the intended starting point. A
proposal cannot itself become a captured baseline.

If no suitable capture exists, run `--schema-review snapshot DATABASE BASE.json`
once against the chosen SQLite file, PostgreSQL connection document, or backup.
Store the baseline and plan in a temporary or Git-local directory, for example
the path returned by `git rev-parse --git-path schema-preview`. Associate a cache
with the exact source revision or database snapshot; refresh it when that source
changes. A preview does not check whether a live database has changed since capture.

```bash
# Cheap index: don't load the entire snapshot into the agent's context.
"$studio" --schema-review inspect "$baseline" --find order
# Read only the fields and incident relations needed for the design.
"$studio" --schema-review inspect "$baseline" --table public.orders --column status
# Write plan.json, then project it without SQL, a server, or migration replay.
"$studio" --schema-review preview "$baseline" plan.json changes.sgpreview \
  --agent claude --session "$session_name"
open -a "$bundle" changes.sgpreview
```

When your instructions allow you to name yourself, pass `--agent` (`claude`,
`codex`, `opencode`, `copilot`, or another tool's own name) and `--session` (the
current chat or session's human-readable name) so the preview header shows where
it came from. Never invent either, and leave the session out when its name should
not travel with the file. They sit outside the plan, so they never change its
fingerprint.

`inspect` returns `baseFingerprint`; copy it into the plan. The index is bounded
to 100 tables (`--limit 1..500`, `--find TEXT`). Repeat `--table ID` for more than
one detailed table. Optional `--column NAME` narrows fields and relations to
that field; repeat it for multiple fields. Omit it when full table context is
needed. Raw snapshot metadata need not pass through the agent.

For each iteration, edit the small plan and rerun only `preview` to the **same
output file**. The open preview reloads automatically, keeping selection and
the overview camera. Don't reopen windows, recapture, restore backups, replay
migrations, or rewrite complete before/after schemas on each iteration. The CLI
prints a short summary; inspect the visual result when a change affects the design.

## Plan format

```json
{
  "baseFingerprint": "COPY_FROM_INSPECT",
  "title": "Proposed order approval",
  "changes": [
    {"op":"addColumn","table":"public.orders","column":{"name":"approved_at","type":"timestamp with time zone"}},
    {"op":"alterColumn","table":"public.orders","column":"status","set":{"notNull":true,"defaultSQL":"'pending'"}},
    {"op":"addTable","table":"public.order_approval","columns":[
      {"name":"id","type":"bigint","primaryKeyOrdinal":1,"notNull":true},
      {"name":"order_id","type":"bigint","notNull":true}
    ]},
    {"op":"addRelation","id":"approval_order","source":"public.order_approval","target":"public.orders","sourceColumns":["order_id"],"targetColumns":["id"]}
  ]
}
```

Use actual table/field IDs from `inspect`, adapting the example to the engine.
SQLite IDs are unqualified; PostgreSQL IDs include the schema. Table names with
dots can supply explicit `schema` and `name` whose concatenation equals the ID.

Supported operations, processed in order:

| `op` | Required properties | Optional properties |
| --- | --- | --- |
| `addTable` | `table`, `columns` | `schema`, `name`, `kind` (table/view/materializedView) |
| `removeTable` | `table` | `cascade` |
| `renameTable` | `table`, `to` | `schema`, `name` |
| `addColumn` | `table`, `column` object | — |
| `alterColumn` | `table`, `column` name, `set` object | — |
| `removeColumn` | `table`, `column` name | `cascade` |
| `renameColumn` | `table`, `column` name, `to` | — |
| `addRelation` | `id`, `source`, `target`, `sourceColumns`, `targetColumns` | `definition` |
| `alterRelation` | `id`, `set` object | — |
| `removeRelation` | `id` | — |

New fields require `name` and `type`. Optional field properties: `notNull`
(default false), `defaultSQL` (default null), `primaryKeyOrdinal` (default 0),
`generated` (default 0), `identity` (default empty string). `alterColumn.set`
accepts these properties except `name`; omitted properties are preserved.
Set `defaultSQL:null` to remove a default. Type/default text is displayed, never
executed or validated as SQL. Describe unstated design assumptions in `notes`.

`alterRelation.set` accepts `source`, `target`, `sourceColumns`, `targetColumns`,
and `definition`. Use the ID returned by `inspect` for an existing relation;
assign a readable unique ID to a new one. An omitted relation definition shows
that actions are unspecified. Include the intended definition to preview action
changes such as ON DELETE CASCADE. Renaming a table/field updates its relation
endpoints; a rename appears visually as removal plus addition.

Removing an object with relations requires removing those relations first or
explicit `cascade:true`; cascaded removals are shown. Unknown IDs/properties,
duplicate objects, broken relations and mismatched fingerprints fail without
replacing the last valid preview. Fix the plan instead of silently skipping errors.

## Meaning of the result

This is a design projection of tables, fields and declared relations. It does
not project or validate indexes, triggers, other constraints, data changes,
permissions, routines, extension behavior or whether a migration will succeed.
Captured definition metadata is not presented as newly generated DDL.

No code-review marker or hook receipt is written. Creating a preview does not
apply or approve the proposed changes. After implementation, use the sibling
`database-diff` workflow to compare real schemas through the existing review gate.
Report the proposed outcome and baseline, and link the preview file. Keep the
baseline stable while exploring alternatives; revise it explicitly if the
underlying schema changes.
