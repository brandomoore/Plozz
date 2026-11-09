import AppRuntime
import AVFoundation
import CoreModels
import CoreUI
import CryptoKit
import FeatureMusic
import MediaPlayer
import ProviderJellyfin
import ProviderPlex
import XCTest

@MainActor
final class MusicPlaybackPerformanceTests: XCTestCase {
    func testPerformancePlexMusic() async throws {
        try await measure(provider: .plex)
    }

    func testPerformanceJellyfinMusic() async throws {
        try await measure(provider: .jellyfin)
    }

    private func measure(provider kind: ProviderKind) async throws {
        try PerformanceProbe.requireEnabled()
        guard let address = ProcessInfo.processInfo.environment["PLOZZ_MUSIC_BROKER"],
              let broker = URL(string: address) else {
            throw XCTSkip("An authorized internal music broker is required.")
        }
        guard broker.scheme == "http", broker.host == "127.0.0.1", broker.port != nil,
              broker.user == nil, broker.password == nil, broker.query == nil, broker.fragment == nil else {
            throw ProbeError.configuration
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: broker, timeoutInterval: 10))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProbeError.configuration }
        let configurations = try JSONDecoder().decode([Configuration].self, from: data)
        let configuration = try XCTUnwrap(configurations.first { $0.provider == kind.rawValue })
        let session = UserSession(
            server: .init(id: configuration.serverID, name: "Internal music measurement",
                          baseURL: configuration.baseURL, provider: kind),
            userID: configuration.userID, userName: configuration.username,
            deviceID: "plozz-music-performance", accessToken: configuration.token
        )
        let revision = CredentialRevision()
        let provider: any MusicProvider
        if kind == .plex {
            provider = PlexProvider(session: session, accountID: "music-performance", credentialRevision: revision)
        } else {
            provider = JellyfinProvider(session: session, accountID: "music-performance", credentialRevision: revision)
        }
        let resolver = ManagedAuthenticatedHTTPResolver()
        resolver.configure { _ in
            .init(provider: kind, accountID: "music-performance", credentialRevision: revision,
                  baseURL: configuration.baseURL, token: configuration.token,
                  originProvider: provider as? any AuthenticatedHTTPOriginProviding)
        }
        let libraries = try await provider.musicLibraries()
        let library = try XCTUnwrap(libraries.first)
        let page = try await provider.musicItems(
            in: "", kind: .track, page: .init(limit: 12), libraryIDs: [library.id]
        )
        let tracks = Array(page.tracks.prefix(6))
        XCTAssertEqual(tracks.count, 6)
        guard tracks.count == 6 else { throw ProbeError.configuration }
        let fingerprint = SHA256.hash(data: Data(tracks.map(\.id).joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }.joined()
        print("MUSIC_DATASET provider=\(kind.rawValue) tracks=\(tracks.count) sha256=\(fingerprint)")
        try await PerformanceProbe.measure(self, scenario: "music-\(kind.rawValue)-live") {
            let publisher = SilentPublisher()
            let controller = AudioPlaybackController(nowPlayingPublisher: publisher)
            defer { controller.stop() }
            var urls: [String: URL] = [:]
            var resolutions: [Int] = []
            let stream: AudioPlaybackController.StreamURLResolver = { track in
                let begin = ContinuousClock.now
                do {
                    let request = try await provider.audioPlaybackInfo(for: track.id, queueContext: nil)
                    let url: URL
                    switch request.playbackSource {
                    case .authenticatedHTTP(let locator): url = try await resolver.resolve(locator)
                    case .publicURL(let source): url = source.url
                    default: throw ProbeError.configuration
                    }
                    urls[track.id] = url
                    resolutions.append(Self.milliseconds(since: begin))
                    return .init(url: url, quality: request.quality)
                } catch {
                    if !Task.isCancelled {
                        XCTFail("Music resolution failed: \(type(of: error)), code \((error as NSError).code)")
                    }
                    return nil
                }
            }
            var counters: [String: Int] = [:]
            for (name, index) in [("cold", 0), ("next", 1), ("previous", 0), ("jump", 4), ("newQueue", 2), ("rapid", 5)] {
                let old = publisher.player?.currentItem
                let begin = ContinuousClock.now
                switch name {
                case "cold", "newQueue":
                    controller.play(tracks: tracks, startIndex: index, resolveStreamURL: stream)
                case "next": controller.next()
                case "previous": controller.previous()
                case "rapid":
                    controller.play(at: 3)
                    try await Task.sleep(for: .milliseconds(50))
                    controller.play(at: 0)
                    try await Task.sleep(for: .milliseconds(50))
                    controller.play(at: index)
                default: controller.play(at: index)
                }
                var stopped: Int?
                var reset: Int?
                var ready: Int?
                let deadline = ContinuousClock.now + .seconds(25)
                while ContinuousClock.now < deadline {
                    let player = publisher.player
                    if stopped == nil, old == nil || player?.currentItem !== old || player?.rate == 0 {
                        stopped = Self.milliseconds(since: begin)
                    }
                    if reset == nil, controller.currentTime < 0.1 {
                        reset = Self.milliseconds(since: begin)
                    }
                    if let player, let item = player.currentItem,
                       let url = (item.asset as? AVURLAsset)?.url, url == urls[tracks[index].id],
                       controller.currentTrack?.id == tracks[index].id, item !== old,
                       item.status == .readyToPlay {
                        if ready == nil { ready = Self.milliseconds(since: begin) }
                        if player.timeControlStatus == .playing, player.currentTime().seconds > 0.2,
                           !controller.isBuffering { break }
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard ContinuousClock.now < deadline else {
                    XCTFail("Music \(kind.rawValue) \(name) did not play the requested track within 25 seconds")
                    throw ProbeError.timeout
                }
                let elapsed = Self.milliseconds(since: begin)
                counters["\(name)PlaybackMilliseconds"] = elapsed
                counters["\(name)ReadyMilliseconds"] = ready ?? elapsed
                counters["\(name)OldStopMilliseconds"] = stopped ?? elapsed
                counters["\(name)ResetMilliseconds"] = reset ?? elapsed
                XCTAssertFalse(controller.playbackFailed)
                // Require sustained progress, not merely a ready item or a spinner disappearing.
                let startTime = try XCTUnwrap(publisher.player).currentTime().seconds
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertGreaterThan(try XCTUnwrap(publisher.player).currentTime().seconds, startTime + 0.3)
            }
            counters["completedTransitions"] = 6
            counters["maxResolveMilliseconds"] = resolutions.max() ?? 0
            let encoded = try JSONSerialization.data(withJSONObject: counters, options: [.sortedKeys])
            print("MUSIC_TIMINGS provider=\(kind.rawValue) \(String(decoding: encoded, as: UTF8.self))")
            return counters
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let value = start.duration(to: .now).components
        return Int(value.seconds * 1_000 + value.attoseconds / 1_000_000_000_000_000)
    }

    private struct Configuration: Decodable {
        let provider: String
        let baseURL: URL
        let serverID: String
        let userID: String
        let username: String
        let token: String
    }

    private enum ProbeError: Error { case configuration, timeout }

    private final class SilentPublisher: NowPlayingPublishing {
        private let session = NowPlayingSession()
        weak var player: AVPlayer?
        var isActive: Bool { session.isActive }
        func bind(player: AVPlayer?) {
            self.player = player
            player?.isMuted = true
            session.bind(player: player)
        }
        func activate(
            onCommand: @escaping @MainActor (NowPlayingCommand) -> Void,
            onResigned: @escaping @MainActor () -> Void
        ) { session.activate(onCommand: onCommand, onResigned: onResigned) }
        func publish(_ info: [String: Any], state: MPNowPlayingPlaybackState, transport: NowPlayingTransport) {
            session.publish(info, state: state, transport: transport)
        }
        func invalidate() { session.invalidate() }
    }
}
