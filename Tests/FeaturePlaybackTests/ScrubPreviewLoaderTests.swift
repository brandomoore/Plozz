#if canImport(UIKit)
import XCTest
import UIKit
import CoreModels
@testable import FeaturePlayback
@testable import TestSupportNetworking
@testable import TestSupportPerformance

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

    func testCoordinatorFinishesCurrentFrameThenDecodesOnlyLatestPosition() async throws {
        let first = expectation(description: "first extraction")
        let latest = expectation(description: "latest extraction")
        let published = expectation(description: "both useful frames published")
        published.expectedFulfillmentCount = 2
        let extractor = ControlledScrubStillExtractor()
        extractor.onStart = { seconds in
            if seconds == 10 { first.fulfill() }
            else if seconds == 30 { latest.fulfill() }
            else { XCTFail("Obsolete position decoded: \(seconds)") }
        }
        let coordinator = try XCTUnwrap(ScrubPreviewCoordinator(source: nil, generatedStills: extractor))
        defer { coordinator.clear() }
        let red = makeSolidCGImage(color: .red)
        let blue = makeSolidCGImage(color: .blue)
        coordinator.onImageChange = { if $0 != nil { published.fulfill() } }
        coordinator.update(for: 10)
        await fulfillment(of: [first], timeout: 2)
        coordinator.update(for: 20)
        coordinator.update(for: 30)
        extractor.finish(at: 10, with: red)
        await fulfillment(of: [latest], timeout: 2)
        XCTAssertTrue(coordinator.image === red)
        extractor.finish(at: 30, with: blue)
        await fulfillment(of: [published], timeout: 2)
        XCTAssertTrue(coordinator.image === blue)
        XCTAssertEqual(extractor.requestedSeconds, [10, 30])
        XCTAssertEqual(extractor.maxInFlight, 1)
        XCTAssertEqual(extractor.cancellations, 0)
    }

    func testCoordinatorDoesNotPublishAcrossAReversal() async throws {
        let first = expectation(description: "forward extraction")
        let reversed = expectation(description: "reversed extraction")
        let delivered = expectation(description: "reversed image")
        let extractor = ControlledScrubStillExtractor()
        extractor.onStart = { seconds in
            if seconds == 100 { first.fulfill() }
            else if seconds == 80 { reversed.fulfill() }
            else { XCTFail("Unexpected extraction: \(seconds)") }
        }
        let coordinator = try XCTUnwrap(ScrubPreviewCoordinator(source: nil, generatedStills: extractor))
        defer { coordinator.clear() }
        let blue = makeSolidCGImage(color: .blue)
        coordinator.onImageChange = { image in
            if let image {
                XCTAssertTrue(image === blue, "A forward frame must not overwrite the reversed preview.")
                delivered.fulfill()
            }
        }
        coordinator.update(for: 100)
        await fulfillment(of: [first], timeout: 2)
        coordinator.update(for: 120)
        coordinator.update(for: 80)
        extractor.finish(at: 100, with: makeSolidCGImage(color: .red))
        await fulfillment(of: [reversed], timeout: 2)
        XCTAssertNil(coordinator.image)
        extractor.finish(at: 80, with: blue)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(extractor.requestedSeconds, [100, 80])
    }

    func testCachedFrameCannotBeOverwrittenByAnOlderExtraction() async throws {
        let warm = expectation(description: "cache warmup")
        let cached = expectation(description: "cached frame")
        let slow = expectation(description: "slow extraction")
        let obsolete = expectation(description: "obsolete publication")
        obsolete.isInverted = true
        let extractor = ControlledScrubStillExtractor()
        extractor.onStart = { seconds in
            if seconds == 0 { warm.fulfill() } else { slow.fulfill() }
        }
        let coordinator = try XCTUnwrap(ScrubPreviewCoordinator(source: nil, generatedStills: extractor))
        defer { coordinator.clear() }
        let red = makeSolidCGImage(color: .red)
        coordinator.onImageChange = { if $0 != nil { cached.fulfill() } }
        coordinator.update(for: 0)
        await fulfillment(of: [warm], timeout: 2)
        extractor.finish(at: 0, with: red)
        await fulfillment(of: [cached], timeout: 2)
        coordinator.onImageChange = { if $0 !== red { obsolete.fulfill() } }
        coordinator.update(for: 100)
        await fulfillment(of: [slow], timeout: 2)
        XCTAssertTrue(coordinator.update(for: 0))
        extractor.finish(at: 100, with: makeSolidCGImage(color: .blue))
        await fulfillment(of: [obsolete], timeout: 0.1)
        XCTAssertTrue(coordinator.image === red)
        coordinator.onImageChange = nil
        XCTAssertTrue(coordinator.update(for: 100), "Suppressed completions still populate the cache.")
    }

    func testClearCancelsExtractionWithoutOverlappingItsReplacement() async throws {
        let first = expectation(description: "old extraction")
        let replacement = expectation(description: "replacement extraction")
        let delivered = expectation(description: "replacement image")
        let extractor = ControlledScrubStillExtractor()
        extractor.onStart = { seconds in
            if seconds == 100 { first.fulfill() } else { replacement.fulfill() }
        }
        let coordinator = try XCTUnwrap(ScrubPreviewCoordinator(source: nil, generatedStills: extractor))
        defer { coordinator.clear() }
        coordinator.update(for: 100)
        await fulfillment(of: [first], timeout: 2)
        coordinator.clear()
        let blue = makeSolidCGImage(color: .blue)
        coordinator.onImageChange = { image in
            if let image {
                XCTAssertTrue(image === blue)
                delivered.fulfill()
            }
        }
        coordinator.update(for: 200)
        XCTAssertEqual(extractor.requestedSeconds, [100])
        extractor.finish(at: 100, with: makeSolidCGImage(color: .red))
        await fulfillment(of: [replacement], timeout: 2)
        XCTAssertNil(coordinator.image)
        extractor.finish(at: 200, with: blue)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(extractor.requestedSeconds, [100, 200])
        XCTAssertEqual(extractor.maxInFlight, 1)
        XCTAssertEqual(extractor.cancellations, 1)
    }

    func testImageCallbackCanClearAndImmediatelyStartAnotherPreview() async throws {
        let first = expectation(description: "first extraction")
        let replacement = expectation(description: "replacement extraction")
        let delivered = expectation(description: "replacement image")
        let extractor = ControlledScrubStillExtractor()
        extractor.onStart = { seconds in
            if seconds == 10 { first.fulfill() } else { replacement.fulfill() }
        }
        let coordinator = try XCTUnwrap(ScrubPreviewCoordinator(source: nil, generatedStills: extractor))
        defer { coordinator.clear() }
        let red = makeSolidCGImage(color: .red)
        let blue = makeSolidCGImage(color: .blue)
        coordinator.onImageChange = { [weak coordinator] image in
            if image === red {
                coordinator?.clear()
                coordinator?.update(for: 20)
            } else if image === blue {
                delivered.fulfill()
            }
        }
        coordinator.update(for: 10)
        await fulfillment(of: [first], timeout: 2)
        extractor.finish(at: 10, with: red)
        await fulfillment(of: [replacement], timeout: 2)
        extractor.finish(at: 20, with: blue)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertTrue(coordinator.image === blue)
        XCTAssertEqual(extractor.requestedSeconds, [10, 20])
    }

    func testTransientMissKeepsTheLastUsefulPreview() async throws {
        let first = expectation(description: "initial extraction")
        let delivered = expectation(description: "initial image")
        let miss = expectation(description: "unavailable extraction")
        let blank = expectation(description: "transient blank")
        blank.isInverted = true
        let extractor = ControlledScrubStillExtractor()
        extractor.onStart = { seconds in
            if seconds == 0 { first.fulfill() } else { miss.fulfill() }
        }
        let coordinator = try XCTUnwrap(ScrubPreviewCoordinator(source: nil, generatedStills: extractor))
        defer { coordinator.clear() }
        let red = makeSolidCGImage(color: .red)
        coordinator.onImageChange = { if $0 != nil { delivered.fulfill() } }
        coordinator.update(for: 0)
        await fulfillment(of: [first], timeout: 2)
        extractor.finish(at: 0, with: red)
        await fulfillment(of: [delivered], timeout: 2)
        coordinator.onImageChange = { if $0 == nil { blank.fulfill() } }
        coordinator.update(for: 100)
        await fulfillment(of: [miss], timeout: 2)
        extractor.finish(at: 100, with: nil)
        await fulfillment(of: [blank], timeout: 0.1)
        XCTAssertTrue(coordinator.image === red)
        XCTAssertTrue(coordinator.isAvailable)
        coordinator.onImageChange = nil
    }

    func testInFlightExtractionDoesNotRetainTheCoordinator() async throws {
        let started = expectation(description: "extraction started")
        let extractor = ControlledScrubStillExtractor()
        extractor.onStart = { _ in started.fulfill() }
        var coordinator = ScrubPreviewCoordinator(source: nil, generatedStills: extractor)
        weak var weakCoordinator = coordinator
        coordinator?.update(for: 10)
        await fulfillment(of: [started], timeout: 2)
        coordinator = nil
        XCTAssertNil(weakCoordinator)
        extractor.finish(at: 10, with: nil)
    }

    func testMissingPlexBIFFallsBackWithoutStarvingDuringMotion() async throws {
        let server = try LoopbackHTTPServer { _ in .init(status: 404) }
        let url = try await server.start().appendingPathComponent("indexes/hd")
        do {
            let extractor = PacedScrubExtractor(delay: .milliseconds(80))
            let coordinator = try XCTUnwrap(ScrubPreviewCoordinator(
                source: .plexBIF(resource: .publicURL(try SecretFreeURLSource(url: url))), generatedStills: extractor
            ))
            defer { coordinator.clear() }
            var motionFrames = 0
            coordinator.onImageChange = { if $0 != nil { motionFrames += 1 } }
            for sample in 0..<24 {
                coordinator.update(for: Double(sample * 50))
                try await Task.sleep(for: .milliseconds(33))
            }
            XCTAssertGreaterThan(motionFrames, 2)
            let deadline = ContinuousClock.now + .seconds(1)
            while coordinator.image !== extractor.images[575], ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertNotNil(coordinator.image)
            XCTAssertTrue(coordinator.image === extractor.images[575])
            XCTAssertTrue(coordinator.isAvailable)
            XCTAssertEqual(extractor.maxInFlight, 1)
            XCTAssertEqual(extractor.cancellations, 0)
            let requests = await server.requests
            XCTAssertEqual(requests.count, 1, "A missing BIF must not be fetched on every input.")
            coordinator.onImageChange = nil
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    func testPerformancePlexBIFScan() async throws {
        try PerformanceProbe.requireEnabled()
        let colors = (0..<64).map { index -> UIColor in
            let red = CGFloat(32 + (index % 4) * 64) / 255
            let green = CGFloat(32 + ((index / 4) % 4) * 64) / 255
            let blue = CGFloat(32 + (index / 16) * 64) / 255
            return UIColor(red: red, green: green, blue: blue, alpha: 1)
        }
        let frames = colors.map { makeJPEGData(color: $0, size: 320) }
        let data = try makeBIFData(frameIntervalMs: 2_000, frames: (0...3_600).map { frames[$0 % 64] })
        let server = try LoopbackHTTPServer { _ in .init(body: data, delay: .milliseconds(100)) }
        let url = try await server.start().appendingPathComponent("indexes/hd")
        do {
            try await PerformanceProbe.measure(self, scenario: "seek-plex-bif") {
                let initialRequests = await server.requests.count
                let coordinator = try XCTUnwrap(ScrubPreviewCoordinator(
                    source: .plexBIF(resource: .publicURL(try SecretFreeURLSource(url: url)))
                ))
                defer { coordinator.clear() }
                var inputs = 0
                var stages = 0
                var framesDuringMotion = 0
                var moving = true
                var firstFrameMicroseconds = 0
                let began = ContinuousClock.now
                coordinator.onImageChange = { image in
                    guard image != nil else { return }
                    if firstFrameMicroseconds == 0 {
                        let elapsed = began.duration(to: .now).components
                        firstFrameMicroseconds = Int(elapsed.seconds * 1_000_000 + elapsed.attoseconds / 1_000_000_000_000)
                    }
                    if moving { framesDuringMotion += 1 }
                }
                for _ in 0..<2 {
                    for direction in [-1, 1] {
                        for level in 1...8 {
                            var position: TimeInterval = 3_600
                            let before = framesDuringMotion
                            moving = true
                            for _ in 0..<8 {
                                position = RemoteSeekScan.position(
                                    from: position, level: direction * level, elapsed: 0.033, duration: 7_200
                                )
                                coordinator.update(for: position)
                                inputs += 1
                                try await Task.sleep(for: .milliseconds(33))
                            }
                            moving = false
                            let expected = Int(position / 2) % 64
                            let deadline = ContinuousClock.now + .seconds(1)
                            while !self.matchesBIFColor(coordinator.image, index: expected),
                                  ContinuousClock.now < deadline {
                                try await Task.sleep(for: .milliseconds(5))
                            }
                            XCTAssertTrue(self.matchesBIFColor(coordinator.image, index: expected),
                                          "BIF preview must match the final target, not an earlier frame.")
                            XCTAssertEqual(coordinator.image?.width, 320)
                            XCTAssertGreaterThan(framesDuringMotion, before)
                            stages += 1
                        }
                    }
                }
                coordinator.onImageChange = nil
                let requests = await server.requests.count - initialRequests
                XCTAssertEqual(requests, 1, "Cold load plus warm rescrubbing must reuse one BIF download.")
                XCTAssertEqual(inputs, 256)
                XCTAssertEqual(stages, 32)
                XCTAssertLessThan(firstFrameMicroseconds, 500_000)
                return ["inputSamples": inputs, "stages": stages, "motionFrames": framesDuringMotion,
                        "httpRequests": requests, "bifBytes": data.count,
                        "firstFrameMicroseconds": firstFrameMicroseconds]
            }
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    private func matchesBIFColor(_ image: CGImage?, index: Int) -> Bool {
        guard let image else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        let expected = [32 + (index % 4) * 64, 32 + ((index / 4) % 4) * 64, 32 + (index / 16) * 64]
        return drawn && zip(pixel.prefix(3), expected).allSatisfy { abs(Int($0) - $1) <= 8 }
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

    private func makeJPEGData(color: UIColor, size: CGFloat = 8) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size * 9 / 16), format: format)
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size * 9 / 16))
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

@MainActor
private final class ControlledScrubStillExtractor: ScrubStillExtracting {
    var onStart: ((TimeInterval) -> Void)?
    private var waiters: [TimeInterval: CheckedContinuation<CGImage?, Never>] = [:]
    private(set) var requestedSeconds: [TimeInterval] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var cancellations = 0

    func thumbnail(atSeconds seconds: TimeInterval, maxWidth: Int) async -> CGImage? {
        requestedSeconds.append(seconds)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        let image = await withCheckedContinuation { continuation in
            waiters[seconds] = continuation
            onStart?(seconds)
        }
        if Task.isCancelled { cancellations += 1 }
        return image
    }

    func finish(at seconds: TimeInterval, with image: CGImage?) {
        guard let waiter = waiters.removeValue(forKey: seconds) else {
            XCTFail("No extraction pending at \(seconds)")
            return
        }
        waiter.resume(returning: image)
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
