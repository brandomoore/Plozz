import XCTest
@testable import CoreModels

/// Tests for the `MediaVersion` value type, its labels, device-compatibility
/// prediction, and the smart "recommended selection" used as the picker default.
final class MediaVersionTests: XCTestCase {

    // MARK: - Labels

    func testResolutionLabelBuckets() {
        XCTAssertEqual(MediaVersion(id: "1", height: 2160).resolutionLabel, "4K")
        XCTAssertEqual(MediaVersion(id: "2", height: 1440).resolutionLabel, "1440p")
        XCTAssertEqual(MediaVersion(id: "3", height: 1080).resolutionLabel, "1080p")
        XCTAssertEqual(MediaVersion(id: "4", height: 720).resolutionLabel, "720p")
        XCTAssertEqual(MediaVersion(id: "5", height: 480).resolutionLabel, "SD")
        XCTAssertNil(MediaVersion(id: "6").resolutionLabel)
    }

    func testHDRAndAudioLabels() {
        let doviAtmos = MediaVersion(
            id: "1", height: 2160, videoRange: "DOVI",
            audioChannels: 8, audioProfile: "Dolby Atmos"
        )
        XCTAssertTrue(doviAtmos.isHDR)
        XCTAssertEqual(doviAtmos.hdrLabel, "Dolby Vision")
        XCTAssertEqual(doviAtmos.audioLabel, "Atmos")

        let sdr51 = MediaVersion(id: "2", height: 1080, videoRange: "SDR", audioChannels: 6)
        XCTAssertFalse(sdr51.isHDR)
        XCTAssertNil(sdr51.hdrLabel)
        XCTAssertEqual(sdr51.audioLabel, "5.1")

        let hdr10Plus = MediaVersion(id: "3", height: 2160, videoRange: "HDR10Plus")
        XCTAssertTrue(hdr10Plus.isHDR)
        XCTAssertEqual(hdr10Plus.hdrLabel, "HDR10+")
        XCTAssertTrue(hdr10Plus.displayLabel?.contains("HDR10+") == true)
        XCTAssertEqual(hdr10Plus.technicalBadges.map(\.label), ["4K", "HDR10+"])
    }

    func testHDR10PlusVersionRetainsItsHDR10CompatibleDirectPlay() {
        let version = MediaVersion(id: "hdr", videoCodec: "hevc", videoRange: "HDR10Plus", audioCodec: "aac")
        XCTAssertEqual(version.compatibility(with: .init(supportsHDR10: true)), .directPlay)
        XCTAssertEqual(version.compatibility(with: .init(supportsHDR10: false)), .transcode)
    }

    func testCombinedDolbyVisionBadgeDoesNotBypassNativeCompatibilityGating() {
        let version = MediaVersion(
            id: "dv", videoCodec: "hevc", videoRange: "DOVIWithHDR10Plus", audioCodec: "aac"
        )
        XCTAssertEqual(version.technicalBadges, [MediaBadge("Dolby Vision", style: .dolby, detail: "HDR10+")])
        XCTAssertEqual(version.compatibility(with: .init(supportsDolbyVision: false)), .transcode)
        XCTAssertEqual(version.compatibility(with: .init(supportsDolbyVision: true)), .directPlay)
    }

    func testTechnicalBadgesUsePictureThenAudioOrder() {
        let dovi = MediaVersion(
            id: "1",
            width: 3840,
            height: 2160,
            videoCodec: "hevc",
            videoRange: "DOVIWithHDR10",
            audioCodec: "eac3",
            audioChannels: 8,
            audioProfile: "Dolby Atmos"
        )
        XCTAssertEqual(dovi.technicalBadges.map(\.label),
                       ["4K", "Dolby Vision", "Dolby Digital+", "Dolby Atmos"])
        XCTAssertEqual(dovi.technicalBadges[1].detail, "HDR10")

        // A 720p SDR stereo version should emit just 720p · SDR — no audio
        // headline, no HDR badges, and channels < 6 are not surfaced.
        let sd = MediaVersion(
            id: "2",
            width: 1280,
            height: 720,
            videoCodec: "h264",
            videoRange: "SDR",
            audioCodec: "aac",
            audioChannels: 2
        )
        XCTAssertEqual(sd.technicalBadges.map(\.label), ["720p", "SDR"])

        let dd = MediaVersion(
            id: "3",
            width: 1920,
            height: 1080,
            videoCodec: "hevc",
            videoRange: "HDR10",
            audioCodec: "eac3",
            audioChannels: 6
        )
        let labels = dd.technicalBadges.map(\.label)
        XCTAssertEqual(labels.first, "1080p")
        XCTAssertEqual(labels.dropFirst().prefix(2), ArraySlice(["HDR10", "Dolby Digital+"]))
    }

    func testDisplayLabelPrefersDerivedFactsThenName() {
        let derived = MediaVersion(id: "1", height: 2160, sizeBytes: 12_000_000_000, videoRange: "HDR10")
        XCTAssertTrue(derived.displayLabel?.contains("4K") == true)
        XCTAssertTrue(derived.displayLabel?.contains("HDR10") == true)
        XCTAssertTrue(derived.displayLabel?.contains("12 GB") == true)

        // A name that names a source-quality token now surfaces that token (the
        // edition/source recovery the picker needs) rather than echoing the raw
        // release string verbatim.
        XCTAssertEqual(MediaVersion(id: "2", name: "Bluray Remux").displayLabel, "Remux")
        // A name with no recognised edition/source/quality still falls back whole.
        XCTAssertEqual(MediaVersion(id: "2b", name: "Server Copy").displayLabel, "Server Copy")

        // No facts and no name: displayLabel is nil — the caller supplies its
        // own "Version" copy fallback rather than us baking English in here.
        XCTAssertNil(MediaVersion(id: "3").displayLabel)
    }

    func testRichMenuFactsKeepFileNameSeparate() {
        let version = MediaVersion(
            id: "1",
            name: "Extended Remux",
            fileName: "Movie.Extended.2160p.mkv",
            height: 2160,
            bitrate: 80_000_000,
            sizeBytes: 42_000_000_000,
            duration: 7_200,
            videoRange: "DOVI",
            audioChannels: 8,
            audioProfile: "Dolby Atmos"
        )

        XCTAssertEqual(version.menuTitle, "Extended")
        XCTAssertEqual(
            version.menuFacts,
            ["4K", "Dolby Vision", "Remux", "Atmos", "80 Mbps", "42 GB", "2h"]
        )
        XCTAssertEqual(version.fileName, "Movie.Extended.2160p.mkv")
    }

    func testSynthesizedVersionCarriesSourceFileSize() {
        let item = MediaItem(
            id: "movie",
            title: "Movie",
            kind: .movie,
            mediaInfo: MediaSourceMetadata(fileSizeBytes: 8_500_000_000)
        )

        let version = MediaVersion.synthesized(from: item)
        XCTAssertEqual(version.sizeBytes, 8_500_000_000)
        XCTAssertEqual(version.sizeLabel, "8.5 GB")
    }

    func testPickerPresentationIncludesSourceAudioLanguagesFormatsAndRelease() {
        let version = MediaVersion(
            id: "file", name: "Extended Remux", fileName: "Film.Extended.2160p.REMUX-GROUP.mkv",
            height: 2160, bitrate: 80_000_000, sizeBytes: 42_000_000_000, duration: 7_200,
            sourceMetadata: .init(
                video: .init(codec: "hevc", width: 3840, height: 2160, bitDepth: 10, videoRangeType: "DOVIWithHDR10"),
                audio: .init(codec: "truehd", profile: "Atmos", channels: 8, language: "eng"),
                audioLanguages: ["eng", "en", "fra", "und", ""]
            )
        )
        let row = MediaVersion.PickerPresentation(version, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(row.title, "Extended · 4K · Dolby Vision · Remux · 42 GB")
        XCTAssertEqual(row.supplementalFacts, [
            "HDR10", "HEVC", "10-bit", "English, French", "Dolby TrueHD + Dolby Atmos + 7.1", "80 Mbps", "2h"
        ])
        XCTAssertEqual(row.releaseName, "Film.Extended.2160p.REMUX-GROUP.mkv")
        XCTAssertEqual(row.badges.map(\.label), [
            "4K", "Dolby Vision", "HEVC", "Dolby TrueHD", "Dolby Atmos", "English", "French"
        ])
        XCTAssertEqual(row.badges.first { $0.label == "Dolby Vision" }?.detail, "HDR10")
        XCTAssertEqual(row.badges.first { $0.label == "HEVC" }?.style, .spec)
        XCTAssertEqual(row.badges.suffix(2).map(\.style), [.audio, .audio])
        XCTAssertEqual(row.badges.first { $0.label == "Dolby TrueHD" }?.style, .dolby)
        XCTAssertEqual(row.titleWithoutBadges, "Extended · Remux · 42 GB")
        XCTAssertEqual(row.supplementalFactsWithoutBadges, ["10-bit", "80 Mbps", "2h"])
        XCTAssertEqual(row.summaryWithoutBadges, "Extended · Remux · 42 GB · 10-bit · 80 Mbps · 2h")
        XCTAssertEqual(
            version.audioLanguageNames(in: Locale(identifier: "es_ES")),
            ["Inglés", "Francés"]
        )
    }

    func testPickerAudioKeepsCodecProfileAndChannelsWithoutGuessingMissingFacts() {
        XCTAssertEqual(MediaVersion(id: "a", audioCodec: "aac", audioChannels: 2).audioFormatLabel, "AAC Stereo")
        XCTAssertEqual(
            MediaVersion(id: "b", audioCodec: "dts", audioChannels: 8, audioProfile: "DTS-HD MA").audioFormatLabel,
            "DTS-HD MA 7.1"
        )
        XCTAssertEqual(
            MediaVersion(id: "c", audioCodec: "truehd", audioChannels: 6).audioFormatLabel,
            "Dolby TrueHD 5.1"
        )
        XCTAssertEqual(MediaVersion(id: "d", audioCodec: "aac").audioFormatLabel, "AAC")
        XCTAssertNil(MediaVersion(id: "e").audioFormatLabel)
        let unknown = MediaVersion.PickerPresentation(.init(id: "unknown", sizeBytes: -1, duration: 0))
        XCTAssertNil(unknown.title)
        XCTAssertTrue(unknown.supplementalFacts.isEmpty)
        XCTAssertNil(unknown.releaseName)
        XCTAssertTrue(unknown.badges.isEmpty)
        XCTAssertNil(unknown.titleWithoutBadges)
        XCTAssertTrue(unknown.supplementalFactsWithoutBadges.isEmpty)
        XCTAssertNil(MediaVersion(id: "invalid", duration: .infinity).durationLabel)
        XCTAssertNil(MediaVersion(id: "invalid", duration: .nan).durationLabel)
    }

    func testPickerBadgesUseOnlyThisVersionsFactsAndIncludeAudioDetails() {
        let surround = MediaVersion.PickerPresentation(.init(
            id: "surround", height: 1080, videoCodec: "h264", videoRange: "SDR",
            audioCodec: "ac3", audioChannels: 6
        ))
        XCTAssertEqual(surround.badges.map(\.accessibilityText), ["1080p", "SDR", "H.264", "Dolby Digital 5.1"])
        XCTAssertNil(surround.titleWithoutBadges)
        XCTAssertTrue(surround.supplementalFactsWithoutBadges.isEmpty)
        let stereo = MediaVersion.PickerPresentation(.init(id: "stereo", height: 720, audioCodec: "aac", audioChannels: 2))
        XCTAssertEqual(stereo.badges.map(\.label), ["720p", "AAC"])
        XCTAssertEqual(stereo.badges.last?.detail, "Stereo")
        XCTAssertTrue(stereo.supplementalFactsWithoutBadges.isEmpty)
        XCTAssertFalse(stereo.badges.contains { $0.style == .dolby || $0.style == .sdr })
        XCTAssertEqual(
            MediaVersion.PickerPresentation(.init(id: "named", name: "Server copy")).titleWithoutBadges,
            "Server copy"
        )
    }

    func testPickerKeepsCodecBeforeAudioWithOrWithoutOtherPictureFacts() {
        for version in [
            MediaVersion(id: "flat", videoCodec: "h264", audioCodec: "aac"),
            MediaVersion(id: "rich", sourceMetadata: .init(
                video: .init(codec: "av1"),
                audio: .init(codec: "aac"),
                audioLanguages: ["eng"]
            ))
        ] {
            let row = MediaVersion.PickerPresentation(version, locale: Locale(identifier: "en_US"))
            XCTAssertEqual(row.formatBadges.map(\.style), [.spec, .audio])
            XCTAssertEqual(row.formatBadges.first?.isAudio, false)
            XCTAssertEqual(row.formatBadges.last?.isAudio, true)
            XCTAssertEqual(row.badges.dropFirst(2).map(\.style),
                           version.id == "rich" ? [.audio] : [])
        }
        let videoOnly = MediaVersion.PickerPresentation(.init(id: "video", videoCodec: "hevc"))
        XCTAssertEqual(videoOnly.formatBadges, [MediaBadge("HEVC", style: .spec)])
    }

    func testPickerAudioBadgesPreserveCodecAndLayoutWithoutDuplicateChannelChips() {
        let cases: [(MediaVersion, [MediaBadge])] = [
            (.init(id: "truehd", audioCodec: "truehd", audioChannels: 6),
             [MediaBadge("Dolby TrueHD", style: .dolby, detail: "5.1")]),
            (.init(id: "atmos", audioCodec: "truehd", audioProfile: "Atmos"),
             [MediaBadge("Dolby TrueHD", style: .dolby), MediaBadge("Dolby Atmos", style: .dolby)]),
            (.init(id: "ddp", audioCodec: "eac3", audioProfile: "Atmos"),
             [MediaBadge("Dolby Digital+", style: .dolby), MediaBadge("Dolby Atmos", style: .dolby)]),
            (.init(id: "atmos-channels", audioCodec: "eac3", audioChannels: 6, audioProfile: "Atmos"),
             [MediaBadge("Dolby Digital+", style: .dolby, detail: "5.1"), MediaBadge("Dolby Atmos", style: .dolby)]),
            (.init(id: "atmos-layout", sourceMetadata: .init(
                audio: .init(codec: "truehd", profile: "Atmos", channels: 8, channelLayout: "7.1")
            )),
             [MediaBadge("Dolby TrueHD", style: .dolby, detail: "7.1"), MediaBadge("Dolby Atmos", style: .dolby)]),
            (.init(id: "dtsx-channels", audioCodec: "dts", audioChannels: 8, audioProfile: "DTS:X"),
             [MediaBadge("DTS", style: .dts, detail: "7.1"), MediaBadge("DTS:X", style: .dts)]),
            (.init(id: "dts", audioCodec: "dts", audioChannels: 8, audioProfile: "DTS-HD MA"),
             [MediaBadge("DTS-HD", style: .dts, detail: "MA 7.1")]),
            (.init(id: "aac", audioCodec: "aac", audioChannels: 6),
             [MediaBadge("AAC", style: .audio, detail: "5.1")]),
            (.init(id: "channels", audioChannels: 6), [MediaBadge("5.1", style: .audio)])
        ]
        for (version, expected) in cases {
            let row = MediaVersion.PickerPresentation(version)
            XCTAssertEqual(row.badges, expected, version.id)
            XCTAssertTrue(row.supplementalFactsWithoutBadges.isEmpty, version.id)
        }
        XCTAssertEqual(
            cases[1].0.technicalBadges,
            [MediaBadge("Dolby TrueHD", style: .dolby), MediaBadge("Dolby Atmos", style: .dolby)],
            "The detail hero and picker retain the same codec and spatial facts."
        )
    }

    func testPickerLanguageBadgesAreLocalizedUniqueAndExcludeUnknownLanguages() {
        let version = MediaVersion(id: "languages", sourceMetadata: .init(
            audio: .init(language: "eng"),
            audioLanguages: ["en", "eng", "fra", "und", "zxx", ""]
        ))
        let row = MediaVersion.PickerPresentation(version, locale: Locale(identifier: "es_ES"))
        XCTAssertEqual(row.badges, [
            MediaBadge("Inglés", style: .audio), MediaBadge("Francés", style: .audio)
        ])
        XCTAssertEqual(row.supplementalFacts, ["Inglés, Francés"])
        XCTAssertTrue(row.supplementalFactsWithoutBadges.isEmpty)
        XCTAssertTrue(MediaVersion.PickerPresentation(.init(id: "unknown")).badges.isEmpty)
    }

    func testPickerLanguagePriorityUsesOnlyReportedLanguagesAndKeepsTheFullInventory() {
        let locale = Locale(identifier: "en_US")
        let version = MediaVersion(id: "multi", sourceMetadata: .init(
            audioLanguages: ["fra", "deu", "spa", "eng", "ita", "por", "jpn", "kor", "zho", "ara", "en"]
        ))
        let row = MediaVersion.PickerPresentation(version, locale: locale)
        let preferred = row.prioritizedAudioLanguages(preferredLanguage: "eng", locale: locale)
        XCTAssertEqual(preferred.first, "English")
        XCTAssertEqual(preferred.count - 1, 9)
        XCTAssertEqual(Set(preferred), Set(row.audioLanguages))
        XCTAssertEqual(row.audioLanguages.first, "French", "Display priority must not rewrite the source inventory.")
        XCTAssertEqual(
            row.prioritizedAudioLanguages(preferredLanguage: "nl", locale: locale),
            row.audioLanguages,
            "A missing preferred language must never be invented."
        )
        XCTAssertEqual(row.prioritizedAudioLanguages(preferredLanguage: "fra", locale: locale).first, "French")
        XCTAssertTrue(row.formatBadges.isEmpty)
    }

    func testPickerReleaseFallbackAndFilenameQualityDoNotChangeVersionIdentity() {
        let original = MediaVersion(id: "raw", fileName: "Movie.2160p.WEB-DL-GROUP.mkv", height: 2160)
        let qualified = original.qualified(accountID: "account", itemID: "item")
        let row = MediaVersion.PickerPresentation(qualified)
        XCTAssertEqual(row.title, "4K")
        XCTAssertEqual(row.supplementalFacts, ["WEB-DL"])
        XCTAssertEqual(row.releaseName, original.fileName)
        XCTAssertEqual(qualified.playbackMediaSourceID, "raw")
        XCTAssertNotEqual(qualified.id, "raw")
        XCTAssertEqual(MediaVersion.PickerPresentation(.init(id: "a", name: "Release", height: 1080)).releaseName, "Release")
        XCTAssertNil(MediaVersion.PickerPresentation(.init(id: "b", name: "Server Copy")).releaseName)
    }

    func testCachedMetadataAndSynthesizedVersionsPreserveLanguageFacts() throws {
        let legacy = try JSONDecoder().decode(
            MediaSourceMetadata.self, from: Data(#"{"audio":{"codec":"aac","language":"eng"}}"#.utf8)
        )
        XCTAssertNil(legacy.audioLanguages)
        let metadata = MediaSourceMetadata(
            fileName: "Movie.mkv", audio: legacy.audio, audioLanguages: ["eng", "jpn"]
        )
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, mediaInfo: metadata)
        let version = MediaVersion.synthesized(from: item)
        let restored = try JSONDecoder().decode(MediaVersion.self, from: JSONEncoder().encode(version))
        XCTAssertEqual(restored, version)
        XCTAssertEqual(restored.audioLanguageNames(in: Locale(identifier: "en_US")), ["English", "Japanese"])
        XCTAssertEqual(MediaVersion.PickerPresentation(restored).releaseName, "Movie.mkv")
        XCTAssertNil(restored.playbackMediaSourceID)
        XCTAssertEqual(
            MediaVersion(id: "legacy", sourceMetadata: legacy).audioLanguageNames(in: Locale(identifier: "en_US")),
            ["English"]
        )
    }

    func testFilenameHintsAreDecodedWithoutChangingStoredSourceOrIdentity() throws {
        let query = "filename=Film%20%26%20Friends.Extended.2160p.REMUX-GROUP.mkv&id=tt123&media_type=movie"
        for rawName in [
            "https://media.example/stream?\(query)",
            "n?\n\(query)",
            query
        ] {
            let version = MediaVersion(
                id: "raw-source", fileName: rawName, height: 2160,
                sourceMetadata: .init(fileName: rawName)
            ).qualified(accountID: "account", itemID: "item")
            let cached = try JSONDecoder().decode(MediaVersion.self, from: JSONEncoder().encode(version))
            let row = MediaVersion.PickerPresentation(cached)
            XCTAssertEqual(row.title, "Extended · 4K")
            XCTAssertEqual(row.supplementalFacts, ["Remux"])
            XCTAssertEqual(row.releaseName, "Film & Friends.Extended.2160p.REMUX-GROUP.mkv")
            XCTAssertEqual(cached.fileName, rawName)
            XCTAssertEqual(cached.sourceMetadata?.fileName, rawName)
            XCTAssertEqual(cached.playbackMediaSourceID, "raw-source")
            XCTAssertEqual(cached.id, version.id)
            XCTAssertTrue(cached.audioLanguageNames().isEmpty)
            XCTAssertNil(cached.audioFormatLabel)
        }
    }

    func testURLBackedProviderNameCannotLeakQueryTextIntoPickerTitles() {
        let version = MediaVersion(
            id: "source", name: "https://media.example/stream?file_name=Release%20Name&id=tt123"
        )
        XCTAssertEqual(version.displayLabel, "Release Name")
        XCTAssertEqual(version.menuTitle, "Release Name")
        XCTAssertNil(MediaVersion.PickerPresentation(version).releaseName)

        let endpoint = MediaVersion(
            id: "endpoint",
            name: "https://media.example/stream?token=Extended.REMUX",
            fileName: "stream?token=Extended.REMUX"
        )
        let row = MediaVersion.PickerPresentation(endpoint)
        XCTAssertNil(row.title)
        XCTAssertTrue(row.supplementalFacts.isEmpty)
        XCTAssertNil(row.releaseName)
    }

    func testSourceDisplayNamesDecodeOnlyURLValuesAndPreserveOrdinaryNames() {
        let cases: [(String, String?)] = [
            ("filename=%E6%8C%87%E7%8E%AF%E7%8E%8B.mkv&id=tt123", "指环王.mkv"),
            ("file_name=Film%20%26%20Friends%2BPlus.mkv&id=tt123", "Film & Friends+Plus.mkv"),
            ("filename=Film+Plus.mkv&id=tt123", "Film+Plus.mkv"),
            ("filename=Film%2520Name.mkv&id=tt123", "Film%20Name.mkv"),
            ("filename=Episode%20%231.mkv", "Episode #1.mkv"),
            ("file_name=C%3A%5CMovies%5CFilm.mkv", "Film.mkv"),
            ("https://media.example/stream?FileName=Film.mkv", "Film.mkv"),
            ("https://media.example/stream?file_name=Film.mkv&filename=Film.mkv", "Film.mkv"),
            ("https://media.example/Film%20Name.mkv?token=fixture#fragment", "Film Name.mkv"),
            ("https://media.example/Original.mkv?filename=Different.Extended.mkv", "Original.mkv"),
            ("https://media.example/folder.name/?filename=Film.mkv", "Film.mkv"),
            ("Film.mkv?token=fixture#fragment", "Film.mkv"),
            ("/movies/Film%20Name.mkv", "Film%20Name.mkv"),
            ("/movies/Part=1.mkv", "Part=1.mkv"),
            (#"C:\Movies\Film.mkv"#, "Film.mkv"),
            ("Film & Friends+Plus.mkv", "Film & Friends+Plus.mkv"),
            ("https://media.example/stream?filename=&id=tt123", nil),
            ("filename=%E6%8C&id=tt123", nil),
            ("https://media.example/stream?token=fixture", nil),
            ("https://media.example/stream", nil),
            ("https://media.example/Zk9xa1JpN25vY2xEMnJpcFQ5dGxY", nil),
            ("?token=fixture", nil),
            ("token=Private.mkv", nil),
            ("name=Private.mkv", nil),
            ("source_name=Private.mkv&id=tt123", nil),
            ("https://media.example/stream?token=Private.mkv", nil),
            ("https://media.example/folder.name/", nil),
            ("https://media.example/stream?filename=One.mkv&file_name=Two.mkv", nil),
            ("filename=https%3A%2F%2Fmedia.example%2Fstream%3Ftoken%3Dfixture", nil),
            ("filename=file%3A%2F%2F%2Fprivate%2FSecret.mkv", nil),
            ("filename=%2F%2Fmedia.example%2FSecret.mkv", nil),
            ("filename=Film.mkv%3Ftoken%3Dfixture", nil),
            ("filename=Film%0AName.mkv", nil)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(MediaSourceDisplayName.fileName(from: input), expected, input)
        }
        XCTAssertEqual(MediaSourceDisplayName.name(from: "Theatrical / Original"), "Theatrical / Original")
        let fallback = MediaVersion.PickerPresentation(.init(
            id: "fallback", name: "Server copy", fileName: "stream?token=fixture", height: 1080
        ))
        XCTAssertEqual(fallback.releaseName, "Server copy")
    }

    func testUnsupportedFilenameQueriesFallBackToServerFactsWithoutChangingIdentity() throws {
        let locator = "https://media.example/stream?source_name=Untrusted.Extended.REMUX.mkv&token=fixture"
        let version = MediaVersion(
            id: "server-source", name: "Server copy", fileName: locator,
            height: 2160, videoCodec: "hevc",
            sourceMetadata: .init(fileName: locator, audioLanguages: ["eng"])
        ).qualified(accountID: "account", itemID: "item")
        let restored = try JSONDecoder().decode(MediaVersion.self, from: JSONEncoder().encode(version))
        let row = MediaVersion.PickerPresentation(restored, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(row.title, "4K")
        XCTAssertEqual(row.releaseName, "Server copy")
        XCTAssertTrue(row.badges.contains { $0.label == "HEVC" })
        XCTAssertEqual(row.audioLanguages, ["English"])
        XCTAssertNil(restored.editionLabel)
        XCTAssertNil(restored.sourceQualityLabel)
        XCTAssertEqual(restored.fileName, locator)
        XCTAssertEqual(restored.sourceMetadata?.fileName, locator)
        XCTAssertEqual(restored.playbackMediaSourceID, "server-source")
        XCTAssertEqual(restored.id, version.id)
        XCTAssertFalse(row.supplementalFacts.contains("Remux"))
    }

    func testMultilineSourceDescriptionUsesItsMarkedReleaseFilename() {
        let providerName = """
        [Source] Remote
        2160p • WEB-DL
        Audio • English • French
        🗂️ Film.2026.MULTi.2160p.WEB-DL.DDP5.1-GROUP.mkv
        """
        let version = MediaVersion(
            id: "original-id", name: providerName,
            fileName: "https://media.example/opaque-source-endpoint", height: 2160
        )
        let row = MediaVersion.PickerPresentation(version)
        XCTAssertEqual(row.releaseName, "Film.2026.MULTi.2160p.WEB-DL.DDP5.1-GROUP.mkv")
        XCTAssertFalse(row.releaseName?.contains("\n") ?? true)
        XCTAssertEqual(version.name, providerName)
        XCTAssertEqual(version.playbackMediaSourceID, "original-id")
        XCTAssertTrue(version.audioLanguageNames().isEmpty, "Display text must not invent audio-track metadata.")
    }

    func testWrappedReleaseDescriptionsPreserveTheCompleteInternationalFilename() {
        let names = [
            ["Example.Brand.New.Day.2026.IMAX.MULTI.VF2.2160p.CORE.WEB-",
             "DL.DV.HDR10+.DDP.Atmos.5.1.HEVC-HYPERION.mkv"],
            ["Le.Fabuleux.Destin.d’Amélie.Édition.spéciale.2160p.",
             "WEB-DL.DDP5.1-GROUPE.mkv"],
            ["千と千尋の神隠し.特別版.日本語.2160p.",
             "WEB-DL.HEVC-グループ.mkv"],
            ["رحلة.إلى.القمر.نسخة.خاصة.2160p.",
             "WEB-DL.HEVC-مجموعة.mkv"]
        ]
        for parts in names {
            for marker in ["🗂️", "📁", "📂"] {
                let description = "2160p • WEB-DL\r\n\(marker) \(parts.joined(separator: "\r\n  "))\r\n🌐 English | Multi"
                let version = MediaVersion(id: "source", name: description, height: 2160)
                let row = MediaVersion.PickerPresentation(version)
                XCTAssertEqual(row.releaseName, parts.joined(), description)
                XCTAssertEqual(version.name, description)
                XCTAssertEqual(version.playbackMediaSourceID, "source")
                XCTAssertTrue(row.audioLanguages.isEmpty, "Description text is not a track inventory.")
            }
        }
        XCTAssertEqual(
            MediaSourceDisplayName.name(from: "📁 Complete.mkv\nUnrelated field"),
            "Complete.mkv"
        )
        XCTAssertEqual(
            MediaSourceDisplayName.name(from: "📁 Incomplete\n🌐 English\nAnother.mkv"),
            "Incomplete"
        )
    }

    func testFileSizeUsesAtMostOneFractionDigit() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(
            MediaFileSizeFormatter.string(
                fromByteCount: 65_270_000_000,
                locale: locale
            ),
            "65.3 GB"
        )
        XCTAssertEqual(
            MediaFileSizeFormatter.string(
                fromByteCount: 682_600_000,
                locale: locale
            ),
            "682.6 MB"
        )
        XCTAssertEqual(
            MediaFileSizeFormatter.string(
                fromByteCount: 12_000_000_000,
                locale: locale
            ),
            "12 GB"
        )
    }

    func testExplicitSourceSizesDistinguishBytesFromBitratesAndFilenames() {
        let cases: [(String, Int64?)] = [
            ("🌍 MULTI | 27 Mb | 26,2 Go", 26_200_000_000),
            ("📦 87.8 GB (80.7 Mbps)", 87_800_000_000),
            ("Size 946 Mo", 946_000_000),
            ("Size 1.5 GiB", 1_610_612_736),
            ("Size 1 TB", 1_000_000_000_000),
            ("Size 26,2\u{00a0}Go", 26_200_000_000),
            ("26.2 GB | 26.2 GB", 26_200_000_000),
            ("27 Mb | 26 Mbps | 26 MB/s | 26 MB / s", nil),
            ("Movie.26 GB.mkv", nil),
            ("📁 Movie.26 GB.mkv", nil),
            ("26.2 GB\n📁 Movie.99 GB.mkv", 26_200_000_000),
            ("https://media.example/26 GB.mkv?token=fixture", nil),
            ("Source?size=26 GB", nil),
            ("26 GB | 12 GB", nil),
            ("-26 GB", nil),
            ("1,234.5 GB", nil),
            ("0 GB", nil),
            ("9999999999999999999 TB", nil)
        ]
        for (description, expected) in cases {
            XCTAssertEqual(MediaSourceDisplayName.declaredFileSizeBytes(from: description), expected, description)
        }
    }

    func testDeclaredLanguagesReadOnlyNamedSourceFieldsWithoutCountingMulti() {
        let cases: [(String?, [String])] = [
            ("🌍 French | Multi | English", ["fr", "en"]),
            ("🌐 ENGLISH | English | eng | MULTI | French", ["en", "fr"]),
            ("Audio • English • French\r\n📁 Film.MULTI.VF2.mkv", ["en", "fr"]),
            ("Audio languages: Japanese, Korean, Chinese, Arabic", ["ja", "ko", "zh", "ar"]),
            ("Languages: German | Spanish | Italian | Portuguese", ["de", "es", "it", "pt"]),
            ("🌎 French\n🌏 English", ["fr", "en"]),
            ("🇫🇷 🇨🇦 🇬🇧 ✓ • 💾 87,8 Go • 🔎 Source", ["fr", "en"]),
            ("🌍 🇫🇷 🇨🇦 🇬🇧 • 💾 87,8 Go • 🔎 Source", ["fr", "en"]),
            ("🇫🇷 🇬🇧 ✓ • 💾 26,2 Go • 🔎 Source", ["fr", "en"]),
            ("🌍 🇫🇷 • 💾 26,2 Go • 🔎 Source • 🔗 Source", ["fr"]),
            ("🇬🇧 💬 ✓ • 💾 27,2 Go • 🔎 Source", ["en"]),
            ("🌍 🇯🇵 🇵🇹 🇧🇷 • 💾 3 GB", ["ja", "pt"]),
            ("🌍 🇨🇦 • 💾 3 GB", []),
            ("🌍 Region 🇫🇷 • 💾 3 GB", []),
            ("Subtitles 🇫🇷 • 💾 3 GB", []),
            ("🌍 🇫🇷 • 3 GB", []),
            ("🌍 🇫🇷 • 💾 unknown", []),
            ("🌍 🇫🇷 • 💾 3 Mbps", []),
            ("🌍 Multi", []),
            ("🌍 MULTI | 27 Mb | 26,2 Go", []),
            ("🌍 Subtitles: French | English", []),
            ("Subtitles: French | English", []),
            ("🌍 France | Canada", []),
            ("🇫🇷 MULTI | 🇺🇸", []),
            ("Film.English.French.MULTI.VF2.mkv", []),
            ("📁 Film.mkv\n🌍 French | English", []),
            ("📁 Film.mkv\n🇫🇷 🇬🇧 ✓ • 💾 26,2 Go", []),
            ("🗂️ Film.\nFrench.English.mkv\n🌍 French | English", []),
            ("https://fixture.test/stream?name=🌍 French | English", []),
            ("🌍 https://fixture.test/French | English", []),
            ("🌍 English | und | mul | zxx", []),
            (nil, [])
        ]
        for (description, expected) in cases {
            XCTAssertEqual(
                MediaSourceDisplayName.declaredAudioLanguages(from: description), expected,
                description ?? "nil"
            )
        }
    }

    func testCompactSummaryCombinesSizeQualityAndRuntimeWithoutEmptyRows() {
        let version = MediaVersion(
            id: "file", fileName: "Film.REMUX.mkv", height: 2160,
            sizeBytes: 42_000_000_000, duration: 7_200
        )
        XCTAssertEqual(MediaVersion.PickerPresentation(version).summaryWithoutBadges, "42 GB · Remux · 2h")
        XCTAssertNil(MediaVersion.PickerPresentation(.init(id: "unknown")).summaryWithoutBadges)
        XCTAssertEqual(MediaVersion.PickerPresentation(.init(id: "duration", duration: 7_200)).summaryWithoutBadges, "2h")
    }

    func testFilenameWrappingPreservesVisibleCharactersAndOriginalIdentity() {
        for name in [
            "Spider-Man.Brand.New.Day.2026.IMAX.MULTI.VF2.2160p.CORE.WEB-DL.DV.HDR10+.DDP.Atmos.5.1.HEVC-HYPERION.mkv",
            "Amélie_Édition.spéciale.mkv", "千と千尋の神隠し_日本語.mkv", "رحلة.إلى.القمر.mkv"
        ] {
            let wrapped = MediaSourceDisplayName.wrappingFileName(name)
            XCTAssertEqual(wrapped.replacingOccurrences(of: "\u{200B}", with: ""), name)
            XCTAssertTrue(wrapped.contains(".\u{200B}"))
            XCTAssertEqual(MediaVersion.PickerPresentation(.init(id: "file", fileName: name)).releaseName, name)
        }
    }

    func testQualityScoreRanksHDRAndResolution() {
        let uhdHDR = MediaVersion(id: "1", height: 2160, videoRange: "HDR10")
        let uhdSDR = MediaVersion(id: "2", height: 2160, videoRange: "SDR")
        let hd = MediaVersion(id: "3", height: 1080, videoRange: "SDR")
        XCTAssertGreaterThan(uhdHDR.qualityScore, uhdSDR.qualityScore)
        XCTAssertGreaterThan(uhdSDR.qualityScore, hd.qualityScore)
    }

    // MARK: - Compatibility prediction

    func testCompatibilityUnknownWithoutCodec() {
        let v = MediaVersion(id: "1", height: 1080)
        XCTAssertEqual(v.compatibility(with: .default), .unknown)
    }

    func testCompatibilityDirectPlayForSupportedH264AAC() {
        // h264 + SDR + AAC is universally decodable on any Apple TV 4K.
        let v = MediaVersion(id: "1", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        XCTAssertEqual(v.compatibility(with: .default), .directPlay)
    }

    func testCompatibilityTranscodeWhenHDRUnsupported() {
        // Dolby Vision falls outside the default native profile. The provider or
        // Plozzigen may still handle it without a server transcode.
        let dovi = MediaVersion(id: "1", height: 2160, videoCodec: "hevc", videoRange: "DOVI", audioCodec: "aac")
        XCTAssertEqual(dovi.compatibility(with: .default), .transcode)

        let doviCapable = MediaCapabilities(supportsDolbyVision: true)
        XCTAssertEqual(dovi.compatibility(with: doviCapable), .directPlay)
    }

    func testCompatibilityTranscodeWhenVideoCodecUnsupported() {
        let av1 = MediaVersion(id: "1", height: 2160, videoCodec: "av1", videoRange: "SDR", audioCodec: "aac")
        XCTAssertEqual(av1.compatibility(with: .default), .transcode) // default native profile has no AV1
        XCTAssertEqual(av1.compatibility(with: MediaCapabilities(supportsAV1: true)), .directPlay)
    }

    func testCompatibilityTranscodeForDTSWithoutPassthrough() {
        let dts = MediaVersion(id: "1", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "dts")
        XCTAssertEqual(dts.compatibility(with: .default), .transcode)
        XCTAssertEqual(dts.compatibility(with: MediaCapabilities(supportsDTSPassthrough: true)), .directPlay)
    }

    // MARK: - Recommended selection (smart default)

    func testRecommendedSelectionPicksBestDirectPlayable() {
        // On a default (non-DoVi) profile, the conservative recommended default is
        // the highest-quality known-native version — the 1080p.
        let versions = [
            MediaVersion(id: "4k", height: 2160, isDefault: true, videoCodec: "hevc", videoRange: "DOVI", audioCodec: "aac"),
            MediaVersion(id: "1080", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        ]
        XCTAssertEqual(versions.recommendedSelection(for: .default)?.id, "1080")
    }

    func testRecommendedSelectionPrefersDirectPlayUHDWhenCapable() {
        // A DoVi-capable device direct-plays the 4K, so it wins.
        let versions = [
            MediaVersion(id: "4k", height: 2160, videoCodec: "hevc", videoRange: "DOVI", audioCodec: "aac"),
            MediaVersion(id: "1080", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        ]
        XCTAssertEqual(versions.recommendedSelection(for: MediaCapabilities(supportsDolbyVision: true))?.id, "4k")
    }

    func testRecommendedSelectionFallsBackToServerDefaultWhenNoneDirectPlay() {
        // Device can't HEVC-decode anything offered → fall back to server default.
        let caps = MediaCapabilities(supportsHEVC: false)
        let versions = [
            MediaVersion(id: "a", height: 2160, videoCodec: "hevc", videoRange: "SDR", audioCodec: "aac"),
            MediaVersion(id: "b", height: 2160, isDefault: true, videoCodec: "hevc", videoRange: "SDR", audioCodec: "aac")
        ]
        XCTAssertEqual(versions.recommendedSelection(for: caps)?.id, "b")
    }

    func testRecommendedSelectionEmptyIsNil() {
        XCTAssertNil([MediaVersion]().recommendedSelection(for: .default))
    }

    func testPickerOrderSortsKnownSizesLargestFirstAndUnknownLast() {
        let versions = [
            MediaVersion(id: "small", height: 2160, sizeBytes: 5_510_000_000),
            MediaVersion(id: "unknown", height: 4320),
            MediaVersion(id: "largest", height: 2160, sizeBytes: 65_270_000_000),
            MediaVersion(id: "medium", height: 480, sizeBytes: 11_410_000_000)
        ]

        XCTAssertEqual(
            versions.sortedForPicker().map(\.id),
            ["largest", "medium", "small", "unknown"]
        )
    }
}
