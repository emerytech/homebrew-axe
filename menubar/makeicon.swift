import AppKit

// Renders Axe's app icon — a bold red X on a dark rounded square.

func drawIcon(px: CGFloat) {
    let rect  = NSRect(x: 0, y: 0, width: px, height: px)
    let inset = px * 0.08
    let body  = rect.insetBy(dx: inset, dy: inset)
    let bg    = NSBezierPath(roundedRect: body, xRadius: px * 0.2, yRadius: px * 0.2)

    // Dark charcoal background
    NSGradient(colors: [
        NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1),
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1),
    ])!.draw(in: bg, angle: -90)

    // Bold "×" drawn as two crossing rounded-rect strokes
    let arm: CGFloat = px * 0.26
    let thick: CGFloat = px * 0.095
    let cx = px / 2, cy = px / 2

    let color = NSColor(srgbRed: 0.96, green: 0.28, blue: 0.28, alpha: 1)
    NSGraphicsContext.saveGraphicsState()
    bg.setClip()

    for angle: CGFloat in [45, -45] {
        let t = NSAffineTransform()
        t.translateX(by: cx, yBy: cy)
        t.rotate(byDegrees: angle)
        t.concat()
        let bar = NSBezierPath(roundedRect: NSRect(x: -arm, y: -thick/2,
                                                   width: arm * 2, height: thick),
                               xRadius: thick / 2, yRadius: thick / 2)
        color.setFill()
        bar.fill()
        let undo = NSAffineTransform()
        undo.translateX(by: -cx, yBy: -cy)
        undo.rotate(byDegrees: -angle)
        undo.concat()
    }
    NSGraphicsContext.restoreGraphicsState()
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let script = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let dir    = script.deletingLastPathComponent()
let iset   = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iset, withIntermediateDirectories: true)

for sz in sizes {
    for scale in [1, 2] {
        let px = sz * scale
        guard let bmp = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
        drawIcon(px: CGFloat(px))
        NSGraphicsContext.current = nil
        let name = scale == 1 ? "icon_\(sz)x\(sz).png" : "icon_\(sz)x\(sz)@2x.png"
        let data = bmp.representation(using: .png, properties: [:])
        try? data?.write(to: iset.appendingPathComponent(name))
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o",
                  dir.appendingPathComponent("AppIcon.icns").path,
                  iset.path]
try? task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(at: iset)
print("AppIcon.icns generated")
