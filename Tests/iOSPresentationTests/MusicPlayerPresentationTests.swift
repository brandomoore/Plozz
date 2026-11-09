#if os(iOS)
import AVFoundation
import CoreModels
import CoreNetworking
@testable import FeatureMusic
import ProviderPlex
import SwiftUI
import UIKit
import XCTest

@MainActor
final class MusicPlayerPresentationTests: XCTestCase {
    func testMobileNavigationOnlyIncludesMusicWhenEnabled() {
        let music = NavigationLibraryLayout.musicKey
        XCTAssertFalse(NavigationDestinationDefaults.iOS(visibleLibraries: []).contains(music))
        let enabled = NavigationDestinationDefaults.iOS(visibleLibraries: [], hasMusic: true)
        XCTAssertTrue(enabled.contains(music))
        XCTAssertFalse(NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: enabled).contains(music))
        XCTAssertFalse(AppReleaseChannel.production.isBeta)
        XCTAssertTrue(AppReleaseChannel.testflight.isBeta)
        XCTAssertTrue(AppReleaseChannel.debug.isBeta)
    }

    func testFeedbackRollbackSerializationAndScopeInvalidation() async throws {
        let http = MusicFeedbackHTTP()
        let session = MusicPlayerSession()
        defer { session.stop() }
        let user = UserSession(
            server: MediaServer(id: "server", name: "Music", baseURL: URL(string: "https://music.invalid")!, provider: .plex),
            userID: "user", userName: "Listener", deviceID: "device", accessToken: "fixture-token"
        )
        let provider = PlexProvider(session: user, http: http)
        let account = ResolvedAccount(account: Account(id: "account", from: user), provider: provider)
        session.configure(accounts: [account], authorizationID: "first", isAuthorized: { true })
        let track = FeatureMusic.Track(source: CoreModels.MusicTrack(id: "song", title: "Song", sourceAccountID: "account"))
        session.playback.feedback[track.id] = .rating(2)
        await http.setFailure(true)
        let failed = await session.environment.setRating(4, track: track)
        XCTAssertFalse(failed)
        XCTAssertEqual(session.playback.feedback[track.id], .rating(2))
        XCTAssertNotNil(session.toasts.message)
        await http.setFailure(false)
        let first = Task { await session.environment.setRating(3, track: track) }
        let second = Task { await session.environment.setRating(4.5, track: track) }
        let firstSaved = await first.value
        let secondSaved = await second.value
        XCTAssertTrue(firstSaved)
        XCTAssertTrue(secondSaved)
        XCTAssertEqual(session.playback.feedback[track.id], .rating(4.5))
        let writes = await http.ratings
        XCTAssertEqual(writes, ["8.0", "6.0", "9.0"])
        session.configure(accounts: [], authorizationID: "second", isAuthorized: { false })
        XCTAssertTrue(session.playback.feedback.isEmpty)
        let rejected = await session.environment.setRating(5, track: track)
        XCTAssertFalse(rejected)
        let after = await http.ratings
        XCTAssertEqual(after, writes)
    }

    func testAlbumAndArtistNavigationPreservesAccountIdentity() {
        let source = CoreModels.MusicTrack(
            id: "song", title: "Song", albumTitle: "Album", albumID: "album",
            artistName: "Artist", artistID: "artist", sourceAccountID: "account"
        )
        XCTAssertTrue(TrackNavigationButtons.canNavigate(.init(source: source), surface: .player))
        var noAccount = source
        noAccount.sourceAccountID = nil
        XCTAssertFalse(TrackNavigationButtons.canNavigate(.init(source: noAccount), surface: .player))
        let navigation = MusicNavigation()
        navigation.open(.album(MusicAlbum(id: "album", title: "Album", sourceAccountID: "account")))
        XCTAssertEqual(navigation.path, [.album(MusicAlbum(id: "album", title: "Album", sourceAccountID: "account"))])
        navigation.reset()
        XCTAssertTrue(navigation.path.isEmpty)
    }

    func testFeedbackCompletionCannotRepopulateAnInvalidatedProfile() async {
        let http = MusicFeedbackHTTP()
        await http.holdNextWrite()
        let session = MusicPlayerSession()
        defer { session.stop() }
        let user = UserSession(
            server: MediaServer(id: "server", name: "Music", baseURL: URL(string: "https://music.invalid")!, provider: .plex),
            userID: "user", userName: "Listener", deviceID: "device", accessToken: "fixture-token"
        )
        let provider = PlexProvider(session: user, http: http)
        session.configure(
            accounts: [ResolvedAccount(account: Account(id: "account", from: user), provider: provider)],
            authorizationID: "first", isAuthorized: { true }
        )
        let track = FeatureMusic.Track(source: CoreModels.MusicTrack(id: "song", title: "Song", sourceAccountID: "account"))
        let write = Task { await session.environment.setRating(4, track: track) }
        await http.waitUntilHeld()
        session.configure(accounts: [], authorizationID: "second", isAuthorized: { false })
        await http.releaseWrite()
        let saved = await write.value
        XCTAssertFalse(saved)
        XCTAssertTrue(session.playback.feedback.isEmpty)
        XCTAssertNil(session.toasts.message)
    }

    func testMountedPlayerExpandsCollapsesAndChangesTracks() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let player = MusicPlayerSession()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer {
            player.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: file)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441_000))
        buffer.frameLength = 441_000
        let samples = try XCTUnwrap(buffer.floatChannelData)
        samples[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let audio = try AVAudioFile(forWriting: file, settings: format.settings)
            try audio.write(from: buffer)
        }
        player.controller.play(
            tracks: [
                CoreModels.MusicTrack(id: "one", title: "The First Song", albumTitle: "Evening Light", artistName: "Test Artist", duration: 10),
                CoreModels.MusicTrack(id: "two", title: "Another Song", albumTitle: "Evening Light", artistName: "Test Artist", duration: 10),
                CoreModels.MusicTrack(id: "unavailable", title: "Unavailable", duration: 10)
            ],
            startIndex: 0,
            resolveStreamURL: { track in
                if track.id == "unavailable" {
                    return nil
                }
                return .init(url: file)
            }
        )
        let host = UIHostingController(rootView:
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                MusicPlayerOverlay(session: player, hasBottomBar: false)
            }
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))
        attach(window, name: "Music mini player")
        player.isPresented = true
        try await Task.sleep(for: .milliseconds(900))
        attach(window, name: "Music expanded player")
        XCTAssertTrue(player.isPresented)
        player.controller.pause()
        await player.controller.seek(to: 2)
        XCTAssertEqual(player.controller.currentTime, 2, accuracy: 0.1)
        XCTAssertFalse(player.controller.isPlaying)
        player.controller.resume()
        let generation = player.controller.transportGeneration
        player.playback.next()
        XCTAssertEqual(player.controller.currentTrack?.id, "two")
        XCTAssertGreaterThan(player.controller.transportGeneration, generation)
        player.isPresented = false
        try await Task.sleep(for: .milliseconds(900))
        attach(window, name: "Music collapsed after skip")
        player.isPresented = true
        player.isPresented = false
        player.isPresented = true
        try await Task.sleep(for: .milliseconds(900))
        attach(window, name: "Music reopened player")
        XCTAssertTrue(player.isPresented)
        XCTAssertGreaterThan(host.view.bounds.width, 0)
        player.controller.next()
        let deadline = Date().addingTimeInterval(2)
        while !player.controller.playbackFailed && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(player.controller.playbackFailed)
        XCTAssertFalse(player.controller.isPlaying)
        XCTAssertFalse(player.controller.isBuffering)
    }

    private func attach(_ window: UIWindow, name: String) {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private actor MusicFeedbackHTTP: HTTPClient {
    var ratings: [String] = []
    private var fail = false
    private var shouldHold = false
    private var heldWrite: CheckedContinuation<Void, Never>?
    private var holdObserver: CheckedContinuation<Void, Never>?
    func setFailure(_ value: Bool) { fail = value }
    func holdNextWrite() { shouldHold = true }
    func waitUntilHeld() async {
        if heldWrite != nil { return }
        await withCheckedContinuation { holdObserver = $0 }
    }
    func releaseWrite() {
        heldWrite?.resume()
        heldWrite = nil
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        guard endpoint.path == "/:/rate" else { throw AppError.notFound }
        ratings.append(endpoint.queryItems.first { $0.name == "rating" }?.value ?? "")
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation {
                heldWrite = $0
                holdObserver?.resume()
                holdObserver = nil
            }
        }
        if fail { throw AppError.serverUnreachable }
        return (Data(), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
#endif
