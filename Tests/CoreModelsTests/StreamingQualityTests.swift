import Foundation
import XCTest
@testable import CoreModels

final class StreamingQualityTests: XCTestCase {
    func testAutomaticRetriesTheOtherKnownCodecOnlyOnce() {
        XCTAssertEqual(StreamingCodecRetryPolicy.next(
            preference: .automatic, selectedCodec: .h264, supportsHEVC: true, alreadyRetried: false
        ), .preferHEVC)
        XCTAssertEqual(StreamingCodecRetryPolicy.next(
            preference: .automatic, selectedCodec: .hevc, supportsHEVC: true, alreadyRetried: false
        ), .preferH264)
        XCTAssertNil(StreamingCodecRetryPolicy.next(
            preference: .automatic, selectedCodec: .h264, supportsHEVC: false, alreadyRetried: false
        ))
        for preference in StreamingCodecPreference.allCases {
            XCTAssertNil(StreamingCodecRetryPolicy.next(
                preference: preference, selectedCodec: .h264, supportsHEVC: true, alreadyRetried: true
            ))
        }
        XCTAssertNil(StreamingCodecRetryPolicy.next(
            preference: .preferH264, selectedCodec: .h264, supportsHEVC: true, alreadyRetried: false
        ))
        XCTAssertNil(StreamingCodecRetryPolicy.next(
            preference: .preferHEVC, selectedCodec: .h264, supportsHEVC: true, alreadyRetried: false
        ), "Do not repeat H.264 when the server already substituted it for a HEVC request")
        var message = StreamingPreparationPhase.requesting.message(
            provider: "Emby", transcoding: true, usingH264Fallback: false, usingHEVCFallback: true
        )
        message.locale = Locale(identifier: "en_US")
        XCTAssertEqual(String(localized: message), "Trying HEVC…")
    }

    func testPreparationCopyIsAShortStatusNotAnExplanation() {
        let cases: [(StreamingPreparationPhase, Bool, Bool, String)] = [
            (.requesting, false, false, "Connecting to Plex…"),
            (.requesting, true, true, "Trying H.264…"),
            (.opening, true, false, "Transcoding…"),
            (.opening, false, false, "Opening video…"),
            (.waitingForVideo, true, false, "Buffering…")
        ]
        for (phase, transcoding, fallback, expected) in cases {
            var message = phase.message(provider: "Plex", transcoding: transcoding, usingH264Fallback: fallback)
            message.locale = Locale(identifier: "en_US")
            XCTAssertEqual(String(localized: message), expected)
        }
    }

    func testDefaultsAndLegacyPlaybackSettingsUseBalancedCellularOnly() throws {
        let old = try JSONDecoder().decode(PlaybackSettings.self, from: Data(#"{"backgroundAudio":true}"#.utf8))
        XCTAssertTrue(old.backgroundAudio)
        XCTAssertEqual(old.streaming.local, .original)
        XCTAssertEqual(old.streaming.remote, .original)
        XCTAssertEqual(old.streaming.cellular, .hd720)
        XCTAssertEqual(old.streaming.options(for: .cellular).quality.maximumBitrate, 2_000_000)
        XCTAssertFalse(old.streaming.forceTranscoding)
    }

    func testMalformedOrFutureValuesPreserveOtherStreamingPreferences() throws {
        let data = Data(#"{"local":"sd480","remote":"future","cellular":null,"codec":"preferH264","forceTranscoding":true}"#.utf8)
        let settings = try JSONDecoder().decode(StreamingQualitySettings.self, from: data)
        XCTAssertEqual(settings.local, .sd480)
        XCTAssertEqual(settings.remote, .original)
        XCTAssertEqual(settings.cellular, .hd720)
        XCTAssertEqual(settings.codec, .preferH264)
        XCTAssertTrue(settings.forceTranscoding)
    }

    func testStreamingPreferencesRoundTripAndStayProfileScoped() throws {
        let name = "streaming-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = PlaybackSettingsStore(defaults: defaults, namespace: "first")
        let second = PlaybackSettingsStore(defaults: defaults, namespace: "second")
        var settings = PlaybackSettings.default
        settings.streaming.cellular = .sd480
        settings.streaming.codec = .preferHEVC
        settings.streaming.forceTranscoding = true
        first.save(settings)
        XCTAssertEqual(first.load(), settings)
        XCTAssertEqual(second.load(), .default)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testCellularAndUnknownPathsCannotBeMisclassifiedAsLocalWiFi() {
        for path in [StreamingNetwork.cellular, .unknown, .offline] {
            XCTAssertEqual(StreamingConnection.resolve(network: path, locality: .local), .cellular)
        }
        XCTAssertEqual(StreamingConnection.resolve(network: .wifi, locality: .local), .local)
        XCTAssertEqual(StreamingConnection.resolve(network: .wired, locality: .remote), .remote)
        XCTAssertEqual(StreamingConnection.resolve(network: .wifi, locality: .unknown), .remote)
    }

    func testStreamingNetworkClassifiesActualInterfacesInsteadOfPathCost() {
        XCTAssertEqual(StreamingNetwork.classify(
            isSatisfied: true, usesCellular: false, usesWiFi: true, usesEthernet: false
        ), .wifi)
        XCTAssertEqual(StreamingNetwork.classify(
            isSatisfied: true, usesCellular: false, usesWiFi: false, usesEthernet: true
        ), .wired)
        XCTAssertEqual(StreamingNetwork.classify(
            isSatisfied: true, usesCellular: true, usesWiFi: true, usesEthernet: false
        ), .cellular, "An explicitly cellular path must not evade the cellular limit")
        XCTAssertEqual(StreamingNetwork.classify(
            isSatisfied: true, usesCellular: false, usesWiFi: false, usesEthernet: false
        ), .unknown, "Do not guess a tunneled path's underlying interface")
        XCTAssertEqual(StreamingNetwork.classify(
            isSatisfied: false, usesCellular: false, usesWiFi: true, usesEthernet: false
        ), .offline)
    }

    @MainActor
    func testSavedLocalDefaultSurvivesModelRecreationAndProfileSwitching() throws {
        let name = "streaming-local-default-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let primary = PlaybackSettingsStore(defaults: defaults)
        let guest = PlaybackSettingsStore(defaults: defaults, namespace: "guest")
        let model = PlaybackSettingsModel(store: primary)
        model.settings.streaming.local = .low
        model.settings.streaming.codec = .preferHEVC
        model.settings.streaming.forceTranscoding = true
        let guestModel = PlaybackSettingsModel(store: guest)
        guestModel.settings.streaming.local = .sd480

        let restored = PlaybackSettingsModel(store: primary).settings.streaming
        XCTAssertEqual(restored.local, .low)
        XCTAssertEqual(restored.remote, .original)
        XCTAssertEqual(restored.cellular, .hd720)
        XCTAssertEqual(PlaybackSettingsModel(store: guest).settings.streaming.local, .sd480)

        let network = StreamingNetwork.classify(
            isSatisfied: true, usesCellular: false, usesWiFi: true, usesEthernet: false
        )
        let locality = SourceLocalityClassifier.classify(host: "192.168.68.71")
        let connection = StreamingConnection.resolve(network: network, locality: locality)
        XCTAssertEqual(connection, .local)
        let options = restored.options(for: connection)
        XCTAssertEqual(options.quality, .low)
        XCTAssertEqual(options.quality.maximumBitrate, 500_000)
        XCTAssertEqual(options.codec, .preferHEVC)
        XCTAssertTrue(options.forceTranscoding)

        var videoOverride = options
        videoOverride.quality = .hd720
        XCTAssertEqual(videoOverride.quality, .hd720)
        XCTAssertEqual(primary.load().streaming.local, .low,
                       "A current-video option value must not replace the saved profile default")
    }

    func testEveryPresetKeepsAudioInsideItsTotalBudgetAndShowsAnHonestEstimate() throws {
        for quality in StreamingQuality.allCases where quality != .original {
            let total = try XCTUnwrap(quality.maximumBitrate)
            XCTAssertEqual(try XCTUnwrap(quality.videoBitrate) + quality.audioBitrate, total)
            XCTAssertEqual(quality.estimatedBytesPerHour, Int64(total) * 450)
            XCTAssertGreaterThan(try XCTUnwrap(quality.maximumWidth), 0)
        }
        XCTAssertEqual(StreamingQuality.hd720.estimatedBytesPerHour, 900_000_000)
        XCTAssertNil(StreamingQuality.original.maximumBitrate)
    }

    func testDirectPlayRequiresKnownFactsInsideEveryLimit() {
        let quality = StreamingQuality.hd720
        XCTAssertTrue(quality.permitsOriginal(bitrate: 2_000_000, width: 1280, height: 720))
        XCTAssertFalse(quality.permitsOriginal(bitrate: 2_000_001, width: 1280, height: 720))
        XCTAssertFalse(quality.permitsOriginal(bitrate: 1_000_000, width: 1920, height: 1080))
        XCTAssertFalse(quality.permitsOriginal(bitrate: nil, width: 1280, height: 720))
        XCTAssertFalse(quality.permitsOriginal(bitrate: 1_000_000, width: nil, height: nil))
        XCTAssertTrue(StreamingQuality.original.permitsOriginal(bitrate: nil, width: nil, height: nil))
    }

    func testHEVCIsAPreferenceWithCompatibleFallback() {
        XCTAssertEqual(StreamingCodecPreference.automatic.codecs(supportsHEVC: true), ["hevc", "h264"])
        XCTAssertEqual(StreamingCodecPreference.preferHEVC.codecs(supportsHEVC: true), ["hevc"])
        XCTAssertEqual(StreamingCodecPreference.preferHEVC.codecs(supportsHEVC: false), ["h264"])
        XCTAssertEqual(StreamingCodecPreference.preferH264.codecs(supportsHEVC: true), ["h264"])
        XCTAssertEqual(StreamingCodecPreference.automatic.codecs(supportsHEVC: false), ["h264"])
    }
}
