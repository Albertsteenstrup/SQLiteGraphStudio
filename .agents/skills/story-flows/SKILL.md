---
name: story-flows
description: Write user-story-inspired flow stories with acceptance notes and narrated schema playback to a SQLite Graph Studio sidecar file. Use when the user asks what happens during an application flow, lifecycle, workflow, signup, checkout, import, sync, deletion, permission change, or other behavior that should be captured as a user-centered story and shown as table graph playback.
---

# story-flows

You write user-story-inspired flow stories to `<db>.sqlite.studio.json`, next to the database file. SQLite Graph Studio reads the `stories` array when the database opens and when the user opens **Features -> Stories**.

Use the user story pattern as inspiration: capture who benefits (`actor`), what they need (`goal`), and why it matters (`benefit`). Keep it lighter than a Jira ticket when that fits the question: short title and value statement, useful conversation notes, acceptance criteria that confirm the flow, and graph playback beats that explain how the data moves through the schema.

The app plays each playback beat by moving the graph viewport, expanding the focused table, spotlighting the tables in the beat with a warm animated fill, highlighting relation edges for a referenced column, and typing the beat text on screen. Users can also enable read-aloud playback; when they do, the app reads the beat's hidden `spoken_text` with Kokoro-82M's Bella voice (`af_bella`). The app does not show `spoken_text`; if it is missing, the app reads `text`.

## Inputs you need

Before writing the file, gather:

1. **The database path.** Ask if it is not obvious. The sidecar lives next to it, for example `app.sqlite` -> `app.sqlite.studio.json`.
2. **The user flow and persona.** Capture the exact flow question and who benefits, such as "what happens when a user signs up?"
3. **The schema.** Run `sqlite3 <db> ".tables"` and `sqlite3 <db> ".schema"` or inspect existing schema docs. You need exact table and column names.
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
- `conversation` - optional short notes, assumptions, exclusions, or open questions discovered while inspecting the schema.
- `acceptance_criteria` - confirmation of done. Prefer Given/When/Then objects with stable IDs (`AC1`, `AC2`). Plain strings are supported but less precise.
- `playback` - ordered graph playback beats. Aim for 3-7 beats. The app ignores the old `steps` key.
- `text` - narration typed during the beat. Keep it concise and specific.
- `spoken_text` - optional hidden human-language version read aloud with Kokoro-82M Bella. Write this for every beat when the story should sound natural over audio. Avoid raw table syntax unless it helps the listener; never put anything here that should be visibly shown.
- `tables` - exact case-sensitive table names spotlighted during playback.
- `focus` - optional exact table name the viewport should move toward.
- `expand` - optional exact table name whose columns should be opened.
- `relation` - optional `{ "table": "...", "column": "..." }` for a real PK/FK/REF column; the app highlights connected edges and pulls related tables into view.
- `duration_ms` - optional step duration. Use only when a step needs unusual timing.

## Workflow

1. Read `<db>.sqlite.studio.json` if it exists.
2. List the schema and identify the tables and foreign-key columns used by the requested flow.
3. Draft the story card: `actor`, `goal`, and `benefit`. Keep it value-oriented, but do not force awkward wording.
4. Add conversation notes only for useful assumptions, exclusions, or questions.
5. Add acceptance criteria that are observable and testable.
6. Draft the graph playback beats in causal order: record created, identity/relation fan-out, downstream records, final state. For each beat, write visible `text` for the graph card and hidden `spoken_text` for read-aloud playback.
7. Verify every table and relation column exists exactly as written.
8. Append the story to `stories`, preserving existing `tables`, `clusters`, and earlier `stories`.
9. Tell the user to open **Features -> Stories** and activate the new story.

## What not to do

- Don't modify SQLite DDL or create tables in the database. Stories belong in the sidecar.
- Don't invent table or column names.
- Don't make `actor`, `goal`, or `benefit` only about tables or UI mechanics; the story should keep a user or stakeholder value thread.
- Don't write the old `steps` key. Playback belongs in `playback`.
- Don't show or mention `spoken_text` in visible story copy; it is for hidden voiceover only.
- Don't use `relation` for a column unless it participates in a declared foreign-key relationship.
- Don't overwrite existing stories unless the user explicitly asks.
- Don't read more than 5 sample rows per table.
