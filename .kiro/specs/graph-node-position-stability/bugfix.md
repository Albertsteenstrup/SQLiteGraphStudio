# Bugfix Requirements Document

## Introduction

Three related bugs affect node position stability in the graph view of SQLiteGraphStudio. Together they cause user-arranged node layouts to be lost or distorted in ways the user did not request:

1. **Graph full screen toggle resets node positions** — using the in-app full screen toggle (a button within the schema graph panel that expands the graph to fill the window, or collapses it back) causes the physics engine to re-run on already-settled positions, moving nodes away from where the user placed them.
2. **"Show all Table Cards" toggle resets node positions** — switching the presentation mode between compact and all-cards causes nodes to lose their manually arranged positions and re-layout from scratch.
3. **Physics engine spreads nodes too much vertically** — the force-directed layout engine produces a narrow vertical column of nodes instead of a balanced two-dimensional spread, sometimes pushing nodes outside the visible canvas bounds.

## Bug Analysis

### Current Behavior (Defect)

1.1 WHEN the user activates or deactivates the schema graph full screen toggle (the in-app control that expands the graph panel to fill the window or collapses it back) THEN the system re-runs the physics stabilization pass on the graph, moving nodes away from their user-arranged positions

1.2 WHEN the user toggles "Show all Table Cards" from off to on THEN the system runs a full physics stabilization pass that overrides the positions the user manually arranged in compact mode

1.3 WHEN the user toggles "Show all Table Cards" from on back to off THEN the system restores the compact layout from the last persisted snapshot, discarding any node positions the user arranged while in compact mode that were not yet persisted

1.4 WHEN the physics engine runs the initial layout or stabilization pass on a graph with multiple nodes THEN the system produces a layout where nodes are clustered in a narrow vertical column, with vertical spread significantly exceeding horizontal spread

1.5 WHEN the physics engine applies overlap correction between two nodes THEN the system preferentially resolves overlaps along the vertical axis, causing nodes to stack vertically rather than spreading in two dimensions

### Expected Behavior (Correct)

2.1 WHEN the user activates or deactivates the schema graph full screen toggle THEN the system SHALL preserve all node positions exactly as they were before the panel resize, without running any physics pass

2.2 WHEN the user toggles "Show all Table Cards" from off to on THEN the system SHALL use the current compact node positions as starting positions for the all-cards layout and SHALL only run physics to resolve card-size overlaps introduced by the larger card dimensions, not to re-arrange already-separated nodes

2.3 WHEN the user toggles "Show all Table Cards" from on back to off THEN the system SHALL restore the compact layout from the snapshot that was saved immediately before the toggle was activated, preserving the positions the user had at that moment

2.4 WHEN the physics engine runs the initial layout or stabilization pass THEN the system SHALL produce a layout where nodes are spread across both horizontal and vertical axes in a roughly balanced two-dimensional arrangement

2.5 WHEN the physics engine applies overlap correction between two nodes THEN the system SHALL resolve overlaps along whichever axis requires the smaller displacement, without a systematic bias toward the vertical axis

### Unchanged Behavior (Regression Prevention)

3.1 WHEN the user manually drags a node to a new position THEN the system SHALL CONTINUE TO pin that node at the dragged position and persist the layout at the end of the drag

3.2 WHEN the user clicks "Relayout" THEN the system SHALL CONTINUE TO run a full physics relayout from scratch, discarding previous positions

3.3 WHEN a database is opened and a persisted layout snapshot exists THEN the system SHALL CONTINUE TO restore node positions from the snapshot without running physics

3.4 WHEN a database is opened and no persisted layout snapshot exists THEN the system SHALL CONTINUE TO run the initial physics layout to produce a starting arrangement

3.5 WHEN the graph schema changes (tables added or removed) THEN the system SHALL CONTINUE TO run a layout pass that places new nodes while preserving positions of existing nodes

3.6 WHEN the user is in all-cards mode and drags a node THEN the system SHALL CONTINUE TO pin that node at the dragged position for the duration of the all-cards session

3.7 WHEN the physics engine settles (total velocity drops below threshold) THEN the system SHALL CONTINUE TO stop animating and mark the layout as stable
