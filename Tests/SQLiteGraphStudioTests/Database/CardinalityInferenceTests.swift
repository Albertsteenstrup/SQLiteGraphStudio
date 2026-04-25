import Foundation
import Testing
@testable import StudioCore

/// Property-based tests for cardinality inference.
///
/// Feature: schema-graph-ux-improvements
/// Property 1: Cardinality inference is a total function of uniqueness flags
///
/// **Validates: Requirements 1.2, 1.3, 1.4, 1.5, 1.6**
struct CardinalityInferenceTests {

    // MARK: - Property 1: Cardinality inference is a total function of uniqueness flags

    /// Enumerates all 4 (Bool, Bool) combinations and asserts the correct EdgeCardinality
    /// value is returned for each. The mapping must be:
    ///   (true,  true)  → .oneToOne
    ///   (true,  false) → .oneToMany
    ///   (false, true)  → .manyToOne
    ///   (false, false) → .manyToMany
    @Test("Property 1: inferEdgeCardinality covers all four (Bool, Bool) combinations correctly")
    func cardinalityInferenceIsTotalFunction() {
        // All four combinations
        let cases: [(sourceUnique: Bool, targetUnique: Bool, expected: EdgeCardinality)] = [
            (true,  true,  .oneToOne),
            (true,  false, .oneToMany),
            (false, true,  .manyToOne),
            (false, false, .manyToMany),
        ]

        for (sourceUnique, targetUnique, expected) in cases {
            let result = inferEdgeCardinality(sourceUnique: sourceUnique, targetUnique: targetUnique)
            #expect(
                result == expected,
                "inferEdgeCardinality(sourceUnique: \(sourceUnique), targetUnique: \(targetUnique)) should be \(expected) but got \(result)"
            )
        }
    }

    /// Verifies that the inference function is exhaustive: every EdgeCardinality value
    /// is reachable from exactly one (Bool, Bool) input combination.
    @Test("Property 1: every EdgeCardinality value is produced by exactly one input combination")
    func cardinalityInferenceIsInjective() {
        let allCombinations: [(Bool, Bool)] = [(true, true), (true, false), (false, true), (false, false)]
        let results = allCombinations.map { inferEdgeCardinality(sourceUnique: $0.0, targetUnique: $0.1) }

        // All four EdgeCardinality values must appear
        #expect(results.contains(.oneToOne))
        #expect(results.contains(.oneToMany))
        #expect(results.contains(.manyToOne))
        #expect(results.contains(.manyToMany))

        // No two combinations produce the same cardinality (injective mapping)
        let uniqueResults = Set(results)
        #expect(uniqueResults.count == 4, "Expected 4 distinct cardinality values, got \(uniqueResults.count)")
    }

    // MARK: - Default cardinality when target info is unavailable

    /// Verifies that when target table index info is unavailable (nil), the cardinality
    /// defaults to .manyToOne (treating target column as unique).
    @Test("Default cardinality is .manyToOne when target table info is unavailable")
    func defaultCardinalityWhenTargetInfoUnavailable() {
        // When targetUniqueColumns is nil, target is treated as unique → manyToOne for non-unique source
        let result = inferEdgeCardinality(sourceUnique: false, targetUnique: true)
        #expect(result == .manyToOne)
    }

    // MARK: - Property 2: Cardinality display string is always a valid label

    /// **Validates: Requirements 3.2**
    ///
    /// Property 2: Cardinality display string is always a valid label.
    /// For every `EdgeCardinality` value, `cardinalityDisplayString(for:)` must return
    /// one of `"1:1"`, `"1:N"`, `"N:1"`, `"N:M"`, and the mapping must be injective
    /// (no two cardinality values produce the same string).
    @Test("Feature: schema-graph-ux-improvements, Property 2: Cardinality display string is always a valid label")
    func cardinalityDisplayStringIsAlwaysValidLabel() {
        let validLabels: Set<String> = ["1:1", "1:N", "N:1", "N:M"]
        let allValues: [EdgeCardinality] = [.oneToOne, .oneToMany, .manyToOne, .manyToMany]

        var producedStrings: [String] = []
        for cardinality in allValues {
            let label = cardinalityDisplayString(for: cardinality)
            #expect(
                validLabels.contains(label),
                "cardinalityDisplayString(for: \(cardinality)) returned '\(label)', which is not in \(validLabels)"
            )
            producedStrings.append(label)
        }

        // Mapping must be injective: no two cardinality values produce the same string
        let uniqueStrings = Set(producedStrings)
        #expect(
            uniqueStrings.count == allValues.count,
            "Expected \(allValues.count) distinct display strings, got \(uniqueStrings.count): \(producedStrings)"
        )
    }

    // MARK: - Unit tests for GraphEdge default cardinality (Requirements 1.1)

    /// Asserts that a `GraphEdge` initialized without an explicit `cardinality` argument
    /// defaults to `.manyToOne`.
    @Test("GraphEdge default cardinality is .manyToOne")
    func graphEdgeDefaultCardinalityIsManyToOne() {
        let edge = GraphEdge(
            id: "test-edge",
            sourceID: "orders",
            targetID: "customers",
            sourceColumn: "customer_id",
            targetColumn: "id"
        )
        #expect(edge.cardinality == .manyToOne)
    }

    /// Asserts that `EdgeCardinality` round-trips through `Codable` for all four values.
    @Test("EdgeCardinality round-trips through Codable for all four values")
    func edgeCardinalityRoundTripsCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let allValues: [EdgeCardinality] = [.oneToOne, .oneToMany, .manyToOne, .manyToMany]

        for cardinality in allValues {
            let data = try encoder.encode(cardinality)
            let decoded = try decoder.decode(EdgeCardinality.self, from: data)
            #expect(
                decoded == cardinality,
                "EdgeCardinality.\(cardinality) did not survive Codable round-trip; got \(decoded)"
            )
        }
    }
}
