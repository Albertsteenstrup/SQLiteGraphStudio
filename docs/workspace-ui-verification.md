# Workspace input and startup verification

Verified on 30 September 2026 against `origin/main` at `6b88be867ad763263e58031b146b8953af4e676c`, with the workspace input and startup changes applied.

## Behavior

- Normal launch opens an empty workspace. Explicit source requests retain their ordered file-opening path.
- Supported formats appear in an on-demand welcome-screen popover.
- Metadata issues can be dismissed without discarding diagnostics. Unchanged reloads keep the panel dismissed; changed diagnostics or a different source show it again.
- The metadata panel owns wheel, trackpad and pinch input instead of the graph underneath. Exclusions follow panel geometry, visibility, removal and window identity.
- The graph's native observer and the informational minimap pass clicks through to workspace controls.

## Automated evidence

`swift test --disable-sandbox --filter 'WorkspaceInteractionTests|GraphTrackpadInputViewTests|GraphInputPublisherTests|WorkspaceStateTests|WorkspaceRestorationTests|GraphSessionInteractionTests|GraphInteractionGeometryTests|WorkspaceOwnershipTests'` passed: 71 tests across 8 suites, including native hosted click delivery, metadata dismissal, graph input routing, workspace state, snapshot restoration and coding-task ownership.

The 17-test input subset also passed after the final runtime changes. The previous native observer returned itself from hit testing instead of allowing underlying controls to receive clicks; the pre-fix check reproduced that failure.

The application executable compiled successfully. `git diff --check` passed.

## Native app evidence and limits

The installed development app was restarted and displayed the empty welcome screen even with a prior migrations workspace saved on disk. The Supported formats popover opened. Opening the migrations folder explicitly displayed its schema model. The table picker opened and search narrowed its results; graph search selected a matching table; filtering applied and cleared; the split divider changed its fraction; the tables pane maximized and returned to the split; metadata dismissal hid the panel.

Native pointer automation reported `noWindowsAvailable`, so these installed-app control checks used accessibility actions. Separate hosted AppKit/SwiftUI tests delivered mouse events to underlying controls and the Open Table button. Complete installed-app pointer drag/pinch behavior, Finder/CLI file-open delivery, PostgreSQL services, release signing and notarization are not claimed by this check. Migration models remain schema-only.

The existing `WorkspaceSplitViewTests.restoredFractionAndMaximizeChangeTheRenderedPaneWidths` failed to discover pane backing-view frames on this host. The same test failed on the unchanged base; its failure is not counted as a passing check. The production split action changed the reported fraction in the installed app.

This repository has no tracked Wiki or Wiki publisher. Current workflow documentation is in [README](../README.md), [CHANGES](../CHANGES.md), the [design](agent-exploration-design.md) and the [acceptance plan](agent-exploration-validation.md).
