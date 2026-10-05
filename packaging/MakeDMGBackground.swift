// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

@main struct MakeDMGBackground {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scale in [1, 2] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640 * scale, pixelsHigh: 400 * scale,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            NSColor(calibratedRed: 0.97, green: 0.98, blue: 1, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 640, height: 400).fill()

            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
                (value as NSString).draw(in: NSRect(x: 30, y: y, width: 580, height: size + 12), withAttributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: weight),
                    .foregroundColor: color, .paragraphStyle: centered
                ])
            }
            text("校园网助手", y: 310, size: 30, weight: .semibold,
                 color: NSColor(calibratedRed: 0.12, green: 0.19, blue: 0.32, alpha: 1))
            text("拖入「应用程序」即可安装", y: 276, size: 16, weight: .regular,
                 color: NSColor(calibratedRed: 0.35, green: 0.41, blue: 0.52, alpha: 1))

            NSColor(calibratedRed: 0.20, green: 0.47, blue: 0.89, alpha: 1).setStroke()
            let arrow = NSBezierPath()
            arrow.lineWidth = 6
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.move(to: NSPoint(x: 270, y: 200))
            arrow.line(to: NSPoint(x: 366, y: 200))
            arrow.move(to: NSPoint(x: 346, y: 220))
            arrow.line(to: NSPoint(x: 366, y: 200))
            arrow.line(to: NSPoint(x: 346, y: 180))
            arrow.stroke()

            text("安装后，从「应用程序」打开，在菜单栏中使用。", y: 54, size: 13, weight: .regular,
                 color: NSColor(calibratedRed: 0.40, green: 0.46, blue: 0.55, alpha: 1))
            NSGraphicsContext.restoreGraphicsState()
            bitmap.size = NSSize(width: 640, height: 400)
            let name = scale == 1 ? "background.png" : "background@2x.png"
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
        }
    }
}
