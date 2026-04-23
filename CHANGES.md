# Project Changes Log

This file tracks intentional changes made to the codebase that should NOT be reverted.

## Schema Graph View

### Trackpad Scrolling Direction
- **File**: `Sources/StudioCore/GraphView/SchemaGraphView.swift`
- **Function**: `applyTrackpadPan(_ delta: CGSize)`
- **Change**: Natural scrolling enabled (+ signs, not - signs)
- **Reason**: Moving fingers right should pan viewport right (like moving the canvas)
- **Status**: ✅ ACTIVE - DO NOT REVERT

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
