# Open PostgreSQL dumps

**Goal:** The existing secondary database picker accepts PostgreSQL custom archives and connection documents. It is labelled Other Database, with the supported formats shown explicitly. No login or connection profile is required to open a dump.

**Design:** Recognize `.dump` and `.backup` custom archives by their PGDMP header; retain `.postgres` and `.pgstudio` connection documents. Prepare each archive in a private local PostgreSQL instance, using a compatible bundled runtime or an installed runtime. Only the restore helper writes to that instance. The browser uses a separate reader and existing read-only query/backend gates. Keep the source untouched. Use a private Unix socket, sandbox the server and restore tools, and stop the instance on close, cancellation or application exit. Unsupported formats or missing dependencies are explicit errors, never partially opened databases.

The source document, rather than a temporary server address, owns recents, layout, saved queries and sidecar metadata. Progress and cancellation remain accessible while opening. Reopening prepares a new copy; persistent restored-data caching is intentionally deferred to avoid stale snapshots and unbounded retained data.

## Work and verification

- [x] Centralize supported formats and source identity. Test dump selection, uppercase extensions, invalid headers and document identity; inspect shared launch routing.
- [x] Add a cancellable subprocess runner and managed PostgreSQL dump lifecycle. Test a real archive restore, read-only browsing, failure and cleanup with an opt-in local runtime fixture.
- [x] Route the picker, launch events and recents through one document dispatcher; update labels and show progress/cancellation.
- [x] Package an optional relocatable PostgreSQL runtime and document runtime/extension requirements. Keep packaging verification independent from Swift compilation.
- [x] Verify the supplied Fjordholm archive with PostgreSQL 17, inspect graph/catalog completeness, preserve file hash, check close cleanup, run focused lifecycle/regression tests and build the application.
- [x] Review source integrity, concurrency, isolation and cleanup; address the supplied review findings and verify the resulting paths. Independent review found additional lifecycle branches; the parent repaired those with the native helper and fail-closed checks below.

## Verification evidence (2026-09-06)

Implementation checkpoint base: `995a5881f5a170d8e8151cf6c6091779f0be2294` (verified `origin/main`). Branch: `codex/open-postgres-dumps`. At this checkpoint no merge, push or installation had been performed. Subsequent main-integration verification is recorded below.

### Security boundaries

- `DatabaseDocument.openArchive` opens once with `O_RDONLY | O_NONBLOCK | O_CLOEXEC`, requires a regular file using `fstat`, validates its header, and passes that same descriptor to the private copy. FIFO symlinks and directories are rejected; regular-file symlinks remain supported without changing source permissions. This closes special-file blocking and validation/reopen races.
- `PostgresDumpSession.sandboxProfile` permits network access only to the exact owned `.s.PGSQL.5432` socket. The outside-socket test uses an owned harmless listener, not Docker or another user's database: the former all-Unix rule accepted a connection; the restricted rule does not. Real restoration through the permitted socket still works.
- Archive SQL executes as `studio_restore`, a non-superuser with no role/database creation or native-language privileges; the role becomes NOLOGIN after restoration. Trusted extensions can install normally. Only the fixed pgvector installation is elevated, using trusted runtime extension files before archive SQL executes. Other superuser-only features fail closed. This prevents archive-supplied programs or untrusted language functions from creating arbitrary orphan processes, instead of relying on ancestry polling to contain malicious code.
- The server's sandbox prohibits executable mappings from the writable workspace and process execution except the exact trusted PostgreSQL binary. A native internal executable mode of the app supervises the server outside that restricted sandbox, before SwiftUI/document state is initialized. It detects GUI death using its direct kernel parent relationship (`getppid`), not a reusable PID lookup, and uses the same audit-token cleanup as the GUI. No shell supervisor or numeric shell signals remain. A live owner-level COPY PROGRAM attempt is rejected by the sandbox; the restore role additionally cannot COPY PROGRAM or create native C functions.
- `PostgresToolProcess` tracks descendant process identities including start times, not only process groups. Shutdown attempts fast then immediate PostgreSQL shutdown, freezes/rescans before forced termination, and checks tracked descendants before workspace removal. Signals use kernel-checked audit tokens, not a check-then-kill PID operation. The wrong-PID-version regression is rejected, while a legitimate harmless signal succeeds. Enumeration resets/checks errno because libproc returns zero on error; injected enumeration failure prevents successful cleanup authorization. An unexpected supervisor exit invalidates completeness.
- A harmless worker that calls `setsid()` and ignores shutdown signals reproduced the prior escape, then passed with the fix. The original same-group stubborn-child test also passes. This proves ordinary tracked worker cleanup, not a general-purpose hostile process-tree containment mechanism; the restore privilege and sandbox boundaries above prevent the supplied hostile process-creation paths.
- Cancellation retains cleanup tasks through immediate Quit. Snapshot-only RLS bypass preserves archived rows; read-only transactions and mutation gates remain enforced. Function-backed views receive only restricted invoker-function permissions; unsafe writing functions remain inaccessible.
- Privileged post-restore SQL resets `search_path` to `pg_catalog` using a separate psql command. A fixture changes database defaults during restored CHECK evaluation and supplies a fake public catalog table; privileged setup and legitimate browsing still work. First-observer cancellation reaps before marking shutdown requested. Failed supervisor status and failed second-parent identity verification prevent cleanup authorization.

### Commands and results

With `SGS_POSTGRES_DUMP_TEST_FILE` set to the supplied Fjordholm archive and `SGS_POSTGRES_SUPERVISOR` pointing to this checkout's built `SQLiteGraphStudio` executable (Swift Testing runs in a separate helper executable):

- `swift test --no-parallel --filter PostgresDumpTests`: **15 passed** after the synchronous-launcher correction (32.489 seconds), including source integrity after FIFO alias replacement, outside-socket rejection, both escalation fixtures, audit-token version rejection, failed enumeration, first-observer supervisor exit, least-privilege restore, blocked program/native functions, protected catalog search path, cancellation, RLS/function views, and real restore/browse/close.
- Final `swift test --no-parallel`: **353 Swift Testing tests in 60 suites passed**, plus **13 XCTest tests passed** (177.386 seconds for Swift Testing), including the final launcher, native supervisor and all security regressions. The dump suite passed again in 32.745 seconds. Separate opt-in live-connection fixtures were not enabled and reported skips; the real archive fixture was enabled.
- An earlier `swift test --parallel --num-workers 1` run failed with graph scheduler and app-smoke timeouts under concurrent main-actor graph workloads. `--num-workers 1` did not serialize Swift Testing. All 25 tests in the affected two suites passed in an isolated serial rerun, and the subsequent complete serial run passed. No unrelated timing tests were changed.
- `python3 Tests/Packaging/test_packaging.py`: **30 passed**. These are packaging command-double tests, not a real redistributable PostgreSQL runtime test.
- `bash script/build_and_run.sh --build-only`: **passed**; final refresh took 4.13 seconds and rebuilt `dist/SQLiteGraphStudio.app` without launching or replacing the installed app.
- Final `swift build -c release --product SQLiteGraphStudio`: **passed** after the synchronous-launcher correction (88.78 seconds).
- `git diff --check`: **passed**.
- Post-run process inspection found no owned `postgres -D /private/tmp/sgs-pg-…` server or native `--studio-postgres-supervisor` remaining.

Fjordholm: custom archive v1.16, restored with installed PostgreSQL 17.9. Catalog: **351 tables and 11 views**, **362 graph nodes**, **1,136 graph relationships**. All 11 views were browsed. The read-only session setting was `on`, CREATE was rejected, and source bytes remained identical. Source SHA-256 before/after: `28cec6f3e543bc3056cf0af479d9f8d8bccf558468e12f0cf5a54735609aadc0`.

### Verification limits

Native UI inspection used an isolated test bundle and confirmed the welcome action, toolbar action, picker title, supported-format caption and selectable supplied dump. Early computer-control calls encountered clipboard timeouts, changing-window state and `noWindowsAvailable`. A later click-through exposed an async-launcher regression: AppKit's event loop nested inside an async main-actor job, preventing later document-open tasks from running. A one-second sample of the isolated app confirmed that stack. The launcher now enters ordinary SwiftUI/AppKit synchronously and uses async dispatch only for the internal non-UI supervisor.

Final picker-to-graph verification passed: opening the supplied archive through **Choose Other Database** showed cancellable loading, the exact dump filename, the **PostgreSQL · strictly read-only** badge and a visible compact overview of **362 objects in 29 groups**. The table chooser also listed the populated `public.ai_usage_event` table with 106 estimated rows; opening that row was not claimed because computer-control row selection did not take effect. All 11 views were separately browsed by the automated app-session fixture.

For the final visual run, `SGS_POSTGRES_SUPERVISOR` pointed to this checkout's identical debug executable outside the QA bundle. With the default same-bundle helper, restore completed and the archive appeared in recents, but computer-control window lookup began timing out after helper launch. A fresh main-process sample showed an idle ordinary AppKit event loop, not the former async-main hang. The external-path helper avoided that window-selection ambiguity. Native **Quit SQLite Graph Studio** then exited the QA process successfully, and process inspection found no private PostgreSQL server or helper remaining. The user's original application was not closed or replaced.

No self-contained PostgreSQL binary distribution was manufactured. The local build uses installed PostgreSQL; optional runtime packaging requires a separately prepared relocatable runtime. Universal runtime restoration, Developer ID signing, notarization and Gatekeeper were not verified. Unsupported archive formats, unavailable extensions and unsafe function-backed views produce explicit errors.

The disposable workspace retained after the deliberately terminated first QA process was removed only after process inspection and absence of its postmaster PID file confirmed shutdown. The original Downloads archive remains unchanged; no user database was removed.

## Main-integration review follow-up

A fresh pre-main review identified two additional cleanup-ownership gaps. Both were reproduced before their fixes: five failed assertions covered unconfirmed initialization cleanup deleting its directory, and Quit returning before cleanup during both SQLite and connection-document switches.

- The dump session now preserves failed tool-shutdown confirmation independently of its server, including initialization before a server exists. The regression injects only a libproc enumeration failure into a real cancellable child, with a normal-enumeration control proving confirmed cleanup still removes the directory.
- The database facade retains a serialized cleanup task chain across actor suspension. Both opening another document and closing join that chain, so clearing the active backend cannot hide an in-progress teardown from Quit. The regression pauses only its owned postmaster using audit-token signals, starts each kind of document switch, verifies Quit has not completed, then resumes the server and checks that the private directory is gone before Quit returns.

The two new regressions passed after the fixes (16.775 seconds before adding the normal-enumeration control). Final pre-integration verification:

- Complete serial suite: **355 Swift Testing tests in 60 suites passed** (169.665 seconds), plus **13 XCTest tests passed**. All **17 dump test methods** passed (55.201 seconds), including the normal/failed enumeration controls and both document-switch cases. Separate opt-in live-connection fixtures still report their coverage as skipped.
- Packaging: **30 tests passed**, plus the real isolated preference-migration executable passed.
- Release build passed (74.64 seconds); final debug app bundle rebuild passed (3.71 seconds).
- Diff-check, shell syntax and plist validation passed. The archive hash remains unchanged, and post-run process inspection found no owned PostgreSQL server or supervisor.
- The fresh reviewer rechecked both cleanup findings and their immediate interactions, confirmed both cleared, and returned **Gate: PASS** with no remaining actionable findings. A second fetch still found `origin/main` at `995a588`.

Wiki impact: no update needed — this repository has no Wiki; README and packaging documentation are the maintained user-facing references and have been updated for this feature. This integration does not install an application or publish a release artifact.
