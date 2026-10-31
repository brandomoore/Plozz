import Observation
import SwiftUI
#if os(iOS)
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
    func settingsSearchAnchor(_ id: String, focusAction: (@MainActor () -> Void)? = nil) -> some View {
        modifier(SettingsSearchAnchor(id: id, focusAction: focusAction))
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
    let id: String
    var focusAction: (@MainActor () -> Void)?
    @Environment(SettingsSearchRequest.self) private var request: SettingsSearchRequest?
    @Environment(\.settingsSearchScroll) private var scroll
    @Environment(\.themePalette) private var palette
    @FocusState private var focused: Bool
    @State private var highlighted = false
    #if os(tvOS)
    @Environment(\.settingsPageContext) private var page
    #endif

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
                #if os(iOS)
                if let request, request.targetID == id, !request.revealed {
                    SettingsSearchNativeReveal {
                        request.revealed = true
                        highlighted = true
                    }
                }
                if highlighted {
                    RoundedRectangle(cornerRadius: 8).fill(palette.accent.opacity(0.15))
                        .accessibilityHidden(true)
                }
                #endif
            }
            .task(id: canReveal) {
                #if os(tvOS)
                guard canReveal, let request, request.targetID == id, !request.revealed else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                scroll?(id)
                if let focusAction { focusAction() }
                else { focused = true }
                request.revealed = true
                #endif
            }
            .task(id: highlighted) {
                guard highlighted else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                highlighted = false
            }
    }
}

#if os(iOS)
private struct SettingsSearchNativeReveal: UIViewRepresentable {
    let onReveal: () -> Void

    func makeUIView(context: Context) -> RevealView { RevealView(onReveal: onReveal) }
    func updateUIView(_ view: RevealView, context: Context) { view.setNeedsLayout() }

    final class RevealView: UIView {
        private let onReveal: () -> Void
        private var revealed = false
        private var revealScheduled = false

        init(onReveal: @escaping () -> Void) {
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
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    let rect = convert(bounds, to: scroll)
                    let insets = scroll.adjustedContentInset
                    let visibleHeight = scroll.bounds.height - insets.top - insets.bottom
                    let maximum = max(-insets.top, scroll.contentSize.height - scroll.bounds.height + insets.bottom)
                    let offset = min(max(rect.midY - insets.top - visibleHeight / 2, -insets.top), maximum)
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
                    revealed = true
                    DispatchQueue.main.async { [onReveal] in onReveal() }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
#endif
