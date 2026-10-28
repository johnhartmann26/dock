import SwiftUI

/// What the Dock shows. The engine owns the truth; this mirrors it for the UI.
@MainActor
final class DockState: ObservableObject {
    @Published var config: DockConfig
    @Published var current: String
    @Published var running: Set<String> = []
    /// Apps shown for `current`.
    @Published var shownApps: [DockApp] = []

    var onSelect: (String) -> Void = { _ in }
    var onOpenApp: (String) -> Void = { _ in }
    var onMenuForApp: (String) -> NSMenu? = { _ in nil }

    init(config: DockConfig, current: String) {
        self.config = config
        self.current = current
        self.shownApps = Self.apps(for: current, in: config)
    }

    var currentContext: DockContext? { config.contexts.first { $0.id == current } }

    static func apps(for id: String, in config: DockConfig) -> [DockApp] {
        (config.contexts.first { $0.id == id }?.apps ?? []).compactMap(DockApp.init(bundleID:))
    }

    /// Called by the engine after a switch, from whatever source (Dock, hotkey, focus).
    /// The bar stays open: icons cross-fade in place and the bar glides to its new width.
    /// Apps that are in both contexts (Dia in Work and Personal) keep their tile.
    func show(_ id: String) {
        guard id != current else { return }
        withAnimation(DockMotion.switch) {
            current = id
            shownApps = Self.apps(for: id, in: config)
        }
    }

    func reloadApps() {
        shownApps = Self.apps(for: current, in: config)
    }
}

/// Lets the gallery show hover states without a mouse.
private struct ForcedHoverKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var forcedHover: String? {
        get { self[ForcedHoverKey.self] }
        set { self[ForcedHoverKey.self] = newValue }
    }
}

enum DockMetrics {
    static let icon: CGFloat = 40
    static let control: CGFloat = 30
    /// Width of the selected context's pill.
    static let pill: CGFloat = 42
    static let corner: CGFloat = 21
    static let bottomGap: CGFloat = 8
    static let padV: CGFloat = 7
    static let panelHeight: CGFloat = 120   // room above the bar for the hover label
    /// Bar height: padding, icon, the 3pt gap and the 4pt running dot.
    static let barHeight: CGFloat = padV * 2 + icon + 3 + 4
    /// The strip at the bottom of the screen that windows are kept out of (bar, gap below, a little air).
    static let reserved: CGFloat = bottomGap + barHeight + 6
}

struct DockView: View {
    @ObservedObject var state: DockState
    @Namespace private var pill

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            bar
                .padding(.bottom, DockMetrics.bottomGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(state.config.contexts) { ctx in
                    ModeButton(context: ctx, selected: ctx.id == state.current, namespace: pill) {
                        state.onSelect(ctx.id)
                    }
                    // The sliding pill belongs to the selected button; keep it above the buttons it passes.
                    .zIndex(ctx.id == state.current ? 1 : 0)
                }
            }
            Rectangle()
                .fill(.primary.opacity(0.16))
                .frame(width: 1, height: 30)
                .padding(.horizontal, 11)
            HStack(spacing: 7) {
                ForEach(Array(state.shownApps.enumerated()), id: \.element.id) { index, app in
                    AppTile(app: app, running: state.running.contains(app.bundleID),
                            open: { state.onOpenApp(app.bundleID) },
                            menu: { state.onMenuForApp(app.bundleID) })
                        .transition(.asymmetric(insertion: .tileIn(index), removal: .tileOut))
                }
            }
            .frame(minWidth: DockMetrics.icon, alignment: .leading)
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .padding(.vertical, DockMetrics.padV)
        .background(DockGlass(cornerRadius: DockMetrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: DockMetrics.corner, style: .continuous)
                .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
        .animation(DockMotion.switch, value: state.current)
    }
}

/// A context control: a quiet circle, or a filled pill when selected. No name in the pill, so the
/// Dock stays narrow and keeps its width when you switch; the name shows above it on hover, like apps.
private struct ModeButton: View {
    let context: DockContext
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var mouseOver = false
    @State private var pressed = false
    @Environment(\.forcedHover) private var forced
    private var hover: Bool { mouseOver || forced == context.id }

    var body: some View {
        Button(action: action) {
            ContextSymbol(name: context.symbol, size: 12.5)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(hover ? 0.9 : 0.55)))
                .frame(width: selected ? DockMetrics.pill : DockMetrics.control, height: DockMetrics.control)
                .background {
                    if selected {
                        Capsule().fill(context.tint)
                            .matchedGeometryEffect(id: "pill", in: namespace)
                            // Arrive solid and slide; the old pill just drops out (no orange/purple cross-fade).
                            .transition(.asymmetric(insertion: .identity, removal: .quickExit))
                    } else {
                        Circle().fill(.primary.opacity(hover ? 0.16 : 0.07))
                    }
                }
                .contentShape(Capsule())
                .scaleEffect(pressed ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if hover {
                Text("\(context.name)  ⌃⌥\(context.key)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Frosted(cornerRadius: 12))
                    .fixedSize()
                    .offset(y: -39)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                    .allowsHitTesting(false)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { mouseOver = h } }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
            .onEnded { _ in withAnimation(.spring(response: 0.25)) { pressed = false } })
    }
}

private struct AppTile: View {
    let app: DockApp
    let running: Bool
    let open: () -> Void
    let menu: () -> NSMenu?
    @State private var mouseOver = false
    @Environment(\.forcedHover) private var forced
    private var hover: Bool { mouseOver || forced == app.bundleID }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: DockMetrics.icon, height: DockMetrics.icon)
                .scaleEffect(hover ? 1.08 : 1, anchor: .bottom)
                .offset(y: hover ? -2 : 0)
            Circle()
                .fill(.primary.opacity(running ? 0.75 : 0))
                .frame(width: 4, height: 4)
        }
        .overlay(alignment: .top) {
            if hover {
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Frosted(cornerRadius: 12))
                    .fixedSize()
                    .offset(y: -32)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { mouseOver = h } }
        .onTapGesture(perform: open)
        .contextMenu {
            // SwiftUI can't host an NSMenu directly; mirror its items.
            if let m = menu() {
                ForEach(Array(m.items.enumerated()), id: \.offset) { _, item in
                    if item.isSeparatorItem { Divider() } else {
                        Button(item.title) {
                            if let a = item.action { NSApp.sendAction(a, to: item.target, from: item) }
                        }.disabled(!item.isEnabled)
                    }
                }
            }
        }
    }
}

/// The Dock's background: Liquid Glass like the macOS 26 Dock, so what's behind shows through.
/// AppKit's glass view just resizes when the Dock's width changes (SwiftUI's `glassEffect` fades
/// out while it re-morphs). Frosted blur before macOS 26.
struct DockGlass: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let g = DockGlassView()
            g.cornerRadius = cornerRadius
            g.style = .regular
            g.applyTint()
            return g
        }
        return Frosted.make(cornerRadius: cornerRadius, material: Frosted.dockMaterial, alpha: 1)
    }

    func updateNSView(_ v: NSView, context: Context) {
        if #available(macOS 26.0, *), let g = v as? NSGlassEffectView { g.cornerRadius = cornerRadius }
    }
}

/// Plain glass picks up the colors behind it, so in light mode it looked dark over anything but a
/// white page. In light mode it gets a white tint so it reads as light frosted glass, like the
/// light macOS Dock; dark mode is left as plain glass.
@available(macOS 26.0, *)
final class DockGlassView: NSGlassEffectView {
    static let lightTint = NSColor.white.withAlphaComponent(0.6)

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    func applyTint() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        tintColor = dark ? nil : Self.lightTint
    }
}

/// Frosted blur of whatever is behind the window, light or dark with the system like the macOS Dock. Liquid Glass
/// (`glassEffect`) fades to half opacity while it re-morphs during a width change, so it isn't used here.
struct Frosted: NSViewRepresentable {
    var cornerRadius: CGFloat
    var material: NSVisualEffectView.Material = Frosted.dockMaterial
    var alpha: CGFloat = 1

    static var dockMaterial: NSVisualEffectView.Material = .menu

    func makeNSView(context: Context) -> NSVisualEffectView {
        Self.make(cornerRadius: cornerRadius, material: material, alpha: alpha)
    }

    static func make(cornerRadius: CGFloat, material: NSVisualEffectView.Material, alpha: CGFloat) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.alphaValue = alpha
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.layer?.cornerRadius = cornerRadius
    }
}

/// One curve for the whole switch: quick to start, settles softly, no bounce.
enum DockMotion {
    static let `switch` = Animation.smooth(duration: 0.32)
}

extension AnyTransition {
    /// New icon: fades and rises in a beat after the old one starts leaving, staggered left to right.
    static func tileIn(_ index: Int) -> AnyTransition {
        AnyTransition.opacity
            .combined(with: .scale(scale: 0.88, anchor: .bottom))
            .combined(with: .offset(y: 4))
            .animation(.smooth(duration: 0.26).delay(0.06 + Double(index) * 0.018))
    }

    /// Old icon: fades and settles down slightly where it stands.
    static var tileOut: AnyTransition {
        AnyTransition.opacity
            .combined(with: .scale(scale: 0.92, anchor: .bottom))
            .animation(.easeOut(duration: 0.14))
    }

    /// Gone in 50ms regardless of the surrounding animation. `.identity` would keep a removed view
    /// fully visible until the whole switch animation finishes.
    static var quickExit: AnyTransition { .opacity.animation(.easeOut(duration: 0.05)) }
}
