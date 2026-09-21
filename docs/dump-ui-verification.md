# PostgreSQL dump and native UI verification

Verified on 2026-09-21 with the Downloads archive
`fjordholm-demo-v4-20260917T122655Z-1deb5155f71e.dump` and local PostgreSQL 17.
All restore and query checks used disposable private databases, not the source
application's database or the existing local PostgreSQL server.

## Regression coverage

`ReportedUXRegressionTests.everyDumpTableCanOpenRenderSortAndClose` restores the
actual archive and opens all 216 catalog objects. It loads and sorts every object,
constructs the native table grid, copies its headers, scrolls it, and closes the
tab. Results: 130 populated objects, 86 empty objects, and 2,953 column headers.
The same test checks exact zero-row filtering, combined field/row ranges, invalid
ranges preserving the previous filter, no matches, and reset.

The header ownership test repeatedly copies and draws 500 headers with long
PostgreSQL type strings. Both supplied crash reports failed during destruction of
`MetadataHeaderCell`'s Swift string storage. The cell now creates an independently
owned copy. Table and query-grid regressions also verify that the header rectangle
and row clip rectangle do not intersect.

The selected graph, native-grid, browsing, PostgreSQL support, archive, query, and
session suites reported 152 tests with no failures; ten opt-in external-server
tests were skipped. After the final archive lifecycle changes, the 17-test focused
archive/native/session/UX selection was rerun (one external-server test skipped).
The opt-in actual-archive tests were enabled throughout. The standard `swift test`
command is blocked on this machine by missing XCTest in its Command Line Tools
installation; Swift Testing suites were compiled and linked against the debug
StudioCore build and the bundled Testing framework instead.

## Native interaction checks

The running packaged app was exercised through its UI:

| State | Observed result |
| --- | --- |
| Choose the Downloads `.dump` in the PostgreSQL file picker | Restore loads 216 tables without a connection document |
| Quit, relaunch the same build, and open Recent | Archive restores again successfully |
| Double-click `field_research_public_query_identity` | Empty table opens without the reported crash |
| Open populated research tables and switch tabs | Rows and metadata load |
| Scroll to the last rows | Column headers remain separate from row values |
| Search, submit, clear, and click outside search | Search can be cleared and editing focus dismissed |
| Navigate to `field_*` | Other groups and cross-group edges remain visible |
| Expand/search-focus a table | Root and direct neighbours have separate card positions |
| Maximize graph pane and toggle all-card mode | Layout remains navigable; focus controls stay reachable |
| Reversed graph filter bounds | Validation rejects the range |
| Zero-row graph filter | 86 matching objects |
| No matching tables and reset | Empty-state message and recovery control appear |
| Top toolbar | Folder, server, and table shortcuts removed; underlying menu/workspace actions retained |

The default PostgreSQL schema prefix `public.` is hidden only in display labels.
Qualified catalog IDs, SQL identifiers, and sidecar references are retained.
Every detailed graph card has field and row badges; `— rows` means the catalog
does not have a count. Applying a row filter obtains exact counts for its field
range, including views and empty tables.

The local app is an unsigned development build. Rebuilding its executable can
invalidate macOS file-access grants; selecting the file again establishes access
for that build. The same-build restart test above is separate from rebuilds.
Native pointer-scroll automation intermittently lost its window binding; the
successful final visual scroll check used the native scrollbar value instead.

Build artifact: `dist/SQLiteGraphStudio.app`. No release or remote deployment was
performed.

## Compact graph controls follow-up

Rebuilt the packaged app and checked the compact toolbar with the same archive.
Search, Filter, and Graph options occupy one row. Applying a 10–20 field filter
matched 109 tables without adding a count line or changing toolbar height. The
options menu showed the count and retained Clear filter, display toggles, Stories,
and Relayout. Clearing the filter restored the overview. Searching for the
research identity table focused its five-table neighbourhood, with an inline back
button that successfully returned to the overview. Build and `git diff --check`
passed; this presentation-only follow-up did not rerun the database test matrix.

## Database name placement follow-up

The database filename is now shown only in the widest pane, with a short animated
transition when that pane changes. It stays on one line and uses middle truncation
if necessary. An even split retains the current owner, and Reduce Motion disables
the transition. Native UI checks moved the divider from 701 to 450 points and back,
confirming the filename switched sides with no persistent duplicate. Maximizing
the narrower pane and restoring the split also restored the correct title owner.
The packaged build and `git diff --check` passed.

## Final upstream integration verification

Before pushing, integrated `origin/main` commit `49e225d`, retaining its sandboxed
restore implementation, private Unix socket, process supervision, packaging, and
non-superuser restore role. The UI and archive regression tests now exercise that
implementation rather than the earlier local restore helper.

Rebuilt the app and reran the selected suites with both archive test variables and
`SGS_POSTGRES_SUPERVISOR` set: 169 tests across 19 suites completed without failure;
ten opt-in external-server checks were skipped. This included the upstream dump
lifecycle/sandbox regressions and the full 216-object UI matrix (130 populated,
86 empty, 2,953 headers). All 30 packaging tests and the preference migration check
passed. The integrated app's native picker reopened the Downloads dump, showing
216 tables and 20 groups with the compact controls and one filename header.

## Relation range filtering

The Filter popover now includes minimum/maximum Relations bounds. Counts use
foreign-key constraints from the complete catalog, including incoming and outgoing
relationships; composite and self-referencing keys each count once. They remain
stable when other tables are hidden and combine with field and row bounds. Row
count queries run only for tables passing the field and relation bounds.

The five focused UX regression tests passed, including a SQLite fixture with
multiple composite keys, a self-reference, incoming references, and an isolated
table. The actual-dump test cross-checked the research identity table's relation
count against PostgreSQL's constraint catalog and repeated the 216-object grid
matrix. In the native UI, zero relations matched 20 of 216 tables, reopening kept
the entered bounds, reversed bounds showed validation, and Reset restored the full
graph. The toolbar remained one line. The packaged build and `git diff --check`
passed.

## Overview hover previews

Hover now enlarges every table card or overview marker slightly. Below the detail
zoom threshold, the hovered table gets a readable name, field/row counts, and
relation count; its immediate neighbours get name/count annotations and enlarged
markers. Direct links are drawn even when the overview normally shows group
connections. Annotations do not take pointer events, move the saved layout, or
change selection. Their placement avoids one another, the hovered node, controls,
and minimap; crowded/offscreen neighbours are reflected in a remaining-table
count. Unknown row counts are distinct from zero and hovering does not run count
queries.

The packaged build passed. The 53 selected hover, interaction-geometry,
exploration, and geometry tests passed, including scaled row/header alignment,
marker hit targets, unchanged layout positions, dense/narrow viewport placement,
filter scope, and reserved UI areas. SwiftUI image rendering of the actual label
view was inspected with long names, zero/one rows, and unknown counts. The rebuilt
app reopened the supplied dump through its picker. Full live pointer-hover QA
remains unverified: native coordinate actions returned `noWindowsAvailable`,
although accessibility actions and screenshots worked. No claim of a completed
live hover walkthrough is made by these checks.

## Node size by fields, rows, or relations

The Graph options menu now has a Node size submenu with Uniform, Fields, Rows,
and Relations. The choice is saved in preferences. Full-catalog size profiles are
rebuilt when counts or the selected metric change, with logarithmic compression
and a smooth increase in emphasis below the detailed-card zoom threshold. Marker
sizes remain within their existing layout allocation (apart from the existing
minimum visible size and hover enlargement). Detailed cards keep their usual
geometry. Drawing, hit targets, hover labels, and edge anchors share the sized
marker frames. Nonuniform sizing also enables overview markers on small schemas
when zoomed out.

Row sizing does not issue count queries: it uses exact counts already obtained by
filters, otherwise the catalog's available counts/estimates. Unknown row counts
have a neutral size and dashed outline; zero stays a known minimum. Filtering
never enters scale normalization. New count data can legitimately update the
scale, and closing a database discards its profile data.

The packaged build and 59 focused graph tests passed. Tests cover each metric,
zero/unknown/negative counts, extreme outliers, zoom emphasis, unchanged positions,
scaled hit targets, detailed-card geometry, cached updates, preference restore,
composite/self-reference relation counts, stable scales across filtering, and
cleanup on close. Native UI checks with the 216-object dump selected Fields,
Rows, and Relations from the submenu and visually confirmed different marker
sizes and dashed unknown-row markers. The final app is open with Relations
selected. Continuous pointer zoom/hover remains covered by geometry tests rather
than a completed native pointer walkthrough due the automation limitation above.

## Unified database file picker

The welcome screen now has one Choose Database File button, with all supported
SQLite, PostgreSQL backup, and PostgreSQL connection-document extensions below
it. File → Open Database File (⌘O) uses the same picker and automatic document
routing. The separate PostgreSQL picker and menu action were removed.

The packaged build and seven focused archive/open-lifecycle tests passed,
including every supported extension, uppercase extensions, directory navigation,
unsupported-file rejection, SQLite routing, and restoring/reopening the supplied
216-object dump. Native checks confirmed the welcome layout, single File menu
action, opening the supplied dump as PostgreSQL read-only from the welcome
button, and opening Samples/small_sample.sqlite from the same File menu picker.
The rebuilt app was left on the welcome screen.
