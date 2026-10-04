#if canImport(SwiftUI)
import SwiftUI

/// Smoothly feathers both horizontal edges while leaving vertical overflow alone.
///
/// Shared by cast-credit rails and compact selection rails. The 24-stop
/// smoothstep curve has zero slope at both ends, avoiding the visible crease and
/// banding of a two-stop linear gradient.
/// Independent strengths keep a reached content edge readable without changing
/// the mask's structure or geometry.
public struct HorizontalEdgeFadeMask: View {
    private let fadeWidth: CGFloat
    private let verticalOverhang: CGFloat
    private let leadingStrength: CGFloat
    private let trailingStrength: CGFloat
    @Environment(\.layoutDirection) private var layoutDirection

    public init(
        fadeWidth: CGFloat,
        verticalOverhang: CGFloat = 0,
        leadingStrength: CGFloat = 1,
        trailingStrength: CGFloat = 1
    ) {
        self.fadeWidth = fadeWidth
        self.verticalOverhang = verticalOverhang
        self.leadingStrength = min(max(leadingStrength, 0), 1)
        self.trailingStrength = min(max(trailingStrength, 0), 1)
    }

    public var body: some View {
        HStack(spacing: 0) {
            edgeFade(
                reversed: false,
                strength: layoutDirection == .rightToLeft ? trailingStrength : leadingStrength
            ).frame(width: fadeWidth)
            Color.black
            edgeFade(
                reversed: true,
                strength: layoutDirection == .rightToLeft ? leadingStrength : trailingStrength
            ).frame(width: fadeWidth)
        }
        // Stack and gradient mirroring differed between SDKs; resolve the
        // semantic strengths once, then draw in physical left-to-right space.
        .environment(\.layoutDirection, .leftToRight)
        .padding(.vertical, -verticalOverhang)
    }

    private func edgeFade(reversed: Bool, strength: CGFloat) -> some View {
        let samples = 24
        let stops = (0 ... samples).map { step -> Gradient.Stop in
            let t = Double(step) / Double(samples)
            let eased = t * t * (3 - 2 * t)
            let activeOpacity = reversed ? 1 - eased : eased
            return Gradient.Stop(
                color: .black.opacity(1 - Double(strength) * (1 - activeOpacity)),
                location: t
            )
        }
        return LinearGradient(
            stops: stops,
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// Feathers only the LEADING edge, leaving the trailing edge hard.
///
/// For a rail that scrolls out under fixed chrome (the navigation rail): content
/// has to dissolve on the side it disappears, while the other side keeps the
/// ordinary edge so nothing looks washed out for no reason.
public struct LeadingEdgeFadeMask: View {
    private let fadeWidth: CGFloat
    private let verticalOverhang: CGFloat
    private let horizontalOverhang: CGFloat

    public init(
        fadeWidth: CGFloat,
        verticalOverhang: CGFloat = 0,
        horizontalOverhang: CGFloat = 0
    ) {
        self.fadeWidth = fadeWidth
        self.verticalOverhang = verticalOverhang
        self.horizontalOverhang = horizontalOverhang
    }

    public var body: some View {
        HorizontalEdgeFadeMask(
            fadeWidth: fadeWidth,
            verticalOverhang: verticalOverhang,
            trailingStrength: 0
        )
        // A visible leading fade starts at the row edge by design. When the
        // pinned sidebar hides and fadeWidth reaches zero, extend the opaque mask
        // on BOTH sides so focused-card bloom remains unclipped. Trailing always
        // overhangs because no fade is drawn there.
        .padding(.leading, fadeWidth > 0 ? 0 : -horizontalOverhang)
        .padding(.trailing, -horizontalOverhang)
    }
}

/// Applies pinned-sidebar scroll clearance and fading without touching native
/// navigation styles.
///
/// A mask clips its source even when the visible gradient width is zero. Applying
/// `leadingEdgeFadeMask(fadeWidth: 0)` under native top/sidebar navigation therefore
/// clipped focused cards at the row's left and right bounds despite drawing no fade.
/// Branching in this dedicated view means native content receives no mask at all,
/// while pinned-sidebar content keeps the exact safe-area + feather treatment.
///
/// `verticalOverhang` is the room the row reserves for a focused card's lift and
/// shadow; the mask reaches that far past the row so the lift is never clipped.
///
/// `cardPitch` (a card slot plus the gap after it) keeps the row's cards on
/// their slots. tvOS parks a card it scrolls to against the screen's own safe
/// area and ignores the gutter, so the leftmost card would otherwise stop short
/// of where the first card opened, under the sidebar.
public struct PinnedSidebarLeadingFade<Content: View>: View {
    private let isActive: Bool
    private let inset: CGFloat
    private let verticalOverhang: CGFloat
    private let cardPitch: CGFloat?
    private let content: Content

    public init(
        isActive: Bool,
        inset: CGFloat,
        verticalOverhang: CGFloat = 0,
        cardPitch: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.isActive = isActive
        self.inset = inset
        self.verticalOverhang = verticalOverhang
        self.cardPitch = cardPitch
        self.content = content()
    }

    @ViewBuilder
    public var body: some View {
        // `isActive` is navigation-style state and stays stable across a detail
        // push. Branching on the live inset would replace every wrapped ScrollView
        // when the sidebar hides (64 → 0), losing row offsets and focus on Back.
        if isActive {
            content
                .safeAreaPadding(.leading, inset)
                .modifier(RowSlotParking(pitch: cardPitch))
                // Leave room for the first card's focus lift while fading cards
                // under the sidebar. Only the feather's trailing edge extends
                // into that clearance.
                .mask {
                    Group {
                        if inset > 0 {
                            PinnedSidebarFeather(start: inset)
                        } else {
                            // Detail pages have no sidebar to cover. Keep the
                            // scroll view intact, but let its artwork reach the
                            // screen edge instead of clipping at the safe area.
                            Color.black.ignoresSafeArea(.container, edges: .horizontal)
                        }
                    }
                    .padding(.vertical, -verticalOverhang)
                    .padding(.trailing, -verticalOverhang)
                }
        } else {
            content
        }
    }
}

/// Stops a horizontal row's scrolls on card-slot boundaries, so the leftmost
/// card always sits exactly where the first card opened.
///
/// The focus engine's own scroll aims at the boundary directly. If a scroll
/// still comes to rest between boundaries, the row finishes the move itself.
private struct RowSlotParking: ViewModifier {
    let pitch: CGFloat?
    @State private var position = ScrollPosition(edge: .leading)

    func body(content: Content) -> some View {
        if let pitch, pitch > 0 {
            content
                .scrollPosition($position)
                .scrollTargetBehavior(RowSlotTargets(pitch: pitch))
                .onScrollPhaseChange { _, phase, context in
                    guard phase == .idle else { return }
                    let offset = context.geometry.contentOffset.x
                    // Content offsets start at minus the inset; slots start at zero.
                    let inset = context.geometry.contentInsets.leading
                    let slot = RowSlotTargets.slot(for: offset + inset, pitch: pitch)
                    guard abs(slot - (offset + inset)) > 0.5 else { return }
                    withAnimation(.smooth(duration: 0.3)) {
                        position.scrollTo(x: slot)
                    }
                }
        } else {
            content
        }
    }
}

/// Moves a scroll's target onto the nearest card-slot boundary.
private struct RowSlotTargets: ScrollTargetBehavior {
    let pitch: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.x = Self.slot(for: target.rect.minX, pitch: pitch)
    }

    /// The slot boundary nearest `position`, measured from where the row opened
    /// (zero) in whole card pitches. The engine stops within a gutter's width
    /// of a boundary, well under half a pitch.
    static func slot(for position: CGFloat, pitch: CGFloat) -> CGFloat {
        max(0, (position / pitch).rounded()) * pitch
    }
}

/// Retains a 10% glimpse under the icons, rising to solid near the first card.
/// The same mask carries the floor through the overscan gutter.
private struct PinnedSidebarFeather: View {
    /// Where the first card's slot opens.
    let start: CGFloat

    /// How far a focused first card's lift reaches back from its slot.
    static let lift: CGFloat = 18
    /// The feather's base width, ending faint just past the sidebar's icons.
    static let width: CGFloat = 30
    static let trailingExtension: CGFloat = 18

    var body: some View {
        let clear = max(0, start - Self.lift - Self.width)
        let solid = max(0, start - Self.lift) + Self.trailingExtension
        HStack(spacing: 0) {
            Color.clear.frame(width: clear)
            LinearGradient(
                stops: (0 ... 24).map { step in
                    let t = Double(step) / 24
                    return Gradient.Stop(color: .black.opacity(t * t * (3 - 2 * t)), location: t)
                },
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: solid - clear)
            Color.black
        }
        .background {
            Color.black.opacity(0.1)
                // Native Showcase hosts suppress safe-area propagation. Match
                // their viewport's overflow without shifting the feather.
                .padding(.leading, -160)
                .ignoresSafeArea(.container, edges: .leading)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Smoothly feathers both vertical edges while leaving horizontal overflow alone.
///
/// For a list that scrolls between fixed chrome — the navigation rail's library
/// list, which sits under a section label and above the pinned Settings row.
/// Clipping alone would cut a row mid-glyph at each end; this dissolves it
/// instead, so nothing ever appears to overlap the chrome.
///
/// `horizontalOverhang` widens the mask left and right so a focused row's own
/// lift and shadow are not clipped by it.
public struct VerticalEdgeFadeMask: View {
    private let topFadeHeight: CGFloat
    private let bottomFadeHeight: CGFloat
    private let topStrength: CGFloat
    private let bottomStrength: CGFloat
    private let horizontalOverhang: CGFloat

    /// Feathers both ends by the same amount.
    public init(fadeHeight: CGFloat, horizontalOverhang: CGFloat = 0) {
        topFadeHeight = fadeHeight
        bottomFadeHeight = fadeHeight
        topStrength = 1
        bottomStrength = 1
        self.horizontalOverhang = horizontalOverhang
    }

    /// Feathers each end independently. A fade of `0` leaves that end hard, which
    /// is what a list wants at an end it is not scrolled past — an always-on fade
    /// dims the first or last row for no reason.
    public init(topFade: CGFloat, bottomFade: CGFloat, horizontalOverhang: CGFloat = 0) {
        topFadeHeight = topFade
        bottomFadeHeight = bottomFade
        topStrength = 1
        bottomStrength = 1
        self.horizontalOverhang = horizontalOverhang
    }

    /// Feathers both ends over a fixed distance while independently varying how
    /// strongly each fade is applied. Keeping the geometry fixed avoids replacing
    /// mask subtrees as a scroll view reaches either edge.
    public init(
        fadeHeight: CGFloat,
        topStrength: CGFloat,
        bottomStrength: CGFloat,
        horizontalOverhang: CGFloat = 0
    ) {
        topFadeHeight = fadeHeight
        bottomFadeHeight = fadeHeight
        self.topStrength = min(max(topStrength, 0), 1)
        self.bottomStrength = min(max(bottomStrength, 0), 1)
        self.horizontalOverhang = horizontalOverhang
    }

    public var body: some View {
        VStack(spacing: 0) {
            edgeFade(reversed: false, strength: topStrength)
                .frame(height: topFadeHeight)
            Color.black
            edgeFade(reversed: true, strength: bottomStrength)
                .frame(height: bottomFadeHeight)
        }
        .padding(.horizontal, -horizontalOverhang)
    }

    private func edgeFade(reversed: Bool, strength: CGFloat) -> some View {
        let samples = 24
        let stops = (0 ... samples).map { step -> Gradient.Stop in
            let t = Double(step) / Double(samples)
            let eased = t * t * (3 - 2 * t)
            let activeOpacity = reversed ? 1 - eased : eased
            let opacity = 1 - Double(strength) * (1 - activeOpacity)
            return Gradient.Stop(
                color: .black.opacity(opacity),
                location: t
            )
        }
        return LinearGradient(
            stops: stops,
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

public extension View {
    /// Feathers the top and bottom edges. `horizontalOverhang` expands the mask
    /// left and right so a focused row's lift and shadow are not clipped by it.
    func verticalEdgeFadeMask(
        fadeHeight: CGFloat,
        horizontalOverhang: CGFloat = 0
    ) -> some View {
        mask {
            VerticalEdgeFadeMask(
                fadeHeight: fadeHeight,
                horizontalOverhang: horizontalOverhang
            )
        }
    }

    /// Feathers each end independently, so a list only dissolves at an end it is
    /// actually scrolled past.
    func verticalEdgeFadeMask(
        topFade: CGFloat,
        bottomFade: CGFloat,
        horizontalOverhang: CGFloat = 0
    ) -> some View {
        mask {
            VerticalEdgeFadeMask(
                topFade: topFade,
                bottomFade: bottomFade,
                horizontalOverhang: horizontalOverhang
            )
        }
    }

    /// Feathers both edges using continuously variable strengths over fixed mask
    /// geometry. A strength of `0` is fully opaque; `1` applies the full dissolve.
    func verticalEdgeFadeMask(
        fadeHeight: CGFloat,
        topStrength: CGFloat,
        bottomStrength: CGFloat,
        horizontalOverhang: CGFloat = 0
    ) -> some View {
        mask {
            VerticalEdgeFadeMask(
                fadeHeight: fadeHeight,
                topStrength: topStrength,
                bottomStrength: bottomStrength,
                horizontalOverhang: horizontalOverhang
            )
        }
    }

    /// Feathers the leading edge only. `verticalOverhang` expands the mask above
    /// and below so a focused card's lift and shadow are not clipped by it.
    func leadingEdgeFadeMask(
        fadeWidth: CGFloat,
        verticalOverhang: CGFloat = 0,
        horizontalOverhang: CGFloat = 0
    ) -> some View {
        mask {
            LeadingEdgeFadeMask(
                fadeWidth: fadeWidth,
                verticalOverhang: verticalOverhang,
                horizontalOverhang: horizontalOverhang
            )
        }
    }

    func horizontalEdgeFadeMask(
        fadeWidth: CGFloat,
        verticalOverhang: CGFloat = 0,
        leadingStrength: CGFloat = 1,
        trailingStrength: CGFloat = 1
    ) -> some View {
        mask {
            HorizontalEdgeFadeMask(
                fadeWidth: fadeWidth,
                verticalOverhang: verticalOverhang,
                leadingStrength: leadingStrength,
                trailingStrength: trailingStrength
            )
        }
    }
}
#endif
