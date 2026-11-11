// Draws the GatePass app icon: a little figure leaping over a gate.
// Usage: swift scripts/make-icon.swift  -> assets/AppIcon.icns + assets/AppIcon.png
import AppKit

let size: CGFloat = 1024
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("assets")
try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func stroke(_ points: [CGPoint], width: CGFloat, color c: NSColor) {
    let p = NSBezierPath()
    p.move(to: points[0])
    for pt in points.dropFirst() { p.line(to: pt) }
    p.lineWidth = width
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    c.setStroke()
    p.stroke()
}

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Body: macOS icon grid (824pt squircle-ish rounded rect, centered), with a soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.28).cgColor)
color(0x0F766E).setFill()
bodyPath.fill()
ctx.restoreGState()

// Gradient: emerald -> teal -> cyan.
bodyPath.addClip()
NSGradient(colors: [color(0x34D399), color(0x10B981), color(0x0891B2)],
           atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
    .draw(in: body, angle: -55)

// Subtle top highlight.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)

let white = NSColor.white
let soft = NSColor.white.withAlphaComponent(0.38)

// Ground line.
stroke([CGPoint(x: 210, y: 262), CGPoint(x: 814, y: 262)], width: 20, color: soft)

// Gate: two posts + striped barrier.
stroke([CGPoint(x: 345, y: 262), CGPoint(x: 345, y: 470)], width: 38, color: white)
stroke([CGPoint(x: 679, y: 262), CGPoint(x: 679, y: 470)], width: 38, color: white)
let bar = NSBezierPath(roundedRect: NSRect(x: 300, y: 438, width: 424, height: 64), xRadius: 32, yRadius: 32)
white.setFill()
bar.fill()
ctx.saveGState()
bar.addClip()
color(0x0E9F8A).setFill()
for i in 0..<6 {
    let x = 318 + CGFloat(i) * 76
    let stripe = NSBezierPath()
    stripe.move(to: CGPoint(x: x, y: 438))
    stripe.line(to: CGPoint(x: x + 34, y: 438))
    stripe.line(to: CGPoint(x: x + 64, y: 502))
    stripe.line(to: CGPoint(x: x + 30, y: 502))
    stripe.close()
    stripe.fill()
}
ctx.restoreGState()

// Motion arc behind the figure.
let arc = NSBezierPath()
arc.move(to: CGPoint(x: 205, y: 340))
arc.curve(to: CGPoint(x: 440, y: 640), controlPoint1: CGPoint(x: 245, y: 520), controlPoint2: CGPoint(x: 330, y: 620))
arc.lineWidth = 16
arc.lineCapStyle = .round
arc.setLineDash([2, 40], count: 2, phase: 0)
soft.setStroke()
arc.stroke()

// Speed lines.
stroke([CGPoint(x: 238, y: 716), CGPoint(x: 330, y: 716)], width: 18, color: soft)
stroke([CGPoint(x: 268, y: 650), CGPoint(x: 345, y: 650)], width: 18, color: soft)

// The figure, mid-leap, moving right.
let limb: CGFloat = 46
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: NSColor.black.withAlphaComponent(0.18).cgColor)
ctx.beginTransparencyLayer(auxiliaryInfo: nil) // one shadow for the whole figure, no seams at joints
let hip = CGPoint(x: 486, y: 618)
let shoulder = CGPoint(x: 572, y: 712)
stroke([hip, shoulder], width: 54, color: white)                                                     // torso
stroke([hip, CGPoint(x: 592, y: 598), CGPoint(x: 690, y: 566)], width: limb, color: white)           // front leg
stroke([hip, CGPoint(x: 408, y: 566), CGPoint(x: 352, y: 616)], width: limb, color: white)           // back leg
stroke([shoulder, CGPoint(x: 650, y: 704), CGPoint(x: 712, y: 752)], width: limb - 6, color: white)  // front arm
stroke([shoulder, CGPoint(x: 500, y: 760), CGPoint(x: 452, y: 808)], width: limb - 6, color: white)  // back arm
let head = NSBezierPath(ovalIn: NSRect(x: 586, y: 744, width: 108, height: 108))
white.setFill()
head.fill()
ctx.endTransparencyLayer()
ctx.restoreGState()

image.unlockFocus()

// Write PNG + iconset -> icns.
func png(_ img: NSImage, px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try png(image, px: 1024).write(to: assets.appendingPathComponent("AppIcon.png"))
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(image, px: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(image, px: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("✓ assets/AppIcon.icns")
