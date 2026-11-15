import XCTest
import CoreModels

final class ProviderIDNamespaceTests: XCTestCase {
    func testLookupPreservesAliasPriorityAndSkipsEmptyValues() {
        var ids = ["TheMovieDb": " 42 ", "TMDB ID": " 43 ", "TMDb": " 44 "]
        XCTAssertEqual(ids.providerID(.tmdb), "44")
        ids["TMDb"] = " \n "
        XCTAssertEqual(ids.providerID(.tmdb), "43")
        ids["TMDB ID"] = ""
        XCTAssertEqual(ids.providerID(.tmdb), "42")
        XCTAssertNil(ids.providerID(.imdb))
    }

    func testLookupPreservesFirstValidNormalizedSpelling() throws {
        let ids = ["TMDb": "41", "T-M-D-B": "42", "tmdb": " \n ", "TheMovieDb": "43"]
        let expected = try XCTUnwrap(ids.first {
            ["TMDb", "T-M-D-B"].contains($0.key)
        }?.value)
        XCTAssertEqual(ids.providerID(.tmdb), expected)
        XCTAssertEqual(ids.normalizedProviderIDs["tmdb"], expected)
    }

    func testNamespacesRetainCasePunctuationAndUnicodeNormalization() {
        for namespace in ProviderIDNamespace.allCases {
            let punctuated = namespace.canonicalKey.uppercased().map(String.init).joined(separator: "-")
            let ids = [punctuated: " \t123\n", "Unrelated": "ignored"]
            XCTAssertEqual(ids.providerID(namespace), "123", namespace.rawValue)
        }
        let ids = ["Wetra\u{212A}r": " 73 ", "TM\u{200D}Db": "74", "IMDb": "tt75"]
        XCTAssertEqual(ids.providerID(.wetrakr), "73")
        XCTAssertEqual(ids.providerID(.tmdb), "74")
        XCTAssertEqual(ids.providerID(.imdb), "tt75")
        XCTAssertNil(["\u{0130}mdb": "tt76"].providerID(.imdb))
        XCTAssertEqual(
            ["A-\u{00C9}\u{0662}": " value ", "Ignored": "\n"].normalizedProviderIDs,
            ["a\u{00E9}\u{0662}": "value"]
        )
    }
}
