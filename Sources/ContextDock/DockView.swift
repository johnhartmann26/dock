import SwiftUI

/// What the Dock shows. The engine owns the truth; this mirrors it for the UI.
@MainActor
final class DockState: ObservableObject {
    @Published var config: DockConfig
    @Published var current: String
    @Published var running: Set<String> = []
    /// Apps shown for `current`, filled one by one so a switch cascades in like the reference video.
    @Published var shownApps: [DockApp] = []

    var onSelect: (String) -> Void = { _ in }
    var onOpenApp: (String) -> Void = { _ in }
    var onMenuForApp: (String) -> NSMenu? = { _ in nil }

    private var cascade: Task<Void, Never>?

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
    func show(_ id: String) {
        guard id != current else { return }
        current = id
        let target = Self.apps(for: id, in: config)
        cascade?.cancel()
        withAnimation(.easeOut(duration: 0.07)) { shownApps = [] }
        cascade = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            for app in target {
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { shownApps.append(app) }
                try? await Task.sleep(for: .milliseconds(18))
            }
        }
    }

    func reloadApps() {
        cascade?.cancel()
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
    static let icon: CGFloat = 46
    static let control: CGFloat = 34
    static let corner: CGFloat = 24
    static let bottomGap: CGFloat = 8
    static let panelHeight: CGFloat = 132   // room above the bar for the hover label
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
        .environment(\.colorScheme, .dark)
    }

    private var bar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(state.config.contexts) { ctx in
                    ModeButton(context: ctx, selected: ctx.id == state.current, namespace: pill) {
                        state.onSelect(ctx.id)
                    }
                }
            }
            Rectangle()
                .fill(.white.opacity(0.16))
                .frame(width: 1, height: 34)
                .padding(.horizontal, 12)
            HStack(spacing: 8) {
                ForEach(state.shownApps) { app in
                    AppTile(app: app, running: state.running.contains(app.bundleID),
                            open: { state.onOpenApp(app.bundleID) },
                            menu: { state.onMenuForApp(app.bundleID) })
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.55).combined(with: .opacity),
                            removal: .quickExit))
                }
            }
            .frame(minWidth: DockMetrics.icon, alignment: .leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(Frosted(cornerRadius: DockMetrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: DockMetrics.corner, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: state.current)
        .animation(.spring(response: 0.22, dampingFraction: 0.88), value: state.shownApps.count)
    }
}

/// A context control: a quiet circle, or a filled pill with its name when selected.
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
            HStack(spacing: 7) {
                Image(systemName: context.symbol)
                    .font(.system(size: 14, weight: .semibold))
                if selected {
                    Text(context.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .fixedSize()
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.12).delay(0.11)),
                                                removal: .quickExit))
                }
            }
            .foregroundStyle(selected ? .white : .white.opacity(hover ? 0.9 : 0.55))
            .padding(.horizontal, selected ? 14 : 0)
            .frame(minWidth: DockMetrics.control, minHeight: DockMetrics.control)
            .background {
                if selected {
                    Capsule().fill(context.tint)
                        .matchedGeometryEffect(id: "pill", in: namespace)
                        // Arrive solid and slide; the old pill just drops out (no orange/purple cross-fade).
                        .transition(.asymmetric(insertion: .identity, removal: .quickExit))
                } else {
                    Circle().fill(.white.opacity(hover ? 0.16 : 0.07))
                }
            }
            .contentShape(Capsule())
            .scaleEffect(pressed ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { mouseOver = h } }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.easeOut(duration: 0.08)) { pressed = true } }
            .onEnded { _ in withAnimation(.spring(response: 0.25)) { pressed = false } })
        .help("\(context.name)  ⌃⌥\(context.key)")
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
                .fill(.white.opacity(running ? 0.75 : 0))
                .frame(width: 4, height: 4)
        }
        .overlay(alignment: .top) {
            if hover {
                Text(app.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Frosted(cornerRadius: 12))
                    .fixedSize()
                    .offset(y: -36)
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

/// Dark frosted blur of whatever is behind the window, like the reference Dock. Liquid Glass
/// (`glassEffect`) fades to half opacity while it re-morphs during a width change, so it isn't used here.
struct Frosted: NSViewRepresentable {
    var cornerRadius: CGFloat
    var material: NSVisualEffectView.Material = Frosted.dockMaterial
    var alpha: CGFloat = 1

    static var dockMaterial: NSVisualEffectView.Material = .menu

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.appearance = NSAppearance(named: .darkAqua)
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

extension AnyTransition {
    /// Gone in 50ms regardless of the surrounding animation. `.identity` would keep a removed view
    /// fully visible until the whole switch animation finishes.
    static var quickExit: AnyTransition { .opacity.animation(.easeOut(duration: 0.05)) }
}
