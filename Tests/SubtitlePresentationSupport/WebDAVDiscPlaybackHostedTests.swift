import CoreModels
import EnginePlozzigen
import Foundation
import MediaTransportCore
import MediaTransportHTTP
import MediaTransportWebDAV
@testable import ProviderShare
import UIKit
import XCTest

@MainActor
final class WebDAVDiscPlaybackHostedTests: XCTestCase {
    private enum CheckFailure: Error {
        case invalidInput, engineFailed, deadlineExceeded
    }

    func testSyntheticDVDISOPlaysAndSeeksOverWebDAV() async throws {
        try await checkFixturePlayback(named: "dvd-test-pattern", fileExtension: "iso")
    }

    func testMP4PlaysAndSeeksOverWebDAV() async throws {
        try await checkFixturePlayback(named: "embedded", fileExtension: "mp4")
    }

    func testMKVPlaysAndSeeksOverWebDAV() async throws {
        try await checkFixturePlayback(named: "glow-software", fileExtension: "mkv")
    }

    func testMKVResumesOverWebDAV() async throws {
        try await checkFixturePlayback(named: "glow-software", fileExtension: "mkv", startPosition: 3)
    }

    func testSyntheticDVDISOResumesOverWebDAV() async throws {
        try await checkFixturePlayback(named: "dvd-test-pattern", fileExtension: "iso", startPosition: 3)
    }

    func testExplicitLocalHighBitratePlaybackWithLatency() async throws {
        guard let name = ProcessInfo.processInfo.environment["PLOZZ_WEBDAV_LOCAL_PLAYBACK_FIXTURE"] else {
            throw XCTSkip("Requires a staged synthetic local playback fixture; never contacts a public server.")
        }
        guard name == (name as NSString).lastPathComponent, name.hasSuffix(".mkv") else {
            throw CheckFailure.invalidInput
        }
        let file = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            .appendingPathComponent(name)
        try await checkFixturePlayback(
            file: file, fileExtension: "mkv", seekPositions: [35, 5, 20],
            sustainedPlaybackSeconds: 60, headerDelay: .milliseconds(80), bodyDelay: .milliseconds(1)
        )
    }

    private func checkFixturePlayback(
        named name: String, fileExtension: String, startPosition: Double = 0
    ) async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: fileExtension, subdirectory: "Fixtures"
        ))
        try await checkFixturePlayback(
            file: file, fileExtension: fileExtension, seekPositions: [4, 1], startPosition: startPosition
        )
    }

    private func checkFixturePlayback(
        file: URL, fileExtension: String, seekPositions: [Double],
        startPosition: Double = 0, sustainedPlaybackSeconds: Int = 0,
        headerDelay: Duration = .zero, bodyDelay: Duration = .zero
    ) async throws {
        let path = "fixture.\(fileExtension)"
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let etag = "\"synthetic-disc\""
        let collection = """
        <D:response><D:href>/dav/</D:href><D:propstat><D:prop>
        <D:resourcetype><D:collection/></D:resourcetype>
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        """
        let fileProperties = """
        <D:response>
        <D:href>/dav/\(path)</D:href><D:propstat><D:prop>
        <D:getcontentlength>\(data.count)</D:getcontentlength>
        <D:getetag>\(etag)</D:getetag>
        <D:getcontenttype>application/octet-stream</D:getcontenttype>
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        """
        let server = try IPTVTestHTTPServer { request in
            if request.hasPrefix("OPTIONS ") {
                return .init(headers: ["DAV": "1, 2"])
            }
            if request.hasPrefix("PROPFIND ") {
                let target = request.split(separator: " ").dropFirst().first
                let properties: String
                if target == "/dav" || target == "/dav/" {
                    let listsChildren = request.components(separatedBy: "\r\n").contains {
                        $0.lowercased() == "depth: 1"
                    }
                    properties = collection + (listsChildren ? fileProperties : "")
                } else if target == "/dav/\(path)" {
                    properties = fileProperties
                } else {
                    return .init(status: 404)
                }
                let xml = "<D:multistatus xmlns:D=\"DAV:\">\(properties)</D:multistatus>"
                return .init(data: Data(xml.utf8), status: 207, headers: ["Content-Type": "application/xml"])
            }
            guard request.hasPrefix("GET /dav/\(path) "),
                  let range = request.components(separatedBy: "\r\n").first(where: {
                      $0.lowercased().hasPrefix("range: bytes=")
                  })?.split(separator: "=").last?.split(separator: "-"),
                  range.count == 2,
                  let start = Int(range[0]), let end = Int(range[1]),
                  start >= 0, end >= start, end < data.count else {
                return .init(status: 416)
            }
            return .init(data: data.subdata(in: start..<(end + 1)), status: 206, headers: [
                "Content-Range": "bytes \(start)-\(end)/\(data.count)",
                "ETag": etag,
                "Content-Type": "application/octet-stream"
            ], headerDelay: headerDelay, delay: bodyDelay)
        }
        addTeardownBlock { await server.stop() }
        let base = try await server.start().appendingPathComponent("dav")
        try await checkPlayback(
            base: base, path: path, credential: .anonymous, seekPositions: seekPositions,
            startPosition: startPosition, sustainedPlaybackSeconds: sustainedPlaybackSeconds
        )
        print("WEBDAV_LOCAL requests=\(await server.requestCount) peakActive=\(await server.peakActiveRequestCount)")
    }

    func testExplicitLiveWebDAVISOPlaysAndSeeks() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLOZZ_WEBDAV_PLAYBACK_JSON"] != nil
                || environment["PLOZZ_WEBDAV_PLAYBACK_INPUT"] != nil else {
            throw XCTSkip("Requires an explicitly supplied private WebDAV playback configuration.")
        }
        struct Input: Decodable {
            let baseURL: URL
            let username: String
            let password: String
            let relativePath: String
            let seekPositions: [Double]
            let startPosition: Double?
        }
        let data: Data
        if let json = environment["PLOZZ_WEBDAV_PLAYBACK_JSON"] {
            data = Data(json.utf8)
        } else {
            let inputPath = try XCTUnwrap(environment["PLOZZ_WEBDAV_PLAYBACK_INPUT"])
            let inputURL = inputPath.hasPrefix("cache:")
                ? try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
                    .appendingPathComponent(String(inputPath.dropFirst("cache:".count)))
                : URL(fileURLWithPath: inputPath)
            data = try Data(contentsOf: inputURL)
        }
        let input = try JSONDecoder().decode(Input.self, from: data)
        let startPosition = input.startPosition ?? 0
        guard input.baseURL.scheme == "https", input.baseURL.user == nil,
              input.baseURL.password == nil, input.baseURL.query == nil,
              startPosition.isFinite, startPosition >= 0,
              !input.seekPositions.isEmpty, input.seekPositions.count <= 3,
              input.seekPositions.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw CheckFailure.invalidInput
        }
        try await checkPlayback(
            base: input.baseURL, path: input.relativePath,
            credential: .password(username: input.username, password: input.password, policy: .automatic),
            seekPositions: input.seekPositions, startPosition: startPosition, sustainedPlaybackSeconds: 60
        )
    }

    private func checkPlayback(
        base: URL, path: String, credential: WebDAVCredential, seekPositions: [Double],
        startPosition: Double = 0, sustainedPlaybackSeconds: Int = 0
    ) async throws {
        let scheme = try XCTUnwrap(base.scheme.flatMap(WebDAVScheme.init(rawValue:)))
        let account = "webdav-playback-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let endpoint = try MediaTransportEndpointIdentity(
            transportIdentifier: scheme.rawValue, host: try XCTUnwrap(base.host),
            port: base.port, rootPath: base.path
        )
        let key = MediaTransportSessionKey(
            accountID: account, credentialRevision: revision, endpoint: endpoint,
            trustRevision: UUID(), role: .playback
        )
        let adapter = WebDAVMediaTransportAdapter(scheme: scheme) { _, _ in
            .init(credential: credential, trustPolicy: .system)
        }
        let metadataKey = MediaTransportSessionKey(
            accountID: account, credentialRevision: revision, endpoint: endpoint,
            trustRevision: key.trustRevision, role: .metadata
        )
        let metadata = try await adapter.connect(for: metadataKey)
        addTeardownBlock { await metadata.shutdown() }
        try await metadata.fileSystem.validate()
        let browser = ShareTransportBrowser(role: .metadata, sessionFactory: { _ in metadata })
        let library = ShareLibraryStore(browser: browser, serverName: "Disc fixture")
        addTeardownBlock { await library.close() }
        let parent = (path as NSString).deletingLastPathComponent
        let container = parent.isEmpty ? ShareLibraryStore.rootLibraryID : "d:\(parent)"
        let entries = try await library.entries(forContainerID: container)
        let item = try XCTUnwrap(entries.first { $0.id == "f:\(path)" },
                                 "The production browser must expose the selected media")
        let provider = ShareProvider(
            session: UserSession(
                server: .init(id: account, name: "Disc fixture", baseURL: base, provider: .mediaShare),
                userID: "fixture", userName: "", deviceID: "fixture", accessToken: ""
            ),
            credentialRevision: revision, sessionFactory: { _ in metadata },
            catalogCoordinator: ShareCatalogCoordinator(initialWorkScope: .paused)
        )
        addTeardownBlock { await provider.teardown() }
        let preparationStarted = ContinuousClock.now
        let request = try await provider.playbackInfo(for: item.id, mediaSourceID: nil, forceTranscode: false)
        let preparationDuration = preparationStarted.duration(to: .now)
        print("WEBDAV_DISC preparationSeconds=\(preparationDuration)")
        guard case .networkFile = request.playbackSource else {
            return XCTFail("Disc playback must use the production network-file path")
        }
        let registry = MediaTransportResolverRegistry(adapter: adapter)
        let resolver = MediaTransportNetworkFileResolver(registry: registry, sessionKeyProvider: { _ in key })
        let engine = try PlozzigenVideoEngine(networkFileResolver: resolver)
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        addTeardownBlock {
            await engine.stop()
            await engine.drainTransport()
            await registry.retire(accountID: account, credentialRevision: revision)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = engine.makeVideoOutputView()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        let started = ContinuousClock.now
        try await perform(engine: engine) { await engine.load(request: request, startPosition: startPosition) }
        try await wait(engine: engine, seconds: 45) {
            engine.isPlaybackPositionReady && engine.hasPresentedVideoFrame
        }
        let firstPresentedPosition = engine.currentTime
        XCTAssertGreaterThanOrEqual(firstPresentedPosition, max(0, startPosition - 1))
        XCTAssertLessThan(firstPresentedPosition, startPosition + 5)
        try await waitForPlayback(engine, after: startPosition + 0.5, before: startPosition + 5)
        XCTAssertGreaterThan(engine.duration, max(startPosition, seekPositions.max()!) + 1)
        print("WEBDAV_DISC startPosition=\(startPosition) firstPresentedPosition=\(firstPresentedPosition)")
        print("WEBDAV_DISC firstFrameSeconds=\(started.duration(to: .now)) duration=\(engine.duration)")
        print("WEBDAV_DISC preparationAndFirstFrameSeconds=\(preparationDuration + started.duration(to: .now))")
        for target in seekPositions {
            let seekStart = ContinuousClock.now
            try await perform(engine: engine) { await engine.seek(to: target) }
            try await waitForPlayback(engine, after: target + 0.3, before: target + 5)
            print("WEBDAV_DISC seek=\(target) landed=\(engine.currentTime) elapsed=\(seekStart.duration(to: .now))")
        }
        if sustainedPlaybackSeconds > 0 {
            let initialPosition = engine.currentTime
            let started = ContinuousClock.now
            while started.duration(to: .now) < .seconds(sustainedPlaybackSeconds) {
                if case .failed = engine.status { throw CheckFailure.engineFailed }
                try await Task.sleep(for: .milliseconds(250))
            }
            let progress = engine.currentTime - initialPosition
            XCTAssertGreaterThan(progress, Double(sustainedPlaybackSeconds) - 2)
            print("WEBDAV_DISC sustainedSeconds=\(sustainedPlaybackSeconds) progressed=\(progress)")
        }
    }

    private func perform(
        engine: PlozzigenVideoEngine, operation: @escaping @MainActor () async -> Void
    ) async throws {
        var completed = false
        let task = Task { await operation(); completed = true }
        do {
            try await wait(engine: engine, seconds: 120) { completed }
            await task.value
        } catch {
            task.cancel()
            engine.stop()
            await task.value
            throw error
        }
    }

    private func waitForPlayback(
        _ engine: PlozzigenVideoEngine, after: Double, before: Double = .greatestFiniteMagnitude
    ) async throws {
        try await wait(engine: engine, seconds: 45) {
            engine.isPlaybackPositionReady && engine.hasPresentedVideoFrame
                && engine.currentTime > after && engine.currentTime < before
        }
    }

    private func wait(
        engine: PlozzigenVideoEngine, seconds: Int, condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            if case .failed = engine.status { throw CheckFailure.engineFailed }
            guard ContinuousClock.now < deadline else { throw CheckFailure.deadlineExceeded }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
