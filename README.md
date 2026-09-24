# SQLite Graph Studio

A macOS app for browsing SQLite databases and connecting to PostgreSQL in a strictly read-only mode. Explore schemas as interactive graphs, browse rows, run safe read queries, and export results.

<p>
  <a href="../../releases/latest">
    <img src="https://img.shields.io/github/v/release/Albertsteenstrup/SQLiteGraphStudio?label=Download&amp;style=for-the-badge" alt="Download latest release">
  </a>
</p>

> **No Xcode or Swift required.** Download the DMG, drag SQLite Graph Studio to Applications, open.

---

## Features

- Pick a project folder and let Graph Studio find what it can open — databases, PostgreSQL backups and connection documents, and folders of SQL migrations
- Read a data model straight from a project's migration files, with no database or server involved, at any point in its history
- Interactive schema graph showing foreign-key relationships and cardinality, with faint signals drifting along each relation in the direction its foreign key points
- **View ▸ Graph Visuals** switches any graph decoration off and remembers the choice — relation pulses, zoomed-out relations, relationship labels, group colours and titles, zoomed-out group links, card shadows, hover previews and the minimap
- Inline row editing with right-click row actions (add, clone, delete)
- Typed equality, comparison, range and NULL filters, explicit text search, key-based next pages, and on-demand exact counts
- SQL query runner with Stop, timeouts, bounded fetching, duplicate-column-safe results and explain plan
- Narrow-window layout — the workspace fits a Split View or Stage Manager tile, and once there is no longer room for two panes it shows one and keeps the schema graph on screen; the dock stays available to switch which pane that is
- Explicit loaded-row and all-matching exports, with snapshot consistency, progress, cancellation and atomic file publication
- User-selected PostgreSQL connection documents with schema-qualified catalog browsing, paging, search, filtering, sorting, exports, query history, and non-executing EXPLAIN
- Schema notes from a sidecar file — table and column descriptions in `<database>.studio.json` show up as hover tooltips on graph nodes, table grids, and query result headers (see the [schema-descriptions](.claude/skills/schema-descriptions/SKILL.md) skill for AI-assisted authoring)
- AI-authored cluster hints — let an agent group related tables by a chosen lens, defaulting to domain areas but supporting concepts like people, artifacts, departments, workflows, or ownership (via the [graph-clusters](.claude/skills/graph-clusters/SKILL.md) skill)
- Local MCP bridge — Codex and Claude Code can inspect the active task's source context and request supported schema views through Graph Studio. The bridge reports status without opening the app; launching is an explicit tool action.
- Workspace tabs — each tab keeps its own graph/data split, camera, filters and query drafts; restorable browsing state returns after relaunch without running saved drafts or restarting speech.
- Guided explanations — an agent can show a small set of tables, inspect rows or a read-only result, and add short captioned points with local streamed macOS narration and immediate playback controls.

## AI Skills

Five optional AI coding agent skills support schema exploration and review:

- **graph-clusters** — Groups your tables into meaningful clusters. It defaults to domain areas, and you can ask for another lens such as people, artifacts, departments, workflows, or ownership. Run from your AI coding agent.
- **schema-descriptions** — Annotates your tables and columns with hover descriptions shown in the graph, table grids, and query results. Run from your AI coding agent.
- **database-diff** — Compares database versions after code review, showing table, field, and foreign-key changes for a PR or local integration. See [the skill](Skills/database-diff/SKILL.md).
- **database-preview** — Shows intended schema changes before implementation using a compact plan and cached metadata. Iteration runs without migrations or a database server. See [the skill](Skills/database-preview/SKILL.md).
- **database-explore** — Helps an agent inspect the current source and schema through the local MCP bridge, when the app-side action is supported. See [the skill](Skills/database-explore/SKILL.md).

Download them from inside the app: **Database → AI Skills…** — or from the prompt that appears when you open a database with more than 10 tables. The in-app installer places project skills next to your database or PostgreSQL connection document so agents in that directory can use them. The user-wide MCP setup below also installs the canonical Codex and Claude Code skills in their normal per-user directories.

For Codex, create `.agents/skills` in your repo first; the app installs all five skills there. Use `/skills` or mention a skill such as `$database-diff` or `$database-preview` in Codex to invoke it.

### Local MCP bridge

The `StudioMCP` executable provides a newline-framed JSON-RPC stdio server for Codex and Claude Code. For a normal installation, place the app in `/Applications` and register both user-level clients with the helper shipped inside the app:

```bash
"/Applications/SQLiteGraphStudio.app/Contents/MacOS/StudioMCP" setup all
```

This packaged helper path is the stable setup route: it does not depend on a repository checkout or a SwiftPM build directory. From Graph Studio, choose **Coding Agents → Install local MCP and skills…**. The review defaults to user-wide setup and also offers a project folder. Project setup writes Codex MCP configuration to that project's `.codex/config.toml` and asks Claude Code to merge its project server into `.mcp.json`; it installs skills under that project's `.agents/skills` or `.claude/skills`. Codex loads project configuration only after you trust the project. Project setup refuses symlinked configuration and skill destinations. `swift run StudioMCP setup all` is for development checkouts and remains user-wide; use `setup codex` or `setup claude` to select clients. Run setup after placing the app at its final path because each client stores the helper's absolute executable path. Existing entries named `sqlite-graph-studio` are left unchanged when they point elsewhere, and unrelated configuration is kept. A skill file is updated only when it matches a released Graph Studio managed version; customized files are reported and left intact. The retired `story-flows` skill is removed only when its file exactly matches a known released copy. After writing a client entry, setup reads it back and starts the bundled helper for an MCP handshake, tool discovery, and a read-only `studio_status` call. This checks the helper and bridge status; it does not claim that a running coding-agent session has loaded the server. Restart or reload the client, then call `studio_status` from that client to confirm its live connection.

`studio_status` never launches Graph Studio. When a user asks to see a visualization, `studio_launch` opens the app and waits for its private local bridge to become ready. App-bound tools require Graph Studio to be running; tools without an app-side handler return a structured `TOOL_UNAVAILABLE` error. The bridge is local to the same macOS user and does not expose database write operations.

See the [agent exploration implementation status](docs/agent-exploration-implementation-status.md) for current coverage and validation limits.

## Database schema comparisons

Choose **File → Compare Database Schemas…**, select the before and after databases,
and save the `.sgreview` comparison. SQLite files, PostgreSQL connection documents,
and custom-format backups are supported; both versions must use the same engine.
Capture reads schema metadata only. Opening a saved comparison is fully offline.

The graph preserves group colours on the outer border. A separate inner border
uses solid blue for additions/changes and dashed red for removals, with explicit
`+`, `−`, and `~` field counts. New tables have a **New** badge; removed tables stay
visible and faded with **Removed**. Edited foreign keys show both old and new
links. The table list carries the same badges, and table details compare field
definitions, relations, and available constraints/indexes/triggers. Row data,
permissions, RLS, routines, and deployment effects still need normal code review.

The [database-diff skill](Skills/database-diff/SKILL.md) documents command-line
snapshot and comparison creation for hooks. Bind generated reviews to immutable
base/head revisions and run them after the existing code-review rounds. Git does
not run pre-merge-commit on fast-forward merges, so that workflow needs an explicit
final schema-review step as well.

## Proposed changes before implementation

Use the sibling [database-preview skill](Skills/database-preview/SKILL.md) to
explore a design before writing migrations. Capture metadata once, or reuse the
chosen side of a real `.sgreview`. The agent writes only intended table, field
and relation operations in a small JSON plan; the CLI builds a `.sgpreview`
without executing SQL. `inspect --find`, `--table` and `--column` keep the agent's
context focused instead of loading the entire schema.

Open the preview once. Rebuilding the same file automatically updates the view,
preserving selection and the overview camera. Invalid updates retain the last
valid view and show an error. **Proposed · not applied** and **Captured / Proposed**
labels distinguish this design from a completed-change review. The plan is
bound to its baseline fingerprint; refresh that baseline explicitly when the
source schema changes. A preview neither proves migration validity nor satisfies
the real schema-review hook.

## Opening a project folder

Choose **Open Project Folder…** from the File menu (⇧⌘O), or **Search Project Folder** on the welcome screen, and pick a repository. Graph Studio walks it and its subfolders and reports everything it can open: SQLite databases, PostgreSQL custom-format backups, `.postgres`/`.pgstudio` connection documents, folders of versioned SQL migrations, and standalone `schema.sql`/`structure.sql` scripts. A progress panel shows folders and files searched while it runs, and Cancel stops it at any point.

Finding one match opens it. Finding several shows a picker grouped by kind, with each match's location inside the project and a short description (`407 migrations · PostgreSQL · 0001 → 0485`, `6.3 MB`, `db.example.test:5432/catalog`).

Candidate files are checked by content, not by name: a `.db` file without the SQLite header, a `.dump` that is not a `PGDMP` archive, and a `.postgres` file that is not a connection document are all left out.

### What the search skips

Two rules apply together, because neither is sufficient alone:

- **A built-in list of dependency, environment and build directories** — `node_modules`, `.venv`/`venv`, `vendor`, `site-packages`, `__pycache__`, `.tox`, `build`, `dist`, `target`, `.build`, `DerivedData`, `Pods`, `.gradle`, `.next`, `.turbo`, `.terraform`, caches and coverage output, and every `.egg-info`. Hidden directories and anything containing a `pyvenv.cfg` are skipped too, so a virtual environment is recognised whatever it is called. This list is short and stable because it only needs to name conventions, not packages.
- **The project's own `.gitignore` files** — comments, negation (`!`), anchoring, directory-only patterns, `*`, `?`, `**` and character classes are all honoured, and a nested `.gitignore` overrides the one above it. This covers whatever is specific to the project without anyone maintaining a list.

Symbolic links are never followed, so a link cannot lead the search out of the chosen folder or into a cycle. Depth and total entries are bounded; reaching a limit is reported rather than hidden. Cancel stops the walk itself, not just the panel. Searching a repository the size of a medium backend takes well under a second, and a monorepo with a `.gitignore` in every package is no slower — ignore rules apply to the branch they belong to rather than accumulating across the tree. Patterns are matched by a linear scanner, so a wildcard-heavy `.gitignore` cannot stall the search.

Handing the app a folder — dropping it on the icon, passing it as a launch argument, or choosing it from **Open Recent** — searches it the same way, unless the folder is itself a set of versioned SQL migrations, which opens directly.

## Migration data models

A folder of versioned SQL files opens as a data model with no database, server or credentials involved. Graph Studio replays the DDL in order and shows the schema those migrations produce: tables, columns and types, primary keys, foreign-key edges with cardinality, unique and check constraints, indexes, triggers, and views.

Files are recognised by a leading version — `0001_init.sql`, `001-init.sql`, `20240115093000_init.sql`, Flyway's `V1_2__init.sql`, and golang-migrate's `000001_init.up.sql`. Rollback files (`.down.sql`, `_rollback.sql`, `.undo.sql`) are excluded so a set only ever moves forward. Versions sort by numeric value, so `2` comes before `10`. PostgreSQL and SQLite are both supported; the dialect is inferred from the folder path and the text of the files, and decides schema qualification and identifier case folding.

**The newest migration is the default.** The picker offers any other version before opening, and once open, a control in the pane header steps through the history — arrows for one migration at a time, a menu for any point in it, and **Database → Replay Migrations Through** for the same choice from the menu bar. Graph layout, notes, and groups belong to the migration set, not to one revision of it, so they survive stepping between versions.

`COMMENT ON TABLE` and `COMMENT ON COLUMN` become hover descriptions, in the same place the `schema-descriptions` skill writes them. A hand-written sidecar always wins over a comment from the SQL.

Opening a migration folder directly replays every versioned `.sql` file in it. That is deliberately more inclusive than the search, which also applies the project's ignore rules — so a migration folder that is gitignored never appears in a search but still opens when chosen by hand.

This model is **structure only**: there are no rows to browse, the SQL runner is unavailable, and every editing action is refused with an explanation. Notes, cluster hints, and schema-exploration skills still work through the `<folder>.studio.json` sidecar next to the migration folder.

A migration set is replayed, not executed, so what a parser cannot interpret is reported rather than silently dropped. Statements that build DDL dynamically — a PL/pgSQL loop over `pg_constraint` that runs `execute format(...)`, or `CREATE TABLE … AS SELECT` — appear in the metadata diagnostics panel naming the file and the statement. Idempotency guards around static DDL (`do $$ begin if not exists (…) then alter table … end if; end $$`) are replayed normally. Temporary tables a migration creates for its own use are not part of the model. On a 407-file PostgreSQL history the replay reads 5,700 statements in under three seconds and reports about a dozen statements it could not interpret.

## PostgreSQL connections

Choose **Open Database File…** from the File menu (⌘O), or **Choose Database File** on the welcome screen. One picker accepts SQLite files (`.db`, `.sqlite`, `.sqlite-db`, `.sqlite3`, `.sqlitedb`), PostgreSQL custom-format backups (`.dump`, `.backup`), and connection documents (`.postgres`, `.pgstudio`); the app selects the appropriate backend automatically. All supported extensions appear below the welcome button and in the picker. These files also work through Finder, launch arguments and Open Recent. SQL scripts, directory archives and other database engines are not supported by this picker; a folder of SQL migrations opens through [Open Project Folder…](#opening-a-project-folder) instead.

A backup opens without connection details or a login. Graph Studio copies it into a private temporary workspace, restores it using local PostgreSQL, and opens the schema, rows, record explorer and SQL editor in read-only mode. Progress and Cancel are shown during preparation. The source backup is never modified. Closing the workspace or quitting stops its server and removes the temporary copy; reopening restores a fresh copy. A private Unix socket is used, with no TCP listener. Restore tools and the server run under a filesystem/network sandbox. Restoration is the only write phase and only affects the private copy; browsing uses a separate reader with existing read-only query restrictions.

Archive SQL runs as a non-superuser without role/database creation or native-language privileges. The server also blocks shell/program execution and executable mappings from the writable workspace. Trusted extensions such as `pgcrypto` can restore normally; `vector` is prepared with a fixed command from the trusted installed runtime before archive SQL runs. Other features requiring superuser privileges (including untrusted procedural languages) are rejected rather than restored with elevated permissions. Cleanup uses kernel-checked process identities; if shutdown cannot be confirmed, the private workspace is retained rather than removed underneath a surviving process.

The private snapshot reader can see all rows present in the archive, including tables with row-security policies. It has no table-write or administrative privileges. Stable/immutable SQL and PL/pgSQL functions that run with the reader's permissions remain available to views. Views requiring volatile or security-definer application functions report a permission error. These snapshot permissions do not change any live database or the source archive.

Backup opening requires a compatible local runtime: a packaged `Contents/Resources/PostgreSQL` runtime is preferred, with installed PostgreSQL 17/18 (Homebrew or Postgres.app) supported as a fallback. A development override can use `SGS_POSTGRES_RUNTIME=/path/to/runtime`. The runtime must include any extensions required by the archive (for example `pgcrypto` and `vector`). Missing tools, unsupported archive versions, extensions or restore failures produce an error and discard the incomplete workspace. See [packaging](docs/packaging.md). This does not affect live connection documents.

A connection document is a user-managed `.postgres` or `.pgstudio` JSON file containing only endpoint properties:

    {
      "name": "Read-only database",
      "host": "database.example.test",
      "port": 5432,
      "database": "catalog",
      "username": "reader",
      "tlsMode": "required"
    }

Graph Studio does not show a login form, save connection profiles, or put credentials in documents. PostgreSQL authentication is delegated to the server's configured passwordless mechanism or to the user's existing PGPASSWORD/PGPASSFILE environment configuration. TLS required verifies the server certificate; TLS disabled is intended only for a deliberately local, trusted endpoint.

PostgreSQL sessions are permanently read-only:

- The connection requests default_transaction_read_only=on.
- Catalog, table browsing, query execution, and EXPLAIN each run inside an explicit READ ONLY transaction.
- Every PostgreSQL table descriptor and column is non-editable. Row edits, inserts, deletes, imports, table creation, schema changes, and write SQL are disabled in the UI and fail closed in the backend.
- The query gate accepts SELECT, VALUES, SHOW, read-only WITH queries, and EXPLAIN. It rejects multiple statements, comments/literal bypasses, transaction control, DDL/DML, COPY, CALL, DO, SET/RESET, VACUUM, EXPLAIN ANALYZE, and known side-effecting functions before sending the statement.

PostgreSQL metadata is read from pg_catalog in set-based queries. System and temporary schemas are excluded. Tables, partitioned tables, views, and materialized views include columns, format_type output, nullability, defaults, generated and identity metadata, primary keys, indexes, foreign keys, named CHECK constraints, user triggers, row estimates, and graph cardinality. Initial catalog loading does not count table rows. Query results are capped at 500 visible rows by default (up to 10,000 for the backend request) and report truncation; table browsing uses bound search/filter/paging values.

PostgreSQL uses the same local groups, colours, notes and AI skills as SQLite. Put metadata next to the selected document: `fjordholm.dump.studio.json` for `fjordholm.dump`, `fjordholm.postgres.studio.json` for `fjordholm.postgres`, or `workspace.pgstudio.studio.json` for `workspace.pgstudio`. A migration folder named `migrations` uses the sibling `migrations.studio.json`. Table references must use the exact schema-qualified catalog ID, for example `public.orders`. The optional `overviewTables` array names up to 16 exact table IDs that receive readable callouts on a full-model map; it neither pins layout nor creates relationships. **Relayout** reloads the sidecar and rebuilds the graph. The selected document appears in **Open Recent**, and its path owns saved queries and layout even when a fresh local copy is restored.

Query history, saved queries and graph layout use a password-free, hashed connection identity. The selected document provides the local metadata/skills directory. Use **AI Skills → Reinstall** to explicitly replace an older installed skill with the current instructions.

## Exploring large schemas

Both database types use the same graph engine. For more than 128 tables, it divides layout work into neighbourhoods of at most 64 tables, applies the existing force solver inside them, and packs the resulting regions without overlapping cards. Authored groups retain their labels and colours, including groups larger than one neighbourhood. Unassigned tables get deterministic local groups based on schema, repeated name prefixes and relationships; these inferred groups are not saved into the sidecar.

At full-model zoom, authored group titles and a few optional `overviewTables` callouts provide orientation while the other nodes stay compact. A coding agent can then show a readable subset spanning the main domains and move into a narrower group or table. The sidecar hints guide that presentation; they do not restrict the agent to those tables.

- Use the graph's **Find tables and groups** button to search the complete catalog, including tables outside the current view.
- Choose a group to move the camera to it while keeping other groups and cross-group connections visible. Expand a table to focus it and arrange its direct neighbours without overlap; the back button returns to the previous view. Groups with more than 48 tables and tables with more than 48 neighbours have previous/next controls.
- **Graph options (…) → Node size** offers **Uniform**, **Fields**, **Rows**, and **Relations**. Count differences become stronger as you zoom out; detailed cards keep their usual size. A compressed scale uses the full catalog, so filtering does not renormalize the remaining tables. Row sizing uses available counts (catalog estimates until counted); unknown counts have neutral-sized, dashed markers. The choice is remembered across restarts.
- Hovering a table gently enlarges it and its directly connected tables at every zoom level. In the zoomed-out overview, their names, field counts, and row counts appear inside the existing nodes, using the same header style as detailed cards. Their links are highlighted across groups. Hover never adds floating callouts or moves the layout; text scales with the nodes.
- The compact graph toolbar keeps search and **Filter** visible. The **Graph options (…)** menu contains **Graph visuals** (the same switches as **View ▸ Graph Visuals**), node size, relayout, and table counts; active filters never add another toolbar row.
- **Filter** limits the graph by inclusive minimum/maximum field, row, and relation counts. Empty bounds are unlimited. Relations count incoming and outgoing foreign-key constraints in the full schema; composite and self-referencing keys each count once, and zero finds unconnected tables. Row filters count matching tables and views afresh, including empty tables; Reset restores the complete graph. Unknown row counts are shown as **— rows** until counted.
- PostgreSQL labels omit the default `public.` schema prefix. Other schema names remain visible, and all queries, relationship IDs and sidecar references retain the exact qualified names.
- Zoomed-out overviews draw inexpensive table marks, group relationships, and a bounded even-stride sample of up to 1200 individual relations at reduced contrast — enough to keep relation pulses readable without drawing every edge, since nothing is off screen at that zoom for culling to discard. Below that many relations, all of them are drawn. Switch it off with **Relations While Zoomed Out**. Zoom in or select a table for details. Detailed card views are capped at 160; remaining visible tables stay represented by marks, including when a large selection is active.
- **Graph options (…) → Expand all tables** uses the same size-aware layout and refits large views. Return to all groups to recover the overview; ordinary panning and hovering do not rerun layout.

Canvas interaction reuses relationship indexes, group connections and table sizes while the camera moves. Only visible detailed cards prepare column rows; overview marks use a spatial hit index. Camera updates keep the minimap moving during continuous gestures, and the active drag stays mounted at the viewport edge. The minimap batches its table and relationship drawing. These limits apply equally to PostgreSQL and SQLite.

See [dump and native UI verification](docs/dump-ui-verification.md) for archive, crash, scrolling and filter checks. See [verification evidence](docs/postgres-parity-scale-verification.md) for measured layout and canvas preparation work, test coverage and the limits of the native interaction checks.

Dragging and saved pins remain available. Relayout deliberately rebuilds positions; obsolete large-grid snapshots are regenerated while preserving saved pins. If saved pins themselves overlap, their explicit positions take precedence.

See [query, browsing, export and metadata contracts](docs/query-data-contracts.md) for value formats and consistency guarantees.

The [combined integration verification](docs/main-integration-verification.md) records the final shared tests, large-catalog check and remaining native interaction limits.

## Install

1. Go to [Releases](../../releases/latest)
2. Download `SQLiteGraphStudio.dmg`
3. Open the DMG and drag `SQLiteGraphStudio.app` to `/Applications`
4. Open a .sqlite file or .postgres document with it

Release artifacts must be signed with Developer ID and notarized for normal Gatekeeper distribution. Older or local builds may be unsigned or unnotarized; see the release notes for that artifact. If macOS blocks an app, use a verified signed release or build from source. Removing quarantine attributes is not an installation requirement or a substitute for a trusted release.

See [building, preference migration, and distribution signing](docs/packaging.md) for local build commands and the configured release workflow.

## Build from source

Requires a Swift 6.3 toolchain (including a compatible Xcode installation). Built in Swift/SwiftUI — not because it's the obvious choice for a database tool, but because it was the fastest way to build something native on macOS that felt good to use.

```bash
git clone https://github.com/Albertsteenstrup/SQLiteGraphStudio.git
cd SQLiteGraphStudio
swift run SQLiteGraphStudio /path/to/database.sqlite
```

### PostgreSQL verification

To run the UI/archive regression checks with a selected local backup, build the app and set `SGS_POSTGRES_ARCHIVE_TEST_FILE=/path/to/backup.dump` and `SGS_POSTGRES_SUPERVISOR=/path/to/SQLiteGraphStudio.app/Contents/MacOS/SQLiteGraphStudio`. These checks exercise read-only opening, reopening, every table grid, graph filters, and source-file preservation.

The normal unit suite does not require a running PostgreSQL server. To run the opt-in integration tests, provide an explicitly chosen test database through environment variables and set SGS_POSTGRES_TESTS=1:

    SGS_POSTGRES_TESTS=1 \
    SGS_POSTGRES_HOST=... \
    SGS_POSTGRES_PORT=... \
    SGS_POSTGRES_DATABASE=... \
    SGS_POSTGRES_USER=... \
    SGS_POSTGRES_PASSWORD=... \
    SGS_POSTGRES_TLS=required \
    swift test --filter PostgreSQLIntegrationTests

Without `SGS_POSTGRES_TESTS=1`, live tests explicitly report skipped coverage. With opt-in, missing or invalid configuration fails the run, including missing `SGS_POSTGRES_TLS` (`required` or `disabled`). An explicitly empty password is allowed for a deliberately passwordless test role. PostgreSQL 14 or later is required for server-side disconnected-client detection. Use a least-privilege reader and a disposable database. The generic integration tests only read; fixture-specific tests additionally require `SGS_POSTGRES_FIXTURE_TESTS=1` and the owned fixture described in [verification](docs/query-export-verification.md).

## Reporting issues

Open a [GitHub Issue](../../issues) — include your macOS version and what you were doing when it broke.

## License

MIT — see [LICENSE](LICENSE).

## Record inspection and navigation

Right-click a loaded row and choose **Inspect Record…** to read full values, follow foreign keys, and explore a bounded graph of actual records on SQLite or read-only PostgreSQL. Back/forward preserves the originating table or query context. The record graph has separate state from the schema graph and supports catalog-validated mappings for explicit node/edge tables. See [Record exploration](docs/record-exploration.md) for controls, limits, and mapping examples.
