import Foundation
import XCTest
@testable import CoreModels

final class StreamingQualityTests: XCTestCase {
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
        XCTAssertEqual(StreamingCodecPreference.preferHEVC.codecs(supportsHEVC: true), ["hevc", "h264"])
        XCTAssertEqual(StreamingCodecPreference.preferHEVC.codecs(supportsHEVC: false), ["h264"])
        XCTAssertEqual(StreamingCodecPreference.preferH264.codecs(supportsHEVC: true), ["h264"])
    }
}
