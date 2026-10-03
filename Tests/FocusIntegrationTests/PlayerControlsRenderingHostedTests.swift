import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PlayerControlsRenderingHostedTests: XCTestCase {
    func testClockUpdatesAndRepeatedCardRevealsPreserveBothNativeMaterials() async throws {
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
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        for performance in [false, true] {
            let model = PlayerControlsModel()
            model.controlsVisible = true
            model.duration = 3_600
            model.currentSeconds = 600
            model.bufferedSeconds = 800
            model.title = "Rendering fixture"
            model.subtitle = "Season 1, Episode 2"
            model.infoCard.headline = "Episode two"
            model.infoCard.overview = "A stable, local fixture for the production controls."
            model.engineCapabilities = [.playbackSpeed]
            window.rootViewController = UIHostingController(rootView:
                PlayerControls(
                    model: model, palette: .dark, actions: PlayerOptionsActions(), onExitToSurface: {}
                )
                .environment(\.plozzReducePanelGlass, performance)
                .environment(\.colorScheme, .dark)
                .background(Color(red: 0.08, green: 0.12, blue: 0.18))
            )
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(800))
            let initial = try XCTUnwrap(model.subtitleLayout.frame(for: .timeline))

            for _ in 0..<20 {
                model.currentSeconds += 0.25
                model.bufferedSeconds += 0.25
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(model.subtitleLayout.frame(for: .timeline), initial)

            for _ in 0..<3 {
                model.controlBar.entry = .info
                model.controlBar.focusArmed = false
                model.controlBar.settled = false
                model.controlBarVisible = true
                try await Task.sleep(for: .milliseconds(650))
                XCTAssertTrue(model.controlBar.focusArmed)
                model.controlBar.settled = true
                XCTAssertTrue(model.controlBar.infoCardOpen)
                let card = try XCTUnwrap(model.subtitleLayout.frame(for: .card))
                XCTAssertGreaterThan(card.minY, 0)
                XCTAssertLessThanOrEqual(card.maxY, window.bounds.maxY + 1)
                model.controlBarVisible = false
                try await Task.sleep(for: .milliseconds(650))
                XCTAssertFalse(model.controlBar.infoCardOpen)
                let restored = try XCTUnwrap(model.subtitleLayout.frame(for: .timeline))
                XCTAssertEqual(restored.minX, initial.minX, accuracy: 1)
                XCTAssertEqual(restored.minY, initial.minY, accuracy: 1)
                XCTAssertEqual(restored.width, initial.width, accuracy: 1)
                XCTAssertEqual(restored.height, initial.height, accuracy: 1)
            }

            let driver = InfoFocusDriver()
            model.infoCard.hasPreviousEpisode = true
            model.infoCard.hasNextEpisode = true
            window.rootViewController = UIHostingController(rootView:
                InfoFocusFixture(model: model, driver: driver)
                    .frame(width: 1600)
                    .environment(\.plozzReducePanelGlass, performance)
                    .environment(\.colorScheme, .dark)
                    .background(Color(red: 0.08, green: 0.12, blue: 0.18))
            )
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            for _ in 0..<3 {
                for target in [PlayerControls.FocusSlot.infoNext, .infoPrev, .infoRestart, .infoStats] {
                    let previousFocus = UIFocusSystem.focusSystem(for: window)?.focusedItem
                    try XCTUnwrap(driver.requestFocus)(target)
                    try await Task.sleep(for: .milliseconds(250))
                    let currentFocus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
                    XCTAssertFalse(currentFocus === previousFocus, "Native focus must move to the requested action.")
                }
            }
            NotificationCenter.default.post(name: .metadataProviderSettingsDidChange, object: nil)
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

@MainActor
private final class InfoFocusDriver {
    var requestFocus: ((PlayerControls.FocusSlot) -> Void)?
}

private struct InfoFocusFixture: View {
    let model: PlayerControlsModel
    let driver: InfoFocusDriver
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        InfoPanelView(model: model, actions: PlayerOptionsActions(), focus: $focus, onClose: {})
            .onAppear {
                driver.requestFocus = { focus = $0 }
                focus = .infoRestart
            }
            .onDisappear { driver.requestFocus = nil }
    }
}
