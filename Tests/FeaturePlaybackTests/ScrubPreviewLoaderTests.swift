#if canImport(UIKit)
import XCTest
import UIKit
import CoreModels
@testable import FeaturePlayback

@MainActor
final class ScrubPreviewLoaderTests: XCTestCase {
    override func tearDown() {
        URLSessionStubProtocol.reset()
        super.tearDown()
    }

    func testTrickplayLoaderCachesTileAcrossScrubPositions() async throws {
        let tileURL = URL(string: "https://example.test/trickplay/0.jpg")!
        URLSessionStubProtocol.setResponses(
            [.init(statusCode: 200, data: try makeTileImageData())],
            for: tileURL
        )
        let loader = TrickplayThumbnailLoader(
            manifest: TrickplayManifest(
                thumbnailWidth: 10,
                thumbnailHeight: 10,
                tileColumns: 2,
                tileRows: 1,
                thumbnailCount: 2,
                intervalMs: 10_000,
                tileResources: [
                    .publicURL(try SecretFreeURLSource(url: tileURL))
                ]
            ),
            session: makeSession()
        )

        let first = await loader.thumbnail(forSeconds: 0)
        XCTAssertEqual(first?.width, 10)
        XCTAssertEqual(first?.height, 10)

        let second = await loader.thumbnail(forSeconds: 12)
        XCTAssertEqual(second?.width, 10)
        XCTAssertEqual(second?.height, 10)
        XCTAssertEqual(URLSessionStubProtocol.requestCount(for: tileURL), 1)
        XCTAssertNotNil(loader.cachedThumbnail(forSeconds: 12))
    }

    func testTrickplayLoaderReturnsNilWhenFetchFails() async {
        let tileURL = URL(string: "https://example.test/trickplay/missing.jpg")!
        URLSessionStubProtocol.setResponses([.init(statusCode: 404, data: Data())], for: tileURL)
        let loader = TrickplayThumbnailLoader(
            manifest: TrickplayManifest(
                thumbnailWidth: 10,
                thumbnailHeight: 10,
                tileColumns: 1,
                tileRows: 1,
                thumbnailCount: 1,
                intervalMs: 10_000,
                tileResources: [
                    .publicURL(try! SecretFreeURLSource(url: tileURL))
                ]
            ),
            session: makeSession()
        )

        let image = await loader.thumbnail(forSeconds: 0)
        XCTAssertNil(image)
        XCTAssertNil(loader.cachedThumbnail(forSeconds: 0))
    }

    func testPlexBIFLoaderDownloadsBlobOnceAndCachesFrames() async throws {
        let bifURL = URL(string: "https://example.test/indexes/hd")!
        URLSessionStubProtocol.setResponses(
            [.init(statusCode: 200, data: try makeBIFData(frames: [makeJPEGData(color: .red), makeJPEGData(color: .blue)]))],
            for: bifURL
        )
        let loader = PlexBIFThumbnailLoader(
            resource: .publicURL(try SecretFreeURLSource(url: bifURL)),
            session: makeSession()
        )

        let first = await loader.thumbnail(forSeconds: 0)
        XCTAssertNotNil(first)
        XCTAssertNotNil(loader.cachedThumbnail(forSeconds: 0.5))
        let second = await loader.thumbnail(forSeconds: 1.2)
        XCTAssertNotNil(second)
        XCTAssertEqual(URLSessionStubProtocol.requestCount(for: bifURL), 1)
    }

    func testPlexBIFLoaderRetriesAfterInitialFailure() async throws {
        let bifURL = URL(string: "https://example.test/indexes/sd")!
        URLSessionStubProtocol.setResponses(
            [
                .init(statusCode: 503, data: Data("busy".utf8)),
                .init(statusCode: 200, data: try makeBIFData(frames: [makeJPEGData(color: .green)]))
            ],
            for: bifURL
        )
        let loader = PlexBIFThumbnailLoader(
            resource: .publicURL(try SecretFreeURLSource(url: bifURL)),
            session: makeSession()
        )

        let first = await loader.thumbnail(forSeconds: 0)
        XCTAssertNil(first)
        let second = await loader.thumbnail(forSeconds: 0)
        XCTAssertNotNil(second)
        XCTAssertEqual(URLSessionStubProtocol.requestCount(for: bifURL), 2)
    }

    func testPlexBIFLoaderRetriesTransientClientErrors() async throws {
        for status in [408, 429] {
            let url = URL(string: "https://example.test/indexes/retry-\(status)")!
            URLSessionStubProtocol.setResponses([
                .init(statusCode: status, data: Data()),
                .init(statusCode: 200, data: try makeBIFData(frames: [makeJPEGData(color: .green)]))
            ], for: url)
            let loader = PlexBIFThumbnailLoader(
                resource: .publicURL(try SecretFreeURLSource(url: url)),
                session: makeSession()
            )
            let first = await loader.thumbnail(forSeconds: 0)
            XCTAssertNil(first)
            XCTAssertFalse(loader.isPermanentlyUnavailable)
            let retry = await loader.thumbnail(forSeconds: 0)
            XCTAssertNotNil(retry)
            XCTAssertEqual(URLSessionStubProtocol.requestCount(for: url), 2)
        }
    }

    func testTrickplayLoaderResolvesAuthenticatedResourceAtFetch() async throws {
        let resolvedURL = URL(string: "https://media.test/trickplay/0.jpg?api_key=current")!
        URLSessionStubProtocol.setResponses(
            [.init(statusCode: 200, data: try makeTileImageData())],
            for: resolvedURL
        )
        let locator = try scrubLocator(
            provider: .jellyfin,
            path: "Videos/item/Trickplay/320/0.jpg"
        )
        let resolver = RecordingScrubResolver(url: resolvedURL)
        let loader = TrickplayThumbnailLoader(
            manifest: TrickplayManifest(
                thumbnailWidth: 10,
                thumbnailHeight: 10,
                tileColumns: 2,
                tileRows: 1,
                thumbnailCount: 2,
                intervalMs: 10_000,
                tileResources: [.authenticatedHTTP(locator)]
            ),
            authenticatedHTTPResolver: resolver,
            session: makeSession()
        )

        let image = await loader.thumbnail(forSeconds: 0)
        XCTAssertNotNil(image)
        XCTAssertEqual(resolver.locators, [locator])
    }

    func testBIFLoaderResolvesAuthenticatedResourceAtFetch() async throws {
        let resolvedURL = URL(
            string: "https://plex.test/library/parts/42/indexes/sd?X-Plex-Token=current"
        )!
        URLSessionStubProtocol.setResponses(
            [
                .init(
                    statusCode: 200,
                    data: try makeBIFData(frames: [makeJPEGData(color: .green)])
                )
            ],
            for: resolvedURL
        )
        let locator = try scrubLocator(
            provider: .plex,
            path: "library/parts/42/indexes/sd"
        )
        let resolver = RecordingScrubResolver(url: resolvedURL)
        let loader = PlexBIFThumbnailLoader(
            resource: .authenticatedHTTP(locator),
            authenticatedHTTPResolver: resolver,
            session: makeSession()
        )

        let image = await loader.thumbnail(forSeconds: 0)
        XCTAssertNotNil(image)
        XCTAssertEqual(resolver.locators, [locator])
    }

    func testControlsModelSignalsPreviewFrameAvailability() {
        let model = PlayerControlsModel()
        XCTAssertFalse(model.hasPreviewFrame)

        model.previewImage = makeSolidCGImage(color: .white)
        XCTAssertTrue(model.hasPreviewFrame)

        model.previewImage = nil
        XCTAssertFalse(model.hasPreviewFrame)
    }

    func testPlexBIFLoaderStopsRetryingMissingIndex() async throws {
        // Plex keeps advertising `indexes` after its preview files are deleted.
        let bifURL = URL(string: "https://example.test/indexes/gone")!
        URLSessionStubProtocol.setResponses(
            [
                .init(statusCode: 404, data: Data("missing".utf8)),
                .init(statusCode: 200, data: try makeBIFData(frames: [makeJPEGData(color: .green)]))
            ],
            for: bifURL
        )
        let loader = PlexBIFThumbnailLoader(
            resource: .publicURL(try SecretFreeURLSource(url: bifURL)),
            session: makeSession()
        )

        let first = await loader.thumbnail(forSeconds: 0)
        let second = await loader.thumbnail(forSeconds: 4)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertTrue(loader.isPermanentlyUnavailable)
        XCTAssertEqual(URLSessionStubProtocol.requestCount(for: bifURL), 1)
    }

    func testFallbackLoaderSwitchesToGeneratedStillsWhenServerPreviewsAreMissing() async {
        let primary = FakeThumbnailLoader()
        let extractor = FakeScrubStillExtractor(image: makeSolidCGImage(color: .red))
        let loader = FallbackScrubThumbnailLoader(
            primary: primary,
            fallback: GeneratedScrubThumbnailLoader(extractor: extractor)
        )

        let whileAdvertised = await loader.thumbnail(forSeconds: 8)
        XCTAssertNil(whileAdvertised)
        XCTAssertTrue(extractor.requestedSeconds.isEmpty)

        primary.isPermanentlyUnavailable = true
        let afterMissing = await loader.thumbnail(forSeconds: 8)
        XCTAssertNotNil(afterMissing)
        XCTAssertNotNil(loader.cachedThumbnail(forSeconds: 9))
        XCTAssertFalse(loader.isPermanentlyUnavailable)
        XCTAssertEqual(primary.requestCount, 1)
        XCTAssertEqual(extractor.requestedSeconds, [8])
    }

    func testGeneratedLoaderSnapsToGridAndCachesFrames() async {
        let extractor = FakeScrubStillExtractor(image: makeSolidCGImage(color: .red))
        let loader = GeneratedScrubThumbnailLoader(extractor: extractor)

        let first = await loader.thumbnail(forSeconds: 5.3)
        let sameCell = await loader.thumbnail(forSeconds: 5.9)
        XCTAssertNotNil(first)
        XCTAssertNotNil(sameCell)
        XCTAssertNotNil(loader.cachedThumbnail(forSeconds: 4.1))
        XCTAssertNil(loader.cachedThumbnail(forSeconds: 6.0))
        let nextCell = await loader.thumbnail(forSeconds: 6.0)
        XCTAssertNotNil(nextCell)

        // Both drags inside one 2-second cell decode once, at the cell start.
        XCTAssertEqual(extractor.requestedSeconds, [4, 6])
        XCTAssertEqual(extractor.requestedWidths, [GeneratedScrubThumbnailLoader.maxWidth, GeneratedScrubThumbnailLoader.maxWidth])
    }

    func testGeneratedLoaderRetriesAfterUnavailableFrame() async {
        let extractor = FakeScrubStillExtractor(image: makeSolidCGImage(color: .red))
        extractor.pendingFailures = 1
        let loader = GeneratedScrubThumbnailLoader(extractor: extractor)

        let unavailable = await loader.thumbnail(forSeconds: 10)
        XCTAssertNil(unavailable)
        XCTAssertNil(loader.cachedThumbnail(forSeconds: 10))
        let retried = await loader.thumbnail(forSeconds: 10)
        XCTAssertNotNil(retried)
        XCTAssertEqual(extractor.requestedSeconds, [10, 10])
    }

    func testCoordinatorCoalescesPendingSamplesInTheSameCell() async throws {
        let started = expectation(description: "first decode started")
        let delivered = expectation(description: "latest update delivered")
        let extractor = SuspendedScrubStillExtractor { started.fulfill() }
        let coordinator = try XCTUnwrap(ScrubPreviewCoordinator(source: nil, generatedStills: extractor))
        coordinator.onImageChange = { image in
            if image != nil { delivered.fulfill() }
        }
        coordinator.update(for: 5.3)
        await fulfillment(of: [started], timeout: 2)
        coordinator.update(for: 5.5)
        await Task.yield()
        coordinator.update(for: 5.9)
        await Task.yield()
        extractor.finish(with: makeSolidCGImage(color: .red))
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(extractor.requestedSeconds, [4])
        coordinator.onImageChange = nil
        XCTAssertTrue(coordinator.update(for: 5.1))
    }

    func testGeneratedLoaderBoundsCacheAndDoesNotPrefetch() async {
        let extractor = FakeScrubStillExtractor(image: makeSolidCGImage(color: .red))
        let loader = GeneratedScrubThumbnailLoader(extractor: extractor)
        loader.prefetch()
        XCTAssertTrue(extractor.requestedSeconds.isEmpty)
        for cell in 0...90 {
            _ = await loader.thumbnail(forSeconds: Double(cell * 2))
        }
        XCTAssertNil(loader.cachedThumbnail(forSeconds: 0))
        XCTAssertNotNil(loader.cachedThumbnail(forSeconds: 2))
        XCTAssertNotNil(loader.cachedThumbnail(forSeconds: 180))
        XCTAssertEqual(extractor.requestedSeconds.count, 91)
    }

    func testCoordinatorNeedsServerPreviewsOrGeneratedStills() {
        XCTAssertNil(ScrubPreviewCoordinator(source: nil))
        XCTAssertNotNil(ScrubPreviewCoordinator(
            source: nil,
            generatedStills: FakeScrubStillExtractor(image: nil)
        ))
    }

    func testCoordinatorFallsBackToGeneratedStillsForUnusableServerPreviews() async {
        let extractor = FakeScrubStillExtractor(image: makeSolidCGImage(color: .blue))
        let unusable = TrickplayManifest(
            thumbnailWidth: 10,
            thumbnailHeight: 10,
            tileColumns: 1,
            tileRows: 1,
            thumbnailCount: 0,
            intervalMs: 10_000,
            tileResources: []
        )
        guard let coordinator = ScrubPreviewCoordinator(
            source: .tiled(unusable),
            generatedStills: extractor
        ) else {
            return XCTFail("expected generated-stills fallback")
        }
        let delivered = expectation(description: "generated still delivered")
        coordinator.onImageChange = { image in
            if image != nil { delivered.fulfill() }
        }

        XCTAssertFalse(coordinator.update(for: 31))
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(extractor.requestedSeconds, [30])
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLSessionStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func scrubLocator(
        provider: ProviderKind,
        path: String
    ) throws -> AuthenticatedHTTPPlaybackLocator {
        try AuthenticatedHTTPPlaybackLocator(
            provider: provider,
            accountID: "account",
            credentialRevision: CredentialRevision(),
            itemID: "item",
            deliveryMode: .directFile,
            purpose: .scrubPreview,
            resource: try AuthenticatedHTTPResource(
                pathBase: .configuredBaseURL,
                path: path
            )
        )
    }

    private func makeTileImageData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        }
        guard let data = image.pngData() else { throw NSError(domain: "ScrubPreviewLoaderTests", code: 1) }
        return data
    }

    private func makeJPEGData(color: UIColor) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }

    private func makeSolidCGImage(color: UIColor) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return image.cgImage!
    }

    private func makeBIFData(
        frameIntervalMs: UInt32 = 1_000,
        frames: [Data]
    ) throws -> Data {
        var bytes = [UInt8]()

        func appendU32(_ value: UInt32) {
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 24) & 0xFF))
        }

        bytes.append(contentsOf: BIFIndex.magic)
        appendU32(0) // version
        appendU32(UInt32(frames.count))
        appendU32(frameIntervalMs)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 64 - bytes.count))

        let indexEntries = frames.count + 1
        var offsets: [UInt32] = []
        offsets.reserveCapacity(indexEntries)
        var runningOffset = UInt32(64 + indexEntries * 8)
        for frame in frames {
            offsets.append(runningOffset)
            runningOffset += UInt32(frame.count)
        }
        offsets.append(runningOffset)

        for index in 0..<frames.count {
            appendU32(UInt32(index))
            appendU32(offsets[index])
        }
        appendU32(0xFFFF_FFFF)
        appendU32(offsets[frames.count])

        for frame in frames {
            bytes.append(contentsOf: frame)
        }
        return Data(bytes)
    }
}

@MainActor
private final class RecordingScrubResolver:
    AuthenticatedHTTPResourceResolving
{
    let url: URL
    private(set) var locators: [AuthenticatedHTTPPlaybackLocator] = []

    init(url: URL) {
        self.url = url
    }

    func resolve(
        _ locator: AuthenticatedHTTPPlaybackLocator
    ) async throws -> URL {
        locators.append(locator)
        return url
    }
}

@MainActor
private final class FakeThumbnailLoader: ScrubThumbnailProviding {
    var isPermanentlyUnavailable = false
    private(set) var requestCount = 0

    func thumbnail(forSeconds seconds: TimeInterval) async -> CGImage? {
        requestCount += 1
        return nil
    }

    func cachedThumbnail(forSeconds seconds: TimeInterval) -> CGImage? { nil }
}

@MainActor
private final class FakeScrubStillExtractor: ScrubStillExtracting {
    private let image: CGImage?
    var pendingFailures = 0
    private(set) var requestedSeconds: [TimeInterval] = []
    private(set) var requestedWidths: [Int] = []

    init(image: CGImage?) {
        self.image = image
    }

    func thumbnail(atSeconds seconds: TimeInterval, maxWidth: Int) async -> CGImage? {
        requestedSeconds.append(seconds)
        requestedWidths.append(maxWidth)
        if pendingFailures > 0 {
            pendingFailures -= 1
            return nil
        }
        return image
    }
}

@MainActor
private final class SuspendedScrubStillExtractor: ScrubStillExtracting {
    private let onStart: () -> Void
    private var waiters: [CheckedContinuation<CGImage?, Never>] = []
    private var finishedImage: CGImage?
    private(set) var requestedSeconds: [TimeInterval] = []

    init(onStart: @escaping () -> Void) { self.onStart = onStart }

    func thumbnail(atSeconds seconds: TimeInterval, maxWidth: Int) async -> CGImage? {
        requestedSeconds.append(seconds)
        if let finishedImage { return finishedImage }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if requestedSeconds.count == 1 { onStart() }
        }
    }

    func finish(with image: CGImage) {
        finishedImage = image
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume(returning: image) }
    }
}

private struct URLStubResponse {
    let statusCode: Int
    let data: Data
}

private final class URLSessionStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [URL: [URLStubResponse]] = [:]
    private static var requestCounts: [URL: Int] = [:]

    static func setResponses(_ queue: [URLStubResponse], for url: URL) {
        lock.lock()
        responses[url] = queue
        lock.unlock()
    }

    static func requestCount(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts[url, default: 0]
    }

    static func reset() {
        lock.lock()
        responses = [:]
        requestCounts = [:]
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let nextResponse: URLStubResponse = {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            Self.requestCounts[url, default: 0] += 1
            guard var queue = Self.responses[url], !queue.isEmpty else {
                return URLStubResponse(statusCode: 404, data: Data())
            }
            let first = queue.removeFirst()
            Self.responses[url] = queue
            return first
        }()

        let response = HTTPURLResponse(
            url: url,
            statusCode: nextResponse.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: nextResponse.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
