# Local MCP tool catalog

Companion to the [product design](agent-exploration-design.md). The bundled local MCP exposes 62 tools, grouped by intent. This guide explains when an agent should use them. The bundled [JSON catalog](../Sources/StudioMCP/Resources/ToolCatalog.json) defines their current arguments and descriptions; see the [implementation status](agent-exploration-implementation-status.md) for verified behavior and remaining release gates.

The tools expose the application's useful inspection and presentation capabilities. They do not require a story or narration. Every tool that changes the view can also be used without speech. The server never exposes actual database writes or arbitrary code execution.

Reconnect recovery lasts only while the current Graph Studio app process remains open. The resume token and receipts are held in memory and are invalidated when the app exits; after that, connect a new context and explicitly select the intended workspace/source. A resumed export request returns its original job receipt; because disconnect stops active exports, inspect that job's status before starting a new export with a new request ID.

## Common contracts

### Addressing and current state

- `studio_connect_context` returns an opaque `context_id`, random `resume_token`, and `client_task_id` claim. Keep all three in that coding task's own session state. To resume after stdio disconnect while Graph Studio remains open, pass the old context as `resume_context_id`, the matching task ID, and the current token; successful recovery rotates the token. The task label is not authentication, and an active context cannot be taken over by another client.
- Source-bound operations use an explicit `source_id`; view operations also use a `workspace_id`. Bindings can fill these for an established context, but responses always identify the actual source and workspace. Ambiguity produces candidates, not a guessed target.
- Tables, columns, relationships, records, result columns, jobs, and artifacts have opaque IDs. Exact display names accompany IDs. Do not split a qualified identifier on dots or use a row's visible index as its permanent identity.
- Source/schema revisions and workspace/view revisions are separate. UI changes support an `expected_view_revision`; source-dependent actions require a matching `source_revision`. Stale requests return current context and a recovery instruction rather than silently applying to another version.
- Mutating requests carry a `request_id`. Receipts are scoped to the stable task context rather than a short-lived stdio client ID. Repeating the same request ID and arguments after reconnect returns the original outcome; reusing it with different arguments is an error. Detached contexts, workspace ownership, artifacts, and receipts remain in memory for up to 24 hours; retention is capped at 128 detached contexts and 4,096 receipts. A native tab transfer remains authoritative and is never undone by reconnect. An uncertain outcome is reconciled before retrying.
- An agent controls its own workspace. Inspecting the active user selection is allowed when relevant, but changing another task's workspace or taking over narration requires an explicit foreground user action/request. Client-supplied task labels are not treated as authentication.

### Results and limits

Return structured content plus a concise human-readable summary. Include affected IDs, revisions, effective limits, warnings, and any recovery action. Distinguish accepted, prepared, applied, rendered in background, and visible. An accepted request is not evidence the user saw it. The same applies to narration queued, generation started, audible playback, and playback finished.

Large operations return a `job_id` promptly. Jobs expose progress where measurable, cancellation, terminal status, and partial/truncated output explicitly. Current limits are 100 rows by default (up to 500 where the tool allows it), a 30-second maximum query timeout, and a hard 1 MiB serialized MCP response cap. Query-job previews contain at most 10 rows, 20 columns, and 256 text characters per cell. SQLite and PostgreSQL row, query, and record reads enforce a backend materialization budget of 512 columns, 256 KiB per text/binary cell, and 8 MiB per result page. MCP reads reject an over-budget result with an actionable error. The native table grid may omit an oversized non-key cell and labels it “Large value — inspect in slices”; use `studio_inspect_value` to retrieve a large cell in bounded pieces. These limits do not imply that a partial cell is a complete value or that a page exceeding the budget was returned in full.

Represent large integers, decimals, binary data, timestamps, NULL, and empty strings without lossy coercion. Preserve duplicate query labels through distinct column IDs. Result sets describe whether they represent a fixed snapshot or a later live page; unstable paging must not be presented as one immutable result.

Errors use a stable code, useful explanation, retained state, and suggested next action. Expected examples: `APP_NOT_RUNNING`, `AMBIGUOUS_SOURCE`, `STALE_SOURCE`, `STALE_VIEW`, `OBJECT_NOT_FOUND`, `NOT_VISIBLE`, `NOT_OWNER`, `READ_ONLY_VIOLATION`, `LIMIT_REACHED`, `CANCELLED`, `SPEECH_UNAVAILABLE`, and `ARTIFACT_VERSION_UNSUPPORTED`.

### Effects and discoverability

Use accurate MCP annotations. A database read may be read-only, but opening a tab, speaking, exporting a file, or saving a preference changes state and must not be mislabeled read-only. Schema names, row values, descriptions, and other database content are data, never tool instructions.

Descriptions below are intended as the basis of the actual agent-visible descriptions. Keep common mechanics in shared schemas/server instructions, and return useful next-tool hints in context. Skills provide workflows; they do not replace self-explanatory tool definitions. Use client tool search/deferred loading where supported, without making it a prerequisite for either client. Do not replace the catalog with a generic “execute arbitrary action” tool to reduce tool count.

## Connection and workspaces

| Tool | Agent-visible description | Main inputs | Result and effect |
| --- | --- | --- | --- |
| `studio_status` | Check whether Graph Studio, its bridge, and supported capabilities are available. Use before deciding whether to offer or open a visualization. This does not launch the app. | Optional `context_id` | Installed/running state, versions, client compatibility, connection diagnostics, capabilities and limits. No UI change. |
| `studio_connect_context` | Create this task's context or resume it after stdio loss. For recovery, provide the prior `context_id` as `resume_context_id`, the matching `client_task_id`, and the current secret `resume_token`; task labels alone never recover state. A successful resume rotates the token and never takes back a tab explicitly transferred by the user. | Task identity, optional `resume_context_id` + `resume_token`, optional deliberate `workspace_id` | Opaque `context_id`, rotating resume token, recovery status, visible workspace choices, and current ownership. |
| `studio_launch` | Open Graph Studio for a requested visualization and wait for bridge readiness. Use when the user asked to see something or accepted an offer to visualize it. | Context, foreground intent, optional known workspace | App instance and readiness or actionable failure. Launches/foregrounds only as requested; no database inferred from an arbitrary recent file. |
| `studio_scan_project` | Scan a project folder for exact database, PostgreSQL connection/backup, migration-set, and schema-script candidates. Use when the user gives a repository rather than one source; choose based on their question and code context. The bounded, ignore-aware scan never opens a candidate. | Context, project path, candidate offset/limit | Paged candidate IDs and exact source paths, scan counts, and a limit flag. Narrow the folder if the scan reached its 50,000-entry cap. |
| `studio_open_source` | Open an exact SQLite file, PostgreSQL connection/backup, saved schema artifact, migration-set folder, or SQL schema script. A general project folder requires `studio_scan_project` and an explicit candidate choice. | Context, exact source path, optional migration version, activation, request ID | Source identity, revision and capabilities or an actionable failure. Migration models expose schema only, with no row or query operations. |
| `studio_list_workspaces` | List workspace tabs and their source labels so you can reuse the right view without disturbing unrelated work. | Context, optional source filter | IDs, titles, source identity, active/visible/owned status, and presentation state. Read-only. |
| `studio_create_workspace` | Create an exploration or comparison tab, optionally duplicating an existing view. New tabs use graph/data split by default and stay in the background unless foreground presentation was requested. | Source/artifact, title, optional `duplicate_from`, activation intent | Workspace ID and initial revision. Does not clone or mutate the database. |
| `studio_update_workspace` | Rename, reorder, or explicitly activate an existing workspace. Use activation for an intended foreground presentation, not for background preparation. | Workspace, typed changes, expected revision | Updated tab state. Changing the active narrator's visibility pauses its presentation. |
| `studio_close_workspace` | Close a workspace and cancel its pending work. Use when asked to close it; preserve restorable drafts and release shared source resources only when no remaining workspace uses them. | Workspace, expected revision | Closure receipt, saved draft state, cancelled jobs. No source file deletion. |
| `studio_get_view` | Read the current panes, camera, selection, expanded fields, filters, query/result context, and presentation state. Use for “explain this” or before adapting to manual interaction. | Workspace, detail sections, optional bounded selected-value request | Exact current context and revisions. Row values are omitted unless requested; selection does not start an explanation. |
| `studio_set_layout` | Set graph/data split, resize the split, or maximize a pane while preserving its content. Use to make the current material readable without opening an unrelated workspace. | Workspace, layout, split fraction, pane contents | Applied layout and readiness. Default remains split; source changes require opening a source/workspace explicitly. |
| `studio_capture_view` | Capture a restorable view checkpoint before a temporary focus or rearrangement. Use to support Back or Return to previous workspace; this does not save an explanation artifact. | Workspace, optional label | Checkpoint ID with source/view revision. Ephemeral view state, without a new database snapshot. |
| `studio_restore_view` | Restore a captured view or an earlier navigation entry without replaying old pending actions. Use to return from a focused explanation; report missing objects if the schema changed. | Workspace, checkpoint/history entry | Restored camera, arrangement, selection, panes and filters; incompatibilities are explicit. No automatic narration. |

## Schema discovery and graph control

| Tool | Agent-visible description | Main inputs | Result and effect |
| --- | --- | --- | --- |
| `studio_search_schema` | Find tables, fields, and documented concepts by exact name or search text. Use to resolve the user's vocabulary before selecting objects; return evidence for matches rather than claiming a business relationship from a name. | Source, text, kinds, match mode, cursor | Bounded candidates with exact IDs/names, descriptions, and match reason. No graph change. |
| `studio_describe_schema` | Read selected schema facts, including columns, keys, constraints, indexes, views, and existing descriptions. Use a summary for an overview and targeted detail for an explanation. | Source, object IDs or summary scope, sections, cursor | Facts and source revision, count estimates with provenance, metadata evidence. Does not scan all rows by default. |
| `studio_find_relations` | Find declared neighbors, key relationships, or paths between selected objects. Use to choose a useful subset or explain actual database links; application-only associations are not returned as declared edges. | Source, seeds, neighbors/path mode, direction, hops, relation filters, result budget | Exact relationship IDs, ordered key pairs, path candidates and truncation. No obligation to display every result. |
| `studio_refresh_source` | Refresh schema and requested data after external changes. Use after the coding agent modifies a database or when the user requests fresh facts. Report affected views and invalidate stale jobs instead of mixing versions. | Source, schema/data sections, workspace scope | Refresh job, new revision and invalidated IDs. Keeps saved explanations historical and pauses affected presentations. |
| `studio_show_tables` | Show an exact chosen table set, add or remove tables, or return to the full model. Use for overviews, process subsets, or co-displaying application-related tables; proximity never creates a relationship edge. | Workspace, table IDs, replace/add/remove/all, visibility treatment, fit intent | Actual visible IDs and declared edges. Temporary focus; no metadata persistence. |
| `studio_select_objects` | Select or highlight exact tables, columns, declared relationships, or visible records. Use to direct attention to what you are explaining while keeping identifiers visible. | Workspace, IDs, replace/add/remove, emphasis style | Selection and rendered targets. Unsupported or hidden targets are reported, not silently guessed. |
| `studio_expand_tables` | Expand tables to a selected field set or all fields, or collapse them. Use relevant fields and necessary keys for readability; keep a visible indication and Show all control for hidden fields. | Workspace, per-table field IDs/all/collapse, include necessary keys | Visible fields and omitted counts. Retains the user's ability to expand manually. |
| `studio_focus_keys` | Focus selected primary/foreign keys and their declared connections. Use for a key explanation, choosing which connected tables to show and whether to compact their layout. | Workspace, key/relationship IDs, subset, direction, optional compact layout | Focused key pairs and table set. Composite keys stay intact; saves a return checkpoint when requested. |
| `studio_set_camera` | Fit selected objects, fit the model, pan, or set zoom. Use to make the current focus readable; honor reduced motion and yield immediately when the user manipulates the graph. | Workspace, typed camera mode, targets/coordinates, optional animation | Camera state and render completion. A pending camera action cannot override a newer manual view revision. |
| `studio_arrange_tables` | Temporarily compact, position, pin, unpin, or relayout chosen tables, including disconnected ones. Use to improve comparison and readability without implying a relationship. | Workspace, table IDs, arrangement mode/positions, checkpoint | Applied positions and restore checkpoint. Other tables remain stable where possible; no invented edge or saved grouping. |
| `studio_set_node_sizing` | Set temporary node emphasis by field count, row count, relationship count, or uniform size. Use to explain scale or structure; unknown counts stay unknown. | Workspace, metric, zoom emphasis settings, selected emphasis | Effective sizing state. Durable user defaults belong in preferences; this does not trigger expensive exact counts. |
| `studio_set_groups` | Apply temporary named/color groups for a useful lens such as domain or workflow. Use to organize an explanation; a group is not a database relationship. | Workspace, groups and table IDs, replace/merge | Displayed groups and legend. Persist requested grouping with `studio_update_annotations`. |
| `studio_annotate_view` | Add, replace, or clear temporary captions, highlights, and anchored notes. Use human-language explanations and evidence labels; this tool cannot draw an inferred relationship between tables. | Workspace, annotation IDs, text, anchors, evidence references, operation | Visible annotations. Plain text with validated anchors; no arbitrary HTML, scripts, or custom relation edges. |

## Tables, records, and queries

| Tool | Agent-visible description | Main inputs | Result and effect |
| --- | --- | --- | --- |
| `studio_open_table` | Open a table or view in the workspace's table pane and coordinate its graph selection. On a database source it loads a bounded row page; on a migration model it shows column definitions without rows. | Workspace, table ID, request ID | Table tab ID, schema-only flag, and row readiness. It does not automatically return all displayed values to the agent. |
| `studio_configure_table` | Apply text search, typed filters, one sort column, or a page size to the table grid. Multi-column sorting is unsupported; use a read-only SQL query when several sort keys are needed. | Workspace, table, filters, one sort column, page size, expected view revision | Current grid configuration and load state. |
| `studio_fetch_rows` | Read a bounded offset page from a named table. Supply `column_ids` to project only the requested values at the database boundary; declared key columns may also be read for row identity but are not returned unless requested. Use another offset for the next page; stable cursors, exact counts, and a byte-budget input are unavailable. | Source/workspace, table, optional column IDs, filters, one sort column, search text, offset, row limit | Typed projected values, returned offset/limit and `has_more`. No view mutation. SQLite pages are additionally subject to the hard cell/column/page materialization bounds above. |
| `studio_inspect_value` | Read one exact cell using a database-side bounded slice. Default `display_intent=data` returns at most 4096 characters or bytes, full byte/character counts, type, NULL/empty distinction, and truthful continuation metadata without changing the view. Set `value_offset` to read another slice. Use `display_intent=show` only when the user wants the selected cell visible; it opens a one-cell inspector that says when the displayed value is partial. | Table/column, filtered and sorted `row_index`, optional stale-view guard, character/byte `value_offset`, capped `max_length`, data/show intent | Typed slice, byte/character counts, `complete`, `truncated`, `has_more`, and optional bounded inspector state. Binary slices use base64. Other row fields and key identity are not loaded. |
| `studio_list_record_mappings` | Discover or read exact application-defined record graph mappings saved in the source sidecar. Call before following a non-foreign-key association; then use a returned usable `mapping_id` with `studio_follow_record`. These mappings are not database-declared foreign keys, so never invent a `relation_id`. Invalid or duplicate IDs include diagnostics. | Source/workspace, optional exact mapping ID, bounded offset and page size | At most 5 complete validated definitions per page, typed scope filters, sidecar index provenance, followability and validation status. Long strings are bounded, BLOB filter values are omitted, and no rows or files are read or changed. |
| `studio_follow_record` | Follow a selected record through an exact declared relationship or an explicitly identified application mapping. Use `relation_id` only for a database-declared edge; for a sidecar mapping, first discover its exact ID with `studio_list_record_mappings` and pass that as `mapping_id`. | Record identity, relation/mapping ID, direction, display intent | Bounded related records/edges, page continuation, provenance and visible inspector state. No fabricated schema edge; unstable identities are disclosed. |
| `studio_show_record_graph` | Display a bounded record neighborhood when relationships between particular rows are clearer as a graph. Use with exact record identities and selectable expansion limits. | Workspace, seed records, declared relation selection, direction, hops, node budget | Rendered record IDs, declared links, omissions and expansion controls. Application-only associations remain unconnected and explained in text. |
| `studio_prepare_query` | Put SQL and its plain-language purpose in a query editor without executing it. Use when preparing a query for inspection or continuing a saved draft. | Workspace, SQL, parameter values, purpose, existing draft ID | Draft ID and editor state. Replacing a draft uses its expected revision and preserves navigation history. |
| `studio_run_query` | Start one permitted read-only SELECT, VALUES, or WITH query and return promptly with a cancellable job ID. Poll `studio_get_job`; when complete, use `studio_show_query_results` if the user should see the captured result. Writes and unsupported side-effecting operations are rejected. | Source/workspace, SQL, timeout (1–30 seconds), row limit (up to 500), request ID | Job ID immediately; later status, immutable result ID and preview capped at 10 rows, 20 columns and 256 text characters per cell. The captured result is subject to the backend page/materialization budget. |
| `studio_explain_query` | Obtain a non-executing plan for a permitted read-only query. Use to explain joins or likely query work; this is not a runtime measurement or an EXPLAIN ANALYZE request. | Source/draft, SQL, parameters | Engine plan and limitations. No query execution for timing; no mutable statement plans. |
| `studio_fetch_query_results` | Read a bounded offset page from a query result retained in this app instance and workspace. An expired result requires running the query again; this tool does not support cursors or byte-budget paging. | Workspace, result ID, offset, row limit (up to 100) | Typed bounded page from the same captured result. Expired handles return a clear re-run choice. |
| `studio_show_query_results` | Show an existing result in the current workspace, optionally emphasizing columns or rows. Use to explain query output while retaining access to the SQL and source context. | Workspace, result ID, column order, highlights, optional linked schema IDs | Rendered result state. Post-result filtering/sorting is explicitly scoped to captured rows; a whole-query transformation requires a new read-only query. |
| `studio_get_job` | Inspect a query, export or speech job owned by this task context. For a query, poll until completed, failed or cancelled; completion provides `result_id` and a bounded preview. Use `studio_show_query_results` to show that captured result in the app, or `studio_fetch_query_results` for more rows. | Job ID, optional exact workspace ID | Current status and kind-specific result/progress/error details. Query results are discarded when their source changes or workspace closes. |
| `studio_cancel_job` | Stop a query when the user interrupts, corrects the request or changes direction; cancellation waits for the database read to stop and returns the final state. Also cancels exports or speech operations owned by this task. | Job ID, optional exact workspace ID, request ID | Final cancellation receipt. A cancelled query has no result handle and cannot publish stale results. |

Read-only enforcement must include the execution engine, statement controls, and permitted functions/extensions. SQLite automation must deny writable attachments, extension loading, and mutating pragmas as well as ordinary writes. PostgreSQL execution uses read-only transaction/session controls and rejects unsupported side-effecting operations. Do not treat a leading `SELECT`, tool annotation, or a SQL parser alone as proof of harmless execution. Validate the existing backend gates before reusing them.

## Presentation and events

| Tool | Agent-visible description | Main inputs | Result and effect |
| --- | --- | --- | --- |
| `studio_start_presentation` | Begin a freeform visual explanation in a task's workspace with optional narration. Use one or several short points; Graph Studio waits for visible views and actual audio completion before advancing. | Workspace, title, initial points, narration mode, start policy, return checkpoint | Presentation ID/revision and current state. No story fields required; foreground/narrator ownership is explicit. |
| `studio_update_presentation` | Append points, replace pending points, or revise the current explanation after a correction. Use small adaptable batches; invalidate obsolete actions and audio rather than continuing the old answer. | Presentation, expected revision, append/replace-pending/replace-current-and-pending, points, optional finish-after-queue | New revision and accepted/invalidated point IDs. Correcting the active point pauses it before replacement; completed history is retained. |
| `studio_control_presentation` | Pause, continue, go back, go next, repeat the current point, change speed, end, or return to the preceding workspace. Use Pause/End for immediate interruption; continuing never revives cancelled points. | Presentation, control enum, optional point/speed/expected revision | Actual control state, visible point and remaining dwell. Back/Next use validated history and prepared actions; failures do not trigger unsupported narration. |
| `studio_get_presentation` | Read what is actually visible, speaking, waiting, paused, or finished, including pending point IDs and recent interaction. Use to synchronize reasoning with the user's experience. | Presentation, history/pending detail limits | Point/revision, visual readiness, audible state, dwell, manual-interaction reason, history cursor and recovery options. |
| `studio_wait_events` | Wait briefly for view readiness, playback completion, manual interaction, job progress, or a pause. Use while actively orchestrating a live explanation; timeout returns current state and a resumable cursor. | Context, optional workspace/presentation/job filters, `after_cursor`, bounded wait | Ordered events, new cursor and current revisions. Lost/expired cursors require state reconciliation. This does not wake an idle agent or receive microphone audio. |

### Point format

The following is an illustrative request payload, not an implemented schema. IDs in real calls come from discovery. There is no inferred edge between the two example tables.

```json
{
  "point_id": "approval-context",
  "caption": "These tables support the same approval process.",
  "narration": "The application uses requests and audit entries during approval. There is no declared foreign key between these two tables.",
  "pronunciations": [],
  "actions": [
    {
      "type": "show_tables",
      "table_ids": ["table:requests", "table:audit_entries"],
      "mode": "replace"
    },
    {
      "type": "arrange_tables",
      "table_ids": ["table:requests", "table:audit_entries"],
      "mode": "compact"
    }
  ],
  "evidence": [
    { "kind": "schema", "source_revision": "schema:r17" },
    { "kind": "code", "reference": "src/approval.ts:42", "revision": "example-commit" }
  ],
  "timing": {
    "minimum_visible_ms": 5000,
    "extra_hold_ms": 1000,
    "advance": "automatic"
  }
}
```

Actions reuse the same validated view-command types as the individual tools. The permitted action set covers layout, table visibility, selection, expansion, key focus, camera, arrangement, sizing, temporary groups/annotations, grid configuration, prepared record/result views, and artifact focus. It excludes file writes, database queries, model installation, and arbitrary tool calls inside a point. Perform those as explicit jobs first and reference their ready outputs. An action batch either applies coherently or leaves the previous view intact.

Optional narration and empty action lists allow a text-only explanation or speaking about the view already on screen. A point can use `advance: "manual"`. The app supplies a reading-time default for text-only points; the agent can set longer viewing time. No fixed slide count, workflow structure, or requirement to visit every related table is imposed.

## Preferences and durable descriptions

| Tool | Agent-visible description | Main inputs | Result and effect |
| --- | --- | --- | --- |
| `studio_get_preferences` | Read general explanation preferences and familiarity with this source, including whether first-use questions have been answered. Use to tailor detail without repeatedly onboarding the user. | Context, optional source | Preference values, scope, explicit feedback provenance and onboarding state. |
| `studio_update_preferences` | Save an explicit preference or first-use answer, or apply a one-answer override. Use when the user asks for a different explanation style; honor “just this time.” | Scope, typed preference patch, source where needed, durable/temporary, feedback reference | Updated values and scope. Persistent user preferences are distinct from temporary presentation settings. |
| `studio_get_annotations` | Read the current metadata revision, saved table/column descriptions, graph clusters and a bounded page of durable notes. Use `studio_list_record_mappings` for mapping definitions and provenance. | Source, optional object IDs, note offset/limit | Saved annotations, active groups, mapping count and `metadata_revision`. No view or file change. |
| `studio_update_annotations` | Save requested descriptions, graph groups and/or durable notes. First read `metadata_revision`; send it as `expected_metadata_revision`. On conflict, re-read and merge before retrying with a new request ID. This tool does not create or edit record mappings. | Source, expected revision, typed patch, request ID | New revision and refreshed affected views. Application-level notes do not add database edges. |

## Proposed changes, comparisons, saving, and export

| Tool | Agent-visible description | Main inputs | Result and effect |
| --- | --- | --- | --- |
| `studio_capture_schema` | Capture a real source schema as a versioned baseline for preview or comparison. Use before design changes or when recording an actual database version; this does not execute migrations. | Source, artifact destination/managed destination, revision label | Immutable snapshot artifact, engine, source/time and fingerprint. Creates a local artifact; no row dump. |
| `studio_inspect_artifact` | Inspect a captured schema, compact proposal, comparison, saved explanation, or fresh refresh draft by summary or exact object. Use exact table IDs to read saved fields, key relations, and only the row pages present in that artifact. | Artifact ID/path, exact object/search, detail scope, cursor | Artifact kind, version, fingerprints, object facts and historical/proposed labels. No source refresh; refresh drafts expose fresh facts without old narration. |
| `studio_update_preview` | Create or revise a proposed schema from a captured baseline and compact change plan. Use to show a design before implementing it; projected types/defaults are not an executed migration or a correctness guarantee. | Baseline fingerprint, typed plan, artifact destination/existing ID, expected artifact revision | Projected preview artifact and validation diagnostics, refreshed open preview tab. Actual database remains unchanged. |
| `studio_compare_schemas` | Compare two real captured schema versions using the existing diff rules. Use for before/after review; reject presenting a hypothetical preview as an actual migrated database. | Before/after snapshots, engine policy, comparison destination | Versioned comparison artifact, changed objects and provenance. Creates local artifact only. |
| `studio_show_artifact` | Open or focus a preview/comparison in its own split workspace and show selected changes, surrounding context, or a chosen version. Use to explain impact while clearly labeling proposed versus captured state. | Artifact, workspace/new-tab intent, changed/all/subset focus, version | Visible object/version IDs, graph plus details, readiness. Proposed edges stay explicitly marked. |
| `studio_save_explanation` | Save only points already displayed, and only after the user asks. Select exact cached query result pages or already loaded table pages in `included_result_scope`; omit the scope to save no row values. | Active presentation, title, optional path, explicit result/page IDs | Atomic `.sgexplanation` with schema, captions/words, typed visual actions, evidence IDs, source hashes, capture time, and at most 1,000 selected rows. SQL, source locators, schema defaults/definitions, and credential-like columns are omitted or redacted. No overwrite. |
| `studio_open_explanation` | Open a saved artifact in a new isolated offline tab. Manual mode shows the historical graph, captured values, and captions; replay mode applies supported graph actions while presenting saved captions/words. | Artifact path/ID, manual or replay mode | No live source is opened or queried. This build does not replay table/query panes; skipped action types are reported and captured values remain visible in the historical detail panel. |
| `studio_prepare_explanation_refresh` | After the user asks for fresh data, bind an exact currently open `source_id` and choose table pages to read. The result is a separate draft for rewriting claims. | Historical artifact, current source ID, optional table page scope | Atomic `.sgrefresh` with the new schema, bounded selected rows, and schema changes. It cannot contain the old captions or narration; the old artifact remains unchanged. |
| `studio_export` | Export CSV or JSON for a selected table page, all rows matching a table grid's filters and sort, a displayed page or captured bounded query result, or a visible explanation transcript. Choose `scope.kind` explicitly. Query snapshots are never rerun as all-matching. Existing destinations fail unless overwrite is explicitly true. All-matching table exports have a timeout capped at 300 seconds. Graph images and explanation packages return `TOOL_UNAVAILABLE` in this build. | Object/workspace, CSV/JSON format, explicit scope, absolute destination, overwrite intent, optional timeout | Immediate export job ID, then progress, output path, row count, truncation and source/workspace provenance through `studio_get_job`. |

## Speech configuration

| Tool | Agent-visible description | Main inputs | Result and effect |
| --- | --- | --- | --- |
| `studio_get_speech` | Check narration availability, active model/voice, asset status, and warm/cold state. Use before offering voice or explaining a speech failure. | Optional context | Provider/version, supported voices, asset download size, readiness, active narrator and diagnostic status. No download. |
| `studio_configure_speech` | Enable/disable narration or select an installed supported preset voice and speed. Use for the user's audio preference; missing assets produce an install offer rather than a hidden environment setup. | Typed settings, scope, durable/temporary | Effective settings and readiness. No microphone capture or arbitrary voice cloning. |
| `studio_manage_speech_assets` | Present or continue the app's download, cancel it, or retry installation for a supported model/voice package. Use when the user enables narration; show size and progress and let visual explanations continue. | Supported package ID, offer/install/cancel/retry, existing job where applicable | Native install offer or managed job. Pinned assets only; no arbitrary executable/URL downloads or silent acceptance of gated terms. |
| `studio_test_speech` | Play a short requested sample or run the defined local speech diagnostic in the owning visible workspace. Use to compare voice quality and measure actual start/cancel behavior on this device. | Preset voice, bounded text or diagnostic ID, workspace | Audible sample or benchmark job/results with hardware/runtime identity. Does not interrupt another task's narrator. |

## Workflows the tools must support

### “Give me an overview of this data model”

Resolve the task source, read explanation preferences, and inspect a schema summary and relevant documentation. Create or reuse the task workspace. Present useful groups with an initial overview, then add points only where detail helps. Use declared edges, exact identifiers, and plain-language captions. A small model may need just one view.

### “Show all tables connected to process X”

Clarify whether X is a table, a record, or an application process only when the context does not resolve it. For a table, inspect declared paths/neighbors. For a process, use code evidence to choose tables, co-displaying those without foreign keys as unconnected. For a record, follow actual key values and show matching rows. “All” is an explicit scope request: cover the requested set, using several views if necessary, and disclose any traversal limits.

### “These records look wrong; show me why”

Read the selected cell/record and current filters. Fetch only relevant values, inspect declared related records, or prepare/run a read-only query. Show filters and SQL, label empty or truncated results, and distinguish what the data proves from a likely application explanation. Open a full-value inspector where the discrepancy involves JSON or long text.

### “Add an approval status and show the impact”

Use `database-preview` with a captured baseline and compact plan. Open a proposal tab, show the changed table and relevant context, and explain consequences. The agent implements requested code/migration changes through its normal coding tools. Capture actual resulting schemas and use `database-diff` for comparison; the MCP server does not execute the migration.

### “Wait, I meant the renewal process”

The app Pause button can stop immediately while the agent is still busy. Once the correction reaches the agent, read the current state, replace pending points and their audio revision, choose the corrected table set, and continue only with the corrected explanation. Keep prior views in history without retaining obsolete future actions. If the user manually moved a table, do not discard that view just because an earlier request finished later.

### “Save this, and next time explain it more simply”

Save the bounded historical explanation and update the explicit explanation preference. Reopening the saved artifact uses captured data. A later request to refresh creates a distinct draft and requires updated claims, rather than replaying the historical words over live rows.

Historical artifact format in this build: `.sgexplanation` files are limited to 16 MiB and stored with user-only file permissions. Offline replay restores schema graph/layout/table selections and shows the captured table/query pages referenced by the current point. It reads only the artifact; it never reopens or queries the original source. Included pages with no point reference remain available in the manual historical detail view. `.sgrefresh` is a fresh-only draft and never carries historical narration forward.
