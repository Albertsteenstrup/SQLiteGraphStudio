import Foundation

/// The patterns from one `.gitignore`, matched relative to the directory that
/// contains it. Supports the parts of the format that matter for pruning a
/// project scan: comments, negation, anchoring, directory-only patterns, `*`,
/// `?`, `**` and character classes.
///
/// Patterns are matched by a linear scanner rather than a regular expression.
/// A `.gitignore` comes from whatever folder the user points at, and a regex
/// built from `*`-heavy input backtracks catastrophically — a fifteen-character
/// line was enough to wedge a scan indefinitely.
struct GitIgnoreFile: Sendable {
    /// Absolute path of the directory holding this file, without a trailing slash.
    let basePath: String
    let patterns: [Pattern]

    struct Pattern: Sendable {
        let segments: [Segment]
        let isNegated: Bool
        let directoryOnly: Bool
        /// Anchored patterns match from the `.gitignore`'s own directory;
        /// others match a name at any depth below it.
        let isAnchored: Bool
    }

    /// One `/`-separated piece of a pattern.
    enum Segment: Sendable {
        case doubleStar
        case glob([GlobToken])
    }

    enum GlobToken: Sendable {
        case literal(Character)
        /// `*` — any run of characters within one path component.
        case anyRun
        /// `?` — exactly one character.
        case single
        case set(members: Set<Character>, ranges: [ClosedRange<Character>], isNegated: Bool)
    }

    static func load(in directory: URL) -> GitIgnoreFile? {
        let url = directory.appendingPathComponent(".gitignore")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let patterns = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap {
            Pattern(line: String($0))
        }
        guard !patterns.isEmpty else { return nil }
        return GitIgnoreFile(basePath: directory.standardizedFileURL.path, patterns: patterns)
    }

    /// `true` to ignore, `false` for an explicit un-ignore, `nil` when no pattern
    /// in this file has an opinion. The last matching pattern wins, as in git.
    func decision(forPath path: String, isDirectory: Bool) -> Bool? {
        guard path.count > basePath.count + 1, path.hasPrefix(basePath + "/") else { return nil }
        let components = path.dropFirst(basePath.count + 1).split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        var decision: Bool?
        for pattern in patterns {
            if pattern.directoryOnly && !isDirectory { continue }
            if pattern.matches(components) { decision = !pattern.isNegated }
        }
        return decision
    }
}

extension GitIgnoreFile.Pattern {
    init?(line rawLine: String) {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        // Trailing whitespace is not part of a pattern unless escaped.
        while line.hasSuffix(" "), !line.hasSuffix("\\ ") { line.removeLast() }
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

        var isNegated = false
        if line.hasPrefix("!") {
            isNegated = true
            line.removeFirst()
        } else if line.hasPrefix("\\#") || line.hasPrefix("\\!") {
            line.removeFirst()
        }
        guard !line.isEmpty else { return nil }

        var directoryOnly = false
        if line.hasSuffix("/") {
            directoryOnly = true
            line.removeLast()
        }
        guard !line.isEmpty else { return nil }

        let isAnchored = line.dropLast().contains("/") || line.hasPrefix("/")
        if line.hasPrefix("/") { line.removeFirst() }
        guard !line.isEmpty else { return nil }

        let segments = line.split(separator: "/", omittingEmptySubsequences: false).map { piece -> GitIgnoreFile.Segment in
            piece == "**" ? .doubleStar : .glob(GitIgnoreFile.Pattern.tokens(in: String(piece)))
        }
        guard !segments.isEmpty else { return nil }
        self.init(segments: segments, isNegated: isNegated, directoryOnly: directoryOnly, isAnchored: isAnchored)
    }

    /// A pattern matches when its segments line up with a run of path
    /// components — from the first component when anchored, from any component
    /// otherwise. Components after the run are allowed, so an ignored directory
    /// covers everything beneath it.
    func matches(_ components: [String]) -> Bool {
        if isAnchored { return matchSegments(from: 0, component: 0, components: components) }
        for start in components.indices where matchSegments(from: 0, component: start, components: components) {
            return true
        }
        return false
    }

    private func matchSegments(from segmentIndex: Int, component componentIndex: Int, components: [String]) -> Bool {
        // `**` is the only construct that can branch, so memoising on the pair
        // keeps the whole match linear in segments × components.
        var visited = Set<Int>()
        let width = components.count + 1

        func walk(_ segment: Int, _ component: Int) -> Bool {
            if segment == segments.count { return true }
            guard visited.insert(segment * width + component).inserted else { return false }
            if component >= components.count {
                return segments[segment...].allSatisfy {
                    if case .doubleStar = $0 { return true } else { return false }
                }
            }
            switch segments[segment] {
            case .doubleStar:
                for next in component...components.count where walk(segment + 1, next) { return true }
                return false
            case .glob(let tokens):
                guard Self.matches(tokens: tokens, in: components[component]) else { return false }
                return walk(segment + 1, component + 1)
            }
        }
        return walk(segmentIndex, componentIndex)
    }

    /// Classic linear wildcard matching: a single backtrack point per `*`, so
    /// the cost stays bounded no matter how many wildcards a pattern has.
    static func matches(tokens: [GitIgnoreFile.GlobToken], in component: String) -> Bool {
        let characters = Array(component)
        var tokenIndex = 0
        var characterIndex = 0
        var starToken = -1
        var starCharacter = 0

        func consumes(_ token: GitIgnoreFile.GlobToken, _ character: Character) -> Bool {
            switch token {
            case .literal(let expected):
                return expected == character
            case .single:
                return true
            case .set(let members, let ranges, let isNegated):
                let contained = members.contains(character) || ranges.contains { $0.contains(character) }
                return contained != isNegated
            case .anyRun:
                return false
            }
        }

        while characterIndex < characters.count {
            if tokenIndex < tokens.count, case .anyRun = tokens[tokenIndex] {
                starToken = tokenIndex
                starCharacter = characterIndex
                tokenIndex += 1
                continue
            }
            if tokenIndex < tokens.count, consumes(tokens[tokenIndex], characters[characterIndex]) {
                tokenIndex += 1
                characterIndex += 1
                continue
            }
            guard starToken >= 0 else { return false }
            tokenIndex = starToken + 1
            starCharacter += 1
            characterIndex = starCharacter
        }
        while tokenIndex < tokens.count, case .anyRun = tokens[tokenIndex] { tokenIndex += 1 }
        return tokenIndex == tokens.count
    }

    private static func tokens(in piece: String) -> [GitIgnoreFile.GlobToken] {
        var tokens: [GitIgnoreFile.GlobToken] = []
        let characters = Array(piece)
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "*":
                // `a**b` inside one component behaves as `a*b`; collapsing the
                // run also keeps redundant wildcards from multiplying work.
                while index < characters.count, characters[index] == "*" { index += 1 }
                if case .anyRun = tokens.last { break }
                tokens.append(.anyRun)
            case "?":
                tokens.append(.single)
                index += 1
            case "[":
                var cursor = index + 1
                var isNegated = false
                if cursor < characters.count, characters[cursor] == "!" || characters[cursor] == "^" {
                    isNegated = true
                    cursor += 1
                }
                var members: Set<Character> = []
                var ranges: [ClosedRange<Character>] = []
                var closed = false
                while cursor < characters.count {
                    if characters[cursor] == "]", cursor > index + 1 {
                        closed = true
                        cursor += 1
                        break
                    }
                    if characters[cursor] == "\\", cursor + 1 < characters.count {
                        members.insert(characters[cursor + 1])
                        cursor += 2
                        continue
                    }
                    if cursor + 2 < characters.count, characters[cursor + 1] == "-", characters[cursor + 2] != "]",
                       characters[cursor] <= characters[cursor + 2] {
                        ranges.append(characters[cursor]...characters[cursor + 2])
                        cursor += 3
                        continue
                    }
                    members.insert(characters[cursor])
                    cursor += 1
                }
                if closed {
                    tokens.append(.set(members: members, ranges: ranges, isNegated: isNegated))
                    index = cursor
                } else {
                    tokens.append(.literal("["))
                    index += 1
                }
            case "\\":
                if index + 1 < characters.count {
                    tokens.append(.literal(characters[index + 1]))
                    index += 2
                } else {
                    index += 1
                }
            default:
                tokens.append(.literal(characters[index]))
                index += 1
            }
        }
        return tokens
    }
}

/// Directories a project scan never descends into. `.gitignore` covers most
/// dependency and build output, but plenty of projects are not git repositories
/// and plenty of caches are never listed, so both rules apply together.
public enum ProjectIgnoreRules {
    public static let alwaysSkippedDirectoryNames: Set<String> = [
        // Version control and editor state
        ".git", ".hg", ".svn", ".bzr", ".idea", ".vscode", ".fleet", ".history",
        // Language package/dependency trees
        "node_modules", "bower_components", "jspm_packages", "vendor", "site-packages",
        "pods", "carthage", ".pub-cache", ".pnpm-store", ".yarn", ".bundle", ".cargo",
        // Virtual environments
        ".venv", "venv", ".virtualenv", ".conda", "virtualenv",
        // Build output and caches
        "build", "dist", "target", "out", "deriveddata", ".build", ".swiftpm", ".gradle",
        "__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".tox", ".nox",
        ".eggs", ".parcel-cache", ".turbo", ".next", ".nuxt", ".svelte-kit", ".angular",
        ".cache", ".terraform", ".serverless", ".stack-work", ".dart_tool", ".gradle-cache",
        "coverage", "htmlcov", ".nyc_output", ".sass-cache", ".docusaurus",
    ]

    public static func isSkippedDirectoryName(_ name: String) -> Bool {
        alwaysSkippedDirectoryNames.contains(name.lowercased()) || name.lowercased().hasSuffix(".egg-info")
    }

    /// Python virtual environments are often named something unguessable; the
    /// marker file identifies them regardless of the directory's name.
    public static func isVirtualEnvironment(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("pyvenv.cfg").path)
    }
}
