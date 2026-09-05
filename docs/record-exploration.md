# Inspecting records and their connections

Right-click a loaded table or query row and choose **Inspect Record…**. The inspector shows its table, a readable label, complete unique locator when available, column types and descriptions. NULL and empty text have distinct presentations. **Read full value** opens native selectable text; **Format JSON** adjusts whitespace without rounding numeric literals. JSON formatting falls back to raw text for invalid input or input above 2 MiB, formatted output above 8 MiB, or nesting beyond 128 levels; full-value reading and copying remain available. **Copy exact value** copies raw text; binary values use lowercase hexadecimal, and SQL NULL copies the literal `NULL`.

The inspector is a separate exploration sheet. Its originating table or query stays mounted with its filters, scroll position and selection. Back and forward move through visited snapshots. Back from the first record or **Return to origin** dismisses the sheet. The toolbar **Records** button reopens the exploration. Changing validated graph mappings clears previous exploration so an old scope cannot survive a reload. Database open, switch, refresh or close clears the record exploration and invalidates pending responses.

## Relationship navigation

Outgoing foreign keys and incoming references show the complete column tuple, including composite keys. **Browse records** reads a bounded page; **Load more** and **Previous page** navigate related rows. Multiple foreign keys between the same tables remain separate. NULL references, missing targets, inaccessible tables and query errors have distinct outcomes.

Records with no proven locator remain inspectable. Values are never treated as an identity merely because a column is named `id`. Stable identity requires a complete non-null primary/unique tuple or a proven SQLite rowid. Expression/partial indexes do not prove uniqueness. Views and ambiguous query results remain snapshots. Query navigation accepts only a proven `SELECT * FROM` one exact catalog object (optionally with a numeric `LIMIT`), using the saved SQL that produced the displayed result. Editing the query afterward does not change that origin; joins, computed projections and other shapes remain inspectable snapshots. Relationship queries bind values and quote identifiers; they perform no writes.

Query provenance is intentionally conservative: navigation is permitted only when the immutable SQL that produced the result is a direct `SELECT * FROM` one catalog table, optionally followed by a literal LIMIT, and the result columns match the full descriptor. Other results remain inspectable snapshots, including joins, computed projections and unproven origins.

## Record graph

**Show connections** creates a record graph rooted at the inspected record. It is independent of the schema graph and uses the shared layout engine. Expand individual incoming/outgoing relationships from the inspector. Click a node to inspect it; use its context menu to select a new root. Drag nodes or the canvas, pinch to zoom, and use **Fit** to frame the exploration. Branch controls collapse contributions and load another page. Shared nodes, parallel relationships, cycles and self-links retain their identities.

The graph shows explored relationships, not an exhaustive database scan. Limits are 100 nodes, 250 edges, depth 4, 120 data-query reservations per root, and 2 concurrent requests. FK pages contain at most 25 records; mapped pages contain at most 5 edges and reserve 7 queries. Caps and additional pages remain visible. Collapse branches or select a new root to continue. Requests are cancellable; stale completions cannot replace a newer inspector. PostgreSQL record SELECTs also have a 5-second transaction-local statement timeout. Transaction setup and the constant PostgreSQL money-scale metadata probe are separate from data-query reservations. Offset pages are live reads, not a cross-request database snapshot; concurrent database changes can shift page membership.

## Explicit graph-data mappings

When a database explicitly stores graph nodes and edges, add `recordGraphMappings` to its existing `.studio.json` sidecar. SQLite sidecars sit next to the database; PostgreSQL sidecars sit next to the connection document. This example describes generic tables `vertices` and `arcs` with a composite node key `(scope, key)`:

```json
{
  "version": 1,
  "recordGraphMappings": [
    {
      "id": "example-network",
      "name": "Example network",
      "nodeTable": { "objectName": "vertices" },
      "nodeIDColumns": ["scope", "key"],
      "labelColumn": "title",
      "edgeTable": { "objectName": "arcs" },
      "sourceColumns": ["scope", "from_key"],
      "targetColumns": ["scope", "to_key"],
      "typeColumn": "kind",
      "isDirected": true,
      "nodeScope": [
        { "column": "scope", "value": { "type": "text", "value": "example" } }
      ],
      "edgeScope": [
        { "column": "scope", "value": { "type": "text", "value": "example" } }
      ]
    }
  ]
}
```

For PostgreSQL add `"schemaName": "your_schema"` inside each table object. All names are matched against the catalog, never guessed from naming conventions. Node ID columns must form a complete proven unique tuple. Edge records need their own stable locator so repeated endpoints retain distinct edges. Optional label/type columns and all scope columns are validated. Filter types include `null`, `integer`, `double`, `boolean`, `text`, `exactNumeric`, `uuid`, `dateTime`, `json`, `array`, and `blob` (base64 JSON payload). Use textual `exactNumeric` to preserve decimal precision.

Reload the sidecar via **Relayout** or refresh/reopen the database. Valid mappings appear in the inspector for their node table. Invalid mappings show validation messages. Both source and target connection lists are available; set `isDirected` to false for undirected edges. Scopes apply to the anchor node, edge rows and related nodes. Null/missing/inaccessible/out-of-scope endpoints never become fabricated graph nodes.
