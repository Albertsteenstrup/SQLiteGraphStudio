# Project Changes Log

This file tracks intentional changes made to the codebase that should NOT be reverted.

## Surface Corners

- Use subtle 8-point corners for workspace panes, graph cards and content panels, with 6-point controls and 4-point row highlights. Keep borders, clipping, hit areas and native workspace captures aligned across the app and embedded MCP views.

## Graph Selection Appearance

- Show selected nodes through their background tint. Remove the extra selection outline and selection-specific border emphasis from the shared graph renderer, including cards, multi-selection and overview marks, so the native app and embedded MCP views match. Keep ordinary card, group and schema-change borders.

## Embedded Data in Coding-Agent Conversations

- Embedded graph inspection stays usable after selecting or moving a node. Nodes can be expanded and dragged; zoom commits a fresh Retina frame, preferring lossless text. A full-model context toggle and agent-directed context points highlight a focused group across the complete schema. Card-size-aware layout and separated relationship lanes improve edge and cardinality legibility. Stable caption/status space reduces embedded-card resize churn during audio.

- Reuse loaded migration schema definitions during source-revision checks, invalidating on every catalog assignment and keeping file freshness checks active. Capture graph pixels after the drawing receipt settles so image updates match node hit regions.

- Remove the native player and saved-story reader, including file-picker/Finder registration and restoration of old story tabs. Explanations are exclusively embedded MCP steps: no local speech, timed advancement, native-window visibility acknowledgement, or native fallback on card release/expiry/disconnect. Keep portable files and captured table/query evidence available through MCP.

- Animate embedded camera/focus changes, data-panel transitions and captions. Capture the graph for its final layout before committing a step, preserve image proportions, and acknowledge visibility only after motion settles. Respect reduced motion and cancel superseded transitions on navigation, gestures, source changes and teardown.

- Show a compact current/total page count, such as 1/4, between Back and Next in the embedded view. Keep it synchronized with reader and MCP navigation.

- Add the same Graph Studio logo shortcut as the embedded diff. Clicking it selects the card's validated workspace and brings the paired native app forward, preserving the current explanation step. Check source identity/revision and context ownership before selecting the workspace.

- Replace the embedded player with Back/Next step navigation and a counter. The reader or MCP chooses when to move; timers and local speech are suppressed so Codex audio can accompany the graph. The final step stays visible and appending points preserves the current step. Remove Play/End from the card, release its lease on closure, and retain MCP cleanup controls.

- Render the live card through a dedicated native graph surface, using the same graph view as embedded reviews. Prefer a full-width graph and show selectable bounded rows only for points requesting table or query evidence. Embedded pan, zoom, selection and Fit preview immediately and preserve the current step without moving the desktop viewport. The renderer uses already loaded facts, does not require a visible app window, and confirms graph/data readiness for each requested step. Preserve explicit table expansions when a point leaves relation focus, and draw settled fields instead of capturing their expansion animation.

- Confirm decoded points without recapturing an image, and poll promptly while a view is preparing. Retain the last frame while point actions run. Prepare native drawing before snapshotting transitions and reuse recent unchanged background frames, invalidating them on view, row, render, geometry and appearance changes. Back/Next and MCP navigation are the only ways to advance embedded explanations.

- `studio_show_workspace_inline` renders the task's graph and requested bounded data in one live card with Back/Next and a page count. No native player appears when the card closes, expires or disconnects. Twice-resolution captures prefer lossless PNG for sharp labels. The connection survives hosts omitting private result metadata, and ended explanations stop showing a preparation status. Acknowledgements are pinned to the viewer, source, frame and current point. Background frame reads keep step controls available and cannot overwrite a newer controlled point.
- `studio_show_data_inline` presents read-only table pages and captured query results through MCP Apps. It uses the task's running database workspace without opening native table or query panes. Other hosts receive a bounded text preview and structured rows.
- The viewer preserves positional columns and exact decimal text, distinguishes SQL NULL/empty/binary values, and labels clipped cells and capped query results. Previous/Next and page reload use the same context, workspace and source; query pages never rerun SQL. Stale requests retain the last fetched page with an error.
- The bundled database-explore skill prefers the live Graph Studio card for visual explanations and embedded rows for standalone data reads.

## Workspace Input and Startup

- Normal launch starts with an empty workspace. Sources open through an explicit file/folder choice, Open Recent, Finder, or launch arguments; the app no longer automatically restores datasets from the prior session.
- Supported file formats are available through the welcome screen's **Supported formats** information button.
- Metadata issues can be dismissed without discarding their diagnostics. Their panel owns its scrolling, wheel and pinch gestures, and returns when the source or diagnostics change.
- The graph's native event observer passes clicks through to underlying controls. The informational minimap also passes clicks through, keeping table, search, filter, split and view controls reachable.

## One Graph Studio Window for Coding Agents

- The app uses one main window with workspace tabs. A user-wide process lock prevents separate worktree builds from opening extra app copies; a new build also defers to a running older copy. Launch scripts and bundled skills reuse the running app instead of requesting a new copy.
- `studio_launch` reuses a paired running app. Reopening the same source in one coding task returns its bound workspace; `studio_refresh_source` reloads it when needed.
- The development launcher never terminates Graph Studio processes by name and refuses to replace a bundle while its app or MCP helper is running. Swift build parallelism defaults to four jobs so simultaneous worktrees create less memory pressure.
- At most four documents are loaded across the app, including in-progress opens from separate coding tasks. Normal startup opens no source; unloaded tabs in an explicitly restored workspace load their source when selected. MCP-created workspaces remain bounded to 12 owned tabs and 32 total tabs. At a limit, the tool returns a recoverable error instead of continuing to allocate database sessions and graph canvases.

## PostgreSQL Read-Only Connections

- Files: Sources/StudioCore/Database/, Sources/StudioCore/App/, Sources/StudioCore/TableWorkspace/
- Change: Added a PostgresNIO-backed PostgreSQL target behind a neutral database facade. PostgreSQL catalog browsing, schema graph metadata, paging/search/filter/sort, safe query execution, query history, exports, and non-executing explain plans are supported.
- Security boundary: PostgreSQL sessions request default_transaction_read_only=on, use explicit read-only transactions, apply a preflight SQL policy, expose no mutation capability, and keep credentials outside Graph Studio.
- UX: PostgreSQL opens from a user-selected .postgres or .pgstudio document containing endpoint properties only. The app has no login form and no connection-profile feature.
- Compatibility: SQLite editing, imports and schema actions remain available. Both backends share local sidecars, grouping and the bounded large-catalog explorer.
- Status: ACTIVE

## Schema Graph View

### Trackpad Scrolling Direction
- **File**: `Sources/StudioCore/GraphView/SchemaGraphView.swift`
- **Function**: `applyTrackpadPan(_ delta: CGSize)`
- **Change**: Natural scrolling enabled (+ signs, not - signs)
- **Reason**: Moving fingers right should pan viewport right (like moving the canvas)
- **Status**: ✅ ACTIVE - DO NOT REVERT

### Graph Visuals Settings (View ▸ Graph Visuals)
- **Files**: `Sources/StudioCore/App/GraphVisualSettings.swift`, `Sources/StudioCore/App/GraphVisualToggles.swift`, `Sources/StudioCore/App/StudioCommands.swift`
- **Change**: Every default-on graph decoration is switchable from the menu bar and persists across launches — relation pulses, zoomed-out relations, relationship labels, group colors, group titles, zoomed-out group links, card shadows, hover previews, minimap. Plus "Turn All Off" and "Restore Defaults"
- **Placement**: `CommandGroup(after: .sidebar)` puts it in the View menu. AppKit's "Show Tab Bar"/"Show All Tabs" still appear there — they are only present while the app is frontmost, which makes them look displaced if you inspect the menu of a background instance
- **Storage**: one key, `SQLiteGraphStudio.graph-visuals-disabled`, holding the names of the visuals turned OFF. A visual added in a later version therefore arrives on with no migration, and a name that no longer exists is ignored rather than discarding the rest
- **Replaces**: the unpersisted `session.showClusterHalos` and the view-local `showCardinals` state. `GraphVisualToggles` is the single definition of the list, rendered by both the menu bar and the graph's own options menu
- **Group Colors and Group Titles are independent**: titles used to be gated on the halo flag. Now each switch does only what it says — with colours off, group names still draw, in plain ink
- **Group colour styling**: inferred and uncoloured groups use muted slate and gray tones suited to the cool canvas. Small maps avoid fallback-colour collisions. At overview zoom, a light card surface remains visible beneath a faint group tint; group borders stay subtle until hovered or selected. Explicit sidecar colours remain available.
- **Status**: ✅ ACTIVE

### Zoomed-Out Relations
- **Files**: `Sources/StudioCore/GraphView/GraphEdgeLayerPlan.swift`, `Sources/StudioCore/GraphView/GraphEdgeSampling.swift`, `Sources/StudioCore/GraphView/SchemaGraphView.swift`
- **Change**: The overview draws real relation lines, not only group-to-group links, so relation pulses stay readable while zoomed out. Previously edges appeared only under the pointer
- **Bounds**: `GraphEdgeLayerPlan.overviewRelationLimit` (1200) relations per frame, sampled at an even stride — nothing is off screen at overview zoom, so viewport culling cannot bound the work. Below that many, all are drawn. Sampling happens on the edge list BEFORE anchors and paths are resolved; that ordering is what keeps it affordable
- **Ink**: `overviewInkScale` (0.62) on opacity and width, so a dense catalog reads as texture rather than a grey mat while still carrying pulses
- **Structure**: `GraphEdgeLayerPlan` is the single decision about what the relation layer paints; both the static lines and the pulses are built from one plan, so a signal can never appear on a relation whose line is hidden
- **Schema reviews are never sampled**: a review always takes the detail path at any zoom. Its whole subject is which relations changed, and a bounded sample could drop one. Pulses also stay out of a review, which spends colour and symbols directing the eye to what changed
- **Status**: ✅ ACTIVE

### Schema Review Lens
- **Files**: `Sources/StudioCore/GraphView/SchemaReviewLens.swift`, `Sources/StudioCore/GraphView/GraphNameLabelLayout.swift`, `Sources/StudioCore/GraphView/SchemaGraphView.swift`, `Sources/StudioCore/SchemaReview/SchemaReviewView.swift`
- **Change**: A review opens on every change at once (no table is pre-selected). Choosing a changed table — in the list or the graph — isolates its own changes: the table, the relations it gained or lost, and the tables at their far ends. Other changes fade (never vanish); choosing the table again, "Show All Changes", or clicking empty canvas returns to everything
- **Unchanged relations**: hidden while zoomed out (below `GraphExploration.detailZoom`), shown faintly once cards are readable. Hover and selection highlight only changed relations, so a hub table no longer fans out dozens of unchanged lines with `1`/`*` labels
- **Names**: changed tables carry fixed-size screen labels at overview zoom, placed over the table and culled on collision (additions/removals claim space first). The hovered and chosen tables are always named. Nodes are NOT enlarged on hover: at overview zoom that would cover neighbours and move the hit target, and still name one table at a time
- **Marks**: unchanged tables recede; a review never draws the dashed "size unknown" outline, because it has no row data and dashes mean "removed" there
- **Panel**: the list is grouped Removed / New / Changed; choosing a row reveals the table (pans at the current zoom, zooms out only to fit its changed relations, never in); ⌥⌘↓/⌥⌘↑ step through changes. The graph is clipped to its pane so cards cannot paint over the panel
- **Clicking an overview node in a review selects it** instead of pulling its neighbours into a focus ring, which would rearrange the layout being compared
- **Review panes**: the native graph and table list use a draggable split divider. Full table cards appear from 10% zoom and keep field text opaque. The redundant Added/Changed/Removed header legend is removed; counts, badges, and graph marks still explain changes.
- **Embedded gestures**: pan and zoom immediately transform the current native frame locally. After input pauses for 80 ms, one renderer request refines it; newer input remains visible when an older frame arrives. Camera-only snapshots wait for the graph to consume the command without waiting for selection/layout settling.
- **Status**: ✅ ACTIVE

### Review Author
- **Files**: `Sources/StudioCore/SchemaReview/SchemaReviewDocument.swift`, `Sources/StudioCore/SchemaReview/SchemaReviewAuthorLabel.swift`, `Sources/StudioCore/SchemaReview/SchemaReviewCapture.swift`, `Skills/database-diff`, `Skills/database-preview`
- **Change**: `compare` and `preview` accept `--agent TOOL --session NAME`, stored as an optional `author` on the document. Capture skills require the actual current chat title whenever the host provides it. Native and embedded headers lead with that session title; the native header keeps the tool's mark, and tool/session provenance remains in the tooltip. Unnamed reviews fall back to the tool name. Known tools (`claude`, `codex`, `opencode`, `copilot`) are normalised from common spellings; any other tool keeps its own name
- **Marks**: drawn in code — Claude's spark, and plain monogram tiles for the others rather than imitations of their logos. No third-party artwork is bundled
- **Compatibility**: documents without `author` load unchanged. It is provenance only, never approval, and sits outside a preview's plan so it never changes the plan fingerprint
- **Status**: ✅ ACTIVE

### Relation Pulse Animation
- **Files**: `Sources/StudioCore/GraphView/GraphEdgePulse.swift`, `Sources/StudioCore/GraphView/SchemaGraphView.swift`
- **Change**: Faint signals drift along relation edges from the referencing table toward the referenced table, so foreign-key direction reads at a glance without hovering
- **Look**: Deliberately low contrast (`StudioPalette.edgePulse`) — a small head with a fading wake, faded in at the source and out at the target. It is ambient context, NOT a foreground element; do not raise the opacity or shorten the rest gap
- **Pacing**: Per-edge rhythm seeded from the edge identity (stable FNV-1a, never `hashValue`), so an edge keeps its phase across frames, pans and launches. Rest is longer than travel, holding ~1/3 of visible relations in motion at once
- **Bounds**: At most `GraphEdgePulseField.trackLimit` (110) animated edges per frame, sampled at an even stride; edges under 34pt on screen are skipped. Tracks follow the relations `drawEdges` paints, including sampled overview relations when that visual is enabled.
- **Stops for**: Reduce Motion, and inactive windows (`controlActiveState`). At overview zoom, pulses follow the sampled overview relations when that visual is enabled; with it off, relations and pulses appear only for the hovered area.
- **Status**: ✅ ACTIVE

### Node Hover Edge Highlighting
- **File**: `Sources/StudioCore/GraphView/SchemaGraphView.swift`
- **Change**: Edges become bold when hovering over connected nodes
- **Implementation**: `GraphRelationHighlight` includes `hoveredNodeID` parameter
- **Status**: ✅ ACTIVE

### Graph Layout Spacing
- **Files**: `Sources/StudioCore/GraphModel/GraphLayoutModel.swift`
- **Changes**:
  - Compact mode: `linkDistance: 50`, `nodeGap: 30`, `clusterSpacing: 0` (NO SPACING)
  - `baseRadius: 45`, `layerSpacing: 35`, `minNodeSpacing: 40`
  - `repelStrength: 2_200` (balanced to prevent overlap)
  - `overlapCorrectionStrength: 2.6` (strong overlap prevention)
  - `clusterAttractionStrength: 0.024` (very strong clustering)
  - `gridSpacing: 48` (for isolated nodes)
  - **Target**: ~2 node heights (92px) vertical, ~1 node width (140px) horizontal spacing
  - **Clusters**: 0px separation - clusters are right next to each other
  - Nodes are VERY close together, maximum density without overlap
- **Status**: ✅ ACTIVE - Last updated: 2026-04-23 (17:30)

### Minimap
- **File**: `Sources/StudioCore/GraphView/SchemaGraphView.swift`
- **Component**: `GraphMinimapView`
- **Location**: Bottom-left corner
- **Features**: Informational bird's-eye view and viewport indicator; mouse input passes through to workspace controls
- **Status**: ✅ ACTIVE

### Back to Content Button
- **File**: `Sources/StudioCore/GraphView/SchemaGraphView.swift`
- **Function**: `shouldShowBackToContent(in:)`
- **Trigger**: Appears when no nodes visible in viewport
- **Status**: ✅ ACTIVE

### Node Clustering
- **File**: `Sources/StudioCore/GraphModel/GraphLayoutModel.swift`
- **Change**: Isolated nodes (no connections) grouped into single cluster
- **Layout**: Grid layout for isolated nodes, hierarchical for connected nodes
- **Status**: ✅ ACTIVE

### Pane Maximization
- **Files**: `Sources/StudioCore/App/AppSession.swift`, `Sources/StudioCore/App/StudioRootView.swift`
- **Feature**: Maximize button in pane headers to show Schema/Tables/Query full-screen
- **Status**: ✅ ACTIVE

### App Icon Configuration
- **Files**: `script/build_and_run.sh`, `script/AppIcon.icns`, `script/AppIcon.iconset/`
- **Configuration**:
  - Icon file: `script/AppIcon.icns` (126KB)
  - Copied to: `dist/SQLiteGraphStudio.app/Contents/Resources/AppIcon.icns`
  - Info.plist key: `CFBundleIconFile` = "AppIcon"
  - Icon design: Database with connected nodes (graph visualization theme)
- **Note**: If icon doesn't appear in Dock, run: `touch dist/SQLiteGraphStudio.app && rm -rf ~/Library/Caches/com.apple.iconservices.store && killall Dock`
- **Status**: ✅ ACTIVE

### Z-Index Fix
- **File**: `Sources/StudioCore/App/StudioRootView.swift`
- **Change**: Headers use ZStack with `.zIndex(100)` to stay on top
- **Reason**: Prevents nodes from rendering over pane headers
- **Status**: ✅ ACTIVE

### Multi-Node Selection and Dragging
- **Files**: `Sources/StudioCore/App/AppSession.swift`, `Sources/StudioCore/GraphView/SchemaGraphView.swift`
- **Features**:
  - Hold Shift + drag to draw selection rectangle
  - Multiple nodes can be selected at once
  - Drag any selected node to move all selected nodes together
  - Click empty space to deselect all nodes
  - Visual feedback: selection rectangle with accent color
- **Implementation**:
  - `selectedGraphNodeIDs: Set<String>` tracks multi-selection
  - `selectionRectStart` and `selectionRectCurrent` for rectangle drawing
  - `updateSelectionFromRect()` selects nodes within rectangle
  - Multi-node drag maintains relative positions
  - Node cards check `session.selectedGraphNodeIDs.contains(node.id)` for selection state
- **Status**: ✅ ACTIVE

### Node Position Preservation on Expand/Collapse
- **File**: `Sources/StudioCore/GraphView/SchemaGraphView.swift`
- **Change**: Removed `stabilizeLayout()` calls from expand/collapse operations
- **Reason**: Nodes should stay in same position when expanding/collapsing details
- **Status**: ✅ ACTIVE

### PK/FK Badge Highlighting
- **File**: `Sources/StudioCore/GraphView/SchemaGraphView.swift`
- **Change**: PK/FK/REF badges only highlight when hovering over the node itself
- **Behavior**: 
  - Badges always visible but subtle (low opacity)
  - Only emphasized when hovering directly over the node containing them
  - Connected nodes' badges do NOT highlight when hovering other nodes
- **Status**: ✅ ACTIVE

### Edge Direction Arrows
- **File**: `Sources/StudioCore/GraphView/SchemaGraphView.swift`
- **Feature**: Directional arrows on highlighted edges
- **Implementation**:
  - Arrowheads drawn at target end of edges
  - Only visible when edge is highlighted (on node hover)
  - Shows FK → PK direction clearly
- **Status**: ✅ ACTIVE

### Multi-Node Selection Visual Feedback
- **File**: `Sources/StudioCore/GraphView/SchemaGraphView.swift`
- **Feature**: Clear visual indication when multiple nodes are selected
- **Implementation**:
  - Background tint on selected nodes, including multiple selections and overview marks
  - Selection rectangle with accent color during shift+drag
- **Status**: ✅ ACTIVE

## Important Notes

- **Trackpad scrolling**: Has been changed multiple times. Current direction is FINAL.
- **Layout parameters**: Carefully tuned for optimal spacing. Do not increase without explicit request.
- **Clustering**: Connected components algorithm groups related tables together.

---

Last updated: 2026-04-23 (17:30 - Cluster spacing to 0, multi-selection visual feedback, PK/FK hover-only highlighting, directional arrows)

## Live inline Graph Studio workspace

Visual explanations embed Graph Studio’s rendered graph in one live MCP App card. Back/Next or MCP navigation select manual steps; requested table or query evidence appears alongside the graph. Captures are scoped to the exact task/workspace/source, exclude the tab bar and desktop, and stop with an explicitly retained last frame when the workspace or source is unavailable. The standalone data grid remains available for row-only requests.
