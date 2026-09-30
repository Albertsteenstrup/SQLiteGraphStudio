---
name: database-diff
description: Capture and visually compare SQLite or PostgreSQL schemas in SQLite Graph Studio for a PR, a local integration, or two database versions. Use only when the user explicitly asks for a visual schema diff; never start it automatically after a code review, push, fetch, or merge.
---

# Database diff

Create a `.sgreview` file containing before/after schema snapshots and show it
inline with SQLite Graph Studio's review view. It shows added/removed tables,
field changes, and foreign-key changes in a graph and table details. This is schema
evidence, not proof that data migrations or deployment are safe.

Run this only when the user asks for it. Each run can create disposable databases,
and many coding sessions on one machine may be reviewing at
once, so never trigger it on your own after a review, push, fetch, or merge.

## Choose the comparison

Keep exact immutable before/after revisions and explain their meaning:

- PR: merge-base to the exact PR head for branch changes; use target-to-merged-tree
  when reviewing the resulting integration instead.
- Push: actual remote main SHA to the exact outgoing SHA.
- Local fetch/integrate: current local SHA to the fetched incoming SHA before a
  fast-forward, or the final resolved tree for a merge.
- Two files: label the selected before and after versions by filename.

When the user has asked for a diff, run the repository's existing code-review
rounds first. Do not emit a schema review pass or launch the visual follow-up until
the first review has completed.
Use the repository's database-review hook/adapter when installed; preserve its
exact-tree receipt and artifact hash checks. A new head, base, merge resolution,
or artifact invalidates that receipt. Never mark an unseen artifact as presented.

## Capture real schemas

Find the built app executable at
`/Applications/SQLiteGraphStudio.app/Contents/MacOS/SQLiteGraphStudio`, or the
project's `dist/SQLiteGraphStudio.app/Contents/MacOS/SQLiteGraphStudio`.
Use the same executable for capture, comparison, and display.

```bash
"$studio" --schema-review snapshot before.sqlite before.json
"$studio" --schema-review snapshot after.sqlite after.json
"$studio" --schema-review compare before.json after.json change.sgreview \
  --base-ref "$base_sha" --head-ref "$head_sha" --title "Database changes" \
  --note "Exact source revisions; schema only, no row data." \
  --agent claude --session "$session_name"
```

Show the result in the conversation with the Graph Studio MCP tool
`studio_show_review_inline`, passing the `.sgreview` path. Hosts that render MCP
Apps show Graph Studio's own graph, drawn by a hidden renderer, so no app window,
database, or tab opens; other hosts get a text summary instead. The reader can open
the review in the app from that view. Open the app yourself only when the user asks
for it or the tool is unavailable: `open -a /path/to/SQLiteGraphStudio.app change.sgreview`.

The calling assistant writes the explanation in the embedded view. First call
`studio_review_explanation_context` with the file path to get its `revision` and
bounded schema facts. Use those facts to write 1–3 short natural-language
paragraphs for each connected change set. Then call `studio_show_review_inline`
once with `path`, `revision`, and `explanations`. Each explanation has a zero-based `set` and
`paragraphs`, where each paragraph is an ordered array of `{ "text": "..." }`
parts. Add `table` to a part to make a table name clickable, `table` plus `field`
for a field, or `relation` for a relation. Use exact IDs from the context; the
helper rejects links that are absent from the review. Explain behavior and the
meaning of changed constraints or relations where the schema supports it; avoid
claiming data was migrated or that the change is safe. For very large reviews,
inspect the remaining sets selectively and let the view's factual fallback cover
any you cannot explain.

When your instructions allow you to name yourself, pass `--agent` (`claude`,
`codex`, `opencode`, `copilot`, or another tool's own name). Always include
`--session` with the actual human-readable title of the current chat when the
host makes it available. Retrieve it from the host's session context or tools;
in Codex, use the Codex app's thread listing or reader and match the current
thread's exact ID. Never choose the first or most recent thread just because it
appears in the list, and never substitute an opaque ID for a title. If the host
cannot supply the title, omit `--session`; never invent either name.

The header leads with the session title beside the agent's mark; full tool and
session provenance remains in the tooltip. The session name travels with the
file, so omit it when it contains anything that should not be shared. This
records where the review came from, not an approval.

In the app, Graph Studio replaces an earlier review tab from the same tool
and session, so updated diffs stay in their tab and other sessions have their
own tabs.

Before/after must use the same engine. Snapshot accepts SQLite files, PostgreSQL
custom-format `.dump`/`.backup` archives, and `.postgres`/`.pgstudio` connection
documents. PostgreSQL capture is read-only; `--socket PATH` selects an explicitly
owned local Unix socket. SQLite capture is read-only and does not count or export
rows. Connection credentials and row values never belong in snapshots.

For code revisions, materialize each schema in a separate disposable database
using the repository's trusted migration adapter. Never apply migrations to the
user's active database to obtain a diff. Do not import application code from an
unreviewed revision. The existing code review does not authorize arbitrary remote
scripts, production access, or weakening database isolation.

If a snapshot cannot be produced completely, stop the database-review step with
the concrete error. Do not infer a complete schema from regex parsing a SQL patch,
or turn unsupported syntax, missing privileges, or failed migrations into an empty
schema. For data-only migrations, still show the changed migration paths and state
that the schema is unchanged; data effects remain part of the original review.

## Review and handoff

Look at the shown review and inspect changed tables and their relationships.
For tables, fields, and relations alike, green `+` labels mark additions, blue
`~` labels changes, and red `−` labels removals. Unselected table cards keep a
single quiet border; selecting one colours that border by change kind (dashed
red for a removal). Removed tables remain faded with a Removed badge. A relation
that keeps its tables but changes columns or
actions is one changed relation; one that moves to other tables shows as removed
plus added. Cards list keys first, then changed fields. Table details show field
types, nullability, defaults, key membership, and available definition changes.
The graph frames the first connected set of changes without selecting its tables,
names changed tables at a readable size, and hides unchanged relations
until zoomed in. ⌥⌘↓ and ⌥⌘↑, or Next and Previous in the conversation view, step
between connected sets. Choosing a table in the list or the graph isolates its own
changes and the tables they reach, fading the rest; choose it again or click empty
canvas to see every change.

Report the exact base/head, affected tables, artifact path, and unsupported scope.
No automatic rename inference is made: a rename appears as removal plus addition.
Snapshots cover tables/views, fields, declared foreign keys, and available
index/trigger/constraint definitions; row data, grants, RLS, stored routines,
extensions, and deployment behavior are not a complete part of this review.
Keep the normal code review authoritative for those changes. Never claim a schema
diff approves a merge or push. Preserve the user's existing publication authority.

The comparison is self-contained: opening it never connects to a database or
executes SQL. Existing `.studio.json` notes and cluster colours are separate; do
not overwrite them. Save review artifacts outside source control unless the user
or repository workflow asks for them to be committed.
