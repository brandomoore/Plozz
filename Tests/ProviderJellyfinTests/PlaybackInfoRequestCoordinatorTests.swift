import CoreModels
import Foundation
import XCTest
@testable import ProviderJellyfin

final class PlaybackInfoRequestCoordinatorTests: XCTestCase {
    @TaskLocal private static var requestScope = ""

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private static func response() throws -> PlaybackInfoResponse {
        try JSONDecoder().decode(PlaybackInfoResponse.self, from: Data(#"{"MediaSources":[{"Id":"file"}]}"#.utf8))
    }

    private func waitForReaders(_ count: Int, in coordinator: PlaybackInfoRequestCoordinator) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await coordinator.waitingReaderCount != count, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let actual = await coordinator.waitingReaderCount
        XCTAssertEqual(actual, count)
    }

    func testInventoryCoalescesAndCancelledReaderDoesNotReleaseRunningWork() async throws {
        let coordinator = PlaybackInfoRequestCoordinator()
        let entered = Gate()
        let release = Gate()
        let calls = Counter()
        let key = PlaybackInfoRequestCoordinator.Key(scope: UUID(), userID: "user", itemID: "item")
        let first = Task {
            try await coordinator.run(server: "server", inventoryKey: key) {
                await calls.increment()
                await entered.open()
                await release.wait()
                return try Self.response()
            }
        }
        await entered.wait()
        first.cancel()
        do { _ = try await first.value; XCTFail("The cancelled inventory reader must leave promptly.") }
        catch { XCTAssertTrue(error is CancellationError) }

        let joined = Task {
            try await coordinator.run(server: "server", inventoryKey: key) {
                await calls.increment()
                return try Self.response()
            }
        }
        let nextStarted = Counter()
        let next = Task {
            try await coordinator.run(server: "server") {
                await nextStarted.increment()
                return try Self.response()
            }
        }
        await waitForReaders(2, in: coordinator)
        // A different server remains independent while this one is blocked.
        _ = try await coordinator.run(server: "other") { try Self.response() }
        let startsBeforeRelease = await nextStarted.value
        XCTAssertEqual(startsBeforeRelease, 0)
        await release.open()
        _ = try await joined.value
        _ = try await next.value
        let inventoryCalls = await calls.value
        XCTAssertEqual(inventoryCalls, 1)
    }

    func testQueuedWorkKeepsItsOwnTaskLocalContext() async throws {
        let coordinator = PlaybackInfoRequestCoordinator()
        let entered = Gate()
        let release = Gate()
        let first = Task {
            try await Self.$requestScope.withValue("first") {
                try await coordinator.run(server: "server") {
                    await entered.open()
                    await release.wait()
                    return try Self.response()
                }
            }
        }
        await entered.wait()
        let second = Task {
            try await Self.$requestScope.withValue("second") {
                try await coordinator.run(server: "server") {
                    XCTAssertEqual(Self.requestScope, "second")
                    return try Self.response()
                }
            }
        }
        await waitForReaders(2, in: coordinator)
        await release.open()
        _ = try await first.value
        _ = try await second.value
    }

    func testTransportFailureStopsQueuedWorkAndPreventsImmediateReplacement() async throws {
        let coordinator = PlaybackInfoRequestCoordinator(backoff: .seconds(30))
        let entered = Gate()
        let release = Gate()
        let calls = Counter()
        let first = Task {
            try await coordinator.run(server: "server") {
                await entered.open()
                await release.wait()
                throw URLError(.timedOut)
            }
        }
        await entered.wait()
        let queued = Task {
            try await coordinator.run(server: "server") {
                await calls.increment()
                return try Self.response()
            }
        }
        await waitForReaders(2, in: coordinator)
        await release.open()
        do { _ = try await first.value; XCTFail("Expected the original timeout.") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        do { _ = try await queued.value; XCTFail("Do not start another server probe after the timeout.") }
        catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        do {
            _ = try await coordinator.run(server: "server") {
                await calls.increment()
                return try Self.response()
            }
            XCTFail("Immediate replacement must fail without sending.")
        } catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        let count = await calls.value
        XCTAssertEqual(count, 0)
    }

    func testUnresolvedServerResponsesAlsoBlockReplacementWork() async throws {
        let failures: [(Error, AppError)] = [
            (AppError.invalidResponse, .invalidResponse), (AppError.decoding, .decoding),
            (StreamingQualityError.serverHTTP(504), .invalidResponse),
            (StreamingQualityError.malformedResponse, .decoding)
        ]
        for (failure, blockedError) in failures {
            let coordinator = PlaybackInfoRequestCoordinator()
            let calls = Counter()
            do {
                _ = try await coordinator.run(server: "server") { throw failure }
                XCTFail("Expected the original server response failure.")
            } catch {
                if let appError = failure as? AppError {
                    XCTAssertEqual(error as? AppError, appError)
                } else {
                    XCTAssertEqual(error as? StreamingQualityError, failure as? StreamingQualityError)
                }
            }
            do {
                _ = try await coordinator.run(server: "server") {
                    await calls.increment()
                    return try Self.response()
                }
                XCTFail("A failed proxy or malformed response does not prove server work stopped.")
            } catch { XCTAssertEqual(error as? AppError, blockedError) }
            let count = await calls.value
            XCTAssertEqual(count, 0)
        }
    }

    func testCancelledStartedNegotiationStillDeliversItsLeaseForCleanup() async throws {
        let coordinator = PlaybackInfoRequestCoordinator()
        let entered = Gate()
        let release = Gate()
        let negotiation = Task {
            try await coordinator.run(server: "server") {
                await entered.open()
                await release.wait()
                return try JSONDecoder().decode(
                    PlaybackInfoResponse.self,
                    from: Data(#"{"MediaSources":[{"Id":"file"}],"PlaySessionId":"owned-session"}"#.utf8)
                )
            }
        }
        await entered.wait()
        negotiation.cancel()
        await release.open()
        let response = try await negotiation.value
        XCTAssertEqual(response.PlaySessionId, "owned-session")
    }

    func testDifferentCredentialScopesDoNotShareInventory() async throws {
        let coordinator = PlaybackInfoRequestCoordinator()
        let calls = Counter()
        let entered = Gate()
        let release = Gate()
        let tasks = [UUID(), UUID()].map { scope in
            Task {
                try await coordinator.run(
                    server: "server", inventoryKey: .init(scope: scope, userID: "user", itemID: "item")
                ) {
                    await calls.increment()
                    await entered.open()
                    await release.wait()
                    return try Self.response()
                }
            }
        }
        await entered.wait()
        await waitForReaders(2, in: coordinator)
        await release.open()
        for task in tasks { _ = try await task.value }
        let count = await calls.value
        XCTAssertEqual(count, 2)
    }

    func testCancelledQueuedWorkNeverStartsEvenWhenTheActiveRequestCompletes() async throws {
        for isInventory in [true, false] {
            let coordinator = PlaybackInfoRequestCoordinator()
            let entered = Gate()
            let release = Gate()
            let calls = Counter()
            let active = Task {
                try await coordinator.run(server: "server") {
                    await entered.open()
                    await release.wait()
                    return try Self.response()
                }
            }
            await entered.wait()
            let queued = Task {
                try await coordinator.run(
                    server: "server",
                    inventoryKey: isInventory ? .init(scope: UUID(), userID: "user", itemID: "item") : nil
                ) {
                    await calls.increment()
                    return try Self.response()
                }
            }
            await waitForReaders(2, in: coordinator)
            queued.cancel()
            await release.open()
            _ = try await active.value
            do { _ = try await queued.value; XCTFail("A cancelled queued request must not run.") }
            catch { XCTAssertTrue(error is CancellationError) }
            let count = await calls.value
            XCTAssertEqual(count, 0)
        }
    }

    func testServerRetryAfterIsHonoredBeyondLocalBackoff() async throws {
        for interval in [60, Double.greatestFiniteMagnitude] {
            let coordinator = PlaybackInfoRequestCoordinator(backoff: .zero)
            let failure = AppError.rateLimited(retryAfter: interval)
            do {
                _ = try await coordinator.run(server: "server") { throw failure }
                XCTFail("Expected rate limiting.")
            } catch { XCTAssertEqual(error as? AppError, failure) }
            do {
                _ = try await coordinator.run(server: "server") { try Self.response() }
                XCTFail("The server's Retry-After outlives the local backoff.")
            } catch { XCTAssertEqual(error as? AppError, failure) }
        }
    }

    func testExplicitRetryCanProceedAfterBackoffExpires() async throws {
        let coordinator = PlaybackInfoRequestCoordinator(backoff: .zero)
        do {
            _ = try await coordinator.run(server: "server") { throw URLError(.timedOut) }
            XCTFail("Expected timeout.")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let response = try await coordinator.run(server: "server") { try Self.response() }
        XCTAssertEqual(response.MediaSources.first?.Id, "file")
    }

    func testPendingRequestsAreBounded() async throws {
        let coordinator = PlaybackInfoRequestCoordinator()
        let entered = Gate()
        let release = Gate()
        let active = Task {
            try await coordinator.run(server: "server") {
                await entered.open()
                await release.wait()
                return try Self.response()
            }
        }
        await entered.wait()
        let queued = (0..<16).map { _ in
            Task { try await coordinator.run(server: "server") { try Self.response() } }
        }
        await waitForReaders(17, in: coordinator)
        do {
            _ = try await coordinator.run(server: "server") { try Self.response() }
            XCTFail("Do not grow an unbounded queue.")
        } catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: nil)) }
        queued.forEach { $0.cancel() }
        await release.open()
        _ = try await active.value
        for task in queued {
            do { _ = try await task.value; XCTFail("Queued cancellation must win.") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }
}
