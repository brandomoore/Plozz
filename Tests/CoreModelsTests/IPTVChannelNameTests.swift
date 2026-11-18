import XCTest
@testable import CoreModels

final class IPTVChannelNameTests: XCTestCase {
    func testPreviewPrefersChangedDistinctNamesWithoutRewritingTheirOriginals() {
        let names = [
            "BBC One HD", "BBC: News", "## BBC One H D ##", "** BBC One H D **",
            "|UK| Sky Sports 1", "Canal+ F H D", "## Fourth H D ##"
        ]
        XCTAssertEqual(IPTVChannelName.previewSamples(from: names), [
            "## BBC One H D ##", "|UK| Sky Sports 1", "Canal+ F H D"
        ])
        XCTAssertEqual(IPTVChannelName.previewSamples(from: names.prefix(4)), [
            "## BBC One H D ##", "BBC: News"
        ])
    }

    func testPreviewUsesAvailableNamesWhenCleanupIsUnnecessaryAndNeverInventsChannels() {
        XCTAssertEqual(IPTVChannelName.previewSamples(from: ["", " \t\n"]), [])
        XCTAssertEqual(IPTVChannelName.previewSamples(from: [String]()), [])
        XCTAssertEqual(IPTVChannelName.previewSamples(from: [
            "BBC: News", "BBC: News", "Canal+", "Sky Sports 1", "Sky Sports 10"
        ]), ["BBC: News", "Canal+", "Sky Sports 1"])
    }

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

    func testByteCleanupMatchesTheUnicodeRulesForASCIINames() {
        let atoms = [
            "#", "##", "*", "**", "***", "|", "||", " ", "  ", "\t", "\n", "\r\n", "\r", "\u{0B}", "\u{0C}",
            "U", "F", "H", "D", "S", "HD", "FHD", "UHD", "SD", "hd", "4K", "8k", "HDR", "HDR10", "HEVC", "H264",
            "h.265", "H.264", "1080p", "60FPS", "50fps", "+1", "+", "P", "FPS", "(HD)", "[FHD]", "((4K))", "()",
            "[", ")", "US", "UK", "DE1", "ABCDEF", "A", "ab", "Us", "News", "Sport 1", "CNN", "x", "1", "22",
            "-", ":", "/", "\u{0}", "\u{1F}", "\u{7F}", ".", ",", "p", "fps", "720P", "P1", "1P", "++1", "+1P"
        ]
        var names = [
            "", " ", "####", "## ##", "##  a  ##", "#a#", "##a#", "** 1 **", "|US|", "|US| A", "| US | A B",
            "|us| CNN HD", "|ABCDEF| X Y", "HD", "HD HD", "A H D", "U H D", "A U H D", "A F H D 4K (1080p) +1",
            "4K| RELAX 1 3840P", "AFR| CANAL+ SPORT 1 FHD", "24/7 ACTION/ADVENTURE", "DE: Das Erste HD (1080p)"
        ]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed >> 33) % bound
        }
        for _ in 0..<20_000 {
            var name = ""
            for _ in 0..<next(9) {
                name += atoms[next(atoms.count)]
                if next(3) == 0 { name += " " }
            }
            names.append(name)
        }
        for name in names where IPTVChannelName.cleaned(name) != IPTVChannelName.cleanedUnicode(name) {
            XCTFail("Cleanup differs for \(name.debugDescription)")
            return
        }
        // Names outside ASCII keep the Unicode rules.
        XCTAssertEqual(IPTVChannelName.cleaned("Nyheter  \u{1D34}\u{1D30}"), "Nyheter HD")
        XCTAssertEqual(IPTVChannelName.cleaned("Café\u{00A0}Uno  H D"), "Café Uno HD")
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
