import Foundation

extension Array {
    /// Bounds-checked element access, for parsers that look ahead past the end.
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
