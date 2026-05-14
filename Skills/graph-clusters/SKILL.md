---
name: graph-clusters
description: Generate cluster hints for the SQLite Graph Studio physics engine so related tables group together by a chosen lens. Default to domain areas (auth, billing, content, etc.) unless the user asks to cluster around another concept such as people, artifacts, departments, workflows, or ownership.
---

# graph-clusters

You write a JSON sidecar (`<db>.sqlite.studio.json`) that tells SQLite Graph Studio's force-directed layout which tables belong together. The physics engine already attracts tables in the same cluster to each other — your job is to decide what the clusters should be, using the database schema and whatever task context the user has shared.

The sidecar is read once when a database opens and re-read when the user clicks **Features → Schema Notes** in the graph view. The user can edit your output by hand at any time.

## Inputs you need

Before writing the file, gather:

1. **The database path.** Ask the user if not obvious — the sidecar lives next to it (e.g. `app.sqlite` → `app.sqlite.studio.json`).
2. **The schema.** Run `sqlite3 <db> ".tables"` and `sqlite3 <db> ".schema"` (or `.schema <table>` per table). You need table names and foreign-key columns.
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
- 30+: 5–9 clusters, but don't over-fragment — clusters of 1–2 tables waste a hint

Tables that don't fit anywhere are fine to leave out of all clusters. The app falls back to connected-components for unhinted tables.

## Output format

Write to `<db-name>.sqlite.studio.json` next to the database file. Preserve any existing `tables: {...}` block — the schema-descriptions skill writes to the same file.

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
- `label` — human-readable name shown in the table tooltip (e.g. "Authentication & Users").
- `tables` — exact case-sensitive table names. Names not in the schema are silently skipped.
- `color` — optional hex string, reserved for future visual cluster tinting.

## Workflow

1. Read `<db>.sqlite.studio.json` if it already exists — preserve `tables`, replace `clusters`.
2. List the tables with `sqlite3` or by reading existing schema docs.
3. Propose 2–9 clusters in chat, briefly justifying each, and ask the user if any feel wrong before writing the file.
4. Write the file with `Write`.
5. Tell the user to click **Features → Schema Notes** in the running app (the icon turns blue when the sidecar is loaded).

## What not to do

- Don't create a cluster per table — the physics engine already handles single nodes.
- Don't put every table in a cluster — leaving some uncluttered lets the FK-based fallback handle them.
- Don't write `strength`, `weight`, or other fields not in the format above — they're ignored and signal you're guessing.
- Don't run any SQL beyond `.tables` / `.schema` / a `LIMIT 5` peek — the user's data isn't your input.
- Don't commit the sidecar without asking. Some users want it gitignored.
