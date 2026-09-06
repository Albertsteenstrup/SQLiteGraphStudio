# Record exploration verification

The record feature is implemented on `codex/record-inspection-graph`, based on the committed PostgreSQL checkpoint `29630b191062a6d0d5dfacfd55b26140591c7bb7`. This is an isolated worktree. No push or merge to main is part of this task.

## Integrated checkpoints

- `643b981`: generic record access, inspector, navigation, record graph and sidecar mappings.
- `778aa12`: parity owner checkpoint `8a8fdc4`, including PostgreSQL metadata, grouping, colours and bounded large schema layout.
- `9222b42`: SQLite FK spelling, affinity/collation and real cancellation, plus structured PostgreSQL catalog identity.
- `e04b399`: fixes owner checkpoint `6088fc3`, including positional query columns, saved executed SQL, cancellation, paging/filtering, export and metadata lifecycle.
- `d0d6621`: fixes owner packaging checkpoint `8131f39`; fixture isolation `6c8010e` was integrated earlier as `312787d`.
- `cf2f153`: numeric specials, finite decimal scale, exact locale-aware money and qualified record labels.
- `e9a8bf4`: fixes owner follow-up `83c7601`, including native grid verification, explicit count assertions, safe file-panel filtering and snapshot-export regressions. Its export-target prerequisite was recovered from the owner's committed parity-integration resolution `e23c8ac`; those guards are included in the final record commit.

The subsequently completed canvas performance checkpoint `eb1e4b2` was integrated as `0451837`, preserving per-fixture UUID isolation and the record hooks. Later uncommitted fixes remain outside the integration boundary.

## Automated evidence

The initial shared baseline had 113 tests and 29 issues caused by colliding temporary fixture filenames across worktrees. Fixture isolation was integrated before feature validation. Partial or interrupted runs are not counted as passing.

Focused regression tests cover complete composite keys, qualified identities, expression/partial index rejection, SQLite rowid shadowing, duplicate query labels, NULL/missing/inaccessible targets, composite FK affinity and collation, multiple relationships, cycles, shared branches, bounded continuation, mapping validation/scope, stale responses, navigation, cancellation and database lifecycle. End-to-end model tests exercise table inspection through relationship navigation, back, graph expansion and database reset, plus immutable executed-query provenance.

The first complete integrated run finished 263 Swift Testing cases and 13 XCTest cases. Three older assertions required adaptation: two assumed automatic exact table counts, and one applied the large-layout non-overlap contract to a 25-node force-layout fixture. The fixes owner supplied the count adapters; the layout assertion now applies above the existing overview threshold.

The final review repair run passed 45 tests in 8 suites against SQLite and the owned PostgreSQL fixture. It includes exact UUID/array/temporal/numeric/money values, PostgreSQL FK round trips, catalog labels, and bounded/cancellable JSON formatting. The cancellation regression first reproduced an approximately 18-second SQLite backend hold; the repaired async read test completed in approximately 0.125 seconds.

Packaging verification passed 9 tests plus the preference migration harness. No Developer ID signing, notarization or distribution is claimed.

A subsequent repeat stalled and was terminated; it is not passing evidence. A single-test-at-a-time helper run localized the stall to repeated early PostgreSQL cancellation. The cancellation owner is repairing the race; final full-suite results remain pending below.

An additional owned-fixture regression reproduced false FK matches when target varchar, char, numeric or timestamp type modifiers truncated or rounded lookup parameters. Lookup casts now preserve values without reapplying the target column's modifiers; valid-reference controls remain part of the test.

The reviewed record checkpoint passed 71 Swift Testing cases in 14 suites with serial execution (6.417 seconds), including all record tests, owned PostgreSQL value/relationship tests, native grid tests and new canvas interaction tests. The same group's frame-timing tests were affected by concurrent fixture setup; the serial control passed all cases. The separate XCTest workflow run passed 13 tests (0.099 seconds) after canvas integration. The integrated remainder suite passed 312 Swift Testing cases in 55 suites (133.601 seconds), with only `repeatedEarlyCancellationLeavesPoolReusable` explicitly excluded. That full-suite early-cancellation blocker remains open pending the owner's repair.

## Fixture ownership and repeatability

Final integration review reproduced and repaired incoming mixed-base-type FK failures, traditional inheritance identity/relationship scope (seven failing assertions before repair), and bit-array comparison/decoding. The live controls cover nonmatching numeric and narrow integer references, valid reverse navigation, inherited duplicate keys, descendant-only rows, partitioned roots, exact non-byte-aligned bit values and bit arrays. The resulting focused run passed 28 tests in 4 suites (0.135 seconds). The bit-array fixture uses a catalog-declared `NOT VALID` legacy FK because PostgreSQL 17's own bit-array FK insertion trigger rejects its `anyarray` comparison; application lookup comparisons are exercised directly.

All PostgreSQL writes were confined to a newly created task-owned PostgreSQL 17 container, `sgs-record-b96d`, database `record_fixture`. Tests connected as `record_reader`, with SELECT grants and default read-only transactions. Existing external databases and other tasks' containers were not restored or modified.

The committed `Tests/Fixtures/record-postgres*.sql` scripts build the generic fixture and supplemental typed-value/query cases. Run them only in a fresh disposable database. The record integration tests opt in with `SGS_RECORD_POSTGRES_PORT`; the integrated query tests use `SGS_POSTGRES_TESTS=1`, complete `SGS_POSTGRES_*` connection settings, and `SGS_POSTGRES_FIXTURE_TESTS=1` for the supplemental `public.items` fixture. Ordinary runs explicitly skip live tests.

## Actual application inspection

An app bundle built from this worktree was launched under the isolated preview bundle identifier `com.albertsteenstrup.recordinspection.b96d`, opening the disposable SQLite fixture. Accessibility actions verified query execution, row inspection, return to unchanged query context, table opening through the schema context menu, table-row inspection, outgoing composite-FK navigation, back, Show connections, graph expansion and selecting the related graph node into the same inspector. Screenshots showed the actual native inspector and graph.

The computer-use host intermittently returned `noWindowsAvailable` or `elementHasNoFrame`. Coordinate clicks and the picker row selection were unavailable through that tool; accessibility context menus and keyboard query entry provided working alternatives. This is separate from the automated model/backend evidence. The final integrated preview additionally verified saved-query provenance (Ada with complete tenant/code key), distinct empty-text display, bounded 25-edge incoming expansion with continuation, and exact graph-node selection. A high-degree screenshot motivated suppressing edge text below readable zoom and adding locator text to cards. Drag/pinch interaction and complete PostgreSQL UI click-through are not claimed from those checks.

## Limits

Exploration is bounded and observes live pages rather than a cross-request database snapshot. Caps and continuation are explicit. PostgreSQL data access remains read-only; SQLite editing remains in its existing table surface. Query identity is enabled only for narrowly proven single-object `SELECT *` results. Large/deep JSON falls back to its raw value while retaining full reading/copy. Invalid mappings are reported; changing validated mapping definitions cancels and clears the previous exploration.
