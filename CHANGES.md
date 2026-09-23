# Project Changes Log

This file tracks intentional changes made to the codebase that should NOT be reverted.

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
