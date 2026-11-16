import CoreUI
import XCTest

final class ProfileSettingsCategoryTests: XCTestCase {
    func testProfileCategoriesHaveOneCrossPlatformOrder() {
        var expected: [ProfileSettingsCategory] = [.playback, .subtitles, .liveTV, .libraries]
        #if os(iOS)
        expected.append(.downloads)
        #endif
        expected += [.appearance, .screensNavigation, .trackers, .seerr, .language]
        XCTAssertEqual(ProfileSettingsCategory.allCases, expected)
        XCTAssertEqual(Set(ProfileSettingsCategory.allCases.map(\.id)).count, expected.count)
    }

    func testSummariesDescribeTheirGroupsRatherThanAnUnrelatedScope() {
        XCTAssertNotNil(ProfileSettingsCategory.appearance.summary)
        XCTAssertNotNil(ProfileSettingsCategory.screensNavigation.summary)
        XCTAssertEqual(
            ProfileSettingsCategory.trackers.summary,
            "Trakt, Simkl, WeTrakr, AniList, MyAnimeList, Last.fm"
        )
        XCTAssertNil(ProfileSettingsCategory.libraries.summary, "Libraries uses the actual included sources.")
        XCTAssertTrue(ProfileSettingsCategory.allCases.allSatisfy { !$0.symbol.isEmpty })
    }
}
