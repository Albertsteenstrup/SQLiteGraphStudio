import Foundation
import Darwin

/// Shared by the picker, Finder/CLI launch handling and recent documents.
public enum DatabaseDocument {
    public static let sqliteExtensions: Set<String> = ["sqlite", "sqlite3", "db", "sqlite-db", "sqlitedb"]
    public static let archiveExtensions: Set<String> = ["dump", "backup"]
    public static let otherExtensions = archiveExtensions.union(PostgresConnectionDocument.supportedFileExtensions)
    public static let supportedExtensions = sqliteExtensions.union(otherExtensions)
    public static let otherFormatsDescription = "PostgreSQL backups (.dump, .backup) and connection documents (.postgres, .pgstudio)"

    public static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased())
    }

    static func openArchive(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            try? file.close()
            throw DatabaseUserError(kind: .invalidInput, message: "Choose a regular PostgreSQL archive file.")
        }
        do {
            let header = try file.read(upToCount: 32) ?? Data()
            guard header.count == 32, header.prefix(5) == Data("PGDMP".utf8) else {
                throw DatabaseUserError(kind: .invalidInput,
                    message: "This file is not a complete PostgreSQL custom-format archive.",
                    recoverySuggestion: "Choose a .dump or .backup made with pg_dump's custom format. SQL scripts and directory backups are not supported.")
            }
            try file.seek(toOffset: 0)
            return file
        } catch {
            try? file.close()
            throw error
        }
    }
}
