# Record exploration implementation plan

> Execute with Superpowers subagent-driven-development and focused test-first increments.

**Goal:** Complete generic record inspection, relationship navigation and bounded record graph for SQLite and PostgreSQL.
**Architecture:** Additive Records module over the existing database facade, native modal inspector preserving its origin, and separate record graph state reusing graph layout/geometry.
**Tech Stack:** Swift 6, SwiftUI/AppKit, GRDB, PostgresNIO, XCTest.

- [x] Verify PostgreSQL checkpoint and isolated branch; coordinate shared contracts with parity/fix owners.
- [ ] Establish baseline (`swift test --parallel --num-workers 1`).
- [ ] RecordModels/RecordAccess and additive backend SELECT methods: first add real fixture tests, run red, implement identity validation, composite FK grouping and bounded binding plans, run green.
- [ ] RecordWorkspace: test navigation, stale completion, database invalidation and bounded pages before implementing observable state and async request lifecycle.
- [ ] RecordGraphModel: test cycles, shared branches, distinct edges, limits and continuation before implementing root/expand/collapse state.
- [ ] RecordMapping: test catalog validation, explicit edge direction and scope binding before implementing sidecar JSON mapping and mapped connections.
- [ ] RecordInspectorView/RecordGraphView: native full-value presentation, raw copy, async JSON formatting, relationship pages, shared graph layout/viewport and root/branch controls.
- [ ] Add row inspection callbacks to table/query grids and Records presentation to AppSession/StudioRootView. Retain originating views and invalidate immediately on open/close.
- [ ] Integrate committed parity and fix checkpoints; resolve only integration conflicts within approved scope.
- [ ] Verify focused tests and full suite, owned PostgreSQL fixture, SQLite editing and PostgreSQL mutation boundaries. Build exact worktree app and inspect actual UI.
- [ ] Independent spec review then quality review; correct findings, update README and validation notes, commit feature branch. Do not push or merge main.
