# SQLite Graph Studio

A macOS app for browsing and editing SQLite databases. Open a file, explore the schema as an interactive graph, and edit rows directly in the table view.

![SQLite Graph Studio in use](docs/demo.gif)

<p>
  <a href="../../releases/latest">
    <img src="https://img.shields.io/github/v/release/Albertsteenstrup/SQLiteGraphStudio?label=Download&amp;style=for-the-badge" alt="Download latest release">
  </a>
</p>

> **No Xcode or Swift required.** Download the zip, drag to Applications, open.

---

## Features

- Interactive schema graph showing foreign-key relationships and cardinality
- Inline row editing with right-click row actions (add, clone, delete)
- Column sorting, filtering, and search
- SQL query runner with explain plan
- Connection profiles for quick re-opening
- Schema notes from a sidecar file — table and column descriptions in `<database>.studio.json` show up as hover tooltips on table and column nodes (see the [schema-descriptions](.claude/skills/schema-descriptions/SKILL.md) skill for AI-assisted authoring)
- AI-authored cluster hints — let an agent group related tables by a chosen lens, defaulting to domain areas but supporting concepts like people, artifacts, departments, workflows, or ownership (via the [graph-clusters](.claude/skills/graph-clusters/SKILL.md) skill)

## AI Skills

Two optional AI coding agent skills let you enrich the graph with a single prompt:

- **graph-clusters** — Groups your tables into meaningful clusters. It defaults to domain areas, and you can ask for another lens such as people, artifacts, departments, workflows, or ownership. Run from your AI coding agent.
- **schema-descriptions** — Annotates your tables and columns with hover descriptions stored in the editable `.studio.json` sidecar. Run from your AI coding agent.

Download them from inside the app: **Database → AI Skills…** — or from the prompt that appears when you open a database with more than 10 tables. Skills are installed next to your `.sqlite` file so any AI coding agent in that directory can use them.

For Codex, create `.agents/skills` in your repo first; the app will install `graph-clusters` and `schema-descriptions` there. Use `/skills` or mention `$graph-clusters` / `$schema-descriptions` in Codex to invoke them.

## Install

1. Go to [Releases](../../releases/latest)
2. Download `SQLiteGraphStudio.zip`
3. Unzip and drag `SQLiteGraphStudio.app` to `/Applications`
4. Open a `.sqlite` file with it

> **First launch:** macOS may block the app since it isn't notarized. If you see a "damaged" or Gatekeeper warning, run this once in Terminal:
>
> ```bash
> xattr -cr /Applications/SQLiteGraphStudio.app
> ```
>
> Then open the app normally. Alternatively:
> 1. Open **System Settings → Privacy & Security**
> 2. Scroll down and click **"Open Anyway"** next to the app name
> 3. Confirm in the dialog that appears

## Build from source

Requires Xcode 15+ or the Swift toolchain. Built in Swift/SwiftUI — not because it's the obvious choice for a database tool, but because it was the fastest way to build something native on macOS that felt good to use.

```bash
git clone https://github.com/Albertsteenstrup/SQLiteGraphStudio.git
cd SQLiteGraphStudio
swift run SQLiteGraphStudio /path/to/database.sqlite
```

## Reporting issues

Open a [GitHub Issue](../../issues) — include your macOS version and what you were doing when it broke.

## License

MIT — see [LICENSE](LICENSE).
