# Graph Node Position Stability — Implementation Tasks

## Tasks

- [x] 1. Write exploratory tests to confirm the three bugs on unfixed code
  - [x] 1.1 Write a test that simulates a full-screen toggle re-mount and asserts that node positions change (expected to fail on fixed code, pass on unfixed code)
  - [x] 1.2 Write a test that calls `relayoutPreservingCurrentPositions` + `stabilize` with `allCards` parameters and asserts that nodes moved significantly from compact positions (expected to fail on fixed code, pass on unfixed code)
  - [x] 1.3 Write a test that calls `reset` + `stabilize` on a 6-node graph and asserts that vertical spread exceeds horizontal spread by more than 2× (expected to fail on fixed code, pass on unfixed code)
  - [x] 1.4 Run the exploratory tests on unfixed code and record the counterexamples to confirm root cause analysis

- [x] 2. Fix Bug 1 — Full-screen toggle resets node positions
  - [x] 2.1 In `SchemaGraphView.performInitialLayout(in:)`, remove the `stabilizeLayout` call in the `hasRestoredSnapshot == true` branch and replace it with an early return
  - [x] 2.2 Write a unit test that restores a snapshot, records positions, calls the fixed `performInitialLayout` logic, and asserts all positions are unchanged
  - [x] 2.3 Run the full test suite to verify no regressions

- [x] 3. Fix Bug 2 — "Show all Table Cards" toggle resets node positions
  - [x] 3.1 In `SchemaGraphView.switchPresentationMode(isShowingAllCards:in:)`, replace the `stabilizeLayout(in:refit:persistLayout:)` call with a direct `session.graphLayout.stabilize(…, maxIterations: 0)` call followed by `layoutRevision &+= 1` and `fitGraph(in: size)`
  - [x] 3.2 Write a unit test that sets compact positions, calls `relayoutPreservingCurrentPositions` + `stabilize(maxIterations: 0)`, and asserts that no node moved by more than one card width from its compact position
  - [x] 3.3 Run the full test suite to verify no regressions

- [x] 4. Fix Bug 3a — Vertical bias in `resolveRemainingOverlaps`
  - [x] 4.1 In `GraphLayoutModel.resolveRemainingOverlaps`, change `let separateOnX = overlapX <= overlapY` to `let separateOnX = overlapX <= overlapY + 4.0` to add a horizontal preference when overlaps are nearly equal
  - [x] 4.2 Write a unit test that creates two nodes with equal X and Y overlap and asserts they are separated on the X axis
  - [x] 4.3 Run the full test suite to verify no regressions

- [x] 5. Fix Bug 3b — Asymmetric height cap in `limitSpreadIfNeeded`
  - [x] 5.1 In `GraphLayoutModel.limitSpreadIfNeeded`, change the `maxHeight` values from `max(480, nodeFactor * 90)` (compact) and `max(800, nodeFactor * 200)` (allCards) to `max(700, nodeFactor * 180)` and `max(1_100, nodeFactor * 380)` respectively
  - [x] 5.2 Write a unit test that calls `reset` + `stabilize` on a graph with 6 nodes and asserts that horizontal spread is at least 50% of vertical spread
  - [x] 5.3 Run the full test suite to verify no regressions

- [x] 6. Write fix-checking tests (Property-Based Tests)
  - [x] 6.1 Write a property test for Property 1: for any graph with a restored snapshot, simulating a view re-mount does not change any node position
  - [x] 6.2 Write a property test for Property 2: for any graph, switching to all-cards mode displaces no node by more than `maxCardWidth + nodeGap` from its compact position
  - [x] 6.3 Write a property test for Property 3: for any graph with 3+ nodes, after `stabilize`, horizontal spread is between 50% and 200% of vertical spread
  - [x] 6.4 Run all property tests and confirm they pass on fixed code

- [x] 7. Write preservation-checking tests (Property-Based Tests)
  - [x] 7.1 Write a property test for Property 4a: for any graph, pinning a node at a position still results in that node being at the pinned position after `stabilize`
  - [x] 7.2 Write a property test for Property 4b: for any graph, calling `relayout` still produces a layout where `isAnimating` starts true and settles to false after `stabilize`
  - [x] 7.3 Write a property test for Property 4c: for any graph and snapshot, `restore(_:for:presentation:descriptorLookup:)` sets `hasRestoredSnapshot = true` and positions match the snapshot
  - [x] 7.4 Run all preservation tests and confirm they pass on fixed code

- [x] 8. Verify all existing tests still pass
  - [x] 8.1 Run `GraphLayoutTests` and confirm all existing tests pass
  - [x] 8.2 Run `GraphGeometryTests` and confirm all existing tests pass
  - [x] 8.3 Run the full test suite and confirm no regressions
