import AppKit
import Foundation
import SwiftUI

/// Renders a schema review's graph offscreen so the MCP helper can show the exact app view
/// inside a conversation. Run as `SQLiteGraphStudio --render-review-session`: one JSON
/// request per line on stdin, one JSON response per line on stdout. No window is ever
/// shown, the process has no Dock icon, and it exits when stdin closes.
///
/// Requests: `{"id", "cmd": "render", "path", "width", "height", "scale", "appearance"?,
/// "actions"?, "format"?}` applies the actions in order and returns a JPEG (or PNG) frame;
/// `{"id", "cmd": "close", "path"}` releases a review.
/// Actions reuse the app's own code: clicks go through the graph's hit-testing and tap
/// handling, linked tables use the graph's own reveal action, camera moves through its
/// viewport transform, and stepping through connected-change sets. The helper stops it when
/// idle; the renderer also exits on its own after ten quiet minutes.
public enum SchemaReviewRenderSession {
    public static let flag = "--render-review-session"

    public static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.dropFirst().first == flag
    }

    @MainActor
    public static func run() -> Never {
        // macOS ties a running process to an app by its executable file. Run from the app
        // bundle, the renderer would receive the documents meant for Graph Studio, so the
        // helper starts it from a clone of the executable outside the bundle.
        guard Bundle.main.bundleIdentifier != PreferenceDomainMigration.canonicalBundleIdentifier else {
            FileHandle.standardOutput.write(Data(#"{"ok":false,"error":"The review renderer must run from a copy outside the app bundle."}"#.utf8 + [0x0A]))
            exit(2)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let (lines, continuation) = AsyncStream.makeStream(of: Data.self)
        Thread.detachNewThread {
            let input = FileHandle.standardInput
            var buffer = Data()
            while true {
                let chunk = input.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    continuation.yield(Data(buffer[buffer.startIndex..<newline]))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            continuation.finish()
        }
        let server = SchemaReviewRenderServer()
        Task { @MainActor in
            for await line in lines {
                let response = await server.handle(line)
                FileHandle.standardOutput.write(response + Data([0x0A]))
            }
            server.closeAll()
            exit(0)
        }
        // A safety net for a helper that stays alive but stops asking.
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(30))
                if server.lastRequest.duration(to: .now) > .seconds(600) { exit(0) }
            }
        }
        application.run()
        exit(0)
    }
}

@MainActor
final class SchemaReviewRenderServer {
    /// Reviews kept open at once; the least recently shown one closes first.
    static let maximumOpenReviews = 3
    private var reviews: [String: RenderedReview] = [:]
    private var recent: [String] = []
    private(set) var lastRequest = ContinuousClock.now

    func handle(_ line: Data) async -> Data {
        lastRequest = .now
        defer { lastRequest = .now }
        var response: [String: Any]
        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        do {
            response = try await perform(request)
            response["ok"] = true
        } catch {
            response = ["ok": false, "error": error.localizedDescription]
        }
        response["id"] = request["id"] ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data(#"{"ok":false}"#.utf8)
    }

    func closeAll() {
        for review in reviews.values { review.close() }
        reviews = [:]
    }

    private func perform(_ request: [String: Any]) async throws -> [String: Any] {
        guard let path = request["path"] as? String, !path.isEmpty else { throw RenderError("A review path is required.") }
        switch request["cmd"] as? String {
        case "close":
            reviews.removeValue(forKey: path)?.close()
            recent.removeAll { $0 == path }
            return [:]
        case "render":
            let version = try ReviewFileVersion(path: path)
            let size = CGSize(width: Self.dimension(request["width"], default: 680), height: Self.dimension(request["height"], default: 460))
            let scale = min(max((request["scale"] as? NSNumber)?.doubleValue ?? 2, 1), 3)
            // Graph Studio follows the system appearance, so frames do too unless asked otherwise.
            let dark = (request["appearance"] as? String).map { $0 == "dark" }
            let clock = ContinuousClock()
            let started = clock.now
            let review: RenderedReview
            if let existing = reviews[path], existing.fileVersion == version {
                review = existing
                review.configure(size: size, dark: dark)
            } else {
                reviews.removeValue(forKey: path)?.close()
                review = try await RenderedReview(url: URL(fileURLWithPath: path), size: size, dark: dark,
                                                  fileVersion: version)
                guard try ReviewFileVersion(path: path) == version else {
                    review.close()
                    throw RenderError("The review changed while it was opening. Retry the frame.")
                }
                reviews[path] = review
            }
            recent.removeAll { $0 == path }
            recent.append(path)
            while recent.count > Self.maximumOpenReviews {
                reviews.removeValue(forKey: recent.removeFirst())?.close()
            }
            let opened = clock.now
            let actions = request["actions"] as? [[String: Any]]
                ?? (request["action"] as? [String: Any]).map { [$0] } ?? []
            for action in actions.prefix(64) {
                review.apply(action)
                // Let each step land before the next: a click must hit the view the
                // preceding camera move produced.
                if actions.count > 1 { await review.settle() }
            }
            await review.settle()
            let settled = clock.now
            var frame = try review.frame(scale: scale, png: request["format"] as? String == "png")
            frame["timing"] = ["openMs": Self.milliseconds(started.duration(to: opened)),
                               "settleMs": Self.milliseconds(opened.duration(to: settled)),
                               "encodeMs": Self.milliseconds(settled.duration(to: clock.now))]
            return frame
        default:
            throw RenderError("Unknown render command.")
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func dimension(_ value: Any?, default fallback: CGFloat) -> CGFloat {
        let number = (value as? NSNumber)?.doubleValue ?? Double(fallback)
        return CGFloat(min(max(number, 120), 2400))
    }
}

/// A cheap per-frame identity check. Preview generation replaces files atomically, so the
/// inode changes even if a new revision happens to have the same length and timestamp.
struct ReviewFileVersion: Equatable {
    let size: UInt64
    let modified: Date
    let fileNumber: UInt64?

    init(path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw RenderError("The review file could not be inspected.")
        }
        self.size = size.uint64Value
        self.modified = modified
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}

/// One review shown in a hidden window, driven the way a reader drives the app.
@MainActor
final class RenderedReview {
    let session: AppSession
    let fileVersion: ReviewFileVersion
    private let window: NSWindow
    private let hosting: NSHostingView<AnyView>
    /// A private plist standing in for the app's preferences, deleted on close.
    private let defaultsFile: URL
    private var needsInitialFit = true
    private var dark: Bool?

    init(url: URL, size: CGSize, dark: Bool?, fileVersion: ReviewFileVersion) async throws {
        // Start from the reader's graph preferences, but write nothing back: opening a
        // review here must not add it to the app's recent documents. A suite named by a
        // file path keeps the copy out of ~/Library/Preferences.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SQLiteGraphStudio Render", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defaultsFile = folder.appendingPathComponent(UUID().uuidString + ".plist")
        let defaults = UserDefaults(suiteName: defaultsFile.path) ?? .standard
        for (key, value) in UserDefaults.standard.persistentDomain(forName: PreferenceDomainMigration.canonicalBundleIdentifier) ?? [:] {
            defaults.set(value, forKey: key)
        }
        session = AppSession(databaseService: DatabaseService(), userDefaults: defaults)
        self.fileVersion = fileVersion
        session.rendersOffscreen = true
        await session.openDocument(url: url)
        guard session.schemaReview != nil else {
            Self.removeDefaults(at: defaultsFile)
            throw RenderError(session.presentedError?.message ?? "The review could not be opened.")
        }
        hosting = NSHostingView(rootView: Self.root(session: session, dark: dark))
        hosting.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        self.dark = dark
        applyAppearance()
    }

    func configure(size: CGSize, dark: Bool?) {
        if hosting.frame.size != size {
            window.setContentSize(size)
            hosting.frame = CGRect(origin: .zero, size: size)
        }
        if dark != self.dark {
            self.dark = dark
            hosting.rootView = Self.root(session: session, dark: dark)
        }
        applyAppearance()
    }

    /// A window that is never shown doesn't pass an appearance on to SwiftUI, so a requested
    /// color scheme is set on the view itself, and AppKit colors resolve against the same one.
    private static func root(session: AppSession, dark: Bool?) -> AnyView {
        let view = SchemaGraphView(session: session).background(Color(nsColor: .windowBackgroundColor))
        guard let dark else { return AnyView(view) }
        return AnyView(view.environment(\.colorScheme, dark ? .dark : .light))
    }

    private func applyAppearance() {
        let appearance = dark.flatMap { NSAppearance(named: $0 ? .darkAqua : .aqua) }
        for target in [window, hosting, NSApp] as [NSAppearanceCustomization?] where target?.appearance?.name != appearance?.name {
            target?.appearance = appearance
        }
    }

    func apply(_ action: [String: Any]) {
        let point = CGPoint(x: number(action["x"]), y: number(action["y"]))
        switch action["type"] as? String {
        case "click":
            session.requestGraphTap(at: point)
        case "select":
            if let table = action["table"] as? String { session.revealGraphNode(table) }
        case "pan":
            moveCamera(to: GraphViewportTransform(
                zoom: session.graphZoom,
                pan: CGSize(width: session.graphPan.width + number(action["dx"]),
                            height: session.graphPan.height + number(action["dy"]))
            ))
        case "zoom":
            moveCamera(to: GraphViewportTransform(zoom: session.graphZoom, pan: session.graphPan)
                .magnified(by: number(action["magnification"]), at: point, in: hosting.bounds.size, minZoom: minimumZoom))
        case "transform":
            // The view previews gestures by scaling and moving the last frame; this applies
            // the same screen mapping, x' = scale · x + (tx, ty), to the graph camera.
            let scale = number(action["scale"], default: 1)
            let shift = CGSize(width: number(action["tx"]), height: number(action["ty"]))
            let current = GraphViewportTransform(zoom: session.graphZoom, pan: session.graphPan)
            guard scale.isFinite, scale > 0, shift.width.isFinite, shift.height.isFinite else { break }
            if abs(scale - 1) < 0.000_001 {
                moveCamera(to: GraphViewportTransform(zoom: current.zoom, pan: CGSize(
                    width: current.pan.width + shift.width, height: current.pan.height + shift.height)))
            } else {
                // A scale with a shift is a zoom about its one fixed point.
                let anchor = CGPoint(x: shift.width / (1 - scale), y: shift.height / (1 - scale))
                moveCamera(to: current.magnified(by: scale - 1, at: anchor, in: hosting.bounds.size, minZoom: minimumZoom))
            }
        case "step":
            session.stepReviewChangeSet(by: Int(number(action["direction"], default: 1)) >= 0 ? 1 : -1)
        case "set":
            let index = Int(number(action["index"], default: -1))
            if index == -1 { session.showSchemaReviewFullModel() }
            else if session.schemaReviewChangeSets.indices.contains(index) { session.revealReviewChangeSet(at: index) }
        case "fit":
            if session.isSchemaReviewFullModelView {
                session.showSchemaReviewFullModel()
            } else if session.schemaReviewViewIndex > 0 {
                session.revealReviewChangeSet(at: session.schemaReviewViewIndex - 1)
            } else {
                session.requestAutomationViewport(fitVisibleTables: true, transitionMilliseconds: 0)
            }
        default:
            break
        }
    }

    private var minimumZoom: CGFloat {
        session.graph.nodes.count > GraphLayoutModel.largeGraphOverviewThreshold ? 0.005 : 0.12
    }

    /// Waits until the camera, selection and layout have stopped changing.
    func settle() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var last: (CGFloat, CGSize, Set<String>)?
        var stableTicks = 0
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            hosting.layoutSubtreeIfNeeded()
            let fitted = !needsInitialFit || session.initializedGraphViewportDocument != nil
            let current = (session.graphZoom, session.graphPan, session.selectedGraphNodeIDs)
            if fitted, session.graphLayout.hasSettledLayout, let last,
               last.0 == current.0, last.1 == current.1, last.2 == current.2 {
                stableTicks += 1
                if stableTicks >= 3 { break }
            } else {
                stableTicks = 0
            }
            last = current
        }
        needsInitialFit = false
    }

    func frame(scale: Double, png: Bool) throws -> [String: Any] {
        hosting.layoutSubtreeIfNeeded()
        let bounds = hosting.bounds
        let pixelsWide = Int((bounds.width * scale).rounded()), pixelsHigh = Int((bounds.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw RenderError("Could not allocate a frame.") }
        bitmap.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: bitmap)
        // JPEG keeps frames small enough to send on every interaction; the graph is drawn
        // on an opaque background, so nothing depends on transparency.
        let encoded = png ? bitmap.representation(using: .png, properties: [:])
            : bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        guard let encoded else { throw RenderError("Could not encode the frame.") }
        let sets = session.schemaReviewChangeSets
        return [
            "image": encoded.base64EncodedString(),
            "mimeType": png ? "image/png" : "image/jpeg",
            "width": bounds.width,
            "height": bounds.height,
            "sets": sets.count,
            "setTables": sets,
            "set": session.schemaReviewViewIndex - 1,
            "selection": session.selectedGraphNodeIDs.sorted(),
        ]
    }

    func close() {
        window.contentView = nil
        window.close()
        Self.removeDefaults(at: defaultsFile)
    }

    private static func removeDefaults(at file: URL) {
        UserDefaults.standard.removePersistentDomain(forName: file.path)
        try? FileManager.default.removeItem(at: file)
    }

    private func moveCamera(to transform: GraphViewportTransform) {
        session.graphZoom = transform.zoom
        session.graphPan = transform.pan
        session.requestAutomationViewport(fitVisibleTables: false, transitionMilliseconds: 0)
    }

    private func number(_ value: Any?, default fallback: CGFloat = 0) -> CGFloat {
        CGFloat((value as? NSNumber)?.doubleValue ?? Double(fallback))
    }
}

struct RenderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
