import Foundation
import Testing
@testable import StudioCore

struct StorySpeechNarratorTests {
    @Test
    func preparationConcurrencyUsesSingleWorkerForOneBeat() {
        #expect(StorySpeechNarrator.preparationConcurrency(for: 0) == 1)
        #expect(StorySpeechNarrator.preparationConcurrency(for: 1) == 1)
    }

    @Test
    func preparationConcurrencyScalesWithProcessorCount() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let cap = max(1, min(cores, 6))

        #expect(StorySpeechNarrator.preparationConcurrency(for: 2) == min(2, cap))
        #expect(StorySpeechNarrator.preparationConcurrency(for: 12) == min(12, cap))
        #expect(StorySpeechNarrator.preparationConcurrency(for: 100) == cap)
    }
}
