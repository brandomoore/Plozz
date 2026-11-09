// Adapted from brandomoore/Mozz at 58dab0015d09a4978f2c484e072d1bc0e30f69dc.
// Copyright (C) 2026 Mozz contributors. GPL-3.0-only with Apple distribution permission.
// See Mozz-NOTICE.txt. Plozz adapters retain the original player motion and geometry.
#if os(iOS)
import SwiftUI
import CoreModels
#if canImport(UIKit)
import AVKit
import UIKit
#endif

// MARK: - AirPlay route picker

#if canImport(UIKit)
/// A SwiftUI wrapper around `AVRoutePickerView` — the real system AirPlay /
/// output-route picker. Tapping it presents the OS route sheet (headphones,
/// AirPlay speakers, etc.). Tinted to match the player's monochrome controls;
/// pass a clear tint to hide its built-in glyph and overlay a custom device icon.
struct AirPlayRoutePicker: UIViewRepresentable {
    var tint: UIColor = .label

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = tint
        v.activeTintColor = tint
        v.prioritizesVideoDevices = false
        v.backgroundColor = .clear
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        return v
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = tint
    }
}

/// Observes the current audio output route (`AVAudioSession`) so the player can
/// show the *actual* output device — its name ("Brandon's Room") and a matching
/// icon — like Apple Music. Updates live on route changes (plugging headphones,
/// picking an AirPlay speaker, etc.).
@MainActor
final class AudioRouteMonitor: ObservableObject {
    struct Output: Equatable {
        var name: String
        var icon: String
        /// Show a route label at all (false only for the built-in speaker).
        var showsLabel: Bool
        /// Prepend "iPhone →" — Apple does this only for external speakers /
        /// rooms (AirPlay, CarPlay, TV), NOT personal audio (AirPods/headphones).
        var showsSourcePrefix: Bool
    }

    @Published private(set) var output: Output

    private var observer: NSObjectProtocol?

    init() {
        output = Self.current()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.output = Self.current() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private static func current() -> Output {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let out = route.outputs.first else {
            return Output(name: "iPhone", icon: airPlaySymbol, showsLabel: false, showsSourcePrefix: false)
        }
        return classify(port: out.portType, name: out.portName)
    }

    private static func classify(port: AVAudioSession.Port, name: String) -> Output {
        switch port {
        case .builtInSpeaker, .builtInReceiver:
            // Nothing external is playing — show the AirPlay glyph (tap to pick a
            // target), not a phone icon: the button's purpose is to START AirPlay,
            // not to indicate the phone is the destination.
            return Output(name: "iPhone", icon: airPlaySymbol, showsLabel: false, showsSourcePrefix: false)
        case .headphones, .headsetMic:
            return Output(name: name, icon: "headphones", showsLabel: true, showsSourcePrefix: false)
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            // Personal Bluetooth audio (AirPods / Beats / headphones): show the
            // device icon + its name, no "iPhone →" prefix (matches Apple).
            return Output(name: name, icon: bluetoothIcon(name: name),
                          showsLabel: true, showsSourcePrefix: false)
        case .usbAudio:
            return Output(name: name, icon: "headphones", showsLabel: true, showsSourcePrefix: false)
        case .airPlay:
            // External room/speaker: "iPhone → Name". Public API can't identify
            // the AirPlay target (HomePod vs Apple TV vs 3rd-party) and usually
            // reports a generic "AirPlay" name, so we always show the generic
            // AirPlay glyph rather than risk a confidently-wrong specific icon.
            return Output(name: name, icon: airPlaySymbol,
                          showsLabel: true, showsSourcePrefix: true)
        case .carAudio:
            return Output(name: name, icon: "car.fill", showsLabel: true, showsSourcePrefix: true)
        case .HDMI, .displayPort:
            return Output(name: name, icon: "tv.fill", showsLabel: true, showsSourcePrefix: true)
        default:
            return Output(name: name, icon: airPlaySymbol, showsLabel: true, showsSourcePrefix: true)
        }
    }

    /// AirPods get their model-specific glyph via a name heuristic (the port type
    /// alone can't distinguish them); everything else on Bluetooth just shows a
    /// headphones icon (we can't reliably tell a BT speaker from headphones, and
    /// headphones is the common personal-audio case).
    private static func bluetoothIcon(name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpod") { return airPodsIcon(name: n) }
        return "headphones"
    }

    /// Pick the model-specific AirPods glyph. There's no public API for the model,
    /// but iOS's default naming (and user names) include it — "AirPods Pro",
    /// "AirPods (4th generation)", "…Gen 4 AirPods" — so we parse the name. Each
    /// choice validates against the runtime so an unknown/too-new symbol falls
    /// back to a known-good AirPods glyph rather than rendering blank. `name` is
    /// already lowercased.
    private static func airPodsIcon(name n: String) -> String {
        if n.contains("max") {
            return firstAvailableSymbol(["airpods.max", "airpodsmax", "airpods"])
        }
        if n.contains("pro") {
            return firstAvailableSymbol(["airpods.pro", "airpodspro", "airpods"])
        }
        if n.contains("gen 4") || n.contains("gen4") || n.contains("4th gen") || n.contains("generation 4") {
            return firstAvailableSymbol(["airpods.gen4", "airpods.gen3", "airpods"])
        }
        if n.contains("gen 3") || n.contains("gen3") || n.contains("3rd gen") || n.contains("generation 3") {
            return firstAvailableSymbol(["airpods.gen3", "airpods"])
        }
        return "airpods"
    }

    /// The first SF Symbol name in `candidates` that actually exists on this OS
    /// (guards against too-new symbol names), else the last as a final fallback.
    private static func firstAvailableSymbol(_ candidates: [String]) -> String {
        for name in candidates where UIImage(systemName: name) != nil { return name }
        return candidates.last ?? "airpods"
    }

    /// The generic AirPlay glyph — the honest icon for any AirPlay target, since
    /// public API can't identify the specific device.
    private static var airPlaySymbol: String {
        firstAvailableSymbol(["airplayaudio", "airplay.audio"])
    }
}
#endif

// MARK: - Queue panel

/// Intrinsic height of the History section = the "card at top" snap detent (how
/// far the content must scroll for the now-playing card to reach the top edge).
///
/// This is a **single, scroll-invariant size measurement** — deliberately NOT a
/// difference of two global-space anchors. Differencing anchors is fragile: if
/// the two ever coincide (empty History, or a value latched before layout) the
/// detent silently reads 0 and the snap disables itself. A subview's own height
/// can't coincide-to-zero by accident: it's 0 only when History is genuinely
/// empty (in which case there's correctly nothing to snap to).
struct HistoryHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Height of the History header row (title + Clear) — how tall the pinned header
/// is, and thus how close the rising card must get before it pushes it off top.
struct HistoryHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Height of the now-playing card (song row) — used to place the pinned queue
/// controls just beneath it and to know when the card has scrolled fully off.
struct QueueCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Height of the queue-controls block (shuffle/repeat pills + Queue/Clear header)
/// — the pinned block that sticks to the top as you scroll down into up-next.
struct QueueControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Height of a single up-next row — the uniform pitch used to part the rows and
/// map the finger to an insertion slot during an in-place drag-reorder.
struct QueueRowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The full-player queue: the played "History" (scroll up), the now-playing
/// **card** (injected by the container — artwork + title + star/overflow +
/// shuffle/repeat pills), and the "Continue Playing" up-next list. The card
/// scrolls as one unit with the list between two snap detents; tapping any
/// History / Continue-Playing row jumps to & plays it.
///
/// Order math: the queue's play order is `history + [current] + upNext`, so a
/// history row at index `i` maps to order position `i`, and an up-next row at
/// index `j` maps to `history.count + 1 + j` (the current track — the card —
/// sits at `history.count`, but isn't a tappable list row).
private struct QueueReorderIdentity: Equatable {
    let track: Track
    let occurrence: Int
}

struct PlayerQueuePanel<Card: View, Controls: View>: View {
    var playback: MusicPlayerAdapter
    /// Queue-open progress (0…1) — fades the list in alongside the docking card.
    var queueP: CGFloat
    /// A SEPARATE, slower progress (0…1) that drives ONLY the body's rise + fade
    /// (`BodyRise` / `BodyFade`). Decoupled from `queueP` so the body's climb into
    /// place can take longer than the fast artwork/card hand-off above it — the panel
    /// container animates this on its own gentler spring. Everything else (the panel
    /// container fade, pinned History header) stays on the fast `queueP`.
    var bodyP: CGFloat
    /// How far (points) the queue BODY — shuffle/repeat pills, "Queue" header, and
    /// Continue-Playing list — is pushed DOWN at q=0 so it rises up into place from
    /// below the scrub bar as the queue opens. Supplied by the container from the
    /// drawer's own (synchronously-known) geometry rather than measured here: the
    /// panel's measured viewport reads 0 on a fresh open (the panel remounts every
    /// time), which collapsed the rise to nothing. The now-playing card is excluded
    /// — it docks via the traveling artwork and its own short title/star cross-fade.
    var bodyRise: CGFloat = 0
    /// Opacity of the queue's body — History, the pills/header, and the up-next
    /// list — never the now-playing card.
    ///
    /// Swapping between this panel and the lyrics cross-fades the two bodies while
    /// both cards stay fully opaque. They are the same card, so drawing it twice
    /// looks like drawing it once, and it holds perfectly still rather than dipping
    /// through the middle of a dissolve.
    var bodyOpacity: Double = 1
    /// Bumped by the container on every queue open; each change snaps the scroll
    /// back to the now-playing card at the top (so a reopen never lingers on
    /// History or a prior scroll position).
    var resetToken: Int
    /// Jump to a specific order position and play it.
    var onSelect: (Int) -> Void
    /// Drop the played history.
    var onClearHistory: () -> Void
    /// Drop the up-next queue.
    var onClearQueue: () -> Void
    /// Called `true` when an in-place drag-reorder begins and `false` when it ends,
    /// so the container can slide the transport chrome out of the way. The list
    /// itself never moves — the grabbed row lifts and the others part in place.
    var onReorderActive: (Bool) -> Void = { _ in }
    /// Commit a finished reorder: move the up-next item from offset `from` to `to`
    /// (final-position semantics — see `MusicPlayerAdapter.moveUpNext`).
    var onCommitReorder: (Int, Int) -> Void = { _, _ in }
    /// How far the panel may grow DOWNWARD while a row is being dragged — the height
    /// of the transport-chrome region the container slides away, so the up-next list
    /// expands to fill the reclaimed space (Apple-Music style) instead of staying
    /// clipped to the header-tall window. `0` disables the growth.
    var reorderExtraHeight: CGFloat = 0
    /// Top-overscroll (≥0) once History is fully revealed and there's nothing left
    /// to scroll up — the container translates the whole drawer down by this.
    var onPull: (CGFloat) -> Void = { _ in }
    /// Finger-lift while overscrolling the top (overscroll amount, downward
    /// velocity) — the container decides dismiss-vs-settle.
    var onPullEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
    /// The now-playing card (song row: artwork + title + star/overflow), injected
    /// by the container. The shuffle/repeat pills are NOT part of this — they ride
    /// in the sticky queue-controls block just beneath it.
    @ViewBuilder var card: () -> Card
    /// The shuffle/repeat pills, injected by the container. Rendered in the queue-
    /// controls block (beneath the card) so they can pin to the top as a sticky
    /// header when scrolling down into up-next.
    @ViewBuilder var queueControls: () -> Controls
    /// Whether the card above is real. Beside the player it is not — the cover and
    /// its titles are in the column next to this one — and the sticky controls
    /// below have to know, because they wait on the card's measured height and
    /// would otherwise wait forever for a card that is never laid out.
    var showsNowPlayingCard: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Intrinsic height of the History section = the "card at top" snap detent,
    /// measured directly (scroll-invariant; 0 only when History is truly empty).
    @State private var historyHeight: CGFloat = 0
    /// Live viewport (scroll container) height — used to guarantee enough scroll
    /// room below the card for it to dock at the top even when Continue Playing
    /// is short, and to compute the released (History-full) detent.
    @State private var viewportH: CGFloat = 0
    /// Live scroll offset (contentOffset.y, reported by the iOS 18 controller) —
    /// drives the pinned History header. 0 = History top at the panel top;
    /// `detentTop` = card docked at the panel top.
    @State private var scrollY: CGFloat = 0
    /// Measured height of the History header row (title + Clear), including its
    /// bottom padding — the pinned overlay copies it, and the card pushes it off
    /// once its top rises within this distance of the panel top.
    @State private var historyHeaderH: CGFloat = 0
    /// Measured height of the now-playing card (song row) — places the pinned
    /// queue controls just beneath it at the docked position.
    @State private var cardHeight: CGFloat = 0
    /// Measured height of the queue-controls block (pills + Queue/Clear header) —
    /// how tall the sticky block is once it pins to the top.
    @State private var queueControlsH: CGFloat = 0
    /// Measured uniform height of an up-next row — the pitch used to part the rows
    /// and map the finger to an insertion slot during an in-place drag-reorder.
    @State private var upNextRowH: CGFloat = 0
    /// Origin up-next offset of the row being dragged, or `nil` when no reorder is
    /// in flight. The grabbed row follows the finger; every other row stays put
    /// until the drag crosses it, then shifts by exactly one row to open the gap —
    /// so the list never moves, only parts.
    @State private var dragFrom: Int? = nil
    /// Stable identity of the grabbed queue occurrence. Track IDs alone are not
    /// enough because the same track may be queued more than once.
    @State private var draggedQueueItem: QueueReorderIdentity?
    /// Exact up-next snapshot the visible drag geometry was calculated from.
    /// Any external mutation invalidates those positional offsets.
    @State private var reorderItemsAtPickup: [Track] = []
    /// Once playback mutates the queue under an active finger, keep that gesture
    /// cancelled until lift. Otherwise its next `.onChanged` would pick up the
    /// different track that inherited the same row offset.
    @State private var reorderInvalidated = false
    @GestureState private var reorderGestureActive = false
    /// The insertion slot the grabbed row currently targets (0-based in up-next).
    @State private var dragTo: Int? = nil
    /// The grabbed row's live finger translation (points) from its grab point.
    @State private var dragOffset: CGFloat = 0
    /// Whether the visible viewport is currently grown into the reclaimed chrome
    /// space. Toggled (animated, in lockstep with the container's chrome slide) on
    /// pickup/drop so the list expands to fill the freed space during a reorder.
    @State private var reorderGrown = false
    /// Extra pan (points) applied to the scroll content DURING a reorder so dragging
    /// toward an edge auto-scrolls the frozen list — positive reveals lower rows.
    /// Folded into the grabbed-row follow math and the pinned-overlay positions so
    /// everything tracks. `0` whenever a reorder isn't in flight.
    @State private var reorderPan: CGFloat = 0
    /// The grabbed row's last finger translation (points), retained so the auto-
    /// scroll timer can recompute the follow offset as the pan advances while the
    /// finger is held still at an edge.
    @State private var reorderTranslation: CGFloat = 0
    /// The finger's Y within the panel's own (stable) coordinate space — drives the
    /// edge-zone auto-scroll. Unaffected by the grabbed row's offset or the content
    /// pan, so it's a clean read of where the finger physically is in the viewport.
    @State private var reorderFingerY: CGFloat = 0
    /// The frozen scroll offset captured at pickup. `effScroll = reorderScrollBase +
    /// reorderPan`; the pan is clamped so `effScroll` never rises above the top of
    /// the up-next list (you can't reorder into the now-playing card / History).
    @State private var reorderScrollBase: CGFloat = 0
    /// One-shot request that transfers the reorder's visual edge-scroll pan into
    /// the real iOS 18 `ScrollPosition` on drop. The request ID makes repeated
    /// drops to the same Y distinct for `.onChange`.
    @State private var reorderScrollRequest: QueueScrollRequest?
    @State private var reorderScrollRequestID = 0
    /// Identifies the current pickup/drop lifecycle so a delayed close from an
    /// older drop cannot collapse a newer reorder that started and ended within
    /// the 0.5-second return delay.
    @State private var reorderGeneration = 0
    /// Drives the edge-zone auto-scroll while a row is held near the top/bottom.
    @State private var autoScroller = QueueAutoScroller()

    private let nowPlayingID = "queue.nowPlaying"

    /// Whether the sticky pinned-header overlays are in use (iOS 18+, where we get
    /// the live scroll offset). On iOS 17 the headers render inline instead.
    private var usesStickyHeaders: Bool {
#if os(iOS)
        if #available(iOS 18.0, *) { return true } else { return false }
#else
        return false
#endif
    }

    /// The "card at top" detent: how far the content must scroll for the card to
    /// reach the top edge = the History section's height.
    private var detentTop: CGFloat { max(0, historyHeight) }

    /// Temporary height reclaimed from the transport chrome during a reorder.
    /// Applied to BOTH the visible viewport and an unconditional trailing spacer
    /// so their difference (the maximum scroll offset) never changes, regardless
    /// of queue length. Without the matching content growth, the scroll view can
    /// clamp to a new offset as the viewport expands and cannot recover its prior
    /// position when it shrinks.
    private var activeReorderExtraHeight: CGFloat {
        reorderGrown ? reorderExtraHeight : 0
    }

    var body: some View {
        GeometryReader { geo in
            let baseH = geo.size.height
            // While a row is dragged, grow the visible viewport DOWN into the space
            // the transport chrome vacates so the full up-next list is reachable
            // (Apple-Music style) instead of clipping to the header-tall window.
            // `viewportH` (set below) stays on `baseH`, so the snap/detent math and
            // scroll position are unchanged — only the ScrollView's own frame and
            // the clip grow, revealing rows already laid out below the fold.
            let grownH = baseH + activeReorderExtraHeight
            Group {
#if os(iOS)
                if #available(iOS 18.0, *) {
                    // iOS 18+: drive the snap ourselves for a fast, crisp settle we
                    // fully control (native ScrollTargetBehavior's release
                    // deceleration is not tunable). Owns its ScrollPosition, snap
                    // spring, and seal-break haptic; also reports the live offset
                    // that drives the pinned History header.
                    scrollBase
                        .modifier(QueueManualSnap18(detentTop: detentTop,
                                                    viewportH: viewportH,
                                                    enabled: !reduceMotion,
                                                    resetToken: resetToken,
                                                    externalScrollRequest: reorderScrollRequest,
                                                    onExternalScrollApplied: { y in
                                                        // The native scroll and visual-pan removal
                                                        // happen in one transaction, so the pixels
                                                        // do not move during the ownership handoff.
                                                        scrollY = y
                                                        reorderPan = 0
                                                    },
                                                    onScrollY: { scrollY = $0 }))
                } else {
                    // iOS 17 fallback: native ScrollTargetBehavior + ScrollViewReader
                    // reset (no seal-break haptic — needs onScrollGeometryChange).
                    ScrollViewReader { proxy in
                        scrollBase
                            .modifier(QueueSnapModifier(detentTop: detentTop,
                                                        enabled: !reduceMotion))
                            .onAppear { resetToCard(proxy) }
                            .onChange(of: resetToken) { _, _ in resetToCard(proxy) }
                    }
                }
#else
                ScrollViewReader { proxy in
                    scrollBase
                        .modifier(QueueSnapModifier(detentTop: detentTop,
                                                    enabled: !reduceMotion))
                        .onAppear { resetToCard(proxy) }
                        .onChange(of: resetToken) { _, _ in resetToCard(proxy) }
                }
#endif
            }
            .frame(height: grownH, alignment: .top)
            // A stable coordinate space anchored at the panel top (it does NOT move
            // when the grabbed row is offset or the content pans), so the reorder
            // gesture can read a clean finger translation AND the finger's position
            // within the viewport for edge-zone auto-scroll.
            .coordinateSpace(.named("queueReorderSpace"))
            .opacity(queueP)
            .mask(bottomFadeMask)
            // Pinned History header: stays fixed at the top while its rows scroll
            // under it, then the rising now-playing card pushes it off. Drawn
            // OUTSIDE the fade mask so it stays crisp while rows dissolve beneath.
            // iOS 18 only (needs the live scroll offset); on 17 the header just
            // scrolls with the list.
            .overlay(alignment: .top) { pinnedHistoryHeader.opacity(bodyOpacity) }
            .overlay(alignment: .top) { pinnedQueueControls.opacity(bodyOpacity) }
            .clipped()
            // Top-of-list pull-to-dismiss, classified per gesture by START position.
            // A non-consuming UIKit pan attached HERE — at the panel container, an
            // ancestor of the whole scroll + overlays — so it reliably receives the
            // touches. If the finger was ALREADY at the top when the gesture began,
            // the whole drawer drags 1:1 with the finger while the scroll is frozen
            // (content can't move). If the gesture began mid-list, it's a pure scroll
            // that hard-stops at the top and NEVER pulls the drawer — so scrolling up
            // to the top can't bleed into an accidental drawer pull. The two are
            // mutually exclusive within a single touch.
            .modifier(QueuePullGestureModifier(atTop: scrollY <= 0.5,
                                               enabled: dragFrom == nil,
                                               onPull: onPull,
                                               onEnd: onPullEnd))
            .onPreferenceChange(HistoryHeightKey.self) { historyHeight = $0 }
            .onPreferenceChange(HistoryHeaderHeightKey.self) { historyHeaderH = $0 }
            .onPreferenceChange(QueueCardHeightKey.self) { cardHeight = $0 }
            .onPreferenceChange(QueueControlsHeightKey.self) { queueControlsH = $0 }
            .onPreferenceChange(QueueRowHeightKey.self) { if $0 > 0 { upNextRowH = $0 } }
            .onAppear { viewportH = baseH }
            .onDisappear { cancelReorder() }
            .onChange(of: geo.size.height) { _, h in viewportH = h }
            // Watch the revision, not the array. `onChange` compares its value on
            // every view update, and this body updates on every frame of a scroll
            // (it reports the live offset) — so comparing the queue itself ran an
            // element-by-element check over thousands of tracks per frame on a
            // shuffled library. The revision is an Int.
            .onChange(of: playback.queueRevision) { _, _ in
                guard dragFrom != nil else { return }
                cancelReorder()
            }
            .onChange(of: reorderGestureActive) { _, active in
                if !active { reorderInvalidated = false }
            }
        }
    }

    /// A floating copy of the History header (title + Clear) pinned to the panel
    /// top. `pinnedHeaderY`:
    ///   • `0` while scrolling through the History rows (rows slide under it),
    ///   • follows the content down on overscroll bounce,
    ///   • slides up (negative) as the now-playing card's top rises to meet it,
    ///     so the card — and only the card — pushes it off the top.
    @ViewBuilder private var pinnedHistoryHeader: some View {
        if usesStickyHeaders, detentTop > 1, !playback.history.isEmpty,
           historyHeaderH > 0 {
            historyHeaderRow
                .padding(.horizontal, 24)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: pinnedHeaderY)
                .opacity(queueP)
        }
    }

    /// Vertical position of the pinned header (see `pinnedHistoryHeader`).
    private var pinnedHeaderY: CGFloat {
        let y = scrollY
        let pushedByCard = detentTop - y - historyHeaderH
        return min(max(-y, 0), pushedByCard)
    }

    /// A floating copy of the queue controls (shuffle/repeat pills + Queue/Clear
    /// header) pinned to the panel top. Symmetric to the History header but for
    /// the DOWN direction: it sits just beneath the docked card, and as you scroll
    /// down the card slides off above it while this block sticks to the top and
    /// the up-next rows scroll under it. Scrolling back up, the descending card
    /// pushes it back down to its natural spot.
    @ViewBuilder private var pinnedQueueControls: some View {
        if usesStickyHeaders, !showsNowPlayingCard || cardHeight > 0, queueControlsH > 0 {
            queueControlsBlock
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: queueControlsY)
                // Rise up from below the scrub bar as the queue opens, on top of the
                // normal sticky-pin position.
                .modifier(BodyRise(progress: bodyP, start: bodyRiseStart, distance: bodyRise, ease: bodyRiseEase))
                .modifier(BodyFade(progress: bodyP, start: bodyFadeStart))
        }
    }

    /// Vertical position of the pinned queue controls: their natural spot just
    /// below the card (`detentTop + cardHeight` in content terms) minus the scroll,
    /// clamped so they never rise above the panel top — that's the pin.
    private var queueControlsY: CGFloat {
        max(0, detentTop + cardHeight - effScrollY)
    }

    /// The *effective* scroll the pinned overlays (shuffle/repeat pills + Queue/Clear
    /// header) and top fade follow so they stay glued to the content: raw `scrollY`
    /// plus the reorder auto-scroll pan. It is deliberately NOT clamped to ≥0 — when
    /// the user pulls the top and the scroll gives way (a native rubber-band, i.e. the
    /// rigid `QueuePullGesture` didn't arm), `scrollY` goes negative and the overlays
    /// must ride DOWN with the rest of the list rather than freezing at the top (which
    /// left them stuck while everything around them moved). A rigid drawer pull freezes
    /// the scroll's bounce instead (see `QueuePullGesture`), so `scrollY` stays ~0 there
    /// and the overlays stay put anyway. During a drag-reorder the pan is floored at the
    /// top of the up-next list, so this stays ≥0 then.
    private var effScrollY: CGFloat { scrollY + reorderPan }

    /// The body holds down at the scrub-bar line through the first slice of the open
    /// (`bodyRiseStart`), then rises to rest by q=1 — so it travels up *as the hero
    /// row is fading out* above it (the hand-off), rather than creeping up from the
    /// very start before the hero has moved. Applied via the `BodyRise` modifier so
    /// SwiftUI samples the delayed ramp per frame (a plain offset from animated state
    /// would linearize the hold away).
    private let bodyRiseStart: CGFloat = 0.45

    /// Ease-out strength for the body's rise into place (exponent on the remaining
    /// distance): the body covers most of its travel quickly, then decelerates into
    /// the final spot — `distance * (1 - t)^bodyRiseEase`. `1` is a plain linear remap
    /// of the spring; higher values "get there faster but settle in more slowly" for a
    /// softer landing. Only shapes the rise motion, not the fade.
    private let bodyRiseEase: CGFloat = 2

    /// When (in q, 0 → 1) the queue body starts fading IN. Before this the pills /
    /// header / list are fully transparent, then they ramp 0 → 1 by q=1 — decoupled
    /// from the card row's own `LateFade` (`cardFadeStart`) so the body's fade-in can
    /// be timed independently of the title/star hand-off above it. Applied via the
    /// `BodyFade` modifier (per-frame sampling of the delayed ramp).
    private let bodyFadeStart: CGFloat = 0.6

    /// How tall a fully-clear band to punch at the TOP of the scroll content so
    /// the rows dissolve into the real page background behind the pinned header
    /// (the header then reads as the page color — no frosted band). Ramps from 0
    /// when the card is docked (nothing pinned, so the card's own top stays crisp)
    /// up to the pinned block's height once a header is stuck at the top —
    /// whichever direction is active (History above, or queue controls below).
    private var topFadeAmount: CGFloat {
        let historyFade = max(0, min(historyHeaderH, historyHeaderH + pinnedHeaderY))
        let queueFade = max(0, min(queueControlsH, effScrollY - detentTop))
        return max(historyFade, queueFade)
    }

    /// The shared scroll content (History → now-playing card → Continue Playing).
    /// The snap engine (manual on iOS 18, `ScrollTargetBehavior` on 17) is layered
    /// on by the caller.
    private var scrollBase: some View {
        ScrollView {
            // Eager VStack (NOT lazy): the card is scrolled to mid-content on
            // open, so History sits off-screen above it. A LazyVStack drops
            // those off-screen rows and never lays out the full History, which
            // made the detent measurement read ~0 → the snap silently disabled
            // itself. The queue is small, so eager layout is cheap and makes the
            // measurement rock-solid.
            VStack(alignment: .leading, spacing: 0) {
                // History wrapped in a container whose intrinsic height is the
                // snap detent (History empty → 0, otherwise its full height).
                // Measured as a size, not a global position, so it can't
                // accidentally coincide-to-zero.
                VStack(alignment: .leading, spacing: 0) {
                    history
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: HistoryHeightKey.self,
                                           value: g.size.height)
                })
                .opacity(bodyOpacity)
                card()
                    .id(nowPlayingID)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: QueueCardHeightKey.self,
                                               value: g.size.height)
                    })
                // Shuffle/repeat pills + the Queue/Clear header. Reserved here so
                // it takes up its space and is measured; INVISIBLE on iOS 18 where
                // the pinned overlay draws the visible, sticky copy. On iOS 17
                // (no overlay) it renders inline and interactive — so it carries the
                // rise-from-below-the-scrubber entrance itself there.
                queueControlsBlock
                    .opacity(usesStickyHeaders ? 0 : 1)
                    .allowsHitTesting(!usesStickyHeaders)
                    .modifier(BodyRise(progress: bodyP, start: bodyRiseStart, distance: bodyRise, ease: bodyRiseEase))
                    .modifier(BodyFade(progress: bodyP, start: bodyFadeStart))
                    .background(GeometryReader { g in
                        Color.clear.preference(key: QueueControlsHeightKey.self,
                                               value: g.size.height)
                    })
                    .opacity(bodyOpacity)
                upNextRows
                    // Rise up from below the scrub bar with the pills/header as one
                    // unit as the queue opens.
                    .modifier(BodyRise(progress: bodyP, start: bodyRiseStart, distance: bodyRise, ease: bodyRiseEase))
                    .modifier(BodyFade(progress: bodyP, start: bodyFadeStart))
                    .opacity(bodyOpacity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            // Guarantee the card can always scroll to the very top when the queue
            // is short, then add the reorder delta OUTSIDE that minimum-height
            // frame. This unconditionally grows content by exactly as much as the
            // visible viewport — for short, medium, and long queues — keeping the
            // maximum scroll offset invariant so SwiftUI never clamps (and loses)
            // the user's current position.
            .frame(minHeight: detentTop + viewportH, alignment: .top)
            .padding(.bottom, activeReorderExtraHeight)
            // Auto-scroll pan: while a row is dragged toward an edge, shift the whole
            // (frozen) content up/down so the rest of the up-next list is reachable.
            // 0 except during/settling a reorder. The grabbed row counter-offsets
            // this in `reorderOffset` so it keeps tracking the finger.
            .offset(y: -reorderPan)
            // NOTE: no counter-offset here. A gesture that began mid-list must
            // rubber-band natively when it reaches the top (the drawer stays put),
            // so we must NOT cancel the overscroll. During a real drawer pull the
            // gesture instead freezes the scroll's bounce (see QueuePullGesture), so
            // the content can't move and no counter-offset is needed.
        }
        .scrollIndicators(.hidden)
        // Freeze the underlying scroll while a row is being dragged, so the list
        // stays exactly where it was at grab and only the parting moves.
        .scrollDisabled(dragFrom != nil)
    }

    /// Snap the scroll so the now-playing card sits at the very top (iOS 17
    /// fallback path). Deferred to the next runloop tick so the content has laid
    /// out first — calling `scrollTo` synchronously in `onAppear` runs before the
    /// fresh ScrollView knows its content size and silently no-ops.
    private func resetToCard(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(nowPlayingID, anchor: .top)
        }
    }
    /// Content fade mask. A soft ~40pt bottom fade (rows dissolve under the lower
    /// chrome), plus a dynamic TOP fade: a clear band the height of the pinned
    /// History header so the rows dissolve into the real page background behind
    /// it — the header reads as the page color, not a frosted band. The top band
    /// is 0 when the card is docked, so the card's own top never fades.
    private var bottomFadeMask: some View {
        let clearH = topFadeAmount
        let tail = min(16, clearH)
        return VStack(spacing: 0) {
            if clearH > 0.5 {
                Color.clear.frame(height: clearH)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: tail)
            }
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 40)
        }
    }

    // MARK: History

    /// How many played tracks History shows.
    ///
    /// History is everything before the current track, so tapping a song deep into
    /// a shuffled library moves thousands of tracks into it at once. Unbounded,
    /// that is slow to lay out and useless to scroll — and it pushes the
    /// now-playing card thousands of rows below wherever you happen to be. A recent
    /// window keeps the section meaningful and its layout cheap and exact, which is
    /// what lets the rows stay eager (the scroll snap measures their full height —
    /// see `scrollBase`).
    private static var historyLimit: Int { 200 }

    @ViewBuilder private var history: some View {
        let items = playback.history
        if !items.isEmpty {
            // Only the most recent window, indexed in place: an order position IS
            // the history index, so slicing by index keeps row → jump-target
            // mapping correct with no arithmetic to get wrong.
            let first = max(0, items.count - Self.historyLimit)
            // Reserve the header's vertical space; INVISIBLE on iOS 18 where the
            // pinned overlay (pinnedHistoryHeader) draws the visible, sticky copy
            // so it stays stuck to the top while these rows scroll under it. On
            // iOS 17 (no overlay) it renders inline. Measured either way so the
            // overlay lines up and knows where the rising card should push it off.
            historyHeaderRow
                .padding(.top, 2)
                .padding(.bottom, 8)
                .opacity(usesStickyHeaders ? 0 : 1)
                .allowsHitTesting(!usesStickyHeaders)
                .background(GeometryReader { g in
                    Color.clear.preference(key: HistoryHeaderHeightKey.self,
                                           value: g.size.height)
                })

            ForEach(first..<items.count, id: \.self) { index in
                row(track: items[index], orderPosition: index, dimmed: true)
            }
            .padding(.bottom, 4)
        }
    }

    /// The History section header: "History" on the left, "Clear" on the right.
    /// Shared by the invisible reserved slot in the list and the visible pinned
    /// overlay so the two align exactly.
    private var historyHeaderRow: some View {
        HStack {
            Text("History").font(.headline)
            Spacer()
            Button("Clear", action: onClearHistory)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Queue controls + up-next

    /// Shuffle/repeat pills plus (when there's an up-next) the "Queue / Clear"
    /// header. This whole block is what sticks to the top when you scroll down —
    /// it sits directly beneath the now-playing card and heads the up-next list.
    private var queueControlsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            queueControls()
            if !playback.upNext.isEmpty {
                queueHeaderRow
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// The up-next section header: "Queue" on the left, "Clear" on the right —
    /// mirrors the History header. Shared by the reserved inline slot and the
    /// pinned overlay so the two align exactly.
    private var queueHeaderRow: some View {
        HStack {
            Text("Queue").font(.headline)
            Spacer()
            Button("Clear", action: onClearQueue)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// The up-next rows (the "Continue Playing" list). The section header lives in
    /// `queueControlsBlock` above so it can pin with the pills. During an in-place
    /// drag-reorder the grabbed row lifts and follows the finger while the others
    /// part by exactly one row — the real rows move, nothing is reconstructed, so
    /// the list can never teleport.
    /// Continue Playing.
    ///
    /// **Lazy**, unlike History above it. Shuffling a whole library puts thousands
    /// of tracks up next, and every row carries an `ArtworkView` — laying them all
    /// out eagerly built thousands of rows and fired thousands of image loads
    /// before the panel could draw, so the queue simply never opened.
    ///
    /// Laziness is safe *here* specifically, and would not be above: the only
    /// measurement the snap depends on is `HistoryHeightKey`, and History keeps its
    /// eager layout. The row-pitch measurement this list does publish
    /// (`QueueRowHeightKey`) comes from whichever rows are on screen, and the
    /// reader ignores zero, so it survives rows being recycled out.
    @ViewBuilder private var upNextRows: some View {
        let items = playback.upNext
        if items.isEmpty {
            // Otherwise the panel just stops: pills, then nothing, and no way to
            // tell an empty queue from one that failed to load.
            Text("Nothing in the queue")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
        } else {
            let base = playback.history.count + 1
            LazyVStack(alignment: .leading, spacing: 0) {
                // Indices rather than `Array(items.enumerated())`: the live scroll
                // offset re-evaluates this body on every frame, and materialising a
                // tuple array of the whole queue each time is pure waste on a long
                // one. Identity is the index either way.
                ForEach(items.indices, id: \.self) { index in
                    let track = items[index]
                    row(track: track, orderPosition: base + index,
                        showsHandle: true, upNextIndex: index)
                        // Expand only the painted pickup container by the same six-point
                        // inset the artwork already has vertically. The row's layout
                        // remains unchanged while the 12-point outer corner stays
                        // concentric with the artwork's six-point corner.
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.white.opacity(dragFrom == index ? 0.14 : 0))
                                .padding(.horizontal, -6)
                        }
                        .shadow(color: .black.opacity(dragFrom == index ? 0.3 : 0),
                                radius: 14, y: 6)
                        .offset(y: reorderOffset(index))
                        .zIndex(dragFrom == index ? 1 : 0)
                }
            }
        }
    }

    // MARK: Row

    private func row(track: Track, orderPosition: Int,
                     dimmed: Bool = false, showsHandle: Bool = false,
                     upNextIndex: Int? = nil) -> some View {
        HStack(spacing: 12) {
            Button {
                onSelect(orderPosition)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(artwork: track.artwork,
                                seed: track.albumTitle ?? track.title,
                                size: 44, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.body)
                            .lineLimit(1)
                        Text(track.artistName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .opacity(dimmed ? 0.6 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityActions {
                if let upNextIndex, upNextIndex > 0 {
                    Button("Move Up") {
                        accessibilityMoveUpNext(from: upNextIndex, by: -1)
                    }
                }
                if let upNextIndex, upNextIndex < playback.upNext.count - 1 {
                    Button("Move Down") {
                        accessibilityMoveUpNext(from: upNextIndex, by: 1)
                    }
                }
            }

            if showsHandle {
                reorderHandle(upNextIndex: upNextIndex)
            }
        }
        .padding(.vertical, 6)
        // Measure a representative up-next row's pitch (spacing is 0 in the
        // enclosing VStack, so this is the exact layout pitch the reorder overlay
        // uses). Only up-next rows carry a handle, so gate on that.
        .background(
            Group {
                if showsHandle {
                    GeometryReader { g in
                        Color.clear.preference(key: QueueRowHeightKey.self,
                                               value: g.size.height)
                    }
                }
            }
        )
    }

    /// Springs for the in-place reorder: a snappy lift on pickup and a slightly
    /// softer part as the target slot changes. (Instance `let`, not `static` —
    /// `PlayerQueuePanel` is generic and can't hold static stored properties.)
    private let reorderLiftSpring = Animation.spring(response: 0.28, dampingFraction: 0.72)
    private let reorderPartSpring = Animation.spring(response: 0.30, dampingFraction: 0.82)
    /// Spring for growing/shrinking the viewport into the reclaimed chrome space —
    /// tuned to match the container's chrome slide (`reorderChromeSpring`) so the
    /// list expands in lockstep as the controls move away, and settles back as they
    /// return.
    private let reorderGrowSpring = Animation.spring(response: 0.34, dampingFraction: 0.9)
    /// How close (points) the finger must be to the top/bottom edge of the grown
    /// viewport before the list auto-scrolls, and the peak speed at the very edge.
    /// Speed is time-based (not points-per-timer-tick) and enters on a smoothstep
    /// curve so crossing into the zone never kicks the list abruptly.
    private let reorderEdgeZone: CGFloat = 84
    private let reorderMaxScrollSpeed: CGFloat = 420
    /// After dropping a row, hold the grown viewport + slid-away chrome for this long
    /// before shrinking back and returning the controls, so the placement settles
    /// visually before the controls glide home.
    private let reorderChromeReturnDelay: TimeInterval = 0.5

    private func reorderIdentity(at index: Int, in items: [Track]) -> QueueReorderIdentity {
        let track = items[index]
        let occurrence = items[..<index].reduce(into: 0) { count, candidate in
            if candidate == track { count += 1 }
        }
        return QueueReorderIdentity(track: track, occurrence: occurrence)
    }

    private func index(of identity: QueueReorderIdentity, in items: [Track]) -> Int? {
        var occurrence = 0
        for (index, track) in items.enumerated() where track == identity.track {
            if occurrence == identity.occurrence { return index }
            occurrence += 1
        }
        return nil
    }

    /// Commit only while the queue still exactly matches the geometry or
    /// accessibility action that chose these offsets.
    @discardableResult
    private func commitValidatedReorder(from: Int, to: Int,
                                        identity: QueueReorderIdentity,
                                        expectedItems: [Track]) -> Bool {
        let currentItems = playback.upNext
        guard currentItems == expectedItems,
              currentItems.indices.contains(to),
              index(of: identity, in: currentItems) == from else { return false }
        if from != to { onCommitReorder(from, to) }
        return true
    }

    private func accessibilityMoveUpNext(from: Int, by distance: Int) {
        let items = playback.upNext
        let to = from + distance
        guard items.indices.contains(from), items.indices.contains(to) else { return }
        let identity = reorderIdentity(at: from, in: items)
        if commitValidatedReorder(from: from, to: to,
                                  identity: identity, expectedItems: items) {
            reorderMoveHaptic()
        }
    }

    /// Playback can advance while a handle is held (remote Next, natural finish).
    /// The row offsets are positional, so any live queue mutation invalidates the
    /// gesture. Cancel instead of ever committing those offsets to different items.
    private func cancelReorder() {
        guard dragFrom != nil || reorderGrown else { return }
        reorderGeneration &+= 1
        reorderInvalidated = true
        autoScroller.stop()
        autoScroller.onTick = nil
        draggedQueueItem = nil
        reorderItemsAtPickup = []
        reorderScrollRequest = nil
        withAnimation(reorderGrowSpring) {
            dragFrom = nil
            dragTo = nil
            dragOffset = 0
            reorderTranslation = 0
            reorderFingerY = 0
            reorderPan = 0
            reorderGrown = false
        }
        onReorderActive(false)
    }

    /// Vertical offset for up-next row `i` during an in-place reorder. The grabbed
    /// row follows the finger; every other row holds still until the grabbed row
    /// crosses it, then shifts by exactly one row height to open the insertion gap.
    private func reorderOffset(_ i: Int) -> CGFloat {
        guard let from = dragFrom else { return 0 }
        if i == from { return dragOffset }
        guard let to = dragTo, from != to, upNextRowH > 0 else { return 0 }
        if from < to, i > from, i <= to { return -upNextRowH }
        if to < from, i >= to, i < from { return upNextRowH }
        return 0
    }

    /// The trailing drag handle for an up-next row. An enlarged (~44pt) hit target
    /// carrying a high-priority drag gesture that reorders the list in place: the
    /// grabbed row lifts and follows the finger, the others part around it, and the
    /// move commits on release. A tap falls through (only the row body's Button
    /// selects/jumps).
    @ViewBuilder
    private func reorderHandle(upNextIndex: Int?) -> some View {
        Image(mozz: "line.3.horizontal")
            .font(.body)
            .foregroundStyle(.tertiary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .highPriorityGesture(
                // Measure in a stable named space anchored at the panel top (NOT
                // `.local`): the grabbed row hosts this gesture and is moved by
                // `.offset`, so a local space would shift under the finger every
                // frame and corrupt `translation` into a jitter feedback loop. The
                // named space also gives the finger's position within the viewport,
                // which drives the edge-zone auto-scroll.
                DragGesture(minimumDistance: 8, coordinateSpace: .named("queueReorderSpace"))
                    .updating($reorderGestureActive) { _, active, _ in
                        active = true
                    }
                    .onChanged { value in
                        guard let idx = upNextIndex else { return }
                        guard !reorderInvalidated else { return }
                        if dragFrom == nil {
                            let items = playback.upNext
                            guard items.indices.contains(idx) else { return }
                            reorderGeneration &+= 1
                            draggedQueueItem = reorderIdentity(at: idx, in: items)
                            reorderItemsAtPickup = items
                            reorderScrollBase = scrollY
                            reorderPan = 0
                            reorderTranslation = 0
                            onReorderActive(true)
                            reorderPickupHaptic()
                            withAnimation(reorderGrowSpring) { reorderGrown = true }
                            withAnimation(reorderLiftSpring) {
                                dragFrom = idx
                                dragTo = idx
                            }
                            autoScroller.onTick = { deltaTime in
                                stepAutoScroll(deltaTime: deltaTime)
                            }
                            autoScroller.start()
                        }
                        reorderTranslation = value.translation.height
                        reorderFingerY = value.location.y
                        updateReorderFollow()
                    }
                    .onEnded { _ in
                        autoScroller.stop()
                        autoScroller.onTick = nil
                        reorderInvalidated = false
                        guard let from = dragFrom else { return }
                        let to = dragTo ?? from
                        guard let draggedQueueItem,
                              commitValidatedReorder(from: from, to: to,
                                                     identity: draggedQueueItem,
                                                     expectedItems: reorderItemsAtPickup) else {
                            cancelReorder()
                            return
                        }
                        let closeGeneration = reorderGeneration
                        reorderDropHaptic()
                        // Edge auto-scroll is a visual content pan while the native
                        // ScrollView is frozen. On iOS 18, transfer its effective Y
                        // into the real ScrollPosition before releasing the pan so
                        // the list stays exactly where the drag scrolled it.
                        let transfersReorderPan: Bool
#if os(iOS)
                        if #available(iOS 18.0, *), abs(reorderPan) > 0.5 {
                            transfersReorderPan = true
                            reorderScrollRequestID &+= 1
                            reorderScrollRequest = QueueScrollRequest(
                                id: reorderScrollRequestID,
                                y: reorderScrollBase + reorderPan
                            )
                        } else {
                            transfersReorderPan = false
                        }
#else
                        transfersReorderPan = false
#endif
                        // Commit + clear the lift synchronously so SwiftUI renders one
                        // final frame in the new order (row lands in place instantly).
                        // Hold the grown viewport, auto-scroll pan, and slid-away chrome
                        // for a beat AFTER the drop so the placement reads before the
                        // controls glide back — then shrink + return them together.
                        dragFrom = nil
                        dragTo = nil
                        dragOffset = 0
                        reorderTranslation = 0
                        self.draggedQueueItem = nil
                        reorderItemsAtPickup = []
                        DispatchQueue.main.asyncAfter(deadline: .now() + reorderChromeReturnDelay) {
                            // A newer drag may have begun (and even ended) during
                            // the delay. Only this drop's generation may close its
                            // viewport/chrome lifecycle.
                            guard dragFrom == nil,
                                  reorderGeneration == closeGeneration else { return }
                            withAnimation(reorderGrowSpring) {
                                reorderGrown = false
                                // Only an iOS 18 handoff clears the visual pan through
                                // QueueManualSnap18. Every fallback clears it here.
                                if !transfersReorderPan { reorderPan = 0 }
                            }
                            onReorderActive(false)
                        }
                    }
            )
    }

    /// Recompute the grabbed row's follow offset and target slot from the current
    /// finger translation PLUS the auto-scroll pan, so the row keeps tracking the
    /// finger as the list scrolls under it. Called on every finger move and on every
    /// auto-scroll tick.
    private func updateReorderFollow() {
        guard let idx = dragFrom, upNextRowH > 0 else {
            dragOffset = reorderTranslation
            return
        }
        let count = playback.upNext.count
        // Clamp the effective displacement to the up-next slot span so the grabbed
        // row can't be dragged above the first row or below the last.
        let lo = CGFloat(-idx) * upNextRowH
        let hi = CGFloat(count - 1 - idx) * upNextRowH
        let displacement = min(max(reorderTranslation + reorderPan, lo), hi)
        dragOffset = displacement
        let steps = Int((displacement / upNextRowH).rounded())
        let target = min(max(idx + steps, 0), max(0, count - 1))
        if target != dragTo {
            withAnimation(reorderPartSpring) { dragTo = target }
            reorderMoveHaptic()
        }
    }

    /// One display-linked auto-scroll step: if the finger sits in the top/bottom
    /// edge zone, advance the content pan toward that edge. Velocity ramps in and
    /// out with a smoothstep curve and is integrated by elapsed time, so movement
    /// stays consistent without unsynchronized timer jumps.
    private func stepAutoScroll(deltaTime: TimeInterval) {
        guard dragFrom != nil, upNextRowH > 0 else { return }
        let grownH = viewportH + activeReorderExtraHeight
        let y = reorderFingerY
        var delta: CGFloat = 0
        if y < reorderEdgeZone {
            let depth = (reorderEdgeZone - max(0, y)) / reorderEdgeZone
            delta = -reorderMaxScrollSpeed * smoothEdgeDepth(depth) * CGFloat(deltaTime)
        } else if y > grownH - reorderEdgeZone {
            let depth = (max(0, y) - (grownH - reorderEdgeZone)) / reorderEdgeZone
            delta = reorderMaxScrollSpeed * smoothEdgeDepth(depth) * CGFloat(deltaTime)
        }
        guard delta != 0 else { return }
        let count = playback.upNext.count
        // Floor: normally the top of the up-next list (can't reorder into the
        // now-playing card or History). If the drag STARTED above that detent,
        // however, keep its starting offset as the floor. Forcing such a drag
        // forward to `detentTop` on the first tick is the large snap this clamp
        // must prevent. The ceiling likewise includes the starting offset so an
        // approximate content-bottom measurement can never snap backward.
        let contentBottom = detentTop + cardHeight + queueControlsH
            + CGFloat(count) * upNextRowH + 24
        let minEff = min(reorderScrollBase, detentTop)
        let maxEff = max(reorderScrollBase, max(minEff, contentBottom - grownH))
        let eff = reorderScrollBase + reorderPan
        let newEff = min(max(eff + delta, minEff), maxEff)
        guard newEff != eff else { return }
        reorderPan = newEff - reorderScrollBase
        updateReorderFollow()
    }

    private func smoothEdgeDepth(_ raw: CGFloat) -> CGFloat {
        let t = min(1, max(0, raw))
        return t * t * (3 - 2 * t)
    }

    #if canImport(UIKit)
    private func reorderPickupHaptic() {
        let g = UIImpactFeedbackGenerator(style: .medium); g.prepare(); g.impactOccurred()
    }
    private func reorderMoveHaptic() { UISelectionFeedbackGenerator().selectionChanged() }
    private func reorderDropHaptic() {
        let g = UIImpactFeedbackGenerator(style: .rigid); g.prepare(); g.impactOccurred()
    }
    #else
    private func reorderPickupHaptic() {}
    private func reorderMoveHaptic() {}
    private func reorderDropHaptic() {}
    #endif
}

/// Display-synchronized 60 Hz ticker for edge auto-scroll. It reports elapsed
/// time so scroll velocity is frame-rate independent. Held in `@State` so it
/// survives view re-renders while the finger remains motionless at an edge.
#if canImport(UIKit)
private final class QueueAutoScroller {
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private lazy var proxy = QueueAutoScrollDisplayLinkProxy(owner: self)
    var onTick: ((TimeInterval) -> Void)?

    func start() {
        stop()
        let link = CADisplayLink(target: proxy, selector: #selector(proxy.tick(_:)))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let elapsed = lastTimestamp.map { link.timestamp - $0 } ?? link.duration
        lastTimestamp = link.timestamp
        // Never convert a stalled frame into a giant catch-up jump.
        onTick?(min(max(elapsed, 0), 1.0 / 30.0))
    }

    deinit { stop() }
}

private final class QueueAutoScrollDisplayLinkProxy: NSObject {
    weak var owner: QueueAutoScroller?

    init(owner: QueueAutoScroller) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        owner?.tick(link)
    }
}
#else
private final class QueueAutoScroller {
    private var timer: Timer?
    private var lastTick: Date?
    var onTick: ((TimeInterval) -> Void)?

    func start() {
        stop()
        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            let elapsed = now.timeIntervalSince(lastTick ?? now)
            lastTick = now
            onTick?(min(max(elapsed, 0), 1.0 / 30.0))
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTick = nil
    }

    deinit { stop() }
}
#endif

/// Slides the queue body (pills + "Queue" header + Continue-Playing list) DOWN by
/// `distance` at q=0 so it rises up from below the scrub bar into place by q=1,
/// holding at the bottom until `start` so it travels up AS the hero row fades out
/// above it (the hand-off). `Animatable` so SwiftUI samples the delayed ramp every
/// frame — a plain `.offset(y:)` computed from animated state would only interpolate
/// its endpoints and linearize the hold away. Crucially, `distance` is a constant
/// (device-scaled, passed by the container) so the motion never depends on measured
/// geometry that reads 0 on a fresh open — the bug that pinned the body in place.
private struct BodyRise: ViewModifier, Animatable {
    var progress: CGFloat
    var start: CGFloat
    var distance: CGFloat
    var ease: CGFloat = 1
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let span = max(0.0001, 1 - start)
        let t = min(1, max(0, (progress - start) / span))
        // Ease-out on the remaining distance: quick departure, gentle settle.
        let remaining = CGFloat(pow(Double(1 - t), Double(ease)))
        return content.offset(y: remaining * distance)
    }
}

/// Fades the queue body (pills + "Queue" header + Continue-Playing list) IN, but
/// only after `progress` (q, 0 → 1) passes `start`; before that it stays fully
/// transparent, then ramps 0 → 1 over the remaining `start…1` range. The fade
/// counterpart to `BodyRise` — same delayed schedule so the body fades in and
/// rises up as one unit, decoupled from the card row's own `LateFade` hand-off
/// above it. `Animatable` for the same reason as `BodyRise`: a computed
/// `.opacity(...)` from animated state only interpolates its endpoints and skips
/// the delay curve, so it must sample `animatableData` per frame.
private struct BodyFade: ViewModifier, Animatable {
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

// MARK: - Two-detent "stuck to top" snap scroll

private struct QueueScrollRequest: Equatable {
    let id: Int
    let y: CGFloat
}

/// **iOS 18+ manual snap.** We own the whole thing so the settle is fast and
/// crisp: the native `ScrollTargetBehavior` uses Apple's fixed release
/// deceleration, which is not tunable and felt too slow. Instead we track the
/// live offset, and the instant the user lifts their finger we spring the scroll
/// to the nearer detent ourselves with a fast, fully-controlled animation. Also
/// owns the "breaking the seal" haptic (one firm impact when the content peels
/// off a detent) and the reset-to-top on reopen.
///
/// Two resting states (never settles between them):
///   • **Top (docked):** card pinned to the top edge — card + Continue Playing
///     fill the screen, History hidden above. Offset = `detentTop`.
///   • **Released:** card pushed just below the fold — History fills the screen.
///     Offset = `max(0, detentTop − viewportH)`.
/// Dragging within the one-viewport band between them snaps in the direction of
/// the release flick (or, on a still release, to the nearer detent) — symmetric.
/// Past the card (into Continue Playing) or deep into History, scrolling is free.
#if os(iOS)
@available(iOS 18.0, *)
private struct QueueManualSnap18: ViewModifier {
    var detentTop: CGFloat
    var viewportH: CGFloat
    var enabled: Bool
    var resetToken: Int
    /// One-shot offset transfer from reorder edge auto-scroll into the native
    /// ScrollPosition. Applying it without animation is visually neutral because
    /// the panel removes its equal-and-opposite visual pan in the same transaction.
    var externalScrollRequest: QueueScrollRequest?
    var onExternalScrollApplied: (CGFloat) -> Void
    /// Reports the live content offset so the panel can drive its pinned header.
    var onScrollY: (CGFloat) -> Void

    @State private var scrollPos = ScrollPosition()
    @State private var currentY: CGFloat = 0
    @State private var prevY: CGFloat = 0
    /// Smoothed per-event offset delta → the release direction/velocity sign.
    @State private var recentDelta: CGFloat = 0
    /// True while the scroll rests on (near) a detent — gates the seal-break
    /// haptic with hysteresis so it can't chatter at the boundary.
    @State private var isDocked = true
    /// Suppresses the haptic during the programmatic reset scroll on open.
    @State private var hapticArmed = false
    /// Once the user has dragged, stop auto-re-pinning as the detent settles.
    @State private var hasUserScrolled = false
    /// True while WE are animating the scroll — so our own motion neither
    /// re-triggers a snap nor fires the haptic.
    @State private var programmatic = false
    @State private var sealTick = 0

    private let sealBreakThreshold: CGFloat = 12
    private let reSealThreshold: CGFloat = 3
    private var bottomDetent: CGFloat { max(0, detentTop - viewportH) }

    func body(content: Content) -> some View {
        content
            .scrollPosition($scrollPos)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, y in
                let d = y - prevY
                prevY = y
                recentDelta = recentDelta * 0.4 + d * 0.6
                currentY = y
                onScrollY(y)
                updateSeal(y)
            }
            .onScrollPhaseChange { oldPhase, newPhase, _ in
                if newPhase == .interacting { hasUserScrolled = true }
                // Fire exactly once, the moment the finger lifts (whether or not
                // momentum follows) — that's when we take over the settle. The
                // top-pull-to-dismiss is owned by QueuePullGesture now, so here we
                // only ever snap to the nearer detent.
                if oldPhase == .interacting {
                    snapToNearest()
                }
            }
            .sensoryFeedback(.impact(weight: .heavy, intensity: 1.0), trigger: sealTick)
            .onAppear { pinToTop() }
            .onChange(of: resetToken) { _, _ in
                hasUserScrolled = false
                pinToTop()
            }
            .onChange(of: externalScrollRequest) { _, request in
                guard let request else { return }
                applyExternalScroll(request.y)
            }
            .onChange(of: detentTop) { _, _ in
                // Detent height can arrive/refine after first layout; keep the
                // card pinned to the top until the user actually scrolls.
                if !hasUserScrolled { pinToTop() }
            }
    }

    /// Convert the reorder overlay's temporary pan into the ScrollView's real
    /// offset. No animation: the content is already visibly at `y`; this only
    /// changes which layer owns that displacement.
    private func applyExternalScroll(_ y: CGFloat) {
        let target = max(0, y)
        programmatic = true
        hasUserScrolled = true
        recentDelta = 0
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPos.scrollTo(y: target)
            currentY = target
            prevY = target
            onExternalScrollApplied(target)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            programmatic = false
        }
    }

    /// Reset to the docked (card-at-top) position, un-animated, and re-arm the
    /// seal-break haptic once it settles so a reopen never buzzes.
    private func pinToTop() {
        programmatic = true
        isDocked = true
        hapticArmed = false
        scrollPos.scrollTo(y: detentTop)
        // Re-apply next tick: a fresh ScrollView may not know its size yet.
        DispatchQueue.main.async { scrollPos.scrollTo(y: detentTop) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            programmatic = false
            hapticArmed = true
        }
    }

    /// On finger-lift, spring the scroll to the nearer detent — fast and crisp.
    private func snapToNearest() {
        guard enabled, !programmatic else { return }
        let top = detentTop
        let bottom = bottomDetent
        // Need a meaningful gap to snap across.
        guard top - bottom > 40 else { return }
        let y = currentY
        // Only govern the one-viewport band between the two detents; deeper into
        // History (above) or Continue Playing (below) is free scroll.
        guard y > bottom - 0.5, y < top + 0.5 else { return }
        // Honor the release flick's direction (offset ↑ → toward the top detent,
        // offset ↓ → toward released); a still release falls back to midpoint.
        let target: CGFloat
        if recentDelta > 2 { target = top }
        else if recentDelta < -2 { target = bottom }
        else { target = (y - bottom) >= (top - bottom) / 2 ? top : bottom }
        guard abs(target - y) > 0.5 else { return }
        programmatic = true
        // Kill any fling momentum FIRST. A fast flick hands the finger-lift off
        // to the scroll view's deceleration; a spring `scrollTo` issued while it's
        // still decelerating gets applied instantly (UIKit cancels the running
        // deceleration and jumps), which reads as a jarring no-animation snap.
        // Pinning to the current offset un-animated stops the deceleration, then
        // we animate to the detent on the next runloop tick so the settle spring
        // ALWAYS plays, regardless of flick speed.
        scrollPos.scrollTo(y: y)
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                scrollPos.scrollTo(y: target)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { programmatic = false }
        }
    }

    /// Fire one firm haptic the instant the content peels off a detent (the
    /// "breaking the seal" feel); re-arm once it settles back so every unstick
    /// clicks. Hysteresis (`sealBreakThreshold` > `reSealThreshold`) prevents
    /// chatter; suppressed while WE animate (`programmatic`).
    private func updateSeal(_ y: CGFloat) {
        let top = detentTop
        let bottom = bottomDetent
        guard top - bottom > 40 else { return }
        let nearest = abs(y - top) <= abs(y - bottom) ? top : bottom
        let dist = abs(y - nearest)
        if isDocked {
            if dist > sealBreakThreshold {
                isDocked = false
                if hapticArmed && !programmatic { sealTick &+= 1 }
            }
        } else if dist < reSealThreshold {
            isDocked = true
        }
    }
}
#endif

// MARK: - Top-of-list pull-to-dismiss (per-gesture, start-position gated)

/// **iOS 18+ pull-to-dismiss.** A non-consuming UIKit pan recognizer bridged into
/// SwiftUI's gesture system, recognized *simultaneously* with the ScrollView's own
/// pan (and with `cancelsTouchesInView = false`, so taps/buttons/scrolling are
/// untouched). It gives the top-pull a true 1:1 finger feel that a SwiftUI
/// `DragGesture` on a ScrollView cannot (the scroll cancels it).
///
/// **Scroll and drawer-pull are mutually exclusive, classified by where the touch
/// began — never both at once:**
///   • **Began mid-list** → a pure scroll for its ENTIRE life. Even when it reaches
///     the top it just rubber-bands natively; the drawer never moves. So scrolling
///     up to the top can't bleed into an accidental drawer pull — you have to lift
///     and touch again once it's settled at the top.
///   • **Began already settled at the top** → a drawer pull. The scroll's overscroll
///     bounce is frozen so the content can't rubber-band, and the whole drawer drags
///     1:1 with the finger. (Dragging UP still scrolls down into the list normally —
///     freezing bounce only kills the past-the-edge rubber-band, not real scrolling.)
#if os(iOS)
@available(iOS 18.0, *)
private struct QueuePullGesture: UIGestureRecognizerRepresentable {
    /// Whether the list is settled at its very top RIGHT NOW. Sampled once, at the
    /// instant each gesture begins, to classify it as scroll-vs-pull.
    var atTop: Bool
    /// Whether the pull-to-dismiss is allowed to arm at all. False while an in-place
    /// row reorder is active, so a downward drag on a row's handle (which, with no
    /// history, begins settled at the very top) can't also pull the whole drawer.
    var enabled: Bool
    /// Live 1:1 pull distance (points, ≥0). Maps straight to `dragY`. Only ever
    /// non-zero for a gesture that began settled at the top.
    var onPull: (CGFloat) -> Void
    /// Finger-lift: (pull distance, real downward velocity in points/second). The
    /// container decides dismiss-vs-settle.
    var onEnd: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        // Observe only — never steal touches from the scroll view or its rows.
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.atTop = atTop
        context.coordinator.enabled = enabled
        context.coordinator.onPull = onPull
        context.coordinator.onEnd = onEnd
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.handle(recognizer)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Live "is the list settled at the top" flag, kept fresh via
        /// `updateUIGestureRecognizer`. Read ONCE per gesture (at `.began`).
        var atTop = true
        /// Live "is the pull allowed to arm" flag (false during a row reorder). Read
        /// at `.began` to gate arming, and continuously in `.changed` so a reorder
        /// that engages mid-gesture disarms an already-armed pull.
        var enabled = true
        var onPull: (CGFloat) -> Void = { _ in }
        var onEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
        /// Whether THIS gesture began while the list was already settled at the very
        /// top. Only such gestures can pull the drawer; a gesture that began mid-list
        /// stays a pure scroll for its whole life, even after it reaches the top.
        private var beganAtTop = false
        /// Whether the pull has moved past `pullActivate` while still enabled, i.e.
        /// committed to actually dragging the drawer. A short deadzone at the start
        /// lets a concurrent row-reorder (which engages at ~8pt and then flips
        /// `enabled` off) win the ambiguity window WITHOUT the drawer twitching first.
        private var pullCommitted = false
        /// Downward distance (points) the finger must travel before an armed pull
        /// starts moving the drawer. Above the reorder gesture's 8pt threshold so a
        /// handle drag disarms this pull before it can move anything.
        private let pullActivate: CGFloat = 14
        /// The queue's own scroll view, captured so we can freeze its top rubber-band
        /// for the duration of a drawer pull.
        private weak var scrollView: UIScrollView?
        /// Whether WE turned the scroll's bounce off (so we only restore what we took).
        private var didFreezeBounce = false

        // Ride alongside the scroll's own pan — never compete with it. Also the
        // reliable place to grab the scroll view: the ScrollView's own pan reports
        // its UIScrollView as `other.view`.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if scrollView == nil, let sv = other.view as? UIScrollView { scrollView = sv }
            return true
        }

        // Always allowed to begin; the real gating (scroll-vs-pull) happens in
        // `handle` off the start position.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { true }

        // Receive the touch even when it lands on the scroll view / its rows, so a
        // pull can start from ANYWHERE in the panel (including on a queue row).
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool { true }

        /// Freeze / restore the scroll's overscroll bounce. Freezing while the drawer
        /// is being pulled pins the list's `contentOffset` at the top (no rubber-band),
        /// so the content can NEVER move at the same time as the drawer — the two are
        /// mutually exclusive. `bounces = false` only kills the past-the-edge
        /// rubber-band, so scrolling DOWN into the list still works normally.
        private func setBounceFrozen(_ frozen: Bool) {
            guard let sv = scrollView else { return }
            if frozen, !didFreezeBounce {
                sv.bounces = false
                didFreezeBounce = true
            } else if !frozen, didFreezeBounce {
                sv.bounces = true
                didFreezeBounce = false
            }
        }

        /// Depth-first search for the queue's scroll view under the gesture's view,
        /// as a fallback if the simultaneity callback never handed it to us.
        private func findScrollView(_ v: UIView?) -> UIScrollView? {
            guard let v else { return nil }
            if let sv = v as? UIScrollView { return sv }
            for sub in v.subviews {
                if let found = findScrollView(sub) { return found }
            }
            return nil
        }

        func handle(_ g: UIPanGestureRecognizer) {
            // Measure in the WINDOW (a fixed space), NOT `g.view`: the gesture is
            // attached inside the surface that `dragY` translates, so measuring in
            // the view would move WITH the drawer — the finger's position relative
            // to it stays constant as we pull, the translation stops growing, and
            // the drag cancels itself (a feedback lock). The window never moves, so
            // its translation is the true physical finger delta → real 1:1.
            let space = g.view?.window
            let t = g.translation(in: space).y
            switch g.state {
            case .began:
                if scrollView == nil { scrollView = findScrollView(g.view) }
                // Classify ONCE by start position, and only arm if pulling is allowed
                // (no active reorder). If the list was already settled at the top,
                // this gesture pulls the drawer; freeze the bounce for its whole life
                // so the content can never rubber-band alongside the pull. If it began
                // mid-list, it stays a pure scroll — we never touch it, so reaching the
                // top just rubber-bands natively and the drawer stays put.
                beganAtTop = atTop && enabled
                pullCommitted = false
                if beganAtTop { setBounceFrozen(true) }
            case .changed:
                guard beganAtTop else { break }
                // A row reorder engaged mid-gesture: disarm, snap the drawer back to
                // rest, and hand the scroll back — the reorder owns the touch now.
                if !enabled {
                    onPull(0)
                    beganAtTop = false
                    pullCommitted = false
                    setBounceFrozen(false)
                    break
                }
                // Hold the drawer still until the finger clears the deadzone, then
                // track 1:1 from that point (no jump). Only downward (max(0,…)):
                // dragging up from the top just scrolls into the list.
                if !pullCommitted {
                    guard t >= pullActivate else { break }
                    pullCommitted = true
                }
                onPull(max(0, t - pullActivate))
            case .ended, .cancelled, .failed:
                if beganAtTop && pullCommitted {
                    onEnd(max(0, t - pullActivate), g.velocity(in: space).y)
                }
                beganAtTop = false
                pullCommitted = false
                setBounceFrozen(false)
            default:
                break
            }
        }
    }
}
#endif

/// Applies the iOS-18 pull gesture (a no-op on iOS 17, where the whole sticky
/// overscroll machinery is disabled). Lets the caller attach it with a plain
/// `.modifier(...)` without an inline `if #available` at the call site.
private struct QueuePullGestureModifier: ViewModifier {
    var atTop: Bool
    var enabled: Bool
    var onPull: (CGFloat) -> Void
    var onEnd: (CGFloat, CGFloat) -> Void

    func body(content: Content) -> some View {
#if os(iOS)
        if #available(iOS 18.0, *) {
            content.gesture(QueuePullGesture(atTop: atTop, enabled: enabled,
                                             onPull: onPull, onEnd: onEnd))
        } else {
            content
        }
#else
        content
#endif
    }
}

/// iOS 17 fallback: native symmetric snap via `ScrollTargetBehavior`, a no-op
/// under Reduce Motion. (No seal-break haptic here — that needs the iOS 18
/// `onScrollGeometryChange` offset stream.)
private struct QueueSnapModifier: ViewModifier {
    /// Content offset at which the now-playing card is pinned to the TOP of the
    /// viewport (= the History section's height).
    var detentTop: CGFloat
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled, #available(iOS 17.0, *) {
            content.scrollTargetBehavior(QueueSnapBehavior(detentTop: detentTop))
        } else {
            content
        }
    }
}

/// The now-playing card behaves like a header that's **stuck to the top** of the
/// queue page. There are only two resting states, and you can never settle
/// between them:
///   • **Top (stuck):**  card pinned to the top edge — card + Continue Playing
///     fill the screen, History hidden above. Content offset = `detentTop`.
///   • **Released:**      card pushed just below the fold (off the bottom edge) —
///     History fills the whole screen. Content offset = `detentTop − viewportH`.
/// Dragging within the one-viewport band between them snaps to whichever side the
/// *predicted* landing is nearer (so a fling completes, a nudge springs back) —
/// symmetric in both directions. Past the card (into Continue Playing) or deep
/// into a long History, scrolling is free.
@available(iOS 17.0, *)
private struct QueueSnapBehavior: ScrollTargetBehavior {
    var detentTop: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let top = detentTop
        let viewportH = context.containerSize.height
        let bottom = max(0, top - viewportH)
        let y = target.rect.minY
        // Need a real History section and a meaningful gap to snap across.
        guard viewportH > 1, top - bottom > 40 else { return }
        // Only govern the band between the two states.
        guard y > bottom, y < top else { return }
        // `target.rect` is the *predicted* landing (deceleration already folded
        // in), so a simple midpoint threshold naturally honors fling velocity.
        let mid = (top + bottom) / 2
        target.rect.origin.y = y >= mid ? top : bottom
    }
}

// MARK: - Shuffle / repeat pill

/// A capsule control for the queue's shuffle / repeat toggles. Deliberately
/// NEUTRAL (monochrome) — the player floats over arbitrary artwork colors, so a
/// brand tint would clash. Active reads as a brighter, more opaque capsule; off
/// is dim. An optional badge (e.g. "1" for repeat-one) rides over the glyph in
/// the same tint.
struct QueuePill: View {
    let glyph: AppIcon
    let label: String
    var active: Bool
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    glyph.styled(size: 18)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .heavy))
                            .offset(x: 7, y: -6)
                    }
                }
                Text(label).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(
                // Flat translucent white — renders uniformly over any artwork
                // backdrop (a material blurred the gradient unevenly and looked
                // muddy). Brighter when active.
                Capsule().fill(Color.white.opacity(active ? 0.20 : 0.09))
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(active ? 0.28 : 0.12),
                                       lineWidth: 1)
            )
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#endif
