import Foundation
import Testing
@testable import StudioCore

struct BoundedCellOperationsTests {
    @Test func textSearchFindsMatchAcrossSliceBoundary() async throws {
        let source = String(repeating: "a", count: 4_095) + "needle" + String(repeating: "z", count: 100)
        let scalars = Array(source.unicodeScalars)
        let found = try await BoundedCellOperations.findText("needle") { offset, length in
            let end = min(scalars.count, offset + length)
            let slice = String(String.UnicodeScalarView(scalars[offset..<end]))
            return BoundedCellRead(storageType: "text", value: .text(slice), byteCount: nil,
                                   characterCount: scalars.count, offset: offset, returnedLength: end - offset)
        }
        #expect(found == 4_095)
    }

    @Test func clipboardCollectionIsExactAndBounded() async throws {
        let source = Data(repeating: 0xA5, count: 10_000)
        let value = try await BoundedCellOperations.collectForClipboard { offset, length in
            let end = min(source.count, offset + length)
            return BoundedCellRead(storageType: "blob", value: .blob(source.subdata(in: offset..<end)),
                                   byteCount: source.count, characterCount: nil,
                                   offset: offset, returnedLength: end - offset)
        }
        #expect(value == .binary(source))

        let text = String(repeating: "é🛰️", count: 4_000)
        let scalars = Array(text.unicodeScalars)
        let copiedText = try await BoundedCellOperations.collectForClipboard { offset, length in
            let end = min(scalars.count, offset + length)
            let slice = String(String.UnicodeScalarView(scalars[offset..<end]))
            return BoundedCellRead(storageType: "text", value: .text(slice), byteCount: nil,
                                   characterCount: scalars.count, offset: offset, returnedLength: end - offset)
        }
        #expect(copiedText == .text(text))
    }

    @Test func collectionStopsWhenLengthChangesBetweenSlices() async throws {
        await #expect(throws: BoundedCellOperations.Failure.self) {
            _ = try await BoundedCellOperations.collectForClipboard { offset, length in
                let count = offset == 0 ? 10_000 : 10_001
                return BoundedCellRead(storageType: "text", value: .text(String(repeating: "x", count: length)),
                                       byteCount: nil, characterCount: count,
                                       offset: offset, returnedLength: length)
            }
        }
    }

    @Test func streamingSaveWritesExactTextWithoutOverwriting() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("value.txt")
        let source = String(repeating: "é🛰️", count: 5_000)
        let scalars = Array(source.unicodeScalars)
        func read(_ offset: Int, _ length: Int) async throws -> BoundedCellRead? {
            let end = min(scalars.count, offset + length)
            let slice = String(String.UnicodeScalarView(scalars[offset..<end]))
            return BoundedCellRead(storageType: "text", value: .text(slice), byteCount: nil,
                                   characterCount: scalars.count, offset: offset, returnedLength: end - offset)
        }
        let written = try await BoundedCellOperations.saveToFile(at: destination, read: read)
        #expect(written == source.utf8.count)
        #expect(try String(contentsOf: destination, encoding: .utf8) == source)
        await #expect(throws: BoundedCellOperations.Failure.self) {
            _ = try await BoundedCellOperations.saveToFile(at: destination, read: read)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == source)
    }
}
