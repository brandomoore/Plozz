import XCTest
@testable import CoreModels

final class MediaBadgesTests: XCTestCase {
    // MARK: Resolution

    func testResolutionBadge4K() {
        let meta = MediaSourceMetadata(video: .init(width: 3840, height: 2160))
        XCTAssertEqual(meta.resolutionBadge?.label, "4K")
    }

    func testResolutionBadge1080p() {
        let meta = MediaSourceMetadata(video: .init(width: 1920, height: 1080))
        XCTAssertEqual(meta.resolutionBadge?.label, "1080p")
    }

    func testResolutionBadge720p() {
        let meta = MediaSourceMetadata(video: .init(width: 1280, height: 720))
        XCTAssertEqual(meta.resolutionBadge?.label, "720p")
    }

    func testResolutionBadgeSD() {
        let meta = MediaSourceMetadata(video: .init(width: 720, height: 480))
        XCTAssertEqual(meta.resolutionBadge?.label, "SD")
    }

    func testResolutionInfersFromWidthWhenHeightMissing() {
        // 3840 wide, no height -> ~2160 lines -> 4K.
        let meta = MediaSourceMetadata(video: .init(width: 3840, height: nil))
        XCTAssertEqual(meta.resolutionBadge?.label, "4K")
    }

    func testResolutionNilWhenNoDimensions() {
        let meta = MediaSourceMetadata(video: .init())
        XCTAssertNil(meta.resolutionBadge)
    }

    func testLetterboxedCinemaWidthClassifiesByWidth() {
        // A 2.40:1 movie mastered at full-HD width is 1920×804; keying off the
        // cropped height alone would misread it as 720p.
        let meta = MediaSourceMetadata(video: .init(width: 1920, height: 804))
        XCTAssertEqual(meta.resolutionBadge?.label, "1080p")
    }

    func testUltrawide4KClassifiesByWidth() {
        // 3840×1600 (2.40:1 UHD) is 4K despite its 1600-line height.
        let meta = MediaSourceMetadata(video: .init(width: 3840, height: 1600))
        XCTAssertEqual(meta.resolutionBadge?.label, "4K")
    }

    // MARK: Video codec badge

    func testVideoCodecBadgeHEVC() {
        let meta = MediaSourceMetadata(video: .init(codec: "hevc"))
        XCTAssertEqual(meta.videoCodecBadge?.label, "HEVC")
        XCTAssertEqual(meta.videoCodecBadge?.style, .spec)
    }

    func testVideoCodecBadgeH264() {
        let meta = MediaSourceMetadata(video: .init(codec: "h264"))
        XCTAssertEqual(meta.videoCodecBadge?.label, "H.264")
    }

    func testVideoCodecBadgeNilWithoutCodec() {
        let meta = MediaSourceMetadata(video: .init(width: 1920, height: 1080))
        XCTAssertNil(meta.videoCodecBadge)
    }

    func testTechnicalBadgesOmitCodec() {
        let meta = MediaSourceMetadata(
            video: .init(codec: "hevc", width: 1920, height: 1080, videoRange: "HDR", videoRangeType: "HDR10"),
            audio: .init(codec: "eac3", profile: "Dolby Atmos")
        )
        // The video codec (HEVC) is intentionally excluded from the headline badge
        // row; it remains available via `videoCodecBadge` for the diagnostics overlay.
        XCTAssertEqual(meta.technicalBadges.map(\.label), ["1080p", "HDR10", "Dolby Digital+", "Dolby Atmos"])
    }

    func testTechnicalBadgeOrderSeparatesPictureAndAudio() {
        let meta = MediaSourceMetadata(
            video: .init(width: 3840, height: 2160, videoRangeType: "DOVIWithHDR10"),
            audio: .init(codec: "eac3", profile: "Dolby Digital+ Atmos", channels: 6, channelLayout: "5.1")
        )
        XCTAssertEqual(meta.technicalBadges.map(\.label),
                       ["4K", "Dolby Vision", "Dolby Digital+", "Dolby Atmos"])
        XCTAssertEqual(meta.technicalBadges[1].detail, "HDR10")
    }

    // MARK: Dynamic range

    func testCombinedRangesAgreeAcrossDetailVersionAndCachedShareFacts() {
        let cases: [(String, [String])] = [
            ("DOVIWithHDR10Plus", ["Dolby Vision", "HDR10+"]),
            ("DOVIWithHDR10PLUS", ["Dolby Vision", "HDR10+"]),
            (" dovi_with_hdr10+ ", ["Dolby Vision", "HDR10+"]),
            ("DOVIWithHDR10", ["Dolby Vision", "HDR10"]),
            ("DOVIWithHLG", ["Dolby Vision", "HLG"]),
            ("DOVIWithSDR", ["Dolby Vision"]),
            ("DOVI", ["Dolby Vision"]),
            ("HDR10Plus", ["HDR10+"]),
            ("HDR10+", ["HDR10+"]),
            ("HDR10", ["HDR10"]),
            ("HLG", ["HLG"]),
            ("SDR", ["SDR"])
        ]
        for (token, expected) in cases {
            let metadata = MediaSourceMetadata(video: .init(videoRangeType: token))
            let version = MediaVersion(id: "file", videoRange: token)
            let item = MediaItem(id: "item", title: "Item", kind: .movie, mediaInfo: metadata)
            let share = ProbedStreamFacts(videoRangeType: token).applying()
            XCTAssertEqual(metadata.dynamicRangeBadges.map(\.label), expected, token)
            XCTAssertEqual(version.technicalBadges, item.technicalBadges, token)
            XCTAssertEqual(share.technicalBadges, item.technicalBadges, token)
            if expected.count == 2 {
                XCTAssertEqual(item.technicalBadges.count, 1, token)
                XCTAssertEqual(item.technicalBadges.first?.detail, expected.last, token)
                XCTAssertEqual(item.technicalBadges.first?.accessibilityText, expected.joined(separator: " "), token)
            }
            XCTAssertEqual(version.isHDR, token != "SDR", token)
            XCTAssertEqual(version.hdrLabel, token == "SDR" ? nil : expected.first, token)
        }
    }

    func testUnknownRangesDoNotAssertSDRAndExplicitFactsOutrankCoarseRange() {
        for token in ["", " ", "Unknown", "unrecognized"] {
            let metadata = MediaSourceMetadata(video: .init(videoRangeType: token))
            XCTAssertTrue(metadata.dynamicRangeBadges.isEmpty, token)
        }
        for (type, expected) in [
            ("DOVIWithHDR10Plus", ["Dolby Vision", "HDR10+"]),
            ("DOVIWithHLG", ["Dolby Vision", "HLG"]),
            ("HDR10Plus", ["HDR10+"]),
            ("HDR", ["HDR"]),
            ("HLG", ["HLG"])
        ] {
            let metadata = MediaSourceMetadata(video: .init(videoRange: "SDR", videoRangeType: type))
            XCTAssertEqual(metadata.dynamicRangeBadges.map(\.label), expected)
        }
    }

    func testTransferAndProfileHintsNeverInventDolbyVisionCompatibility() {
        for (transfer, expected) in [
            ("smpte2084", "HDR10"), ("smpte2094-40", "HDR10+"),
            ("arib-std-b67", "HLG"), ("bt709", "SDR")
        ] {
            let metadata = MediaSourceMetadata(video: .init(colorTransfer: transfer))
            XCTAssertEqual(metadata.dynamicRangeBadges.map(\.label), [expected])
        }
        for profile in [5, 7, 8] {
            let metadata = MediaSourceMetadata(video: .init(
                colorTransfer: "smpte2084", dolbyVisionProfile: profile
            ))
            XCTAssertEqual(metadata.dynamicRangeBadges.map(\.label), ["Dolby Vision"])
        }
        let plus = MediaSourceMetadata(video: .init(
            videoRangeType: "HDR10", colorTransfer: "smpte2094-40"
        ))
        XCTAssertEqual(plus.dynamicRangeBadges.map(\.label), ["HDR10+"])
    }

    func testSeriesSummaryPreservesRicherDolbyVisionCompatibilityInEitherOrder() {
        let combined = MediaSourceMetadata(video: .init(videoRangeType: "DOVIWithHDR10Plus"))
        let plain = MediaSourceMetadata(video: .init(videoRangeType: "DOVI"))
        for sources in [[combined, plain], [plain, combined]] {
            XCTAssertEqual(MediaSourceMetadata.representativeTechnicalBadges(from: sources), [
                MediaBadge("Dolby Vision", style: .dolby, detail: "HDR10+")
            ])
        }
    }

    func testResolutionTiersMatchVersionsAndKeep8K() {
        for (width, height, label) in [
            (7680, 3200, "8K"), (7680, 4320, "8K"),
            (3840, 1600, "4K"), (2560, 1080, "1440p"),
            (1920, 804, "1080p"), (1280, 540, "720p"), (720, 480, "SD")
        ] {
            let metadata = MediaSourceMetadata(video: .init(width: width, height: height))
            let version = MediaVersion(id: "file", width: width, height: height)
            XCTAssertEqual(metadata.resolutionBadge?.label, label)
            XCTAssertEqual(version.resolutionLabel, label)
            XCTAssertEqual(version.technicalBadges, metadata.technicalBadges)
        }
        let best = MediaSourceMetadata.representativeTechnicalBadges(from: [
            .init(video: .init(height: 2160)), .init(video: .init(height: 4320))
        ])
        XCTAssertEqual(best.first?.label, "8K")
    }

    func testDolbyVisionFromRangeType() {
        let meta = MediaSourceMetadata(video: .init(videoRangeType: "DOVIWithHDR10"))
        // DoVi with an HDR10 base layer advertises both badges (Plex "DoVi/HDR10").
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["Dolby Vision", "HDR10"])
        XCTAssertEqual(meta.dynamicRangeBadges.first?.style, .dolby)
        XCTAssertEqual(meta.dynamicRangeBadges.last?.style, .hdr)
    }

    func testPureDolbyVisionHasNoHDR10Badge() {
        // Profile 5 DoVi has no HDR10 fallback, so it shows Dolby Vision alone.
        let meta = MediaSourceMetadata(video: .init(videoRangeType: "DOVI"))
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["Dolby Vision"])
    }

    func testHDR10Plus() {
        let meta = MediaSourceMetadata(video: .init(videoRangeType: "HDR10Plus"))
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["HDR10+"])
    }

    func testHDR10() {
        let meta = MediaSourceMetadata(video: .init(videoRange: "HDR", videoRangeType: "HDR10"))
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["HDR10"])
    }

    func testHLG() {
        let meta = MediaSourceMetadata(video: .init(videoRangeType: "HLG"))
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["HLG"])
    }

    func testGenericHDRFromCoarseRange() {
        let meta = MediaSourceMetadata(video: .init(videoRange: "HDR"))
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["HDR"])
    }

    func testSDRBadgeFromExplicitToken() {
        // Jellyfin reports an explicit SDR range token.
        let meta = MediaSourceMetadata(video: .init(videoRange: "SDR"))
        XCTAssertEqual(meta.dynamicRangeBadges.map(\.label), ["SDR"])
        XCTAssertEqual(meta.dynamicRangeBadges.first?.style, .sdr)
    }

    func testNoDynamicRangeBadgeWhenOnlyDimensionsKnown() {
        // Plex's coarse media-level fallback knows the resolution but has no
        // way to confirm the dynamic range — the trimmed children response can
        // strip the HDR display-title hint without meaning the content is SDR.
        // Stay silent rather than asserting a wrong "SDR" pill on a real
        // DoVi/HDR episode.
        let meta = MediaSourceMetadata(video: .init(width: 1920, height: 1080))
        XCTAssertTrue(meta.dynamicRangeBadges.isEmpty)
    }

    func testNoDynamicRangeBadgeWhenStreamHasNothingToClassify() {
        // A bare codec with no dimensions or range token stays unbadged rather
        // than asserting SDR on no evidence.
        let meta = MediaSourceMetadata(video: .init(codec: "h264"))
        XCTAssertTrue(meta.dynamicRangeBadges.isEmpty)
    }

    // MARK: Audio

    func testAudioCodecAliasesAndExplicitSpatialProfiles() {
        for (codec, profile, labels) in [
            ("ec-3", "JOC", ["Dolby Digital+", "Dolby Atmos"]),
            ("eac3", "Dolby Digital Plus with Dolby Atmos", ["Dolby Digital+", "Dolby Atmos"]),
            ("ac-3", "", ["Dolby Digital"]),
            ("mlp", "Atmos", ["Dolby TrueHD", "Dolby Atmos"]),
            ("dca", "DTS-HD MA / DTS-X", ["DTS-HD", "DTS:X"]),
            ("dts-hd", "DTS:X", ["DTS-HD", "DTS:X"]),
            ("dts", "DTS-HD HRA", ["DTS-HD"]),
            ("dts", "HRA", ["DTS-HD"]),
            ("dts", "Main", ["DTS"]),
            ("dts", "", ["DTS"])
        ] {
            let metadata = MediaSourceMetadata(audio: .init(codec: codec, profile: profile, channels: 6))
            XCTAssertEqual(metadata.audioBadges.map(\.label), labels, "\(codec) \(profile)")
            XCTAssertEqual(metadata.audioBadges.first?.detail, "5.1")
            if labels.count > 1 { XCTAssertNil(metadata.audioBadges.last?.detail) }
        }
        for codec in ["aac", "flac", "alac", "pcm_s24le", "opus"] {
            let version = MediaVersion(id: "file", audioCodec: codec, audioChannels: 2)
            XCTAssertTrue(version.technicalBadges.isEmpty, "Stereo codecs are detail facts, not headline badges.")
            XCTAssertNotNil(version.audioFormatLabel, codec)
        }
        XCTAssertEqual(PlaybackDiagnostics.friendlyAudioName(codec: "ec-3", profile: "JOC"), "Dolby Atmos")
        XCTAssertEqual(MediaSourceMetadata.audioBadges(codec: "aac", profile: "JOC", channels: nil), [])
    }

    func testAtmosKeepsItsCodecAndAttachesKnownChannelsToThatCodec() {
        let meta = MediaSourceMetadata(audio: .init(codec: "eac3", profile: "Dolby Atmos", channels: 8, channelLayout: "7.1"))
        XCTAssertEqual(meta.audioBadges.map(\.label), ["Dolby Digital+", "Dolby Atmos"])
        XCTAssertEqual(meta.audioBadges.first?.style, .dolby)
        XCTAssertEqual(meta.audioBadges.first?.detail, "7.1")
        XCTAssertNil(meta.audioBadges.last?.detail)
    }

    func testDTSXHeadline() {
        let meta = MediaSourceMetadata(audio: .init(codec: "dts", profile: "DTS:X", channels: 8))
        XCTAssertEqual(meta.audioBadges.map(\.label), ["DTS", "DTS:X"])
        XCTAssertEqual(meta.audioBadges.first?.detail, "7.1")
    }

    func testDolbyDigitalPlusWithSurroundChannel() {
        let meta = MediaSourceMetadata(audio: .init(codec: "eac3", profile: nil, channels: 6, channelLayout: "5.1"))
        XCTAssertEqual(meta.audioBadges.map(\.label), ["Dolby Digital+"])
        XCTAssertEqual(meta.audioBadges.first?.detail, "5.1")
    }

    func testStereoProducesNoChannelBadge() {
        let meta = MediaSourceMetadata(audio: .init(codec: "aac", channels: 2, channelLayout: "stereo"))
        XCTAssertTrue(meta.audioBadges.isEmpty)
    }

    func testSurroundFromChannelCountWhenNoLayout() {
        let meta = MediaSourceMetadata(audio: .init(codec: "aac", channels: 6))
        XCTAssertEqual(meta.audioBadges.map(\.label), ["5.1"])
    }

    // MARK: Combined technical badges + gating

    func testTechnicalBadgesOrder() {
        let meta = MediaSourceMetadata(
            video: .init(width: 3840, height: 2160, videoRangeType: "DOVI"),
            audio: .init(codec: "eac3", profile: "Dolby Atmos")
        )
        XCTAssertEqual(meta.technicalBadges.map(\.label), ["4K", "Dolby Vision", "Dolby Digital+", "Dolby Atmos"])
    }

    func testTechnicalBadgesGatedToPlayableKinds() {
        let meta = MediaSourceMetadata(video: .init(width: 3840, height: 2160, videoRange: "SDR"))
        let movie = MediaItem(id: "1", title: "M", kind: .movie, mediaInfo: meta)
        XCTAssertEqual(movie.technicalBadges.map(\.label), ["4K", "SDR"])

        let series = MediaItem(id: "2", title: "S", kind: .series, mediaInfo: meta)
        XCTAssertTrue(series.technicalBadges.isEmpty)
    }

    // MARK: Representative (series ← episodes) aggregation

    func testRepresentativeBadgesPicksBestOfEachCategory() {
        let episodes = [
            // 1080p SDR stereo.
            MediaItem(id: "1", title: "E1", kind: .episode,
                      mediaInfo: .init(video: .init(width: 1920, height: 1080),
                                       audio: .init(codec: "aac", channels: 2))),
            // 4K Dolby Vision, Dolby Digital+ 5.1.
            MediaItem(id: "2", title: "E2", kind: .episode,
                      mediaInfo: .init(video: .init(width: 3840, height: 2160, videoRangeType: "DOVI"),
                                       audio: .init(codec: "eac3", channels: 6, channelLayout: "5.1"))),
            // 1080p HDR10, Dolby Atmos.
            MediaItem(id: "3", title: "E3", kind: .episode,
                      mediaInfo: .init(video: .init(width: 1920, height: 1080, videoRange: "HDR", videoRangeType: "HDR10"),
                                       audio: .init(codec: "eac3", profile: "Dolby Atmos", channels: 8))),
        ]
        XCTAssertEqual(episodes.representativeTechnicalBadges.map(\.label),
                       ["4K", "Dolby Vision", "Dolby Digital+", "Dolby Atmos"])
        XCTAssertEqual(episodes.representativeTechnicalBadges.first(where: { $0.label == "Dolby Digital+" })?.detail, "7.1")
    }

    func testRepresentativeBadgesAddSurroundWhenFormatDoesNotImplyIt() {
        let episodes = [
            MediaItem(id: "1", title: "E1", kind: .episode,
                      mediaInfo: .init(video: .init(width: 1920, height: 1080, videoRange: "SDR"),
                                       audio: .init(codec: "eac3", channels: 6, channelLayout: "5.1"))),
            MediaItem(id: "2", title: "E2", kind: .episode,
                      mediaInfo: .init(audio: .init(codec: "eac3", channels: 8, channelLayout: "7.1"))),
        ]
        let badges = episodes.representativeTechnicalBadges
        XCTAssertEqual(badges.map(\.label), ["1080p", "SDR", "Dolby Digital+"])
        XCTAssertEqual(badges.first(where: { $0.label == "Dolby Digital+" })?.detail, "7.1")
    }

    func testRepresentativeBadgesGroupPictureBeforeAudio() {
        let episodes = [
            MediaItem(id: "1", title: "E1", kind: .episode,
                      mediaInfo: .init(video: .init(width: 1920, height: 1080),
                                       audio: .init(codec: "aac", channels: 2))),
            MediaItem(id: "2", title: "E2", kind: .episode,
                      mediaInfo: .init(video: .init(width: 3840, height: 2160, videoRangeType: "DOVIWithHDR10"),
                                       audio: .init(codec: "eac3", profile: "Dolby Digital+ Atmos", channels: 6))),
        ]
        XCTAssertEqual(episodes.representativeTechnicalBadges.map(\.label),
                       ["4K", "Dolby Vision", "Dolby Digital+", "Dolby Atmos"])
        XCTAssertEqual(episodes.representativeTechnicalBadges[1].detail, "HDR10")
    }

    func testRepresentativeAudioDoesNotBorrowAnotherSourcesChannelsOrCodec() {
        let sources = [
            MediaSourceMetadata(audio: .init(codec: "truehd", profile: "Atmos", channels: 6)),
            MediaSourceMetadata(audio: .init(codec: "dts", profile: "DTS-HD MA", channels: 8))
        ]
        let audio = MediaSourceMetadata.representativeTechnicalBadges(from: sources).filter(\.isAudio)
        XCTAssertEqual(audio, [
            MediaBadge("Dolby TrueHD", style: .dolby, detail: "5.1"),
            MediaBadge("Dolby Atmos", style: .dolby)
        ])
    }

    func testUnknownCodecAndChannelsDoNotInventAnAtmosCarrier() {
        let badges = MediaSourceMetadata(audio: .init(profile: "Atmos")).audioBadges
        XCTAssertEqual(badges, [MediaBadge("Dolby Atmos", style: .dolby)])
    }

    func testTrueHDChannelsRemainAttachedWithoutSpatialMetadata() {
        let badges = MediaSourceMetadata(audio: .init(codec: "truehd", channels: 8)).audioBadges
        XCTAssertEqual(badges, [MediaBadge("Dolby TrueHD", style: .dolby, detail: "7.1")])
    }

    func testPictureAndAudioTreatmentsAreIndependentOfBrand() {
        XCTAssertFalse(MediaBadge("Dolby Vision", style: .dolby).isAudio)
        XCTAssertTrue(MediaBadge("Dolby Atmos", style: .dolby).isAudio)
        XCTAssertTrue(MediaBadge("DTS:X", style: .dts).isAudio)
        XCTAssertTrue(MediaBadge("5.1", style: .audio).isAudio)
        XCTAssertFalse(MediaBadge("HDR10+", style: .hdr).isAudio)
    }

    func testFilenameClaimsDoNotInventFormats() {
        let metadata = MediaSourceMetadata(
            fileName: "Movie.DV.HDR10+.DTS-X.mkv",
            video: .init(videoRangeType: "HDR10"),
            audio: .init(codec: "eac3", channels: 6)
        )
        XCTAssertEqual(metadata.technicalBadges.map(\.label), ["HDR10", "Dolby Digital+"])
    }

    func testRepresentativeBadgesEmptyWhenNoMediaInfo() {
        let episodes = [
            MediaItem(id: "1", title: "E1", kind: .episode),
            MediaItem(id: "2", title: "E2", kind: .episode),
        ]
        XCTAssertTrue(episodes.representativeTechnicalBadges.isEmpty)
    }

    // MARK: Rating badge

    func testRatingBadgeFromOfficialRating() {
        let item = MediaItem(id: "1", title: "M", kind: .movie, officialRating: "TV-14")
        XCTAssertEqual(item.ratingBadge?.label, "TV-14")
        XCTAssertEqual(item.ratingBadge?.style, .rating)
    }

    func testRatingBadgeNilWhenBlank() {
        let item = MediaItem(id: "1", title: "M", kind: .movie, officialRating: "   ")
        XCTAssertNil(item.ratingBadge)
    }

    // MARK: Metadata line

    func testMetadataComponentsOrderAndGenreCap() {
        let item = MediaItem(
            id: "1",
            title: "M",
            kind: .movie,
            productionYear: 2010,
            genres: ["Action", "Adventure", "Science Fiction", "Thriller"],
            runtime: 8880 // 2h 28m
        )
        XCTAssertEqual(item.metadataComponents(), ["2010", "2h 28m", "Action", "Adventure", "Sci-Fi"])
    }

    func testGenreDisplayFormatterCanonicalizesSciFiAliasesAndDeduplicates() {
        XCTAssertEqual(
            GenreDisplayFormatter.displayNames(
                for: [
                    "Science Fiction",
                    "Sci-Fi",
                    "Sci Fi",
                    "SciFi",
                    "Sci-Fiction",
                    "Science Fiction and Fantasy",
                    "Fantasy",
                    "Drama"
                ]
            ),
            ["Sci-Fi & Fantasy", "Drama"]
        )
    }

    // MARK: Card runtime text

    func testCardRuntimeTextShowsOverallRuntimeWhenNotInProgress() {
        let item = MediaItem(id: "1", title: "Movie", kind: .movie, runtime: 5400)
        XCTAssertEqual(item.cardRuntimeText, "1h 30m")
        XCTAssertFalse(item.cardRuntimeIsRemaining)
    }

    func testCardRuntimeTextShowsRemainingWhenResumePositionExists() {
        let item = MediaItem(
            id: "1",
            title: "Movie",
            kind: .movie,
            runtime: 7200,
            resumePosition: 1800
        )
        XCTAssertEqual(item.cardRuntimeText, "1h 30m")
        XCTAssertTrue(item.cardRuntimeIsRemaining)
    }

    func testCardRuntimeTextShowsRemainingWhenOnlyPercentageExists() {
        let item = MediaItem(
            id: "1",
            title: "Episode",
            kind: .episode,
            runtime: 1800,
            playedPercentage: 0.5
        )
        XCTAssertEqual(item.cardRuntimeText, "15m")
        XCTAssertTrue(item.cardRuntimeIsRemaining)
    }

    /// A saved resume point outranks having seen the title before, matching how
    /// the progress bar already behaves (`testProgressTakesPriorityOverWatchedBadge`).
    /// The two disagreed: the bar treated progress as the stronger fact, the label
    /// treated "watched" as the stronger one, so a rewatch drew a part-filled bar
    /// beside its full runtime.
    ///
    /// The risk this accepts: a server can leave a stale position behind on a title
    /// marked watched, and that now reads as remaining time. Nothing on the item
    /// distinguishes a stale position from a genuine restart — but a viewer who has
    /// actually started again is the far commoner case, and the row exists to tell
    /// them where they are.
    func testCardRuntimeTextPrefersRemainingOverWatchedWhenAResumePointExists() {
        let item = MediaItem(
            id: "1",
            title: "Movie",
            kind: .movie,
            runtime: 7200,
            resumePosition: 1800,
            isPlayed: true
        )
        XCTAssertEqual(item.cardRuntimeText, "1h 30m")
        XCTAssertTrue(item.cardRuntimeIsRemaining)
    }

    /// Without a resume point, "watched" stands: the percentage of 1 such a title
    /// reports describes the previous viewing, not a current one.
    func testCardRuntimeTextUsesOverallWhenWatchedWithNoResumePoint() {
        let item = MediaItem(
            id: "1",
            title: "Movie",
            kind: .movie,
            runtime: 7200,
            playedPercentage: 1,
            isPlayed: true
        )
        XCTAssertEqual(item.cardRuntimeText, "2h")
        XCTAssertFalse(item.cardRuntimeIsRemaining)
    }

    func testCardRuntimeTextNilForUnsupportedKinds() {
        let item = MediaItem(id: "1", title: "Library", kind: .folder, runtime: 3600)
        XCTAssertNil(item.cardRuntimeText)
    }

    // MARK: Resume affordance (drives hero + detail Play/Resume button)

    func testResumeProgressFractionSetForPartialResumePosition() {
        let item = MediaItem(
            id: "1",
            title: "Movie",
            kind: .movie,
            runtime: 7200,
            resumePosition: 1800
        )
        XCTAssertEqual(item.resumeProgressFraction ?? 0, 0.25, accuracy: 0.0001)
    }

    func testResumeProgressFractionSetForPartialPercentageOnly() {
        let item = MediaItem(
            id: "1",
            title: "Episode",
            kind: .episode,
            runtime: 1800,
            playedPercentage: 0.5
        )
        XCTAssertEqual(item.resumeProgressFraction ?? 0, 0.5, accuracy: 0.0001)
    }

    func testResumeProgressFractionNilWhenResumePositionIsZero() {
        // Providers (e.g. Jellyfin PlaybackPositionTicks: 0, Plex viewOffset: 0)
        // report a non-nil but zero resume position for unwatched items — the hero
        // Play button must read "Play", not "Resume".
        let item = MediaItem(
            id: "1",
            title: "Movie",
            kind: .movie,
            runtime: 7200,
            resumePosition: 0
        )
        XCTAssertNil(item.resumeProgressFraction)
    }

    func testResumeProgressFractionNilWhenNotStarted() {
        let item = MediaItem(id: "1", title: "Movie", kind: .movie, runtime: 7200)
        XCTAssertNil(item.resumeProgressFraction)
    }

    /// The detail page's Play button reads this, which is why restarting a film
    /// already seen left that button showing nothing while the same title's card in
    /// a library row showed its progress correctly. Same gate, fourth place.
    func testResumeProgressFractionSurvivesTheWatchedMarkWhenThereIsAResumePoint() {
        let item = MediaItem(
            id: "1",
            title: "Movie",
            kind: .movie,
            runtime: 7200,
            resumePosition: 1800,
            isPlayed: true
        )
        XCTAssertEqual(item.resumeProgressFraction, 0.25)
    }

    func testResumeProgressFractionNilWhenWatchedWithNoResumePoint() {
        let item = MediaItem(
            id: "1",
            title: "Movie",
            kind: .movie,
            runtime: 7200,
            playedPercentage: 1,
            isPlayed: true
        )
        XCTAssertNil(item.resumeProgressFraction)
    }

    // MARK: Dolby format word

    func testDolbyFormatWordStripsBrand() {
        XCTAssertEqual(MediaBadge("Dolby Atmos", style: .dolby).dolbyFormatWord, "Atmos")
        XCTAssertEqual(MediaBadge("Dolby Vision", style: .dolby).dolbyFormatWord, "Vision")
        XCTAssertEqual(MediaBadge("Dolby Digital+", style: .dolby).dolbyFormatWord, "Digital+")
    }

    func testNonDolbyFormatWordIsFullLabel() {
        XCTAssertEqual(MediaBadge("4K", style: .spec).dolbyFormatWord, "4K")
    }

    func testRuntimeBadgeText() {        XCTAssertEqual((8880 as TimeInterval).runtimeBadgeText, "2h 28m")
        XCTAssertEqual((2820 as TimeInterval).runtimeBadgeText, "47m")
        XCTAssertEqual((3600 as TimeInterval).runtimeBadgeText, "1h")
        XCTAssertNil((0 as TimeInterval).runtimeBadgeText)
    }
}

/// A Continue Watching card was drawing its progress bar with no time beside it.
///
/// The bar needs only a *fraction*, which a provider can report directly; the label
/// needs a duration in seconds, and some titles arrive with the first and not the
/// second — a share file has no runtime until it has been played once, and a server
/// whose media was never probed reports none. The card then said a film was
/// part-watched without saying how much was left.
final class RecoveredRuntimeTests: XCTestCase {

    private func movie(
        runtime: TimeInterval? = nil,
        resume: TimeInterval? = nil,
        percentage: Double? = nil,
        versionDuration: TimeInterval? = nil
    ) -> MediaItem {
        var item = MediaItem(id: "m1", title: "West Side Story", kind: .movie)
        item.runtime = runtime
        item.resumePosition = resume
        item.playedPercentage = percentage
        if let versionDuration {
            item.versions = [MediaVersion(id: "v1", name: "File", duration: versionDuration)]
        }
        return item
    }

    /// The reported bug: a bar, and nothing beside it.
    func testAProgressBarWithoutARuntimeNowShowsATime() {
        let item = movie(resume: 3_600, percentage: 0.5)
        XCTAssertNotNil(item.resumeProgressFraction, "the bar was always drawn")
        XCTAssertNotNil(item.cardRuntimeText, "the time beside it was missing")
        XCTAssertTrue(item.cardRuntimeIsRemaining)
    }

    /// 3600s at the halfway mark is a two-hour film, so an hour is left.
    func testPositionOverFractionRecoversTheRuntime() {
        XCTAssertEqual(movie(resume: 3_600, percentage: 0.5).cardRuntimeText, 3_600.runtimeBadgeText)
    }

    /// The file's own duration is the true length and outranks the derivation.
    func testTheFilesDurationIsPreferredOverTheDerivation() {
        let item = movie(resume: 600, percentage: 0.5, versionDuration: 7_200)
        // 7200 × (1 − 0.5) = 3600 left, NOT the 600 the ratio would have implied.
        XCTAssertEqual(item.cardRuntimeText, 3_600.runtimeBadgeText)
    }

    /// A stated runtime always wins; none of this may perturb a normal item.
    func testAStatedRuntimeIsUnchanged() {
        let item = movie(runtime: 7_200, resume: 1_800, percentage: 0.25)
        XCTAssertEqual(item.cardRuntimeText, 5_400.runtimeBadgeText)
    }

    /// Dividing by a tiny fraction multiplies its rounding error into a wild
    /// duration. A confident "3h 40m left" that is invented is worse than a blank.
    func testAVanishinglySmallFractionIsNotExtrapolated() {
        XCTAssertNil(movie(resume: 60, percentage: 0.001).cardRuntimeText)
    }

    /// Nothing to work from stays blank rather than guessing.
    func testNoPositionMeansNoTime() {
        XCTAssertNil(movie(percentage: 0.4).cardRuntimeText)
        XCTAssertNil(movie().cardRuntimeText)
    }
}
