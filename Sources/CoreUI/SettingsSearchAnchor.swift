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
    @Environment(\.themePalette) private var palette
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
                    RoundedRectangle(cornerRadius: 8).fill(palette.accent.opacity(0.15))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                #endif
            }
            #if os(iOS)
            .preference(key: SettingsSearchHighlightKey.self, value: highlighted)
            .listRowBackground(
                highlighted && isNativeListRow && !rowOwnsHighlight
                    ? palette.accent.opacity(0.15) : nil
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
            .task(id: highlighted) {
                guard highlighted else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                highlighted = false
            }
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

private extension EnvironmentValues {
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

/// The row owner draws after padding, rather than expanding a control's bounds by guessed insets.
struct SettingsSearchRowHighlight: ViewModifier {
    let isFirst: Bool
    let isLast: Bool
    let cornerRadius: CGFloat
    @Environment(\.themePalette) private var palette

    func body(content: Content) -> some View {
        content
            .environment(\.settingsSearchRowOwnsHighlight, true)
            .backgroundPreferenceValue(SettingsSearchHighlightKey.self) { highlighted in
                if highlighted {
                    UnevenRoundedRectangle(
                        topLeadingRadius: isFirst ? cornerRadius : 0,
                        bottomLeadingRadius: isLast ? cornerRadius : 0,
                        bottomTrailingRadius: isLast ? cornerRadius : 0,
                        topTrailingRadius: isFirst ? cornerRadius : 0
                    )
                    .fill(palette.accent.opacity(0.15))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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
