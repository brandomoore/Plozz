@testable import CoreUI
@testable import AppShell
import Observation
import SwiftUI
import UIKit
import TVUIKit
import XCTest

@MainActor
final class NativeFocusRequestHostedTests: XCTestCase {
    func testRepeatedNativeRequestsDoNotRequireABooleanReset() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for _ in 0..<3 {
            fixture.model.cardFocus?.requestFocus(animated: false)
            try await waitUntil(diagnostic: fixture.describe) { fixture.model.cardFocused }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(fixture.model.cardFocused, fixture.describe())
            XCTAssertFalse(try XCTUnwrap(fixture.model.cardFocus).request.wrappedValue.wantsFocus)
            fixture.model.focusHero?()
            try await waitUntil { fixture.model.heroFocused && !fixture.model.cardFocused }
        }
    }

    func testNativeRequestWaitsForTheCardToBeMounted() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.showsCard = false
        try await Task.sleep(for: .milliseconds(50))
        fixture.model.cardFocus?.requestFocus(animated: false)
        XCTAssertTrue(try XCTUnwrap(fixture.model.cardFocus).request.wrappedValue.wantsFocus)
        fixture.model.showsCard = true
        try await waitUntil(diagnostic: fixture.describe) { fixture.model.cardFocused }
    }

    func testNativeRequestWaitsForFocusEligibility() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.cardEnabled = false
        try await Task.sleep(for: .milliseconds(50))
        fixture.model.cardFocus?.requestFocus(animated: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(fixture.model.cardFocused)
        XCTAssertTrue(try XCTUnwrap(fixture.model.cardFocus).request.wrappedValue.wantsFocus)
        fixture.model.cardEnabled = true
        try await waitUntil(diagnostic: fixture.describe) { fixture.model.cardFocused }
    }

    private func makeFixture() async throws -> Fixture {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene)
        try await waitUntil { fixture.model.cardFocus != nil }
        XCTAssertTrue(try XCTUnwrap(fixture.model.cardFocus).usesNativeFocus)
        fixture.model.focusHero?()
        try await waitUntil { fixture.model.heroFocused }
        return fixture
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        diagnostic: (@MainActor () -> String)? = nil,
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), diagnostic?() ?? "", file: file, line: line)
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let previous: UIWindow?
        let model = NativeFocusRequestModel()
        init(scene: UIWindowScene) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(
                rootView: NativeFocusRequestView(model: model).environment(\.plozzCardFocusStyle, .system)
            )
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }
        func close() {
            model.cardFocus = nil
            model.focusHero = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func describe() -> String {
            var views = [window as UIView]
            var lines = ["request=\(String(describing: model.cardFocus?.request.wrappedValue))",
                         "focus=\(String(describing: UIFocusSystem.focusSystem(for: window)?.focusedItem))"]
            if let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem {
                lines.append("focused frame=\(String(describing: NavigationRowFocusRequester.frame(of: focused, relativeTo: window)))")
            }
            while let view = views.popLast() {
                if let card = view as? TVLockupView {
                    lines.append("native frame=\(card.convert(card.bounds, to: window)) enabled=\(card.isEnabled) eligible=\(card.canBecomeFocused) focused=\(card.isFocused) window=\(card.window != nil)")
                }
                views.append(contentsOf: view.subviews)
            }
            return lines.joined(separator: "\n")
        }
    }
}

@MainActor @Observable
private final class NativeFocusRequestModel {
    @ObservationIgnored var cardFocus: PlozzCardFocus.Binding?
    @ObservationIgnored var focusHero: (() -> Void)?
    var showsCard = true
    var cardEnabled = true
    var cardFocused = false
    var heroFocused = false
}

private struct NativeFocusRequestView: View {
    let model: NativeFocusRequestModel
    @PlozzCardFocus private var cardFocused: Bool
    @FocusState private var heroFocused: Bool

    var body: some View {
        VStack(spacing: 100) {
            Button("Hero") {}
                .focused($heroFocused)
            NativeFocusDecoy()
            if model.showsCard {
                NativeTVPoster(
                    image: nil, treatment: .original, aspectRatio: 2,
                    fallbackWidth: 400, title: .content("Target poster"), subtitle: nil,
                    overlay: Color.clear, focus: $cardFocused, action: {}
                )
                    .frame(width: 400, height: 250)
                    .focused($cardFocused.focusState)
                    .disabled(!model.cardEnabled)
            }
        }

        .defaultFocus($heroFocused, true, priority: .userInitiated)
        .environment(\.plozzCardFocusStyle, .system)
        .onAppear {
            model.cardFocus = $cardFocused
            model.focusHero = { heroFocused = true }
        }
        .onChange(of: cardFocused) { _, focused in model.cardFocused = focused }
        .onChange(of: heroFocused, initial: true) { _, focused in model.heroFocused = focused }
    }
}

private struct NativeFocusDecoy: View {
    @PlozzCardFocus private var focused: Bool

    var body: some View {
        Text("Other native card")
            .frame(width: 400, height: 100)
            .focusableCard(isFocused: $focused, cornerRadius: 20, action: {})
    }
}
