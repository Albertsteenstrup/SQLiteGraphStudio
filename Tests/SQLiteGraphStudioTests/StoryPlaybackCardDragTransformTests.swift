import CoreGraphics
import Testing
@testable import StudioCore

struct StoryPlaybackCardDragTransformTests {
    @Test
    func affineTransformAppliesDragOffset() {
        let offset = CGSize(width: 240, height: -80)
        let transform = StoryPlaybackCardDragTransform.affineTransform(for: offset)

        #expect(transform.tx == 240)
        #expect(transform.ty == -80)
        #expect(transform.a == 1)
        #expect(transform.d == 1)
    }

    @Test
    func affineTransformIsIdentityForZeroOffset() {
        let transform = StoryPlaybackCardDragTransform.affineTransform(for: .zero)
        #expect(transform == .identity)
    }
}
