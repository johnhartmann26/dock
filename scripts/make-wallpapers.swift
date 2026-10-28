import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// Makes a light and a dark wallpaper for each context in config.json, in that context's Dock color:
// soft blurred color fields with a fine grain. Writes <id>-light.heic and <id>-dark.heic.
//
//   swift scripts/make-wallpapers.swift ~/Library/Application\ Support/ContextDock/Wallpapers
let W = 3600, H = 2340
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func color(_ hex: String) -> NSColor {
    var v: UInt64 = 0; Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}
func hsb(_ c: NSColor, dh: CGFloat = 0, s: CGFloat? = nil, b: CGFloat? = nil, sMul: CGFloat = 1) -> NSColor {
    var h: CGFloat = 0, sat: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
    c.usingColorSpace(.sRGB)!.getHue(&h, saturation: &sat, brightness: &br, alpha: &a)
    var nh = h + dh; if nh < 0 { nh += 1 }; if nh > 1 { nh -= 1 }
    return NSColor(hue: nh, saturation: min(1, (s ?? sat) * sMul), brightness: b ?? br, alpha: 1)
}

struct Blob { var x, y, r: CGFloat; var c: NSColor; var a: CGFloat }

func render(base: NSColor, blobs: [Blob], blur: Double, grain: Double, to path: String) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(base.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    for b in blobs {
        let center = CGPoint(x: b.x * CGFloat(W), y: b.y * CGFloat(H))
        let g = CGGradient(colorsSpace: cs, colors: [b.c.withAlphaComponent(b.a).cgColor, b.c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: b.r * CGFloat(W), options: [])
    }
    var img = CIImage(cgImage: ctx.makeImage()!)
    let extent = img.extent
    img = img.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: extent)
    // Fine grain so the gradients don't band.
    let grainImg = CIFilter.randomGenerator().outputImage!.cropped(to: extent)
        .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: grain)])
    img = grainImg.composited(over: img)
    let out = CIContext().createCGImage(img, from: extent)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.heic" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

let configURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ContextDock/config.json")
let json = (try? Data(contentsOf: configURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
let contexts: [(String, String)] = (json?["contexts"] as? [[String: Any]])?.compactMap { c in
    (c["id"] as? String).flatMap { id in (c["color"] as? String).map { (id, $0) } }
} ?? [("personal", "#CF8812"), ("work", "#3277BB"), ("agents", "#7B5CC4")]
for (n, (id, hex)) in contexts.enumerated() {
    let i = n % 3
    let c = color(hex)
    // Same layout for light and dark, different per context.
    let layout: [(CGFloat, CGFloat, CGFloat)] = [
        [(0.18, 0.78, 0.55), (0.82, 0.22, 0.6), (0.62, 0.70, 0.4), (0.30, 0.20, 0.42), (0.95, 0.85, 0.35)],
        [(0.80, 0.80, 0.55), (0.15, 0.25, 0.6), (0.45, 0.55, 0.38), (0.70, 0.15, 0.4), (0.05, 0.90, 0.35)],
        [(0.50, 0.92, 0.5), (0.10, 0.45, 0.5), (0.88, 0.40, 0.55), (0.45, 0.10, 0.45), (0.65, 0.60, 0.3)],
    ][i]
    // Warm colors turn olive when shifted toward yellow in the dark, so amber only shifts toward red.
    let shifts: [CGFloat] = id == "personal" ? [-0.01, -0.035, -0.015, -0.025, -0.06] : [0, -0.035, 0.025, -0.02, -0.06]

    // Light: pale wash of the color, soft deeper fields.
    let light = layout.enumerated().map { j, p in
        Blob(x: p.0, y: p.1, r: p.2, c: hsb(c, dh: shifts[j], b: 1, sMul: j == 0 ? 0.8 : 0.6), a: 0.85)
    }
    render(base: hsb(c, s: 0.10, b: 0.98), blobs: light, blur: 90, grain: 0.035, to: "\(outDir)/\(id)-light.heic")

    // Dark: near-black in the color, glowing fields.
    let dark = layout.enumerated().map { j, p in
        Blob(x: p.0, y: p.1, r: p.2, c: hsb(c, dh: shifts[j], b: j == 0 ? 0.78 : 0.55, sMul: 1.2), a: j == 0 ? 0.85 : 0.7)
    }
    render(base: hsb(c, b: 0.07, sMul: 1.0), blobs: dark, blur: 90, grain: 0.045, to: "\(outDir)/\(id)-dark.heic")
}
