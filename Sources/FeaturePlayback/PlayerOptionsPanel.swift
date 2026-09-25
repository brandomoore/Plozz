#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import CoreUI
import SwiftUI

/// The transport's floating options panel — Audio, Subtitles (with its Style,
/// Sync and Download screens), Speed, A/V Sync and Version — as one component
/// every player hosts, so a live channel's menus are the VOD player's menus.
///
/// The host decides which menu is open, where the panel sits and where focus
/// returns when it closes; the panel owns everything inside it: its header, its
/// measured height morph, its Subtitles sub-screens and the focus they take.
/// Hosts give each opened menu its own identity (`.id(category)`), so a fresh
/// open starts from the menu's remembered height rather than the last one's.
struct PlayerOptionsPanel: View {
    typealias Category = PlayerControls.Category
    typealias FocusSlot = PlayerControls.FocusSlot
    typealias SubtitleScreen = PlayerControls.SubtitleScreen
    typealias TrackRow = PlayerControls.TrackRow

    let category: Category
    let model: PlayerControlsModel
    let palette: ThemePalette
    let actions: PlayerOptionsActions
    /// Which Subtitles screen shows. The host owns it: it resets it on open and
    /// reads it to know when the Style editor is up.
    @Binding var subtitleScreen: SubtitleScreen
    /// Each menu's last measured height, remembered across opens so a reopen
    /// lays out at its settled size from the first frame (see `bodyHeight`).
    @Binding var heightCache: [Category: CGFloat]
    @FocusState.Binding var focus: FocusSlot?
    /// Closes the panel: a picked version plays straight away.
    let close: () -> Void
    /// Bumped by the host's Menu handling to step back one Subtitles screen.
    let backRequest: Int
    /// Whether the host can show a second subtitle line (a live channel can't).
    let offersDualSubtitles: Bool

    @Environment(\.plozzHDRDisplayActive) private var hdrDisplayActive

    /// The panel body's measured natural height, driving the glass box's height.
    @State private var bodyHeight: CGFloat
    /// Which menu `bodyHeight` was last measured for: a first measurement snaps,
    /// a later one within the same menu (tracks ↔ Style) animates.
    @State private var measuredFor: Category?

    init(
        category: Category, model: PlayerControlsModel, palette: ThemePalette,
        actions: PlayerOptionsActions, subtitleScreen: Binding<SubtitleScreen>,
        heightCache: Binding<[Category: CGFloat]>, focus: FocusState<FocusSlot?>.Binding,
        close: @escaping () -> Void, backRequest: Int, offersDualSubtitles: Bool = true
    ) {
        self.category = category
        self.model = model
        self.palette = palette
        self.actions = actions
        _subtitleScreen = subtitleScreen
        _heightCache = heightCache
        _focus = focus
        self.close = close
        self.backRequest = backRequest
        self.offersDualSubtitles = offersDualSubtitles
        // Seed the box height from the last time this menu was open so it renders
        // in the measured (ScrollView) branch immediately — no pre-measure→measured
        // structural swap that would rebuild the rows and knock initial focus to
        // the top. A miss (first open) falls back to 0 → pre-measure branch, and
        // leaves it unmeasured so the first measurement snaps.
        let seeded = heightCache.wrappedValue[category] ?? 0
        _bodyHeight = State(initialValue: seeded)
        _measuredFor = State(initialValue: seeded > 0 ? category : nil)
    }

    var body: some View {
        morphingPanel(for: category)
            .onChange(of: backRequest) { _, _ in
                guard category == .subtitles, subtitleScreen != .tracks else { return }
                openSubtitleScreen(subtitleScreen.parent)
            }
            .onChange(of: model.subtitleDownload.state) { _, state in
                // When search results land (async) while the Download screen is open,
                // move focus onto the first result so it's immediately actionable —
                // instead of leaving it parked on Back. Deferred for the same reason
                // as panel-open focus: let tvOS's own pass run first, then land ours.
                guard category == .subtitles, subtitleScreen == .download else { return }
                if case .results = state { restoreFocus(.row(0)) }
            }
    }

    /// True while the Style editor (or one of its detail screens) is up.
    private var styleEditing: Bool {
        category == .subtitles && subtitleScreen.isStyleFamily
    }

    /// Where focus lands in this menu as it opens or changes screen.
    var preferredFocus: FocusSlot? {
        Self.preferredFocus(for: category, subtitleScreen: subtitleScreen, model: model)
    }

    /// The focus target a freshly-opened menu should land on: the active/selected
    /// row for the track lists, the first available delay row for Sync, and the
    /// right control for each Subtitles screen. Card tabs land on their tab.
    static func preferredFocus(
        for panel: Category, subtitleScreen: SubtitleScreen, model: PlayerControlsModel
    ) -> FocusSlot? {
        switch panel {
        case .info, .cast:
            // The tab, not the card: the row above the card behaves like a
            // segmented control, so opening lands there and a further Down press
            // steps into the card's actions.
            return .button(panel)
        case .subtitles:
            switch subtitleScreen {
            case .tracks:
                return model.subtitleTrackListFocus
            case .download:
                // Land on the first result when we have them; while still searching
                // (no rows yet) rest on Back. An async results arrival is handled by
                // an onChange that moves focus onto the first row.
                if case .results = model.subtitleDownload.state { return .row(0) }
                return .subBack
            case .sync:
                // Land on the − nudge (leftmost control); the value and + sit to
                // its right.
                return .row(0)
            case .style:
                return model.secondarySubtitleImagePrimaryFormat == nil ? .row(0) : .subBack
            case .styleFont:
                return .row(SubtitleFontFamily.allCases.firstIndex(of: model.subtitleStyle.fontFamily) ?? 0)
            case .styleOutline, .styleBackground, .styleDual:
                return .row(0)
            }
        case .audio, .speed, .version:
            return .row(selectedRowIndex(for: panel, model: model))
        case .sync:
            if model.engineCapabilities.contains(.audioDelay) { return .row(0) }
            if model.engineCapabilities.contains(.subtitleDelay) { return .row(10) }
            return nil
        }
    }

    /// Move focus after the current view update settles. Opening a menu or
    /// swapping its screen makes tvOS run its own default focus pass in the same
    /// update; a single deferred write lands after it rather than racing it.
    private func restoreFocus(_ slot: FocusSlot?) {
        guard let slot else { return }
        DispatchQueue.main.async { focus = slot }
    }

    /// Fixed width for an open control panel, per category. Most menus share a
    /// roomy 520pt column; the Speed menu only holds short preset labels
    /// ("1.25×") and a compact stepper, so it uses roughly half the width to
    /// avoid a mostly-empty panel.
    func panelWidth(for category: Category) -> CGFloat {
        Self.width(for: category, subtitleScreen: subtitleScreen)
    }

    static func width(for category: Category, subtitleScreen: SubtitleScreen) -> CGFloat {
        switch category {
        case .speed: return 260
        case .version: return 860
        // The Download screen lists scene-release filenames; it's wider than the
        // other menus, and the title marquee-scrolls the rest on focus, so it needs
        // room to be readable without being absurdly wide.
        case .subtitles where subtitleScreen == .download: return 860
        default: return 520
        }
    }

    /// The tallest a scrollable list (track list / Audio / Speed / Sync) may grow
    /// before it clamps + scrolls, so a long list never overflows. The Style editor
    /// is exempt — it grows to its full natural height.
    private static let panelBodyMaxHeight: CGFloat = 440

    /// The floating options panel for every non-info category. A *single*
    /// measured-height container (no per-screen swap), so navigating between screens
    /// — the track list, the Style editor, and its sub-screens — animates ONLY the
    /// glass box's height while the rows stay put:
    ///
    /// - The body is laid out inside a `ScrollView` and its natural height measured
    ///   via `PanelBodyHeightKey`; that value drives the box height, animated in
    ///   `onPreferenceChange` (a plain `.animation(_, value:)` doesn't reliably fire
    ///   for preference-driven state — it settles a frame after layout).
    /// - The Style editor (and sub-screens) is pinned to the top corner with room to
    ///   spare, so it grows to full natural height with scrolling disabled — the
    ///   morph reveals the rows top-down through the clip and nothing is cut off. The
    ///   track / Audio / Speed / Sync lists clamp to `panelBodyMaxHeight` and scroll.
    /// - Because the track list and the Style editor share this one container, tapping
    ///   Edit *morphs* the box height from the track-list height up to the Style
    ///   height instead of swapping one panel for another (which read as a jump).
    /// A separator matched to the surface it is drawn on.
    ///
    /// Replaces `Divider().background(...)`, which draws TWO things: the
    /// system divider and a white wash behind it. Over glass the refraction hid
    /// the doubling; over frost, which is lighter and flat, it read as a
    /// brighter, thicker line than the panel's own edge — the same idea at two
    /// different weights on one surface.
    private var frostAwareDivider: some View {
        // HDR-compensated like the borders, and for the same reason: this sits
        // inside the panel whose edge it has to match, and both are drawn into a
        // signal that maps SDR white brighter than SDR mode does.
        PlozzFrostedSurface.dividerColor(hdrDisplayActive: hdrDisplayActive)
            .frame(height: PlozzFrostedSurface.dividerHeight)
    }

    @ViewBuilder
    private func morphingPanel(for category: Category) -> some View {
        let styleFamily = category == .subtitles && subtitleScreen.isStyleFamily
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(for: category)
            frostAwareDivider
            morphingBody(styleFamily: styleFamily, category: category) { panelBodyContent(for: category) }
        }
        // Hard-swap the panel chrome + content on the tracks↔Style flip instead of
        // cross-fading it. `styleEditing` toggles ONLY on tracks→Style, and the
        // ambient `.animation(.easeInOut, value: styleEditing)` up in `body` would
        // otherwise capture this content-identity change and dissolve the track list
        // into the Style editor: the header title ("Subtitles"→"Subtitle Style") and
        // the rows ghost over each other, and the taller editor spills past the
        // still-growing box. Nil-ing animation for styleEditing-driven changes on the
        // whole panel makes header + rows swap instantly — exactly how the Style
        // *sub-screen* morphs already behave (they don't flip styleEditing, so they
        // never cross-fade). Only the box height then animates, via the explicit
        // `withAnimation` in `onPreferenceChange`: "animate the container, not what's
        // inside." The Spacer/transport layout flip keeps its animation (that modifier
        // lives on `body`, above this override).
        .animation(nil, value: styleEditing)
        // Content swaps INSTANTLY on a subtitle sub-screen change (track list ↔
        // Download ↔ Style): only the glass container should animate, never the rows
        // ghosting into each other. The container's width/height animate via the
        // explicit `withAnimation` in `openSubtitleScreen` + the height morph in
        // `onPreferenceChange` — both of which sit OUTSIDE this nil scope.
        .animation(nil, value: subtitleScreen)
        .frame(width: panelWidth(for: category), alignment: .leading)
        .modifier(PanelGlassBackground())
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        // OUTSIDE the background, not inside it.
        //
        // `.colorScheme` sets the environment for the subtree it is attached to,
        // and a `.background` added by a later modifier is not in that subtree —
        // so with this above `PanelGlassBackground` the panel's CONTENT was dark
        // while its material resolved against the ambient scheme. A `Material`
        // is scheme-dependent and `.thickMaterial` in light mode is white, which
        // is the white slab that appeared before the panel settled.
        //
        // It never showed while the panel was glass: `glassEffect` is not a
        // Material and does not flip on colour scheme.
        .colorScheme(.dark)
        // Drive the height change explicitly (see note above). The first
        // measurement for a given panel snaps in (no grow-from-zero / no
        // shrink-from-stale); later changes *within the same panel* (the
        // tracks↔Style morph) animate.
        .onPreferenceChange(PanelBodyHeightKey.self) { heights in
            // Only ever read the currently-open panel's own height. A closing panel
            // keeps reporting its (tall) height through its 0.2s exit transition; by
            // keying on category we ignore it entirely instead of letting it size the
            // panel that's replacing it.
            let panel = category
            guard let newHeight = heights[panel],
                  newHeight > 0,
                  newHeight != bodyHeight
            else { return }
            // Remember this panel's natural height so the next open can seed it and skip
            // the pre-measure→measured swap (see heightCache). For Subtitles only
            // cache the tracks-list height — a fresh open always starts on the track list,
            // so we must not seed it with the taller Style-editor height.
            if panel != .subtitles || subtitleScreen == .tracks {
                heightCache[panel] = newHeight
            }
            if measuredFor != panel {
                // First measurement for THIS panel → snap to its natural size.
                // This write runs *inside* the ambient `.animation(value: openPanel)` of
                // the host
                // transaction that opening the panel started, so without explicitly
                // disabling animations the height correction would be interpolated and
                // the box would visibly resize on open. Disable animation for the snap
                // only; the tracks↔Style morph below keeps its explicit animation.
                measuredFor = panel
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) { bodyHeight = newHeight }
            } else {
                // Same panel, content morphed (tracks↔Style) → animate the box.
                withAnimation(.easeInOut(duration: 0.28)) { bodyHeight = newHeight }
            }
        }
    }

    @ViewBuilder
    private func morphingBody<Content: View>(
        styleFamily: Bool,
        category: Category,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let body = VStack(alignment: .leading, spacing: 0) {
            content()
        }
        // Equal top/bottom gutter so the first/last row's focus card sits the same
        // distance from the panel edge as its left/right gutter (18) — see the row
        // style's concentric card inset.
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PanelBodyHeightKey.self,
                    value: [category: proxy.size.height]
                )
            }
        )

        if bodyHeight > 0 {
            ScrollView {
                body
            }
            .scrollIndicators(.hidden)
            // The Style editor never scrolls (it grows to full height); disabling
            // scroll keeps the height morph a clean top-down clip reveal with no
            // bounce.
            .scrollDisabled(styleFamily)
            .frame(
                height: styleFamily ? bodyHeight : min(bodyHeight, Self.panelBodyMaxHeight),
                alignment: .top
            )
        } else {
            // Pre-measurement (first frame of a fresh open — always the track list,
            // as the Style editor is only reached from it). Render the body as a plain
            // VStack clamped to the cap.
            //
            // CRITICAL: a flexible `.frame(maxHeight:)` is GREEDY — given a tall
            // proposal (the bottom cluster proposes far more than the cap) it fills to
            // the cap regardless of content, so a 2-row Audio menu would paint at 440
            // and then shrink to its real ~166 once measured. Wrapping it in an outer
            // `.fixedSize(vertical:)` feeds the frame a nil proposal, so it falls back
            // to the child's ideal height clamped to the cap = min(content, cap). Now
            // the first painted frame equals the settled measured height for BOTH a
            // short list (→ its natural height) and a long 30-track list (→ the cap),
            // leaving zero height delta to animate on open.
            // The GeometryReader still reports the true content height for the handoff
            // to the scrolling branch, which enables scrolling for over-cap lists.
            body
                .frame(maxHeight: Self.panelBodyMaxHeight, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
        }
    }

    @ViewBuilder
    private func panelBodyContent(for category: Category) -> some View {
        switch category {
        case .version:
            VStack(alignment: .leading, spacing: 12) {
                PlayerMenuRowStack(rows: Self.versionRows(model: model, close: close), palette: palette, focus: $focus)
                Text("Resumes at the current position. Different cuts may have different timing.")
                    .font(.caption)
                    .plozzForeground(.secondary)
                    .padding(.horizontal, 16)
            }
            .padding(.horizontal, 14)
        case .subtitles: subtitleBody
        case .audio: AudioPaneView(rows: Self.audioRows(model: model, actions: actions), palette: palette, focus: $focus)
        case .speed: SpeedPaneView(model: model, palette: palette, actions: actions, focus: $focus)
        case .sync: SyncPaneView(model: model, actions: actions, focus: $focus)
        // Card tabs render in the bottom card, never in the floating menu.
        case .info, .cast: EmptyView()
        }
    }

    /// Header of the floating panel: the screen title, plus — on the Subtitles
    /// track list — a trailing ✎ Edit (appearance) button, and — on a Subtitles
    /// sub-screen — a leading Back chevron.
    @ViewBuilder
    private func panelHeader(for category: Category) -> some View {
        HStack(spacing: 14) {
            // On a Subtitles sub-screen (Style / Download), the Back control lives
            // in the header — leading the title — so it mirrors the other menus
            // rather than floating inside the scrollable content.
            if category == .subtitles && subtitleScreen != .tracks {
                Button {
                    openSubtitleScreen(subtitleScreen.parent)
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(PlozzPanelHeaderButtonStyle())
                .focusEffectDisabled()
                .focused($focus, equals: .subBack)
                // Pull the chip past the header gutter so it hugs the panel's
                // leading edge, concentric with the rounded corner.
                .padding(.leading, -10)
            }
            Text(headerTitle(for: category))
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 12)
            if category == .subtitles && subtitleScreen == .tracks {
                // Timing (Sync) chip — only when the app's overlay owns the active
                // subtitle, so the app-side offset can actually shift it. Sits left
                // of Style; opens a compact delay screen. Icon-only (clock) so the
                // header fits the title plus both chips.
                if model.subtitleDelayAdjustable {
                    Button {
                        openSubtitleScreen(.sync)
                    } label: {
                        Image(systemName: "clock")
                            .accessibilityLabel("Subtitle Sync")
                    }
                    .buttonStyle(PlozzPanelHeaderButtonStyle())
                    .focusEffectDisabled()
                    .focused($focus, equals: .subSync)
                }
                // Hidden while native subtitles draw in the system caption style,
                // which in-app appearance can't change.
                if model.subtitleDownload.canEditStyle {
                    Button {
                        openSubtitleScreen(.style)
                    } label: {
                        Label("Style", systemImage: "paintpalette")
                    }
                    .buttonStyle(PlozzPanelHeaderButtonStyle())
                    .focusEffectDisabled()
                    .focused($focus, equals: .edit)
                    // Mirror the back chip: hug the trailing edge, ignoring the gutter.
                    .padding(.trailing, -10)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 18)
        // Group the header as a focus section so directional focus can reach it
        // from anywhere below — e.g. pressing Up from the right (+) chip of the
        // sync stepper lands on Back even though nothing is geometrically above it.
        .plozzFocusSection()
    }

    private func headerTitle(for category: Category) -> LocalizedStringResource {
        guard category == .subtitles else { return category.title }
        switch subtitleScreen {
        case .tracks: return category.title
        case .download: return LocalizedStringResource(
            "player.subtitles.download",
            defaultValue: "Download Subtitles",
            comment: "Header of the in-player screen for downloading subtitle files."
        )
        case .sync: return LocalizedStringResource(
            "player.subtitles.sync",
            defaultValue: "Subtitle Sync",
            comment: "Header of the in-player screen for adjusting subtitle timing."
        )
        case .style: return "Subtitle Style"
        case .styleFont: return "Font"
        case .styleOutline: return "Shadow & Outline"
        case .styleBackground: return "Background"
        case .styleDual: return "Dual Subtitles"
        }
    }

    /// The Subtitles panel is a small master flow: the track list (default), a
    /// Download screen (from the trailing row) and a Style screen (from ✎ Edit).
    @ViewBuilder
    private var subtitleBody: some View {
        switch subtitleScreen {
        case .tracks: subtitlePane
        case .download:
            // Pin the Download screen to the panel's max body height so it opens to a
            // stable size and stays put across its states (searching → results →
            // downloading → added). Without this floor the short "searching"/"added"
            // states would collapse the box and the results list would then grow it
            // back — a visible shrink-then-expand. A tall results list still scrolls
            // (the enclosing morphingBody caps + scrolls at this same height).
            SubtitleDownloadScreen(model: model, actions: actions, focus: $focus)
                .frame(minHeight: Self.panelBodyMaxHeight, alignment: .top)
        case .sync: SubtitleSyncScreen(model: model, actions: actions, focus: $focus)
        case .style, .styleFont, .styleOutline, .styleBackground, .styleDual:
            SubtitleStylePanel(
                screen: subtitleScreen,
                model: model,
                palette: palette,
                actions: actions,
                focus: $focus,
                openScreen: { openSubtitleScreen($0) },
                offersDualSubtitles: offersDualSubtitles
            )
        }
    }

    /// The Subtitles track list: one full-width column of selectable tracks
    /// (incl. "Off"), then a trailing "Search for subtitles…" row. Full width so
    /// a rich label ("Spanish (SDH, PGS)") never truncates.
    @ViewBuilder
    private var subtitlePane: some View {
        VStack(alignment: .leading, spacing: 2) {
            let rows = Self.subtitleRows(model: model, actions: actions)
            if rows.isEmpty {
                emptyRow("No subtitles")
            } else {
                PlayerMenuRowStack(rows: rows, palette: palette, focus: $focus)
            }
            // The divider sets the download row apart; with nothing to download
            // it would only be a line under the last track.
            if model.subtitleDownload.canSearch {
                frostAwareDivider
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                downloadEntryRow
            }
        }
        .padding(.horizontal, 14)
    }

    /// "Looked through them all, found nothing → get more." Kept at the END of
    /// the list so it surfaces exactly when it's needed (few / no tracks) and
    /// stays out of the way when there are many.
    private var downloadEntryRow: some View {
        Button {
            openSubtitleScreen(.download)
            // Kick off a search on entry (idempotent: while results already show,
            // re-opening won't wipe them — the VM only re-searches on demand).
            if case .results = model.subtitleDownload.state {} else {
                actions.searchRemoteSubtitles(nil)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").font(.body)
                Text("Download subtitles…").font(.body).lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .download)
    }

    private func openSubtitleScreen(_ screen: SubtitleScreen) {
        // Entering the Style editor from the (non-style) track list flips the body
        // from the capped, scrollable list to the UNCAPPED Style column. At this point
        // `bodyHeight` still holds the track list's full measured content height,
        // which for a film with ~60 language tracks is ~2000pt — far past the cap it
        // was actually displayed at. Uncapping without clamping would snap the box to
        // that stale height and then shrink it down to the ~700pt editor: a violent
        // overshoot (invisible on short lists, where the stale height already ≈ the
        // editor height). Clamp the morph baseline to the height the list was really
        // showing so the box grows cleanly from the cap up to the editor instead of
        // collapsing into it from far above. The snap is un-animated; the subsequent
        // grow to the editor's true height animates via `onPreferenceChange`.
        if !subtitleScreen.isStyleFamily && screen.isStyleFamily {
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                bodyHeight = min(bodyHeight, Self.panelBodyMaxHeight)
            }
        }
        // Animate the CONTAINER as the screen changes: setting `subtitleScreen`
        // inside an explicit animation animates the frame width (e.g. 520→720 for
        // the wider Download screen) and, via onPreferenceChange, the height. The
        // content is held instant by `.animation(nil, value: subtitleScreen)` on the
        // panel, so only the glass box glides; the rows swap without ghosting.
        withAnimation(.easeInOut(duration: 0.28)) {
            subtitleScreen = screen
        }
        // Defer the focus write to the next runloop tick (same mechanism as
        // panel-open, via `restoreFocus`). Swapping the header chips + rows for the
        // new sub-screen makes tvOS's focus engine run its own default pass in this
        // same update; a synchronous @FocusState write races it and the engine wins —
        // landing on the header Back chip instead of the intended row (e.g. Font at
        // the top of the Style editor). `preferredFocus` already encodes the
        // correct target for every sub-screen, so reuse it.
        restoreFocus(preferredFocus)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .plozzForeground(.secondary)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
    }

    /// Subtitle menu rows (one full-width column, including "Off"). Indexed from
    /// 0 in their own focus-slot space — safe because only one panel is open at a
    /// time, so audio and subtitle `.row` ids never coexist.
    static func subtitleRows(model: PlayerControlsModel, actions: PlayerOptionsActions) -> [TrackRow] {
        guard model.hasSelectableSubtitles else { return [] }
        return model.subtitleOptions.enumerated().map { index, option in
            TrackRow(
                id: index,
                header: nil,
                title: option.title,
                subtitle: nil,
                isSelected: option.isSelected,
                isToggle: false,
                isExternal: option.isExternal,
                action: { actions.selectSubtitle(option.id) }
            )
        }
    }

    /// Audio menu rows: selectable tracks followed by the Dialog Enhance toggle
    /// when supported. A single track is not an actionable menu row.
    static func audioRows(model: PlayerControlsModel, actions: PlayerOptionsActions) -> [TrackRow] {
        var rows: [TrackRow] = []
        var index = 0
        for option in model.audioOptions where model.hasSelectableAudio {
            rows.append(TrackRow(
                id: index,
                header: nil,
                title: option.title,
                subtitle: nil,
                isSelected: option.isSelected,
                isToggle: false,
                action: { actions.selectAudio(option.id) }
            ))
            index += 1
        }
        if model.engineCapabilities.contains(.dialogEnhance) {
            rows.append(TrackRow(
                id: index,
                header: nil,
                title: Text("Dialog Enhance"),
                subtitle: Text("Boost speech clarity in loud mixes"),
                isSelected: model.dialogEnhanceEnabled,
                isToggle: true,
                action: { actions.setDialogEnhance(!model.dialogEnhanceEnabled) }
            ))
            index += 1
        }
        return rows
    }

    static func versionRows(model: PlayerControlsModel, close: @escaping () -> Void) -> [TrackRow] {
        model.versions.options.enumerated().map { index, option in
            TrackRow(
                id: index, header: nil,
                title: option.version.displayLabel.map { Text(verbatim: $0) } ?? Text("Original"),
                subtitle: option.version.fileName.map { Text(verbatim: $0) },
                isSelected: option.isSelected, isToggle: false,
                action: {
                    withAnimation { close() }
                    model.versions.select(option.id)
                }
            )
        }
    }

    static func selectedRowIndex(for category: Category, model: PlayerControlsModel) -> Int {
        let actions = PlayerOptionsActions()
        switch category {
        case .version:
            return model.versions.options.firstIndex(where: \.isSelected) ?? 0
        case .subtitles:
            // Open focused on the active subtitle (incl. "Off"), else the top row.
            return subtitleRows(model: model, actions: actions).first(where: { $0.isSelected })?.id ?? 0
        case .audio:
            return audioRows(model: model, actions: actions).first(where: { $0.isSelected })?.id ?? 0
        case .speed:
            return PlayerControls.speedPresets.firstIndex(where: { abs(model.playbackSpeed - $0) < 0.001 }) ?? 0
        case .sync:
            return 0
        case .info, .cast:
            return 0
        }
    }
}
#endif
