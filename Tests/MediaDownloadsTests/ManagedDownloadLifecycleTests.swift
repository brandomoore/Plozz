import Foundation
import CoreModels
import XCTest
@testable import MediaDownloads

final class ManagedDownloadLifecycleTests: XCTestCase {
    private func record() throws -> DownloadedMediaRecord {
        var record = try DownloadTestFactory.record(status: .completed)
        record.sourceKind = .managedHTTP
        record.managedHTTPSource = ManagedHTTPDownloadSource(
            provider: .silo, accountID: "account", itemID: "movie1", mediaSourceID: "42",
            preparationReference: .init(queueIdentifier: "silo:2", itemIdentifier: "download1"))
        return record
    }

    func testRemoteDeletionSurvivesLocalRecordRemovalAndRelaunch() async throws {
        let store = InMemoryDownloadedMediaStore()
        let registry = DownloadedMediaRegistry(store: store)
        let record = try record()
        _ = try await registry.beginDownload(record)
        try await registry.remove(identityKey: record.identityKey)
        let reloaded = DownloadedMediaRegistry(store: store)
        let local = await reloaded.record(forKey: record.identityKey)
        let pending = await reloaded.pendingManagedRemovals()
        XCTAssertNil(local)
        XCTAssertEqual(pending, [try XCTUnwrap(record.managedHTTPSource)])
        try await reloaded.acknowledgeManagedRemoval(pending[0])
        let acknowledged = await reloaded.pendingManagedRemovals()
        XCTAssertTrue(acknowledged.isEmpty)
    }

    func testCompletionCanBeRetriedWithoutRedownloadingMedia() async throws {
        let store = InMemoryDownloadedMediaStore()
        let registry = DownloadedMediaRegistry(store: store)
        let record = try record()
        _ = try await registry.beginDownload(record)
        let pending = await registry.pendingManagedCompletions()
        XCTAssertEqual(pending.count, 1)
        let entry = try XCTUnwrap(pending.first)
        try await registry.acknowledgeManagedCompletion(identityKey: entry.identityKey, at: entry.updatedAt)
        let reloaded = DownloadedMediaRegistry(store: store)
        let remaining = await reloaded.pendingManagedCompletions()
        let available = await reloaded.record(forKey: entry.identityKey)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(available?.status, .completed)
    }

    func testOldDownloadStateDecodesWithoutNewOutboxes() throws {
        let state = try JSONDecoder().decode(DownloadedMediaRegistryState.self, from: Data(#"{"records":{}}"#.utf8))
        XCTAssertTrue(state.pendingManagedRemovals.isEmpty)
        XCTAssertTrue(state.managedCompletionAcknowledgements.isEmpty)
    }
}
