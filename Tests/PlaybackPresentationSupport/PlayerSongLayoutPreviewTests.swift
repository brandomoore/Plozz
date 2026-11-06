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
    func testNormalPlaybackDoesNotSelectAnUnapprovedLayout() {
        XCTAssertEqual(EnvironmentValues().playerSongLayoutPreview, .original)
    }

    func testCaptureBothLayoutsOverNativePlayback() async throws {
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
        for layout in [PlayerSongLayoutPreview.integrated, .separate] {
            PlayerScreenshotHook.pendingPanel = .info
            let probe = SongArtworkProbe()
            let host = UIHostingController(rootView:
                SongPreviewPlayer(engine: engine, player: player)
                    .environment(\.playerSongLayoutPreview, layout)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.themePalette, .dark)
                    .onPreferenceChange(PlayerSongPreviewArtworkBounds.self) { probe.bounds = $0 }
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            if layout == .integrated {
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
            model.songID = .found(song)
            try await Task.sleep(for: .seconds(2))
            window.layoutIfNeeded()
            if layout == .separate {
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
            attachment.name = "\(layout.rawValue)-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        await player.stop()
    }
}

@MainActor
private final class SongArtworkProbe {
    var bounds: [PlayerSongPreviewArtworkBounds.Role: CGRect] = [:]
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
