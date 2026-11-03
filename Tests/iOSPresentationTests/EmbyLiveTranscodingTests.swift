#if os(iOS)
import AppRuntime
import AVFoundation
import AVKit
import CoreModels
import CoreNetworking
import UIKit
import XCTest
@testable import AppShelliOS
@testable import FeaturePlayback
@testable import ProviderJellyfin

/// Opt-in real-media checks using an explicitly authorized, passwordless test user.
/// Credentials and resolved playback URLs remain in memory, never attachments.
@MainActor
final class EmbyLiveTranscodingTests: XCTestCase {
    func testH264RealMediaPlaybackAndPictureInPicture() async throws {
        try await verify(codec: .preferH264)
    }

    func testHEVCCapableProfileRealMediaPlaybackAndPictureInPicture() async throws {
        try await verify(codec: .preferHEVC)
    }

    private struct Configuration: Decodable {
        let baseURL: URL
        let username: String
        let itemIDs: [String]
    }

    private struct TestUser: Decodable {
        struct UserPolicy: Decodable { let IsAdministrator: Bool }
        let Name: String
        let Policy: UserPolicy
    }

    private func verify(codec: StreamingCodecPreference) async throws {
        guard let input = ProcessInfo.processInfo.environment["PLOZZ_LIVE_EMBY_CONFIGURATION"] else {
            throw XCTSkip("Set PLOZZ_LIVE_EMBY_CONFIGURATION for authorized real-media testing.")
        }
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(input.utf8))
        guard !configuration.itemIDs.isEmpty, configuration.itemIDs.count <= 3,
              let scheme = configuration.baseURL.scheme, ["http", "https"].contains(scheme),
              configuration.baseURL.host != nil,
              configuration.baseURL.user == nil, configuration.baseURL.password == nil,
              configuration.baseURL.query == nil else {
            XCTFail("Provide one to three explicit media IDs and a credential-free server address.")
            return
        }
        let deviceID = "plozz-live-transcoding-\(UUID().uuidString)"
        let client = JellyfinClient(
            baseURL: configuration.baseURL, deviceProfile: .init(deviceID: deviceID), providerKind: .emby
        )
        let auth = try await client.authenticate(username: configuration.username, password: "")
        addTeardownBlock {
            var request = URLRequest(url: configuration.baseURL.appendingPathComponent("Sessions/Logout"))
            request.httpMethod = "POST"
            request.setValue(auth.token, forHTTPHeaderField: "X-Emby-Token")
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204, "Release the test login.")
        }
        var userRequest = URLRequest(
            url: configuration.baseURL.appendingPathComponent("Users").appendingPathComponent(auth.userID),
            timeoutInterval: 30
        )
        userRequest.setValue(auth.token, forHTTPHeaderField: "X-Emby-Token")
        let (userData, userResponse) = try await URLSession.shared.data(for: userRequest)
        guard (userResponse as? HTTPURLResponse)?.statusCode == 200 else {
            XCTFail("Could not verify the authenticated test identity.")
            return
        }
        let user = try JSONDecoder().decode(TestUser.self, from: userData)
        guard !user.Policy.IsAdministrator, user.Name == configuration.username else {
            XCTFail("Live playback requires the configured non-administrator test identity.")
            return
        }
        let serverID = try XCTUnwrap(auth.serverID)
        let provider = JellyfinProvider(
            session: .init(
                server: .init(id: serverID, name: "Internal verification", baseURL: configuration.baseURL, provider: .emby),
                userID: auth.userID, userName: auth.userName, deviceID: deviceID, accessToken: auth.token
            ),
            hybridEngineEnabled: true, playbackRequests: .init()
        )
        let resolver = ManagedAuthenticatedHTTPResolver()
        resolver.configure { _ in
            .init(
                provider: .emby, accountID: provider.accountID, credentialRevision: provider.credentialRevision,
                baseURL: configuration.baseURL, token: auth.token, originProvider: provider
            )
        }
        for (index, itemID) in configuration.itemIDs.enumerated() {
            let item = try await provider.playbackItem(id: itemID)
            let options = StreamingPlaybackOptions(quality: .hd720, codec: codec, forceTranscoding: true)
            let request: PlaybackRequest
            if codec == .preferHEVC {
                // Simulators report no hardware HEVC. Exercise the real protocol
                // with a capable-device profile without changing production detection.
                let capableClient = JellyfinClient(
                    baseURL: configuration.baseURL, deviceProfile: .init(deviceID: deviceID),
                    providerKind: .emby, token: auth.token,
                    capabilityProfile: .appleTV(capabilities: .init(supportsHEVC: true), hybridEngineEnabled: true)
                )
                let info = try await capableClient.playbackInfo(
                    userID: auth.userID, itemID: itemID, mediaSourceID: item.versions.first?.id,
                    mode: .transcode, streaming: options
                )
                do {
                    XCTAssertNil(info.ErrorCode)
                    var source = try XCTUnwrap(info.MediaSources.first)
                    source.TranscodingUrl = try source.boundedTranscodingURL(
                        options, supportsHEVC: true, forceVideoTranscode: true
                    )
                    try source.requestSDRForH264Transcode(provider: .emby, forceVideoTranscode: true)
                    let locator = try provider.authenticatedPlaybackLocator(
                        itemID: itemID, source: source, playSessionID: info.PlaySessionId, didRemux: false
                    )
                    var converted = PlaybackRequest(
                        item: item, playbackSource: .authenticatedHTTP(locator),
                        playSessionID: info.PlaySessionId, deliveryMode: .transcode, sourceProvider: .emby
                    )
                    converted.streamingOptions = options
                    converted.streamingSessionID = info.PlaySessionId
                    converted.negotiatedStreamingVideoCodec = .hevc
                    request = converted
                } catch {
                    if let id = info.PlaySessionId { await provider.releaseStreamingEncoding(id) }
                    throw error
                }
            } else {
                request = try await provider.playbackInfo(
                    for: itemID, mediaSourceID: item.versions.first?.id,
                    forceTranscode: true, streaming: options
                )
            }
            do {
                XCTAssertTrue(request.isTranscoding)
                XCTAssertEqual(request.negotiatedStreamingVideoCodec, codec == .preferHEVC ? .hevc : .h264)
                try await play(
                    request, resolver: resolver, expectedCodec: codec == .preferHEVC ? .hevc : .h264, caseIndex: index
                )
                await provider.releaseStreamingSession(request)
            } catch {
                await provider.releaseStreamingSession(request)
                throw error
            }
        }
    }

    private func play(
        _ request: PlaybackRequest, resolver: ManagedAuthenticatedHTTPResolver,
        expectedCodec: DirectPlayVideoCodec, caseIndex: Int
    ) async throws {
        try await waitUntil(seconds: 10) {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let engine = NativeVideoEngine(authenticatedHTTPResolver: resolver, startsMuted: true)
        let pip = PlozziOSPictureInPictureController()
        defer {
            pip.detach()
            engine.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let surface = engine.makeVideoOutputView()
        surface.frame = host.view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(surface)
        pip.attach(engine: engine)
        let started = ContinuousClock.now
        await engine.load(request: request, startPosition: 0)
        try await waitUntil(seconds: 60) { engine.hasPresentedVideoFrame }
        let firstFrameTime = started.duration(to: .now)
        let player = try XCTUnwrap(engine.underlyingPlayer)
        let item = try XCTUnwrap(player.currentItem)
        try await waitUntil(seconds: 10) { engine.streamingOutputVideoCodec != nil }
        XCTAssertEqual(engine.streamingOutputVideoCodec, expectedCodec, "Verify decoded output, not URL flags.")
        let dimensions = item.presentationSize
        // A decoded first frame can precede AVPlayer's cold-encoder buffering.
        // Measure sustained playback from playing, not from readiness.
        try await waitUntil(seconds: 60) { player.timeControlStatus == .playing }
        let playingTime = started.duration(to: .now)
        let initialPosition = player.currentTime().seconds
        try await Task.sleep(for: .seconds(12))
        let progress = player.currentTime().seconds - initialPosition
        let evidence = "case=\(caseIndex) codec=\(expectedCodec) firstFrame=\(firstFrameTime) playing=\(playingTime) "
            + "size=\(dimensions.width)x\(dimensions.height) range=\(String(describing: engine.streamingOutputDynamicRange)) "
            + "progress=\(progress) systemPiPSupported=\(AVPictureInPictureController.isPictureInPictureSupported())"
        XCTContext.runActivity(named: "Real Emby playback measurement") { activity in
            let attachment = XCTAttachment(string: evidence)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        XCTAssertGreaterThan(progress, 10, "The real rendition must sustain playback beyond startup.")
        XCTAssertNil(item.error, "Playback must not silently fail after the first frame.")
        let layer = try XCTUnwrap(engine.pictureInPicturePlayerLayer())
        XCTAssertTrue(layer.player === player)
        XCTAssertTrue(layer.isReadyForDisplay)
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }
        try await waitUntil(seconds: 10) { pip.isAvailable }
        pip.toggle()
        try await waitUntil(seconds: 10) { pip.isActive }
        XCTAssertTrue(engine.continuesPlaybackInBackground)
        pip.toggle()
        try await waitUntil(seconds: 10) { !pip.continuesPlayback }
    }

    private func waitUntil(seconds: Int, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard condition() else {
            XCTFail("Live playback did not reach the expected state within \(seconds) seconds.")
            throw LivePlaybackTimeout()
        }
    }

    private struct LivePlaybackTimeout: Error {}
}
#endif
