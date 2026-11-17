#if os(iOS) && DEBUG
import CoreModels
import CoreSecureStore
import CryptoKit
import FeatureAuth
import FeatureSyncCloud
import Foundation
import XCTest
@testable import AppShelliOS
@testable import FeatureLiveTVCore

/// Destructive LOCAL fixture: opt-in only, on a newly created, signed-out simulator.
/// The runner must create a new device, select only this suite, disable parallel
/// workers, and forward that device's UDID. Never run on a reused simulator.
/// Set TEST_RUNNER_PLOZZ_IOS_ERASURE_FIXTURE=fresh-owned-sandbox and
/// TEST_RUNNER_PLOZZ_IOS_ERASURE_FIXTURE_SIMULATOR_ID=<new device UDID> on
/// xcodebuild. Use Debug and the ad-hoc-signed PlozziOSPresentationTests host.
@MainActor
final class LiveTVLastSeenErasureEntryPointTests: XCTestCase {
    func testFirstRunResetErasesSnapshotsAndEvictedPreResetProfileKeys() async throws {
        let fixture = try await makeFixture()
        let oldProfileIDs = Set(fixture.app.profiles.profiles.map(\.id))

        XCTAssertTrue(fixture.app.resetToFirstRunForDebugging())

        try fixture.assertErased()
        XCTAssertEqual(fixture.app.profiles.profiles.count, 1)
        XCTAssertTrue(Set(fixture.profileIDs).isDisjoint(with: fixture.app.profiles.profiles.map(\.id)))
        XCTAssertTrue(Set(fixture.profileIDs).isSubset(of: oldProfileIDs))
        XCTAssertTrue(fixture.app.accountsProviders.accounts.isEmpty)
        XCTAssertFalse(fixture.app.profiles.firstRunProfileSetupComplete)
    }

    func testHouseholdErasureErasesSnapshotsAndKeysBeforeFailingFirstRunReset() async throws {
        let fixture = try await makeFixture()
        let oldProfileIDs = fixture.app.profiles.profiles.map(\.id)
        // Prevent the second cleanup in resetToFirstRunForDebugging from masking
        // a missing erase in performCloudSyncErasure. No accounts/providers exist.
        fixture.accountSecrets.rejectAccountRosterRemoval = true
        fixture.app.cloudServerErasureForTesting = { .completed }

        await fixture.app.eraseCloudSyncData().value

        XCTAssertEqual(fixture.app.cloudSyncStatus.recoveryResult, .failed)
        XCTAssertTrue(fixture.accountSecrets.didRejectAccountRosterRemoval)
        XCTAssertNotNil(fixture.app.accountError)
        XCTAssertEqual(fixture.app.profiles.profiles.map(\.id), oldProfileIDs)
        try fixture.assertErased()
    }

    func testHouseholdErasureCompletesFirstRunResetAndPreservesUnrelatedCatalogKey() async throws {
        let fixture = try await makeFixture()
        fixture.app.cloudServerErasureForTesting = { .completed }

        await fixture.app.eraseCloudSyncData().value

        XCTAssertEqual(fixture.app.cloudSyncStatus.recoveryResult, .completed)
        try fixture.assertErased()
        XCTAssertEqual(fixture.app.profiles.profiles.count, 1)
        XCTAssertTrue(Set(fixture.profileIDs).isDisjoint(with: fixture.app.profiles.profiles.map(\.id)))
        XCTAssertFalse(fixture.app.profiles.firstRunProfileSetupComplete)
    }

    func testHouseholdErasureRefusesKidsProfileWithoutDeletingSnapshotsOrKeys() async throws {
        let fixture = try await makeFixture()
        var active = fixture.app.profiles.activeProfile
        active.isKids = true
        fixture.app.profiles.update(active)
        fixture.app.cloudServerErasureForTesting = {
            XCTFail("An unauthorized profile must not reach the remote erasure boundary")
            return .completed
        }

        await fixture.app.eraseCloudSyncData().value

        XCTAssertEqual(fixture.app.cloudSyncStatus.recoveryResult, .unavailable)
        try fixture.assertRetained()
    }

    func testFailedRemoteHouseholdErasureDoesNotDeleteSnapshotsOrKeys() async throws {
        let fixture = try await makeFixture()
        fixture.app.cloudServerErasureForTesting = { .failed }

        await fixture.app.eraseCloudSyncData().value

        XCTAssertEqual(fixture.app.cloudSyncStatus.recoveryResult, .failed)
        try fixture.assertRetained()
    }

    func testHouseholdErasureRechecksAuthorizationBeforeLocalDeletion() async throws {
        let fixture = try await makeFixture()
        let app = fixture.app
        app.cloudServerErasureForTesting = { [weak app] in
            guard let app else { return .failed }
            var active = app.profiles.activeProfile
            active.isKids = true
            app.profiles.update(active)
            return .completed
        }

        await app.eraseCloudSyncData().value

        XCTAssertEqual(app.cloudSyncStatus.recoveryResult, .interrupted)
        try fixture.assertRetained()
    }

    private func makeFixture() async throws -> LastSeenErasureFixture {
        try requireOwnedSimulator()
        let directory = try XCTUnwrap(LiveTVLastSeenStore.defaultDirectory())
        // Refuse existing snapshots rather than clearing a potentially reused host.
        if FileManager.default.fileExists(atPath: directory.path) {
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard files.isEmpty else { throw FixtureError.nonemptySnapshotDirectory }
        }
        let suite = "LiveTVLastSeenErasureEntryPointTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let profileStore = ProfileStore(defaults: defaults)
        let profiles = ProfilesModel(store: profileStore)
        let active = profiles.add(name: "Fixture active", avatarSymbol: "person", colorIndex: 0)
        let evicted = profiles.add(name: "Fixture evicted", avatarSymbol: "person", colorIndex: 1)
        profiles.select(active.id)
        profileStore.setFirstRunProfileSetupComplete(true)
        let flag = SyncSetupFeatureFlag()
        flag.prepareForLaunch(hasExistingInstallation: false)
        flag.isEnabled = false
        let accountSecrets = ErasureAccountSecrets()
        let app = PlozziOSAppModel(
            appAdmissionStore: AppAdmissionStore(defaults: defaults),
            accountStore: AccountStore(secureStore: accountSecrets), profileStore: profileStore
        )
        let fixture = LastSeenErasureFixture(
            app: app, accountSecrets: accountSecrets, directory: directory,
            profileIDs: [active.id, evicted.id]
        )
        // Teardown is registered before any snapshot/key mutation. It removes only
        // this fixture's explicitly named keys/files, not a whole keychain service.
        addTeardownBlock { @MainActor in
            try fixture.removeOwnedData()
            defaults.removePersistentDomain(forName: suite)
        }
        XCTAssertTrue(app.accountsProviders.accounts.isEmpty)
        XCTAssertEqual(app.profiles.activeProfileID, active.id)
        XCTAssertFalse(app.profiles.activeProfile.isKids)
        XCTAssertTrue(app.profiles.firstRunProfileSetupComplete)
        XCTAssertFalse(app.managementRequiresParentalPIN)
        XCTAssertFalse(SyncSetupFeatureFlag().allowsAutomaticSync)
        await app.ensureTrackersScopedToActiveProfile()
        try await fixture.seed()
        return fixture
    }

    private func requireOwnedSimulator() throws {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLOZZ_IOS_ERASURE_FIXTURE"] == "fresh-owned-sandbox" else {
            throw XCTSkip("Requires a runner-created simulator and PLOZZ_IOS_ERASURE_FIXTURE=fresh-owned-sandbox")
        }
        let actualID = try XCTUnwrap(environment["SIMULATOR_UDID"])
        XCTAssertFalse(actualID.isEmpty)
        guard !actualID.isEmpty,
              environment["PLOZZ_IOS_ERASURE_FIXTURE_SIMULATOR_ID"] == actualID,
              Bundle.main.bundleIdentifier == "com.thatcube.Plozz.PresentationHost",
              PlozziOSAppModel.isRunningUnitTests else {
            throw FixtureError.unownedSandbox
        }
        let simulatorData = try XCTUnwrap(environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"])
        let dataPath = URL(fileURLWithPath: simulatorData).standardizedFileURL.path
        let homePath = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        guard homePath.hasPrefix(dataPath + "/Containers/Data/Application/") else {
            throw FixtureError.unownedSandbox
        }
        #else
        throw XCTSkip("Never run household/reset erasure fixtures on a physical device or macOS host")
        #endif
    }
}

private enum FixtureError: Error {
    case unownedSandbox
    case nonemptySnapshotDirectory
    case accountRosterRemovalDenied
}

@MainActor
private final class LastSeenErasureFixture {
    let app: PlozziOSAppModel
    let accountSecrets: ErasureAccountSecrets
    let directory: URL
    let profileIDs: [String]
    // Deliberately use the REAL catalog service, not the sources or accounts
    // service: removing source credentials alone must not satisfy these tests.
    let catalogSecrets = LiveTVSourceStorage.catalogSecrets()
    let unrelatedKey = "erasure-fixture.unrelated." + UUID().uuidString
    private let unrelatedValue = "fixture-catalog-key-must-survive"
    private var seededKeys: [String: String] = [:]
    private var retainedFileBytes: Data?

    init(app: PlozziOSAppModel, accountSecrets: ErasureAccountSecrets, directory: URL, profileIDs: [String]) {
        self.app = app
        self.accountSecrets = accountSecrets
        self.directory = directory
        self.profileIDs = profileIDs
    }

    func seed() async throws {
        let channel = LiveTVPrototypeChannel(
            id: "fixture-channel", number: 1, name: "Fixture channel", category: "News",
            symbol: "tv", accent: 0, source: .iptv, tagline: "",
            configuredSourceID: "fixture-source", groups: ["News"]
        )
        let snapshot = LiveTVLastSeenSnapshot(
            sources: [.init(
                sourceID: "fixture-source", accountID: "fixture-account", kind: .iptv,
                entries: [.init(nativeID: "native-channel", channel: channel)], viewerScopeID: "fixture-viewer"
            )],
            browse: .init(categories: ["News"], categoryCounts: ["News": 1], totalCount: 1)
        )
        for profileID in profileIDs {
            XCTAssertNil(try catalogSecrets.readString(for: keyName(profileID)))
            let store = LiveTVLastSeenStore(profileID: profileID, secureStore: catalogSecrets)
            await store.save(snapshot)
            // A rejected/failed save must not produce a vacuous erasure pass.
            let loaded = await store.load()
            XCTAssertEqual(loaded, snapshot)
            let key = try XCTUnwrap(catalogSecrets.readString(for: keyName(profileID)))
            seededKeys[profileID] = key
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(profileID).path))
        }
        retainedFileBytes = try Data(contentsOf: fileURL(profileIDs[0]))
        // Cache eviction leaves its catalog key behind. Only the PRE-reset roster
        // can find this key; enumerating remaining .bin files cannot recover it.
        try FileManager.default.removeItem(at: fileURL(profileIDs[1]))
        try catalogSecrets.setString(unrelatedValue, for: unrelatedKey)
        try assertRetained()
    }

    func assertErased(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), file: file, line: line)
        for profileID in profileIDs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(profileID).path), file: file, line: line)
            XCTAssertNil(try catalogSecrets.readString(for: keyName(profileID)), file: file, line: line)
        }
        XCTAssertEqual(try catalogSecrets.readString(for: unrelatedKey), unrelatedValue, file: file, line: line)
    }

    func assertRetained(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: fileURL(profileIDs[0])), retainedFileBytes, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(profileIDs[1]).path), file: file, line: line)
        for profileID in profileIDs {
            XCTAssertEqual(try catalogSecrets.readString(for: keyName(profileID)), seededKeys[profileID], file: file, line: line)
        }
        XCTAssertEqual(try catalogSecrets.readString(for: unrelatedKey), unrelatedValue, file: file, line: line)
        XCTAssertTrue(Set(profileIDs).isSubset(of: Set(app.profiles.profiles.map(\.id))), file: file, line: line)
    }

    func removeOwnedData() throws {
        for profileID in profileIDs {
            let url = fileURL(profileID)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try catalogSecrets.removeValue(for: keyName(profileID))
        }
        try catalogSecrets.removeValue(for: unrelatedKey)
    }

    private func digest(_ profileID: String) -> String {
        SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func keyName(_ profileID: String) -> String { "liveTV.lastSeen." + digest(profileID) + ".key" }
    private func fileURL(_ profileID: String) -> URL { directory.appendingPathComponent(digest(profileID) + ".bin") }
}

/// Real AccountStore backend with a narrowly armed failure at its clearAll
/// boundary. This keeps the cloud-call-site regression independent of the later
/// first-run cleanup, while exercising real snapshot files and catalog keys.
private final class ErasureAccountSecrets: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var rejectsRemoval = false
    private var rejectedRemoval = false
    var rejectAccountRosterRemoval: Bool {
        get { lock.withLock { rejectsRemoval } }
        set { lock.withLock { rejectsRemoval = newValue } }
    }
    var didRejectAccountRosterRemoval: Bool { lock.withLock { rejectedRemoval } }
    func string(for key: String) -> String? { lock.withLock { values[key] } }
    func readString(for key: String) throws -> String? { string(for: key) }
    func setString(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    func insertStringIfAbsent(_ value: String, for key: String) throws -> Bool {
        lock.withLock {
            guard values[key] == nil else { return false }
            values[key] = value
            return true
        }
    }
    func removeValue(for key: String) throws {
        try lock.withLock {
            if rejectsRemoval, key == "com.plozz.accounts.v2" {
                rejectedRemoval = true
                throw FixtureError.accountRosterRemovalDenied
            }
            values[key] = nil
        }
    }
}
#endif
