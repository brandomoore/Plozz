import XCTest
@testable import CoreModels

final class ProfileReturnPolicyTests: XCTestCase {
    func testDefaultsPrioritizeAnyLocalOrPlexPIN() throws {
        let first = Profile(id: "first", name: "First")
        var second = Profile(id: "second", name: "Second")
        XCTAssertNil(ProfileReturnPolicy.delay(for: [], automaticallySignIn: false))
        XCTAssertNil(ProfileReturnPolicy.delay(for: [first], automaticallySignIn: false))
        XCTAssertEqual(ProfileReturnPolicy.delay(for: [first, second], automaticallySignIn: false), 300)
        second.lock = try XCTUnwrap(ProfileLock.make(pin: "1234", iterations: 1))
        XCTAssertEqual(ProfileReturnPolicy.delay(for: [second], automaticallySignIn: false), 0)
        XCTAssertEqual(ProfileReturnPolicy.delay(for: [first, second], automaticallySignIn: false), 0)
        second.lock = nil
        second = second.settingHomeUserBinding(
            .init(homeUserID: "parent", name: "Parent", requiresPIN: true),
            forPlexAccount: "plex"
        )
        XCTAssertEqual(ProfileReturnPolicy.delay(for: [second], automaticallySignIn: false), 0)
        XCTAssertEqual(ProfileReturnPolicy.delay(for: [first, second], automaticallySignIn: false), 0)
    }

    func testAutomaticSignInBypassesReturnPromptForEveryDefault() throws {
        let first = Profile(id: "first", name: "First")
        let second = Profile(id: "second", name: "Second")
        var locked = Profile(id: "locked", name: "Locked")
        locked.lock = try XCTUnwrap(ProfileLock.make(pin: "1234", iterations: 1))
        let plex = second.settingHomeUserBinding(
            .init(homeUserID: "parent", name: "Parent", requiresPIN: true),
            forPlexAccount: "plex"
        )
        for profiles in [[], [first], [first, second], [locked], [first, locked], [plex], [first, plex]] {
            XCTAssertNil(ProfileReturnPolicy.delay(for: profiles, automaticallySignIn: true))
        }
    }
}
