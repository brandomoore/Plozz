import CoreImage
import Foundation
import XCTest

#if os(tvOS)
/// Drives the normally configured TV app without fixtures or credential seeding.
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
        if cancel.exists && !activation.exists {
            entered = true
            try cancelEntry()
        }
        try requireUnconnectedPage()
        let code = try await openWebsiteEntry()

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
        XCTAssertEqual(components.path, "/pmdb")
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

        XCTAssertTrue(activation.waitForExistence(timeout: 120),
                      "The real browser handoff did not establish an authenticated native connection.")
        entered = false
        XCTAssertFalse(keyField.exists)
        XCTAssertEqual(enter.label, "Replace API key")
        XCTAssertTrue(app.staticTexts["Connected"].exists)
        try await verifyRevoked(code)
        try PublicMetaDBLiveNavigation.changeActivation(in: app, from: true)
        assertInactiveAccount()
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
        assertInactiveAccount()
        XCTAssertTrue(app.launchArguments.isEmpty)
        XCTAssertTrue(app.launchEnvironment.isEmpty)
        app.terminate()
        app.launch()
        try PublicMetaDBLiveNavigation.openSettings(in: app)
        XCTAssertTrue(activation.waitForExistence(timeout: 60))
        XCTAssertEqual(enter.label, "Replace API key")
        XCTAssertTrue(app.staticTexts["Connected"].exists)
        assertInactiveAccount()
    }

    func testLiveManualConnection() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let simulator = try XCTUnwrap(environment["PLOZZ_TRACKER_CONNECTION_SIMULATOR"])
        XCTAssertFalse(simulator.isEmpty)
        XCTAssertEqual(simulator, environment["SIMULATOR_UDID"])
        XCTAssertEqual(environment["PLOZZ_TRACKER_CONNECTION_LIVE"], "1")
        XCTAssertEqual(app.state, .runningForeground)
        if cancel.exists {
            entered = true
            try cancelEntry()
        }
        try PublicMetaDBLiveNavigation.openSettings(in: app)
        if !activation.exists && app.buttons["Retry saved connection"].exists {
            try PublicMetaDBLiveNavigation.focus(back, moving: .up)
            try PublicMetaDBLiveNavigation.select(app.buttons["Retry saved connection"], moving: .down)
        }
        if app.switches["publicmetadb.ratings"].exists {
            try PublicMetaDBLiveNavigation.select(app.buttons["Done"], moving: .down)
            XCTAssertTrue(app.buttons["Done"].waitForNonExistence(timeout: 5))
        }
        XCTAssertTrue(activation.waitForExistence(timeout: 60))
        try PublicMetaDBLiveNavigation.focus(back, moving: .up)
        try PublicMetaDBLiveNavigation.select(enter, moving: .down)
        let replacement = app.sheets.firstMatch
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        try PublicMetaDBLiveNavigation.select(replacement.buttons["Replace API key"].firstMatch, moving: .right)
        entered = true
        try revealManualEntry()
        XCUIRemote.shared.press(.select)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let input = try await PublicMetaDBLiveManualInput.readKey()
        try PublicMetaDBLiveKeyboard.enter(input, in: keyboard)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        try focusKeyEntry()
        try move(.down, to: cancel)
        try move(.left, to: app.buttons["publicmetadb.connect"])
        XCUIRemote.shared.press(.select)
        guard activation.waitForExistence(timeout: 60), !keyField.exists else {
            throw Failure.precondition("The real manually entered key did not establish a native connection.")
        }
        entered = false
        XCTAssertTrue(app.staticTexts["Connected"].exists)
        try PublicMetaDBLiveNavigation.changeActivation(in: app, from: true)
        assertInactiveAccount()
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
        XCTAssertTrue(activation.waitForExistence(timeout: 60))
        let initialState = try XCTUnwrap(activation.value as? String)
        try PublicMetaDBLiveNavigation.focus(back, moving: .up)
        try PublicMetaDBLiveNavigation.select(enter, moving: .down)
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        try PublicMetaDBLiveNavigation.select(replacement.buttons["Cancel"].firstMatch, moving: .left)
        XCTAssertTrue(replacement.waitForNonExistence(timeout: 5))
        XCTAssertTrue(activation.exists)
        XCTAssertFalse(keyField.exists)
        XCTAssertEqual(activation.value as? String, initialState)

        try PublicMetaDBLiveNavigation.focus(back, moving: .up)
        try PublicMetaDBLiveNavigation.select(enter, moving: .down)
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        try PublicMetaDBLiveNavigation.select(replacement.buttons["Replace API key"].firstMatch, moving: .right)
        entered = true
        try PublicMetaDBLiveNavigation.requirePairingEntry(in: app)
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
        XCTAssertEqual(activation.value as? String, initialState)

        try PublicMetaDBLiveNavigation.focus(back, moving: .up)
        try PublicMetaDBLiveNavigation.select(enter, moving: .down)
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        try PublicMetaDBLiveNavigation.select(replacement.buttons["Replace API key"].firstMatch, moving: .right)
        entered = true
        try submitInvalidKey()
        guard app.staticTexts["Your session has expired. Please sign in again."].waitForExistence(timeout: 50) else {
            throw Failure.precondition("The real invalid replacement was not rejected.")
        }
        try cancelEntry()
        guard app.staticTexts["Connected"].waitForExistence(timeout: 45) else {
            throw Failure.precondition("Cancelling a rejected replacement did not restore the saved connection.")
        }
        XCTAssertEqual(activation.value as? String, initialState)

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
        XCTAssertTrue(app.launchArguments.isEmpty)
        XCTAssertTrue(app.launchEnvironment.isEmpty)
        app.terminate()
        app.launch()
        try PublicMetaDBLiveNavigation.openSettings(in: app)
        try requireUnconnectedPage()
    }
    private var activation: XCUIElement { PublicMetaDBLiveNavigation.activation(in: app) }

    private func assertInactiveAccount() {
        XCTAssertEqual(activation.label, "Enable tracker")
        XCTAssertEqual(activation.value as? String, "0")
        XCTAssertEqual(enter.label, "Replace API key")
        XCTAssertFalse(app.buttons["tracker-history.ongoing-sync"].exists)
        XCTAssertFalse(app.buttons["publicmetadb.browse"].exists)
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

        let firstCode = try await openWebsiteEntry()
        try PublicMetaDBLiveNavigation.focus(manual, moving: .down, maximumPresses: 2)
        for _ in 0..<3 {
            try move(.up, to: back)
            try move(.down, to: manual)
        }
        try move(.right, to: cancel)
        try cancelEntry()
        try await verifyRevoked(firstCode)
        try requireUnconnectedPage()

        let secondCode = try await openWebsiteEntry()
        guard secondCode != firstCode else { throw Failure.unexpectedRelayResponse }
        try submitInvalidKey()
        try await verifyRevoked(secondCode)

        let rejected = app.staticTexts["Your session has expired. Please sign in again."]
        guard rejected.waitForExistence(timeout: 50),
              !activation.exists,
              keyField.exists else {
            throw Failure.precondition("The real app did not show the expected live invalid-key rejection.")
        }
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
        try revealManualEntry()
        XCUIRemote.shared.press(.select)
        guard app.keyboards.firstMatch.waitForExistence(timeout: 5) else {
            throw Failure.precondition("API-key keyboard did not open.")
        }
        keyField.typeText("pm-" + String(repeating: "a", count: 60))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        try focusKeyEntry()
        try move(.down, to: cancel)
        try move(.left, to: app.buttons["publicmetadb.connect"])
        XCUIRemote.shared.press(.select)
    }

    private var keyField: XCUIElement { app.secureTextFields["publicmetadb.key"] }
    private var manual: XCUIElement { app.buttons["publicmetadb.pair.manual"] }
    private var back: XCUIElement { app.buttons["settings-workspace-back"] }
    private var cancel: XCUIElement { app.buttons["publicmetadb.pair.cancel"] }
    private var enter: XCUIElement { app.buttons["publicmetadb.pair"] }

    private func requireUnconnectedPage() throws {
        guard app.state == .runningForeground, enter.waitForExistence(timeout: 5),
              enter.label == "Connect PublicMetaDB", enter.isEnabled, !app.buttons["Disconnect"].exists,
              !activation.exists, !keyField.exists else {
            throw Failure.precondition("Open English PublicMetaDB settings with no saved key; existing connections are never replaced.")
        }
    }

    private func openPairingEntry() throws {
        try requireUnconnectedPage()
        if !enter.hasFocus {
            guard back.hasFocus else {
                throw Failure.precondition("Focus must be on Back or Connect PublicMetaDB.")
            }
            try move(.down, to: enter)
        }
        XCUIRemote.shared.press(.select)
        entered = true
        try PublicMetaDBLiveNavigation.requirePairingEntry(in: app)
    }

    private func openWebsiteEntry() async throws -> String {
        try openPairingEntry()
        let codeLabel = app.staticTexts["publicmetadb.pair.code"]
        guard codeLabel.waitForExistence(timeout: 50) else {
            throw Failure.precondition("The actual app did not obtain a live pairing challenge.")
        }
        let code = codeLabel.label.replacingOccurrences(of: " ", with: "")
        guard code.range(of: "^[A-HJ-NP-Z2-9]{8}$", options: .regularExpression) != nil else {
            throw Failure.unexpectedRelayResponse
        }
        let (data, status) = try await Self.relay(code)
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
        XCTAssertTrue(manual.isEnabled)
        return code
    }

    private func cancelEntry() throws {
        guard entered, app.state == .runningForeground, cancel.exists else {
            throw Failure.precondition("Cannot safely dismiss the expected pairing entry.")
        }
        if app.keyboards.firstMatch.exists {
            XCUIRemote.shared.press(.menu)
            guard app.keyboards.firstMatch.waitForNonExistence(timeout: 5) else {
                throw Failure.precondition("API-key keyboard did not close.")
            }
        }
        if !cancel.hasFocus {
            if keyField.exists {
                if app.buttons["publicmetadb.connect"].hasFocus { try move(.right, to: cancel) }
                else {
                    try focusKeyEntry()
                    try move(.down, to: cancel)
                }
            } else {
                try PublicMetaDBLiveNavigation.focus(back, moving: .up)
                try PublicMetaDBLiveNavigation.focus(manual, moving: .down, maximumPresses: 4)
                try move(.right, to: cancel)
            }
        }
        try focused(cancel)
        XCUIRemote.shared.press(.select)
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
        try await Self.verifyRelayRevoked(code)
    }

    static func verifyRelayRevoked(_ code: String) async throws {
        for attempt in 0..<5 {
            let (_, status) = try await relay(code)
            if status == 410 { return }
            guard status == 200 else { throw Failure.unexpectedRelayResponse }
            if attempt < 4 { try await Task.sleep(for: .seconds(1)) }
        }
        throw Failure.cancellationNotConfirmed
    }

    private static func relay(_ code: String) async throws -> (Data, Int) {
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

    private func revealManualEntry() throws {
        try PublicMetaDBLiveNavigation.requirePairingEntry(in: app)
        try PublicMetaDBLiveNavigation.select(manual, moving: .down, maximumPresses: 4)
        try focused(keyField)
        XCTAssertFalse(app.staticTexts["publicmetadb.pair.code"].exists || app.keyboards.firstMatch.exists)
    }

    private func focusKeyEntry() throws {
        if keyField.hasFocus { return }
        try PublicMetaDBLiveNavigation.focus(back, moving: .up)
        XCUIRemote.shared.press(.down)
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
}
#endif

enum PublicMetaDBLiveManualInput {
    enum Failure: Error {
        case requiresPrivateLoopbackLocatorFile
        case requiresOneShotLoopbackInputURL
        case oneShotInputUnavailable
        case invalidOneShotKeyResponse
        case dedicatedAccountNotVerified
    }

    static func readKey() async throws -> String {
        let environment = ProcessInfo.processInfo.environment
        #if os(iOS)
        // XCTest can retain its launch environment. Pass the file name, not the one-shot capability.
        guard let path = environment["PLOZZ_TRACKER_MANUAL_INPUT_URL_FILE"], path.hasPrefix("/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
              let size = attributes[.size] as? NSNumber, (1...2048).contains(size.intValue),
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw Failure.requiresPrivateLoopbackLocatorFile
        }
        let location = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        guard let location = environment["PLOZZ_TRACKER_MANUAL_INPUT_URL"] else {
            throw Failure.requiresOneShotLoopbackInputURL
        }
        #endif
        guard let url = URL(string: location), url.scheme == "http", url.host == "127.0.0.1",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw Failure.requiresOneShotLoopbackInputURL
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // URLSession errors can include the private one-shot URL. Never attach them or the response.
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.oneShotInputUnavailable }
        struct Input: Decodable { let key: String }
        guard data.count <= 4096, let input = try? JSONDecoder().decode(Input.self, from: data),
              input.key.utf8.count == 63,
              input.key.range(of: "^pm-[A-Za-z0-9]{60}$", options: .regularExpression) != nil else {
            throw Failure.invalidOneShotKeyResponse
        }
        return input.key
    }

    // Lists aren't exposed in tracking settings. Verify the dedicated key's marker
    // read-only, before pasting it, rather than removing the account identity check.
    static func verifyDedicatedAccount(key: String, expectedList: String) async throws {
        struct Page: Decodable {
            struct Item: Decodable { let name: String }
            let items: [Item]
            let totalPages: Int
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://publicmetadb.com/api/external/lists?page=1&perPage=100")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1024 * 1024,
              let page = try? JSONDecoder().decode(Page.self, from: data), page.totalPages == 1,
              page.items.contains(where: { $0.name == expectedList }) else { throw Failure.dedicatedAccountNotVerified }
    }
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
