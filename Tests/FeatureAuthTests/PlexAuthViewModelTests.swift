import XCTest
import CoreModels
@testable import FeatureAuthCore

final class PlexAuthViewModelTests: XCTestCase {
    @MainActor
    func testFreshLinkRequiresExplicitSelectionEvenForOneOwnedServer() async throws {
        let stub = recoveryStub(userID: "owner")
        stub.stubSequence(pathSuffix: "/api/v2/resources", jsons: ["""
        [{"clientIdentifier":"saved","name":"Saved","provides":"server","owned":true,"accessToken":"SERVER-TOKEN",
          "connections":[{"uri":"https://saved.example","local":true}]}]
        """])
        var received: UserSession?
        let model = PlexAuthViewModel(
            service: PlexAuthService(deviceID: "device", http: stub, probeHTTP: stub),
            onAuthenticated: { received = $0 }
        )
        defer { model.cancel() }
        model.start()
        try await waitForResult(model) { if case .selectingServer = model.phase { return true }; return false }
        guard case let .selectingServer(candidates) = model.phase else { return XCTFail("Missing server selection") }
        XCTAssertEqual(candidates.count, 1)
        XCTAssertNil(received)
        model.selectServer(try XCTUnwrap(candidates.first))
        try await waitForResult(model) { received != nil }
        XCTAssertEqual(received?.server.id, "saved")
    }
    @MainActor
    func testRecoveryAutomaticallySelectsOriginalServerAndRejectsWrongLogin() async throws {
        for userID in ["owner", "different-owner"] {
            let stub = recoveryStub(userID: userID)
            let account = recoveryAccount()
            var received: UserSession?
            let model = PlexAuthViewModel(
                service: PlexAuthService(deviceID: "device", http: stub, probeHTTP: stub),
                reconnectingAccount: account,
                onAuthenticated: { received = $0 }
            )
            defer { model.cancel() }
            model.start()
            try await waitForResult(model) { received != nil }
            if userID == "owner" {
                XCTAssertEqual(received?.server.id, account.server.id)
                XCTAssertEqual(received?.userID, account.userID)
                XCTAssertEqual(received?.accessToken, "SERVER-TOKEN")
            } else {
                XCTAssertNil(received)
                XCTAssertEqual(model.phase, .error("Sign in with the original Plex account to reconnect this server."))
            }
        }
    }

    @MainActor
    func testRecoveryMissingServerAndPersistenceFailureRemainRecoverableErrors() async throws {
        for missingServer in [true, false] {
            let stub = recoveryStub(userID: "owner", includesSavedServer: !missingServer)
            var attemptedSave = false
            let model = PlexAuthViewModel(
                service: PlexAuthService(deviceID: "device", http: stub, probeHTTP: stub),
                reconnectingAccount: recoveryAccount(),
                onAuthenticated: { _ in
                    attemptedSave = true
                    throw AppError.conflict
                }
            )
            defer { model.cancel() }
            model.start()
            try await waitForResult(model) { false }
            XCTAssertEqual(attemptedSave, !missingServer)
            if !missingServer { XCTAssertEqual(model.phase, .error(AppError.conflict.userMessage)) }
        }
    }

    private func recoveryAccount() -> Account {
        Account(
            id: "legacy", server: MediaServer(
                id: "saved", name: "Saved", baseURL: URL(string: "https://saved.example")!, provider: .plex
            ), userID: "owner", userName: "Owner", deviceID: "device"
        )
    }

    private func recoveryStub(userID: String, includesSavedServer: Bool = true) -> StubHTTPClient {
        let stub = StubHTTPClient()
        stub.stubFixed(pathSuffix: "/api/v2/pins", json: #"{"id":1,"code":"CODE"}"#)
        stub.stubFixed(pathSuffix: "/api/v2/pins/1", json: #"{"id":1,"code":"CODE","authToken":"ACCOUNT-TOKEN"}"#)
        stub.stubFixed(pathSuffix: "/api/v2/user", json: #"{"uuid":"\#(userID)","username":"Owner"}"#)
        stub.stubFixed(pathSuffix: "/identity", json: "{}")
        let id = includesSavedServer ? "saved" : "missing"
        stub.stubFixed(pathSuffix: "/api/v2/resources", json: """
        [
          {"clientIdentifier":"other","name":"Other","provides":"server","accessToken":"OTHER",
           "connections":[{"uri":"https://other.example","local":true}]},
          {"clientIdentifier":"\(id)","name":"Saved","provides":"server","accessToken":"SERVER-TOKEN",
           "connections":[{"uri":"https://saved.example","local":true}]}
        ]
        """)
        return stub
    }

    @MainActor
    private func waitForResult(_ model: PlexAuthViewModel, success: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if success() { return }
            if case .error = model.phase { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Plex linking did not finish within its test deadline.")
    }

    func testDualPinRaceReturnsFirstLinkedChallenge() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/api/v2/pins", jsons: [
            #"{"id":1,"code":"MANU","authToken":null}"#,
            #"{"id":2,"code":"HOST","authToken":null}"#
        ])
        stub.stubFixed(
            pathSuffix: "/api/v2/pins/1",
            json: #"{"id":1,"code":"MANU","authToken":null}"#
        )
        stub.stubFixed(
            pathSuffix: "/api/v2/pins/2",
            json: #"{"id":2,"code":"HOST","authToken":"HOST_TOKEN"}"#
        )
        let service = makeService(stub: stub, pollInterval: 0.02)
        let manualPin = try await service.begin()
        let hostedPin = try await service.begin(strong: true)

        let outcome = try await PlexAuthViewModel.awaitLinkOrExpiry(
            service: service,
            pins: [manualPin, hostedPin],
            expiresAt: Date().addingTimeInterval(1)
        )

        XCTAssertEqual(outcome, .linked("HOST_TOKEN"))
    }

    func testDualPinRaceExpiresAndCancelsPolls() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/api/v2/pins", jsons: [
            #"{"id":1,"code":"MANU","authToken":null}"#,
            #"{"id":2,"code":"HOST","authToken":null}"#
        ])
        stub.stubFixed(
            pathSuffix: "/api/v2/pins/1",
            json: #"{"id":1,"code":"MANU","authToken":null}"#
        )
        stub.stubFixed(
            pathSuffix: "/api/v2/pins/2",
            json: #"{"id":2,"code":"HOST","authToken":null}"#
        )
        let service = makeService(stub: stub, pollInterval: 1)
        let manualPin = try await service.begin()
        let hostedPin = try await service.begin(strong: true)

        let outcome = try await PlexAuthViewModel.awaitLinkOrExpiry(
            service: service,
            pins: [manualPin, hostedPin],
            expiresAt: Date().addingTimeInterval(0.02)
        )

        XCTAssertEqual(outcome, .expired)
    }

    func testCancellingDualPinRaceCancelsAllWork() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/api/v2/pins", jsons: [
            #"{"id":1,"code":"MANU","authToken":null}"#,
            #"{"id":2,"code":"HOST","authToken":null}"#
        ])
        stub.stubFixed(
            pathSuffix: "/api/v2/pins/1",
            json: #"{"id":1,"code":"MANU","authToken":null}"#
        )
        stub.stubFixed(
            pathSuffix: "/api/v2/pins/2",
            json: #"{"id":2,"code":"HOST","authToken":null}"#
        )
        let service = makeService(stub: stub, pollInterval: 1)
        let manualPin = try await service.begin()
        let hostedPin = try await service.begin(strong: true)
        let race = Task {
            try await PlexAuthViewModel.awaitLinkOrExpiry(
                service: service,
                pins: [manualPin, hostedPin],
                expiresAt: Date().addingTimeInterval(5)
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        race.cancel()

        do {
            _ = try await race.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeService(
        stub: StubHTTPClient,
        pollInterval: TimeInterval
    ) -> PlexAuthService {
        PlexAuthService(
            deviceID: "dev1",
            http: stub,
            config: .init(pollInterval: pollInterval, timeout: 5)
        )
    }
}
