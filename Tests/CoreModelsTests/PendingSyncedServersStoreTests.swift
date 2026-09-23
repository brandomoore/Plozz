import XCTest
@testable import CoreModels

final class PendingSyncedServersStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "PendingSyncedServersTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        return d
    }

    private func desc(_ id: String) -> SyncedAccountDescriptor {
        SyncedAccountDescriptor(id: id, provider: .jellyfin, serverID: "srv-\(id)",
                                serverName: "Server \(id)", userID: "u", userName: "U")
    }

    func testReconcileRecordsOnlyUnauthorized() {
        var store = PendingSyncedServersStore(defaults: makeDefaults())
        let newlyPending = store.reconcile(
            syncedDescriptors: [desc("A"), desc("B"), desc("C")],
            localAccountIDs: ["B"] // already signed into B
        )
        XCTAssertEqual(store.pending.map(\.id), ["A", "C"])
        XCTAssertEqual(newlyPending.map(\.id), ["A", "C"])
    }

    func testSigningInRemovesFromPending() {
        var store = PendingSyncedServersStore(defaults: makeDefaults())
        _ = store.reconcile(syncedDescriptors: [desc("A")], localAccountIDs: [])
        XCTAssertEqual(store.pending.map(\.id), ["A"])
        // Now signed into A locally.
        _ = store.reconcile(syncedDescriptors: [desc("A")], localAccountIDs: ["A"])
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testIgnoreHidesFromPendingButKeepsInAll() {
        var store = PendingSyncedServersStore(defaults: makeDefaults())
        _ = store.reconcile(syncedDescriptors: [desc("A"), desc("B")], localAccountIDs: [])
        store.ignore("A")
        XCTAssertEqual(store.pending.map(\.id), ["B"])
        XCTAssertEqual(store.all.map(\.id), ["A", "B"])
        XCTAssertTrue(store.ignoredIDs.contains("A"))
    }

    func testPromptedExcludedFromNewButStaysPending() {
        var store = PendingSyncedServersStore(defaults: makeDefaults())
        let first = store.reconcile(syncedDescriptors: [desc("A")], localAccountIDs: [])
        XCTAssertEqual(first.map(\.id), ["A"])
        store.markPrompted(["A"])
        // Re-reconcile: still pending (visible in list) but not "new" for a prompt.
        let second = store.reconcile(syncedDescriptors: [desc("A")], localAccountIDs: [])
        XCTAssertTrue(second.isEmpty, "an already-prompted server must not re-prompt")
        XCTAssertEqual(store.pending.map(\.id), ["A"], "but it stays listed as pending")
    }

    func testForgetRemovesEntirely() {        var store = PendingSyncedServersStore(defaults: makeDefaults())
        _ = store.reconcile(syncedDescriptors: [desc("A")], localAccountIDs: [])
        store.ignore("A")
        store.forget("A")
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertFalse(store.ignoredIDs.contains("A"))
    }

    func testDescriptorLeavingHouseholdPrunesBookkeeping() {
        var store = PendingSyncedServersStore(defaults: makeDefaults())
        _ = store.reconcile(syncedDescriptors: [desc("A")], localAccountIDs: [])
        store.ignore("A")
        store.markPrompted(["A"])
        // A removed from the household entirely (no longer synced).
        _ = store.reconcile(syncedDescriptors: [], localAccountIDs: [])
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertFalse(store.ignoredIDs.contains("A"))
        XCTAssertFalse(store.promptedIDs.contains("A"))
    }

    func testLaterInSettingsSurvivesRelaunchWithoutHidingSetupOrRepeatingDrawer() {
        let defaults = makeDefaults()
        var store = PendingSyncedServersStore(defaults: defaults)
        store.upsertSynced(desc("A"))
        XCTAssertEqual(store.setupOffers(from: store.pending).map(\.id), ["A"])
        store.deferSetup(["A"])

        var relaunched = PendingSyncedServersStore(defaults: defaults)
        relaunched.reconcile(syncedDescriptors: [desc("A")], localAccountIDs: [])
        XCTAssertTrue(relaunched.setupOffers(from: relaunched.pending).isEmpty)
        XCTAssertTrue(relaunched.newlyPending(excludingLocal: []).isEmpty)
        XCTAssertEqual(relaunched.pending.map(\.id), ["A"], "Setup must remain available in Settings.")
        XCTAssertTrue(relaunched.ignoredIDs.isEmpty, "Deferring is not ignoring or deleting a server.")
    }

    func testDeferralAppliesOnlyToPresentedServersAndThisDevice() {
        let defaults = makeDefaults()
        var store = PendingSyncedServersStore(defaults: defaults)
        store.upsertSynced(desc("A"))
        let presentedIDs = store.setupOffers(from: store.pending).map(\.id)
        store.upsertSynced(desc("B"))
        store.deferSetup(presentedIDs)
        XCTAssertEqual(store.setupOffers(from: store.pending).map(\.id), ["B"])

        var otherDevice = PendingSyncedServersStore(defaults: makeDefaults())
        otherDevice.reconcile(syncedDescriptors: [desc("A"), desc("B")], localAccountIDs: [])
        XCTAssertEqual(otherDevice.setupOffers(from: otherDevice.pending).map(\.id), ["A", "B"])
    }

    func testExistingDrawerPromptBookkeepingDoesNotSuppressFirstFullPageOffer() {
        var store = PendingSyncedServersStore(defaults: makeDefaults())
        store.upsertSynced(desc("A"))
        store.markPrompted(["A"])
        XCTAssertEqual(store.setupOffers(from: store.pending).map(\.id), ["A"])
        store.deferSetup(["A"])
        store.upsertSynced(desc("A"))
        XCTAssertTrue(store.setupOffers(from: store.pending).isEmpty)
    }

    func testResetAndHouseholdRemovalClearDeferrals() {
        for removal in 0..<4 {
            var store = PendingSyncedServersStore(defaults: makeDefaults())
            store.upsertSynced(desc("A"))
            store.deferSetup(["A"])
            switch removal {
            case 0: store.removeAll()
            case 1: store.removeSynced("A")
            case 2: store.forget("A")
            default: store.reconcile(syncedDescriptors: [], localAccountIDs: [])
            }
            store.upsertSynced(desc("A"))
            XCTAssertEqual(store.setupOffers(from: store.pending).map(\.id), ["A"])
        }
    }
}
