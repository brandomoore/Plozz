import CoreModels
import CoreNetworking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ProviderSilo
import XCTest
@testable import FeatureAuthCore

@MainActor
final class SiloAuthViewModelTests: XCTestCase {
    func testSignInPreservesTheSelectedServerNameInsteadOfSavingItsHost() async throws {
        for (selectedName, expectedName) in [("Silo", "Silo"), ("Living Room Movies", "Living Room Movies"), ("silo.test", "Silo")] {
            let http = SiloOnboardingHTTP()
            let url = URL(string: "https://silo.test")!
            let server = MediaServer(id: url.absoluteString, name: selectedName, baseURL: url, provider: .silo)
            var received: UserSession?
            let model = SiloAuthViewModel(
                server: server, deviceID: "test",
                service: SiloAuthentication(baseURL: url, http: http),
                onAuthenticated: { received = $0 }
            )
            defer { model.cancel() }
            model.start()
            try await wait { if case .profiles = model.phase { return true }; return false }
            guard case let .profiles(profiles) = model.phase,
                  let open = profiles.first(where: { !$0.has_pin }) else { return XCTFail("Missing open profile") }
            model.select(open)
            try await wait { received != nil }
            XCTAssertEqual(received?.server.name, expectedName)
            XCTAssertEqual(received?.server.baseURL, url)
            XCTAssertNotEqual(received?.server.id, url.absoluteString, "The authenticated installation id still owns identity.")
        }
    }

    func testPINBackKeepsApprovalAndAllowsAnotherProfile() async throws {
        let http = SiloOnboardingHTTP()
        var received: [UserSession] = []
        let model = makeModel(http) { received.append($0) }
        defer { model.cancel() }
        model.start()
        try await wait { if case .profiles = model.phase { return true }; return false }
        guard case let .profiles(profiles) = model.phase else { return XCTFail("Missing profiles") }
        model.select(profiles[0])
        model.pin = "wrong"
        model.submitPIN(profiles[0])
        XCTAssertEqual(model.pin, "")
        try await wait { model.pinError != nil }
        XCTAssertEqual(model.phase, .pin(profiles[0]))
        model.chooseAnotherProfile()
        XCTAssertEqual(model.phase, .profiles(profiles))
        XCTAssertNil(model.pinError)
        XCTAssertEqual(model.pin, "")
        model.select(profiles[1])
        try await wait { received.count == 1 }
        XCTAssertEqual(received.first?.userID, "owner:open")
        let starts = await http.count("/api/v2/auth/device/start")
        XCTAssertEqual(starts, 1, "Going back from PIN must not require approving another code")
    }

    func testLockedProfileRequiresProofAndDuplicateSubmissionDoesNotSignInTwice() async throws {
        let http = SiloOnboardingHTTP()
        var received: [UserSession] = []
        let model = makeModel(http) { received.append($0) }
        defer { model.cancel() }
        model.start()
        try await wait { if case .profiles = model.phase { return true }; return false }
        guard case let .profiles(profiles) = model.phase else { return XCTFail("Missing profiles") }
        model.select(profiles[0])
        model.submitPIN(profiles[0])
        XCTAssertEqual(model.phase, .pin(profiles[0]), "Empty input must stay on the PIN field")
        model.pin = "1234"
        model.submitPIN(profiles[0])
        model.submitPIN(profiles[0])
        try await wait { received.count == 1 }
        let credential = try SiloCredential.decode(XCTUnwrap(received.first).accessToken)
        XCTAssertEqual(credential.profileID, "locked")
        XCTAssertEqual(credential.profileToken, "profile-proof")
        XCTAssertEqual(model.pin, "")
        let verificationCount = await http.count("/api/v2/profiles/locked/verify-pin")
        XCTAssertEqual(verificationCount, 1)
        let headers = await http.lastHeaders("/api/v2/playback/capabilities")
        XCTAssertEqual(headers?["X-Profile-Id"], "locked")
        XCTAssertEqual(headers?["X-Profile-Token"], "profile-proof")
    }

    func testProfileRetryReusesApprovalInsteadOfStartingOver() async throws {
        let http = SiloOnboardingHTTP(failFirstProfiles: true)
        let model = makeModel(http)
        defer { model.cancel() }
        model.start()
        try await wait { if case .error = model.phase { return true }; return false }
        model.retry()
        model.retry()
        try await wait { if case .profiles = model.phase { return true }; return false }
        let starts = await http.count("/api/v2/auth/device/start")
        let polls = await http.count("/api/v2/auth/device/poll")
        let profiles = await http.count("/api/v2/profiles")
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(polls, 1)
        XCTAssertEqual(profiles, 2)
    }

    func testCancellationRejectsLateSuccessfulSession() async throws {
        let http = SiloOnboardingHTTP(holdFinish: true)
        var received: [UserSession] = []
        let model = makeModel(http) { received.append($0) }
        model.start()
        try await wait { if case .profiles = model.phase { return true }; return false }
        guard case let .profiles(profiles) = model.phase else { return XCTFail("Missing profiles") }
        model.select(profiles[1])
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await !http.isFinishHeld, ContinuousClock.now < deadline { await Task.yield() }
        let held = await http.isFinishHeld
        XCTAssertTrue(held)
        model.cancel()
        await http.releaseFinish()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.verificationURL)
        XCTAssertTrue(received.isEmpty)
        model.select(profiles[1])
        XCTAssertEqual(model.phase, .idle, "A stale profile button cannot restart a cancelled login")
    }

    func testExpiredCodeStopsAtDeadlineAndCanBeRenewed() async throws {
        let http = SiloOnboardingHTTP(expiresIn: 1, interval: 30)
        let model = makeModel(http)
        defer { model.cancel() }
        model.start()
        try await wait { model.phase == .expired }
        XCTAssertNil(model.verificationURL)
        let polls = await http.count("/api/v2/auth/device/poll")
        XCTAssertEqual(polls, 0, "Do not wait for a long polling interval after code expiration")
        model.retry()
        try await wait { if case .pairing = model.phase { return true }; return false }
        let starts = await http.count("/api/v2/auth/device/start")
        XCTAssertEqual(starts, 2)
    }

    func testDeniedApprovalNeverAdvancesAndRetryRequestsNewCode() async throws {
        let http = SiloOnboardingHTTP(pollStatus: "denied")
        let model = makeModel(http)
        defer { model.cancel() }
        model.start()
        try await wait { if case .error = model.phase { return true }; return false }
        let profiles = await http.count("/api/v2/profiles")
        XCTAssertEqual(profiles, 0)
        model.retry()
        try await wait { if case .pairing = model.phase { return true }; return false }
        let starts = await http.count("/api/v2/auth/device/start")
        XCTAssertEqual(starts, 2)
    }

    func testBothApprovalLinksMustBelongToSelectedServer() async throws {
        for foreignManual in [true, false] {
            let http = SiloOnboardingHTTP(foreignManual: foreignManual, foreignApproval: !foreignManual)
            let model = makeModel(http)
            model.start()
            try await wait { if case .error = model.phase { return true }; return false }
            XCTAssertNil(model.verificationURL)
            let polls = await http.count("/api/v2/auth/device/poll")
            XCTAssertEqual(polls, 0)
            model.cancel()
        }
    }

    func testManualLinkIsSeparateFromPrefilledApprovalLink() async throws {
        let http = SiloOnboardingHTTP()
        let model = makeModel(http)
        defer { model.cancel() }
        model.start()
        try await wait { if case .pairing = model.phase { return true }; return false }
        guard case let .pairing(code, match, url, _) = model.phase else { return XCTFail("Missing pairing") }
        XCTAssertEqual(code, "ABCD12")
        XCTAssertEqual(match, "57")
        XCTAssertEqual(model.verificationURL?.absoluteString, "https://silo.test/pair")
        XCTAssertEqual(url.absoluteString, "https://silo.test/pair?code=ABCD12")
    }

    private func makeModel(_ http: SiloOnboardingHTTP,
                           completed: @escaping (UserSession) -> Void = { _ in XCTFail("Unexpected sign-in") }) -> SiloAuthViewModel {
        let url = URL(string: "https://silo.test")!
        return SiloAuthViewModel(
            server: MediaServer(id: "silo", name: "Silo", baseURL: url, provider: .silo),
            deviceID: "fixture", service: SiloAuthentication(baseURL: url, http: http),
            onAuthenticated: completed
        )
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Onboarding did not reach the expected phase")
    }
}

private actor SiloOnboardingHTTP: HTTPClient {
    let failFirstProfiles: Bool
    let holdFinish: Bool
    let expiresIn: Int
    let interval: Int
    let pollStatus: String
    let foreignManual: Bool
    let foreignApproval: Bool
    private var requests: [Endpoint] = []
    private var finish: CheckedContinuation<Void, Never>?
    var isFinishHeld: Bool { finish != nil }

    init(failFirstProfiles: Bool = false, holdFinish: Bool = false, expiresIn: Int = 600,
         interval: Int = 1, pollStatus: String = "approved",
         foreignManual: Bool = false, foreignApproval: Bool = false) {
        self.failFirstProfiles = failFirstProfiles
        self.holdFinish = holdFinish
        self.expiresIn = expiresIn
        self.interval = interval
        self.pollStatus = pollStatus
        self.foreignManual = foreignManual
        self.foreignApproval = foreignApproval
    }

    func count(_ path: String) -> Int { requests.filter { $0.path == path }.count }
    func lastHeaders(_ path: String) -> [String: String]? { requests.last { $0.path == path }?.headers }
    func releaseFinish() { finish?.resume(); finish = nil }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        let body: String
        switch endpoint.path {
        case "/api/v2/system/info": body = #"{"api_major":2}"#
        case "/api/v2/auth/device/capability":
            body = #"{"state":"available","protocol_versions":[2],"allowed":true}"#
        case "/api/v2/auth/device/start":
            body = """
            {"device_code":"device-secret","user_code":"ABCD12","match_code":"57",
             "verification_uri":"https://\(foreignManual ? "other" : "silo").test/pair",
             "verification_uri_complete":"https://\(foreignApproval ? "other" : "silo").test/pair?code=ABCD12",
             "expires_in":\(expiresIn),"interval":\(interval)}
            """
        case "/api/v2/auth/device/poll":
            body = """
            {"status":"\(pollStatus)","poll_after":1,"temporary":false,
             "tokens":{"access_token":"test-access","refresh_token":"test-refresh",
             "expires_in":3600,"user":{"id":"owner","username":"Owner"}}}
            """
        case "/api/v2/profiles":
            if failFirstProfiles, count(endpoint.path) == 1 { throw AppError.serverUnreachable }
            body = """
            {"items":[{"id":"locked","name":"Protected","has_pin":true,"is_child":false},
                      {"id":"open","name":"Guest","has_pin":false,"is_child":false}]}
            """
        case "/api/v2/profiles/locked/verify-pin":
            let object = try JSONSerialization.jsonObject(with: XCTUnwrap(endpoint.body)) as? [String: String]
            body = object?["pin"] == "1234"
                ? #"{"valid":true,"profile_token":"profile-proof"}"# : #"{"valid":false}"#
        case "/api/v2/playback/capabilities":
            if holdFinish { await withCheckedContinuation { finish = $0 } }
            body = """
            {"installation_id":"server","protocol_versions":[3],"features":[],"deliveries":[],
             "state":"available","allowed":true}
            """
        default: throw AppError.notFound
        }
        return (Data(body.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
