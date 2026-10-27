#if os(iOS)
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS
@testable import FeaturePlayback

@MainActor
final class PlayerZoomMenuPresentationTests: XCTestCase {
    func testNativeChoicesApplyTheirModeAndOnlyCustomOpensFineControl() throws {
        let model = PlayerVideoZoomModel()
        var opened = 0
        let menu = PlayerZoomMenu.make(model: model, locale: Locale(identifier: "en-US")) { opened += 1 }
        let choices = menu.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(choices.count, 4)
        XCTAssertEqual(choices.map(\.title), ["Normal (Default)", "Crop", "Stretch", "Custom"])
        XCTAssertTrue(choices.allSatisfy { $0.subtitle?.isEmpty != false }, "Keep the choices concise without extra descriptions.")
        for mode in PlayerVideoZoom.Mode.allCases {
            let button = UIButton(type: .system)
            button.addAction(choices[mode.rawValue], for: .primaryActionTriggered)
            button.sendActions(for: .primaryActionTriggered)
            XCTAssertEqual(model.settings.mode, mode)
            XCTAssertEqual(opened, mode == .custom ? 1 : 0)
        }
    }

    func testZoomMenuKeepsItsNativeSnapshotUntilDismissalAndRefreshesOnReopen() async throws {
        let state = State()
        let host = UIHostingController(rootView: MenuHost(state: state))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = PlayerOrientationTestWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await waitUntil { self.button(in: host.view) != nil }
        let button = try XCTUnwrap(button(in: host.view))
        let interaction = try XCTUnwrap(button.contextMenuInteraction)
        defer { interaction.dismissMenu() }
        button.performPrimaryAction()
        try await waitUntil { button.presentedMenu != nil }
        let menu = try XCTUnwrap(button.presentedMenu)
        let zoomMenu = try XCTUnwrap(menu.children.first as? UIMenu)
        let rows = zoomMenu.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(rows.map(\.title), ["Normal (Default)", "Crop", "Stretch", "Custom"])
        XCTAssertEqual(rows.map(\.state), [.on, .off, .off, .off])
        for tick in 1...10 {
            state.seconds = tick
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(button.presentedMenu === menu)
        }
        XCTAssertEqual(state.presentations, [true])
        XCTAssertEqual(state.builds, 1)
        interaction.dismissMenu()
        try await waitUntil { button.presentedMenu == nil }
        state.zoom.settings.mode = .fill
        button.performPrimaryAction()
        try await waitUntil { button.presentedMenu != nil }
        let reopened = try XCTUnwrap(button.presentedMenu?.children.first as? UIMenu)
        XCTAssertEqual(reopened.children.compactMap { ($0 as? UIAction)?.state }, [.off, .on, .off, .off])
        XCTAssertEqual(state.builds, 2)
        interaction.dismissMenu()
        try await waitUntil { button.presentedMenu == nil }
    }

    func testLiveZoomMenuAndCustomControlsKeepLandscapeOwnership() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let state = State()
        let host = UIHostingController(rootView: MenuHost(state: state))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = PlayerOrientationTestWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await waitUntil { scene.effectiveGeometry.interfaceOrientation == .portrait }
        state.livePlayback = true
        try await waitUntil {
            scene.effectiveGeometry.interfaceOrientation.isLandscape
                && PlozziOSWindowOrientation.supportedOrientations(for: window) == .landscape
        }
        let button = try XCTUnwrap(button(in: host.view))
        let interaction = try XCTUnwrap(button.contextMenuInteraction)
        defer { interaction.dismissMenu() }
        button.performPrimaryAction()
        try await waitUntil { button.presentedMenu != nil && host.presentedViewController != nil }
        let zoom = try XCTUnwrap(button.presentedMenu?.children.first as? UIMenu)
        let custom = try XCTUnwrap(zoom.children.compactMap { $0 as? UIAction }.last)
        try await assertLandscapeThroughoutPresentation(window: window, scene: scene)
        interaction.dismissMenu()
        try await waitUntil { button.presentedMenu == nil && host.presentedViewController == nil }
        let action = UIButton(type: .system)
        action.addAction(custom, for: .primaryActionTriggered)
        action.sendActions(for: .primaryActionTriggered)
        try await waitUntil { host.presentedViewController != nil }
        XCTAssertEqual(state.zoom.settings.mode, .custom)
        try await assertLandscapeThroughoutPresentation(window: window, scene: scene)
        state.customZoom = false
        try await waitUntil { host.presentedViewController == nil }
        XCTAssertEqual(PlozziOSWindowOrientation.supportedOrientations(for: window), .landscape)
        state.livePlayback = false
        try await waitUntil {
            PlozziOSWindowOrientation.supportedOrientations(for: window) == .portrait
                && scene.effectiveGeometry.interfaceOrientation == .portrait
        }
    }

    @MainActor @Observable final class State {
        let zoom = PlayerVideoZoomModel()
        var seconds = 0
        var builds = 0
        var presentations: [Bool] = []
        var livePlayback = false
        var customZoom = false
    }

    private struct MenuHost: View {
        let state: State
        var body: some View {
            VStack {
                Text(verbatim: "\(state.seconds)")
                PlayerOptionsMenuButton(
                    makeMenu: {
                        state.builds += 1
                        return UIMenu(children: [PlayerZoomMenu.make(
                            model: state.zoom, locale: Locale(identifier: "en-US"),
                            onCustomZoom: { state.customZoom = true }
                        )])
                    },
                    onPresentationChange: { state.presentations.append($0) }
                )
                .frame(width: 44, height: 44)
            }
            .plozziOSLivePlayerOrientation(isPresented: state.livePlayback, orientation: .landscape)
            .plozzSheet(isPresented: Binding(get: { state.customZoom }, set: { state.customZoom = $0 })) {
                PlayerZoomSettingsSheet(model: state.zoom)
            }
        }
    }

    private func button(in view: UIView) -> PlayerOptionsMenuControl? {
        if let button = view as? PlayerOptionsMenuControl { return button }
        return view.subviews.lazy.compactMap { self.button(in: $0) }.first
    }

    private func assertLandscapeThroughoutPresentation(
        window: UIWindow, scene: UIWindowScene, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        var masks: Set<UInt> = []
        var stayedLandscape = true
        for _ in 0..<20 {
            masks.insert(PlozziOSWindowOrientation.supportedOrientations(for: window).rawValue)
            stayedLandscape = stayedLandscape && scene.effectiveGeometry.interfaceOrientation.isLandscape
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(masks, [UIInterfaceOrientationMask.landscape.rawValue], file: file, line: line)
        XCTAssertTrue(stayedLandscape, file: file, line: line)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Native zoom menu did not reach its expected state.")
    }
}
#endif
