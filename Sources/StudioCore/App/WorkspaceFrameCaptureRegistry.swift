import AppKit
import Foundation
import SwiftUI

/// Captures only the registered workspace rectangle from Graph Studio's own
/// rendered content view. This does not capture the screen, title bar or tab bar.
@MainActor
public final class WorkspaceFrameCaptureRegistry {
    private final class Entry {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }
    private var entries: [UUID: Entry] = [:]

    public init() {}

    fileprivate func register(_ view: NSView, workspaceID: UUID) {
        entries[workspaceID] = Entry(view)
    }

    public func bounds(workspaceID: UUID) -> CGRect? {
        guard let probe = entries[workspaceID]?.view, let root = probe.window?.contentView else { return nil }
        root.layoutSubtreeIfNeeded()
        return root.convert(probe.bounds, from: probe).intersection(root.bounds)
    }

    /// Ask the native layer tree to draw before a snapshot is needed. This lets
    /// camera completion and canvas acknowledgements run without bitmap readback.
    public func prepare(workspaceID: UUID) {
        guard let root = entries[workspaceID]?.view?.window?.contentView else { return }
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        root.layer?.displayIfNeeded()
    }

    public func capture(workspaceID: UUID, maximumWidth: Int = 960) throws -> (image: Data, mimeType: String, width: Int, height: Int) {
        guard let probe = entries[workspaceID]?.view, let root = probe.window?.contentView else {
            throw CaptureError.unavailable
        }
        root.layoutSubtreeIfNeeded()
        let region = root.convert(probe.bounds, from: probe).intersection(root.bounds)
        guard region.width >= 100, region.height >= 100 else { throw CaptureError.unavailable }
        // Width is the logical card width. Draw at twice that resolution so
        // embedded Retina text does not enlarge a one-pixel-per-point JPEG.
        let factor = 2 * min(1, CGFloat(maximumWidth) / region.width, 900 / region.height)
        let width = max(1, Int((region.width * factor).rounded()))
        let height = max(1, Int((region.height * factor).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CaptureError.unavailable
        }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CaptureError.unavailable }
        bitmap.size = region.size
        root.cacheDisplay(in: region, to: bitmap)
        // View-based NSTableView draws its visible row views separately. AppKit's
        // ancestor cache can omit those rows even though they are onscreen.
        // Composite the actual visible row views, with the table's scroll clip.
        compositeTableRows(in: root, root: root, region: region, context: context.cgContext,
                           width: CGFloat(width), height: CGFloat(height))
        // Lossless UI captures preserve small labels and thin graph edges.
        // Dense scenes may need JPEG to fit the bridge's bounded response.
        if let image = bitmap.representation(using: .png, properties: [:]), image.count <= 600_000 {
            return (image, "image/png", width, height)
        }
        for quality in [0.94, 0.88, 0.80] {
            if let image = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               image.count <= 600_000 { return (image, "image/jpeg", width, height) }
        }
        throw CaptureError.tooLarge
    }

    private func compositeTableRows(in view: NSView, root: NSView, region: CGRect,
                                    context: CGContext, width: CGFloat, height: CGFloat) {
        guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0 else { return }
        if let table = view as? NSTableView {
            if let header = table.headerView {
                paintNativeView(header, area: header.visibleRect, clip: root.convert(header.visibleRect, from: header),
                                root: root, region: region, context: context, width: width, height: height)
            }
            let visible = table.visibleRect
            let range = table.rows(in: visible)
            if range.location != NSNotFound {
                for index in range.location..<NSMaxRange(range) {
                    // Materialize only rows already in the native scroll viewport,
                    // including when the app's window is covered by the chat.
                    guard let row = table.rowView(atRow: index, makeIfNecessary: true) else { continue }
                    let area = row.bounds.intersection(row.convert(visible, from: table))
                    paintNativeView(row, area: area, clip: root.convert(visible, from: table),
                                    root: root, region: region, context: context, width: width, height: height)
                }
            }
            return
        }
        for child in view.subviews {
            compositeTableRows(in: child, root: root, region: region, context: context, width: width, height: height)
        }
    }

    private func paintNativeView(_ view: NSView, area: CGRect, clip: CGRect, root: NSView, region: CGRect,
                                 context: CGContext, width: CGFloat, height: CGFloat) {
        guard !area.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: area) else { return }
        view.cacheDisplay(in: area, to: rep)
        guard let image = rep.cgImage else { return }
        let bounds = root.convert(area, from: view)
        func destination(_ rect: CGRect) -> CGRect {
            let x = (rect.minX - region.minX) * width / region.width
            let y = root.isFlipped ? (region.maxY - rect.maxY) : (rect.minY - region.minY)
            return CGRect(x: x, y: y * height / region.height,
                          width: rect.width * width / region.width, height: rect.height * height / region.height)
        }
        context.saveGState()
        context.clip(to: destination(clip.intersection(region)))
        for marker in WorkspaceFrameCaptureRegion.Marker.regions.allObjects
            where marker.window === root.window && !marker.isHiddenOrHasHiddenAncestor {
            let mask = root.convert(marker.bounds, from: marker)
            if let radius = marker.cornerRadius {
                if mask.intersects(bounds) {
                    context.addPath(CGPath(roundedRect: destination(mask),
                        cornerWidth: radius * width / region.width,
                        cornerHeight: radius * height / region.height, transform: nil))
                    context.clip()
                }
            } else {
                let foreground = CGMutablePath()
                foreground.addRect(CGRect(x: 0, y: 0, width: width, height: height))
                foreground.addRect(destination(mask))
                context.addPath(foreground)
                context.clip(using: .evenOdd)
            }
        }
        context.draw(image, in: destination(bounds))
        context.restoreGState()
    }

    public enum CaptureError: LocalizedError {
        case unavailable, tooLarge
        public var errorDescription: String? {
            switch self {
            case .unavailable: "This workspace has not been rendered in Graph Studio yet."
            case .tooLarge: "The workspace frame is too large. Reduce the frame width."
            }
        }
    }
}

/// Marks native pane clipping or foreground controls that must stay above a
/// table's separately captured row views. It never participates in hit testing.
public struct WorkspaceFrameCaptureRegion: NSViewRepresentable {
    public let cornerRadius: CGFloat?
    public init(cornerRadius: CGFloat? = nil) { self.cornerRadius = cornerRadius }
    public func makeNSView(context: Context) -> Marker { Marker(cornerRadius: cornerRadius) }
    public func updateNSView(_ nsView: Marker, context: Context) { nsView.cornerRadius = cornerRadius }

    public final class Marker: NSView {
        fileprivate static let regions = NSHashTable<Marker>.weakObjects()
        fileprivate var cornerRadius: CGFloat?
        fileprivate init(cornerRadius: CGFloat?) {
            self.cornerRadius = cornerRadius
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { Self.regions.add(self) } else { Self.regions.remove(self) }
        }
        public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct WorkspaceFrameRegistration: NSViewRepresentable {
    let workspaceID: UUID
    let registry: WorkspaceFrameCaptureRegistry
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        registry.register(view, workspaceID: workspaceID)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        registry.register(nsView, workspaceID: workspaceID)
    }
}
