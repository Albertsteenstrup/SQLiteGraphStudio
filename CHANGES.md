# Project Changes Log

This file tracks intentional changes made to the codebase that should NOT be reverted.

## One Graph Studio Window for Coding Agents

- The app uses one main window with workspace tabs and prohibits multiple app instances. Launch scripts and bundled skills reuse the running app instead of requesting a new copy.
- `studio_launch` reuses a paired running app. Reopening the same source in one coding task returns its bound workspace; `studio_refresh_source` reloads it when needed.
- MCP-created workspaces are bounded to 12 owned tabs and 32 total tabs. At the limit, the tool returns a recoverable error instead of continuing to allocate database sessions and graph canvases.

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
- **Status**: ✅ ACTIVE

### Review Author
- **Files**: `Sources/StudioCore/SchemaReview/SchemaReviewDocument.swift`, `Sources/StudioCore/SchemaReview/SchemaReviewAuthorLabel.swift`, `Sources/StudioCore/SchemaReview/SchemaReviewCapture.swift`, `Skills/database-diff`, `Skills/database-preview`
- **Change**: `compare` and `preview` accept `--agent TOOL --session NAME`, stored as an optional `author` on the document. The header then leads with the tool's mark and `Claude · Session name`. Known tools (`claude`, `codex`, `opencode`, `copilot`) are normalised from common spellings; any other tool keeps its own name
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
- **Location**: Bottom-right corner
- **Features**: Bird's-eye view, viewport indicator, click-to-navigate
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
  - Accent-colored border (3px) around all selected nodes when count > 1
  - Selection rectangle with accent color during shift+drag
  - Enhanced shadow on selected nodes
- **Status**: ✅ ACTIVE

## Important Notes

- **Trackpad scrolling**: Has been changed multiple times. Current direction is FINAL.
- **Layout parameters**: Carefully tuned for optimal spacing. Do not increase without explicit request.
- **Clustering**: Connected components algorithm groups related tables together.

---

Last updated: 2026-04-23 (17:30 - Cluster spacing to 0, multi-selection visual feedback, PK/FK hover-only highlighting, directional arrows)
