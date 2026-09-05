# PostgreSQL parity and large catalog verification

The PostgreSQL backend shares schema exploration, grouping, colours, local notes and stories with SQLite. PostgreSQL database mutation remains disabled. These changes are based on PostgreSQL checkpoint `29630b1` and were developed on `codex/postgres-parity-scale`.

## Large catalog behavior

The overview keeps every table discoverable. Explicit groups and colours win; uncovered tables receive deterministic schema, name-prefix and relationship groups. Inferred labels describe their mechanical basis and are not persisted as authored metadata.

Above 128 nodes, one shared layout path divides work into pieces of at most 64 nodes and applies up to 12 steps of the existing force solver. It retains node repulsion, relationship springs, cohesion and alignment. The bounded local solves skip edge-path repulsion. A hierarchy of card-size-aware rectangles separates pieces and groups, and a spatial obstacle index keeps unpinned cards clear of saved pins. Conflicting pins themselves remain fixed.

The overview uses lightweight drawing and aggregate group connections. Group and relationship scopes page at 48 tables. Search covers the entire catalog regardless of the current scope. Detailed SwiftUI cards are capped at 160; viewport culling and overview marks keep the remaining nodes represented without constructing all expanded views. This bounds layout and rendering work, rather than relying on users to zoom into a global all-pairs simulation.

## Release measurements

These are measured reset-plus-stabilization times on this Mac for one oversized authored group. They are layout timings, not frame-rate or total connection-time promises.

| Objects | Compact | All cards |
| --- | --- | --- |
| 585 | 0.414 s | 0.516 s |
| 1,000 | 0.855 s | 0.795 s |
| 2,000 | 1.259 s | 1.433 s |

The final complete release run passed 184 tests in 29 suites in 98.300 seconds, including the optimized layout suites. Coverage includes finite and complete positions, input-order determinism, group separation, real card-size non-overlap, pins, old-grid migration, restored snapshots, presentation switching, and bounded public stepping. Five of the original large-layout regressions were first observed failing against the PostgreSQL baseline.

## Live PostgreSQL evidence

The explicitly selected local PostgreSQL catalog contained 570 tables and 11 views, with 1,604 relationships and 41 inferred groups. Its shared compact layout took 0.294 seconds in the final rerun (0.142 seconds in the first run). The final opted-in integration test passed in 1.021 seconds and checked catalog completeness, trigger and CHECK counts against independent catalog reads, SELECT, non-executing EXPLAIN, transaction_read_only=on, and client rejection of CREATE. No database fixture was created or mutated. Credentials were read from the local development container into process memory; no credential file was saved.

The development app displayed the same 581 objects and 41 coloured groups. Group navigation, catalog-wide exact table search and expanded-card presentation were exercised against that connection. The visual check found a transient initial viewport fit, which is covered by the final camera repair and recheck below.

## Final checks

`swift test -c release --no-parallel` completed successfully: 184 tests across 29 suites, 98.300 seconds; release compilation completed successfully. The separately opted-in PostgreSQL integration passed against this exact release. The built app was reopened with saved PostgreSQL positions and now displayed the whole overview at a useful scale. Search, group focus and expanded-card presentation were visually checked.

A subsequent compact/expanded transition check exposed a fit using the previous pane dimensions. The same cancellable viewport fitting now handles presentation changes; all eight focused initial/presentation viewport tests passed after an observed regression failure. The native tool could operate accessibility controls, but coordinate clicks reported `noWindowsAvailable`; pointer-only interaction was not established by this UI run.

A previous parallel debug run exposed a SQLite tooltip regression and also starved an asynchronous query deadline behind long MainActor layout tests. The tooltip repair passed its original failing test plus PostgreSQL ambiguity safeguards; all 28 focused session/metadata tests passed using sequential Swift Testing execution.

This checkpoint covers parity and bounded layout. The user's additional request to reduce canvas interaction latency is being implemented and verified separately.
