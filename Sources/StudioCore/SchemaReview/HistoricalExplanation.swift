import Foundation
import CoreFoundation

/// A portable, explicitly saved explanation. This type deliberately has no field
/// for a database URL, connection document, credential, or SQL text.
public struct HistoricalExplanationArtifact: Codable, Sendable {
    public static let currentVersion = 1
    public static let maximumFileBytes = 16 * 1024 * 1024

    public var version: Int = currentVersion
    public var id: UUID
    public var title: String
    public var capturedAt: Date
    public var engine: String
    /// SHA-256 of the live source identity. The identity itself is never stored.
    public var sourceIdentityHash: String
    /// A hash of the schema revision at capture time, not a live source locator.
    public var sourceRevisionHash: String
    public var schema: SchemaReviewSnapshot
    public var points: [Point]
    public var queryResults: [CapturedQueryResult]
    public var tablePages: [CapturedTablePage]
    public var warnings: [String]

    public init(id: UUID = UUID(), title: String, capturedAt: Date = Date(), engine: String,
                sourceIdentityHash: String, sourceRevisionHash: String, schema: SchemaReviewSnapshot,
                points: [Point], queryResults: [CapturedQueryResult] = [],
                tablePages: [CapturedTablePage] = [], warnings: [String] = []) {
        self.id = id; self.title = title; self.capturedAt = capturedAt; self.engine = engine
        self.sourceIdentityHash = sourceIdentityHash; self.sourceRevisionHash = sourceRevisionHash
        self.schema = schema; self.points = points; self.queryResults = queryResults
        self.tablePages = tablePages; self.warnings = warnings
    }

    public struct Point: Codable, Sendable {
        public var id: String
        public var caption: String
        public var narration: String?
        public var minimumVisibleMilliseconds: Int
        public var extraHoldMilliseconds: Int
        public var advance: String
        public var actions: [HistoricalJSONValue]
        public var evidence: [EvidenceReference]
        /// Any action outside the offline graph replay subset is listed here.
        public var replayOmissions: [String]

        public init(id: String, caption: String, narration: String?, minimumVisibleMilliseconds: Int,
                    extraHoldMilliseconds: Int, advance: String, actions: [HistoricalJSONValue],
                    evidence: [EvidenceReference] = [], replayOmissions: [String] = []) {
            self.id = id; self.caption = caption; self.narration = narration
            self.minimumVisibleMilliseconds = minimumVisibleMilliseconds
            self.extraHoldMilliseconds = extraHoldMilliseconds; self.advance = advance
            self.actions = actions; self.evidence = evidence; self.replayOmissions = replayOmissions
        }
    }

    public struct EvidenceReference: Codable, Sendable {
        public var kind: String
        public var objectID: String
        public var tableID: String?
        public var resultID: String?
        public var rowOffset: Int?
        public var columnID: String?

        public init(kind: String, objectID: String, tableID: String? = nil, resultID: String? = nil,
                    rowOffset: Int? = nil, columnID: String? = nil) {
            self.kind = kind; self.objectID = objectID; self.tableID = tableID
            self.resultID = resultID; self.rowOffset = rowOffset; self.columnID = columnID
        }
    }

    public struct CapturedColumn: Codable, Sendable {
        public var name: String
        public var type: String
        public init(name: String, type: String) { self.name = name; self.type = type }
    }

    public struct CapturedCell: Codable, Sendable {
        public var type: String
        public var value: String?
        public var byteCount: Int?
        public var truncated: Bool
        public init(type: String, value: String?, byteCount: Int? = nil, truncated: Bool = false) {
            self.type = type; self.value = value; self.byteCount = byteCount; self.truncated = truncated
        }
    }

    public struct CapturedRow: Codable, Sendable {
        public var ordinal: Int
        public var values: [CapturedCell]
        public init(ordinal: Int, values: [CapturedCell]) { self.ordinal = ordinal; self.values = values }
    }

    public struct CapturedQueryResult: Codable, Sendable {
        public var resultID: String
        public var columns: [CapturedColumn]
        public var rows: [CapturedRow]
        public var displayedOffset: Int
        public var omittedRows: Int
        public var sourceWasTruncated: Bool
        public init(resultID: String, columns: [CapturedColumn], rows: [CapturedRow], displayedOffset: Int,
                    omittedRows: Int, sourceWasTruncated: Bool) {
            self.resultID = resultID; self.columns = columns; self.rows = rows
            self.displayedOffset = displayedOffset; self.omittedRows = omittedRows
            self.sourceWasTruncated = sourceWasTruncated
        }
    }

    public struct CapturedTablePage: Codable, Sendable {
        public var tableID: String
        public var columns: [CapturedColumn]
        public var rows: [CapturedRow]
        public var displayedOffset: Int
        public var omittedRows: Int
        public init(tableID: String, columns: [CapturedColumn], rows: [CapturedRow], displayedOffset: Int,
                    omittedRows: Int) {
            self.tableID = tableID; self.columns = columns; self.rows = rows
            self.displayedOffset = displayedOffset; self.omittedRows = omittedRows
        }
    }

    /// The bounded table and query pages that a single saved presentation point
    /// can show again without opening or contacting its original source.
    public struct CapturedReplayView: Sendable {
        public var pointID: String
        public var caption: String
        public var tablePages: [CapturedTablePage]
        public var queryResults: [CapturedQueryResult]
        /// Explicit pane choices saved in a `set_layout` action, when present.
        public var leftPane: String?
        public var rightPane: String?
    }

    /// Resolves only pages explicitly attached to this point through its saved
    /// actions or evidence references. It never consults a source locator.
    public func capturedView(forPointID pointID: String) -> CapturedReplayView? {
        guard let point = points.first(where: { $0.id == pointID }) else { return nil }
        var tableIDs = Set<String>()
        var resultIDs = Set<String>()
        var resultOffsets: [String: Set<Int>] = [:]
        var tableOffsets: [String: Set<Int>] = [:]
        var leftPane: String?
        var rightPane: String?

        for action in point.actions {
            guard case .object(let fields) = action,
                  case .string(let type)? = fields["type"] else { continue }
            switch type {
            case "open_table":
                if case .string(let id)? = fields["table_id"] { tableIDs.insert(id) }
            case "set_layout":
                if case .string(let pane)? = fields["left_pane"], ["schema", "tables", "query"].contains(pane) {
                    leftPane = pane
                }
                if case .string(let pane)? = fields["right_pane"], ["schema", "tables", "query"].contains(pane) {
                    rightPane = pane
                }
            default:
                break
            }
        }

        for reference in point.evidence {
            if let tableID = reference.tableID {
                tableIDs.insert(tableID)
                if let rowOffset = reference.rowOffset { tableOffsets[tableID, default: []].insert(rowOffset) }
            } else if reference.kind == "table" {
                tableIDs.insert(reference.objectID)
                if let rowOffset = reference.rowOffset { tableOffsets[reference.objectID, default: []].insert(rowOffset) }
            }

            if let resultID = reference.resultID {
                resultIDs.insert(resultID)
                if let rowOffset = reference.rowOffset { resultOffsets[resultID, default: []].insert(rowOffset) }
            } else if ["query", "query_result"].contains(reference.kind) {
                resultIDs.insert(reference.objectID)
                if let rowOffset = reference.rowOffset { resultOffsets[reference.objectID, default: []].insert(rowOffset) }
            }
        }

        let selectedPages = tablePages.filter { page in
            guard tableIDs.contains(page.tableID) else { return false }
            return Self.page(page.displayedOffset, rowCount: page.rows.count, containsAny: tableOffsets[page.tableID])
        }
        let selectedResults = queryResults.filter { result in
            guard resultIDs.contains(result.resultID) else { return false }
            return Self.page(result.displayedOffset, rowCount: result.rows.count, containsAny: resultOffsets[result.resultID])
        }
        return CapturedReplayView(pointID: pointID, caption: point.caption,
                                 tablePages: selectedPages, queryResults: selectedResults,
                                 leftPane: leftPane, rightPane: rightPane)
    }

    private static func page(_ offset: Int, rowCount: Int, containsAny requestedOffsets: Set<Int>?) -> Bool {
        guard let requestedOffsets, !requestedOffsets.isEmpty else { return true }
        guard rowCount > 0 else { return requestedOffsets.contains(offset) }
        return requestedOffsets.contains { $0 >= offset && $0 < offset + rowCount }
    }

    public func validate() throws {
        guard version == Self.currentVersion, !title.isEmpty, title.count <= 500,
              ["sqlite", "postgresql"].contains(engine), isHash(sourceIdentityHash),
              isHash(sourceRevisionHash), points.count <= 200,
              Set(points.map(\.id)).count == points.count,
              queryResults.count <= 40, tablePages.count <= 40,
              Set(queryResults.map(\.resultID)).count == queryResults.count,
              Set(tablePages.map { "\($0.tableID)\u{1f}\($0.displayedOffset)" }).count == tablePages.count,
              warnings.count <= 40 else {
            throw HistoricalExplanationError.invalid("Unsupported or oversized historical explanation metadata.")
        }
        try schema.validate()
        guard schema.engine == engine,
              schema.tables.allSatisfy({ $0.metadata.isEmpty && $0.columns.allSatisfy({ $0.defaultSQL == nil }) }) else {
            throw HistoricalExplanationError.invalid("The captured schema engine does not match the artifact.")
        }
        guard points.allSatisfy({ point in
            !point.id.isEmpty && point.id.count <= 300 && !point.caption.isEmpty && point.caption.count <= 2_000
                && (point.narration?.count ?? 0) <= 5_000
                && (0...60_000).contains(point.minimumVisibleMilliseconds)
                && (0...60_000).contains(point.extraHoldMilliseconds)
                && ["automatic", "manual"].contains(point.advance)
                && point.actions.count <= 12 && point.evidence.count <= 32 && point.replayOmissions.count <= 12
                && point.actions.allSatisfy({ validJSONValue($0, depth: 0) })
        }) else {
            throw HistoricalExplanationError.invalid("A saved explanation point exceeds its field limits.")
        }
        let resultRows = queryResults.reduce(0) { $0 + $1.rows.count }
        let tableRows = tablePages.reduce(0) { $0 + $1.rows.count }
        guard resultRows + tableRows <= 1_000,
              queryResults.allSatisfy({ result in !result.resultID.isEmpty && result.resultID.count <= 300 && result.displayedOffset >= 0 && result.omittedRows >= 0
                  && result.columns.count <= 256 && result.columns.allSatisfy(validColumn)
                  && result.rows.allSatisfy { row in row.ordinal >= 0 && row.values.count == result.columns.count } }),
              tablePages.allSatisfy({ page in !page.tableID.isEmpty && schema.tables.contains(where: { $0.id == page.tableID }) && page.tableID.count <= 500 && page.displayedOffset >= 0 && page.omittedRows >= 0
                  && page.columns.count <= 256 && page.columns.allSatisfy(validColumn)
                  && page.rows.allSatisfy { row in row.ordinal >= 0 && row.values.count == page.columns.count } }),
              (queryResults + tablePages.map({
                  CapturedQueryResult(resultID: "", columns: $0.columns, rows: $0.rows,
                                      displayedOffset: $0.displayedOffset, omittedRows: $0.omittedRows,
                                      sourceWasTruncated: false)
              })).allSatisfy({ result in result.rows.allSatisfy { $0.values.allSatisfy(validCell) } }) else {
            throw HistoricalExplanationError.invalid("Captured result rows exceed the bounded snapshot limits.")
        }
        guard evidenceIsBounded(points: points), warnings.allSatisfy({ $0.count <= 1_000 }) else {
            throw HistoricalExplanationError.invalid("Historical explanation references exceed their limits.")
        }
    }

    private func validCell(_ cell: CapturedCell) -> Bool {
        cell.type.count <= 32 && (cell.value?.utf8.count ?? 0) <= 16_384
            && (cell.byteCount.map { $0 >= 0 } ?? true)
    }

    private func validColumn(_ column: CapturedColumn) -> Bool {
        !column.name.isEmpty && column.name.count <= 1_000 && column.type.count <= 500
    }

    private func validJSONValue(_ value: HistoricalJSONValue, depth: Int) -> Bool {
        guard depth <= 8 else { return false }
        return switch value {
        case .null, .bool: true
        case .number(let value): value.isFinite
        case .string(let value): value.count <= 4_096
        case .array(let values): values.count <= 1_000 && values.allSatisfy { validJSONValue($0, depth: depth + 1) }
        case .object(let values): values.count <= 64 && values.allSatisfy { $0.key.count <= 128 && validJSONValue($0.value, depth: depth + 1) }
        }
    }

    private func evidenceIsBounded(points: [Point]) -> Bool {
        points.allSatisfy { point in
            point.evidence.allSatisfy {
                $0.kind.count <= 64 && $0.objectID.count <= 500
                    && ($0.tableID?.count ?? 0) <= 500 && ($0.resultID?.count ?? 0) <= 300
                    && ($0.columnID?.count ?? 0) <= 500 && ($0.rowOffset.map { $0 >= 0 } ?? true)
            } && point.replayOmissions.allSatisfy({ $0.count <= 100 })
        }
    }
}

/// JSON-compatible values for the deliberately small action objects recorded with
/// each displayed point. It preserves structure without accepting arbitrary code.
public indirect enum HistoricalJSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([HistoricalJSONValue])
    case object([String: HistoricalJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([HistoricalJSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: HistoricalJSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public init(any value: Any) throws {
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let values as [Any]: self = .array(try values.map(HistoricalJSONValue.init(any:)))
        case let values as [String: Any]:
            self = .object(try values.mapValues { try HistoricalJSONValue(any: $0) })
        default: throw HistoricalExplanationError.invalid("A saved action contains a non-JSON value.")
        }
    }

    public var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.foundationValue)
        case .object(let value): value.mapValues(\.foundationValue)
        }
    }
}

/// A refresh draft intentionally contains only newly captured facts. It cannot hold
/// historical narration, preventing old claims from being silently paired with new rows.
public struct HistoricalExplanationRefreshDraft: Codable, Sendable {
    public static let currentVersion = 1
    public var version: Int = currentVersion
    public var id: UUID
    public var title: String
    public var preparedAt: Date
    public var parentArtifactHash: String
    public var engine: String
    public var sourceIdentityHash: String
    public var sourceRevisionHash: String
    public var priorSchemaFingerprint: String
    public var freshSchemaFingerprint: String
    public var freshSchema: SchemaReviewSnapshot
    public var queryResults: [HistoricalExplanationArtifact.CapturedQueryResult]
    public var tablePages: [HistoricalExplanationArtifact.CapturedTablePage]
    public var schemaChanges: [String]
    public var warnings: [String]

    public init(id: UUID = UUID(), title: String, preparedAt: Date = Date(), parentArtifactHash: String,
                engine: String, sourceIdentityHash: String, sourceRevisionHash: String,
                priorSchemaFingerprint: String, freshSchemaFingerprint: String, freshSchema: SchemaReviewSnapshot,
                queryResults: [HistoricalExplanationArtifact.CapturedQueryResult] = [],
                tablePages: [HistoricalExplanationArtifact.CapturedTablePage] = [],
                schemaChanges: [String] = [], warnings: [String] = []) {
        self.id = id; self.title = title; self.preparedAt = preparedAt
        self.parentArtifactHash = parentArtifactHash; self.engine = engine
        self.sourceIdentityHash = sourceIdentityHash; self.sourceRevisionHash = sourceRevisionHash
        self.priorSchemaFingerprint = priorSchemaFingerprint; self.freshSchemaFingerprint = freshSchemaFingerprint
        self.freshSchema = freshSchema; self.queryResults = queryResults; self.tablePages = tablePages
        self.schemaChanges = schemaChanges; self.warnings = warnings
    }

    public func validate() throws {
        guard version == Self.currentVersion, !title.isEmpty, title.count <= 500,
              ["sqlite", "postgresql"].contains(engine), isHash(parentArtifactHash),
              isHash(sourceIdentityHash), isHash(sourceRevisionHash),
              isHash(priorSchemaFingerprint), isHash(freshSchemaFingerprint),
              schemaChanges.count <= 2_000, warnings.count <= 40,
              queryResults.count <= 40, tablePages.count <= 40,
              Set(queryResults.map(\.resultID)).count == queryResults.count,
              Set(tablePages.map { "\($0.tableID)\u{1f}\($0.displayedOffset)" }).count == tablePages.count else {
            throw HistoricalExplanationError.invalid("Unsupported or oversized refresh draft metadata.")
        }
        try freshSchema.validate()
        guard freshSchema.engine == engine,
              freshSchema.tables.allSatisfy({ $0.metadata.isEmpty && $0.columns.allSatisfy({ $0.defaultSQL == nil }) }),
              warnings.allSatisfy({ $0.count <= 1_000 }),
              schemaChanges.allSatisfy({ $0.count <= 1_000 }) else {
            throw HistoricalExplanationError.invalid("Refresh draft schema metadata exceeds its limits.")
        }
        let rowCount = queryResults.reduce(0) { $0 + $1.rows.count } + tablePages.reduce(0) { $0 + $1.rows.count }
        guard rowCount <= 1_000,
              queryResults.allSatisfy({ result in !result.resultID.isEmpty && result.resultID.count <= 300
                  && result.displayedOffset >= 0 && result.omittedRows >= 0 && result.columns.count <= 256
                  && result.columns.allSatisfy(validCapturedColumn)
                  && result.rows.allSatisfy({ capturedRowIsBounded($0, columnCount: result.columns.count) }) }),
              tablePages.allSatisfy({ page in !page.tableID.isEmpty && freshSchema.tables.contains(where: { $0.id == page.tableID })
                  && page.tableID.count <= 500 && page.displayedOffset >= 0 && page.omittedRows >= 0
                  && page.columns.count <= 256 && page.columns.allSatisfy(validCapturedColumn)
                  && page.rows.allSatisfy({ capturedRowIsBounded($0, columnCount: page.columns.count) }) }) else {
            throw HistoricalExplanationError.invalid("Refresh row snapshot exceeds its limit.")
        }
    }
}

public enum HistoricalExplanationError: Error, LocalizedError {
    case invalid(String)
    case destinationExists

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .destinationExists: "The artifact destination already exists; no file was overwritten."
        }
    }
}

public enum HistoricalExplanationStore {
    public static let maximumFileBytes = HistoricalExplanationArtifact.maximumFileBytes

    public static func defaultDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw HistoricalExplanationError.invalid("The application support directory is unavailable.")
        }
        let directory = support.appendingPathComponent("SQLiteGraphStudio/Explanations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    @discardableResult
    public static func write(_ artifact: HistoricalExplanationArtifact, to destination: URL? = nil) throws -> URL {
        try artifact.validate()
        let url: URL
        if let destination { url = destination.standardizedFileURL }
        else { url = try defaultDirectory().appendingPathComponent("explanation-" + artifact.id.uuidString.lowercased()).appendingPathExtension("sgexplanation") }
        guard url.pathExtension.lowercased() == "sgexplanation" else {
            throw HistoricalExplanationError.invalid("Save explanations with the .sgexplanation extension.")
        }
        let data = try encoder().encode(artifact)
        guard data.count <= maximumFileBytes else { throw HistoricalExplanationError.invalid("The explanation exceeds the 16 MB save limit.") }
        try writeExclusively(data, to: url)
        return url
    }

    public static func load(_ url: URL) throws -> HistoricalExplanationArtifact {
        let data = try readBounded(url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let artifact = try decoder.decode(HistoricalExplanationArtifact.self, from: data)
        try artifact.validate()
        return artifact
    }

    @discardableResult
    public static func write(_ draft: HistoricalExplanationRefreshDraft, to destination: URL? = nil) throws -> URL {
        try draft.validate()
        let url: URL
        if let destination { url = destination.standardizedFileURL }
        else { url = try defaultDirectory().appendingPathComponent("refresh-" + draft.id.uuidString.lowercased()).appendingPathExtension("sgrefresh") }
        guard url.pathExtension.lowercased() == "sgrefresh" else {
            throw HistoricalExplanationError.invalid("Save refresh drafts with the .sgrefresh extension.")
        }
        let data = try encoder().encode(draft)
        guard data.count <= maximumFileBytes else { throw HistoricalExplanationError.invalid("The refresh draft exceeds the 16 MB save limit.") }
        try writeExclusively(data, to: url)
        return url
    }

    public static func loadRefreshDraft(_ url: URL) throws -> HistoricalExplanationRefreshDraft {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let draft = try decoder.decode(HistoricalExplanationRefreshDraft.self, from: readBounded(url))
        try draft.validate()
        return draft
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func readBounded(_ url: URL) throws -> Data {
        guard ["sgexplanation", "sgrefresh"].contains(url.pathExtension.lowercased()) else {
            throw HistoricalExplanationError.invalid("This is not a supported explanation artifact.")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumFileBytes else {
            throw HistoricalExplanationError.invalid("The explanation artifact is missing, not a regular file, or exceeds 16 MB.")
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func writeExclusively(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !manager.fileExists(atPath: url.path) else { throw HistoricalExplanationError.destinationExists }
        let staging = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".staging")
        defer { try? manager.removeItem(at: staging) }
        try data.write(to: staging, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        do { try manager.moveItem(at: staging, to: url) }
        catch {
            if manager.fileExists(atPath: url.path) { throw HistoricalExplanationError.destinationExists }
            throw error
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private func isHash(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy(\.isHexDigit)
}

private func validCapturedColumn(_ column: HistoricalExplanationArtifact.CapturedColumn) -> Bool {
    !column.name.isEmpty && column.name.count <= 1_000 && column.type.count <= 500
}

private func capturedRowIsBounded(_ row: HistoricalExplanationArtifact.CapturedRow, columnCount: Int) -> Bool {
    row.ordinal >= 0 && row.values.count == columnCount && row.values.allSatisfy { cell in
        cell.type.count <= 32 && (cell.value?.utf8.count ?? 0) <= 16_384 && (cell.byteCount.map { $0 >= 0 } ?? true)
    }
}
