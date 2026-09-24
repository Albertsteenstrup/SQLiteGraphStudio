---
name: graph-clusters
description: Generate cluster hints for the SQLite Graph Studio physics engine so related tables group together by a chosen lens. Default to domain areas (auth, billing, content, etc.) unless the user asks to cluster around another concept such as people, artifacts, departments, workflows, or ownership.
---

# graph-clusters

You write a JSON sidecar (`<document>.studio.json`) that tells SQLite Graph Studio's force-directed layout which tables belong together. The physics engine already attracts tables in the same cluster to each other — your job is to decide what the clusters should be, using the database schema and whatever task context the user has shared. For a broad model overview, you may also choose a few `overviewTables` to name on the full-catalog map.

When Graph Studio MCP is available, show temporary groups immediately with `studio_set_groups`. To save a requested durable grouping, read `studio_get_annotations` first and pass its `metadata_revision` as `expected_metadata_revision` to `studio_update_annotations`; the app refreshes it. If the save returns `METADATA_CONFLICT`, read again, merge the intended grouping with the current metadata, and retry with a new `request_id`. The sidecar file remains available for offline work, and the user can edit it by hand.

## Database documents and read-only discovery

Append `.studio.json` to the complete opened filename. A SQLite file uses `app.sqlite.studio.json`; a PostgreSQL connection document uses `catalog.postgres.studio.json` or `catalog.pgstudio.studio.json`. Keep the sidecar beside that document, even when another document connects to the same database. Never put credentials in the sidecar or modify the connection document.

For PostgreSQL, use the app's exact schema-qualified table IDs, such as `public.orders`, everywhere a table is referenced. Keep column names exact and unqualified. Do not remove the schema or split IDs on dots: schema, table, and column names can themselves contain dots. When writing discovery SQL, quote the schema and object separately, for example `"public"."orders"`.

For SQLite, inspect schema with `sqlite3 -readonly <db> ".tables"` and `sqlite3 -readonly <db> ".schema"`, or use existing schema documentation. For PostgreSQL, use a schema export or an already authorized connection that enforces read-only transactions. Inspect `pg_catalog` or `information_schema` with SELECT queries; include table/view names, columns, and declared foreign keys. Do not run DDL, migrations, data changes, or arbitrary database functions. Read a small bounded sample only when table meaning is unclear; fetch more if the question requires it.

The app loads local metadata when the document opens. **Relayout** reloads notes and groups and rebuilds graph positions. Cluster colours are used for graph groups, table borders, and the table picker. Local sidecar and skill edits do not enable database writes.

## Inputs you need

Before writing the file, gather:

1. **The opened database file or PostgreSQL document path.** Ask the user if not obvious — the sidecar lives next to it (e.g. `app.sqlite` → `app.sqlite.studio.json`).
2. **The schema.** Use the read-only discovery workflow above. You need table names and foreign-key columns.
3. **Task context and clustering lens.** What is the user *working on*, and what do they want the graph organized around? Default to domain areas if they do not say. A clustering tuned to "show me the tables around each department" looks different from "I'm refactoring the billing flow."

If the database has fewer than ~6 tables, clustering rarely helps — recommend skipping the skill and just letting the FK-based default lay out.

## How to choose clusters

Group tables by the user's requested **clustering lens**, not by FK chains. Foreign keys already create attraction; clusters should add a *second* signal on top, capturing semantic groupings the schema doesn't express.

Use **domain area** as the default lens when the user does not specify one. If they do specify a lens, follow it. Valid lenses can be anything that makes the schema easier to reason about: persons, artifacts, departments, workflows, bounded contexts, ownership teams, lifecycle stages, or another concept from the user's task.

Good signals:
- **Naming prefixes** (`auth_*`, `billing_*`, `event_*`) — strong, usually correct.
- **Shared subject matter** even without prefixes — `users`, `sessions`, `password_resets` all belong to auth.
- **Requested lens terms** — if the user asks for departments, cluster around department ownership; if they ask for artifacts, cluster tables by the objects those artifacts represent.
- **What references what** — a hub table that 8 others reference is the center of its cluster.
- **The user's task** — if they said "I'm working on the order pipeline", that's a cluster, even if the tables span multiple prefixes.

Cluster count guidance:
- 6–12 tables: 2–3 clusters
- 13–30 tables: 3–6 clusters
- 30–150 tables: 5–9 clusters; larger catalogs can use more meaningful groups. Keep authored domain groups intact; the app handles their layout internally.

Tables that don't fit anywhere are fine to leave out of all clusters. The app computes deterministic groups for unassigned tables from schema, names, and relationships. These inferred groups are not written into the sidecar.

For an overview, choose 4–16 exact table IDs across the main domains as `overviewTables`. Favor canonical records and the few tables that explain how sources, evidence, decisions, and outputs connect. Verify their roles from schema or code; raw foreign-key degree alone is a poor guide because account and audit tables often have many incidental references. The list is ordered by explanatory priority. It enlarges those existing nodes enough to show their names on the full map; it does not add floating labels, pin tables, create relations, or restrict what an agent can focus on. A narrow task does not need this hint.

## Output format

Write to `<document>.studio.json` beside the opened database file or PostgreSQL connection document. Preserve existing `tables` and all other unrelated metadata. Update `clusters`; update `overviewTables` only when the user wants a broad model map or different anchors.

```json
{
  "version": 1,
  "overviewTables": ["users", "orders", "payments"],
  "clusters": [
    {
      "id": "auth",
      "label": "Authentication & Users",
      "tables": ["users", "sessions", "password_resets", "auth_tokens"],
      "color": "#7CC3FF"
    },
    {
      "id": "billing",
      "label": "Billing",
      "tables": ["customers", "subscriptions", "invoices", "payments", "refunds"],
      "color": "#F8B26A"
    },
    {
      "id": "content",
      "label": "Content",
      "tables": ["posts", "comments", "tags", "post_tags"]
    }
  ]
}
```

Field rules:
- `id` — short, lowercase, no spaces. Used internally and in error messages.
- `label` — human-readable name shown on graph groups, in the table picker, and in table tooltips (e.g. "Authentication & Users").
- `tables` — exact case-sensitive table IDs; PostgreSQL uses schema-qualified IDs such as `public.orders`. Names not in the schema are skipped.
- `color` — optional six-digit `#RRGGBB` hex colour used for group labels, halos, table borders, and picker markers. The app provides a stable colour when omitted.
- `overviewTables` — optional ordered list of at most 16 distinct, exact table IDs. PostgreSQL uses schema-qualified IDs. Unknown IDs are ignored when drawing so the sidecar can survive schema changes; check against the current catalog before saving.

## Workflow

1. Read `<document>.studio.json` if it already exists — preserve `tables` and all other unrelated fields; update only `clusters`.
2. List the tables using read-only schema discovery or existing schema docs.
3. Choose meaningful clusters for the requested lens and, for a requested broad overview, a short set of model anchors. Briefly explain what makes each group and anchor relevant. When the user has requested this change, write the sidecar using that scope.
4. Write the file with `Write`.
5. If MCP is connected, call `studio_get_annotations`, then `studio_update_annotations` for requested persistent groups and `overview_table_ids` using the returned revision, and confirm the refreshed view. For offline sidecar edits, tell the user to click **Relayout** in the running app.

## What not to do

- Don't create a cluster per table — the physics engine already handles single nodes.
- Don't force an ambiguous table into a cluster. For a catalog-wide overview, assigning every object is useful when each placement has a defensible domain; otherwise let the FK-based fallback handle the remainder.
- Don't write `strength`, `weight`, or other fields not in the format above — they're ignored and signal you're guessing.
- Don't add an overview anchor solely because it has many foreign keys or imply that the labels describe every important table.
- Don't run SQL beyond read-only schema discovery or a `LIMIT 5` sample — the user's data isn't the clustering input.
- Don't commit the sidecar without asking. Some users want it gitignored.
