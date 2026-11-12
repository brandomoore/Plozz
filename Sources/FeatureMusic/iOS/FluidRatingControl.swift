// Adapted from brandomoore/Mozz at 58dab0015d09a4978f2c484e072d1bc0e30f69dc.
// Copyright (C) 2026 Mozz contributors. GPL-3.0-only with Apple distribution permission.
// See Mozz-NOTICE.txt. Plozz adapters retain the original player motion and geometry.
#if os(iOS)
import SwiftUI
import CoreModels

// MARK: - Tunables
//
// Everything about the fluid rating control's feel lives here so it's cheap to
// iterate on-device. Sizes are points; durations are seconds.
enum RatingTuning {
    static let starCount = 5
    /// Size of a star glyph in the expanded strip (popover + hold-drag reveal).
    static let stripStarSize: CGFloat = 30
    /// Gap between stars in the expanded strip.
    static let stripStarSpacing: CGFloat = 10
    /// Movement (points) past which a press is treated as a drag-to-rate instead
    /// of a tap.
    static let moveSlop: CGFloat = 10
    /// How long the finger must rest on the player star before the strip reveals
    /// and drag-to-rate begins. Short so it feels immediate but still lets a
    /// quick tap open the sticky popover instead.
    static let longPressDuration: Double = 0.18
    /// Vertical offset of the revealed strip above the player star so the finger
    /// doesn't cover it.
    static let revealYOffset: CGFloat = -78
    /// How long after releasing on a rating the tap popover waits before it grows
    /// to reveal the "Clear" link.
    static let clearRevealDelay: Double = 0.5
    /// Row height the "Clear" link animates between (0 ↔ this), which drives the
    /// popover's height change. Includes visual gap above/below the text.
    static let clearRowHeight: CGFloat = 44
    /// Corner radius of the hold-drag reveal bubble (matches the tap popover's
    /// rounded-rect look rather than a full capsule).
    static let revealCornerRadius: CGFloat = 24
    /// The downward tail on the reveal bubble that points at the star. Each side
    /// is a single cubic that leaves the body edge horizontally (a seamless
    /// fillet — no corner) and meets at the bottom with a horizontal tangent (a
    /// smooth rounded tip), so the whole outline is tangent-continuous and the
    /// glass rim flows without kinks. `revealTailBase` = width where it meets the
    /// body, `revealTailHeight` = drop, `revealTailShoulder` = fillet softness
    /// (fraction of the half-base), `revealTailTip` = bottom roundness.
    static let revealTailBase: CGFloat = 52
    static let revealTailHeight: CGFloat = 17
    static let revealTailShoulder: CGFloat = 0.5
    static let revealTailTip: CGFloat = 6
    static let tint: Color = .primary
    static let inactiveTint: Color = .secondary
}

/// A rounded-rectangle "speech bubble" whose bottom edge flows into a small,
/// centered, downward tail — drawn as ONE continuous path so the tail morphs out
/// of the container (smooth necks in, rounded tip) instead of reading as a
/// detached triangle. Points down at the star, mirroring the tap popover.
struct TailedBubble: Shape {
    var cornerRadius: CGFloat = RatingTuning.revealCornerRadius
    var tailBase: CGFloat = RatingTuning.revealTailBase
    var tailHeight: CGFloat = RatingTuning.revealTailHeight
    var tailShoulder: CGFloat = RatingTuning.revealTailShoulder
    var tailTip: CGFloat = RatingTuning.revealTailTip
    /// X position (in the shape's own coordinate space) the tail should point at.
    /// `nil` centers it. Clamped so the tail base never overruns the body corners,
    /// so a caller can aim it at an off-center star without breaking the outline.
    var tailX: CGFloat? = nil
    /// When true the tail sits on the TOP edge pointing UP (bubble drawn BELOW the
    /// star) instead of the bottom edge pointing down. The body path is built once
    /// (tail down) and mirrored vertically, so both variants stay identical.
    var tailUp: Bool = false

    func path(in rect: CGRect) -> Path {
        let p = bottomTailPath(in: rect)
        guard tailUp else { return p }
        // Mirror vertically about the rect's centre so the tail moves to the top.
        return p.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                            tx: 0, ty: rect.minY + rect.maxY))
    }

    private func bottomTailPath(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height - tailHeight) / 2)
        let w = rect.width
        let bottom = rect.maxY - tailHeight        // body's bottom edge (tail base)
        let baseHalf = tailBase / 2
        let cx = min(max(tailX ?? rect.midX, rect.minX + r + baseHalf),
                     rect.maxX - r - baseHalf)
        let tipY = rect.maxY

        var p = Path()
        // Top edge + corners, right edge (clockwise from top-left).
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: w - r, y: rect.minY))
        p.addArc(center: CGPoint(x: w - r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: w, y: bottom - r))
        p.addArc(center: CGPoint(x: w - r, y: bottom - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        // Bottom edge to the tail's right base.
        p.addLine(to: CGPoint(x: cx + baseHalf, y: bottom))
        // Right side: one cubic leaving the body horizontally (seamless fillet)
        // and arriving at the tip horizontally (rounded bottom).
        p.addCurve(to: CGPoint(x: cx, y: tipY),
                   control1: CGPoint(x: cx + baseHalf * tailShoulder, y: bottom),
                   control2: CGPoint(x: cx + tailTip, y: tipY))
        // Left side: mirror image, back up into the body.
        p.addCurve(to: CGPoint(x: cx - baseHalf, y: bottom),
                   control1: CGPoint(x: cx - tailTip, y: tipY),
                   control2: CGPoint(x: cx - baseHalf * tailShoulder, y: bottom))
        // Bottom edge (left side) + bottom-left corner, left edge, top-left corner.
        p.addLine(to: CGPoint(x: rect.minX + r, y: bottom))
        p.addArc(center: CGPoint(x: rect.minX + r, y: bottom - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - Rating math
//
// Pure geometry → rating mapping shared by tap and drag so both feel identical.
enum RatingMath {
    /// Total width the star strip occupies (stars are laid out in fixed-width
    /// cells so the visual layout exactly matches the hit math below).
    static func stripWidth(starSize: CGFloat = RatingTuning.stripStarSize,
                           spacing: CGFloat = RatingTuning.stripStarSpacing) -> CGFloat {
        CGFloat(RatingTuning.starCount) * starSize
            + CGFloat(RatingTuning.starCount - 1) * spacing
    }

    /// Map a horizontal position measured from the FIRST star's leading edge to a
    /// snapped rating. The left half of star `i` yields `i - 0.5`, the right half
    /// `i`; a position left of the first star (x < 0, e.g. dragging past the strip)
    /// yields `nil` (clear). Result is clamped to `0.5...5.0`.
    static func rating(atX x: CGFloat,
                       starSize: CGFloat = RatingTuning.stripStarSize,
                       spacing: CGFloat = RatingTuning.stripStarSpacing) -> Double? {
        if x < 0 { return nil }
        let pitch = starSize + spacing
        let index = Int(x / pitch)
        if index >= RatingTuning.starCount { return 5.0 }
        let within = x - CGFloat(index) * pitch
        let value = within < starSize / 2 ? Double(index) + 0.5 : Double(index) + 1.0
        return min(value, 5.0)
    }
}

// MARK: - Selection haptics
//
// Fires a light "tick" whenever the previewed rating crosses a half-step, so the
// drag feels detented and premium. No-op off iOS.
final class RatingHaptic {
#if canImport(UIKit)
    private let generator = UISelectionFeedbackGenerator()
    func prepare() { generator.prepare() }
    func tick() {
        generator.selectionChanged()
        generator.prepare()
    }
#else
    func prepare() {}
    func tick() {}
#endif
}

// MARK: - Star strip
//
// Renders the 5-star strip from a preview value in fixed-width cells (so the
// visual centres line up exactly with the drag/tap math). When interactive
// (`onCommit` supplied) a single drag gesture handles BOTH a tap and a slide:
// `onPreview` fires live as the finger tracks across (half-star snapping +
// selection haptics), and `onCommit` fires the final value on release. Dragging
// left off the first star yields nil (clear). Used by the popover (interactive)
// and the player's hold-drag reveal (display only).
struct RatingStripView: View {
    let value: Double?
    var starSize: CGFloat = RatingTuning.stripStarSize
    var spacing: CGFloat = RatingTuning.stripStarSpacing
    var onPreview: ((Double?) -> Void)? = nil
    var onCommit: ((Double?) -> Void)? = nil

    @State private var tracking = false
    @State private var lastReported: Double?
    private let haptic = RatingHaptic()

    private var isInteractive: Bool { onCommit != nil }

    var body: some View {
        let stars = HStack(spacing: spacing) {
            ForEach(0..<RatingTuning.starCount, id: \.self) { i in
                Image(mozz: symbol(for: i))
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(isFilled(i) ? RatingTuning.tint : RatingTuning.inactiveTint)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: starSize, height: starSize)
            }
        }

        if isInteractive {
            // Expand the hit area vertically to the 44pt minimum without enlarging
            // the glyphs, so tapping/dragging the stars meets the touch-target
            // guideline (the drag math reads X only, so vertical padding is free).
            stars
                .padding(.vertical, max(0, (PlayerControlMetrics.minHit - starSize) / 2))
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .animation(.snappy(duration: 0.12), value: value)
        } else {
            stars.animation(.snappy(duration: 0.12), value: value)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { event in
                if !tracking { haptic.prepare(); tracking = true; lastReported = value }
                let v = RatingMath.rating(atX: event.location.x, starSize: starSize, spacing: spacing)
                if v != lastReported {
                    haptic.tick()
                    lastReported = v
                }
                onPreview?(v)
            }
            .onEnded { event in
                let v = RatingMath.rating(atX: event.location.x, starSize: starSize, spacing: spacing)
                onCommit?(v)
                tracking = false
            }
    }

    private func symbol(for index: Int) -> String {
        let v = value ?? 0
        let starValue = Double(index + 1)
        if v >= starValue { return "star.fill" }
        if v >= starValue - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }

    /// A star is "filled" (brand-colored) once it holds at least a half; empty
    /// stars stay gray so the red fill stands out.
    private func isFilled(_ index: Int) -> Bool {
        (value ?? 0) >= Double(index + 1) - 0.5
    }
}

// MARK: - Rating bubble body (shared)
//
// The interactive stars + the delayed, animated "Clear" link. Reused by BOTH the
// row "…" menu (wrapped in a system popover) and the player's sticky bubble
// (wrapped in the tailed-glass overlay). Tap a star OR slide across to set the
// rating (live); it does NOT dismiss. Sliding left off the first star clears; the
// "Clear" link appears ~`clearRevealDelay` after you lift your finger, and only
// while a rating exists.
struct RatingBubbleContent: View {
    let initialRating: Double?
    let onSet: (Double?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current: Double?
    /// Drives the Clear link + popover height. Decoupled from `current` so it can
    /// lag: after you release on a rating it reveals ~`clearRevealDelay` later, and
    /// it collapses immediately while you're actively adjusting.
    @State private var showClear: Bool
    @State private var clearWork: DispatchWorkItem?

    init(rating: Double?, onSet: @escaping (Double?) -> Void) {
        self.initialRating = rating
        self.onSet = onSet
        _current = State(initialValue: rating)
        _showClear = State(initialValue: (rating ?? 0) > 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            RatingStripView(
                value: current,
                onPreview: { previewing($0) },
                onCommit: { committed($0) }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rating")
            .accessibilityValue(current.map { Text("\(LikeControl.format($0)) stars") } ?? Text("No rating"))
            .accessibilityAdjustableAction { direction in
                adjust(direction)
            }

            // On reveal the bubble grows downward (slow, smooth) and Clear fades
            // in. On hide, Clear fades out FAST (its own quick opacity transition)
            // so it reads as a fade rather than a slide, while the container
            // collapses quickly behind it.
            if showClear {
                Button {
                    setClear(false)
                    current = nil
                    onSet(nil)
                } label: {
                    Text("Clear")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity)
                        .frame(height: RatingTuning.clearRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.13)))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        // Clear owns a full 44pt tap row (the bulk of the space under it); only a
        // little breathing room below that before the bubble's edge.
        .padding(.bottom, showClear ? 6 : 24)
    }

    // Live drag: update the stars only. Never change the popover height while the
    // finger is down — both growing and shrinking wait for release (below).
    private func previewing(_ value: Double?) {
        current = value
    }

    // Release: commit the rating, then grow/shrink to match after a short delay,
    // so the height change always trails your finger lifting (in both directions).
    private func committed(_ value: Double?) {
        current = value
        onSet(value)
        scheduleClear(to: (value ?? 0) > 0)
    }

    /// Animate the Clear link / height to `target` after `clearRevealDelay`.
    private func scheduleClear(to target: Bool) {
        clearWork?.cancel()
        guard target != showClear else { return }
        let work = DispatchWorkItem { applyShowClear(target) }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + RatingTuning.clearRevealDelay, execute: work)
    }

    /// Immediate (no delay) height change — for the explicit Clear button and the
    /// VoiceOver adjust action.
    private func setClear(_ on: Bool) {
        clearWork?.cancel()
        applyShowClear(on)
    }

    /// Toggle `showClear` inside a `withAnimation` transaction so the height
    /// change propagates OUT to the host (the morph overlay repositions the whole
    /// bubble), not just within this view. Asymmetric: slow smooth grow on reveal,
    /// quick collapse on hide.
    private func applyShowClear(_ target: Bool) {
        guard target != showClear else { return }
        if reduceMotion {
            showClear = target
        } else {
            withAnimation(target ? .smooth(duration: 0.55) : .easeOut(duration: 0.18)) {
                showClear = target
            }
        }
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        let step = 0.5
        let base = current ?? 0
        let next = direction == .increment ? min(base + step, 5) : max(base - step, 0)
        current = next == 0 ? nil : next
        onSet(current)
        setClear((current ?? 0) > 0)
    }
}

/// Row "…" menu presentation: the shared body in a system popover. (A system
/// popover can't animate its own size — that's why the player uses a custom
/// overlay instead — but for a one-off menu action the snap is acceptable.)
struct RatingPopoverContent: View {
    let rating: Double?
    let onSet: (Double?) -> Void
    var body: some View {
        RatingBubbleContent(rating: rating, onSet: onSet)
            .presentationCompactAdaptation(.popover)
    }
}

/// Publishes the player rating star's bounds so the morph root can anchor the
/// sticky rating bubble above it (the bubble must be hosted by a screen-spanning
/// ancestor so it can catch outside taps and animate its own height).
struct PlayerRatingAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Live state of an in-progress hold-drag reveal, published up to the player root
/// so the reveal bubble can be drawn ABOVE the traveling album artwork (a local
/// overlay renders under it). Non-nil only while a `hostReveal` control is being
/// dragged; the previewed value tracks the finger.
struct RatingReveal: Equatable {
    var preview: Double?
}

struct RatingRevealKey: PreferenceKey {
    static let defaultValue: RatingReveal? = nil
    static func reduce(value: inout RatingReveal?, nextValue: () -> RatingReveal?) {
        value = nextValue() ?? value
    }
}

// MARK: - Player fluid rating control
//
// Compact display for the now-playing player (ratings/Plex path only): a single
// star + numeric rating, shown ONLY when rated. Driven by the morph container
// (single source of truth via the `rating` binding, since rating writes don't
// propagate back through the playback engine):
//   • Quick tap  → asks the container to open the sticky bubble (hosted at the
//     player root so it can animate and catch outside taps).
//   • Press-hold → reveals the strip in place; drag to live-preview (half-star
//     snapping + haptics); release commits AND closes (self-contained overlay).
// Under Reduce Motion the hold-drag reveal is disabled; a tap opens the sticky
// bubble instead.
struct FluidRatingControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var rating: Double?
    let onSet: (Double?) -> Void
    var onRequestPicker: () -> Void
    /// Whether this instance publishes the sticky-bubble anchor. The player hosts
    /// more than one star (the traveling hero/queue cluster + the card's own
    /// scrolling star); only the currently-active one should emit the anchor so
    /// the bubble stays unambiguous. Defaults to `true` for standalone use.
    var emitsAnchor: Bool = true
    /// When true this control does NOT draw its own hold-drag reveal; instead it
    /// publishes `RatingRevealKey` so a screen-spanning host can draw the reveal
    /// bubble above the traveling artwork (which otherwise covers a local overlay).
    /// The drag math is unaffected — it reads the star's frame, not the reveal.
    var hostReveal: Bool = false
    /// Glyph size for the collapsed player star, shared with the other player
    /// controls so they read at a consistent size.
    var glyphSize: CGFloat = PlayerControlMetrics.utilityGlyph

    @State private var preview: Double?
    @State private var isDragging = false
    @State private var stripFrame: CGRect = .zero
    @State private var lastHapticValue: Double?
    @State private var touchDownAt: Date?
    @State private var lastX: CGFloat = 0
    @State private var revealWork: DispatchWorkItem?
    /// Press feedback for a tap. Latched like the transport buttons, and driven
    /// by the same springs — this control can't use `PlayerButtonStyle` because
    /// it isn't a `Button` (a `Button` plus a simultaneous drag would fight over
    /// the hold-to-rate gesture), so it keeps its own copy of the state and
    /// borrows the shared timing.
    @State private var pressed = false
    @State private var pressedAt = Date.now
    @State private var pendingLift: DispatchWorkItem?

    private let haptic = RatingHaptic()
    private let space = "fluidRating"

    var body: some View {
        surface
            .anchorPreference(key: PlayerRatingAnchorKey.self,
                              value: .bounds) { emitsAnchor ? $0 : nil }
            // Publish the live reveal so the host can draw it above the artwork.
            // Only the host-driven, actively-dragged control emits a value.
            .preference(key: RatingRevealKey.self,
                        value: (hostReveal && isDragging) ? RatingReveal(preview: preview) : nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rating")
            .accessibilityValue(rating.map { Text("\(LikeControl.format($0)) stars") } ?? Text("No rating"))
            .accessibilityAdjustableAction { direction in accessibilityAdjust(direction) }
    }

    // Reduce Motion: a plain tap opens the sticky bubble (no hold-drag reveal).
    // Otherwise one drag gesture handles both a quick tap (→ open sticky) and a
    // press-hold-drag (→ live preview + commit), resolving on touch-up.
    @ViewBuilder private var surface: some View {
        if reduceMotion {
            collapsedStar
                .playerHitTarget()
                .onTapGesture { onRequestPicker() }
        } else {
            collapsedStar
                // Track the star's frame so the drag math (and any host-drawn
                // reveal) stays centered on it without depending on a rendered
                // reveal overlay — the strip sits centered over the star.
                // Read before the press transform, so a squashed star can't
                // shift where a drag thinks the strip is.
                .background(starFrameReader)
                // The press. Every value here is the transport buttons' own, so
                // this feels identical under the finger despite being driven by
                // a drag gesture rather than a button. Deliberately absent from
                // the Reduce Motion path above. Applied before the overlay so
                // the reveal bubble, which replaces this once a hold engages,
                // never inherits it.
                .background { pressWash }
                .scaleEffect(pressed ? PlayerButtonStyle.pressScale : 1)
                .opacity(pressed ? PlayerButtonStyle.pressOpacity : 1)
                .animation(PlayerButtonStyle.spring(down: pressed), value: pressed)
                .sensoryFeedback(trigger: pressed) { _, down in
                    down ? PlayerButtonStyle.pressHaptic : nil
                }
                .overlay(alignment: .center) {
                    if isDragging && !hostReveal { revealStrip.offset(y: RatingTuning.revealYOffset) }
                }
                .frame(minWidth: PlayerControlMetrics.minHit, minHeight: PlayerControlMetrics.minHit)
                .coordinateSpace(name: space)
                .contentShape(Rectangle())
                .gesture(rateGesture)
        }
    }

    /// The press wash, matching the one every player button draws.
    ///
    /// A capsule rather than a circle only because the content it sits behind
    /// isn't always square: unrated it is a lone star and the capsule renders as
    /// exactly the heart's circle, rated it stretches to take in the number.
    /// Inset from the glyph itself rather than given a fixed diameter, since
    /// that width changes with the rating.
    private var pressWash: some View {
        Capsule()
            .fill(.primary.opacity(PlayerButtonStyle.washOpacity))
            .padding(-PlayerButtonStyle.washInset)
            .scaleEffect(pressed ? 1 : PlayerButtonStyle.washRestScale)
            .opacity(pressed ? 1 : 0)
            .animation(PlayerButtonStyle.washSpring, value: pressed)
            .allowsHitTesting(false)
    }

    /// Records the collapsed star's frame (in the gesture's coordinate space) and
    /// derives the reveal strip's frame from it — centered on the star, exactly
    /// `stripWidth` wide — so finger-X maps to a rating identically whether the
    /// reveal is drawn locally or by the host.
    private var starFrameReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { stripFrame = centeredStrip(around: geo.frame(in: .named(space))) }
                .onChange(of: geo.frame(in: .named(space))) { _, new in
                    stripFrame = centeredStrip(around: new)
                }
        }
    }

    private func centeredStrip(around star: CGRect) -> CGRect {
        let w = RatingMath.stripWidth()
        return CGRect(x: star.midX - w / 2, y: star.midY, width: w, height: 0)
    }

    // MARK: Collapsed display (single star + number when rated)

    private var collapsedStar: some View {
        let rated = (rating ?? 0) > 0
        return HStack(spacing: 4) {
            Image(mozz: rated ? "star.fill" : "star")
                .resizable().scaledToFit()
                .frame(width: glyphSize, height: glyphSize)
            if let r = rating, r > 0 {
                Text(LikeControl.format(r))
                    .font(.title3).monospacedDigit()
                    // "4.5" is three characters and must stay three characters.
                    // Without this the row can compress it under width pressure —
                    // which a `Text` answers by WRAPPING, so the queue card's
                    // rating came out as "4." over "5" on a narrow phone. Fixed
                    // size makes the cluster claim the width it needs instead.
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        // Unrated shows a white outline star (rated fills it + shows the number);
        // full-contrast on the player surface, not a dim gray. The 5-star reveal
        // strip keeps its dimmer unfilled stars so the fill level stays legible.
        .foregroundStyle(rated ? RatingTuning.tint : .primary)
    }

    // MARK: Hold-drag reveal (self-contained overlay; non-interactive)
    // Used only when NOT host-driven (`hostReveal == false`); the player hosts the
    // reveal at its root so it can draw above the traveling artwork.

    private var revealStrip: some View {
        VStack(spacing: 14) {
            RatingStripView(value: preview)
            Text((preview ?? 0) > 0 ? LikeControl.format(preview!) + " stars" : "No rating")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.top, 26)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .padding(.bottom, RatingTuning.revealTailHeight)
        .glassBackground(TailedBubble())
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    private var rateGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                lastX = value.location.x
                if touchDownAt == nil {
                    touchDownAt = Date()
                    haptic.prepare()
                    scheduleReveal()
                    press()
                }
                let moved = hypot(value.translation.width, value.translation.height) > RatingTuning.moveSlop
                if moved && !isDragging { engage() }
                if isDragging { updatePreview(forX: value.location.x) }
            }
            .onEnded { value in
                revealWork?.cancel(); revealWork = nil
                lift()
                let elapsed = touchDownAt.map { Date().timeIntervalSince($0) } ?? 0
                let moved = hypot(value.translation.width, value.translation.height) > RatingTuning.moveSlop
                if isDragging {
                    updatePreview(forX: value.location.x)
                    commit(preview)
                    endDragging()
                } else if !moved && elapsed < RatingTuning.longPressDuration + 0.25 {
                    onRequestPicker()
                }
                touchDownAt = nil
            }
    }

    /// After the hold threshold, reveal the strip even if the finger is stationary
    /// (a plain DragGesture emits no updates for a still finger).
    private func scheduleReveal() {
        let work = DispatchWorkItem {
            guard touchDownAt != nil, !isDragging else { return }
            engage()
            updatePreview(forX: lastX)
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + RatingTuning.longPressDuration, execute: work)
    }

    private func engage() {
        guard !isDragging else { return }
        preview = rating
        lastHapticValue = rating
        // The touch has become a hold-drag, so the tap's press feedback has no
        // business lingering under the reveal — drop it at once rather than
        // holding it for the usual minimum beat.
        cancelPress()
        withAnimation(.snappy(duration: 0.18)) { isDragging = true }
    }

    private func press() {
        pendingLift?.cancel()
        pendingLift = nil
        pressedAt = .now
        pressed = true
    }

    /// Let go — but not before the press has been on screen long enough to see.
    /// A tap is far shorter than the spring takes to travel, so without this the
    /// star would barely move unless the finger lingered.
    private func lift() {
        let remaining = PlayerButtonStyle.minimumHold
            - Date.now.timeIntervalSince(pressedAt)
        guard remaining > 0 else { pressed = false; return }
        let work = DispatchWorkItem { pressed = false }
        pendingLift = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func cancelPress() {
        pendingLift?.cancel()
        pendingLift = nil
        pressed = false
    }

    private func updatePreview(forX x: CGFloat) {
        let localX = x - stripFrame.minX
        let newValue = RatingMath.rating(atX: localX)
        if newValue != preview {
            preview = newValue
            if newValue != lastHapticValue {
                haptic.tick()
                lastHapticValue = newValue
            }
        }
    }

    private func endDragging() {
        withAnimation(.snappy(duration: 0.18)) { isDragging = false }
    }

    private func commit(_ newValue: Double?) {
        onSet(newValue)
    }

    private func accessibilityAdjust(_ direction: AccessibilityAdjustmentDirection) {
        let step = 0.5
        let base = rating ?? 0
        let next = direction == .increment ? min(base + step, 5) : max(base - step, 0)
        commit(next == 0 ? nil : next)
    }
}

#endif
