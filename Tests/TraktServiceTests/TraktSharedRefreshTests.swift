import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import TraktService
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let sharedExpired = TraktTokens(
    accessToken: "expired-access", refreshToken: "original-refresh",
    expiresAt: .distantPast, accountIdentity: "one-trakt-account"
)
private let sharedFresh = TraktTokens(
    accessToken: "next-access", refreshToken: "next-refresh",
    expiresAt: .distantFuture, accountIdentity: "one-trakt-account"
)
private let profileA = "test.tokens\0trakt.oauth.A"
private let profileB = "test.tokens\0trakt.oauth.B"

final class TraktSharedRefreshTests: XCTestCase {
    func testSuspendedSyncOwnsScopeAndJoinedAccessRenewsExpiredResult() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let gate = SharedCloudGate()
        await cloud.pauseNextRead(using: gate)
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP()
        let sync = Task { try await device.coordinator.synchronizeShared(store: device.store) }
        await gate.waitUntilStarted()
        let syncOwner = await device.coordinator.refreshes[profileA]
        XCTAssertNotNil(syncOwner)
        XCTAssertEqual(syncOwner?.renewsExpiredTokens, false)

        let entered = expectation(description: "Access entered the coordinator")
        let access = Task {
            try await device.coordinator.accessAfterSignaling(
                store: device.store, http: http, entered: { entered.fulfill() }
            )
        }
        await fulfillment(of: [entered], timeout: 5)
        // This actor read follows accessAfterSignaling's first suspension, so
        // joining the held sync is observed without sleeps or scheduler guesses.
        let joinedOwner = await device.coordinator.refreshes[profileA]
        XCTAssertEqual(joinedOwner?.id, syncOwner?.id)
        let readsWhileSyncHeld = await cloud.readCount
        let exchangesWhileSyncHeld = await http.count
        XCTAssertEqual(readsWhileSyncHeld, 1)
        XCTAssertEqual(exchangesWhileSyncHeld, 0)

        await gate.release()
        try await sync.value
        let result = try await access.value
        XCTAssertEqual(result, "next-access", "A passive sync result must not bypass refresh")
        let count = await http.count
        XCTAssertEqual(count, 1)
        let journal = try JSONDecoder().decode(
            TraktSharedJournalState.self, from: XCTUnwrap(device.journal.read(scope: profileA))
        )
        XCTAssertNil(journal.pending)
        XCTAssertEqual(journal.accepted?.tokens?.refreshToken, "next-refresh")
    }

    func testSyncJoinsPendingPublicationWithoutOverwritingSuccessorJournal() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let gate = SharedCloudGate()
        await cloud.pauseNextSuccessor(using: gate)
        await cloud.failNextSuccessor()
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP()
        let access = Task { try await device.access(http) }
        await gate.waitUntilStarted()
        let owner = await device.coordinator.refreshes[profileA]
        let pending = try XCTUnwrap(device.journal.read(scope: profileA))
        let pendingState = try JSONDecoder().decode(TraktSharedJournalState.self, from: pending)
        XCTAssertEqual(pendingState.pending?.kind, .successor)
        let readsBeforeSync = await cloud.readCount

        let entered = expectation(description: "Sync entered the coordinator")
        let sync = Task {
            try await device.coordinator.syncAfterSignaling(
                store: device.store, entered: { entered.fulfill() }
            )
        }
        await fulfillment(of: [entered], timeout: 5)
        let joinedOwner = await device.coordinator.refreshes[profileA]
        XCTAssertEqual(joinedOwner?.id, owner?.id)
        let readsAfterSync = await cloud.readCount
        XCTAssertEqual(readsAfterSync, readsBeforeSync)
        XCTAssertEqual(try device.journal.read(scope: profileA), pending)
        await gate.release()
        do { _ = try await access.value; XCTFail("Publication failure must surface") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .unavailable) }
        do { try await sync.value; XCTFail("Joined sync must observe the same publication failure") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .unavailable) }
        XCTAssertEqual(try device.journal.read(scope: profileA), pending)

        let restarted = SharedDevice(cloud: cloud, store: device.store, journal: device.journal)
        let result = try await restarted.access(http)
        XCTAssertEqual(result, "next-access")
        let count = await http.count
        XCTAssertEqual(count, 1, "Recovery must publish the journaled successor, not exchange again")
    }

    func testAccessorJoiningPassiveSyncCanResumeItsUnspentClaim() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        await cloud.loseNextClaimAcknowledgement()
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP()
        do { _ = try await device.access(http); XCTFail("Lost claim acknowledgement must surface") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .unavailable) }
        let gate = SharedCloudGate()
        await cloud.pauseNextRead(using: gate)
        let sync = Task { try await device.coordinator.synchronizeShared(store: device.store) }
        await gate.waitUntilStarted()
        let owner = await device.coordinator.refreshes[profileA]
        let entered = expectation(description: "Access joined passive claim recovery")
        let access = Task {
            try await device.coordinator.accessAfterSignaling(
                store: device.store, http: http, entered: { entered.fulfill() }
            )
        }
        await fulfillment(of: [entered], timeout: 5)
        let joinedOwner = await device.coordinator.refreshes[profileA]
        XCTAssertEqual(joinedOwner?.id, owner?.id)
        await gate.release()
        do { try await sync.value; XCTFail("Passive sync cannot exchange an unspent claim") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .refreshInProgress) }
        let result = try await access.value
        XCTAssertEqual(result, "next-access")
        let count = await http.count
        XCTAssertEqual(count, 1)
    }

    func testConnectionChangesInvalidateSuspendedSyncAndItsJoinedAccessor() async throws {
        for replacement in [nil, sharedFresh] as [TraktTokens?] {
            let cloud = FakeTraktCloud()
            try await cloud.seed(sharedExpired, scope: profileA)
            let device = SharedDevice(cloud: cloud)
            let context = try await device.coordinator.prepareConnection(store: device.store)
            let oldRead = SharedCloudGate()
            await cloud.pauseNextRead(using: oldRead)
            let http = SharedRefreshHTTP()
            let sync = Task { try await device.coordinator.synchronizeShared(store: device.store) }
            await oldRead.waitUntilStarted()
            let oldOwner = await device.coordinator.refreshes[profileA]
            let entered = expectation(description: "Access joined the old sync")
            let access = Task {
                try await device.coordinator.accessAfterSignaling(
                    store: device.store, http: http, entered: { entered.fulfill() }
                )
            }
            await fulfillment(of: [entered], timeout: 5)
            let joinedOwner = await device.coordinator.refreshes[profileA]
            XCTAssertEqual(joinedOwner?.id, oldOwner?.id)

            let newRead = SharedCloudGate()
            await cloud.pauseNextRead(using: newRead)
            let change = Task {
                if let replacement {
                    try await device.coordinator.save(replacement, store: device.store, context: context)
                } else {
                    _ = try await device.coordinator.disconnect(store: device.store)
                }
            }
            await newRead.waitUntilStarted()
            let newOwner = await device.coordinator.refreshes[profileA]
            XCTAssertNotNil(newOwner)
            XCTAssertNotEqual(newOwner?.id, oldOwner?.id)
            // Return the old server snapshot while the new connection change
            // still owns the slot. Neither its journal nor its slot may be lost.
            let pendingChange = try device.journal.read(scope: profileA)
            await oldRead.release()
            do { try await sync.value; XCTFail("Old sync must be invalidated") }
            catch { XCTAssertTrue(error is CancellationError) }
            do { _ = try await access.value; XCTFail("Old sync's accessor must be invalidated") }
            catch { XCTAssertTrue(error is CancellationError) }
            let retainedOwner = await device.coordinator.refreshes[profileA]
            XCTAssertEqual(retainedOwner?.id, newOwner?.id)
            XCTAssertEqual(try device.journal.read(scope: profileA), pendingChange)
            await newRead.release()
            try await change.value
            XCTAssertEqual(device.store.load(), replacement)
            let count = await http.count
            XCTAssertEqual(count, 0)
        }
    }

    func testLegacyMigrationStillRefreshesExpiredGrantBeforeReturning() async throws {
        let cloud = FakeTraktCloud()
        await cloud.setLegacy(sharedExpired, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP()
        let access = try await device.access(http)
        XCTAssertEqual(access, "next-access")
        let count = await http.count
        XCTAssertEqual(count, 1)
    }

    func testTwoDevicesShareExactlyOneExchangeAndSuccessor() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let first = SharedDevice(cloud: cloud)
        let second = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP(paused: true)
        let owner = Task { try await first.access(http) }
        await http.waitUntilStarted()
        do {
            _ = try await second.access(http)
            XCTFail("A follower must wait for the claimed generation")
        } catch {
            XCTAssertEqual(error as? TraktSharedRefreshError, .refreshInProgress)
        }
        await http.release()
        let firstAccess = try await owner.value
        let secondAccess = try await second.access(http)
        XCTAssertEqual(firstAccess, "next-access")
        XCTAssertEqual(firstAccess, secondAccess)
        XCTAssertEqual(first.store.load()?.refreshToken, "next-refresh")
        XCTAssertEqual(second.store.load(), first.store.load())
        let count = await http.count
        XCTAssertEqual(count, 1)
    }

    func testSimultaneousConditionalClaimsHaveOneWinner() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        await cloud.synchronizeNextTwoClaims()
        let first = SharedDevice(cloud: cloud)
        let second = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP(paused: true)
        let a = Task { try await first.access(http) }
        let b = Task { try await second.access(http) }
        await http.waitUntilStarted()
        await http.release()
        for operation in [a, b] {
            do { _ = try await operation.value }
            catch { XCTAssertEqual(error as? TraktSharedRefreshError, .refreshInProgress) }
        }
        let aAccess = try await first.access(http)
        let bAccess = try await second.access(http)
        XCTAssertEqual(aAccess, "next-access")
        XCTAssertEqual(bAccess, aAccess)
        let count = await http.count
        let claims = await cloud.successfulClaims
        XCTAssertEqual(count, 1)
        XCTAssertEqual(claims, 1)
    }

    func testFailedCloudPublicationResumesAfterProcessRestartWithoutExchange() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        await cloud.failNextSuccessor()
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP()
        do {
            _ = try await device.access(http)
            XCTFail("Cloud publication failure must propagate")
        } catch {
            XCTAssertEqual(error as? TraktSharedRefreshError, .unavailable)
        }
        let restarted = SharedDevice(cloud: cloud, store: device.store, journal: device.journal)
        let recovered = try await restarted.access(http)
        XCTAssertEqual(recovered, "next-access")
        let count = await http.count
        XCTAssertEqual(count, 1)
    }

    func testLostSuccessorAcknowledgementAdoptsAlreadyPublishedResult() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        await cloud.loseNextSuccessorAcknowledgement()
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP()
        do { _ = try await device.access(http); XCTFail("Lost acknowledgement must surface") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .unavailable) }
        let restarted = SharedDevice(cloud: cloud, store: device.store, journal: device.journal)
        let access = try await restarted.access(http)
        XCTAssertEqual(access, "next-access")
        let count = await http.count
        XCTAssertEqual(count, 1)
    }

    func testFailedSuccessorJournalWriteRetainsResultForRetry() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let journal = FakeTraktJournal()
        journal.failSuccessorOnce = true
        let device = SharedDevice(cloud: cloud, journal: journal)
        let http = SharedRefreshHTTP()
        do {
            _ = try await device.access(http)
            XCTFail("The failed journal write must be surfaced")
        } catch { XCTAssertTrue(error is SharedStorageFailure) }
        let recovered = try await device.access(http)
        XCTAssertEqual(recovered, "next-access")
        let count = await http.count
        XCTAssertEqual(count, 1)
    }

    func testFailedLocalTokenWriteRecoversFromPublishedSuccessor() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let store = SharedTestTokenStore(scope: profileA)
        store.failSuccessorOnce = true
        let device = SharedDevice(cloud: cloud, store: store)
        let http = SharedRefreshHTTP()
        do {
            _ = try await device.access(http)
            XCTFail("Token persistence failure must propagate")
        } catch { XCTAssertTrue(error is SharedStorageFailure) }
        let peer = SharedDevice(cloud: cloud)
        let peerAccess = try await peer.access(http)
        let recovered = try await device.access(http)
        XCTAssertEqual(peerAccess, "next-access")
        XCTAssertEqual(recovered, peerAccess)
        let count = await http.count
        XCTAssertEqual(count, 1)
    }

    func testRemoteSignOutDuringExchangeRejectsLateOwnerAndStaleSync() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let owner = SharedDevice(cloud: cloud)
        let peer = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP(paused: true)
        let refresh = Task { try await owner.access(http) }
        await http.waitUntilStarted()
        _ = try await peer.coordinator.disconnect(store: peer.store)
        await http.release()
        do {
            _ = try await refresh.value
            XCTFail("An old refresh cannot restore a signed-out generation")
        } catch { XCTAssertEqual(error as? TraktSharedRefreshError, .superseded) }
        XCTAssertNil(owner.store.load())
        // Old raw-token delivery is only a hint. The CAS tombstone still wins.
        await cloud.setLegacy(sharedExpired, scope: profileA)
        try await owner.coordinator.synchronizeShared(store: owner.store)
        XCTAssertNil(owner.store.load())
        let freshDevice = SharedDevice(cloud: cloud)
        let access = try await freshDevice.access(http)
        XCTAssertNil(access)
        let count = await http.count
        XCTAssertEqual(count, 1)
    }

    func testLocalSignOutDuringExchangeInvalidatesPendingResponse() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP(paused: true)
        let refresh = Task { try await device.access(http) }
        await http.waitUntilStarted()
        _ = try await device.coordinator.disconnect(store: device.store)
        await http.release()
        do {
            _ = try await refresh.value
            XCTFail("Cancelled owner must not persist")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(device.store.load())
        let restarted = SharedDevice(cloud: cloud, store: device.store, journal: device.journal)
        let access = try await restarted.access(http)
        XCTAssertNil(access)
    }

    func testReconnectOnAnotherDeviceFencesOldEpoch() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let owner = SharedDevice(cloud: cloud)
        let peer = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP(paused: true)
        let refresh = Task { try await owner.access(http) }
        await http.waitUntilStarted()
        let replacement = TraktTokens(
            accessToken: "replacement", refreshToken: "replacement-refresh",
            expiresAt: .distantFuture, accountIdentity: "different-trakt-account"
        )
        let context = try await peer.coordinator.prepareConnection(store: peer.store)
        try await peer.coordinator.save(replacement, store: peer.store, context: context)
        await http.release()
        do {
            _ = try await refresh.value
            XCTFail("Old epoch must not overwrite reconnect")
        } catch { XCTAssertEqual(error as? TraktSharedRefreshError, .superseded) }
        XCTAssertEqual(owner.store.load(), replacement)
    }

    func testPendingReconnectCannotResurrectAfterRemoteSignOut() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedFresh, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP()
        _ = try await device.access(http)
        let context = try await device.coordinator.prepareConnection(store: device.store)
        await cloud.failNextConnection()
        let replacement = TraktTokens(
            accessToken: "replacement", refreshToken: "replacement-refresh", expiresAt: .distantFuture
        )
        do {
            try await device.coordinator.save(replacement, store: device.store, context: context)
            XCTFail("Failed connection publication must surface")
        } catch { XCTAssertEqual(error as? TraktSharedRefreshError, .unavailable) }
        let peer = SharedDevice(cloud: cloud)
        _ = try await peer.coordinator.disconnect(store: peer.store)
        do { _ = try await device.access(http); XCTFail("Stale reconnect must not undo sign-out") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .superseded) }
        XCTAssertNil(device.store.load())
    }

    func testDifferentProfileCanRefreshWhileFirstProfileIsClaimed() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        try await cloud.seed(sharedExpired, scope: profileB)
        let first = SharedDevice(cloud: cloud)
        let otherProfile = SharedDevice(cloud: cloud, store: SharedTestTokenStore(scope: profileB))
        let held = SharedRefreshHTTP(paused: true)
        let other = SharedRefreshHTTP()
        let pending = Task { try await first.access(held) }
        await held.waitUntilStarted()
        let access = try await otherProfile.access(other)
        XCTAssertEqual(access, "next-access")
        let count = await other.count
        XCTAssertEqual(count, 1)
        _ = try await otherProfile.coordinator.disconnect(store: otherProfile.store)
        await held.release()
        _ = try await pending.value
        XCTAssertNotNil(first.store.load())
        XCTAssertNil(otherProfile.store.load())
    }

    func testLostClaimAcknowledgementRetriesCASNotTheExchange() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        await cloud.loseNextClaimAcknowledgement()
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP()
        do { _ = try await device.access(http); XCTFail("Lost acknowledgement must surface") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .unavailable) }
        let initialCount = await http.count
        XCTAssertEqual(initialCount, 0)
        let restarted = SharedDevice(cloud: cloud, store: device.store, journal: device.journal)
        let access = try await restarted.access(http)
        XCTAssertEqual(access, "next-access")
        let count = await http.count
        XCTAssertEqual(count, 1)
    }

    func testAmbiguousExchangeNeverReplaysAfterRestartOrOnAnotherDevice() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP(fail: true)
        do { _ = try await device.access(http); XCTFail("An uncertain exchange must not retry") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .outcomeUnknown) }
        let restarted = SharedDevice(cloud: cloud, store: device.store, journal: device.journal)
        do { _ = try await restarted.access(http); XCTFail("Restart cannot reclaim") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .outcomeUnknown) }
        let peer = SharedDevice(cloud: cloud)
        do { _ = try await peer.access(http); XCTFail("Peer cannot reclaim") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .refreshInProgress) }
        let count = await http.count
        XCTAssertEqual(count, 1)
    }

    func testPositiveNotSentEvidenceAllowsOwnerToResumeWithoutReauthorization() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let unsent = SharedRefreshHTTP(notSent: true)
        do { _ = try await device.access(unsent); XCTFail("Not-sent failure must surface") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .retryable(retryNotBefore: nil)) }
        let restarted = SharedDevice(cloud: cloud, store: device.store, journal: device.journal)
        let success = SharedRefreshHTTP()
        let access = try await restarted.access(success)
        XCTAssertEqual(access, "next-access")
        let count = await success.count
        XCTAssertEqual(count, 1)
    }

    func testCachedAccessWorksOfflineButExpiredGrantNeverRefreshesLocally() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedFresh, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP()
        _ = try await device.access(http)
        await cloud.setOffline(true)
        let access = try await device.access(http)
        XCTAssertEqual(access, sharedFresh.accessToken)
        let expiredStore = SharedTestTokenStore(scope: profileB, tokens: sharedExpired)
        let expiredDevice = SharedDevice(cloud: cloud, store: expiredStore)
        do { _ = try await expiredDevice.access(http); XCTFail("No unsynchronized fallback") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .unavailable) }
        let count = await http.count
        XCTAssertEqual(count, 0)
    }

    func testAccountSwitchNeverUploadsPreviousAccountsTokens() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedFresh, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP()
        _ = try await device.access(http)
        await cloud.switchAccount("different-icloud-account")
        do { _ = try await device.access(http); XCTFail("Must reject old account binding") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .accountChanged) }
        XCTAssertNil(device.store.load())
        let access = try await device.access(http)
        XCTAssertNil(access)
        let count = await cloud.recordCount
        XCTAssertEqual(count, 0)
    }

    func testDeletedAuthorityIsNotRecreatedFromCachedCredentials() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedFresh, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP()
        _ = try await device.access(http)
        await cloud.removeRecord(scope: profileA)
        do { _ = try await device.access(http); XCTFail("No resurrection after authority deletion") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .missingRecord) }
        let count = await cloud.recordCount
        XCTAssertEqual(count, 0)
    }

    func testDeferredReconnectKeepsPreparedEpochWhenFirstPublicationReadFails() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedFresh, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP()
        _ = try await device.access(http)
        let context = try await device.coordinator.prepareConnection(store: device.store)
        await cloud.failNextRead()
        do {
            try await device.coordinator.save(sharedFresh, store: device.store, context: context)
            XCTFail("The first publication read must fail")
        } catch { XCTAssertEqual(error as? TraktSharedRefreshError, .unavailable) }
        let pending = try JSONDecoder().decode(
            TraktSharedJournalState.self, from: XCTUnwrap(device.journal.read(scope: profileA))
        ).pending
        XCTAssertEqual(pending?.expectedEpoch, context.expectedEpoch)
        XCTAssertEqual(pending?.needsBaseline, false)

        let peer = SharedDevice(cloud: cloud)
        _ = try await peer.coordinator.disconnect(store: peer.store)
        let restarted = SharedDevice(cloud: cloud, store: device.store, journal: device.journal)
        do { _ = try await restarted.access(http); XCTFail("Retry must not adopt the new sign-out epoch") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .superseded) }
        XCTAssertNil(device.store.load())
        let count = await http.count
        XCTAssertEqual(count, 0)
    }

    func testFreshDeviceReconnectFreezesExistingOrAbsentBaselineBeforeOAuth() async throws {
        for existing in [nil, sharedFresh] as [TraktTokens?] {
            let cloud = FakeTraktCloud()
            if let existing { try await cloud.seed(existing, scope: profileA) }
            let device = SharedDevice(cloud: cloud)
            let context = try await device.coordinator.prepareConnection(store: device.store)
            XCTAssertEqual(context.expectedEpoch == nil, existing == nil)
            XCTAssertNil(device.store.load())
            await cloud.failNextRead()
            do {
                try await device.coordinator.save(sharedFresh, store: device.store, context: context)
                XCTFail("The first post-OAuth read must fail")
            } catch { XCTAssertEqual(error as? TraktSharedRefreshError, .unavailable) }
            let peer = SharedDevice(cloud: cloud)
            _ = try await peer.coordinator.disconnect(store: peer.store)
            let restarted = SharedDevice(cloud: cloud, store: device.store, journal: device.journal)
            do {
                _ = try await restarted.access(SharedRefreshHTTP())
                XCTFail("A fresh device cannot turn unknown/absent into the later tombstone epoch")
            } catch { XCTAssertEqual(error as? TraktSharedRefreshError, .superseded) }
            XCTAssertNil(device.store.load())
        }
    }

    func testUnknownBaselineMustBeResolvedBeforeAuthorizationCanCommit() async throws {
        let cloud = FakeTraktCloud()
        let device = SharedDevice(cloud: cloud)
        await cloud.failNextRead()
        do {
            _ = try await device.coordinator.prepareConnection(store: device.store)
            XCTFail("OAuth must not start without a known baseline")
        } catch { XCTAssertEqual(error as? TraktSharedRefreshError, .unavailable) }
        do {
            try await device.coordinator.save(sharedFresh, store: device.store)
            XCTFail("Shared save must not silently prepare after OAuth")
        } catch { XCTAssertEqual(error as? TraktSharedRefreshError, .superseded) }
        XCTAssertNil(device.store.load())
        let records = await cloud.recordCount
        XCTAssertEqual(records, 0)
    }

    func testAccessorJoiningPreparationStillResolvesTheCloudGrant() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedFresh, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let gate = SharedCloudGate()
        await cloud.pauseNextRead(using: gate)
        let preparation = Task { try await device.coordinator.prepareConnection(store: device.store) }
        await gate.waitUntilStarted()
        let owner = await device.coordinator.refreshes[profileA]
        XCTAssertEqual(owner?.resolvesAccessToken, false)
        let entered = expectation(description: "Accessor joined connection preparation")
        let http = SharedRefreshHTTP()
        let access = Task {
            try await device.coordinator.accessAfterSignaling(
                store: device.store, http: http, entered: { entered.fulfill() }
            )
        }
        await fulfillment(of: [entered], timeout: 5)
        let joinedOwner = await device.coordinator.refreshes[profileA]
        XCTAssertEqual(joinedOwner?.id, owner?.id)
        await gate.release()
        _ = try await preparation.value
        let result = try await access.value
        XCTAssertEqual(result, sharedFresh.accessToken)
        XCTAssertEqual(device.store.load(), sharedFresh)
        let count = await http.count
        XCTAssertEqual(count, 0)
    }

    func testSignOutDuringOAuthInvalidatesPreparedRemoteEpoch() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedFresh, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let context = try await device.coordinator.prepareConnection(store: device.store)
        let peer = SharedDevice(cloud: cloud)
        _ = try await peer.coordinator.disconnect(store: peer.store)
        do {
            try await device.coordinator.save(sharedFresh, store: device.store, context: context)
            XCTFail("A grant authorized against the previous epoch cannot undo sign-out")
        } catch { XCTAssertEqual(error as? TraktSharedRefreshError, .superseded) }
        XCTAssertNil(device.store.load())
    }

    func testConnectionContextIsBoundToProfileAndLocalRevision() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedFresh, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let context = try await device.coordinator.prepareConnection(store: device.store)
        let other = SharedTestTokenStore(scope: profileB)
        do {
            try await device.coordinator.save(sharedFresh, store: other, context: context)
            XCTFail("A prepared connection cannot cross profiles")
        } catch { XCTAssertEqual(error as? TraktSharedRefreshError, .superseded) }
        _ = try await device.coordinator.disconnect(store: device.store)
        do {
            try await device.coordinator.save(sharedFresh, store: device.store, context: context)
            XCTFail("Local disconnect invalidates an outstanding authorization context")
        } catch { XCTAssertEqual(error as? TraktSharedRefreshError, .superseded) }
        XCTAssertNil(other.load())
        XCTAssertNil(device.store.load())
    }

    func testFailedExchangeStartedWriteKeepsUnspentClaimThroughRetriesAndRestart() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let journal = FakeTraktJournal()
        journal.failExchangeStartedWrites = 2
        let store = SharedTestTokenStore(scope: profileA)
        let http = SharedRefreshHTTP()
        for _ in 0..<2 {
            let device = SharedDevice(cloud: cloud, store: store, journal: journal)
            do { _ = try await device.access(http); XCTFail("Boundary persistence must succeed before HTTP") }
            catch { XCTAssertEqual(error as? TraktSharedRefreshError, .retryable(retryNotBefore: nil)) }
            let retained = try JSONDecoder().decode(
                TraktSharedJournalState.self, from: XCTUnwrap(journal.read(scope: profileA))
            )
            XCTAssertEqual(retained.pending?.kind, .claimPrepared)
            let count = await http.count
            XCTAssertEqual(count, 0)
        }
        let recovered = SharedDevice(cloud: cloud, store: store, journal: journal)
        let access = try await recovered.access(http)
        XCTAssertEqual(access, "next-access")
        let count = await http.count
        XCTAssertEqual(count, 1)
    }

    func testFailedBoundaryWriteAfterStorageChangedStillRollsBackBeforeHTTP() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let journal = FakeTraktJournal()
        journal.failExchangeStartedAfterWriteOnce = true
        let device = SharedDevice(cloud: cloud, journal: journal)
        let http = SharedRefreshHTTP()
        do { _ = try await device.access(http); XCTFail("A failed acknowledgement is not permission to send") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .retryable(retryNotBefore: nil)) }
        let state = try JSONDecoder().decode(
            TraktSharedJournalState.self, from: XCTUnwrap(journal.read(scope: profileA))
        )
        XCTAssertEqual(state.pending?.kind, .claimPrepared)
        let before = await http.count
        XCTAssertEqual(before, 0)
        let restarted = SharedDevice(cloud: cloud, store: device.store, journal: journal)
        let access = try await restarted.access(http)
        XCTAssertEqual(access, "next-access")
        let after = await http.count
        XCTAssertEqual(after, 1)
    }

    func testRateLimitedClaimKeepsTypedRetryAndDeadlineAcrossRestart() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let clock = SharedTestClock()
        let device = SharedDevice(cloud: cloud, now: { clock.read() })
        let http = SharedRefreshHTTP(rateLimited: true, retryAfter: 120)
        let deadline = clock.read().addingTimeInterval(120)
        do { _ = try await device.access(http); XCTFail("Rate limit must be a recoverable shared error") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .retryable(retryNotBefore: deadline)) }
        let state = try JSONDecoder().decode(
            TraktSharedJournalState.self, from: XCTUnwrap(device.journal.read(scope: profileA))
        )
        XCTAssertEqual(state.pending?.kind, .claimPrepared)
        XCTAssertEqual(state.pending?.retryNotBefore, deadline)
        let restarted = SharedDevice(
            cloud: cloud, store: device.store, journal: device.journal, now: { clock.read() }
        )
        for advance in [0.0, 119.0] {
            clock.advance(advance)
            do { _ = try await restarted.access(http); XCTFail("Retry cannot bypass Retry-After") }
            catch { XCTAssertEqual(error as? TraktSharedRefreshError, .retryable(retryNotBefore: deadline)) }
            let count = await http.count
            XCTAssertEqual(count, 1)
        }
        clock.advance(1)
        let access = try await restarted.access(http)
        XCTAssertEqual(access, "next-access")
        let count = await http.count
        XCTAssertEqual(count, 2, "One rejected request followed by one successful exchange")
    }

    func testRateLimitWithoutRetryAfterUsesPersistedFallbackDelay() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let clock = SharedTestClock()
        let device = SharedDevice(cloud: cloud, now: { clock.read() })
        let http = SharedRefreshHTTP(rateLimited: true)
        let deadline = clock.read().addingTimeInterval(60)
        for _ in 0..<2 {
            do { _ = try await device.access(http); XCTFail("Missing Retry-After still needs backoff") }
            catch { XCTAssertEqual(error as? TraktSharedRefreshError, .retryable(retryNotBefore: deadline)) }
        }
        let count = await http.count
        XCTAssertEqual(count, 1)
    }

    func testOfflineDisconnectIsDurableAndRetriesWithoutRestoringTokens() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedFresh, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let http = SharedRefreshHTTP()
        _ = try await device.access(http)
        await cloud.setOffline(true)
        do { _ = try await device.coordinator.disconnect(store: device.store); XCTFail("Cloud retry is required") }
        catch { XCTAssertEqual(error as? TraktSharedRefreshError, .unavailable) }
        XCTAssertNil(device.store.load())
        await cloud.setOffline(false)
        let restarted = SharedDevice(cloud: cloud, store: device.store, journal: device.journal)
        let access = try await restarted.access(http)
        XCTAssertNil(access)
        let peer = SharedDevice(cloud: cloud)
        let peerAccess = try await peer.access(http)
        XCTAssertNil(peerAccess)
    }
}

final class TraktSharedConnectionLifecycleTests: XCTestCase {
    @MainActor
    func testBrowserPreparationFailureDoesNotLaunchBrowserOrAuthorize() async {
        await assertPreparationFailure(flow: .browser)
    }

    @MainActor
    func testDevicePreparationFailureDoesNotRequestDeviceCode() async {
        await assertPreparationFailure(flow: .device)
    }

    @MainActor
    func testBrowserGrantCompletionCannotOverwriteSignOutAfterPreparation() async throws {
        try await assertGrantCannotUndoSignOut(flow: .browser)
    }

    @MainActor
    func testDeviceGrantCompletionCannotOverwriteSignOutAfterPreparation() async throws {
        try await assertGrantCannotUndoSignOut(flow: .device)
    }

    @MainActor
    func testFollowerOffersExplicitReconnectButRetryNeverStartsAuthorization() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let owner = SharedDevice(cloud: cloud)
        let heldRefresh = SharedRefreshHTTP(paused: true)
        let rotation = Task { try await owner.access(heldRefresh) }
        await heldRefresh.waitUntilStarted()
        let follower = SharedDevice(cloud: cloud)
        let http = SharedLifecycleHTTP()
        let service = makeService(device: follower, http: http)

        for _ in 0..<2 {
            await service.refreshStatus()
            assertSyncError(service, .refreshInProgress, canReconnect: true)
            let requests = await http.requests
            XCTAssertTrue(requests.isEmpty)
            XCTAssertNil(service.connectTask)
        }
        await heldRefresh.release()
        _ = try await rotation.value
        await service.refreshStatus()
        XCTAssertEqual(service.phase, .connected(username: "viewer"))
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/users/settings"])
        XCTAssertNil(service.connectTask)
        let exchanges = await heldRefresh.count
        XCTAssertEqual(exchanges, 1)
    }

    @MainActor
    func testRateLimitedFacadeOffersRetryAndHonorsDeadlineWithoutAuthorization() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let clock = SharedTestClock()
        let device = SharedDevice(cloud: cloud, now: { clock.read() })
        let http = SharedLifecycleHTTP(refreshFailure: .rateLimited(seconds: 120))
        let service = makeService(device: device, http: http)
        let deadline = clock.read().addingTimeInterval(120)

        await service.refreshStatus()
        assertSyncError(service, .retryable(retryNotBefore: deadline), canReconnect: false)
        for advance in [0.0, 119.0] {
            clock.advance(advance)
            await service.refreshStatus()
            assertSyncError(service, .retryable(retryNotBefore: deadline), canReconnect: false)
            let requests = await http.requests
            XCTAssertEqual(requests.map(\.path), ["/oauth/token"])
            XCTAssertEqual(requests.map(\.grantType), ["refresh_token"])
            XCTAssertNil(service.connectTask)
        }
        clock.advance(1)
        await service.refreshStatus()
        XCTAssertEqual(service.phase, .connected(username: "viewer"))
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/oauth/token", "/oauth/token", "/users/settings"])
        XCTAssertEqual(requests.compactMap(\.grantType), ["refresh_token", "refresh_token"])
        XCTAssertNil(service.connectTask)
    }

    @MainActor
    func testConfirmedUndeliveredFacadeOffersRetryWithoutNewAuthorization() async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedExpired, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let http = SharedLifecycleHTTP(refreshFailure: .notSent)
        let service = makeService(device: device, http: http)

        await service.refreshStatus()
        assertSyncError(service, .retryable(retryNotBefore: nil), canReconnect: false)
        XCTAssertNil(service.connectTask)
        await service.refreshStatus()
        XCTAssertEqual(service.phase, .connected(username: "viewer"))
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/oauth/token", "/oauth/token", "/users/settings"])
        XCTAssertEqual(requests.compactMap(\.grantType), ["refresh_token", "refresh_token"])
        XCTAssertNil(service.connectTask)
    }

    @MainActor
    func testBrowserPublicationRetryCommitsRetainedGrantWithoutReauthorization() async throws {
        try await assertPublicationRetry(flow: .browser)
    }

    @MainActor
    func testDevicePublicationRetryCommitsRetainedGrantWithoutReauthorization() async throws {
        try await assertPublicationRetry(flow: .device)
    }

    private enum Flow: Sendable, Equatable { case browser, device }

    @MainActor
    private func makeService(device: SharedDevice, http: SharedLifecycleHTTP) -> TraktService {
        TraktService(
            config: TraktConfig(clientID: "test-client"), http: http,
            tokenStore: device.store, coordinator: device.coordinator
        )
    }

    @MainActor
    private func start(_ flow: Flow, service: TraktService, browser: SharedLifecycleBrowser) {
        switch flow {
        case .browser:
            service.connect { url, callback in try browser.callback(url: url, redirect: callback) }
        case .device:
            service.connect()
        }
    }

    @MainActor
    private func assertSyncError(
        _ service: TraktService, _ error: TraktSharedRefreshError, canReconnect: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            service.phase, .syncError(message: error.userMessage, canReconnect: canReconnect),
            file: file, line: line
        )
    }

    @MainActor
    private func assertPreparationFailure(flow: Flow) async {
        let cloud = FakeTraktCloud()
        await cloud.failNextRead()
        let device = SharedDevice(cloud: cloud)
        let http = SharedLifecycleHTTP()
        let service = makeService(device: device, http: http)
        let browser = SharedLifecycleBrowser()
        start(flow, service: service, browser: browser)
        await service.connectTask?.value
        assertSyncError(service, .unavailable, canReconnect: false)
        XCTAssertEqual(browser.launches, 0)
        XCTAssertNil(device.store.load())
        let beforeRetry = await http.requests
        XCTAssertTrue(beforeRetry.isEmpty)

        await service.refreshStatus()
        XCTAssertEqual(service.phase, .disconnected)
        XCTAssertEqual(browser.launches, 0)
        let afterRetry = await http.requests
        XCTAssertTrue(afterRetry.isEmpty)
    }

    @MainActor
    private func assertGrantCannotUndoSignOut(flow: Flow) async throws {
        let cloud = FakeTraktCloud()
        try await cloud.seed(sharedFresh, scope: profileA)
        let device = SharedDevice(cloud: cloud)
        let gate = SharedCloudGate()
        let http = SharedLifecycleHTTP(grantGate: gate)
        let service = makeService(device: device, http: http)
        let browser = SharedLifecycleBrowser()
        var connectionNotifications = 0
        service.onConnectionAvailable = { connectionNotifications += 1 }
        start(flow, service: service, browser: browser)
        let connection = service.connectTask
        // Gate the completed browser/device token exchange, not a guessed delay.
        await gate.waitUntilStarted()
        let peer = SharedDevice(cloud: cloud)
        do {
            _ = try await peer.coordinator.disconnect(store: peer.store)
        } catch {
            await gate.release()
            await connection?.value
            throw error
        }
        await gate.release()
        await connection?.value
        assertSyncError(service, .superseded, canReconnect: false)
        XCTAssertNil(device.store.load())
        XCTAssertEqual(connectionNotifications, 0)
        XCTAssertEqual(browser.launches, flow == .browser ? 1 : 0)
        let beforeRetry = await http.requests
        XCTAssertEqual(
            beforeRetry.map(\.path),
            flow == .browser ? ["/oauth/token"] : ["/oauth/device/code", "/oauth/device/token"]
        )
        await service.refreshStatus()
        XCTAssertEqual(service.phase, .disconnected)
        let afterRetry = await http.requests
        XCTAssertEqual(afterRetry, beforeRetry)
        XCTAssertEqual(connectionNotifications, 0)
    }

    @MainActor
    private func assertPublicationRetry(flow: Flow) async throws {
        let cloud = FakeTraktCloud()
        await cloud.failNextConnection()
        let device = SharedDevice(cloud: cloud)
        let http = SharedLifecycleHTTP()
        let service = makeService(device: device, http: http)
        let browser = SharedLifecycleBrowser()
        var connectionNotifications = 0
        service.onConnectionAvailable = { connectionNotifications += 1 }
        start(flow, service: service, browser: browser)
        await service.connectTask?.value
        assertSyncError(service, .unavailable, canReconnect: false)
        XCTAssertNil(device.store.load())
        XCTAssertEqual(connectionNotifications, 0)
        let retained = try JSONDecoder().decode(
            TraktSharedJournalState.self, from: XCTUnwrap(device.journal.read(scope: profileA))
        )
        XCTAssertEqual(retained.pending?.kind, .connect)
        XCTAssertEqual(retained.pending?.grant.tokens?.accessToken, "authorized-access")
        let beforeRetry = await http.requests
        XCTAssertEqual(
            beforeRetry.map(\.path),
            flow == .browser ? ["/oauth/token"] : ["/oauth/device/code", "/oauth/device/token"]
        )

        await service.refreshStatus()
        XCTAssertEqual(service.phase, .connected(username: "viewer"))
        XCTAssertEqual(device.store.load()?.accessToken, "authorized-access")
        XCTAssertEqual(connectionNotifications, 1)
        XCTAssertEqual(browser.launches, flow == .browser ? 1 : 0)
        let afterRetry = await http.requests
        XCTAssertEqual(Array(afterRetry.dropLast()), beforeRetry)
        XCTAssertEqual(afterRetry.last?.path, "/users/settings")
        XCTAssertEqual(afterRetry.filter { $0.grantType == "authorization_code" }.count, flow == .browser ? 1 : 0)
        XCTAssertTrue(afterRetry.allSatisfy { $0.grantType != "refresh_token" })
    }
}

@MainActor
private final class SharedLifecycleBrowser {
    private(set) var launches = 0

    func callback(url: URL, redirect: URL) throws -> URL {
        launches += 1
        let state = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value
        )
        var response = try XCTUnwrap(URLComponents(url: redirect, resolvingAgainstBaseURL: false))
        response.queryItems = [
            URLQueryItem(name: "code", value: "approved"),
            URLQueryItem(name: "state", value: state)
        ]
        return try XCTUnwrap(response.url)
    }
}

private actor SharedLifecycleHTTP: HTTPClient {
    struct Request: Sendable, Equatable {
        let path: String
        let grantType: String?
    }

    enum RefreshFailure: Sendable {
        case notSent
        case rateLimited(seconds: TimeInterval)
    }

    private var grantGate: SharedCloudGate?
    private var refreshFailure: RefreshFailure?
    private(set) var requests: [Request] = []

    init(grantGate: SharedCloudGate? = nil, refreshFailure: RefreshFailure? = nil) {
        self.grantGate = grantGate
        self.refreshFailure = refreshFailure
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let result = try await sendRaw(endpoint, baseURL: baseURL)
        guard (200..<300).contains(result.1.statusCode) else { throw AppError.invalidResponse }
        return result
    }

    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let body = endpoint.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let grantType = body?["grant_type"] as? String
        requests.append(Request(path: endpoint.path, grantType: grantType))
        switch endpoint.path {
        case "/oauth/device/code":
            return response("""
            {"device_code":"device","user_code":"ABCD","verification_url":"https://auth.trakt.tv/activate","expires_in":600,"interval":1}
            """, baseURL: baseURL)
        case "/oauth/device/token":
            await holdAuthorizationResponseIfNeeded()
            return token("authorized", baseURL: baseURL)
        case "/oauth/token":
            if grantType == "authorization_code" {
                await holdAuthorizationResponseIfNeeded()
                return token("authorized", baseURL: baseURL)
            }
            guard grantType == "refresh_token" else { throw AppError.invalidResponse }
            if let failure = refreshFailure {
                refreshFailure = nil
                switch failure {
                case .notSent:
                    throw HTTPRequestNotSentError(underlying: .serverUnreachable)
                case .rateLimited(let seconds):
                    return response(
                        #"{"error":"rate_limit_exceeded"}"#, baseURL: baseURL,
                        status: 429, headers: ["Retry-After": String(seconds)]
                    )
                }
            }
            return token("next", baseURL: baseURL)
        case "/users/settings":
            return response(#"{"user":{"username":"viewer"}}"#, baseURL: baseURL)
        default:
            throw AppError.notFound
        }
    }

    private func holdAuthorizationResponseIfNeeded() async {
        if let gate = grantGate {
            grantGate = nil
            await gate.suspend()
        }
    }

    private func token(_ prefix: String, baseURL: URL) -> (Data, HTTPURLResponse) {
        response("""
        {"access_token":"\(prefix)-access","refresh_token":"\(prefix)-refresh","expires_in":604800,"created_at":\(Int(Date().timeIntervalSince1970))}
        """, baseURL: baseURL)
    }

    private func response(
        _ json: String, baseURL: URL, status: Int = 200, headers: [String: String] = [:]
    ) -> (Data, HTTPURLResponse) {
        (
            Data(json.utf8),
            HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: headers)!
        )
    }
}

private struct SharedDevice {
    let store: SharedTestTokenStore
    let journal: FakeTraktJournal
    let coordinator: TraktTokenCoordinator

    init(
        cloud: FakeTraktCloud,
        store: SharedTestTokenStore = SharedTestTokenStore(scope: profileA),
        journal: FakeTraktJournal = FakeTraktJournal(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.journal = journal
        coordinator = TraktTokenCoordinator(
            sharedConfiguration: .init(transport: cloud, journal: journal), now: now
        )
    }

    func access(_ http: SharedRefreshHTTP) async throws -> String? {
        try await coordinator.accessToken(
            store: store, auth: TraktAuthService(config: TraktConfig(clientID: "test-client"), http: http)
        )
    }
}

private extension TraktTokenCoordinator {
    func accessAfterSignaling(
        store: any TraktTokenStoring, http: SharedRefreshHTTP,
        entered: @Sendable () -> Void
    ) async throws -> String? {
        entered()
        return try await accessToken(
            store: store, auth: TraktAuthService(config: TraktConfig(clientID: "test-client"), http: http)
        )
    }

    func syncAfterSignaling(
        store: any TraktTokenStoring, entered: @Sendable () -> Void
    ) async throws {
        entered()
        try await synchronizeShared(store: store)
    }
}

private actor SharedCloudGate {
    private var started = false
    private var released = false
    private var starters: [CheckedContinuation<Void, Never>] = []
    private var waiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        starters.forEach { $0.resume() }
        starters = []
        if !released { await withCheckedContinuation { waiter = $0 } }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { starters.append($0) }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private final class SharedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 4_000_000_000)

    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(seconds)
    }
}

private enum SharedStorageFailure: Error { case write }

private final class SharedTestTokenStore: TraktTokenStoring, @unchecked Sendable {
    let coordinationID: String
    private let lock = NSLock()
    private var tokens: TraktTokens?
    var failSuccessorOnce = false

    init(scope: String, tokens: TraktTokens? = nil) {
        coordinationID = scope
        self.tokens = tokens
    }
    func load() -> TraktTokens? { lock.lock(); defer { lock.unlock() }; return tokens }
    func save(_ tokens: TraktTokens) throws {
        lock.lock(); defer { lock.unlock() }
        if failSuccessorOnce && tokens.refreshToken == "next-refresh" {
            failSuccessorOnce = false
            throw SharedStorageFailure.write
        }
        self.tokens = tokens
    }
    func clear() throws { lock.lock(); defer { lock.unlock() }; tokens = nil }
    func snapshot() -> any TraktTokenStoring { self }
    func setNamespace(_ namespace: String?) {}
}

private final class FakeTraktJournal: TraktSharedRefreshJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    var failSuccessorOnce = false
    var failExchangeStartedWrites = 0
    var failExchangeStartedAfterWriteOnce = false

    func read(scope: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return data[scope] }
    func write(_ value: Data, scope: String) throws {
        lock.lock(); defer { lock.unlock() }
        let state = try JSONDecoder().decode(TraktSharedJournalState.self, from: value)
        if state.pending?.kind == .exchangeStarted {
            if failExchangeStartedWrites > 0 {
                failExchangeStartedWrites -= 1
                throw SharedStorageFailure.write
            }
            if failExchangeStartedAfterWriteOnce {
                failExchangeStartedAfterWriteOnce = false
                data[scope] = value
                throw SharedStorageFailure.write
            }
        }
        if failSuccessorOnce && state.pending?.kind == .successor {
            failSuccessorOnce = false
            throw SharedStorageFailure.write
        }
        data[scope] = value
    }
}

private actor FakeTraktCloud: TraktSharedRefreshTransport {
    private var account = "icloud-account"
    private var records: [String: TraktSharedRecord] = [:]
    private var legacy: [String: TraktTokens] = [:]
    private var sequence = 0
    private var offline = false
    private var failSuccessor = false
    private var failConnection = false
    private var failRead = false
    private var loseClaimAcknowledgement = false
    private var loseSuccessorAcknowledgement = false
    private var pairClaims = false
    private var claimWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextReadGate: SharedCloudGate?
    private var nextSuccessorGate: SharedCloudGate?
    private(set) var successfulClaims = 0
    private(set) var readCount = 0
    var recordCount: Int { records.count }

    func accountID() throws -> String {
        if offline { throw TraktSharedRefreshError.unavailable }
        return account
    }
    func read(scope: String, accountID: String) async throws -> TraktSharedRecord? {
        guard try self.accountID() == accountID else { throw TraktSharedRefreshError.accountChanged }
        readCount += 1
        if failRead { failRead = false; throw TraktSharedRefreshError.unavailable }
        let snapshot = records[scope]
        if let gate = nextReadGate {
            nextReadGate = nil
            await gate.suspend()
        }
        return snapshot
    }
    func readLegacyTokens(scope: String, accountID: String) throws -> TraktTokens? {
        guard try self.accountID() == accountID else { throw TraktSharedRefreshError.accountChanged }
        return legacy[scope]
    }
    func compareAndSwap(
        scope: String, accountID: String, expected: TraktSharedRecord?, value: Data
    ) async throws -> TraktSharedRecord {
        let grant = try TraktSharedGrant.decode(value)
        if grant.phase == .ready, grant.generation > 0, let gate = nextSuccessorGate {
            nextSuccessorGate = nil
            await gate.suspend()
        }
        if pairClaims, grant.phase == .refreshing {
            await withCheckedContinuation { continuation in
                claimWaiters.append(continuation)
                if claimWaiters.count == 2 {
                    pairClaims = false
                    claimWaiters.forEach { $0.resume() }
                    claimWaiters = []
                }
            }
        }
        guard try self.accountID() == accountID else { throw TraktSharedRefreshError.accountChanged }
        guard records[scope]?.version == expected?.version else { throw TraktSharedRefreshError.conflict }
        if failConnection, grant.phase == .ready, grant.generation == 0 {
            failConnection = false
            throw TraktSharedRefreshError.unavailable
        }
        if failSuccessor, grant.phase == .ready, grant.generation > 0 {
            failSuccessor = false
            throw TraktSharedRefreshError.unavailable
        }
        sequence += 1
        let saved = TraktSharedRecord(value: value, version: Data(String(sequence).utf8))
        records[scope] = saved
        if grant.phase == .refreshing { successfulClaims += 1 }
        if loseClaimAcknowledgement, grant.phase == .refreshing {
            loseClaimAcknowledgement = false
            throw TraktSharedRefreshError.unavailable
        }
        if loseSuccessorAcknowledgement, grant.phase == .ready, grant.generation > 0 {
            loseSuccessorAcknowledgement = false
            throw TraktSharedRefreshError.unavailable
        }
        return saved
    }
    func seed(_ tokens: TraktTokens, scope: String) throws {
        sequence += 1
        records[scope] = .init(
            value: try TraktSharedGrant.ready(tokens).encoded(), version: Data(String(sequence).utf8)
        )
    }
    func setLegacy(_ tokens: TraktTokens, scope: String) { legacy[scope] = tokens }
    func failNextSuccessor() { failSuccessor = true }
    func failNextConnection() { failConnection = true }
    func failNextRead() { failRead = true }
    func loseNextClaimAcknowledgement() { loseClaimAcknowledgement = true }
    func loseNextSuccessorAcknowledgement() { loseSuccessorAcknowledgement = true }
    func synchronizeNextTwoClaims() { pairClaims = true }
    func pauseNextRead(using gate: SharedCloudGate) { nextReadGate = gate }
    func pauseNextSuccessor(using gate: SharedCloudGate) { nextSuccessorGate = gate }
    func setOffline(_ value: Bool) { offline = value }
    func switchAccount(_ value: String) { account = value; records = [:]; legacy = [:] }
    func removeRecord(scope: String) { records[scope] = nil }
}

private actor SharedRefreshHTTP: HTTPClient {
    private var paused: Bool
    private let fail: Bool
    private let notSent: Bool
    private var rateLimited: Bool
    private let retryAfter: TimeInterval?
    private var started: [CheckedContinuation<Void, Never>] = []
    private var response: CheckedContinuation<Void, Never>?
    var count = 0

    init(
        paused: Bool = false, fail: Bool = false, notSent: Bool = false,
        rateLimited: Bool = false, retryAfter: TimeInterval? = nil
    ) {
        self.paused = paused
        self.fail = fail
        self.notSent = notSent
        self.rateLimited = rateLimited
        self.retryAfter = retryAfter
    }
    func waitUntilStarted() async {
        if count > 0 { return }
        await withCheckedContinuation { started.append($0) }
    }
    func release() { paused = false; response?.resume(); response = nil }
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        count += 1
        started.forEach { $0.resume() }
        started = []
        if paused { await withCheckedContinuation { response = $0 } }
        if notSent { throw HTTPRequestNotSentError(underlying: .serverUnreachable) }
        if rateLimited {
            rateLimited = false
            throw AppError.rateLimited(retryAfter: retryAfter)
        }
        if fail { throw AppError.serverUnreachable }
        let json = """
        {"access_token":"next-access","refresh_token":"next-refresh","expires_in":604800,"created_at":\(Int(Date().timeIntervalSince1970))}
        """
        return (
            Data(json.utf8),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
