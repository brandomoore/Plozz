#if os(tvOS) || os(iOS)
import AppRuntime
import CoreModels
import CryptoKit
import FeatureAuth
import XCTest
#if os(tvOS)
@testable import AppShell
#elseif os(iOS)
@testable import AppShelliOS
#endif

@MainActor
final class WatchlistCloudApplyTests: XCTestCase {
    func testShellForwardsCaptureReceiptsBeforeApplyingCloudWatchlistChanges() async throws {
        let suite = "WatchlistCloudApply.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let profileStore = ProfileStore(defaults: defaults)
        #if os(tvOS)
        let app = AppState(accountStore: accounts, profilesModel: ProfilesModel(store: profileStore))
        #elseif os(iOS)
        let app = PlozziOSAppModel(accountStore: accounts, profileStore: profileStore)
        #endif
        let profileID = ProfileStore.defaultProfileID
        let model = app.universalWatchlist
        let aliasID = MediaAliasID()
        try model.activate(profileID: profileID)
        try model.remove(
            profileID: profileID, aliasID: aliasID, kind: .series,
            at: Date(timeIntervalSince1970: 1_000)
        )
        let key = WatchlistMediaStateRecordKey(profileID: profileID, aliasID: aliasID)
        let removed = try XCTUnwrap(model.captureSyncRecords(profileID: profileID)[key.recordName])
        try model.add(
            profileID: profileID, aliasID: aliasID, kind: .series,
            at: Date(timeIntervalSince1970: 2_000)
        )
        let saved = try XCTUnwrap(model.captureSyncRecords(profileID: profileID)[key.recordName])

        await app.applyMediaStateSyncRecords([key.recordName: removed], localCaptureDigests: [:])
        XCTAssertTrue(model.activeSnapshot.contains(aliasID: aliasID))

        await app.applyMediaStateSyncRecords(
            [key.recordName: removed],
            localCaptureDigests: [key.recordName: Data(SHA256.hash(data: saved))]
        )
        XCTAssertFalse(model.activeSnapshot.contains(aliasID: aliasID))
    }
}
#endif
