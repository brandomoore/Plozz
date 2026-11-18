// Adapted from brandomoore/Mozz at 58dab0015d09a4978f2c484e072d1bc0e30f69dc.
// Copyright (C) 2026 Mozz contributors. GPL-3.0-only with Apple distribution permission.
// See Mozz-NOTICE.txt. Plozz adapters retain the original player motion and geometry.
#if os(iOS)
import SwiftUI
import CoreModels

/// The full-player lyrics view: the now-playing **card** (injected by the
/// container — the same artwork + title + star/overflow row the queue uses) above
/// a scrolling column of lyric lines.
///
/// For synced lyrics the line being sung is solid white while its neighbours dim
/// and blur progressively with distance, and the list scrolls itself to keep the
/// active line just above centre. Unsynced lyrics render as a plain, evenly-lit
/// page the user scrolls themselves.
struct PlayerLyricsPanel<Card: View>: View {
    var controller: LyricsController
    /// Panel-open progress (0…1) — fades the whole panel in alongside the docking
    /// card, exactly like the queue.
    var lyricsP: CGFloat
    /// A separate, slower progress driving ONLY the lyric column's rise + fade, so
    /// it glides into place after the faster artwork/card hand-off above it.
    var bodyP: CGFloat
    /// How far (points) the lyric column is pushed DOWN at p=0 so it rises up into
    /// place from below the scrub bar as the panel opens. Supplied by the container
    /// from geometry it knows synchronously (the panel remounts on every open, so
    /// its own GeometryReader reads 0 for the first frames).
    var bodyRise: CGFloat = 0
    /// How far the panel MAY grow DOWNWARD once the transport chrome fades away.
    ///
    /// Deliberately the *potential* growth rather than the currently-applied
    /// growth: every position in the column is derived from it, so it has to stay
    /// constant across the collapse or the lines would shift as the panel resizes
    /// (see `focusOffset` / `tailPad`).
    var chromeReclaim: CGFloat = 0
    /// Vertical space the card occupies above the column (its height plus the gap
    /// beneath it). Supplied by the container, which owns the card's geometry.
    var cardReserve: CGFloat
    /// The panel's left/right inset. Supplied by the container so it matches the
    /// queue's — and, more importantly, the point the travelling artwork docks at.
    /// Hard-coding it here let the two drift apart, which showed up as the whole
    /// header sitting further in than the queue's and the artwork jumping sideways
    /// as it handed over.
    var cardInset: CGFloat
    /// Opacity of the lyric column only, never the card.
    ///
    /// Swapping between this panel and the queue cross-fades the two bodies while
    /// both cards stay fully opaque — they are the same card, so drawing it twice
    /// looks like drawing it once, and it holds perfectly still instead of dipping
    /// through a dissolve.
    var bodyOpacity: Double = 1
    /// Whether the chrome is currently hidden (immersive). While immersive, taps
    /// anywhere restore the chrome instead of seeking.
    var immersive: Bool
    /// Any touch inside the panel — restores the chrome and/or restarts the
    /// idle countdown.
    var onInteract: () -> Void
    /// Seek to the start of a lyric line (synced only).
    var onSeekToLine: (Int) -> Void
    /// The now-playing card, injected by the container so it is pixel-identical to
    /// the queue's.
    @ViewBuilder var card: () -> Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the spinner + "Searching for lyrics…" label may show. Held off for
    /// `loadingChromeDelay` so a fast resolve (a cache hit, a quick server) never
    /// flashes it — the column just stays blank for a beat and then fills in.
    @State private var showLoadingChrome = false
    /// Eases the column in on first appearance instead of letting it pop.
    @State private var appeared = false

    private static var loadingChromeDelay: Duration { .milliseconds(500) }

    // MARK: Tunables

    /// Where the active line sits vertically in the column: a third of the way
    /// down rather than dead centre, so there is more room to read ahead than
    /// behind — how every lyrics view worth using places it.
    private let focusAnchor: CGFloat = 0.34
    private let lineSpacing: CGFloat = 26
    private let lineFontSize: CGFloat = 29

    var body: some View {
        GeometryReader { geo in
            // The column's height with the chrome UP. `geo` is the fixed hero-sized
            // slot, so this never changes — which is exactly what lets every
            // position below be computed once and stay put.
            let restingHeight = max(0, geo.size.height - cardReserve)
            let grown = restingHeight + (immersive ? chromeReclaim : 0)
            VStack(spacing: 0) {
                card()
                    .padding(.horizontal, cardInset)
                column(restingHeight: restingHeight, visibleHeight: grown)
                    .modifier(LyricsBodyRise(progress: bodyP, distance: bodyRise))
                    .modifier(LyricsBodyFade(progress: bodyP))
                    .opacity(bodyOpacity)
            }
            .frame(height: cardReserve + grown, alignment: .top)
            .opacity(lyricsP)
            .clipped()
            // With the chrome up, a tap counts as interaction wherever it doesn't
            // land on a line. This sits BEHIND the lines (which claim their own
            // taps to seek) so it never blocks them.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onInteract() }
            }
            .onAppear { controller.setVisible(true) }
            .onDisappear { controller.setVisible(false) }
        }
        .task(id: controller.state.isResolving) {
            // Reset the gate on leaving the resolving state, and restart the delay
            // on entering it. `.task(id:)` cancels its previous instance on an
            // identity change, which doubles as the timer cancellation when the
            // answer lands before the delay elapses.
            guard controller.state.isResolving else {
                showLoadingChrome = false
                return
            }
            showLoadingChrome = false
            try? await Task.sleep(for: Self.loadingChromeDelay)
            guard !Task.isCancelled else { return }
            showLoadingChrome = true
        }
    }

    // MARK: Column

    /// - Parameters:
    ///   - restingHeight: the column's height with the chrome up — the stable
    ///     reference every line position is measured against.
    ///   - visibleHeight: how tall the column is *right now*. Only the scroll
    ///     anchor uses it, because that one value is expressed as a fraction of
    ///     the visible viewport.
    @ViewBuilder
    private func column(restingHeight: CGFloat, visibleHeight: CGFloat) -> some View {
        switch controller.state {
        case .idle, .loading, .silent:
            // `.silent` means we already know there's nothing here — render exactly
            // like `.idle` so the panel never flashes a spinner or a verdict for a
            // track we've already resolved to "none".
            placeholder {
                if showLoadingChrome {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Searching for lyrics…")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showLoadingChrome)

        case .unavailable:
            placeholder {
                VStack(spacing: 8) {
                    AppIcon.lyrics.styled(size: 30)
                        .foregroundStyle(.tertiary)
                    Text("No lyrics found")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }

        case let .loaded(lyrics):
            lines(lyrics, restingHeight: restingHeight, visibleHeight: visibleHeight)
        }
    }

    private func placeholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lines(_ lyrics: Lyrics, restingHeight: CGFloat, visibleHeight: CGFloat) -> some View {
        let active = controller.activeIndex
        // The line to keep in the focus slot. Before the first timestamp `active`
        // is nil, so fall back to the upcoming line (line 0 at the very start) —
        // that way the column opens already positioned rather than pinned to the
        // top and then jumping.
        let focus = focusIndex(in: lyrics, active: active)
        let advance: Animation = reduceMotion
            ? .linear(duration: 0.01)
            : .spring(response: 0.55, dampingFraction: 0.86)

        // Where the sung line sits, as a FIXED distance from the top of the column.
        //
        // This is the whole trick to the panel not moving when the chrome collapses:
        // the column only ever grows at its BOTTOM edge, so as long as the leading
        // pad is an absolute number of points the lines above and around the focus
        // slot keep their exact position, and going full screen simply reveals more
        // of the song below. Deriving it from the live height instead (a fraction of
        // a viewport that just got 350pt taller) is what pushed everything down.
        let focusOffset = restingHeight * focusAnchor
        let leadPad = max(0, focusOffset - lineFontSize)
        // Sized for the LARGEST the column can get, so it doesn't change either —
        // a shrinking tail pad can clamp the scroll offset and shift the content
        // even when nothing above it moved.
        let tailPad = max(0, restingHeight + chromeReclaim - focusOffset)
        // `scrollTo` places the target at a fraction of the *visible* viewport, so
        // this is the one value that must track the live height — expressing the
        // same absolute `focusOffset` in whatever the column currently measures.
        let anchorY = visibleHeight > 0 ? min(1, focusOffset / visibleHeight) : focusAnchor

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: lineSpacing) {
                    Color.clear.frame(height: leadPad)
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        lineView(line, index: index, active: active, isSynced: lyrics.isSynced)
                            .id(index)
                            .animation(advance, value: active)
                    }
                    if let source = lyrics.source {
                        // Quiet attribution at the very end of the scroll, so it's
                        // discoverable without ever competing with the words.
                        Text(source.displayName)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 12)
                    }
                    Color.clear.frame(height: tailPad)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, cardInset)
            }
            .scrollClipDisabled()
            // "Tap anywhere brings the controls back" has to include the gaps
            // between lines, which belong to the scroll view rather than to any
            // line. A *simultaneous* tap recognises those without competing with
            // the scroll — a hit-testable catcher laid over the top would take the
            // touch first and make unsynced lyrics, the ones you actually have to
            // scroll yourself, impossible to move while full screen.
            .simultaneousGesture(TapGesture().onEnded { onInteract() })
            .mask(edgeFade)
            .opacity(appeared ? 1 : 0)
            .onChange(of: active) { _, newIndex in
                guard let newIndex else { return }
                withAnimation(advance) { proxy.scrollTo(newIndex, anchor: .init(x: 0, y: anchorY)) }
            }
            .onAppear {
                proxy.scrollTo(focus, anchor: .init(x: 0, y: anchorY))
                withAnimation(.easeOut(duration: 0.45)) { appeared = true }
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: LyricLine, index: Int, active: Int?, isSynced: Bool) -> some View {
        let distance = active.map { abs(index - $0) }
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: lineFontSize, weight: .bold))
            .foregroundStyle(.primary)
            .opacity(Self.opacity(forDistance: distance))
            .blur(radius: Self.blur(forDistance: distance))
            // A whisper of scale on the active line reads as depth without
            // reflowing the column (scaleEffect doesn't affect layout).
            .scaleEffect(distance == 0 ? 1 : 0.97, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                // While immersive, ANY tap is "bring the controls back" — seeking
                // by tapping a half-blurred line you can barely read would be a
                // trap. With the chrome up, a tap on a synced line seeks to it.
                if immersive || !isSynced {
                    onInteract()
                } else {
                    onSeekToLine(index)
                }
            }
    }

    /// The line to keep in the focus slot: the active one, or — before the first
    /// timestamp — the next upcoming line, so the column always opens positioned.
    private func focusIndex(in lyrics: Lyrics, active: Int?) -> Int {
        if let active { return active }
        guard lyrics.isSynced else { return 0 }
        let now = controller.estimatedElapsed
        return lyrics.lines.firstIndex { ($0.start ?? .infinity) > now } ?? 0
    }

    /// How visible a line is given its distance from the active one. With no
    /// active line (unsynced, or the run-up before the first timestamp) every line
    /// sits at one calm, even brightness.
    static func opacity(forDistance distance: Int?) -> Double {
        guard let distance else { return 0.8 }
        switch distance {
        case 0: return 1
        case 1: return 0.4
        case 2: return 0.28
        default: return 0.2
        }
    }

    /// How soft a line is given its distance from the active one — the depth-of-
    /// field that makes the current line pop off the page.
    ///
    /// The lines you are about to read stay SHARP. Softening starts a couple of
    /// lines out and ramps from there, so the blur reads as the column receding
    /// towards its edges rather than as a spotlight on one line: by the time a
    /// line is soft it is also close to scrolling off, which is the only place
    /// unreadable is the right answer.
    ///
    /// Blurring the immediate neighbours is the version that fights the reader.
    /// The next line is the one being sung in a moment, and the eye is already
    /// on it; softening it means you spend the bar squinting at the words you
    /// are about to hear. Dimming those lines is enough on its own to say which
    /// one is current — that is what `opacity(forDistance:)` is for.
    static func blur(forDistance distance: Int?) -> CGFloat {
        guard let distance else { return 0 }
        let beyond = distance - sharpRadius
        guard beyond > 0 else { return 0 }
        return min(blurCeiling, CGFloat(beyond) * blurStep)
    }

    /// How many lines either side of the current one stay perfectly sharp.
    private static var sharpRadius: Int { 1 }
    /// Added softness per line beyond the sharp radius.
    private static var blurStep: CGFloat { 1.1 }
    /// The most any line is softened, however far away it is.
    private static var blurCeiling: CGFloat { 3.5 }

    /// Dissolves the lines into the backdrop at the top and bottom of the column
    /// rather than letting them cut off against a hard edge.
    ///
    /// Fixed point heights, not fractions: a proportional band would slide down the
    /// column as the panel grows for immersive mode and visibly re-dim lines that
    /// hadn't moved.
    private var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 56)
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 72)
        }
    }
}

// MARK: - Entrance modifiers

/// Slides the lyric column up into place from `distance` points below as
/// `progress` runs 0 → 1, with an ease-out so it departs quickly and settles
/// gently. `Animatable` so SwiftUI samples the curve per frame — a plain offset
/// computed from animated state only interpolates its endpoints and would skip
/// the shaping entirely.
private struct LyricsBodyRise: ViewModifier, Animatable {
    var progress: CGFloat
    var distance: CGFloat
    /// The column holds still until the artwork has begun docking, so the two
    /// movements read as a hand-off rather than a simultaneous scramble.
    var start: CGFloat = 0.4
    var ease: CGFloat = 2.2

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let span = max(0.0001, 1 - start)
        let t = min(1, max(0, (progress - start) / span))
        let remaining = CGFloat(pow(Double(1 - t), Double(ease)))
        return content.offset(y: remaining * distance)
    }
}

/// The fade counterpart to ``LyricsBodyRise`` — same delayed schedule, so the
/// column fades in and rises as one unit.
private struct LyricsBodyFade: ViewModifier, Animatable {
    var progress: CGFloat
    var start: CGFloat = 0.4

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let span = max(0.0001, 1 - start)
        return content.opacity(Double(min(1, max(0, (progress - start) / span))))
    }
}

#endif
