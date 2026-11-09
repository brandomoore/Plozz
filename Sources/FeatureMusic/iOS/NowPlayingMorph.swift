// Adapted from brandomoore/Mozz at 58dab0015d09a4978f2c484e072d1bc0e30f69dc.
// Copyright (C) 2026 Mozz contributors. GPL-3.0-only with Apple distribution permission.
// See Mozz-NOTICE.txt. Plozz adapters retain the original player motion and geometry.
#if os(iOS)
import SwiftUI
import CoreModels
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Morph container (Candidate B: pure custom Liquid Glass)
//
// The mini island and the full-screen drawer are ONE view that morphs between
// two states. There is no native `tabViewBottomAccessory` and no cross-layer
// hand-off: the container literally *is* the island, so the collapse clip, the
// receive-bounce and the glass settle all fall out of one set of geometry
// interpolations. Two scalars drive everything:
//
//   • `p`     ∈ [0,1]  expand progress. 0 = island, 1 = full drawer. Only the
//                      open/collapse springs move it — never the drag.
//   • `dragY` ≥ 0      live finger translation while dragging the open drawer
//                      down. The whole surface rides the finger 1:1, fully
//                      opaque; the morph/fade happens ONLY on release.
//
// Because `p` stays pinned at 1 for the entire drag, the surface is full-size
// and fully opaque the whole time a finger is down — nothing clips, glasses, or
// fades mid-drag, and the mini controls stay hidden. Letting go animates `p` → 0,
// which shrinks the surface up to the island frame (clipping the body away),
// fades the body out, fades the mini controls in, dissolves the frost into
// Liquid Glass and lands the artwork in the slot.
/// The two secondary surfaces that can take the now-playing hero's place in the
/// expanded player. They are mutually exclusive because they share one slot — and
/// one set of open/close progresses — so exactly one can be on screen at a time.
enum PlayerPanel: Equatable, Hashable, CaseIterable {
    case queue
    case lyrics
}

struct NowPlayingMorphContainer: View {
    var playback: MusicPlayerAdapter
    @ObservedObject var ui: PlayerUIModel
    /// Tab-bar minimize progress (0 = docked island above the bar, 1 = island
    /// dropped into the bar's centre pill between the split blobs). Scroll-driven.
    var minimize: CGFloat = 0
    /// Left edge of the content area — the rail's gutter when there is a rail,
    /// otherwise zero. The dock centres over the *content*, not over the window,
    /// so it does not sit visibly off-centre with a rail down one side.
    var contentLeft: CGFloat = 0
    /// Whether there is a bottom bar under the island. Beside a rail there is
    /// not, and the island takes the bar's place at the bottom edge.
    var hasBottomBar: Bool = true
    /// Whether the window has room for two columns, which is what decides
    /// between a panel *beside* the artwork and one *instead* of it.
    var wide: Bool = false

    init(playback: MusicPlayerAdapter, ui: PlayerUIModel, minimize: CGFloat = 0,
         contentLeft: CGFloat = 0, hasBottomBar: Bool = true, wide: Bool = false) {
        self.playback = playback
        self.ui = ui
        self.minimize = minimize
        self.contentLeft = contentLeft
        self.hasBottomBar = hasBottomBar
        self.wide = wide
        // Seeded here rather than lazily, because the controller owns tasks and a
        // ticker that must belong to exactly one instance for the player's lifetime.
        _lyrics = State(initialValue: LyricsController(playback: playback))
    }

    /// The display's pixels-per-point, so prefetches ask for the pixels this
    /// screen will actually draw rather than a @2x assumption.
    @Environment(\.displayScale) private var displayScale

    /// 0 = docked island, 1 = full drawer. Animated by the open/collapse springs.
    @State private var p: CGFloat = 0
    /// Live drag translation (points) while the open drawer is being pulled down.
    @State private var dragY: CGFloat = 0
    /// True once a queue top-overscroll has committed to dismissing the drawer, so
    /// trailing overscroll callbacks during teardown don't re-inflate `dragY`.
    @State private var dismissingViaPull = false
    /// True only during the collapse, so the downward receive-bounce fires on the
    /// way into the island and never while opening or dragging.
    @State private var receiving = false
    /// Live island-press state: `pressed` drives the whole-island scale, `location`
    /// (pill-local) drives the finger-following glow. Kept in an `@Observable` so
    /// the high-frequency `location` updates re-render ONLY the lightweight glow
    /// layer — not this container (which builds the drawer's up-next list).
    @State private var press = IslandPressState()

    @EnvironmentObject private var env: MusicPlayerEnvironment
    /// For the one thing this view has to say rather than show: that a song has
    /// no lyrics, at the moment someone reaches for them.
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Single source of truth for the current track's rating on the player
    /// (ratings/Plex path). Lifted here so the collapsed star, the hold-drag
    /// reveal, and the root-hosted sticky bubble all share it — rating writes
    /// don't propagate back through the playback engine, so the view layer owns
    /// the optimistic value. Reseeded when the track changes.
    @State private var playerRating: Double?
    /// Whether the sticky tap picker (hosted at the morph root) is open.
    @State private var ratingPickerOpen = false
    /// Live hold-drag reveal state published by the active rating star, drawn at the
    /// morph root so the reveal bubble sits ABOVE the traveling artwork (a local
    /// overlay renders underneath it). Presence is split from the previewed value so
    /// the fast per-move preview updates don't restart the appear transition.
    @State private var ratingRevealActive = false
    @State private var ratingRevealPreview: Double?
    /// Which secondary panel (if any) is showing in place of the now-playing hero.
    /// Only meaningful while fully expanded; reset on collapse.
    ///
    /// The queue and the lyrics occupy the SAME slot and share one set of
    /// open/close progresses, because their entrance is identical: the hero title
    /// row lifts away, the big artwork docks into the compact card, and a body
    /// rises into the space below. Only the body differs.
    @State private var openPanel: PlayerPanel?
    /// Panel-open animation progress (0 = hero cover big-center, 1 = cover docked
    /// into the card's compact thumbnail slot). Driven as a spring alongside
    /// `openPanel` so the single traveling artwork *slides* into place instead of the
    /// big cover cross-fading with a separate thumbnail.
    @State private var panelP: CGFloat = 0
    /// A SECOND, slower open/close progress that drives ONLY the queue body's rise +
    /// fade (see `PlayerQueuePanel.bodyP`). Animated alongside `panelP` in
    /// `drivePanel()` but on `panelBodySpring` (a gentler, longer response) for the
    /// OPEN so the body glides into place after the fast artwork/card hand-off; the
    /// CLOSE reuses the fast `panelSpring` so it retracts in lock-step with `panelP`
    /// and the existing unmount-on-completion stays correct.
    @State private var panelBodyP: CGFloat = 0
    /// A THIRD open/close progress that drives ONLY the hero row's lift + fade
    /// (`HeroLift` / `RangeFadeOut` in `titleRow`). Animated alongside `panelP` in
    /// `drivePanel()` but on `panelHeroSpring` (a slower response) for the OPEN so the
    /// hero title/artist visibly *travels* up and out at its own gentler pace, decoupled
    /// from the fast artwork dock. The CLOSE reuses the fast `panelSpring` so the hero
    /// snaps back in lock-step with the rest.
    @State private var panelHeroP: CGFloat = 0
    /// True only once the panel-open spring has fully settled (and false the moment
    /// a close/open starts, and while no panel is open). Gates the seamless
    /// hand-off between the traveling artwork/star (shown during the transition)
    /// and the card's own scrolling artwork/star (shown at rest).
    @State private var panelSettled = false
    /// Bumped every time a panel opens, so the queue resets its scroll to the
    /// now-playing card at the top (never left showing History or scrolled) on
    /// each reopen — not just the first appearance.
    @State private var panelOpenNonce = 0
    /// Monotonic id bumped on every `setPanel` call. Each open/close spring's
    /// `completion:` captures the id and only applies its terminal state if it's still
    /// current — so when you toggle a panel faster than the spring settles, a stale
    /// completion from the superseded transition can't fire out of order and strand
    /// the view in a corrupt state (e.g. `panelSettled == true` while `openPanel ==
    /// nil`, which hides both the traveling AND the card artwork → blank drawer).
    @State private var panelTransition = 0
    /// The user's *latest* panel intent (which panel to show, or nil to close), set
    /// synchronously in `setPanel`. Distinct from `openPanel` (the mount flag, which
    /// lingers through a close until its spring completes). It's the single
    /// source of truth for direction: the toggle buttons and `drivePanel()` read it,
    /// and flipping it fires `.onChange(of: panelWantsOpen)` which deterministically
    /// animates `panelP` to the latest target — so no fast toggle can strand the hero
    /// row (previously a late `onAppear` could resurrect a superseded open and pin
    /// `panelP` at 1: hero stuck at the top, panel logically closed → next open
    /// teleported).
    @State private var panelWantsOpen: PlayerPanel?
    /// Whether the panel subtree was *already mounted* when the current open began.
    /// A fresh open (it was unmounted) is kicked by the subtree's `onAppear` so it
    /// animates from a committed q=0 frame (no snap); a re-open *while still mounted*
    /// (during a close) is kicked by `.onChange(of: panelWantsOpen)` instead, since
    /// `onAppear` won't fire again. This flag routes each open to exactly one of those.
    @State private var panelWasMounted = false
    /// Whether the "open onto the queue when wide" default has already been spent.
    @State private var panelDefaulted = false
    /// Where the layout reported the artwork's slot. See `artSlot`.
    @State private var artSlotRect: CGRect?
    /// The panel being replaced during a swap, kept mounted underneath the incoming
    /// one until the cross-fade finishes. `nil` whenever no swap is in flight.
    @State private var panelSwapFrom: PlayerPanel?
    /// The incoming panel's opacity during a swap (0 → 1).
    @State private var panelSwapP: CGFloat = 1
    /// Identifies the current swap so a superseded one's completion can't unmount
    /// the outgoing panel of a newer swap that started inside the same window.
    @State private var panelSwapGeneration = 0
    /// Whether the lyrics panel has taken over the whole drawer: after a spell of no
    /// interaction the transport chrome fades away and the lyrics grow into the space
    /// it vacates. Any touch brings the chrome back. Queue-only concept-free — this is
    /// never set while the queue is the open panel.
    @State private var lyricsImmersive = false
    /// Restarted on every interaction while the lyrics are open; when it elapses the
    /// chrome fades and `lyricsImmersive` turns on. Held so an interaction can cancel
    /// a countdown already in flight.
    @State private var immersiveCountdown: Task<Void, Never>?
    /// Animated flag for the transport-chrome slide/fade during an in-place row
    /// reorder — the controls move out of the way while the grabbed row is dragged,
    /// then return on drop. The list itself never moves (see `PlayerQueuePanel`).
    @State private var reorderChromeHidden = false
    /// Measured height of the transport-chrome region beneath the header (the space
    /// the chrome vacates during a drag-reorder). Passed to the queue panel so it
    /// can grow its viewport down into the reclaimed space and reveal the full list.
    @State private var chromeRegionH: CGFloat = 0
    /// Resolves the current track's lyrics and publishes which line is being sung.
    /// Built once per player (it owns tasks + a ticker) and pointed at the live
    /// backend, so signing into a different server needs no rebuild.
    @State private var lyrics: LyricsController
    /// True only once the expand spring has fully settled (and false the moment a
    /// collapse/expand starts). Gates expensive-at-rest effects — the artwork's
    /// soft shadow and the backdrop's live drift — OFF during the transition, so
    /// the spring settles without per-frame shadow re-rasterization or a competing
    /// 30fps mesh tick. That's what removes the "settling feels laggy" hitch.
    @State private var settled = false
    #if canImport(UIKit)
    /// Live current-output-route (device name + icon) for the AirPlay control.
    @StateObject private var routeMonitor = AudioRouteMonitor()
    #endif
    /// Live Low Power Mode state — used to keep the cheaper mid-morph surface even
    /// after settling on throttled devices (see `useGlassSurface`).
    @StateObject private var power = LowPowerModeObserver()

    @Environment(\.musicPlayerBackground) private var bgStyle
    /// User setting: use Liquid Glass chrome for the player (default on). When off,
    /// the player uses a cheaper opaque chrome surface.
    @Environment(\.plozzReduceTransparency) private var plozzReduceTransparency
    // Observed so the island/player chrome token re-resolves live when the dark
    // flavor (Dim↔Black) toggles; see `MozzScreenBackground`.
    @Environment(\.musicPlayerBlackout) private var blackout
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Colors sampled from the current artwork for the adaptive backdrop.
    @State private var artGrid: ArtworkColorGrid?

    /// Whether the transport chrome is currently slid out of the way — either for a
    /// drag-reorder in the queue, or the lyrics' idle takeover.
    private var chromeHidden: Bool { reorderChromeHidden || lyricsImmersive }

    /// True when the Black dark style is in effect.
    ///
    /// Black is not a darker Dark. It is the mode where nothing takes its colour
    /// from the artwork: every background in the app is black, and a cover is
    /// only ever seen inside its own frame. The player's drifting artwork field
    /// is the largest thing that rule applies to.
    /// The color scheme the player surface presents its content in: forced dark on
    /// the artwork/OLED backdrops (the surface is dark regardless of the app's
    /// appearance), or the system scheme in `theme` mode. Applied to the drawer body
    /// AND the root-level traveling star cluster so the star/overflow keep the same
    /// on-surface color as they hand off between the two (otherwise the traveling
    /// cluster — which lives outside the surface — would resolve `.primary` to black
    /// on a light-appearance device and pop to white the instant the card takes over).
    private var surfaceColorScheme: ColorScheme {
        bgStyle == .theme ? systemColorScheme : .dark
    }
    /// Identity for the palette task: re-derive when the artwork changes.
    private var artworkToken: String {
        (playback.currentTrack?.artwork?.key) ?? (playback.currentTrack?.id ?? "none")
    }
    /// Identity for artwork prefetching: changes when the current track or the
    /// next few up-next tracks change, so we warm their covers ahead of a skip.
    private var prefetchToken: String {
        ([playback.currentTrack?.id] + playback.upNext.prefix(3).map { $0.id })
            .compactMap { $0 }.joined(separator: "|")
    }

    /// How much the docked island grows while touched.
    private static let pressScale: CGFloat = 1.04
    private static let pressSpring = Animation.spring(response: 0.28, dampingFraction: 0.62)
    /// Horizontal bloom of the glow on release — it stretches to this multiple as
    /// it fades, so the light diffuses left/right along the rail before vanishing.
    private static let glowReleaseSpread: CGFloat = 4.5

    var body: some View {
        // Outer reader supplies the real safe-area insets; the inner reader,
        // ignoring the safe area, supplies the true full-screen size. We need
        // both: the island is placed off the bottom inset, the drawer bleeds
        // full-screen.
        GeometryReader { safeGeo in
            let safeTop = safeGeo.safeAreaInsets.top
            let safeBottom = safeGeo.safeAreaInsets.bottom
            GeometryReader { geo in
                // A short window uses the two-column player whether or not the
                // shell is wide: a phone on its side has the width for it and
                // nowhere near the height for the stacked form.
                let short = geo.size.height - safeTop - safeBottom < Morph.shortHeight
                let columns = wide || short
                let presentation = playerPresentation(wide: columns, panel: openPanel)
                let m = Morph(width: geo.size.width, height: geo.size.height,
                              safeTop: safeTop, safeBottom: safeBottom,
                              safeLeading: safeGeo.safeAreaInsets.leading,
                              safeTrailing: safeGeo.safeAreaInsets.trailing,
                              pRaw: p, receiving: receiving,
                              isExpanded: ui.isFullPresented, minimize: minimize,
                              // The artwork docks into the queue's card only when
                              // the panel has TAKEN the artwork's place. Beside it,
                              // the cover stays where it is and there is no card to
                              // dock into — so this stage of the morph never runs.
                              queue: columns ? 0 : panelP,
                              contentLeft: contentLeft,
                              hasBottomBar: hasBottomBar,
                              presentation: presentation,
                              measuredArtRect: artSlotRect,
                              // A short window keeps the cover exactly where it is
                              // when a panel opens: the panel takes the transport's
                              // place in the column beside it, so there is nothing
                              // to slide out of the way.
                              panelShift: (wide && !short) ? panelP : 0)
                ZStack(alignment: .topLeading) {
                    surface(m)
                    // Enlarged, invisible tap target so edge taps open the player
                    // instead of "falling through" to the page/tab-bar behind. It
                    // sits BELOW IslandContent (so the play/pause/next buttons and
                    // the swipe zone keep priority) but consumes taps in the margin
                    // around the pill. Docked state only.
                    if m.p < 0.5 {
                        Color.clear
                            .frame(width: m.islandTapW, height: m.islandTapH)
                            .contentShape(Rectangle())
                            .onTapGesture { ui.isFullPresented = true }
                            // Expose the target itself as a control. Without this the
                            // island is only a title, an artist and two transport
                            // buttons, so "open the full player" is reachable by touch
                            // but not by VoiceOver — or by a UI test.
                            .accessibilityElement()
                            .accessibilityIdentifier("mini-player")
                            .accessibilityLabel("Now Playing")
                            .accessibilityHint("Opens the full player")
                            .accessibilityAddTraits(.isButton)
                            .position(x: m.surfaceCenterX, y: m.islandTapCenterY)
                    }
                    // Finger-following specular glow: a soft highlight on the glass
                    // that tracks the touch point, like Apple's interactive Liquid
                    // Glass. It reads `press.location`, so tracking the finger
                    // re-renders ONLY this layer, never the container. (We render
                    // our own instead of `.glassEffect(.interactive())` because that
                    // API adds its own press-scale that fought our unified scale.)
                    if m.p < 0.5 {
                        IslandGlow(press: press, width: m.islandDropW,
                                   height: m.islandDropH, radius: m.radius)
                            .frame(width: m.islandDropW, height: m.islandDropH)
                            .position(x: m.surfaceCenterX, y: m.miniCenterY)
                            .allowsHitTesting(false)
                    }
                    // The island content is a self-contained subview owning its own
                    // swipe/slide state, so swiping to change tracks re-renders ONLY
                    // the island — not the whole full-player overlay (that was a big
                    // source of jank). The parent just places it: it rides the
                    // surface's top edge DOWN into the island on collapse
                    // (miniCenterY), is hidden while expanding (miniOpacity), and
                    // shrinks into the centre pill (islandDropW) when minimized.
                    IslandContent(playback: playback, onExpand: { ui.isFullPresented = true },
                                  collapse: m.dropT, pillWidth: m.islandDropW,
                                  maxPillWidth: m.islandW, wide: wide)
                        .frame(width: m.islandDropW, height: m.islandDropH)
                        // Clip the mini controls to the pill shape so nothing
                        // renders past its edges (top included) during the collapse
                        // morph — the text/buttons dissolve at the pill boundary
                        // instead of poking out above it.
                        .clipShape(Capsule())
                        .position(x: m.surfaceCenterX, y: m.miniCenterY)
                        .opacity(m.miniOpacity)
                        .allowsHitTesting(m.p < 0.5)
                    travelingArtwork(m)
                    // Instant, whole-island press detection. A UIKit 0-duration
                    // long-press recognizer (installed on the window, so it sits
                    // above the real touch target that SwiftUI draws into a shared
                    // host view) reports touch-DOWN with zero delay — the SwiftUI
                    // drag/long-press gestures wait to disambiguate a stationary
                    // finger, which lagged the scale. It observes without stealing
                    // the touch, and this transparent layer spans the ENTIRE pill,
                    // so a press anywhere — artwork, titles OR the buttons — scales
                    // the whole island as one unit and lights the glow. Gated to the
                    // docked state.
                    Color.clear
                        .frame(width: m.islandDropW, height: m.islandTapH)
                        .onTouchChanged { active, loc in
                            guard m.p < 0.5 else { return }
                            press.location = loc      // instant, tracks the finger
                            withAnimation(Self.pressSpring) { press.pressed = active }
                            if active {
                                press.spread = 1      // snap back to natural width
                                withAnimation(.easeOut(duration: 0.16)) { press.glow = 1 }
                            } else {
                                // Release: bloom outward left/right while fading.
                                withAnimation(.easeOut(duration: 0.45)) {
                                    press.glow = 0
                                    press.spread = Self.glowReleaseSpread
                                }
                            }
                        }
                        .position(x: m.surfaceCenterX, y: m.islandTapCenterY)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                // Press-scale the WHOLE island as one unit: scale the entire
                // overlay around the island's centre, so glass, artwork and text
                // grow together. When docked the rest of the overlay is
                // transparent, so only the island is visibly affected.
                .scaleEffect(press.pressed ? Self.pressScale : 1,
                             anchor: UnitPoint(x: m.surfaceCenterX / max(geo.size.width, 1),
                                               y: m.miniCenterY / max(geo.size.height, 1)))
                .onChange(of: ui.isFullPresented, initial: true) { _, want in
                    animate(to: want)
                }
                // Sticky rating bubble (ratings/Plex path): hosted here at the
                // morph root — a screen-spanning ancestor — so it can catch
                // outside taps and animate its own height (a system popover can't).
                .overlayPreferenceValue(PlayerRatingAnchorKey.self) { anchor in
                    ZStack {
                        ratingPickerOverlay(anchor: anchor, geo: geo)
                        ratingRevealOverlay(anchor: anchor, geo: geo)
                    }
                }
                // Mirror the active star's live hold-drag reveal up to the root so
                // the bubble draws above the traveling artwork. Set BOTH values
                // plainly — the appear/disappear is driven by an `.animation(value:)`
                // keyed to `ratingRevealActive` on the overlay itself. (Wrapping
                // these sets in `withAnimation` here didn't reliably fire the
                // transition, since the preference update and the resulting view are
                // computed in the same pass.)
                .onPreferenceChange(RatingRevealKey.self) { reveal in
                    if let reveal { ratingRevealPreview = reveal.preview }
                    ratingRevealActive = (reveal != nil)
                }
                .onChange(of: playback.currentTrack?.id) { _, _ in
                    playerRating = playback.currentTrack?.rating
                    ratingPickerOpen = false
                    lyrics.load(track: playback.currentTrack)
                }
                .onChange(of: playback.currentTrack?.rating) { _, value in
                    playerRating = value
                }
                .onChange(of: playback.snapshot.status) { _, status in
                    syncImmersiveToPlayback(status)
                }
                .onChange(of: ui.isFullPresented) { _, open in
                    if !open {
                        ratingPickerOpen = false
                    }
                }
                .onAppear {
                    playerRating = playback.currentTrack?.rating
                    lyrics.load(track: playback.currentTrack)
                }
                // Opening onto the queue when there is a column for it, and onto
                // the artwork when there is not, is a DEFAULT rather than a rule —
                // hence the one-shot. Once someone has chosen, their choice
                // survives rotating, folding and resizing.
                .onChange(of: wide, initial: true) { _, isWide in
                    guard isWide, !panelDefaulted else { return }
                    panelDefaulted = true
                    // Next runloop turn, not this one: with `initial: true` this
                    // closure runs inside the first update pass, and the panel
                    // state it sets is discarded there — the player opened with no
                    // queue and no sign anything had been asked for.
                    Task { @MainActor in setPanel(.queue) }
                }
                // Derive the adaptive backdrop palette from the artwork; resolve
                // synchronously if cached (correct on first frame), else crossfade.
                .task(id: artworkToken) {
                    if let cached = ArtworkPalette.cachedGrid(
                        for: playback.currentTrack?.artwork, backend: env.active?.backend, seed: artworkToken) {
                        artGrid = cached
                    } else {
                        let g = await ArtworkPalette.grid(
                            for: playback.currentTrack?.artwork, backend: env.active?.backend, seed: artworkToken)
                        guard !Task.isCancelled else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) { artGrid = g }
                    }
                }
                // Warm the current + upcoming covers at the player's pixel size so
                // skipping finds the artwork already cached — no placeholder flash.
                .onChange(of: prefetchToken, initial: true) { _, _ in
                    prefetchNearbyArtwork(side: m.expArtSide)
                }
                // Live finger translation for drag-to-dismiss, applied as ONE
                // container offset here — isolated behind a binding so reading
                // `dragY` re-runs only this modifier, never the parent body. The
                // morph geometry above is dragY-free, so a drag no longer rebuilds
                // the surface + the whole queue subtree every frame (which read as
                // stutter). `$dragY` is a binding, so the parent body takes no
                // dependency on the value and isn't invalidated as it changes.
                .modifier(DragTranslate(dragY: $dragY))
            }
            .ignoresSafeArea()
        }
    }

    /// Prefetch the current + next few covers so a skip finds the artwork already
    /// cached and renders it on the first frame instead of flashing a placeholder.
    ///
    /// `side` is the expanded player's artwork size, and it has to be: a prefetch
    /// at any other size warms a URL nothing asks for, which costs a download and
    /// buys nothing.
    private func prefetchNearbyArtwork(side: CGFloat) {
        guard let backend = env.active?.backend else { return }
        let pixels = ArtworkResolution.rung(forPoints: side, scale: displayScale)
        let tracks = [playback.currentTrack].compactMap { $0 } + playback.upNext.prefix(3)
        for track in tracks {
            if let artwork = track.artwork, let url = backend.artworkURL(for: artwork, size: pixels) {
                ArtworkImageLoader.shared.prefetch(url)
            }
        }
    }

    /// The root-hosted sticky rating bubble + a full-screen tap-catcher, anchored
    /// to the player's rating star.
    @ViewBuilder
    private func ratingPickerOverlay(anchor: Anchor<CGRect>?, geo: GeometryProxy) -> some View {
        if ratingPickerOpen, let anchor, let track = playback.currentTrack {
            RatingBubbleContainer(rect: geo[anchor], geo: geo, reduceMotion: reduceMotion,
                                  dismiss: { closeRatingPicker() }) {
                RatingBubbleContent(rating: playerRating) { setPlayerRating($0, track: track) }
            }
            // Now Playing remains white-on-artwork regardless of the app/system
            // appearance. Scope dark semantics to this bubble so its primary /
            // secondary stars and glass stay consistent without affecting menus
            // on library rows.
            .environment(\.colorScheme, .dark)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { closeRatingPicker() }
        }
    }

    /// The root-hosted hold-drag reveal, drawn above the traveling artwork (which
    /// would otherwise cover the star's own local overlay). Non-interactive; shows
    /// the live previewed rating.
    @ViewBuilder
    private func ratingRevealOverlay(anchor: Anchor<CGRect>?, geo: GeometryProxy) -> some View {
        Group {
            if ratingRevealActive, let anchor {
                RatingBubbleContainer(rect: geo[anchor], geo: geo, reduceMotion: reduceMotion,
                                      dismiss: nil) {
                    VStack(spacing: 14) {
                        RatingStripView(value: ratingRevealPreview)
                        Text((ratingRevealPreview ?? 0) > 0 ? LikeControl.format(ratingRevealPreview!) + " stars" : "No rating")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.top, 26)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
                .environment(\.colorScheme, .dark)
                .allowsHitTesting(false)
            }
        }
        // Provides the transaction for the bubble's REMOVAL fade when the finger
        // lifts. Keyed to presence only, so the live per-move preview updates don't
        // spawn a transaction of their own. (The appear is driven by the container's
        // onAppear, so preview churn can't snap it — see RatingBubbleContainer.)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: ratingRevealActive)
    }

    private func setPlayerRating(_ value: Double?, track: Track) {
        playerRating = value
        Task { await env.setRating(value, track: track) }
    }

    private func closeRatingPicker() {
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.16)) { ratingPickerOpen = false }
    }

    // MARK: Surface (Liquid Glass background + fading drawer body)

    /// Whether the player uses real Liquid Glass (blur) vs a cheap opaque chrome
    /// surface. Decided per MODE and held CONSTANT through the morph (never swapped
    /// mid-animation — that black↔glass flip was the jarring part). Glass is the
    /// default; it drops to solid when the user turns it off, in Low Power Mode, or
    /// with Reduce Transparency on (accessibility) — all cases where a consistent
    /// opaque surface is smoother / preferred.
    private var useGlassSurface: Bool {
        // Black takes the glass off here for the same reason the tab bar does:
        // glass is a lit, frosted surface, which is a lighter shade of whatever
        // is behind it by definition. The two have to agree — the dock and the
        // bar sit against each other at the bottom of the screen and read as one
        // navigation surface, so one of them frosted and the other flat black is
        // worse than either choice made twice.
        !plozzReduceTransparency && !power.isLowPower && !reduceTransparency && !blackout
    }

    /// Opaque chrome surface used when glass is off — a theme-aware elevated color
    /// that matches the surrounding nav, not pure black.
    private var cheapSurfaceFill: Color { .mozzChrome }

    private func surface(_ m: Morph) -> some View {
        ZStack(alignment: .top) {
            // Opaque panel for the expanded drawer. A frosted material base (so
            // mid-collapse the shrinking bubble stays translucent, revealing the
            // Liquid Glass behind) with the artwork-adaptive backdrop painted on
            // top. Both fade out together via `solidBgOpacity` during the collapse.
            RoundedRectangle(cornerRadius: m.radius, style: .continuous)
                .fill(useGlassSurface ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(cheapSurfaceFill))
                .overlay {
                    PlayerBackdrop(style: bgStyle, grid: artGrid, animated: settled && useGlassSurface)
                }
                .clipShape(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
                .opacity(m.solidBgOpacity)

            drawerBody(m)
                .frame(width: m.width, height: m.surfaceHExpanded, alignment: .top)
                // The space the artwork slot is measured in. Its origin is the
                // body's top-left, which IS the screen's at full expansion — and
                // the body keeps this fixed full-screen frame through the
                // collapse, so a measured slot never moves under the morph.
                .coordinateSpace(name: Self.artSlotSpace)
                .modifier(PlayerArtworkSlotObserver(
                    rect: $artSlotRect,
                    animation: wide && ui.isFullPresented && !reduceMotion ? Self.panelSpring : nil
                ))
                // Drag-to-dismiss anywhere the content doesn't claim the touch:
                // a clear, hit-testable layer directly behind the body. Interactive
                // children (buttons, scrubber, the queue scroll) sit in front and
                // consume their own gestures, so only the non-interactive gaps fall
                // through to this dismiss drag. (The queue's own top-overscroll →
                // dismiss is handled separately via onPull.)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(dragGesture)
                        .allowsHitTesting(m.p > 0.5)
                )
                .opacity(m.bodyOpacity)
                .allowsHitTesting(m.p > 0.5)
                // On the adaptive/OLED backdrop the surface is dark-colored, so
                // render the drawer content light (matches the detail pages). In
                // `theme` mode it follows the system scheme.
                .environment(\.colorScheme, surfaceColorScheme)
        }
        .frame(width: m.surfaceW, height: m.surfaceH, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
        .liquidGlass(radius: m.radius, enabled: useGlassSurface, fallbackFill: cheapSurfaceFill)
        // The same hairline the tab bar draws, and it fades out as the player
        // opens: a full-screen player is the page, and a page has no outline.
        .overlay {
            if blackout {
                RoundedRectangle(cornerRadius: m.radius, style: .continuous)
                    .strokeBorder(Color.mozzHairline, lineWidth: 1)
                    .opacity(1 - Double(m.p))
                    .allowsHitTesting(false)
            }
        }
        .position(x: m.surfaceCenterX, y: m.surfaceCenterY)
    }

    // MARK: Traveling artwork (single image, big-center ⇄ small-left)

    private func travelingArtwork(_ m: Morph) -> some View {
        // Apple-Music-style paused shrink: at rest the cover sits 25% smaller,
        // growing to full size while playing. Only in the expanded player (scaled
        // by `m.p`) so the island/mini art is unaffected — and unwound (×(1−q)) as
        // the cover docks into the fixed-size queue thumbnail slot, so it fills that
        // slot exactly instead of sitting under-sized.
        let isPlaying = playback.snapshot.status == .playing || playback.snapshot.status == .buffering
        let pausedScale = 1 - Self.pausedArtShrink * m.p * (1 - m.q) * (isPlaying ? 0 : 1)
        // Shadow only once settled, at a CONSTANT blur radius: an animated blur
        // radius re-rasterizes the shadow every frame (a classic hitch during the
        // expand). Gated on `settled` + faded via color opacity, the shadow costs
        // nothing during the transition and rasterizes once at rest. Dropped while
        // the queue is open — the compact thumbnail carries no drop shadow.
        // Beside a panel the cover is still the cover: it never docks, so it keeps
        // the shadow that says it is sitting above the backdrop.
        let handsOverToCard = !usesColumns(m)
        let showShadow = settled && (openPanel == nil || !handsOverToCard)
        return MorphArtwork(track: playback.currentTrack, side: m.artSide,
                            cornerRadius: m.artRadius, resolveSide: m.expArtSide)
            .scaleEffect(pausedScale)
            .shadow(color: .black.opacity(showShadow ? 0.35 : 0), radius: 16, y: 8)
            .position(x: m.artCenterX, y: m.artCenterY)
            // Hidden once the queue settles: the card's own (scrolling) artwork
            // takes over at the identical slot, so it can scroll & clip with the
            // list. Instant swap at a coincident position → no pop. Beside a panel
            // there is no card and no hand-over — this IS the cover.
            .opacity(panelSettled && handsOverToCard ? 0 : 1)
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72),
                       value: isPlaying)
            .animation(.easeOut(duration: 0.3), value: showShadow)
    }

    // MARK: Star + overflow cluster (rating/like + per-track menu)

    /// The star (rating on Plex / like on Jellyfin) + overflow cluster. Rendered in
    /// two places — the hero title row and the queue card's trailing slot — with a
    /// directional move-up + cross-fade between them (no single traveling copy).
    @ViewBuilder
    private func starOverflowCluster(interactive: Bool, emitsAnchor: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let track = playback.currentTrack {
                if env.usesRatings {
                    FluidRatingControl(
                        rating: $playerRating,
                        onSet: { setPlayerRating($0, track: track) },
                        onRequestPicker: {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) { ratingPickerOpen = true }
                        },
                        emitsAnchor: emitsAnchor,
                        hostReveal: true
                    )
                } else if env.supportsFeedback {
                    PlayerLikeControl(track: track)
                }
            }
            // Per-track overflow — shares the row/detail action set (P1 factory).
            if let track = playback.currentTrack {
                Menu {
                    TrackActionButtons(track: track)
                } label: {
                    AppIcon.overflow.styled(size: PlayerControlMetrics.utilityGlyph)
                        .foregroundStyle(.primary)
                        .playerHitTarget()
                }
                .accessibilityLabel("More actions")
            }
        }
        .allowsHitTesting(interactive)
    }

    /// How much the cover shrinks when paused (fraction), in the expanded player.
    private static let pausedArtShrink: CGFloat = 0.25

    // MARK: Drawer body (everything below the top edge; fades + clips on collapse)

    @ViewBuilder
    private func drawerBody(_ m: Morph) -> some View {
        // Branched on the WIDTH, not on the presentation. Keying it off whether a
        // panel is open would swap one layout for another mid-animation, and no
        // amount of interpolation survives the tree being rebuilt underneath it —
        // the player has to be the same layout before and after so it can slide.
        if m.presentation == .panelBeside || m.isShort || wide {
            besideBody(m)
        } else {
            stackedBody(m)
        }
    }

    /// The player with a panel in a column of its own.
    ///
    /// The cover does not move out of the way to make room for the queue,
    /// because there is room for both — so the transport stays exactly where it
    /// was, under the same thumb, and the queue simply appears next to it. That
    /// is the whole reason `PlayerPresentation` exists rather than a width test
    /// at each call site: one piece of state (`openPanel`), drawn two ways.
    private func besideBody(_ m: Morph) -> some View {
        VStack(spacing: 0) {
            // Hoisted out of the header so it is centred on the window rather
            // than on the left column. The geometry is unchanged: the header's
            // own grabber block was exactly this tall, so the artwork below it
            // still lands on `expArtTopGap`.
            grabber(m)
            if m.isShort {
                shortPlayer(m)
            } else {
                HStack(spacing: 0) {
                    playerColumn(m)
                        // Capped first, then centred in a slot that shrinks to
                        // the left half as the panel arrives. Two frames, because
                        // a cap applied after the slot has nothing left to shrink.
                        .frame(maxWidth: Morph.singleColumnMax)
                        .frame(width: m.playerSlotW)

                    panelColumn(m).frame(maxWidth: .infinity)
                }

                wideButtonRow(m)
            }
        }
        .onChange(of: panelWantsOpen) { _, wantsOpen in
            if wantsOpen != nil && !panelWasMounted { return }
            drivePanel()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(ChromeRegionHeightKey.self) { chromeRegionH = $0 }
    }

    /// The record and its controls.
    ///
    /// Stacked — cover over titles over transport — wherever there is height for
    /// it. In a short window (a phone on its side) the cover moves BESIDE the
    /// controls instead, because stacked simply does not fit: see `Morph.isShort`.
    /// Both forms hand the travelling cover its position by measurement, so
    /// neither has to be predicted.
    @ViewBuilder
    private func playerColumn(_ m: Morph) -> some View {
        VStack(spacing: 0) {
            header(m, showsGrabber: false)
            bottomChrome(m, showsButtons: false)
        }
    }

    /// The player laid sideways: the record on the left at the full height of the
    /// window, everything else in a column beside it.
    ///
    /// The three utility controls belong to that column, NOT to a band across the
    /// window under both of them. As a band they were a full row's worth of height
    /// taken off the record for the sake of two buttons, with the AirPlay control
    /// stranded out under the cover — which is the shape the reference layout
    /// pointedly does not have.
    private func shortPlayer(_ m: Morph) -> some View {
        HStack(spacing: 0) {
            artSlot(m, flexible: true)
            VStack(spacing: 0) {
                titleRow(m)
                    .padding(.trailing, Self.shortColumnInset)
                // The panel takes the TRANSPORT's place here, not the cover's.
                // Sideways there is room for the record and the queue at once,
                // and moving the record to make space for a list it is already
                // sitting next to is motion for nothing.
                ZStack(alignment: .top) {
                    bottomChrome(m, showsButtons: false, sideInset: 0)
                        .padding(.trailing, Self.shortColumnInset)
                        .opacity(1 - Double(min(max(panelP, 0), 1)))
                        // A view at zero opacity still takes touches, and the
                        // scrubber sits exactly where the queue's first rows
                        // land — without this it swallows them.
                        .allowsHitTesting(panelP < 0.5)
                    // The queue keeps its own 24pt row inset, which is the rail
                    // the two above have just been moved onto.
                    panelColumn(m)
                        .padding(.leading, -Self.shortColumnInset)
                }
                bottomButtonRow
                    .padding(.trailing, Self.shortColumnInset)
                    .padding(.top, 10)
                    .opacity(chromeHidden ? 0 : 1)
                    .allowsHitTesting(!chromeHidden)
            }
            // One rail for everything in this column — the title, the scrub bar
            // and the queue's rows all start here. They were on three different
            // insets, which is what read as misalignment.
            .padding(.leading, Self.shortColumnInset)
            .frame(maxWidth: .infinity)
        }
        // No `singleColumnMax` here: running the controls to the window's edge is
        // the point of turning the phone, and capping the pair at 560 left a band
        // of dead space down both sides.
        // Clear of the notch. A phone on its side puts the safe area on the
        // leading edge, and the cover was sitting under it.
        .padding(.leading, max(Self.heroSideInset, m.safeLeading))
        .padding(.trailing, max(Self.heroSideInset, m.safeTrailing))
        .padding(.top, 20)
        // The surface overhangs the screen by `bottomOverhang`; lift the whole
        // row out of that off-screen region, cover included.
        .padding(.bottom, Morph.bottomOverhang + m.safeBottom + 20)
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    /// The open panel, or nothing. Its own view because two layouts place it: a
    /// column of its own beside the player, or inside the player's column in the
    /// transport's place when the window is short.
    @ViewBuilder
    private func panelColumn(_ m: Morph) -> some View {
        ZStack(alignment: .top) {
            ForEach(PlayerPanel.allCases, id: \.self) { panel in
                if panel == openPanel || panel == panelSwapFrom {
                    panelBody(panel, m, beside: true)
                        .zIndex(panel == openPanel ? 1 : 0)
                }
            }
        }
    }

    private func stackedBody(_ m: Morph) -> some View {
        VStack(spacing: 0) {
            // Top region: the now-playing hero and the queue occupy the same
            // space and cross-fade. The queue is an overlay on the hero so it
            // inherits the hero's fixed height — it never competes with the
            // trailing Spacer for vertical space, so the controls below never
            // shift and the queue list isn't squished.
            header(m)
                .allowsHitTesting(openPanel == nil)
                .overlay(alignment: .top) {
                    // No `.transition` here: the entrance is driven entirely
                    // by the internal `q`-modifiers (the card title/star
                    // cross-fade rise and the body's rise-from-below-the-
                    // scrubber). `setPanel(_:)` mounts this at q=0 — where
                    // those are already offset-below and faded to zero — then
                    // springs q→1 on the next runloop so they interpolate in
                    // rather than snapping to their resting state.
                    // During a swap both bodies are mounted and the incoming one
                    // fades in ON TOP of the outgoing, which holds full opacity
                    // underneath. A symmetric cross-fade would dip the shared
                    // now-playing card to ~75% halfway through (two half-opaque
                    // copies of the same pixels), and that blink is exactly what
                    // made switching read as a cut rather than a change of content.
                    // Overlapping instead keeps the card, artwork and star rock
                    // steady while only the body below them dissolves.
                    // Every panel keeps its OWN slot, mounted or not, so swapping
                    // is a change of content rather than of identity.
                    //
                    // Two conditional slots — "the outgoing one" and "the open one"
                    // — meant that on a swap the very same panel moved from the
                    // second slot to the first, which SwiftUI reads as one view
                    // being destroyed and a different one created. The lyrics were
                    // torn down and rebuilt mid-dissolve, so their first-appearance
                    // ease ran again from zero: they vanished, then faded back in
                    // while simultaneously fading out.
                    ZStack(alignment: .top) {
                        ForEach(PlayerPanel.allCases, id: \.self) { panel in
                            if panel == openPanel || panel == panelSwapFrom {
                                panelBody(panel, m, beside: false)
                                    // The arriving panel is always on top.
                                    .zIndex(panel == openPanel ? 1 : 0)
                            }
                        }
                    }
                }
                // Deterministic driver for every toggle except a fresh open (which
                // the panel subtree's `onAppear` handles). Attached to the always-
                // mounted header so it fires reliably on each intent flip — close,
                // and re-open while the panel is still mounted mid-close.
                .onChange(of: panelWantsOpen) { _, wantsOpen in
                    if wantsOpen != nil && !panelWasMounted { return }  // fresh open → onAppear
                    drivePanel()
                }

            bottomChrome(m)
                // The chrome slides + fades fully out of the way in two cases, and
                // the panel below grows into the space it leaves:
                //   • a drag-reorder — so the controls never sit under the grabbed row;
                //   • the lyrics' idle takeover — so the words get the whole screen.
                // Animated on its own spring; the panel itself stays put, only the
                // chrome moves.
                .opacity(chromeHidden ? 0 : 1)
                .offset(y: chromeHidden ? Self.reorderChromeDrop : 0)
                .allowsHitTesting(!chromeHidden)
                // Touching the transport is emphatically NOT "leaving the lyrics
                // alone", so it restarts the idle countdown. A non-consuming
                // observer, so the scrubber and buttons beneath still work normally.
                .onTouchChanged { active, _ in
                    guard active, panelWantsOpen == .lyrics else { return }
                    armImmersiveCountdown()
                }
                // Measure the chrome region's height (its LAYOUT height is fixed —
                // the slide/fade above only offsets it) so the queue panel knows how
                // far it may grow down into the space this vacates during a reorder.
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: ChromeRegionHeightKey.self,
                                               value: g.size.height)
                    }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(ChromeRegionHeightKey.self) { chromeRegionH = $0 }
    }

    /// The transport chrome beneath the header/queue: scrubber, play controls,
    /// format badge, and the bottom button row + route label. Factored out so the
    /// whole block can fade away as one unit during a drag-reorder.
    @ViewBuilder
    private func bottomChrome(_ m: Morph, showsButtons: Bool = true,
                              sideInset: CGFloat = 32) -> some View {
        VStack(spacing: 0) {
            scrubber
                .padding(.horizontal, sideInset)
                .padding(.top, 22)
            // The surplus height is SHARED between these two rather than all
            // of it landing under the transport.
            //
            // A fixed 54 here and a greedy Spacer below spent every spare
            // pixel in one place, which on a tall phone is close to a fifth of
            // the screen of nothing beneath the buttons — it reads as the
            // layout having run out rather than as breathing room. Two Spacers
            // split what is spare evenly, and the unequal minimums leave the
            // transport just above the middle of the band it occupies, so the
            // player reads as two balanced halves.
            Spacer(minLength: 54)
            transport(m)
                // The same rail the scrub bar above keeps. Without it the row
                // spread to the full column while the scrubber stayed inset, so
                // shuffle and repeat — the only two controls at the ends — hung
                // 32pt out past everything else on the screen.
                .padding(.horizontal, sideInset)
            Spacer(minLength: 20)
            // At a wide width this row is not part of the chrome: it spans both
            // columns beneath them (`wideButtonRow`), so the AirPlay control sits
            // under the record and the panel toggles sit over the column they act
            // on. Here the three share one column, in iOS's order.
            if showsButtons {
                VStack(spacing: 10) {
                    bottomButtonRow
                    #if canImport(UIKit)
                    routeLabel
                    #endif
                }
                // The surface overhangs the screen by `bottomOverhang`; lift the
                // row out of that off-screen region so it sits at the safe-area
                // bottom rather than 120pt below it.
                .padding(.bottom, Morph.bottomOverhang + m.safeBottom + 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Grabber + reserved artwork slot + titles. Owns the dismiss drag so the
    /// scrubber and up-next scroll keep their own gestures.
    private func header(_ m: Morph, showsGrabber: Bool = true) -> some View {
        VStack(spacing: 0) {
            if showsGrabber { grabber(m) }

            artSlot(m)
                .padding(.top, 26)

            titleRow(m)
                .padding(.top, 22)
                .padding(.horizontal, Self.heroSideInset)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    /// Reserves the big artwork's rest space, and REPORTS where that space landed.
    ///
    /// The travelling cover is drawn as an absolute sibling, so it has to be told
    /// where the layout put the slot rather than deriving it from the same
    /// constants twice. Deriving it worked while there was one arrangement; there
    /// are three now (stacked, beside, and side-by-side in a short window) and a
    /// predicted centre would have to be right in all of them forever. Android
    /// measures for exactly this reason.
    ///
    /// Only the CENTRE is measured. The size stays computed — feeding a measured
    /// side back into the frame that produced it is a loop.
    ///
    /// Safe to measure because the drawer body is laid out at a fixed full-screen
    /// size (see `surface`) and merely clipped as the surface shrinks, so this
    /// frame does not move during the collapse.
    @ViewBuilder
    private func artSlot(_ m: Morph, flexible: Bool = false) -> some View {
        let reporter = GeometryReader { g in
            Color.clear.preference(key: ArtSlotKey.self,
                                   value: g.frame(in: .named(Self.artSlotSpace)))
        }
        if flexible {
            // Sideways the cover takes the height the row gives it and stays
            // square, rather than being sized from a subtraction. The arithmetic
            // version had to know every inset the layout was working with — safe
            // areas included — and got it wrong by 90pt on a real phone. Here the
            // layout decides and then says what it decided.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .background(reporter)
        } else {
            Color.clear
                .frame(width: m.expArtSide, height: m.expArtSide)
                .background(reporter)
        }
    }

    /// The coordinate space the slot is measured in: the drawer body's own, whose
    /// origin is the screen's at full expansion — the same space the morph's
    /// geometry is expressed in.
    static let artSlotSpace = "mozz.player.body"

    /// The sheet's drag handle. Its own view because the beside layout centres it
    /// on the window while the header it normally lives in is only half as wide.
    private func grabber(_ m: Morph) -> some View {
        Capsule().fill(.white.opacity(0.5)).frame(width: 40, height: 5)
            .padding(.top, m.safeTop + 8)
            .opacity(m.grabberOpacity)
    }

    /// The rail everything in the sideways controls column sits on — the queue
    /// panel's own row inset, so the scrub bar and the title line up with the
    /// rows rather than each keeping a margin of its own.
    private static let shortColumnInset: CGFloat = 24

    /// Side inset of the hero's title row (matches the scrubber below it).
    /// Doubles as the distance a scrolling title is allowed to bleed past its
    /// own leading edge, so its fade lands on the screen edge.
    private static let heroSideInset: CGFloat = 32

    /// Gap between the title block and the star/overflow cluster.
    ///
    /// Deliberately small, because two invisible things already pad it out: the
    /// title's trailing fade ramp dissolves the text ~14pt before its frame ends,
    /// and the cluster's 44pt minimum touch target leaves ~9pt of empty space
    /// around a 26pt glyph. The gap you SEE is roughly this plus both of those.
    /// Doubles as the title's trailing bleed, so the fade finishes inside this
    /// gap rather than short of it and the two stay in step when tuned.
    private static let titleClusterGap: CGFloat = 8

    /// The hero's now-playing metadata: title/artist on the left, the interactive
    /// star + overflow cluster on the right. On queue-open the WHOLE row lifts up and
    /// fades out early as one unit (Apple-style), while the card's own title + star
    /// fade in below by the docked artwork — a directional cross-fade, no single
    /// traveling copy.
    private func titleRow(_ m: Morph) -> some View {
        HStack(alignment: .center, spacing: Self.titleClusterGap) {
            titleArtistBlock
            // No Spacer: the title block is greedy, so it already pushes the
            // cluster to the trailing edge, and the gap is exactly the HStack
            // spacing. A Spacer here stacked ANOTHER gap between the two (its
            // minLength plus a second helping of spacing), which is what left
            // the title stranded so far from the star.
            //
            // The cluster reports an honest intrinsic width (a 44pt minimum that
            // grows when the rating shows "4.5"), and greedy-versus-intrinsic
            // means SwiftUI sizes the cluster first and gives the title what's
            // left — so the title zone re-fits itself whenever the rating
            // appears, changes width, or clears.
            starOverflowCluster(interactive: usesColumns(m) || openPanel == nil,
                                emitsAnchor: usesColumns(m) || openPanel == nil)
        }
        .font(.title3)
        // Lift the whole row UP a long way as the queue opens — it should travel
        // toward the card row (roughly halfway or more up the screen), not just
        // nudge. It stays fully visible through the early climb, then fades out
        // across a back-loaded window (RangeFadeOut) so you actually see it move
        // before it hands off to the card row catching below it.
        // Beside a panel the hero row has nowhere to go and nothing to hand over
        // to: the queue's card is not drawn, because the cover and the titles it
        // would repeat are right there in the next column.
        .modifier(HeroLift(progress: usesColumns(m) ? 0 : panelHeroP,
                           start: Self.heroLiftStart,
                           end: Self.heroLiftEnd,
                           distance: Self.heroRowLift))
        .modifier(RangeFadeOut(progress: usesColumns(m) ? 0 : panelHeroP,
                               start: Self.heroFadeStart,
                               end: Self.heroFadeEnd))
    }

    /// Title over artist, tappable: a tap opens the destination menu (Go to
    /// Artist / Album with the name as a subtitle), the way the title block works
    /// in Apple's player. Falls back to plain text when the track has neither a
    /// linkable artist nor album (e.g. the offline demo backend), so nothing
    /// presents an empty menu. The two lines sit tight (negative spacing) so they
    /// read as one block rather than two separate labels, and each scrolls its
    /// own overflow rather than truncating.
    @ViewBuilder
    private var titleArtistBlock: some View {
        let lines = VStack(alignment: .leading, spacing: -1) {
            MarqueeLine(text: playback.currentTrack?.title ?? "",
                        leadBleed: Self.heroSideInset, trailBleed: Self.titleClusterGap)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            MarqueeLine(text: playback.currentTrack?.artistName ?? "",
                        leadBleed: Self.heroSideInset, trailBleed: Self.titleClusterGap)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
            .multilineTextAlignment(.leading)
            // Claim the row's remaining width so the lines know how much room
            // they have to overflow past — without it they'd size to their text
            // and shove the star/overflow cluster off the row.
            .frame(maxWidth: .infinity, alignment: .leading)

        if let track = playback.currentTrack,
           TrackNavigationButtons.canNavigate(track, surface: .player) {
            Menu {
                TrackNavigationButtons(track: track, surface: .player, showsSubtitles: true)
            } label: {
                lines.contentShape(Rectangle())
            }
            .accessibilityLabel("\(track.title), \(track.artistName)")
            .accessibilityHint("Opens artist and album")
        } else {
            lines
        }
    }

    /// Progress (in q, 0…1) by which the hero row completes its full upward lift.
    /// Below this it climbs `heroRowLift * (q / heroLiftEnd)`; past it the row holds
    /// at full lift — invisible by then anyway, since it has faded out. This makes the
    /// *duration* of the visible climb tunable independently of the whole transition:
    /// with the old `q`-linear travel the row only reached ~half its lift before
    /// fading, so most of the climb was never seen. Applied via the `HeroLift`
    /// Animatable modifier so SwiftUI samples the clamped ramp per frame (a plain
    /// offset from animated state would linearize the endpoints and skip the corner).
    private static let heroLiftEnd: CGFloat = 0.9

    /// Progress (in `panelHeroP`, 0…1) at which the hero row BEGINS its upward lift.
    /// Below this it holds in place (still at full opacity), then climbs over
    /// [`heroLiftStart`, `heroLiftEnd`] — a delayed rise so the row sits a beat before
    /// travelling. Keep below `heroFadeEnd` or the climb happens after the row has
    /// already faded out (and so is never seen). Gated via the `HeroLift` Animatable
    /// modifier so the hold corner is sampled per frame. `0` = no delay (lift from the
    /// start).
    private static let heroLiftStart: CGFloat = 0

    /// How far the hero title/star row lifts as the queue opens (points). Large on
    /// purpose: the row should visibly climb toward the card row, not just fade in
    /// place. It fades out (see `heroFadeEnd`) before reaching the full lift.
    private static let heroRowLift: CGFloat = 360

    /// The hero row holds full opacity until `heroFadeStart`, then fades 1→0 by
    /// `heroFadeEnd` — a back-loaded fade so it climbs (staying visible) before
    /// dissolving, handing off to the card row + the queue body rising up beneath.
    private static let heroFadeStart: CGFloat = 0.2
    private static let heroFadeEnd: CGFloat = 0.68

    /// How far the card's title/artist + star rise into place from just below their
    /// own final spot as the queue opens (points). Short, directional cross-fade —
    /// they "catch" the hero row fading out above them. The card artwork does NOT
    /// use this (it docks via the traveling artwork), and the queue body's much
    /// larger rise-from-the-scrubber lives in `PlayerQueuePanel`.
    private static let cardRowRise: CGFloat = 80

    /// Where the card's title/star begin their entrance along the open progress
    /// (0…1) — now gates BOTH the rise (`GatedRise`) and the fade (`LateFade`), so the
    /// row holds down + invisible until here, then rises + fades in together after the
    /// hero row has mostly cleared (a delayed hand-off rather than a slide already
    /// underway).
    private static let cardFadeStart: CGFloat = 0.7

    /// The queue view shown in place of the hero when it is the open panel: a pinned
    /// grabber over the scrollable History / now-playing card / Continue-Playing
    /// list. The card scrolls as one unit with the list (see `PlayerQueuePanel`).
    private func queueTop(_ m: Morph, bodyOpacity: Double = 1, showsCard: Bool = true,
                          beside: Bool = false) -> some View {
        VStack(spacing: 0) {
            // Beside the player the sheet's one grabber is hoisted above both
            // columns, so this would be a second handle for the same sheet.
            if !beside {
                Capsule().fill(.white.opacity(0.5)).frame(width: 40, height: 5)
                    .padding(.top, m.safeTop + 8)
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
            }

            PlayerQueuePanel(
                playback: playback,
                queueP: panelOpenProgress(m),
                bodyP: panelBodyP,
                bodyRise: panelBodyRise(m),
                bodyOpacity: bodyOpacity,
                resetToken: panelOpenNonce,
                onSelect: { orderPosition in
                    playback.jump(toOrderPosition: orderPosition)
                    // Jumping rewrites what counts as history and what's up next, so
                    // the row you tapped is now the card — somewhere far from where
                    // you were scrolled. Re-dock so it lands back at the top instead
                    // of leaving you staring at a stretch of queue you just skipped.
                    panelOpenNonce &+= 1
                },
                onClearHistory: { withAnimation(.easeInOut(duration: 0.25)) { playback.clearHistory() } },
                onClearQueue: { withAnimation(.easeInOut(duration: 0.25)) { playback.clearUpNext() } },
                onReorderActive: { active in
                    withAnimation(Self.reorderChromeSpring) { reorderChromeHidden = active }
                },
                onCommitReorder: { from, to in playback.moveUpNext(fromOffset: from, toOffset: to) },
                reorderExtraHeight: reclaimableChromeHeight(m),
                onPull: { raw in handleQueuePull(raw) },
                onPullEnd: { raw, velocity in handleQueuePullEnd(raw, velocity) },
                // Beside the artwork there is no need to repeat the current
                // track as a card — the cover and its titles are in the column
                // next to this one. The shuffle/repeat pills DO stay: unlike
                // Android's, this transport has never carried them, so the queue
                // is the only place they exist.
                card: {
                    Group {
                        if beside { EmptyView() }
                        else { nowPlayingCard(m).opacity(showsCard ? 1 : 0) }
                    }
                },
                // The pills stay on a phone. They are dropped only where the
                // play controls have taken shuffle and repeat over, since a
                // control with two homes on one screen is worse than a control
                // in the wrong one.
                queueControls: {
                    Group {
                        if showsPlayModes(m) { EmptyView() } else { shuffleRepeatPills }
                    }
                },
                showsNowPlayingCard: !beside
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Fresh open only: this fires once the subtree has mounted + laid out at q=0,
        // so the whole entrance (artwork dock, card cross-fade, body rise) interpolates
        // 0→1 from a committed frame instead of snapping. Re-opens while still mounted
        // are driven by `.onChange(of: panelWantsOpen)` (onAppear won't refire).
        .onAppear { drivePanel() }
    }

    /// One of the two interchangeable panel bodies.
    ///
    /// During a swap both are mounted and their bodies cross-fade, while the card
    /// above them stays put.
    ///
    /// Exactly ONE panel draws the card at any moment, and during a swap it is the
    /// OUTGOING one — the panel that is already on screen with its card laid out
    /// and positioned.
    ///
    /// Drawing it in both brightened the artist name: it is `.secondary`, a
    /// translucent colour, so two stacked copies composite to roughly 0.84 alpha
    /// instead of 0.6. Handing it to the arriving panel instead swapped that for a
    /// worse problem — that panel is mounting this very frame and has not laid its
    /// card out yet, so the whole header blinked out. The outgoing panel has no
    /// such gap, and by the time it unmounts the arriving one has had the full
    /// dissolve to settle, so the hand-over lands on identical pixels.
    @ViewBuilder
    private func panelBody(_ panel: PlayerPanel, _ m: Morph, beside: Bool) -> some View {
        let isOutgoing = panelSwapFrom != nil && panel == panelSwapFrom
        let swapping = panelSwapFrom != nil
        let bodyOpacity: Double = {
            guard swapping else { return 1 }
            return isOutgoing ? Double(1 - panelSwapP) : Double(panelSwapP)
        }()
        let showsCard = swapping ? isOutgoing : true
        switch panel {
        case .queue: queueTop(m, bodyOpacity: bodyOpacity, showsCard: showsCard, beside: beside)
        case .lyrics: lyricsTop(m, bodyOpacity: bodyOpacity, showsCard: showsCard, beside: beside)
        }
    }

    /// The lyrics view shown in place of the hero when it is the open panel. Shares
    /// the queue's slot, grabber and now-playing card verbatim — only the body below
    /// the card differs — so the two read as one surface with two contents.
    ///
    /// While immersive it grows DOWN into the height the transport chrome vacates,
    /// exactly as the queue does during a drag-reorder.
    private func lyricsTop(_ m: Morph, bodyOpacity: Double = 1, showsCard: Bool = true,
                           beside: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !beside {
                Capsule().fill(.white.opacity(0.5)).frame(width: 40, height: 5)
                    .padding(.top, m.safeTop + 8)
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
            }

            PlayerLyricsPanel(
                controller: lyrics,
                lyricsP: panelOpenProgress(m),
                bodyP: panelBodyP,
                bodyRise: panelBodyRise(m),
                chromeReclaim: reclaimableChromeHeight(m),
                cardReserve: beside ? 0 : Morph.queueArtSide + 26,
                // The same rail the queue's content uses, which is also where the
                // travelling artwork docks — so the two panels' headers line up
                // exactly and the artwork doesn't shift as it hands over.
                cardInset: Morph.queueArtLeading,
                bodyOpacity: bodyOpacity,
                immersive: lyricsImmersive,
                onInteract: { handleLyricsInteraction() },
                onSeekToLine: { index in
                    lyrics.seek(toLine: index)
                    handleLyricsInteraction()
                },
                card: {
                    Group {
                        if beside { EmptyView() }
                        else { nowPlayingCard(m).opacity(showsCard ? 1 : 0) }
                    }
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { drivePanel() }
    }

    /// How far the panel itself has arrived — which is what fades it in.
    ///
    /// Distinct from `Morph.queue`, the artwork's dock into the queue's card:
    /// beside the artwork there is no card to dock into, so that stage of the
    /// morph is pinned at zero while the panel still has to appear.
    /// Whether the player is drawn as two columns: because the shell is wide, or
    /// because the window is too short to stack. Both mean the panel gets a column
    /// of its own and the cover never docks into a card.
    private func usesColumns(_ m: Morph) -> Bool { wide || m.isShort }

    private func panelOpenProgress(_ m: Morph) -> CGFloat {
        usesColumns(m) ? min(max(panelP, 0), 1) : m.q
    }

    /// How far a panel may grow DOWNWARD once the transport chrome is out of the
    /// way: the chrome region's height minus the part of it that hangs off the
    /// bottom of the screen anyway.
    private func reclaimableChromeHeight(_ m: Morph) -> CGFloat {
        max(0, chromeRegionH - (Morph.bottomOverhang + m.safeBottom))
    }

    /// How far the queue body (pills + "Queue" header + Continue-Playing list) drops
    /// below its resting spot at q=0, so it rises up from below the scrub bar as the
    /// queue opens. Derived from the drawer's own geometry — the header is dominated
    /// by the big artwork, and the scrubber sits just beneath it — so this is a solid
    /// device-scaled proxy for "the panel's height" that's known SYNCHRONOUSLY at
    /// mount. (The panel can't measure its own viewport in time: it remounts on every
    /// open and its GeometryReader reads 0 for the first frames, which is exactly what
    /// left the body pinned in place.) Overshoot is harmless — the panel is clipped,
    /// so a body that starts a little past the scrubber just rises in from off-screen.
    private func panelBodyRise(_ m: Morph) -> CGFloat {
        m.safeTop + 45 + m.expArtSide
    }

    /// The now-playing card at the center of the queue: artwork + title/artist +
    /// star/overflow. (The shuffle/repeat pills sit just below it in the queue's
    /// sticky controls block, not in this card.) The artwork and star are reserved
    /// (empty) slots during the open transition — the traveling artwork/star cover
    /// them — and become the card's own scrolling copies once the queue settles.
    private func nowPlayingCard(_ m: Morph) -> some View {
        HStack(spacing: 12) {
            // Card's own artwork — visible once settled so it scrolls & clips
            // with the list; hidden during the transition (the traveling
            // artwork covers this exact slot). Tapping it (once settled) closes
            // the queue and returns to the now-playing hero.
            MorphArtwork(track: playback.currentTrack,
                         side: Morph.queueArtSide, cornerRadius: Morph.queueArtRadius)
                .opacity(panelSettled ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { if panelSettled { setPanel(nil) } }
                .allowsHitTesting(panelSettled)
            VStack(alignment: .leading, spacing: 2) {
                // Scrolls rather than truncating, exactly as the hero title
                // above it does. The title does not change when the queue
                // opens, so it should not change how it behaves either — a
                // name that was readable a moment ago should not become
                // "Something From The Series Arcane Leag…" because a list
                // appeared underneath it.
                MarqueeLine(text: playback.currentTrack?.title ?? "",
                            leadBleed: 0, trailBleed: 8)
                    .font(.headline)
                Text(playback.currentTrack?.artistName ?? "")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            // Rise into place from a little below as the queue opens, so the
            // card titles appear to "catch" the hero titles fading out above
            // them — a directional cross-fade, not a plain fade. The fade-in is
            // DELAYED (LateFade) so it starts around the time the hero row has
            // mostly cleared, overlapping rather than waiting for it to finish.
            .modifier(GatedRise(progress: m.q, start: Self.cardFadeStart, distance: Self.cardRowRise))
            .modifier(LateFade(progress: m.q, start: Self.cardFadeStart))
            Spacer(minLength: 8)
            // Card's own star + overflow at its final resting slot. Rises + fades
            // in on the SAME delayed curve and SAME upward offset as the card
            // title, so the title/artist + star move up and fade in as ONE row —
            // the top half of the directional cross-fade with the hero cluster
            // lifting away above. Interactive + owns the rating anchor only once
            // settled (the hero cluster owns it while the queue is closed, so
            // exactly one anchor is ever published).
            starOverflowCluster(interactive: panelSettled, emitsAnchor: panelSettled)
                .modifier(GatedRise(progress: m.q, start: Self.cardFadeStart, distance: Self.cardRowRise))
                .modifier(LateFade(progress: m.q, start: Self.cardFadeStart))
        }
        .padding(.top, 8)
    }

    /// Shuffle + repeat pills directly beneath the current song.
    private var shuffleRepeatPills: some View {
        let snapshot = playback.snapshot
        return HStack(spacing: 12) {
            QueuePill(glyph: AppIcon.shuffle, label: "Shuffle",
                      active: snapshot.isShuffled) {
                playback.toggleShuffle()
                // Toggling shuffle rewrites the play order (enabling pins the
                // current track to the front so history empties; disabling
                // restores it), which swings `detentTop`. Re-dock so the current
                // song snaps back to the top with the fresh order instead of
                // leaving the user stranded mid-list.
                panelOpenNonce &+= 1
            }
            QueuePill(glyph: AppIcon.repeatTracks,
                      label: snapshot.repeatMode == .one ? "Repeat One" : "Repeat",
                      active: snapshot.repeatMode != .off,
                      badge: snapshot.repeatMode == .one ? "1" : nil) {
                playback.cycleRepeatMode()
            }
        }
    }

    // MARK: Gestures / animation

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard p > 0.5 else { return }
                dragY = max(0, value.translation.height)
            }
            .onEnded { value in
                guard p > 0.5 else { return }
                let far = value.translation.height > 140
                let flung = value.predictedEndTranslation.height > 340
                if far || flung {
                    // Route through the shared flag so the collapse always runs
                    // the same spring, whether triggered here or externally.
                    ui.isFullPresented = false
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { dragY = 0 }
                }
            }
    }

    /// Live top-pull from the queue: once the list is at its very top and the
    /// finger keeps dragging down, the whole player drawer follows the finger 1:1
    /// (the queue cancels its own rubber-band so the content stays rigid and only
    /// the drawer moves), toward dismissal.
    private func handleQueuePull(_ pull: CGFloat) {
        guard p > 0.5, !dismissingViaPull else { return }
        dragY = pull
    }

    /// Finger-lift while pulling the queue's top down: dismiss if pulled far or
    /// flung down hard (real velocity, points/second); otherwise spring the drawer
    /// back to rest.
    private func handleQueuePullEnd(_ pull: CGFloat, _ velocity: CGFloat) {
        guard p > 0.5, !dismissingViaPull else { return }
        if pull > 120 || velocity > 800 {
            dismissingViaPull = true
            ui.isFullPresented = false
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { dragY = 0 }
        }
    }

    /// The single animator.
    /// - `open`  grows the drawer.
    /// - `!open` collapses it into the island. The spring itself is unchanged
    ///   (the feel you liked); `receiving` gates a downward bounce that fires
    ///   only during this collapse. `p` is clamped in the geometry, so the
    ///   spring's own overshoot can't wobble the surface — the only bounce is the
    ///   deliberate downward one.
    private func animate(to open: Bool) {
        if open {
            // Clear the pull-dismiss latch on (re)present; it stays set through the
            // whole collapse so trailing overscroll callbacks can't re-inflate dragY.
            dismissingViaPull = false
            receiving = false
            settled = false
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                p = 1; dragY = 0
            } completion: {
                // Only now (fully at rest) enable the shadow + backdrop drift.
                settled = true
            }
        } else {
            receiving = true
            settled = false
            // Invalidate any in-flight panel open/close completion: the collapse below
            // keeps the panel progresses pinned and its own completion resets the panel
            // flags, so a stale panel completion firing afterwards must not flip
            // `panelSettled` back on (which would blank the drawer on the next expand).
            panelTransition &+= 1
            // NOTE: don't reset `panelWantsOpen` here — it feeds `.onChange`, and
            // clearing it now would kick `drivePanel()` which (seeing a close intent)
            // would unmount the panel at the START of the collapse. We keep it set
            // through the collapse and reset it in the completion, once fully collapsed.
            // Dismiss the drawer as ONE rigid unit — do NOT morph the queue open→hero
            // during the collapse. Keep all three queue progresses (`panelP`,
            // `panelBodyP`, `panelHeroP`) pinned at 1 so the fully laid-out queue
            // (docked artwork, card star, shuffle/repeat pills, "Queue" header, list)
            // rides straight down and is clipped away WITH the surface, instead of the
            // artwork flying back to center + the list fading while the body/hero stay
            // put (the old jumble, caused by driving only `panelP`→0 here). `panelSettled`
            // likewise stays TRUE so the card's in-flow star/artwork ride down rather
            // than reviving the root-level traveling star (which sits outside the
            // surface clip and would fling UP off-screen). Everything queue-related is
            // reset in the completion once fully collapsed and invisible.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                p = 0; dragY = 0
            } completion: {
                receiving = false
                // Fully collapsed now (invisible): reset the panel flags AND all three
                // progresses so a fresh present starts from the hero header with the
                // traveling star, without any flash or stranded body/hero offset.
                openPanel = nil
                panelSettled = false
                panelWantsOpen = nil
                panelP = 0
                panelBodyP = 0
                panelHeroP = 0
                endImmersive()
            }
        }
    }

    /// Show `panel` (or close whatever is open when `nil`), driving `panelP` as a
    /// spring and managing `panelSettled` — the traveling ⇄ card artwork/star
    /// hand-off flag.
    ///
    /// This ONLY records intent (`panelWantsOpen`) and manages the mount flag; it
    /// never springs `panelP` itself. The animation is driven by `drivePanel()`,
    /// kicked from exactly one place per transition:
    ///   • fresh open (nothing mounted) → the subtree's `onAppear` (committed q=0 frame)
    ///   • re-open while mounted / close → `.onChange(of: panelWantsOpen)`
    /// so `panelP` deterministically animates to the *latest* intent no matter how
    /// fast you toggle — no `onAppear`-vs-lingering-mount race can strand the hero row.
    ///
    /// Switching directly between the queue and the lyrics does NOT close and
    /// reopen. Everything above the body — the docked artwork, the card, the lifted
    /// hero — is identical in both, so only the body cross-fades while the rest
    /// holds perfectly still. Closing first would throw all of that away and play
    /// the same entrance twice for no reason.
    private func setPanel(_ panel: PlayerPanel?) {
        guard panel != panelWantsOpen else { return }
        let isSwap = panel != nil && panelWantsOpen != nil && panelP > 0
        // Arm or tear down the lyrics' idle takeover for the panel we're moving to.
        // On a swap the chrome has to come back on the same spring as everything
        // else, or it would snap in underneath a body that is still dissolving.
        if panel == .lyrics {
            armImmersiveCountdown()
        } else if isSwap {
            withAnimation(Self.immersiveSpring) { endImmersive() }
        } else {
            endImmersive()
        }
        if let panel, isSwap {
            // Live swap: every progress stays exactly where it is — the hero is
            // already lifted away and the artwork already docked, so re-running
            // that entrance would be motion for its own sake. Only the body changes.
            let outgoing = openPanel
            panelSwapGeneration &+= 1
            let generation = panelSwapGeneration
            panelWantsOpen = panel
            panelOpenNonce &+= 1
            panelSwapFrom = outgoing
            panelSwapP = 0
            openPanel = panel
            guard !reduceMotion else {
                panelSwapFrom = nil
                panelSwapP = 1
                return
            }
            // Kick the dissolve on the NEXT runloop turn, once the frame above has
            // been committed. Animating in the same update does nothing at all:
            // `panelSwapP` rests at 1, so setting it to 0 and then animating it
            // back to 1 in one pass is a no-op — SwiftUI only ever sees 1, the
            // intermediate 0 is never rendered, and the bodies simply cut. What was
            // left visibly moving was the rebuilt panel replaying its own entrance.
            Task { @MainActor in
                guard generation == panelSwapGeneration else { return }
                withAnimation(Self.panelSwapFade) {
                    panelSwapP = 1
                } completion: {
                    guard generation == panelSwapGeneration else { return }
                    panelSwapFrom = nil
                }
            }
            return
        }
        // Any non-swap transition starts from a clean slate.
        panelSwapFrom = nil
        panelSwapP = 1
        // Supersede any in-flight transition so its completion can't apply terminal
        // flags after this newer toggle.
        panelTransition &+= 1
        if let panel {
            // `panelWasMounted` distinguishes a re-open-during-close (subtree still
            // up, onAppear won't refire) from a fresh open (it remounts, onAppear fires).
            panelWasMounted = openPanel != nil
            openPanel = panel
            panelSettled = false
            panelOpenNonce &+= 1
        } else {
            panelSettled = false
        }
        // Flip intent LAST so `.onChange(of:)` sees the mount flags already updated.
        panelWantsOpen = panel
        if reduceMotion {
            let open = panel != nil
            panelP = open ? 1 : 0
            panelBodyP = open ? 1 : 0
            panelHeroP = open ? 1 : 0
            panelSettled = open
            if !open { openPanel = nil }
        }
    }

    /// The single writer of the open/close spring. Reads the *current* intent, so it
    /// always animates `panelP` toward the latest target; the completion is token-
    /// guarded so a superseded transition can't commit `panelSettled`/unmount late.
    /// Called from the panel subtree's `onAppear` (fresh open) and
    /// `.onChange(of: panelWantsOpen)` (re-open while mounted, and every close) —
    /// see `setPanel` for the routing.
    private func drivePanel() {
        guard !reduceMotion else { return }
        let token = panelTransition
        if panelWantsOpen != nil {
            guard panelP < 1 else { return }
            withAnimation(Self.panelSpring) {
                panelP = 1
            } completion: {
                guard token == panelTransition else { return }
                panelSettled = true
            }
            // Body climbs on its own gentler, longer spring so it settles into place
            // after the fast hand-off above — not tied to the panelP completion.
            withAnimation(Self.panelBodySpring) {
                panelBodyP = 1
            }
            // Hero lifts + fades on its own slower spring so its travel reads as a
            // deliberate hand-off rather than a quick snap, decoupled from the artwork.
            withAnimation(Self.panelHeroSpring) {
                panelHeroP = 1
            }
        } else {
            // Already collapsed: nothing to animate, just drop the mount.
            guard panelP > 0 else { openPanel = nil; panelBodyP = 0; panelHeroP = 0; return }
            withAnimation(Self.panelSpring) {
                panelP = 0
            } completion: {
                guard token == panelTransition else { return }
                openPanel = nil
            }
            // Retract the body in lock-step with panelP (fast spring) so it finishes
            // together and the unmount-on-panelP-completion above stays clean.
            withAnimation(Self.panelSpring) {
                panelBodyP = 0
            }
            // Hero snaps back with the fast spring too — no reason to linger on close.
            withAnimation(Self.panelSpring) {
                panelHeroP = 0
            }
        }
    }

    // MARK: Lyrics immersive takeover

    /// The dissolve when swapping the queue body for the lyrics body (or back)
    /// while the panel stays open.
    ///
    /// Deliberately quick. The card and artwork above don't move at all, and the
    /// two bodies are completely different text — linger over that and you read it
    /// as both sets of words on screen at once rather than as one changing into the
    /// other.
    private static let panelSwapFade = Animation.easeInOut(duration: 0.18)

    /// How long the lyrics sit alongside the full transport before the chrome
    /// fades and they take over the screen. Long enough to scrub or skip without
    /// the controls sliding out from under you, short enough that simply looking
    /// at the lyrics gets you the full-screen view.
    private static let immersiveDelay: Duration = .seconds(5)

    /// Spring for the chrome's exit/return. Slower and softer than the reorder
    /// slide — this is an ambient transition the user didn't ask for, so it should
    /// drift rather than snap.
    private static let immersiveSpring = Animation.spring(response: 0.55, dampingFraction: 0.9)

    /// Whether audio is actually running. `.buffering` counts: a stall is the app
    /// working on the user's behalf, not the user stopping.
    private var isPlayingOrBuffering: Bool {
        let status = playback.snapshot.status
        return status == .playing || status == .buffering
    }

    /// (Re)starts the idle countdown to the immersive takeover. Any interaction
    /// calls this, so the chrome only leaves after a genuine pause.
    ///
    /// Nothing is armed unless audio is actually playing — the takeover exists to
    /// get out of the way of a song, and a stopped player with no controls is just
    /// a dead end.
    private func armImmersiveCountdown() {
        immersiveCountdown?.cancel()
        immersiveCountdown = nil
        // Nothing to take over beside a panel: the lyrics already have a column
        // of their own, and hiding the transport there would buy them nothing.
        guard !reduceMotion, !wide, isPlayingOrBuffering else { return }
        immersiveCountdown = Task { @MainActor in
            try? await Task.sleep(for: Self.immersiveDelay)
            guard !Task.isCancelled,
                  panelWantsOpen == .lyrics,
                  isPlayingOrBuffering else { return }
            withAnimation(Self.immersiveSpring) { lyricsImmersive = true }
        }
    }

    /// Keeps the takeover in step with the transport.
    ///
    /// Pausing means the user wants the controls, so they come back and stay back
    /// until playback resumes. A transient `.buffering` is deliberately ignored —
    /// a stall on a slow server shouldn't yank the chrome in and out.
    private func syncImmersiveToPlayback(_ status: PlaybackStatus) {
        guard panelWantsOpen == .lyrics else { return }
        switch status {
        case .playing:
            guard !lyricsImmersive else { return }
            armImmersiveCountdown()
        case .paused, .idle:
            immersiveCountdown?.cancel()
            immersiveCountdown = nil
            guard lyricsImmersive else { return }
            withAnimation(Self.immersiveSpring) { lyricsImmersive = false }
        case .buffering:
            break
        }
    }

    /// A touch anywhere in the lyrics: bring the chrome back if it has gone, and
    /// restart the countdown either way.
    private func handleLyricsInteraction() {
        if lyricsImmersive {
            withAnimation(Self.immersiveSpring) { lyricsImmersive = false }
        }
        armImmersiveCountdown()
    }

    /// Cancels the countdown and restores the chrome, without animation — used when
    /// the panel closes or the whole drawer collapses, where the state must simply
    /// be clean for the next open.
    private func endImmersive() {
        immersiveCountdown?.cancel()
        immersiveCountdown = nil
        lyricsImmersive = false
    }

    // MARK: Drag-to-reorder (up-next)

    /// Spring for the transport-chrome fade/slide when a reorder starts and ends.
    private static let reorderChromeSpring = Animation.spring(response: 0.34,
                                                              dampingFraction: 0.86)

    /// How far (points) the transport chrome slides DOWN as it fades out during an
    /// in-place row reorder — enough to clear the drawer so it fully leaves rather
    /// than hovering half-visible under the grabbed row.
    private static let reorderChromeDrop: CGFloat = 360


    /// hand-off (hero lift + `RangeFadeOut`, card rise + `LateFade`, `BodyRise`) is
    /// keyed on `panelP` (0→1), so scaling the one spring that drives `panelP` slows
    /// the WHOLE sequence proportionally — the relative timing of each phase is
    /// preserved, just stretched out. `1.4` = a bit slower/gentler than the raw
    /// spring tuning, which reads smoother on both open and close.
    private static let panelTimeScale: CGFloat = 1.4

    /// Shared open/close spring for the queue transition (× `panelTimeScale`).
    static let panelSpring = Animation.spring(response: 0.48 * panelTimeScale,
                                             dampingFraction: 0.86)

    /// Gentler, longer spring for the queue BODY's rise/fade on OPEN only, so its
    /// climb visibly takes longer than the fast `panelSpring` hand-off (artwork dock +
    /// hero→card title cross-fade) above it. Higher `response` = slower climb; high
    /// damping keeps it from overshooting on the long travel. The close still uses
    /// `panelSpring` (see `drivePanel`), so this only stretches the entrance.
    private static let panelBodySpring = Animation.spring(response: 0.72 * panelTimeScale,
                                                          dampingFraction: 0.92)

    /// Slower spring for the hero row's lift/fade on OPEN only, so the title/artist
    /// visibly travel up and out at a gentler pace than the fast artwork dock instead
    /// of snapping away. Higher `response` = slower; the close reuses `panelSpring`
    /// (see `drivePanel`) so retract stays snappy.
    private static let panelHeroSpring = Animation.spring(response: 0.64 * panelTimeScale,
                                                          dampingFraction: 0.88)

    // MARK: Drawer controls

    private var scrubber: some View {
        let snapshot = playback.snapshot
        let formatLabel = playback.currentTrack?.format.nowPlayingLabel
        return SeekBar(
            elapsed: snapshot.elapsed,
            duration: snapshot.duration,
            trackID: snapshot.currentTrackID,
            formatLabel: formatLabel
        ) { target in
            playback.seek(to: target)
        }
    }

    /// The five transport columns, in the order they are drawn. The bottom
    /// button row is laid on the SAME grid so lyrics, AirPlay and queue sit
    /// directly under previous, play and next.
    /// Gap between the play controls, and between the utility buttons below them.
    ///
    /// One number for both rows: that is what keeps lyrics, AirPlay and queue
    /// under previous, play and next. The five-column grid it replaced reserved
    /// the shuffle/repeat columns even when they were empty, which quietly spent
    /// 88pt of a phone's width on nothing and squeezed these to 16.
    private static let transportGap: CGFloat = 52

    private static let transportColumns: [CGFloat] = [
        PlayerControlMetrics.minHit,   // shuffle
        PlayerControlMetrics.skipHit,  // previous
        PlayerControlMetrics.playHit,  // play / pause
        PlayerControlMetrics.skipHit,  // next
        PlayerControlMetrics.minHit,   // repeat
    ]

    /// Whether shuffle and repeat join the play controls rather than sitting as
    /// pills above the queue.
    ///
    /// Only on a genuinely large screen — an iPad or a desktop window. A phone
    /// keeps them by the queue at every orientation, which is why this asks for
    /// width AND height: a phone on its side is still a phone.
    private func showsPlayModes(_ m: Morph) -> Bool { wide && !m.isShort }

    private func transport(_ m: Morph) -> some View {
        let snapshot = playback.snapshot
        let playing = snapshot.status == .playing
        let mode = snapshot.repeatMode
        let modes = showsPlayModes(m)
        // Three controls: the fixed gap the utility row copies, which is what
        // keeps the two aligned. Five: let them spread instead — 272pt of controls
        // plus four 52pt gaps is 480, and a portrait iPad's column with the queue
        // open is 353, so a fixed gap pushes repeat off the end. (It did exactly
        // that on Android's half-column before the same fix.)
        return HStack(spacing: modes ? 0 : Self.transportGap) {
            if modes {
                PlayerIconButton(glyph: .shuffle,
                                 glyphSize: 22,
                                 tint: snapshot.isShuffled ? .primary : .secondary,
                                 haptics: false,
                                 label: snapshot.isShuffled ? "Shuffle on" : "Shuffle off") {
                    playback.toggleShuffle()
                }
                .frame(width: Self.transportColumns[0])
                Spacer(minLength: 12)
            }
            TransportSkipButton(travel: .backward,
                                direction: snapshot.transportDirection,
                                generation: snapshot.transportGeneration,
                                isEnabled: snapshot.hasPrevious,
                                label: "Previous") { playback.previous() }
                .frame(width: Self.transportColumns[1])
            if modes { Spacer(minLength: 12) }
            PlayPauseButton(playing: playing,
                            buffering: snapshot.status == .buffering) { playback.togglePlayPause() }
                .frame(width: Self.transportColumns[2])
            if modes { Spacer(minLength: 12) }
            TransportSkipButton(travel: .forward,
                                direction: snapshot.transportDirection,
                                generation: snapshot.transportGeneration,
                                isEnabled: snapshot.hasNext,
                                label: "Next") { playback.next() }
                .frame(width: Self.transportColumns[3])
            // One glyph for all three repeat modes, as the queue's pill did —
            // there is no repeat-one icon in this set, and the state is carried
            // by the accent and read out by the label.
            if modes {
                Spacer(minLength: 12)
                PlayerIconButton(glyph: .repeatTracks,
                                 glyphSize: 22,
                                 tint: mode != .off ? .primary : .secondary,
                                 haptics: false,
                                 label: mode == .one ? "Repeat one"
                                      : (mode == .all ? "Repeat all" : "Repeat off")) {
                    playback.cycleRepeatMode()
                }
                .frame(width: Self.transportColumns[4])
            }
        }
    }

    /// The bottom control row: the lyrics toggle, the current-output-route control
    /// (shows the real device icon; tap to open the AirPlay picker), and the queue
    /// toggle. The two panel toggles are mutually exclusive — they share one slot —
    /// so tapping one while the other is open swaps between them.
    /// (The equalizer lives in Settings for now.)
    private var bottomButtonRow: some View {
        // The transport's grid, with its outer two columns left empty: lyrics
        // lands under previous, AirPlay under play, queue under next. Aligning
        // them by eye with a different padding is what had them drifting apart
        // at every width except the one it was tuned on.
        HStack(spacing: Self.transportGap) {
            lyricsToggle.frame(width: Self.transportColumns[1])
            #if canImport(UIKit)
            routeControl.frame(width: Self.transportColumns[2])
            #endif
            queueToggle.frame(width: Self.transportColumns[3])
        }
    }

    /// The same three controls, arranged for a window with two columns: the
    /// output route under the record it belongs to, the two panel toggles over
    /// on the side the panel occupies. One row spanning both columns rather than
    /// one per column, so the three keep a shared baseline.
    private func wideButtonRow(_ m: Morph) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                #if canImport(UIKit)
                routeControl
                #endif
                Spacer(minLength: 12)
                // The pair sits together: they share a job, and a gap between
                // them would read as two unrelated controls.
                HStack(spacing: 18) {
                    lyricsToggle
                    queueToggle
                }
            }
            .padding(.horizontal, 32)
            #if canImport(UIKit)
            routeLabel
            #endif
        }
        // Clear of the surface's off-screen overhang, exactly as the single-column
        // row is — this is the element that owns the bottom edge here.
        .padding(.bottom, Morph.bottomOverhang + m.safeBottom + 12)
        .opacity(chromeHidden ? 0 : 1)
        .offset(y: chromeHidden ? Self.reorderChromeDrop : 0)
        .allowsHitTesting(!chromeHidden)
    }

    /// Whether the lookup has settled on "this song has none".
    ///
    /// `.silent` counts: it is a cached negative being quietly re-checked, and
    /// while that runs the panel shows a blank column — which is a worse answer
    /// than saying so. `.idle` and `.loading` do not: we do not know yet, and a
    /// control that dims and then un-dims a second later is its own bug.
    private var lyricsMissing: Bool {
        switch lyrics.state {
        case .unavailable, .silent: return true
        case .idle, .loading, .loaded: return false
        }
    }

    private var lyricsToggle: some View {
        // Still live while the panel is open, whatever the new track turned out
        // to have: the control that opened it has to be the one that closes it.
        let missing = lyricsMissing && panelWantsOpen != .lyrics
        return PlayerIconButton(glyph: .lyrics,
                                tint: panelWantsOpen == .lyrics ? .primary : .secondary,
                                haptics: false,
                                isActive: panelWantsOpen == .lyrics,
                                label: "Lyrics") {
            // Dimmed but not `disabled`: a control that does nothing at all
            // leaves you tapping it to find out why. It says why instead.
            guard !missing else {
                toasts.confirm("No lyrics for this song", icon: "text.quote")
                return
            }
            setPanel(panelWantsOpen == .lyrics ? nil : .lyrics)
        }
        // The same 0.35 `PlayerIconButton` dims a disabled control to, applied
        // from outside so the button stays tappable.
        .opacity(missing ? 0.35 : 1)
        .accessibilityHint(missing ? "No lyrics for this song" : "")
    }

    private var queueToggle: some View {
        PlayerIconButton(glyph: .queue,
                         tint: panelWantsOpen == .queue ? .primary : .secondary,
                         haptics: false,
                         isActive: panelWantsOpen == .queue,
                         label: "Queue") {
            setPanel(panelWantsOpen == .queue ? nil : .queue)
        }
    }

    #if canImport(UIKit)
    /// The output-route control: the real device icon (AirPods / headphones /
    /// AirPlay / car / TV / speaker) drawn over an invisible `AVRoutePickerView`
    /// (so a tap still opens the system picker). Tinted to signal when audio is
    /// routed off the phone speaker.
    private var routeControl: some View {
        ZStack {
            AirPlayRoutePicker(tint: .clear)   // invisible glyph, still tappable
            Image(systemName: routeMonitor.output.icon)
                .font(.system(size: PlayerControlMetrics.routeGlyph))
                .foregroundStyle(routeMonitor.output.showsLabel ? Color.primary : Color.secondary)
                .allowsHitTesting(false)
        }
        .frame(width: PlayerControlMetrics.minHit, height: PlayerControlMetrics.minHit)
    }

    /// The route line under the controls. For external speakers/rooms (AirPlay,
    /// CarPlay, TV) it reads "iPhone → Name"; for personal audio (AirPods,
    /// headphones) just the device name; nothing on the built-in speaker — like
    /// Apple Music.
    @ViewBuilder private var routeLabel: some View {
        let out = routeMonitor.output
        if out.showsLabel {
            HStack(spacing: 5) {
                if out.showsSourcePrefix {
                    Text("iPhone").foregroundStyle(.secondary)
                    Image(mozz: "arrow.forward").font(.caption2).foregroundStyle(.secondary)
                }
                Text(out.name).foregroundStyle(.primary)
            }
            .font(.footnote)
            .lineLimit(1)
        }
    }
    #endif
}

// MARK: - Island content (self-contained: swipe + title/artist slide)

/// Shared spring for the island text slide.
private let islandTextSpring = Animation.spring(response: 0.34, dampingFraction: 1.0)
/// The outgoing (leaving) title/artist clears out faster than the incoming
/// settles, so the old text doesn't linger under the new one.
private let islandExitAnimation = Animation.easeOut(duration: 0.20)
/// The outgoing text aims WELL past the zone edge (this × zoneW), so it becomes
/// fully hidden early in the ease (during its fast part) rather than only at the
/// decelerating tail — otherwise a long title's tail lingers as the new one
/// settles. It's off-screen for the slow remainder, so the overshoot is unseen.
private let islandExitOvershoot: CGFloat = 1.9
/// The incoming text STARTS this far past the edge (× zoneW), beyond the fade, so
/// the spring's fast initial burst happens off-screen and the visible motion is
/// the slower settle — it reads as sliding in from the edge, not appearing
/// mid-zone. Symmetric with the exit overshoot.
private let islandEnterOvershoot: CGFloat = 1.9

// MARK: - Marquee (classic music-player horizontal scroll for overflowing text)

/// How fast the marquee glides (points per second). Slow enough to read.
private let marqueeSpeed: CGFloat = 26
/// Overflow smaller than this doesn't bother scrolling (a couple clipped pixels
/// aren't worth the motion).
private let marqueeMinOverflow: CGFloat = 8
/// Dwell at the start before scrolling out, and at the end before returning, so
/// the reader can catch the beginning/end of the line.
private let marqueeStartDwell: Duration = .milliseconds(2600)
private let marqueeEndDwell: Duration = .milliseconds(1100)
/// A tiny settle pause between the return finishing and the next cycle starting.
private let marqueeLoopGap: Duration = .milliseconds(250)
/// Spring used to ease the title back to home (offset 0) when a glide is
/// interrupted — by a collapse/expand morph or a swipe. Roughly matches the
/// scroll-minimize morph spring so the text returns in lockstep with the pill
/// instead of teleporting.
private let marqueeReturn = Animation.spring(response: 0.45, dampingFraction: 0.9)

/// Publishes a measured intrinsic (untruncated) text width up the view tree.
private struct MarqueeWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Publishes the width actually available to a ``MarqueeLine`` (its own frame),
/// which is what decides whether the text overflows and by how much.
private struct MarqueeZoneWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One line of text that scrolls its overflow instead of truncating it.
///
/// The island has its own marquee welded into ``IslandSlideText`` (which also
/// owns the swipe cross-slide), so this is the standalone version for anywhere
/// that just needs "long text shouldn't end in an ellipsis" — currently the
/// expanded player's title and artist. Same tuning constants as the island, so
/// both surfaces scroll at one speed and dwell for the same beats.
///
/// Font and colour come from the environment, so callers style it exactly like
/// the `Text` it replaces. Both edges soft-fade rather than hard-clip; the
/// leading fade only appears while the line is away from home, so a parked line
/// starts flush with everything below it.
private struct MarqueeLine: View {
    let text: String
    /// Width of the soft edge ramp. Kept modest so it dissolves the overflow
    /// without visibly dimming a line that only just overflows.
    var fade: CGFloat = 14
    /// How far the scrolling text may run PAST its own leading edge before it
    /// fades out. The player passes its side inset here, so a scrolling title
    /// runs into the margin and dissolves at the screen edge rather than
    /// stopping short at the text column — the head gets the full width of the
    /// screen to travel through, and the ramp reads as part of the display
    /// rather than as a box the text lives in.
    var leadBleed: CGFloat = 0
    /// Same idea at the other end: how far the line may run past its trailing
    /// edge before fading. The gap to the star plus the dead space inside the
    /// star's 44pt touch target is otherwise unusable, which left the fade
    /// finishing well short of the glyph.
    var trailBleed: CGFloat = 0

    /// Intrinsic (untruncated) width, measured off the real label.
    @State private var naturalW: CGFloat = 0
    /// The width this line is allowed to occupy.
    @State private var zoneW: CGFloat = 0
    @State private var marqueeX: CGFloat = 0
    /// True for the whole out-and-back cycle. Drives the leading fade, so the
    /// mask only ever changes while the text is parked — never mid-glide, which
    /// would pop the ramp on or off under the moving glyphs.
    @State private var gliding = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A hidden, NON-fixedSize twin does the layout: a plain one-line `Text`
        // compresses to whatever the row can spare, exactly like the label this
        // replaces, so the line can never push its neighbours off the row. The
        // real (unclipped, scrolling) label rides in an overlay, which by
        // definition contributes nothing to layout.
        //
        // Getting this wrong is loud: with `fixedSize` in the layout path the
        // block reports the title's full intrinsic width, the row grows past the
        // screen, and the title renders half off the left edge with the star and
        // overflow buttons pushed out of sight.
        Text(text)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { g in
                    Color.clear.preference(key: MarqueeZoneWidthKey.self, value: g.size.width)
                }
            }
            .overlay(alignment: .leading) {
                Text(text)
                    .lineLimit(1)
                    // Full intrinsic width: never truncates, so there's a real
                    // tail to reveal and no ellipsis to swap mid-animation.
                    .fixedSize(horizontal: true, vertical: false)
                    .background(alignment: .leading) {
                        GeometryReader { g in
                            Color.clear.preference(key: MarqueeWidthKey.self, value: g.size.width)
                        }
                    }
                    .offset(x: marqueeX)
            }
            // Widen the maskable region to the LEFT by the bleed, fade inside
            // that widened region, then take the width back with a negative
            // padding so layout is untouched. The strip the ramp now lives in is
            // the row's own margin, so the text dissolves at the screen edge
            // while everything below still lines up on the inset.
            .padding(.leading, leadBleed)
            .padding(.trailing, trailBleed)
            .mask(fadeMask)
            .padding(.leading, -leadBleed)
            .padding(.trailing, -trailBleed)
            .onPreferenceChange(MarqueeWidthKey.self) { naturalW = $0 }
            .onPreferenceChange(MarqueeZoneWidthKey.self) { zoneW = $0 }
            .task(id: marqueeKey) { await drive() }
            .onChange(of: text) { _, _ in
                // A new track paints at the previous line's scroll offset unless
                // we park it first — and animating that would look like the new
                // title sliding in from nowhere.
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { marqueeX = 0; gliding = false }
            }
    }

    @MainActor
    private func drive() async {
        guard active else {
            if marqueeX != 0 { withAnimation(marqueeReturn) { marqueeX = 0 } }
            gliding = false
            return
        }
        // Travel the overflow PLUS whatever the trailing ramp still covers after
        // the bleed. Stopping at the bare overflow parks the tail underneath the
        // fade, so a title that had scrolled the whole way still looked clipped
        // at exactly the moment the reader wanted those glyphs.
        let dist = overflow + max(0, fade - trailBleed)
        let dur = Double(dist / marqueeSpeed)
        // Ease home first if a previous run (or a resize mid-scroll) left the
        // line off-home, so a cycle always starts from the beginning.
        if marqueeX != 0 { withAnimation(marqueeReturn) { marqueeX = 0 } }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: marqueeStartDwell)
                gliding = true
                withAnimation(.linear(duration: dur)) { marqueeX = -dist }
                try await Task.sleep(for: .seconds(dur))
                try await Task.sleep(for: marqueeEndDwell)
                withAnimation(.linear(duration: dur)) { marqueeX = 0 }
                try await Task.sleep(for: .seconds(dur))
                gliding = false
                try await Task.sleep(for: marqueeLoopGap)
            } catch {
                // Cancelled: a fresh run owns the offset and will ease it home.
                return
            }
        }
    }

    private var overflow: CGFloat { max(0, naturalW - zoneW) }

    private var active: Bool {
        !reduceMotion && !text.isEmpty && overflow > marqueeMinOverflow && zoneW > 0
    }

    /// Identity for the driver: a new track, a real width change, or losing/
    /// gaining overflow restarts it from the first dwell. Width is bucketed so
    /// sub-pixel layout jitter doesn't churn the task.
    private var marqueeKey: String {
        "\(text)|\(Int((zoneW / 3).rounded()))|\(Int(naturalW.rounded()))|\(active ? 1 : 0)"
    }

    /// Soft ramps at the edges instead of a hard cut. The trailing ramp is there
    /// whenever the line overflows (that's the "there's more" cue that replaces
    /// the ellipsis); the leading one only while scrolled away from home, and it
    /// spans the whole bleed strip so the head dissolves gradually across the
    /// margin rather than snapping off at the text column.
    private var fadeMask: some View {
        let total = max(zoneW + leadBleed + trailBleed, 1)
        let leadWidth = max(leadBleed, fade)
        let lead = gliding ? min(leadWidth / total, 0.5) : 0
        let trail = overflow > 0 ? min(fade / total, 0.4) : 0
        return LinearGradient(
            stops: [
                .init(color: lead > 0 ? .clear : .black, location: 0),
                .init(color: .black, location: lead),
                .init(color: .black, location: 1 - trail),
                .init(color: trail > 0 ? .clear : .black, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
    }
}

/// Publishes the measured height of the transport-chrome region up the view tree,
/// so the queue panel knows how far it may grow into the reclaimed space during a
/// drag-reorder.
/// Where the expanded artwork's reserved slot actually landed, in the drawer
/// body's coordinate space. See `artSlot`.
struct ArtSlotKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

struct PlayerArtworkSlotObserver: ViewModifier {
    @Binding var rect: CGRect?
    let animation: Animation?

    func body(content: Content) -> some View {
        content.onPreferenceChange(ArtSlotKey.self) { target in
            // Preference delivery loses the layout's spring transaction.
            // Restore it for the separately positioned cover, but not its first placement.
            withAnimation(rect == nil ? nil : animation) { rect = target }
        }
    }
}

private struct ChromeRegionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Live press state for the docked island. `@Observable` so SwiftUI's
/// per-property observation re-renders only the views that read a given field:
/// the whole-island scale reads `pressed` (toggles ~twice per touch), while the
/// finger-following glow reads `location` (updates every move) — so tracking the
/// finger never re-renders the heavy morph container.
@Observable @MainActor final class IslandPressState {
    var pressed = false
    /// Glow opacity (0…1). Fades in fast on touch, out slowly on release.
    var glow: Double = 0
    /// Horizontal spread of the glow (1 = natural). On release it grows so the
    /// light blooms outward left/right along the rail as it fades — like Apple's.
    var spread: CGFloat = 1
    /// Touch point in island-pill-local coordinates (0…islandW, 0…islandHeight).
    var location: CGPoint = .zero
}

/// A soft specular highlight on the island glass that follows the finger — our
/// own take on Apple's interactive Liquid Glass glow. It brightens the glass with
/// a radial `plusLighter` pool centred on the touch, clipped to the pill and
/// fading with the press. Reading `press.location`/`press.pressed` here (and not
/// in the parent) keeps finger-tracking re-renders scoped to just this view.
private struct IslandGlow: View {
    var press: IslandPressState
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat

    var body: some View {
        // A narrow, dim core right under the finger that washes out very gradually
        // across a wide radius — a small bright point with a long, faint, far-
        // reaching tail (like Apple's), rather than a wide bright plateau.
        //
        // The centre is LOCKED to the rail vertically (y = 0.5) and clamped to the
        // pill horizontally, so — like Apple — dragging your finger off the island
        // never lets the highlight leave it: it just slides along the rail and
        // stays put at the nearest edge.
        //
        // On release the whole gradient is stretched horizontally about the touch
        // point (`spread`) as it fades (`glow`), so the light blooms outward to the
        // left and right along the rail before dissipating — clipped to the pill.
        let nx = min(max(press.location.x / max(width, 1), 0), 1)
        return RadialGradient(
            stops: [
                .init(color: .white.opacity(0.15),  location: 0.0),
                .init(color: .white.opacity(0.12),  location: 0.12),
                .init(color: .white.opacity(0.075), location: 0.28),
                .init(color: .white.opacity(0.038), location: 0.50),
                .init(color: .white.opacity(0.014), location: 0.74),
                .init(color: .white.opacity(0.0),   location: 1.0),
            ],
            center: UnitPoint(x: nx, y: 0.5),
            startRadius: 0, endRadius: 280)
        .frame(width: width, height: height)
        .scaleEffect(x: press.spread, y: 1, anchor: UnitPoint(x: nx, y: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .blendMode(.plusLighter)
        .opacity(press.glow)
        .allowsHitTesting(false)
    }
}

/// The docked island's content row: [artwork slot][title/artist][play][next].
///
/// It's a self-contained view so an in-island swipe re-renders ONLY this view,
/// not the whole full-player overlay. While swiping, the title/artist follow the
/// thumb; on release past a threshold it changes track and the title/artist
/// slide across (incoming always from the correct fixed side); otherwise they
/// spring back. Only a swipe animates — every other change (opening a song,
/// auto-advance, the buttons) swaps instantly. The traveling artwork is owned by
/// the parent, so this only reserves its slot.
private struct IslandContent: View {
    var playback: MusicPlayerAdapter
    var onExpand: () -> Void
    /// How far the island has dropped into the tab bar's centre pill (0…1). At 1
    /// the skip/next button is gone (Apple's minimized island keeps only
    /// play/pause), giving the narrower pill more room for the title/artist.
    var collapse: CGFloat = 0
    /// The pill's current content width (from the parent's morph). Drives the text
    /// zone width DETERMINISTICALLY — the old measure→pin→remeasure loop kept the
    /// labels full-island-wide when the pill collapsed, so text spilled left and
    /// the buttons overflowed onto the Search circle.
    var pillWidth: CGFloat = 0
    /// The DOCKED (largest) pill width. The text truncates once at this width so it
    /// doesn't re-truncate (which "races" the ellipsis) as the pill narrows during
    /// the collapse — the narrowing pill just clips the tail instead.
    var maxPillWidth: CGFloat = 0
    /// Whether the pill has room for the controls a phone-width one cannot fit.
    ///
    /// On a phone the pill is the screen's width less a margin, and artwork plus a
    /// title plus five controls is a row of things too small to hit. On a tablet
    /// the space is there, and reaching into the player to shuffle is a trip you
    /// should not have to make. Android's line, and its reasoning.
    var wide: Bool = false

    @State private var dragX: CGFloat = 0        // live thumb-follow (0 at rest)
    @State private var navDir = 1                // +1 next, -1 previous
    @State private var animateSwipe = false      // true only for a swipe commit
    @State private var commitStart: CGFloat = 0  // finger offset at commit
    @State private var commitTick = 0            // bumped to fire a haptic pop
    @State private var armedDir = 0              // side currently past the threshold

    /// Text-zone width for a given pill width + collapse: the pill minus the fixed
    /// row parts (leading inset, artwork, gaps, play button, collapsing skip,
    /// trailing inset). Deterministic — no measurement, no feedback loop.
    private func zoneWidth(pill: CGFloat, collapse: CGFloat) -> CGFloat {
        let skip = (30 + 10) * (1 - collapse)     // skip button + its HStack gap
        // Previous, shuffle and repeat, when the pill is wide enough to carry
        // them. They collapse away with the skip, since a pill dropped into the
        // tab bar is never wide.
        let extras = wide ? 3 * (30 + 10) * (1 - collapse) : 0
        let fixed = Morph.islandArtLeading        // 20 leading inset
                  + Morph.islandArtSide           // 34 artwork
                  + 10                            // artwork → text gap
                  + 10                            // text → play gap
                  + 30                            // play button
                  + skip
                  + extras
                  + Morph.islandContentPad        // 12 trailing inset
        return max(pill - fixed, 1)
    }
    /// Current text-zone width (drives layout so the play button sits correctly).
    private var zoneW: CGFloat { zoneWidth(pill: pillWidth, collapse: collapse) }
    /// Docked text-zone width — the stable width the text truncates at.
    private var stableZoneW: CGFloat {
        zoneWidth(pill: max(maxPillWidth, pillWidth), collapse: 0)
    }
    // A text line locks (stays put, ignores the thumb) when the track it'd change
    // to shares that line's text — so the artist never "scrolls" when swiping
    // between same-artist tracks. Set at drag time so they stay correct through
    // the commit settle (when currentTrack has already advanced).
    @State private var lockTitle = false
    @State private var lockArtist = false

    /// Scales with Dynamic Type (10 at default) so we can subtract its growth from
    /// the title/artist line spacing — the two lines pull together at large sizes,
    /// where the stacked line-heights otherwise leave a big gap, while default
    /// sizes are left untouched.
    @ScaledMetric(relativeTo: .subheadline) private var typeUnit: CGFloat = 10
    private var titleArtistSpacing: CGFloat { max(-8, 1 - (typeUnit - 10)) }
    /// Upward nudge to visually centre the text glyphs (font line boxes pad the
    /// top more than the bottom). Scales with type: ~0.5pt at default, ~0.7pt at
    /// xxxLarge — where the ~4px imbalance is actually visible.
    @ScaledMetric(relativeTo: .subheadline) private var textVerticalNudge: CGFloat = 0.5

    /// Width of the soft fade at each edge of the text zone — the outgoing/incoming
    /// (and live-drag) title/artist dissolve through it instead of hard-clipping.
    /// Matches the artwork↔text gap (the inner HStack spacing) so the fade sits in
    /// that gap: the resting text is fully opaque, and text only dissolves as it
    /// slides into the gap.
    private static let textEdgeFade: CGFloat = 10
    /// The left fade ends this far short of the artwork (1pt), so it clears just to
    /// the RIGHT of the artwork rather than exactly at its edge.
    private static let textLeftFadeInset: CGFloat = 1
    private static var textLeftFade: CGFloat { textEdgeFade - textLeftFadeInset }
    /// The RIGHT fade is longer than the gap so the tail dissolves gradually into
    /// the play button (a softer, longer ramp than the left).
    private static let textRightFade: CGFloat = textEdgeFade + 12

    /// Horizontal fade mask applied over the text zone AFTER it's been expanded by
    /// the fade widths on each side (see body). The clear→opaque ramps therefore
    /// fall in those expansion strips — the gaps to the artwork (left) and the play
    /// button (right) — leaving the whole measured text area opaque. The left strip
    /// is 1pt narrower so it clears just right of the artwork.
    private var edgeFadeMask: some View {
        let padded = zoneW + Self.textLeftFade + Self.textRightFade
        let leftFrac = min(Self.textLeftFade / max(padded, 1), 0.5)
        let rightFrac = min(Self.textRightFade / max(padded, 1), 0.5)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: leftFrac),
                .init(color: .black, location: 1 - rightFrac),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        HStack(spacing: 10) {
            // The artwork + titles zone owns all island touch handling (press,
            // tap-open, swipe). A single high-priority gesture claims the touch
            // immediately, so there's no scroll/tap disambiguation delay — press
            // feedback is instant. The play/next buttons are SIBLINGS (outside
            // this gesture) so they keep working.
            HStack(spacing: 10) {
                Color.clear.frame(width: Morph.islandArtSide, height: Morph.islandArtSide)

                VStack(alignment: .leading, spacing: titleArtistSpacing) {
                    IslandSlideText(text: playback.currentTrack?.title ?? "",
                                    dir: navDir, zoneW: zoneW, renderW: stableZoneW, animate: animateSwipe,
                                    liveDrag: lockTitle ? 0 : dragX, commitStart: commitStart,
                                    font: .subheadline.weight(.semibold), secondary: false, marquees: true)
                    IslandSlideText(text: playback.currentTrack?.artistName ?? "",
                                    dir: navDir, zoneW: zoneW, renderW: stableZoneW, animate: animateSwipe,
                                    liveDrag: lockArtist ? 0 : dragX, commitStart: commitStart,
                                    font: .caption2, secondary: true, marquees: false)
                }
                // Hard-constrain the text column to the CURRENT zone width (which
                // shrinks as the pill collapses) and left-align, so the play button
                // stays pinned to the right and the stable-width labels overflow to
                // the right where the mask below clips them — no re-truncation.
                .frame(width: zoneW, alignment: .leading)
                // Soft fade at the zone edges (replaces a hard clip): the sliding
                // text dissolves as it enters/leaves. Expand the maskable region by
                // the fade width on each side, apply the fade there, then restore
                // the layout with negative padding — so the ramps live in the gaps
                // (to the artwork on the left, the play button on the right) and the
                // resting text stays fully opaque. The left strip is 1pt narrower so
                // the fade clears just to the right of the artwork, not on its edge.
                .padding(.leading, Self.textLeftFade)
                .padding(.trailing, Self.textRightFade)
                .mask(edgeFadeMask)
                .padding(.leading, -Self.textLeftFade)
                .padding(.trailing, -Self.textRightFade)
                // Nudge the text block up to correct font line-box asymmetry (the
                // glyphs sit slightly low inside their line boxes, so the visual
                // top gap is larger than the bottom). Scales with Dynamic Type, so
                // it's imperceptible at default and evens out the gap at xxxLarge.
                .offset(y: -textVerticalNudge)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(islandGesture)

            if wide {
                islandExtra(AppIcon.shuffle,
                            active: playback.snapshot.isShuffled,
                            label: playback.snapshot.isShuffled ? "Shuffle on" : "Shuffle off") {
                    playback.toggleShuffle()
                }
            }

            if wide {
                // Only here. On a phone-width pill the row is artwork, a title
                // and two controls; a third would make all of them harder to
                // hit than any of them is worth.
                Button {
                    commitTick &+= 1
                    changeTrack(goNext: false, from: 0)
                } label: {
                    AppIcon.skipBack.styled(size: 22)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!playback.snapshot.hasPrevious)
                .accessibilityLabel("Previous")
                .opacity((playback.snapshot.hasPrevious ? 1 : 0.4) * Double(1 - collapse))
                .frame(width: 30 * (1 - collapse))
                .allowsHitTesting(collapse < 0.5)
            }

            PlayPauseButton(
                playing: playback.snapshot.status == .playing,
                buffering: playback.snapshot.status == .buffering,
                glyphSize: wide ? 30 : 20,
                hitSize: 30
            ) { playback.togglePlayPause() }

            Button {
                // Skip button runs the same slide as a swipe (from rest).
                commitTick &+= 1
                changeTrack(goNext: true, from: 0)
            } label: {
                AppIcon.skipForward.styled(size: wide ? 22 : 24)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!playback.snapshot.hasNext)
            // Fades out and collapses its width as the island drops into the centre
            // pill, so the minimized island keeps only play/pause (like Apple's).
            .opacity((playback.snapshot.hasNext ? 1 : 0.4) * Double(1 - collapse))
            .frame(width: 30 * (1 - collapse))
            .allowsHitTesting(collapse < 0.5)

            if wide {
                let mode = playback.snapshot.repeatMode
                // One glyph for all three modes, as the queue's own pill does —
                // there is no repeat-one icon in this set, and the state is
                // carried by the accent and read out by the label.
                islandExtra(AppIcon.repeatTracks,
                            active: mode != .off,
                            label: mode == .one ? "Repeat one"
                                 : (mode == .all ? "Repeat all" : "Repeat off")) {
                    playback.cycleRepeatMode()
                }
            }
        }
        .padding(.leading, Morph.islandArtLeading)
        .padding(.trailing, Morph.islandContentPad)
        // Subtle "pop" the instant a swipe crosses the threshold / a commit fires.
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.9), trigger: commitTick)
        // Cap Dynamic Type so the compact island doesn't blow up at the large
        // accessibility sizes and overflow the pill — the same thing Apple does
        // for the tab bar / now-playing bar. Standard sizes still scale.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// One of the wide pill's extra controls. Same 30pt box as the transport
    /// buttons beside it, dimmed when the mode is off, and collapsing away with
    /// them if the pill ever drops into the tab bar.
    private func islandExtra(_ icon: AppIcon, active: Bool, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon.styled(size: 18)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .foregroundStyle(active ? AnyShapeStyle(Color.musicPlayerAccent)
                                : AnyShapeStyle(Color.secondary))
        .opacity(Double(1 - collapse))
        .frame(width: 30 * (1 - collapse))
        .allowsHitTesting(collapse < 0.5)
    }

    /// Lock a title/artist line (stops it following the thumb) when the track the
    /// current drag direction would land on shares that line's text — so the line
    /// never "scrolls" only to spring back. `previous()` restarts the current
    /// track when >3s in, so in that case the target IS the current track (both
    /// lines unchanged). No target (nothing to skip to) ⇒ no lock, so the
    /// rubber-band feedback is preserved.
    private func updateLineLocks(goNext: Bool) {
        let target: Track? = goNext
            ? playback.peekNextTrack
            : (playback.snapshot.elapsed > 3 ? playback.currentTrack : playback.peekPreviousTrack)
        guard let target else { lockTitle = false; lockArtist = false; return }
        let cur = playback.currentTrack
        lockTitle = (target.title) == (cur?.title ?? "")
        lockArtist = (target.artistName) == (cur?.artistName ?? "")
    }

    /// Shared slide-commit used by both the swipe and the skip button. `startX`
    /// is where the outgoing line begins its exit (the finger's release position
    /// for a swipe, or 0 for a button press from rest).
    private func changeTrack(goNext: Bool, from startX: CGFloat) {
        commitStart = startX
        animateSwipe = true
        navDir = goNext ? 1 : -1
        if goNext { playback.next() } else { playback.previous() }
        withAnimation(islandTextSpring) { dragX = 0 }
        DispatchQueue.main.async { animateSwipe = false }
    }

    private static let commitDist: CGFloat = 55   // drag distance that arms a commit
    private static let tapSlop: CGFloat = 8         // movement under this = a tap
    private static let openDist: CGFloat = 40       // upward drag that opens the player

    /// One high-priority gesture for the artwork+titles zone: tap or swipe-up to
    /// open, horizontal swipe to change track. (Press-scale is handled separately
    /// by the parent's whole-pill touch-down reader.)
    private var islandGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let w = value.translation.width, h = value.translation.height
                guard abs(w) > abs(h), abs(w) > Self.tapSlop else {
                    if dragX != 0 { dragX = 0 }    // vertical / tap: don't follow
                    armedDir = 0
                    lockTitle = false; lockArtist = false
                    return
                }
                let canGo = w < 0
                    ? playback.snapshot.hasNext
                    : (playback.snapshot.hasPrevious || playback.snapshot.elapsed > 3)
                dragX = canGo ? w : w * 0.3
                updateLineLocks(goNext: w < 0)
                var qual = 0
                if w <= -Self.commitDist, playback.snapshot.hasNext { qual = 1 }
                else if w >= Self.commitDist,
                        playback.snapshot.hasPrevious || playback.snapshot.elapsed > 3 { qual = -1 }
                if qual != 0, qual != armedDir { commitTick &+= 1 }
                armedDir = qual
            }
            .onEnded { value in
                let w = value.translation.width, h = value.translation.height
                let pw = value.predictedEndTranslation.width
                let ph = value.predictedEndTranslation.height
                armedDir = 0
                // Barely moved → tap → open.
                if abs(w) < Self.tapSlop, abs(h) < Self.tapSlop { onExpand(); return }
                if abs(w) > abs(h) {
                    let goNext = (w < -Self.commitDist || pw < -140) && playback.snapshot.hasNext
                    let goPrev = (w > Self.commitDist || pw > 140)
                        && (playback.snapshot.hasPrevious || playback.snapshot.elapsed > 3)
                    if goNext || goPrev {
                        commitTick &+= 1
                        changeTrack(goNext: goNext, from: dragX)
                    } else {
                        withAnimation(islandTextSpring) { dragX = 0 }
                    }
                } else {
                    // Vertical up → open.
                    if h < -Self.openDist || ph < -120 { onExpand() }
                    withAnimation(islandTextSpring) { dragX = 0 }
                }
            }
    }
}

/// A single line of island text.
///
/// At rest / while dragging it shows one string offset by `liveDrag` (the zone
/// follows the thumb). On a swipe-driven change (`animate`) it renders BOTH the
/// outgoing and incoming strings: the outgoing continues off from the finger's
/// release position (`commitStart`), the incoming ALWAYS enters from the correct
/// fixed side (`+zoneW` for next, `-zoneW` for previous) — independent of how far
/// you dragged, so a big swipe can't make it come from the wrong side. Both lines
/// use the same fixed sides, so title + artist stay in sync, and computing both
/// from the current `dir` in one pass prevents forward/back intersection. Any
/// non-swipe change swaps instantly. `dir`: +1 next (moves left), -1 previous.
private struct IslandSlideText: View {
    let text: String
    let dir: Int
    let zoneW: CGFloat
    /// Fixed width the label renders (and truncates) at. Held constant during the
    /// collapse DROP so the title doesn't re-truncate — which SwiftUI would animate
    /// as a snapshot cross-fade ("the ellipsis flies off, the full text fades in").
    /// The narrowing pill clips the tail instead. Equals `zoneW` while docked.
    let renderW: CGFloat
    let animate: Bool
    let liveDrag: CGFloat
    let commitStart: CGFloat
    let font: Font
    let secondary: Bool
    /// Whether this line is allowed to auto-scroll (marquee) when it overflows. Only
    /// the title opts in: running the title AND artist together desynced into a busy
    /// double-scroll, so the artist stays put and just clips.
    let marquees: Bool

    @State private var current: String
    @State private var outgoing: String?
    @State private var currentX: CGFloat = 0
    @State private var outgoingX: CGFloat = 0
    @State private var transitioning = false
    @State private var gen = 0
    /// Intrinsic (untruncated) width of `current`, measured off-screen. Drives
    /// whether the line needs to scroll and how far.
    @State private var naturalW: CGFloat = 0
    /// Live marquee scroll offset (0 = start, negative = scrolled left to reveal
    /// the tail). Driven entirely by the marquee task, which eases it back to 0
    /// (never snaps) whenever a glide is interrupted, so the offset can be read
    /// directly with no gating flag.
    @State private var marqueeX: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(text: String, dir: Int, zoneW: CGFloat, renderW: CGFloat, animate: Bool,
         liveDrag: CGFloat, commitStart: CGFloat, font: Font, secondary: Bool,
         marquees: Bool) {
        self.text = text; self.dir = dir; self.zoneW = zoneW; self.renderW = renderW
        self.animate = animate
        self.liveDrag = liveDrag; self.commitStart = commitStart
        self.font = font; self.secondary = secondary; self.marquees = marquees
        _current = State(initialValue: text)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if let outgoing {
                label(outgoing).offset(x: outgoingX)
            }
            // ONE label structure in every state (no conditional view swap) so the
            // morph never cross-fades between a truncated and a full-width variant —
            // that swap is what made the title "race" upward on collapse. `fixedSize`
            // means it never truncates, so there's a real tail for the marquee to
            // reveal and no re-truncation snapshot to animate.
            //
            // Offset priority: a swipe commit (currentX) wins; then a live finger
            // drag (liveDrag) so track-swipe follows the thumb; otherwise the marquee
            // (marqueeX, which the task holds at 0 whenever it isn't actively
            // gliding). No gating flag — marqueeX is authoritative at rest.
            label(current)
                .offset(x: transitioning ? currentX : (liveDrag != 0 ? liveDrag : marqueeX))
        }
        // Measure the intrinsic width off-screen so we know when (and how far) to
        // scroll. A background never affects the ZStack's own size.
        .background(alignment: .leading) { measuringLabel }
        .onPreferenceChange(MarqueeWidthKey.self) { naturalW = $0 }
        // One driver, keyed on marqueeKey (text, bucketed width, measured width,
        // active). It restarts on a real width change (a collapse/expand morph
        // crosses width buckets) or a track/state change, and auto-cancels when the
        // view goes away. Every marqueeX transition here is ANIMATED (linear glide,
        // or `marqueeReturn` easing back to home) — the task never snaps the offset,
        // so an interrupted glide eases back in lockstep with the morph instead of
        // teleporting. During a morph the task keeps restarting: each run eases to
        // home and re-enters the dwell (the next restart cancels it before it can
        // glide), so the text rides the morph parked at home, then resumes once the
        // width settles.
        .task(id: marqueeKey) {
            // Not scrollable in this state (short title, mid-swipe, reduce motion):
            // ease home (never snap) and bail.
            guard marqueeActive, overflow > marqueeMinOverflow else {
                if marqueeX != 0 { withAnimation(marqueeReturn) { marqueeX = 0 } }
                return
            }
            let dist = overflow
            let dur = Double(dist / marqueeSpeed)
            // Coordinated return: if a previous glide (or a mid-scroll morph) left the
            // text off-home, ease it back to 0 before the fresh cycle.
            if marqueeX != 0 { withAnimation(marqueeReturn) { marqueeX = 0 } }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: marqueeStartDwell)
                    withAnimation(.linear(duration: dur)) { marqueeX = -dist }
                    try await Task.sleep(for: .seconds(dur))
                    try await Task.sleep(for: marqueeEndDwell)
                    withAnimation(.linear(duration: dur)) { marqueeX = 0 }
                    try await Task.sleep(for: .seconds(dur))
                    try await Task.sleep(for: marqueeLoopGap)
                } catch {
                    // Cancelled (view gone or restarting): a fresh run owns marqueeX
                    // now and will ease it home, so don't write shared state here.
                    return
                }
            }
        }
        .onChange(of: text) { _, new in
            guard new != current else { return }
            guard animate else {                 // instant swap for non-swipe changes
                transitioning = false
                outgoing = nil
                current = new
                // Reset the marquee offset to home WITHOUT animating, or the new
                // title would paint at the previous title's scroll offset and then
                // visibly slide in when the task eases it home. (Swipe/skip changes
                // are masked by `transitioning`→`currentX`, but auto-advance and
                // library selection take this instant path.)
                if marqueeX != 0 {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { marqueeX = 0 }
                }
                return
            }
            let enter = dir > 0 ? zoneW * islandEnterOvershoot : -zoneW * islandEnterOvershoot  // incoming from the correct side, beyond the fade
            // Outgoing aims well past the edge so it's hidden early (fast part of
            // the ease), not only at the decelerating tail — no lingering tail on
            // long titles.
            let exit  = dir > 0 ? -zoneW * islandExitOvershoot : zoneW * islandExitOvershoot
            outgoing = current
            outgoingX = commitStart               // continue from the finger
            current = new
            currentX = enter
            transitioning = true
            gen += 1
            let token = gen
            // Defer one tick so the start offsets render, then slide to rest.
            // The incoming settles on `islandTextSpring`; the outgoing clears out
            // on the snappier `islandExitAnimation` so it leaves faster. State
            // cleanup rides the (slower) incoming so it fires after both settle.
            DispatchQueue.main.async {
                withAnimation(islandExitAnimation) {
                    outgoingX = exit
                }
                withAnimation(islandTextSpring) {
                    currentX = 0
                } completion: {
                    if gen == token { outgoing = nil; transitioning = false }
                }
            }
        }
    }

    /// ONE label used in every state. `fixedSize` gives it its full intrinsic width
    /// (never truncates), pinned to a stable `renderW` footprint so the overflow
    /// spills past the edges where the parent's fade mask dissolves it — and so the
    /// pill collapse never re-truncates (that recompute is what SwiftUI animated as
    /// a flying snapshot). The marquee scrolls this same view; the narrowing pill
    /// just clips more of it.
    private func label(_ s: String) -> some View {
        Text(s)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(width: renderW, alignment: .leading)
    }

    /// Off-screen twin used only to measure the intrinsic (untruncated) width.
    private var measuringLabel: some View {
        Text(current)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background(GeometryReader { g in
                Color.clear.preference(key: MarqueeWidthKey.self, value: g.size.width)
            })
            .hidden()
            .allowsHitTesting(false)
    }

    /// How far the text runs past the CURRENTLY VISIBLE width (`zoneW`, which shrinks
    /// as the island drops into the tab-bar pill) — so the collapsed pill scrolls
    /// its (larger) overflow too, not just the full-width resting island.
    private var overflow: CGFloat { max(0, naturalW - zoneW) }
    /// Scroll only at rest: never during a swipe or a finger drag, and never while
    /// the collapse morph is animating (`zoneW` is changing — see `marqueeKey`, which
    /// restarts the driver every frame of the morph and only settles once still).
    /// Honors Reduce Motion, and only runs when there's something to reveal.
    private var marqueeActive: Bool {
        marquees && !transitioning && liveDrag == 0 && !reduceMotion
            && overflow > marqueeMinOverflow && !current.isEmpty
    }
    /// Identity for the marquee driver: any change restarts it from the beginning.
    /// Uses a BUCKETED zoneW (see `widthBucket`) so sub-pixel jitter of the measured
    /// island frame doesn't churn the task; a real morph crosses buckets and restarts
    /// it (holding the text still), and once the width settles it runs, scrolled to
    /// that width's overflow.
    private var marqueeKey: String {
        "\(current)|\(Self.widthBucket(zoneW))|\(Int(naturalW.rounded()))|\(marqueeActive ? 1 : 0)"
    }

    /// Quantise a width to ~3pt buckets, so the imperceptible sub-pixel jitter of the
    /// measured native-accessory frame is ignored while genuine morph transitions
    /// (tens of points) still register.
    private static func widthBucket(_ w: CGFloat) -> Int { Int((w / 3).rounded()) }
}

// MARK: - Geometry

/// Applies the live drag-to-dismiss translation as a single `.offset`, reading
/// `dragY` through a binding. Because the parent passes `$dragY` (a binding, not
/// the value), the parent body registers NO dependency on `dragY`, so a drag
/// re-runs only this modifier and re-applies the offset to the already-built
/// drawer — it never re-executes the morph geometry or the heavy queue subtree.
/// This is the same re-render isolation the island glow/content already rely on.
private struct DragTranslate: ViewModifier {
    @Binding var dragY: CGFloat
    func body(content: Content) -> some View {
        content.offset(y: max(0, dragY))
    }
}

/// Fades a view OUT across a window `[start, end]` of an animated `progress`
/// (0 → 1): fully opaque before `start`, ramps 1 → 0 across the window, gone
/// after `end`. Back-loaded on purpose — the hero row uses it to climb (staying
/// visible) through the early part of the open, then dissolve as it hands off to
/// the card row + rising queue body. Implemented as an `Animatable` modifier so
/// SwiftUI samples the curve every frame: a plain `.opacity(...)` computed from
/// animated state only interpolates its start/end opacity along the spring, so
/// the window has no visible effect. Driving `animatableData` with `progress`
/// forces the windowed opacity to be evaluated per interpolated step.
private struct RangeFadeOut: ViewModifier, Animatable {
    var progress: CGFloat
    var start: CGFloat
    var end: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let span = max(0.0001, end - start)
        let t = min(1, max(0, (progress - start) / span))
        return content.opacity(Double(1 - t))
    }
}

/// Lifts the hero row UP by `distance`, completing the full climb by `end` (in
/// progress, 0 → 1) and holding there after — so the climb's duration is decoupled
/// from the whole transition. `Animatable` so SwiftUI samples the clamped ramp every
/// frame: a plain `.offset(y:)` from animated state would interpolate only the 0 and
/// -distance endpoints along the spring, linearizing the `end` clamp away.
private struct HeroLift: ViewModifier, Animatable {
    var progress: CGFloat
    var start: CGFloat
    var end: CGFloat
    var distance: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let span = max(0.0001, end - start)
        let t = min(1, max(0, (progress - start) / span))
        return content.offset(y: -distance * t)
    }
}

/// Holds a view pushed DOWN by `distance` until `progress` (0 → 1) passes `start`,
/// then rises it to rest by `progress = 1` — the delayed-entrance rise used by the
/// card row so its climb *and* fade (`LateFade`, same `start`) begin together, giving
/// a deliberate "comes in" rather than a slide that's already underway. `Animatable`
/// so the hold corner is sampled per frame: a plain `.offset(y:)` from animated state
/// would interpolate only the endpoints and linearize the hold away.
private struct GatedRise: ViewModifier, Animatable {
    var progress: CGFloat
    var start: CGFloat
    var distance: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let span = max(0.0001, 1 - start)
        let t = min(1, max(0, (progress - start) / span))
        return content.offset(y: (1 - t) * distance)
    }
}

/// Fades a view IN, but only after `progress` (0 → 1) passes `start`; before that
/// it stays fully transparent, then ramps 0 → 1 over the remaining `start…1` range.
/// The delayed-fade counterpart to `RangeFadeOut`, used for the queue card's title
/// + star so they "catch" the hero row after it has mostly lifted away. Must be
/// `Animatable` for the same reason as `RangeFadeOut`: a computed `.opacity` from
/// animated state would only interpolate its endpoints and skip the delay curve;
/// driving `animatableData` forces per-frame sampling of the delayed ramp.
private struct LateFade: ViewModifier, Animatable {
    var progress: CGFloat
    var start: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let span = max(0.0001, 1 - start)
        let o = min(1, max(0, (progress - start) / span))
        return content.opacity(Double(o))
    }
}

/// All frames and opacities are pure functions of `p` (and `queue`) and the
/// screen metrics, so the whole morph is deterministic and reversible. The live
/// finger translation (`dragY`) is applied OUTSIDE this geometry as a single
/// container offset (see `DragTranslate`) so a drag never re-derives the morph or
/// rebuilds the heavy queue subtree.
private struct Morph {
    let width: CGFloat
    let height: CGFloat
    let safeTop: CGFloat
    let safeBottom: CGFloat
    /// The horizontal safe area. Zero in portrait; on a phone laid sideways it is
    /// the notch's side, and the cover sat under it without this.
    let safeLeading: CGFloat
    let safeTrailing: CGFloat
    /// Raw spring value; may briefly leave [0,1]. Everything below uses the
    /// clamped `p`, so the spring's overshoot can't wobble the surface.
    let pRaw: CGFloat
    /// True during the collapse — enables the upward receive-bounce.
    let receiving: Bool
    /// Target state: `true` while expanded/opening, `false` while docked/collapsing.
    /// The mini controls are hidden whenever this is true, so the drawer opens
    /// OVER them (they never flash during an open).
    let isExpanded: Bool
    /// Tab-bar minimize progress (0…1). While docked, the island slides DOWN into
    /// the tab bar's centre pill as this →1. Unwound as the drawer expands.
    let minimize: CGFloat
    /// Queue-open progress (0 = hero cover big-center, 1 = cover docked into the
    /// queue's compact-header thumbnail slot). Only meaningful while fully expanded.
    let queue: CGFloat
    /// Left edge of the content area: the rail's gutter, or 0 with a bottom bar.
    let contentLeft: CGFloat
    /// Whether a bottom bar sits under the island. False beside a rail, where the
    /// island takes the bar's place against the bottom edge.
    let hasBottomBar: Bool
    /// Which way the expanded player is laid out — decides where the cover flies to.
    let presentation: PlayerPresentation
    /// Where the layout actually put the artwork's slot, once it has been laid out
    /// and said so. Nil for the first frame, where the computed values below stand
    /// in. Measured rather than predicted because there are three arrangements now
    /// and a prediction has to be right in all of them.
    let measuredArtRect: CGRect?
    /// How far the player has moved aside to make room for a panel: 0 = its column
    /// centred in the window, 1 = in the left half with the panel beside it.
    ///
    /// Animated (it is the panel's own open progress), so the player *slides*
    /// between the two rather than jumping the moment a panel is asked for. Always
    /// 0 where there is only one column, which is what keeps every phone metric
    /// below exactly what it was.
    let panelShift: CGFloat

    var p: CGFloat { min(max(pRaw, 0), 1) }
    var q: CGFloat { min(max(queue, 0), 1) }

    // MARK: tunables
    static let islandHeight: CGFloat = BottomBar.islandHeight
    static let islandHMargin: CGFloat = BottomBar.hMargin       // pill inset from the screen edges
    static let islandContentPad: CGFloat = 12   // trailing inset (play/next side)
    static let islandArtLeading: CGFloat = 20   // leading inset — shifts art+titles right
    static let islandArtSide: CGFloat = 34      // was 42 (−8, smaller island artwork)
    static let islandArtRadius: CGFloat = 8
    static let islandBottomGap: CGFloat = BottomBar.islandGap    // gap between island and tab bar
    static let tabBarHeight: CGFloat = BottomBar.tabHeight       // floating tab-bar height
    static let expandedRadius: CGFloat = 24
    static let expandedArtRadius: CGFloat = 18
    static let bottomOverhang: CGFloat = 120    // surface runs off-screen at p=1
    static let receiveDepth: CGFloat = 4        // how far the island grows UP on the catch
    static let receiveZone: CGFloat = 0.18      // last fraction of collapse the bounce lives in
    static let miniFadeFull: CGFloat = 0.10     // p at/below which mini controls are fully shown
    static let miniFadeEnd: CGFloat = 0.34      // p at/above which mini controls are hidden
    static let expArtTopGap: CGFloat = 39       // grabber + gap above big artwork

    // Island touch-target slop: the tappable area extends beyond the 56pt visual
    // pill so edge taps don't "fall through" to the page/tab-bar behind (Apple's
    // hit targets are likewise larger than their visual bounds). Bottom is kept
    // under `islandBottomGap` (8pt) so it can't steal tab-bar taps.
    static let islandTapSlopTop: CGFloat = 12
    static let islandTapSlopBottom: CGFloat = 6
    static let islandTapSlopH: CGFloat = 8

    // Island (collapsed) frame -----------------------------------------------
    // Anchored to the screen's bottom EDGE (matching the floating tab bar, which
    // sits `BottomBar.edgeMargin` from the edge), so the island floats a fixed
    // `islandBottomGap` above the tab bar regardless of the safe-area inset.
    /// The width the dock has to live in: the window, less any rail.
    var contentW: CGFloat { width - contentLeft }
    /// Full width of the content area less its margins — until the cap, past
    /// which the island stops growing and simply centres itself, so on an iPad
    /// it reads as a floating capsule rather than a bar welded across the window.
    var islandW: CGFloat {
        min(contentW - 2 * Self.islandHMargin, BottomBar.dockMaxWidth)
    }
    /// Beside a rail there is no bar to clear, so the island takes the bar's own
    /// place — the same `edgeMargin` from the bottom edge. That is what keeps the
    /// dock's geometry identical at every width, and therefore one morph.
    var islandBottom: CGFloat {
        hasBottomBar
            ? height - BottomBar.edgeMargin - Self.tabBarHeight - Self.islandBottomGap
            : height - BottomBar.edgeMargin
    }
    var islandTop: CGFloat { islandBottom - Self.islandHeight }
    var islandCenterY: CGFloat { islandBottom - Self.islandHeight / 2 }
    var islandLeft: CGFloat { contentLeft + (contentW - islandW) / 2 }
    var islandCenterX: CGFloat { islandLeft + islandW / 2 }
    var islandArtCenterX: CGFloat { islandLeft + Self.islandArtLeading + Self.islandArtSide / 2 }
    var islandRadius: CGFloat { Self.islandHeight / 2 }

    // Enlarged island hit target (visual pill stays `islandDropH`; only the
    // tappable/press area grows). Centred on the pill but extends more upward.
    var islandTapW: CGFloat { islandDropW + 2 * Self.islandTapSlopH }
    var islandTapH: CGFloat { islandDropH + Self.islandTapSlopTop + Self.islandTapSlopBottom }
    var islandTapCenterY: CGFloat { miniCenterY + (Self.islandTapSlopBottom - Self.islandTapSlopTop) / 2 }

    // Expanded artwork --------------------------------------------------------
    // Matches the content width (scrubber / titles / buttons use 32pt side
    // padding), so the cover lines up flush with the controls below it.

    /// The slot the player occupies: the whole window, shrinking to its left half
    /// as a panel arrives. The split is of the *window*, not the content area —
    /// the open player covers the rail as well as the page.
    var playerSlotW: CGFloat { lerp(width, width / 2, min(max(panelShift, 0), 1)) }

    /// The player's actual content width, centred in that slot.
    ///
    /// A title, a scrub bar and three buttons stretched across a whole iPad is
    /// not a player, it is a toolbar: past this the column stops growing and
    /// simply centres itself. Android's `SINGLE_COLUMN_MAX`, to the point. On a
    /// phone the window is narrower than the cap, so nothing appears to be
    /// capped at all.
    static let singleColumnMax: CGFloat = 560
    /// A short window ignores the cap: the reference layout runs the controls to
    /// the window's edge beside a big cover, and capping the pair at 560 would
    /// waste most of the width a phone on its side has.
    var playerColumnW: CGFloat {
        isShort ? playerSlotW : min(playerSlotW, Self.singleColumnMax)
    }

    /// Whether the window is too short to stack the cover above the transport.
    ///
    /// A phone on its side has about 440pt of height. The stacked player needs the
    /// cover, a title, a scrub bar, the transport AND the button row — which
    /// overruns that by roughly 280pt however small the cover gets, so the buttons
    /// simply fall off the bottom. Past this the cover moves BESIDE the controls
    /// instead of above them, which is what every phone music player does on its
    /// side. A portrait phone (874) and an iPad either way (834 / 1210) are never
    /// short, so nothing about them changes.
    var isShort: Bool { height - safeTop - safeBottom < Self.shortHeight }
    static let shortHeight: CGFloat = 560

    /// What the cover shares its column with when the window is short: the grabber
    /// above it, and the button row and its safe-area margin below.
    ///
    /// Deliberately NOT including `bottomOverhang`. The surface runs 120pt off the
    /// bottom of the screen and the button row pads itself back out of that, so
    /// the overhang is not height the cover competes for — counting it left the
    /// record two-thirds the size it had room for, with a band of empty black
    /// under it.
    var shortArtReserve: CGFloat { 13 + 20 + safeBottom + 20 }

    /// Height is in this at all because a wide window is usually a short one: a
    /// landscape iPad's cover, sized purely by width, runs off the bottom of the
    /// screen and takes the transport with it. On a phone in portrait the width is
    /// always the smaller of the two, so this changes nothing there.
    var expArtSide: CGFloat {
        // Sideways the slot is flexible, so its measured size is the answer —
        // no loop, because nothing sizes that slot from this. Stacked, the slot
        // IS this value, so the measurement would feed itself and is ignored.
        if isShort, let side = measuredArtRect?.width, side > 0 { return side }
        let byHeight = isShort
            ? height - safeTop - safeBottom - shortArtReserve
            : (height - safeTop - safeBottom) * 0.52
        // Side by side, the cover may take about half its column; stacked, it is
        // the column less the same 32pt inset the controls under it use.
        // Sideways the cover is sized by the HEIGHT it has and takes the width
        // that follows — about a third of the window, which is what the reference
        // layout does; the width bound is only a rail for a very wide short
        // window. Stacked, it is the column less the 32pt inset the controls use.
        let byWidth = isShort ? width * 0.45 : playerColumnW - 64
        return max(0, min(byWidth, byHeight))
    }
    /// Centred in the slot, so the cover travels with the column as it slides —
    /// unless the layout has reported where it really put the slot, which wins.
    var expArtCenterX: CGFloat { measuredArtRect?.midX ?? (playerSlotW / 2) }
    var expArtCenterY: CGFloat {
        measuredArtRect?.midY ?? (safeTop + Self.expArtTopGap + expArtSide / 2)
    }

    // Morphing surface --------------------------------------------------------
    // The surface is anchored by its BOTTOM edge: it lands exactly on the
    // island's bottom and NEVER moves below it (Apple pins the bottom and grows
    // the island UPWARD to receive the drawer). `receiveGrow` extends the TOP up
    // for the catch bounce; the bottom stays put.
    //
    // On TOP of that island↔drawer morph, the scroll-minimize DROP slides the
    // docked island DOWN into the tab bar's centre pill (between the split blobs)
    // and shrinks it to `centerPillW`. `dropT` is the drop amount; it's full while
    // docked (p≈0) and unwinds as the drawer expands (×(1−p)), so opening the
    // player is unaffected.
    var mz: CGFloat { min(max(minimize, 0), 1) }
    var dropT: CGFloat { mz * (1 - p) }
    var barCenterY: CGFloat { BottomBar.barCenterY(inHeight: height) }
    var centerPillW: CGFloat { BottomBar.centerGap(inWidth: width).width }
    var centerPillCenterX: CGFloat { BottomBar.centerGap(inWidth: width).centerX }

    var surfaceHExpanded: CGFloat { height + Self.bottomOverhang }
    /// Upward receive-bounce: a half-sine that is 0 at rest (p=0) and 0 at the
    /// zone edge, peaking in between — so as the drawer lands the island grows
    /// taller UPWARD by up to `receiveDepth`pt, then settles with no rebound and
    /// without ever moving the bottom edge. Active only during the collapse.
    var receiveGrow: CGFloat {
        guard receiving, p < Self.receiveZone else { return 0 }
        let u = Double(p / Self.receiveZone)   // 1 at zone edge → 0 at rest
        return Self.receiveDepth * CGFloat(sin(.pi * u))
    }

    // p-only ("natural") surface frame, before the scroll-minimize drop.
    private var baseH_p: CGFloat { lerp(Self.islandHeight, surfaceHExpanded, p) }
    private var surfaceH_p: CGFloat { baseH_p + receiveGrow }
    private var bottomEdge_p: CGFloat { lerp(islandTop, 0, p) + baseH_p }
    private var centerY_p: CGFloat { bottomEdge_p - surfaceH_p / 2 }

    var surfaceW: CGFloat { lerp(lerp(islandW, width, p), centerPillW, dropT) }
    var surfaceH: CGFloat { lerp(surfaceH_p, BottomBar.minElementH, dropT) }
    var surfaceCenterX: CGFloat { lerp(lerp(islandCenterX, width / 2, p), centerPillCenterX, dropT) }
    var surfaceCenterY: CGFloat { lerp(centerY_p, barCenterY, dropT) }
    var bottomEdge: CGFloat { surfaceCenterY + surfaceH / 2 }
    var radius: CGFloat { lerp(lerp(islandRadius, Self.expandedRadius, p), BottomBar.minElementH / 2, dropT) }
    /// The surface's top edge WITHOUT the receive-grow. The mini controls ride
    /// this down into the island, so the grow can raise the glass above them
    /// without carrying them up.
    var baseTop: CGFloat { lerp(islandTop, 0, p) }
    /// Center of the mini-control row: rides the top edge down (resting centered
    /// in the island at p=0), and drops to the bar centre when minimized.
    var miniCenterY: CGFloat { lerp(baseTop + Self.islandHeight / 2, barCenterY, dropT) }
    /// Island content frame — shrinks into the centre pill as it drops.
    var islandDropW: CGFloat { lerp(islandW, centerPillW, dropT) }
    var islandDropH: CGFloat { lerp(Self.islandHeight, BottomBar.minElementH, dropT) }

    // Traveling artwork -------------------------------------------------------
    // Queue-card slot — the now-playing card's artwork position the cover travels
    // INTO when the queue opens. Constants MIRROR the `queueTop` + `nowPlayingCard`
    // layout so the traveling cover lands exactly on the card's (reserved) slot at
    // Detent A: down by grabber pad (safeTop + 8) + capsule (5) + card top pad (8);
    // in by the scroll content leading pad (24); 72pt square, 11pt radius. Keep in
    // sync with `nowPlayingCard`.
    static let queueArtSide: CGFloat = 72
    static let queueArtRadius: CGFloat = 11
    static let queueArtLeading: CGFloat = 24
    static let queueArtTopGap: CGFloat = 8 + 5 + 8
    var queueArtCenterX: CGFloat { Self.queueArtLeading + Self.queueArtSide / 2 }
    var queueArtCenterY: CGFloat { safeTop + Self.queueArtTopGap + Self.queueArtSide / 2 }

    // The p-blend runs island⇄big-center; the q-blend then docks big-center⇄queue
    // slot. Because q is only ≠0 at p≈1 (and unwinds with p on collapse), the two
    // stages compose cleanly without a jump.
    var artSide: CGFloat { lerp(lerp(Self.islandArtSide, expArtSide, p), Self.queueArtSide, q) }
    var artRadius: CGFloat { lerp(lerp(Self.islandArtRadius, Self.expandedArtRadius, p), Self.queueArtRadius, q) }
    /// Artwork is left-aligned in the pill; when dropped it follows the centre
    /// pill's left edge.
    private var dropArtCenterX: CGFloat {
        (centerPillCenterX - centerPillW / 2) + Self.islandArtLeading + Self.islandArtSide / 2
    }
    var artCenterX: CGFloat { lerp(lerp(lerp(islandArtCenterX, expArtCenterX, p), dropArtCenterX, dropT), queueArtCenterX, q) }
    var artCenterY: CGFloat { lerp(lerp(lerp(islandCenterY, expArtCenterY, p), barCenterY, dropT), queueArtCenterY, q) }

    // Opacities ---------------------------------------------------------------
    // While a finger is down `p` is pinned at 1, so anything keyed purely on `p`
    // stays put during the drag and only animates on release — the mini controls
    // must NEVER appear until you let go.
    /// Mini controls are hidden while expanding/expanded (the drawer opens OVER
    /// them — they never flash on open). While docked/collapsing they fade in as
    /// the island forms: fully shown by `miniFadeFull`, gone by `miniFadeEnd`.
    var miniOpacity: CGFloat {
        guard !isExpanded else { return 0 }
        return clamp((Self.miniFadeEnd - p) / (Self.miniFadeEnd - Self.miniFadeFull))
    }
    /// Body fades out fast (gone by p≈0.55) so the collapse reads as a morph.
    var bodyOpacity: CGFloat { clamp((p - 0.55) / 0.45) }
    /// Frost → glass: opaque while expanded/dragging, clear by p≈0.30.
    var solidBgOpacity: CGFloat { clamp((p - 0.30) / 0.70) }
    /// Grabber rides with the drawer body and fades out with it on collapse.
    var grabberOpacity: CGFloat { bodyOpacity }
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
private func clamp(_ x: CGFloat, _ lo: CGFloat = 0, _ hi: CGFloat = 1) -> CGFloat { min(max(x, lo), hi) }

// MARK: - Liquid Glass background

private extension View {
    /// The island's Liquid Glass on iOS/macOS 26+, a material fallback below it.
    /// When `enabled` is false, a plain opaque `fallbackFill` is used instead —
    /// cheap to resize during the morph (no backdrop blur) — so the expensive
    /// glass is only paid at rest / outside Low Power Mode.
    @ViewBuilder
    func liquidGlass(radius: CGFloat, enabled: Bool = true, fallbackFill: Color = .black) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if !enabled {
            self.background(shape.fill(fallbackFill))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
        }
    }
}

// MARK: - Instant touch-down reporting (UIKit)

extension View {
    /// Reports touch-DOWN / move / up on this view **instantly**, with the touch
    /// point in this view's local coordinates. SwiftUI's own DragGesture /
    /// LongPressGesture wait to disambiguate a stationary finger (they only fire on
    /// movement), which lagged the island press-scale. This bridges a UIKit
    /// 0-duration long-press recognizer that fires on `touchesBegan` and, being
    /// non-cancelling + simultaneous, observes without stealing the touch from
    /// SwiftUI gestures/buttons underneath. No-op off iOS.
    @ViewBuilder
    func onTouchChanged(_ action: @escaping (Bool, CGPoint) -> Void) -> some View {
        #if canImport(UIKit)
        self.background(TouchDownReader(onChange: action))
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
/// Installs a 0-duration `UILongPressGestureRecognizer` on the **window** so
/// touch-down is reported with zero delay, scoped to this view's bounds, without
/// consuming the touch (so the SwiftUI swipe/tap gestures and buttons still work).
///
/// It must attach to the window — not the representable's immediate `superview` —
/// because SwiftUI draws `Text`/`Image`/shapes into a shared backing view rather
/// than a `UIView` per element, so the immediate superview is usually NOT an
/// ancestor of the real touch target and the recognizer never fires. The window
/// is always an ancestor, and `shouldReceive` re-scopes delivery to this view's
/// bounds. `allowableMovement` is unbounded so the press survives a swipe.
struct TouchDownReader: UIViewRepresentable {
    var onChange: (Bool, CGPoint) -> Void

    func makeUIView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        context.coordinator.onChange = onChange
        context.coordinator.view = view
        view.onEnterHierarchy = { [weak view] in
            guard let view, let window = view.window,
                  context.coordinator.recognizer == nil else { return }
            let press = UILongPressGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.handle(_:)))
            press.minimumPressDuration = 0
            press.allowableMovement = .greatestFiniteMagnitude
            press.cancelsTouchesInView = false
            press.delaysTouchesBegan = false
            press.delaysTouchesEnded = false
            press.delegate = context.coordinator
            window.addGestureRecognizer(press)
            context.coordinator.recognizer = press
            context.coordinator.host = window
        }
        return view
    }

    func updateUIView(_ uiView: PassthroughView, context: Context) {
        context.coordinator.onChange = onChange
    }

    static func dismantleUIView(_ uiView: PassthroughView, coordinator: Coordinator) {
        if let r = coordinator.recognizer { coordinator.host?.removeGestureRecognizer(r) }
        coordinator.recognizer = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: ((Bool, CGPoint) -> Void)?
        weak var view: PassthroughView?
        weak var recognizer: UIGestureRecognizer?
        weak var host: UIView?

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            guard let view else { return }
            let loc = g.location(in: view)
            switch g.state {
            case .began, .changed: onChange?(true, loc)
            case .ended, .cancelled, .failed: onChange?(false, loc)
            default: break
            }
        }

        // Run alongside SwiftUI's gestures rather than fighting them.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // Only react to touches inside this view's own bounds (the island pill),
        // so touches elsewhere on the window are ignored.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view, view.window != nil else { return false }
            return view.bounds.contains(touch.location(in: view))
        }
    }

    /// Transparent, never the hit-test target — it exists only as a bounds anchor
    /// for the window recognizer's `shouldReceive` scoping.
    final class PassthroughView: UIView {
        var onEnterHierarchy: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onEnterHierarchy?() }
        }
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}
#endif

// MARK: - Artwork

/// One traveling artwork. Its display size animates, but the pixel size used to
/// resolve the backend URL is fixed, so scaling never triggers a reload and the
/// image never flashes its placeholder mid-flight. On a track change it keeps
/// showing the previous cover until the new one is ready (`retainWhileLoading`),
/// so — combined with up-next prefetching — skipping never reveals a placeholder.
private struct MorphArtwork: View {
    let track: Track?
    let side: CGFloat
    var cornerRadius: CGFloat = 10
    /// The largest side this artwork will ever be drawn at. The URL is resolved
    /// from THIS, not from `side`, so the animated size never changes the request
    /// — and so the cover is fetched at the size the expanded player will show it
    /// rather than the size the dock started it at.
    var resolveSide: CGFloat?

    @EnvironmentObject private var env: MusicPlayerEnvironment
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let url = resolvedURL {
                CachedArtworkImage(url: url, retainWhileLoading: true) { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var resolvedURL: URL? {
        guard let artwork = track?.artwork, let backend = env.active?.backend else { return nil }
        let pixels = ArtworkResolution.rung(forPoints: resolveSide ?? side, scale: displayScale)
        return backend.artworkURL(for: artwork, size: pixels)
    }

    private var placeholder: some View { ArtworkPlaceholder(cornerRadius: cornerRadius) }
}

/// Positions a rating bubble relative to the star: pinned just ABOVE it by default
/// (tail pointing down), but flipped BELOW (tail up) when there isn't room above —
/// e.g. with the queue open, where the star sits near the status bar / notch.
///
/// The appear is driven by an `onAppear` property animation (`shown`), NOT a
/// `.transition`: the hold-drag reveal re-renders rapidly as the finger moves, and
/// a `.transition`-based appear gets finalized by those unrelated re-renders (it
/// read as "no animation"). Animating an explicit property survives that churn.
/// Horizontally clamps within a screen margin and aims the tail at the star even
/// when the body is shifted inward.
private struct RatingBubbleContainer<Content: View>: View {
    let rect: CGRect
    let geo: GeometryProxy
    let reduceMotion: Bool
    let dismiss: (() -> Void)?
    let content: Content

    init(rect: CGRect, geo: GeometryProxy, reduceMotion: Bool,
         dismiss: (() -> Void)?, @ViewBuilder content: () -> Content) {
        self.rect = rect
        self.geo = geo
        self.reduceMotion = reduceMotion
        self.dismiss = dismiss
        self.content = content()
    }

    @State private var shown = false

    private let gap: CGFloat = 6
    private let margin: CGFloat = 12
    // Conservative bubble height, used ONLY to choose above-vs-below (the positioning
    // itself is height-agnostic). Generous so we flip a touch eagerly near the top
    // rather than risk bleeding into the status bar / Dynamic Island.
    private let flipHeight: CGFloat = 210

    var body: some View {
        let topInset = geo.safeAreaInsets.top > 0 ? geo.safeAreaInsets.top : 59
        let bubbleWidth = RatingMath.stripWidth() + 48
        let half = bubbleWidth / 2
        let minCenter = half + margin
        let maxCenter = geo.size.width - half - margin
        let center = maxCenter >= minCenter
            ? min(max(rect.midX, minCenter), maxCenter)
            : geo.size.width / 2
        // Tail X within the bubble's own space (TailedBubble clamps it to the body).
        let tailX = rect.midX - (center - half)
        // Flip below when the bubble wouldn't clear the top safe area above the star.
        let placeBelow = (rect.minY - gap - flipHeight) < (topInset + margin)

        ZStack {
            if let dismiss {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                if placeBelow {
                    Color.clear.frame(height: max(0, rect.maxY + gap)).allowsHitTesting(false)
                } else {
                    Spacer(minLength: 0)
                }
                content
                    .padding(placeBelow ? .top : .bottom, RatingTuning.revealTailHeight)
                    .glassBackground(TailedBubble(tailX: tailX, tailUp: placeBelow))
                    .frame(width: bubbleWidth)
                    .offset(x: center - geo.size.width / 2,
                            y: shown ? 0 : (placeBelow ? -12 : 12))
                    .opacity(shown ? 1 : 0)
                if placeBelow {
                    Spacer(minLength: 0)
                } else {
                    Color.clear.frame(height: max(0, geo.size.height - (rect.minY - gap)))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Appear is handled by `shown`; only the removal fades (via the caller's
        // animation transaction). `.identity` insertion avoids a second,
        // transition-driven appear that the preview churn would snap.
        .transition(.asymmetric(insertion: .identity, removal: .opacity))
        .ignoresSafeArea()
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(.snappy(duration: 0.26)) { shown = true } }
        }
    }
}

#endif
