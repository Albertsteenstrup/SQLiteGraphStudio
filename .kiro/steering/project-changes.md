---
inclusion: auto
---

# Project Changes - Critical Context

**ALWAYS read CHANGES.md before making modifications to this codebase.**

## Critical Rules

### 1. Trackpad Scrolling Direction (Schema Graph)
**File**: `Sources/StudioCore/GraphView/SchemaGraphView.swift`

```swift
private func applyTrackpadPan(_ delta: CGSize) {
    // MUST use + signs (natural scrolling)
    pan = CGSize(
        width: pan.width + delta.width,  // ✅ CORRECT
        height: pan.height + delta.height // ✅ CORRECT
    )
    panStart = pan
}
```

**❌ NEVER change to minus signs**
**✅ Current behavior**: Moving fingers right pans viewport right (natural scrolling)

### 2. Graph Layout Spacing
**File**: `Sources/StudioCore/GraphModel/GraphLayoutModel.swift`

Current compact mode parameters (DO NOT INCREASE - these are VERY tight):
- `linkDistance: 50` (very short connections)
- `nodeGap: 30` (minimal gap to prevent overlap)
- `clusterSpacing: 15` (barely visible cluster separation)
- `baseRadius: 45` (tight initial placement)
- `layerSpacing: 35` (close hierarchical layers)
- `repelStrength: 2_200` (balanced repulsion)
- `overlapCorrectionStrength: 2.6` (strong overlap prevention)
- `minNodeSpacing: 40` (enforced minimum)
- `clusterAttractionStrength: 0.024` (very strong clustering)

**Target spacing**: ~2 node heights (92px) vertical, ~1 node width (140px) horizontal
**These values create maximum density without overlap.**

### 3. Before Making Changes

1. **Read CHANGES.md** to understand existing modifications
2. **Check for comments** marked with "IMPORTANT", "DO NOT", or "CRITICAL"
3. **Search for related changes** before modifying layout/interaction code
4. **Update CHANGES.md** if you make new intentional changes

### 4. Updating CHANGES.md

When making changes that should be preserved:

1. Add entry to CHANGES.md with:
   - File path
   - What changed
   - Why it changed
   - Status: ✅ ACTIVE

2. If change contradicts existing entry:
   - Update the existing entry
   - Add note about why it was changed
   - Update "Last updated" date

3. Mark deprecated changes:
   - Change status to ❌ DEPRECATED
   - Add reason for deprecation
   - Keep entry for historical context

### 5. Key Components to Preserve

- **GraphRelationHighlight**: Includes `hoveredNodeID` for edge highlighting
- **GraphMinimapView**: Bottom-right minimap component
- **shouldShowBackToContent**: Back button when viewport is empty
- **buildClusters**: Groups isolated nodes together
- **Pane maximization**: ZStack with header at `.zIndex(100)`

### 6. Common Mistakes to Avoid

❌ Reverting trackpad direction to minus signs
❌ Increasing layout spacing parameters
❌ Removing `hoveredNodeID` from GraphRelationHighlight
❌ Changing header z-index structure
❌ Breaking cluster grouping logic

### 7. Testing Changes

After modifications:
1. Build: `swift build`
2. Run: `swift run SQLiteGraphStudio`
3. Test trackpad scrolling feels natural
4. Verify nodes are close together
5. Check minimap is visible
6. Test "Back to Content" button

---

**Reference**: #[[file:CHANGES.md]] for complete change history
