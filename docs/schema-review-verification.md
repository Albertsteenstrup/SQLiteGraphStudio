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

## Review lens, readable names and review authors

Reviews now open on every change, and choosing a table isolates its own changes
while fading the rest. Unchanged relations stay off the canvas while zoomed out and
never light up on hover. Changed tables carry fixed-size, collision-culled name
labels at overview zoom instead of enlarging nodes. The table list is grouped by
kind, reveals the chosen table with minimal camera movement, and steps through
changes with ⌥⌘↓/⌥⌘↑. The graph is clipped to its pane. `--agent`/`--session`
record which agent and session produced a review or preview, shown in the header.

Focused Swift Testing checks cover the lens weighting, label placement and
truncation, the reveal camera, review opening without a pre-selected table, author
normalisation, validation and legacy decoding. Every Swift Testing suite
passed (511 tests in 74 suites), run from a scratch package that links the local
Command Line Tools' Testing framework; the four XCTest files could not be compiled
there and were excluded. The CLI
flags were exercised against the built binary on a synthetic 195-table comparison.
The native review window was not inspected visually in this pass.


## Embedded review and setup follow-up — 2026-09-29

This follow-up supersedes the earlier descriptions of multiple card borders and
opening every change at once. Reviews frame View 1 without selecting a table.
Selected change cards have a single change-coloured border, with no outer halo.
View 0 shows only the after-schema model with uniform node sizing and opacity;
View 1 and later retain the focused change presentation. Cards appear at a lower
zoom in every review view.

Embedded viewers keep the last complete frame during movement and resizing,
use absolute view navigation to reject stale replies, and isolate state by iframe.
Linked assistant explanations are tied to the exact review revision and validated
against its table, field and relation IDs. The explanation disclosure preference
survives view switches and refreshed tool results. Details close with **Close ×**
or **Escape**, including while a frame is pending; panel collapse requests a
smaller host height. Versioned and historical viewer resource names remain readable
after helper upgrades. Already-running helpers still require a host restart.

The setup installer accepts Codex's current nested stdio transport format and
preserves already-correct registrations. User-wide skill-root links can resolve
to an existing, user-owned directory inside the home folder, with other-user
writes prohibited. Project destinations and nested skill links retain their
restrictions; customized skills are preserved.

Fresh focused pre-push verification against `origin/main` at `499ffdf`:

- 47 XCTest checks passed: 21 MCP App/resource checks, 19 installer checks and
  seven WKWebView embedded interaction checks.
- 69 Swift Testing checks passed in nine suites, including real renderer
  processes, graph geometry/lens behavior, schema comparison, View 0, inline/native
  parity, historical explanations and skill installation.
- Canonical, generated and MCP skill contents match
  (`python3 Tools/generate_embedded_skills.py --check`).
- The packaged app built successfully. Its installed helper completed setup for
  both clients, including MCP handshake, 67-tool discovery and `studio_status`;
  repeated setup reported all 10 skill copies current. Existing Codex settings,
  the Claude skills link and previously existing shared skill files were unchanged.

This is focused regression evidence, not a full test-suite or live PostgreSQL
migration-validation claim. WKWebView tests exercise the actual viewer HTML with
controlled host replies; they do not prove every host application's iframe layout.

The independent pre-push review found two regressions, both reproduced before
repair: dropping entirely omitted sets renumbered large-review explanations, and
historical explanation captures accidentally inherited View 0 rendering rules.
Detail sets now retain their original indices, omitted counts remain accurate,
and fallback navigation keeps bounded overview labels. A WKWebView regression
checks the correct explanation after an omitted set and bounds the navigation
chips with 500 further omitted sets. Historical captures are explicitly excluded
from View 0 so their saved visibility, expansion and focus behavior remains active.

The reviewer rechecked the repairs and reported no remaining findings. All 116
focused tests passed; after the final omitted-set message adjustment, all 28
MCP App and embedded-view checks passed again, including navigation beyond the
40-label overview limit.

Wiki impact: no update needed — this repository has no Wiki source or publishing
machinery; README and canonical documentation cover the changed workflows.

Gate: PASS

## Embedded gesture responsiveness — 2026-09-30

Dragging and zooming now transform the last rendered image immediately in the
browser. An 80 ms pause in input triggers a native frame, with only one request
outstanding, keeping snapshotting and image decoding out of continuous gestures.
Incoming frames retain gestures
made after their request, and queued clicks follow subsequent camera movements
so they still hit the table the reader chose. Navigation resets the preview
transform before restoring a cached view. Newly exposed areas show the canvas
background until the next native frame arrives; zoomed images can be temporarily
soft while waiting for that frame.

The existing delayed-frame WKWebView regression was extended to check immediate
dragging, zooming in and back out at the pointer, batching twenty pointer moves,
click coordinates during further movement, and reconciliation of an older frame
without replaying its pan. It failed on the original HTML and passed after the
fix. All 72 XCTest checks in `StudioMCPTests` passed, including all eight embedded
browser checks. Verification compiled the repository's actual MCP source, resource
bundle and test target in a disposable SwiftPM package, without unrelated native
app dependencies.

These checks use controlled host replies; they do not measure live host frame
latency or establish a display frame rate. The initial iteration left the native
renderer and installed app unchanged. A rebuilt helper and refreshed MCP
connection are needed to load the updated viewer.

For the subsequent inline trial, the installed helper's viewer HTML was updated
to match this checkout; app binaries and settings were left in place. Its prior
HTML is backed up at
`/private/tmp/sql-gui-embedded-performance-check/installed-viewer-before.html`.
The synthetic `drag-and-zoom-trial.sgreview` was shown through the real inline
tool. Resource discovery confirmed that the existing connection still serves
the old HTML revision (`d5c7ddd3a585ca52270905db`), while the installed update is
`1fc1cb4ac2acd6fd1277f7f8`. The MCP connection must be refreshed before the trial
can demonstrate the new gesture behavior.

### Native camera latency and earlier table details

Resource discovery during the follow-up confirmed that the connection had loaded
the first gesture fix (`1fc1cb4ac2acd6fd1277f7f8`), so the remaining lag was not
just an old viewer. Camera-only rendering now waits for SwiftUI to consume its
viewport command instead of waiting for three additional stable ticks. Initial
fit, selection, and set navigation retain the full settling path. The viewer
waits for an 80 ms input pause before requesting a refined frame, previews input
immediately, and uses the renderer's camera limits to prevent zoom overshoot.
Cached navigation frames retain their camera metadata.

Review detail cards start at 10% zoom, previously 22%. Their names and field text
no longer fade as the camera zooms out. Repeated table clicks keep the same
choose/unchoose behavior when cards become visible sooner. A native render of
the synthetic trial at the user's approximate zoom confirmed that fields are
drawn at full opacity instead of behind the large overview labels.

Two local hidden-renderer runs used the same seven-table review, an 800 by 520
viewport at scale 1, and six consecutive 10-pixel pans after opening. Median
request time was 214.61 ms before the changes and 26.515 ms after. The updated
run ranged from 24.58 to 341.33 ms, including one slow outlier. This excludes MCP
transport and host display time and is not a live iframe frame-rate claim.
Timing records are in
`/private/tmp/sql-gui-embedded-performance-check/renderer-baseline.json` and
`/private/tmp/sql-gui-embedded-performance-check/renderer-updated.json`.

All 128 focused checks passed: 72 MCP XCTest checks (including eight WKWebView
checks), 54 graph geometry/exploration checks, and two real renderer process
checks. Native pixel checks verify that returned pan and zoom frames already
contain the moved and resized card. Embedded checks verify immediate transforms,
late-frame reconciliation, click alignment, and both zoom limits. The packaged
viewer matches the source resource; its current revision is
`9348240fbd0ad6afa81afdf6`.

The tested app is built at `dist/SQLiteGraphStudio.app`. After user approval, it
was installed at `/Applications/SQLiteGraphStudio.app` and reopened with the
synthetic Drag and zoom trial. The previous bundle is preserved at
`/private/tmp/sql-gui-embedded-performance-check/installed-app-before-native-update.app`.
The update preserved existing MCP helper processes. Installed app and helper
binaries and the viewer HTML match the tested package; the installed bundle
passes deep, strict ad-hoc signature verification. `studio_status` reports the
new app instance accepting requests, and native accessibility inspection confirms
that the trial and its table fields are visible. After the user restarted the MCP
connection, resource discovery confirmed viewer revision
`9348240fbd0ad6afa81afdf6`, and the synthetic trial was shown again through
`studio_show_review_inline` on the refreshed connection. User-perceived embedded
gesture latency remains a live trial, rather than a claim established by tests.

The Added / Changed / Removed legend was subsequently removed from the native
review header at the user's request. The app built successfully, was installed
and reopened, and accessibility inspection confirmed the original trial's header
no longer includes those labels. The previous app is preserved at
`/private/tmp/sql-gui-embedded-performance-check/installed-app-before-legend-removal.app`.

The graph and table/details panel now use a native `HSplitView` instead of fixed
56% / 44% widths. Both panes remain clipped and have minimum widths so the graph
and table controls stay usable. The app built, was installed and reopened, and
native accessibility resizing moved the divider from 639.5 to 800 and back to
716 points. Before/after renders confirmed the graph grows and the table panel
shrinks with the divider. Mouse-drag automation returned `noWindowsAvailable`
while the app remained running; the native splitter itself was verified through
its accessibility value. The previous app is preserved at
`/private/tmp/sql-gui-embedded-performance-check/installed-app-before-review-split.app`.


### Session title as the author heading (2026-09-30)

The current Codex task was matched by exact thread ID
`01a0f137-4f4a-7181-9e56-04fa3d755153` using the Codex app thread list. Its actual
title is `Improve embedded view performance`; this title now lives in the trial
review's `author.session`. Native headers lead with that session name, keeping
the agent mark and complete tool/session provenance in the tooltip and accessible
label. Reviews without a session keep their normalized tool name.

Inline overviews retain the existing `author` provenance string and add an
optional `authorLabel`. The production HTML displays this label using
`textContent`, falls back to legacy provenance strings, and hides the row for
unauthored reviews. Canonical diff/preview capture instructions require the actual
current title whenever the host provides it; generated resources, project copies,
and the four verified managed user-wide Codex/Claude copies were updated. Custom
copies are preserved, with prior managed hashes retained for future updates.

Verification: the existing MCP integration test failed on the pre-fix transport
because `authorLabel` was absent. All 72 MCP checks then passed, including eight
production-HTML WebKit tests; the header test exercises the real title, provenance,
legacy fallback, and absent-author refresh. Eight native review tests and eleven
skill tests passed. After final skill regeneration, all twenty MCP setup tests
passed, and the generator check and `git diff --check` passed.

The built app was ad-hoc signed, verified deeply and strictly, installed with a
recoverable backup at
`/private/tmp/sql-gui-embedded-performance-check/installed-app-before-session-title.app`,
and reopened. Its native window visibly showed the actual session title beside
the Codex mark. Existing MCP helper processes were preserved; the current Codex
connection still serves its earlier cached viewer and must reconnect before the
embedded header update appears there.


### Main integration before push (2026-09-30)

Fetched `origin/main` at `e3f151ce8f030c1b044282c70e141125b4280e2a`
(`Restore workspace controls and start with an empty workspace`). An independent
pre-sync review inspected the actual patch, camera and hit-testing call paths,
and the incoming graph input monitor; it found no actionable issues and passed
all eight production-HTML WebKit checks. The local review changes were then
committed and rebased onto that main commit without conflicts. A second fetch
confirmed the same upstream base during verification.

Fresh combined verification passed:

- Full MCP XCTest suite: 72 tests, including eight WebKit gesture/viewer tests.
- Native graph, workspace, review and skill checks: 89 tests across eleven
  suites. The incoming workspace/input tests exercised real AppKit panel,
  minimap, button and trackpad exclusion behavior.
- Actual renderer-process and native/inline review parity checks: seven tests
  across two suites, including two renderer pixel/input tests.
- Generated skill contents and whitespace checks passed. README and CHANGES
  describe the revised card threshold, pane sizing, immediate embedded gesture
  previews, and producing-session label.

This is focused integrated validation; the complete Swift suite, PostgreSQL
fixtures, packaged distribution checks and live embedded frame rate were not
rerun for this change. The native splitter mouse-drag automation limitation and
current MCP connection's cached viewer limitation above remain unchanged.

Wiki impact: no update needed — this repository has no Wiki source or publishing
validator; README and canonical documentation cover these user-visible changes.
