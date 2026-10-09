import CoreModels
import CoreNetworking
import CoreUI
import FeatureAuth
import FeatureAuthCore
import Observation
import ProviderIPTV
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class IPTVImportPresentationHostedTests: XCTestCase {
    func testImportWakeProtectionReleasesOnSuccessFailureAndCancellation() async throws {
        for outcome in ImportWakeOutcome.allCases {
            let gate = PresentationImportGate()
            addTeardownBlock { await gate.release() }
            var authenticated = false
            let model = IPTVAuthViewModel(
                deviceID: "fixture", address: "https://provider.test/playlist",
                signIn: { credential, _, _, progress in
                    await gate.wait(progress)
                    if outcome == .failure { throw LiveTVSourceImportError.invalidPlaylist }
                    return UserSession(
                        server: MediaServer(id: "fixture", name: "Fixture", baseURL: credential.address, provider: .iptv),
                        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
                    )
                }, onAuthenticated: { _ in authenticated = true }
            )
            let window = try await host(
                IPTVSignInView(model: model, onCancel: {}).environment(\.scenePhase, .active)
            )
            defer { model.cancel(); close(window) }
            try await assertIdleTimerDisabled(false)
            model.connect()
            await gate.waitUntilStarted()
            try await assertIdleTimerDisabled(true)
            for stage in [IPTVImportProgress.Stage.playlist, .catalogCommit] {
                await gate.send(.init(stage: stage, entries: 382_324))
                try await assertIdleTimerDisabled(true)
            }
            if outcome == .cancellation { model.cancel() }
            await gate.release()
            try await assertIdleTimerDisabled(false)
            XCTAssertFalse(model.isConnecting)
            XCTAssertEqual(authenticated, outcome == .success)
            if outcome == .failure { XCTAssertNotNil(model.issue) }
        }
    }

    func testImportWakeProtectionTracksForegroundAndPreservesOverlappingPlayback() async throws {
        let gate = PresentationImportGate()
        addTeardownBlock { await gate.release() }
        let model = IPTVAuthViewModel(
            deviceID: "fixture", address: "https://provider.test/playlist",
            signIn: { _, _, _, progress in
                await gate.wait(progress)
                throw CancellationError()
            }, onAuthenticated: { _ in XCTFail("Dismissed import must not authenticate.") }
        )
        let state = ImportWakeScene()
        let playbackLease = DisplayWakeLease()
        let window = try await host(ImportWakeFixture(model: model, state: state))
        defer { model.cancel(); close(window); playbackLease.allowSleep() }
        model.connect()
        await gate.waitUntilStarted()
        try await assertIdleTimerDisabled(true)
        for phase in [ScenePhase.inactive, .active, .background, .active] {
            state.phase = phase
            try await assertIdleTimerDisabled(phase == .active)
        }
        playbackLease.keepAwake(true)
        state.visible = false
        let deadline = ContinuousClock.now + .seconds(3)
        while model.isConnecting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isConnecting, "Leaving setup must cancel the pending import.")
        try await assertIdleTimerDisabled(true)
        playbackLease.allowSleep()
        try await assertIdleTimerDisabled(false)
        await gate.release()
    }

    func testImportReplacesTheFormWithReadableProgressAndACancelAction() async throws {
        let gate = PresentationImportGate()
        addTeardownBlock { await gate.release() }
        let model = IPTVAuthViewModel(
            deviceID: "fixture", address: "https://provider.test/playlist",
            signIn: { credential, _, _, progress in
                await gate.wait(progress)
                throw CancellationError()
            }, onAuthenticated: { _ in XCTFail("The presentation fixture must not authenticate.") }
        )
        let window = try await host(
            IPTVSignInView(model: model, onCancel: {})
                .environment(\.themePalette, .dark)
                .environment(\.gradientBackgroundsEnabled, true)
        )
        defer { model.cancel(); close(window) }
        model.connect()
        await gate.waitUntilStarted()
        var text = try await capture(window, name: "iptv-connecting")
        XCTAssertTrue(text.contains("Connecting to your provider"), text)
        XCTAssertTrue(text.contains("Cancel"), text)
        XCTAssertFalse(text.contains("Playlist URL"), text)
        #if os(tvOS)
        let focusDeadline = ContinuousClock.now + .seconds(3)
        while UIFocusSystem(for: window)?.focusedItem == nil, ContinuousClock.now < focusDeadline {
            window.setNeedsFocusUpdate()
            window.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(UIFocusSystem(for: window)?.focusedItem, "The remaining Cancel action must receive native focus.")
        #endif
        await gate.send(.init(stage: .playlist, entries: 382_324))
        text = try await capture(window, name: "iptv-reading")
        XCTAssertTrue(text.contains("Reading your playlist"), text)
        XCTAssertTrue(text.contains("382,324"), text)
        XCTAssertTrue(text.contains("Playlist entries read"), text)
        await gate.send(.init(stage: .catalogCommit, entries: 120_000))
        text = try await capture(window, name: "iptv-saving")
        XCTAssertTrue(text.contains("Saving your library"), text)
        XCTAssertTrue(text.contains("120,000"), text)
        XCTAssertTrue(text.contains("Library records saved"), text)
        model.cancel()
        await gate.release()
        text = try await capture(window, name: "iptv-form-restored")
        XCTAssertTrue(text.contains("Playlist URL"), text)
        XCTAssertFalse(text.contains("Saving your library"), text)
    }

    func testDiscoveryCardSupportsLargeTextContrastAndOpaqueSurfacesOverTheGradient() async throws {
        let window = try await host(
            ScrollView {
                VStack(spacing: 24) {
                    SetupProgressCard(
                        title: "Finding your libraries",
                        detail: "Checking your connected sources for available libraries.",
                        symbol: "rectangle.stack"
                    )
                    Button("Choose later") {}
                        .plozzActionButton(role: .primary)
                }
                .padding(24)
            }
            .background { SettingsPageBackground() }
            .environment(\.themePalette, .dark)
            .environment(\.gradientBackgroundsEnabled, true)
            .environment(\.plozzReduceTransparency, true)
            .environment(\.dynamicTypeSize, .accessibility1),
            increasedContrast: true
        )
        defer { close(window) }
        let text = try await capture(window, name: "library-discovery-accessible")
        XCTAssertTrue(text.contains("Finding your libraries"), text)
        XCTAssertTrue(text.contains("Choose later"), text)
    }

    private func assertIdleTimerDisabled(_ expected: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while UIApplication.shared.isIdleTimerDisabled != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, expected)
    }

    private func host<V: View>(_ view: V, increasedContrast: Bool = false) async throws -> UIWindow {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "en_US")))
        controller.overrideUserInterfaceStyle = .dark
        if increasedContrast { controller.traitOverrides.accessibilityContrast = .high }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene?.windows.first(where: { $0 !== window })?.makeKeyAndVisible()
    }

    private func capture(_ window: UIWindow, name: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

private enum ImportWakeOutcome: CaseIterable, Sendable {
    case success, failure, cancellation
}

@MainActor @Observable
private final class ImportWakeScene {
    var phase = ScenePhase.active
    var visible = true
}

private struct ImportWakeFixture: View {
    let model: IPTVAuthViewModel
    let state: ImportWakeScene

    var body: some View {
        VStack {
            if state.visible {
                IPTVSignInView(model: model, onCancel: {})
            }
        }
        .environment(\.scenePhase, state.phase)
    }
}

private actor PresentationImportGate {
    private var progress: (@Sendable (IPTVImportProgress) -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(_ progress: @escaping @Sendable (IPTVImportProgress) -> Void) async {
        self.progress = progress
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        let deadline = ContinuousClock.now + .seconds(3)
        while progress == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(progress)
    }

    func send(_ value: IPTVImportProgress) { progress?(value) }
    func release() { continuation?.resume(); continuation = nil }
}
