import Foundation
import XCTest
import CoreModels
@testable import CoreSecureStore

@MainActor
final class SerializedCredentialPublisherTests: XCTestCase {
    func testSlowKeychainWriteDoesNotBlockMainActorAndUnchangedValuesAreNotRewritten() async {
        let entered = expectation(description: "Background write entered")
        let release = DispatchSemaphore(value: 0)
        let store = PublisherTestStore {
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        let publisher = makePublisher(store)
        defer { release.signal() }
        publisher.publish {
            XCTAssertFalse(Thread.isMainThread, "Credential reads and encoding must also stay off main")
            return ["account": "token"]
        }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(Thread.isMainThread)
        release.signal()
        await publisher.waitForPendingOperations()
        publisher.publish { ["account": "token"] }
        await publisher.waitForPendingOperations()
        XCTAssertEqual(store.writes, 1)
        XCTAssertEqual(store.string(for: "account"), "token")
    }

    func testSignOutWaitsBehindInFlightWriteAndCancelsOlderQueuedPublication() async {
        let entered = expectation(description: "In-flight write")
        let release = DispatchSemaphore(value: 0)
        let store = PublisherTestStore {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        let publisher = makePublisher(store)
        defer { release.signal() }
        publisher.publish { ["account": "token"] }
        await fulfillment(of: [entered], timeout: 3)
        publisher.publish { ["account": "stale"] }
        publisher.removeValue(for: "account")
        XCTAssertFalse(publisher.mayRead("account"))
        release.signal()
        await publisher.waitForPendingOperations()
        XCTAssertNil(store.string(for: "account"))
        XCTAssertEqual(store.writes, 1)
        XCTAssertTrue(publisher.mayRead("account"))
    }

    func testPurgeCannotBeUndoneByAnOlderPublication() async {
        let entered = expectation(description: "In-flight write")
        let cleared = expectation(description: "Purge completed")
        let release = DispatchSemaphore(value: 0)
        let store = PublisherTestStore {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        let publisher = makePublisher(store)
        defer { release.signal() }
        publisher.publish { ["account": "token"] }
        await fulfillment(of: [entered], timeout: 3)
        publisher.publish { ["account": "stale"] }
        publisher.removeAll {
            if case .failure(let error) = $0 { XCTFail("Purge failed: \(error)") }
            cleared.fulfill()
        }
        XCTAssertFalse(publisher.mayRead("account"))
        XCTAssertFalse(publisher.mayRead("household.seerr.connection.v1"))
        release.signal()
        await fulfillment(of: [cleared], timeout: 3)
        await publisher.waitForPendingOperations()
        XCTAssertNil(store.string(for: "account"))
        XCTAssertEqual(store.writes, 1)
    }

    func testDisableCancelsPublicationWhileCredentialSnapshotIsBeingRead() async {
        let entered = expectation(description: "Reading credentials")
        let release = DispatchSemaphore(value: 0)
        let store = PublisherTestStore()
        let publisher = makePublisher(store)
        defer { release.signal() }
        publisher.publish {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return ["account": "token"]
        }
        await fulfillment(of: [entered], timeout: 3)
        publisher.cancelPendingPublication()
        release.signal()
        await publisher.waitForPendingOperations()
        XCTAssertEqual(store.writes, 0)
    }

    func testNewerSnapshotSupersedesQueuedAndInFlightSnapshots() async {
        let entered = expectation(description: "Reading old snapshot")
        let release = DispatchSemaphore(value: 0)
        let store = PublisherTestStore()
        let publisher = makePublisher(store)
        defer { release.signal() }
        publisher.publish {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return ["account": "old"]
        }
        await fulfillment(of: [entered], timeout: 3)
        publisher.publish { ["account": "superseded"] }
        publisher.publish { ["account": "latest"] }
        release.signal()
        await publisher.waitForPendingOperations()
        XCTAssertEqual(store.string(for: "account"), "latest")
        XCTAssertEqual(store.writes, 1)
    }

    func testFailedWritesRetryAndRemoteDeletionIsNotHiddenBySuccessCache() async {
        let failed = expectation(description: "Write failure reported")
        let store = PublisherTestStore()
        store.failWrites = true
        let publisher = SerializedCredentialPublisher(
            store: store, clearStore: { store.clear() }, isEnabled: { true },
            onFailure: { operation, _ in
                XCTAssertEqual(operation, .publish)
                failed.fulfill()
            }
        )
        publisher.publish { ["account": "token"] }
        await fulfillment(of: [failed], timeout: 3)
        await publisher.waitForPendingOperations()
        XCTAssertNil(store.string(for: "account"))
        store.failWrites = false
        publisher.publish { ["account": "token"] }
        await publisher.waitForPendingOperations()
        XCTAssertEqual(store.string(for: "account"), "token")
        store.clear()
        publisher.publish { ["account": "token"] }
        await publisher.waitForPendingOperations()
        XCTAssertEqual(store.string(for: "account"), "token")
        XCTAssertEqual(store.writes, 2)
    }

    func testDisabledSyncDoesNotReadOrWriteCredentials() async {
        let store = PublisherTestStore()
        let publisher = SerializedCredentialPublisher(
            store: store, clearStore: { store.clear() }, isEnabled: { false },
            onFailure: { _, error in XCTFail("Unexpected failure: \(error)") }
        )
        publisher.publish {
            XCTFail("Disabled sync must not read credentials")
            return ["account": "token"]
        }
        await publisher.waitForPendingOperations()
        XCTAssertEqual(store.writes, 0)
    }

    func testReadFailureDoesNotBecomeAnUnconditionalOverwrite() async {
        let failed = expectation(description: "Read failure reported")
        let store = PublisherTestStore()
        store.failReads = true
        let publisher = SerializedCredentialPublisher(
            store: store, clearStore: { store.clear() }, isEnabled: { true },
            onFailure: { operation, _ in
                XCTAssertEqual(operation, .publish)
                failed.fulfill()
            }
        )
        publisher.publish { ["account": "token"] }
        await fulfillment(of: [failed], timeout: 3)
        await publisher.waitForPendingOperations()
        XCTAssertEqual(store.writes, 0)
        store.failReads = false
        publisher.publish { ["account": "token"] }
        await publisher.waitForPendingOperations()
        XCTAssertEqual(store.string(for: "account"), "token")
    }

    private func makePublisher(_ store: PublisherTestStore) -> SerializedCredentialPublisher {
        SerializedCredentialPublisher(
            store: store, clearStore: { store.clear() }, isEnabled: { true },
            onFailure: { _, error in XCTFail("Unexpected failure: \(error)") }
        )
    }
}

private final class PublisherTestStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var writeCount = 0
    private var writeFailure = false
    private var readFailure = false
    private let beforeWrite: @Sendable () -> Void

    init(beforeWrite: @escaping @Sendable () -> Void = {}) {
        self.beforeWrite = beforeWrite
    }

    var writes: Int { lock.withLock { writeCount } }
    var failWrites: Bool {
        get { lock.withLock { writeFailure } }
        set { lock.withLock { writeFailure = newValue } }
    }
    var failReads: Bool {
        get { lock.withLock { readFailure } }
        set { lock.withLock { readFailure = newValue } }
    }

    func setString(_ value: String, for key: String) throws {
        beforeWrite()
        try lock.withLock {
            if writeFailure { throw CocoaError(.fileWriteNoPermission) }
            values[key] = value
            writeCount += 1
        }
    }

    func string(for key: String) -> String? { lock.withLock { values[key] } }
    func readString(for key: String) throws -> String? {
        try lock.withLock {
            if readFailure { throw CocoaError(.fileReadNoPermission) }
            return values[key]
        }
    }
    func removeValue(for key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
    func clear() { lock.withLock { values = [:] } }
}
