import CoreGraphics
import Testing
@testable import StudioCore

struct GraphInputPublisherTests {
    @Test func continuousViewportInputPublishesTheLatestSampleAtEveryOpportunity() {
        var input = GraphLatestInput<GraphViewportTransform>()
        for frame in 0..<20 {
            for sample in 0..<12 {
                _ = input.stage(GraphViewportTransform(
                    zoom: 0.2 + CGFloat(frame) * 0.01,
                    pan: CGSize(width: CGFloat(frame * 12 + sample), height: CGFloat(sample))
                ))
            }
            let published = input.take()
            #expect(published?.pan.width == CGFloat(frame * 12 + 11))
            #expect(published?.pan.height == 11)
            #expect(input.take() == nil)
        }
    }

    @Test func duplicatePointerDeliveryDoesNotRepeatHoverWork() {
        var input = GraphLatestInput<GraphPointerSample>()
        let sample = GraphPointerSample(point: CGPoint(x: 20, y: 40), geometryRevision: 7)
        let firstStaged = input.stage(sample)
        #expect(firstStaged)
        let duplicateStaged = input.stage(sample)
        #expect(duplicateStaged)
        #expect(input.take() == sample)
        let unchangedStaged = input.stage(sample)
        #expect(!unchangedStaged)
        #expect(input.take() == nil)
    }

    @Test func stationaryPointerIsReevaluatedAfterGeometryChanges() {
        var input = GraphLatestInput<GraphPointerSample>()
        let point = CGPoint(x: 20, y: 40)
        _ = input.stage(GraphPointerSample(point: point, geometryRevision: 7))
        _ = input.take()
        let updated = GraphPointerSample(point: point, geometryRevision: 8)
        let updatedStaged = input.stage(updated)
        #expect(updatedStaged)
        #expect(input.take() == updated)
    }

    @Test func returningToPublishedPointerBeforeDeliverySuppressesStaleHover() {
        var input = GraphLatestInput<GraphPointerSample>()
        let outside = GraphPointerSample(point: nil, geometryRevision: 1)
        _ = input.stage(outside)
        _ = input.take()
        _ = input.stage(GraphPointerSample(point: CGPoint(x: 50, y: 60), geometryRevision: 1))
        let outsideStaged = input.stage(outside)
        #expect(!outsideStaged)
        #expect(input.take() == nil)
    }

    @Test func finalFlushCanRepublishCameraAfterExternalSessionReset() {
        var input = GraphLatestInput<GraphViewportTransform>()
        _ = input.stage(.identity)
        #expect(input.take() == .identity)
        _ = input.stage(.identity)
        #expect(input.take(force: true) == .identity)
    }

    @MainActor
    @Test func schedulerPublishesLatestValuesWhileInputContinues() async {
        let publisher = GraphInputPublisher<Int>(interval: .milliseconds(30))
        var latestEnqueued = 0
        var deliveries: [(value: Int, latestAtDelivery: Int)] = []
        let producer = Task { @MainActor in
            while !Task.isCancelled {
                latestEnqueued += 1
                publisher.enqueue(latestEnqueued) { value in
                    deliveries.append((value, latestEnqueued))
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer {
            producer.cancel()
            publisher.cancel()
        }

        // The producer deliberately stays active until we observe delivery.
        // A trailing debounce would time out instead of publishing two samples.
        let publishedDuringStream = await waitForPublication { deliveries.count >= 2 }
        producer.cancel()
        await producer.value
        publisher.cancel()

        #expect(publishedDuringStream)
        #expect(deliveries.count >= 2)
        #expect(deliveries.allSatisfy { $0.value == $0.latestAtDelivery })
        #expect(Set(deliveries.map(\.value)).count == deliveries.count)
    }

    @MainActor
    @Test func schedulerFlushPublishesFinalValueOnceAndCancelsPendingDelivery() async throws {
        let publisher = GraphInputPublisher<Int>(interval: .milliseconds(20))
        defer { publisher.cancel() }
        var received: [Int] = []
        publisher.enqueue(1) { received.append($0) }
        publisher.enqueue(2) { received.append($0) }
        publisher.flush(3) { received.append($0) }
        publisher.flush(3) { received.append($0) }
        #expect(received == [3])

        // Allow several complete publication windows for any stale task to run.
        try await Task.sleep(for: .milliseconds(120))
        #expect(received == [3])
    }

    @MainActor
    @Test func schedulerCancelSuppressesPendingCallbackAndAllowsLaterInput() async throws {
        let publisher = GraphInputPublisher<Int>(interval: .milliseconds(20))
        defer { publisher.cancel() }
        var received: [Int] = []
        publisher.enqueue(1) { received.append($0) }
        publisher.cancel()
        try await Task.sleep(for: .milliseconds(120))
        #expect(received.isEmpty)

        publisher.enqueue(2) { received.append($0) }
        let resumed = await waitForPublication { received == [2] }
        #expect(resumed)
        #expect(received == [2])
    }

    @MainActor
    @Test func schedulerDoesNotPublishUnchangedSamples() async throws {
        let publisher = GraphInputPublisher<Int>(interval: .milliseconds(20))
        defer { publisher.cancel() }
        var received: [Int] = []
        publisher.enqueue(7) { received.append($0) }
        let firstDelivered = await waitForPublication { received == [7] }
        #expect(firstDelivered)

        for _ in 0..<100 {
            publisher.enqueue(7) { received.append($0) }
        }
        try await Task.sleep(for: .milliseconds(120))
        #expect(received == [7])
    }

    @MainActor
    private func waitForPublication(_ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition(), clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
