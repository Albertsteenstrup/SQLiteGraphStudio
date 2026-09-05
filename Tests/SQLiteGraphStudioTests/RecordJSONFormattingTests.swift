import Foundation
import Testing
@testable import StudioCore

struct RecordJSONFormattingTests {
    @Test func formattingPreservesExactTokensAndDuplicateKeys() async {
        let raw = #" {"n":123456789012345678901234567890,"n":-0.0100e+200,"s":"a\"b\\c\u0061","unicode":"ø😀","items":[true,false,null,{},[]]} "#
        let formatted = await RecordValuePresentation.formattedJSON(raw)
        #expect(formatted.contains("\n"))
        #expect(formatted.contains("123456789012345678901234567890"))
        #expect(formatted.contains("-0.0100e+200"))
        #expect(formatted.contains(#""s": "a\"b\\c\u0061""#))
        #expect(formatted.components(separatedBy: #""n":"#).count == 3)
        #expect(formatted.contains("ø😀"))
        #expect((try? JSONSerialization.jsonObject(with: Data(formatted.utf8))) != nil)
    }

    @Test func invalidJSONRemainsExactlyRaw() async {
        for raw in ["[01]", "[1,]", "{\"x\":}", "{\"x\" 1}", "[true false]", "[1e+]", "[.1]", "[+1]", #"["\q"]"#, #"["\u123z"]"#, "[\"line\nbreak\"]", "{} trailing", "[\u{00a0}1]", "-", "1.", "1e", " ", "{]", "\"unterminated"] {
            #expect(await RecordValuePresentation.formattedJSON(raw) == raw)
        }
    }

    @Test func validNumbersNeedNoFloatingPointOrObjectConversion() async {
        #expect(await RecordValuePresentation.formattedJSON(" [1e+99999,-0,0.00000000000000000000000000000001] ") == "[\n  1e+99999,\n  -0,\n  0.00000000000000000000000000000001\n]")
        #expect(await RecordValuePresentation.formattedJSON("  true \n") == "true")
        #expect(await RecordValuePresentation.formattedJSON("  {}  ") == "{}")
    }

    @Test func excessiveInputDepthAndOutputFallBackToRaw() async {
        let oversized = "[\"" + String(repeating: "x", count: 2 * 1024 * 1024) + "\"]"
        #expect(await RecordValuePresentation.formattedJSON(oversized) == oversized)
        let deep = String(repeating: "[", count: 129) + "0" + String(repeating: "]", count: 129)
        #expect(await RecordValuePresentation.formattedJSON(deep) == deep)
        // Compact input can expand drastically when many elements need deep indentation.
        let expansive = String(repeating: "[", count: 120) + String(repeating: "0,", count: 36_000) + "0" + String(repeating: "]", count: 120)
        #expect(await RecordValuePresentation.formattedJSON(expansive) == expansive)
    }

    @Test func cancelledFormattingReturnsRawWithoutRunningDetachedWork() async {
        let raw = #"{"items":[1,2,3],"label":"unchanged when cancelled"}"#
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await RecordValuePresentation.formattedJSON(raw)
        }.value
        #expect(result == raw)
    }

    @Test func cancellationStopsRunningDetachedFormattingPromptly() async throws {
        // This bounded input requires millions of indentation bytes when allowed
        // to finish. Cancellation must stop the worker, not merely hide its result.
        let raw = String(repeating: "[", count: 120) + String(repeating: "0,", count: 36_000) + "0" + String(repeating: "]", count: 120)
        let work = Task { await RecordValuePresentation.formattedJSON(raw) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = ContinuousClock.now
        work.cancel()
        let result = await work.value
        #expect(result == raw)
        #expect(cancelledAt.duration(to: .now) < .seconds(1))
    }
}
