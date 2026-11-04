import CoreModels
import EnginePlozzigen
import FeatureHomeCore
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

    private actor BodyChunkPacer {
        let interval: Duration
        private var next = ContinuousClock.now

        init(interval: Duration) {
            self.interval = interval
        }

        func wait() async throws {
            try Task.checkCancellation()
            let deadline = max(next, .now) + interval
            next = deadline
            try await Task.sleep(until: deadline, clock: .continuous)
        }
    }

    func testLocalBodyPacingIsSharedAcrossRequests() async throws {
        let pacer = BodyChunkPacer(interval: .milliseconds(20))
        let started = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { try await pacer.wait() }
            }
            try await group.waitForAll()
        }
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(80))
    }

    func testSyntheticDVDISOPlaysAndSeeksOverWebDAV() async throws {
        try await checkFixturePlayback(named: "dvd-test-pattern", fileExtension: "iso")
    }

    private final class FixtureReads: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []
        func record(_ path: String) { lock.withLock { _ = paths.insert(path) } }
        func contains(_ path: String) -> Bool { lock.withLock { paths.contains(path) } }
    }

    func testSyntheticBluRayFolderPlaysBothClipsAndSeeksOverWebDAV() async throws {
        try await checkBluRayPlayback(startPosition: 0)
    }

    func testSyntheticBluRayFolderResumesIntoSecondClipOverWebDAV() async throws {
        try await checkBluRayPlayback(startPosition: 9)
    }

    private func checkBluRayPlayback(startPosition: Double) async throws {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
            .appendingPathComponent("Fixtures/bluray-test-pattern")
        let subpaths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        var files: [String: URL] = [:]
        var sizes: [String: Int] = [:]
        var directories: Set<String> = [""]
        for path in subpaths {
            let url = root.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true {
                directories.insert(path)
            } else {
                files[path] = url
                sizes[path] = try XCTUnwrap(values.fileSize)
            }
        }
        let fixtureFiles = files
        let fixtureSizes = sizes
        let fixtureDirectories = directories
        let reads = FixtureReads()
        let server = try IPTVTestHTTPServer { request in
            let target = String(request.split(separator: " ").dropFirst().first ?? "")
            let path = String(target.dropFirst("/dav".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if request.hasPrefix("OPTIONS ") { return .init(headers: ["DAV": "1, 2"]) }
            if request.hasPrefix("PROPFIND ") {
                guard fixtureDirectories.contains(path) || fixtureFiles[path] != nil else { return .init(status: 404) }
                var paths = [path]
                if request.lowercased().contains("\r\ndepth: 1\r\n") {
                    paths += (Array(fixtureDirectories) + Array(fixtureFiles.keys)).filter {
                        !$0.isEmpty && $0 != path && ($0 as NSString).deletingLastPathComponent == path
                    }
                }
                let properties = paths.sorted().map { entry in
                    let collection = fixtureDirectories.contains(entry)
                    let body = collection ? "<D:resourcetype><D:collection/></D:resourcetype>"
                        : "<D:getcontentlength>\(fixtureSizes[entry]!)</D:getcontentlength><D:getetag>\"fixture\"</D:getetag>"
                    return "<D:response><D:href>/dav/\(entry)\(collection ? "/" : "")</D:href><D:propstat><D:prop>\(body)</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
                }.joined()
                return .init(data: Data("<D:multistatus xmlns:D=\"DAV:\">\(properties)</D:multistatus>".utf8),
                             status: 207, headers: ["Content-Type": "application/xml"])
            }
            guard request.hasPrefix("GET "), let file = fixtureFiles[path], let size = fixtureSizes[path],
                  let range = request.components(separatedBy: "\r\n").first(where: {
                      $0.lowercased().hasPrefix("range: bytes=")
                  })?.split(separator: "=").last?.split(separator: "-"),
                  range.count == 2, let start = Int(range[0]), let end = Int(range[1]),
                  start >= 0, end >= start, end < size else { return .init(status: 416) }
            reads.record(path)
            return .init(file: file, status: 206, headers: [
                "Content-Range": "bytes \(start)-\(end)/\(size)", "ETag": "\"fixture\""
            ], range: start..<(end + 1))
        }
        addTeardownBlock { await server.stop() }
        let base = try await server.start().appendingPathComponent("dav")
        try await checkPlayback(
            base: base, path: "BDMV/index.bdmv", credential: .anonymous,
            seekPositions: [10, 2, 13], startPosition: startPosition
        )
        XCTAssertTrue(reads.contains("BDMV/STREAM/00001.m2ts"))
        XCTAssertTrue(reads.contains("BDMV/STREAM/00002.m2ts"))
        XCTAssertFalse(reads.contains("BDMV/STREAM/00003.m2ts"), "The largest clip is not the selected movie")
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

    func testExplicitLocalISOPlaybackWithLatency() async throws {
        try await checkExplicitLocalPlayback(
            fixtureKey: "PLOZZ_WEBDAV_LOCAL_ISO_FIXTURE", extensions: ["iso"], requiresNativeHLS: true
        )
    }

    func testExplicitLocalContainerPlaybackWithLatency() async throws {
        try await checkExplicitLocalPlayback(
            fixtureKey: "PLOZZ_WEBDAV_LOCAL_CONTAINER_FIXTURE", extensions: ["mp4", "mkv"],
            requiresNativeHLS: false
        )
    }

    private func checkExplicitLocalPlayback(
        fixtureKey: String, extensions: Set<String>, requiresNativeHLS: Bool
    ) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment[fixtureKey] else {
            throw XCTSkip("Requires a staged synthetic local file; never contacts a public server.")
        }
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard name == (name as NSString).lastPathComponent,
              extensions.contains(fileExtension),
              let start = Double(environment["PLOZZ_WEBDAV_LOCAL_START_POSITION"] ?? "0"),
              start.isFinite, start >= 0 else {
            throw CheckFailure.invalidInput
        }
        let file = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            .appendingPathComponent(name)
        try await checkFixturePlayback(
            file: file, fileExtension: fileExtension, seekPositions: [30], startPosition: start,
            sustainedPlaybackSeconds: 60, headerDelay: .milliseconds(250), bodyDelay: .milliseconds(10),
            requiresNativeHLS: requiresNativeHLS
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
        headerDelay: Duration = .zero, bodyDelay: Duration = .zero,
        requiresNativeHLS: Bool = false
    ) async throws {
        let path = "fixture.\(fileExtension)"
        let fileSize = try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let etag = "\"synthetic-disc\""
        let collection = """
        <D:response><D:href>/dav/</D:href><D:propstat><D:prop>
        <D:resourcetype><D:collection/></D:resourcetype>
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        """
        let fileProperties = """
        <D:response>
        <D:href>/dav/\(path)</D:href><D:propstat><D:prop>
        <D:getcontentlength>\(fileSize)</D:getcontentlength>
        <D:getetag>\(etag)</D:getetag>
        <D:getcontenttype>application/octet-stream</D:getcontenttype>
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        """
        let aggregate = ProcessInfo.processInfo.environment["PLOZZ_WEBDAV_AGGREGATE_BANDWIDTH"] == "1"
        let pacer = aggregate && bodyDelay != .zero ? BodyChunkPacer(interval: bodyDelay) : nil
        let server = try IPTVTestHTTPServer(beforeBodyChunk: {
            try await pacer?.wait()
        }) { request in
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
                  start >= 0, end >= start, end < fileSize else {
                return .init(status: 416)
            }
            return .init(file: file, status: 206, headers: [
                "Content-Range": "bytes \(start)-\(end)/\(fileSize)",
                "ETag": etag,
                "Content-Type": "application/octet-stream"
            ], headerDelay: headerDelay, delay: pacer == nil ? bodyDelay : .zero, range: start..<(end + 1))
        }
        let recordIO: @Sendable (String) async -> Void = { phase in
            print("WEBDAV_LOCAL phase=\(phase) requests=\(await server.requestCount) peakActive=\(await server.peakActiveRequestCount) bodyBytes=\(await server.bodyBytesSent)")
        }
        addTeardownBlock {
            await server.stop()
            await recordIO("teardown")
        }
        let base = try await server.start().appendingPathComponent("dav")
        print("WEBDAV_LOCAL bandwidth=\(pacer == nil ? "per-connection" : "aggregate") headerDelay=\(headerDelay) chunkDelay=\(bodyDelay)")
        try await checkPlayback(
            base: base, path: path, credential: .anonymous, seekPositions: seekPositions,
            startPosition: startPosition, sustainedPlaybackSeconds: sustainedPlaybackSeconds,
            requiresNativeHLS: requiresNativeHLS, recordIO: recordIO
        )
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
        startPosition: Double = 0, sustainedPlaybackSeconds: Int = 0,
        requiresNativeHLS: Bool = false, recordIO: (@Sendable (String) async -> Void)? = nil
    ) async throws {
        let environment = ProcessInfo.processInfo.environment
        let detailPlayDelay: Duration?
        if let value = environment["PLOZZ_WEBDAV_DETAIL_PLAY_DELAY_SECONDS"] {
            guard environment["PLOZZ_WEBDAV_DETAIL_PREPARATION"] == "1",
                  let seconds = Double(value), [2.0, 3.0].contains(seconds) else {
                throw CheckFailure.invalidInput
            }
            detailPlayDelay = .seconds(seconds)
        } else {
            detailPlayDelay = nil
        }
        let earlyHandoff = environment["PLOZZ_WEBDAV_EARLY_HANDOFF"] == "1"
        guard !earlyHandoff || detailPlayDelay != nil else { throw CheckFailure.invalidInput }
        let sceneDeadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < sceneDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
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
        let registry = MediaTransportResolverRegistry(adapter: adapter)
        let resolver = MediaTransportNetworkFileResolver(
            registry: registry,
            sourcePreparer: PlozzigenNetworkFileStreamProber.preparePlaybackSource,
            sessionKeyProvider: { _ in key }
        )
        let coordinator = DetailPlaybackPreparationCoordinator()
        defer { coordinator.invalidate() }
        var preparationHandle: MediaTransportPreparation?
        let preparationStarted: ContinuousClock.Instant
        if let detailPlayDelay {
            var detailItem = item
            detailItem.sourceAccountID = account
            detailItem.resumePosition = startPosition
            let candidate = try XCTUnwrap(DetailPlaybackPreparationCandidate(
                detailItem, exactFileRelativePath: ShareProvider.exactFileRelativePath(for: detailItem)
            ))
            let detailScope = DetailPlaybackPreparationScope(
                profileID: "fixture", authorizationID: "fixture", accountID: account,
                serverUserID: "fixture", credentialRevision: revision
            )
            let detailStarted = ContinuousClock.now
            let preparationEnvironment = DetailPlaybackPreparationEnvironment(
                scope: { $0 == account ? detailScope : nil },
                exactFileRelativePath: { ShareProvider.exactFileRelativePath(for: $0) },
                provider: { $0 == account ? provider : nil },
                reserve: { locator, position in
                    if earlyHandoff {
                        let handle = try resolver.beginPreparation(locator, startPosition: position)
                        preparationHandle = handle
                        print("WEBDAV_DISC detailPreparationTicketSeconds=\(detailStarted.duration(to: .now))")
                        return DetailPlaybackPreparationReservation(
                            cancel: { handle.cancel() },
                            requestPlaybackHandoff: { handle.requestPlaybackHandoff() }
                        )
                    }
                    let handle = try await resolver.prepare(locator, startPosition: position)
                    preparationHandle = handle
                    print("WEBDAV_DISC detailPreparationSeconds=\(detailStarted.duration(to: .now))")
                    return DetailPlaybackPreparationReservation { handle.cancel() }
                }
            )
            await recordIO?("detail")
            let detailVisible = ContinuousClock.now
            coordinator.update(candidate: candidate, environment: preparationEnvironment, isActive: true)
            try await Task.sleep(for: detailPlayDelay)
            preparationStarted = .now
            let readyAtPlay = preparationHandle?.warmupOutcome != nil
            coordinator.handoff(detailItem)
            coordinator.stop()
            print("WEBDAV_DISC detailPlayDelaySeconds=\(detailVisible.duration(to: preparationStarted)) preparationReadyAtPlay=\(readyAtPlay) earlyHandoff=\(earlyHandoff)")
        } else if environment["PLOZZ_WEBDAV_DETAIL_PREPARATION"] == "1" {
            let detailStarted = ContinuousClock.now
            let detailLocator = try await provider.playbackPreparationLocator(
                for: item.id, mediaSourceID: path
            )
            let locator = try XCTUnwrap(detailLocator)
            do {
                preparationHandle = try await resolver.prepare(locator, startPosition: startPosition)
            } catch {
                print("WEBDAV_DISC preparationFailureType=\(String(reflecting: type(of: error))) cancelled=\(Task.isCancelled)")
                if let transportError = error as? MediaTransportError {
                    switch transportError {
                    case .timeout: print("WEBDAV_DISC preparationFailure=timeout")
                    case .cancelled: print("WEBDAV_DISC preparationFailure=cancelled")
                    case .transport(let code): print("WEBDAV_DISC preparationFailure=transport code=\(code)")
                    default: print("WEBDAV_DISC preparationFailure=otherTransport")
                    }
                }
                throw error
            }
            print("WEBDAV_DISC detailPreparationSeconds=\(detailStarted.duration(to: .now))")
            preparationStarted = .now
        } else {
            preparationStarted = .now
        }
        let prepared = preparationHandle
        defer { withExtendedLifetime(prepared) {} }
        await recordIO?("play")
        let request = try await provider.playbackInfo(for: item.id, mediaSourceID: nil, forceTranscode: false)
        let preparationDuration = preparationStarted.duration(to: .now)
        print("WEBDAV_DISC preparationSeconds=\(preparationDuration)")
        guard request.playbackSource?.requiresNetworkFileResolver == true else {
            return XCTFail("Disc playback must use the production transport path")
        }
        if path.hasSuffix("index.bdmv") {
            guard case .networkDisc = request.playbackSource else {
                return XCTFail("A Blu-ray folder must not play its index as an ordinary file")
            }
        }
        let engine = try PlozzigenVideoEngine(
            networkFileResolver: resolver
        )
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        let initiallyRendered = await engine.hasRenderedVideoFrame()
        XCTAssertFalse(initiallyRendered)
        addTeardownBlock {
            await engine.stop()
            await engine.drainTransport()
            await registry.retire(accountID: account, credentialRevision: revision)
        }
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = engine.makeVideoOutputView()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        let started = ContinuousClock.now
        try await perform(engine: engine) { await engine.load(request: request, startPosition: startPosition) }
        if requiresNativeHLS {
            XCTAssertEqual(engine.diagnosticRoute, .localHLS, "The native ISO workload must not use a software fallback")
        }
        if let prepared {
            XCTAssertTrue(prepared.wasConsumed, "A prepared sample must consume its exact reservation")
        }
        try await wait(engine: engine, seconds: 45) {
            guard engine.isPlaybackPositionReady else { return false }
            let rendered = await engine.hasRenderedVideoFrame()
            return rendered && engine.isPlaybackPositionReady
        }
        let renderedAt = ContinuousClock.now
        let firstRenderedDuration = started.duration(to: renderedAt)
        let playToFirstRenderedDuration = preparationStarted.duration(to: renderedAt)
        let firstPresentedPosition = engine.currentTime
        await recordIO?("firstFrame")
        XCTAssertGreaterThanOrEqual(firstPresentedPosition, max(0, startPosition - 1))
        XCTAssertLessThan(firstPresentedPosition, startPosition + 5)
        try await waitForPlayback(engine, after: firstPresentedPosition + 0.5, before: startPosition + 5)
        let startupDuration = preparationStarted.duration(to: .now)
        if environment["PLOZZ_WEBDAV_REQUIRE_SUBTHREE_START"] == "1" {
            if detailPlayDelay == nil {
                XCTAssertNotNil(prepared, "The prepared-start acceptance run must consume a reservation")
            }
            XCTAssertLessThan(startupDuration, .seconds(3), "Play-to-render-and-advance exceeded the target")
        }
        XCTAssertGreaterThan(
            engine.duration, max(startPosition, seekPositions.max()!) + Double(max(1, sustainedPlaybackSeconds))
        )
        if path.hasSuffix("index.bdmv") {
            XCTAssertEqual(engine.duration, 16, accuracy: 0.5, "The selected playlist spans both eight-second clips")
        }
        print("WEBDAV_DISC startPosition=\(startPosition) firstPresentedPosition=\(firstPresentedPosition)")
        print("WEBDAV_DISC firstRenderedFrameSeconds=\(firstRenderedDuration) duration=\(engine.duration)")
        print("WEBDAV_DISC playToFirstRenderedFrameSeconds=\(playToFirstRenderedDuration)")
        print("WEBDAV_DISC population=\(detailPlayDelay == nil ? (prepared == nil ? "cold" : "prepared") : "timed-detail") reservationConsumed=\(prepared?.wasConsumed ?? false)")
        print("WEBDAV_DISC warmupOutcome=\(prepared?.warmupOutcome.map { String(describing: $0) } ?? "none")")
        print("WEBDAV_DISC startupSeconds=\(startupDuration) route=\(engine.diagnosticRoute?.rawValue ?? "unknown")")
        try await checkSustainedPlayback(
            engine, seconds: sustainedPlaybackSeconds, phase: "startup"
        )
        for target in seekPositions {
            let seekStart = ContinuousClock.now
            try await perform(engine: engine) { await engine.seek(to: target) }
            try await waitForPlayback(engine, after: target + 0.3, before: target + 5)
            print("WEBDAV_DISC seek=\(target) landed=\(engine.currentTime) elapsed=\(seekStart.duration(to: .now))")
        }
        try await checkSustainedPlayback(
            engine, seconds: sustainedPlaybackSeconds, phase: "afterSeek"
        )
        engine.stop()
        await engine.drainTransport()
        let renderedAfterStop = await engine.hasRenderedVideoFrame()
        XCTAssertFalse(renderedAfterStop)
    }

    private func checkSustainedPlayback(
        _ engine: PlozzigenVideoEngine, seconds: Int, phase: String
    ) async throws {
        guard seconds > 0 else { return }
        let initialPosition = engine.currentTime
        let started = ContinuousClock.now
        while started.duration(to: .now) < .seconds(seconds) {
            if case .failed = engine.status { throw CheckFailure.engineFailed }
            try await Task.sleep(for: .milliseconds(250))
        }
        let progress = engine.currentTime - initialPosition
        XCTAssertGreaterThan(progress, Double(seconds) - 2, "Sustained playback stalled during \(phase)")
        print("WEBDAV_DISC sustainedSeconds=\(seconds) progressed=\(progress) phase=\(phase)")
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
            guard engine.isPlaybackPositionReady else { return false }
            let rendered = await engine.hasRenderedVideoFrame()
            return rendered && engine.isPlaybackPositionReady
                && engine.currentTime > after && engine.currentTime < before
        }
    }

    private func wait(
        engine: PlozzigenVideoEngine, seconds: Int, condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !(await condition()) {
            if case .failed = engine.status { throw CheckFailure.engineFailed }
            guard ContinuousClock.now < deadline else { throw CheckFailure.deadlineExceeded }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
