import AppKit
import SwiftUI

enum BalanceArtwork {
    // Shared vector artwork for the app, About window, and reproducible icon assets.
    static func draw(in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = AffineTransform(scaleByX: rect.width / 1024, byY: rect.height / 1024)
        (transform as NSAffineTransform).concat()
        NSColor(srgbRed: 0, green: 122 / 255, blue: 1, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200).fill()
        NSColor.white.setStroke()
        let b = NSBezierPath()
        b.move(to: NSPoint(x: 278, y: 276))
        b.line(to: NSPoint(x: 278, y: 748))
        b.line(to: NSPoint(x: 442, y: 748))
        b.curve(to: NSPoint(x: 442, y: 512), controlPoint1: NSPoint(x: 620, y: 748), controlPoint2: NSPoint(x: 620, y: 512))
        b.line(to: NSPoint(x: 278, y: 512))
        b.move(to: NSPoint(x: 442, y: 512))
        b.curve(to: NSPoint(x: 466, y: 276), controlPoint1: NSPoint(x: 662, y: 512), controlPoint2: NSPoint(x: 662, y: 276))
        b.line(to: NSPoint(x: 278, y: 276))
        b.lineWidth = 62
        b.lineCapStyle = .round
        b.lineJoinStyle = .round
        b.stroke()
        NSColor.white.setFill()
        for (x, height) in [(688.0, 180.0), (748.0, 340.0), (808.0, 240.0)] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 512 - height / 2, width: 30, height: height), xRadius: 15, yRadius: 15).fill()
        }
    }

    static let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
        draw(in: rect)
        return true
    }
}

struct BalanceLogo: View {
    var body: some View {
        Image(nsImage: BalanceArtwork.image).resizable().scaledToFit().accessibilityHidden(true)
    }
}
