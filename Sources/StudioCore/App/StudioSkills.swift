import Foundation

// MARK: - StudioSkill

public struct StudioSkill: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let shortDescription: String
    public let fullContent: String
}

// MARK: - StudioSkills namespace

public enum StudioSkills {

    public static let all: [StudioSkill] = [graphClusters, schemaDescriptions]

    // MARK: Skills

    public static let graphClusters = StudioSkill(
        id: "graph-clusters",
        title: "graph-clusters",
        shortDescription: "Groups your tables into domain clusters so the graph lays out by meaning, not just foreign keys. Run from your AI coding agent.",
        fullContent: graphClustersContent
    )

    public static let schemaDescriptions = StudioSkill(
        id: "schema-descriptions",
        title: "schema-descriptions",
        shortDescription: "Annotates your tables and columns with hover descriptions stored as -- comments in the DDL. Run from your AI coding agent.",
        fullContent: schemaDescriptionsContent
    )

    // MARK: Installation targets

    /// Each entry is (subpath to write, directory that must already exist).
    /// Files are only written when the guard directory is present — no new
    /// top-level agent directories are ever created from scratch.
    public static func installationTargets(for skill: StudioSkill) -> [(subpath: String, guardDirectory: String)] {
        [
            (".claude/skills/\(skill.id)/SKILL.md",                    ".claude/skills"),
            (".codex/skills/\(skill.id)/SKILL.md",                     ".codex/skills"),
            (".cursor/rules/\(skill.id).md",                           ".cursor/rules"),
            (".github/instructions/\(skill.id).instructions.md",       ".github/instructions"),
            (".windsurf/rules/\(skill.id).md",                         ".windsurf/rules"),
            (".gemini/\(skill.id).md",                                 ".gemini"),
        ]
    }

    // MARK: Install

    public static func install(_ skills: [StudioSkill], to directory: URL) throws {
        let fm = FileManager.default
        for skill in skills {
            for (subpath, guardDir) in installationTargets(for: skill) {
                let guardURL = directory.appendingPathComponent(guardDir)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: guardURL.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let fileURL = directory.appendingPathComponent(subpath)
                try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try skill.fullContent.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: Git root

    /// Walks up from `directory` looking for a `.git` entry (directory or file for worktrees).
    /// Returns the containing directory if found, nil if no git repo is detected.
    public static func gitRoot(from directory: URL) -> URL? {
        let fm = FileManager.default
        var current = directory.standardized
        while true {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
        return nil
    }

    // MARK: Detection

    public static func areInstalled(in directory: URL) -> Bool {
        let probe = directory
            .appendingPathComponent(".claude/skills/graph-clusters/SKILL.md")
        return FileManager.default.fileExists(atPath: probe.path)
    }

    // MARK: - Skill content
    // Source of truth: ./Skills/<id>/SKILL.md in the repository root.

    // swiftlint:disable line_length
    private static let graphClustersContent = #"""
    ---
    name: graph-clusters
    description: Generate cluster hints for the SQLite Graph Studio physics engine so related tables group together by domain (auth, billing, content, etc.) instead of by foreign-key topology alone. Use when nodes overlap or look like one big blob, when the user asks to "group related tables", "organize the schema", or describes a task that needs a few specific tables clustered together (e.g. "I'm working on auth — pull those together").
    ---

    # graph-clusters

    You write a JSON sidecar (`<db>.sqlite.studio.json`) that tells SQLite Graph Studio's force-directed layout which tables belong together. The physics engine already attracts tables in the same cluster to each other — your job is to decide what the clusters should be, using the database schema and whatever task context the user has shared.

    The sidecar is read once when a database opens and re-read when the user clicks **Features → Schema Notes** in the graph view. The user can edit your output by hand at any time.

    ## Inputs you need

    Before writing the file, gather:

    1. **The database path.** Ask the user if not obvious — the sidecar lives next to it (e.g. `app.sqlite` → `app.sqlite.studio.json`).
    2. **The schema.** Run `sqlite3 <db> ".tables"` and `sqlite3 <db> ".schema"` (or `.schema <table>` per table). You need table names and foreign-key columns.
    3. **Task context.** What is the user *working on*? A clustering tuned to "I'm refactoring the billing flow" looks different from "I'm exploring this dump for the first time."

    If the database has fewer than ~6 tables, clustering rarely helps — recommend skipping the skill and just letting the FK-based default lay out.

    ## How to choose clusters

    Group tables by **domain concept**, not by FK chains. Foreign keys already create attraction; clusters should add a *second* signal on top, capturing semantic groupings the schema doesn't express.

    Good signals:
    - **Naming prefixes** (`auth_*`, `billing_*`, `event_*`) — strong, usually correct.
    - **Shared subject matter** even without prefixes — `users`, `sessions`, `password_resets` all belong to auth.
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
    """#

    private static let schemaDescriptionsContent = #"""
    ---
    name: schema-descriptions
    description: Add `--` line comments to a SQLite database's DDL so SQLite Graph Studio surfaces them as hover tooltips on table and column nodes. Use when the user asks to "document the schema", "annotate the tables", "explain what these columns mean", or hands you an unfamiliar database. The app reads the comments from `sqlite_master.sql` at load time — no sidecar file is involved for descriptions.
    ---

    # schema-descriptions

    You add `--` line comments to the DDL stored in `sqlite_master.sql`. SQLite Graph Studio parses those comments at load time and shows them as native macOS hover tooltips, with a tiny accent dot indicating "has description." Layout is unaffected — the cards don't grow, the view doesn't split.

    The `.studio.json` sidecar is **not** used for descriptions anymore. It is still used for cluster hints (see `graph-clusters`). Descriptions live in the database itself.

    ## How SQLite stores comments — read this first

    SQLite's `sqlite_master.sql` contains the CREATE statement as the user wrote it, with one catch:

    - ✅ Comments **inside** `CREATE TABLE ( … )` are preserved.
    - ✅ Comments **inside** `CREATE VIEW name AS … SELECT …` are preserved.
    - ❌ Comments **before** `CREATE TABLE` or `CREATE VIEW` are silently dropped. Do not rely on them.

    This determines where you put the comments.

    ## The placement rules the app parses

    These rules are enforced by `DDLCommentParser.swift`. Stick to them or your comments won't show up.

    **Column description** — one of:
    1. Stacked `--` lines on the line(s) immediately before the column.
    2. A trailing `-- …` comment on the same line as the column.

    ```sql
    CREATE TABLE users (
      -- App account id; autoincrement
      id INTEGER PRIMARY KEY,
      email TEXT, -- lowercased, verified at signup
      status TEXT
    );
    ```

    **Table description** — a `--` comment block at the top of the parens, **separated from the first column by a blank line**. The blank line is mandatory; without it the comments belong to the first column instead.

    ```sql
    CREATE TABLE users (
      -- App account roster - one row per signed-up user.
      -- Soft-deleted rows kept for 30 days then purged.

      id INTEGER PRIMARY KEY,
      email TEXT
    );
    ```

    **View description** — a `--` comment block between `AS` and the SELECT body.

    ```sql
    CREATE VIEW active_users AS
      -- Excludes soft-deleted rows and unverified signups.
      SELECT id, email FROM users WHERE status = 'active';
    ```

    **Where comments are dropped** — before constraint defs (PRIMARY KEY, FOREIGN KEY, CHECK, UNIQUE, CONSTRAINT, …) and outside the CREATE statement. The parser ignores them.

    ## How to actually add comments

    SQLite has no `COMMENT ON COLUMN …` syntax — and `ALTER TABLE` cannot edit a column definition. To attach a comment to an existing table you must **recreate the table** with the comments embedded. SQLite docs call this the "12-step ALTER TABLE" pattern; here's the safe version:

    ```sql
    BEGIN;

    -- 1. Inspect the existing definition.
    -- (Look at SELECT sql FROM sqlite_master WHERE name='users' first.)

    -- 2. Rename the existing table.
    ALTER TABLE users RENAME TO users_old;

    -- 3. Create the new table with the same columns + your comments.
    CREATE TABLE users (
      -- App account roster - one row per signed-up user.

      -- Surrogate key. Never reused.
      id INTEGER PRIMARY KEY,
      email TEXT UNIQUE, -- lowercased, verified at signup
      -- active | suspended | pending_verification
      status TEXT NOT NULL,
      created_at TEXT NOT NULL
    );

    -- 4. Copy data across.
    INSERT INTO users (id, email, status, created_at)
    SELECT id, email, status, created_at FROM users_old;

    -- 5. Drop the old table.
    DROP TABLE users_old;

    COMMIT;
    ```

    Disable foreign keys around the rebuild if other tables reference this one:

    ```sql
    PRAGMA foreign_keys = OFF;
    BEGIN;
    -- … the rebuild …
    COMMIT;
    PRAGMA foreign_keys = ON;
    PRAGMA foreign_key_check;  -- bail if anything is broken
    ```

    You **must** preserve:
    - All column types, NOT NULL, DEFAULT, CHECK, UNIQUE constraints.
    - The primary key shape (including composite keys and `WITHOUT ROWID`).
    - Foreign keys (re-declare them).
    - Indexes and triggers (drop, recreate after the swap).

    When in doubt, dump the table with `.schema <name>` and modify only the comment lines.

    ## New tables

    If you are writing a `CREATE TABLE` that doesn't exist yet, embed the comments directly — no rebuild needed:

    ```sql
    CREATE TABLE orders (
      -- One row per customer order. Status transitions: pending → paid → shipped → cancelled.

      id INTEGER PRIMARY KEY,
      customer_id INTEGER NOT NULL REFERENCES customers(id),
      -- pending | paid | shipped | cancelled
      status TEXT NOT NULL DEFAULT 'pending',
      total_cents INTEGER NOT NULL, -- order total in cents, always > 0
      created_at TEXT NOT NULL
    );
    ```

    ## Workflow

    **Always ask the user for permission before modifying the database.** Describe which tables will be rebuilt and what will change, then wait for explicit confirmation before running any SQL.

    1. **Read** the current DDL: `sqlite3 <db> ".schema <table>"` or `SELECT sql FROM sqlite_master WHERE name = ?`.
    2. **Pull 5 sample rows** per table — concrete values often contradict what column names imply.
    3. **Draft** the rebuild SQL in chat, with comments added. Show the user before executing.
    4. **Ask for permission** — list the tables to be rebuilt and confirm the user wants to proceed.
    5. **Run inside a transaction.** Confirm row count matches before COMMIT.
    6. **Tell the user** to click **Features → Schema Notes** in the running app. That re-reads `sqlite_master` and refreshes the tooltips.
    7. Skip tables that are tiny or self-explanatory. Mention which you skipped so the user isn't surprised.

    ## Writing good descriptions

    Tooltip space is small. Aim for:

    - **Tables**: 1 sentence, ~10 words. What's one row? What's the grain?
      - Good: `App account roster - one row per signed-up user. Soft-deleted kept 30 days.`
      - Bad: `This table contains users.`
    - **Columns**: 3–10 words. Format, unit, source of truth, or a quirk.
      - Good: `Cents, never null`, `FK -> tenants.id, NULL for staff`, `active | suspended | pending`
      - Bad: `The user's email address.`

    Skip the obvious. Don't describe `id`, `created_at`, `updated_at` unless they have a quirk. Don't speculate ("probably …"). If you'd be guessing, leave the column out.

    ## What not to do

    - Don't write SQL comments **before** `CREATE TABLE` — they don't survive.
    - Don't omit the blank line separator for table descriptions — without it the comments attach to the first column.
    - Don't use `/* block comments */` — the parser only handles `--` line comments.
    - Don't put descriptions in the `.studio.json` sidecar — that field was removed.
    - Don't read more than 5 rows per table; this is documentation, not data exfiltration.
    - Don't run the rebuild outside a transaction. A crash mid-copy loses data.
    - Don't drop and recreate triggers or indexes silently — list what you're doing and ask first.
    """#
    // swiftlint:enable line_length
}
