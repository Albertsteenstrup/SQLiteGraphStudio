import SwiftUI

/// The graph decoration switches, as menu content.
///
/// One definition serves both View ▸ Graph Visuals in the menu bar and the graph's own
/// options menu, so the two can never drift apart.
public struct GraphVisualToggles: View {
    @Bindable private var session: AppSession

    public init(session: AppSession) {
        self.session = session
    }

    public var body: some View {
        ForEach(Array(GraphVisual.Section.allCases.enumerated()), id: \.element) { index, section in
            if index > 0 {
                Divider()
            }
            ForEach(section.visuals) { visual in
                Toggle(visual.title, isOn: binding(for: visual))
                    .help(visual.help)
            }
        }

        Divider()

        Button("Turn All Off") {
            session.graphVisuals.disableAll()
        }
        .disabled(session.graphVisuals.disabledVisuals.count == GraphVisual.allCases.count)

        Button("Restore Defaults") {
            session.graphVisuals.reset()
        }
        .disabled(session.graphVisuals.isDefault)
    }

    private func binding(for visual: GraphVisual) -> Binding<Bool> {
        Binding(
            get: { session.graphVisuals.isEnabled(visual) },
            set: { session.graphVisuals.setEnabled($0, for: visual) }
        )
    }
}
