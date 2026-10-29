import SwiftUI

/// What the Dock shows. The engine owns the truth; this mirrors it for the UI.
@MainActor
final class DockState: ObservableObject {
    @Published var config: DockConfig
    @Published var current: String
    @Published var running: Set<String> = []
    /// Apps shown for `current`.
    @Published var shownApps: [DockApp] = []
    /// Apps with windows open in `current` that aren't in its Dock, shown after a divider like the
    /// macOS Dock's recent apps.
    @Published var openApps: [DockApp] = []
    private var tiles: [String: DockApp] = [:]

    var onSelect: (String) -> Void = { _ in }
    var onOpenApp: (String) -> Void = { _ in }
    var onMenuForApp: (String) -> NSMenu? = { _ in nil }
    var onSetPinned: ([String]) -> Void = { _ in }

    /// An icon being dragged: from the pinned apps (reorder, or drag out to remove) or from the
    /// open apps (drop among the pinned ones to keep it).
    struct Drag: Equatable {
        var bundleID: String
        var fromPinned: Bool
        var index: Int
        var start: CGPoint
        var translation: CGSize
        var location: CGPoint { CGPoint(x: start.x + translation.width, y: start.y + translation.height) }
    }
    @Published var drag: Drag?
    /// Where the pinned icons sit, in the bar's coordinates.
    var pinnedFrame: CGRect = .zero
    static let step = DockMetrics.icon + 7
    /// Dragged this far up, a pinned icon is removed on release.
    static let removeLift: CGFloat = 36

    var removing: Bool { drag.map { $0.fromPinned && $0.translation.height < -Self.removeLift } ?? false }

    /// Where the dragged icon would land among the pinned ones (an index into the pinned list
    /// without it), or nil when it's outside them or being removed.
    var dropIndex: Int? {
        guard let d = drag, !removing else { return nil }
        let x = d.location.x
        guard x > pinnedFrame.minX - Self.step / 2, x < pinnedFrame.maxX + Self.step / 2 else { return nil }
        let count = shownApps.count - (d.fromPinned ? 1 : 0)
        return min(max(Int(((x - pinnedFrame.minX) / Self.step).rounded(.down)), 0), count)
    }

    /// How far a pinned icon moves aside to make room for the dragged one.
    func shift(ofPinned k: Int) -> CGFloat {
        guard let d = drag else { return 0 }
        if d.fromPinned {
            if k == d.index { return 0 }
            let p = k < d.index ? k : k - 1          // its place without the dragged icon
            let shown = dropIndex.map { p >= $0 ? p + 1 : p } ?? p
            return CGFloat(shown - k) * Self.step
        }
        guard let j = dropIndex else { return 0 }
        return k >= j ? Self.step : 0
    }

    func endDrag() {
        guard let d = drag else { return }
        var apps = shownApps.map(\.bundleID)
        let target = dropIndex
        if d.fromPinned {
            apps.remove(at: d.index)
            if let j = target { apps.insert(d.bundleID, at: j) }
        } else if let j = target {
            apps.insert(d.bundleID, at: j)
        }
        withAnimation(DockMotion.switch) { drag = nil }
        if apps != shownApps.map(\.bundleID) { onSetPinned(apps) }
    }

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
    func show(_ id: String, open: [String]) {
        let tiles = open.compactMap(tile)
        guard id != current else {
            if tiles.map(\.id) != openApps.map(\.id) { withAnimation(DockMotion.switch) { openApps = tiles } }
            return
        }
        withAnimation(DockMotion.switch) {
            current = id
            shownApps = Self.apps(for: id, in: config)
            openApps = tiles
        }
    }

    /// Icons are looked up once per app.
    private func tile(_ bundleID: String) -> DockApp? {
        if let t = tiles[bundleID] { return t }
        let t = DockApp(bundleID: bundleID)
        tiles[bundleID] = t
        return t
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
                        .draggableTile(state: state, bundleID: app.bundleID, pinned: true, index: index)
                        .offset(x: state.shift(ofPinned: index))
                        .transition(.asymmetric(insertion: .tileIn(index), removal: .tileOut))
                }
            }
            .frame(minWidth: DockMetrics.icon, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.onAppear { state.pinnedFrame = g.frame(in: .named("bar")) }
                    .onChange(of: g.frame(in: .named("bar"))) { _, f in state.pinnedFrame = f }
            })
            .animation(.easeOut(duration: 0.16), value: state.drag)
            if !state.openApps.isEmpty {
                Rectangle()
                    .fill(.primary.opacity(0.16))
                    .frame(width: 1, height: 30)
                    .padding(.horizontal, 11)
                    .transition(.opacity)
                HStack(spacing: 7) {
                    ForEach(Array(state.openApps.enumerated()), id: \.element.id) { index, app in
                        AppTile(app: app, running: true,
                                open: { state.onOpenApp(app.bundleID) },
                                menu: { state.onMenuForApp(app.bundleID) })
                            .draggableTile(state: state, bundleID: app.bundleID, pinned: false, index: index)
                            .transition(.asymmetric(insertion: .tileIn(index), removal: .tileOut))
                    }
                }
            }
        }
        .coordinateSpace(name: "bar")
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

extension View {
    /// Drag an icon: sideways to reorder or move between the open and pinned apps, up and out of
    /// the bar to remove a pinned one. A click is still a click (it takes 5pt of movement to drag).
    func draggableTile(state: DockState, bundleID: String, pinned: Bool, index: Int) -> some View {
        let dragging = state.drag?.bundleID == bundleID
        return self
            .offset(dragging ? state.drag!.translation : .zero)
            .scaleEffect(dragging ? 1.1 : 1, anchor: .bottom)
            .opacity(dragging && state.removing ? 0.35 : 1)
            .overlay(alignment: .top) {
                if dragging && state.removing {
                    Text("Remove")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Frosted(cornerRadius: 10))
                        .fixedSize()
                        .offset(y: state.drag!.translation.height - 26)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(dragging ? 2 : 0)
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("bar"))
                    .onChanged { v in
                        if state.drag?.bundleID != bundleID {
                            state.drag = .init(bundleID: bundleID, fromPinned: pinned, index: index,
                                               start: v.startLocation, translation: v.translation)
                        } else {
                            state.drag?.translation = v.translation
                        }
                    }
                    .onEnded { _ in state.endDrag() }
            )
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

/// Plain glass picks up the colors behind it: in light mode it looked dark over anything but a
/// white page, and in dark mode light over anything but a dark one. So it's tinted toward the
/// mode: white in light mode, black in dark mode, like the macOS Dock.
@available(macOS 26.0, *)
final class DockGlassView: NSGlassEffectView {
    static let lightTint = NSColor.white.withAlphaComponent(0.6)
    static let darkTint = NSColor.black.withAlphaComponent(0.45)

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    func applyTint() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        tintColor = dark ? Self.darkTint : Self.lightTint
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
