import Foundation
import XCTest
@testable import FeatureSettings
@testable import PublicMetaDBService
@testable import TestSupportNetworking

@MainActor
final class PublicMetaDBReadOperationTests: XCTestCase {
    private func withService(_ body: (PublicMetaDBService) async throws -> Void) async throws {
        let name = "PublicMetaDBReadOperationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: #"{"items":[],"total":0,"page":1,"perPage":1,"totalPages":0}"#)
        let service = PublicMetaDBService(credentials: ReadCredentials(), http: http, defaults: defaults)
        let key = "pm-" + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(60)
        await service.connect(key: key)
        XCTAssertEqual(service.phase, .connected)
        try await body(service)
    }

    func testOlderReadCannotOverwriteNewerResultOrErrorState() async throws {
        for oldFails in [false, true] {
            try await withService { service in
                let model = PublicMetaDBReadOperation<Int>()
                let started = expectation(description: "Old read started")
                var continuation: CheckedContinuation<Int, any Error>?
                let old = Task {
                    await model.load(service: service) { _ in
                        try await withCheckedThrowingContinuation {
                            continuation = $0
                            started.fulfill()
                        }
                    }
                }
                await fulfillment(of: [started], timeout: 2)
                await model.load(service: service) { _ in 2 }
                if oldFails { continuation?.resume(throwing: PublicMetaDB.Failure.rejected) }
                else { continuation?.resume(returning: 1) }
                await old.value
                XCTAssertEqual(model.value, 2)
                XCTAssertNil(model.failure)
                XCTAssertFalse(model.loading)
            }
        }
    }

    func testProfileSwitchRejectsAnInFlightResultEvenIfTransportFinishes() async throws {
        try await withService { service in
            let model = PublicMetaDBReadOperation<Int>()
            let started = expectation(description: "Read started")
            var continuation: CheckedContinuation<Int, any Error>?
            let read = Task {
                await model.load(service: service) { _ in
                    try await withCheckedThrowingContinuation {
                        continuation = $0
                        started.fulfill()
                    }
                }
            }
            await fulfillment(of: [started], timeout: 2)
            service.selectProfile(namespace: "different-profile")
            continuation?.resume(returning: 1)
            await read.value
            XCTAssertNil(model.value)
            XCTAssertFalse(model.loading)
            await model.load(service: service) { _ in
                XCTFail("Disconnected profile ran a read")
                return 2
            }
            XCTAssertNil(model.value)
            XCTAssertEqual(model.failure as? PublicMetaDB.Failure, .disconnected)
        }
    }

    func testCancellationNeverPublishesAnOtherwiseSuccessfulResult() async throws {
        try await withService { service in
            let model = PublicMetaDBReadOperation<Int>()
            let started = expectation(description: "Read started")
            var continuation: CheckedContinuation<Int, any Error>?
            let read = Task {
                await model.load(service: service) { _ in
                    try await withCheckedThrowingContinuation {
                        continuation = $0
                        started.fulfill()
                    }
                }
            }
            await fulfillment(of: [started], timeout: 2)
            read.cancel()
            continuation?.resume(returning: 1)
            await read.value
            XCTAssertNil(model.value)
            XCTAssertTrue(model.failure is CancellationError)
            XCTAssertFalse(model.loading)
        }
    }
}

private struct ReadCredentials: PublicMetaDBCredentialStoring {
    func load(namespace: String?) -> PublicMetaDBCredentials? { nil }
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws {}
    func clear(namespace: String?) throws {}
}
