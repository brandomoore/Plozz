import CoreModels
import Foundation
import XCTest
@testable import CoreSecureStore

final class TrackerSignInConsentTests: XCTestCase {
    func testFreshLocalAuthenticationSupersedesAnOlderSignOutOnReenable() throws {
        let suite = "TrackerLocalReauthentication.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flag = SyncSetupFeatureFlag(defaults: defaults)
        let cloud = TokenStore()
        let local = TokenStore()
        let box = SyncedTokenBox<String>(
            service: suite, account: "tracker", synced: cloud, local: local,
            allowsSync: { flag.allowsAutomaticSignInSync })
        flag.isEnabled = true
        try box.save("old")
        try box.clear()
        flag.isEnabled = false
        try box.save("new")
        flag.isEnabled = true
        XCTAssertEqual(box.load(), "new")
        XCTAssertEqual(cloud.values, ["tracker": "\"new\""])
        XCTAssertTrue(local.values.isEmpty)
    }

    func testReenabledSyncNeverMigratesPreservedCopyAcrossRemoteSignOut() throws {
        let service = "TrackerSignOut.\(UUID())"
        let cloud = TokenStore()
        let local = TokenStore()
        let box = SyncedTokenBox<String>(service: service, account: "tracker", synced: cloud, local: local,
                                         allowsSync: { true })
        try box.save("login")
        try SyncedTokenRegistry.preserveDeviceSignIn(account: "tracker", source: cloud, local: local)
        XCTAssertEqual(box.load(), "login")
        XCTAssertTrue(local.values.isEmpty)
        // Even a failed cleanup that left a local copy cannot override a tombstone.
        try local.setString("\"login\"", for: "tracker")
        try cloud.removeValue(for: "tracker")
        SyncedTokenRegistry.shared.markSignedOut(.init(service: service, account: "tracker"))
        XCTAssertNil(box.load())
        XCTAssertTrue(cloud.values.isEmpty)
    }
    func testPendingAndDeclinedConsentKeepTrackerSignInsLocal() throws {
        let suite = "TrackerSignInConsent.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flag = SyncSetupFeatureFlag(defaults: defaults)
        flag.prepareForLaunch(hasExistingInstallation: false)
        let cloud = TokenStore()
        let local = TokenStore()
        try cloud.setString("\"other-device\"", for: "tracker")
        let box = SyncedTokenBox<String>(
            service: suite, account: "tracker", synced: cloud, local: local,
            allowsSync: { flag.allowsAutomaticSignInSync }
        )
        XCTAssertNil(box.load(), "Onboarding must not adopt a remotely synchronized sign-in.")
        flag.isEnabled = false
        try box.save("local-sign-in")
        XCTAssertEqual(box.load(), "local-sign-in")
        XCTAssertEqual(cloud.values, ["tracker": "\"other-device\""])
        XCTAssertEqual(cloud.readCount, 0)
        try box.clear()
        XCTAssertNil(box.load())
        XCTAssertEqual(cloud.values, ["tracker": "\"other-device\""])
        XCTAssertEqual(cloud.readCount, 0)
    }

    func testEnablingSyncCanMigrateALocallyCreatedSignIn() throws {
        let suite = "TrackerSignInEnable.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flag = SyncSetupFeatureFlag(defaults: defaults)
        flag.prepareForLaunch(hasExistingInstallation: false)
        flag.isEnabled = false
        let cloud = TokenStore()
        let local = TokenStore()
        let box = SyncedTokenBox<String>(
            service: suite, account: "tracker", synced: cloud, local: local,
            allowsSync: { flag.allowsAutomaticSignInSync }
        )
        try box.save("local-sign-in")
        XCTAssertTrue(cloud.values.isEmpty)
        flag.isEnabled = true
        XCTAssertEqual(box.load(), "local-sign-in")
        XCTAssertEqual(cloud.values, ["tracker": "\"local-sign-in\""])
        XCTAssertTrue(local.values.isEmpty)
        try SyncedTokenRegistry.preserveDeviceSignIn(account: "tracker", source: cloud, local: local)
        flag.isEnabled = false
        let readsBeforeOptOut = cloud.readCount
        XCTAssertEqual(box.load(), "local-sign-in")
        XCTAssertEqual(cloud.readCount, readsBeforeOptOut)
        try box.clear()
        XCTAssertEqual(cloud.values, ["tracker": "\"local-sign-in\""])
    }

    func testPreservingSignInsDoesNotResurrectARemoteSignOut() throws {
        let cloud = TokenStore()
        let local = TokenStore()
        try local.setString("\"old-sign-in\"", for: "tracker")
        try SyncedTokenRegistry.preserveDeviceSignIn(
            account: "tracker", source: cloud, local: local, signedOut: true
        )
        XCTAssertTrue(local.values.isEmpty)
    }

    func testMissingSyncedCopyDoesNotDiscardALocalSignInThatHasNotUploaded() throws {
        let local = TokenStore()
        try local.setString("\"local-sign-in\"", for: "tracker")
        try SyncedTokenRegistry.preserveDeviceSignIn(account: "tracker", source: TokenStore(), local: local)
        XCTAssertEqual(local.values, ["tracker": "\"local-sign-in\""])
    }
}

private final class TokenStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var reads = 0
    var values: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    var readCount: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }
    func setString(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }
    func string(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return storage[key]
    }
    func readString(for key: String) throws -> String? { string(for: key) }
    func removeValue(for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}
