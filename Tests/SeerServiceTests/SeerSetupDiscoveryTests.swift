import CoreModels
import XCTest
@testable import SeerService

@MainActor
final class SeerSetupDiscoveryTests: XCTestCase {
    private let url = URL(string: "https://requests.example.test:8443/seerr")!

    private func methods(_ type: Int) -> SeerLoginMethods {
        .init(initialized: true, mediaServerType: type, mediaServerLogin: true, localLogin: true)
    }

    private func scope(_ id: String = "profile", preferred: URL? = nil) -> SeerSetupDiscovery.Scope {
        .init(profileID: id, sources: [.init(
            scopeID: id, urls: [URL(string: "https://media.example.test")!], mediaServerType: 1
        )], preferredURL: preferred, mediaServerTypes: [1])
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testFastCompatibleResultIsReadyBeforePluginAndSubnetAndReusedOnEntry() async {
        let model = SeerSetupDiscovery()
        var continuation: AsyncStream<DiscoveredSeerServer>.Continuation?
        var plugin: CheckedContinuation<[URL], Error>?
        var calls = 0
        let discover: @MainActor (SeerDiscovery.Request) -> AsyncStream<DiscoveredSeerServer> = { request in
            XCTAssertFalse(request.includesSubnet)
            calls += 1
            return AsyncStream { continuation = $0 }
        }
        model.prepare(scope: scope(), discover: discover,
                      suggested: { try await withCheckedThrowingContinuation { plugin = $0 } },
                      methods: { _ in XCTFail("Stream capabilities must be reused"); throw AppError.invalidResponse },
                      isCurrent: { true })
        await waitUntil { continuation != nil && plugin != nil }
        continuation?.yield(.init(baseURL: url, version: "3", loginMethods: methods(1)))
        await waitUntil { model.selected != nil }
        XCTAssertFalse(model.isSearching, "Readiness must not wait for either suspended operation")
        XCTAssertEqual(model.selected?.baseURL, url)
        model.prepare(scope: scope(), discover: discover, suggested: { XCTFail("Must reuse prefetch"); return [] },
                      methods: { _ in XCTFail("Must reuse capabilities"); throw AppError.invalidResponse }, isCurrent: { true })
        XCTAssertEqual(calls, 1)
        plugin?.resume(returning: [])
        continuation?.finish()
        await waitUntil { !model.isSearching }
        model.cancel()
    }

    func testMismatchedCandidateDoesNotPreventEarlyCompatibleSelection() async {
        let model = SeerSetupDiscovery()
        var continuation: AsyncStream<DiscoveredSeerServer>.Continuation?
        model.prepare(scope: scope(), discover: { _ in AsyncStream { continuation = $0 } },
                      suggested: { [] }, methods: { _ in throw AppError.invalidResponse }, isCurrent: { true })
        await waitUntil { continuation != nil }
        let mismatch = URL(string: "https://jellyfin.example.test")!
        continuation?.yield(.init(baseURL: mismatch, version: "3", loginMethods: methods(2)))
        await waitUntil { model.servers.count == 1 }
        XCTAssertNil(model.selected)
        continuation?.yield(.init(baseURL: url, version: "3", loginMethods: methods(1)))
        await waitUntil { model.selected != nil }
        XCTAssertEqual(model.selected?.baseURL, url)
        continuation?.finish()
        model.cancel()
    }

    func testKnownFailuresFallBackToSubnetAndExposeCapabilities() async {
        let model = SeerSetupDiscovery()
        var phases: [Bool] = []
        model.prepare(scope: scope(), discover: { request in
            phases.append(request.includesSubnet)
            return AsyncStream {
                if request.includesSubnet {
                    $0.yield(.init(baseURL: self.url, version: "3", loginMethods: self.methods(1)))
                }
                $0.finish()
            }
        }, suggested: { throw AppError.serverUnreachable }, methods: { _ in throw AppError.invalidResponse },
                      isCurrent: { true })
        await waitUntil { !model.isSearching }
        XCTAssertEqual(phases, [false, true])
        XCTAssertEqual(model.selected?.baseURL, url)
        XCTAssertNil(model.error)
    }

    func testExplicitDraftDoesNotScanOrReplaceAnUnavailableAddress() async {
        let model = SeerSetupDiscovery()
        var inspected: [URL] = []
        model.prepare(scope: scope(preferred: url),
                      discover: { _ in XCTFail("Do not replace an explicit choice"); return AsyncStream { $0.finish() } },
                      suggested: { XCTFail("Do not replace an explicit choice"); return [] },
                      methods: { inspected.append($0); throw AppError.serverUnreachable }, isCurrent: { true })
        await waitUntil { !model.isSearching }
        XCTAssertEqual(inspected, [url])
        XCTAssertNil(model.selected)
        XCTAssertNotNil(model.error)
    }

    func testScopeChangeRejectsLateNoncooperativeMethodsAndAllowsFreshPreparation() async {
        let model = SeerSetupDiscovery()
        var response: CheckedContinuation<SeerLoginMethods, Error>?
        var current = scope(preferred: url)
        let old = current
        model.prepare(scope: old, discover: { _ in AsyncStream { $0.finish() } }, suggested: { [] },
                      methods: { _ in try await withCheckedThrowingContinuation { response = $0 } },
                      isCurrent: { current == old })
        await waitUntil { response != nil }
        current = scope("other", preferred: url)
        response?.resume(returning: methods(1))
        await waitUntil { !model.isSearching }
        XCTAssertNil(model.selected)
        XCTAssertTrue(model.servers.isEmpty)
        model.prepare(scope: current, discover: { _ in AsyncStream { $0.finish() } }, suggested: { [] },
                      methods: { _ in self.methods(1) }, isCurrent: { true })
        await waitUntil { !model.isSearching }
        XCTAssertEqual(model.selected?.baseURL, url)
    }

    func testCancelledLookupCannotPublishAndRescanStartsNewWork() async {
        let model = SeerSetupDiscovery()
        var response: CheckedContinuation<SeerLoginMethods, Error>?
        model.prepare(scope: scope(preferred: url), discover: { _ in AsyncStream { $0.finish() } }, suggested: { [] },
                      methods: { _ in try await withCheckedThrowingContinuation { response = $0 } }, isCurrent: { true })
        await waitUntil { response != nil }
        model.cancel()
        model.prepare(scope: scope(preferred: url), force: true,
                      discover: { _ in AsyncStream { $0.finish() } }, suggested: { [] },
                      methods: { _ in self.methods(2) }, isCurrent: { true })
        await waitUntil { model.selected != nil }
        response?.resume(returning: methods(1))
        await Task.yield()
        XCTAssertEqual(model.selected?.loginMethods?.mediaServerType, 2)
    }

    func testFailedPrefetchIsRetriedWhenThePageOpens() async {
        let model = SeerSetupDiscovery()
        var attempts = 0
        let lookup: @MainActor (URL) async throws -> SeerLoginMethods = { _ in
            attempts += 1
            if attempts == 1 { throw AppError.serverUnreachable }
            return self.methods(1)
        }
        for _ in 0..<2 {
            model.prepare(scope: scope(preferred: url), discover: { _ in AsyncStream { $0.finish() } },
                          suggested: { [] }, methods: lookup, isCurrent: { true })
            await waitUntil { !model.isSearching }
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(model.selected?.baseURL, url)
        XCTAssertNil(model.error)
    }

    func testReorderedApprovedRoutesDoNotRestartAReadyPrefetch() async {
        let model = SeerSetupDiscovery()
        var attempts = 0
        let routes = [url, URL(string: "http://192.168.1.10:32400")!]
        for urls in [routes, Array(routes.reversed())] {
            let scope = SeerSetupDiscovery.Scope(
                profileID: "profile", sources: [.init(scopeID: "account", urls: urls, mediaServerType: 1)],
                preferredURL: url, mediaServerTypes: [1]
            )
            model.prepare(scope: scope, discover: { _ in XCTFail("Use the preferred URL"); return AsyncStream { $0.finish() } },
                          suggested: { [] }, methods: { _ in attempts += 1; return self.methods(1) }, isCurrent: { true })
            await waitUntil { !model.isSearching }
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(model.selected?.baseURL, url)
    }
}
