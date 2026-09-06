# Query and export verification

Work is isolated on `codex/query-export-hygiene`, based on PostgreSQL checkpoint `29630b191062a6d0d5dfacfd55b26140591c7bb7`. No main merge, push, installation or release distribution is part of this change.

## Reproductions

All seven findings are **reproduced-and-fixed in code**, with the evidence and native verification limits below. None is classified as already resolved. Final interactive acceptance remains blocked by the locked Mac; real distribution validation is unavailable without credentials and is outside this task’s release scope.

| Finding | Original evidence | Implemented repair |
| --- | --- | --- |
| Duplicate query names | SQLite returned repeated first-name values; PostgreSQL JSON dictionary construction trapped for duplicate keys. | Positional column IDs and value reads; collision-safe JSON names and positional grid/copy access. |
| Page-only export | Filtered fixture exported 50 rows instead of 602; wrong first/last IDs. | Explicit loaded/all-matching choices; ordered snapshot streaming and atomic publication. |
| Query limit/cancellation | Five retained PostgreSQL rows still took about 2.19s for all 200 sleeping rows; SQLite cancellation returned success after work completed. | Bounded server cursor, native SQLite cancellation, deadlines, Stop and request generations. |
| Counts/filters/pages | Initial two-row page claimed exact 1205; numeric equality behaved as text contains. | Sentinel-based count evidence, explicit exact count, typed predicates and stable keyed pagination. |
| Metadata | Malformed/unsupported sidecars silently became empty; an old open could republish after Close. | Document-scoped last-good state, visible diagnostics, version/identity validation and lifecycle guards. |
| Integration gating/UI | Missing opt-in configuration returned successfully without coverage; unavailable write controls remained visible. | Explicit skip versus throwing opt-in validation; capability-gated controls and backend rejection. |
| Packaging identity | Launcher/release identifiers differed; packaging fixture regression began with six failures. | One source plist, missing-key-only preference migration, configurable Developer ID signing/notarization. |

The initial full baseline completed with 113 tests and 29 issues. Concurrent worktrees reused temporary fixture filenames, so that result was not a clean application baseline. Commit `6c8010e` gives every fixture a unique directory. A later combined focused process stalled and was terminated; partial output is not counted as a passing verification.

## Running checks

```sh
swift test
bash script/test_packaging.sh
```

Normal runs explicitly skip live PostgreSQL tests. For a deliberately selected read-only test connection:

```sh
SGS_POSTGRES_TESTS=1 \
SGS_POSTGRES_HOST=127.0.0.1 \
SGS_POSTGRES_PORT=5432 \
SGS_POSTGRES_DATABASE=disposable_test \
SGS_POSTGRES_USER=reader \
SGS_POSTGRES_PASSWORD='' \
SGS_POSTGRES_TLS=disabled \
swift test --filter PostgreSQLIntegrationTests
```

`disabled` is only appropriate for a deliberately trusted local fixture; remote verification should use `required`. Opting in without any required variable, with an invalid port/TLS mode, or with an unusable connection must fail. PostgreSQL 14+ is required.

Fixture-specific browsing/export tests additionally require `SGS_POSTGRES_FIXTURE_TESTS=1`. Export snapshot/cancellation fixtures use `SGS_POSTGRES_FIXTURE_OWNER` for a separate owner role in this disposable database; it creates and drops UUID-named test schemas while the application connection remains SELECT-only. Provision a new disposable database and a SELECT-only role; never run setup against an existing dataset. The fixture is 1205 `public.items` rows with composite `(tenant,id)` primary key; `tenant=i%3`, `id=i`, `label=NULL` for multiples of five and otherwise `group-(i%7)`, `amount=i+0.1234567890` as numeric(30,10), and `active=i%2=0`. `public.keyless(label,value)` contains `('same',1),('same',1),('other',2)`; `item_view` selects label and amount. The task's owned PostgreSQL 17 fixture lives exclusively in `/tmp/sgs-query-pgdata`.

## Verification status

The [combined main integration verification](main-integration-verification.md) records the completed shared release suite, PostgreSQL checks and final review repairs. Distribution signing requires a Developer ID private key and notarization credentials; no real signing/notarization or distribution is claimed by local packaging tests.

The shared query repair is committed in `c9d132a`; asynchronous file dialogs and source-bound imports are in `135366d`. PostgreSQL parity checkpoint `8a8fdc4` was integrated as `e23c8ac`; its completed canvas checkpoint `eb1e4b2` was integrated as `86ea919`, retaining this branch's metadata diagnostics and per-fixture isolation. That hygiene-only branch excluded record feature files; the combined main integration preserves record exploration. The final shared fixes from parity/main checkpoint `d84f27c` were selected into `a0fcd6c8fdc69b60896e15cf73c1d7619aa48d53`; this task did not perform that other task’s main push.

Additional review reproductions and repairs:

- PostgreSQL inherited parents included child rows whose keys need not be unique within the parent scope. Five live expectations reproduced the browsing/count/export mismatch. Checkpoint `10359d1` uses `ONLY` consistently for traditional inheritance parents, including both generated Top 10 consumers; partition roots and user SQL retain inclusive semantics. The generated-query and normalized-source regressions failed three expectations before the repair and passed five focused tests with live inheritance coverage afterward (`/tmp/sgs-consumer-red2.log`, `/tmp/sgs-consumer-green.log`).
- SQLite session URLs containing parent-directory segments differed from the facade’s normalized target. Captured-source guards could reject a valid operation. The session now uses the same standardized file identity.
- Selected shared CSV/JSON round-trip, SQLite stored-type cursor and PostgreSQL lexical read-policy regressions failed 26 expectations in 25 tests before adoption (`/tmp/sgs-shared-integration-red.log`). After the shared repairs, 26 focused tests passed in 0.123 seconds, including live read-policy and graph metadata-cache recovery (`/tmp/sgs-shared-integration-green.log`).
- Final review found that missing CSV fields had become explicit NULL, losing column-default behavior. The added CSV/JSON regression reproduced three CSV failures while its JSON control passed. Absent fields now remain absent; explicit NULL stays distinct. Three import tests passed in 0.027 seconds, including default and NOT NULL behavior (`/tmp/sgs-import-defaults-red.log`, `/tmp/sgs-import-defaults-green.log`). Independent read-only reviewers found no remaining actionable issue in these final scopes.

- Closing a PostgreSQL lease before driver query registration stranded its response promise. A bounded regression reproduced the non-completion. Shared event-loop query registration now rejects the closed lease promptly while preserving native streaming/backpressure.
- Early cancellation and cancellation during error rollback could release a closing connection back to the pool. Both were reproduced as failed immediate reuse. Cleanup now awaits physical closure, including cancellation around handler teardown. Twenty independent runs passed 6,000 early cancellations; five additional runs passed 1,500 early and 1,500 error/rollback cancellation-and-reuse cycles.
- Casting typed search values with storage modifiers could make `abcd` equal stored `abc` in varchar(3), char(3), and char(3)[] columns. Comparison casts remove modifiers; live enum, array, money, bit, numeric-special and overlong-value controls pass. Qualified `pg_catalog.bit` preserves width and array operator compatibility.
- A delayed SQLite import could write into a newly selected database with the same table name. The two-database regression first inserted the unwanted row, then passed after the facade checked the captured target before backend acquisition.

Focused final PostgreSQL integration: 12 cases passed in 5.576 seconds, including explicit configuration tests. Streaming export: six live cases passed, covering more than one page, snapshot consistency, exact values, cancellation before the first row, and atomic destination handling. Native AppKit regressions verify rendered duplicate columns, copy after column reorder, and page viewport movement without returning to the prior page.

Final local packaging verification: nine Python tests passed in 5.186 seconds, and the compiled Swift preference-migration check passed (`/tmp/sgs-packaging-final-shared.log`). These tests use disposable fixtures and do not prove real distribution signing.

### Native application evidence and limitation

A temporary QA copy of the locally built application used a separate bundle identifier to isolate saved preferences. The canonical bundle identity was unchanged. Native automation opened the owned SQLite fixture through the normal chooser and displayed query headers `id`, `id`, `id_2` with distinct values `1`, `2`, `3`. The query export menu displayed its captured one-row scope. Switching Open to the asynchronous panel API resolved the disabled Open button observed with the nested modal flow. Save and import use the same asynchronous pattern with captured-source checks.

The Mac then explicitly reported that its screen was locked and automatic unlock failed. Final Save confirmation, table filter/count/paging interaction, SQLite edit interaction, and PostgreSQL Stop interaction could not be completed in the running application. Automated backend, model, and native grid evidence does not substitute for those remaining interactive checks. Earlier automation calls also timed out; a minimal native chooser control was used to distinguish app behavior from tool availability. No completed UI export file is claimed.

### Full integrated run

Final code checkpoint **`a0fcd6c8fdc69b60896e15cf73c1d7619aa48d53`** passed **294 tests in 49 suites in 184.781 seconds**, exit 0, with **all live PostgreSQL and owned-fixture gates enabled and zero skips**. This includes the final inherited-table consumers, normalized source identity, import/default fidelity, mixed stored-type paging, lexical read policy, and metadata-cache recovery. Log: `/tmp/sgs-full-final-shared.log`.

The final canonical debug app build completed successfully in 4.62 seconds using `bash script/build_and_run.sh --build-only`, without launching or installing it (`/tmp/sgs-app-final-shared.log`). Its bundle identity is `com.albertsteenstrup.sqlitegraphstudio`, version `0.3.1`, build `2`.

The final fixture audit found zero remaining `sgs_export_*` schemas and the original 1205 owned `public.items` rows intact. The owned PostgreSQL server was then stopped successfully, retaining its disposable files for a later repeat. No external dataset was used for mutation or fixture setup.


At integrated code checkpoint `86ea919`, all **283 tests in 46 suites passed in 268.117 seconds**, exit 0, with PostgreSQL and owned-fixture gates enabled and **no skipped tests**. Log: `/tmp/sgs-full-integrated-final.log`; build: `/tmp/sgs-final-test-build.log`. The isolated bit/varbit decoder from committed peer checkpoint `69c0dec` was then added as `1fc3bc2`, without record feature files. Its own regression first failed six expectations for scalar/array/empty values; eight focused mapper and live PostgreSQL tests subsequently passed in 0.610 seconds (`/tmp/sgs-bit-red.log`, `/tmp/sgs-bit-green.log`).

A subsequent full run at `1fc3bc2` passed **284 tests in 46 suites in 300.344 seconds**, exit 0, with all live gates enabled and no skips (`/tmp/sgs-full-values-final.log`).

Final gating checks: an ordinary run explicitly skipped nine live PostgreSQL cases and passed three configuration cases (`/tmp/sgs-final-explicit-skips.log`). Opting in without `SGS_POSTGRES_TLS` failed with exit 1 and named that missing variable (`/tmp/sgs-final-missing-tls.log`). Skipped cases are not counted as live coverage. A previous concurrent focused run compared catalog counts while another test created temporary fixture tables; the comparison observed three versus nine objects. The isolated integration rerun passed. Full fixture verification therefore uses one Swift Testing execution slot. A previously stalled full run is not counted as successful.

The final read-only keychain identity query completed successfully and found zero Developer ID Application identities. Neither `SIGNING_IDENTITY` nor `NOTARYTOOL_PROFILE` is configured in this task environment. Real distribution signing and notarization remain unavailable; no upload, installation or distribution was performed by this task. Local packaging tests do not prove Gatekeeper acceptance.

The deterministic full-suite invocation on the verified Xcode toolchain is:

```sh
swift test list
DYLD_FRAMEWORK_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper \
  --test-bundle-path "$(swift build --show-bin-path)/SQLiteGraphStudioPackageTests.xctest/Contents/MacOS/SQLiteGraphStudioPackageTests" \
  --testing-library swift-testing --experimental-maximum-parallelization-width 1
```

Set the explicit PostgreSQL environment above, including the fixture and owner gates, on the runner when live fixture coverage is intended. SwiftPM's XCTest worker count alone does not serialize this Swift Testing version.
