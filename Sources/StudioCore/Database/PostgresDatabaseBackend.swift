import Foundation
import Logging
import NIOSSL
import PostgresNIO

public struct PostgresCatalogObject: Sendable, Hashable {
    public let schemaName: String
    public let objectName: String
    public let relkind: String
    public let rowEstimate: Double?
    public let hasInheritanceChildren: Bool

    public init(schemaName: String, objectName: String, relkind: String, rowEstimate: Double?, hasInheritanceChildren: Bool = false) {
        self.schemaName = schemaName
        self.objectName = objectName
        self.relkind = relkind
        self.rowEstimate = rowEstimate
        self.hasInheritanceChildren = hasInheritanceChildren
    }
}

public struct PostgresCatalogColumn: Sendable, Hashable {
    public let schemaName: String
    public let objectName: String
    public let name: String
    public let declaredType: String
    public let notNull: Bool
    public let defaultValueSQL: String?
    public let ordinal: Int
    public let generatedKind: String
    public let identityKind: String

    public init(
        schemaName: String,
        objectName: String,
        name: String,
        declaredType: String,
        notNull: Bool,
        defaultValueSQL: String?,
        ordinal: Int,
        generatedKind: String = "",
        identityKind: String = ""
    ) {
        self.schemaName = schemaName
        self.objectName = objectName
        self.name = name
        self.declaredType = declaredType
        self.notNull = notNull
        self.defaultValueSQL = defaultValueSQL
        self.ordinal = ordinal
        self.generatedKind = generatedKind
        self.identityKind = identityKind
    }
}

public struct PostgresCatalogIndex: Sendable, Hashable {
    public let schemaName: String
    public let objectName: String
    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public let isPrimary: Bool
    public let isPartial: Bool

    public init(
        schemaName: String,
        objectName: String,
        name: String,
        columns: [String],
        isUnique: Bool,
        isPrimary: Bool,
        isPartial: Bool
    ) {
        self.schemaName = schemaName
        self.objectName = objectName
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.isPartial = isPartial
    }
}

public struct PostgresCatalogForeignKey: Sendable, Hashable {
    public let id: String
    public let constraintName: String
    public let sourceSchemaName: String
    public let sourceObjectName: String
    public let sourceColumns: [String]
    public let targetSchemaName: String
    public let targetObjectName: String
    public let targetColumns: [String]

    public init(
        id: String,
        constraintName: String,
        sourceSchemaName: String,
        sourceObjectName: String,
        sourceColumns: [String],
        targetSchemaName: String,
        targetObjectName: String,
        targetColumns: [String]
    ) {
        self.id = id
        self.constraintName = constraintName
        self.sourceSchemaName = sourceSchemaName
        self.sourceObjectName = sourceObjectName
        self.sourceColumns = sourceColumns
        self.targetSchemaName = targetSchemaName
        self.targetObjectName = targetObjectName
        self.targetColumns = targetColumns
    }
}

public struct PostgresCatalogTrigger: Sendable, Hashable {
    public let schemaName: String
    public let objectName: String
    public let name: String
    public let sql: String

    public init(schemaName: String, objectName: String, name: String, sql: String) {
        self.schemaName = schemaName
        self.objectName = objectName
        self.name = name
        self.sql = sql
    }
}

public struct PostgresCatalogCheckConstraint: Sendable, Hashable {
    public let id: String
    public let schemaName: String
    public let objectName: String
    public let name: String
    public let columns: [String]
    public let sql: String

    public init(id: String, schemaName: String, objectName: String, name: String, columns: [String], sql: String) {
        self.id = id
        self.schemaName = schemaName
        self.objectName = objectName
        self.name = name
        self.columns = columns
        self.sql = sql
    }
}

public enum PostgresCatalogMapper {
    public static func makeSnapshot(
        objects: [PostgresCatalogObject],
        columns: [PostgresCatalogColumn],
        indexes: [PostgresCatalogIndex],
        foreignKeys: [PostgresCatalogForeignKey],
        triggers: [PostgresCatalogTrigger] = [],
        checkConstraints: [PostgresCatalogCheckConstraint] = []
    ) -> CatalogSnapshot {
        let columnsByObject = Dictionary(grouping: columns) { key($0.schemaName, $0.objectName) }
        let indexesByObject = Dictionary(grouping: indexes) { key($0.schemaName, $0.objectName) }
        let foreignKeysByObject = Dictionary(grouping: foreignKeys) { key($0.sourceSchemaName, $0.sourceObjectName) }
        let triggersByObject = Dictionary(grouping: triggers) { key($0.schemaName, $0.objectName) }
        let checksByObject = Dictionary(grouping: checkConstraints) { key($0.schemaName, $0.objectName) }

        let descriptors = objects.map { object -> TableDescriptor in
            let objectKey = key(object.schemaName, object.objectName)
            let objectColumns = (columnsByObject[objectKey] ?? []).sorted { $0.ordinal < $1.ordinal }
            let objectIndexes = (indexesByObject[objectKey] ?? []).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            let primaryIndex = objectIndexes.first(where: \.isPrimary)
            let primaryKeyColumns = primaryIndex?.columns ?? []
            let descriptorName = objectKey

            var constraints: [SchemaConstraint] = []
            if !primaryKeyColumns.isEmpty {
                constraints.append(
                    SchemaConstraint(
                        id: descriptorName + ".pk",
                        kind: .primaryKey,
                        name: primaryIndex?.name,
                        columns: primaryKeyColumns,
                        detail: "PRIMARY KEY (\(primaryKeyColumns.joined(separator: ", ")))"
                    )
                )
            }
            for column in objectColumns {
                if column.notNull {
                    constraints.append(
                        SchemaConstraint(
                            id: "\(descriptorName).\(column.name).not-null",
                            kind: .notNull,
                            columns: [column.name],
                            detail: "\(column.name) NOT NULL"
                        )
                    )
                }
                if let defaultValueSQL = column.defaultValueSQL {
                    constraints.append(
                        SchemaConstraint(
                            id: "\(descriptorName).\(column.name).default",
                            kind: .defaultValue,
                            columns: [column.name],
                            detail: "\(column.name) DEFAULT \(defaultValueSQL)"
                        )
                    )
                }
            }
            for index in objectIndexes where index.isUnique && !index.isPrimary && !index.columns.isEmpty {
                constraints.append(
                    SchemaConstraint(
                        id: "\(descriptorName).unique.\(index.name)",
                        kind: .unique,
                        name: index.name,
                        columns: index.columns,
                        detail: "UNIQUE (\(index.columns.joined(separator: ", ")))"
                    )
                )
            }
            for foreignKey in foreignKeysByObject[objectKey] ?? [] {
                constraints.append(
                    SchemaConstraint(
                        id: "\(descriptorName).fk.\(foreignKey.id)",
                        kind: .foreignKey,
                        name: foreignKey.constraintName,
                        columns: foreignKey.sourceColumns,
                        detail: "FOREIGN KEY (\(foreignKey.sourceColumns.joined(separator: ", "))) REFERENCES \(key(foreignKey.targetSchemaName, foreignKey.targetObjectName)) (\(foreignKey.targetColumns.joined(separator: ", ")))"
                    )
                )
            }
            for check in (checksByObject[objectKey] ?? []).sorted(by: {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }) {
                constraints.append(
                    SchemaConstraint(
                        id: "\(descriptorName).check.\(check.id)",
                        kind: .check,
                        name: check.name,
                        columns: check.columns,
                        detail: check.sql
                    )
                )
            }

            let generatedColumns = objectColumns.compactMap { column -> GeneratedColumnInfo? in
                guard !column.generatedKind.isEmpty else { return nil }
                return GeneratedColumnInfo(
                    name: column.name,
                    declaredType: column.declaredType,
                    storedKind: column.generatedKind == "s" ? "stored" : "virtual"
                )
            }

            return TableDescriptor(
                name: descriptorName,
                objectType: objectType(for: object.relkind),
                columns: objectColumns.map { column in
                    TableColumn(
                        name: column.name,
                        declaredType: column.declaredType,
                        notNull: column.notNull,
                        defaultValueSQL: column.defaultValueSQL,
                        primaryKeyOrdinal: primaryKeyColumns.firstIndex(of: column.name).map { $0 + 1 } ?? 0,
                        hiddenValue: column.generatedKind.isEmpty ? 0 : (column.generatedKind == "s" ? 3 : 2),
                        isEditable: false,
                        identityKind: column.identityKind
                    )
                },
                primaryKeyColumns: primaryKeyColumns,
                rowIdentityStrategy: .readOnly,
                isWithoutRowID: false,
                isEditable: false,
                rowCount: object.rowEstimate.flatMap { $0 >= 0 ? Int($0.rounded()) : nil },
                indexes: objectIndexes.map { index in
                    SchemaIndex(
                        name: index.name,
                        columns: index.columns,
                        isUnique: index.isUnique,
                        origin: index.isPrimary ? "primary" : "c",
                        isPartial: index.isPartial,
                        sql: nil
                    )
                },
                triggers: (triggersByObject[objectKey] ?? []).sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }.map { trigger in
                    SchemaTrigger(name: trigger.name, tableName: descriptorName, sql: trigger.sql)
                },
                constraints: constraints,
                generatedColumns: generatedColumns,
                schemaName: object.schemaName,
                objectName: object.objectName,
                hasInheritanceChildren: object.hasInheritanceChildren
            )
        }

        let descriptorByKey: [String: TableDescriptor] = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.name, $0) })
        let uniqueKeys: [String: Set<String>] = Dictionary(uniqueKeysWithValues: descriptors.map { descriptor in
            (
                descriptor.name,
                Set(
                    descriptor.indexes
                        .filter { $0.isUnique && !$0.columns.isEmpty }
                        .map { $0.columns }
                        .map { $0.joined(separator: "\u{1F}") }
                )
            )
        })

        let edges = foreignKeys.flatMap { foreignKey -> [GraphEdge] in
            let sourceKey = key(foreignKey.sourceSchemaName, foreignKey.sourceObjectName)
            let targetKey = key(foreignKey.targetSchemaName, foreignKey.targetObjectName)
            guard descriptorByKey[sourceKey] != nil, descriptorByKey[targetKey] != nil,
                  foreignKey.sourceColumns.count == foreignKey.targetColumns.count,
                  !foreignKey.sourceColumns.isEmpty
            else {
                return []
            }
            let sourceIsUnique = uniqueKeys[sourceKey]?.contains(foreignKey.sourceColumns.joined(separator: "\u{1F}")) ?? false
            let targetIsUnique = uniqueKeys[targetKey]?.contains(foreignKey.targetColumns.joined(separator: "\u{1F}")) ?? false
            let cardinality = inferEdgeCardinality(sourceUnique: sourceIsUnique, targetUnique: targetIsUnique)
            return zip(foreignKey.sourceColumns, foreignKey.targetColumns).enumerated().map { index, pair in
                GraphEdge(
                    id: "\(sourceKey)->\(targetKey)#\(foreignKey.id):\(index)",
                    sourceID: sourceKey,
                    targetID: targetKey,
                    sourceColumn: pair.0,
                    targetColumn: pair.1,
                    cardinality: cardinality
                )
            }
        }

        let graphNodes = descriptors.map {
            GraphNode(id: $0.name, title: $0.name, isEditable: false)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        return CatalogSnapshot(
            descriptors: descriptors.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            graph: SchemaGraph(nodes: graphNodes, edges: edges),
            recordRelationshipMetadata: foreignKeys.map { foreignKey in
                let sourceTable = RecordTableID(schemaName: foreignKey.sourceSchemaName, objectName: foreignKey.sourceObjectName)
                let targetTable = RecordTableID(schemaName: foreignKey.targetSchemaName, objectName: foreignKey.targetObjectName)
                return RecordRelationship(
                    id: sourceTable.id + ":fk:" + foreignKey.id,
                    sourceTable: sourceTable,
                    targetTable: targetTable,
                    sourceColumns: foreignKey.sourceColumns,
                    targetColumns: foreignKey.targetColumns,
                    sourceDescriptor: descriptors.first { RecordTableID(descriptor: $0) == sourceTable },
                    targetDescriptor: descriptors.first { RecordTableID(descriptor: $0) == targetTable }
                )
            }
        )
    }

    private static func key(_ schema: String, _ object: String) -> String {
        catalogDisplayKey(schema, object)
    }

    /// Keep ordinary display keys stable while preserving identifier boundaries.
    static func catalogDisplayKey(_ schema: String, _ object: String) -> String {
        func component(_ value: String) -> String {
            value.range(of: #"^[A-Za-z_][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil ? value : quoteIdentifier(value)
        }
        return component(schema) + "." + component(object)
    }

    private static func objectType(for relkind: String) -> DatabaseObjectType {
        switch relkind {
        case "r": return .table
        case "p": return .partitionedTable
        case "v": return .view
        case "m": return .materializedView
        default: return .unknown
        }
    }
}

public enum PostgresValueMapper {
    // Money's binary Int64 contains minor units; its decimal scale comes from
    // lc_monetary on the leased connection, never from a client locale assumption.
    @TaskLocal static var moneyFractionDigits: Int?

    public static func map(_ data: PostgresData) -> PostgresValue {
        guard data.value != nil else { return .null }

        if data.type.knownSQLName?.hasSuffix("[]") == true {
            return .array(arrayText(data))
        }

        switch data.type {
        case .bool:
            return data.bool.map(PostgresValue.boolean) ?? .text(rawText(data))
        case .int2, .int4, .int8, .oid, .regproc:
            return data.int64.map(PostgresValue.integer) ?? .text(rawText(data))
        case .float4, .float8:
            return data.double.map(PostgresValue.double) ?? .text(rawText(data))
        case .numeric:
            return .exactNumeric(numericText(data) ?? rawText(data))
        case .money:
            if let text = moneyText(data) { return .exactNumeric(text) }
            // Without server scale, preserve the bytes instead of inventing an amount.
            return data.formatCode == .text ? .text(rawText(data)) : .blob(Data(data.bytes ?? []))
        case .uuid:
            return .uuid(data.uuid?.uuidString ?? rawText(data))
        case .date, .time, .timetz, .timestamp, .timestamptz:
            return .dateTime(temporalText(data) ?? rawText(data))
        case .json:
            return .json(data.json.flatMap { String(data: $0, encoding: .utf8) } ?? rawText(data))
        case .jsonb:
            return .json(data.jsonb.flatMap { String(data: $0, encoding: .utf8) } ?? rawText(data))
        case .bytea:
            return .blob(Data(data.bytes ?? []))
        case .bit, .varbit:
            return bitText(data).map(PostgresValue.text) ?? .blob(Data(data.bytes ?? []))
        case .boolArray, .byteaArray, .charArray, .nameArray, .int2Array, .int4Array,
             .int8Array, .float4Array, .float8Array, .textArray, .uuidArray, .jsonArray,
             .jsonbArray:
            return .array(arrayText(data))
        default:
            if data.type.isUserDefined, let string = data.string {
                return .text(string)
            }
            return data.string.map(PostgresValue.text) ?? .blob(Data(data.bytes ?? []))
        }
    }

    public static func typeLabel(for data: PostgresData) -> String {
        data.type.knownSQLName ?? "OID \(data.type.rawValue)"
    }

    private static func rawText(_ data: PostgresData) -> String {
        if let string = data.string {
            return string
        }
        if let value = data.value, data.formatCode == .text {
            return String(decoding: value.readableBytesView, as: UTF8.self)
        }
        return "0x" + (data.bytes ?? []).map { String(format: "%02x", $0) }.joined()
    }

    private static func bitText(_ data: PostgresData) -> String? {
        guard data.formatCode == .binary else { return rawText(data) }
        guard var buffer = data.value, let count = buffer.readInteger(as: Int32.self), count >= 0,
              buffer.readableBytes == (Int(count) + 7) / 8 else { return nil }
        let bytes = Array(buffer.readableBytesView)
        return String(decoding: (0..<Int(count)).map { index in
            UInt8(bytes[index / 8] & (1 << (7 - index % 8)) == 0 ? 48 : 49)
        }, as: UTF8.self)
    }

    private static func numericText(_ data: PostgresData) -> String? {
        guard data.formatCode == .binary else { return rawText(data) }
        guard let buffer = data.value, buffer.readableBytes >= 8,
              let sign = buffer.getInteger(at: buffer.readerIndex + 4, as: UInt16.self),
              let scale = buffer.getInteger(at: buffer.readerIndex + 6, as: UInt16.self) else { return nil }
        // NIO returns zero for ndigits=0 before inspecting these special signs.
        switch sign {
        case 0xC000: return "NaN"
        case 0xD000: return "Infinity"
        case 0xF000: return "-Infinity"
        default: break
        }
        guard var text = data.numeric?.string else { return nil }
        // PostgreSQL trims zero base-10000 groups on the wire but retains dscale.
        // Restore presentation scale without rounding through floating point.
        if scale > 0 {
            let existing = text.firstIndex(of: ".").map { text.distance(from: text.index(after: $0), to: text.endIndex) } ?? 0
            if existing == 0 { text += "." }
            if Int(scale) > existing { text += String(repeating: "0", count: Int(scale) - existing) }
        }
        return text
    }

    private static func moneyText(_ data: PostgresData) -> String? {
        guard data.formatCode == .binary, let scale = moneyFractionDigits,
              (0...10).contains(scale), var buffer = data.value,
              buffer.readableBytes == 8, let minorUnits = buffer.readInteger(as: Int64.self) else { return nil }
        var digits = String(minorUnits.magnitude)
        if scale > 0 {
            digits = String(repeating: "0", count: max(0, scale + 1 - digits.count)) + digits
            digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -scale))
        }
        return (minorUnits < 0 ? "-" : "") + digits
    }

    /// PostgreSQL timestamps are integer microseconds from 2000-01-01.
    /// Going through Foundation Date.description would discard the key's fraction.
    private static func temporalText(_ data: PostgresData) -> String? {
        guard data.formatCode == .binary, var buffer = data.value else { return nil }
        if data.type == .date {
            guard let days = buffer.readInteger(as: Int32.self) else { return nil }
            if days == Int32.max { return "infinity" }
            if days == Int32.min { return "-infinity" }
            let date = calendarDate(Int64(days))
            return date.text + (date.beforeCommonEra ? " BC" : "")
        }
        guard let micros = buffer.readInteger(as: Int64.self) else { return nil }
        if data.type == .time || data.type == .timetz {
            guard (0...86_400_000_000).contains(micros) else { return nil }
            var result = clockText(micros)
            if data.type == .timetz {
                guard let secondsWest = buffer.readInteger(as: Int32.self) else { return nil }
                let secondsEast = -Int64(secondsWest)
                let absolute = abs(secondsEast)
                result += (secondsEast < 0 ? "-" : "+") + padded(absolute / 3600, 2) + ":" + padded(absolute / 60 % 60, 2)
                if absolute % 60 != 0 { result += ":" + padded(absolute % 60, 2) }
            }
            return result
        }
        if micros == Int64.max { return "infinity" }
        if micros == Int64.min { return "-infinity" }
        var days = micros / 86_400_000_000
        var remainder = micros % 86_400_000_000
        if remainder < 0 { days -= 1; remainder += 86_400_000_000 }
        let date = calendarDate(days)
        return date.text + " " + clockText(remainder) + (data.type == .timestamptz ? "+00" : "") + (date.beforeCommonEra ? " BC" : "")
    }

    private static func clockText(_ micros: Int64) -> String {
        let seconds = micros / 1_000_000
        return padded(seconds / 3600, 2) + ":" + padded(seconds / 60 % 60, 2) + ":" + padded(seconds % 60, 2) + "." + padded(micros % 1_000_000, 6)
    }

    private static func padded(_ value: Int64, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    /// Proleptic Gregorian conversion using integer days, including PostgreSQL's
    /// extended year range and BC dates, without floating-point rounding.
    private static func calendarDate(_ postgresDays: Int64) -> (text: String, beforeCommonEra: Bool) {
        let shifted = postgresDays + 10_957 + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        var year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPart = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPart + 2) / 5 + 1
        let month = monthPart + (monthPart < 10 ? 3 : -9)
        if month <= 2 { year += 1 }
        return (padded(year > 0 ? year : 1 - year, 4) + "-" + padded(month, 2) + "-" + padded(day, 2), year <= 0)
    }

    private static func arrayText(_ data: PostgresData) -> String {
        guard data.formatCode == .binary, var buffer = data.value else { return rawText(data) }
        guard let dimensionCount = buffer.readInteger(as: Int32.self), (0...6).contains(dimensionCount),
              buffer.readInteger(as: Int32.self) != nil,
              let elementOID = buffer.readInteger(as: UInt32.self),
              let elementType = PostgresDataType(rawValue: elementOID) else { return rawText(data) }
        if dimensionCount == 0 { return "{}" }
        var dimensions: [(length: Int, lowerBound: Int)] = []
        var elementCount = 1
        for _ in 0..<dimensionCount {
            guard let length = buffer.readInteger(as: Int32.self), length >= 0,
                  let lowerBound = buffer.readInteger(as: Int32.self) else { return rawText(data) }
            let product = elementCount.multipliedReportingOverflow(by: Int(length))
            guard !product.overflow else { return rawText(data) }
            elementCount = product.partialValue
            dimensions.append((Int(length), Int(lowerBound)))
        }
        // Every element requires at least its four-byte length header.
        guard elementCount <= buffer.readableBytes / 4 else { return rawText(data) }
        var elements: [String] = []
        for _ in 0..<elementCount {
            guard let length = buffer.readInteger(as: Int32.self) else { return rawText(data) }
            if length == -1 {
                elements.append("NULL")
            } else {
                guard length >= 0, let value = buffer.readSlice(length: Int(length)) else { return rawText(data) }
                elements.append(arrayElementText(PostgresData(type: elementType, value: value)))
            }
        }
        var index = 0
        func render(_ depth: Int) -> String {
            let parts = (0..<dimensions[depth].length).map { _ -> String in
                if depth + 1 < dimensions.count { return render(depth + 1) }
                defer { index += 1 }
                return elements[index]
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
        let bounds = dimensions.contains { $0.lowerBound != 1 }
            ? dimensions.map { "[\($0.lowerBound):\($0.lowerBound + $0.length - 1)]" }.joined() + "="
            : ""
        return bounds + render(0)
    }

    private static func arrayElementText(_ data: PostgresData) -> String {
        guard data.value != nil else { return "NULL" }
        let value: String
        switch map(data) {
        case .blob(let bytes): value = "\\x" + bytes.map { String(format: "%02x", $0) }.joined()
        case let mapped: value = mapped.editorText
        }
        // Quote every non-NULL element: literal NULL, empty strings, delimiters,
        // whitespace, quotes and backslashes all round-trip through array input.
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

}

public actor PostgresDatabaseBackend: DatabaseBackend {
    public nonisolated let configuration: PostgresConnectionConfiguration
    public nonisolated let capabilities: DatabaseCapabilities = .postgresReadOnly

    private let credentialOverride: String?
    private var client: PostgresClient?
    private var clientRunTask: Task<Void, Never>?

    public init(configuration: PostgresConnectionConfiguration, password: String? = nil) {
        self.configuration = configuration
        self.credentialOverride = password
    }

    public func open() async throws {
        guard !configuration.host.isEmpty,
              (1...65_535).contains(configuration.port),
              !configuration.database.isEmpty,
              !configuration.username.isEmpty
        else {
            throw DatabaseUserError(
                kind: .invalidInput,
                message: "Enter a valid PostgreSQL host, port, database, and username."
            )
        }

        let password = credentialOverride ?? PostgresExternalCredential.password(for: configuration)
        var clientConfiguration = PostgresClient.Configuration(
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            password: password,
            database: configuration.database,
            tls: configuration.tlsMode == .disabled
                ? .disable
                : .require(.makeClientConfiguration())
        )
        clientConfiguration.options.additionalStartupParameters = [
            ("default_transaction_read_only", "on")
        ]
        clientConfiguration.options.connectTimeout = .seconds(10)
        clientConfiguration.options.tlsServerName = configuration.host

        let client = PostgresClient(configuration: clientConfiguration)
        self.client = client
        let runTask = Task { await client.run() }
        self.clientRunTask = runTask

        do {
            let result = try await withReadOnlyTransaction { connection in
                try await Self.query(
                    PostgresQuery(unsafeSQL: "SELECT current_setting('transaction_read_only') AS read_only"),
                    on: connection
                )
            }
            guard result.rows.first?.first?.displayText.lowercased() == "on" else {
                throw DatabaseUserError(kind: .readOnly, message: "PostgreSQL did not enable read-only transactions.")
            }
        } catch {
            await close()
            throw Self.mapError(error)
        }
    }

    public func close() async {
        clientRunTask?.cancel()
        if let clientRunTask {
            await clientRunTask.value
        }
        clientRunTask = nil
        client = nil
    }

    public func listTables() async throws -> [TableSummary] {
        try await loadCatalogSnapshot().descriptors.map(\.summary)
    }

    public func loadSchemaGraph() async throws -> SchemaGraph {
        try await loadCatalogSnapshot().graph
    }

    public func loadCatalogSnapshot() async throws -> CatalogSnapshot {
        do {
            return try await withReadOnlyTransaction { connection in
                let objects = try await Self.query(
                    PostgresQuery(unsafeSQL: """
                    SELECT n.nspname AS schema_name,
                           c.relname AS object_name,
                           c.relkind::text AS relkind,
                           c.reltuples::float8 AS row_estimate,
                           (c.relkind = 'r' AND EXISTS (SELECT 1 FROM pg_catalog.pg_inherits i WHERE i.inhparent = c.oid)) AS has_inheritance_children
                    FROM pg_catalog.pg_class AS c
                    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
                    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
                      AND n.nspname !~ '^pg_temp_'
                      AND c.relkind IN ('r', 'p', 'v', 'm')
                      AND has_schema_privilege(n.oid, 'USAGE')
                      AND has_table_privilege(c.oid, 'SELECT')
                    ORDER BY n.nspname, c.relname
                    """),
                    on: connection
                )
                let columns = try await Self.query(
                    PostgresQuery(unsafeSQL: """
                    SELECT n.nspname AS schema_name,
                           c.relname AS object_name,
                           a.attname AS column_name,
                           pg_catalog.format_type(a.atttypid, a.atttypmod) AS declared_type,
                           a.attnotnull AS not_null,
                           pg_catalog.pg_get_expr(ad.adbin, ad.adrelid) AS default_sql,
                           a.attnum AS ordinal,
                           a.attgenerated::text AS generated_kind,
                           a.attidentity::text AS identity_kind
                    FROM pg_catalog.pg_attribute AS a
                    JOIN pg_catalog.pg_class AS c ON c.oid = a.attrelid
                    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
                    LEFT JOIN pg_catalog.pg_attrdef AS ad
                      ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
                    WHERE a.attnum > 0
                      AND NOT a.attisdropped
                      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
                      AND n.nspname !~ '^pg_temp_'
                      AND c.relkind IN ('r', 'p', 'v', 'm')
                      AND has_table_privilege(c.oid, 'SELECT')
                    ORDER BY n.nspname, c.relname, a.attnum
                    """),
                    on: connection
                )
                let indexes = try await Self.query(
                    PostgresQuery(unsafeSQL: """
                    SELECT n.nspname AS schema_name,
                           c.relname AS object_name,
                           index_class.relname AS index_name,
                           ix.indisunique AS is_unique,
                           ix.indisprimary AS is_primary,
                           (ix.indpred IS NOT NULL) AS is_partial,
                           COALESCE((
                               SELECT pg_catalog.json_agg(COALESCE(att.attname, '') ORDER BY keys.ord)::text
                               FROM unnest(ix.indkey) WITH ORDINALITY AS keys(attnum, ord)
                               LEFT JOIN pg_catalog.pg_attribute AS att
                                 ON att.attrelid = ix.indrelid AND att.attnum = keys.attnum
                               WHERE keys.ord <= ix.indnkeyatts
                           ), '[]') AS columns_json
                    FROM pg_catalog.pg_index AS ix
                    JOIN pg_catalog.pg_class AS c ON c.oid = ix.indrelid
                    JOIN pg_catalog.pg_class AS index_class ON index_class.oid = ix.indexrelid
                    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
                    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
                      AND n.nspname !~ '^pg_temp_'
                      AND c.relkind IN ('r', 'p', 'v', 'm')
                      AND ix.indisvalid AND ix.indisready
                      AND has_table_privilege(c.oid, 'SELECT')
                    ORDER BY n.nspname, c.relname, index_class.relname
                    """),
                    on: connection
                )
                let foreignKeys = try await Self.query(
                    PostgresQuery(unsafeSQL: """
                    SELECT con.oid::text AS constraint_id,
                           con.conname AS constraint_name,
                           src_ns.nspname AS source_schema_name,
                           src.relname AS source_object_name,
                           tgt_ns.nspname AS target_schema_name,
                           tgt.relname AS target_object_name,
                           COALESCE((
                               SELECT pg_catalog.json_agg(src_att.attname ORDER BY keys.ord)::text
                               FROM unnest(con.conkey, con.confkey) WITH ORDINALITY AS keys(source_num, target_num, ord)
                               JOIN pg_catalog.pg_attribute AS src_att
                                 ON src_att.attrelid = con.conrelid AND src_att.attnum = keys.source_num
                           ), '[]') AS source_columns_json,
                           COALESCE((
                               SELECT pg_catalog.json_agg(tgt_att.attname ORDER BY keys.ord)::text
                               FROM unnest(con.conkey, con.confkey) WITH ORDINALITY AS keys(source_num, target_num, ord)
                               JOIN pg_catalog.pg_attribute AS tgt_att
                                 ON tgt_att.attrelid = con.confrelid AND tgt_att.attnum = keys.target_num
                           ), '[]') AS target_columns_json
                    FROM pg_catalog.pg_constraint AS con
                    JOIN pg_catalog.pg_class AS src ON src.oid = con.conrelid
                    JOIN pg_catalog.pg_namespace AS src_ns ON src_ns.oid = src.relnamespace
                    JOIN pg_catalog.pg_class AS tgt ON tgt.oid = con.confrelid
                    JOIN pg_catalog.pg_namespace AS tgt_ns ON tgt_ns.oid = tgt.relnamespace
                    WHERE con.contype = 'f'
                      AND src_ns.nspname NOT IN ('pg_catalog', 'information_schema')
                      AND src_ns.nspname !~ '^pg_temp_'
                      AND has_table_privilege(src.oid, 'SELECT')
                    ORDER BY src_ns.nspname, src.relname, con.conname
                    """),
                    on: connection
                )
                let triggers = try await Self.query(
                    PostgresQuery(unsafeSQL: """
                    SELECT n.nspname AS schema_name,
                           c.relname AS object_name,
                           t.tgname AS trigger_name,
                           pg_catalog.pg_get_triggerdef(t.oid, false) AS trigger_sql
                    FROM pg_catalog.pg_trigger AS t
                    JOIN pg_catalog.pg_class AS c ON c.oid = t.tgrelid
                    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
                    WHERE NOT t.tgisinternal
                      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
                      AND n.nspname !~ '^pg_temp_'
                      AND c.relkind IN ('r', 'p', 'v', 'm')
                      AND has_schema_privilege(n.oid, 'USAGE')
                      AND has_table_privilege(c.oid, 'SELECT')
                    ORDER BY n.nspname, c.relname, t.tgname
                    """),
                    on: connection
                )
                let checkConstraints = try await Self.query(
                    PostgresQuery(unsafeSQL: """
                    SELECT con.oid::text AS constraint_id,
                           n.nspname AS schema_name,
                           c.relname AS object_name,
                           con.conname AS constraint_name,
                           pg_catalog.pg_get_constraintdef(con.oid, false) AS constraint_sql,
                           COALESCE((
                               SELECT pg_catalog.json_agg(att.attname ORDER BY keys.ord)::text
                               FROM unnest(con.conkey) WITH ORDINALITY AS keys(attnum, ord)
                               JOIN pg_catalog.pg_attribute AS att
                                 ON att.attrelid = con.conrelid AND att.attnum = keys.attnum
                           ), '[]') AS columns_json
                    FROM pg_catalog.pg_constraint AS con
                    JOIN pg_catalog.pg_class AS c ON c.oid = con.conrelid
                    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
                    WHERE con.contype = 'c'
                      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
                      AND n.nspname !~ '^pg_temp_'
                      AND c.relkind IN ('r', 'p', 'v', 'm')
                      AND has_schema_privilege(n.oid, 'USAGE')
                      AND has_table_privilege(c.oid, 'SELECT')
                    ORDER BY n.nspname, c.relname, con.conname
                    """),
                    on: connection
                )

                return PostgresCatalogMapper.makeSnapshot(
                    objects: Self.objects(from: objects),
                    columns: Self.columns(from: columns),
                    indexes: Self.indexes(from: indexes),
                    foreignKeys: Self.foreignKeys(from: foreignKeys),
                    triggers: Self.triggers(from: triggers),
                    checkConstraints: Self.checkConstraints(from: checkConstraints)
                )
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    public func fetchDescriptor(named tableName: String) async throws -> TableDescriptor {
        let snapshot = try await loadCatalogSnapshot()
        guard let descriptor = snapshot.descriptors.first(where: { $0.name == tableName || $0.objectName == tableName }) else {
            throw DatabaseUserError(kind: .notFound, message: "Table \(tableName) was not found.")
        }
        return descriptor
    }

    public func fetchChunk(query: TableQueryState, descriptor: TableDescriptor) async throws -> TableChunk {
        guard query.limit >= 0, query.offset >= 0, query.offset <= Int.max - 10_001 else { throw DatabaseUserError(kind: .invalidInput, message: "Invalid page bounds.") }
        var page = query
        page.limit = min(query.limit, 10_000) + 1
        let plan = try PostgresTableQueryBuilder.makePlan(query: page, descriptor: descriptor)
        do {
            return try await withReadOnlyTransaction { connection in
                var exactCount = query.cachedExactCount
                if query.requestExactCount {
                    let count = try await Self.query(PostgresQuery(unsafeSQL: plan.countSQL, binds: try Self.bindings(Array(plan.countParameters))), on: connection)
                    exactCount = count.rows.first?.first.flatMap(Self.integerValue)
                }
                let rows = try await Self.query(
                    PostgresQuery(
                        unsafeSQL: plan.selectSQL,
                        binds: try Self.bindings(plan.parameters)
                    ),
                    on: connection
                )
                let limit = min(query.limit, 10_000)
                let countState = TableCountState.forPage(query: query, rowCount: min(rows.rows.count, limit), hasMore: rows.rows.count > limit, exactCount: exactCount)
                let tableRows = rows.rows.prefix(limit).map { values in
                    let identityValues = descriptor.primaryKeyColumns.compactMap { columnName -> IdentityComponent? in
                        guard let index = descriptor.columns.firstIndex(where: { $0.name == columnName }), values.indices.contains(index) else {
                            return nil
                        }
                        return IdentityComponent(columnName: columnName, value: values[index])
                    }
                    let identity = TableRowIdentity.primaryKey(
                        identityValues.isEmpty
                            ? descriptor.fallbackSortColumns.enumerated().compactMap { _, columnName in
                                guard let index = descriptor.columns.firstIndex(where: { $0.name == columnName }), values.indices.contains(index) else { return nil }
                                return IdentityComponent(columnName: columnName, value: values[index])
                            }
                            : identityValues
                    )
                    return TableRow(identity: identity, values: values)
                }
                return TableChunk(rows: tableRows, totalRowCount: max(countState.navigationCount, query.offset + min(rows.rows.count, limit) + (rows.rows.count > limit ? 1 : 0)), offset: query.offset, limit: limit, countState: countState, hasMore: rows.rows.count > limit)
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    public func fetchRecords(descriptor: TableDescriptor, predicates: [IdentityComponent], offset: Int = 0, limit: Int = 50) async throws -> RecordPage {
        let plan = try RecordAccess.plan(descriptor: descriptor, predicates: predicates, offset: offset, limit: limit, postgres: true)
        return try await executeRecordPlan(plan)
    }

    public func fetchRelated(record: RecordSnapshot, relationship: RecordRelationship, direction: RecordDirection, offset: Int = 0, limit: Int = 50) async throws -> RecordPage {
        do {
            guard let plan = try RecordAccess.relatedPlan(record: record, relationship: relationship, direction: direction, offset: offset, limit: limit, postgres: true) else { return .empty(.nullReference) }
            return try await executeRecordPlan(plan, missingReference: direction == .outgoing)
        } catch RecordAccessError.unavailableTable {
            return .empty(.unavailable)
        }
    }

    private func executeRecordPlan(_ plan: RecordQueryPlan, missingReference: Bool = false) async throws -> RecordPage {
        try Task.checkCancellation()
        do {
            return try await withReadOnlyTransaction { connection in
                _ = try await Self.query(Self.command("SET LOCAL statement_timeout = '5000ms'"), on: connection)
                var binds = PostgresBindings(capacity: plan.parameters.count)
                for value in plan.parameters {
                    // Text on the wire plus a validated target-type cast preserves
                    // UUID, exact numerics, arrays and bytea without interpolation.
                    switch value {
                    case .null: binds.appendNull()
                    case .blob(let data): binds.append("\\x" + data.map { String(format: "%02x", $0) }.joined())
                    default: binds.append(value.editorText)
                    }
                }
                let result = try await Self.query(PostgresQuery(unsafeSQL: plan.sql, binds: binds), on: connection, rowLimit: plan.limit + 1)
                try Task.checkCancellation()
                return try RecordAccess.page(values: result.rows, plan: plan, missingReference: missingReference)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapError(error)
        }
    }

    public func executeReadOnlyQuery(sql: String, rowLimit: Int = 500, timeoutSeconds: TimeInterval = 30) async throws -> QueryResult {
        _ = try ReadOnlySQLPolicy.validate(sql)
        let boundedLimit = min(max(rowLimit, 1), 10_000)
        do {
            let root = try ReadOnlySQLPolicy.statementRoot(sql)
            let isUtilityResponse = root == "SHOW" || root == "EXPLAIN"
            let rawResult = try await withReadOnlyTransaction(
                timeoutSeconds: timeoutSeconds,
                discardConnectionAfterBody: isUtilityResponse
            ) { connection in
                if isUtilityResponse {
                    return try await Self.query(PostgresQuery(unsafeSQL: sql), on: connection, rowLimit: boundedLimit)
                }
                // PostgreSQL parses the original statement as a cursor query.
                // FETCH bounds server execution and transfer without rewriting SQL.
                try await Self.drain(Self.command("DECLARE sgs_query_cursor NO SCROLL CURSOR FOR \(sql)"), on: connection, logger: Logger(label: "SQLiteGraphStudio.PostgreSQL"))
                let fetched = try await Self.query(Self.command("FETCH FORWARD \(boundedLimit + 1) FROM sgs_query_cursor"), on: connection)
                return RawPostgresResult(columns: fetched.columns, rows: fetched.rows, isTruncated: fetched.rows.count > boundedLimit)
            }
            let rows = rawResult.rows.prefix(boundedLimit).enumerated().map { index, values in
                QueryResultRow(id: index, values: values)
            }
            return QueryResult(
                columns: rawResult.columns,
                rows: Array(rows),
                isTruncated: rawResult.isTruncated,
                rowLimit: boundedLimit
            )
        } catch {
            if error is CancellationError { throw error }
            throw Self.mapError(error)
        }
    }

    public func explainQueryPlan(sql: String, timeoutSeconds: TimeInterval = 30) async throws -> [ExplainPlanRow] {
        _ = try ReadOnlySQLPolicy.validate(sql)
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let explainSQL = try ReadOnlySQLPolicy.statementRoot(trimmed) == "EXPLAIN"
            ? trimmed
            : "EXPLAIN (FORMAT TEXT) \(trimmed)"
        let result = try await executeReadOnlyQuery(sql: explainSQL, rowLimit: 500, timeoutSeconds: timeoutSeconds)
        return result.rows.enumerated().map { index, row in
            ExplainPlanRow(
                id: index,
                parent: 0,
                notUsed: 0,
                detail: row.values.first?.displayText ?? ""
            )
        }
    }

    public func commitEdit(_ change: CellEditChange) async throws {
        throw readOnlyMutationError("Values cannot be edited on PostgreSQL connections.")
    }

    public func insertDefaultRow(into descriptor: TableDescriptor) async throws {
        throw readOnlyMutationError("Rows cannot be added on PostgreSQL connections.")
    }

    public func insertClonedRow(from sourceRow: TableRow, into descriptor: TableDescriptor) async throws {
        throw readOnlyMutationError("Rows cannot be cloned on PostgreSQL connections.")
    }

    public func deleteRow(_ identity: TableRowIdentity, from descriptor: TableDescriptor) async throws {
        throw readOnlyMutationError("Rows cannot be deleted on PostgreSQL connections.")
    }

    public func dropColumn(columnName: String, from descriptor: TableDescriptor) async throws {
        throw readOnlyMutationError("Columns cannot be dropped on PostgreSQL connections.")
    }

    public func createTable(_ draft: TableCreateDraft) async throws {
        throw readOnlyMutationError("Tables cannot be created on PostgreSQL connections.")
    }

    public func renameTable(from currentName: String, to newName: String) async throws {
        throw readOnlyMutationError("Tables cannot be renamed on PostgreSQL connections.")
    }

    public func addColumn(_ draft: TableColumnDraft, to descriptor: TableDescriptor) async throws {
        throw readOnlyMutationError("Columns cannot be added on PostgreSQL connections.")
    }

    public func renameColumn(from currentName: String, to newName: String, in descriptor: TableDescriptor) async throws {
        throw readOnlyMutationError("Columns cannot be renamed on PostgreSQL connections.")
    }

    public func serializeQueryResult(_ result: QueryResult, format: DataTransferFormat) async throws -> String {
        try ResultSerialization.serializeQueryResult(result, format: format)
    }

    public func serializeTableRows(descriptor: TableDescriptor, rows: [TableRow], format: DataTransferFormat) async throws -> String {
        try ResultSerialization.serializeTableRows(descriptor: descriptor, rows: rows, format: format)
    }

    public func importRows(into descriptor: TableDescriptor, text: String, format: DataTransferFormat) async throws -> ImportRowsResult {
        throw readOnlyMutationError("Rows cannot be imported into PostgreSQL connections.")
    }

    private func readOnlyMutationError(_ message: String) -> DatabaseUserError {
        DatabaseUserError(kind: .readOnly, message: message)
    }

    func withReadOnlyTransaction<T: Sendable>(
        timeoutSeconds: TimeInterval = 30,
        discardConnectionAfterBody: Bool = false,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> T
    ) async throws -> T {
        guard let client else {
            throw DatabaseUserError(kind: .generic, message: "No PostgreSQL connection is open.")
        }
        return try await withQueryTimeout(seconds: timeoutSeconds) {
            try await client.withConnection { connection in
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    let logger = Logger(label: "SQLiteGraphStudio.PostgreSQL")
                    do {
                        try await Self.drain(Self.command("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY"), on: connection, logger: logger)
                        let milliseconds = max(1, Int(timeoutSeconds * 1_000))
                        try await Self.drain(Self.command("SET LOCAL statement_timeout = \(milliseconds)"), on: connection, logger: logger)
                        // Detect a cancelled client's closed socket during server work.
                        try await Self.drain(Self.command("SET LOCAL client_connection_check_interval = '100ms'"), on: connection, logger: logger)
                        // This constant metadata read is transaction setup; record
                        // graph budgets count bounded data fetches, not setup commands.
                        let moneyScale = try await Self.moneyScale(on: connection)
                        let value = try await PostgresValueMapper.$moneyFractionDigits.withValue(moneyScale) {
                            try await body(connection)
                        }
                        try Task.checkCancellation()
                        if discardConnectionAfterBody {
                            // Utility statements cannot use a SQL cursor. Their
                            // capped reader may already have closed this lease.
                            // Discard it without issuing COMMIT on a closed channel.
                            try await connection.close()
                        } else {
                            try await Self.drain(Self.command("COMMIT"), on: connection, logger: logger)
                        }
                        return value
                    } catch {
                        // Querying an already closed channel can leave the driver's
                        // response promise unresolved. Cancellation discards the
                        // connection, so there is no transaction left to roll back.
                        try Task.checkCancellation()
                        if !connection.isClosed {
                            _ = try? await Self.drain(Self.command("ROLLBACK"), on: connection, logger: logger)
                        }
                        throw error
                    }
                } onCancel: {
                    // Discard only this lease. The pool creates a fresh physical
                    // connection, preserving backend usability after Stop/timeout.
                    let _: Void = connection.close()
                }
            }
        }
    }

    private static func moneyScale(on connection: PostgresConnection) async throws -> Int {
        let result = try await Self.query(Self.command("SELECT pg_catalog.cash_send(1::numeric::money)"), on: connection)
        guard case .blob(let bytes) = result.rows.first?.first, bytes.count == 8 else {
            throw DatabaseUserError(kind: .generic, message: "PostgreSQL did not return its money precision.")
        }
        var units = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var scale = 0
        while units > 1, units % 10 == 0, scale < 10 { units /= 10; scale += 1 }
        guard units == 1 else {
            throw DatabaseUserError(kind: .generic, message: "PostgreSQL returned an unsupported money precision.")
        }
        return scale
    }

    private static func command(_ sql: String) -> PostgresQuery {
        PostgresQuery(unsafeSQL: sql)
    }

    private static func drain(_ request: PostgresQuery, on connection: PostgresConnection, logger: Logger) async throws {
        _ = try await PostgresDatabaseBackend.query(request, on: connection, logger: logger).rows
    }

    private static func query(
        _ query: PostgresQuery,
        on connection: PostgresConnection,
        logger: Logger = Logger(label: "SQLiteGraphStudio.PostgreSQL"),
        rowLimit: Int? = nil
    ) async throws -> RawPostgresResult {
        let sequence = try await connection.query(query, logger: logger)
        let columns = sequence.columns.map {
            QueryResultColumn(name: $0.name, typeLabel: $0.dataType.knownSQLName ?? "OID \($0.dataType.rawValue)")
        }
        var rows: [[PostgresValue]] = []
        var isTruncated = false
        for try await row in sequence {
            if let rowLimit, rows.count >= rowLimit {
                isTruncated = true
                // Dropping the sequence alone can still drain server output.
                // Close the utility lease at the sentinel row to stop receiving.
                try await connection.close()
                break
            }
            let random = row.makeRandomAccess()
            rows.append((0..<random.count).map { PostgresValueMapper.map(random[data: $0]) })
        }
        return RawPostgresResult(columns: columns, rows: rows, isTruncated: isTruncated)
    }

    static func bindings(_ parameters: [PostgresQueryParameter]) throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: parameters.count)
        for parameter in parameters {
            switch parameter {
            case .null:
                bindings.appendNull()
            case .text(let value):
                bindings.append(value)
            case .integer(let value):
                bindings.append(value)
            case .double(let value):
                bindings.append(value)
            case .boolean(let value):
                bindings.append(value)
            case .bytes(let value):
                try bindings.append(value)
            }
        }
        return bindings
    }

    private static func integerValue(_ value: PostgresValue) -> Int? {
        if case .integer(let integer) = value { return Int(integer) }
        if case .exactNumeric(let numeric) = value { return Int(numeric) }
        if case .text(let text) = value { return Int(text) }
        return nil
    }

    private static func objects(from result: RawPostgresResult) -> [PostgresCatalogObject] {
        result.rows.compactMap { row in
            guard let schema = result.text("schema_name", row: row),
                  let object = result.text("object_name", row: row),
                  let relkind = result.text("relkind", row: row)
            else { return nil }
            return PostgresCatalogObject(
                schemaName: schema,
                objectName: object,
                relkind: relkind,
                rowEstimate: result.double("row_estimate", row: row),
                hasInheritanceChildren: result.bool("has_inheritance_children", row: row)
            )
        }
    }

    private static func columns(from result: RawPostgresResult) -> [PostgresCatalogColumn] {
        result.rows.compactMap { row in
            guard let schema = result.text("schema_name", row: row),
                  let object = result.text("object_name", row: row),
                  let name = result.text("column_name", row: row),
                  let declaredType = result.text("declared_type", row: row)
            else { return nil }
            return PostgresCatalogColumn(
                schemaName: schema,
                objectName: object,
                name: name,
                declaredType: declaredType,
                notNull: result.bool("not_null", row: row),
                defaultValueSQL: result.optionalText("default_sql", row: row),
                ordinal: result.int("ordinal", row: row),
                generatedKind: result.text("generated_kind", row: row) ?? "",
                identityKind: result.text("identity_kind", row: row) ?? ""
            )
        }
    }

    private static func indexes(from result: RawPostgresResult) -> [PostgresCatalogIndex] {
        result.rows.compactMap { row in
            guard let schema = result.text("schema_name", row: row),
                  let object = result.text("object_name", row: row),
                  let name = result.text("index_name", row: row)
            else { return nil }
            return PostgresCatalogIndex(
                schemaName: schema,
                objectName: object,
                name: name,
                columns: result.jsonStrings("columns_json", row: row),
                isUnique: result.bool("is_unique", row: row),
                isPrimary: result.bool("is_primary", row: row),
                isPartial: result.bool("is_partial", row: row)
            )
        }
    }

    private static func foreignKeys(from result: RawPostgresResult) -> [PostgresCatalogForeignKey] {
        result.rows.compactMap { row in
            guard let id = result.text("constraint_id", row: row),
                  let name = result.text("constraint_name", row: row),
                  let sourceSchema = result.text("source_schema_name", row: row),
                  let sourceObject = result.text("source_object_name", row: row),
                  let targetSchema = result.text("target_schema_name", row: row),
                  let targetObject = result.text("target_object_name", row: row)
            else { return nil }
            return PostgresCatalogForeignKey(
                id: id,
                constraintName: name,
                sourceSchemaName: sourceSchema,
                sourceObjectName: sourceObject,
                sourceColumns: result.jsonStrings("source_columns_json", row: row),
                targetSchemaName: targetSchema,
                targetObjectName: targetObject,
                targetColumns: result.jsonStrings("target_columns_json", row: row)
            )
        }
    }

    private static func triggers(from result: RawPostgresResult) -> [PostgresCatalogTrigger] {
        result.rows.compactMap { row in
            guard let schema = result.text("schema_name", row: row),
                  let object = result.text("object_name", row: row),
                  let name = result.text("trigger_name", row: row),
                  let sql = result.text("trigger_sql", row: row)
            else { return nil }
            return PostgresCatalogTrigger(schemaName: schema, objectName: object, name: name, sql: sql)
        }
    }

    private static func checkConstraints(from result: RawPostgresResult) -> [PostgresCatalogCheckConstraint] {
        result.rows.compactMap { row in
            guard let id = result.text("constraint_id", row: row),
                  let schema = result.text("schema_name", row: row),
                  let object = result.text("object_name", row: row),
                  let name = result.text("constraint_name", row: row),
                  let sql = result.text("constraint_sql", row: row)
            else { return nil }
            return PostgresCatalogCheckConstraint(
                id: id,
                schemaName: schema,
                objectName: object,
                name: name,
                columns: result.jsonStrings("columns_json", row: row),
                sql: sql
            )
        }
    }

    private static func mapError(_ error: any Error) -> DatabaseUserError {
        if let error = error as? DatabaseUserError {
            return error
        }
        if let error = error as? PSQLError {
            if let serverInfo = error.serverInfo {
                let state = serverInfo[.sqlState] ?? ""
                let message = serverInfo[.message] ?? "PostgreSQL request failed."
                let kind: DatabaseUserError.Kind
                if state.hasPrefix("28") {
                    kind = .authentication
                } else if state == "42501" {
                    kind = .permission
                } else if state == "57014" {
                    kind = .timeout
                } else if state.hasPrefix("42") {
                    kind = .syntax
                } else {
                    kind = .generic
                }
                return DatabaseUserError(kind: kind, message: message)
            }
            switch error.code {
            case .authMechanismRequiresPassword, .unsupportedAuthMechanism, .saslError:
                return DatabaseUserError(kind: .authentication, message: "PostgreSQL authentication failed.")
            case .connectionError, .serverClosedConnection, .clientClosedConnection, .uncleanShutdown:
                return DatabaseUserError(kind: .network, message: "The PostgreSQL connection closed unexpectedly.")
            default:
                return DatabaseUserError(kind: .generic, message: "The PostgreSQL request failed.")
            }
        }
        return DatabaseUserError(kind: .network, message: "The PostgreSQL connection could not be established.")
    }
}

private struct RawPostgresResult: Sendable {
    let columns: [QueryResultColumn]
    let rows: [[PostgresValue]]
    let isTruncated: Bool

    func index(of name: String) -> Int? {
        columns.firstIndex { $0.name == name }
    }

    func value(_ name: String, row: [PostgresValue]) -> PostgresValue? {
        guard let index = index(of: name), row.indices.contains(index) else { return nil }
        return row[index]
    }

    func text(_ name: String, row: [PostgresValue]) -> String? {
        switch value(name, row: row) {
        case .text(let value), .uuid(let value), .dateTime(let value), .json(let value), .array(let value), .exactNumeric(let value):
            return value
        case .integer(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .boolean(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    func optionalText(_ name: String, row: [PostgresValue]) -> String? {
        guard let value = value(name, row: row), value != .null else { return nil }
        return text(name, row: row)
    }

    func int(_ name: String, row: [PostgresValue]) -> Int {
        guard let text = text(name, row: row) else { return 0 }
        return Int(text) ?? 0
    }

    func double(_ name: String, row: [PostgresValue]) -> Double? {
        guard let text = text(name, row: row) else { return nil }
        return Double(text)
    }

    func bool(_ name: String, row: [PostgresValue]) -> Bool {
        switch value(name, row: row) {
        case .boolean(let value): return value
        case .integer(let value): return value != 0
        case .text(let value): return value == "t" || value.caseInsensitiveCompare("true") == .orderedSame
        default: return false
        }
    }

    func jsonStrings(_ name: String, row: [PostgresValue]) -> [String] {
        guard let text = text(name, row: row),
              let data = text.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return values
    }
}

private extension PostgresDatabaseBackend {
    static func query(_ query: PostgresQuery, on connection: PostgresConnection) async throws -> RawPostgresResult {
        try await self.query(query, on: connection, logger: Logger(label: "SQLiteGraphStudio.PostgreSQL"), rowLimit: nil)
    }
}

/// Uses credentials configured outside the app. A PostgreSQL document never
/// contains a password and Graph Studio never presents a login form. The
/// environment and standard pgpass file are intentionally read without ever
/// writing or logging their contents.
private enum PostgresExternalCredential {
    static func password(for configuration: PostgresConnectionConfiguration) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let password = environment["PGPASSWORD"], !password.isEmpty {
            return password
        }

        let fileURL: URL
        if let path = environment["PGPASSFILE"], !path.isEmpty {
            fileURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        } else {
            fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pgpass")
        }

        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        for line in contents.split(whereSeparator: { $0.isNewline }) {
            let text = String(line)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty,
                  !text.trimmingCharacters(in: .whitespaces).hasPrefix("#")
            else { continue }
            let fields = split(text)
            guard fields.count == 5 else { continue }
            guard matches(fields[0], configuration.host),
                  matches(fields[1], String(configuration.port)),
                  matches(fields[2], configuration.database),
                  matches(fields[3], configuration.username)
            else { continue }
            return fields[4]
        }
        return nil
    }

    private static func split(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var escaped = false
        for character in line {
            if escaped {
                field.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == ":" {
                fields.append(field)
                field = ""
            } else {
                field.append(character)
            }
        }
        if escaped { field.append("\\") }
        fields.append(field)
        return fields
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        pattern == "*" || pattern.caseInsensitiveCompare(value) == .orderedSame
    }
}
