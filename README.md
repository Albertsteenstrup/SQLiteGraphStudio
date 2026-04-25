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

## Install

1. Go to [Releases](../../releases/latest)
2. Download `SQLiteGraphStudio.zip`
3. Unzip and drag `SQLiteGraphStudio.app` to `/Applications`
4. Open a `.sqlite` file with it

> **First launch:** macOS may block the app since it isn't notarized. If you see a Gatekeeper warning:
> 1. Open **System Settings → Privacy & Security**
> 2. Scroll down and click **"Open Anyway"** next to the app name
> 3. Confirm in the dialog that appears
>
> You only need to do this once.

## Build from source

Requires Xcode 15+ or the Swift toolchain. Built in Swift/SwiftUI — not because it's the obvious choice for a database tool, but because it was the fastest way to build something native on macOS that felt good to use.

```bash
git clone https://github.com/albertsteenstrup/sql_gui.git
cd sql_gui
swift run SQLiteGraphStudio /path/to/database.sqlite
```

## Reporting issues

Open a [GitHub Issue](../../issues) — include your macOS version and what you were doing when it broke.

## License

MIT — see [LICENSE](LICENSE).
