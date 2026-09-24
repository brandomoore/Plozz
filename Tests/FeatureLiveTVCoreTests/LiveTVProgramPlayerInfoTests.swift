import CoreModels
import FeatureLiveTVCore
import XCTest

final class LiveTVProgramPlayerInfoTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)

    func testSubtitlePrefersTheEpisodeTitleOverTheEpisodeNumber() {
        let info = program(subtitle: "The One Where", episode: "S02E03").playerInfo
        XCTAssertEqual(info.subtitle, "The One Where")
        XCTAssertEqual(info.summary, "The One Where – Synopsis.")
    }

    func testSubtitleFallsBackToTheEpisodeNumber() {
        XCTAssertEqual(program(subtitle: "", episode: "S02E03").playerInfo.subtitle, "S02E03")
    }

    func testCarriesTimingArtworkAndTitle() {
        let artwork = URL(string: "https://example.invalid/art.jpg")
        let info = program(subtitle: "", episode: nil, artwork: artwork).playerInfo
        XCTAssertEqual(info.title, "Show")
        XCTAssertEqual(info.start, start)
        XCTAssertEqual(info.end, start.addingTimeInterval(3_600))
        XCTAssertEqual(info.artworkURL, artwork)
        XCTAssertNil(info.subtitle)
        XCTAssertEqual(info.summary, "Synopsis.")
    }

    private func program(subtitle: String, episode: String?, artwork: URL? = nil) -> LiveTVPrototypeProgram {
        LiveTVPrototypeProgram(
            id: "p", channelID: "c", title: "Show", subtitle: subtitle,
            start: start, end: start.addingTimeInterval(3_600),
            details: LiveTVProgramDetails(description: "Synopsis.", episode: episode, artworkURL: artwork)
        )
    }
}
