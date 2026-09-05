---
name: graph-clusters
description: Generate cluster hints for the SQLite Graph Studio physics engine so related tables group together by a chosen lens. Default to domain areas (auth, billing, content, etc.) unless the user asks to cluster around another concept such as people, artifacts, departments, workflows, or ownership.
---

# graph-clusters

You write a JSON sidecar (`<document>.studio.json`) that tells SQLite Graph Studio's force-directed layout which tables belong together. The physics engine already attracts tables in the same cluster to each other — your job is to decide what the clusters should be, using the database schema and whatever task context the user has shared.

The sidecar is loaded when a document opens and re-read when the user clicks **Relayout** in the graph view. The user can edit your output by hand at any time.

## Database documents and read-only discovery

Append `.studio.json` to the complete opened filename. A SQLite file uses `app.sqlite.studio.json`; a PostgreSQL connection document uses `catalog.postgres.studio.json` or `catalog.pgstudio.studio.json`. Keep the sidecar beside that document, even when another document connects to the same database. Never put credentials in the sidecar or modify the connection document.

For PostgreSQL, use the app's exact schema-qualified table IDs, such as `public.orders`, everywhere a table is referenced. This includes `tables` keys, cluster membership, and story playback `tables`, `focus`, `expand`, and `relation.table`. Keep column names exact and unqualified. Do not remove the schema or split IDs on dots: schema, table, and column names can themselves contain dots. When writing discovery SQL, quote the schema and object separately, for example `"public"."orders"`.

For SQLite, inspect schema with `sqlite3 -readonly <db> ".tables"` and `sqlite3 -readonly <db> ".schema"`, or use existing schema documentation. For PostgreSQL, use a schema export or an already authorized connection that enforces read-only transactions. Inspect `pg_catalog` or `information_schema` with SELECT queries; include table/view names, columns, and declared foreign keys. Do not run DDL, migrations, data changes, or arbitrary database functions. Inspect at most five sample rows per table when their meaning is otherwise unclear.

The app loads local metadata when the document opens. **Relayout** reloads notes and groups and rebuilds graph positions; **Features -> Stories** reloads the story list. Cluster colours are used for graph groups, table borders, and the table picker. Local sidecar and skill edits do not enable database writes.

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

## Output format

Write to `<document>.studio.json` beside the opened database file or PostgreSQL connection document. Preserve existing `tables` and `stories` blocks — the other skills write to the same file.

```json
{
  "version": 1,
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

## Workflow

1. Read `<document>.studio.json` if it already exists — preserve `tables`, `stories`, and other unrelated fields; update only `clusters`.
2. List the tables using read-only schema discovery or existing schema docs.
3. Choose meaningful clusters for the requested lens and briefly explain them. When the user has requested this change, write the sidecar using that scope.
4. Write the file with `Write`.
5. Tell the user to click **Relayout** in the running app to reload the sidecar and rebuild the layout with the new groups and colours.

## What not to do

- Don't create a cluster per table — the physics engine already handles single nodes.
- Don't put every table in a cluster — leaving some uncluttered lets the FK-based fallback handle them.
- Don't write `strength`, `weight`, or other fields not in the format above — they're ignored and signal you're guessing.
- Don't run SQL beyond read-only schema discovery or a `LIMIT 5` sample — the user's data isn't the clustering input.
- Don't commit the sidecar without asking. Some users want it gitignored.
