import CoreGraphics

/// Decides when the workspace has run out of room for two side-by-side panes.
///
/// The window can narrow for reasons the app does not control: the user drags it
/// smaller, tiles it beside another application in Split View, or parks it in a
/// Stage Manager slot. Two panes stop being readable well before they stop
/// fitting, so below `collapseWidth` the layout shows a single pane and prefers
/// the schema graph — the view that still says something useful when it is the
/// only thing on screen.
public struct WorkspaceCompactLayout: Equatable, Sendable {
    /// Smallest window the app allows. Chosen so a Split View or Stage Manager
    /// tile is reachable while every sheet the app presents still fits inside
    /// the window that hosts it.
    public static let windowMinimumWidth: CGFloat = 720

    /// Smallest window height the app allows, by the same reasoning.
    public static let windowMinimumHeight: CGFloat = 560

    /// Padding the root view puts around the workspace, on each side. The width
    /// this type measures is the window's content width less twice this.
    public static let workspaceInset: CGFloat = 16

    /// Workspace width below which the layout drops to a single pane.
    public static let collapseWidth: CGFloat = 760

    /// Workspace width at which the second pane returns. The gap above
    /// `collapseWidth` keeps a resize drag that lingers near the boundary from
    /// flipping the layout back and forth.
    public static let restoreWidth: CGFloat = 820

    /// Smallest width a pane may be dragged to while both are on screen. Narrow
    /// enough that two of them always fit inside `narrowestWorkspaceWidth` — a
    /// split view forced wider than the window would report a width that never
    /// falls under `collapseWidth`, hiding the very narrowness this type detects.
    public static let splitPaneMinimumWidth: CGFloat = 320

    /// Floor for the one pane a compact workspace shows. Lower than
    /// `splitPaneMinimumWidth` because it has no neighbour to leave room for.
    public static let singlePaneMinimumWidth: CGFloat = 240

    /// The least width the workspace can ever be given.
    public static var narrowestWorkspaceWidth: CGFloat {
        windowMinimumWidth - 2 * workspaceInset
    }

    public private(set) var isCompact: Bool

    public init(isCompact: Bool = false) {
        self.isCompact = isCompact
    }

    /// Feeds a freshly measured workspace width in.
    /// - Returns: `true` when this changed the compact state.
    @discardableResult
    public mutating func update(width: CGFloat) -> Bool {
        guard width.isFinite, width > 0 else { return false }
        let next = isCompact ? width < Self.restoreWidth : width < Self.collapseWidth
        guard next != isCompact else { return false }
        isCompact = next
        return true
    }
}
