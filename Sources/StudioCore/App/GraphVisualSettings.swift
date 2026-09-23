import Foundation

/// A decoration the schema graph draws on top of the tables themselves.
///
/// Everything listed here ships on. They are the parts of the canvas that carry
/// atmosphere rather than data — motion, colour, depth, and the overlays that summarise
/// a graph too large to read directly — so each one is something a reader may reasonably
/// want quiet while they work.
public enum GraphVisual: String, CaseIterable, Sendable, Identifiable, Codable {
    /// Faint signals drifting along each relation in foreign-key direction.
    case relationPulses
    /// Real relation lines at overview zoom, not just the aggregate group links.
    case overviewRelations
    /// The `1` / `*` cardinality symbols on a highlighted relation.
    case relationshipLabels
    /// Per-group tint on card borders and overview marks.
    case groupColors
    /// The group name headings floating over each cluster.
    case groupTitles
    /// Aggregate group-to-group curves drawn at overview zoom.
    case overviewGroupLinks
    /// Drop shadows under table and story cards.
    case cardShadows
    /// Callout labels naming the tables around the pointer at overview zoom.
    case hoverPreviews
    /// The graph overview inset in the bottom-left corner.
    case minimap

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .relationPulses:     return "Relation Pulses"
        case .overviewRelations:  return "Relations While Zoomed Out"
        case .relationshipLabels: return "Relationship Labels"
        case .groupColors:        return "Group Colors"
        case .groupTitles:        return "Group Titles"
        case .overviewGroupLinks: return "Group Links While Zoomed Out"
        case .cardShadows:        return "Card Shadows"
        case .hoverPreviews:      return "Hover Previews"
        case .minimap:            return "Minimap"
        }
    }

    /// Shown as the menu item's tooltip.
    public var help: String {
        switch self {
        case .relationPulses:
            return "Faint signals travel each relation from the referencing table to the referenced one."
        case .overviewRelations:
            return "Draw individual relations while zoomed out, instead of only group-to-group links."
        case .relationshipLabels:
            return "Show 1 and * cardinality marks on the relation under the pointer."
        case .groupColors:
            return "Tint table cards and overview marks by the group they belong to."
        case .groupTitles:
            return "Float each group's name above its tables."
        case .overviewGroupLinks:
            return "Summarise traffic between groups as single curves while zoomed out."
        case .cardShadows:
            return "Lift table cards off the canvas with a drop shadow."
        case .hoverPreviews:
            return "Name the tables around the pointer while zoomed out."
        case .minimap:
            return "Show the whole graph in the bottom-left corner."
        }
    }

    /// Menu grouping. Items are listed in this order, with a separator between sections.
    public var section: Section {
        switch self {
        case .relationPulses, .overviewRelations, .relationshipLabels: return .relations
        case .groupColors, .groupTitles, .overviewGroupLinks:          return .groups
        case .cardShadows, .hoverPreviews, .minimap:                   return .canvas
        }
    }

    public enum Section: String, CaseIterable, Sendable {
        case relations
        case groups
        case canvas

        public var visuals: [GraphVisual] {
            GraphVisual.allCases.filter { $0.section == self }
        }
    }
}

/// Which graph decorations are switched on.
///
/// Stored as the set of visuals the reader has turned *off*, so a visual added in a later
/// version arrives switched on without a migration, and a stored value naming a visual
/// that no longer exists is simply ignored.
public struct GraphVisualSettings: Sendable, Equatable {
    private var disabled: Set<GraphVisual>

    public static let `default` = GraphVisualSettings()

    public init(disabled: Set<GraphVisual> = []) {
        self.disabled = disabled
    }

    public var isDefault: Bool { disabled.isEmpty }

    /// Visuals the reader has switched off, for display.
    public var disabledVisuals: Set<GraphVisual> { disabled }

    public func isEnabled(_ visual: GraphVisual) -> Bool {
        !disabled.contains(visual)
    }

    public mutating func setEnabled(_ isEnabled: Bool, for visual: GraphVisual) {
        if isEnabled {
            disabled.remove(visual)
        } else {
            disabled.insert(visual)
        }
    }

    public mutating func reset() {
        disabled.removeAll()
    }

    public mutating func disableAll() {
        disabled = Set(GraphVisual.allCases)
    }

    // MARK: - Persistence

    static let storageKey = "SQLiteGraphStudio.graph-visuals-disabled"

    /// Unknown names are dropped rather than rejected, so downgrading after a release
    /// that added a visual leaves the remaining choices intact.
    public static func load(from userDefaults: UserDefaults) -> GraphVisualSettings {
        let stored = userDefaults.stringArray(forKey: storageKey) ?? []
        return GraphVisualSettings(disabled: Set(stored.compactMap(GraphVisual.init(rawValue:))))
    }

    public func save(to userDefaults: UserDefaults) {
        guard !disabled.isEmpty else {
            userDefaults.removeObject(forKey: Self.storageKey)
            return
        }
        userDefaults.set(disabled.map(\.rawValue).sorted(), forKey: Self.storageKey)
    }
}
