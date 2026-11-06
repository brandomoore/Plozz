#if os(iOS)
import CoreModels
import FeatureAuth
import XCTest
@testable import AppRuntime
@testable import AppShelliOS

@MainActor
final class CloudConfigurationRefreshTests: XCTestCase {
    func testAccountRemovalLocallyEverywhereAndViaSyncKeepsOtherSourcesDisabled() async throws {
        enum Removal: CaseIterable { case local, everywhere, synced }
        for removal in Removal.allCases {
            try await withApp { app, _ in
                let selectedID = UUID().uuidString
                let excludedID = UUID().uuidString
                let unselectedID = UUID().uuidString
                app.accountsProviders.registry.register(.jellyfin) {
                    AccountSelectionProvider(session: $0.session)
                }
                for id in [selectedID, excludedID, unselectedID] {
                    try app.accountStore.add(Account(
                        id: id,
                        server: .init(id: id, name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!, provider: .jellyfin),
                        userID: "viewer", userName: "Viewer", deviceID: "fixture"
                    ), token: "fixture")
                }
                app.accountStore.setActiveAccountIDs([selectedID, excludedID, unselectedID])
                app.profiles.setActiveAccountIDs([selectedID], for: app.profiles.activeProfileID)
                app.accountsProviders.reloadAccounts()
                let libraryKey = "\(excludedID):movies"
                app.settings.homeVisibility.setEnabled(false, for: libraryKey)
                XCTAssertEqual(app.accountsProviders.activeAccountIDs, [selectedID])
                app.removeAccount(id: unselectedID)
                XCTAssertEqual(app.accountsProviders.activeAccountIDs, [selectedID])
                XCTAssertEqual(app.profiles.storedActiveAccountIDs(for: app.profiles.activeProfileID), [selectedID])
                defer {
                    var removals = RemovedAccountsStore()
                    removals.clear(selectedID)
                }

                switch removal {
                case .local:
                    app.removeAccount(id: selectedID)
                case .everywhere:
                    app.removeAccountEverywhere(id: selectedID)
                case .synced:
                    app.applySyncRecords([
                        "removal:\(selectedID)": try XCTUnwrap(CanonicalJSON.encode(
                            AccountRemovalDTO(accountID: selectedID, removedAtEpoch: 1_793_577_905)
                        ))
                    ])
                }

                XCTAssertEqual(app.accountsProviders.accounts.map(\.id), [excludedID])
                XCTAssertTrue(app.accountsProviders.activeAccountIDs.isEmpty)
                XCTAssertTrue(app.activeAccountIDs(for: app.profiles.activeProfileID).isEmpty)
                XCTAssertTrue(app.accountsProviders.navigationAccounts.isEmpty)
                XCTAssertTrue(app.accountsProviders.homeAccounts.isEmpty)
                XCTAssertNil(app.accountsProviders.primaryActiveAccount)
                XCTAssertTrue(app.accountsProviders.liveTVServerChoices.isEmpty)
                XCTAssertFalse(app.settings.homeVisibility.isEnabled(libraryKey))
                XCTAssertEqual(app.profiles.storedActiveAccountIDs(for: app.profiles.activeProfileID), [selectedID])
                let captured = app.captureSyncRecords(fallback: [:])
                let membership = try XCTUnwrap(captured["membership:\(app.profiles.activeProfileID)"])
                XCTAssertEqual(try JSONDecoder().decode([String].self, from: membership), [selectedID])
                if removal != .local {
                    XCTAssertTrue(RemovedAccountsStore().isRemoved(selectedID))
                    XCTAssertNotNil(captured["removal:\(selectedID)"])
                }
            }
        }
    }

    func testRebuiltMobileSettingsPreserveAutomaticDiscoveryAndExplicitChoice() {
        let namespace = "MobileDiscovery.\(UUID())"
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(namespace) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        var configured = false
        let initial = PlozziOSSettingsModel(namespace: namespace, isSeerrConfigured: { configured })
        XCTAssertFalse(initial.hero.effectiveSettings.isEnabled(.featured))
        configured = true
        XCTAssertTrue(initial.hero.effectiveSettings.isEnabled(.featured))
        initial.hero.settings.maxItems = 10
        let rebuilt = PlozziOSSettingsModel(namespace: namespace, isSeerrConfigured: { configured })
        XCTAssertTrue(rebuilt.hero.effectiveSettings.isEnabled(.featured))
        rebuilt.hero.settings.setEnabled(.featured, enabled: false)
        let explicit = PlozziOSSettingsModel(namespace: namespace, isSeerrConfigured: { configured })
        XCTAssertFalse(explicit.hero.effectiveSettings.isEnabled(.featured))
        XCTAssertFalse(explicit.hero.settings.discoveryFollowsSeerr)
        XCTAssertEqual(explicit.hero.settings.maxItems, 10)
    }

    func testPerformancePreferenceSync() async throws {
        try PerformanceProbe.requireEnabled()
        try await withApp { app, other in
            var invalidations = 0
            let original = app.accountsProviders.onAccountsInvalidated
            app.accountsProviders.onAccountsInvalidated = {
                invalidations += 1
                original()
            }
            try await PerformanceProbe.measure(self, scenario: "mobile-preference-sync") {
                let before = invalidations
                var downloadTransitions = 0
                var indexResets = 0
                for iteration in 0..<24 {
                    let downloads = app.downloads
                    let revision = app.identityIndex.identitySnapshotStore.revision
                    var hero = HeroSettings.default
                    hero.maxItems = iteration.isMultiple(of: 2) ? 7 : 8
                    app.applySyncRecords([
                        setting(app.profiles.activeProfileID, "com.plozz.heroSettings"): try blob(JSONEncoder().encode(hero)),
                        setting(other.id, "com.plozz.playback.preferredVersions"): try blob(["title": "version-\(iteration)"])
                    ])
                    XCTAssertEqual(app.settings.hero.settings.maxItems, hero.maxItems)
                    XCTAssertEqual(VersionPreferenceStore(namespace: other.id).preferredVersionID(forTitle: "title"), "version-\(iteration)")
                    if app.downloads !== downloads { downloadTransitions += 1 }
                    if app.identityIndex.identitySnapshotStore.revision != revision { indexResets += 1 }
                }
                return [
                    "batches": 24, "appliedPreferences": 48,
                    "accountInvalidations": invalidations - before,
                    "indexResets": indexResets, "downloadTransitions": downloadTransitions
                ]
            }
            try await PerformanceProbe.attachMemoryAfterOneSecond(self, scenario: "mobile-preference-sync")
        }
    }

    func testActivePreferencesUpdateWithoutRestartingSourcesOrDownloads() async throws {
        try await withApp { app, _ in
            let downloads = app.downloads
            let revision = app.identityIndex.identitySnapshotStore.revision
            var invalidations = 0
            app.accountsProviders.onAccountsInvalidated = { invalidations += 1 }
            var hero = HeroSettings.default
            hero.maxItems = 14
            let activeID = app.profiles.activeProfileID
            app.applySyncRecords([
                setting(activeID, "com.plozz.heroSettings"): try blob(JSONEncoder().encode(hero)),
                setting(activeID, "com.plozz.playback.preferredVersions"): try blob(["title": "selected"])
            ])
            XCTAssertEqual(app.settings.hero.settings.maxItems, 14)
            XCTAssertEqual(app.versionPreferences.preferredVersionID(forTitle: "title"), "selected")
            XCTAssertTrue(app.downloads === downloads)
            XCTAssertEqual(app.identityIndex.identitySnapshotStore.revision, revision)
            XCTAssertEqual(invalidations, 0)
            app.applySyncRecords([setting(activeID, "com.plozz.heroSettings"): nil])
            XCTAssertEqual(app.settings.hero.settings, .default)
            XCTAssertEqual(invalidations, 0)
        }
    }

    func testInactivePreferencesAndProfilesDoNotRebuildActiveSettings() async throws {
        try await withApp { app, other in
            let settings = app.settings
            let downloads = app.downloads
            let revision = app.identityIndex.identitySnapshotStore.revision
            var update = ProfileSyncDTO(profile: other)
            update.name = "Updated inactive viewer"
            app.applySyncRecords([
                "profile:\(other.id)": try XCTUnwrap(CanonicalJSON.encode(update)),
                "membership:\(other.id)": try XCTUnwrap(CanonicalJSON.encode([String]())),
                setting(other.id, "com.plozz.playback.preferredVersions"): try blob(["title": "selected"])
            ])
            XCTAssertEqual(app.profiles.profiles.first { $0.id == other.id }?.name, update.name)
            XCTAssertEqual(VersionPreferenceStore(namespace: other.id).preferredVersionID(forTitle: "title"), "selected")
            XCTAssertTrue(app.settings === settings)
            XCTAssertTrue(app.downloads === downloads)
            XCTAssertEqual(app.identityIndex.identitySnapshotStore.revision, revision)
            app.applySyncRecords([:])
            XCTAssertTrue(app.settings === settings)
        }
    }

    func testActiveMembershipAndRestrictionsStillRefreshRuntime() async throws {
        try await withApp { app, _ in
            var invalidations = 0
            let original = app.accountsProviders.onAccountsInvalidated
            app.accountsProviders.onAccountsInvalidated = {
                invalidations += 1
                original()
            }
            let activeID = app.profiles.activeProfileID
            XCTAssertNil(app.profiles.storedActiveAccountIDs(for: activeID))
            app.applySyncRecords(["membership:\(activeID)": try XCTUnwrap(CanonicalJSON.encode([String]()))])
            XCTAssertGreaterThan(invalidations, 0)
            let afterMembership = invalidations
            app.applySyncRecords(["membership:\(activeID)": try XCTUnwrap(CanonicalJSON.encode([String]()))])
            XCTAssertEqual(invalidations, afterMembership, "Reapplying the same membership must not restart sources.")
            app.applySyncRecords(["membership:\(activeID)": nil])
            XCTAssertNil(app.profiles.storedActiveAccountIDs(for: activeID))
            XCTAssertGreaterThan(invalidations, afterMembership)
            let afterClear = invalidations
            var profile = app.profiles.activeProfile
            profile.isKids = true
            app.applySyncRecords(["profile:\(activeID)": try XCTUnwrap(CanonicalJSON.encode(ProfileSyncDTO(profile: profile)))])
            XCTAssertGreaterThan(invalidations, afterClear)
            XCTAssertFalse(app.settings.hero.allowsDiscovery)
            XCTAssertTrue(app.profiles.activeProfile.isKids)
        }
    }

    private func setting(_ profileID: String, _ baseKey: String) -> String {
        SyncRecordKey(kind: .setting, id: profileID, subkey: baseKey).recordName
    }

    private func blob(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0)
    }

    private func withApp(_ exercise: (PlozziOSAppModel, Profile) async throws -> Void) async throws {
        let suite = "CloudConfigurationRefresh.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileStore(defaults: defaults)
        let profiles = ProfilesModel(store: store)
        let active = profiles.add(name: "Active", avatarSymbol: "person", colorIndex: 0)
        let other = profiles.add(name: "Inactive", avatarSymbol: "person", colorIndex: 1)
        profiles.select(active.id)
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.contains(active.id) || key.contains(other.id) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let app = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()), profileStore: store
        )
        try await Task.sleep(for: .milliseconds(200))
        try await exercise(app, other)
        await app.ensureTrackersScopedToActiveProfile()
        try await Task.sleep(for: .milliseconds(100))
    }
}

private struct AccountSelectionProvider: MediaProvider {
    let session: UserSession
    var kind: ProviderKind { .jellyfin }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
