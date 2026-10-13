// Run: xcrun swiftc Sources/EqualizerMac/Branding.swift scripts/generate-icon.swift -o .build/generate-icon
// Then: .build/generate-icon && iconutil -c icns .build/BalanceEQ.iconset -o Resources/BalanceEQ.icns
import AppKit

@main
struct GenerateIcon {
    static func main() throws {
        let directory = URL(fileURLWithPath: ".build/BalanceEQ.iconset")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let size = points * scale
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                BalanceArtwork.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
                NSGraphicsContext.restoreGraphicsState()
                let data = bitmap.representation(using: .png, properties: [:])!
                let suffix = scale == 2 ? "@2x" : ""
                try data.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
                if size == 1024 { try data.write(to: URL(fileURLWithPath: "Resources/BalanceEQ.png")) }
            }
        }
    }
}
