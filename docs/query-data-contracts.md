# Query and data contracts

Implementation and verification checklist: [plan](superpowers/plans/2026-09-05-query-export-hygiene.md).

## Shared interfaces

- Query columns have stable zero-based positional IDs. Names remain display labels and may repeat. QueryResult normalizes incoming column positions. A column's values are always read positionally.
- QueryDocument.executedSQL records the SQL for the displayed result, independently of subsequent editor changes. A query snapshot alone does not prove a table or editable row origin.
- JSON object keys reserve every original column name. The first occurrence keeps its name; subsequent occurrences try `_2`, `_3`, and so on, skipping both original names and already allocated names. Thus `id, id, id_2` maps to `id, id_3, id_2`. CSV retains the original headers.
- Exact numeric values remain decimal strings in JSON. SQL NULL is JSON null. Text, JSON-typed data and arrays retain their exact textual values; exports do not parse and re-encode embedded JSON.
- CSV uses unquoted `\N` for SQL NULL and quoted `"\N"` for literal text of that value. Import also accepts legacy unquoted `NULL`; literal `NULL` and whitespace-only text are quoted on export and retained as text on import. Empty text is quoted `""`; embedded delimiters, quotes and newlines follow standard CSV quoting. JSON string values are never treated as SQL NULL. Binary values are base64. PostgreSQL numeric scale and NaN/Infinity signs are preserved; money decoding uses the server locale’s fractional scale.
- Loaded export means only the current loaded chunk, with its displayed ordering. All matching export reads the current filters and ordering from one consistent read snapshot, ignoring the page offset. Query export means the already executed result; a truncated result must be labelled with its retained row count and cap.
- A streaming export writes a temporary sibling file. The captured database target is checked before backend acquisition, including across save-panel delays. The destination is replaced atomically only after all rows finish and cancellation is checked. Failure or cancellation removes the temporary file and preserves any previous destination.

These are coordinated changes for the record-explorer task; integration must use a committed checkpoint before adopting them.

## Query lifetime

The PostgreSQL lexical policy rejects known side-effect functions even when their names are quoted or schema-qualified. Escape strings use PostgreSQL's `E'...'` rules; ordinary strings use `standard_conforming_strings=on` on each connection. Unicode-escaped identifiers are rejected with an explanation; ordinary quoted identifiers remain supported. Read-only transactions and the connection role remain the database mutation boundary.

`executeReadOnlyQuery(sql:rowLimit:timeoutSeconds:)` and `explainQueryPlan(sql:timeoutSeconds:)` are asynchronous on both backends (default timeout 30 seconds). PostgreSQL SELECT/WITH/VALUES use a server cursor and fetch only the requested cap plus one sentinel without modifying the original statement. Stop cancels the task, discards only its active PostgreSQL connection, and waits for physical closure before releasing the lease. The pool then replaces it. Shared `PostgresDatabaseBackend.querySequence` initiates requests on the connection event loop, preventing a close between its liveness check and driver registration; backend extensions must use this helper instead of calling `connection.query` directly. Error rollback and late cancellation use the same closure guarantee. SQLite uses GRDB's cancellable asynchronous read. PostgreSQL 14+ detects disconnected clients during long server work. A blocking sort/aggregate may still do server work before producing the first row; the execution deadline remains in force.

Query workspace requests have identities. Run, Stop, closing/resetting a query, and database switching invalidate older requests. An old completion cannot publish into a newer request. Database open/close operations also have generations and ordered close completion.

## Browsing

`ColumnFilter` adds `comparison` and optional `upperValue`; `.contains` remains explicit literal text search. Typed filters bind values and validate column names, integer/decimal/boolean input. NULL filters need no value. PostgreSQL enums, arrays and money use bound operands cast to validated database types. Comparison casts remove storage length/precision modifiers to avoid truncating or rounding the search value; quoted type names remain intact. Numeric and floating-point special values remain valid PostgreSQL operands. `TableQueryState` carries an optional `after` cursor, a cached exact count and an explicit exact-count request.

`TableChunk.countState` is unknown, a lower bound, or an exact result from the last count. `hasMore` is separate navigation evidence from a sentinel row, so an old cached count cannot force another page after EOF. PostgreSQL catalog counts are estimates and display an approximation mark. Exact counting is a separate action; pages reuse compatible count evidence and invalidate it when filters or local data change.

Reliable primary/unique keys break sort ties. Nullable, partial or incomplete expression-index keys cannot establish unique identity. Forward pages use lexicographic cursors, including composite keys and NULLS LAST. Tables/views without reliable keys use offset pages and show the concurrent-change caveat. Pages read live data; updates to sort/key values can move rows. Use all-matching export for one consistent snapshot. Grid callbacks and `TableTabModel.row(at:)` retain **absolute row indices**; a viewport request accompanies explicit page navigation.

SQLite cursor parameters retain each stored value's type; declared column affinity does not re-parse page keys. Typed user filter validation remains separate from cursor binding.

## Metadata

`SchemaSidecarStore.load(for:)` now throws unreadable, malformed and unsupported-version errors. `SchemaMetadataState` distinguishes absent, loaded, intentionally removed and failed states. Invalid files retain the last good annotations only for the same document. Deleting the sidecar clears annotations; switching documents clears prior state. Stale table/column/cluster/story references produce visible diagnostics. Duplicate story/cluster IDs are rejected before graph consumers can construct keyed dictionaries.

PostgreSQL uses the user-selected local connection document as the sidecar anchor. Refresh preserves that URL. These local annotations do not change the remote database.
