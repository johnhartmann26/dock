import AppKit
import SwiftUI

/// Context symbols: any SF Symbol name, plus a few drawn here that SF Symbols doesn't have.
enum Glyph {
    /// Template image for the menu bar and anywhere AppKit wants an NSImage.
    static func image(_ name: String, pointSize: CGFloat) -> NSImage? {
        if let path = custom[name] {
            let side = pointSize * 1.15
            let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                let t = AffineTransform(scale: rect.width / 16)
                let p = path()
                p.transform(using: t)
                NSColor.black.setFill()
                p.fill()
                return true
            }
            img.isTemplate = true
            return img
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
    }

    static func isCustom(_ name: String) -> Bool { custom[name] != nil }

    /// Shapes on a 16×16 grid, y up.
    private static let custom: [String: () -> NSBezierPath] = ["robot": robot]

    /// A friendly robot head: visor eyes, a small smile, an antenna with a ball.
    private static func robot() -> NSBezierPath {
        let p = NSBezierPath()
        p.windingRule = .evenOdd
        p.append(NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.0, width: 13, height: 10), xRadius: 3.6, yRadius: 3.6))
        p.append(NSBezierPath(roundedRect: NSRect(x: 4.0, y: 5.4, width: 3.0, height: 2.0), xRadius: 1, yRadius: 1))
        p.append(NSBezierPath(roundedRect: NSRect(x: 9.0, y: 5.4, width: 3.0, height: 2.0), xRadius: 1, yRadius: 1))
        p.append(NSBezierPath(roundedRect: NSRect(x: 6.3, y: 2.9, width: 3.4, height: 1.1), xRadius: 0.55, yRadius: 0.55))
        p.append(NSBezierPath(roundedRect: NSRect(x: 7.35, y: 10.6, width: 1.3, height: 2.6), xRadius: 0.65, yRadius: 0.65))
        p.append(NSBezierPath(ovalIn: NSRect(x: 6.4, y: 12.6, width: 3.2, height: 3.2)))
        return p
    }
}

/// A context's symbol in SwiftUI, tinted by the surrounding foreground style.
struct ContextSymbol: View {
    let name: String
    let size: CGFloat

    var body: some View {
        if Glyph.isCustom(name), let img = Glyph.image(name, pointSize: size) {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .frame(width: size * 1.15, height: size * 1.15)
        } else {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
        }
    }
}
