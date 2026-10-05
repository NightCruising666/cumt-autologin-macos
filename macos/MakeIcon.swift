// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

@main struct MakeIcon {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!; NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(size) / 512, y: CGFloat(size) / 512)
            let square = NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 472, height: 472), xRadius: 102, yRadius: 102)
            NSGradient(starting: NSColor(calibratedRed: 0.24, green: 0.57, blue: 0.96, alpha: 1),
                       ending: NSColor(calibratedRed: 0.13, green: 0.28, blue: 0.77, alpha: 1))!.draw(in: square, angle: -45)
            NSColor.white.setStroke(); NSColor.white.setFill()
            for radius: CGFloat in [95, 150, 205] {
                let arc = NSBezierPath(); arc.lineWidth = 29; arc.lineCapStyle = .round
                arc.appendArc(withCenter: NSPoint(x: 256, y: 155), radius: radius, startAngle: 45, endAngle: 135)
                arc.stroke()
            }
            NSBezierPath(ovalIn: NSRect(x: 234, y: 133, width: 44, height: 44)).fill()
            NSGraphicsContext.restoreGraphicsState()
            let data = bitmap.representation(using: .png, properties: [:])!
            let standard = "icon_\(size)x\(size).png"
            if size <= 512 { try data.write(to: directory.appendingPathComponent(standard)) }
            if size >= 32 { try data.write(to: directory.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png")) }
        }
    }
}
