import CoreModels
@testable import CoreUI
import FeatureProfiles
import SwiftUI
import TVUIKit
import UIKit
import XCTest

@MainActor
final class ProfileAvatarFocusHostedTests: XCTestCase {
    func testProfileAndCreateAvatarsStayCustomWhileMediaCardsKeepSystemFocus() async throws {
        try await verify(style: .system, expectedNativeCards: 1)
    }

    func testExistingCustomFocusSelectionsRemainCustom() async throws {
        for style in [CardFocusStyle.highlight, .outlined] {
            try await verify(style: style, expectedNativeCards: 0)
        }
    }

    private func verify(style: CardFocusStyle, expectedNativeCards: Int) async throws {
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
        window.rootViewController = UIHostingController(rootView:
            ProfileAvatarFocusFixture().environment(\.plozzCardFocusStyle, style)
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        let focusDeadline = ContinuousClock.now + .seconds(5)
        while UIFocusSystem.focusSystem(for: window)?.focusedItem == nil,
              ContinuousClock.now < focusDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        XCTAssertEqual(nativeCards(in: window).count, expectedNativeCards,
                       "Profile and Add avatars must not acquire native rectangular plates.")
    }

    private func nativeCards(in view: UIView) -> [TVLockupView] {
        let here = (view as? TVLockupView).map { [$0] } ?? []
        return here + view.subviews.flatMap { nativeCards(in: $0) }
    }
}

private struct ProfileAvatarFocusFixture: View {
    private let profiles = [
        Profile(name: "Viewer One", avatarSymbol: "person.fill", colorIndex: 0),
        Profile(name: "Viewer Two", avatarSymbol: "star.fill", colorIndex: 1)
    ]
    @PlozzCardFocus private var mediaFocused: Bool

    var body: some View {
        HStack(spacing: 40) {
            ProfilePickerView(
                profiles: profiles,
                activeProfileID: profiles[0].id,
                onSelect: { _ in },
                onAddProfile: {},
                onAddKidsProfile: {}
            )
            .frame(width: 1450)
            Color.red
                .frame(width: 220, height: 300)
                .focusableCard(isFocused: $mediaFocused, cornerRadius: 20, action: {})
        }
    }
}
