import XCTest
@testable import CoreModels

final class IPTVChannelNameTests: XCTestCase {
    func testDecorationsAndTrailingQualitySpacingAreCleanedWithoutDiscardingTags() {
        let examples = [
            ("## UK|NOW TV SPORT U H D 3840P ##", "UK | NOW TV SPORT UHD 3840P"),
            ("** |UK| BBC One H D **", "UK | BBC One HD"),
            (" \tCanal+  F H D HEVC 50FPS\n", "Canal+ FHD HEVC 50FPS"),
            ("BBC One \u{1D34}\u{1D30}", "BBC One HD"),
            ("BBC One \u{1DA0}\u{1D34}\u{1D30} +1", "BBC One FHD +1"),
            ("Sports U H D 10", "Sports UHD 10")
        ]
        for (source, expected) in examples {
            XCTAssertEqual(IPTVChannelName.cleaned(source), expected, source)
            XCTAssertEqual(IPTVChannelName.cleaned(expected), expected, "Cleanup must not be cumulative")
        }
    }

    func testAmbiguousNamesAndFeedDistinctionsArePreserved() {
        for name in [
            "BBC: News", "CNN | International", "Sky - Sports F1", "DUNE - Part Two",
            "Canal+", "BBC One +1", "Sky Sports 1", "Sky Sports 10",
            "UK - BBC One HD", "US: BBC America", "BBC One London", "BBC One Scotland",
            "Shdtv", "UHDTV", "HDSports", "H D Television", "S D Channel",
            "Now TV 3840P", "[UK] BBC One (1080p)", "##", "####", "**", "#Music",
            "## News", "News ##", "## + ##", "", "Café Télévision", "日本テレビ"
        ] {
            XCTAssertEqual(IPTVChannelName.cleaned(name), name)
        }
    }
}
