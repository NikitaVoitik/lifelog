// Draws the Lifelog app icon (record button on a warm gradient, with a clock-tick ring) → recorder/AppIcon.icns
// usage: swift tools/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS icon grid: 824/1024 body, ~22% corner radius, soft drop shadow
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset * 1.2, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(srgbRed: 1.0, green: 0.47, blue: 0.36, alpha: 1).cgColor,
                                   NSColor(srgbRed: 0.84, green: 0.16, blue: 0.30, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    let c = CGPoint(x: body.midX, y: body.midY)
    let R = body.width * 0.36
    // 60 minute ticks, every 5th one longer
    for i in 0..<60 {
        let a = CGFloat(i) / 60 * 2 * .pi
        let long = i % 5 == 0
        let r1 = R * (long ? 0.86 : 0.92), r2 = R
        ctx.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
        ctx.addLine(to: CGPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(long ? 0.95 : 0.55).cgColor)
        ctx.setLineWidth(s * (long ? 0.014 : 0.007))
        ctx.setLineCap(.round)
        ctx.strokePath()
    }
    // record button
    ctx.setFillColor(NSColor.white.cgColor)
    let rr = R * 0.56
    ctx.fillEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
    ctx.setFillColor(NSColor(srgbRed: 0.93, green: 0.26, blue: 0.30, alpha: 1).cgColor)
    let ri = rr * 0.62
    ctx.fillEllipse(in: CGRect(x: c.x - ri, y: c.y - ri, width: 2 * ri, height: 2 * ri))
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Lifelog.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "recorder/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try! render(512).write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lifelog-icon-preview.png"))
print(p.terminationStatus == 0 ? "wrote recorder/AppIcon.icns" : "iconutil failed")
