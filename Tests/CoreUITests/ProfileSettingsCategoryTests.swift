import CoreUI
import XCTest

final class ProfileSettingsCategoryTests: XCTestCase {
    func testProfileCategoriesHaveOneCrossPlatformOrder() {
        XCTAssertEqual(ProfileSettingsCategory.allCases, [
            .playback, .subtitles, .liveTV, .libraries, .appearance, .screensNavigation, .trackers, .seerr, .language
        ])
        XCTAssertEqual(Set(ProfileSettingsCategory.allCases.map(\.id)).count, 9)
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
