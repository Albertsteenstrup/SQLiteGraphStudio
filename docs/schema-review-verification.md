# Database schema review verification

Verified locally on macOS on 2026-09-22. This feature compares schema metadata,
not application records or the safety of data migrations.

## Implemented behavior

- File → Compare Database Schemas captures two SQLite files or PostgreSQL
  backups/connection documents and saves an offline `.sgreview` document.
- The graph preserves the group border and adds a separate blue change border
  or dashed red removal border. Card headers and overview node summaries show New, Removed,
  field addition/removal/modification counts, and relationship changes.
- Removed tables/fields remain inspectable. Edited relationships show both the
  removed and added definitions. The table panel provides aligned Before/After
  fields with a fixed header, search, and a Changes only toggle.
- The bundled and project-local `database-diff` skill describes exact revision
  selection, isolated materialization, CLI capture, and review limitations.

## Evidence

- Built the packaged application with `script/build_and_run.sh --build-only`.
- 44 focused Swift Testing checks in five suites passed. They cover real SQLite capture, source preservation,
  no row export, composite/implicit foreign keys, duplicate constraints,
  PostgreSQL OID independence, malformed/colliding identities, offline session
  restrictions, skill installation/parity, graph interaction geometry/hover,
  and session opening lifecycle. The local Command Line Tools installation
  lacks XCTest, so these suites used the installed Swift Testing runtime with
  the compiled StudioCore objects; this was not a full `swift test` run.
- Packaging checks: 30 Python tests plus preference migration verification.
- Native UI: opened a comparison, selected new/removed/modified tables,
  expanded the changed graph card, and scrolled details with headers retained.
  Used the two-file comparison command to capture and save a new document,
  then reopened that document from Recent. Automation lost its accessibility
  connection after Save; process sampling showed an idle main thread, and
  the saved file and recent entry were intact. The reopened view was verified.
- Opened the actual grcplatform PostgreSQL comparison from `e3be159d19dbb2762ccc99aa8025a7894ba67920`
  to `ac8a256f00ca902c745743dffa8b9d117daf6383`: 78 changed tables, including
  additions, removals, changed fields and relations. The artifact was generated
  by replaying immutable migration SQL in separate disposable catalogs. This
  capture proof did not write a passing review marker or authorize integration.

## Scope boundaries

Snapshots include tables/views, fields and declared foreign keys, plus available
index/trigger/constraint definitions. Renames appear as removal plus addition.
They do not completely compare grants, RLS, stored routines, extensions,
runtime-generated DDL, or row data. A live connection should remain unchanged
during capture; the multi-query metadata capture is not one atomic transaction.

The grcplatform integration is implemented in its separate
`codex/database-schema-review` worktree. Its existing code-review gate runs first;
the follow-up binds artifacts to exact revisions/trees, capture tools and hashes.
Fast-forward integration uses the final skill step because Git does not invoke
a pre-merge-commit hook for fast-forwards. A presentation receipt records that
the artifact was opened, not human approval. No merge or push was performed as
part of implementing this feature.

Local activation was verified separately: grcplatform's original checkout uses
a worktree-specific hook path pointing to the pinned follow-up under its Git
directory. Its original hooks remain intact, and 17 other checkout settings
were unchanged. The shared implementation is committed in
`codex/database-schema-review` at `a843b4f95eb6bce05d4072dfcf7f66f87f326312`;
the installed runtime is pinned to `b7ccf0ed1bfe4bab282d63df8a7fabd8e5985167`
(the later commit only records activation).
Original main has only the companion-instruction commit
`303409db3b010da775146b2673ce6f50b7f02321`. Hook validation passed 47 new tests,
33 existing review-script tests and five memory-budget checks. The installed
pre-push dry invocation rejected a missing original review before any schema
capture. The original implementation verification did not push either repository.

## Proposed-change preview follow-up

Added the sibling `database-preview` skill, bundled with the app and installed
in this project's `.agents/skills` and the user's personal Codex skills. The
preview CLI projects a compact JSON plan onto a captured snapshot, or the
explicitly chosen side of a real comparison. It never opens a database or
executes SQL. `.sgpreview` documents retain the baseline/plan fingerprints and
show Proposed labels; they cannot be loaded as captured baselines.

The final focused run passed 53 tests in six suites (including parameterized
invalid-plan cases), and all 30 packaging checks plus preference migration.
The preview tests cover table/field/relation operations, renames, explicit
cascade behavior, unknown IDs/properties, stale fingerprints, partial field
updates, compact inspection, and refresh failure/recovery without losing context.

Native verification opened a proposal on the real PostgreSQL capture, then
regenerated the same file with a new table, field removal and relation. The
open view updated without reopening or pressing Refresh. A deliberately invalid
atomic replacement retained the last good view and showed an error; the next
valid version recovered automatically. A real SQLite capture/project CLI check
confirmed unchanged source bytes and that a stale plan did not overwrite the
previous preview. Saving a proposal with `.sgreview` was rejected.

Local timing with the 1,552,547-byte GRC snapshot: a 201-byte one-field plan took
0.118 seconds median over five CLI runs (0.118–0.120 seconds). Inspecting only
`public.app_user.email` returned 328 bytes instead of the full snapshot. These
measurements cover warm preview iterations after capture, not initial database
capture or database migration validation. Output documents remain self-contained;
the agent only needs to author the small plan and read selected metadata.

The view checks file metadata every 500 ms and decodes only changed files.
Proposals retain the same graph/table markers as actual reviews but omit raw
definition metadata from the details panel because it has not been regenerated
by a database. The actual schema-review hook and its review receipts are unchanged.

## Subtle hover and final integration checks

Removed detached hover callouts. Overview nodes now draw the shared table header
inside their existing bounds. Hover scales the table by 2.5% and its immediate
neighbors by 1.5% at every zoom level, without changing saved positions or adding
pointer targets. Unrelated overview nodes no longer dim during hover.

The combined final run passed 75 focused Swift Testing tests in nine suites,
covering schema comparison, previews, skill packaging, session lifecycle, graph
geometry, node sizing, exploration, relation highlights, and hover. The packaged
app builds and opens the sample database with the shared headers. Native pointer
automation returned `noWindowsAvailable`, so live hover was not verified through
the UI; size limits, text bounds, hit targets and zoom transitions were checked
by the focused tests. This remains a focused run, not the full XCTest suite.
