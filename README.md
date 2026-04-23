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

## Targets

- `SQLiteGraphStudio`: the macOS app entrypoint
- `StudioCore`: shared app, database, graph, and table-editor logic
- `FixtureBuilder`: generates `Fixtures/sample.sqlite`
