import CoreModels
import CoreUI
import FeatureAuth
import FeatureAuthCore
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class AccountRecoveryPresentationHostedTests: XCTestCase {
    #if os(tvOS)
    func testManagedSignInPhaseOwnsItsOpaqueSurfaceInsteadOfShowingTheExpiredPageBehindIt() async throws {
        let model = AccountReauthenticationModel(
            account: .init(
                id: "account",
                server: .init(id: "server", name: "Server", baseURL: URL(string: "https://server.example")!, provider: .jellyfin),
                userID: "user", userName: "Viewer", deviceID: "fixture"
            ),
            deviceID: "fixture", store: AccountStore(secureStore: InMemorySecureStore()),
            isAuthorized: { true }, onComplete: {}
        )
        try await verify(
            ZStack(alignment: .leading) {
                Color.red.ignoresSafeArea()
                Text("EXPIRED UNDERLAY").font(.system(size: 48)).padding(120)
                AccountReauthenticationView(model: model, onCancel: {}) { _ in
                    Text("Link your account")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            },
            name: "Opaque account-link phase", palette: .dark,
            expected: ["Link your account"], notExpected: ["EXPIRED", "UNDERLAY"]
        )
    }
    #endif

    func testPlexRecoveryKeepsExplanationAndAllActionsVisibleWithNativePrimaryFocus() async throws {
        #if os(iOS)
        let widths: [CGFloat] = [320, 390, 430, 844]
        #else
        let widths: [CGFloat] = [1920]
        #endif
        for width in widths {
            for (name, error) in [("expired", AppError.unauthorized), ("offline", .serverUnreachable)] {
                try await verify(
                    PlexAccountRecoveryView(
                        name: "Alex", message: error.userMessage, signIn: nil,
                        onSignIn: {}, onRetry: {}, onCancel: {}, onCancelSignIn: {}
                    ),
                    name: "Plex recovery \(name) \(Int(width))", palette: .dark,
                    expected: ["Reconnect to Plex", "Alex", "Sign In Again", "Try Again", "Cancel"],
                    focusedTitle: "Sign In Again", mobileWidth: width, checksPlexActionLayout: true
                )
            }
        }
    }

    func testManagedAccountErrorsShareRecoveryLayoutAcrossProvidersAndThemes() async throws {
        for provider in ProviderKind.allCases where provider.supportsAccountReauthentication {
            let account = Account(
                id: "account",
                server: MediaServer(
                    id: "server", name: "Home Server",
                    baseURL: try XCTUnwrap(URL(string: "https://server.example")), provider: provider
                ),
                userID: "alex", userName: "Alex", deviceID: "fixture"
            )
            for (theme, palette) in [("dark", ThemePalette.dark), ("light", .light)] {
                let model = AccountReauthenticationModel(
                    account: account, deviceID: "fixture",
                    store: AccountStore(secureStore: InMemorySecureStore()),
                    isAuthorized: { true }, onComplete: { XCTFail("Mismatched sign-in must not complete.") }
                )
                var session = account.session(token: "FIXTURE")
                session.userID = "different-user"
                XCTAssertThrowsError(try model.complete(session))
                try await verify(
                    AccountReauthenticationView(model: model, onCancel: {}) { _ in EmptyView() },
                    name: "\(provider.displayName) recovery \(theme)", palette: palette,
                    expected: ["Reconnect to \(provider.displayName)", "Alex", "same account", "Try Again", "Cancel"],
                    focusedTitle: "Try Again"
                )
            }
        }
    }

    func testPlaybackFailureRetainsReadableExplanationAndActionsInSharedLayout() async throws {
        try await verify(
            PlaybackFailureView(
                title: "Playback timed out", message: AppError.serverUnreachable.userMessage, report: nil
            ) {
                Button("Try Again") {}.plozzActionButton()
                Button("Back") {}.plozzActionButton(role: .secondary)
            },
            name: "Playback recovery", palette: .light,
            expected: ["Playback timed out", "server", "Try Again", "Back"]
        )
    }

    private func verify<Content: View>(
        _ content: Content, name: String, palette: ThemePalette,
        expected: [String], notExpected: [String] = [], focusedTitle: String? = nil,
        mobileWidth: CGFloat = 390, checksPlexActionLayout: Bool = false
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        #if os(iOS)
        window.frame = CGRect(x: 0, y: 0, width: mobileWidth, height: mobileWidth > 500 ? 390 : 844)
        #endif
        let host = UIHostingController(rootView:
            ZStack {
                AppBackground(palette: palette).ignoresSafeArea()
                content
            }
            .environment(\.themePalette, palette)
            .environment(\.colorScheme, palette.isLight ? .light : .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.dynamicTypeSize, .large)
        )
        host.overrideUserInterfaceStyle = palette.isLight ? .light : .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        #if os(tvOS)
        let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        let focusDeadline = ContinuousClock.now + .seconds(5)
        while focus.focusedItem == nil, ContinuousClock.now < focusDeadline {
            focus.requestFocusUpdate(to: host)
            focus.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #endif
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let observations = request.results ?? []
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        for value in expected {
            XCTAssertTrue(text.contains(value), "\(name) must show \(value): \(text)")
        }
        for value in notExpected {
            XCTAssertFalse(text.contains(value), "\(name) must hide the covered page's \(value): \(text)")
        }
        #if os(iOS)
        if checksPlexActionLayout {
            let buttons = try ["Sign In Again", "Try Again", "Cancel"].map { title in
                try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string == title }).boundingBox
            }
            if mobileWidth < 500 {
                for button in buttons {
                    XCTAssertEqual(button.midX * mobileWidth, mobileWidth / 2, accuracy: 3)
                }
                let primary = buttons[0]
                let cgImage = try XCTUnwrap(image.cgImage)
                let scale = CGFloat(cgImage.width) / mobileWidth
                let row = try XCTUnwrap(cgImage.cropping(to: CGRect(
                    x: 0, y: (1 - primary.midY) * CGFloat(cgImage.height),
                    width: CGFloat(cgImage.width), height: 1
                )))
                var pixels = [UInt8](repeating: 0, count: row.width * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(
                        data: buffer.baseAddress, width: row.width, height: 1,
                        bitsPerComponent: 8, bytesPerRow: row.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ))
                    context.draw(row, in: CGRect(x: 0, y: 0, width: row.width, height: 1))
                }
                let fill = (0..<row.width).filter { x in
                    (0..<3).allSatisfy { pixels[x * 4 + $0] > 180 }
                }
                let leading = CGFloat(try XCTUnwrap(fill.first)) / scale
                let trailing = CGFloat(try XCTUnwrap(fill.last) + 1) / scale
                XCTAssertEqual(leading, 44, accuracy: 2, "Native fill must start at the card's content inset.")
                XCTAssertEqual(trailing, mobileWidth - 44, accuracy: 2, "Native fill must span the content width.")
            } else {
                for button in buttons.dropFirst() {
                    XCTAssertEqual(button.midY, buttons[0].midY, accuracy: 0.01,
                                   "Wide layouts must retain the horizontal action row.")
                }
            }
        }
        #endif
        let safeBounds = window.bounds.inset(by: window.safeAreaInsets)
        for observation in observations {
            let rect = observation.boundingBox
            let frame = CGRect(
                x: rect.minX * window.bounds.width, y: (1 - rect.maxY) * window.bounds.height,
                width: rect.width * window.bounds.width, height: rect.height * window.bounds.height
            )
            XCTAssertTrue(safeBounds.contains(frame), "\(name) text must remain inside the safe area: \(frame)")
        }
        #if os(tvOS)
        if let focusedTitle {
            let item = try XCTUnwrap(focus.focusedItem)
            var environment: (any UIFocusEnvironment)? = item
            var focusedFrame: CGRect?
            while let current = environment {
                if let container = current.focusItemContainer {
                    focusedFrame = container.coordinateSpace.convert(item.frame, to: window)
                    break
                }
                environment = current.parentFocusEnvironment
            }
            let frame = try XCTUnwrap(focusedFrame)
            XCTAssertTrue(observations.contains { observation in
                guard observation.topCandidates(1).first?.string == focusedTitle else { return false }
                let rect = observation.boundingBox
                return frame.contains(CGPoint(
                    x: rect.midX * window.bounds.width, y: (1 - rect.midY) * window.bounds.height
                ))
            }, "Native focus must land on \(focusedTitle), not just a SwiftUI focus binding: \(text)")
        }
        #endif
    }
}
