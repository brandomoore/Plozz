#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreModels
import CoreUI

/// The focusable "Up Next" card shown in the lower-right during an episode's
/// closing credits when a next episode is queued. Hosted in its own UIKit focus
/// context (`PlayerInputViewController`) so it can take Siri-Remote focus the
/// moment credits begin, like a streaming app's next-episode affordance.
///
/// Select → advance to the next episode (`actions.playUpNext`, an in-place VM
/// swap, never a seek-to-end, so the next episode never flashes the series
/// page). Menu / swipe-up → dismiss without advancing (`actions.dismissUpNext`).
/// The card only renders when `model.upNextCard.isPresenting` is true and no menu is
/// open (`!controlBarVisible`) — i.e. the container has actually presented it
/// during the (seek-respecting) credits window with a next episode queued — so
/// it never draws over an open menu and never collides with the Skip Credits
/// button (they share this slot and are mutually exclusive by construction).
///
/// The thumbnail is run through the user's Spoiler settings up front (in the view
/// model), so an unwatched next episode never leaks its frame. The show name and
/// season/episode number are never spoilers, so they always show.
struct UpNextCardView: View {
    let model: PlayerControlsModel
    let palette: ThemePalette
    let onPlayNext: () -> Void
    let onDismiss: () -> Void
    let onPlayPause: () -> Void
    @FocusState private var focused: Bool
    /// Measured height of the eyebrow/title/subtitle text column. The artwork is
    /// sized to match it exactly so the two align (the text is the tallest element
    /// and its height varies with the tvOS dynamic-type fonts). Seeded with a
    /// sensible default so the first frame isn't zero-height.
    @State private var mediaHeight: CGFloat = 92

    // MARK: Metrics
    //
    // The card is a landscape media card — artwork inset inside a rounded surface —
    // so it uses the SHARED radius pair rather than numbers of its own:
    // `mediumMediaCornerRadius` inside, and the derived
    // `landscapeCardCornerRadius` (= inner + `cardInset`) outside. That's the same
    // pair the Home rails and the episode cards use, so the corners read as one
    // family and stay concentric — a constant-width border rather than a fatter
    // curve at each corner.

    /// Inner artwork radius — the shared landscape-media value.
    static var artRadius: CGFloat { PlozzTheme.Metrics.mediumMediaCornerRadius }

    /// Outer surface radius, derived so the border stays concentric with the art.
    static var surfaceRadius: CGFloat { artRadius + PlozzTheme.Metrics.cardInset }

    /// Diameter of the trailing play control. Sized so the glyph clears the ring by
    /// ~4pt on every side rather than crowding it.
    static let controlDiameter: CGFloat = 56

    /// The countdown ring sits just inside the control.
    static var ringDiameter: CGFloat { controlDiameter - 2 }

    /// Shared with the Skip button's ring so the two read as the same component.
    static let ringStroke: CGFloat = 5

    /// Typography comes from the SHARED card scale (`PlozzMetrics`), not ad-hoc
    /// semantic styles — the same source Home's rails and the episode cards use, so
    /// this reads as part of the card family and follows the Display Size setting.
    /// It sits one step down from a browse card because this is a compact overlay
    /// floating over video, not a page surface.
    private var metrics: PlozzMetrics { PlozzMetrics.standard }

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if model.upNextCard.isPresenting, !model.controlBarVisible, let info = model.upNextCard.info {
                    card(for: info)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Anchored bottom-right and lifted clear of the transport cluster so
            // it always floats above the scrub bar, matching the Skip button.
            .padding(.trailing, 60)
            .padding(.bottom, 200)
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.upNextCard.isPresenting)
        .onAppear { focused = true }
        .playerPlatformAppearance()
    }

    @ViewBuilder
    private func card(for info: UpNextInfo) -> some View {
        let button = Button(action: onPlayNext) {
            HStack(spacing: 22) {
                thumbnail(for: info)

                VStack(alignment: .leading, spacing: 5) {
                    info.eyebrow
                        .font(.system(size: metrics.cardSubtitleFontSize * 0.78, weight: .heavy))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.primary.opacity(0.65))
                    // Show name leads. It's highly variable (short sitcoms →
                    // very long anime titles), so it shrinks a step, then wraps to
                    // two lines, then truncates — always staying readable.
                    info.showName
                        .font(.system(size: metrics.cardSubtitleFontSize * 1.2, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .truncationMode(.tail)
                    if let meta = info.metaLine {
                        Text(meta)
                            .font(.system(size: metrics.cardSubtitleFontSize * 0.9, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                // Height is added HERE, not to the card's outer padding. The
                // artwork is sized to this column's measured height and the card's
                // outer inset must stay at `cardInset` for the corners to remain
                // concentric — so growing the column grows the artwork and the card
                // together, while padding the card's edge would break the corner
                // rule and leave the artwork stranded at its old size.
                .padding(.vertical, 23)
                .frame(maxWidth: 420, alignment: .leading)
                // Publish the text column's height so the artwork can match it.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: UpNextMediaHeightKey.self, value: geo.size.height)
                    }
                )

                trailingControl
            }
            // Leading + vertical are ONE inset, and it's the same `cardInset` the
            // home-screen cards use — that's what makes the card's corner
            // concentric with the artwork's (outer radius = inner + inset), so the
            // border reads as a constant-width ring rather than a fatter curve at
            // the corners. The trailing side holds the play button, not artwork, so
            // it isn't bound by the rule and keeps a wider optical margin.
            .padding(.leading, PlozzTheme.Metrics.cardInset)
            .padding(.trailing, 24)
            .padding(.vertical, PlozzTheme.Metrics.cardInset)
        }
        .buttonStyle(PlayerOverVideoCardStyle(focused: focused, cornerRadius: Self.surfaceRadius))
        .focused($focused)
        .onPreferenceChange(UpNextMediaHeightKey.self) { height in
            if height > 0 { mediaHeight = height }
        }
        #if os(tvOS)
        button
            .onExitCommand { onDismiss() }
        // Play/Pause works while the card holds focus: toggle playback in place
        // (the auto-advance ring freezes because it tracks playback position)
        // without dismissing the card or losing focus.
            .onPlayPauseCommand { onPlayPause() }
            .onMoveCommand { direction in
                // An upward swipe dismisses the card, matching the player's other Up
                // gestures (which surface the transport / leave focusable overlays).
                if direction == .up { onDismiss() }
            }
        #else
        button
        #endif
    }

    @ViewBuilder
    private func thumbnail(for info: UpNextInfo) -> some View {
        let source = EpisodeArtworkSource(
            item: info.episode, spoilerSettings: info.spoilerSettings, policy: model.artworkPolicy
        )
        // Sized to the measured text-column height at 16:9, so the artwork spans
        // exactly the same vertical extent as the eyebrow/title/subtitle block —
        // top and bottom edges aligned — instead of a fixed height that the larger
        // tvOS fonts overflow.
        Color.clear
            .frame(width: mediaHeight * 16.0 / 9.0, height: mediaHeight)
            .overlay {
                FallbackAsyncImage(
                    references: source.references, variant: .landscapeCard,
                    artworkPolicy: source.policy,
                    asyncFallbackURL: source.fallbackURL, pinIdentity: source.pinIdentity
                ) {
                    ZStack {
                        // Fixed white, NOT palette.fill: over the player's variable
                        // video backdrop (scrim-relative), so it must not track theme.
                        Rectangle().fill(Color.white.opacity(0.08))
                        Image(systemName: "play.rectangle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.artRadius, style: .continuous))
            .blur(radius: info.blurThumbnail ? 18 : 0)
            .clipShape(RoundedRectangle(cornerRadius: Self.artRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.artRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
    }

    /// A larger circular play affordance — a countdown ring wraps it while Auto
    /// (delay) is advancing; otherwise it's a subtle filled circle. Sized to feel
    /// like a real button against the roomier card.
    @ViewBuilder
    private var trailingControl: some View {
        ZStack {
            // Subtle circular backing so it reads as a tappable play button.
            Circle()
                .fill(Color.primary.opacity(0.15))

            if model.skipMode == .autoDelay, let deadline = model.upNextCard.advanceAtSeconds {
                let remaining = deadline - model.currentSeconds
                let fraction = min(1, max(0, remaining / model.automaticUpNextDelay))
                CountdownRing(fraction: fraction)
            }

            Image(systemName: "play.fill")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Color.primary)
                // Optical centering — a play triangle reads slightly left of centre.
                .offset(x: 2)
        }
        .frame(width: Self.controlDiameter, height: Self.controlDiameter)
    }
}

/// A clockwise-depleting countdown ring for the Up Next card's Auto (delay)
/// advance, mirroring the Skip button's remaining-time ring.
private struct CountdownRing: View {
    let fraction: Double

    var body: some View {
        let foreground = Color.primary
        ZStack {
            Circle()
                .stroke(foreground.opacity(0.22), lineWidth: UpNextCardView.ringStroke)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(foreground, style: StrokeStyle(lineWidth: UpNextCardView.ringStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: UpNextCardView.ringDiameter, height: UpNextCardView.ringDiameter)
        .animation(.linear(duration: 0.3), value: fraction)
    }
}

/// Shared Up Next/Cast focus treatment: keep the surface and mark focus with
/// a contrasting ring and lift. The fallback follows the app's appearance.
struct PlayerOverVideoCardStyle: ButtonStyle {
    let focused: Bool
    let cornerRadius: CGFloat
    /// How far the card grows on focus.
    ///
    /// Small cards want the full tvOS card lift; the Up Next card is already
    /// near the screen's width, where that much growth just pushes it off the
    /// edges — so it keeps the gentler default.
    var focusScale: CGFloat = 1.04
    /// How far a press depresses the card, as a factor of `focusScale`.
    ///
    /// `1` disables it. Worth doing where a card is the SOURCE of a transition:
    /// the depress moves the card while Select is held, so anything measuring it
    /// to animate out of is measuring a position the viewer is actively
    /// changing.
    var pressScale: CGFloat = 0.94
    var mediaGlass = false
    var showsSurface = true

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return configuration.label
            .background {
                if showsSurface {
                    PlayerOverVideoSurface(focused: focused, cornerRadius: cornerRadius, mediaGlass: mediaGlass)
                }
            }
            .overlay {
                // Focus only. A resting hairline reads as an outline rather than
                // an edge — tolerable on one floating card, busy repeated across a
                // row of them — and the scrim already separates the card from the
                // footage behind it.
                shape.strokeBorder(
                    Color.primary.opacity(focused ? 0.9 : 0),
                    lineWidth: focused ? 4 : 0
                )
            }
            .clipShape(shape)
            .scaleEffect(configuration.isPressed ? focusScale * pressScale : (focused ? focusScale : 1.0))
            .shadow(color: .black.opacity(focused ? 0.30 : 0.20), radius: focused ? 14 : 8, y: focused ? 7 : 4)
            .animation(.easeOut(duration: 0.18), value: focused)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

}

/// The surface a `PlayerOverVideoCardStyle` card sits on, on its own so a panel
/// that isn't a button — the cast detail, which the row's card grows into — can
/// wear exactly the same one rather than an approximation of it.
struct PlayerOverVideoSurface: View {
    var focused: Bool = false
    let cornerRadius: CGFloat
    var mediaGlass = false

    /// Accessibility and user intent. Takes the flat scrim, because a viewer who
    /// asked for less transparency wants exactly that.
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    /// Performance. Takes a frosted material instead — the goal here is to stop
    /// paying for live refraction, NOT to stop being translucent, and the two
    /// wants are different enough to deserve different surfaces.
    @Environment(\.plozzReducePanelGlass) private var reducePanelGlass
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        surface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func surface(_ shape: RoundedRectangle) -> some View {
        let scrim = shape.fill(colorScheme == .light
            ? PlozzFrostedSurface.fill(colorScheme: .light, raised: focused)
            : .black.opacity(focused ? 0.72 : 0.55))
        if reduceTransparency {
            scrim
        } else if reducePanelGlass {
            shape
                .fill(.clear)
                .plozzFrostedBackground(shape, raised: focused)
                .plozzFrostedBorder(shape, visible: !focused)
        } else if #available(iOS 26.0, tvOS 26.0, *) {
            // Glass at rest as well as on focus — a card over live video is what
            // the material is for, and showing it only on focus is why this read
            // as a flat scrim. Drawn as a background underlay rather than wrapped
            // around the content: wrapping `.glassEffect` hangs tvOS 27's focus
            // engine (see PlozzGlassCardModifier).
            #if os(iOS)
            PlayerNativeGlassSurface(shape, glass: mediaGlass ? .clear : .regular)
            #else
            PlayerNativeGlassSurface(shape)
            #endif
        } else {
            scrim
        }
    }
}

/// Publishes the Up Next text column's height so the artwork can match it exactly
/// (keeping the two vertically aligned across the larger tvOS fonts).
private struct UpNextMediaHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
