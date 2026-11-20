import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Reserves a view's final geometry while its content is still loading.
///
/// Loading placeholders exist for two different jobs, and mixing them up is what
/// produced the reflows this exists to prevent:
///
/// 1. **Reserve the space** so the page does not jump when real content arrives.
/// 2. **Signal that something is happening**, which is only worth showing when the
///    viewer asked for it (a filter change, a season switch) or the wait is long.
///
/// A placeholder that is *only* the second thing leaves a zero-height hole and
/// reflows the page; one that is always visible flashes on every load. So the
/// placeholder is **always laid out** while pending (`isPending`), and
/// `revealsPlaceholder` decides only whether it is painted. Neither decision may
/// be driven by elapsed time — see `docs/swiftui-guidelines.md`.
///
/// ```swift
/// PlozzReservedPlaceholder(
///     isPending: episodes == nil,
///     revealsPlaceholder: viewerChangedSeason
/// ) {
///     EpisodeSkeletonRail()          // real card height
/// } content: {
///     EpisodeRail(episodes)
/// }
/// ```
public struct PlozzReservedPlaceholder<Placeholder: View, Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let isPending: Bool
    private let revealsPlaceholder: Bool
    private let placeholder: Placeholder
    private let content: Content

    public init(
        isPending: Bool,
        revealsPlaceholder: Bool = false,
        @ViewBuilder placeholder: () -> Placeholder,
        @ViewBuilder content: () -> Content
    ) {
        self.isPending = isPending
        self.revealsPlaceholder = revealsPlaceholder
        self.placeholder = placeholder()
        self.content = content()
    }

    public var body: some View {
        Group {
            if isPending {
                placeholder
                    // Laid out either way: `.opacity` keeps the placeholder's real
                    // height, which is the whole point of reserving it.
                    .opacity(revealsPlaceholder ? 1 : 0)
                    .accessibilityHidden(!revealsPlaceholder)
                    .transition(.opacity)
            } else {
                content
                    .transition(.opacity)
            }
        }
        // Content arrives underneath the viewer without moving the page; a short
        // fade keeps it from snapping in. Nothing here gates hit testing.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: isPending)
    }
}

/// Reveals one presentation group once its initial content is ready.
/// Later refreshes update in place without replaying the entrance.
public struct PlozzFadeInOnAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    #if os(iOS)
    @State private var pageHasAppeared = false
    #endif
    private let duration: Double
    private let isReady: Bool
    private let hasRevealed: Binding<Bool>?

    public init(duration: Double = 0.24, isReady: Bool = true, hasRevealed: Binding<Bool>? = nil) {
        self.duration = duration
        self.isReady = isReady
        self.hasRevealed = hasRevealed
        _visible = State(initialValue: hasRevealed?.wrappedValue ?? false)
    }

    private var canReveal: Bool {
        #if os(iOS)
        isReady && pageHasAppeared
        #else
        isReady
        #endif
    }

    public func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            #if os(iOS)
            .plozzOnPageAppearanceChange { pageHasAppeared = $0 }
            #endif
            .task(id: canReveal) {
                guard canReveal, !visible, !Task.isCancelled else { return }
                if reduceMotion {
                    reveal()
                } else {
                    withAnimation(.easeOut(duration: duration)) { reveal() }
                }
            }
            .onChange(of: hasRevealed?.wrappedValue) { _, revealed in
                if revealed == true, !visible { visible = true }
            }
    }

    private func reveal() {
        visible = true
        hasRevealed?.wrappedValue = true
    }
}

#if os(iOS)
private struct PlozzPageAppearanceReader: UIViewControllerRepresentable {
    let startsDuringTransition: Bool
    let onChange: (Bool) -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.startsDuringTransition = startsDuringTransition
        controller.onChange = onChange
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.startsDuringTransition = startsDuringTransition
        controller.onChange = onChange
    }

    final class Controller: UIViewController {
        var startsDuringTransition = false
        var onChange: ((Bool) -> Void)?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onChange?(true)
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            onChange?(startsDuringTransition)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            onChange?(false)
        }
    }
}
#endif

public extension View {
    #if os(iOS)
    /// Reports native entry completion (or entry start when requested), and leaving the page.
    func plozzOnPageAppearanceChange(
        startsDuringTransition: Bool = false,
        perform: @escaping (Bool) -> Void
    ) -> some View {
        background {
            PlozzPageAppearanceReader(startsDuringTransition: startsDuringTransition, onChange: perform)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
    #endif

    func plozzFadeInOnAppear(
        duration: Double = 0.24, isReady: Bool = true, hasRevealed: Binding<Bool>? = nil
    ) -> some View {
        modifier(PlozzFadeInOnAppear(duration: duration, isReady: isReady, hasRevealed: hasRevealed))
    }
}
