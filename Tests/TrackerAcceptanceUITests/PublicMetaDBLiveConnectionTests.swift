import Foundation
import XCTest

/// Attaches to the already-running production app. No fixture, credential seeding,
/// application install, launch, termination, or profile selection is performed here.
@MainActor
final class PublicMetaDBLiveConnectionTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz")
    private var entered = false

    private enum Failure: Error {
        case precondition(String)
        case unexpectedRelayResponse
        case cancellationNotConfirmed
    }

    func testLivePairingCancellationAndInvalidKey() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let simulator = environment["PLOZZ_TRACKER_CONNECTION_SIMULATOR"],
              !simulator.isEmpty,
              simulator == environment["SIMULATOR_UDID"],
              environment["PLOZZ_TRACKER_CONNECTION_LIVE"] == "1" else {
            throw Failure.precondition("Requires the explicit simulator-only live runner.")
        }
        guard app.state == .runningForeground else {
            throw Failure.precondition("Production Plozz must already be running in the foreground.")
        }
        try requireUnconnectedPage()
        defer { cancelIfPossible() }

        let firstCode = try await openEntry()
        #if os(tvOS)
        for _ in 0..<3 {
            try move(.up, to: back)
            try move(.down, to: keyField)
        }
        #endif
        try cancelEntry()
        try await verifyRevoked(firstCode)
        try requireUnconnectedPage()

        let secondCode = try await openEntry()
        guard secondCode != firstCode else { throw Failure.unexpectedRelayResponse }
        #if os(tvOS)
        XCUIRemote.shared.press(.select)
        guard app.keyboards.firstMatch.waitForExistence(timeout: 5) else {
            throw Failure.precondition("API-key keyboard did not open.")
        }
        #else
        keyField.tap()
        #endif
        keyField.typeText("pm-" + String(repeating: "a", count: 60))
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        try focused(keyField)
        try move(.down, to: cancel)
        try move(.left, to: app.buttons["publicmetadb.connect"])
        XCUIRemote.shared.press(.select)
        #else
        app.buttons["publicmetadb.connect"].tap()
        #endif

        let rejected = app.staticTexts["Your session has expired. Please sign in again."]
        guard rejected.waitForExistence(timeout: 50),
              !app.buttons["publicmetadb.browse"].exists,
              keyField.exists else {
            throw Failure.precondition("The real app did not show the expected live invalid-key rejection.")
        }
        try await verifyRevoked(secondCode)
        try cancelEntry()
        try requireUnconnectedPage()

        let evidence = XCTAttachment(string: """
        {"schemaVersion":1,"kind":"production-app-live-connection-negative-check",
         "fixtureUsed":false,"authenticatedAccountAcceptance":false,
         "relayChallengeObserved":true,"cancelRevocationObserved":true,
         "freshReentryCodeObserved":true,"invalidKeyRejected":true,
         "noSavedKeyAfterwardObserved":true}
        """)
        evidence.name = "publicmetadb-live-negative-result.json"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private var keyField: XCUIElement { app.secureTextFields["publicmetadb.key"] }
    private var back: XCUIElement { app.buttons["settings-workspace-back"] }
    private var cancel: XCUIElement { app.buttons["publicmetadb.pair.cancel"] }
    private var enter: XCUIElement { app.buttons["publicmetadb.pair"] }

    private func requireUnconnectedPage() throws {
        guard app.state == .runningForeground, enter.waitForExistence(timeout: 5),
              enter.label == "Enter API key", enter.isEnabled,
              !app.buttons["publicmetadb.browse"].exists, !keyField.exists else {
            throw Failure.precondition("Open English PublicMetaDB settings with no saved key; existing connections are never replaced.")
        }
    }

    private func openEntry() async throws -> String {
        try requireUnconnectedPage()
        #if os(tvOS)
        if !enter.hasFocus {
            guard back.hasFocus else {
                throw Failure.precondition("Focus must be on Back or Enter API key.")
            }
            try move(.down, to: enter)
        }
        XCUIRemote.shared.press(.select)
        #else
        enter.tap()
        #endif
        entered = true
        guard keyField.waitForExistence(timeout: 5) else {
            throw Failure.precondition("The native API-key field did not appear.")
        }
        #if os(tvOS)
        try focused(keyField)
        #endif
        let codeLabel = app.staticTexts["publicmetadb.pair.code"]
        guard codeLabel.waitForExistence(timeout: 50) else {
            throw Failure.precondition("The actual app did not obtain a live pairing challenge.")
        }
        let code = codeLabel.label.replacingOccurrences(of: " ", with: "")
        guard code.range(of: "^[A-HJ-NP-Z2-9]{8}$", options: .regularExpression) != nil else {
            throw Failure.unexpectedRelayResponse
        }
        let (data, status) = try await relay(code)
        struct Challenge: Decodable {
            let publicKey: String
            let expiresAt: Double
        }
        guard status == 200 else { throw Failure.unexpectedRelayResponse }
        let challenge = try JSONDecoder().decode(Challenge.self, from: data)
        guard challenge.expiresAt.isFinite,
              challenge.expiresAt > Date().timeIntervalSince1970 * 1000,
              challenge.expiresAt <= (Date().timeIntervalSince1970 + 610) * 1000,
              challenge.publicKey.range(of: "^[A-Za-z0-9_-]{87}$", options: .regularExpression) != nil else {
            throw Failure.unexpectedRelayResponse
        }
        #if os(tvOS)
        try focused(keyField)
        #endif
        return code
    }

    private func cancelEntry() throws {
        guard entered, app.state == .runningForeground, cancel.exists else {
            throw Failure.precondition("Cannot safely dismiss the expected pairing entry.")
        }
        #if os(tvOS)
        if app.keyboards.firstMatch.exists { XCUIRemote.shared.press(.menu) }
        if keyField.hasFocus { try move(.down, to: cancel) }
        else if app.buttons["publicmetadb.connect"].hasFocus { try move(.right, to: cancel) }
        try focused(cancel)
        XCUIRemote.shared.press(.select)
        #else
        cancel.tap()
        #endif
        guard enter.waitForExistence(timeout: 5), !keyField.exists else {
            throw Failure.precondition("Pairing entry did not close.")
        }
        entered = false
    }

    private func cancelIfPossible() {
        guard entered else { return }
        do { try cancelEntry() }
        catch { XCTFail("Live pairing UI cleanup was not confirmed; its relay expiry remains the fallback.") }
    }

    private func verifyRevoked(_ code: String) async throws {
        for attempt in 0..<5 {
            let (_, status) = try await relay(code)
            if status == 410 { return }
            guard status == 200 else { throw Failure.unexpectedRelayResponse }
            if attempt < 4 { try await Task.sleep(for: .seconds(1)) }
        }
        throw Failure.cancellationNotConfirmed
    }

    private func relay(_ code: String) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://plozz.app/api/publicmetadb/pairing/\(code)")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 4096 else {
            throw Failure.unexpectedRelayResponse
        }
        return (data, response.statusCode)
    }

    #if os(tvOS)
    private func focused(_ target: XCUIElement) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in target.exists && target.hasFocus }, object: nil
        )
        guard XCTWaiter.wait(for: [expectation], timeout: 5) == .completed else {
            throw Failure.precondition("The expected native focus handoff failed.")
        }
    }

    private func move(_ direction: XCUIRemote.Button, to target: XCUIElement) throws {
        XCUIRemote.shared.press(direction)
        try focused(target)
    }
    #endif
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
