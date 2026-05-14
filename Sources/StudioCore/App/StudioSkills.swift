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
        shortDescription: "Groups your tables into meaningful clusters. Defaults to domain areas, but can use a lens like people, artifacts, departments, workflows, or ownership. Run from your AI coding agent.",
        fullContent: graphClustersContent
    )

    public static let schemaDescriptions = StudioSkill(
        id: "schema-descriptions",
        title: "schema-descriptions",
        shortDescription: "Annotates your tables and columns with hover descriptions stored in the editable .studio.json sidecar. Run from your AI coding agent.",
        fullContent: schemaDescriptionsContent
    )

    // MARK: Installation targets

    /// Each entry is (subpath to write, directory that must already exist).
    /// Files are only written when the guard directory is present — no new
    /// top-level agent directories are ever created from scratch.
    public static func installationTargets(for skill: StudioSkill) -> [(subpath: String, guardDirectory: String)] {
        [
            (".agents/skills/\(skill.id)/SKILL.md",                    ".agents/skills"),
            (".claude/skills/\(skill.id)/SKILL.md",                    ".claude/skills"),
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
        let probes = [
            ".agents/skills/graph-clusters/SKILL.md",
            ".claude/skills/graph-clusters/SKILL.md",
        ]
        return probes.contains { subpath in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(subpath).path)
        }
    }

    // MARK: - Skill content
    // Source of truth: ./Skills/<id>/SKILL.md in the repository root.

    // swiftlint:disable line_length
    private static let graphClustersContent = #"""
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
    """#

    private static let schemaDescriptionsContent = #"""
    ---
    name: schema-descriptions
    description: Add table and column descriptions to a SQLite Graph Studio sidecar file so they surface as hover tooltips on schema graph nodes. Use when the user asks to "document the schema", "annotate the tables", "explain what these columns mean", or hands you an unfamiliar database.
    ---

    # schema-descriptions

    You write descriptions to `<db>.sqlite.studio.json`, next to the database file. SQLite Graph Studio reads this sidecar at load time and when the user clicks **Features -> Schema Notes**. The database DDL is not modified.

    Descriptions are intentionally a sidecar so users can edit them directly without rebuilding SQLite tables.

    ## Inputs you need

    Before writing the file, gather:

    1. **The database path.** Ask the user if not obvious. The sidecar lives next to it (for example, `app.sqlite` -> `app.sqlite.studio.json`).
    2. **The schema.** Run `sqlite3 <db> ".tables"` and `sqlite3 <db> ".schema"` or inspect existing schema docs. You need exact table and column names.
    3. **Small samples only when useful.** Pull up to 5 rows for unclear tables or columns. Do not inspect more data than needed for documentation.

    ## Output format

    Preserve any existing `clusters` block. Add or replace only the `tables` entries you are documenting.

    ```json
    {
      "version": 1,
      "tables": {
        "users": {
          "description": "auth.users -- App account roster, one row per signed-up user.",
          "columns": {
            "email": "Lowercased login email.",
            "status": "active | suspended | pending"
          }
        },
        "orders": {
          "description": "billing.orders -- Customer purchase record, one row per checkout.",
          "columns": {
            "total_cents": "Order total in cents.",
            "created_at": "UTC timestamp from checkout."
          }
        }
      },
      "clusters": []
    }
    ```

    Field rules:

    - `tables` - object keyed by exact case-sensitive table or view name.
    - `description` - optional table-level description shown verbatim when hovering the table name.
    - `columns` - optional object keyed by exact case-sensitive column name.
    - Unknown table or column names are ignored by the app, so verify spelling before writing.

    ## Workflow

    1. Read `<db>.sqlite.studio.json` if it already exists.
    2. List the schema with `sqlite3` or by reading existing schema docs.
    3. Draft concise table and column descriptions.
    4. Write the sidecar JSON, preserving unrelated fields such as `clusters`.
    5. Tell the user to click **Features -> Schema Notes** in the running app to reload the sidecar.

    ## Writing good descriptions

    Tooltip space is small. Aim for:

    - **Tables**: exactly `cluster_name.table_name -- short description`. State the table grain: what one row represents. Use an existing cluster id when present; use `unclustered` only when the table is not in any cluster.
      - Good: `authoring.comments -- Reader comments, with replies linked to parent comments.`
      - Bad: `This table contains users.`
    - **Columns**: 3-10 words. Include format, unit, source of truth, or a quirk.
      - Good: `Cents, never null`, `FK -> tenants.id, NULL for staff`, `active | suspended | pending`
      - Bad: `The user's email address.`

    Skip obvious columns like `id`, `created_at`, and `updated_at` unless they have a real quirk. Do not speculate. If you would be guessing, leave the field out.

    ## What not to do

    - Don't modify SQLite DDL or add SQL comments. Descriptions belong in the sidecar.
    - Don't overwrite existing `clusters`.
    - Don't invent table or column names.
    - Don't read more than 5 sample rows per table.
    - Don't commit the sidecar without asking. Some users want it gitignored.
    """#
    // swiftlint:enable line_length
}
