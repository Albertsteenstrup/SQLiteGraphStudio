import SwiftUI
import Testing
@testable import StudioCore

/// Covers the drill-down stack behind `StudioMenu` dropdowns.
@MainActor
struct StudioMenuControllerTests {
    @Test
    func aFreshDropdownShowsItsRootPage() {
        let controller = StudioMenuController()
        #expect(controller.pages.isEmpty)
        #expect(controller.pages.last == nil)
    }

    @Test
    func openingSubmenusStacksPagesAndBackPopsThem() {
        let controller = StudioMenuController()
        controller.push("Graph visuals", content: AnyView(EmptyView()))
        controller.push("Colours", content: AnyView(EmptyView()))
        #expect(controller.pages.map(\.title) == ["Graph visuals", "Colours"])
        #expect(controller.pages.last?.title == "Colours")

        controller.pop()
        #expect(controller.pages.last?.title == "Graph visuals")

        controller.pop()
        #expect(controller.pages.isEmpty)
    }

    @Test
    func goingBackFromTheRootDoesNothing() {
        let controller = StudioMenuController()
        controller.pop()
        #expect(controller.pages.isEmpty)
    }
}
