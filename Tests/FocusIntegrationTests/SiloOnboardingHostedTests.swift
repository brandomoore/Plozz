#if os(tvOS)
import CoreModels
import CoreNetworking
@testable import CoreUI
@testable import AppShell
import FeatureAuth
import FeatureAuthCore
import ProviderSilo
import SwiftUI
import UIKit
import XCTest

@MainActor
final class SiloOnboardingHostedTests: XCTestCase {
    func testPairingLayoutsAndApprovalFocusesFirstProfile() async throws {
        try await wait {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for light in [false, true] {
            let url = URL(string: "https://silo.example.test")!
            let server = MediaServer(id: "fixture", name: "Silo", baseURL: url, provider: .silo)
            let http = OnboardingPreviewHTTP()
            let model = SiloAuthViewModel(
                server: server, deviceID: "fixture",
                service: SiloAuthentication(baseURL: url, http: http),
                onAuthenticated: { _ in XCTFail("Preview must not create a real account") }
            )
            let host = UIHostingController(rootView:
                SiloSignInView(viewModel: model, server: server, onCancel: {})
                    .environment(\.themePalette, light ? .light : .dark)
                    .preferredColorScheme(light ? .light : .dark)
                    .background(light ? Color.white : Color.black)
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { model.cancel() }
            try await wait { if case .pairing = model.phase { return true }; return false }
            try await Task.sleep(for: .seconds(1))
            window.layoutIfNeeded()
            _ = capture(window, name: light ? "silo-pairing-light" : "silo-pairing-dark")
            await http.approve()
            try await wait { if case .profiles = model.phase { return true }; return false }
            try await wait {
                guard let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem,
                      let frame = NavigationRowFocusRequester.frame(of: focused, relativeTo: window) else { return false }
                // SwiftUI uses virtual focus items, not UIViews/accessibility
                // elements. Of this fixture's three cards, only Alex is left of center.
                return frame.midX < window.bounds.midX && frame.width > 150 && frame.height > 150
            }
            _ = capture(window, name: light ? "silo-profiles-light" : "silo-profiles-dark")
            let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            let frame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: focused, relativeTo: window))
            XCTAssertTrue(window.bounds.contains(frame),
                          "The first profile must be on-screen, not just assigned in FocusState")
        }
    }

    private func capture(_ window: UIWindow, name: String) -> UIImage {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}

private actor OnboardingPreviewHTTP: HTTPClient {
    private var approved = false
    func approve() { approved = true }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let body: String
        switch endpoint.path {
        case "/api/v2/system/info": body = #"{"api_major":2}"#
        case "/api/v2/auth/device/capability":
            body = #"{"state":"available","protocol_versions":[2],"allowed":true}"#
        case "/api/v2/auth/device/start":
            body = """
            {"device_code":"fixture","user_code":"ABCD12","match_code":"57",
             "verification_uri":"https://silo.example.test/pair",
             "verification_uri_complete":"https://silo.example.test/pair?code=ABCD12",
             "expires_in":600,"interval":1}
            """
        case "/api/v2/auth/device/poll":
            body = """
            {"status":"\(approved ? "approved" : "pending")","poll_after":1,"temporary":false,
             "tokens":{"access_token":"fixture","refresh_token":"fixture","expires_in":3600,
             "user":{"id":"fixture","username":"Alex"}}}
            """
        case "/api/v2/profiles":
            body = """
            {"items":[{"id":"alex","name":"Alex","has_pin":false,"is_child":false},
            {"id":"sam","name":"Sam","has_pin":true,"is_child":false},
            {"id":"kids","name":"Kids","has_pin":true,"is_child":true}]}
            """
        default: throw AppError.notFound
        }
        return (Data(body.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
#endif
