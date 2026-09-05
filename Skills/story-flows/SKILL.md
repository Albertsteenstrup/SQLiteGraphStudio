---
name: story-flows
description: Write user-story-inspired flow stories with acceptance notes and narrated schema playback to a SQLite Graph Studio sidecar file. Use when the user asks what happens during an application flow, lifecycle, workflow, signup, checkout, import, sync, deletion, permission change, or other behavior that should be captured as a user-centered story and shown as table graph playback.
---

# story-flows

You write user-story-inspired flow stories to `<document>.studio.json`, beside the opened database file or PostgreSQL connection document. SQLite Graph Studio reads the `stories` array when the document opens and when the user opens **Features -> Stories**.

Use the user story pattern as inspiration: capture who benefits (`actor`), what they need (`goal`), and why it matters (`benefit`). Keep it lighter than a Jira ticket when that fits the question: short title and value statement, useful conversation notes, acceptance criteria that confirm the flow, and graph playback beats that explain how the data moves through the schema.

The app plays each playback beat by moving the graph viewport, expanding the focused table, spotlighting the tables in the beat with a warm animated fill, highlighting relation edges for a referenced column, and typing the beat text on screen. Users can also enable read-aloud playback; when they do, the app reads the beat's hidden `spoken_text` with Kokoro-82M's Bella voice (`af_bella`). The app does not show `spoken_text`; if it is missing, the app reads `text`.

## Database documents and read-only discovery

Append `.studio.json` to the complete opened filename. A SQLite file uses `app.sqlite.studio.json`; a PostgreSQL connection document uses `catalog.postgres.studio.json` or `catalog.pgstudio.studio.json`. Keep the sidecar beside that document, even when another document connects to the same database. Never put credentials in the sidecar or modify the connection document.

For PostgreSQL, use the app's exact schema-qualified table IDs, such as `public.orders`, everywhere a table is referenced. This includes `tables` keys, cluster membership, and story playback `tables`, `focus`, `expand`, and `relation.table`. Keep column names exact and unqualified. Do not remove the schema or split IDs on dots: schema, table, and column names can themselves contain dots. When writing discovery SQL, quote the schema and object separately, for example `"public"."orders"`.

For SQLite, inspect schema with `sqlite3 -readonly <db> ".tables"` and `sqlite3 -readonly <db> ".schema"`, or use existing schema documentation. For PostgreSQL, use a schema export or an already authorized connection that enforces read-only transactions. Inspect `pg_catalog` or `information_schema` with SELECT queries; include table/view names, columns, and declared foreign keys. Do not run DDL, migrations, data changes, or arbitrary database functions. Inspect at most five sample rows per table when their meaning is otherwise unclear.

The app loads local metadata when the document opens. **Relayout** reloads notes and groups and rebuilds graph positions; **Features -> Stories** reloads the story list. Cluster colours are used for graph groups, table borders, and the table picker. Local sidecar and skill edits do not enable database writes.

## Inputs you need

Before writing the file, gather:

1. **The opened database file or PostgreSQL document path.** Ask if it is not obvious. The sidecar lives next to it, for example `app.sqlite` -> `app.sqlite.studio.json`.
2. **The user flow and persona.** Capture the exact flow question and who benefits, such as "what happens when a user signs up?"
3. **The schema.** Use the read-only discovery workflow above. You need exact table and column names.
4. **Tiny samples only if necessary.** Use `LIMIT 5` only when a table's role is unclear. Do not inspect more data than needed.

## Output format

Preserve existing `tables` and `clusters`. Append one new object to `stories`; do not replace older stories unless the user asks.

```json
{
  "version": 1,
  "tables": {},
  "clusters": [],
  "stories": [
    {
      "id": "user-signup-2026-05-18T14-30-00Z",
      "title": "User Signup",
      "created_at": "2026-05-18T14:30:00Z",
      "prompt": "What happens when a user signs up?",
      "actor": "a new user",
      "goal": "to create an account",
      "benefit": "I can start using a personal workspace",
      "clusters": ["auth", "workspace"],
      "related_stories": [
        { "story_id": "user-signs-in-2026-05-18T14-10-00Z", "kind": "precedes" }
      ],
      "conversation": [
        "Signup creates both identity and the first usable workspace.",
        "Email verification is outside this story unless the schema shows verification tables."
      ],
      "acceptance_criteria": [
        {
          "id": "AC1",
          "given": "a valid signup request",
          "when": "the signup completes",
          "then": "a users row exists for the new account"
        },
        {
          "id": "AC2",
          "given": "the users row exists",
          "when": "workspace provisioning runs",
          "then": "a workspace and membership are linked to that user"
        }
      ],
      "playback": [
        {
          "text": "A new user row is inserted first. This row becomes the identity anchor for the rest of the signup flow.",
          "spoken_text": "First, the app creates the user's account record. Everything else in signup will attach back to that identity.",
          "tables": ["users"],
          "focus": "users",
          "expand": "users"
        },
        {
          "text": "The users.id key is then reused by dependent records, so the graph highlights every table attached to that account identity.",
          "spoken_text": "Next, the new user's identifier is reused by nearby records, so the account can be connected to sessions and membership details.",
          "tables": ["users", "sessions", "memberships"],
          "focus": "users",
          "expand": "users",
          "relation": { "table": "users", "column": "id" }
        },
        {
          "text": "A default workspace is created and linked back through membership, giving the new user a place to start.",
          "spoken_text": "Finally, the app creates a starter workspace and links the user into it, so there is a usable place to land after signup.",
          "tables": ["workspaces", "memberships", "users"],
          "focus": "workspaces",
          "expand": "workspaces"
        }
      ]
    }
  ]
}
```

Field rules:

- `id` - unique, stable, lowercase slug. Include a timestamp suffix if needed.
- `title` - short human label shown in the app's Stories list.
- `created_at` - ISO-8601 UTC timestamp for when you append the story.
- `prompt` - optional copy of the user's question.
- `actor` - user or stakeholder role. Include the article if natural, e.g. `a new user`.
- `goal` - user-visible goal, not implementation.
- `benefit` - user or business value.
- `clusters` - optional existing top-level cluster IDs whose tables are central to the story. Use the same cluster IDs already present in the sidecar; do not invent new story-only cluster names. Omit this when the sidecar has no relevant clusters.
- `related_stories` - optional lightweight links to existing stories. Each link is `{ "story_id": "...", "kind": "..." }`; use only intentional relations such as `precedes`, `follows`, `depends_on`, `extends`, `alternative`, or `related`.
- `conversation` - optional short notes, assumptions, exclusions, or open questions discovered while inspecting the schema.
- `acceptance_criteria` - confirmation of done. Prefer Given/When/Then objects with stable IDs (`AC1`, `AC2`). Plain strings are supported but less precise.
- `playback` - ordered graph playback beats. Aim for 3-7 beats. The app ignores the old `steps` key.
- `text` - narration typed during the beat. Keep it concise and specific.
- `spoken_text` - optional hidden human-language version read aloud with Kokoro-82M Bella. Write this for every beat when the story should sound natural over audio. Avoid raw table syntax unless it helps the listener; never put anything here that should be visibly shown.
- `tables` - exact case-sensitive table IDs spotlighted during playback; PostgreSQL requires schema-qualified IDs such as `public.orders`.
- `focus` - optional exact table ID the viewport should move toward.
- `expand` - optional exact table ID whose columns should be opened.
- `relation` - optional `{ "table": "...", "column": "..." }` for a real PK/FK/REF column; the app highlights connected edges and pulls related tables into view.
- `duration_ms` - optional step duration. Use only when a step needs unusual timing.

## Workflow

1. Read `<document>.studio.json` if it exists.
2. List the schema and identify the tables and foreign-key columns used by the requested flow.
3. Draft the story card: `actor`, `goal`, and `benefit`. Keep it value-oriented, but do not force awkward wording.
4. Assign `clusters` by matching the story's playback tables to existing top-level `clusters[].tables`. Prefer the smallest useful set of cluster IDs; leave it empty if the flow crosses the whole schema or no cluster exists.
5. Add `related_stories` only when the sidecar already has a clearly connected story. Keep links sparse and obvious; do not create a complete graph.
6. Add conversation notes only for useful assumptions, exclusions, or questions.
7. Add acceptance criteria that are observable and testable.
8. Draft the graph playback beats in causal order: record created, identity/relation fan-out, downstream records, final state. For each beat, write visible `text` for the graph card and hidden `spoken_text` for read-aloud playback.
9. Verify every table and relation column exists exactly as written.
10. Append the story to `stories`, preserving existing `tables`, `clusters`, and earlier `stories`.
11. Tell the user to open **Features -> Stories** and activate the new story.

## What not to do

- Don't modify database DDL or create tables in the database. Stories belong in the sidecar. Narrate application writes without executing them.
- Don't invent table or column names.
- Don't invent cluster IDs; story clusters must reuse existing top-level sidecar cluster IDs.
- Don't over-link stories. Prefer no `related_stories` over speculative links.
- Don't make `actor`, `goal`, or `benefit` only about tables or UI mechanics; the story should keep a user or stakeholder value thread.
- Don't write the old `steps` key. Playback belongs in `playback`.
- Don't show or mention `spoken_text` in visible story copy; it is for hidden voiceover only.
- Don't use `relation` for a column unless it participates in a declared foreign-key relationship.
- Don't overwrite existing stories unless the user explicitly asks.
- Don't read more than 5 sample rows per table.
