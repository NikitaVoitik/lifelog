// Draws the iPhone app icon (same design as the Mac one, full-bleed, opaque) → phone/Sources/Assets.xcassets
// usage: swift tools/make-phone-icon.swift
import AppKit

let px = 1024, s = CGFloat(px)
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor(srgbRed: 1.0, green: 0.47, blue: 0.36, alpha: 1).cgColor,
                               NSColor(srgbRed: 0.84, green: 0.16, blue: 0.30, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
let c = CGPoint(x: s / 2, y: s / 2), R = s * 0.33
for i in 0..<60 {
    let a = CGFloat(i) / 60 * 2 * .pi, long = i % 5 == 0
    let r1 = R * (long ? 0.86 : 0.92)
    ctx.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
    ctx.addLine(to: CGPoint(x: c.x + cos(a) * R, y: c.y + sin(a) * R))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(long ? 0.95 : 0.55).cgColor)
    ctx.setLineWidth(s * (long ? 0.014 : 0.007)); ctx.setLineCap(.round); ctx.strokePath()
}
ctx.setFillColor(NSColor.white.cgColor)
let rr = R * 0.56
ctx.fillEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
ctx.setFillColor(NSColor(srgbRed: 0.93, green: 0.26, blue: 0.30, alpha: 1).cgColor)
let ri = rr * 0.62
ctx.fillEllipse(in: CGRect(x: c.x - ri, y: c.y - ri, width: 2 * ri, height: 2 * ri))
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
let dir = URL(fileURLWithPath: "phone/Sources/Assets.xcassets/AppIcon.appiconset")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("icon.png"))
try! #"{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#
    .write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try! #"{"info":{"author":"xcode","version":1}}"#.write(to: dir.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(dir.path)/icon.png")
