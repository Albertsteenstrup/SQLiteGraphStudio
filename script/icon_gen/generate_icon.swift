import AppKit

func createIcon() {
    let size = CGSize(width: 1024, height: 1024)
    let image = NSImage(size: size, flipped: false) { rect in
        let ctx = NSGraphicsContext.current!.cgContext
        
        // Background
        let path = NSBezierPath(roundedRect: NSRect(x: 100, y: 104, width: 824, height: 824), xRadius: 180, yRadius: 180)
        NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.98, alpha: 1.0).setFill()
        path.fill()
        
        // Draw the rest... we can do it via a simple CoreGraphics or NSBezierPath
        
        return true
    }
    
    // Save image
}
