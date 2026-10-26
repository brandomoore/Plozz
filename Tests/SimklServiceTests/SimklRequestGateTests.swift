import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import SimklService
@testable import TestSupportNetworking

final class SimklRequestGateTests: XCTestCase {
    private func response(status: Int = 200, headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.test")!, statusCode: status, httpVersion: nil, headerFields: headers
        ))
    }

    func testReadsAndWritesArePacedAtActualDispatchAfterScopeValidation() async throws {
        for (method, minimum) in [(HTTPMethod.get, 0.1), (.post, 1.0)] {
            let clock = SimklExportClock()
            let gate = SimklRequestGate(now: { clock.now() }, sleep: { clock.advance($0) })
            let response = try response()
            let baseline = clock.now()
            _ = try await gate.run(clientID: "fixture", method: method, validate: { clock.advance(2) }) {
                (Data(), response)
            }
            let first = clock.now()
            _ = try await gate.run(clientID: "fixture", method: method, validate: {}) { (Data(), response) }
            XCTAssertEqual(first.timeIntervalSince(baseline), 2, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(clock.now().timeIntervalSince(first), minimum)
        }
    }

    func testIndependentClientsShareTheProductionGate() {
        let first = SimklClient(config: .init(clientID: "first"), http: URLSessionHTTPClient())
        let second = SimklClient(config: .init(clientID: "second"), http: URLSessionHTTPClient())
        XCTAssertTrue(first.gate === second.gate)
    }

    func testWatchlistMutationsRejectCredentialReplacementDuringPacing() async throws {
        for (desiredState, change) in [WatchlistDesiredState.present, .absent].flatMap({
            state in ["replacement", "profile", "return", "reconnect"].map { (state, $0) }
        }) {
            let tokens = InMemorySimklTokenStore(tokens: .init(accessToken: "fixture"))
            tokens.setNamespace("other")
            try tokens.save(.init(accessToken: "fixture"))
            tokens.setNamespace(nil)
            let clock = SimklExportClock()
            let gate = SimklRequestGate(now: { clock.now() }, sleep: {
                clock.advance($0)
                switch change {
                case "profile": tokens.setNamespace("other")
                case "return":
                    tokens.setNamespace("other")
                    tokens.setNamespace(nil)
                case "reconnect":
                    try tokens.clear()
                    try tokens.save(.init(accessToken: "fixture"))
                default: try tokens.save(.init(accessToken: "replacement"))
                }
            })
            let http = RecordingHTTPClient()
            http.stubEmpty(pathSuffix: "/sync/add-to-list")
            http.stubEmpty(pathSuffix: "/sync/remove-from-list")
            let destination = SimklWatchlistDestination(
                client: .init(config: .init(clientID: "fixture"), http: http, gate: gate), tokenStore: tokens
            )
            let binding = try XCTUnwrap(WatchlistDestinationBinding(
                destinationID: destination.id, opaqueValue: "movie|tmdb|550"
            ))
            let scope = destination.reconciliationScope
            try await destination.apply(.present, to: binding, expectedReconciliationScope: scope)
            do {
                try await destination.apply(desiredState, to: binding, expectedReconciliationScope: scope)
                XCTFail("Queued mutation must be rejected")
            } catch {
                XCTAssertEqual(error as? WatchlistDestinationError, .authenticationRequired)
            }
            XCTAssertEqual(http.sent.count, 1, "Only the first, authorized write may reach HTTP")
        }
    }

    func testAppQuotaCooldownPersistsAcrossNewGateInstances() async throws {
        let suite = "SimklGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = SimklExportClock()
        let gate = SimklRequestGate(defaults: defaults, now: { clock.now() }, sleep: { clock.advance($0) })
        let response = try response(status: 429, headers: ["Retry-After": "120"])
        _ = try await gate.run(clientID: "fixture", method: .post, validate: {}) { (Data(), response) }
        let recreated = SimklRequestGate(defaults: defaults, now: { clock.now() }, sleep: { clock.advance($0) })
        do {
            _ = try await recreated.run(clientID: "fixture", method: .get, validate: {}) {
                XCTFail("No request during quota cooldown")
                return (Data(), response)
            }
            XCTFail("Expected cooldown")
        } catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 120)) }
        clock.advance(121)
        let success = try self.response()
        _ = try await recreated.run(clientID: "fixture", method: .get, validate: {}) { (Data(), success) }
    }

    func testLastAllowedResponseBlocksFurtherRequestsUntilEasternMidnight() async throws {
        let clock = SimklExportClock()
        let gate = SimklRequestGate(now: { clock.now() }, sleep: { clock.advance($0) })
        let response = try response(headers: ["X-RateLimit-Remaining": "0"])
        _ = try await gate.run(clientID: "fixture", method: .get, validate: {}) { (Data(), response) }
        do {
            _ = try await gate.run(clientID: "fixture", method: .get, validate: {}) {
                XCTFail("Exhausted quota")
                return (Data(), response)
            }
            XCTFail("Expected cooldown")
        } catch {
            guard case .rateLimited(let delay) = error as? AppError else { return XCTFail("Wrong quota failure") }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
            let midnight = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: clock.now())))
            XCTAssertEqual(try XCTUnwrap(delay), midnight.timeIntervalSince(clock.now()), accuracy: 0.001)
        }
    }

    func testQueuedScopeValidationOccursAfterPacingAndCanCancelWithoutDispatch() async throws {
        let clock = SimklExportClock()
        let baseline = clock.now()
        let gate = SimklRequestGate(now: { clock.now() }, sleep: { clock.advance($0) })
        let response = try response()
        _ = try await gate.run(clientID: "fixture", method: .post, validate: {}) { (Data(), response) }
        do {
            _ = try await gate.run(clientID: "fixture", method: .post, validate: {
                XCTAssertGreaterThan(clock.now().timeIntervalSince(baseline), 1)
                throw CancellationError()
            }) {
                XCTFail("Canceled request must never dispatch")
                return (Data(), response)
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
