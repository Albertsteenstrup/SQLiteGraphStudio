# Graph Node Position Stability Bugfix Design

## Overview

Three related bugs cause node positions in the schema graph to be lost or distorted without user intent:

1. **Full-screen toggle resets positions** — `toggleMaximizePane` changes `maximizedPaneSide`, which causes `SchemaGraphView` to be re-mounted (SwiftUI replaces the view tree). On mount, `performInitialLayout` is called. When `hasRestoredSnapshot` is `true` it calls `stabilizeLayout(refit: false)`, which runs a full physics pass and moves nodes.

2. **"Show all Table Cards" toggle resets positions** — `switchPresentationMode(isShowingAllCards: true)` calls `relayoutPreservingCurrentPositions`, which correctly seeds positions from compact state, but then calls `stabilizeLayout` with `maxIterations: 140`. The physics pass re-runs on already-separated compact nodes, moving them significantly because the `allCards` repel/spring parameters are tuned for large cards and push nodes far apart.

3. **Physics engine vertical bias** — Two independent causes:
   - In `resolveRemainingOverlaps`, the axis-selection logic (`separateOnX = overlapX <= overlapY`) resolves overlaps on the X axis only when `overlapX` is strictly smaller. Because initial positions are placed on circular arcs, many node pairs have similar overlap in both axes, and the tie-breaking favours Y-axis separation, stacking nodes vertically.
   - In `limitSpreadIfNeeded`, the `maxHeight` cap is much tighter than `maxWidth` (e.g. compact: `max(480, n*90)` vs `max(900, n*200)`), so the scale factor is dominated by the height constraint and compresses the layout vertically before the final overlap pass.

## Glossary

- **Bug_Condition (C)**: The set of inputs that trigger one of the three position-stability bugs.
- **Property (P)**: The desired correct behavior for each bug condition.
- **Preservation**: Existing behaviors (drag-to-pin, Relayout, snapshot restore, schema change layout) that must remain unchanged.
- **`GraphLayoutModel`**: The physics engine in `Sources/StudioCore/GraphModel/GraphLayoutModel.swift` that owns node positions, velocities, and pinned positions.
- **`SchemaGraphView`**: The SwiftUI view in `Sources/StudioCore/GraphView/SchemaGraphView.swift` that drives layout calls and renders the graph.
- **`AppSession`**: The observable model in `Sources/StudioCore/App/AppSession.swift` that owns `graphLayout`, `showAllGraphTableCards`, and `maximizedPaneSide`.
- **`hasRestoredSnapshot`**: A flag on `GraphLayoutModel` that is `true` when positions were loaded from a persisted snapshot (or from `restore(_:for:presentation:descriptorLookup:)`).
- **`performInitialLayout`**: The `SchemaGraphView` method called on `onAppear` and on `session.graph` change; it branches on `hasRestoredSnapshot`.
- **`stabilize`**: The `GraphLayoutModel` method that runs up to N physics ticks followed by overlap resolution and spread limiting.
- **`relayoutPreservingCurrentPositions`**: The `GraphLayoutModel` method that seeds positions from the current state before switching presentation mode.
- **`resolveRemainingOverlaps`**: The post-physics overlap correction pass in `GraphLayoutModel`.
- **`limitSpreadIfNeeded`**: The post-physics spread-compression pass in `GraphLayoutModel`.

## Bug Details

### Bug Condition

**Bug 1 — Full-screen toggle re-runs physics on settled layout:**

The bug manifests when `maximizedPaneSide` changes (full-screen toggle). SwiftUI re-mounts `SchemaGraphView`, triggering `onAppear` → `performInitialLayout`. When `hasRestoredSnapshot` is `true`, `performInitialLayout` calls `stabilizeLayout(refit: false)`, which runs a full physics pass and moves nodes.

```
FUNCTION isBugCondition_1(event)
  INPUT: event — a full-screen toggle action (maximizedPaneSide changes)
  OUTPUT: boolean

  RETURN graphLayout.hasRestoredSnapshot == true
         AND performInitialLayout was called due to view re-mount
         AND stabilize() was invoked with maxIterations > 0
         AND nodes moved from their pre-toggle positions
END FUNCTION
```

**Bug 2 — "Show all Table Cards" toggle re-runs physics on compact positions:**

The bug manifests when `showAllGraphTableCards` is set to `true`. `switchPresentationMode` calls `relayoutPreservingCurrentPositions` (correct) then `stabilizeLayout` with 140 iterations. The `allCards` physics parameters (repelStrength: 16,000, linkDistance: 180) are tuned for large expanded cards and aggressively push apart nodes that were already well-separated in compact mode.

```
FUNCTION isBugCondition_2(event)
  INPUT: event — "Show all Table Cards" toggled on
  OUTPUT: boolean

  RETURN showAllGraphTableCards changed from false to true
         AND relayoutPreservingCurrentPositions was called
         AND stabilize() was invoked with allCards parameters
         AND nodes moved significantly from their compact positions
END FUNCTION
```

**Bug 3 — Physics engine vertical bias:**

The bug manifests during any physics stabilization pass. Two sub-conditions:

```
FUNCTION isBugCondition_3a(nodeA, nodeB)
  INPUT: two overlapping nodes after physics
  OUTPUT: boolean

  overlapX := halfWidths + gap - abs(posA.x - posB.x)
  overlapY := halfHeights + gap - abs(posA.y - posB.y)
  RETURN overlapX > 0 AND overlapY > 0
         AND overlapX == overlapY  -- tie: Y axis chosen, causing vertical stacking
         AND separateOnX == false  -- current code: separateOnX = (overlapX <= overlapY)
                                   -- when equal, separateOnX is true, but in practice
                                   -- circular initial positions produce overlapY < overlapX
                                   -- more often, biasing toward Y separation
END FUNCTION

FUNCTION isBugCondition_3b(graph)
  INPUT: graph after physics pass
  OUTPUT: boolean

  bounds := union of all node frames
  RETURN bounds.height > maxHeight  -- maxHeight is much smaller than maxWidth
         AND limitSpreadIfNeeded compresses height more than width
         AND resulting layout is a narrow vertical column
END FUNCTION
```

### Examples

**Bug 1:**
- User opens a database with 8 tables. Nodes settle into a nice layout. User clicks "Maximize pane" to enter full-screen. `SchemaGraphView` re-mounts. `performInitialLayout` runs `stabilizeLayout`. Nodes scatter from their arranged positions.
- Expected: nodes stay exactly where they were before the toggle.

**Bug 2:**
- User arranges 6 nodes in compact mode. User toggles "Show all Table Cards". `relayoutPreservingCurrentPositions` seeds positions correctly, but `stabilize` with `allCards` parameters pushes nodes far apart. Nodes end up in a very different arrangement.
- Expected: nodes start from compact positions and only move enough to resolve card-size overlaps.

**Bug 3:**
- User opens a database with 10 tables. Initial layout produces a narrow vertical column of nodes, some outside the visible canvas. Horizontal spread is ~200 px, vertical spread is ~900 px.
- Expected: nodes spread roughly equally in both axes.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- Manual drag-to-pin: dragging a node pins it at the dragged position; this must continue to work.
- "Relayout" button: clicking Relayout runs a full physics relayout from scratch; this must continue to work.
- Snapshot restore on database open: when a persisted layout exists, positions are restored without physics; this must continue to work.
- Initial layout on first open: when no snapshot exists, physics runs to produce a starting arrangement; this must continue to work.
- Schema change layout: when tables are added or removed, new nodes are placed while existing positions are preserved; this must continue to work.
- All-cards drag-to-pin: dragging a node in all-cards mode pins it; this must continue to work.
- Physics settlement: when total velocity drops below threshold, animation stops; this must continue to work.

**Scope:**
All inputs that do NOT involve the full-screen toggle, the "Show all Table Cards" toggle, or the initial physics pass should be completely unaffected by this fix. This includes:
- Mouse clicks on nodes and buttons
- Keyboard shortcuts
- Database open/close
- Schema refresh

## Hypothesized Root Cause

### Bug 1 — Full-screen toggle

1. **View re-mount triggers `onAppear`**: When `maximizedPaneSide` changes, SwiftUI replaces the view tree. `SchemaGraphView.onAppear` fires, calling `performInitialLayout`.
2. **`performInitialLayout` calls `stabilizeLayout` unconditionally when `hasRestoredSnapshot` is true**: The intent was to stabilize only when needed, but a settled layout with a restored snapshot does not need any physics. The fix is to skip `stabilizeLayout` entirely when `hasRestoredSnapshot` is `true` and the graph signature has not changed.

### Bug 2 — "Show all Table Cards" toggle

1. **`stabilizeLayout` is called with full iteration count after `relayoutPreservingCurrentPositions`**: The compact positions are already well-separated for compact-sized nodes. Running 140 iterations of `allCards` physics (repelStrength: 16,000) on these positions moves them far from where the user placed them.
2. **Fix**: After `relayoutPreservingCurrentPositions`, run only a targeted overlap-resolution pass (using `resolveRemainingOverlaps` directly, or `stabilize` with a very low iteration count like 0–20) to handle card-size expansion, rather than a full physics relayout.

### Bug 3 — Vertical bias

1. **`resolveRemainingOverlaps` axis selection**: `separateOnX = overlapX <= overlapY`. When `overlapX < overlapY`, nodes are separated on X (correct). When `overlapX > overlapY`, nodes are separated on Y (correct). When `overlapX == overlapY`, nodes are separated on X (correct). However, the initial circular placement tends to produce node pairs where the vertical distance is smaller than the horizontal distance (nodes on the same arc layer are closer vertically), so `overlapY < overlapX` is common, causing Y-axis separation to dominate. The fix is to add a small horizontal preference: when the overlap difference is within a small epsilon, prefer X-axis separation.
2. **`limitSpreadIfNeeded` asymmetric bounds**: `maxHeight` is set to `max(480, n*90)` for compact and `max(800, n*200)` for allCards, while `maxWidth` is `max(900, n*200)` and `max(1400, n*420)` respectively. The height cap is roughly 2× tighter than the width cap, so the scale factor is dominated by height, compressing the layout into a vertical column. The fix is to make the height cap proportionally larger (e.g. `max(700, n*180)` compact, `max(1100, n*380)` allCards) so the aspect ratio of the bounding box is closer to 1:1.

## Correctness Properties

Property 1: Bug Condition 1 — Full-screen toggle preserves node positions

_For any_ graph with a restored snapshot where the full-screen toggle fires (maximizedPaneSide changes), the fixed `performInitialLayout` SHALL NOT move any node from its pre-toggle position. All node positions after the toggle SHALL be identical to the positions before the toggle.

**Validates: Requirements 2.1**

Property 2: Bug Condition 2 — "Show all Table Cards" toggle preserves compact positions as starting points

_For any_ graph where "Show all Table Cards" is toggled on, the fixed `switchPresentationMode` SHALL use the current compact node positions as starting positions for the all-cards layout and SHALL only displace nodes by the minimum amount needed to resolve card-size overlaps, not to re-arrange already-separated nodes.

**Validates: Requirements 2.2**

Property 3: Bug Condition 3 — Physics engine produces balanced 2D spread

_For any_ graph with 3 or more nodes after a full physics stabilization pass, the fixed layout engine SHALL produce a layout where the horizontal spread (maxX − minX of node centers) is at least 50% of the vertical spread (maxY − minY of node centers), and the vertical spread is at least 50% of the horizontal spread. Neither axis SHALL dominate by more than 2×.

**Validates: Requirements 2.4, 2.5**

Property 4: Preservation — Drag-to-pin and Relayout are unaffected

_For any_ input that is NOT a full-screen toggle or "Show all Table Cards" toggle (mouse drag, Relayout button, database open, schema change), the fixed code SHALL produce exactly the same behavior as the original code, preserving all existing layout functionality.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7**

## Fix Implementation

### Changes Required

#### Fix 1: Skip physics in `performInitialLayout` when snapshot is already settled

**File**: `Sources/StudioCore/GraphView/SchemaGraphView.swift`

**Function**: `performInitialLayout(in:)`

**Current code:**
```swift
private func performInitialLayout(in size: CGSize) {
    guard !session.graph.nodes.isEmpty else { return }

    if session.graphLayout.hasRestoredSnapshot {
        stabilizeLayout(in: size, refit: false, persistLayout: false)
    } else {
        rebuildLayout(in: size, refit: true, clearPinnedState: true, persistLayout: true)
    }
}
```

**Specific Changes**:
1. **Remove the `stabilizeLayout` call in the `hasRestoredSnapshot` branch**: When a snapshot has been restored, positions are already settled. No physics pass is needed. The view re-mount from a full-screen toggle should be a no-op for layout.
2. **Replace with a viewport fit only**: After a view re-mount with a restored snapshot, only refit the viewport if the viewport size changed from zero (first appearance), otherwise do nothing.

**Proposed fix:**
```swift
private func performInitialLayout(in size: CGSize) {
    guard !session.graph.nodes.isEmpty else { return }

    if session.graphLayout.hasRestoredSnapshot {
        // Positions are already settled — do not run physics.
        // Only fit the viewport on the very first appearance (size was zero before).
        // Re-mounts from full-screen toggle must not disturb node positions.
        return
    } else {
        rebuildLayout(in: size, refit: true, clearPinnedState: true, persistLayout: true)
    }
}
```

Note: The initial `fitGraph` on first appearance is handled by the `onChange(of: geometry.size)` handler which fires when size transitions from `.zero` to a real size. No separate fit call is needed here.

---

#### Fix 2: Skip full physics pass when switching to all-cards mode

**File**: `Sources/StudioCore/GraphView/SchemaGraphView.swift`

**Function**: `switchPresentationMode(isShowingAllCards:in:)`

**Current code:**
```swift
private func switchPresentationMode(isShowingAllCards: Bool, in size: CGSize) {
    if isShowingAllCards {
        session.graphLayout.relayoutPreservingCurrentPositions(
            for: session.graph,
            presentation: presentationMode,
            descriptorLookup: { session.descriptor(named: $0) }
        )
        stabilizeLayout(in: size, refit: true, persistLayout: false)
    } else {
        session.restoreCompactGraphLayoutForCurrentDatabase()
        layoutRevision &+= 1
        fitGraph(in: size)
    }
}
```

**Specific Changes**:
1. **Replace `stabilizeLayout` with a direct overlap-resolution call**: After `relayoutPreservingCurrentPositions`, call `session.graphLayout.stabilize` with `maxIterations: 0` so only the post-physics overlap resolution and spread-limiting passes run (no force-directed ticks). This resolves card-size overlaps without re-arranging nodes.

**Proposed fix:**
```swift
private func switchPresentationMode(isShowingAllCards: Bool, in size: CGSize) {
    if isShowingAllCards {
        session.graphLayout.relayoutPreservingCurrentPositions(
            for: session.graph,
            presentation: presentationMode,
            descriptorLookup: { session.descriptor(named: $0) }
        )
        // Use maxIterations: 0 to skip force-directed ticks entirely.
        // Only the post-physics overlap resolution and spread-limiting passes run,
        // which is sufficient to handle the larger card sizes without re-arranging nodes.
        session.graphLayout.stabilize(
            graph: session.graph,
            presentation: presentationMode,
            descriptorLookup: { session.descriptor(named: $0) },
            nodeSizeLookup: { nodeSize(for: $0) },
            maxIterations: 0
        )
        layoutRevision &+= 1
        fitGraph(in: size)
    } else {
        session.restoreCompactGraphLayoutForCurrentDatabase()
        layoutRevision &+= 1
        fitGraph(in: size)
    }
}
```

---

#### Fix 3a: Remove vertical bias in `resolveRemainingOverlaps`

**File**: `Sources/StudioCore/GraphModel/GraphLayoutModel.swift`

**Function**: `resolveRemainingOverlaps(graph:nodeSizeLookup:gap:maxIterations:)`

**Specific Changes**:
1. **Add a horizontal preference when overlaps are nearly equal**: Change the axis-selection condition to prefer X-axis separation when `overlapX` and `overlapY` are within a small epsilon (e.g. 4 pt). This breaks the systematic vertical bias without changing behavior for clearly asymmetric overlaps.

**Current code:**
```swift
let separateOnX = overlapX <= overlapY
```

**Proposed fix:**
```swift
// Prefer horizontal separation to avoid vertical stacking bias.
// When overlaps are nearly equal (within 4 pt), always separate on X.
let separateOnX = overlapX <= overlapY + 4.0
```

---

#### Fix 3b: Relax the height cap in `limitSpreadIfNeeded`

**File**: `Sources/StudioCore/GraphModel/GraphLayoutModel.swift`

**Function**: `limitSpreadIfNeeded(graph:presentation:nodeSizeLookup:)`

**Specific Changes**:
1. **Increase `maxHeight` to be proportionally closer to `maxWidth`**: Change the compact height cap from `max(480, n*90)` to `max(700, n*180)` and the allCards height cap from `max(800, n*200)` to `max(1100, n*380)`. This makes the aspect ratio of the allowed bounding box closer to 1:1, preventing the layout from being compressed into a vertical column.

**Current code:**
```swift
let maxWidth = presentation == .allCards ? max(1_400, nodeFactor * 420) : max(900, nodeFactor * 200)
let maxHeight = presentation == .allCards ? max(800, nodeFactor * 200) : max(480, nodeFactor * 90)
```

**Proposed fix:**
```swift
let maxWidth = presentation == .allCards ? max(1_400, nodeFactor * 420) : max(900, nodeFactor * 200)
let maxHeight = presentation == .allCards ? max(1_100, nodeFactor * 380) : max(700, nodeFactor * 180)
```

## Testing Strategy

### Validation Approach

The testing strategy follows a two-phase approach: first, surface counterexamples that demonstrate each bug on unfixed code, then verify the fix works correctly and preserves existing behavior.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bugs BEFORE implementing the fix. Confirm or refute the root cause analysis.

**Test Plan**: Write unit tests that simulate the triggering conditions for each bug and assert the incorrect behavior on unfixed code.

**Test Cases**:

1. **Full-screen toggle test** (Bug 1): Create a `GraphLayoutModel`, restore a snapshot, record positions, simulate a view re-mount by calling `performInitialLayout` logic (i.e. call `stabilize` as `performInitialLayout` currently does), assert that positions changed — this will fail on unfixed code, confirming the bug.

2. **Show all Table Cards test** (Bug 2): Create a `GraphLayoutModel`, set compact positions, call `relayoutPreservingCurrentPositions` then `stabilize` with `allCards` parameters and 140 iterations, assert that node positions moved significantly from their starting points — this will demonstrate the bug.

3. **Vertical bias test** (Bug 3): Create a `GraphLayoutModel`, call `reset` + `stabilize` for a graph with 6+ nodes, measure the horizontal and vertical spread of node centers, assert that vertical spread exceeds horizontal spread by more than 2× — this will fail on unfixed code.

**Expected Counterexamples**:
- Bug 1: Positions after simulated re-mount differ from positions before re-mount.
- Bug 2: Node positions after `allCards` stabilize differ by more than one card-width from compact positions.
- Bug 3: `(maxY - minY) / (maxX - minX) > 2.0` for a typical graph.

### Fix Checking

**Goal**: Verify that for all inputs where the bug condition holds, the fixed code produces the expected behavior.

**Pseudocode:**
```
FOR ALL graph WHERE isBugCondition_1(fullScreenToggleEvent) DO
  positionsBefore := graphLayout.allPositions(for: graph)
  simulateFullScreenToggle()
  positionsAfter := graphLayout.allPositions(for: graph)
  ASSERT positionsBefore == positionsAfter
END FOR

FOR ALL graph WHERE isBugCondition_2(showAllCardsToggleEvent) DO
  compactPositions := graphLayout.allPositions(for: graph)
  switchToAllCards()
  allCardsPositions := graphLayout.allPositions(for: graph)
  FOR ALL nodeID DO
    displacement := distance(compactPositions[nodeID], allCardsPositions[nodeID])
    ASSERT displacement < maxCardSize  -- nodes only moved to resolve overlap
  END FOR
END FOR

FOR ALL graph WHERE isBugCondition_3(graph) DO
  stabilize(graph)
  spread := measureSpread(graphLayout.allPositions(for: graph))
  ASSERT spread.horizontal >= spread.vertical * 0.5
  ASSERT spread.vertical >= spread.horizontal * 0.5
END FOR
```

### Preservation Checking

**Goal**: Verify that for all inputs where the bug condition does NOT hold, the fixed code produces the same result as the original code.

**Pseudocode:**
```
FOR ALL input WHERE NOT isBugCondition(input) DO
  ASSERT originalBehavior(input) == fixedBehavior(input)
END FOR
```

**Testing Approach**: Property-based testing is recommended for preservation checking because:
- It generates many random graphs and interaction sequences automatically.
- It catches edge cases (single node, disconnected graph, all nodes pinned) that manual tests miss.
- It provides strong guarantees that drag-to-pin, Relayout, and snapshot restore are unaffected.

**Test Cases**:
1. **Drag-to-pin preservation**: Verify that pinning a node at a position still works correctly after the fix.
2. **Relayout preservation**: Verify that calling `relayout` still produces a fresh physics layout.
3. **Snapshot restore preservation**: Verify that `restore(_:for:presentation:descriptorLookup:)` still sets `hasRestoredSnapshot = true` and positions match the snapshot.
4. **Schema change preservation**: Verify that adding a new node to the graph still triggers a layout pass that places the new node while preserving existing positions.

### Unit Tests

- Test that `performInitialLayout` with `hasRestoredSnapshot = true` does NOT change any node positions (Bug 1 fix).
- Test that `switchPresentationMode(isShowingAllCards: true)` with pre-arranged compact positions results in node displacements smaller than one card width (Bug 2 fix).
- Test that after `stabilize` on a 6-node graph, horizontal spread ≥ 50% of vertical spread (Bug 3 fix).
- Test that `resolveRemainingOverlaps` with equal X and Y overlap separates on X axis (Bug 3a fix).
- Test that existing `GraphLayoutTests` still pass (preservation).

### Property-Based Tests

- Generate random graphs (2–12 nodes, 0–8 edges) and verify that after `stabilize`, the aspect ratio of node spread is between 0.5 and 2.0.
- Generate random graphs with pre-arranged positions and verify that `relayoutPreservingCurrentPositions` + `stabilize(maxIterations: 0)` moves no node by more than `maxCardWidth + nodeGap`.
- Generate random pinned positions and verify that `stabilize` does not move pinned nodes.

### Integration Tests

- Full flow: open database → arrange nodes → toggle full-screen → verify positions unchanged.
- Full flow: open database → arrange nodes → toggle "Show all Table Cards" → verify nodes start from compact positions.
- Full flow: open database → verify initial layout has balanced horizontal/vertical spread.
- Full flow: open database → drag node → toggle full-screen → verify dragged node stays pinned.
