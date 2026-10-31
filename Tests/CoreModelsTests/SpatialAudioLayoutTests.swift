import XCTest
@testable import CoreModels

final class SpatialAudioLayoutTests: XCTestCase {
    func testDefaultAndSupportedLayouts() {
        XCTAssertEqual(SpatialAudioLayout.default, .nineOneSix)
        XCTAssertEqual(SpatialAudioLayout.allCases.map(\.rawValue),
                       ["5.1.2", "5.1.4", "7.1.2", "7.1.4", "9.1.6"])
        XCTAssertEqual(SpatialAudioLayout.allCases.filter(\.supportsDTSXHeights),
                       [.sevenOneFour, .nineOneSix])
    }

    func testUnconfiguredDeviceDoesNotWriteOrChangeSavedSpatialChoices() throws {
        try withDefaults { defaults in
            let store = SpatialAudioLayoutStore(defaults: defaults)
            for namespace: String? in [nil, "guest"] {
                let playback = PlaybackSettingsStore(defaults: defaults, namespace: namespace)
                for enabled in [false, true] {
                    var settings = PlaybackSettings.default
                    settings.trueHDAtmosEnabled = enabled
                    playback.save(settings)
                    XCTAssertEqual(store.load(), .nineOneSix)
                    XCTAssertEqual(playback.load().trueHDAtmosEnabled, enabled)
                    XCTAssertNil(defaults.object(forKey: SpatialAudioLayoutStore.storageKey))
                }
            }
        }
    }

    func testEveryLayoutPersistsAcrossStoreRecreation() throws {
        try withDefaults { defaults in
            for layout in SpatialAudioLayout.allCases {
                SpatialAudioLayoutStore(defaults: defaults).save(layout)
                XCTAssertEqual(SpatialAudioLayoutStore(defaults: defaults).load(), layout)
            }
        }
    }

    func testUnknownAndMalformedValuesArePreservedWhileUsingDefault() throws {
        try withDefaults { defaults in
            for value: NSObject in ["future layout" as NSString, NSNumber(value: 16), NSData(data: Data([1]))] {
                defaults.set(value, forKey: SpatialAudioLayoutStore.storageKey)
                XCTAssertEqual(SpatialAudioLayoutStore(defaults: defaults).load(), .default)
                XCTAssertEqual(defaults.object(forKey: SpatialAudioLayoutStore.storageKey) as? NSObject, value)
            }
        }
    }

    func testLayoutStaysDeviceLocalAcrossProfileTransfer() throws {
        try withDefaults { source in
            try withDefaults { target in
                let sourceStore = SpatialAudioLayoutStore(defaults: source)
                let targetStore = SpatialAudioLayoutStore(defaults: target)
                sourceStore.save(.fiveOneFour)
                targetStore.save(.sevenOneFour)
                for namespace: String? in [nil, "adult", "kids"] {
                    let snapshot = ProfileSettingsTransfer.capture(namespace: namespace, defaults: source)
                    XCTAssertNil(snapshot[SpatialAudioLayoutStore.storageKey])
                    ProfileSettingsTransfer.apply(snapshot, namespace: namespace, defaults: target)
                    XCTAssertEqual(sourceStore.load(), .fiveOneFour)
                    XCTAssertEqual(targetStore.load(), .sevenOneFour)
                }
                XCTAssertFalse(ProfileSettingsTransfer.transferableBaseKeys.contains(SpatialAudioLayoutStore.storageKey))
            }
        }
    }

    func testPCMEncodingLabelsUseKnownRenderedLayoutsRatherThanSourceMetadata() {
        for layout in SpatialAudioLayout.allCases {
            for source in ["TRUEHD Atmos", "DTS:X"] {
                let diagnostics = PlaybackDiagnostics(
                    audioCodec: "AAC", audioChannels: 2,
                    audioPipelineDescription: "\(source) → PCM \(layout.rawValue)", mode: .plozzigen
                )
                XCTAssertEqual(diagnostics.audioEncodingDescription, "Rendered to PCM")
            }
        }
        for pipeline in ["TRUEHD Atmos → PCM", "DTS:X → PCM unknown", "PCM 9.1.6"] {
            XCTAssertNil(PlaybackDiagnostics(
                audioPipelineDescription: pipeline, mode: .plozzigen
            ).audioEncodingDescription)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "SpatialAudioLayoutTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
