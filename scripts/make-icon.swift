import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 35
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.set()
        let background = NSBezierPath(roundedRect: NSRect(x: 85, y: 85, width: 854, height: 854), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(srgbRed: 0.96, green: 0.54, blue: 0.34, alpha: 1),
                   ending: NSColor(srgbRed: 0.83, green: 0.30, blue: 0.20, alpha: 1))!.draw(in: background, angle: -90)
        NSShadow().set()
        NSColor.white.setStroke()
        let board = NSBezierPath(roundedRect: NSRect(x: 295, y: 235, width: 434, height: 510), xRadius: 58, yRadius: 58)
        board.lineWidth = 40
        board.stroke()
        NSColor(srgbRed: 0.91, green: 0.42, blue: 0.27, alpha: 1).setFill()
        let clip = NSBezierPath(roundedRect: NSRect(x: 410, y: 685, width: 204, height: 112), xRadius: 32, yRadius: 32)
        clip.fill()
        NSColor.white.setStroke()
        clip.lineWidth = 37
        clip.stroke()
        for y in [560, 445, 330] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 402, y: y))
            line.line(to: NSPoint(x: y == 330 ? 535 : 622, y: y))
            line.lineWidth = 33
            line.lineCapStyle = .round
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("Icon generation failed") }
try FileManager.default.removeItem(at: iconset)
