# PostgreSQL parity and large catalog verification

PostgreSQL shares schema exploration, grouping, colours, local notes, stories and AI skills with SQLite. PostgreSQL database mutation remains disabled. The work is based on PostgreSQL checkpoint `29630b1` on `codex/postgres-parity-scale`.

## Large catalog behavior

Explicit sidecar groups and colours take precedence. Uncovered tables receive deterministic schema, name-prefix and relationship groups. Inferred labels describe their mechanical basis and are not persisted as authored metadata.

Above 128 nodes, the shared layout divides work into pieces of at most 64 nodes and applies up to 12 steps of the existing force solver. It retains node repulsion, relationship springs, cohesion and alignment; bounded local solves skip edge-path repulsion. Card-size-aware region packing separates pieces and groups. A spatial obstacle index keeps unpinned cards clear of saved pins; conflicting pins remain fixed.

Every table stays discoverable through catalog-wide search. Group and relationship scopes page at 48 tables. Zoomed-out views draw table marks and aggregate group connections. Detailed SwiftUI cards are capped at 160, including select-all, and offscreen cards are culled.

## Interaction work

- Relationship ordering, group connections and highlights are cached by catalog/group revisions. Camera changes reuse graph-coordinate bounds and group centres.
- Only visible detailed cards prepare column rows. Expanded cards prepare at most seven visible rows each; markers and offscreen endpoints use rectangle anchors without reading columns.
- Spatial pointer lookup respects visual layers, then z-index and table order. Markers cannot capture scrolling through invisible rows. Active dragged cards remain mounted outside the viewport.
- Pointer samples publish at most once per 16 ms interval; shared camera samples use 32 ms. Continuous input never postpones pending delivery. Wheel and magnification events refresh their own pointer position synchronously before routing. Completed gestures flush the final camera, including outside the viewport.
- The minimap combines schema drawing into one relationship stroke and one table fill: 2,185 submissions become two for the live catalog, excluding its viewport overlay.
- Marquee selection uses scoped rectangles and preserves its primary table. Unchanged selections do not publish another update.
- Magnification uses the same 0.005 minimum as large-overview fitting and preserves the pointer anchor. Ordinary graph zoom limits remain unchanged.

## Final verification

`swift test -c release --no-parallel` passed **224 tests across 33 suites in 51.185 seconds**. Release compilation completed in 190.16 seconds with no warnings or errors. `git diff --check` passed. Tests run sequentially so expensive MainActor layout tests do not starve unrelated asynchronous query deadlines.

Coverage includes SQLite editing, local PostgreSQL metadata, canonical/ambiguous table references, all database write restrictions, complete and finite layouts, deterministic groups, card non-overlap, saved pins, old-grid migration, restored cameras, eight initial/presentation viewport cases, row anchors, culling, detail priorities, spatial hits and publisher cancellation/flush/continuous delivery. Primary-detail and large-overview zoom regressions were observed failing before their repairs. The old zoom algorithm jumped from 0.008 to 0.12 and shifted the pointer anchor; all three added magnification tests now pass.

Independent subagent review covered the parity implementation and the cache, hit-testing and publication design. Final input corrections were reviewed and included in the complete release checks.

## Live PostgreSQL and app evidence

The explicitly selected local catalog contained **570 tables and 11 views**, **1,604 relationships** and **41 groups**. Its final shared compact layout took **0.218 seconds**. The separately opted-in read-only integration run passed in **1.123 seconds**, checking catalog completeness, trigger and CHECK counts against independent reads, SELECT, non-executing EXPLAIN, `transaction_read_only=on` and client rejection of CREATE. No database fixture was created or mutated. Credentials stayed in process memory.

The final isolated app is `dist/SQLiteGraphStudioParity.app` in this worktree. It displayed the same catalog and colours. Saved positions reopened with the complete overview visible; catalog-wide search, group focus, expanded table details, compact/expanded overview switching and return to all groups were checked. Switching presentation fitted the new pane size correctly. No other installed app was replaced.

Native accessibility controls and screenshots worked. Wheel input reached an earlier build, but subsequent pointer actions repeatedly returned `noWindowsAvailable`, including after refreshing bindings and raising the window. The final native column-scroll, drag and pinch paths therefore remain unverified by this automation session. Geometry, publication ordering and zoom behavior have automated coverage; no displayed frame-rate claim is made.

## Release layout measurements

These are final-run reset-plus-stabilization observations on this Mac for one oversized authored group, not total connection-time promises.

| Objects | Compact | All cards |
| --- | --- | --- |
| 585 | 0.326 s | 0.353 s |
| 1,000 | 0.714 s | 0.592 s |
| 2,000 | 1.300 s | 1.485 s |

## Canvas preparation measurements

The focused release run passed 33 exploration, interaction geometry and performance tests. Its fixture has 12–36 columns per object and approximately four foreign keys per object: 2,310 edges at 581 objects, 7,957 at 2,000. Each scenario records 32 samples after eight warmups. CPU preparation excludes SwiftUI/AppKit drawing and native event latency.

| Objects and presentation | Detail pan/zoom, median / p95 | Select-all overview, median / p95 | Hover plus full frame regeneration, median / p95 |
| --- | --- | --- | --- |
| 581 compact | 0.082 / 0.100 ms | 0.504 / 0.520 ms | 0.265 / 0.278 ms |
| 581 all cards | 0.121 / 0.152 ms | 0.674 / 0.708 ms | 0.291 / 0.340 ms |
| 2,000 compact | 0.214 / 0.367 ms | 1.980 / 2.695 ms | 1.026 / 1.360 ms |
| 2,000 all cards | 0.250 / 0.322 ms | 2.776 / 7.840 ms | 1.176 / 1.904 ms |

The initial select-all medians at 2,000 objects were 20.6 ms compact and 24.1 ms all cards. Ranking now calculates visibility, priority and distance once per candidate, then performs one sort with scalar comparisons. The observed medians became 1.98 and 2.78 ms. Other work was active on the Mac, so this is diagnostic evidence rather than a controlled speedup ratio. Ordinary unselected overview medians were 1.38–1.54 ms, with p95 values of 2.54–6.94 ms.

Full hover-driven world-frame regeneration had medians of 0.79–0.84 ms at 2,000 objects. Card sizing uses inexpensive character-count arithmetic, so another size-cache layer was unnecessary for these measured cases. Pointer lookup batch-mean p95 was 3.19 microseconds; hits matched a brute-force reference. A burst test coalesced 768 samples into 12 scheduled publications while preserving the latest sample.

The [raw observations](benchmarks/canvas-2026-09-05.json) retain the before/after measurements and subsequent final full-suite run. Reproduce the operations with `swift test -c release --no-parallel --filter GraphCanvasPerformanceTests`.
