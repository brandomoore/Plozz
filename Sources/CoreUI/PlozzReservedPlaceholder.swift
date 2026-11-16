import SwiftUI

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

/// Fades a section in when it first appears. Used for content that arrives from
/// its own network round trip (cast, extras, related) so it joins the page
/// smoothly instead of snapping into place, while the page stays interactive.
public struct PlozzFadeInOnAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    private let duration: Double

    public init(duration: Double = 0.24) {
        self.duration = duration
    }

    public func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            // `.task` runs after the first rendered frame, so the 0-opacity state
            // is actually painted before the fade starts. `.onAppear` could run
            // during the push and finish the fade while the section was offscreen,
            // which is why the sections appeared to snap in.
            .task {
                guard !visible else { return }
                if reduceMotion {
                    visible = true
                } else {
                    withAnimation(.easeOut(duration: duration)) { visible = true }
                }
            }
    }
}

public extension View {
    func plozzFadeInOnAppear(duration: Double = 0.24) -> some View {
        modifier(PlozzFadeInOnAppear(duration: duration))
    }
}
