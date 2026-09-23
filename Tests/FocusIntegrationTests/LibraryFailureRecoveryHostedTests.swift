import CoreModels
import CoreUI
import FeatureSettings
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class LibraryFailureRecoveryHostedTests: XCTestCase {
    func testLibrariesDistinguishOfflineAuthenticationAndServerResponseFailures() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let server = MediaServer(
            id: "silo", name: "Silo Test", baseURL: URL(string: "https://silo.example.test")!, provider: .silo
        )
        let account = Account(id: "silo", server: server, userID: "viewer", userName: "Viewer", deviceID: "test")
        let suite = "LibraryFailurePresentation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))

        for failure in [AppError.serverUnreachable, .unauthorized, .invalidResponse] {
            let scope = ProfileLibrariesScope(
                accounts: [account], activeProfile: .init(id: "profile", name: "Viewer"),
                discoveredLibraries: .empty, refreshingLibraryAccountIDs: [],
                unreachableLibraryAccountIDs: ["silo"], libraryFailures: ["silo": failure],
                reloadLibraries: {}, homeVisibility: visibility,
                isAccountIncludedInActiveProfile: { _ in true },
                onSetAccountIncluded: { _, _ in }, onAddAccount: {}, onAddUser: { _ in },
                plexHomeUsersFetcher: { _ in [] }, onSelectPlexHomeUser: { _, _ in }
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(rootView:
                MyLibrariesDetailView(scope: scope)
                    .environment(\.themePalette, ThemePalette.dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .background(.black)
            )
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").lowercased()
            if failure.requiresSignIn {
                XCTAssertTrue(text.contains("session has expired"), text)
                XCTAssertTrue(text.contains("sign in"), text)
                XCTAssertFalse(text.contains("offline"), text)
            } else if failure == .serverUnreachable {
                XCTAssertTrue(text.contains("offline"), text)
                XCTAssertTrue(text.contains("retry"), text)
            } else {
                XCTAssertTrue(text.contains("unexpected response"), text)
                XCTAssertFalse(text.contains("offline"), text)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Library failure - \(HandoffDiagnostics.errorCode(failure))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
