import CoreUI
@testable import AppShell
@testable import FeaturePlayback
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class SubtitleStyleRepeatHostedTests: XCTestCase {
    private typealias Scope = PlayerOptionsFocusScope<EmptyView, PlayerControls.SubtitleScreen>
    private typealias Controller = Scope.Controller

    func testInlineSubtitleEditorOwnsInputEvenWithoutAPresentation() async throws {
        try await withHeldRow { controller, window, _ in
            let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            XCTAssertNil(window.rootViewController?.presentedViewController)
            XCTAssertTrue(controller.ownsHorizontalNavigationInput)
            XCTAssertFalse(NavigationRailEdgeCatcher.permitsNavigationFallback(from: focused))
        }
    }

    func testReleaseStopsRepeatingAndFreshPressStartsFine() async throws {
        try await withHeldRow { controller, _, moves in
            controller.stopRepeating()
            let released = moves.values.count
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(moves.values.count, released)
            controller.beginPress(.right)
            XCTAssertEqual(moves.values.count, released + 1)
            XCTAssertEqual(moves.values.last?.0, .right)
            XCTAssertEqual(moves.values.last?.1, false)
            controller.stopRepeating()
        }
    }

    func testSubmenuRightOpensOnceAndLeftDoesNotActivateIt() async throws {
        try await withHeldRow { controller, _, moves in
            controller.stopRepeating()
            controller.adjustableRow = { nil }
            controller.submenuRow = { 3 }
            moves.values.removeAll()
            controller.beginPress(.left)
            XCTAssertTrue(moves.values.isEmpty)
            controller.beginPress(.right)
            XCTAssertEqual(moves.values.count, 1)
            XCTAssertEqual(moves.values.first?.0, .right)
            XCTAssertEqual(moves.values.first?.1, false)
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertEqual(moves.values.count, 1, "Holding Right must not open further screens.")
        }
    }

    func testNativeFocusLossStopsEvenBeforeSwiftUIChangesItsRow() async throws {
        try await withHeldRow { controller, window, moves in
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let original = try XCTUnwrap(system.focusedItem)
            moves.focusSecond = true
            let deadline = ContinuousClock.now + .seconds(3)
            while system.focusedItem === original, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(system.focusedItem)
            XCTAssertFalse(system.focusedItem === original)
            let count = moves.values.count
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(moves.values.count, count)
        }
    }

    func testScreenChangeAndDismantlingStopRepeating() async throws {
        try await withHeldRow { controller, _, moves in
            controller.screen = .styleOutline
            let count = moves.values.count
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(moves.values.count, count)
            controller.beginPress(.left)
            Scope.dismantleUIViewController(controller, coordinator: ())
            let dismantled = moves.values.count
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(moves.values.count, dismantled)
        }
    }

    func testAppDeactivationAndDisappearanceStopRepeating() async throws {
        try await withHeldRow { controller, _, moves in
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            let inactive = moves.values.count
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(moves.values.count, inactive)
            controller.beginPress(.left)
            controller.viewWillDisappear(false)
            let hidden = moves.values.count
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(moves.values.count, hidden)
        }
    }

    @Observable final class Moves {
        var values: [(PlozzMoveCommandDirection, Bool)] = []
        var focusSecond = false
    }

    private struct Rows: View {
        let moves: Moves
        @FocusState private var focus: Int?

        var body: some View {
            VStack {
                Button("Adjustable row") {}.focused($focus, equals: 0)
                Button("Other row") {}.focused($focus, equals: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { focus = 0 }
            .onChange(of: moves.focusSecond) { _, value in focus = value ? 1 : 0 }
        }
    }

    private func withHeldRow(
        _ body: (Controller, UIWindow, Moves) async throws -> Void
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
        let moves = Moves()
        let controller = Controller(rootView: AnyView(Rows(moves: moves)))
        controller.screen = .style
        controller.adjustableRow = { 3 }
        controller.onMove = { moves.values.append(($0, $1)) }
        controller.loadViewIfNeeded()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.stopRepeating()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let focusDeadline = ContinuousClock.now + .seconds(3)
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        while system.focusedItem == nil, ContinuousClock.now < focusDeadline {
            window.layoutIfNeeded()
            system.requestFocusUpdate(to: controller)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(system.focusedItem)
        controller.beginPress(.left)
        XCTAssertEqual(moves.values.count, 1)
        XCTAssertEqual(moves.values.first?.1, false)
        try await Task.sleep(for: .milliseconds(720))
        XCTAssertGreaterThan(moves.values.count, 2)
        XCTAssertTrue(moves.values.dropFirst().allSatisfy { $0.1 })
        try await body(controller, window, moves)
    }
}
