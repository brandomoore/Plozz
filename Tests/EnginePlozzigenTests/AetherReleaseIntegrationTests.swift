@testable import AetherEngine
import CoreModels
import FeaturePlayback
import XCTest
@testable import EnginePlozzigen

final class AetherReleaseIntegrationTests: XCTestCase {
    func testNativeAudioMenuTrackKeepsObservedCodecChannelsAndSelectionIdentity() {
        let id = PlozzigenVideoEngine.bypassAudioIDBase + 2
        let track = PlozzigenVideoEngine.bypassAudioTrack(
            id: id, title: "English", language: "en", isDefault: true, codec: "opus", channels: 6
        )
        XCTAssertEqual(track.id, id)
        XCTAssertEqual(track.codec, "opus")
        XCTAssertEqual(track.channels, 6)
        XCTAssertTrue(track.isDefault)
        XCTAssertEqual(
            TrackLabeling.audioLabel(displayTitle: track.displayTitle, language: track.language, codec: track.codec,
                                    channels: track.channels, trackID: track.id, locale: Locale(identifier: "en")),
            TrackLabel(base: .content("English"), qualifiers: [.format("Opus 5.1")])
        )
    }

    func testResolvedEngineAndSourceCreditIdentifyPinnedReleaseIntegration() throws {
        XCTAssertEqual(AetherEngine.version, "7.51.0")
        let credit = try XCTUnwrap(PlozzAttributions.entries.first { $0.title == "AetherEngine" })
        // The metadata guard compares the exact revision with Package.resolved.
        XCTAssertNotNil(credit.detail.range(
            of: #"https://github\.com/brandomoore/AetherEngine/tree/[0-9a-f]{40}"#,
            options: .regularExpression
        ))
    }

    @MainActor
    func testPlaybackLabelUsesTheLinkedEngineVersion() throws {
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }
        XCTAssertEqual(engine.displayName, "AetherEngine v\(AetherEngine.version)")
    }

    func testProductionSpatialConversionComponentsAreBuiltIn() {
        XCTAssertTrue(AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn)
        XCTAssertTrue(AetherEngine.OptionalComponent.dtsxObjectAudio.isBuiltIn)
    }

    func testDolbyVisionComponentsRemainBuiltIn() {
        for component in [
            AetherEngine.OptionalComponent.dualLayerDolbyVision, .dolbyVisionStillReshaping
        ] {
            XCTAssertTrue(component.isBuiltIn, "\(component.traitName) must not silently become a no-op")
        }
    }

    func testEngineLivesInItsOwnDynamicFramework() {
        let engineBundle = Bundle(for: AetherEngine.self)
        XCTAssertEqual(engineBundle.bundleURL.lastPathComponent, "AetherEngine.framework")
        XCTAssertNotEqual(engineBundle.bundleURL, Bundle.main.bundleURL)
    }

    func testUpstreamDefaultsRemainOptIn() {
        let options = LoadOptions()
        XCTAssertEqual(options.stereoPresentation, .automatic)
        XCTAssertEqual(options.objectAudioRendering, .off)
        XCTAssertFalse(options.progressiveSegmentDelivery)
        XCTAssertFalse(options.preferDualLayerDolbyVision)
        XCTAssertFalse(PlozzigenVideoEngine.onDemandLoadOptions().preferDualLayerDolbyVision)
    }

    @MainActor
    func testReleasedHostControlsPreserveExistingDefaults() throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        XCTAssertTrue(engine.rendererAudioSessionActivationEnabled)
        XCTAssertFalse(engine.retainsVideoPipelineWhenBackgrounded)
        XCTAssertFalse(engine.ownsSoftwareNowPlaying)
    }

    func testRetainedSubtitleCorrectionDoesNotInventAnASSCueDuration() {
        XCTAssertNil(SubtitleCueEndOffset.resolve(
            decodedMilliseconds: 0, packetDuration: nil, timeBaseSeconds: 0.001,
            isASS: true, fallback: 5
        ))
        XCTAssertEqual(SubtitleCueEndOffset.resolve(
            decodedMilliseconds: 0, packetDuration: nil, timeBaseSeconds: 0.001,
            isASS: false, fallback: 5
        ), 5)
    }

    func testSoftwareSpatialStreamCopyUsesTheReleasedEncodingLabel() {
        let track = TrackInfo(
            id: 0, name: "English", codec: "eac3", language: "en",
            channels: 6, isDefault: true
        )
        let pipeline = AetherEngine.softwareAudioDecoderLabel(
            audioTracks: [track], activeIndex: 0, route: .compressedEAC3JOC
        )
        let diagnostics = PlaybackDiagnostics(audioPipelineDescription: pipeline, mode: .plozzigen)
        XCTAssertEqual(diagnostics.audioEncodingDescription, "No re-encoding")
    }

    func testFELPreferenceReachesOnDemandOptionsWithoutDisablingAudioForOtherSources() {
        for enabled in [false, true] {
            let options = PlozzigenVideoEngine.onDemandLoadOptions(
                dolbyVisionFELEnabled: enabled
            )
            XCTAssertEqual(options.preferDualLayerDolbyVision, enabled)
            XCTAssertEqual(options.dolbyVisionHandling, .automatic)
            XCTAssertFalse(options.isLive)
            XCTAssertTrue(options.matchContentEnabled)
            XCTAssertEqual(options.audioBridgeMode, .lossless)
            assertSpatialRendering(options, enabled: true)
        }
    }

    @MainActor
    func testResolvedRequestCarriesSpatialAndFELPreferencesIntoActualAdapterOptions() throws {
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }
        for provider in [ProviderKind.plex, .jellyfin, .emby, .mediaShare, .silo] {
            for enabled in [false, true] {
                var request = PlaybackRequest(
                    item: MediaItem(id: "fel", title: "FEL fixture", kind: .movie),
                    streamURL: URL(string: "https://media.example/movie.mkv")!
                )
                request.sourceProvider = provider
                request.trueHDAtmosEnabled = enabled
                request.dolbyVisionFELEnabled = enabled
                let options = engine.onDemandLoadOptions(for: request)
                XCTAssertEqual(options.preferDualLayerDolbyVision, enabled)
                assertSpatialRendering(options, enabled: enabled)
            }
        }
    }

    func testLivePlaybackNeverRequestsFEL() {
        for suffix in ["ts", "m3u8", ""] {
            let options = PlozzigenVideoEngine.liveLoadOptions(
                httpHeaders: [:], url: URL(string: "https://media.example/live.\(suffix)")!
            )
            XCTAssertTrue(options.isLive)
            XCTAssertFalse(options.preferDualLayerDolbyVision)
            XCTAssertEqual(options.objectAudioRendering, .off)
        }
    }

    func testOnDemandSpatialChoicePreservesChannelFallbackAndBuffering() {
        for lossless in [false, true] {
            for enabled in [false, true] {
                for buffer in PlaybackReadAhead.allCases {
                    let options = PlozzigenVideoEngine.onDemandLoadOptions(
                        losslessAudioEnabled: lossless, trueHDAtmosEnabled: enabled, readAhead: buffer
                    )
                    assertSpatialRendering(options, enabled: enabled)
                    XCTAssertEqual(options.audioBridgeMode, lossless ? .lossless : .surroundCompat)
                    XCTAssertEqual(options.sessionCacheByteBudget, buffer == .automatic ? nil : Int.max)
                    XCTAssertTrue(options.matchContentEnabled)
                    XCTAssertFalse(options.isLive)
                    XCTAssertFalse(options.progressiveSegmentDelivery)
                }
            }
        }
    }

    func testSharedLivePlayersAndMutedPreviewsKeepTheOrdinaryAudioBridge() {
        for policy in [
            LiveChannelOutputPolicy(isAudible: false),
            .init(isAudible: true, sharesAudioSession: true),
            .init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true)
        ] {
            let options = PlozzigenVideoEngine.onDemandLoadOptions(
                dolbyVisionFELEnabled: true, outputPolicy: policy
            )
            XCTAssertEqual(options.objectAudioRendering, .off)
            XCTAssertFalse(options.preferDualLayerDolbyVision)
            XCTAssertEqual(options.audioBridgeMode, .lossless)
            XCTAssertEqual(options.suppressDisplayCriteria, policy.suppressesDisplayMatching)
            XCTAssertEqual(options.matchContentEnabled, !policy.suppressesDisplayMatching)
        }
    }

    func testDisplaySuppressedPreviewDoesNotRequestFEL() {
        let options = PlozzigenVideoEngine.onDemandLoadOptions(
            dolbyVisionFELEnabled: true,
            outputPolicy: .init(isAudible: true, suppressesDisplayMatching: true)
        )
        XCTAssertFalse(options.preferDualLayerDolbyVision)
    }

    func testTrueHDLegalCreditIncludesSourceAndBothLicenses() throws {
        let credit = try XCTUnwrap(PlozzAttributions.entries.first { $0.title == "LibTrueHD" })
        XCTAssertFalse(credit.detail.contains("not linked in this build"))
        XCTAssertTrue(credit.detail.contains(
            "https://github.com/superuser404notfound/LibTrueHD/tree/3.1.0"
        ))
        XCTAssertTrue(credit.detail.contains("Quick104"))
        XCTAssertTrue(credit.detail.contains("Rainbaby"))
        XCTAssertTrue(credit.detail.contains("LibTrueHDNotices.txt"))
        XCTAssertEqual(Set(credit.licenses.map(\.label)), ["MIT", "Apache-2.0"])
    }

    private func assertSpatialRendering(
        _ options: LoadOptions, enabled: Bool, file: StaticString = #filePath, line: UInt = #line
    ) {
        #if os(tvOS) || os(iOS)
        if #available(tvOS 26.0, iOS 26.0, *), enabled {
            XCTAssertEqual(options.objectAudioRendering, .render(.l916), file: file, line: line)
            return
        }
        #endif
        XCTAssertEqual(options.objectAudioRendering, .off, file: file, line: line)
    }

    func testFFmpegCreditRemainsWithoutTheRetiredLibDTSXCredit() {
        XCTAssertFalse(PlozzAttributions.entries.contains { $0.title == "LibDTSX" })
        XCTAssertTrue(PlozzAttributions.entries.contains { $0.title == "FFmpeg" })
    }

    func testReleasedProbeCancellationAPIIsAvailable() {
        let cancellation = ProbeCancellation()
        XCTAssertFalse(cancellation.isCancelled)
        cancellation.cancel()
        XCTAssertTrue(cancellation.isCancelled)
    }

    func testInformationalRemoteHLSTracksDoNotBecomeNonworkingMenuActions() {
        let tracks = [
            TrackInfo(id: 400_000, name: "English", codec: "aac", language: "en", channels: 2, isDefault: true),
            TrackInfo(id: 400_001, name: "French", codec: "aac", language: "fr", channels: 2, isDefault: false)
        ]
        XCTAssertTrue(PlozzigenVideoEngine.selectableAudioTracks(from: tracks, route: .remoteBypass).isEmpty)
    }

    func testSelectableRoutesKeepAudioTrackIdentityAndFlags() {
        let tracks = [
            TrackInfo(
                id: 3, name: "English", codec: "eac3", language: "en",
                channels: 6, isDefault: true, isCommentary: true, isAtmos: true
            )
        ]
        for route in [VideoRoute.loopback, .software, .audio] {
            let mapped = PlozzigenVideoEngine.selectableAudioTracks(from: tracks, route: route)
            XCTAssertEqual(mapped.map(\.id), [3])
            XCTAssertEqual(mapped.first?.language, "en")
            XCTAssertEqual(mapped.first?.channels, 6)
            XCTAssertEqual(mapped.first?.isAtmos, true)
            XCTAssertEqual(mapped.first?.isCommentary, true)
            XCTAssertEqual(mapped.first?.isDefault, true)
        }
    }
}
