# SQLite Graph Studio

A macOS app for browsing and editing SQLite databases. Open a file, explore the schema as an interactive graph, and edit rows directly in the table view.

![SQLite Graph Studio in use](docs/demo.gif)

<p>
  <a href="../../releases/latest">
    <img src="https://img.shields.io/github/v/release/albertsteenstrup/sql_gui?label=Download&style=for-the-badge" alt="Download latest release">
  </a>
</p>

> **No Xcode or Swift required.** Download the DMG, drag to Applications, open.

---

## Features

- Interactive schema graph showing foreign-key relationships and cardinality
- Inline row editing with right-click row actions (add, clone, delete)
- Column sorting, filtering, and search
- SQL query runner with explain plan
- Connection profiles for quick re-opening

## Install

1. Go to [Releases](../../releases/latest)
2. Download `SQLiteGraphStudio.dmg`
3. Open the DMG and drag `SQLiteGraphStudio.app` to `/Applications`
4. Open a `.sqlite` file with it

> **First launch:** macOS may show a warning for unsigned apps. If you see **"damaged and can't be opened"**, run this in Terminal:
> ```bash
> xattr -dr com.apple.quarantine /Applications/SQLiteGraphStudio.app
> ```
> Then open the app normally. This is a Gatekeeper warning — the app is not actually damaged.

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
