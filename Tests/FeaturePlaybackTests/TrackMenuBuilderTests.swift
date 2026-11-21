import XCTest
import SwiftUI
import CoreModels
@testable import FeaturePlayback

@MainActor
final class SubtitleMenuAvailabilityTests: XCTestCase {
    func testDownloadsKeepEmptySubtitleMenuReachableWithoutInventingTracks() {
        let model = controlsWithoutSystemAudio()
        model.engineCapabilities = []
        model.subtitleDownload.canSearch = true

        XCTAssertEqual(model.trackControlCategories, [.subtitles])
        XCTAssertFalse(model.hasSelectableSubtitles)
        XCTAssertTrue(model.subtitleOptions.isEmpty)
        XCTAssertEqual(model.subtitleTrackListFocus, .download)
    }

    func testEmptyUnsupportedSourceHasNoSubtitleControl() {
        let model = controlsWithoutSystemAudio()
        model.engineCapabilities = []

        XCTAssertFalse(model.subtitleDownload.canSearch)
        XCTAssertTrue(model.trackControlCategories.isEmpty)
        XCTAssertEqual(model.subtitleTrackListFocus, .edit)
    }

    func testExistingTracksKeepTheirSelectedFocusWithOrWithoutDownloads() {
        for canSearch in [false, true] {
            let model = controlsWithoutSystemAudio()
            model.engineCapabilities = []
            model.subtitleDownload.canSearch = canSearch
            model.subtitleOptions = [
                PlayerTrackOption(id: PlayerTrackOption.offID, title: Text("Off"), isSelected: false),
                PlayerTrackOption(id: 7, title: Text("English"), isSelected: true)
            ]

            XCTAssertEqual(model.trackControlCategories, [.subtitles])
            XCTAssertEqual(model.subtitleTrackListFocus, .row(1))
            model.subtitleOptions[0].isSelected = true
            model.subtitleOptions[1].isSelected = false
            XCTAssertEqual(model.subtitleTrackListFocus, .row(0))
        }
    }

    func testUnselectedTracksFocusTheFirstRealRow() {
        let model = controlsWithoutSystemAudio()
        model.subtitleDownload.canSearch = true
        model.subtitleOptions = [
            PlayerTrackOption(id: 7, title: Text("English"), isSelected: false)
        ]

        XCTAssertEqual(model.subtitleTrackListFocus, .row(0))
    }

    func testTrackRefreshKeepsDownloadsAvailableAndUsesAnExistingFocusTarget() {
        let model = controlsWithoutSystemAudio()
        model.engineCapabilities = []
        model.subtitleDownload.canSearch = true
        XCTAssertEqual(model.subtitleTrackListFocus, .download)

        model.subtitleOptions = [
            PlayerTrackOption(id: 7, title: Text("English"), isSelected: true, isExternal: true)
        ]
        XCTAssertEqual(model.subtitleTrackListFocus, .row(0))
        XCTAssertEqual(model.trackControlCategories, [.subtitles])

        model.subtitleOptions = []
        XCTAssertEqual(model.subtitleTrackListFocus, .download)
        XCTAssertEqual(model.trackControlCategories, [.subtitles])
    }

    func testDownloadOnlySubtitleControlPreservesOtherControlsAndTheirOrder() {
        let model = controlsWithoutSystemAudio()
        model.engineCapabilities = [.playbackSpeed]
        model.audioOptions = [
            PlayerTrackOption(id: 1, title: Text("English"), isSelected: true),
            PlayerTrackOption(id: 2, title: Text("French"), isSelected: false)
        ]
        model.subtitleDownload.canSearch = true
        XCTAssertEqual(model.trackControlCategories, [.audio, .subtitles, .speed])

        model.subtitleDownload.canSearch = false
        XCTAssertEqual(model.trackControlCategories, [.audio, .speed])
    }
}

@MainActor
final class AudioMenuAvailabilityTests: XCTestCase {
    func testSingleTrackIsReadOnlyAndAbsentFromTVFocusCategories() {
        let model = controlsWithoutSystemAudio()
        model.engineCapabilities = [.playbackSpeed]
        XCTAssertFalse(model.hasAudioControls)
        model.audioOptions = [.init(id: 1, title: Text("Dolby Digital 5.1"), isSelected: true)]
        XCTAssertFalse(model.hasSelectableAudio)
        XCTAssertFalse(model.hasAudioControls)
        XCTAssertEqual(model.trackControlCategories, [.speed])
        XCTAssertEqual(model.audioOptions.count, 1, "Hiding the control must not discard track metadata")
    }

    func testAlternateTrackAndDialogEnhanceEachKeepAudioReachable() {
        let model = controlsWithoutSystemAudio()
        model.audioOptions = [
            .init(id: 1, title: Text("English"), isSelected: true),
            .init(id: 2, title: Text("French"), isSelected: false)
        ]
        XCTAssertTrue(model.hasSelectableAudio)
        XCTAssertTrue(model.hasAudioControls)
        XCTAssertEqual(model.trackControlCategories, [.audio])
        model.audioOptions.removeLast()
        model.engineCapabilities = [.dialogEnhance]
        XCTAssertFalse(model.hasSelectableAudio)
        XCTAssertTrue(model.hasAudioControls)
        XCTAssertEqual(model.trackControlCategories, [.audio])
        model.audioOptions = []
        XCTAssertTrue(model.hasAudioControls)
        model.engineCapabilities = []
        XCTAssertFalse(model.hasAudioControls)
        XCTAssertTrue(model.trackControlCategories.isEmpty)
    }
}

/// Direct unit tests for `TrackMenuBuilder`, the pure collaborator that builds
/// the audio / subtitle / secondary-subtitle picker menus and the small
/// selection/eligibility decisions that feed them. These pin the fiddly rules
/// (audio-selection priority, "Off" pinning, preferred-language sort, bitmap
/// exclusion, engine-dual vs sidecar sourcing) that used to be buried in
/// `PlayerViewModel.loadTrackOptions`.
final class TrackMenuBuilderTests: XCTestCase {
    func testRepeatedFrenchSubtitlesUseFormatsBeforeNumbersWithoutLosingNamesOrFlags() {
        let tracks: [MediaTrack] = [
            .init(id: 1, kind: .subtitle, displayTitle: "French", language: "fr", codec: "srt", isForced: true),
            .init(id: 2, kind: .subtitle, displayTitle: "French", language: "fr", codec: "ass", isForced: true),
            .init(id: 3, kind: .subtitle, displayTitle: "French", language: "fr", codec: "subrip", isForced: true),
            .init(id: 4, kind: .subtitle, displayTitle: "French", language: "fr", codec: "srt"),
            .init(id: 5, kind: .subtitle, displayTitle: "French", language: "fr", codec: "webvtt", isExternal: true),
            .init(id: 6, kind: .subtitle, displayTitle: "French", sourceTitle: "Signs & Songs [Studio]",
                  language: "fr", codec: "ass"),
            .init(id: 7, kind: .subtitle, displayTitle: "French", language: "fr", codec: "srt", isHearingImpaired: true)
        ]
        let primary = TrackMenuBuilder.subtitleOptions(
            tracks: tracks, selectedID: 2, preferred: [], detectedLanguages: [:], locale: Locale(identifier: "en")
        )
        let secondary = TrackMenuBuilder.secondaryOptions(
            eligible: tracks, selectedID: 2, preferred: [], detectedLanguages: [:], locale: Locale(identifier: "en")
        )
        let expected = [
            "Off", "French (Forced, SRT) (Track 1)", "French (Forced, ASS)",
            "French (Forced, SRT) (Track 3)", "French (SRT)", "French (WebVTT)",
            "French (Signs & Songs [Studio])", "French (SDH)"
        ]
        for options in [primary, secondary] {
            XCTAssertEqual(options.map(\.nativeTitle), expected)
            XCTAssertEqual(options.map(\.id), [-1, 1, 2, 3, 4, 5, 6, 7])
            XCTAssertEqual(options.filter(\.isSelected).map(\.id), [2])
            XCTAssertEqual(Set(options.map(\.nativeTitle)).count, options.count)
        }
        XCTAssertTrue(primary.first { $0.id == 5 }!.isExternal)
        XCTAssertFalse(secondary.first { $0.id == 5 }!.isExternal)
        let qualifiers = Text(LocalizedStringResource("Forced", locale: Locale(identifier: "en")))
            + Text(verbatim: ", ") + Text(verbatim: "ASS")
        XCTAssertEqual(primary[2].title, Text(verbatim: "French") + Text(verbatim: " (")
            + qualifiers + Text(verbatim: ")"))
    }

    func testSubtitleFormatAliasesAndMissingFormatsRemainDistinctInLocalizedMenus() {
        let tracks: [MediaTrack] = [
            .init(id: 1, kind: .subtitle, displayTitle: "French", language: "fr", codec: "srt"),
            .init(id: 2, kind: .subtitle, displayTitle: "French", language: "fr", codec: "subrip"),
            .init(id: 3, kind: .subtitle, displayTitle: "French", language: "fr"),
            .init(id: 4, kind: .subtitle, displayTitle: "French", language: "fr", codec: "unrecognized"),
            .init(id: 5, kind: .subtitle, displayTitle: "French (SRT)")
        ]
        for localeID in ["en", "es", "fr", "zh-Hans"] {
            let locale = Locale(identifier: localeID)
            let options = TrackMenuBuilder.subtitleOptions(
                tracks: tracks, selectedID: 4, preferred: [], detectedLanguages: [:], locale: locale
            )
            XCTAssertEqual(Set(options.map(\.nativeTitle)).count, options.count)
            XCTAssertEqual(options.filter(\.isSelected).map(\.id), [4])
            for index in [1, 2] { XCTAssertTrue(options[index].nativeTitle.contains("SRT")) }
            for index in [3, 4] {
                XCTAssertFalse(options[index].nativeTitle.contains("SRT"))
                XCTAssertFalse(options[index].nativeTitle.contains("UNRECOGNIZED"))
            }
        }
    }

    func testOnlyCollidingLabelsGetStableTrackNumbersInAllMenus() {
        let tracks = [
            MediaTrack(id: 7, kind: .subtitle, displayTitle: "English", language: "en", codec: "srt"),
            MediaTrack(id: 8, kind: .subtitle, displayTitle: "English", language: "en", codec: "srt", isExternal: true),
            MediaTrack(id: 9, kind: .subtitle, displayTitle: "Spanish", language: "es", codec: "srt")
        ]
        for localeID in ["en", "es", "fr", "zh-Hans"] {
            let locale = Locale(identifier: localeID)
            let language = TrackLabeling.languageName(forCode: "en", in: locale)!
            let primary = TrackMenuBuilder.subtitleOptions(
                tracks: tracks, selectedID: 8, preferred: ["es"], detectedLanguages: [:], locale: locale
            )
            let secondary = TrackMenuBuilder.secondaryOptions(
                eligible: tracks, selectedID: 8, preferred: ["es"], detectedLanguages: [:], locale: locale
            )
            let audioTracks = tracks.map { track in
                var audio = track
                audio.kind = .audio
                audio.codec = nil
                return audio
            }
            let audio = TrackMenuBuilder.audioOptions(
                tracks: audioTracks, selectedID: 8, preferred: ["es"], locale: locale
            )
            for options in [primary, secondary, audio] {
                let rows = options.filter { $0.id != PlayerTrackOption.offID }
                XCTAssertEqual(rows.map(\.id), [9, 7, 8])
                XCTAssertEqual(rows.filter(\.isSelected).map(\.id), [8])
                XCTAssertEqual(rows[0].nativeTitle, TrackLabeling.languageName(forCode: "es", in: locale))
                for row in rows.dropFirst() {
                    let number = LocalizedStringResource("Track \(row.id)", locale: locale)
                    XCTAssertEqual(row.nativeTitle, "\(language) (\(String(localized: number)))")
                    XCTAssertEqual(row.title, Text(verbatim: language)
                        + (Text(verbatim: " (") + Text(number) + Text(verbatim: ")")))
                }
            }
            XCTAssertTrue(primary.first { $0.id == 8 }!.isExternal)
        }
    }

    func testNumberedLabelsCannotCollideWithAnAuthoredNameOrOff() {
        let tracks = [
            MediaTrack(id: 1, kind: .subtitle, displayTitle: "English", language: "en"),
            MediaTrack(id: 2, kind: .subtitle, displayTitle: "English", language: "en"),
            MediaTrack(id: 3, kind: .subtitle, displayTitle: "English (Track 1)"),
            MediaTrack(id: 4, kind: .subtitle, displayTitle: "Off")
        ]
        let options = TrackMenuBuilder.subtitleOptions(
            tracks: tracks, selectedID: nil, preferred: [], detectedLanguages: [:], locale: Locale(identifier: "en")
        )
        XCTAssertEqual(options.map(\.nativeTitle), [
            "Off", "English (Track 1) (Track 1)", "English (Track 2)", "English (Track 1)", "Off (Track 4)"
        ])
        XCTAssertEqual(Set(options.map(\.nativeTitle)).count, options.count)
        XCTAssertEqual(options.filter(\.isSelected).map(\.id), [-1])
    }

    func testAudioDescriptionReachesNativeAndSwiftUIMenusWithoutChangingSelection() {
        let options = TrackMenuBuilder.audioOptions(
            tracks: [
                .init(id: 1, kind: .audio, displayTitle: "English", language: "en"),
                .init(id: 2, kind: .audio, displayTitle: "English", language: "en", isVisualImpaired: true)
            ], selectedID: 1, preferred: [], locale: Locale(identifier: "en")
        )
        XCTAssertEqual(options.map(\.nativeTitle), ["English", "English (Audio Description)"])
        XCTAssertEqual(options.filter(\.isSelected).map(\.id), [1])
        XCTAssertEqual(options[1].title, Text(verbatim: "English") + Text(verbatim: " (")
            + Text(LocalizedStringResource("Audio Description", locale: Locale(identifier: "en"))) + Text(verbatim: ")"))
    }

    func testSharedAudioPrefixAndDuplicateDDPSpellingDoNotHideTheFormatChoice() {
        func track(_ id: Int, _ language: String, _ title: String, atmos: Bool = false) -> MediaTrack {
            .init(id: id, kind: .audio, displayTitle: title, sourceTitle: title, language: language,
                  codec: "eac3", channels: 6, isAtmos: atmos)
        }
        let tracks = [track(1, "en", "BTM DDP5.1 Atmos", atmos: true), track(2, "en", "BTM DDP5.1"),
                      track(3, "fr", "BTM DDP5.1")]
        func rows(_ input: [MediaTrack]) -> [String] {
            TrackMenuBuilder.audioOptions(tracks: input, selectedID: 1, preferred: [],
                                         locale: Locale(identifier: "en")).map(\.nativeTitle)
        }
        XCTAssertEqual(rows(tracks), ["English (Dolby Digital+ Atmos)", "English (Dolby Digital+ 5.1)",
                                      "French (Dolby Digital+ 5.1)"])
        XCTAssertEqual(rows([tracks[1], track(4, "en", "Director mix")]),
                       ["English (BTM, Dolby Digital+ 5.1)", "English (Director mix, Dolby Digital+ 5.1)"])
        var serverTracks = tracks
        serverTracks[0].displayTitle = "BTM DDP5.1 Atmos - English - Dolby Digital Plus + Dolby Atmos - Default"
        serverTracks[1].displayTitle = "BTM DDP5.1 - English - Dolby Digital+"
        XCTAssertEqual(rows(serverTracks), rows(tracks))
    }

    func testRegionalSubtitleRolesAreShownOnceAndFullIsOnlyAuthored() {
        let names = ["French (France) SDH", "French (France) (Forced)", "French (France)", "FULL"]
        let tracks = names.enumerated().map { i, title in
            MediaTrack(id: i, kind: .subtitle, displayTitle: title, sourceTitle: title, language: "fr",
                       codec: "srt", isForced: i == 1, isHearingImpaired: i == 0)
        }
        let options = TrackMenuBuilder.subtitleOptions(tracks: tracks, selectedID: 2, preferred: [],
                                                       detectedLanguages: [:], locale: Locale(identifier: "en"))
        XCTAssertEqual(options.map(\.nativeTitle), ["Off", "French (France) (SDH)", "French (France) (Forced)",
                                                    "French (France)", "French (FULL)"])
    }

    func testSampledServerMetadataHasDistinctLabelsAndStableSelections() throws {
        guard let path = ProcessInfo.processInfo.environment["PLOZZ_TRACK_METADATA_CORPUS"] else {
            throw XCTSkip("Set PLOZZ_TRACK_METADATA_CORPUS to a private, normalized metadata sample.")
        }
        struct Sample: Decodable {
            let group: String
            let id: Int
            let kind: String
            let displayTitle: String
            let sourceTitle: String?
            let language: String?
            let codec: String?
            let profile: String?
            let channels: Int?
            let isForced: Bool
            let isHearingImpaired: Bool
            let isCommentary: Bool
            let isVisualImpaired: Bool
            let isExternal: Bool
            let isDefault: Bool

            var track: MediaTrack {
                MediaTrack(
                    id: id, kind: kind == "audio" ? .audio : .subtitle,
                    displayTitle: displayTitle, sourceTitle: sourceTitle, language: language,
                    codec: codec, profile: profile, isDefault: isDefault, isForced: isForced, channels: channels,
                    isHearingImpaired: isHearingImpaired, isCommentary: isCommentary,
                    isVisualImpaired: isVisualImpaired, isExternal: isExternal
                )
            }
        }
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(samples.isEmpty)
        var collisions = 0
        var menuCount = 0
        var rendered: [[String: String]] = []
        for localeID in ["en", "es", "fr", "zh-Hans"] {
            let locale = Locale(identifier: localeID)
            for group in Dictionary(grouping: samples, by: \.group).values {
                let tracks = group.map(\.track)
                let audio = tracks.filter { $0.kind == .audio }
                let subtitles = tracks.filter { $0.kind == .subtitle }
                let primary = TrackMenuBuilder.subtitleOptions(
                    tracks: subtitles, selectedID: subtitles.last?.id, preferred: ["en"],
                    detectedLanguages: [:], locale: locale
                )
                let secondary = TrackMenuBuilder.secondaryOptions(
                    eligible: subtitles, selectedID: subtitles.last?.id, preferred: ["en"],
                    detectedLanguages: [:], locale: locale
                )
                let options = TrackMenuBuilder.audioOptions(
                    tracks: audio, selectedID: audio.last?.id, preferred: ["en"], locale: locale
                )
                for row in options + primary where row.id != PlayerTrackOption.offID {
                    let kind = options.contains(where: { $0.id == row.id }) ? "audio" : "subtitle"
                    if let sample = group.first(where: { $0.id == row.id && $0.kind == kind }) {
                        rendered.append([
                            "locale": localeID, "group": sample.group, "kind": sample.kind,
                            "sourceTitle": sample.sourceTitle ?? "", "displayTitle": sample.displayTitle,
                            "language": sample.language ?? "", "label": row.nativeTitle
                        ])
                    }
                }
                for (menu, input) in [(options, audio), (primary, subtitles), (secondary, subtitles)] {
                    let rows = menu.filter { $0.id != PlayerTrackOption.offID }
                    menuCount += 1
                    collisions += rows.count - Set(rows.map(\.nativeTitle)).count
                    XCTAssertEqual(rows.map(\.id), input.sortedByPreferredLanguage(["en"]).map(\.id))
                    XCTAssertEqual(rows.filter(\.isSelected).map(\.id), input.last.map { [$0.id] } ?? [])
                    XCTAssertTrue(rows.allSatisfy { !$0.nativeTitle.isEmpty })
                }
            }
        }
        print("Track corpus: \(samples.count) records, \(menuCount) menus, \(collisions) duplicate labels.")
        if let output = ProcessInfo.processInfo.environment["PLOZZ_TRACK_LABEL_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: rendered, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        XCTAssertEqual(collisions, 0, "Different selectable tracks must remain distinguishable.")
    }

    func testContainerNamesReachAudioAndBothSubtitleMenusWithoutChangingSelection() {
        let locale = Locale(identifier: "en")
        let provider = ["Full subs", "Signs & Songs"].enumerated().map { index, title in
            MediaTrack(id: index + 10, kind: .subtitle, displayTitle: "English",
                       sourceTitle: title, language: "en", codec: "srt")
        }
        let engine = provider.map {
            MediaTrack(id: $0.id, kind: .subtitle, displayTitle: "English", language: "en", codec: "srt")
        }
        let primary = TrackMenuBuilder.subtitleOptions(
            tracks: zip(engine, provider).map { $0.enriched(withProvider: $1) },
            selectedID: 11, preferred: ["en"], detectedLanguages: [:], locale: locale
        )
        let secondary = TrackMenuBuilder.secondaryOptions(
            eligible: engine, providerTracks: provider, selectedID: 11,
            preferred: ["en"], detectedLanguages: [:], locale: locale
        )
        for options in [primary, secondary] {
            XCTAssertEqual(options.map(\.id), [-1, 10, 11])
            XCTAssertEqual(options.filter(\.isSelected).map(\.id), [11])
            XCTAssertEqual(options.map(\.nativeTitle), ["Off", "English (Full subs)", "English (Signs & Songs)"])
            XCTAssertEqual(options[2].title,
                           Text(verbatim: "English") + Text(verbatim: " (")
                               + Text(verbatim: "Signs & Songs") + Text(verbatim: ")"))
        }
        let audio = TrackMenuBuilder.audioOptions(
            tracks: [.init(id: 4, kind: .audio, displayTitle: "English",
                           sourceTitle: "Director Commentary", language: "en", codec: "aac", channels: 2)],
            selectedID: 4, preferred: ["en"], locale: locale
        )
        XCTAssertEqual(audio[0].nativeTitle, "English (Director Commentary, AAC Stereo)")
        XCTAssertTrue(audio[0].isSelected)
        XCTAssertEqual(audio[0].title,
                       Text(verbatim: "English") + Text(verbatim: " (")
                           + (Text(verbatim: "Director Commentary") + Text(verbatim: ", ") + Text(verbatim: "AAC Stereo"))
                           + Text(verbatim: ")"))
    }

    func testSubtitleVersionsReachBothMenusWithNativeAndTVParity() {
        let versions = ["VFF", "VFQ"]
        let provider = versions.enumerated().map { index, version in
            MediaTrack(id: index + 10, kind: .subtitle, displayTitle: "French (\(version))",
                       language: "fr", codec: "subrip", isForced: true, isExternal: true)
        }
        let engine = provider.map {
            MediaTrack(id: $0.id, kind: .subtitle, displayTitle: "French",
                       language: "fr", codec: "subrip", isForced: true, isExternal: true)
        }
        for localeID in ["en", "fr", "es"] {
            let locale = Locale(identifier: localeID)
            let language = TrackLabeling.languageName(forCode: "fr", in: locale)!
            let primary = TrackMenuBuilder.subtitleOptions(
                tracks: zip(engine, provider).map { $0.enriched(withProvider: $1) },
                selectedID: 11, preferred: ["fr-CA"], detectedLanguages: [:], locale: locale
            )
            let secondary = TrackMenuBuilder.secondaryOptions(
                eligible: engine, providerTracks: provider, selectedID: 11,
                preferred: ["fr-CA"], detectedLanguages: [:], locale: locale
            )
            let forced = String(localized: LocalizedStringResource("Forced", locale: locale))
            for options in [primary, secondary] {
                XCTAssertEqual(options.map(\.id), [-1, 10, 11])
                XCTAssertEqual(options.filter(\.isSelected).map(\.id), [11])
                XCTAssertEqual(options.dropFirst().map(\.nativeTitle), versions.map { "\(language) (\($0), \(forced))" })
                for (option, version) in zip(options.dropFirst(), versions) {
                    XCTAssertEqual(
                        option.title,
                        Text(verbatim: language) + Text(verbatim: " (")
                            + (Text(verbatim: version) + Text(verbatim: ", ")
                               + Text(LocalizedStringResource("Forced", locale: locale)))
                            + Text(verbatim: ")")
                    )
                }
            }
            XCTAssertTrue(primary.dropFirst().allSatisfy(\.isExternal))
            XCTAssertTrue(secondary.allSatisfy { !$0.isExternal })
        }
    }

    func testFrenchVersionsHaveMatchingNativeAndTVLabelsAndStableSelection() {
        let versions = ["VFQ", "VFF", "VFI"]
        let tracks = versions.enumerated().map { index, version in
            MediaTrack(id: index + 10, kind: .audio, displayTitle: version,
                       language: "fr", codec: "dts", channels: 6)
        }
        for localeID in ["en", "fr", "es"] {
            let locale = Locale(identifier: localeID)
            let language = TrackLabeling.languageName(forCode: "fr", in: locale)!
            let options = TrackMenuBuilder.audioOptions(
                tracks: tracks, selectedID: 11, preferred: ["fr-CA"], locale: locale
            )
            XCTAssertEqual(options.map(\.id), [10, 11, 12])
            XCTAssertEqual(options.filter(\.isSelected).map(\.id), [11])
            XCTAssertEqual(options.map(\.nativeTitle), versions.map { "\(language) (\($0), DTS 5.1)" })
            for (option, version) in zip(options, versions) {
                XCTAssertEqual(
                    option.title,
                    Text(verbatim: language) + Text(verbatim: " (")
                        + (Text(verbatim: version) + Text(verbatim: ", ") + Text(verbatim: "DTS 5.1"))
                        + Text(verbatim: ")")
                )
            }
        }
    }

    func testNativeAndTVAudioLabelsRetainDetailedSourceProfiles() {
        let tracks = [
            MediaTrack(id: 1, kind: .audio, displayTitle: "English", language: "en", codec: "truehd",
                       profile: "Dolby TrueHD + Dolby Atmos", channels: 8),
            MediaTrack(id: 2, kind: .audio, displayTitle: "English", language: "en", codec: "dca",
                       profile: "MA + DTS:X IMAX", channels: 8),
            MediaTrack(id: 3, kind: .audio, displayTitle: "English", language: "en", codec: "eac3",
                       channels: 6, isAtmos: true),
            MediaTrack(id: 4, kind: .audio, displayTitle: "English", language: "en", codec: "dca",
                       profile: "DTS-HD MA", channels: 8, isDTSX: true)
        ]
        let formats = ["Dolby TrueHD Atmos", "DTS-HD MA + DTS:X IMAX", "Dolby Digital+ Atmos", "DTS-HD MA + DTS:X"]
        for selectedID in [1, 2, 4] {
            let options = TrackMenuBuilder.audioOptions(
                tracks: tracks, selectedID: selectedID, preferred: [], locale: .init(identifier: "en")
            )
            XCTAssertEqual(options.map(\.nativeTitle), formats.map { "English (\($0))" })
            XCTAssertEqual(options.filter(\.isSelected).map(\.id), [selectedID])
            for (option, format) in zip(options, formats) {
                XCTAssertEqual(option.title,
                               Text(verbatim: "English") + Text(verbatim: " (") + Text(verbatim: format) + Text(verbatim: ")"))
            }
        }
    }

    func testNativeSubtitleLabelsIncludeOffLanguageAndAccessibilityFacts() {
        let options = TrackMenuBuilder.subtitleOptions(
            tracks: [.init(id: 9, kind: .subtitle, displayTitle: "English", language: "en",
                           codec: "subrip", isHearingImpaired: true)],
            selectedID: 9, preferred: [], detectedLanguages: [:], locale: Locale(identifier: "en")
        )
        XCTAssertEqual(options.map(\.nativeTitle), ["Off", "English (SDH)"])
        XCTAssertEqual(options.map(\.id), [-1, 9])
        XCTAssertEqual(options.map(\.isSelected), [false, true])
    }

    func testBothPresentationsUseNormalizedSourceTrackAndActualSelection() {
        let options = TrackMenuBuilder.audioOptions(tracks: [
            MediaTrack(id: 1, kind: .audio, displayTitle: "AC3 5.1 (Default)", codec: "ac3", isDefault: true, channels: 6),
            MediaTrack(id: 2, kind: .audio, displayTitle: "AAC 2.0", codec: "aac", channels: 2)
        ], selectedID: 2, preferred: [], locale: .init(identifier: "en_US"))
        XCTAssertEqual(options[0].nativeTitle, "Dolby Digital 5.1")
        XCTAssertEqual(options[0].title, Text(verbatim: "Dolby Digital 5.1"))
        XCTAssertFalse(options[0].isSelected, "Container default is not current selection")
        XCTAssertEqual(options[1].nativeTitle, "AAC Stereo")
        XCTAssertTrue(options[1].isSelected)
    }

    func testNativeAudioTitlesKeepLanguageFormatAndCommentary() {
        let tracks = [MediaTrack(
            id: 1, kind: .audio, displayTitle: "Audio 1", language: "en", codec: "ac3",
            channels: 6, isCommentary: true
        )]
        let options = TrackMenuBuilder.audioOptions(tracks: tracks, selectedID: 1, preferred: [], locale: .init(identifier: "en_US"))
        XCTAssertEqual(options.first?.nativeTitle, "English (Dolby Digital 5.1, Commentary)")
        XCTAssertEqual(options.first?.isSelected, true)
    }

    func testBareLanguageProducesSameRichLabelForNativeAndTVMenus() {
        let options = TrackMenuBuilder.audioOptions(
            tracks: [.init(id: 4, kind: .audio, displayTitle: "English", language: "en", codec: "opus", channels: 6)],
            selectedID: 4, preferred: [], locale: .init(identifier: "en")
        )
        XCTAssertEqual(options.first?.nativeTitle, "English (Opus 5.1)")
        XCTAssertEqual(options.first?.title,
                       Text(verbatim: "English") + Text(verbatim: " (") + Text(verbatim: "Opus 5.1") + Text(verbatim: ")"))
        XCTAssertEqual(options.first?.id, 4)
        XCTAssertEqual(options.first?.isSelected, true)
    }

    func testNativeAudioTitlesRespectAppLocaleAndProviderContent() {
        let tracks = [audio(1, lang: "ja"), MediaTrack(id: 2, kind: .audio, displayTitle: "Director's mix")]
        let options = TrackMenuBuilder.audioOptions(tracks: tracks, selectedID: 1, preferred: [], locale: .init(identifier: "es"))
        XCTAssertEqual(options.first?.nativeTitle, "Japonés")
        XCTAssertEqual(options.last?.nativeTitle, "Director's mix")
    }

    func testRepeatedAudioMenuBuildsHaveStableNativeTitlesAndSelection() {
        let tracks = [audio(1, lang: "en"), audio(2, lang: "ja")]
        let first = TrackMenuBuilder.audioOptions(tracks: tracks, selectedID: 1, preferred: [], locale: .init(identifier: "en_US"))
        let second = TrackMenuBuilder.audioOptions(tracks: tracks, selectedID: 1, preferred: [], locale: .init(identifier: "en_US"))
        XCTAssertEqual(first.map(\.nativeTitle), second.map(\.nativeTitle))
        XCTAssertEqual(first.map(\.isSelected), second.map(\.isSelected))
    }

    private func audio(_ id: Int, lang: String? = nil, isDefault: Bool = false) -> MediaTrack {
        MediaTrack(id: id, kind: .audio, displayTitle: "Audio \(id)", language: lang, isDefault: isDefault)
    }

    private func sub(
        _ id: Int,
        lang: String? = nil,
        codec: String? = nil,
        isImageBased: Bool = false,
        hasSidecar: Bool = false,
        isExternal: Bool = false
    ) -> MediaTrack {
        MediaTrack(
            id: id,
            kind: .subtitle,
            displayTitle: "Sub \(id)",
            language: lang,
            codec: codec,
            deliverySource: hasSidecar ? .localFile(URL(fileURLWithPath: "/tmp/\(id).vtt")) : nil,
            isImageBasedSubtitle: isImageBased,
            isExternal: isExternal
        )
    }

    // MARK: - resolveSelectedAudioTrackID

    func testAudioSelectionPrefersPendingWhenPresent() {
        let tracks = [audio(1), audio(2)]
        // Engine not yet on the pending pick → keep pending, don't clear it.
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: 1, pending: 2, engineActive: 1, tracks: tracks)
        XCTAssertEqual(r.selected, 2)
        XCTAssertFalse(r.clearPending)
    }

    func testAudioSelectionClearsPendingOnceEngineConfirms() {
        let tracks = [audio(1), audio(2)]
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: 2, pending: 2, engineActive: 2, tracks: tracks)
        XCTAssertEqual(r.selected, 2)
        XCTAssertTrue(r.clearPending)
    }

    func testAudioSelectionPendingIgnoredWhenNotInTrackList() {
        let tracks = [audio(1), audio(2)]
        // pending 9 absent → fall through to engine active (2), clearing pending.
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: 1, pending: 9, engineActive: 2, tracks: tracks)
        XCTAssertEqual(r.selected, 2)
        XCTAssertTrue(r.clearPending)
    }

    func testAudioSelectionFallsBackToEngineActive() {
        let tracks = [audio(1), audio(2)]
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: nil, pending: nil, engineActive: 2, tracks: tracks)
        XCTAssertEqual(r.selected, 2)
        XCTAssertTrue(r.clearPending)
    }

    func testAudioSelectionDefaultFlagHeuristicOnlyWhenNothingKnown() {
        let tracks = [audio(1), audio(2, isDefault: true)]
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: nil, pending: nil, engineActive: nil, tracks: tracks)
        XCTAssertEqual(r.selected, 2)
        XCTAssertFalse(r.clearPending)
    }

    func testAudioSelectionDefaultFallsBackToFirstTrack() {
        let tracks = [audio(5), audio(6)]
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: nil, pending: nil, engineActive: nil, tracks: tracks)
        XCTAssertEqual(r.selected, 5)
    }

    func testAudioSelectionKeepsCurrentWhenNothingElseMatches() {
        let tracks = [audio(1), audio(2)]
        // current set, no pending, engineActive absent/unmatched → unchanged.
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: 2, pending: nil, engineActive: 99, tracks: tracks)
        XCTAssertEqual(r.selected, 2)
        XCTAssertFalse(r.clearPending)
    }

    // MARK: - audioOptions

    func testAudioOptionsSortPreferredLanguageFirstAndMarkSelected() {
        let tracks = [audio(1, lang: "jpn"), audio(2, lang: "eng")]
        let options = TrackMenuBuilder.audioOptions(tracks: tracks, selectedID: 1, preferred: ["eng"])
        XCTAssertEqual(options.map(\.id), [2, 1])       // English sorted to top
        XCTAssertTrue(options.first { $0.id == 1 }!.isSelected)
        XCTAssertFalse(options.first { $0.id == 2 }!.isSelected)
    }

    // MARK: - subtitleOptions

    func testSubtitleOptionsEmptyWhenNoTracks() {
        XCTAssertTrue(
            TrackMenuBuilder.subtitleOptions(tracks: [], selectedID: nil, preferred: [], detectedLanguages: [:]).isEmpty
        )
    }

    func testSubtitleOptionsPinOffFirstAndReflectSelection() {
        let tracks = [sub(1, lang: "eng"), sub(2, lang: "jpn")]
        let options = TrackMenuBuilder.subtitleOptions(
            tracks: tracks, selectedID: nil, preferred: ["eng"], detectedLanguages: [:]
        )
        XCTAssertEqual(options.first?.id, PlayerTrackOption.offID)
        XCTAssertEqual(options.first?.title, Text(LocalizedStringResource(
            "subtitlePicker.option.off",
            defaultValue: "Off",
            comment: "test expectation mirrors TrackMenuBuilder's resource key"
        )))
        XCTAssertTrue(options.first!.isSelected)         // "Off" is selected when primary is off
        XCTAssertEqual(options.dropFirst().map(\.id), [1, 2]) // eng first
    }

    func testSubtitleOptionsMarkExternalFlag() {
        let tracks = [sub(1, isExternal: true), sub(2)]
        let options = TrackMenuBuilder.subtitleOptions(
            tracks: tracks, selectedID: 1, preferred: [], detectedLanguages: [:]
        )
        XCTAssertTrue(options.first { $0.id == 1 }!.isExternal)
        XCTAssertFalse(options.first { $0.id == 2 }!.isExternal)
        XCTAssertFalse(options.first { $0.id == PlayerTrackOption.offID }!.isSelected)
        XCTAssertTrue(options.first { $0.id == 1 }!.isSelected)
    }

    // MARK: - eligibleSecondaryTracks

    func testSecondaryEligibilityBitmapPrimaryDisablesDual() {
        let engineTracks = [sub(1, codec: "pgs"), sub(2, hasSidecar: true)]
        let eligible = TrackMenuBuilder.eligibleSecondaryTracks(
            selectedPrimaryID: 1, engineTracks: engineTracks, providerTracks: engineTracks,
            engineSupportsDualDecode: false
        )
        XCTAssertTrue(eligible.isEmpty)
    }

    func testSecondaryEligibilityEngineDualSourcesFromEngineTracks() {
        // Engine-dual: embedded tracks (no sidecar) are eligible, primary + bitmap excluded.
        let engineTracks = [sub(1), sub(2), sub(3, codec: "pgs")]
        let eligible = TrackMenuBuilder.eligibleSecondaryTracks(
            selectedPrimaryID: 1, engineTracks: engineTracks, providerTracks: [],
            engineSupportsDualDecode: true
        )
        XCTAssertEqual(eligible.map(\.id), [2])   // 1 is primary, 3 is bitmap
    }

    func testSecondaryEligibilitySidecarRequiresDeliverySource() {
        let providerTracks = [sub(1, hasSidecar: true), sub(2), sub(3, hasSidecar: true)]
        let eligible = TrackMenuBuilder.eligibleSecondaryTracks(
            selectedPrimaryID: 1, engineTracks: [], providerTracks: providerTracks,
            engineSupportsDualDecode: false
        )
        XCTAssertEqual(eligible.map(\.id), [3])   // 1 is primary, 2 has no sidecar
    }

    // MARK: - secondaryOptions

    func testSecondaryOptionsEmptyWhenNoEligible() {
        XCTAssertTrue(
            TrackMenuBuilder.secondaryOptions(eligible: [], selectedID: nil, preferred: [], detectedLanguages: [:]).isEmpty
        )
    }

    func testSecondaryOptionsPinOffAndReflectSelection() {
        let options = TrackMenuBuilder.secondaryOptions(
            eligible: [sub(2, lang: "eng"), sub(3, lang: "jpn")],
            selectedID: 3, preferred: ["eng"], detectedLanguages: [:]
        )
        XCTAssertEqual(options.first?.id, PlayerTrackOption.offID)
        XCTAssertFalse(options.first!.isSelected)
        XCTAssertEqual(options.dropFirst().map(\.id), [2, 3])  // eng first
        XCTAssertTrue(options.first { $0.id == 3 }!.isSelected)
    }

    // MARK: - imagePrimaryFormat

    func testImagePrimaryFormatNilForTextPrimary() {
        let tracks = [sub(1, hasSidecar: true)]
        XCTAssertNil(TrackMenuBuilder.imagePrimaryFormat(
            selectedPrimaryID: 1, engineTracks: tracks, providerTracks: tracks
        ))
    }

    func testImagePrimaryFormatNilWhenPrimaryOff() {
        XCTAssertNil(TrackMenuBuilder.imagePrimaryFormat(
            selectedPrimaryID: nil, engineTracks: [sub(1, codec: "pgs")], providerTracks: []
        ))
    }

    func testImagePrimaryFormatReportsHintForBitmapPrimary() {
        let tracks = [sub(1, codec: "pgssub")]
        let hint = TrackMenuBuilder.imagePrimaryFormat(
            selectedPrimaryID: 1, engineTracks: tracks, providerTracks: tracks
        )
        XCTAssertNotNil(hint)
    }
}
