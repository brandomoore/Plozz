import Observation
import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#endif

@MainActor
@Observable
public final class SettingsSearchRequest {
    public let targetID: String
    public var revealed = false
    fileprivate var hasMountedAnchor = false

    public init(targetID: String) { self.targetID = targetID }
}

public struct SettingsSearchLanding<Content: View>: View {
    @State private var request: SettingsSearchRequest
    private let content: () -> Content

    public init(targetID: String, @ViewBuilder content: @escaping () -> Content) {
        _request = State(initialValue: SettingsSearchRequest(targetID: targetID))
        self.content = content
    }

    public var body: some View {
        ScrollViewReader { proxy in
            content()
                .environment(request)
                #if os(iOS)
                .environment(\.settingsSearchRowOwnsHighlight, false)
                #endif
                .environment(\.settingsSearchScroll, { id in proxy.scrollTo(id, anchor: .center) })
                .task {
                    await Task.yield()
                    guard !Task.isCancelled, !request.revealed else { return }
                    #if os(iOS)
                    guard !request.hasMountedAnchor else { return }
                    #endif
                    proxy.scrollTo("settings-search-group", anchor: .center)
                    #if os(tvOS)
                    proxy.scrollTo(request.targetID, anchor: .center)
                    #endif
                }
        }
    }
}

private struct SettingsSearchScrollKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}

private extension EnvironmentValues {
    var settingsSearchScroll: (@MainActor (String) -> Void)? {
        get { self[SettingsSearchScrollKey.self] }
        set { self[SettingsSearchScrollKey.self] = newValue }
    }
}

public extension View {
    func settingsSearchAnchor(
        _ id: String, fallbackFor: [String] = [], focusAction: (@MainActor () -> Void)? = nil
    ) -> some View {
        modifier(SettingsSearchAnchor(anchorID: id, fallbackFor: fallbackFor, focusAction: focusAction))
    }

    /// Register the containing native List cell before its lazy controls are created.
    func settingsSearchGroup(_ targets: [String]) -> some View {
        modifier(SettingsSearchGroup(targets: targets))
    }
}

private struct SettingsSearchGroup: ViewModifier {
    let targets: [String]
    @Environment(SettingsSearchRequest.self) private var request: SettingsSearchRequest?

    func body(content: Content) -> some View {
        content.id(request.map { targets.contains($0.targetID) } == true
            ? "settings-search-group" : "settings-search-group-\(targets.joined(separator: "-"))")
    }
}

private struct SettingsSearchAnchor: ViewModifier {
    let anchorID: String
    let fallbackFor: [String]
    var focusAction: (@MainActor () -> Void)?
    @Environment(SettingsSearchRequest.self) private var request: SettingsSearchRequest?
    @Environment(\.settingsSearchScroll) private var scroll
    @FocusState private var focused: Bool
    @State private var highlighted = false
    #if os(iOS)
    @Environment(\.settingsSearchRowOwnsHighlight) private var rowOwnsHighlight
    @State private var isNativeListRow = false
    #endif
    #if os(tvOS)
    @Environment(\.settingsPageContext) private var page
    #endif

    private var id: String {
        guard let target = request?.targetID, fallbackFor.contains(target) else { return anchorID }
        return target
    }

    private var canReveal: Bool {
        #if os(tvOS)
        page?.isCurrent ?? true
        #else
        true
        #endif
    }

    func body(content: Content) -> some View {
        content
            .id(id)
            .onAppear {
                if request?.targetID == id { request?.hasMountedAnchor = true }
            }
            #if os(tvOS)
            .focused($focused)
            #endif
            .background {
                #if os(tvOS)
                if canReveal, let request, request.targetID == id, !request.revealed {
                    SettingsSearchFocusReady {
                        guard canReveal, !request.revealed else { return }
                        if let focusAction { focusAction() }
                        else { focused = true }
                        request.revealed = true
                    }
                }
                #endif
                #if os(iOS)
                if let request, request.targetID == id, !request.revealed {
                    SettingsSearchNativeReveal { nativeListRow in
                        isNativeListRow = nativeListRow
                        request.revealed = true
                        highlighted = true
                    }
                }
                if highlighted, !rowOwnsHighlight, !isNativeListRow {
                    SettingsSearchGlow(shape: RoundedRectangle(cornerRadius: 8))
                }
                #endif
            }
            #if os(iOS)
            .transformPreference(SettingsSearchHighlightKey.self) { $0 = $0 || highlighted }
            .listRowBackground(
                highlighted && isNativeListRow && !rowOwnsHighlight
                    ? SettingsSearchGlow(shape: Rectangle()) : nil
            )
            #endif
            .task(id: canReveal) {
                #if os(tvOS)
                guard canReveal, let request, request.targetID == id, !request.revealed else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                scroll?(id)
                #endif
            }
            #if os(iOS)
            .task(id: highlighted) {
                guard highlighted else { return }
                do { try await Task.sleep(for: .seconds(SettingsSearchGlowMotion.duration)) } catch { return }
                highlighted = false
            }
            #endif
    }
}

#if os(tvOS)
/// Native menus register their focusable view during layout, after SwiftUI's task starts.
private struct SettingsSearchFocusReady: UIViewRepresentable {
    let onReady: @MainActor () -> Void

    func makeUIView(context: Context) -> ReadyView { ReadyView(onReady: onReady) }
    func updateUIView(_ view: ReadyView, context: Context) {
        view.onReady = onReady
        view.setNeedsLayout()
    }

    final class ReadyView: UIView {
        var onReady: @MainActor () -> Void
        private var scheduled = false

        init(onReady: @escaping @MainActor () -> Void) {
            self.onReady = onReady
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard window != nil, bounds.width > 0, bounds.height > 0, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil else { return }
                onReady()
            }
        }
    }
}
#endif

#if os(iOS)
private struct SettingsSearchRowOwnsHighlightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsSearchRowOwnsHighlight: Bool {
        get { self[SettingsSearchRowOwnsHighlightKey.self] }
        set { self[SettingsSearchRowOwnsHighlightKey.self] = newValue }
    }
}

private struct SettingsSearchHighlightKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue() || value
    }
}

enum SettingsSearchGlowMotion {
    static let duration = 3.0

    static func opacity(at time: Double) -> Double {
        func eased(_ value: Double) -> Double {
            let t = min(1, max(0, value))
            return t * t * (3 - 2 * t)
        }
        return eased(time / 0.55) * eased((duration - time) / 0.9)
    }

    static func intensity(at position: Double, time: Double, phase: Double) -> Double {
        let swell = 0.5 + 0.5 * cos(2 * .pi * (position - time * 0.29) + phase)
        let ripple = 0.5 + 0.5 * sin(2 * .pi * (2 * position - time * 0.63) + phase * 1.7)
        return 0.20 + 0.34 * swell + 0.16 * ripple
    }
}

/// Mounted only for the landing cue; the inset glow never spills onto neighboring rows.
struct SettingsSearchGlow<Outline: InsettableShape>: View {
    let shape: Outline
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt = Date()
    @State private var finished = false
    @State private var phase: Double

    init(shape: Outline, phase: Double = .random(in: 0..<(2 * .pi))) {
        self.shape = shape
        _phase = State(initialValue: phase)
    }

    private var animates: Bool {
        !reduceMotion && !reduceTransparency && scenePhase == .active
    }

    var body: some View {
        let neutral = palette.primaryText
        Group {
            if animates {
                GeometryReader { geometry in
                    let bounds = CGRect(origin: .zero, size: geometry.size)
                    let outline = shape.inset(by: 2).path(in: bounds)
                    // Cache equal-distance contour pieces outside the frame-driven closure.
                    let segments = (0..<192).map { index in
                        outline.trimmedPath(from: CGFloat(index) / 192, to: CGFloat(index + 1) / 192)
                    }
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: finished)) { timeline in
                        let time = finished ? SettingsSearchGlowMotion.duration
                            : timeline.date.timeIntervalSince(startedAt)
                        Canvas { context, _ in
                            context.opacity = SettingsSearchGlowMotion.opacity(at: time)
                            context.fill(shape.path(in: bounds), with: .color(neutral.opacity(0.10)))
                            let passes: [(CGFloat, CGFloat)] = [(7, 3), (2, 0.75)]
                            for (width, blur) in passes {
                                context.drawLayer { layer in
                                    layer.addFilter(.blur(radius: blur))
                                    for (index, segment) in segments.enumerated() {
                                        let light = SettingsSearchGlowMotion.intensity(
                                            at: (Double(index) + 0.5) / 192, time: time, phase: phase
                                        )
                                        layer.stroke(
                                            segment, with: .color(neutral.opacity(light)),
                                            style: StrokeStyle(lineWidth: width, lineCap: .butt)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                shape.fill(neutral.opacity(0.10))
                    .overlay { shape.strokeBorder(neutral.opacity(0.5), lineWidth: 1.5) }
            }
        }
            .clipShape(shape)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                do { try await Task.sleep(for: .seconds(SettingsSearchGlowMotion.duration)) } catch { return }
                finished = true
            }
    }
}

/// The row owner draws after padding, rather than expanding a control's bounds by guessed insets.
struct SettingsSearchRowHighlight: ViewModifier {
    let isFirst: Bool
    let isLast: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .backgroundPreferenceValue(SettingsSearchHighlightKey.self) { highlighted in
                if highlighted {
                    SettingsSearchGlow(shape: UnevenRoundedRectangle(
                        topLeadingRadius: isFirst ? cornerRadius : 0,
                        bottomLeadingRadius: isLast ? cornerRadius : 0,
                        bottomTrailingRadius: isLast ? cornerRadius : 0,
                        topTrailingRadius: isFirst ? cornerRadius : 0
                    ))
                }
            }
            // A nested row consumes its highlight so an enclosing row cannot also light up.
            .transformPreference(SettingsSearchHighlightKey.self) { $0 = false }
    }
}

private struct SettingsSearchNativeReveal: UIViewRepresentable {
    let onReveal: (Bool) -> Void

    func makeUIView(context: Context) -> RevealView { RevealView(onReveal: onReveal) }
    func updateUIView(_ view: RevealView, context: Context) { view.setNeedsLayout() }

    final class RevealView: UIView {
        private let onReveal: (Bool) -> Void
        private var revealed = false
        private var revealScheduled = false

        init(onReveal: @escaping (Bool) -> Void) {
            self.onReveal = onReveal
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { setNeedsLayout() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !revealed, !revealScheduled, window != nil, bounds.height > 0 else { return }
            revealScheduled = true
            // Finish the List's group-scroll layout before positioning its nested control.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.revealScheduled = false
                self.revealControl()
            }
        }

        private func revealControl() {
            guard !revealed, window != nil, bounds.height > 0 else { return }
            var ancestor = superview
            var nativeListRow = false
            while let view = ancestor {
                if view is UICollectionViewCell || view is UITableViewCell {
                    nativeListRow = true
                }
                if let scroll = view as? UIScrollView {
                    let rect = convert(bounds, to: scroll)
                    let insets = scroll.adjustedContentInset
                    let visibleHeight = scroll.bounds.height - insets.top - insets.bottom
                    let maximum = max(-insets.top, scroll.contentSize.height - scroll.bounds.height + insets.bottom)
                    let offset = min(max(rect.midY - insets.top - visibleHeight / 2, -insets.top), maximum)
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
                    revealed = true
                    DispatchQueue.main.async { [onReveal, nativeListRow] in onReveal(nativeListRow) }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
#endif
