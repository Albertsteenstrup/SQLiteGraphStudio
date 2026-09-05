# PostgreSQL parity and large schema implementation plan

**Goal:** Give PostgreSQL the same local schema exploration features as SQLite while preserving all PostgreSQL database write restrictions, and make schemas with 500 or more tables practical to navigate.

**Architecture:** Both backends continue through `DatabaseService`, `AppSession`, `SchemaGraph`, `GraphLayoutModel`, and `SchemaGraphView`. Sidecars belong to the opened file: `<database>.sqlite.studio.json` or `<connection>.postgres.studio.json` (also `.pgstudio`). Local metadata and database mutation capabilities are separate. Large schemas use the existing force solver within bounded neighbourhoods, then pack those neighbourhoods into separated group regions. Search, group focus and progressive rendering expose detail without requiring hundreds of simultaneous expanded views.

**Base:** Existing PostgreSQL worktree commit `29630b1`, isolated branch `codex/postgres-parity-scale`.

**Tech stack:** Swift 6.3, SwiftUI/AppKit, Swift Testing, GRDB, PostgresNIO.

## Design choices

- Restoring unconstrained all-pairs physics would retain familiar motion but multiply pair and edge-path work at 500–2,000 tables. The existing global grid is fast but loses group separation and overlaps in card mode. A shared bounded force solver within a hierarchy retains relationship placement and supports predictable work bounds.
- Explicit sidecar groups, labels and colours take precedence. Unassigned tables receive deterministic, clearly mechanical groups derived from schema/name/topology. These are computed locally and never written into the database or silently persisted as authored metadata.
- Keep every table reachable. The overview is for orientation; group focus, exact table search and relationship focus are for reading. Low zoom uses lightweight drawing, while detailed views are limited to the visible viewport.
- Preserve original positions when changing focus and preserve database read-only enforcement at the service, SQL policy and PostgreSQL transaction layers.

## Work and ownership

- [x] Metadata parity: `AppSession`, `DatabaseCapabilities`, `StudioRootView`, `StudioSkills`, packaged skill text. Retain connection document URL separately from the connection identity; load/reload/save sidecars beside that document; enable local skills, stories, tooltips, and recent documents. Test reconnect/reload, local story deletion, canonical PostgreSQL table IDs, and every write capability remaining false.
- [x] Shared grouping model: new `GraphGrouping.swift` and focused tests. Resolve explicit groups first, cover all remaining IDs exactly once, assign stable labels/colours independent of node input order, avoid ambiguous unqualified PostgreSQL names, and bound inferred group sizes. Test 585/1,000/2,000 nodes, disconnected and dense graphs, partial hints, and oversized authored groups.
- [x] Shared layout: `GraphLayoutModel`, a focused large layout helper, and layout tests. Apply bounded local force work plus non-overlapping group packing in both compact and all-card modes. Keep positions finite, complete, deterministic, compatible with drag/pin/restore, and card-size aware. Test 585/1,000/2,000 nodes, cross-group edges, giant groups and the compact-to-all-cards transition.
- [x] Read feature audit: `PostgresDatabaseBackend`, `PostgresSQLSupport`, `QueryWorkspaceModel` and focused tests. Match available schema metadata and SQL identifier handling without introducing writes or per-table catalog query loops. Verify constraints, triggers, quoting and bounded catalog loading.
- [x] Navigation/rendering integration: `SchemaGraphView` plus testable presentation helpers. Add group selection and table search with explicit visible/total counts; preserve the overview camera on return; draw inexpensive overview marks at low zoom; cull offscreen detailed cards and unnecessary edges. Use the same resolved groups in colours, titles and layout.
- [x] Canvas interaction follow-up: reuse topology and scene geometry, bound row preparation, use spatial pointer hits that match visible cards/marks, retain active drags and publish the latest camera/pointer sample without starving continuous gestures. Batch minimap drawing. Measure 581 and 2,000 tables separately from rendering frame rate.
- [x] Review and verify: independent spec review followed by code quality review; repair actionable findings. Run focused tests and the complete release suite with sequential Swift Testing (`swift test -c release --no-parallel`) to prevent CPU-heavy MainActor layout tests from starving unrelated asynchronous query deadlines. Build the app, exercise the real UI and run PostgreSQL integration when a current local endpoint is available. Record full results and limitations.

## Acceptance evidence

PostgreSQL must expose local groups/colours/notes/stories while all DB write capabilities remain false. Every input node must remain discoverable at 2,000 tables. Expanded large-schema cards must not overlap after layout. Performance measurements must name dataset size and operation and must cover the real shared path. A skipped environment-gated integration test is not live database proof.
