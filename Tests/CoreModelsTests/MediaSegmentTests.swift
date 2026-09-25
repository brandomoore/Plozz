import XCTest
@testable import CoreModels

final class MediaSegmentTests: XCTestCase {
    func testEveryKnownKindIsSkippable() {
        for kind in MediaSegment.Kind.skippable {
            XCTAssertTrue(MediaSegment(kind: kind, start: 0, end: 5).isSkippable, "\(kind)")
        }
        XCTAssertFalse(MediaSegment(kind: .unknown, start: 0, end: 5).isSkippable)
        XCTAssertEqual(Set(MediaSegment.Kind.skippable + [.unknown]), Set(MediaSegment.Kind.allCases))
    }

    func testFillingAddsOnlyKindsThePrimaryLacks() {
        let server = [MediaSegment(id: "s-intro", kind: .intro, start: 10, end: 40)]
        let community = [
            MediaSegment(id: "c-intro", kind: .intro, start: 12, end: 42),
            MediaSegment(id: "c-credits", kind: .credits, start: 1200, end: 1260)
        ]
        let merged = server.filling(from: community)
        XCTAssertEqual(merged.map(\.id), ["s-intro", "c-credits"])
        XCTAssertEqual([MediaSegment]().filling(from: community).map(\.id), ["c-intro", "c-credits"])
    }

    func testCommunityLookupIsNeededUntilIntroAndCreditsAreBothMarked() {
        let intro = MediaSegment(kind: .intro, start: 10, end: 40)
        let credits = MediaSegment(kind: .credits, start: 1200, end: 1260)
        let recap = MediaSegment(kind: .recap, start: 0, end: 10)
        XCTAssertFalse([MediaSegment]().coversIntroAndCredits)
        XCTAssertFalse([intro, recap].coversIntroAndCredits)
        XCTAssertFalse([credits].coversIntroAndCredits)
        XCTAssertTrue([recap, intro, credits].coversIntroAndCredits)
    }

    func testContainsRespectsMargins() {
        let seg = MediaSegment(kind: .intro, start: 30, end: 60)
        XCTAssertTrue(seg.contains(40))
        // Lead-in tolerance: appears slightly before nominal start.
        XCTAssertTrue(seg.contains(29.9))
        // Excluded once within the trailing margin of the end.
        XCTAssertFalse(seg.contains(59.9))
        XCTAssertFalse(seg.contains(70))
    }

    func testActiveSkippablePicksContainingSegment() {
        let segments = [
            MediaSegment(kind: .intro, start: 10, end: 40),
            MediaSegment(kind: .credits, start: 1200, end: 1260),
            MediaSegment(kind: .unknown, start: 0, end: 8)
        ]
        XCTAssertEqual(segments.activeSkippable(at: 20)?.kind, .intro)
        XCTAssertEqual(segments.activeSkippable(at: 1230)?.kind, .credits)
        // Inside an unrecognised segment → no skip offered.
        XCTAssertNil(segments.activeSkippable(at: 4))
        // Outside every window.
        XCTAssertNil(segments.activeSkippable(at: 600))
    }

    func testActiveSkippablePrefersEarliestStartOnOverlap() {
        let segments = [
            MediaSegment(kind: .credits, start: 25, end: 80),
            MediaSegment(kind: .intro, start: 20, end: 50)
        ]
        XCTAssertEqual(segments.activeSkippable(at: 30)?.kind, .intro)
    }

    func testSkipActionLabels() {
        XCTAssertEqual(MediaSegment.Kind.intro.skipActionLabel, "Skip Intro")
        XCTAssertEqual(MediaSegment.Kind.credits.skipActionLabel, "Skip Credits")
    }

    func testRemainingCountsDownToZeroAtTrailingMargin() {
        let seg = MediaSegment(kind: .intro, start: 30, end: 90)
        // Near the start, almost the whole window remains.
        XCTAssertEqual(seg.remaining(at: 30), 59.75, accuracy: 0.001)
        XCTAssertEqual(seg.remaining(at: 60), 29.75, accuracy: 0.001)
        // At/after the trailing margin it clamps to zero.
        XCTAssertEqual(seg.remaining(at: 89.75), 0, accuracy: 0.001)
        XCTAssertEqual(seg.remaining(at: 200), 0, accuracy: 0.001)
    }

    func testRemainingFractionSpansOneToZero() {
        let seg = MediaSegment(kind: .credits, start: 100, end: 160)
        // Earliest visible point (start - margin) → full bar.
        XCTAssertEqual(seg.remainingFraction(at: 99.75), 1, accuracy: 0.001)
        XCTAssertEqual(seg.remainingFraction(at: 130), 0.5, accuracy: 0.01)
        XCTAssertEqual(seg.remainingFraction(at: 159.75), 0, accuracy: 0.001)
        // Clamped outside the window.
        XCTAssertEqual(seg.remainingFraction(at: 300), 0, accuracy: 0.001)
    }

    func testRemainingFractionZeroForDegenerateWindow() {
        let seg = MediaSegment(kind: .intro, start: 50, end: 50)
        XCTAssertEqual(seg.window, 0, accuracy: 0.001)
        XCTAssertEqual(seg.remainingFraction(at: 50), 0, accuracy: 0.001)
    }

    func testCodableRoundTrip() throws {
        let seg = MediaSegment(id: "abc", kind: .credits, start: 12.5, end: 99.0)
        let data = try JSONEncoder().encode(seg)
        let decoded = try JSONDecoder().decode(MediaSegment.self, from: data)
        XCTAssertEqual(seg, decoded)
    }
}

final class PlaybackSettingsTests: XCTestCase {
    func testDefaultShowsASkipButtonForEveryKindAndUsesCommunityMarkers() {
        let settings = PlaybackSettings.default
        XCTAssertEqual(settings.skipIntros, .on)
        XCTAssertTrue(settings.skipModeOverrides.isEmpty)
        XCTAssertTrue(settings.useCommunityMarkers)
        for kind in MediaSegment.Kind.skippable {
            XCTAssertEqual(settings.skipMarkerModes.mode(for: kind), .on, "\(kind)")
        }
    }

    func testStoredOffStaysOffDespiteTheOnDefault() throws {
        let decoded = try JSONDecoder().decode(
            PlaybackSettings.self, from: Data(#"{"skipIntros":"off"}"#.utf8)
        )
        XCTAssertEqual(decoded.skipIntros, .off)
        XCTAssertFalse(decoded.skipMarkerModes.fetchesMarkers)
    }

    func testLenientDecodeOfEmptyPayload() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertEqual(decoded, .default)
    }

    func testDecodePreservesModeValue() throws {
        let data = Data(#"{"skipIntros":"autoInstant"}"#.utf8)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertEqual(decoded.skipIntros, .autoInstant)
        XCTAssertTrue(decoded.skipIntros.isAutomatic)
    }

    func testLegacyBooleanTrueMapsToOn() throws {
        let data = Data(#"{"skipIntros":true}"#.utf8)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertEqual(decoded.skipIntros, .on)
    }

    func testLegacyBooleanFalseMapsToOff() throws {
        let data = Data(#"{"skipIntros":false}"#.utf8)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
        XCTAssertEqual(decoded.skipIntros, .off)
    }

    func testRoundTripEncodeDecode() throws {
        for mode in SkipIntrosMode.allCases {
            let settings = PlaybackSettings(skipIntros: mode)
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: data)
            XCTAssertEqual(decoded.skipIntros, mode)
        }
    }

    func testOneModeCoversEveryKindUntilAKindIsSetSeparately() throws {
        // An install that predates per-kind modes: its one choice covers them all.
        let legacy = try JSONDecoder().decode(
            PlaybackSettings.self, from: Data(#"{"skipIntros":"autoDelay"}"#.utf8)
        )
        for kind in MediaSegment.Kind.skippable {
            XCTAssertEqual(legacy.skipMarkerModes.mode(for: kind), .autoDelay, "\(kind)")
        }
        XCTAssertEqual(legacy.skipMarkerModes.mode(for: .unknown), .off)

        var settings = legacy
        settings.skipModeOverrides = [.credits: .on, .commercial: .off]
        let modes = settings.skipMarkerModes
        XCTAssertEqual(modes.mode(for: .intro), .autoDelay)
        XCTAssertEqual(modes.mode(for: .credits), .on)
        XCTAssertEqual(modes.mode(for: .commercial), .off)
    }

    func testPerKindModesAndCommunitySwitchRoundTrip() throws {
        let settings = PlaybackSettings(
            skipIntros: .autoInstant,
            skipModeOverrides: [.intro: .autoInstant, .credits: .on, .recap: .off, .preview: .autoDelay],
            useCommunityMarkers: false
        )
        let decoded = try JSONDecoder().decode(
            PlaybackSettings.self, from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded, settings)
    }

    func testUnrecognisedStoredKindsAreDropped() throws {
        let decoded = try JSONDecoder().decode(
            PlaybackSettings.self,
            from: Data(#"{"skipModeOverrides":{"credits":"on","unknown":"autoInstant","sponsor":"off"}}"#.utf8)
        )
        XCTAssertEqual(decoded.skipModeOverrides, [.credits: .on])
    }

    func testMarkersAreFetchedWhileAnyKindSkips() {
        XCTAssertFalse(SkipMarkerModes.allOff.fetchesMarkers)
        XCTAssertTrue(SkipMarkerModes(base: .off, overrides: [.preview: .on]).fetchesMarkers)
        XCTAssertFalse(SkipMarkerModes(base: .on, overrides: Dictionary(
            uniqueKeysWithValues: MediaSegment.Kind.skippable.map { ($0, .off) }
        )).fetchesMarkers)
    }

    func testModeFlags() {
        XCTAssertFalse(SkipIntrosMode.off.fetchesMarkers)
        XCTAssertTrue(SkipIntrosMode.on.fetchesMarkers)
        XCTAssertFalse(SkipIntrosMode.on.isAutomatic)
        XCTAssertTrue(SkipIntrosMode.autoDelay.isAutomatic)
        XCTAssertTrue(SkipIntrosMode.autoInstant.isAutomatic)
    }
}
