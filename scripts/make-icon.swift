// Draws the ContextDock app icon and writes Resources/AppIcon.icns (plus a 1024px preview PNG).
// Usage: swift scripts/make-icon.swift [preview.png]
// Shapes only: SF Symbols may not be used in app icons.
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: String, _ alpha: CGFloat = 1) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
}

/// Apple-style continuous-corner tile (superellipse), on the macOS 26 icon grid.
func squircle(_ r: CGRect) -> NSBezierPath {
    let path = NSBezierPath()
    let n: CGFloat = 5
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let p = NSPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
        i == 0 ? path.move(to: p) : path.line(to: p)
    }
    path.close()
    return path
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func draw(size px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Tile: dusk gradient like the reference video's wallpaper, with a soft drop shadow.
    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = squircle(tileRect)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color("#3B2A6B").setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [color("#D9752F"), color("#9A456A"), color("#3B2A6B")], atLocations: [0, 0.5, 1],
               colorSpace: .sRGB)!.draw(in: tileRect, angle: 90)
    // Gentle glow behind the bar.
    NSGradient(starting: color("#FFB070", 0.35), ending: color("#FFB070", 0))!
        .draw(fromCenter: NSPoint(x: 512, y: 420), radius: 0, toCenter: NSPoint(x: 512, y: 420), radius: 420, options: [])
    NSGraphicsContext.restoreGraphicsState()
    color("#FFFFFF", 0.14).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    // The Dock: a frosted bar with the three contexts (Work selected), a divider, an app.
    // Sized to stay readable at 16-32px.
    let unit: CGFloat = 112
    let gap: CGFloat = 14
    let pad: CGFloat = 30
    let pillW: CGFloat = 222
    let dividerSpace: CGFloat = 42
    let barW = pad + pillW + gap + unit + gap + unit + dividerSpace + unit + pad
    let barH: CGFloat = 112 + 2 * pad
    let bar = CGRect(x: 512 - barW / 2, y: 512 - barH / 2 - 16, width: barW, height: barH)
    NSGraphicsContext.saveGraphicsState()
    let barShadow = NSShadow()
    barShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    barShadow.shadowBlurRadius = 30
    barShadow.shadowOffset = NSSize(width: 0, height: -10)
    barShadow.set()
    color("#2A1C2E", 0.62).setFill()
    rounded(bar, 58).fill()
    NSGraphicsContext.restoreGraphicsState()
    color("#FFFFFF", 0.16).setStroke()
    let barOutline = rounded(bar.insetBy(dx: 1, dy: 1), 57)
    barOutline.lineWidth = 2.5
    barOutline.stroke()

    let cy = bar.midY
    var x = bar.minX + pad

    // Contexts in Dock order: Personal (quiet circle), Work (the selected pill), Agents (quiet circle).
    func quietCircle(_ hex: String) {
        let c = CGRect(x: x, y: cy - unit / 2, width: unit, height: unit)
        color("#FFFFFF", 0.12).setFill()
        NSBezierPath(ovalIn: c).fill()
        color(hex).setFill()
        NSBezierPath(ovalIn: c.insetBy(dx: 36, dy: 36)).fill()
        x += unit + gap
    }
    quietCircle("#CF8812")

    let pill = CGRect(x: x, y: cy - unit / 2, width: pillW, height: unit)
    color("#3277BB").setFill()
    rounded(pill, unit / 2).fill()
    color("#FFFFFF").setFill()
    rounded(CGRect(x: pill.minX + 40, y: cy - 18, width: 36, height: 36), 9).fill()          // tiny briefcase
    rounded(CGRect(x: pill.minX + 92, y: cy - 10, width: 92, height: 20), 10).fill()         // label
    x += pillW + gap

    quietCircle("#7B5CC4")
    x -= gap

    // Divider.
    color("#FFFFFF", 0.22).setFill()
    rounded(CGRect(x: x + dividerSpace / 2 - 2, y: cy - 44, width: 4, height: 88), 2).fill()
    x += dividerSpace

    // One app tile, with a little detail so it reads as an app, not a blank square.
    let app = CGRect(x: x, y: cy - unit / 2, width: unit, height: unit)
    NSGradient(starting: color("#E9E4EE"), ending: color("#FFFFFF"))!.draw(in: squircle(app), angle: 90)
    color("#3277BB").setFill()
    rounded(CGRect(x: app.midX - 28, y: app.midY + 4, width: 56, height: 14), 7).fill()
    color("#9A8FA8").setFill()
    rounded(CGRect(x: app.midX - 28, y: app.midY - 20, width: 38, height: 11), 5.5).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try draw(size: pt * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
if CommandLine.arguments.count > 1 {
    try draw(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
