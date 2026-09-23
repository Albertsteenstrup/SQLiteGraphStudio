import Foundation

/// Operations over a large cell that never ask the database for more than one
/// bounded slice at a time. A caller supplies an identity-checked reader so a
/// changing table cannot turn an offset into a different record's value.
@MainActor
public enum BoundedCellOperations {
    public enum Failure: Error, LocalizedError {
        case invalidSearch
        case changedValue
        case valueTooLarge(Int)
        case unsupportedType
        case destinationExists

        public var errorDescription: String? {
            switch self {
            case .invalidSearch: "Enter between 1 and 4096 characters to search for."
            case .changedValue: "The value changed while it was being read. Refresh the table and try again."
            case .valueTooLarge(let limit): "The value exceeds the \(limit) byte clipboard limit. Save it to a file instead."
            case .unsupportedType: "This operation is available for text and binary values."
            case .destinationExists: "A file already exists at that destination. Choose another name."
            }
        }
    }

    public enum CompleteValue: Sendable, Equatable {
        case text(String)
        case binary(Data)
    }

    public static let sliceLength = 4_096
    public static let clipboardByteLimit = 16 * 1024 * 1024

    /// Returns a Unicode-scalar offset. A short overlap catches matches that
    /// cross two database slices without materializing the whole cell.
    public static func findText(
        _ needle: String,
        startingAt start: Int = 0,
        read: (Int, Int) async throws -> BoundedCellRead?
    ) async throws -> Int? {
        let searched = Array(needle.unicodeScalars)
        guard !searched.isEmpty, searched.count <= sliceLength, start >= 0 else { throw Failure.invalidSearch }
        var offset = start
        var overlap: [Unicode.Scalar] = []
        var expectedTotal: Int?
        while true {
            try Task.checkCancellation()
            guard let part = try await read(offset, sliceLength) else { throw Failure.changedValue }
            guard part.offset == offset, case .text(let text) = part.value,
                  let total = part.characterCount, total >= 0,
                  part.returnedLength == text.unicodeScalars.count,
                  part.returnedLength <= sliceLength,
                  expectedTotal.map({ $0 == total }) ?? true else { throw Failure.changedValue }
            expectedTotal = total
            let scalars = overlap + Array(text.unicodeScalars)
            if scalars.count >= searched.count {
                for index in 0...(scalars.count - searched.count) {
                    if scalars[index..<(index + searched.count)].elementsEqual(searched) {
                        return offset - overlap.count + index
                    }
                }
            }
            let (next, overflow) = offset.addingReportingOverflow(part.returnedLength)
            guard !overflow, next <= total else { throw Failure.changedValue }
            if next == total { return nil }
            guard next > offset else { throw Failure.changedValue }
            overlap = Array(scalars.suffix(max(0, searched.count - 1)))
            offset = next
        }
    }

    /// Collects a value for an explicit clipboard action, with a hard byte
    /// limit. Oversized values remain available through a streaming file save.
    public static func collectForClipboard(
        read: (Int, Int) async throws -> BoundedCellRead?
    ) async throws -> CompleteValue {
        var offset = 0
        var expectedTotal: Int?
        var text = String()
        var binary = Data()
        var kind: String?
        var materializedBytes = 0
        while true {
            try Task.checkCancellation()
            guard let part = try await read(offset, sliceLength), part.offset == offset,
                  part.returnedLength <= sliceLength,
                  let total = part.totalLength, total >= 0,
                  expectedTotal.map({ $0 == total }) ?? true else { throw Failure.changedValue }
            expectedTotal = total
            if total > clipboardByteLimit { throw Failure.valueTooLarge(clipboardByteLimit) }
            switch part.value {
            case .text(let value):
                guard kind == nil || kind == "text", part.returnedLength == value.unicodeScalars.count else { throw Failure.changedValue }
                kind = "text"
                materializedBytes += value.utf8.count
                if materializedBytes > clipboardByteLimit { throw Failure.valueTooLarge(clipboardByteLimit) }
                text.append(value)
            case .blob(let value):
                guard kind == nil || kind == "binary", part.returnedLength == value.count else { throw Failure.changedValue }
                kind = "binary"
                materializedBytes += value.count
                if materializedBytes > clipboardByteLimit { throw Failure.valueTooLarge(clipboardByteLimit) }
                binary.append(value)
            default: throw Failure.unsupportedType
            }
            let (next, overflow) = offset.addingReportingOverflow(part.returnedLength)
            guard !overflow, next <= total else { throw Failure.changedValue }
            if next == total {
                return kind == "binary" ? .binary(binary) : .text(text)
            }
            guard next > offset else { throw Failure.changedValue }
            offset = next
        }
    }

    /// Streams raw UTF-8 text or binary bytes to a temporary sibling, then
    /// moves it into place only after every slice was read successfully.
    /// Existing files are never overwritten, including on cancellation.
    @discardableResult
    public static func saveToFile(
        at destination: URL,
        read: (Int, Int) async throws -> BoundedCellRead?,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> Int {
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else { throw Failure.destinationExists }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        guard files.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: temporary) }
        catch {
            try? files.removeItem(at: temporary)
            throw error
        }
        var finished = false
        defer {
            try? handle.close()
            if !finished { try? files.removeItem(at: temporary) }
        }
        var offset = 0
        var expectedTotal: Int?
        var kind: String?
        var bytesWritten = 0
        while true {
            try Task.checkCancellation()
            guard let part = try await read(offset, sliceLength), part.offset == offset,
                  part.returnedLength <= sliceLength,
                  let total = part.totalLength, total >= 0,
                  expectedTotal.map({ $0 == total }) ?? true else { throw Failure.changedValue }
            expectedTotal = total
            let data: Data
            switch part.value {
            case .text(let value):
                guard kind == nil || kind == "text", part.returnedLength == value.unicodeScalars.count else { throw Failure.changedValue }
                kind = "text"
                data = Data(value.utf8)
            case .blob(let value):
                guard kind == nil || kind == "binary", part.returnedLength == value.count else { throw Failure.changedValue }
                kind = "binary"
                data = value
            default: throw Failure.unsupportedType
            }
            try handle.write(contentsOf: data)
            bytesWritten += data.count
            let (next, overflow) = offset.addingReportingOverflow(part.returnedLength)
            guard !overflow, next <= total else { throw Failure.changedValue }
            progress?(next, total)
            if next == total { break }
            guard next > offset else { throw Failure.changedValue }
            offset = next
            await Task.yield()
        }
        try Task.checkCancellation()
        try handle.synchronize()
        try handle.close()
        guard !files.fileExists(atPath: destination.path) else { throw Failure.destinationExists }
        try files.moveItem(at: temporary, to: destination)
        finished = true
        return bytesWritten
    }
}
