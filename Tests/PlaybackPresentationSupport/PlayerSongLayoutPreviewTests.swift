import AVFoundation
import CoreModels
import CoreUI
@testable import FeaturePlayback
#if os(iOS)
@testable import AppShelliOS
#endif
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class PlayerSongLayoutPreviewTests: XCTestCase {
    func testSongCardUsesSharedArtworkHeight() {
        XCTAssertEqual(PlayerSongCard.artworkSize(for: .tv), PlayerCardMetrics.tv.contentHeight)
        XCTAssertEqual(PlayerSongCard.artworkSize(for: .horizontalWide), PlayerCardMetrics.horizontalWide.contentHeight)
        XCTAssertEqual(PlayerSongCard.artworkSize(for: .verticalNarrow), 112)
        XCTAssertFalse(PlayerControlsModel().songRecognition.isAvailable)
    }

    func testWidePlayerTypographyUsesTouchScaleWithoutChangingTV() {
        XCTAssertEqual(PlayerCardMetrics.tv.titleSize, 34)
        XCTAssertEqual(PlayerCardMetrics.tv.bodySize, 25)
        XCTAssertEqual(PlayerCardMetrics.tv.captionSize, 22)
        #if os(iOS)
        let wide = PlayerCardMetrics.resolved(forWidth: 1376, height: 1032)
        XCTAssertEqual(wide.titleSize, 24)
        XCTAssertEqual(wide.bodySize, 17)
        XCTAssertEqual(wide.captionSize, 14)
        XCTAssertEqual(wide.contentHeight, 208)
        XCTAssertEqual(wide.contentPadding, 16)

        let phone = PlayerCardMetrics.resolved(forWidth: 402, height: 874)
        XCTAssertEqual(phone.titleSize, 17)
        XCTAssertEqual(phone.bodySize, 13)
        XCTAssertEqual(phone.captionSize, 11)

        let middle = PlayerCardMetrics.resolved(forWidth: 900, height: 600)
        XCTAssertEqual(middle.titleSize, 20)
        XCTAssertEqual(middle.bodySize, 14)
        XCTAssertEqual(middle.captionSize, 12)
        #endif
    }

    func testCaptureSeparateCardOverNativePlayback() async throws {
        let path = ProcessInfo.processInfo.environment["PLOZZ_SONG_PREVIEW_DIRECTORY"]
        try XCTSkipIf(path == nil, "Opt-in visual comparison requires a local directory containing film.mp4, still.jpg and album.jpg.")
        let directory = URL(fileURLWithPath: try XCTUnwrap(path), isDirectory: true)
        let server = try SubtitleFixtureServer(directory: directory)
        defer { server.stop() }
        let port = try await server.start()
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        let deadline = ContinuousClock.now + .seconds(10)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let engine = NativeVideoEngine()
        let provider = SongPreviewProvider(origin: origin)
        let player = PlayerViewModel(
            provider: provider, itemID: "song-preview",
            engineFactory: EngineFactory(makeNative: { _ in engine })
        )
        defer {
            engine.stop()
            PlayerScreenshotHook.pendingPanel = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let model = player.controls
        var size = scene.coordinateSpace.bounds.size
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Like the adaptive-panel fixtures, host a wide native viewport
            // without changing the simulator user's iPad windowing preferences.
            size = CGSize(width: max(size.width, size.height), height: min(size.width, size.height))
        }
        #endif
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        let song = SongMatch(
            title: "It's Raining Vengeance", artist: "Michael Giacchino",
            artworkURL: origin.appendingPathComponent("album.jpg"),
            appleMusicURL: URL(string: "https://music.apple.com/")
        )
        do {
            PlayerScreenshotHook.pendingPanel = .info
            let probe = SongArtworkProbe()
            let host = SongPreviewFocusHost(rootView:
                SongPreviewPlayer(engine: engine, player: player)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.themePalette, .dark)
                    .onPreferenceChange(PlayerSongArtworkBounds.self) { probe.bounds = $0 }
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            do {
                await player.load()
                let videoDeadline = ContinuousClock.now + .seconds(20)
                while !engine.hasPresentedVideoFrame, ContinuousClock.now < videoDeadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertTrue(engine.hasPresentedVideoFrame, "The comparison must contain decoded video, not a backdrop mock.")
                engine.play()
                let start = engine.currentTime
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertGreaterThan(engine.currentTime, start)
            }
            await engine.seek(to: 2)
            engine.pause()
            model.controlsVisible = true
            model.infoCard.headline = "Tears of Steel"
            model.infoCard.overview = "In a future Amsterdam, a group of scientists and soldiers gather in the Oude Kerk to recreate a pivotal moment from the past and rescue the world from destructive robots."
            model.infoCard.runtimeLabel = "12m"
            model.infoCard.releaseLabel = "2012"
            model.infoCard.artworkURLs = [origin.appendingPathComponent("still.jpg")]
            model.infoCard.artworkItem = nil
            model.songRecognition.state = .found(song)
            model.songRecognition.isAvailable = true
            try await Task.sleep(for: .seconds(2))
            window.layoutIfNeeded()
            do {
                let artwork = try XCTUnwrap(probe.bounds[.song])
                XCTAssertEqual(artwork.width, artwork.height, accuracy: 1)
                if let infoArtwork = probe.bounds[.info] {
                    XCTAssertEqual(artwork.height, infoArtwork.height, accuracy: 1)
                    XCTAssertEqual(artwork.minY, infoArtwork.minY, accuracy: 1)
                    XCTAssertEqual(artwork.maxY, infoArtwork.maxY, accuracy: 1)
                } else {
                    XCTAssertEqual(artwork.height, 112, accuracy: 1)
                }
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([recognition])
            let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(text.contains("Tears of Steel"), text)
            XCTAssertTrue(text.contains("Raining Vengeance"), text)
            XCTAssertTrue(text.contains("Giacchino"), text)
            let attachment = XCTAttachment(image: image)
            attachment.name = "separate-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
            let infoBounds = probe.bounds[.info]
            #if os(tvOS)
            let artwork = try XCTUnwrap(probe.bounds[.song])
            let point = CGPoint(x: artwork.midX, y: artwork.midY)
            func focusableViews(in view: UIView) -> [UIView] {
                (view.canBecomeFocused ? [view] : []) + view.subviews.flatMap { focusableViews(in: $0) }
            }
            let card = try XCTUnwrap(focusableViews(in: window).first {
                $0.convert($0.bounds, to: window).contains(point)
            }, "The song link must expose a real native focus target.")
            host.target = card
            host.setNeedsFocusUpdate()
            host.updateFocusIfNeeded()
            let focusDeadline = ContinuousClock.now + .seconds(3)
            while UIFocusSystem.focusSystem(for: window)?.focusedItem !== card,
                  ContinuousClock.now < focusDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === card)
            host.target = nil
            #endif
            model.songRecognition.state = .idle
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            XCTAssertEqual(probe.bounds[.info], infoBounds, "Song expiry must not move Info artwork or actions.")
            #if os(tvOS)
            let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            XCTAssertFalse(focused === card, "An expired song must release native focus.")
            #endif
        }
        await player.stop()
    }
}

@MainActor
private final class SongPreviewFocusHost<Content: View>: UIHostingController<Content> {
    var target: (any UIFocusEnvironment)?
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}

@MainActor
private final class SongArtworkProbe {
    var bounds: [PlayerSongArtworkBounds.Role: CGRect] = [:]
}

private struct SongPreviewPlayer: View {
    let engine: NativeVideoEngine
    let player: PlayerViewModel

    var body: some View {
        ZStack {
            VideoSurfaceContainer(engine: engine).ignoresSafeArea()
            #if os(tvOS)
            PlayerControls(
                model: player.controls, player: player, palette: .dark,
                actions: .init(), onExitToSurface: {}
            )
            #else
            PlozziOSPlayerControlsOverlay(
                viewModel: player, keyboardActions: PlozziOSPlayerKeyboardActions(),
                hasVersions: false, versionsPresented: false,
                onShowVersions: {}, onClose: {}
            )
            #endif
        }
        .background(.black)
        .playerPlatformAppearance()
    }
}

private struct SongPreviewProvider: MediaProvider {
    let origin: URL
    let kind = ProviderKind.jellyfin
    let session = UserSession(
        server: .init(id: "preview", name: "Preview", baseURL: URL(string: "https://fixture.invalid")!, provider: .jellyfin),
        userID: "viewer", userName: "Viewer", deviceID: "preview", accessToken: "fixture"
    )
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func item(id: String) async throws -> MediaItem {
        MediaItem(id: id, title: "Tears of Steel", kind: .movie, runtime: 24, allowsTitleBasedMetadataMatching: false)
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        PlaybackRequest(item: try await item(id: itemID), streamURL: origin.appendingPathComponent("film.mp4"))
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { origin.appendingPathComponent("still.jpg") }
}
