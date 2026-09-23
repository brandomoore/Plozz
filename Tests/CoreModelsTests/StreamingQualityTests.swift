import Foundation
import XCTest
@testable import CoreModels

final class StreamingQualityTests: XCTestCase {
    func testLegacyPresetsKeepTheirExactJSONStrings() throws {
        let names = ["original", "hd1080High", "hd1080", "hd720High", "hd720", "sd480", "low"]
        XCTAssertEqual(StreamingQuality.allCases.count, names.count)
        for (quality, name) in zip(StreamingQuality.allCases, names) {
            let legacy = Data("\"\(name)\"".utf8)
            XCTAssertEqual(try JSONDecoder().decode(StreamingQuality.self, from: legacy), quality)
            XCTAssertEqual(try JSONEncoder().encode(quality), legacy)
        }
        let data = Data(#"{"streaming":{"local":"original","remote":"hd1080High","cellular":"sd480","codec":"preferHEVC","forceTranscoding":true}}"#.utf8)
        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertEqual(settings.streaming.local, .original)
        XCTAssertEqual(settings.streaming.remote, .hd1080High)
        XCTAssertEqual(settings.streaming.cellular, .sd480)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testCustomResolutionAndTotalBitrateAreIndependentSelfContainedValues() throws {
        let quality = try StreamingQuality.custom(maximumHeight: 1080, bitrateKbps: 2_000)
        XCTAssertEqual(quality.maximumHeight, 1080)
        XCTAssertEqual(quality.maximumWidth, 1920)
        XCTAssertEqual(quality.maximumBitrate, 2_000_000)
        XCTAssertEqual(quality.videoBitrate, 1_872_000)
        XCTAssertEqual(quality.audioBitrate, 128_000)
        XCTAssertEqual(quality.estimatedBytesPerHour, 900_000_000)
        XCTAssertEqual(quality, try .custom(maximumHeight: 1080, bitrateKbps: 2_000))
        XCTAssertNotEqual(quality, .hd720)
        XCTAssertNotEqual(quality, .hd1080)
        XCTAssertEqual(Set([quality, try .custom(maximumHeight: 1080, bitrateKbps: 2_000)]).count, 1)
        XCTAssertEqual(Set([quality, try .custom(maximumHeight: 720, bitrateKbps: 2_000)]).count, 2)

        let encoded = try JSONEncoder().encode(quality)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "custom")
        XCTAssertEqual(object["maximumHeight"] as? Int, 1080)
        XCTAssertEqual(object["bitrateKbps"] as? Int, 2_000)
        XCTAssertEqual(try JSONDecoder().decode(StreamingQuality.self, from: encoded), quality)
        XCTAssertTrue(quality.permitsOriginal(bitrate: 2_000_000, width: 1920, height: 1080))
        XCTAssertTrue(quality.permitsOriginal(bitrate: 1_000_000, width: 640, height: 360))
        XCTAssertFalse(quality.permitsOriginal(bitrate: 2_000_001, width: 640, height: 360))
        XCTAssertFalse(quality.permitsOriginal(bitrate: 1_000_000, width: 3840, height: 2160))
        XCTAssertFalse(quality.permitsOriginal(bitrate: nil, width: 640, height: 360))
    }

    func testCustomValidationAcceptsEverySupportedHeightAndOnlyRepresentableBudgets() throws {
        XCTAssertEqual(CustomStreamingQuality.supportedHeights, [240, 480, 720, 1080, 1440, 2160])
        for height in CustomStreamingQuality.supportedHeights {
            for bitrate in [129, 2_000, CustomStreamingQuality.maximumBitrateKbps] {
                let quality = try StreamingQuality.custom(maximumHeight: height, bitrateKbps: bitrate)
                XCTAssertEqual(quality.maximumHeight, height)
                XCTAssertEqual(quality.videoBitrate, bitrate * 1_000 - 128_000)
                XCTAssertEqual(quality.estimatedBytesPerHour, Int64(bitrate) * 450_000)
                XCTAssertNoThrow(try quality.validate())
            }
        }
        for bitrate in [Int.min, -1, 0, 128] {
            XCTAssertThrowsError(try StreamingQuality.custom(maximumHeight: 1080, bitrateKbps: bitrate)) {
                XCTAssertEqual($0 as? StreamingQualityValidationError, .bitrateTooLow)
            }
        }
        for bitrate in [CustomStreamingQuality.maximumBitrateKbps + 1, Int.max / 1_000, Int.max] {
            XCTAssertThrowsError(try StreamingQuality.custom(maximumHeight: 1080, bitrateKbps: bitrate)) {
                XCTAssertEqual($0 as? StreamingQualityValidationError, .bitrateTooHigh)
            }
        }
        for height in [Int.min, 0, 360, 1081, 4320, Int.max] {
            XCTAssertThrowsError(try StreamingQuality.custom(maximumHeight: height, bitrateKbps: 2_000)) {
                XCTAssertEqual($0 as? StreamingQualityValidationError, .unsupportedResolution)
            }
        }
    }

    func testCustomDraftRejectsIncompleteFractionalAndOverflowingTextWithoutChangingSelection() throws {
        let original = try StreamingQuality.custom(maximumHeight: 1080, bitrateKbps: 2_000)
        var draft = StreamingQualityDraft(quality: original)
        for text in ["", " ", "2.5", "2,000", "-1", "+2000", "two thousand"] {
            draft.bitrateKbps = text
            XCTAssertEqual(draft.validationError, .invalidBitrate)
            XCTAssertThrowsError(try draft.validatedQuality())
        }
        draft.bitrateKbps = "128"
        XCTAssertEqual(draft.validationError, .bitrateTooLow)
        draft.bitrateKbps = String(repeating: "9", count: 100)
        XCTAssertEqual(draft.validationError, .bitrateTooHigh)
        XCTAssertEqual(original.maximumBitrate, 2_000_000)
        draft.bitrateKbps = "3000"
        XCTAssertEqual(try draft.validatedQuality(), try .custom(maximumHeight: 1080, bitrateKbps: 3_000))
        draft.maximumHeight = 2160
        XCTAssertEqual(try draft.validatedQuality(), try .custom(maximumHeight: 2160, bitrateKbps: 3_000))
        XCTAssertEqual(StreamingQualityDraft(quality: original).bitrateKbps, "2000",
                       "Cancel/reopen must start from the saved selection, not a shared draft")
    }

    @MainActor
    func testCustomDefaultsSurviveRecreationWithIndependentProfilesConnectionsAndVideoOverrides() throws {
        let suite = "custom-streaming-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primaryStore = PlaybackSettingsStore(defaults: defaults)
        let guestStore = PlaybackSettingsStore(defaults: defaults, namespace: "guest")
        let primary = PlaybackSettingsModel(store: primaryStore)
        let guest = PlaybackSettingsModel(store: guestStore)
        let local = try StreamingQuality.custom(maximumHeight: 2160, bitrateKbps: 20_000)
        let remote = try StreamingQuality.custom(maximumHeight: 1080, bitrateKbps: 2_000)
        let cellular = try StreamingQuality.custom(maximumHeight: 480, bitrateKbps: 600)
        primary.settings.streaming.local = local
        primary.settings.streaming.remote = remote
        primary.settings.streaming.cellular = cellular
        guest.settings.streaming.local = try .custom(maximumHeight: 720, bitrateKbps: 1_000)
        let restored = PlaybackSettingsModel(store: primaryStore).settings.streaming
        XCTAssertEqual(restored.options(for: .local).quality, local)
        XCTAssertEqual(restored.options(for: .remote).quality, remote)
        XCTAssertEqual(restored.options(for: .cellular).quality, cellular)
        XCTAssertEqual(PlaybackSettingsModel(store: guestStore).settings, guest.settings)
        XCTAssertNotEqual(guest.settings.streaming.local, local)
        var override = restored.options(for: .remote)
        override.quality = try .custom(maximumHeight: 1440, bitrateKbps: 5_000)
        XCTAssertEqual(primaryStore.load().streaming.remote, remote)
        XCTAssertEqual(restored.options(for: .remote).quality, remote)
        XCTAssertNotEqual(override.quality, remote)
        XCTAssertNotNil(defaults.data(forKey: "com.plozz.playbackSettings"),
                        "The default profile keeps its unsuffixed legacy key")
    }

    func testMalformedCustomDataFailsClosedAndSurvivesOtherPreferenceWrites() throws {
        let payloads = [
            #"{"type":"custom","maximumHeight":1080,"bitrateKbps":128}"#,
            #"{"type":"custom","maximumHeight":360,"bitrateKbps":2000}"#,
            #"{"type":"custom","maximumHeight":1080,"bitrateKbps":2147484}"#,
            #"{"type":"custom","maximumHeight":1080,"bitrateKbps":999999999999999999999999}"#,
            #"{"type":"custom","maximumHeight":1080,"bitrateKbps":"2000"}"#,
            #"{"type":"custom","maximumHeight":1080,"bitrateKbps":2000.5}"#,
            #"{"type":"custom","maximumHeight":"1080","bitrateKbps":2000}"#,
            #"{"type":"custom","maximumHeight":null,"bitrateKbps":2000}"#,
            #"{"type":"custom","maximumHeight":true,"bitrateKbps":2000}"#,
            #"{"type":"custom","maximumHeight":[],"bitrateKbps":2000}"#,
            #"{"type":"custom","maximumHeight":{},"bitrateKbps":2000}"#,
            #"{"type":"custom","bitrateKbps":2000}"#,
            #"{"type":"custom","maximumHeight":1080,"bitrateKbps":null}"#,
            #"{"type":"custom","maximumHeight":1080,"bitrateKbps":true}"#,
            #"{"type":"custom","maximumHeight":1080}"#,
            #""custom""#
        ]
        for payload in payloads {
            XCTAssertThrowsError(try JSONDecoder().decode(StreamingQuality.self, from: Data(payload.utf8)))
            let data = Data("""
            {"backgroundAudio":true,"streaming":{"local":\(payload),"remote":"sd480","cellular":"hd720","codec":"preferHEVC"}}
            """.utf8)
            var saved = try JSONDecoder().decode(PlaybackSettings.self, from: data)
            XCTAssertTrue(saved.backgroundAudio)
            XCTAssertEqual(saved.streaming.remote, .sd480)
            XCTAssertEqual(saved.streaming.cellular, .hd720)
            XCTAssertEqual(saved.streaming.codec, .preferHEVC)
            let quality = saved.streaming.local
            XCTAssertNotEqual(quality, .original)
            XCTAssertNotNil(quality.validationError)
            XCTAssertFalse(quality.permitsOriginal(bitrate: 100_000, width: 320, height: 180))
            XCTAssertThrowsError(try quality.validate()) {
                XCTAssertEqual($0 as? StreamingQualityError, .invalidQuality(quality.validationError!))
            }
            saved.backgroundAudio = false
            let recreated = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(saved))
            XCTAssertEqual(recreated.streaming.local, quality)
            saved.streaming.local = try .custom(maximumHeight: 1080, bitrateKbps: 2_000)
            XCTAssertNil(saved.streaming.local.validationError)
        }
    }

    @MainActor
    func testInvalidSavedCustomQualityRemainsAnErrorAfterSettingsModelRecreation() throws {
        let suite = "invalid-custom-streaming-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"streaming":{"local":{"type":"custom","maximumHeight":1080,"bitrateKbps":0}}}"#.utf8),
                     forKey: "com.plozz.playbackSettings")
        let store = PlaybackSettingsStore(defaults: defaults)
        let model = PlaybackSettingsModel(store: store)
        XCTAssertEqual(model.settings.streaming.local.validationError, .bitrateTooLow)
        model.settings.backgroundAudio = true
        let recreated = PlaybackSettingsModel(store: store)
        XCTAssertEqual(recreated.settings.streaming.local.validationError, .bitrateTooLow)
        XCTAssertTrue(recreated.settings.backgroundAudio)
        XCTAssertThrowsError(try recreated.settings.streaming.options(for: .local).quality.validate())
    }

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
