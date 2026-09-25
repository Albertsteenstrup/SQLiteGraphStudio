---
name: database-diff
description: Capture and visually compare SQLite or PostgreSQL schemas in SQLite Graph Studio for a PR, a local integration, or two database versions. Use only when the user explicitly asks for a visual schema diff; never start it automatically after a code review, push, fetch, or merge.
---

# Database diff

Create a `.sgreview` file containing before/after schema snapshots and open it in
SQLite Graph Studio. The app shows added/removed tables, field changes, and
foreign-key changes in both the graph and a table comparison. This is schema
evidence, not proof that data migrations or deployment are safe.

Run this only when the user asks for it. Each run can create disposable databases
and open Graph Studio, and many coding sessions on one machine may be reviewing at
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
open -a /path/to/SQLiteGraphStudio.app change.sgreview
```

Name yourself when your instructions allow it. `--agent` takes `claude`, `codex`,
`opencode` or `copilot` (GitHub Copilot in VS Code), or another tool's own name;
`--session` takes the human-readable name of the current chat or session. The
review header then leads with the tool's mark, for example `Claude · Table diff
visualization clarity`. Graph Studio replaces the tab of an earlier review from the
same tool and session, so an updated diff does not open another tab; reviews from
other sessions open in their own tabs. Omit `--session` when you don't know the session's name,
and omit both when you may not disclose them; never invent either. The session
name travels with the review file, so leave it out when it holds anything that
should not be shared. This records where the review came from, not an approval.

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

Open the `.sgreview` file and inspect changed tables and their relationships.
Blue solid inner borders and `+`/`~` labels indicate additions/changes. Red dashed
inner borders and `−` labels indicate removals. The existing outer group colour is
preserved. Removed tables remain faded with a Removed badge. Modified relations
show both their removed and added definitions. Table details show field types,
nullability, defaults, key membership, and available definition changes.
The graph opens on every change at once, names changed tables at a readable size,
and hides unchanged relations until zoomed in. Choosing a table in the list or the
graph isolates its own changes and the tables they reach, fading the rest; choose
it again or click empty canvas to see everything. ⌥⌘↓ and ⌥⌘↑ step through changes.

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
