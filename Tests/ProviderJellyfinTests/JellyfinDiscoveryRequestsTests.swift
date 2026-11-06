import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderJellyfin

final class JellyfinDiscoveryRequestsTests: XCTestCase {
    func testOverlappingReadsShareWorkButLaterReadsAreFresh() async throws {
        let requests = JellyfinDiscoveryRequests<Int>()
        let gate = DiscoveryGate()
        let first = Task { try await requests.run(key: "viewer") { try await gate.wait() } }
        try await waitUntil { await gate.started == 1 }
        let second = Task { try await requests.run(key: "viewer") { try await gate.wait() } }
        try await waitUntil { await requests.waitingReaderCount == 2 }
        await gate.release(1, result: .success(7))
        let values = try await [first.value, second.value]
        XCTAssertEqual(values, [7, 7])
        let started = await gate.started
        XCTAssertEqual(started, 1)
        let fresh = try await requests.run(key: "viewer") { 9 }
        XCTAssertEqual(fresh, 9)
    }

    func testFailureIsSharedButNotCached() async throws {
        let requests = JellyfinDiscoveryRequests<Int>()
        let gate = DiscoveryGate()
        let first = Task { try await requests.run(key: "viewer") { try await gate.wait() } }
        try await waitUntil { await gate.started == 1 }
        let second = Task { try await requests.run(key: "viewer") { try await gate.wait() } }
        try await waitUntil { await requests.waitingReaderCount == 2 }
        await gate.release(1, result: .failure(AppError.serverUnreachable))
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("Discovery failure must reach every reader.") }
            catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        }
        let recovered = try await requests.run(key: "viewer") { 11 }
        XCTAssertEqual(recovered, 11)
    }

    func testCancellingOneReaderDoesNotCancelAnother() async throws {
        let requests = JellyfinDiscoveryRequests<Int>()
        let gate = DiscoveryGate()
        let first = Task { try await requests.run(key: "viewer") { try await gate.wait() } }
        try await waitUntil { await gate.started == 1 }
        let second = Task { try await requests.run(key: "viewer") { try await gate.wait() } }
        try await waitUntil { await requests.waitingReaderCount == 2 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled readers must finish before the shared request.") }
        catch { XCTAssertTrue(error is CancellationError) }
        await gate.release(1, result: .success(12))
        let kept = try await second.value
        XCTAssertEqual(kept, 12)
        let cancellations = await gate.completedCancellation
        XCTAssertEqual(cancellations, [false])
    }

    func testLastCancellationCancelsWorkAndLateCompletionCannotReplaceNewFlight() async throws {
        let requests = JellyfinDiscoveryRequests<Int>()
        let gate = DiscoveryGate()
        let first = Task { try await requests.run(key: "viewer") { try await gate.wait() } }
        try await waitUntil { await gate.started == 1 }
        first.cancel()
        do { _ = try await first.value; XCTFail("The last cancelled reader must finish promptly.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let second = Task { try await requests.run(key: "viewer") { try await gate.wait() } }
        try await waitUntil { await gate.started == 2 }
        await gate.release(1, result: .success(99))
        await gate.release(2, result: .success(13))
        let fresh = try await second.value
        XCTAssertEqual(fresh, 13)
        try await waitUntil { await gate.completedCancellation.count == 2 }
        let cancellations = await gate.completedCancellation
        XCTAssertEqual(cancellations.filter { $0 }.count, 1)
    }

    func testDifferentUsersAndDifferentInstancesNeverShare() async throws {
        let requests = JellyfinDiscoveryRequests<Int>()
        let otherCredentials = JellyfinDiscoveryRequests<Int>()
        let gate = DiscoveryGate()
        let tasks = [
            Task { try await requests.run(key: "one") { try await gate.wait() } },
            Task { try await requests.run(key: "two") { try await gate.wait() } },
            Task { try await otherCredentials.run(key: "one") { try await gate.wait() } }
        ]
        try await waitUntil { await gate.started == 3 }
        for index in 1...3 { await gate.release(index, result: .success(index)) }
        var values: Set<Int> = []
        for task in tasks { values.insert(try await task.value) }
        XCTAssertEqual(values, [1, 2, 3])
    }

    func testHomeLayoutAndNavigationShareViewsAndCollectionAvailabilityForBothBackends() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let http = DiscoveryHTTP()
            let provider = JellyfinProvider(session: session(kind), http: http)
            let navigation = Task { try await provider.libraries() }
            try await waitUntil { await http.views == 1 }
            let home = Task { try await provider.libraries() }
            let layout = Task { try await provider.serverHomeLayout() }
            try await waitUntil { await provider.libraryRequests.waitingReaderCount == 2 }
            try await waitUntil { await provider.client.userViewRequests.waitingReaderCount == 2 }
            await http.gate.release(1, result: .success(1))
            let libraries = try await navigation.value
            let homeLibraries = try await home.value
            let serverLayout = try await layout.value
            XCTAssertEqual(libraries, homeLibraries)
            XCTAssertTrue(serverLayout?.sections.contains { $0.libraryID == "movies" } == true)
            let counts = await (http.views, http.collections)
            XCTAssertEqual(counts.0, 1)
            XCTAssertEqual(counts.1, 1)
            await http.changeLibrary()
            let refreshed = try await provider.libraries()
            XCTAssertEqual(refreshed.first?.id, "changed")
            let freshCounts = await (http.views, http.collections)
            XCTAssertEqual(freshCounts.0, 2)
            XCTAssertEqual(freshCounts.1, 2)
        }
    }

    func testAuthenticatedClientCopiesDoNotSharePriorCredentialWork() async throws {
        let http = DiscoveryHTTP()
        let client = JellyfinClient(
            baseURL: session(.jellyfin).server.baseURL, deviceProfile: .init(deviceID: "device"),
            token: "old-fixture", http: http
        )
        let old = Task { try await client.userViews(userID: "viewer") }
        try await waitUntil { await http.views == 1 }
        let replacement = client.authenticated(token: "new-fixture")
        let current = try await replacement.userViews(userID: "viewer")
        XCTAssertFalse(current.isEmpty)
        let views = await http.views
        XCTAssertEqual(views, 2)
        await http.gate.release(1, result: .success(1))
        _ = try await old.value
    }

    private func session(_ kind: ProviderKind) -> UserSession {
        .init(server: .init(id: "server", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                            provider: kind),
              userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: "fixture")
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard await condition() else { throw AppError.invalidResponse }
    }
}

private actor DiscoveryGate {
    private(set) var started = 0
    private(set) var completedCancellation: [Bool] = []
    private var readers: [Int: CheckedContinuation<Int, Error>] = [:]

    func wait() async throws -> Int {
        started += 1
        let index = started
        let value: Int = try await withCheckedThrowingContinuation { readers[index] = $0 }
        completedCancellation.append(Task.isCancelled)
        return value
    }

    func release(_ index: Int, result: Result<Int, Error>) {
        readers.removeValue(forKey: index)?.resume(with: result)
    }
}

private actor DiscoveryHTTP: HTTPClient {
    let gate = DiscoveryGate()
    private(set) var views = 0
    private(set) var collections = 0
    private var library = "movies"

    func changeLibrary() { library = "changed" }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let body: String
        if endpoint.path.hasSuffix("/Views") {
            views += 1
            if views == 1 { _ = try await gate.wait() }
            body = #"{"Items":[{"Id":"\#(library)","Name":"Movies","CollectionType":"movies"}]}"#
        } else if endpoint.path.hasSuffix("/Items") {
            collections += 1
            body = #"{"Items":[],"TotalRecordCount":0}"#
        } else if endpoint.path.hasSuffix("/DisplayPreferences/usersettings") {
            body = "{}"
        } else { throw AppError.notFound }
        return (Data(body.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
