# Query and export verification

Work is isolated on `codex/query-export-hygiene`, based on PostgreSQL checkpoint `29630b191062a6d0d5dfacfd55b26140591c7bb7`. No main merge, push, installation or release distribution is part of this change.

## Reproductions

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

Fixture-specific browsing/export tests additionally require `SGS_POSTGRES_FIXTURE_TESTS=1`. Provision a new disposable database and a SELECT-only role; never run setup against an existing dataset. The fixture is 1205 `public.items` rows with composite `(tenant,id)` primary key; `tenant=i%3`, `id=i`, `label=NULL` for multiples of five and otherwise `group-(i%7)`, `amount=i+0.1234567890` as numeric(30,10), and `active=i%2=0`. `public.keyless(label,value)` contains `('same',1),('same',1),('other',2)`; `item_view` selects label and amount. The task's owned PostgreSQL 17 fixture lives exclusively in `/tmp/sgs-query-pgdata`.

## Verification status

The [combined main integration verification](main-integration-verification.md) records the completed shared release suite, PostgreSQL checks and final review repairs. Distribution signing requires a Developer ID private key and notarization credentials; no real signing/notarization or distribution is claimed by local packaging tests.
