#if os(iOS)
import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlayerMoreMenuPresentationTests: XCTestCase {
    func testFELOverrideAppearsOnlyWhenAvailableAndHonorsStaleMenuGuard() throws {
        let model = controls()
        let availability = PlayerMoreMenuAvailability(video: false)
        XCTAssertFalse(PlayerMoreMenu.sections(model, availability: availability).contains(.fel))
        model.felConversion.isAvailable = true
        var choices: [Bool] = []
        var current = true
        var actions = PlayerMoreMenuActions()
        actions.isCurrent = { current }
        actions.setDolbyVisionFELConversion = { choices.append($0) }
        let menu = PlayerMoreMenu.make(
            model: model, availability: availability, locale: .init(identifier: "en"),
            section: .fel, actions: actions
        )
        let toggle = try XCTUnwrap(menu.children.first as? UIAction)
        XCTAssertEqual(toggle.title, "P7 FEL → P8.1 conversion")
        XCTAssertEqual(toggle.state, .on)
        perform(toggle)
        XCTAssertEqual(choices, [false])
        current = false
        perform(toggle)
        XCTAssertEqual(choices, [false])
        model.felConversion.isEnabled = false
        let disabled = PlayerMoreMenu.make(
            model: model, availability: availability, locale: .init(identifier: "en"),
            section: .fel, actions: actions
        )
        XCTAssertEqual((disabled.children.first as? UIAction)?.state, .off)
    }

    func testLayoutFollowsTheActualPlayerViewport() {
        XCTAssertEqual(PlayerMenuLayout(size: .zero), .consolidated)
        XCTAssertEqual(PlayerMenuLayout(size: CGSize(width: 390, height: 844)), .consolidated)
        XCTAssertEqual(PlayerMenuLayout(size: CGSize(width: 844, height: 390)), .separate)
        XCTAssertEqual(PlayerMenuLayout(size: CGSize(width: 1024, height: 768)), .separate)
        XCTAssertEqual(PlayerMenuLayout(size: CGSize(width: 507, height: 768)), .consolidated)
    }

    func testCommandRowsHaveNeitherIconsNorSelectionAndCustomSpeedIsOutsidePresets() throws {
        let model = controls()
        model.playbackSpeed = 1.3
        let menu = PlayerMoreMenu.make(
            model: model, availability: .init(maximumSpeed: 2, quality: .original, versions: true, multiview: true),
            locale: .init(identifier: "en"), actions: .init()
        )
        let commands = Set(["Search & Download…", "Advanced…", "Custom…", "Version", "Multiview"])
        func verify(_ menu: UIMenu) {
            XCTAssertNil(menu.image, "Navigation menus should not add decorative popup icons.")
            for child in menu.children {
                if let submenu = child as? UIMenu { verify(submenu) }
                if let action = child as? UIAction, commands.contains(action.title) {
                    XCTAssertNil(action.image)
                    XCTAssertEqual(action.state, .off, "\(action.title) is a command, not a selected preset.")
                    XCTAssertFalse(menu.options.contains(.singleSelection))
                }
            }
        }
        verify(menu)
        let speed = try submenu("Playback Speed", in: menu)
        XCTAssertFalse(speed.options.contains(.singleSelection))
        let presets = try XCTUnwrap(speed.children.first as? UIMenu)
        XCTAssertTrue(presets.options.contains(.singleSelection))
        XCTAssertTrue(presets.children.compactMap { $0 as? UIAction }.allSatisfy { $0.state == .off })
    }

    func testOverlappingNativeOwnersDoNotReleaseRequestsUntilTheLastMenuCloses() {
        let presentation = PlayerMenuPresentation()
        let audio = UUID()
        let subtitles = UUID()
        presentation.setPresented(true, owner: audio)
        presentation.setPresented(true, owner: subtitles)
        presentation.request(.subtitleAdvanced, generation: presentation.generation)
        presentation.setPresented(false, owner: audio)
        presentation.setPresented(false, owner: audio)
        XCTAssertTrue(presentation.isPresented)
        XCTAssertNil(presentation.destination)
        presentation.setPresented(false, owner: subtitles)
        XCTAssertEqual(presentation.takeDestination(), .subtitleAdvanced)
        presentation.reset()
        let next = UUID()
        presentation.setPresented(true, owner: next)
        presentation.setPresented(false, owner: subtitles)
        XCTAssertTrue(presentation.isPresented, "Late teardown from an old menu cannot close a new owner.")
    }

    func testAdaptiveControlsReplacePortraitEllipsisWithDirectLandscapeMenusAndBalanceRemoval() async throws {
        let state = FixtureState(controls: controls())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Fixture(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            state.presentation.reset()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { self.buttons(in: host.view).count == 1 }
        let more = try XCTUnwrap(buttons(in: host.view).first)
        XCTAssertEqual(more.accessibilityIdentifier, "player-playback-options")
        more.performPrimaryAction()
        try await waitUntil { more.presentedMenu != nil }
        state.layout = .separate
        try await waitUntil {
            self.buttons(in: host.view).count == 4 && !state.presentation.isBusy
                && more.presentedMenu == nil
        }
        XCTAssertEqual(
            buttons(in: host.view).sorted {
                $0.convert($0.bounds, to: window).midX < $1.convert($1.bounds, to: window).midX
            }.compactMap(\.accessibilityIdentifier),
            ["player-audio", "player-subtitles", "player-playback-speed", "player-settings"]
        )
        let rate = try XCTUnwrap(buttons(in: host.view).first { $0.accessibilityIdentifier == "player-playback-speed" })
        XCTAssertEqual(rate.currentTitle, "1×")
        state.controls.playbackSpeed = 1.25
        try await waitUntil { rate.currentTitle == "1.25×" && rate.accessibilityValue == "1.25×" }
        let settings = try XCTUnwrap(buttons(in: host.view).first { $0.accessibilityIdentifier == "player-settings" })
        XCTAssertEqual(settings.accessibilityLabel, "Playback settings")
        XCTAssertEqual(PlayerOptionsMenuButton.Kind.subtitles.symbol, LiveChannelTrackMenuKind.subtitles.icon)
        let settingsImage = try XCTUnwrap(settings.image(for: .normal))
        let adjustmentsImage = try XCTUnwrap(UIImage(
            systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)
        ))
        XCTAssertTrue(settingsImage.isEqual(adjustmentsImage))
        let audio = try XCTUnwrap(buttons(in: host.view).first { $0.accessibilityIdentifier == "player-audio" })
        audio.performPrimaryAction()
        try await waitUntil { audio.presentedMenu != nil && state.presentation.isPresented }
        let menu = try XCTUnwrap(audio.presentedMenu)
        XCTAssertEqual(menu.title, "Audio")
        XCTAssertTrue(try XCTUnwrap(menu.children.first as? UIMenu).title.isEmpty)
        XCTAssertEqual(visible(menu).map(\.title), ["English (Opus 5.1)", "French (AAC Stereo)"])
        let stale = try XCTUnwrap(visible(menu).first as? UIAction)
        state.controls.audioOptions = []
        try await waitUntil { self.buttons(in: host.view).count == 3 && !state.presentation.isBusy }
        perform(stale)
        XCTAssertTrue(state.audioSelections.isEmpty)
        state.layout = .consolidated
        try await waitUntil {
            self.buttons(in: host.view).count == 1
                && self.buttons(in: host.view).first?.accessibilityIdentifier == "player-playback-options"
        }
    }

    func testNativeButtonTeardownReleasesOnlyItsOwnOverlappingPresentation() async throws {
        let state = FixtureState(controls: controls())
        state.layout = .separate
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Fixture(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            state.presentation.reset()
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { self.buttons(in: host.view).count == 4 }
        let audio = try XCTUnwrap(buttons(in: host.view).first { $0.accessibilityIdentifier == "player-audio" })
        let subtitles = try XCTUnwrap(buttons(in: host.view).first { $0.accessibilityIdentifier == "player-subtitles" })
        let audioInteraction = try XCTUnwrap(audio.contextMenuInteraction)
        let subtitleInteraction = try XCTUnwrap(subtitles.contextMenuInteraction)
        XCTAssertNotNil(audio.contextMenuInteraction(audioInteraction, configurationForMenuAtLocation: .zero))
        XCTAssertNotNil(subtitles.contextMenuInteraction(subtitleInteraction, configurationForMenuAtLocation: .zero))
        state.presentation.request(.subtitleAdvanced, generation: state.presentation.generation)
        PlayerOptionsMenuButton.dismantleUIView(audio, coordinator: ())
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(state.presentation.isPresented)
        XCTAssertNil(state.presentation.destination)
        XCTAssertNil(state.sheet)
        subtitles.onPresentationChange?(false)
        try await waitUntil { state.sheet == .subtitleAdvanced && !state.presentation.isPresented }
    }

    func testOneMenuOffersDirectTracksThenDownloadAndAdvanced() throws {
        let model = controls()
        var selectedAudio: Int?
        var selectedSubtitle: Int?
        var requested: PlayerMenuDestination?
        var actions = PlayerMoreMenuActions()
        actions.selectAudio = { selectedAudio = $0 }
        actions.selectSubtitle = { selectedSubtitle = $0 }
        actions.request = { requested = $0 }
        let menu = PlayerMoreMenu.make(
            model: model, availability: .init(maximumSpeed: 2, quality: .hd1080, versions: true),
            locale: .init(identifier: "en"), actions: actions
        )
        XCTAssertEqual(visible(menu).map(\.title), ["Subtitles", "Audio", "Playback Speed", "Quality", "Zoom", "Version"])
        let subtitles = try submenu("Subtitles", in: menu)
        let subtitleRows = visible(subtitles).compactMap { $0 as? UIAction }
        XCTAssertEqual(subtitleRows.map(\.title), ["Off", "English (SDH)", "Search & Download…", "Advanced…"])
        XCTAssertEqual(subtitleRows[0].state, .on)
        perform(subtitleRows[1])
        XCTAssertEqual(selectedSubtitle, 9)
        perform(subtitleRows[2])
        XCTAssertEqual(requested, .subtitleSearch)
        perform(subtitleRows[3])
        XCTAssertEqual(requested, .subtitleAdvanced)
        let audio = try submenu("Audio", in: menu)
        XCTAssertTrue(try XCTUnwrap(audio.children.first as? UIMenu).title.isEmpty)
        XCTAssertFalse(visible(audio).contains { $0 is UIMenu }, "Tracks must not need a second nested menu.")
        let audioRows = visible(audio).compactMap { $0 as? UIAction }
        XCTAssertEqual(audioRows.map(\.title), ["English (Opus 5.1)", "French (AAC Stereo)"])
        perform(audioRows[1])
        XCTAssertEqual(selectedAudio, 42)
    }

    func testUpwardNativeSubtitleMenuRendersTracksBeforeDownloadAndAdvanced() async throws {
        let state = FixtureState(controls: controls())
        state.layout = .separate
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: VStack { Spacer(); Fixture(state: state) })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            state.presentation.reset()
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let expected = ["Off", "English (SDH)", "Search & Download…", "Advanced…"]
        func rowLabels(in view: UIView) -> [UILabel] {
            guard !view.isHidden, view.alpha > 0 else { return [] }
            if let label = view as? UILabel, let text = label.text, expected.contains(text) { return [label] }
            return view.subviews.flatMap { rowLabels(in: $0) }
        }
        func displayedRows() -> [UILabel] {
            scene.windows.flatMap { rowLabels(in: $0) }
                .sorted { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
        }
        try await waitUntil { self.buttons(in: host.view).contains { $0.accessibilityIdentifier == "player-subtitles" } }
        let button = try XCTUnwrap(buttons(in: host.view).first { $0.accessibilityIdentifier == "player-subtitles" })
        button.performPrimaryAction()
        try await waitUntil { button.presentedMenu != nil && displayedRows().count == expected.count }
        XCTAssertEqual(displayedRows().compactMap(\.text), expected)
        let bottomRow = try XCTUnwrap(displayedRows().last)
        XCTAssertLessThan(bottomRow.convert(bottomRow.bounds, to: nil).midY, button.convert(button.bounds, to: nil).midY)
        let interaction = try XCTUnwrap(button.contextMenuInteraction)
        let configuration = try XCTUnwrap(button.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero))
        XCTAssertEqual(configuration.preferredMenuElementOrder, .fixed, "Snapshot reuse must preserve fixed ordering too.")
        interaction.dismissMenu()
        try await waitUntil { button.presentedMenu == nil && !state.presentation.isPresented }
    }

    func testUnavailableFeaturesAreOmittedAndSpeedPresetsRespectEngineMaximum() throws {
        let model = controls()
        model.subtitleDownload.canSearch = false
        model.subtitleAppearance.primaryIsBurnedIn = true
        var chosenSpeed: Double?
        var destination: PlayerMenuDestination?
        var actions = PlayerMoreMenuActions()
        actions.setSpeed = { chosenSpeed = $0 }
        actions.request = { destination = $0 }
        let menu = PlayerMoreMenu.make(
            model: model, availability: .init(maximumSpeed: 1.5, video: false),
            locale: .init(identifier: "en"), actions: actions
        )
        XCTAssertEqual(visible(menu).map(\.title), ["Subtitles", "Audio", "Playback Speed"])
        XCTAssertEqual(visible(try submenu("Subtitles", in: menu)).map(\.title), ["Off", "English (SDH)"])
        let speeds = visible(try submenu("Playback Speed", in: menu)).compactMap { $0 as? UIAction }
        XCTAssertEqual(speeds.map(\.title), ["0.5×", "0.75×", "1×", "1.25×", "1.5×", "Custom…"])
        XCTAssertEqual(speeds[2].state, .on)
        perform(speeds[3])
        XCTAssertEqual(chosenSpeed, 1.25)
        perform(speeds[5])
        XCTAssertEqual(destination, .speed)
        XCTAssertEqual(chosenSpeed, 1.25, "Opening fine control must not change speed.")
        model.engineCapabilities = []
        XCTAssertFalse(visible(PlayerMoreMenu.make(
            model: model, availability: .init(maximumSpeed: 2),
            actions: .init()
        )).contains { $0.title == "Playback Speed" })
    }

    func testOverflowStartsWithCurrentQualityAndDoesNotRepeatDirectControls() throws {
        let model = controls()
        let availability = PlayerMoreMenuAvailability(maximumSpeed: 2, quality: .hd1080, versions: true)
        var requested: PlayerMenuDestination?
        var selected: [StreamingQuality] = []
        var actions = PlayerMoreMenuActions()
        actions.request = { requested = $0 }
        actions.setQuality = { selected.append($0) }
        let overflow = PlayerMoreMenu.make(
            model: model, availability: availability, locale: .init(identifier: "en"), settingsOnly: true, actions: actions
        )
        XCTAssertEqual(visible(overflow).map(\.title), ["Quality", "Zoom", "Version"])
        let zoom = try submenu("Zoom", in: overflow)
        XCTAssertTrue(zoom.options.contains(.singleSelection))
        let quality = try submenu("Quality", in: overflow)
        XCTAssertEqual(quality.subtitle, "1080p · 8 Mbps")
        let choices = visible(quality).compactMap { $0 as? UIAction }
        XCTAssertEqual(choices.map(\.title), [
            "Maximum", "1080p · 20 Mbps", "1080p · 8 Mbps", "720p · 4 Mbps",
            "720p · 2 Mbps", "480p · 1 Mbps", "240p · 500 Kbps", "Advanced…"
        ])
        XCTAssertEqual(choices.filter { $0.state == .on }.map(\.title), ["1080p · 8 Mbps"])
        perform(try XCTUnwrap(choices.first { $0.title == "720p · 2 Mbps" }))
        XCTAssertEqual(selected, [.hd720])
        XCTAssertNil(requested)
        perform(try XCTUnwrap(zoom.children[1] as? UIAction))
        XCTAssertEqual(model.videoZoom.settings.mode, .fill)
        perform(try XCTUnwrap(choices.last))
        XCTAssertEqual(requested, .quality)
        XCTAssertEqual(selected, [.hd720])
        XCTAssertEqual(model.videoZoom.settings.mode, .fill)
    }

    func testQualityFiltersPresetsAndRetainsCurrentLimitWithoutZoom() throws {
        let model = controls()
        model.engineCapabilities = []
        let custom = try StreamingQuality.custom(maximumHeight: 720, bitrateKbps: 3_000)
        for current in [custom, .low] {
            let root = PlayerMoreMenu.make(
                model: model, availability: .init(video: false, quality: current, qualitySupport: .silo),
                locale: .init(identifier: "en"), settingsOnly: true, actions: .init()
            )
            XCTAssertEqual(visible(root).map(\.title), ["Quality"])
            let quality = try submenu("Quality", in: root)
            let rows = visible(quality).compactMap { $0 as? UIAction }
            let checked = rows.filter { $0.state == .on }
            XCTAssertEqual(checked.count, 1)
            let row = try XCTUnwrap(checked.first)
            XCTAssertEqual(quality.subtitle, row.title)
            if current == .low {
                XCTAssertEqual(row.title, "240p · 500 Kbps")
                XCTAssertTrue(row.attributes.contains(.disabled))
            } else {
                XCTAssertTrue(row.title.hasPrefix("Custom"))
                XCTAssertFalse(row.attributes.contains(.disabled))
                XCTAssertFalse(rows.contains { $0.title == "240p · 500 Kbps" })
            }
            XCTAssertTrue(rows.contains { $0.title == "480p · 1 Mbps" && !$0.attributes.contains(.disabled) })
        }
        XCTAssertTrue(PlayerMoreMenu.make(model: model, availability: .init(video: false),
                                          settingsOnly: true, actions: .init()).children.isEmpty)
    }

    func testCombinedVideoMenusDeferQualityUntilDismissalInBothLayouts() async throws {
        for layout in [PlayerMenuLayout.consolidated, .separate] {
            let state = FixtureState(controls: controls())
            state.layout = layout
            state.qualityAvailable = true
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: Fixture(state: state))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                state.presentation.reset()
                host.dismiss(animated: false)
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            let identifier = layout == .consolidated ? "player-playback-options" : "player-settings"
            try await waitUntil { self.buttons(in: host.view).contains { $0.accessibilityIdentifier == identifier } }
            let button = try XCTUnwrap(buttons(in: host.view).first { $0.accessibilityIdentifier == identifier })
            button.performPrimaryAction()
            try await waitUntil { button.presentedMenu != nil }
            let menu = try XCTUnwrap(button.presentedMenu)
            if layout == .separate {
                XCTAssertEqual(visible(menu).map(\.title), ["Quality", "Zoom"])
            }
            let quality = try submenu("Quality", in: menu)
            perform(try XCTUnwrap(visible(quality).first { $0.title == "Advanced…" } as? UIAction))
            XCTAssertTrue(state.presentation.isPresented)
            XCTAssertNil(state.sheet)
            try XCTUnwrap(button.presentationInteraction).dismissMenu()
            try await waitUntil {
                state.sheet == .quality && !state.presentation.isPresented && button.presentedMenu == nil
                    && host.presentedViewController != nil
            }
            state.sheet = nil
            try await waitUntil { host.presentedViewController == nil }
        }
    }

    func testCombinedVideoAvailabilityChangesRejectOldQualityAndZoomActions() async throws {
        let state = FixtureState(controls: controls())
        state.layout = .separate
        state.qualityAvailable = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Fixture(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            state.presentation.reset()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { self.buttons(in: host.view).count == 4 }
        func invalidateQuality(_ preset: String, by invalidate: () -> Void) async throws {
            let button = try XCTUnwrap(buttons(in: host.view).first { $0.accessibilityIdentifier == "player-settings" })
            button.performPrimaryAction()
            try await waitUntil { button.presentedMenu != nil }
            let quality = try submenu("Quality", in: XCTUnwrap(button.presentedMenu))
            let oldQuality = try XCTUnwrap(visible(quality).first { $0.title == preset } as? UIAction)
            let oldAdvanced = try XCTUnwrap(visible(quality).first { $0.title == "Advanced…" } as? UIAction)
            let generation = state.presentation.generation
            invalidate()
            try await waitUntil {
                state.presentation.generation > generation && !state.presentation.isBusy && button.presentedMenu == nil
            }
            perform(oldQuality)
            perform(oldAdvanced)
            XCTAssertEqual(state.qualitySelections, [])
            XCTAssertNil(state.presentation.destination)
            XCTAssertNil(state.sheet)
        }
        try await invalidateQuality("240p · 500 Kbps") { state.support = .silo }
        try await invalidateQuality("720p · 2 Mbps") { state.qualityAvailable = false }
        let next = try XCTUnwrap(buttons(in: host.view).first { $0.accessibilityIdentifier == "player-settings" })
        next.performPrimaryAction()
        try await waitUntil { next.presentedMenu != nil }
        let oldZoom = try XCTUnwrap(visible(try submenu("Zoom", in: XCTUnwrap(next.presentedMenu))).first as? UIAction)
        state.controls.videoZoom.settings.mode = .fill
        let zoomGeneration = state.presentation.generation
        state.controls.engineCapabilities.remove(.videoZoom)
        try await waitUntil { state.presentation.generation > zoomGeneration && !state.presentation.isBusy && next.presentedMenu == nil }
        perform(oldZoom)
        XCTAssertEqual(state.controls.videoZoom.settings.mode, .fill)
        XCTAssertTrue(PlayerMoreMenu.sections(state.controls, availability: .init(quality: .original)).contains(.quality))
    }

    func testLiveVideoUsesTheRealZoomOwnerAndMultiviewIsDeferred() throws {
        let model = controls()
        let zoom = PlayerVideoZoomModel()
        var requested: PlayerMenuDestination?
        var actions = PlayerMoreMenuActions()
        actions.request = { requested = $0 }
        let menu = PlayerMoreMenu.make(
            model: model, availability: .init(videoModel: zoom, multiview: true),
            locale: .init(identifier: "en"), settingsOnly: true, actions: actions
        )
        XCTAssertEqual(visible(menu).map(\.title), ["Multiview", "Zoom"])
        let video = try submenu("Zoom", in: menu)
        let choices = visible(video).compactMap { $0 as? UIAction }
        perform(choices[1])
        XCTAssertEqual(zoom.settings.mode, .fill)
        XCTAssertEqual(model.videoZoom.settings.mode, .fit)
        perform(choices[3])
        XCTAssertEqual(requested, .zoom)
        perform(try XCTUnwrap(visible(menu).first { $0.title == "Multiview" } as? UIAction))
        XCTAssertEqual(requested, .multiview)
    }

    func testPresentationWaitsForDismissalAndResetRejectsStaleRequests() {
        let presentation = PlayerMenuPresentation()
        presentation.setPresented(true)
        let generation = presentation.generation
        presentation.request(.subtitleSearch, generation: generation)
        XCTAssertTrue(presentation.isBusy)
        XCTAssertNil(presentation.destination)
        XCTAssertNil(presentation.takeDestination())
        presentation.setPresented(false)
        XCTAssertTrue(presentation.isBusy)
        XCTAssertEqual(presentation.takeDestination(), .subtitleSearch)
        XCTAssertFalse(presentation.isBusy)
        presentation.setPresented(true)
        presentation.request(.subtitleAdvanced, generation: generation)
        presentation.reset()
        presentation.setPresented(false)
        presentation.request(.quality, generation: generation)
        XCTAssertNil(presentation.takeDestination())
        XCTAssertFalse(presentation.isBusy)
    }

    func testNativeMenuOpensSheetOnlyAfterDismissalAndOldActionsCannotMutateNewContext() async throws {
        let state = FixtureState(controls: controls())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Fixture(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            state.presentation.reset()
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { self.button(in: host.view) != nil }
        let button = try XCTUnwrap(button(in: host.view))
        XCTAssertEqual(button.accessibilityIdentifier, "player-playback-options")
        button.performPrimaryAction()
        try await waitUntil { button.presentedMenu != nil }
        let menu = try XCTUnwrap(button.presentedMenu)
        let audio = try submenu("Audio", in: menu)
        let oldAudio = try XCTUnwrap(visible(audio).first as? UIAction)
        let video = try submenu("Zoom", in: menu)
        let oldZoom = try XCTUnwrap(visible(video).compactMap { $0 as? UIAction }.first)
        let subtitles = try submenu("Subtitles", in: menu)
        perform(try XCTUnwrap(visible(subtitles).first { $0.title == "Advanced…" } as? UIAction))
        XCTAssertNil(state.sheet)
        XCTAssertNil(state.presentation.destination)
        XCTAssertTrue(state.presentation.isPresented)
        let interaction = try XCTUnwrap(button.contextMenuInteraction)
        interaction.dismissMenu()
        try await waitUntil {
            state.sheet == .subtitleAdvanced && !state.presentation.isPresented
                && button.presentedMenu == nil && host.presentedViewController != nil
        }
        XCTAssertNotNil(host.presentedViewController)
        state.sheet = nil
        try await waitUntil { host.presentedViewController == nil }
        state.controls.videoZoom.settings.mode = .fill
        state.presentation.reset()
        perform(oldAudio)
        perform(oldZoom)
        XCTAssertEqual(state.audioSelections, [])
        XCTAssertEqual(state.controls.videoZoom.settings.mode, .fill)
    }

    private func controls() -> PlayerControlsModel {
        let model = PlayerControlsModel()
        model.audioOptions = [
            .init(id: 17, title: Text(verbatim: "English (Opus 5.1)"), isSelected: true, nativeTitle: "English (Opus 5.1)"),
            .init(id: 42, title: Text(verbatim: "French (AAC Stereo)"), isSelected: false, nativeTitle: "French (AAC Stereo)")
        ]
        model.subtitleOptions = [
            .init(id: -1, title: Text("Off"), isSelected: true, nativeTitle: "Off"),
            .init(id: 9, title: Text(verbatim: "English (SDH)"), isSelected: false, nativeTitle: "English (SDH)")
        ]
        model.subtitleDownload.canSearch = true
        model.engineCapabilities = [.playbackSpeed, .videoZoom]
        return model
    }

    private func visible(_ menu: UIMenu) -> [UIMenuElement] {
        menu.children.flatMap { child in
            if let group = child as? UIMenu, group.options.contains(.displayInline) { return visible(group) }
            return [child]
        }
    }

    private func submenu(_ title: String, in menu: UIMenu) throws -> UIMenu {
        try XCTUnwrap(visible(menu).first { $0.title == title } as? UIMenu)
    }

    private func perform(_ action: UIAction) {
        let button = UIButton(type: .system)
        button.addAction(action, for: .primaryActionTriggered)
        button.sendActions(for: .primaryActionTriggered)
    }

    private func button(in view: UIView) -> PlayerOptionsMenuControl? {
        if let button = view as? PlayerOptionsMenuControl { return button }
        return view.subviews.lazy.compactMap { self.button(in: $0) }.first
    }

    private func buttons(in view: UIView) -> [PlayerOptionsMenuControl] {
        if let button = view as? PlayerOptionsMenuControl { return [button] }
        return view.subviews.flatMap { buttons(in: $0) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }

    @MainActor @Observable
    final class FixtureState {
        let controls: PlayerControlsModel
        let presentation = PlayerMenuPresentation()
        var sheet: PlayerMenuDestination?
        var audioSelections: [Int] = []
        var qualitySelections: [StreamingQuality] = []
        var support: StreamingQualitySupport = .standard
        var layout = PlayerMenuLayout.consolidated
        var qualityAvailable = false
        init(controls: PlayerControlsModel) { self.controls = controls }
    }

    private struct Fixture: View {
        @Bindable var state: FixtureState

        var body: some View {
            var actions = PlayerMoreMenuActions()
            actions.selectAudio = { state.audioSelections.append($0) }
            actions.setQuality = { state.qualitySelections.append($0) }
            return PlayerMoreMenuButton(
                model: state.controls, availability: .init(maximumSpeed: 2, quality: state.qualityAvailable ? .original : nil,
                                                           qualitySupport: state.support),
                presentation: state.presentation, layout: state.layout, actions: actions
            )
            .environment(\.locale, .init(identifier: "en"))
            .task(id: state.presentation.destination) {
                if let destination = state.presentation.takeDestination() { state.sheet = destination }
            }
            .plozzSheet(item: $state.sheet) { destination in
                Text(verbatim: destination.rawValue).accessibilityIdentifier("more-menu-sheet-fixture")
            }
        }
    }
}
#endif
