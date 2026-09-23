import CoreModels
@testable import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class PlayerVersionMenuHostedTests: XCTestCase {
    func testVersionControlReceivesNativeFocusAndTheMenuFocusesThePlayingVersion() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        defer {
            PlayerScreenshotHook.pendingPanel = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let model = PlayerControlsModel()
        model.controlsVisible = true
        model.versions.options = [
            .init(version: .init(id: "1080", fileName: "Movie-1080.mkv", edition: "Theatrical", height: 1080), isSelected: false),
            .init(version: .init(id: "4k", fileName: "Movie-4K.mkv", edition: "Extended", height: 2160), isSelected: true)
        ]
        model.versions.onSelect = { _ in }
        let host = UIHostingController(rootView: controls(model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        model.controlBarVisible = true
        try await waitUntil {
            guard let frame = self.focusFrame(in: window) else { return false }
            return frame.midX > window.bounds.midX && frame.width < 200
        }
        XCTAssertEqual(model.trackControlCategories, [.version])
        model.controlBar.settled = true

        PlayerScreenshotHook.pendingPanel = .versions
        host.rootView = AnyView(controls(model).id(UUID()))
        window.layoutIfNeeded()
        try await waitUntil {
            (self.focusFrame(in: window)?.width ?? 0) > 500 && model.isPanelOpen
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(model.isPanelOpen)
        let image = DetailTransitionSnapshot.image(of: window)
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([text])
        let selectedText = try XCTUnwrap(text.results?.first {
            $0.topCandidates(1).first?.string.contains("Extended") == true
        })
        let rect = selectedText.boundingBox
        let center = CGPoint(
            x: rect.midX * window.bounds.width,
            y: (1 - rect.midY) * window.bounds.height
        )
        XCTAssertTrue(try XCTUnwrap(focusFrame(in: window)).contains(center),
                      "Native focus must land on the playing Extended version, not the first row.")
        let attachment = XCTAttachment(image: image)
        attachment.name = "Apple TV version menu"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func controls(_ model: PlayerControlsModel) -> AnyView {
        AnyView(PlayerControls(
            model: model, palette: .dark,
            actions: PlayerOptionsActions(), onExitToSurface: {}
        ).background(.black))
    }

    private func focusFrame(in window: UIWindow) -> CGRect? {
        guard let item = UIFocusSystem(for: window)?.focusedItem else { return nil }
        var environment: (any UIFocusEnvironment)? = item
        while let current = environment {
            if let container = current.focusItemContainer {
                return container.coordinateSpace.convert(item.frame, to: window)
            }
            environment = current.parentFocusEnvironment
        }
        return nil
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native focus did not reach the requested player control or menu.")
    }
}
