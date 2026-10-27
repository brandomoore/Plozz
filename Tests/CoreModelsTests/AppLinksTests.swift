import XCTest
@testable import CoreModels

final class AppLinksTests: XCTestCase {
    func testPrivacyPolicyUsesPublicHTTPSPage() {
        XCTAssertEqual(AppLinks.privacyPolicy.absoluteString, "https://plozz.app/privacy/")
    }

    func testDiscordUsesStablePublicShortlink() {
        XCTAssertEqual(AppLinks.discord.absoluteString, "https://plozz.app/discord")
    }
}
