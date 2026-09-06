import Foundation

/// Deliberately narrow proof: exact SELECT * from one catalog object, optionally bounded.
/// This is never applied to mutable editor text; callers must supply the SQL that produced the result.
public enum RecordQueryOrigin {
    public static func descriptor(executedSQL: String?, result: QueryResult, catalog: CatalogSnapshot) -> TableDescriptor? {
        guard let executedSQL else { return nil }
        let matches = catalog.descriptors.filter { descriptor in
            guard result.columns.map(\.name) == descriptor.columns.map(\.name) else { return false }
            var identifiers = [descriptor.qualifiedSQLIdentifier]
            let names = [descriptor.schemaName, descriptor.objectName].compactMap { $0 }
            if names.allSatisfy({ $0.range(of: #"^[a-z_][a-z0-9_]*$"#, options: .regularExpression) != nil }) {
                identifiers.append(names.joined(separator: "."))
            }
            if descriptor.schemaName != nil {
                let directIdentifiers = identifiers.map { "(?i:ONLY)\\s+" + NSRegularExpression.escapedPattern(for: $0) }
                if directIdentifiers.contains(where: { source in
                    executedSQL.range(of: #"^\s*(?i:SELECT)\s+\*\s+(?i:FROM)\s+"# + source + #"(?:\s+(?i:LIMIT)\s+[0-9]+)?\s*;?\s*$"#, options: .regularExpression) != nil
                }) { return true }
            }
            guard !descriptor.hasInheritanceChildren else { return false }
            return identifiers.contains { identifier in
                let pattern = #"^\s*(?i:SELECT)\s+\*\s+(?i:FROM)\s+"# + NSRegularExpression.escapedPattern(for: identifier) + #"(?:\s+(?i:LIMIT)\s+[0-9]+)?\s*;?\s*$"#
                return executedSQL.range(of: pattern, options: .regularExpression) != nil
            }
        }
        return matches.count == 1 ? matches.first : nil
    }
}
