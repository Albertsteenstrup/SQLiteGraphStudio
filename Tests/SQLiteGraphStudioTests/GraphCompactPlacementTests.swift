import CoreGraphics
import Testing
@testable import StudioCore

struct GraphCompactPlacementTests {
    @Test func mixedCardSizesStaySeparatedInCallerOrder() {
        let sizes = [
            CGSize(width: 226, height: 46), CGSize(width: 560, height: 46), CGSize(width: 350, height: 46),
            CGSize(width: 440, height: 236), CGSize(width: 290, height: 46), CGSize(width: 440, height: 188),
            CGSize(width: 400, height: 46), CGSize(width: 440, height: 236),
        ]
        let items = sizes.enumerated().map { GraphCompactPlacement.Item(id: "t\($0.offset)", size: $0.element) }
        let positions = GraphCompactPlacement.positions(for: items, columns: 3, around: .zero)
        #expect(positions.count == items.count)
        let frames = items.map { item in
            let point = positions[item.id]!
            return CGRect(x: point.x - item.size.width / 2, y: point.y - item.size.height / 2,
                          width: item.size.width, height: item.size.height)
        }
        for index in frames.indices {
            #expect(!frames.prefix(index).contains { $0.intersects(frames[index]) })
        }
        #expect(positions["t0"]!.x < positions["t1"]!.x)
        #expect(positions["t1"]!.x < positions["t2"]!.x)
        #expect(positions["t0"]!.y < positions["t3"]!.y)
        #expect(positions["t3"]!.y < positions["t6"]!.y)
    }

    @Test func repeatedInputCannotCrashPresentationLayout() {
        let item = GraphCompactPlacement.Item(id: "same", size: CGSize(width: 440, height: 236))
        let positions = GraphCompactPlacement.positions(for: [item, item], columns: 3,
                                                        around: CGPoint(x: 10, y: 20))
        #expect(positions == ["same": CGPoint(x: 10, y: 20)])
    }
}
