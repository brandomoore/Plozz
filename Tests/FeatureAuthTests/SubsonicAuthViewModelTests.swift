import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import FeatureAuthCore

@MainActor
final class SubsonicAuthViewModelTests: XCTestCase {
    func testPersistsOnlyValidatedSessionAndClearsSecret() async throws {
        var sessions: [UserSession] = []
        let model = makeModel { sessions.append($0) }
        model.signIn()
        try await waitForCompletion(model)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.server.provider, .subsonic)
        XCTAssertTrue(model.password.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testPersistenceFailureIsNotSuccessfulSignIn() async throws {
        let model = makeModel { _ in throw AppError.accessRestricted }
        model.signIn()
        try await waitForCompletion(model)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.password.isEmpty)
    }

    func testCancellationCannotPersistLateResponse() async throws {
        var didPersist = false
        let model = makeModel { _ in didPersist = true }
        model.signIn()
        model.cancel()
        await Task.yield()
        XCTAssertFalse(didPersist)
        XCTAssertFalse(model.isConnecting)
        XCTAssertTrue(model.password.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    private func makeModel(_ persist: @escaping (UserSession) throws -> Void) -> SubsonicAuthViewModel {
        let model = SubsonicAuthViewModel(
            deviceID: "test", address: "https://example.test", username: "listener",
            http: SubsonicSignInHTTP(), onAuthenticated: persist
        )
        model.password = "fixture-password"
        return model
    }

    private func waitForCompletion(_ model: SubsonicAuthViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isConnecting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.isConnecting)
    }
}

private struct SubsonicSignInHTTP: HTTPClient {
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        (Data(#"{"subsonic-response":{"status":"ok"}}"#.utf8),
         HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
