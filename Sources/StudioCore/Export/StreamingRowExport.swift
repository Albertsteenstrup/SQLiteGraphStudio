import Foundation
import Darwin

public enum TableExportScope: Sendable { case loadedRows, allMatchingRows }

/// Cancellation is also visible on GRDB's dispatch queue, which has no Swift Task.
public final class ExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public func check() throws { try lock.withLock { if cancelled { throw CancellationError() } } }
    func publish(_ body: () throws -> Void) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try body()
        }
    }
}

/// Single-owner writer; Sendable allows ownership to cross a database read queue.
/// At most one encoded row is retained. Only finish() publishes the destination.
final class AtomicRowExportWriter: @unchecked Sendable {
    let destination: URL
    let temporaryURL: URL
    private let handle: FileHandle
    private let keys: [String]
    private let format: DataTransferFormat
    private let cancellation: ExportCancellation
    private var finished = false
    private(set) var rowCount = 0

    init(destination: URL, names: [String], format: DataTransferFormat, cancellation: ExportCancellation) throws {
        self.destination = destination
        self.temporaryURL = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        self.keys = ResultSerialization.uniqueNames(names)
        self.format = format
        self.cancellation = cancellation
        try cancellation.check()
        let descriptor = Darwin.open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try write(format == .csv ? names.map { ResultSerialization.csvText($0) }.joined(separator: ",") : "[")
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func append(_ values: [DatabaseResultValue]) throws {
        try cancellation.check()
        let text = try ResultSerialization.row(values, keys: keys, format: format)
        try write((format == .csv ? "\n" : (rowCount == 0 ? "" : ",\n")) + text)
        rowCount += 1
    }

    func finish() throws -> Int {
        try cancellation.check()
        if format == .json { try write("]") }
        try handle.synchronize()
        try handle.close()
        // Cancellation and rename have one ordered boundary: a cancellation
        // accepted before publication leaves the old destination untouched.
        try cancellation.publish {
            guard Darwin.rename(temporaryURL.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            finished = true
        }
        return rowCount
    }

    func abort() {
        guard !finished else { return }
        try? handle.close()
        try? FileManager.default.removeItem(at: temporaryURL)
    }
    deinit { abort() }
    private func write(_ text: String) throws { try handle.write(contentsOf: Data(text.utf8)) }
}

public enum StreamingRowExport {
    public static func write(names: [String], rows: [[DatabaseResultValue]], to destination: URL, format: DataTransferFormat,
                             cancellation: ExportCancellation = ExportCancellation(), progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> Int {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            // The retained result is immutable. File IO and encoding stay off the UI actor.
            return try await Task.detached {
                let writer = try AtomicRowExportWriter(destination: destination, names: names, format: format, cancellation: cancellation)
                defer { writer.abort() }
                progress(0)
                for values in rows {
                    try writer.append(values)
                    if writer.rowCount % 128 == 0 { progress(writer.rowCount) }
                }
                progress(writer.rowCount)
                return try writer.finish()
            }.value
        } onCancel: { cancellation.cancel() }
    }
}

public struct RowExportProgress: Sendable {
    public let id: UUID
    public let scope: String
    public var rowsWritten: Int = 0
    public let totalRows: Int?
    public var isRunning = true
    public var outcome: String? = nil
}
