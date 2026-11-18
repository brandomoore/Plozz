#if os(iOS)
import AppRuntime
import AVFoundation
import CoreModels
import EnginePlozzigen
import FeatureAuthCore
import ProviderShare
import ProviderSubsonic
import UIKit
import XCTest

@MainActor
final class LiveProviderSmokeTests: XCTestCase {
    func testSMBBrowseDetailAndPlayback() async throws { try await share("smb") }
    func testSFTPBrowseDetailAndPlayback() async throws { try await share("sftp") }
    func testFTPBrowseDetailAndPlayback() async throws { try await share("ftp") }
    func testNFSBrowseDetailAndPlayback() async throws { try await share("nfs") }
    func testWebDAVBrowseDetailAndPlayback() async throws { try await share("webdav") }

    func testSubsonicSignInBrowseAndPlayback() async throws {
        let config = try await configuration("subsonic")
        do {
            let session = try await SubsonicProvider.signIn(
                address: try XCTUnwrap(config.baseURL).absoluteString,
                username: try XCTUnwrap(config.username), password: try XCTUnwrap(config.password),
                usesAPIKey: false, deviceID: UUID().uuidString
            )
            let provider = try SubsonicProvider(context: .init(
                session: session, accountID: "live-subsonic", credentialRevision: .init()
            ))
            let libraries = try await provider.musicLibraries()
            XCTAssertFalse(libraries.isEmpty)
            let albums = try await provider.musicItems(in: "", kind: .album, page: .init(startIndex: 0, limit: 3))
            let album = try XCTUnwrap(albums.albums.first)
            let tracks = try await provider.tracks(in: album.id)
            let track = try XCTUnwrap(tracks.first)
            let request = try await provider.audioPlaybackInfo(for: track.id, queueContext: nil)
            guard case .authenticatedHTTP(let locator) = request.playbackSource else { throw SmokeFailure.source }
            let player = AVPlayer(url: try await provider.resolveHTTPResource(locator))
            player.isMuted = true
            defer { player.pause(); player.replaceCurrentItem(with: nil) }
            player.play()
            let deadline = ContinuousClock.now + .seconds(30)
            while player.timeControlStatus != .playing, ContinuousClock.now < deadline {
                if player.currentItem?.status == .failed { throw SmokeFailure.playback }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(player.timeControlStatus, .playing)
            let start = player.currentTime().seconds
            try await Task.sleep(for: .seconds(5))
            XCTAssertGreaterThan(player.currentTime().seconds - start, 3)
            player.pause()
            let paused = player.currentTime().seconds
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(player.currentTime().seconds, paused, accuracy: 0.25)
        } catch {
            XCTFail("Live Subsonic smoke failed: \(type(of: error))")
        }
    }

    private func share(_ kind: String) async throws {
        let config = try await configuration(kind)
        let secure = InMemorySecureStore()
        let store = AccountStore(
            secureStore: secure, mediaCredentialVault: MediaCredentialVault(secureStore: secure),
            credentialJournal: try CredentialMutationJournal(store: .init(secureStore: InMemorySecureStore()))
        )
        let service = MediaShareAccountConfigurationService(accountStore: store)
        let runtime = DefaultMediaShareRuntime.make(accountStore: store)
        var prepared: PreparedMediaShareAccount?
        do {
            let library = MediaShareLibraryConfiguration(name: "Internal smoke", contentType: .personalVideos)
            let value: PreparedMediaShareAccount
            switch kind {
            case "smb":
                value = try service.prepareSMB(
                    host: XCTUnwrap(config.host), port: config.port, share: XCTUnwrap(config.share),
                    username: XCTUnwrap(config.username), password: XCTUnwrap(config.password),
                    displayName: "Internal smoke", subpath: XCTUnwrap(config.path), libraryConfiguration: library
                )
            case "sftp":
                value = try service.prepareSFTP(
                    host: XCTUnwrap(config.host), port: config.port, path: XCTUnwrap(config.path),
                    username: XCTUnwrap(config.username), password: XCTUnwrap(config.password),
                    hostKeyPin: SHA256Fingerprint(bytes: XCTUnwrap(config.hostKeySHA256)),
                    displayName: "Internal smoke", libraryConfiguration: library
                )
            case "nfs":
                value = try service.prepareNFS(
                    host: XCTUnwrap(config.host), port: config.port, exportPath: XCTUnwrap(config.exportPath),
                    subpath: XCTUnwrap(config.path), displayName: "Internal smoke", libraryConfiguration: library
                )
            case "ftp":
                value = try service.prepareFTP(
                    baseURL: XCTUnwrap(config.baseURL),
                    auth: .password(username: XCTUnwrap(config.username), password: XCTUnwrap(config.password)),
                    displayName: "Internal smoke", libraryConfiguration: library
                )
            case "webdav":
                value = try service.prepareWebDAV(
                    baseURL: XCTUnwrap(config.baseURL),
                    auth: .password(username: XCTUnwrap(config.username), password: XCTUnwrap(config.password)),
                    trustPin: nil, displayName: "Internal smoke", libraryConfiguration: library
                )
            default: throw SmokeFailure.configuration
            }
            prepared = value
            try service.persist(value)
            let account = try XCTUnwrap(store.loadAccounts().first)
            let registry = ManagedProviderRegistry.make()
            runtime.registerProvider(into: registry, durableLocalStateStore: nil)
            let provider = try registry.provider(for: .init(
                session: value.session, accountID: account.id, credentialRevision: account.credentialRevision,
                localMediaContext: .init(accountID: account.id, profileID: UUID().uuidString, profileNamespace: nil)
            ))
            let browser = try XCTUnwrap(provider as? ShareProvider)
            let libraries = try await provider.libraries()
            XCTAssertTrue(libraries.contains { $0.id == browser.fileBrowserLibrary.id })
            var folders = [browser.fileBrowserLibrary.id]
            var candidate: MediaItem?
            for _ in 0..<8 {
                guard !folders.isEmpty, candidate == nil else { break }
                let page = try await provider.items(
                    in: folders.removeFirst(), kind: .folder, page: .init(startIndex: 0, limit: 30)
                )
                candidate = page.items.first { $0.id.lowercased().hasSuffix(".mp4") }
                folders += page.items.filter { $0.kind == .folder }.map(\.id)
            }
            let item = try XCTUnwrap(candidate, "The approved demo directory must contain an MP4 fixture.")
            let detail = try await provider.item(id: item.id)
            XCTAssertEqual(detail.id, item.id)
            let request = try await provider.playbackInfo(for: item.id)
            guard case .networkFile = request.playbackSource else { throw SmokeFailure.source }
            let engine = try PlozzigenVideoEngine(networkFileResolver: runtime.networkFileResolver)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            let controller = UIViewController()
            window.rootViewController = controller
            let surface = engine.makeVideoOutputView()
            surface.frame = window.bounds
            controller.view.addSubview(surface)
            window.makeKeyAndVisible()
            let load = Task { await engine.load(request: request, startPosition: 0) }
            defer {
                load.cancel()
                engine.stop()
                window.isHidden = true
                window.rootViewController = nil
            }
            let deadline = ContinuousClock.now + .seconds(40)
            while !(await engine.hasRenderedVideoFrame()), ContinuousClock.now < deadline {
                if case .failed = engine.status { throw SmokeFailure.playback }
                try await Task.sleep(for: .milliseconds(100))
            }
            let rendered = await engine.hasRenderedVideoFrame()
            XCTAssertTrue(rendered)
            let start = engine.currentTime
            try await Task.sleep(for: .seconds(5))
            XCTAssertGreaterThan(engine.currentTime - start, 3)
            engine.pause()
            let paused = engine.currentTime
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(engine.currentTime, paused, accuracy: 0.25)
        } catch {
            XCTFail("Live \(kind) smoke failed: \(type(of: error))")
        }
        await runtime.setBackgroundWorkAllowed(false, revision: 1)
        if let prepared {
            await runtime.retire(accountID: prepared.account.id, credentialRevision: prepared.account.credentialRevision)
        }
    }

    private enum SmokeFailure: Error { case configuration, source, playback }

    private struct Configuration: Decodable {
        let baseURL: URL?
        let host: String?
        let port: Int?
        let username: String?
        let password: String?
        let share: String?
        let path: String?
        let exportPath: String?
        let hostKeySHA256: Data?
    }

    private func configuration(_ kind: String) async throws -> Configuration {
        guard let input = ProcessInfo.processInfo.environment["PLOZZ_PROVIDER_SMOKE_BROKER"] else {
            throw XCTSkip("Requires the private internal-provider smoke broker.")
        }
        guard let url = URL(string: input), url.scheme == "http", url.host == "127.0.0.1",
              url.port != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw SmokeFailure.configuration }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(
            url: url.appendingPathComponent(kind), timeoutInterval: 15
        ))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SmokeFailure.configuration }
        return try JSONDecoder().decode(Configuration.self, from: data)
    }
}
#endif
