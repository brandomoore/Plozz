#if os(iOS)
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlayerOptionsMenuButtonTests: XCTestCase {
    func testPresentedMenuSurvivesClockUpdatesBeyondControlsTimeout() async throws {
        let clock = MenuTestClock()
        let recorder = MenuTestRecorder()
        let host = UIHostingController(rootView: MenuTestHarness(clock: clock, recorder: recorder))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let button = try XCTUnwrap(findButton(host.view))
        let interaction = try XCTUnwrap(button.contextMenuInteraction)
        defer { interaction.dismissMenu() }
        XCTAssertTrue(button.showsMenuAsPrimaryAction)
        button.performPrimaryAction()
        try await waitForMenu(button, presented: true)
        let original = try XCTUnwrap(button.presentedMenu)
        XCTAssertEqual(recorder.presentations, [true])
        for tick in 1...50 {
            clock.seconds = tick
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(findButton(host.view) === button)
            XCTAssertTrue(button.presentedMenu === original)
            XCTAssertEqual(recorder.builds, 1, "Position updates must not reconstruct the open native menu")
        }
        XCTAssertEqual(recorder.presentations, [true], "An open menu holds the controls beyond four seconds")
        interaction.dismissMenu()
        try await waitForMenu(button, presented: false)
        XCTAssertNil(button.presentedMenu)
        XCTAssertEqual(recorder.presentations, [true, false])

        button.performPrimaryAction()
        try await waitForMenu(button, presented: true)
        XCTAssertEqual(recorder.builds, 2)
        XCTAssertEqual(button.presentedMenu?.children.first?.title, "Position 50")
        interaction.dismissMenu()
        try await waitForMenu(button, presented: false)
    }

    func testDismantlingDropsCallbacksAndMenuProvider() {
        let button = PlayerOptionsMenuControl(type: .system)
        let recorder = MenuTestRecorder()
        button.menuProvider = { UIMenu(children: []) }
        button.onPresentationChange = { recorder.presentations.append($0) }
        PlayerOptionsMenuButton.dismantleUIView(button, coordinator: ())
        XCTAssertNil(button.menuProvider)
        XCTAssertNil(button.onPresentationChange)
        XCTAssertTrue(recorder.presentations.isEmpty)
    }

    private func findButton(_ view: UIView) -> PlayerOptionsMenuControl? {
        if let button = view as? PlayerOptionsMenuControl { return button }
        return view.subviews.lazy.compactMap { self.findButton($0) }.first
    }

    private func waitForMenu(_ button: PlayerOptionsMenuControl, presented: Bool) async throws {
        for _ in 0..<30 {
            if (button.presentedMenu != nil) == presented { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Native menu presentation did not become \(presented)")
    }
}

@MainActor @Observable
private final class MenuTestClock {
    var seconds = 0
}

@MainActor
private final class MenuTestRecorder {
    var builds = 0
    var presentations: [Bool] = []
}

private struct MenuTestHarness: View {
    let clock: MenuTestClock
    let recorder: MenuTestRecorder

    var body: some View {
        let value = clock.seconds
        VStack {
            Text(verbatim: String(value))
            PlayerOptionsMenuButton(makeMenu: {
                recorder.builds += 1
                return UIMenu(children: [UIAction(title: "Position \(value)") { _ in }])
            }, onPresentationChange: { recorder.presentations.append($0) })
                .frame(width: 44, height: 44)
        }
    }
}
#endif
