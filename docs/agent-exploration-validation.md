# Delivery and validation plan

This plan covers the full [agreed design](agent-exploration-design.md) and the current [62-tool MCP catalog](agent-exploration-mcp-tools.md). Stages establish working dependencies; they do not silently move accepted features out of scope. This remains an acceptance plan; the [implementation status](agent-exploration-implementation-status.md) records what has actually been built and tested.

## Stages and exit evidence

### 1. Prove the live loop and speech path

Build a small typed command path from a bundled stdio helper into the app. Prove status while closed, intentional launch, source identity, a rendered graph selection, one short caption, streamed local speech, playback completion, and immediate cancellation. Use the same path for an immediate unvoiced display. Establish the presentation revision and event contracts before adding many tools.

Evaluate Pocket TTS first using its supported preset-voice path. Pin model, tokenizer, runtime, and voice assets. Record their actual download/install sizes and licenses. Compare VibeVoice and Qwen if quality, streaming, packaging, or target-device performance fails. A manageable development environment is acceptable for this proof; manual runtime installation is not acceptable in the delivered user experience.

Test an actual Codex connection and an actual Claude Code connection, not only a JSON-RPC unit test. Probe their installed protocol versions, tool discovery, result formats, cancellation, and bounded event waits. Do not assume both clients support the newest optional features.

Separately test native Codex voice if available: a difficult model question, a multi-point visualization, a correction during playback, and a long agent reasoning delay. Record whether speech and view timing can be coordinated through supported interfaces. If not proven, retain Graph Studio narration as already selected. No unsupported voice hooks are a delivery dependency.

Exit evidence: protocol traces without row/credential leakage, native view/readiness and audio timestamps, interruption test, a device/runtime-specific speech report, and observed results from both agents. This stage must expose architecture problems early; it does not complete the product.

### 2. Isolate workspaces and source resources

Refactor app/window/source/tab ownership. Introduce the primary workspace tab bar with graph/data split by default and pane maximization. Migrate current state into a first workspace. Support different live databases, restored sources, and artifacts in separate tabs; isolate camera, field selection, filters, query drafts, results, and navigation.

Keep source resources shared where appropriate. Reference-count PostgreSQL restored runtimes and database sessions so closing one tab cannot break another. Define tab ownership and one global narrator. Persist restorable workspaces without automatically executing queries or replaying speech.

Exit evidence: native multi-tab tests with two SQLite databases, PostgreSQL, a preview and a comparison; independent state; restore/relaunch; resource cleanup; existing manual editing still functional.

### 3. Complete inspection and graph/data tools

Implement schema discovery, declared relationship/path selection, arbitrary table subsets, temporary compaction and manual movement, key focus, selected field expansion, metrics, annotations and grouping. Implement grid filtering/sorting, value inspection, record navigation/graph, query preparation/execution/plans/results, jobs and cancellation.

Enforce MCP read-only database access at the backend boundary, including when a manual SQLite tab is writable. Validate tool input, exact source identity, optimistic revisions, typed values, and response limits. Preserve the existing SQLite/PostgreSQL query and record contracts where they are sound; test the actual implementations before assuming their gates cover automation.

Exit evidence: representative real application schema walkthrough, synthetic edge fixtures, both database engines, UI verification, query cancellation and write-rejection tests, and complete schema-to-tool documentation for this tool family.

### 4. Complete live presentation and packaged speech

Implement adaptable point queues, atomic prepared view updates, visible-render acknowledgement, streamed speech, minimum viewing time, text-only reading time, pause/back/next/repeat/end, and history/return behavior. Implement revision cancellation across synthesis, playback, query completion, graph animations, and source refresh.

Respect manual interaction and active-tab visibility. Background agents must not steal focus or audio. Handle disconnects, failed rendering, missing objects, empty results, and unsupported speech without losing the last useful view.

Ship an app-managed, signed/package-compatible runtime and asset installation flow with size, progress, cancellation and retry. Verify a clean machine without development Python, environment variables, cached credentials, or a preinstalled model. Ensure the selected voice/model artifacts remain compatible when pinned.

Exit evidence: recorded timing tests, native interruption and manual-control scenarios, clean-install speech use, warm/cold/memory benchmarks, and both agents extending and correcting a live presentation.

### 5. Complete preferences, artifacts, skills and setup

Implement brief first-use onboarding, general and source-specific preferences, explicit feedback updates, metadata persistence, preview/diff integration, historical explanation saving, separate refresh drafts, and scoped exports. Build both setup entry points on one versioned installer with user-wide defaults, project overrides, merge-safe client configuration, diagnostics, and managed skill updates.

Replace story-flows with the general exploration skill. Update all four retained skills, preserving their CLI/file workflows. Generate client installations and embedded resources from one canonical skill source. Confirm that both app-driven setup and an agent following setup instructions reach the same working state.

Exit evidence: fresh and existing-user installations for both agents; actual discovery and calls; all retained skill workflows; historical replay with the source offline; fresh explanation revision; export verification; preference behavior across agents and databases.

### 6. Retire legacy stories and verify the complete product

Remove the old UI, playback coupling and managed skill. Back up each encountered metadata file before atomically removing its old story entries. Preserve unknown keys and unrelated metadata. Verify recovery from partial migrations, invalid files, read-only folders, and customized skill installations. Do not auto-convert old stories.

Run the complete acceptance matrix below on packaged builds. Resolve regressions across manual browsing, previews, comparisons, backup loading and record/query workflows. Record any unmet acceptance item explicitly. Completion requires all agreed features and required device/client validation; a passing first live demo is insufficient.

## Acceptance matrix

| ID | Scenario | Required result |
| --- | --- | --- |
| A01 | Overview of an unfamiliar model | Short first-use questions; plain-language explanation matched to preference; exact identifiers; useful graph/data split and evidence-backed groups. |
| A02 | Process represented by several tables with mixed schema/code relationships | Agent chooses relevant tables from code and schema; disconnected tables can be close together; application associations have no invented graph edges. |
| A03 | “All tables connected to X,” where X may be a table, process or record | Resolve from context or clarify real ambiguity; honor “all” within stated scope; distinguish declared neighbors, application involvement, and actual matching records. |
| A04 | Agent chooses subsets, additional hops and earlier views | No forced complete neighborhood or story sequence; easy full-model return; history does not revive obsolete actions. |
| A05 | Expand a large table and select a composite PK/FK | Relevant fields plus necessary complete keys; hidden-field count and Show all; correct relation direction, including multiple FKs between the same tables and self-relations. |
| A06 | Drag disconnected tables closer, pan, zoom and pin | Temporary arrangement works without edges; original layout can be restored; manual movement remains smooth and survives late agent callbacks. |
| A07 | Change fields/rows/relationships/uniform node sizing | Per-database user choice persists; agent override is temporary; useful emphasis on zoom out; unknown row counts do not masquerade as zero or cause unrequested full scans. |
| A08 | Inspect full long text, JSON, NULL, empty text and binary data | Correct source/cell identity; raw/formatted view, search and copy; bounded fetches; no truncation described as a complete value. |
| A09 | Sort/filter/page millions of rows | Typed bound filters and deterministic sort where possible; visible filter/sort; bounded result pages and honest counts; no main-thread whole-table load. |
| A10 | Follow records with composite keys, NULLs, missing targets, duplicate values or no stable key | Exact relationship mapping and value binding; correct missing/multiple results; disclose temporary identity; retain navigation history. |
| A11 | Application-defined record mapping | Matching rows can be inspected with provenance; no fabricated declared FK or application-only connection line in the guided graph. |
| A12 | Read-only query with joins, duplicate labels, large integers, decimals and timezone values | Correct typed results and unique result-column IDs; inspectable SQL; stable captured results; explicit limits; no lossy JSON number conversion. |
| A13 | Slow query, large result, empty result, syntax error, disconnected PostgreSQL | Prompt job response, progress where meaningful, cancel/timeout, accurate status; no narration about data that was never shown. |
| A14 | Attempted DDL/DML, writable attachment, mutation-capable CTE/function or forbidden pragma through MCP | Backend rejects unsupported side effects, including in a writable manual SQLite session. Non-executing query explain does not run writes or ANALYZE. |
| A15 | Explicit app Pause/End during synthesis or playback | Audible playback and future actions stop promptly; queued PCM and callbacks from the cancelled revision cannot restart them. |
| A16 | Manual drag/zoom/selection during a spoken point | Finish only the current short point; cancel pending view movement; pause progression; retain manual view; Continue is explicit. |
| A17 | Clarification, correction, and topic change from the agent | Clarification may return; correction replaces obsolete future points; topic change chooses an appropriate workspace; no automatic continuation of outdated claims. |
| A18 | Delayed rendering, delayed data or failed point preparation | Speech waits for actual visible readiness; coherent view updates; last good view retained; Retry/Skip/End available. |
| A19 | Narration finishes before/after minimum viewing time | Advance only after both conditions; paused dwell remains paused; text-only mode has readable pacing; Next can intentionally skip. |
| A20 | Switch tabs, hide/close a narrating view, or disconnect a client | No unseen narration or focus stealing; cancellation and ownership are coherent; reconnect reports actual state before resuming. |
| A21 | Two agents with several tasks and duplicate table names in different sources | Distinct bindings and per-task workspaces; no cross-database reads/updates; one narrator; background preparation remains background. |
| A22 | Primary tabs with SQLite, PostgreSQL, preview, diff and saved explanation | Split default in each tab; pane maximization restores; independent camera/filter/draft/history; source labels and artifact status always clear. |
| A23 | Shared restored PostgreSQL source in two tabs; close either tab | Remaining tab stays usable; final resource release is correct; existing restore safety and cleanup behavior remain intact. |
| A24 | Agent modifies code/schema using its own tools | MCP itself stays read-only; explicit refresh invalidates obsolete IDs/results; comparisons use actual captured versions; manual app editing remains available. |
| A25 | Explain proposed fields/relations and compare actual versions | Preview is clearly proposed; real diff preserves before/after provenance; changed focus can expand to context; no hypothetical artifact presented as a migrated database. |
| A26 | “Document this” versus an ordinary explanation | Requested descriptions/groups/notes save and refresh immediately; ordinary highlights remain temporary; concurrent metadata revisions do not overwrite unrelated changes. |
| A27 | Explicit style correction, “just this time,” another agent, another database | Correct global/source/temporary scope; no repetitive onboarding; first-use skip remains usable; never infer permanent style from a single pause. |
| A28 | Save explanation with table and query evidence, change/delete the source, replay each point, then request refresh | Replay restores each point's referenced captured table/query pane from the artifact without opening or querying the original source; unreferenced saved pages remain available in manual history; refresh is separate with revised claims and no old narration over fresh rows. |
| A29 | Restore application after a crash or normal exit | Tabs/drafts return without automatic query execution or speech; stale display identified; absent sources yield a recoverable state. |
| A30 | App closed during an explicit visualization request and during an ordinary question | Explicit request can launch; status alone does not; optional visualization is offered; no repeated launch approval loop. |
| A31 | Install through app and through each agent, with existing config and project overrides | Same working tools/skills; user-wide default; unrelated config preserved; version diagnostics and real connection test; no development path dependency. |
| A32 | All retained skills with and without MCP | Clustering, descriptions, preview and diff retain their capabilities; offline CLI/file workflows work; story-specific constraints are gone. |
| A33 | Narration enabled on a clean 8 GB Apple Silicon Mac | App manages runtime/model assets; size/progress/cancel/retry; natural English speech; interactive graph and bounded memory under a normal coding workload. |
| A34 | Model download interrupted/offline, missing asset or synthesis failure | Visual/text flow continues; useful status; resumed/retried download verifies pinned assets; no hidden manual Python requirement. |
| A35 | Local bridge request times out after applying an action | Reconcile using request receipt and revision; retry does not create duplicate tabs, exports, saved artifacts or repeated narration. |
| A36 | Legacy metadata containing stories, notes, groups, mappings and unknown fields | Verified backup before write; only legacy stories removed; other data preserved; repeated migration is safe; failure leaves original intact. |
| A37 | Export displayed rows versus all matching rows | Explicit scope and destination; correct counts/types/escaping; cancellable atomic output; no silent overwrite or scope expansion. |
| A38 | Keyboard, screen reader, reduced motion and narration disabled | Core browsing and explanation controls remain usable; captions and exact selection are understandable without sound or animation. |

## Performance and speech measurements

Run a reproducible workload with hundreds of tables, millions of rows accessed through paged reads, several tabs, a coding client, and warm narration. Include both a real application schema and deterministic fixtures for edge cases. Thousands of tables are a stress test, separate from the required baseline.

Record hardware, RAM, OS, build configuration, dataset shape, installed asset versions, model precision, voice, and other running applications. An 8 GB target must be tested on an 8 GB machine; a higher-memory run alone cannot certify it.

| Measurement | Evidence to collect |
| --- | --- |
| UI responsiveness | Native frame/event latency while dragging and zooming under speech/query load; p50/p95/max, visible stalls, and recording of the workload. |
| Memory and resource use | App plus worker peak and steady resident memory, system memory pressure, swap trend, CPU use, thermal behavior, idle resource release. |
| Warm first audio | Time from complete point narration text to first generated PCM and separately to first audible sample; target approximately one second to audible output. |
| Cold start | Asset availability, worker startup, model/voice load and first audible output measured separately; no conflation with agent reasoning. |
| Sustained streaming | Real-time factor, output underruns, long-point behavior, transitions between points, and generation stopping on cancellation. |
| Interruption | User input to muted output and invalidated view queue; propose a 150 ms local stop target, then verify against the audio-device buffer. |
| Visual/speech order | Renderer-visible acknowledgement precedes audible narration; minimum dwell satisfied; background tabs are never marked shown. |
| Quality | Listen to ordinary explanations, identifiers, acronyms, dates, numbers, NULL, long names, and short corrections; assess intelligibility, naturalness and pronunciation stability. |

Existing [canvas measurements](benchmarks/canvas-2026-09-05.json) cover CPU preparation/pointer work rather than native drawing and event latency. They can guide investigation but do not establish that the new UI meets its responsiveness requirement.

If no candidate meets the required memory, quality and responsiveness combination, document the measured tradeoff and revisit the speech implementation. Do not silently lower the 8 GB requirement, substitute a cloud service, or declare a vendor latency claim to be a product measurement.

## Verification strategy

Use focused automated tests for the consequential contracts: source/workspace isolation, revision cancellation, scheduling, read-only enforcement, typed query results, metadata preservation, artifact provenance, idempotent retries and protocol compatibility. Use integration tests with actual SQLite and PostgreSQL services for engine-specific behavior. A mocked database or a docs-only check cannot prove those properties.

Use native app interaction for graph dragging/zoom, tab focus, split layout, full-value inspection, audio controls, and accessibility. Exercise real Codex and Claude Code installations for setup and live orchestration. Verify the packaged build on a clean target environment for runtime dependencies, asset downloads and relaunch behavior.

The final delivery report should identify each completed stage, acceptance evidence, measured speech/runtime choice, tested clients and hardware, and any remaining failures. Unsupported optional native voice integration is reported separately from the required local narration path. Completion means the agreed full product works, with no outstanding required acceptance items hidden behind a successful demo.
