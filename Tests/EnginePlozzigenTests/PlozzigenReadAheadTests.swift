import CoreModels
import XCTest
@testable import EnginePlozzigen

@MainActor
final class PlozzigenReadAheadTests: XCTestCase {
    func testPresetsRequestTheExistingEngineWindowsWithoutChangingOtherOptions() {
        let expected: [Int?] = [nil, 15, 75, 150, 2_700]
        for (choice, segments) in zip(PlaybackReadAhead.allCases, expected) {
            let options = PlozzigenVideoEngine.onDemandLoadOptions(readAhead: choice)
            XCTAssertEqual(options.forwardBufferSegments, segments)
            XCTAssertEqual(options.sessionCacheByteBudget, choice == .automatic ? nil : Int.max)
            XCTAssertEqual(options.softwarePacketCacheStorage, .automatic)
            XCTAssertNil(options.liveEdgeCushionSeconds)
            XCTAssertFalse(options.isLive)
            XCTAssertNil(options.dvrWindowSeconds)
            XCTAssertFalse(options.progressiveSegmentDelivery)
            XCTAssertTrue(options.matchContentEnabled)
            XCTAssertEqual(options.audioBridgeMode, .lossless)
        }
        XCTAssertNil(PlozzigenVideoEngine.onDemandLoadOptions().forwardBufferSegments)
    }

    func testEachNewLoadReadsCurrentDevicePreferenceAndKeepsPriorOptionsUnchanged() throws {
        let suite = "PlozzigenReadAheadTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackReadAheadStore(defaults: defaults)
        let engine = try PlozzigenVideoEngine(readAheadPreference: { store.load() })
        let request = PlaybackRequest(item: item, streamURL: remoteURL)
        XCTAssertNil(engine.onDemandLoadOptions(for: request).forwardBufferSegments)
        store.save(.fiveMinutes)
        let loaded = engine.onDemandLoadOptions(for: request)
        XCTAssertEqual(loaded.forwardBufferSegments, 75)
        store.save(.maximumAvailable)
        XCTAssertEqual(loaded.forwardBufferSegments, 75)
        XCTAssertEqual(engine.onDemandLoadOptions(for: request).forwardBufferSegments, 2_700)
        store.save(.automatic)
        XCTAssertNil(engine.onDemandLoadOptions(for: request).forwardBufferSegments)
    }

    func testRemoteSourcesUseTheSamePreferenceRegardlessOfProviderOrTransport() throws {
        let engine = try PlozzigenVideoEngine(readAheadPreference: { .tenMinutes })
        for provider: ProviderKind in [.jellyfin, .emby, .plex, .silo] {
            let locator = try AuthenticatedHTTPPlaybackLocator(
                provider: provider, accountID: "account", credentialRevision: .init(),
                itemID: item.id, deliveryMode: .directFile,
                resource: AuthenticatedHTTPResource(pathBase: .serverRoot, path: "/movie.mkv")
            )
            let request = PlaybackRequest(item: item, playbackSource: .authenticatedHTTP(locator))
            XCTAssertEqual(engine.onDemandLoadOptions(for: request).forwardBufferSegments, 150)
            XCTAssertEqual(engine.onDemandLoadOptions(for: request).sessionCacheByteBudget, Int.max)
        }
        let locator = try NetworkFileLocator(
            accountID: "account", sourceID: "share", credentialRevision: .init(),
            relativePath: "movie.mkv",
            representation: RemoteFileRepresentation(
                size: 100,
                identity: RemoteFileIdentity(kind: .strongETag, value: "\"fixture\""),
                consistency: .stronglyBound
            ),
            formatHint: MediaFormatHint(container: "mkv")
        )
        let network = PlaybackRequest(item: item, playbackSource: .networkFile(locator))
        XCTAssertEqual(engine.onDemandLoadOptions(for: network).forwardBufferSegments, 150)
        XCTAssertEqual(engine.onDemandLoadOptions(for: network).sessionCacheByteBudget, Int.max)
        XCTAssertEqual(engine.onDemandLoadOptions(
            for: PlaybackRequest(item: item, streamURL: remoteURL)
        ).forwardBufferSegments, 150)
    }

    func testLocalDownloadsScheduledChannelsAndDirectPreviewConstructorsKeepDefaults() throws {
        let engine = try PlozzigenVideoEngine(readAheadPreference: { .maximumAvailable })
        let localURL = URL(fileURLWithPath: "/fixture/movie.mkv")
        let local = PlaybackRequest(item: item, streamURL: localURL)
        XCTAssertNil(engine.onDemandLoadOptions(for: local).forwardBufferSegments)
        XCTAssertNil(engine.onDemandLoadOptions(for: local).sessionCacheByteBudget)
        var scheduled = PlaybackRequest(item: item, streamURL: remoteURL)
        scheduled.suppressOrdinaryWatchReporting = true
        XCTAssertNil(engine.onDemandLoadOptions(for: scheduled).forwardBufferSegments)
        XCTAssertNil(engine.onDemandLoadOptions(for: scheduled).sessionCacheByteBudget)
        let preview = try PlozzigenVideoEngine()
        XCTAssertNil(preview.onDemandLoadOptions(
            for: PlaybackRequest(item: item, streamURL: remoteURL)
        ).forwardBufferSegments)
        for path in ["live.ts", "live.m3u8"] {
            let options = PlozzigenVideoEngine.liveLoadOptions(
                httpHeaders: [:], url: remoteURL.deletingLastPathComponent().appendingPathComponent(path)
            )
            XCTAssertTrue(options.isLive)
            XCTAssertNil(options.forwardBufferSegments)
            XCTAssertNil(options.sessionCacheByteBudget)
            XCTAssertNil(options.dvrWindowSeconds)
        }
    }

    private var item: MediaItem { MediaItem(id: "movie", title: "Fixture", kind: .movie) }
    func testVODHLSLeavesCarriageClassificationToAether() throws {
        let engine = try PlozzigenVideoEngine()
        let request = PlaybackRequest(item: item, streamURL: URL(string: "https://example.test/master.m3u8")!)
        let options = engine.onDemandLoadOptions(for: request)
        XCTAssertFalse(options.nativeRemoteHLS, "An explicit bypass skips finite HEVC-in-TS classification.")
        XCTAssertFalse(options.isLive)
    }

    private var remoteURL: URL { URL(string: "https://example.invalid/movie.mkv")! }
}
