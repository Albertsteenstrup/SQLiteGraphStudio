# SQLite Graph Studio

Native macOS SQLite browser/editor with:

- a read-only foreign-key schema graph
- a dark table workspace with paged inspection and inline edits
- a local fixture generator and sample database

## Local workflow

```bash
./Fixtures/build_fixture.sh
./script/build_and_run.sh
```

Open a specific database directly from Terminal:

```bash
swift run SQLiteGraphStudio /absolute/path/to/database.sqlite
```

If you have a built app bundle, you can open a file with:

```bash
open -a /path/to/SQLiteGraphStudio.app /absolute/path/to/database.sqlite
```

For another user downloading the repo, the simplest flow is:

```bash
git clone <repo-url>
cd sql_gui
swift run SQLiteGraphStudio /absolute/path/to/database.sqlite
```

For another user downloading a release app, they can drag `SQLiteGraphStudio.app` to `/Applications` and run:

```bash
open -a /Applications/SQLiteGraphStudio.app /absolute/path/to/database.sqlite
```

## Targets

- `SQLiteGraphStudio`: the macOS app entrypoint
- `StudioCore`: shared app, database, graph, and table-editor logic
- `FixtureBuilder`: generates `Fixtures/sample.sqlite`
