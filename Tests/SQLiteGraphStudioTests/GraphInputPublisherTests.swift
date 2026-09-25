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
    @Test func schedulerPublishesLatestValuesWhileInputContinues() {
        let scheduler = ManualPublicationScheduler()
        let publisher = GraphInputPublisher<Int>(interval: .milliseconds(30), scheduler: scheduler)
        var latestEnqueued = 0
        var deliveries: [(value: Int, latestAtDelivery: Int)] = []
        for _ in 0..<3 {
            for _ in 0..<6 {
                latestEnqueued += 1
                publisher.enqueue(latestEnqueued) { value in
                    deliveries.append((value, latestEnqueued))
                }
                // Continuing input keeps the one pending window instead of
                // postponing it, which a trailing debounce would do.
                #expect(scheduler.openWindowCount == 1)
            }
            scheduler.elapse()
        }

        #expect(deliveries.map(\.value) == [6, 12, 18])
        #expect(deliveries.allSatisfy { $0.value == $0.latestAtDelivery })
        #expect(scheduler.requestedIntervals == Array(repeating: .milliseconds(30), count: 3))
    }

    @MainActor
    @Test func schedulerFlushPublishesFinalValueOnceAndCancelsPendingDelivery() {
        let scheduler = ManualPublicationScheduler()
        let publisher = GraphInputPublisher<Int>(interval: .milliseconds(20), scheduler: scheduler)
        var received: [Int] = []
        publisher.enqueue(1) { received.append($0) }
        publisher.enqueue(2) { received.append($0) }
        publisher.flush(3) { received.append($0) }
        publisher.flush(3) { received.append($0) }
        #expect(received == [3])
        #expect(scheduler.openWindowCount == 0)

        scheduler.elapse()
        #expect(received == [3])
    }

    @MainActor
    @Test func schedulerCancelSuppressesPendingCallbackAndAllowsLaterInput() {
        let scheduler = ManualPublicationScheduler()
        let publisher = GraphInputPublisher<Int>(interval: .milliseconds(20), scheduler: scheduler)
        var received: [Int] = []
        publisher.enqueue(1) { received.append($0) }
        publisher.cancel()
        #expect(scheduler.openWindowCount == 0)
        scheduler.elapse()
        #expect(received.isEmpty)

        publisher.enqueue(2) { received.append($0) }
        #expect(scheduler.openWindowCount == 1)
        scheduler.elapse()
        #expect(received == [2])
    }

    @MainActor
    @Test func schedulerDoesNotPublishUnchangedSamples() {
        let scheduler = ManualPublicationScheduler()
        let publisher = GraphInputPublisher<Int>(interval: .milliseconds(20), scheduler: scheduler)
        var received: [Int] = []
        publisher.enqueue(7) { received.append($0) }
        scheduler.elapse()
        #expect(received == [7])

        for _ in 0..<100 {
            publisher.enqueue(7) { received.append($0) }
        }
        #expect(scheduler.openWindowCount == 0)
        scheduler.elapse()
        #expect(received == [7])
    }

    @MainActor
    @Test func publisherReleasesItsPendingWindowOnDeinit() {
        let scheduler = ManualPublicationScheduler()
        var received: [Int] = []
        do {
            let publisher = GraphInputPublisher<Int>(interval: .milliseconds(20), scheduler: scheduler)
            publisher.enqueue(1) { received.append($0) }
            #expect(scheduler.openWindowCount == 1)
        }
        #expect(scheduler.openWindowCount == 0)
        scheduler.elapse()
        #expect(received.isEmpty)
    }

    /// The app's scheduler, awaited to completion rather than polled against a
    /// deadline, so a busy main actor delays the test but cannot fail it. No
    /// time limit: the full suite has kept the main actor busy for over a minute.
    @MainActor
    @Test func taskSchedulerDeliversAfterItsIntervalUnlessCancelled() async {
        let scheduler = TaskPublicationScheduler()
        var delivered: [String] = []
        scheduler.schedule(after: .milliseconds(1)) { delivered.append("cancelled") }.cancel()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            _ = scheduler.schedule(after: .milliseconds(1)) {
                delivered.append("delivered")
                continuation.resume()
            }
        }
        #expect(delivered == ["delivered"])
    }
}
