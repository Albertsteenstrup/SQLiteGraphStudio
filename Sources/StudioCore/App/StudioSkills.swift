import CryptoKit
import Foundation

// MARK: - StudioSkill

public struct StudioSkill: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let shortDescription: String
    public let fullContent: String
}

public struct StudioSkillInstallationTarget: Identifiable, Sendable, Hashable {
    public let subpath: String
    public let guardDirectory: String

    public var id: String { subpath }
}

public struct StudioSkillDirectoryTarget: Identifiable, Sendable, Hashable {
    public let subpath: String
    public let label: String

    public var id: String { subpath }
}

public enum StudioSkillInstallationError: LocalizedError {
    case customizedSkill(URL)

    public var errorDescription: String? {
        switch self {
        case .customizedSkill(let url):
            "The existing skill has local changes and was left untouched: \(url.path)"
        }
    }
}

// MARK: - StudioSkills namespace

public enum StudioSkills {

    public static let all: [StudioSkill] = [graphClusters, schemaDescriptions, databaseExplore, databaseDiff, databasePreview]

    // MARK: Skills

    public static let graphClusters = StudioSkill(
        id: "graph-clusters",
        title: "graph-clusters",
        shortDescription: "Groups your tables into meaningful clusters. Defaults to domain areas, but can use a lens like people, artifacts, departments, workflows, or ownership. Run from your AI coding agent.",
        fullContent: graphClustersContent
    )

    public static let schemaDescriptions = StudioSkill(
        id: "schema-descriptions",
        title: "schema-descriptions",
        shortDescription: "Annotates tables and columns with hover descriptions shown in the graph, table grids, and query results.",
        fullContent: schemaDescriptionsContent
    )

    public static let databaseExplore = StudioSkill(
        id: "database-explore",
        title: "database-explore",
        shortDescription: "Investigates the data model and shows useful live explanations through Graph Studio MCP, without a fixed story format.",
        fullContent: databaseExploreContent
    )

    public static let databaseDiff = StudioSkill(
        id: "database-diff", title: "database-diff",
        shortDescription: "Compares SQLite and PostgreSQL schema versions for PRs and local integrations, highlighting table, field, and relation changes.",
        fullContent: databaseDiffContent
    )

    public static let databasePreview = StudioSkill(
        id: "database-preview", title: "database-preview",
        shortDescription: "Previews proposed schema changes from a small plan and cached metadata, without running migrations.",
        fullContent: databasePreviewContent
    )

    // MARK: Installation targets

    public static let targetDirectories: [StudioSkillDirectoryTarget] = [
        StudioSkillDirectoryTarget(subpath: ".agents/skills", label: "Codex (.agents/skills)"),
        StudioSkillDirectoryTarget(subpath: ".claude/skills", label: "Claude (.claude/skills)"),
        StudioSkillDirectoryTarget(subpath: ".cursor/rules", label: "Cursor (.cursor/rules)"),
        StudioSkillDirectoryTarget(subpath: ".github/instructions", label: "GitHub Copilot (.github/instructions)"),
        StudioSkillDirectoryTarget(subpath: ".windsurf/rules", label: "Windsurf (.windsurf/rules)"),
        StudioSkillDirectoryTarget(subpath: ".gemini", label: "Gemini (.gemini)"),
    ]

    /// The default install path only writes into directories that already exist.
    /// New targets are created through the explicit target-directory install path.
    public static func installationTargets(for skill: StudioSkill) -> [StudioSkillInstallationTarget] {
        [
            StudioSkillInstallationTarget(
                subpath: ".agents/skills/\(skill.id)/SKILL.md",
                guardDirectory: ".agents/skills"
            ),
            StudioSkillInstallationTarget(
                subpath: ".claude/skills/\(skill.id)/SKILL.md",
                guardDirectory: ".claude/skills"
            ),
            StudioSkillInstallationTarget(
                subpath: ".cursor/rules/\(skill.id).md",
                guardDirectory: ".cursor/rules"
            ),
            StudioSkillInstallationTarget(
                subpath: ".github/instructions/\(skill.id).instructions.md",
                guardDirectory: ".github/instructions"
            ),
            StudioSkillInstallationTarget(
                subpath: ".windsurf/rules/\(skill.id).md",
                guardDirectory: ".windsurf/rules"
            ),
            StudioSkillInstallationTarget(
                subpath: ".gemini/\(skill.id).md",
                guardDirectory: ".gemini"
            ),
        ]
    }

    // MARK: Install

    public static func install(_ skills: [StudioSkill], to directory: URL) throws {
        let fm = FileManager.default
        var files: [(StudioSkill, URL)] = []
        for skill in skills {
            for target in installationTargets(for: skill) {
                let guardURL = directory.appendingPathComponent(target.guardDirectory)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: guardURL.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                files.append((skill, directory.appendingPathComponent(target.subpath)))
            }
        }
        try installFiles(files, in: directory, retiringLegacyIn: nil)
    }

    public static func install(
        _ skills: [StudioSkill],
        to directory: URL,
        targetDirectory: StudioSkillDirectoryTarget
    ) throws {
        let fm = FileManager.default
        let guardURL = directory.appendingPathComponent(targetDirectory.subpath)
        try fm.createDirectory(at: guardURL, withIntermediateDirectories: true)

        var files: [(StudioSkill, URL)] = []
        for skill in skills {
            for target in installationTargets(for: skill) where target.guardDirectory == targetDirectory.subpath {
                files.append((skill, directory.appendingPathComponent(target.subpath)))
            }
        }
        try installFiles(files, in: directory, retiringLegacyIn: targetDirectory.subpath)
    }

    private static func installFiles(
        _ files: [(StudioSkill, URL)], in directory: URL, retiringLegacyIn selectedDirectory: String?
    ) throws {
        let fm = FileManager.default
        // Check every destination first so a customized skill cannot leave a half-updated set.
        for (skill, url) in files where fm.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            guard existing == Data(skill.fullContent.utf8) || isKnownManaged(existing, skillID: skill.id) else {
                throw StudioSkillInstallationError.customizedSkill(url)
            }
        }
        for (skill, url) in files {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let current = try? Data(contentsOf: url)
            if current != Data(skill.fullContent.utf8) {
                try skill.fullContent.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        if Set(files.map { $0.0.id }) == Set(all.map(\.id)) {
            try removeManagedLegacyStorySkill(in: directory, targetDirectory: selectedDirectory)
        }
    }

    private static func isKnownManaged(_ data: Data, skillID: String) -> Bool {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return knownManagedHashes[skillID]?.contains(hash) == true
    }

    /// Removes only byte-identical released copies. A user-edited legacy skill remains intact.
    public static func removeManagedLegacyStorySkill(
        in directory: URL, targetDirectory: String? = nil
    ) throws {
        let old = StudioSkill(id: "story-flows", title: "", shortDescription: "", fullContent: "")
        for target in installationTargets(for: old) where targetDirectory == nil || target.guardDirectory == targetDirectory {
            let url = directory.appendingPathComponent(target.subpath)
            guard FileManager.default.fileExists(atPath: url.path),
                  isKnownManaged(try Data(contentsOf: url), skillID: old.id) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    public static func availableInstallationTargets(for skill: StudioSkill, in directory: URL) -> [StudioSkillInstallationTarget] {
        let fm = FileManager.default
        return installationTargets(for: skill).filter { target in
            let guardURL = directory.appendingPathComponent(target.guardDirectory)
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: guardURL.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    public static func installedTargets(for skill: StudioSkill, in directory: URL) -> [StudioSkillInstallationTarget] {
        availableInstallationTargets(for: skill, in: directory).filter { target in
            let url = directory.appendingPathComponent(target.subpath)
            return (try? Data(contentsOf: url)) == Data(skill.fullContent.utf8)
        }
    }

    public static func missingTargets(for skill: StudioSkill, in directory: URL) -> [StudioSkillInstallationTarget] {
        availableInstallationTargets(for: skill, in: directory).filter { target in
            let url = directory.appendingPathComponent(target.subpath)
            return (try? Data(contentsOf: url)) != Data(skill.fullContent.utf8)
        }
    }

    public static func missingTargetDirectories(in directory: URL) -> [StudioSkillDirectoryTarget] {
        let fm = FileManager.default
        return targetDirectories.filter { targetDirectory in
            let url = directory.appendingPathComponent(targetDirectory.subpath)
            var isDir: ObjCBool = false
            return !(fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
        }
    }

    // MARK: Git root

    /// Walks up from `directory` looking for a `.git` entry (directory or file for worktrees).
    /// Returns the containing directory if found, nil if no git repo is detected.
    public static func gitRoot(from directory: URL) -> URL? {
        guard directory.isFileURL else { return nil }
        let fm = FileManager.default
        var currentPath = directory.standardizedFileURL.path
        guard currentPath.hasPrefix("/") else { return nil }
        var visitedPaths: Set<String> = []

        // Traverse filesystem path strings rather than retaining URL base chains.
        // Foundation can produce relative parents above the root for composed URLs.
        while !currentPath.isEmpty, currentPath != "/", visitedPaths.insert(currentPath).inserted {
            let current = URL(fileURLWithPath: currentPath, isDirectory: true)
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            let parentPath = (currentPath as NSString).deletingLastPathComponent
            guard !parentPath.isEmpty, parentPath.count < currentPath.count else { return nil }
            currentPath = parentPath
        }
        return nil
    }

    // MARK: Detection

    public static func hasMissingInstallableSkills(in directory: URL) -> Bool {
        all.contains { !missingTargets(for: $0, in: directory).isEmpty }
    }

    public static func isInstalled(_ skill: StudioSkill, in directory: URL) -> Bool {
        let availableTargets = availableInstallationTargets(for: skill, in: directory)
        guard !availableTargets.isEmpty else { return false }
        return availableTargets.allSatisfy { target in
            let url = directory.appendingPathComponent(target.subpath)
            return (try? Data(contentsOf: url)) == Data(skill.fullContent.utf8)
        }
    }

}
