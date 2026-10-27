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
    func testLayoutFollowsTheActualPlayerViewport() {
        XCTAssertEqual(PlayerMenuLayout(size: .zero), .consolidated)
        XCTAssertEqual(PlayerMenuLayout(size: CGSize(width: 390, height: 844)), .consolidated)
        XCTAssertEqual(PlayerMenuLayout(size: CGSize(width: 844, height: 390)), .separate)
        XCTAssertEqual(PlayerMenuLayout(size: CGSize(width: 1024, height: 768)), .separate)
        XCTAssertEqual(PlayerMenuLayout(size: CGSize(width: 507, height: 768)), .consolidated)
    }

    func testCommunityTimestampsAreOptInAndUseTheSharedDestination() throws {
        let model = controls()
        XCTAssertFalse(PlayerMoreMenu.sections(model, availability: .init()).contains(.timestamps))
        let unavailable = PlayerMoreMenu.make(model: model, availability: .init(), actions: .init())
        XCTAssertFalse(visible(unavailable).contains { $0.title == "Community timestamps" })

        let availability = PlayerMoreMenuAvailability(timestamps: true)
        XCTAssertEqual(PlayerMoreMenu.sections(model, availability: availability).last, .timestamps)
        XCTAssertEqual(PlayerMenuSection.timestamps.destination, .timestamps)
        var requested: PlayerMenuDestination?
        var actions = PlayerMoreMenuActions()
        actions.request = { requested = $0 }
        let menu = PlayerMoreMenu.make(
            model: model, availability: availability, locale: .init(identifier: "en"), actions: actions
        )
        let command = try XCTUnwrap(visible(menu).first { $0.title == "Community timestamps" } as? UIAction)
        XCTAssertNil(command.image)
        XCTAssertEqual(command.state, .off)
        perform(command)
        XCTAssertEqual(requested, .timestamps)
    }

    func testCommunityTimestampSheetWaitsForDismissalAndAvailabilityLossInvalidatesOldActions() async throws {
        let state = FixtureState(controls: controls())
        state.timestampsAvailable = true
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
        button.performPrimaryAction()
        try await waitUntil { button.presentedMenu != nil }
        let command = try XCTUnwrap(visible(try XCTUnwrap(button.presentedMenu))
            .first { $0.title == "Community timestamps" } as? UIAction)
        perform(command)
        XCTAssertTrue(state.presentation.isPresented)
        XCTAssertNil(state.sheet)
        XCTAssertNil(state.presentation.destination)
        try XCTUnwrap(button.contextMenuInteraction).dismissMenu()
        try await waitUntil { state.sheet == .timestamps && host.presentedViewController != nil }
        state.sheet = nil
        try await waitUntil { host.presentedViewController == nil }
        let generation = state.presentation.generation
        state.timestampsAvailable = false
        try await waitUntil { state.presentation.generation > generation && !state.presentation.isBusy }
        perform(command)
        XCTAssertNil(state.sheet)
        XCTAssertNil(state.presentation.destination)
    }

    func testCommandRowsHaveNeitherIconsNorSelectionAndCustomSpeedIsOutsidePresets() throws {
        let model = controls()
        model.playbackSpeed = 1.3
        let menu = PlayerMoreMenu.make(
            model: model, availability: .init(maximumSpeed: 2, quality: true, versions: true, multiview: true),
            locale: .init(identifier: "en"), actions: .init()
        )
        let commands = Set(["Search & Download…", "Advanced…", "Custom…", "Quality", "Version", "Multiview"])
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
            Set(buttons(in: host.view).compactMap(\.accessibilityIdentifier)),
            ["player-subtitles", "player-audio", "player-playback-speed", "player-video"]
        )
        let video = try XCTUnwrap(buttons(in: host.view).first { $0.accessibilityIdentifier == "player-video" })
        XCTAssertEqual(video.accessibilityLabel, "Video")
        XCTAssertEqual(PlayerOptionsMenuButton.Kind.video.symbol, "slider.horizontal.3")
        XCTAssertEqual(PlayerOptionsMenuButton.Kind.video.symbol, LiveChannelTrackMenuKind.playback.icon)
        XCTAssertEqual(PlayerOptionsMenuButton.Kind.subtitles.symbol, LiveChannelTrackMenuKind.subtitles.icon)
        let videoImage = try XCTUnwrap(video.image(for: .normal))
        let adjustmentsImage = try XCTUnwrap(UIImage(
            systemName: "slider.horizontal.3", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)
        ))
        XCTAssertTrue(videoImage.isEqual(adjustmentsImage), "Video options must not look like a fullscreen action.")
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
            model: model, availability: .init(maximumSpeed: 2, quality: true, versions: true),
            locale: .init(identifier: "en"), actions: actions
        )
        XCTAssertEqual(visible(menu).map(\.title), ["Subtitles", "Audio", "Playback Speed", "Video", "Version"])
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

    func testVideoCombinesZoomAndQualityWithoutTreatingQualityAsASelectedMode() throws {
        let model = controls()
        let availability = PlayerMoreMenuAvailability(maximumSpeed: 2, quality: true, versions: true)
        XCTAssertEqual(PlayerMoreMenu.sections(model, availability: availability), [.subtitles, .audio, .speed, .video, .versions])
        var requested: PlayerMenuDestination?
        var actions = PlayerMoreMenuActions()
        actions.request = { requested = $0 }
        let video = PlayerMoreMenu.make(
            model: model, availability: availability, locale: .init(identifier: "en"), section: .video, actions: actions
        )
        let zoom = PlayerZoomMenu.make(model: model.videoZoom, locale: .init(identifier: "en"), onCustomZoom: {})
        XCTAssertTrue(video.title.isEmpty, "The standalone Video popup needs no category heading.")
        XCTAssertEqual(try XCTUnwrap(video.children.first as? UIMenu).title, "Zoom Mode")
        let choices = visible(video).compactMap { $0 as? UIAction }
        XCTAssertEqual(choices.map(\.title), zoom.children.map(\.title) + ["Quality"])
        XCTAssertFalse(video.options.contains(.singleSelection))
        XCTAssertTrue(try XCTUnwrap(video.children.first as? UIMenu).options.contains(.singleSelection))
        let quality = try XCTUnwrap(choices.last)
        XCTAssertEqual(quality.state, .off)
        XCTAssertNil(quality.image)
        XCTAssertFalse(try XCTUnwrap(video.children.last as? UIMenu).options.contains(.singleSelection))
        perform(choices[1])
        XCTAssertEqual(model.videoZoom.settings.mode, .fill)
        perform(quality)
        XCTAssertEqual(requested, .quality)
        XCTAssertEqual(model.videoZoom.settings.mode, .fill)
    }

    func testQualityRemainsAvailableInVideoWhenZoomIsUnsupported() throws {
        let model = controls()
        model.engineCapabilities = []
        let availability = PlayerMoreMenuAvailability(video: false, quality: true)
        XCTAssertEqual(PlayerMoreMenu.sections(model, availability: availability), [.subtitles, .audio, .video])
        var requested: PlayerMenuDestination?
        var actions = PlayerMoreMenuActions()
        actions.request = { requested = $0 }
        let root = PlayerMoreMenu.make(
            model: model, availability: availability, locale: .init(identifier: "en"), actions: actions
        )
        let video = try submenu("Video", in: root)
        XCTAssertEqual(visible(video).map(\.title), ["Quality"])
        let standalone = PlayerMoreMenu.make(
            model: model, availability: availability, locale: .init(identifier: "en"), section: .video, actions: actions
        )
        XCTAssertTrue(standalone.title.isEmpty)
        XCTAssertEqual(visible(standalone).map(\.title), ["Quality"])
        perform(try XCTUnwrap(visible(video).first as? UIAction))
        XCTAssertEqual(requested, .quality)
        XCTAssertFalse(PlayerMoreMenu.sections(model, availability: .init(video: false)).contains(.video))
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
            let identifier = layout == .consolidated ? "player-playback-options" : "player-video"
            try await waitUntil { self.buttons(in: host.view).contains { $0.accessibilityIdentifier == identifier } }
            let button = try XCTUnwrap(buttons(in: host.view).first { $0.accessibilityIdentifier == identifier })
            button.performPrimaryAction()
            try await waitUntil { button.presentedMenu != nil }
            let menu = try XCTUnwrap(button.presentedMenu)
            let video = try (layout == .consolidated ? submenu("Video", in: menu) : menu)
            XCTAssertEqual(video.title, layout == .consolidated ? "Video" : "")
            XCTAssertEqual(try XCTUnwrap(video.children.first as? UIMenu).title, "Zoom Mode")
            if layout == .separate { XCTAssertEqual(button.accessibilityLabel, "Video") }
            perform(try XCTUnwrap(visible(video).first { $0.title == "Quality" } as? UIAction))
            XCTAssertTrue(state.presentation.isPresented)
            XCTAssertNil(state.sheet)
            try XCTUnwrap(button.contextMenuInteraction).dismissMenu()
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
        let button = try XCTUnwrap(buttons(in: host.view).first { $0.accessibilityIdentifier == "player-video" })
        button.performPrimaryAction()
        try await waitUntil { button.presentedMenu != nil }
        let oldQuality = try XCTUnwrap(visible(try XCTUnwrap(button.presentedMenu)).last as? UIAction)
        let generation = state.presentation.generation
        state.qualityAvailable = false
        try await waitUntil { state.presentation.generation > generation && !state.presentation.isBusy && button.presentedMenu == nil }
        perform(oldQuality)
        XCTAssertNil(state.presentation.destination)
        XCTAssertNil(state.sheet)
        state.qualityAvailable = true
        try await waitUntil { state.presentation.generation > generation + 1 }
        let next = try XCTUnwrap(buttons(in: host.view).first { $0.accessibilityIdentifier == "player-video" })
        next.performPrimaryAction()
        try await waitUntil { next.presentedMenu != nil }
        let oldZoom = try XCTUnwrap(visible(try XCTUnwrap(next.presentedMenu)).first as? UIAction)
        state.controls.videoZoom.settings.mode = .fill
        let zoomGeneration = state.presentation.generation
        state.controls.engineCapabilities.remove(.videoZoom)
        try await waitUntil { state.presentation.generation > zoomGeneration && !state.presentation.isBusy && next.presentedMenu == nil }
        perform(oldZoom)
        XCTAssertEqual(state.controls.videoZoom.settings.mode, .fill)
        XCTAssertTrue(PlayerMoreMenu.sections(state.controls, availability: .init(quality: true)).contains(.video))
    }

    func testLiveVideoUsesTheRealZoomOwnerAndMultiviewIsDeferred() throws {
        let model = controls()
        let zoom = PlayerVideoZoomModel()
        var requested: PlayerMenuDestination?
        var actions = PlayerMoreMenuActions()
        actions.request = { requested = $0 }
        let menu = PlayerMoreMenu.make(
            model: model, availability: .init(videoModel: zoom, multiview: true),
            locale: .init(identifier: "en"), actions: actions
        )
        XCTAssertFalse(visible(menu).contains { $0.title == "Playback Speed" })
        let video = try submenu("Video", in: menu)
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
        let video = try submenu("Video", in: menu)
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
        var layout = PlayerMenuLayout.consolidated
        var qualityAvailable = false
        var timestampsAvailable = false
        init(controls: PlayerControlsModel) { self.controls = controls }
    }

    private struct Fixture: View {
        @Bindable var state: FixtureState

        var body: some View {
            var actions = PlayerMoreMenuActions()
            actions.selectAudio = { state.audioSelections.append($0) }
            return PlayerMoreMenuButton(
                model: state.controls, availability: .init(
                    maximumSpeed: 2, quality: state.qualityAvailable, timestamps: state.timestampsAvailable
                ),
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
