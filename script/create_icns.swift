import Cocoa

let size = CGSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Shadow
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 32, color: NSColor.black.withAlphaComponent(0.15).cgColor)

// Squircle Background
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: bgRect, xRadius: 180, yRadius: 180)

let gradient = NSGradient(starting: NSColor(white: 0.98, alpha: 1.0), ending: NSColor(white: 0.90, alpha: 1.0))!
gradient.draw(in: path, angle: -90)

ctx.setShadow(offset: .zero, blur: 0, color: nil)

// DB Center
let dbColor = NSColor(red: 0.06, green: 0.72, blue: 0.51, alpha: 1.0)
dbColor.setFill()
let dbEllipse = NSRect(x: 422, y: 350, width: 180, height: 60)
let dbPath = NSBezierPath()
dbPath.appendOval(in: dbEllipse)
let dbBody = NSRect(x: 422, y: 380, width: 180, height: 120)
dbPath.appendRect(dbBody)
dbPath.fill()

let dbTop = NSBezierPath(ovalIn: NSRect(x: 422, y: 470, width: 180, height: 60))
NSColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1.0).setFill()
dbTop.fill()

// Add some connections
NSColor.gray.withAlphaComponent(0.3).setStroke()
let linePath = NSBezierPath()
linePath.lineWidth = 16
linePath.lineCapStyle = .round
// from left box
linePath.move(to: NSPoint(x: 360, y: 640))
linePath.line(to: NSPoint(x: 512, y: 500))
// from right box
linePath.move(to: NSPoint(x: 664, y: 640))
linePath.line(to: NSPoint(x: 512, y: 500))
linePath.stroke()

// Left Box
NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1.0).setFill()
let leftBox = NSBezierPath(roundedRect: NSRect(x: 240, y: 600, width: 160, height: 120), xRadius: 24, yRadius: 24)
leftBox.fill()

// Right Box
NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1.0).setFill()
let rightBox = NSBezierPath(roundedRect: NSRect(x: 624, y: 600, width: 160, height: 120), xRadius: 24, yRadius: 24)
rightBox.fill()

img.unlockFocus()

let workspace = NSWorkspace.shared
let fileManager = FileManager.default

let iconsetURL = URL(fileURLWithPath: "AppIcon.iconset")
try? fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for size in [16, 32, 64, 128, 256, 512] {
    for scale in [1, 2] {
        let pixelSize = size * scale
        if pixelSize > 1024 { continue }
        
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 32)!
        rep.size = NSSize(width: size, height: size)
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        
        let data = rep.representation(using: .png, properties: [:])!
        let fileName = scale == 2 ? "icon_\(size)x\(size)@2x.png" : "icon_\(size)x\(size).png"
        try! data.write(to: iconsetURL.appendingPathComponent(fileName))
    }
}
