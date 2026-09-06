# Combined main integration verification

The PostgreSQL parity, large canvas, query/export and record exploration work was integrated against fetched `origin/main` at `f0b2266`. The combined record checkpoint is `a5535ce`, with its verification documentation at `d486afb`. `d84f27c` contains the initial final review repairs below; the later hygiene integration is recorded at the end. Verification completed on 2026-09-06.

## Included behavior

- PostgreSQL remains read-only and shares SQLite's local groups, colours, descriptions, stories, skills and schema graph engine.
- Large schemas use bounded layout work, catalog-wide search, paged group/relationship focus, overview marks, at most 160 detailed cards, cached geometry and coalesced input. Synthetic coverage reaches 2,000 tables.
- Queries preserve positional columns and executed SQL, support cancellation and deadlines, and export loaded or all-matching rows with snapshot and atomic-file guarantees. Asynchronous file dialogs retain their captured database scope.
- Record inspection supports complete values, relationship navigation, bounded record graphs and validated mappings. Mixed key types, traditional inheritance, declarative partitions and exact PostgreSQL values have fixture coverage.

See the [schema/canvas evidence](postgres-parity-scale-verification.md), [query contracts](query-data-contracts.md), [record evidence](record-exploration-verification.md) and [packaging guide](packaging.md) for the individual contracts.

## Repairs found during integration review

Three independent review agents inspected the implementation and its callers before publication. Verified findings were repaired and reviewed again:

- CSV/JSON imports retain SQL NULL, literal `NULL` and `\N`, empty text, whitespace and CRLF. SQLite paging binds the actual stored type instead of reparsing declared affinity.
- Native table grids refresh on tab identity changes even when per-tab revision counters match; displayed values and record inspection therefore refer to the same table.
- Reloading an existing story advances metadata cache revisions without changing table positions, pins, camera or selection.
- The PostgreSQL policy recognizes quoted/qualified side-effect functions, escape strings, newline continuations and CR/CRLF comments. Connections and read transactions enforce standard-conforming strings. Unicode-escaped identifiers are rejected explicitly; ordinary quoted identifiers remain supported.
- Incoming mixed-type foreign keys compare through the original parent type. Wide legacy integer references return missing results instead of overflowing narrower parent types. Traditional inheritance uses the correct row/identity scope while partition roots remain inclusive.

The first combined regression run failed with 15 issues across import, paging, native-grid and quoted-function cases. The metadata cache regression failed for both SQLite and PostgreSQL. Exact-source scanner probes additionally reproduced escaped-string and newline-boundary bypasses. All corresponding regressions pass in the complete run below.

## Fresh validation

| Check | Result |
| --- | --- |
| Complete release Swift Testing suite | 334 tests, 59 suites, 91.684 seconds; no exclusions or skips |
| XCTest workflow suite from the same invocation | 13 tests, zero failures |
| Release compilation | Passed in 316.66 seconds |
| Packaging regression harness | 9 tests passed; preference migration harness passed |
| Large live PostgreSQL catalog | 581 objects, 1,604 relationships, 41 groups; layout 0.371 seconds; read-only integration test passed in 1.892 seconds |
| Whitespace and merge checks | Passed; no unresolved conflicts |

The full invocation was `swift test -c release --no-parallel`, using an explicit scratch directory and all `SGS_POSTGRES_*`, `SGS_RECORD_POSTGRES_PORT` and owned-fixture gates enabled. It used a separate disposable PostgreSQL 17 container seeded from the committed `Tests/Fixtures/record-postgres*.sql` files. The reader role deliberately defaulted `standard_conforming_strings` to off, verifying that the application's startup and transaction settings restore the parser's expected behavior. Only the disposable fixture's test setup and isolated export-test schemas were written.

The separate large-catalog test only read the existing local database. It checked catalog and relationship completeness, triggers/CHECKs, shared grouping/layout, SELECT, non-executing EXPLAIN, read-only transaction state and rejection of CREATE. Credentials remained in the child process environment.

## Review limits

Native grid regressions exercise AppKit views. Earlier isolated app checks covered schema search/group focus, presentation changes, query results, record inspection/navigation and the corrected SQLite file chooser. Final drag/pinch, complete PostgreSQL Stop/export click-through and displayed frame rate are not claimed: computer-use pointer actions were intermittently unavailable and the desktop was subsequently locked. CPU preparation measurements are separate from rendered frame rate.

Record graph expansion/collapse currently recalculates positions and fits its view, replacing manually dragged record positions. This documented limitation does not affect saved schema graph pins. No release installation, Developer ID signing, notarization or artifact distribution is part of this source integration.


## Follow-up hygiene integration

The user subsequently authorized fetching, integrating the completed hygiene follow-up, and pushing main. The fetched base was `d84f27c11f6add1a0266950d28549cb6e3c24975`. Source checkpoints `10359d1` and `a0fcd6c`, plus documentation `88f5573`, were integrated without removing the existing record or parity implementation. The final tested code is `725ef9d`.

The remaining runtime delta is limited to both generated Top 10 query sources using `tableDataSQLSource`, standardizing the SQLite session's selected URL to match backend target checks, and leaving omitted CSV fields absent so column defaults apply. Explicit NULL remains distinct from omission and empty text.

Independent pre-push review found that the new inheritance export fixture test lacked the explicit owner-role enablement used by its peers. With reader/fixture gates enabled but no owner, the test reproduced setup and cleanup failures. The repaired test explicitly skips that unavailable owner coverage; its owner-enabled run passes. The reviewer rechecked the guard and reported no remaining findings, with a passing gate.

Fresh combined verification on the final code:

| Check | Result |
| --- | --- |
| Complete Swift Testing suite | 338 tests, 59 suites, 131.723 seconds; all PostgreSQL and owned-fixture gates enabled, no exclusions or skips |
| XCTest record/workflow suite | 13 tests, zero failures, 0.050 seconds |
| Application product build | Passed, 4.46 seconds |
| Packaging regression harness | 9 tests passed, 5.390 seconds; compiled preference-migration harness passed |
| Missing-owner configuration control | Previously failed twice; now explicitly skips the owner-dependent case and exits successfully |
| Independent code review and whitespace check | Passed |

The complete suite used the retained task-owned `sgs-record-b96d` PostgreSQL 17 fixture and the Swift Testing helper with one execution slot. An earlier run was stopped to rebuild the owner-gating repair and is not counted as completed evidence. The native-interaction and distribution limits above still apply.

Wiki impact: no update needed — this repository has no Wiki; the updated canonical query contracts and verification documents cover the follow-up.

Gate: PASS
