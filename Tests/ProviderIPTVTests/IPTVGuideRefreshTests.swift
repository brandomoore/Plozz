import CoreModels
import CoreNetworking
import CryptoKit
import FeatureLiveTVCore
import Foundation
import XCTest
@testable import ProviderIPTV

@MainActor
final class IPTVGuideRefreshTests: XCTestCase {
    private let guideURL = URL(string: "https://provider.test/guide")!

    override func tearDown() {
        GuideRefreshTransport.state.reset()
        super.tearDown()
    }

    func testCatalogueWaitsForGuideWithoutInterruptingSavedChannelPlayback() async throws {
        try await checkGuideFirst(data: Data("<tv/>".utf8))
    }

    func testUncoordinatedControlIsRejectedBySingleConnectionProvider() async throws {
        try await checkUncoordinatedControl(data: Data("<tv/>".utf8))
    }

    private func checkUncoordinatedControl(data: Data) async throws {
        GuideRefreshTransport.state.configure(holding: ["/guide"], guide: data)
        defer { GuideRefreshTransport.state.release("/guide") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuideRefreshTransport.self]
        let http = IPTVHTTP(configuration: configuration)
        defer { http.cancel() }
        let guide = Task {
            let (bytes, _) = try await http.bytes(url: guideURL, headers: [:], guideRequest: true)
            defer { bytes.task.cancel() }
            var count = 0
            for try await _ in bytes { count += 1 }
            return count
        }
        defer { guide.cancel() }
        try await wait { GuideRefreshTransport.state.paths == ["/guide"] }
        do {
            let (bytes, _) = try await http.bytes(url: URL(string: "https://provider.test/list")!, headers: [:])
            bytes.task.cancel()
            XCTFail("The control must demonstrate the provider's competing-request refusal.")
        } catch {
            XCTAssertEqual(error as? IPTVError, .httpStatus(503))
        }
        GuideRefreshTransport.state.release("/guide")
        let received = try await guide.value
        XCTAssertEqual(received, data.count)
        XCTAssertEqual(GuideRefreshTransport.state.maximumActive, 2)
        XCTAssertEqual(GuideRefreshTransport.state.rejected, 1)
    }

    private func checkGuideFirst(data: Data) async throws {
        GuideRefreshTransport.state.configure(holding: ["/guide"], guide: data)
        defer { GuideRefreshTransport.state.release("/guide") }
        let client = try client()
        let guide = Task { try await client.guideData(from: guideURL) }
        defer { guide.cancel() }
        try await wait { GuideRefreshTransport.state.paths == ["/guide"] }
        let catalog = Task { try await client.ensureCatalog("live", force: true) }
        defer { catalog.cancel() }
        try await wait { await client.pendingRefreshAdmissionCount == 1 }
        XCTAssertEqual(GuideRefreshTransport.state.paths, ["/guide"])
        let delivery = try await client.delivery("live:saved")
        XCTAssertEqual(delivery.url.path, "/stream")
        XCTAssertEqual(GuideRefreshTransport.state.paths, ["/guide"], "Resolving saved playback must not wait for refresh.")
        GuideRefreshTransport.state.release("/guide")
        let downloaded = try await guide.value
        try await catalog.value
        XCTAssertEqual(downloaded, data)
        XCTAssertEqual(GuideRefreshTransport.state.paths, ["/guide", "/list"])
        XCTAssertEqual(GuideRefreshTransport.state.maximumActive, 1)
        XCTAssertEqual(GuideRefreshTransport.state.rejected, 0)
    }

    func testGuideWaitsForCatalogueAndQueuedReadersReuseCompletedDownload() async throws {
        GuideRefreshTransport.state.configure(holding: ["/list"])
        defer { GuideRefreshTransport.state.release("/list") }
        let client = try client()
        let catalog = Task { try await client.ensureCatalog("live", force: true) }
        defer { catalog.cancel() }
        try await wait { GuideRefreshTransport.state.paths == ["/list"] }
        let first = Task { try await client.guideData(from: guideURL) }
        let second = Task { try await client.guideData(from: guideURL) }
        defer { first.cancel(); second.cancel() }
        try await wait { await client.pendingRefreshAdmissionCount == 2 }
        XCTAssertEqual(GuideRefreshTransport.state.paths, ["/list"])
        GuideRefreshTransport.state.release("/list")
        try await catalog.value
        let firstData = try await first.value
        let secondData = try await second.value
        XCTAssertEqual(firstData, secondData)
        XCTAssertEqual(GuideRefreshTransport.state.paths, ["/list", "/guide"])
        XCTAssertEqual(GuideRefreshTransport.state.rejected, 0)
    }

    func testXtreamPerChannelGuideAlsoWaitsForCatalogue() async throws {
        GuideRefreshTransport.state.configure(holding: ["/player_api.php"])
        defer { GuideRefreshTransport.state.release("/player_api.php") }
        let client = try client(mode: .xtream)
        let catalog = Task { try await client.ensureCatalog("live", force: true) }
        defer { catalog.cancel() }
        try await wait { GuideRefreshTransport.state.paths == ["/player_api.php"] }
        let guide = Task {
            try await client.guide(channelID: "live:saved", from: Date(), to: Date().addingTimeInterval(3_600))
        }
        defer { guide.cancel() }
        try await wait { await client.pendingRefreshAdmissionCount == 1 }
        XCTAssertEqual(GuideRefreshTransport.state.paths.count, 1)
        GuideRefreshTransport.state.release("/player_api.php")
        try await catalog.value
        let programmes = try await guide.value
        XCTAssertTrue(programmes.isEmpty)
        XCTAssertEqual(GuideRefreshTransport.state.paths.count, 4)
        XCTAssertEqual(GuideRefreshTransport.state.maximumActive, 1)
        XCTAssertEqual(GuideRefreshTransport.state.rejected, 0)
    }

    func testCancelledGuideLeavesNoQueuedRequestAndDoesNotCancelCatalogue() async throws {
        GuideRefreshTransport.state.configure(holding: ["/list"])
        defer { GuideRefreshTransport.state.release("/list") }
        let client = try client()
        let catalog = Task { try await client.ensureCatalog("live", force: true) }
        defer { catalog.cancel() }
        try await wait { GuideRefreshTransport.state.paths == ["/list"] }
        let guide = Task { try await client.guideData(from: guideURL) }
        defer { guide.cancel() }
        try await wait { await client.pendingRefreshAdmissionCount == 1 }
        guide.cancel()
        do { _ = try await guide.value; XCTFail("Cancellation must not become a guide success.") }
        catch { XCTAssertTrue(error is CancellationError) }
        GuideRefreshTransport.state.release("/list")
        try await catalog.value
        XCTAssertEqual(GuideRefreshTransport.state.paths, ["/list"])
        let waiting = await client.pendingRefreshAdmissionCount
        XCTAssertEqual(waiting, 0)
        _ = try await client.guideData(from: guideURL)
        XCTAssertEqual(GuideRefreshTransport.state.paths, ["/list", "/guide"])
    }

    func testQueuedCataloguePrecedesAnotherGuideButDoesNotDiscardActiveTransfer() async throws {
        GuideRefreshTransport.state.configure(holding: ["/guide"])
        defer { GuideRefreshTransport.state.release("/guide") }
        let client = try client()
        let first = Task { try await client.guideData(from: guideURL) }
        defer { first.cancel() }
        try await wait { GuideRefreshTransport.state.paths == ["/guide"] }
        let second = Task { try await client.guideData(from: URL(string: "https://provider.test/other-guide")!) }
        defer { second.cancel() }
        try await wait { await client.pendingRefreshAdmissionCount == 1 }
        let catalog = Task { try await client.ensureCatalog("live", force: true) }
        defer { catalog.cancel() }
        try await wait { await client.pendingRefreshAdmissionCount == 2 }
        GuideRefreshTransport.state.release("/guide")
        _ = try await first.value
        try await catalog.value
        _ = try await second.value
        XCTAssertEqual(GuideRefreshTransport.state.paths, ["/guide", "/list", "/other-guide"])
        XCTAssertEqual(GuideRefreshTransport.state.rejected, 0)
    }

    func testOtherAccountsAreNotBlockedAndTeardownReleasesQueuedRequests() async throws {
        GuideRefreshTransport.state.configure(holding: ["/guide"], limit: 2)
        defer { GuideRefreshTransport.state.release("/guide") }
        let first = try client()
        let second = try client()
        let guide = Task { try await first.guideData(from: guideURL) }
        defer { guide.cancel() }
        try await wait { GuideRefreshTransport.state.paths == ["/guide"] }
        try await second.ensureCatalog("live", force: true)
        XCTAssertEqual(GuideRefreshTransport.state.paths, ["/guide", "/list"])
        let queued = Task { try await first.ensureCatalog("live", force: true) }
        defer { queued.cancel() }
        try await wait { await first.pendingRefreshAdmissionCount == 1 }
        await first.cancel()
        do { try await queued.value; XCTFail("Closed clients cannot admit queued catalogue work.") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await guide.value; XCTFail("Teardown must cancel the active transfer.") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(GuideRefreshTransport.state.paths, ["/guide", "/list"])
    }

    func testCapturedRealGuidesPreserveReferenceSchedulesAcrossRefreshAndIndexing() async throws {
        let (corpus, manifest) = try capturedCorpus()
        XCTAssertFalse(manifest.sources.isEmpty)
        for source in manifest.sources {
            let data = try Data(contentsOf: corpus.appendingPathComponent(source.file), options: .mappedIfSafe)
            XCTAssertEqual(data.count, source.bytes, source.name)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), source.sha256)
            GuideRefreshTransport.state.reset()
            try await checkUncoordinatedControl(data: data)
            GuideRefreshTransport.state.reset()
            try await checkGuideFirst(data: data)
            let channels = source.channels.enumerated().map { offset, sample in
                LiveTVPrototypeChannel(
                    id: "sample-\(offset)", number: offset + 1, name: sample.name,
                    category: "Test", symbol: "tv", accent: 0, source: .iptv, tagline: "",
                    guideID: sample.id
                )
            }
            let now = Date(timeIntervalSince1970: manifest.capturedAt)
            let parser = LiveTVXMLTVParser()
            let parsed = try parser.parse(gzipData: data, channels: channels, now: now)
            var indexed: [LiveTVPrototypeProgram] = []
            _ = try parser.parseIndexed(data: data, channels: channels, now: now) { indexed.append($0) }
            XCTAssertEqual(parsed.programs.count, indexed.count, source.name)
            XCTAssertTrue(
                parsed.programs.sorted { $0.id < $1.id } == indexed.sorted { $0.id < $1.id },
                "\(source.name): streaming and materialized listings differ"
            )
            XCTAssertEqual(parsed.matchedChannelCount, channels.count, source.name)
            for (offset, sample) in source.channels.enumerated() {
                let actual = Set(parsed.programs.filter { $0.channelID == "sample-\(offset)" }.map {
                    [$0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970]
                })
                XCTAssertEqual(actual, Set(sample.intervals), "\(source.name): sample \(offset)")
            }
            print("IPTV_GUIDE_CORPUS name=\(source.name) stations=\(parsed.guideChannelCount) sampledChannels=\(channels.count) retainedPrograms=\(parsed.programCount) controlRejected=1 maxConcurrentRefresh=1 rejected=0")
        }
    }

    func testLivePublicGuideDownloadAndFullStationIndex() async throws {
        guard ProcessInfo.processInfo.environment["PLOZZ_LIVE_GUIDE_PROBE"] == "1" else {
            throw XCTSkip("Opt-in live requests to the captured public guide sources; never opens a stream.")
        }
        let (_, manifest) = try capturedCorpus()
        XCTAssertFalse(manifest.sources.isEmpty)
        let client = try client(usesPublicNetwork: true)
        for source in manifest.sources {
            let url = try XCTUnwrap(URL(string: source.url))
            guard url.scheme == "https", ["i.mjh.nz", "epgshare01.online"].contains(url.host ?? ""),
                  url.user == nil, url.password == nil, url.query == nil else {
                XCTFail("Live probe requires an approved public, credential-free guide URL.")
                return
            }
            let document = try await client.guideDocument(from: url)
            let parser = LiveTVXMLTVParser()
            let now = Date()
            let metadata = try parser.parseIndexed(data: document.data, channels: [], now: now) { _ in
                XCTFail("A metadata-only request must not produce programme rows.")
            }
            let channels = metadata.guideChannels.sorted { $0.key < $1.key }.enumerated().map { offset, entry in
                LiveTVPrototypeChannel(
                    id: "station-\(offset)", number: offset + 1, name: entry.value.first ?? entry.key,
                    category: "Test", symbol: "tv", accent: 0, source: .iptv, tagline: "", guideID: entry.key
                )
            }
            var retained = 0
            let indexed = try parser.parseIndexed(
                data: document.data, channels: channels, now: now, indexGuideStations: true
            ) { _ in retained += 1 }
            XCTAssertGreaterThan(indexed.guideChannelCount, 0, source.name)
            XCTAssertGreaterThan(retained, 0, source.name)
            XCTAssertEqual(indexed.programCount, retained, source.name)
            print("IPTV_LIVE_GUIDE name=\(source.name) bytes=\(document.data.count) stations=\(indexed.guideChannelCount) indexedPrograms=\(retained)")
        }
    }

    private func capturedCorpus() throws -> (URL, Manifest) {
        let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/iptv-guide-corpus")
        let manifestURL = corpus.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("Opt in with python3 tools/iptv-guide-corpus.py; test replay never contacts a provider.")
        }
        return (corpus, try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)))
    }

    private func client(
        mode: IPTVCredential.Mode = .playlist, usesPublicNetwork: Bool = false
    ) throws -> IPTVClient {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let credential = try IPTVCredential(
            mode: mode,
            address: XCTUnwrap(URL(string: mode == .xtream ? "https://provider.test" : "https://provider.test/list")),
            username: mode == .xtream ? "fixture" : "", password: mode == .xtream ? "fixture" : "",
            guideURL: guideURL
        )
        do {
            let saved = try IPTVCatalog(
                url: root.appendingPathComponent(credential.identity.uuidString + ".sqlite"), key: credential.catalogKey
            )
            try saved.insert(IPTVRecord(
                item: .init(id: "live:saved", title: "Saved channel", kind: .video, libraryID: "live"),
                streamURL: URL(string: "https://provider.test/stream"), streamID: "7", isLive: true
            ))
            try saved.setState(mode == .xtream ? "live" : "playlist-v5", String(Date().timeIntervalSince1970))
        }
        let configuration = URLSessionConfiguration.ephemeral
        if !usesPublicNetwork { configuration.protocolClasses = [GuideRefreshTransport.self] }
        let client = try IPTVClient(credential: credential, directory: root, configuration: configuration)
        addTeardownBlock {
            await client.cancel()
            try FileManager.default.removeItem(at: root)
        }
        return client
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("The expected refresh transition did not occur.")
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private struct Manifest: Decodable { let capturedAt: TimeInterval; let sources: [Source] }
    private struct Source: Decodable {
        let name: String
        let url: String
        let file: String
        let bytes: Int
        let sha256: String
        let channels: [Channel]
    }
    private struct Channel: Decodable {
        let id: String
        let name: String
        let intervals: [[TimeInterval]]
    }
}

private final class GuideRefreshTransport: URLProtocol, @unchecked Sendable {
    static let state = State()

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var held: Set<String> = []
        private var pending: [ObjectIdentifier: GuideRefreshTransport] = [:]
        private var received: [String] = []
        private var peak = 0
        private var refusals = 0
        private var limit = 1
        private var guide = Data("<tv/>".utf8)
        var paths: [String] { lock.withLock { received } }
        var maximumActive: Int { lock.withLock { peak } }
        var rejected: Int { lock.withLock { refusals } }

        func configure(holding: Set<String>, guide: Data = Data("<tv/>".utf8), limit: Int = 1) {
            lock.withLock { held = holding; self.guide = guide; self.limit = limit }
        }

        func reset() {
            lock.withLock {
                held = []; pending = [:]; received = []; peak = 0; refusals = 0
                guide = Data("<tv/>".utf8); limit = 1
            }
        }

        func start(_ transport: GuideRefreshTransport) {
            let status: Int? = lock.withLock {
                pending[ObjectIdentifier(transport)] = transport
                let path = transport.request.url!.path
                received.append(path)
                peak = max(peak, pending.count)
                if pending.count > limit { refusals += 1; return 503 }
                return held.contains(path) ? nil : 200
            }
            if let status { complete(transport, status: status) }
        }

        func stop(_ transport: GuideRefreshTransport) {
            _ = lock.withLock { pending.removeValue(forKey: ObjectIdentifier(transport)) }
        }

        func release(_ path: String) {
            let ready = lock.withLock {
                held.remove(path)
                return pending.values.filter { $0.request.url?.path == path }
            }
            for transport in ready { complete(transport, status: 200) }
        }

        private func complete(_ transport: GuideRefreshTransport, status: Int) {
            let body: Data? = lock.withLock {
                guard pending.removeValue(forKey: ObjectIdentifier(transport)) != nil else { return nil }
                if status != 200 { return Data() }
                if transport.request.url?.path == "/list" {
                    return Data("#EXTM3U\n#EXTINF:-1,Updated channel\nhttps://provider.test/stream\n".utf8)
                }
                if transport.request.url?.path == "/player_api.php" {
                    let action = URLComponents(url: transport.request.url!, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "action" }?.value
                    let json: String
                    switch action {
                    case nil: json = #"{"user_info":{"auth":1,"status":"Active"}}"#
                    case "get_live_categories": json = "[]"
                    case "get_live_streams": json = #"[{"stream_id":7,"name":"Saved channel","stream_type":"live"}]"#
                    case "get_simple_data_table": json = #"{"epg_listings":[]}"#
                    default: preconditionFailure("Unexpected Xtream fixture request")
                    }
                    return Data(json.utf8)
                }
                return guide
            }
            guard let body else { return }
            let response = HTTPURLResponse(
                url: transport.request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Cache-Control": "max-age=60"]
            )!
            transport.client?.urlProtocol(transport, didReceive: response, cacheStoragePolicy: .notAllowed)
            transport.client?.urlProtocol(transport, didLoad: body)
            transport.client?.urlProtocolDidFinishLoading(transport)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.state.start(self) }
    override func stopLoading() { Self.state.stop(self) }
}
