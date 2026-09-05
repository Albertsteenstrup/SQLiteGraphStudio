import Foundation
import Testing
@testable import StudioCore

struct GraphInitialViewportTests {
    @Test
    func nonzeroTransientSizeIsSupersededByTheActualViewport() {
        var initial = GraphInitialViewport()
        let action = initial.appeared(hasGraph: true, layoutIsSettled: false)
        #expect(action == .scheduleFit)
        let transientRequest = initial.request
        let shouldSchedule = initial.viewportChanged()
        #expect(shouldSchedule)
        let finalRequest = initial.request
        #expect(!initial.canFit(request: transientRequest, hasGraph: true, size: CGSize(width: 150, height: 620)))
        #expect(initial.canFit(request: finalRequest, hasGraph: true, size: CGSize(width: 650, height: 620)))
    }

    @Test
    func zeroAxisDoesNotCompleteThePendingInitialFit() {
        var initial = GraphInitialViewport()
        _ = initial.appeared(hasGraph: true, layoutIsSettled: false)
        #expect(!initial.canFit(request: initial.request, hasGraph: true, size: CGSize(width: 0, height: 620)))
        #expect(initial.needsFit)
        let shouldSchedule = initial.viewportChanged()
        #expect(shouldSchedule)
        #expect(initial.canFit(request: initial.request, hasGraph: true, size: CGSize(width: 650, height: 620)))
    }

    @Test
    func loadingGraphAfterEmptyAppearanceSchedulesAViewportFit() {
        var initial = GraphInitialViewport()
        let action = initial.appeared(hasGraph: false, layoutIsSettled: false)
        #expect(action == .waitForGraph)
        let shouldSchedule = initial.graphChanged(hasGraph: true)
        #expect(shouldSchedule)
        #expect(initial.canFit(request: initial.request, hasGraph: true, size: CGSize(width: 650, height: 620)))
    }

    @Test
    func settledRemountPreservesItsCameraThroughResize() {
        var initial = GraphInitialViewport()
        let action = initial.appeared(hasGraph: true, layoutIsSettled: true, hasSessionCamera: true)
        #expect(action == .restoreCamera)
        let shouldSchedule = initial.viewportChanged()
        #expect(!shouldSchedule)
        #expect(!initial.canFit(request: initial.request, hasGraph: true, size: CGSize(width: 650, height: 620)))
    }

    @Test
    func completedFitDoesNotRunAgainOnManualResize() {
        var initial = GraphInitialViewport()
        _ = initial.appeared(hasGraph: true, layoutIsSettled: false)
        initial.didFit(request: initial.request)
        #expect(!initial.needsFit)
        let shouldSchedule = initial.viewportChanged()
        #expect(!shouldSchedule)
        #expect(!initial.canFit(request: initial.request, hasGraph: true, size: CGSize(width: 1_000, height: 800)))
    }

    @Test
    func cancelledOrSupersededRequestsCannotFitOrCompleteTheNewGraph() {
        var initial = GraphInitialViewport()
        _ = initial.appeared(hasGraph: true, layoutIsSettled: false)
        let oldRequest = initial.request
        initial.cancel()
        #expect(!initial.canFit(request: oldRequest, hasGraph: true, size: CGSize(width: 650, height: 620)))
        let shouldSchedule = initial.graphChanged(hasGraph: true)
        #expect(shouldSchedule)
        initial.didFit(request: oldRequest)
        #expect(initial.needsFit)
        #expect(initial.canFit(request: initial.request, hasGraph: true, size: CGSize(width: 650, height: 620)))
    }

    @Test
    func restoredPositionsWithoutASessionCameraStillNeedTheirFirstFit() {
        var initial = GraphInitialViewport()
        let action = initial.appeared(hasGraph: true, layoutIsSettled: true, hasSessionCamera: false)
        #expect(action == .scheduleFit)
        #expect(initial.canFit(request: initial.request, hasGraph: true, size: CGSize(width: 650, height: 620)))
    }

    @Test
    func presentationChangeFitsAfterThePaneResizesThenPreservesTheCamera() {
        var initial = GraphInitialViewport()
        _ = initial.appeared(hasGraph: true, layoutIsSettled: true, hasSessionCamera: true)

        initial.presentationChanged()
        #expect(initial.needsFit)
        let presentationRequest = initial.request
        let shouldSchedule = initial.viewportChanged()
        #expect(shouldSchedule)
        let resizedRequest = initial.request
        #expect(!initial.canFit(request: presentationRequest, hasGraph: true, size: CGSize(width: 1_167, height: 620)))
        initial.didFit(request: presentationRequest)
        #expect(initial.needsFit)
        #expect(initial.canFit(request: resizedRequest, hasGraph: true, size: CGSize(width: 701, height: 620)))

        initial.didFit(request: resizedRequest)
        #expect(!initial.needsFit)
        let shouldFitAfterManualResize = initial.viewportChanged()
        #expect(!shouldFitAfterManualResize)
    }
}
