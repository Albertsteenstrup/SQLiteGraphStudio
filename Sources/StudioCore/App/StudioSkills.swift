import Foundation

// MARK: - StudioSkill

public struct StudioSkill: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let shortDescription: String
    public let fullContent: String
}

public struct StudioSkillInstallationTarget: Identifiable, Sendable, Hashable {
    public let subpath: String
    public let guardDirectory: String

    public var id: String { subpath }
}

public struct StudioSkillDirectoryTarget: Identifiable, Sendable, Hashable {
    public let subpath: String
    public let label: String

    public var id: String { subpath }
}

// MARK: - StudioSkills namespace

public enum StudioSkills {

    public static let all: [StudioSkill] = [graphClusters, schemaDescriptions, storyFlows]

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
        shortDescription: "Annotates tables and columns with hover descriptions shown in the graph, table grids, and query results.",
        fullContent: schemaDescriptionsContent
    )

    public static let storyFlows = StudioSkill(
        id: "story-flows",
        title: "story-flows",
        shortDescription: "Adds user-story-inspired flow stories with acceptance notes and graph playback to the .studio.json sidecar.",
        fullContent: storyFlowsContent
    )

    // MARK: Installation targets

    public static let targetDirectories: [StudioSkillDirectoryTarget] = [
        StudioSkillDirectoryTarget(subpath: ".agents/skills", label: "Codex (.agents/skills)"),
        StudioSkillDirectoryTarget(subpath: ".claude/skills", label: "Claude (.claude/skills)"),
        StudioSkillDirectoryTarget(subpath: ".cursor/rules", label: "Cursor (.cursor/rules)"),
        StudioSkillDirectoryTarget(subpath: ".github/instructions", label: "GitHub Copilot (.github/instructions)"),
        StudioSkillDirectoryTarget(subpath: ".windsurf/rules", label: "Windsurf (.windsurf/rules)"),
        StudioSkillDirectoryTarget(subpath: ".gemini", label: "Gemini (.gemini)"),
    ]

    /// The default install path only writes into directories that already exist.
    /// New targets are created through the explicit target-directory install path.
    public static func installationTargets(for skill: StudioSkill) -> [StudioSkillInstallationTarget] {
        [
            StudioSkillInstallationTarget(
                subpath: ".agents/skills/\(skill.id)/SKILL.md",
                guardDirectory: ".agents/skills"
            ),
            StudioSkillInstallationTarget(
                subpath: ".claude/skills/\(skill.id)/SKILL.md",
                guardDirectory: ".claude/skills"
            ),
            StudioSkillInstallationTarget(
                subpath: ".cursor/rules/\(skill.id).md",
                guardDirectory: ".cursor/rules"
            ),
            StudioSkillInstallationTarget(
                subpath: ".github/instructions/\(skill.id).instructions.md",
                guardDirectory: ".github/instructions"
            ),
            StudioSkillInstallationTarget(
                subpath: ".windsurf/rules/\(skill.id).md",
                guardDirectory: ".windsurf/rules"
            ),
            StudioSkillInstallationTarget(
                subpath: ".gemini/\(skill.id).md",
                guardDirectory: ".gemini"
            ),
        ]
    }

    // MARK: Install

    public static func install(_ skills: [StudioSkill], to directory: URL) throws {
        let fm = FileManager.default
        for skill in skills {
            for target in installationTargets(for: skill) {
                let guardURL = directory.appendingPathComponent(target.guardDirectory)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: guardURL.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let fileURL = directory.appendingPathComponent(target.subpath)
                try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try skill.fullContent.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    public static func install(
        _ skills: [StudioSkill],
        to directory: URL,
        targetDirectory: StudioSkillDirectoryTarget
    ) throws {
        let fm = FileManager.default
        let guardURL = directory.appendingPathComponent(targetDirectory.subpath)
        try fm.createDirectory(at: guardURL, withIntermediateDirectories: true)

        for skill in skills {
            for target in installationTargets(for: skill) where target.guardDirectory == targetDirectory.subpath {
                let fileURL = directory.appendingPathComponent(target.subpath)
                try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try skill.fullContent.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    public static func availableInstallationTargets(for skill: StudioSkill, in directory: URL) -> [StudioSkillInstallationTarget] {
        let fm = FileManager.default
        return installationTargets(for: skill).filter { target in
            let guardURL = directory.appendingPathComponent(target.guardDirectory)
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: guardURL.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    public static func installedTargets(for skill: StudioSkill, in directory: URL) -> [StudioSkillInstallationTarget] {
        availableInstallationTargets(for: skill, in: directory).filter { target in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(target.subpath).path)
        }
    }

    public static func missingTargets(for skill: StudioSkill, in directory: URL) -> [StudioSkillInstallationTarget] {
        availableInstallationTargets(for: skill, in: directory).filter { target in
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent(target.subpath).path)
        }
    }

    public static func missingTargetDirectories(in directory: URL) -> [StudioSkillDirectoryTarget] {
        let fm = FileManager.default
        return targetDirectories.filter { targetDirectory in
            let url = directory.appendingPathComponent(targetDirectory.subpath)
            var isDir: ObjCBool = false
            return !(fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
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

    public static func hasMissingInstallableSkills(in directory: URL) -> Bool {
        all.contains { !missingTargets(for: $0, in: directory).isEmpty }
    }

    public static func isInstalled(_ skill: StudioSkill, in directory: URL) -> Bool {
        let availableTargets = availableInstallationTargets(for: skill, in: directory)
        guard !availableTargets.isEmpty else { return false }
        return availableTargets.allSatisfy { target in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(target.subpath).path)
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
    description: Add table and column descriptions to a SQLite Graph Studio sidecar file so they surface as hover tooltips on schema graph nodes, table grids, and query result headers. Use when the user asks to "document the schema", "annotate the tables", "explain what these columns mean", or hands you an unfamiliar database.
    ---

    # schema-descriptions

    You write descriptions to `<db>.sqlite.studio.json`, next to the database file. SQLite Graph Studio reads this sidecar at load time and when the user clicks **Features -> Schema Notes**. The notes appear when hovering schema graph nodes, table names and headers in table grids, and matching query result headers. The database DDL is not modified.

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

    private static let storyFlowsContent = #"""
    ---
    name: story-flows
    description: Write user-story-inspired flow stories with acceptance notes and narrated schema playback to a SQLite Graph Studio sidecar file. Use when the user asks what happens during an application flow, lifecycle, workflow, signup, checkout, import, sync, deletion, permission change, or other behavior that should be captured as a user-centered story and shown as table graph playback.
    ---

    # story-flows

    You write user-story-inspired flow stories to `<db>.sqlite.studio.json`, next to the database file. SQLite Graph Studio reads the `stories` array when the database opens and when the user opens **Features -> Stories**.

    Use the user story pattern as inspiration: capture who benefits (`actor`), what they need (`goal`), and why it matters (`benefit`). Keep it lighter than a Jira ticket when that fits the question: short title and value statement, useful conversation notes, acceptance criteria that confirm the flow, and graph playback beats that explain how the data moves through the schema.

    The app plays each playback beat by moving the graph viewport, expanding the focused table, spotlighting the tables in the beat with a warm animated fill, highlighting relation edges for a referenced column, and typing the beat text on screen.

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
              "tables": ["users"],
              "focus": "users",
              "expand": "users"
            },
            {
              "text": "The users.id key is then reused by dependent records, so the graph highlights every table attached to that account identity.",
              "tables": ["users", "sessions", "memberships"],
              "focus": "users",
              "expand": "users",
              "relation": { "table": "users", "column": "id" }
            },
            {
              "text": "A default workspace is created and linked back through membership, giving the new user a place to start.",
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
    6. Draft the graph playback beats in causal order: record created, identity/relation fan-out, downstream records, final state.
    7. Verify every table and relation column exists exactly as written.
    8. Append the story to `stories`, preserving existing `tables`, `clusters`, and earlier `stories`.
    9. Tell the user to open **Features -> Stories** and activate the new story.

    ## What not to do

    - Don't modify SQLite DDL or create tables in the database. Stories belong in the sidecar.
    - Don't invent table or column names.
    - Don't make `actor`, `goal`, or `benefit` only about tables or UI mechanics; the story should keep a user or stakeholder value thread.
    - Don't write the old `steps` key. Playback belongs in `playback`.
    - Don't use `relation` for a column unless it participates in a declared foreign-key relationship.
    - Don't overwrite existing stories unless the user explicitly asks.
    - Don't read more than 5 sample rows per table.
    """#
    // swiftlint:enable line_length
}
