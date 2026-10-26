// Renders AppIcon.icns. Usage: swift make_icon.swift (from app/)
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1), NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)])!
        .draw(in: shape, angle: -90)
    // lens: outer ring, glass, highlight
    let c = NSPoint(x: s / 2, y: s / 2), R = r.width * 0.30
    func circle(_ rad: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad)) }
    NSColor(white: 0.85, alpha: 1).setFill(); circle(R).fill()
    NSColor(white: 0.08, alpha: 1).setFill(); circle(R * 0.82).fill()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.35, blue: 0.75, alpha: 1), NSColor(red: 0.05, green: 0.08, blue: 0.25, alpha: 1)])!
        .draw(in: circle(R * 0.55), relativeCenterPosition: NSPoint(x: -0.3, y: 0.3))
    NSColor(white: 1, alpha: 0.55).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - R * 0.28, y: c.y + R * 0.08, width: R * 0.18, height: R * 0.18)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! render(pt).write(to: dir.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! render(pt * 2).write(to: dir.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", dir.path]
try! p.run(); p.waitUntilExit()
try! FileManager.default.removeItem(at: dir)
print("AppIcon.icns")
