import AetherEngine
import CoreModels
import FeaturePlayback
import XCTest
@testable import EnginePlozzigen

@MainActor
final class LosslessAudioPreferenceTests: XCTestCase {
    func testNewAndUpgradingDevicesUseLosslessForEverySourceChannelCount() throws {
        let engine = try PlozzigenVideoEngine(losslessAudioPreference: {
            LosslessAudioSettingsStore.defaultEnabled
        })
        defer { engine.stop() }
        for channels in [0, 1, 2, 6, 7, 8] {
            var request = request
            request.sourceMetadata = .init(audio: .init(codec: "dts", channels: channels))
            XCTAssertEqual(engine.onDemandLoadOptions(for: request).audioBridgeMode, .lossless)
        }
        XCTAssertEqual(PlozzigenVideoEngine.onDemandLoadOptions().audioBridgeMode, .lossless)
        XCTAssertEqual(PlozzigenVideoEngine.liveLoadOptions(httpHeaders: [:]).audioBridgeMode, .lossless)
    }

    func testEachNewPlaybackReadsCurrentDeviceChoiceForAllProvidersAndKnownOrMissingMetadata() throws {
        let suite = "LosslessAudioPreferenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LosslessAudioSettingsStore(defaults: defaults)
        let engine = try PlozzigenVideoEngine(losslessAudioPreference: { store.load() })
        defer { engine.stop() }
        let earlier = engine.onDemandLoadOptions(for: request)
        for enabled in [false, true] {
            store.save(enabled)
            for provider: ProviderKind in [.jellyfin, .emby, .plex, .silo, .mediaShare] {
                for channels: Int? in [nil, 2, 6, 8] {
                    var request = request
                    request.sourceProvider = provider
                    request.sourceMetadata = .init(audio: .init(codec: "dts", channels: channels))
                    XCTAssertEqual(engine.onDemandLoadOptions(for: request).audioBridgeMode,
                                   enabled ? .lossless : .surroundCompat)
                }
            }
            XCTAssertEqual(engine.liveLoadOptions(httpHeaders: [:]).audioBridgeMode,
                           enabled ? .lossless : .surroundCompat)
        }
        XCTAssertEqual(earlier.audioBridgeMode, .lossless, "An existing session's options do not mutate.")
    }

    func testCompatibilityChoiceAlsoAppliesToDownloadsPreviewsAndSharedPlayers() throws {
        let engine = try PlozzigenVideoEngine(losslessAudioPreference: { false })
        defer { engine.stop() }
        var local = request
        local.streamURL = URL(fileURLWithPath: "/fixture/movie.mkv")
        XCTAssertEqual(engine.onDemandLoadOptions(for: local).audioBridgeMode, .surroundCompat)
        for policy in [
            LiveChannelOutputPolicy(isAudible: false),
            .init(isAudible: true, sharesAudioSession: true)
        ] {
            let options = engine.onDemandLoadOptions(for: request, outputPolicy: policy)
            XCTAssertEqual(options.audioBridgeMode, .surroundCompat)
            XCTAssertEqual(options.objectAudioRendering, .off)
        }
    }

    func testLiveStreamsRetainTheirExistingDeliveryAndBufferingPolicyWithEitherAudioChoice() {
        for enabled in [false, true] {
            for suffix in ["ts", "m3u8"] {
                let options = PlozzigenVideoEngine.liveLoadOptions(
                    httpHeaders: ["X-Fixture": "test"],
                    url: URL(string: "https://example.invalid/live.\(suffix)"),
                    buffer: .tenSeconds, losslessAudioEnabled: enabled
                )
                XCTAssertEqual(options.audioBridgeMode, enabled ? .lossless : .surroundCompat)
                XCTAssertTrue(options.isLive)
                XCTAssertEqual(options.nativeRemoteHLS, suffix == "m3u8")
                XCTAssertEqual(options.liveEdgeCushionSeconds, 10)
                XCTAssertEqual(options.httpHeaders, ["X-Fixture": "test"])
                XCTAssertEqual(options.objectAudioRendering, .off)
            }
        }
    }

    private var request: PlaybackRequest {
        PlaybackRequest(
            item: MediaItem(id: "movie", title: "Fixture", kind: .movie),
            streamURL: URL(string: "https://example.invalid/movie.mkv")!
        )
    }
}
