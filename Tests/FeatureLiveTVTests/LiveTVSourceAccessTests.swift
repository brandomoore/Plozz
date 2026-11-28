#if DEBUG
import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVSourceAccessTests: XCTestCase {
    func testAdultSourceManagementDoesNotRequireTheHouseholdPIN() throws {
        let (profiles, suite) = makeProfiles()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)))
        let access = LiveTVSourceManagementAccess(profiles: profiles)
        XCTAssertTrue(access.canManage)
    }

    func testKidsOnlyRequireUnlockWhenAParentalPINExists() throws {
        let (profiles, suite) = makeProfiles()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let child = profiles.add(name: "Child", isKidsProfile: true)
        profiles.select(child.id)
        let access = LiveTVSourceManagementAccess(profiles: profiles)
        XCTAssertTrue(access.canManage)
        profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)))
        XCTAssertFalse(access.canManage)
        access.unlock("0000")
        XCTAssertFalse(access.canManage)
        access.unlock("1234")
        XCTAssertTrue(access.canManage)
        access.lock()
        XCTAssertFalse(access.canManage)
    }

    func testChangingTheParentalPINRevokesAnExistingGrant() throws {
        let (profiles, suite) = makeProfiles()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let child = profiles.add(name: "Child", isKidsProfile: true)
        profiles.select(child.id)
        profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)))
        let access = LiveTVSourceManagementAccess(profiles: profiles)
        access.unlock("1234")
        XCTAssertTrue(access.canManage)
        profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "5678", iterations: 1)))
        XCTAssertFalse(access.canManage)
        access.unlock("5678")
        XCTAssertTrue(access.canManage)
    }

    func testAProfileSwitchCannotAuthorizeThePreviousProfilesEditor() {
        let (profiles, suite) = makeProfiles()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let originalID = profiles.activeProfileID
        let access = LiveTVSourceManagementAccess(profiles: profiles)
        XCTAssertTrue(access.canManage)
        let other = profiles.add(name: "Another adult")
        profiles.select(other.id)
        XCTAssertFalse(access.canManage)
        XCTAssertTrue(LiveTVSourceManagementAccess(profiles: profiles).canManage)
        profiles.select(originalID)
        XCTAssertFalse(access.canManage)
        XCTAssertTrue(LiveTVSourceManagementAccess(profiles: profiles).canManage)
    }

    func testReplacingThenClearingTheProfileLockRevokesTheRetainedGrant() throws {
        let (profiles, suite) = makeProfiles()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        var child = profiles.add(name: "Child", isKidsProfile: true)
        profiles.select(child.id)
        profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)))
        let access = LiveTVSourceManagementAccess(profiles: profiles)
        access.unlock("1234")
        let canManage = { access.canManage }
        XCTAssertTrue(canManage())

        child.replaceLock(with: try XCTUnwrap(ProfileLock.make(pin: "1357", iterations: 1)))
        profiles.update(child)
        child.replaceLock(with: nil)
        profiles.update(child)
        XCTAssertFalse(canManage())
        access.unlock("1234")
        XCTAssertFalse(canManage())
    }

    func testChangingKidsStatusRequiresReopeningEvenAfterTheOriginalStatusReturns() throws {
        let (profiles, suite) = makeProfiles()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        var child = profiles.add(name: "Child", isKidsProfile: true)
        profiles.select(child.id)
        profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)))
        let access = LiveTVSourceManagementAccess(profiles: profiles)
        access.unlock("1234")
        XCTAssertTrue(access.canManage)

        child.isKids = false
        profiles.update(child)
        XCTAssertFalse(access.canManage)
        child.isKids = true
        profiles.update(child)
        access.unlock("1234")
        XCTAssertFalse(access.canManage)
        let reopened = LiveTVSourceManagementAccess(profiles: profiles)
        reopened.unlock("1234")
        XCTAssertTrue(reopened.canManage)
    }

    func testAutomaticChannelsUseTheSourceManagementPINGrantAndRevokeIt() async throws {
        let (profiles, suite) = makeProfiles()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let child = profiles.add(name: "Child", isKidsProfile: true)
        profiles.select(child.id)
        profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)))
        let access = LiveTVSourceManagementAccess(profiles: profiles)
        let action = LiveTVAutomaticChannelsAction()
        var changes: [Bool] = []
        let state = LiveTVAutomaticChannelsState(
            enabled: false, isWorking: false, issue: nil, channelCount: 0, skippedItemCount: 0,
            setEnabled: { changes.append($0) }, retry: {})
        await action.setEnabled(true, state: state, canManage: { access.canManage })
        XCTAssertTrue(changes.isEmpty)
        access.unlock("1234")
        await action.setEnabled(true, state: state, canManage: { access.canManage })
        XCTAssertEqual(changes, [true])
        profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "5678", iterations: 1)))
        await action.setEnabled(true, state: state, canManage: { access.canManage })
        XCTAssertEqual(changes, [true])
    }

    private func makeProfiles() -> (ProfilesModel, String) {
        let suite = "LiveTVSourceAccessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ProfilesModel(store: ProfileStore(defaults: defaults)), suite)
    }
}
#endif
