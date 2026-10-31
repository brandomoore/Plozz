@testable import AetherEngine
import CoreModels
import FeaturePlayback
import XCTest
@testable import EnginePlozzigen

@MainActor
final class SpatialAudioLayoutPreferenceTests: XCTestCase {
    func testEveryLayoutMapsToItsEngineBedAndDTSXCapability() {
        XCTAssertEqual(SpatialAudioLayout.allCases.count, SpatialSpeakerLayout.allCases.count)
        for layout in SpatialAudioLayout.allCases {
            let bed = PlozzigenVideoEngine.spatialSpeakerLayout(layout)
            XCTAssertEqual(bed.rawValue, layout.rawValue)
            XCTAssertEqual(bed.carriesDTSXOneToOne, layout.supportsDTSXHeights)
            let rendering = ObjectAudioRendering.render(bed)
            XCTAssertEqual(rendering.bedFormat(routeFormat: .lpcm), .lpcm)
            XCTAssertEqual(rendering.bedFormat(routeFormat: .apac), .apac)
        }
        XCTAssertEqual(SpatialBedFormat.forRoute(portTypes: ["HDMIOutput"]), .lpcm)
        XCTAssertEqual(SpatialBedFormat.forRoute(portTypes: ["BluetoothA2DPOutput"]), .lpcm)
        XCTAssertEqual(SpatialBedFormat.forRoute(portTypes: ["HDMIOutput", "AirPlay"]), .apac)
    }

    func testEachNewLoadUsesDeviceLayoutAcrossProvidersAndDownloads() throws {
        let suite = "SpatialAudioLayoutPreferenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SpatialAudioLayoutStore(defaults: defaults)
        let engine = try PlozzigenVideoEngine(spatialAudioLayoutPreference: { store.load() })
        defer { engine.stop() }
        let earlier = engine.onDemandLoadOptions(for: request)
        for layout in SpatialAudioLayout.allCases {
            store.save(layout)
            for provider: ProviderKind in [.jellyfin, .emby, .plex, .silo, .mediaShare] {
                for channels: Int? in [nil, 2, 6, 8] {
                    var request = request
                    request.sourceProvider = provider
                    request.sourceMetadata = .init(audio: .init(codec: "dts", channels: channels))
                    assertRendering(engine.onDemandLoadOptions(for: request), layout: layout)
                    request.streamURL = URL(fileURLWithPath: "/fixture/download.mkv")
                    assertRendering(engine.onDemandLoadOptions(for: request), layout: layout)
                }
            }
        }
        assertRendering(earlier, layout: .nineOneSix)
    }

    func testLayoutDoesNotEnableDisabledOrIneligiblePlaybackOrChangeOrdinaryBridge() {
        for layout in SpatialAudioLayout.allCases {
            for lossless in [false, true] {
                let disabled = PlozzigenVideoEngine.onDemandLoadOptions(
                    losslessAudioEnabled: lossless, trueHDAtmosEnabled: false, spatialAudioLayout: layout
                )
                XCTAssertEqual(disabled.objectAudioRendering, .off)
                XCTAssertEqual(disabled.audioBridgeMode, lossless ? .lossless : .surroundCompat)
                for policy in [
                    LiveChannelOutputPolicy(isAudible: false),
                    .init(isAudible: true, sharesAudioSession: true)
                ] {
                    let options = PlozzigenVideoEngine.onDemandLoadOptions(
                        losslessAudioEnabled: lossless, spatialAudioLayout: layout, outputPolicy: policy
                    )
                    XCTAssertEqual(options.objectAudioRendering, .off)
                    XCTAssertEqual(options.audioBridgeMode, disabled.audioBridgeMode)
                }
                let enabled = PlozzigenVideoEngine.onDemandLoadOptions(
                    losslessAudioEnabled: lossless, spatialAudioLayout: layout
                )
                assertRendering(enabled, layout: layout)
                XCTAssertEqual(enabled.audioBridgeMode, disabled.audioBridgeMode)
            }
        }
    }

    func testDefaultSpatialRenderingAlsoAppliesToFELButNeverToLiveStreams() {
        for fel in [false, true] {
            let options = PlozzigenVideoEngine.onDemandLoadOptions(dolbyVisionFELEnabled: fel)
            assertRendering(options, layout: .default)
            XCTAssertEqual(options.preferDualLayerDolbyVision, fel)
        }
        for suffix in ["ts", "m3u8"] {
            let options = PlozzigenVideoEngine.liveLoadOptions(
                httpHeaders: [:], url: URL(string: "https://example.invalid/live.\(suffix)")
            )
            XCTAssertEqual(options.objectAudioRendering, .off)
        }
    }

    func testActualRenderedPipelineLabelsAreRecognized() {
        for layout in SpatialAudioLayout.allCases {
            let bed = PlozzigenVideoEngine.spatialSpeakerLayout(layout)
            for codec in ["truehd", "dts"] {
                let track = TrackInfo(id: 0, name: "English", codec: codec, language: "en", isDefault: true)
                for (route, expected): (SoftwareAtmosRoute, LocalizedStringResource) in [
                    (.pcmBed(bed), "Rendered to PCM"), (.apac(bed), "Lossy encoding")
                ] {
                    let pipeline = AetherEngine.softwareAudioDecoderLabel(
                        audioTracks: [track], activeIndex: 0, route: route
                    )
                    XCTAssertEqual(PlaybackDiagnostics(
                        audioPipelineDescription: pipeline, mode: .plozzigen
                    ).audioEncodingDescription, expected)
                }
            }
        }
    }

    private func assertRendering(
        _ options: LoadOptions, layout: SpatialAudioLayout,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        #if os(tvOS) || os(iOS)
        if #available(tvOS 26.0, iOS 26.0, *) {
            XCTAssertEqual(options.objectAudioRendering,
                           .render(PlozzigenVideoEngine.spatialSpeakerLayout(layout)), file: file, line: line)
            return
        }
        #endif
        XCTAssertEqual(options.objectAudioRendering, .off, file: file, line: line)
    }

    private var request: PlaybackRequest {
        PlaybackRequest(item: MediaItem(id: "movie", title: "Fixture", kind: .movie),
                        streamURL: URL(string: "https://example.invalid/movie.mkv")!)
    }
}
