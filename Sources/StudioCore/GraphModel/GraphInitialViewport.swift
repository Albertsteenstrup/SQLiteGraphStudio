import Foundation

/// Tracks automatic viewport fit requests independently of settled table positions.
struct GraphInitialViewport {
    enum AppearanceAction: Equatable { case restoreCamera, scheduleFit, waitForGraph }
    private(set) var request: UInt64 = 0
    private(set) var needsFit = false

    mutating func appeared(hasGraph: Bool, layoutIsSettled: Bool, hasSessionCamera: Bool = false) -> AppearanceAction {
        request &+= 1
        needsFit = !(hasGraph && layoutIsSettled && hasSessionCamera)
        if !needsFit { return .restoreCamera }
        return hasGraph ? .scheduleFit : .waitForGraph
    }

    mutating func graphChanged(hasGraph: Bool) -> Bool {
        request &+= 1
        needsFit = true
        return hasGraph
    }

    mutating func presentationChanged() {
        request &+= 1
        needsFit = true
    }

    mutating func viewportChanged() -> Bool {
        guard needsFit else { return false }
        request &+= 1
        return true
    }

    mutating func cancel() {
        request &+= 1
        needsFit = false
    }

    func canFit(request: UInt64, hasGraph: Bool, size: CGSize) -> Bool {
        needsFit && self.request == request && hasGraph
            && size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    mutating func didFit(request: UInt64) {
        guard self.request == request else { return }
        needsFit = false
    }
}
