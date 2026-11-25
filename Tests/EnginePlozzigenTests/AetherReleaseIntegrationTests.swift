@testable import AetherEngine
import CoreModels
import FeaturePlayback
import XCTest
@testable import EnginePlozzigen

final class AetherReleaseIntegrationTests: XCTestCase {
    func testVolumeBoostAppliesLinearGainAndLeavesSpatialCopyAndNativePlaybackAlone() throws {
        let plain = TrackInfo(id: 1, name: "Stereo", codec: "aac", language: "en", isDefault: true)
        let spatial = TrackInfo(id: 2, name: "Surround", codec: "eac3", language: "en",
                                channels: 6, isDefault: false, isAtmos: true)
        let supports = PlozzigenVideoEngine.supportsVolumeBoost
        XCTAssertTrue(supports(.loopback, .streamCopy, [plain]))
        XCTAssertFalse(supports(.loopback, .streamCopy, [plain, spatial]))
        let unprobed = TrackInfo(id: 3, name: "Alternate", codec: "eac3", language: "de", isDefault: false)
        XCTAssertFalse(supports(.loopback, .streamCopy, [unprobed]))
        XCTAssertFalse(supports(.loopback, .bridged, [plain, unprobed]))
        XCTAssertTrue(supports(.loopback, .bridged, [plain]))
        XCTAssertTrue(supports(.software, .decoded, [spatial]))
        XCTAssertFalse(supports(.remoteBypass, .playerManaged, [plain]))
        XCTAssertFalse(supports(.software, .decoded, []))

        XCTAssertNil(PlozzigenVideoEngine.volumeBoostCompressor(.off))
        for (boost, expected) in [(PlayerVolumeBoost.quarter, 1.25), (.double, 2), (.extra300, 4)] {
            let compressor = try XCTUnwrap(PlozzigenVideoEngine.volumeBoostCompressor(boost))
            XCTAssertEqual(compressor.ratio, 1)
            XCTAssertEqual(pow(10, compressor.makeupGainDB / 20), expected, accuracy: 0.00001)
        }
    }

    func testDroppedBoostRestoresUnboostedAudioOnceAndOnlyAfterTheRebuild() throws {
        var shaping = AudioShaping()
        shaping.compressor = PlozzigenVideoEngine.volumeBoostCompressor(.double)
        shaping.lfeMixDB = -6
        let recover = PlozzigenVideoEngine.audioShapingRestoringDroppedAudio
        XCTAssertNil(recover(shaping, .none, true, .playing))
        XCTAssertNil(recover(shaping, .bridged, true, .playing))
        XCTAssertNil(recover(shaping, .droppedNoPipeline, false, .paused))
        XCTAssertNil(recover(shaping, .droppedNoPipeline, true, .loading))
        for state in [PlaybackState.playing, .paused] {
            let restored = try XCTUnwrap(recover(shaping, .droppedNoPipeline, true, state))
            XCTAssertFalse(restored.isActive)
            XCTAssertEqual(restored.lfeMixDB, shaping.lfeMixDB)
            XCTAssertNil(recover(restored, .droppedNoPipeline, true, state))
        }
    }

    @MainActor
    func testBoostedPipelineFailureRestoresOriginalAudioWhilePaused() async throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "quiet-aac", withExtension: "mp4", subdirectory: "Fixtures"
        ))
        let engine = try PlozzigenVideoEngine()
        defer {
            engine.onTracksChanged = nil
            AetherEngine.setForceAudioPipelineFailureForTesting(false)
            engine.stop()
        }
        await engine.load(request: .init(item: .init(id: "quiet", title: "Quiet", kind: .movie), streamURL: url),
                          startPosition: 0)
        func wait(for condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            _ = try XCTUnwrap(condition() ? true : nil, "Timed out waiting for audio delivery.")
        }
        try await wait { engine.capabilities.contains(.volumeBoost) }
        let original = try XCTUnwrap(engine.liveTelemetry?.audioDelivery)
        engine.pause()
        var sawDroppedAudio = false
        engine.onTracksChanged = {
            guard engine.liveTelemetry?.audioDelivery == .droppedNoPipeline else { return }
            sawDroppedAudio = true
            // Fail only the boosted build. The original track is still playable.
            AetherEngine.setForceAudioPipelineFailureForTesting(false)
        }
        AetherEngine.setForceAudioPipelineFailureForTesting(true)
        engine.setVolumeBoost(.double)
        XCTAssertEqual(engine.volumeBoost, .double)
        try await wait {
            sawDroppedAudio && engine.volumeBoost == .off && engine.liveTelemetry?.audioDelivery == original
        }
        XCTAssertTrue(engine.isPaused)
    }

    func testMP4SubtitleNamesDoNotCollideWithGeneratedNativeRenditionSuffixes() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(url: XCTUnwrap(Bundle.module.url(
            forResource: "track-name-collisions", withExtension: "mp4", subdirectory: "Fixtures"
        )))
        let tracks = demuxer.subtitleTrackInfos()
        XCTAssertEqual(tracks.map(\.sourceTitle), ["English", "English", "English 2"])
        let entries = tracks.map { track in
            AetherEngine.NativeSubtitleTrackEntry(
                sourceStreamIndex: track.id, language: track.language, isForced: track.isForced,
                title: track.sourceTitle, isHearingImpaired: track.isHearingImpaired
            )
        }
        let infos = AetherEngine.nativeSubtitleRenditionInfos(for: entries)
        XCTAssertEqual(infos.count, 3)
        XCTAssertEqual(Set(infos.map(\.name)).count, 3)
        XCTAssertEqual(infos.map(\.language), tracks.map(\.language))
        XCTAssertEqual(infos.map(\.isForced), tracks.map(\.isForced))
        XCTAssertEqual(infos.map(\.isHearingImpaired), tracks.map(\.isHearingImpaired))
        let last = try XCTUnwrap(tracks.last)
        XCTAssertEqual(infos.last?.name, AetherEngine.nativeSubtitleRenditionBaseName(
            language: last.language, title: last.sourceTitle
        ))

        let untagged = ["English", "English", "English 2", "English 3", "English"].map {
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 0, language: nil, title: $0)
        }
        XCTAssertEqual(
            AetherEngine.nativeSubtitleRenditionInfos(for: untagged).map(\.name),
            ["English", "English 4", "English 2", "English 3", "English 5"]
        )
    }

    func testMP4AuthoredHandlerNamesReachTheEngine() throws {
        for name in ["track-names", "track-metadata-name"] {
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: XCTUnwrap(Bundle.module.url(
                forResource: name, withExtension: "mp4", subdirectory: "Fixtures"
            )))
            XCTAssertEqual(demuxer.audioTrackInfos().map(\.name), ["Audio Description"])
            XCTAssertEqual(demuxer.subtitleTrackInfos().map(\.name), ["Signs & Songs"])
            let tracks = PlozzigenVideoEngine.selectableAudioTracks(from: demuxer.audioTrackInfos(), route: .loopback)
            XCTAssertEqual(tracks.first?.sourceTitle, "Audio Description")
            XCTAssertFalse(try XCTUnwrap(tracks.first).isVisualImpaired, "A title must not invent a disposition.")
        }
    }

    func testMP4MuxerDefaultsStayGeneratedAndMatroskaRetainsAuthoredNamesAndFlags() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(url: XCTUnwrap(Bundle.module.url(
            forResource: "track-defaults", withExtension: "mp4", subdirectory: "Fixtures"
        )))
        XCTAssertEqual(demuxer.audioTrackInfos().map(\.name), ["ENG (aac)"])
        XCTAssertEqual(demuxer.subtitleTrackInfos().map(\.name), ["ENG (mov_text)"])
        let matroska = Demuxer()
        defer { matroska.close() }
        try matroska.open(url: XCTUnwrap(Bundle.module.url(
            forResource: "track-names", withExtension: "mkv", subdirectory: "Fixtures"
        )))
        let audio = try XCTUnwrap(PlozzigenVideoEngine.selectableAudioTracks(
            from: matroska.audioTrackInfos(), route: .loopback
        ).first)
        let subtitle = try XCTUnwrap(PlozzigenVideoEngine.selectableSubtitleTracks(
            from: matroska.subtitleTrackInfos(), route: .loopback
        ).first)
        XCTAssertEqual(audio.sourceTitle, "Narration [Fixture]")
        XCTAssertTrue(audio.isVisualImpaired)
        XCTAssertFalse(audio.isCommentary)
        XCTAssertEqual(subtitle.sourceTitle, "Signs & Songs [Fixture]")
        XCTAssertTrue(subtitle.isForced)
        XCTAssertTrue(subtitle.isHearingImpaired)
    }

    func testEngineTrackTitleMetadataPrecedence() {
        XCTAssertEqual(Demuxer.resolvedTrackTitle(title: "Full", name: "Signs", handlerName: "Other"), "Full")
        XCTAssertEqual(Demuxer.resolvedTrackTitle(title: " \n", name: "Signs & Songs", handlerName: "Other"), "Signs & Songs")
        XCTAssertEqual(Demuxer.resolvedTrackTitle(title: "SoundHandler", name: nil, handlerName: nil), "SoundHandler")
        for value in [nil, "", " \n", "SoundHandler", "SubtitleHandler", "VideoHandler",
                      "TextHandler", "Core Media Audio", "GPAC ISO Subtitle Handler"] {
            XCTAssertNil(Demuxer.resolvedTrackTitle(title: nil, name: nil, handlerName: value))
        }
    }

    func testContainerTrackNamesReachLabelsWithoutProviderMetadata() throws {
        let subtitleName = "Signs & Songs [MangaUK (Lyrics by Kiyoshi)]"
        let subtitle = try XCTUnwrap(PlozzigenVideoEngine.selectableSubtitleTracks(from: [
            TrackInfo(id: 3, name: subtitleName, codec: "ass", language: "en", isDefault: true)
        ], route: .loopback).first)
        XCTAssertEqual(
            TrackLabeling.subtitleLabel(
                displayTitle: subtitle.displayTitle, sourceTitle: subtitle.sourceTitle,
                language: subtitle.language, codec: subtitle.codec,
                isForced: subtitle.isForced, isImageBased: subtitle.isImageBasedSubtitle,
                trackID: subtitle.id, locale: Locale(identifier: "en")
            ),
            TrackLabel(base: .content("English"), qualifiers: [.title(subtitleName)])
        )
        let audioName = "Commentary by Director Ridley Scott"
        let audio = try XCTUnwrap(PlozzigenVideoEngine.selectableAudioTracks(from: [
            TrackInfo(id: 2, name: audioName, codec: "ac3", language: "en", channels: 2, isDefault: false)
        ], route: .loopback).first)
        XCTAssertEqual(
            TrackLabeling.audioLabel(
                displayTitle: audio.displayTitle, sourceTitle: audio.sourceTitle, language: audio.language,
                codec: audio.codec, channels: audio.channels, trackID: audio.id, locale: Locale(identifier: "en")
            ),
            TrackLabel(base: .content("English"), qualifiers: [.title(audioName), .format("Dolby Digital Stereo")])
        )
        let provider = MediaTrack(id: 3, kind: .subtitle, displayTitle: "English", sourceTitle: "Full subs", language: "en")
        XCTAssertEqual(subtitle.enriched(withProvider: provider).sourceTitle, subtitleName)
        let native = try XCTUnwrap(PlozzigenVideoEngine.selectableSubtitleTracks(from: [
            TrackInfo(id: 3, name: "English", codec: "ass", language: "en", isDefault: true)
        ], route: .remoteBypass).first)
        XCTAssertNil(native.sourceTitle, "AVFoundation display names are not original container names.")
        XCTAssertEqual(native.enriched(withProvider: provider).sourceTitle, "Full subs")
    }

    func testGeneratedEngineNamesDoNotBecomeContainerTitlesOrChangeBitmapRouting() throws {
        for name in ["ENG (aac)", "Track 3 (aac)"] {
            let track = try XCTUnwrap(PlozzigenVideoEngine.selectableAudioTracks(from: [
                TrackInfo(id: 3, name: name, codec: "aac", language: "eng", channels: 2, isDefault: false)
            ], route: .loopback).first)
            XCTAssertNil(track.sourceTitle)
            XCTAssertEqual(track.id, 3)
            XCTAssertEqual(
                TrackLabeling.audioLabel(
                    displayTitle: track.displayTitle, sourceTitle: track.sourceTitle, language: track.language,
                    codec: track.codec, channels: track.channels, trackID: track.id, locale: Locale(identifier: "en")
                ),
                TrackLabel(base: .content("English"), qualifiers: [.format("AAC Stereo")])
            )
        }
        let track = try XCTUnwrap(PlozzigenVideoEngine.selectableSubtitleTracks(from: [
            TrackInfo(id: 5, name: "ENG (pgssub)", codec: "pgssub", language: "eng",
                      isDefault: true, isForced: true, isHearingImpaired: true)
        ], route: .loopback).first)
        XCTAssertNil(track.sourceTitle)
        XCTAssertTrue(track.isDefault)
        XCTAssertTrue(track.isForced)
        XCTAssertTrue(track.isHearingImpaired)
        XCTAssertFalse(track.isImageBasedSubtitle)
        XCTAssertTrue(track.isBitmapSubtitle)
    }

    func testAudioSyncOnlyAdvertisesRoutesThatCanApplyTheOffset() {
        for route in [VideoRoute.software, .loopback, .remoteBypass, .audio, .none] {
            XCTAssertEqual(
                PlozzigenVideoEngine.supportsAudioDelay(route: route, hasAudio: true, canReanchor: true, canReload: true),
                route == .software || route == .loopback
            )
            XCTAssertFalse(PlozzigenVideoEngine.supportsAudioDelay(
                route: route, hasAudio: false, canReanchor: true, canReload: true
            ))
            XCTAssertFalse(PlozzigenVideoEngine.supportsAudioDelay(
                route: route, hasAudio: true, canReanchor: false, canReload: true
            ))
        }
        XCTAssertFalse(PlozzigenVideoEngine.supportsAudioDelay(
            route: .loopback, hasAudio: true, canReanchor: true, canReload: false
        ))
        XCTAssertTrue(PlozzigenVideoEngine.supportsAudioDelay(
            route: .software, hasAudio: true, canReanchor: true, canReload: false
        ))
    }

    func testInPlayerUpscalingExcludesPreviewDiscMenusAndSeparateAudio() {
        var request = PlaybackRequest(
            item: MediaItem(id: "fixture", title: "Fixture", kind: .movie),
            streamURL: URL(string: "https://fixture.invalid/movie.mkv")!
        )
        XCTAssertTrue(PlozzigenVideoEngine.supportsVideoUpscalingChanges(for: request))
        request.suppressOrdinaryWatchReporting = true
        XCTAssertFalse(PlozzigenVideoEngine.supportsVideoUpscalingChanges(for: request))
        request.suppressOrdinaryWatchReporting = false
        request.discPlayback = .openMenu
        XCTAssertFalse(PlozzigenVideoEngine.supportsVideoUpscalingChanges(for: request))
        request.discPlayback = .playVideo
        request.externalAudioURL = URL(string: "https://fixture.invalid/audio.m4a")!
        XCTAssertFalse(PlozzigenVideoEngine.supportsVideoUpscalingChanges(for: request))
    }

    func testUpscalingSelectionReachesOnDemandAndLiveOptionsWithoutChangingOtherPolicies() {
        for mode in VideoUpscaling.allCases {
            let options = [
                PlozzigenVideoEngine.onDemandLoadOptions(videoUpscaling: mode),
                PlozzigenVideoEngine.liveLoadOptions(
                    httpHeaders: [:], url: URL(string: "https://media.example/live.ts")!,
                    videoUpscaling: mode
                ),
                PlozzigenVideoEngine.liveLoadOptions(
                    httpHeaders: [:], url: URL(string: "https://media.example/live.m3u8")!,
                    videoUpscaling: mode
                )
            ]
            for value in options {
                XCTAssertEqual(value.upscalesLowResolutionVideo, mode != .off)
                XCTAssertEqual(value.upscaleScaler, mode == .animation ? .lineArt : .automatic)
                XCTAssertEqual(value.objectAudioRendering, .off)
                XCTAssertEqual(value.dolbyVisionHandling, .profile7MELOnly)
            }
        }
    }

    @MainActor
    func testRequestChoiceOverridesLiveContextAndStandalonePreviewsRemainOff() throws {
        var liveChoice = VideoUpscaling.automatic
        let liveEngine = try PlozzigenVideoEngine(videoUpscalingPreference: { liveChoice })
        let previewEngine = try PlozzigenVideoEngine()
        defer {
            liveEngine.stop()
            previewEngine.stop()
        }
        for provider in [ProviderKind.jellyfin, .plex, .emby, .mediaShare, .silo] {
            for url in [
                URL(string: "https://media.example/movie.mkv")!,
                URL(fileURLWithPath: "/fixture/movie.mkv")
            ] {
                var request = PlaybackRequest(
                    item: MediaItem(
                        id: "upscale", title: "Upscaling fixture", kind: .movie, genres: ["Animation"]
                    ), streamURL: url
                )
                request.sourceProvider = provider
                request.suppressOrdinaryWatchReporting = true
                XCTAssertFalse(previewEngine.onDemandLoadOptions(for: request).upscalesLowResolutionVideo)
                for mode in VideoUpscaling.allCases {
                    liveChoice = mode
                    let options = liveEngine.onDemandLoadOptions(for: request)
                    XCTAssertEqual(options.upscalesLowResolutionVideo, mode != .off)
                    XCTAssertEqual(
                        options.upscaleScaler,
                        mode == .animation || mode == .automatic ? .lineArt : .automatic
                    )
                }
                request.videoUpscaling = .off
                XCTAssertFalse(liveEngine.onDemandLoadOptions(for: request).upscalesLowResolutionVideo)
                request.videoUpscaling = .automatic
                XCTAssertTrue(previewEngine.onDemandLoadOptions(for: request).upscalesLowResolutionVideo)
                request.videoUpscaling = .animation
                XCTAssertEqual(previewEngine.onDemandLoadOptions(for: request).upscaleScaler, .lineArt)
                request.discPlayback = .openMenu
                XCTAssertFalse(liveEngine.onDemandLoadOptions(for: request).upscalesLowResolutionVideo)
                request.discPlayback = .playVideo
                request.externalAudioURL = URL(string: "https://media.example/audio.m4a")!
                XCTAssertFalse(liveEngine.onDemandLoadOptions(for: request).upscalesLowResolutionVideo)
            }
        }
    }

    func testUpscalingModesRetainDecodedResolutionAndHDRLimits() {
        let cases: [(VideoUpscaling, Int, Int, Bool, Bool, Bool)] = [
            (.off, 1280, 720, true, false, false),
            (.standard, 1280, 720, true, false, true),
            (.standard, 1920, 800, true, false, false),
            (.standard, 1920, 1080, true, false, false),
            (.animation, 1920, 1080, true, false, true),
            (.animation, 1920, 1080, true, true, true),
            (.standard, 1280, 720, true, true, false),
            (.animation, 3840, 2160, true, false, false),
            (.standard, 3840, 2160, true, false, false),
            (.animation, 1280, 720, false, true, false),
            (.standard, 1280, 720, false, false, false)
        ]
        for (mode, width, height, sdr, tenBit, expected) in cases {
            let options = PlozzigenVideoEngine.onDemandLoadOptions(videoUpscaling: mode)
            let decision = UpscaleRouteDecision.decide(
                preference: options.upscalesLowResolutionVideo,
                osSupportsStage: true, metalFXSupported: true,
                source: SourceGeometry(width: width, height: height, sarNum: 1, sarDen: 1),
                isSDR: sdr, isDolbyVision: false, isEightBit420: !tenBit,
                display: CGSize(width: 3840, height: 2160),
                wirelessAirPlayRoute: false, demuxedAudioLive: false,
                mlScaleFactors: { _, _ in [2] },
                scaler: options.upscaleScaler, isTenBit420: tenBit
            )
            let taken: Bool
            if case .taken = decision { taken = true } else { taken = false }
            XCTAssertEqual(taken, expected, "\(mode) \(width)x\(height), SDR: \(sdr), 10-bit: \(tenBit)")
        }
        for mode in [VideoUpscaling.standard, .animation] {
            let options = PlozzigenVideoEngine.onDemandLoadOptions(videoUpscaling: mode)
            XCTAssertEqual(
                UpscaleRouteDecision.decide(
                    preference: options.upscalesLowResolutionVideo,
                    osSupportsStage: true, metalFXSupported: true,
                    source: SourceGeometry(width: 1280, height: 720, sarNum: 1, sarDen: 1),
                    isSDR: true, isDolbyVision: false, isEightBit420: true,
                    display: CGSize(width: 1280, height: 720),
                    wirelessAirPlayRoute: false, demuxedAudioLive: false,
                    mlScaleFactors: { _, _ in [2] }, scaler: options.upscaleScaler
                ),
                .notTaken(.displayNotLarger)
            )
        }
    }

    func testFELConversionRequiresHostOptInAndPreservesMELWhenOff() {
        XCTAssertTrue(AetherEngine.OptionalComponent.dolbyVisionFelCurves.isBuiltIn)
        let enabled = PlozzigenVideoEngine.onDemandLoadOptions(dolbyVisionFELConversion: true)
        XCTAssertEqual(enabled.dolbyVisionHandling, .profile7KnownLayers)
        XCTAssertTrue(enabled.foldsDolbyVisionFEL)
        XCTAssertFalse(enabled.preferDualLayerDolbyVision)
        let disabled = PlozzigenVideoEngine.onDemandLoadOptions(dolbyVisionFELConversion: false)
        XCTAssertEqual(disabled.dolbyVisionHandling, .profile7MELOnly)
        XCTAssertFalse(disabled.foldsDolbyVisionFEL)
    }

    @MainActor
    func testFELConversionExcludesPreviewSeparateAudioAndDiscMenus() throws {
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }
        var request = PlaybackRequest(
            item: MediaItem(id: "fel", title: "FEL fixture", kind: .movie),
            streamURL: URL(string: "https://media.example/movie.mkv")!
        )
        request.dolbyVisionFELConversion = true
        XCTAssertTrue(engine.onDemandLoadOptions(for: request).foldsDolbyVisionFEL)
        request.externalAudioURL = URL(string: "https://media.example/audio.m4a")!
        XCTAssertFalse(PlozzigenVideoEngine.supportsFELConversion(for: request))
        XCTAssertFalse(engine.onDemandLoadOptions(for: request).foldsDolbyVisionFEL)
        request.externalAudioURL = nil
        request.suppressOrdinaryWatchReporting = true
        XCTAssertFalse(engine.onDemandLoadOptions(for: request).foldsDolbyVisionFEL)
        request.suppressOrdinaryWatchReporting = false
        request.discPlayback = .openMenu
        XCTAssertFalse(engine.onDemandLoadOptions(for: request).foldsDolbyVisionFEL)
    }

    @MainActor
    func testLinkedEngineSelectivePolicyRejectsUnknownAndHonorsFoldSwitch() throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        for type in ["MEL", "FEL", "unknown"] {
            engine.sourceDolbyVisionEnhancementLayerType = type
            XCTAssertEqual(engine.resolvedDolbyVisionHandling(.profile7KnownLayers, foldsFEL: true),
                           type == "unknown" ? .profile7BaseLayer : .automatic)
            XCTAssertEqual(engine.resolvedDolbyVisionHandling(.profile7KnownLayers, foldsFEL: false),
                           type == "MEL" ? .automatic : .profile7BaseLayer)
        }
        engine.sourceDolbyVisionEnhancementLayerType = nil
        XCTAssertEqual(engine.resolvedDolbyVisionHandling(.profile7KnownLayers), .profile7BaseLayer)
    }
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
        XCTAssertEqual(AetherEngine.version, "7.75.0")
        XCTAssertTrue(PlozzigenVideoEngine.onDemandLoadOptions().readsContainerAttachmentsAtOpen)
        XCTAssertTrue(PlozzigenVideoEngine.liveLoadOptions(httpHeaders: [:]).readsContainerAttachmentsAtOpen)
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
        XCTAssertFalse(options.upscalesLowResolutionVideo)
        XCTAssertFalse(options.audioShaping.isActive)
        XCTAssertFalse(PlozzigenVideoEngine.onDemandLoadOptions().preferDualLayerDolbyVision)
    }

    @MainActor
    func testReleasedHostControlsPreserveExistingDefaults() throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        XCTAssertTrue(engine.rendererAudioSessionActivationEnabled)
        XCTAssertFalse(engine.retainsVideoPipelineWhenBackgrounded)
        XCTAssertFalse(engine.ownsSoftwareNowPlaying)
        XCTAssertFalse(engine.ownsVideoNowPlayingSession)
        XCTAssertFalse(engine.ownsVideoNowPlayingCommands)
        XCTAssertFalse(engine.ownsAudioNowPlaying)
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

    func testOnDemandOptionsConvertOnlyProfile7MELWithoutChangingAudio() {
        let options = PlozzigenVideoEngine.onDemandLoadOptions()
        XCTAssertFalse(options.preferDualLayerDolbyVision)
        XCTAssertFalse(options.foldsDolbyVisionFEL)
        XCTAssertEqual(options.dolbyVisionHandling, .profile7MELOnly)
        XCTAssertFalse(options.isLive)
        XCTAssertTrue(options.matchContentEnabled)
        XCTAssertEqual(options.audioBridgeMode, .lossless)
        XCTAssertEqual(options.objectAudioRendering, .off)
    }

    @MainActor
    func testResolvedRequestsNeverEnableFELOrHeightConversionAcrossProviders() throws {
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }
        for provider in [ProviderKind.plex, .jellyfin, .emby, .mediaShare, .silo] {
            for url in [
                URL(string: "https://media.example/movie.mkv")!,
                URL(fileURLWithPath: "/fixture/download.mkv")
            ] {
                var request = PlaybackRequest(
                    item: MediaItem(id: "fel", title: "FEL fixture", kind: .movie), streamURL: url
                )
                request.sourceProvider = provider
                let options = engine.onDemandLoadOptions(for: request)
                XCTAssertFalse(options.preferDualLayerDolbyVision)
                XCTAssertFalse(options.foldsDolbyVisionFEL)
                XCTAssertEqual(options.dolbyVisionHandling, .profile7MELOnly)
                XCTAssertEqual(options.objectAudioRendering, .off)
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
            XCTAssertFalse(options.foldsDolbyVisionFEL)
            XCTAssertEqual(options.dolbyVisionHandling, .profile7MELOnly)
            XCTAssertEqual(options.objectAudioRendering, .off)
        }
    }

    func testOnDemandPlaybackPreservesChannelBridgeAndBufferingWithoutHeightConversion() {
        for lossless in [false, true] {
            for buffer in PlaybackReadAhead.allCases {
                let options = PlozzigenVideoEngine.onDemandLoadOptions(
                    losslessAudioEnabled: lossless, readAhead: buffer
                )
                XCTAssertEqual(options.objectAudioRendering, .off)
                XCTAssertEqual(options.audioBridgeMode, lossless ? .lossless : .surroundCompat)
                XCTAssertEqual(options.sessionCacheByteBudget, buffer == .automatic ? nil : Int.max)
                XCTAssertTrue(options.matchContentEnabled)
                XCTAssertFalse(options.isLive)
                XCTAssertFalse(options.progressiveSegmentDelivery)
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
                outputPolicy: policy
            )
            XCTAssertEqual(options.objectAudioRendering, .off)
            XCTAssertFalse(options.preferDualLayerDolbyVision)
            XCTAssertEqual(options.dolbyVisionHandling, .profile7MELOnly)
            XCTAssertEqual(options.audioBridgeMode, .lossless)
            XCTAssertEqual(options.suppressDisplayCriteria, policy.suppressesDisplayMatching)
            XCTAssertEqual(options.matchContentEnabled, !policy.suppressesDisplayMatching)
        }
    }

    func testDisplaySuppressedPreviewDoesNotRequestFEL() {
        let options = PlozzigenVideoEngine.onDemandLoadOptions(
            outputPolicy: .init(isAudible: true, suppressesDisplayMatching: true)
        )
        XCTAssertFalse(options.preferDualLayerDolbyVision)
        XCTAssertEqual(options.dolbyVisionHandling, .profile7MELOnly)
    }

    @MainActor
    func testProfile7PolicyDoesNotTrustMissingOrMislabeledProviderMetadata() throws {
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }
        for profile in [nil, 5, 7, 8] as [Int?] {
            var request = PlaybackRequest(
                item: MediaItem(id: "profile", title: "Profile fixture", kind: .movie),
                streamURL: URL(string: "https://media.example/movie.mkv")!
            )
            if let profile {
                request.sourceMetadata = .init(
                    video: .init(codec: "hevc", dolbyVisionProfile: profile))
            }
            XCTAssertEqual(engine.onDemandLoadOptions(for: request).dolbyVisionHandling, .profile7MELOnly)
        }
    }

    func testTrueHDLegalCreditIncludesSourceAndBothLicenses() throws {
        let credit = try XCTUnwrap(PlozzAttributions.entries.first { $0.title == "LibTrueHD" })
        XCTAssertTrue(credit.detail.contains("not linked in this build"))
        XCTAssertTrue(credit.detail.contains(
            "https://github.com/superuser404notfound/LibTrueHD/tree/3.1.0"
        ))
        XCTAssertTrue(credit.detail.contains("Quick104"))
        XCTAssertTrue(credit.detail.contains("Rainbaby"))
        XCTAssertTrue(credit.detail.contains("LibTrueHDNotices.txt"))
        XCTAssertEqual(Set(credit.licenses.map(\.label)), ["MIT", "Apache-2.0"])
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

    func testSourceAudioUsesConfirmedTrackAndCarriesAllAvailableFacts() throws {
        let tracks = [
            TrackInfo(id: 3, name: "English", codec: "truehd", language: "en", channels: 8,
                      bitrate: 4_000_000, isDefault: true, sampleRate: 48_000,
                      channelLayout: "7.1", profile: "Dolby TrueHD + Dolby Atmos"),
            TrackInfo(id: 9, name: "French", codec: "ac3", language: "fr", channels: 2, isDefault: false),
            TrackInfo(id: 12, name: "Japanese", codec: "dca", language: "ja", channels: 8,
                      isDefault: false, profile: "MA + DTS:X IMAX"),
            TrackInfo(id: 15, name: "English", codec: "dca", language: "en", channels: 8,
                      isDefault: false, profile: "DTS-HD MA", isDTSX: true)
        ]
        XCTAssertNil(PlozzigenVideoEngine.activeSourceAudio(from: tracks, selectedID: nil))
        XCTAssertNil(PlozzigenVideoEngine.activeSourceAudio(from: tracks, selectedID: 1))
        let first = try XCTUnwrap(PlozzigenVideoEngine.activeSourceAudio(from: tracks, selectedID: 3))
        XCTAssertEqual(first.profile, "Dolby TrueHD + Dolby Atmos")
        XCTAssertEqual(first.channels, 8)
        XCTAssertEqual(first.channelLayout, "7.1")
        XCTAssertEqual(first.sampleRate, 48_000)
        XCTAssertEqual(first.bitrate, 4_000_000)
        let switched = try XCTUnwrap(PlozzigenVideoEngine.activeSourceAudio(from: tracks, selectedID: 9))
        XCTAssertEqual(switched.codec, "ac3")
        XCTAssertEqual(switched.channels, 2)
        XCTAssertNil(switched.profile)
        XCTAssertNil(switched.channelLayout)
        XCTAssertNil(switched.sampleRate)
        XCTAssertNil(switched.bitrate)
        XCTAssertEqual(PlozzigenVideoEngine.activeSourceAudio(from: tracks, selectedID: 15)?.profile,
                       "DTS-HD MA DTS:X")
        let menu = PlozzigenVideoEngine.selectableAudioTracks(from: tracks, route: .loopback)
        XCTAssertEqual(menu[0].profile, first.profile)
        XCTAssertEqual(menu[2].profile, "MA + DTS:X IMAX")
        XCTAssertTrue(menu[2].isDTSX)
        XCTAssertTrue(menu[3].isDTSX)
    }
}
