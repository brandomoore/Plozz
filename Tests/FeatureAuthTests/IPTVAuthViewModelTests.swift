import CoreModels
import CoreNetworking
import Foundation
import ProviderIPTV
@testable import FeatureAuthCore
import XCTest

@MainActor
final class IPTVAuthViewModelTests: XCTestCase {
    func testImportProgressIsTypedAndLateCallbacksCannotReplaceANewAttempt() async throws {
        let callbacks = AuthProgressCallbacks()
        let gate = IPTVSignInGate()
        let model = IPTVAuthViewModel(
            deviceID: "fixture", address: "https://provider.test/list",
            signIn: { credential, _, _, progress in
                callbacks.append(progress)
                return await gate.complete(credential)
            }, onAuthenticated: { _ in XCTFail("A cancelled attempt must not authenticate.") }
        )
        defer { model.cancel() }
        model.connect()
        XCTAssertEqual(model.progress.stage, .connecting)
        await gate.waitUntilRequested()
        callbacks.send(.init(stage: .playlist, entries: 382_324), at: 0)
        let deadline = ContinuousClock.now + .seconds(3)
        while model.progress.entries != 382_324, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.progress.stage, .playlist)
        XCTAssertEqual(model.progress.entries, 382_324)
        model.cancel()
        await gate.release()
        model.connect()
        XCTAssertEqual(model.progress.stage, .connecting)
        XCTAssertEqual(model.progress.entries, 0)
        await gate.waitUntilRequested()
        callbacks.send(.init(stage: .catalogCommit, entries: 382_324), at: 0)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.progress.stage, .connecting)
        model.cancel()
        await gate.release()
    }

    func testPlaylistFailureCopyAndDiagnosticsRemainSpecificAndAllowRetry() async throws {
        for (error, reason) in [
            (LiveTVSourceImportError.emptyPlaylist, IPTVSetupDiagnostic.Failure.Reason.empty),
            (.invalidPlaylist, .malformed)
        ] {
            let diagnostics = IPTVSetupDiagnostics()
            let buffer = AuthSetupBuffer()
            diagnostics.start { buffer.append($0) }
            let model = IPTVAuthViewModel(
                deviceID: "fixture", address: "https://provider.test/list", setupDiagnostics: diagnostics,
                signIn: { _, _, _, _ in throw error },
                onAuthenticated: { _ in XCTFail("An invalid playlist cannot create an account.") }
            )
            defer { model.cancel() }
            model.connect()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while model.issue == nil, ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertEqual(model.issue, error.userDescription)
            XCTAssertEqual(buffer.values.last?.failure?.reason, reason)
            XCTAssertFalse(model.isConnecting)
            XCTAssertTrue(model.canConnect)
        }
    }

    private final class AuthProgressCallbacks: @unchecked Sendable {
        private let lock = NSLock()
        private var callbacks: [@Sendable (IPTVImportProgress) -> Void] = []
        func append(_ callback: @escaping @Sendable (IPTVImportProgress) -> Void) {
            lock.withLock { callbacks.append(callback) }
        }
        func send(_ progress: IPTVImportProgress, at index: Int) {
            let callback = lock.withLock { callbacks[index] }
            callback(progress)
        }
    }

    func testBasicPlaylistAndRequiredXtreamCredentialsAreNotAdvanced() {
        let model = IPTVAuthViewModel(deviceID: "fixture", onAuthenticated: { _ in })
        XCTAssertFalse(model.hasAdvancedConfiguration)
        XCTAssertFalse(model.usesHTTP)
        model.mode = .xtream
        model.username = "fixture"
        model.password = "fixture"
        XCTAssertFalse(model.hasAdvancedConfiguration)
    }

    func testOptionalPlaylistConfigurationIsAdvanced() {
        let model = IPTVAuthViewModel(deviceID: "fixture", onAuthenticated: { _ in })
        model.authentication = .basic
        XCTAssertTrue(model.hasAdvancedConfiguration)
        model.authentication = .bearer
        XCTAssertTrue(model.hasAdvancedConfiguration)
        model.authentication = .none
        model.discoversPlaylistGuides = false
        XCTAssertTrue(model.hasAdvancedConfiguration)
        model.discoversPlaylistGuides = true
        model.guideAddress = "https://guide.example/guide.xml"
        XCTAssertTrue(model.hasAdvancedConfiguration)
        model.guideAddress = ""
        model.addGuide()
        XCTAssertTrue(model.hasAdvancedConfiguration)
        model.additionalGuides = []
        model.addHeader()
        XCTAssertTrue(model.hasAdvancedConfiguration)
        model.headers = []
        model.addGuideHeader()
        XCTAssertTrue(model.hasAdvancedConfiguration)
        model.guideHeaders = []
        XCTAssertFalse(model.hasAdvancedConfiguration)
    }

    func testHTTPWarningTracksOnlyAddressesUsedByTheSelectedMode() {
        let model = IPTVAuthViewModel(deviceID: "fixture", onAuthenticated: { _ in })
        for address in ["", "   ", "https://playlist.example/list", "playlist.example/list"] {
            model.address = address
            XCTAssertFalse(model.usesHTTP, address)
        }
        model.address = " \nHTTP://playlist.example/list\n "
        XCTAssertTrue(model.usesHTTP)
        model.mode = .xtream
        XCTAssertTrue(model.usesHTTP)
        model.mode = .file
        XCTAssertFalse(model.usesHTTP, "A hidden server field is not used for file imports.")
        model.guideAddress = "http://guide.example/guide.xml"
        XCTAssertTrue(model.usesHTTP)
        model.guideAddress = "https://guide.example/guide.xml"
        XCTAssertFalse(model.usesHTTP)
        model.addGuide()
        model.additionalGuides[0].address = " HTTP://guide.example/extra.xml "
        XCTAssertTrue(model.usesHTTP)
        model.additionalGuides = []
        XCTAssertFalse(model.usesHTTP)
    }

    func testValidationAndHandledAuthenticationFailuresAreAutomaticallyRecorded() async throws {
        let diagnostics = IPTVSetupDiagnostics()
        let buffer = AuthSetupBuffer()
        let finished = expectation(description: "Handled authentication failure")
        diagnostics.start {
            buffer.append($0)
            if $0.stage == .authentication, $0.outcome == .failed { finished.fulfill() }
        }
        let invalid = IPTVAuthViewModel(
            deviceID: "private", address: "ftp://private.test", setupDiagnostics: diagnostics,
            onAuthenticated: { _ in XCTFail("Invalid address cannot authenticate") }
        )
        invalid.connect()
        XCTAssertEqual(buffer.values.last?.stage, .validation)
        XCTAssertEqual(buffer.values.last?.failure?.reason, .invalidInput)
        let model = IPTVAuthViewModel(
            deviceID: "private", address: "https://private.test/list?token=private",
            setupDiagnostics: diagnostics,
            signIn: { _, _, _, _ in
                IPTVSetupDiagnostics.current?.advance(to: .authentication)
                throw IPTVError.authentication
            },
            onAuthenticated: { _ in XCTFail("Rejected authentication cannot persist") }
        )
        model.connect()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(buffer.values.last?.failure?.reason, .authentication)
        XCTAssertNotNil(model.issue)
        XCTAssertFalse(model.isConnecting)
    }

    func testDisabledDiagnosticsDoNotChangeSuccessfulSetup() async {
        let finished = expectation(description: "Account saved without reporting")
        let diagnostics = IPTVSetupDiagnostics()
        let model = IPTVAuthViewModel(
            deviceID: "device", address: "https://provider.example/list", setupDiagnostics: diagnostics,
            signIn: { credential, _, _, _ in
                XCTAssertNil(IPTVSetupDiagnostics.current)
                return IPTVSignInGate.session(credential)
            },
            onAuthenticated: { _ in finished.fulfill() }
        )
        model.connect()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertNil(model.issue)
        XCTAssertFalse(model.isConnecting)
    }

    func testPlaylistBasicBearerAndGuideHeadersStaySeparate() throws {
        let model = IPTVAuthViewModel(
            deviceID: "device", address: "https://provider.example/list",
            guideAddress: "https://guide.example/xmltv", onAuthenticated: { _ in }
        )
        model.authentication = .basic
        model.username = "fixture-user"
        model.password = "fixture-password"
        XCTAssertTrue(model.canConnect)
        model.addGuideHeader()
        model.guideHeaders[0].name = "Authorization"
        model.guideHeaders[0].value = "Bearer guide-fixture"
        let basic = try model.makeCredential()
        XCTAssertEqual(basic.headers["Authorization"], "Basic " + Data("fixture-user:fixture-password".utf8).base64EncodedString())
        XCTAssertEqual(try basic.guideHeaders(for: XCTUnwrap(basic.guideURL))["Authorization"], "Bearer guide-fixture")
        XCTAssertTrue(try basic.guideHeaders(for: XCTUnwrap(URL(string: "https://foreign.example/guide"))).isEmpty)
        model.authentication = .bearer
        XCTAssertFalse(model.canConnect)
        model.token = "playlist-fixture"
        XCTAssertEqual(try model.makeCredential().headers["Authorization"], "Bearer playlist-fixture")
    }

    func testXtreamNormalizesAnAPIEndpointAndRequiresCredentials() throws {
        let model = IPTVAuthViewModel(
            deviceID: "device", address: "https://provider.example/prefix/player_api.php?unused=1",
            onAuthenticated: { _ in }
        )
        model.mode = .xtream
        XCTAssertFalse(model.canConnect)
        model.username = "viewer"
        model.password = "fixture"
        XCTAssertTrue(model.canConnect)
        XCTAssertEqual(try model.makeCredential().address.absoluteString, "https://provider.example/prefix")
    }

    func testSeedPreservesEveryConfiguredGuideAndRejectsDuplicateHeaders() throws {
        let guides = try ["https://guide.example/one", "https://guide.example/two"].map {
            try XCTUnwrap(URL(string: $0))
        }
        let model = IPTVAuthViewModel(
            deviceID: "device", address: "https://provider.example/list", guideURLs: guides,
            onAuthenticated: { _ in }
        )
        XCTAssertEqual(try model.makeCredential().explicitGuideURLs, guides)
        model.addHeader()
        model.headers[0].name = "Cookie"
        model.headers[0].value = "session=fixture"
        model.addHeader()
        model.headers[1].name = "cookie"
        model.headers[1].value = "session=duplicate"
        XCTAssertThrowsError(try model.makeCredential())
    }

    func testCancellationRejectsLateSuccessfulAuthentication() async throws {
        let gate = IPTVSignInGate()
        let diagnostics = IPTVSetupDiagnostics()
        let buffer = AuthSetupBuffer()
        diagnostics.start { buffer.append($0) }
        var received = 0
        let model = IPTVAuthViewModel(
            deviceID: "device", address: "https://provider.example/list",
            setupDiagnostics: diagnostics,
            signIn: { credential, _, _, _ in await gate.complete(credential) },
            onAuthenticated: { _ in received += 1 }
        )
        model.connect()
        await gate.waitUntilRequested()
        model.cancel()
        await gate.release()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(received, 0)
        XCTAssertFalse(model.isConnecting)
        XCTAssertEqual(buffer.values.filter { $0.outcome == .cancelled }.count, 1)
        XCTAssertFalse(buffer.values.contains { $0.outcome == .failed || $0.outcome == .succeeded })
    }

    func testPersistenceFailureRemainsVisibleAndAllowsRetry() async throws {
        let diagnostics = IPTVSetupDiagnostics()
        let buffer = AuthSetupBuffer()
        diagnostics.start { buffer.append($0) }
        let model = IPTVAuthViewModel(
            deviceID: "device", address: "https://provider.example/list",
            setupDiagnostics: diagnostics,
            signIn: { credential, _, _, _ in IPTVSignInGate.session(credential) },
            onAuthenticated: { _ in
                XCTAssertNil(IPTVSetupDiagnostics.current, "Account activation must not pass setup telemetry to background work")
                throw IPTVAuthViewModel.CompletionError.persistence
            }
        )
        defer { model.cancel() }
        model.connect()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.issue == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(model.issue)
        XCTAssertTrue(model.canConnect)
        XCTAssertEqual(buffer.values.last?.stage, .persistence)
        XCTAssertEqual(buffer.values.last?.failure?.reason, .storage)
    }

    private final class AuthSetupBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [IPTVSetupDiagnostic] = []
        var values: [IPTVSetupDiagnostic] { lock.withLock { storage } }
        func append(_ value: IPTVSetupDiagnostic) { lock.withLock { storage.append(value) } }
    }

    func testEditingConnectionRetainsAccountIdentityAndUsesFreshPrivateCatalog() async throws {
        let credential = try IPTVCredential(
            mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.example/old?token=fixture")),
            headers: ["Authorization": "Basic Zml4dHVyZTpwYXNzd29yZA=="],
            guideURL: XCTUnwrap(URL(string: "https://guide.example/one")),
            additionalGuideURLs: [XCTUnwrap(URL(string: "https://guide.example/two"))],
            guideHeaders: ["X-Guide-Key": "fixture"]
        )
        var original = IPTVSignInGate.session(credential)
        original.accessToken = try credential.encoded()
        var received: UserSession?
        let model = IPTVAuthViewModel(
            deviceID: "device", reconnecting: original,
            signIn: { credential, _, _, _ in
                var result = IPTVSignInGate.session(credential)
                result.server.id = "new-catalog"
                result.userID = "new-user"
                result.accessToken = try credential.encoded()
                return result
            },
            onAuthenticated: { received = $0 }
        )
        XCTAssertEqual(try model.makeCredential().headers, credential.headers)
        XCTAssertTrue(model.hasAdvancedConfiguration)
        XCTAssertEqual(try model.makeCredential().explicitGuideURLs, credential.explicitGuideURLs)
        XCTAssertEqual(try model.makeCredential().explicitGuideHeaders, credential.explicitGuideHeaders)
        model.address = "https://provider.example/new?token=updated"
        model.connect()
        defer { model.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while received == nil, ContinuousClock.now < deadline { await Task.yield() }
        let updated = try XCTUnwrap(received)
        XCTAssertEqual(Account.stableID(for: updated), Account.stableID(for: original))
        let updatedCredential = try IPTVCredential.decode(updated.accessToken)
        XCTAssertEqual(updatedCredential.address.absoluteString, model.address)
        XCTAssertNotEqual(updatedCredential.identity, credential.identity)
        XCTAssertNotEqual(updatedCredential.catalogKey, credential.catalogKey)
    }
}

private actor IPTVSignInGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var requested = false
    func complete(_ credential: IPTVCredential) async -> UserSession {
        requested = true
        await withCheckedContinuation { continuation = $0 }
        return Self.session(credential)
    }
    func waitUntilRequested() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !requested, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(requested)
    }
    func release() { continuation?.resume(); continuation = nil; requested = false }
    nonisolated static func session(_ credential: IPTVCredential) -> UserSession {
        UserSession(
            server: MediaServer(id: "fixture", name: "Fixture", baseURL: credential.address, provider: .iptv),
            userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: "fixture"
        )
    }
}
