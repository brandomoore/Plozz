import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import XCTest

@MainActor
final class DiscPlayerHandoffHostedTests: XCTestCase {
    func testProductionDiscMenuReturnsFocusToVideoAndWorkingControls() async throws {
        let scene = try await activeScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let state = DiscMenuPlaybackState()
        state.isActive = true
        state.isOpening = false
        state.isMenuVisible = true
        state.image = UIGraphicsImageRenderer(size: CGSize(width: 1920, height: 1080)).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        }
        let engine = DiscHandoffEngine()
        engine.discMenu = state
        var settings = PlaybackSettings.default
        settings.discPlayback = .openMenu
        let model = PlayerViewModel(
            provider: DiscHandoffProvider(), itemID: "disc",
            playbackSettings: settings,
            engineFactory: .init(makeNative: { _ in engine }, makePlozzigen: { engine })
        )
        window.rootViewController = UIHostingController(rootView: PlayerView(viewModel: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(model.isDiscMenuPlayback)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        state.isOpening = true
        state.isMenuVisible = false
        state.image = nil
        try await Task.sleep(for: .milliseconds(200))
        state.isOpening = false
        state.hasPresentedVideoFrame = true
        XCTAssertFalse(state.presentsMenu)
        try await Task.sleep(for: .milliseconds(700))
        let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Disc to feature controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(focused is PlayerInputView,
                      "The disc toolbar action must not strand input outside transport: \(String(describing: focused))")
        let input = try XCTUnwrap(descendants(window.rootViewController).compactMap {
            $0 as? PlayerInputViewController
        }.first)
        input.perform(NSSelectorFromString("handleDown"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.controls.controlBarVisible)
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        await model.stop()
    }

    func testNewVideoHostClearsRetiredControlBarFocusAndHidesIdleControls() async throws {
        let scene = try await activeScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let controls = PlayerControlsModel()
        controls.title = "Disc feature"
        controls.controlsVisible = true
        let engine = DiscHandoffEngine()
        let first = controller(engine: engine, controls: controls)
        window.rootViewController = first
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(300))
        first.perform(NSSelectorFromString("handleDown"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controls.controlBarVisible)

        // A disc menu temporarily replaces the ordinary video/controls host.
        window.rootViewController = UIHostingController(rootView: Color.black)
        try await Task.sleep(for: .milliseconds(100))
        let next = controller(engine: engine, controls: controls)
        window.rootViewController = next
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(controls.controlBarVisible, "A new input owner cannot inherit retired focus.")
        XCTAssertFalse(controls.isPanelOpen)
        XCTAssertFalse(controls.controlBar.infoCardOpen)
        XCTAssertFalse(controls.controlBar.episodeBrowserOpen)
        let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: next.view)?.focusedItem as? UIView)
        XCTAssertTrue(focused is PlayerInputView, "Video must own the first remote press.")
        XCTAssertTrue(focused.isDescendant(of: next.view))
        try await Task.sleep(for: .seconds(5))
        XCTAssertFalse(controls.controlsVisible, "Already-visible controls must arm their idle timer on handoff.")
        next.perform(NSSelectorFromString("handleDown"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controls.controlBarVisible, "The first Down must enter working controls.")
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: next.view)?.focusedItem)
    }

    private func controller(engine: DiscHandoffEngine, controls: PlayerControlsModel) -> PlayerInputViewController {
        let result = PlayerInputViewController(engine: engine, model: controls, actions: .init())
        result.loadViewIfNeeded()
        result.attachVideoSurface()
        result.attachControls(themePalette: ThemePaletteBox(
            makeControls: { model, actions, exit in
                AnyView(PlayerControls(model: model, palette: .dark, actions: actions, onExitToSurface: exit))
            },
            makeSkipButton: { _, _, _, _ in AnyView(EmptyView()) },
            makeUpNextCard: { _, _, _, _ in AnyView(EmptyView()) }
        ))
        return result
    }

    private func activeScene() async throws -> UIWindowScene {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }

    private func descendants(_ controller: UIViewController?) -> [UIViewController] {
        guard let controller else { return [] }
        return [controller] + controller.children.flatMap { descendants($0) }
    }
}

@MainActor
private final class DiscHandoffEngine: VideoEngine {
    var discMenu: DiscMenuPlaybackState?
    let displayName = "Disc handoff fixture"
    let status: VideoEngineStatus = .ready
    var isPaused = false
    let hasPresentedVideoFrame = true
    private let started = Date()
    var currentTime: TimeInterval { Date().timeIntervalSince(started) }
    let duration: TimeInterval = 120
    var furthestObservedPosition: TimeInterval { currentTime }
    let audioTracks: [MediaTrack] = []
    let subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    private let surface = UIView()
    func load(request: PlaybackRequest, startPosition: TimeInterval) async {}
    func play() { isPaused = false }
    func pause() { isPaused = true }
    func seek(to seconds: TimeInterval) async {}
    func stop() {}
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView { surface }
}

private actor DiscHandoffProvider: MediaProvider {
    nonisolated let kind = ProviderKind.jellyfin
    nonisolated let session = UserSession(
        server: .init(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                      provider: .jellyfin),
        userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: "fixture"
    )
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        .init(id: "disc", title: "Disc fixture", kind: .movie, runtime: 120)
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        let anchor = try NetworkFileLocator(
            accountID: "fixture", sourceID: "fixture", credentialRevision: CredentialRevision(),
            relativePath: "Movie/BDMV/index.bdmv",
            representation: .init(
                size: 40, identity: .init(kind: .strongETag, value: "\"index\""), consistency: .changeDetecting
            ), formatHint: .init(container: "bdmv")
        )
        var request = PlaybackRequest(
            item: try await item(id: itemID), streamURL: URL(fileURLWithPath: "/fixture/BDMV/index.bdmv")
        )
        request.playbackSource = .networkDisc(try NetworkDiscLocator(
            anchor: anchor, files: [.init(path: "BDMV/index.bdmv", locator: anchor)]
        ))
        return request
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
