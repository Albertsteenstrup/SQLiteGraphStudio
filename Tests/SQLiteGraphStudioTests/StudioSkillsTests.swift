import Foundation
import Testing
@testable import StudioCore

struct StudioSkillsTests {
    @Test
    func gitRootTerminatesForDirectoryOutsideARepository() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(StudioSkills.gitRoot(from: root) == nil)
    }

    @Test
    func gitRootStopsAtFilesystemRoot() {
        #expect(StudioSkills.gitRoot(from: URL(fileURLWithPath: "/", isDirectory: true)) == nil)
    }

    @Test
    func gitRootRejectsNonFileURLs() throws {
        let url = try #require(URL(string: "https://example.test/project/connections/"))
        #expect(StudioSkills.gitRoot(from: url) == nil)
    }

    @Test(arguments: [true, false])
    func gitRootFindsRepositoryDirectoriesAndWorktreeFiles(markerIsDirectory: Bool) throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent(".git", isDirectory: markerIsDirectory)
        if markerIsDirectory {
            try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
        } else {
            try Data("gitdir: /tmp/test-worktree-marker\n".utf8).write(to: marker)
        }
        let nested = root.appendingPathComponent("storage/connections", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(StudioSkills.gitRoot(from: nested) == root.standardizedFileURL)
    }

    @Test
    func embeddedSkillsMatchPackagedSources() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        for skill in StudioSkills.all {
            let packaged = try String(contentsOf: repositoryRoot.appendingPathComponent("Skills/\(skill.id)/SKILL.md"), encoding: .utf8)
            #expect(skill.fullContent.trimmingCharacters(in: .whitespacesAndNewlines) == packaged.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test
    func everySkillSupportsPostgresDocumentSidecarsAndReadOnlyDiscovery() {
        for skill in StudioSkills.all {
            #expect(skill.fullContent.contains(".postgres.studio.json"))
            #expect(skill.fullContent.contains(".pgstudio.studio.json"))
            #expect(skill.fullContent.contains("schema-qualified"))
            #expect(skill.fullContent.contains("public.orders"))
            #expect(skill.fullContent.contains("read-only"))
            #expect(skill.fullContent.contains("Relayout"))
            #expect(!skill.fullContent.contains("Features → Schema Notes"))
            #expect(!skill.fullContent.contains("Features -> Schema Notes"))
        }
        #expect(!StudioSkills.graphClusters.fullContent.contains("reserved for future visual cluster tinting"))
    }

    @Test
    func missingTargetsDetectsOneSkillMissingFromExistingSkillDirectory() throws {
        let root = try makeTemporaryRoot()
        try createDirectory(".agents/skills", in: root)
        try writeInstalledSkill(StudioSkills.graphClusters, targetSubpath: ".agents/skills/graph-clusters/SKILL.md", in: root)
        try writeInstalledSkill(StudioSkills.schemaDescriptions, targetSubpath: ".agents/skills/schema-descriptions/SKILL.md", in: root)

        #expect(StudioSkills.isInstalled(StudioSkills.graphClusters, in: root))
        #expect(StudioSkills.isInstalled(StudioSkills.schemaDescriptions, in: root))
        #expect(!StudioSkills.isInstalled(StudioSkills.storyFlows, in: root))
        #expect(StudioSkills.missingTargets(for: StudioSkills.storyFlows, in: root).map(\.subpath) == [
            ".agents/skills/story-flows/SKILL.md",
        ])
        #expect(StudioSkills.hasMissingInstallableSkills(in: root))
    }

    @Test
    func installWritesMissingThirdSkillWithoutRequiringOtherSkillsToBeMissing() throws {
        let root = try makeTemporaryRoot()
        try createDirectory(".agents/skills", in: root)
        try writeInstalledSkill(StudioSkills.graphClusters, targetSubpath: ".agents/skills/graph-clusters/SKILL.md", in: root)
        try writeInstalledSkill(StudioSkills.schemaDescriptions, targetSubpath: ".agents/skills/schema-descriptions/SKILL.md", in: root)

        try StudioSkills.install([StudioSkills.storyFlows], to: root)

        #expect(StudioSkills.isInstalled(StudioSkills.storyFlows, in: root))
        #expect(!StudioSkills.hasMissingInstallableSkills(in: root))
    }

    @Test
    func sameSkillInstalledInOneSupportedDirectoryCanStillBeMissingFromAnother() throws {
        let root = try makeTemporaryRoot()
        try createDirectory(".agents/skills", in: root)
        try createDirectory(".claude/skills", in: root)
        try writeInstalledSkill(StudioSkills.schemaDescriptions, targetSubpath: ".claude/skills/schema-descriptions/SKILL.md", in: root)

        let missingTargets = StudioSkills.missingTargets(for: StudioSkills.schemaDescriptions, in: root).map(\.subpath)

        #expect(!StudioSkills.isInstalled(StudioSkills.schemaDescriptions, in: root))
        #expect(missingTargets == [
            ".agents/skills/schema-descriptions/SKILL.md",
        ])

        try StudioSkills.install([StudioSkills.schemaDescriptions], to: root)

        #expect(StudioSkills.isInstalled(StudioSkills.schemaDescriptions, in: root))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".agents/skills/schema-descriptions/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude/skills/schema-descriptions/SKILL.md").path))
    }

    @Test
    func installCanCreateNewTargetDirectoryEvenWhenExistingTargetIsAlreadyComplete() throws {
        let root = try makeTemporaryRoot()
        try createDirectory(".claude/skills", in: root)
        try StudioSkills.install(StudioSkills.all, to: root)

        #expect(!StudioSkills.hasMissingInstallableSkills(in: root))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".agents/skills").path))

        let agentsTarget = try #require(
            StudioSkills.targetDirectories.first { $0.subpath == ".agents/skills" }
        )
        try StudioSkills.install(StudioSkills.all, to: root, targetDirectory: agentsTarget)

        #expect(!StudioSkills.hasMissingInstallableSkills(in: root))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".agents/skills/graph-clusters/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".agents/skills/schema-descriptions/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".agents/skills/story-flows/SKILL.md").path))
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteGraphStudioTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func createDirectory(_ subpath: String, in root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(subpath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func writeInstalledSkill(_ skill: StudioSkill, targetSubpath: String, in root: URL) throws {
        let url = root.appendingPathComponent(targetSubpath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try skill.fullContent.write(to: url, atomically: true, encoding: .utf8)
    }
}
