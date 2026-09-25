#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlayerOptionsPanelIntegrationTests: XCTestCase {
    private typealias Screen = PlayerControls.SubtitleScreen

    func testEveryStyleScreenUsesTheSharedWidthAndHasTheCorrectParent() {
        let screens: [Screen] = [
            .style, .styleFont, .styleSystemFont, .styleOutline,
            .styleBackground, .styleDual, .styleFileFormatting
        ]
        for screen in screens {
            XCTAssertTrue(screen.isStyleFamily)
            XCTAssertEqual(PlayerOptionsPanel.width(for: .subtitles, subtitleScreen: screen), SubtitleStylePanel.panelWidth)
            XCTAssertFalse(String(localized: PlayerOptionsPanel.headerTitle(for: .subtitles, subtitleScreen: screen)).isEmpty)
        }
        XCTAssertEqual(Screen.style.parent, .tracks)
        XCTAssertEqual(Screen.styleSystemFont.parent, .styleFont)
        XCTAssertEqual(Screen.styleFileFormatting.parent, .style)
        XCTAssertEqual(Screen.styleDual.parent, .style)
        XCTAssertEqual(PlayerOptionsPanel.width(for: .subtitles, subtitleScreen: .download), 860)
        XCTAssertEqual(PlayerOptionsPanel.width(for: .version, subtitleScreen: .tracks), 860)
        XCTAssertEqual(PlayerOptionsPanel.width(for: .speed, subtitleScreen: .tracks), 260)
        XCTAssertFalse(Screen.sync.isStyleFamily)
        XCTAssertEqual(
            String(localized: PlayerOptionsPanel.headerTitle(for: .subtitles, subtitleScreen: .styleSystemFont)),
            String(localized: LocalizedStringResource("System"))
        )
        XCTAssertEqual(
            String(localized: PlayerOptionsPanel.headerTitle(for: .subtitles, subtitleScreen: .styleFileFormatting)),
            String(localized: LocalizedStringResource("File Formatting"))
        )
    }

    func testFontFocusUsesEffectiveMatchingAndFrozenDescriptorsInsteadOfTheFallbackFamily() throws {
        let model = PlayerControlsModel()
        model.subtitleStyle = .default
        model.subtitleStyle.fontFamily = .lexend
        XCTAssertEqual(
            PlayerOptionsPanel.preferredFocus(for: .subtitles, subtitleScreen: .styleFont, model: model),
            .row(try XCTUnwrap(SubtitleFontFamily.allCases.firstIndex(of: .lexend)))
        )

        model.subtitleStyle.followsSystemStyle = true
        XCTAssertEqual(
            PlayerOptionsPanel.preferredFocus(for: .subtitles, subtitleScreen: .styleFont, model: model),
            .row(SubtitleFontFamily.allCases.count)
        )
        model.subtitleStyle = SystemCaptionStyle.shared.editing(model.subtitleStyle) { $0.fontScale += 0.01 }
        XCTAssertFalse(model.subtitleStyle.followsSystemStyle)
        XCTAssertNotNil(model.subtitleStyle.fontDescriptor)
        XCTAssertEqual(
            PlayerOptionsPanel.preferredFocus(for: .subtitles, subtitleScreen: .styleFont, model: model),
            .row(SubtitleFontFamily.allCases.count)
        )

        model.subtitleStyle.fontDescriptor = nil
        model.subtitleStyle.systemFont = .caption(.smallCapitals)
        XCTAssertEqual(
            PlayerOptionsPanel.preferredFocus(for: .subtitles, subtitleScreen: .styleSystemFont, model: model),
            .row(try XCTUnwrap(SubtitleSystemFonts.all.firstIndex { $0.id == .caption(.smallCapitals) }))
        )
        XCTAssertEqual(
            PlayerOptionsPanel.preferredFocus(for: .subtitles, subtitleScreen: .styleFileFormatting, model: model),
            .row(0)
        )
        XCTAssertEqual(
            PlayerOptionsPanel.preferredFocus(for: .subtitles, subtitleScreen: .styleDual, model: model, offersDualSubtitles: false),
            .subBack
        )
        model.secondarySubtitleImagePrimaryFormat = "PGS"
        XCTAssertEqual(
            PlayerOptionsPanel.preferredFocus(for: .subtitles, subtitleScreen: .style, model: model),
            .subBack
        )
    }

    func testTrackRowsAndFocusRemainCapabilityDrivenForBothHosts() {
        let model = PlayerControlsModel()
        var pickedAudio: [Int] = []
        var pickedSubtitle: [Int] = []
        var dialogEnhance: [Bool] = []
        let actions = PlayerOptionsActions(
            selectAudio: { pickedAudio.append($0) },
            selectSubtitle: { pickedSubtitle.append($0) },
            setDialogEnhance: { dialogEnhance.append($0) }
        )
        model.audioOptions = [
            .init(id: 12, title: Text("English"), isSelected: false),
            .init(id: 27, title: Text("French"), isSelected: true)
        ]
        model.engineCapabilities = [.dialogEnhance]
        let audio = PlayerOptionsPanel.audioRows(model: model, actions: actions)
        XCTAssertEqual(audio.map(\.id), [0, 1, 2])
        XCTAssertTrue(audio[2].isToggle)
        audio[1].action()
        audio[2].action()
        XCTAssertEqual(pickedAudio, [27])
        XCTAssertEqual(dialogEnhance, [true])
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(for: .audio, subtitleScreen: .tracks, model: model), .row(1))

        model.subtitleOptions = [
            .init(id: PlayerTrackOption.offID, title: Text("Off"), isSelected: false),
            .init(id: 41, title: Text("English"), isSelected: true, isExternal: true)
        ]
        let subtitles = PlayerOptionsPanel.subtitleRows(model: model, actions: actions)
        XCTAssertEqual(subtitles.map(\.id), [0, 1])
        XCTAssertTrue(subtitles[1].isExternal)
        subtitles[1].action()
        XCTAssertEqual(pickedSubtitle, [41])
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(for: .subtitles, subtitleScreen: .tracks, model: model), .row(1))

        model.subtitleOptions = []
        model.subtitleStyle.followsSystemStyle = true
        model.subtitleDownload.canSearch = false
        XCTAssertTrue(PlayerOptionsPanel.subtitleRows(model: model, actions: actions).isEmpty)
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(for: .subtitles, subtitleScreen: .tracks, model: model), .edit)
        model.subtitleDownload.canSearch = true
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(for: .subtitles, subtitleScreen: .tracks, model: model), .download)
        model.subtitleDownload.state = .searching
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(for: .subtitles, subtitleScreen: .download, model: model), .subBack)
        model.subtitleDownload.state = .results([])
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(for: .subtitles, subtitleScreen: .download, model: model), .row(0))
    }

    func testVersionsSpeedAndSyncKeepTheirOriginalActionsAndFocus() {
        let model = PlayerControlsModel()
        model.versions.options = [
            .init(version: .init(id: "current"), isSelected: true),
            .init(version: .init(id: "alternate"), isSelected: false)
        ]
        var events: [String] = []
        model.versions.onSelect = { events.append($0) }
        let rows = PlayerOptionsPanel.versionRows(model: model, close: { events.append("close") })
        rows[1].action()
        XCTAssertEqual(events, ["close", "alternate"])
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(for: .version, subtitleScreen: .tracks, model: model), .row(0))
        model.playbackSpeed = 1.5
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(for: .speed, subtitleScreen: .tracks, model: model),
                       .row(PlayerControls.speedPresets.firstIndex(of: 1.5)!))
        model.engineCapabilities = []
        XCTAssertNil(PlayerOptionsPanel.preferredFocus(for: .sync, subtitleScreen: .tracks, model: model))
        model.engineCapabilities = [.subtitleDelay]
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(for: .sync, subtitleScreen: .tracks, model: model), .row(10))
        model.engineCapabilities.insert(.audioDelay)
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(for: .sync, subtitleScreen: .tracks, model: model), .row(0))
    }

    func testPanelBodyCapSubtractsMeasuredHeaderAndTracksTheHostViewport() {
        let divider = PlozzFrostedSurface.dividerHeight
        for height: CGFloat in [280, 480, 960] {
            for header: CGFloat in [60, 96, 140] {
                let available = max(0, height - header - divider)
                XCTAssertEqual(PlayerOptionsPanel.bodyHeightLimit(
                    maximumHeight: height, headerHeight: header, styleFamily: true
                ), available)
                XCTAssertEqual(PlayerOptionsPanel.bodyHeightLimit(
                    maximumHeight: height, headerHeight: header, styleFamily: false
                ), min(440, available))
            }
        }
        XCTAssertEqual(PlayerOptionsPanel.bodyHeightLimit(maximumHeight: 0, headerHeight: 80, styleFamily: true), 0)
        XCTAssertEqual(PlayerOptionsPanel.bodyHeightLimit(maximumHeight: 50, headerHeight: 80, styleFamily: true), 0)
        XCTAssertEqual(PlayerOptionsPanel.bodyHeightLimit(maximumHeight: .infinity, headerHeight: 80, styleFamily: true), 0)
    }

    func testHostedPanelStaysWithinChangingHostBoundsWithoutCachingStyleHeights() async throws {
        let state = OptionsPanelProbeState()
        state.controls.subtitleStyle = .default
        state.controls.subtitleStyle.fontFamily = .system
        state.controls.subtitleOptions = (0..<24).map {
            .init(id: $0, title: Text(verbatim: "Subtitle \($0)"), isSelected: $0 == 0)
        }
        let host = UIHostingController(rootView: OptionsPanelProbe(state: state))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 960, height: 900))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds

        func waitForSize(_ predicate: (CGSize) -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                host.view.layoutIfNeeded()
                if predicate(state.measuredSize) { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Shared panel failed to settle inside its host's height: \(state.measuredSize)")
        }
        try await waitForSize { $0.height > 100 && $0.height <= 361 }
        XCTAssertEqual(state.measuredSize.width, SubtitleStylePanel.panelWidth, accuracy: 1)
        XCTAssertEqual(state.heightCache[.subtitles], 1_234, "Style screens must not replace the track-list cache.")

        state.maximumHeight = 280
        try await waitForSize { $0.height > 100 && $0.height <= 281 }
        state.maximumHeight = 600
        try await waitForSize { $0.height > 360 && $0.height <= 601 }
        state.screen = .styleFileFormatting
        try await waitForSize { $0.height > 100 && $0.height <= 601 }
        XCTAssertEqual(state.heightCache[.subtitles], 1_234)
        state.screen = .tracks
        try await waitForSize { _ in state.heightCache[.subtitles] != 1_234 }
        XCTAssertLessThanOrEqual(state.measuredSize.height, 601)
        XCTAssertGreaterThan(state.heightCache[.subtitles] ?? 0, state.measuredSize.height,
                             "Remember natural track height, not its visible scroll viewport.")
    }

    func testBothHostCapabilitiesKeepCurrentStyleRowsResetAndOnePercentEditing() async throws {
        for offersDual in [false, true] {
            let model = PlayerControlsModel()
            model.subtitleStyle = .default
            model.subtitleStyle.fontScale = 1.23
            var applied: [SubtitleStyle] = []
            var opened: [Screen] = []
            let actions = PlayerOptionsActions(setSubtitleStyle: {
                model.subtitleStyle = $0
                applied.append($0)
            })
            var captured: [SubtitleStylePanel.StyleRowSpec]?
            let host = UIHostingController(rootView: StyleRowsProbe(
                model: model, actions: actions, offersDual: offersDual,
                open: { opened.append($0) }, capture: { captured = $0 }
            ))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 960, height: 720))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.frame = window.bounds
            let deadline = ContinuousClock.now + .seconds(3)
            while captured == nil, ContinuousClock.now < deadline {
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let rows = try XCTUnwrap(captured)
            XCTAssertEqual(rows.map(\.slot), Array(0..<rows.count))
            XCTAssertEqual(rows.first?.title, LocalizedStringResource("Use System Caption Style"))
            XCTAssertFalse(rows.contains { $0.title == LocalizedStringResource("Use File Positions") })
            XCTAssertFalse(rows.contains { $0.title == LocalizedStringResource("Use File Colors") })
            XCTAssertFalse(rows.contains { $0.title == LocalizedStringResource("Use Bold and Italic") })
            let dual = rows.first { $0.title == LocalizedStringResource("Dual Subtitles") }
            XCTAssertEqual(dual != nil, offersDual)
            for row in rows {
                if case let .submenu(_, open) = row.kind { open() }
            }
            XCTAssertTrue(opened.contains(.styleFont))
            XCTAssertTrue(opened.contains(.styleFileFormatting))
            XCTAssertEqual(opened.contains(.styleDual), offersDual)

            let size = try XCTUnwrap(rows.first { $0.title == LocalizedStringResource("Text Size") })
            if case let .number(_, step) = size.kind {
                step(1)
                XCTAssertEqual(model.subtitleStyle.fontScale, 1.24, accuracy: 0.000_001)
            } else { XCTFail("Text Size must keep its one-percent stepper.") }
            XCTAssertEqual(SubtitleStyle.fontScaleRange, 0.2...4)
            XCTAssertEqual(SubtitleStyle.fontScaleStep, 0.01)
            let reset = try XCTUnwrap(rows.last)
            XCTAssertEqual(reset.title, LocalizedStringResource("Reset to App Default"))
            if case let .action(run) = reset.kind {
                run()
                XCTAssertEqual(applied.last, .default)
                XCTAssertFalse(model.subtitleStyle.followsSystemStyle)
            } else { XCTFail("Reset must apply the app default directly, not a captured system style.") }
        }
    }
}

@MainActor @Observable
private final class OptionsPanelProbeState {
    let controls = PlayerControlsModel()
    var screen = PlayerControls.SubtitleScreen.styleFont
    var maximumHeight: CGFloat = 360
    var heightCache: [PlayerControls.Category: CGFloat] = [.subtitles: 1_234]
    var measuredSize: CGSize = .zero
}

@MainActor
private struct OptionsPanelProbe: View {
    let state: OptionsPanelProbeState
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        PlayerOptionsPanel(
            category: .subtitles, model: state.controls, palette: .dark, actions: .init(),
            subtitleScreen: Binding(get: { state.screen }, set: { state.screen = $0 }),
            heightCache: Binding(get: { state.heightCache }, set: { state.heightCache = $0 }),
            focus: $focus, close: {}, backRequest: 0, maximumHeight: state.maximumHeight,
            offersDualSubtitles: false
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { state.measuredSize = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

@MainActor
private struct StyleRowsProbe: View {
    let model: PlayerControlsModel
    let actions: PlayerOptionsActions
    let offersDual: Bool
    let open: (PlayerControls.SubtitleScreen) -> Void
    let capture: ([SubtitleStylePanel.StyleRowSpec]) -> Void
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        let panel = SubtitleStylePanel(
            screen: .style, model: model, palette: .dark, actions: actions,
            focus: $focus, openScreen: open, offersDualSubtitles: offersDual
        )
        ScrollView { panel }
            .onAppear { capture(panel.styleMainRows.rows) }
    }
}
#endif
