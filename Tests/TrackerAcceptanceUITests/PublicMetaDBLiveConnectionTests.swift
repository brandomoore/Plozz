import CoreImage
import Foundation
import XCTest

/// Drives the normally configured production app without fixtures or credential seeding.
/// Explicit lifecycle scenarios relaunch it with no custom arguments or environment.
@MainActor
final class PublicMetaDBLiveConnectionTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz")
    private var entered = false

    private enum Failure: Error {
        case precondition(String)
        case unexpectedRelayResponse
        case cancellationNotConfirmed
    }

    override func tearDown() {
        cancelIfPossible()
        super.tearDown()
    }

    func testLiveBrowserConnection() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let simulator = try XCTUnwrap(environment["PLOZZ_TRACKER_CONNECTION_SIMULATOR"])
        XCTAssertFalse(simulator.isEmpty)
        XCTAssertEqual(simulator, environment["SIMULATOR_UDID"])
        XCTAssertEqual(environment["PLOZZ_TRACKER_CONNECTION_LIVE"], "1")
        XCTAssertEqual(app.state, .runningForeground)
        if keyField.exists && !app.buttons["publicmetadb.browse"].exists {
            entered = true
            try cancelEntry()
        }
        try requireUnconnectedPage()
        let code = try await openEntry()

        let screenshot = app.screenshot()
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let payloads = detector.features(in: CIImage(cgImage: image))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(payloads.count, 1, "The actual production QR must decode unambiguously.")
        let url = try XCTUnwrap(payloads.first)
        let components = try XCTUnwrap(URLComponents(string: url))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "plozz.app")
        XCTAssertEqual(components.path, "/publicmetadb")
        let fragment = try XCTUnwrap(components.fragment)
        let parameters = try XCTUnwrap(URLComponents(string: "https://plozz.app/?" + fragment)?.queryItems)
        XCTAssertEqual(parameters.first(where: { $0.name == "code" })?.value, code)
        XCTAssertNotNil(parameters.first(where: { $0.name == "key" })?.value)
        let handoff = try XCTUnwrap(environment["PLOZZ_TRACKER_CONNECTION_HANDOFF"])
        XCTAssertTrue(handoff.hasPrefix("/") && handoff.hasSuffix("/browser-request.json"))
        let data = try JSONSerialization.data(withJSONObject: ["url": url, "code": code, "decodedProductionQR": true])
        try data.write(to: URL(fileURLWithPath: handoff), options: .withoutOverwriting)
        let qr = XCTAttachment(screenshot: screenshot)
        qr.name = "production-publicmetadb-qr"
        qr.lifetime = .keepAlways
        add(qr)

        XCTAssertTrue(app.buttons["publicmetadb.browse"].waitForExistence(timeout: 120),
                      "The real browser handoff did not establish an authenticated native connection.")
        entered = false
        XCTAssertFalse(keyField.exists)
        XCTAssertEqual(enter.label, "Replace API key")
        XCTAssertTrue(app.staticTexts["Connected"].exists)
        try await verifyRevoked(code)
        try verifyAccountLists()
        let connected = XCTAttachment(screenshot: app.screenshot())
        connected.name = "production-publicmetadb-connected"
        connected.lifetime = .keepAlways
        add(connected)
    }

    func testSavedConnectionAfterRelaunch() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let simulator = try XCTUnwrap(environment["PLOZZ_TRACKER_CONNECTION_SIMULATOR"])
        XCTAssertFalse(simulator.isEmpty)
        XCTAssertEqual(simulator, environment["SIMULATOR_UDID"])
        XCTAssertEqual(environment["PLOZZ_TRACKER_CONNECTION_LIVE"], "1")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons["publicmetadb.browse"].exists)
        XCTAssertTrue(app.launchArguments.isEmpty)
        XCTAssertTrue(app.launchEnvironment.isEmpty)
        app.terminate()
        app.launch()
        try PublicMetaDBLiveNavigation.openSettings(in: app)
        XCTAssertTrue(app.buttons["publicmetadb.browse"].waitForExistence(timeout: 60))
        XCTAssertEqual(enter.label, "Replace API key")
        XCTAssertTrue(app.staticTexts["Connected"].exists)
        try verifyAccountLists()
    }

    #if os(tvOS)
    func testLiveManualConnection() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let simulator = try XCTUnwrap(environment["PLOZZ_TRACKER_CONNECTION_SIMULATOR"])
        XCTAssertFalse(simulator.isEmpty)
        XCTAssertEqual(simulator, environment["SIMULATOR_UDID"])
        XCTAssertEqual(environment["PLOZZ_TRACKER_CONNECTION_LIVE"], "1")
        XCTAssertEqual(app.state, .runningForeground)
        if keyField.exists {
            entered = true
            try cancelEntry()
        }
        try PublicMetaDBLiveNavigation.openSettings(in: app)
        if !app.buttons["publicmetadb.browse"].exists && app.buttons["Retry saved connection"].exists {
            try PublicMetaDBLiveNavigation.focus(back, moving: .up)
            try PublicMetaDBLiveNavigation.select(app.buttons["Retry saved connection"], moving: .down)
        }
        XCTAssertTrue(app.buttons["publicmetadb.browse"].waitForExistence(timeout: 60))
        try PublicMetaDBLiveNavigation.focus(back, moving: .up)
        try PublicMetaDBLiveNavigation.select(enter, moving: .down)
        let replacement = app.sheets.firstMatch
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        try PublicMetaDBLiveNavigation.select(replacement.buttons["Replace API key"].firstMatch, moving: .right)
        entered = true
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        try focused(keyField)
        XCUIRemote.shared.press(.select)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let location = try XCTUnwrap(environment["PLOZZ_TRACKER_MANUAL_INPUT_URL"])
        let url = try XCTUnwrap(URL(string: location))
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "127.0.0.1")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        struct Input: Decodable { let key: String }
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard input.key.range(of: "^pm-[A-Za-z0-9]{60}$", options: .regularExpression) != nil else {
            throw Failure.precondition("The dedicated manual input source returned an invalid key shape.")
        }
        try PublicMetaDBLiveKeyboard.enter(input.key, in: keyboard)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        try focusKeyEntry()
        try move(.down, to: cancel)
        try move(.left, to: app.buttons["publicmetadb.connect"])
        XCUIRemote.shared.press(.select)
        guard app.buttons["publicmetadb.browse"].waitForExistence(timeout: 60), !keyField.exists else {
            throw Failure.precondition("The real manually entered key did not establish a native connection.")
        }
        entered = false
        XCTAssertTrue(app.staticTexts["Connected"].exists)
        try verifyAccountLists()
    }

    func testReplacementCancellationAndDisconnect() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let simulator = try XCTUnwrap(environment["PLOZZ_TRACKER_CONNECTION_SIMULATOR"])
        XCTAssertFalse(simulator.isEmpty)
        XCTAssertEqual(simulator, environment["SIMULATOR_UDID"])
        XCTAssertEqual(environment["PLOZZ_TRACKER_CONNECTION_LIVE"], "1")
        XCTAssertEqual(app.state, .runningForeground)
        try PublicMetaDBLiveNavigation.openSettings(in: app)
        let replacement = app.sheets.firstMatch
        if replacement.exists && replacement.buttons["Replace API key"].exists {
            try PublicMetaDBLiveNavigation.select(replacement.buttons["Cancel"].firstMatch, moving: .left)
            XCTAssertTrue(replacement.waitForNonExistence(timeout: 5))
        }
        if app.switches["publicmetadb.ratings"].exists {
            try PublicMetaDBLiveNavigation.select(app.buttons["Done"], moving: .down)
            XCTAssertTrue(app.buttons["Done"].waitForNonExistence(timeout: 5))
        }
        XCTAssertTrue(app.buttons["publicmetadb.browse"].waitForExistence(timeout: 60))
        try PublicMetaDBLiveNavigation.focus(back, moving: .up)
        try PublicMetaDBLiveNavigation.select(enter, moving: .down)
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        try PublicMetaDBLiveNavigation.select(replacement.buttons["Cancel"].firstMatch, moving: .left)
        XCTAssertTrue(replacement.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["publicmetadb.browse"].exists)
        XCTAssertFalse(keyField.exists)
        try verifyAccountLists()

        try PublicMetaDBLiveNavigation.focus(back, moving: .up)
        try PublicMetaDBLiveNavigation.select(enter, moving: .down)
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        try PublicMetaDBLiveNavigation.select(replacement.buttons["Replace API key"].firstMatch, moving: .right)
        entered = true
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        try focused(keyField)
        let codeLabel = app.staticTexts["publicmetadb.pair.code"]
        guard codeLabel.waitForExistence(timeout: 50) else {
            throw Failure.precondition("The replacement entry did not obtain a live challenge.")
        }
        let code = codeLabel.label.replacingOccurrences(of: " ", with: "")
        try cancelEntry()
        try await verifyRevoked(code)
        guard app.staticTexts["Connected"].waitForExistence(timeout: 45) else {
            throw Failure.precondition("Cancelling replacement did not restore the saved connection.")
        }
        try verifyAccountLists()

        try PublicMetaDBLiveNavigation.focus(back, moving: .up)
        try PublicMetaDBLiveNavigation.select(enter, moving: .down)
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        try PublicMetaDBLiveNavigation.select(replacement.buttons["Replace API key"].firstMatch, moving: .right)
        entered = true
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        try focused(keyField)
        try submitInvalidKey()
        guard app.staticTexts["Your session has expired. Please sign in again."].waitForExistence(timeout: 50) else {
            throw Failure.precondition("The real invalid replacement was not rejected.")
        }
        try cancelEntry()
        guard app.staticTexts["Connected"].waitForExistence(timeout: 45) else {
            throw Failure.precondition("Cancelling a rejected replacement did not restore the saved connection.")
        }
        try verifyAccountLists()

        try PublicMetaDBLiveNavigation.focus(back, moving: .up)
        try PublicMetaDBLiveNavigation.select(app.buttons["Disconnect"], moving: .down)
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        try PublicMetaDBLiveNavigation.select(confirmation.buttons["Cancel"].firstMatch, moving: .left)
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertEqual(enter.label, "Replace API key")
        try PublicMetaDBLiveNavigation.select(app.buttons["Disconnect"], moving: .down)
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        try PublicMetaDBLiveNavigation.select(confirmation.buttons["Disconnect"].firstMatch, moving: .right)
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        try requireUnconnectedPage()
        XCTAssertTrue(app.staticTexts["Not connected"].exists)
        XCTAssertTrue(app.launchArguments.isEmpty)
        XCTAssertTrue(app.launchEnvironment.isEmpty)
        app.terminate()
        app.launch()
        try PublicMetaDBLiveNavigation.openSettings(in: app)
        try requireUnconnectedPage()
    }
    #endif

    private func verifyAccountLists() throws {
        #if os(tvOS)
        try PublicMetaDBLiveNavigation.focus(back, moving: .up)
        try PublicMetaDBLiveNavigation.select(app.buttons["publicmetadb.browse"], moving: .down)
        try PublicMetaDBLiveNavigation.select(app.buttons["Lists"], moving: .down)
        #else
        app.buttons["publicmetadb.browse"].tap()
        app.buttons["Lists"].tap()
        #endif
        XCTAssertTrue(app.staticTexts["No records"].waitForExistence(timeout: 45),
                      "The dedicated account's real empty list response did not appear.")
        XCTAssertTrue(app.staticTexts["Page 1 of 1"].exists)
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["No records"].waitForNonExistence(timeout: 5))
        try PublicMetaDBLiveNavigation.select(app.buttons["Done"], moving: .down)
        XCTAssertTrue(app.buttons["Done"].waitForNonExistence(timeout: 5))
        #else
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()
        #endif
        XCTAssertTrue(app.buttons["publicmetadb.browse"].waitForExistence(timeout: 5))
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
        try PublicMetaDBLiveNavigation.openSettings(in: app)
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
        try submitInvalidKey()

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

    private func submitInvalidKey() throws {
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
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        try focusKeyEntry()
        try move(.down, to: cancel)
        try move(.left, to: app.buttons["publicmetadb.connect"])
        XCUIRemote.shared.press(.select)
        #else
        app.buttons["publicmetadb.connect"].tap()
        #endif

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
        if app.keyboards.firstMatch.exists {
            XCUIRemote.shared.press(.menu)
            guard app.keyboards.firstMatch.waitForNonExistence(timeout: 5) else {
                throw Failure.precondition("API-key keyboard did not close.")
            }
        }
        if !keyField.hasFocus && !app.buttons["publicmetadb.connect"].hasFocus && !cancel.hasFocus {
            try focusKeyEntry()
        }
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
    private func focusKeyEntry() throws {
        if keyField.hasFocus { return }
        try PublicMetaDBLiveNavigation.focus(back, moving: .up)
        XCUIRemote.shared.press(.down)
        let retry = app.buttons["publicmetadb.pair.retry"]
        if retry.exists && retry.hasFocus { XCUIRemote.shared.press(.right) }
        try focused(keyField)
    }

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
