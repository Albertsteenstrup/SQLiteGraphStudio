# Query, export, browsing and release hygiene implementation plan

> For agentic workers: use Superpowers subagent-driven-development and test-driven-development. Preserve other worktrees; commits belong only to codex/query-export-hygiene.

**Goal:** Repair the seven findings in the supplied request while preserving SQLite editing and PostgreSQL read-only enforcement.

**Architecture:** Positional result columns and a shared lossless serializer serve both backends. Query operations have explicit lifetime, bounded fetching and cancellation. Table browsing and streaming exports share typed predicates and stable ordering, with snapshot consistency and honest count states. Metadata failures retain the last valid state only for the same document.

**Tech stack:** Swift 6.3, SwiftUI/AppKit, GRDB, PostgresNIO, Swift Testing, shell/Python packaging verification.

**Verified base:** 29630b191062a6d0d5dfacfd55b26140591c7bb7. At baseline verification, main f0b2266 was SQLite-only. Existing isolated worktree: /Users/albertsteenstrup/.codex/worktrees/18b7/sql_gui.

## Execution and evidence checklist

- [x] Baseline: run `swift test --parallel --num-workers 1`; record full result. Owned PostgreSQL fixture lives under /tmp, never an external dataset.
- [x] Identity: reproduce `SELECT 1 AS id, 2 AS id` in SQLite and PostgreSQL. Test three colliding names (`id`, `id`, `id_2`), values and JSON. Change SQLiteModels, both backend readers, shared serialization and QueryWorkspaceView. Use positional IDs; retain header names independently. Read all copy and tooltip consumers.
- [x] Query lifecycle: reproduce unbounded server work with a limited query and `pg_sleep`; test cancellation and reuse. Modify QueryWorkspaceModel, DatabaseServiceFacade and backend execution. Add Stop, timeout, cancellation on rerun/close/reset/database change; reject superseded results.
- [x] Browsing: reproduce repeated counts and contains-only predicates. Add typed equality/order/range/NULL predicates shared by both backends; validate columns and values. Add explicit unknown/exact counts, exact-count action and stable paging with key tie-breakers; make keyless limitations visible. Cover composite keys, duplicate sorts and filter changes.
- [x] Exports: reproduce loaded page only. Add loaded/all-matching scopes, progress/cancellation, exact value and NULL serialization. Stream all matching rows within one read snapshot; write temporary sibling and publish atomically only on success. Test more than one page, filters/order, cancellation and failure cleanup.
- [x] Metadata: reproduce malformed file returning empty. Add absent/removed/unreadable/malformed/unsupported state and stale table/column diagnostics. Retain same-document last good state, clear on switching. Test deletion, failure/recovery and compatible descriptions/clusters/stories.
- [x] UI/gating: hide PostgreSQL write controls; keep backend guards and SQLite actions. Replace silent integration guard with explicit skip plus throwing configuration parsing for opted-in runs. Test missing/invalid fields including TLS, and document invocation.
- [x] Packaging: reproduce bundle/version mismatch. Centralize metadata, preserve existing preferences, configure signing and notarization; validate scripts/plists locally. No install/publish/distribution.
- [x] Integrate committed parity checkpoint; adapt shared consumers and record interface checkpoint for record-explorer task.
- [ ] Final review for spec coverage, then code quality; resolve findings, run full suite and owned PostgreSQL integration, verify app flows. Commit branch without push or merge. Record base/head and each finding's evidence or precise blocker.

Each implementation follows: add focused regression, observe the expected failure, implement, run green, inspect consumers, review and commit checkpoint. Logs and fixture databases stay in /tmp, not Git.

Committed parity checkpoint `8a8fdc4` was integrated as `e23c8ac`; record-specific features were excluded. Final status and evidence: [verification](../../query-export-verification.md).
