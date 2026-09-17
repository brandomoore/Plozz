import CoreModels
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import AppShell

@MainActor
final class NativeSidebarPresentationHostedTests: XCTestCase {
    func testInactiveAndUnpresentedPagesCannotAcceptFocus() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        try await waitUntil { fixture.model.buttons[.home]?.isFocused == true }
        let inactive = try XCTUnwrap(fixture.model.buttons[.settings])
        XCTAssertFalse(inactive.isEnabled)

        fixture.model.handoff.begin(.settings)
        fixture.model.selection = .settings
        try await waitUntil { fixture.model.buttons[.home]?.isEnabled == false }
        XCTAssertFalse(inactive.isEnabled)
        XCTAssertTrue(fixture.model.handoff.isWaiting)
        XCTAssertEqual(fixture.model.prematureFocusCount, 0)

        fixture.model.mountDestinationAnchor = true
        try await waitUntil {
            !fixture.model.handoff.isWaiting && fixture.model.buttons[.settings]?.isEnabled == true
        }
        XCTAssertFalse(try XCTUnwrap(fixture.model.buttons[.home]).isEnabled)
        XCTAssertEqual(fixture.model.prematureFocusCount, 0)
    }

    private func makeFixture() async throws -> Fixture {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        return Fixture(scene: scene)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate())
    }

    @MainActor
    private final class Fixture {
        let model = Model()
        let window: UIWindow
        let previous: UIWindow?

        init(scene: UIWindowScene) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(rootView: Pages(model: model))
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            model.buttons.removeAll()
            previous?.makeKeyAndVisible()
        }
    }

    @MainActor @Observable
    final class Model {
        var selection = NavigationRailDestination.home
        let handoff = NavigationDestinationFocusHandoff()
        var mountDestinationAnchor = false
        var prematureFocusCount = 0
        @ObservationIgnored var buttons: [NavigationRailDestination: UIButton] = [:]
    }

    private struct Pages: View {
        let model: Model

        var body: some View {
            HStack(spacing: 100) {
                NativeSidebarFocusDestination(
                    destination: .home, selection: model.selection, handoff: model.handoff,
                    content: FocusButton(destination: .home, model: model)
                )
                if model.mountDestinationAnchor {
                    NativeSidebarFocusDestination(
                        destination: .settings, selection: model.selection, handoff: model.handoff,
                        content: FocusButton(destination: .settings, model: model)
                    )
                } else {
                    FocusButton(destination: .settings, model: model)
                        .disabled(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct FocusButton: UIViewRepresentable {
        let destination: NavigationRailDestination
        let model: Model

        func makeUIView(context: Context) -> Button {
            let button = Button(type: .system)
            button.setTitle(destination.storageValue, for: .normal)
            model.buttons[destination] = button
            return button
        }

        func updateUIView(_ button: Button, context: Context) {
            button.isEnabled = context.environment.isEnabled
            button.onFocus = {
                if model.handoff.isWaiting { model.prematureFocusCount += 1 }
            }
        }

        final class Button: UIButton {
            var onFocus: (() -> Void)?
            override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
                super.didUpdateFocus(in: context, with: coordinator)
                if context.nextFocusedView === self { onFocus?() }
            }
        }
    }
}
