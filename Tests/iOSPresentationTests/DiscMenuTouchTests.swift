import UIKit
import XCTest
import SwiftUI
import CoreModels
@testable import FeaturePlayback

@MainActor
final class DiscMenuTouchTests: XCTestCase {
    func testOneSpinnerSurvivesResolutionAndBackgroundVideoUntilMenuAppears() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let presentation = DiscLoadingPresentation()
        window.rootViewController = UIHostingController(rootView: DiscLoadingTestView(presentation: presentation))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func indicators(_ view: UIView) -> [UIActivityIndicatorView] {
            (view as? UIActivityIndicatorView).map { [$0] } ?? view.subviews.flatMap(indicators)
        }
        try await Task.sleep(for: .milliseconds(150))
        let first = try XCTUnwrap(indicators(window).first)
        XCTAssertTrue(first.isAnimating)
        let engine = DiscLoadingEngine()
        var settings = PlaybackSettings.default
        settings.discPlayback = .openMenu
        let model = PlayerViewModel(
            provider: DiscLoadingProvider(), itemID: "disc", playbackSettings: settings,
            engineFactory: .init(makeNative: { _ in engine }, makePlozzigen: { engine })
        )
        presentation.model = model
        await model.load()
        XCTAssertTrue(model.isDiscMenuPlayback)
        let state = try XCTUnwrap(engine.discMenu)
        for opening in [false, true, false] {
            state.isOpening = opening
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(model.showBringUpSpinner, "Background video is not an interactive menu")
            XCTAssertEqual(indicators(window).count, 1)
            XCTAssertTrue(indicators(window).first === first, "Do not replace/restart the loading indicator")
            XCTAssertTrue(first.isAnimating)
        }
        state.isMenuVisible = true
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.showBringUpSpinner)
        XCTAssertTrue(indicators(window).isEmpty)
        state.isMenuVisible = false
        state.isOpening = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.showBringUpSpinner)
        state.failure = "Fixture failure"
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.showBringUpSpinner)
        XCTAssertTrue(indicators(window).isEmpty)
        await model.stop()
    }

    func testLoadingEndsAtInteractiveMenuRatherThanBackgroundVideo() {
        let state = DiscMenuPlaybackState()
        XCTAssertTrue(state.showsLoadingIndicator)
        state.isOpening = false
        XCTAssertTrue(state.showsLoadingIndicator)
        state.isMenuVisible = true
        XCTAssertFalse(state.showsLoadingIndicator)
        state.isOpening = true
        XCTAssertFalse(state.showsLoadingIndicator, "Keep a usable language prompt interactive")
        state.isMenuVisible = false
        XCTAssertTrue(state.showsLoadingIndicator)
        state.isMenuRequestPending = false
        state.isOpening = false
        XCTAssertTrue(state.showsLoadingIndicator, "A title change alone does not finish menu presentation")
        state.isMenuVisible = true
        state.isMenuVisible = false
        state.isOpening = false
        XCTAssertFalse(state.showsLoadingIndicator, "An explicit feature choice can play normally")
        state.reset()
        XCTAssertTrue(state.showsLoadingIndicator)
        state.failure = "Fixture failure"
        XCTAssertFalse(state.showsLoadingIndicator)
    }

    func testPendingMenuRequestKeepsTransportHiddenAcrossStartupSceneGaps() {
        let state = DiscMenuPlaybackState()
        state.isActive = true
        state.isOpening = false
        XCTAssertTrue(state.presentsMenu)
        state.isMenuVisible = true
        state.isMenuRequestPending = false
        XCTAssertTrue(state.presentsMenu)
        state.isMenuVisible = false
        XCTAssertFalse(state.presentsMenu)
        state.isMenuRequestPending = true
        XCTAssertTrue(state.presentsMenu)
        state.reset()
        XCTAssertTrue(state.isMenuRequestPending)
    }

    @MainActor @Observable
    final class DiscLoadingPresentation {
        var model: PlayerViewModel?
    }

    private struct DiscLoadingTestView: View {
        let presentation: DiscLoadingPresentation
        var body: some View {
            PlayerLoadingOverlay(viewModel: presentation.model, discMenuRequested: true)
        }
    }

    @MainActor
    private final class DiscLoadingEngine: VideoEngine {
        let displayName = "Disc loading fixture"
        var discMenu: DiscMenuPlaybackState? = DiscMenuPlaybackState()
        let status: VideoEngineStatus = .ready
        let isPaused = false
        private(set) var hasPresentedVideoFrame = false
        let currentTime: TimeInterval = 1
        let duration: TimeInterval = 120
        let furthestObservedPosition: TimeInterval = 1
        let audioTracks: [MediaTrack] = []
        let subtitleTracks: [MediaTrack] = []
        var onProgress: (@MainActor () -> Void)?
        var onFailure: (@MainActor (AppError) -> Void)?
        var onEnded: (@MainActor () -> Void)?
        var onTracksChanged: (@MainActor () -> Void)?
        var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
        var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
        var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
        func load(request: PlaybackRequest, startPosition: TimeInterval) async { hasPresentedVideoFrame = true }
        func play() {}
        func pause() {}
        func seek(to seconds: TimeInterval) async {}
        func stop() {}
        func selectAudioTrack(_ track: MediaTrack?) {}
        func selectSubtitleTrack(_ track: MediaTrack?) {}
        func makeVideoOutputView() -> UIView { UIView() }
    }

    private actor DiscLoadingProvider: MediaProvider {
        nonisolated let kind = ProviderKind.jellyfin
        nonisolated let session = UserSession(
            server: .init(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                          provider: .jellyfin),
            userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: "fixture"
        )
        func libraries() async throws -> [MediaLibrary] { [] }
        func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
        func latest(limit: Int) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem { .init(id: "disc", title: "Disc fixture", kind: .movie) }
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

    func testLandscapeAndPortraitTapsUsePixelsAndIgnoreLetterboxing() {
        let state = menu()
        var points: [CGPoint] = []
        state.sendPointerClick = { points.append(CGPoint(x: Int($0), y: Int($1))) }
        let landscape = CGRect(x: 0, y: 0, width: 1024, height: 768)
        state.activate(at: CGPoint(x: 512, y: 384), in: landscape)
        state.activate(at: CGPoint(x: 512, y: 30), in: landscape)
        XCTAssertEqual(points, [CGPoint(x: 960, y: 540)])
        let portrait = CGRect(x: 0, y: 0, width: 768, height: 1024)
        state.activate(at: CGPoint(x: 192, y: 404), in: portrait)
        state.activate(at: CGPoint(x: 192, y: 1000), in: portrait)
        XCTAssertEqual(points.last, CGPoint(x: 480, y: 270))
        XCTAssertEqual(points.count, 2)
    }

    func testPillarboxingAndOffsetViewportMapWithoutClampingOutsideTaps() {
        let state = menu()
        var points: [CGPoint] = []
        state.sendPointerClick = { points.append(CGPoint(x: Int($0), y: Int($1))) }
        let bounds = CGRect(x: 20, y: 40, width: 2400, height: 1080)
        state.activate(at: CGPoint(x: 260, y: 40), in: bounds)
        state.activate(at: CGPoint(x: 2179, y: 1119), in: bounds)
        state.activate(at: CGPoint(x: 259, y: 40), in: bounds)
        state.activate(at: CGPoint(x: 2180, y: 1120), in: bounds)
        XCTAssertEqual(points, [.zero, CGPoint(x: 1919, y: 1079)])
    }

    func testUnavailableAndRetiredMenusCannotReceivePointerClicks() {
        let state = menu()
        var count = 0
        state.sendPointerClick = { _, _ in count += 1 }
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        state.isMenuVisible = false
        state.activate(at: CGPoint(x: 100, y: 100), in: bounds)
        state.isMenuVisible = true
        state.failure = "Fixture failure"
        state.activate(at: CGPoint(x: 100, y: 100), in: bounds)
        state.failure = nil
        state.activate(at: CGPoint(x: CGFloat.nan, y: 100), in: bounds)
        state.activate(at: .zero, in: .zero)
        state.reset()
        state.sendPointerClick(100, 100)
        XCTAssertEqual(count, 0)
    }

    private func menu() -> DiscMenuPlaybackState {
        let state = DiscMenuPlaybackState()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        state.image = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 540), format: format).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
        }
        state.isActive = true
        state.isMenuVisible = true
        return state
    }
}
