import CoreModels
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS
@testable import PlozziOSPresentationHost

final class PlayerOrientationTestWindow: UIWindow, PresentationOrientationWindow {
    var supportedPresentationOrientations: UIInterfaceOrientationMask {
        PlozziOSWindowOrientation.supportedOrientations(for: self)
    }
}

@MainActor
final class PlayerOrientationTests: XCTestCase {
    func testPhoneBrowsingIsPortraitWhileIPadKeepsAllOrientations() {
        XCTAssertEqual(PlozziOSWindowOrientation.browsingMask(for: .phone), .portrait)
        XCTAssertEqual(PlozziOSWindowOrientation.browsingMask(for: .pad), .all)
    }

    func testAutoRotationReturnsOnlyAutomaticallyExpandedPlaybackToTheGuide() {
        var policy = PlozziOSLiveRotationPolicy()
        XCTAssertEqual(policy.effectivePreference(.auto, isPresented: false, canExpand: true), .auto)
        XCTAssertEqual(policy.interfaceChanged(.landscapeLeft, preference: .auto,
                                              isPresented: false, canExpand: true), .expand)
        XCTAssertEqual(policy.interfaceChanged(.portrait, preference: .auto,
                                              isPresented: true, canExpand: false), .returnToGuide)
        XCTAssertFalse(policy.automaticallyExpanded)
        XCTAssertNil(policy.interfaceChanged(.portrait, preference: .auto,
                                             isPresented: true, canExpand: false),
                     "Manually opened fullscreen stays fullscreen when rotated upright.")
    }

    func testClosingSidewaysWaitsForPhysicalUprightNotForcedPortrait() {
        var policy = PlozziOSLiveRotationPolicy()
        policy.closed(interface: .landscapeLeft, device: .landscapeRight)
        XCTAssertEqual(policy.effectivePreference(.auto, isPresented: false, canExpand: true), .portrait)
        XCTAssertNil(policy.interfaceChanged(.portrait, preference: .auto, isPresented: false, canExpand: true))
        policy.deviceChanged(.landscapeLeft)
        XCTAssertTrue(policy.awaitsUpright)
        XCTAssertNil(policy.interfaceChanged(.landscapeRight, preference: .auto, isPresented: false, canExpand: true))
        policy.deviceChanged(.portrait)
        XCTAssertFalse(policy.awaitsUpright)
        XCTAssertEqual(policy.interfaceChanged(.landscapeRight, preference: .auto,
                                              isPresented: false, canExpand: true), .expand)
    }

    func testUnavailablePreviewAndFixedPreferencesNeverAutoExpand() {
        var policy = PlozziOSLiveRotationPolicy()
        policy.deviceChanged(.landscapeLeft)
        XCTAssertFalse(policy.automaticallyExpanded, "Physical motion alone must not bypass system rotation lock.")
        XCTAssertEqual(policy.effectivePreference(.auto, isPresented: false, canExpand: false), .portrait)
        XCTAssertNil(policy.interfaceChanged(.landscapeLeft, preference: .auto, isPresented: false, canExpand: false))
        for preference in [PlaybackOrientation.portrait, .landscape] {
            XCTAssertEqual(policy.effectivePreference(preference, isPresented: false, canExpand: true), .portrait)
            XCTAssertNil(policy.interfaceChanged(.landscapeLeft, preference: preference, isPresented: false, canExpand: true))
            XCTAssertEqual(policy.effectivePreference(preference, isPresented: true, canExpand: true), preference)
        }
    }

    func testPrePlayCoverStaysPortraitUntilPlaybackStarts() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = PlayerOrientationTestWindow(windowScene: scene)
        let anchor = PlozziOSPlayerPresentation<Color>.Anchor()
        let coordinator = PlozziOSPlayerPresentation<Color>.Coordinator()
        coordinator.anchor = anchor
        coordinator.preference = .landscape
        coordinator.makeContent = { _, _ in AnyView(Color.black) }
        window.rootViewController = anchor
        window.makeKeyAndVisible()
        defer {
            coordinator.host?.tearDown()
            anchor.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { scene.activationState == .foregroundActive }

        for startsPlayback in [false, true] {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            try await waitUntil { scene.effectiveGeometry.interfaceOrientation == .portrait }
            coordinator.request = PlayerCloseProbe.makeRequest()
            coordinator.reconcile()
            try await waitUntil { coordinator.host?.orientation.isAvailable == true }
            let player = try XCTUnwrap(coordinator.host)
            try await waitUntil { player.transitionCoordinator == nil }
            XCTAssertFalse(player.orientation.isPlaybackActive)
            XCTAssertEqual(player.preferredInterfaceOrientationForPresentation, .portrait)
            XCTAssertEqual(player.supportedInterfaceOrientations, .portrait)
            XCTAssertEqual(scene.effectiveGeometry.interfaceOrientation, .portrait)

            if startsPlayback {
                player.orientation.beginPlayback()
                try await waitUntil(diagnostics: { self.orientationState(anchor, window, scene) }) {
                    player.supportedInterfaceOrientations == .landscape
                        && scene.effectiveGeometry.interfaceOrientation.isLandscape
                }
            }
            player.orientation.close()
            try await waitUntil { coordinator.host == nil && anchor.presentedViewController == nil }
            if !startsPlayback {
                XCTAssertEqual(scene.effectiveGeometry.interfaceOrientation, .portrait, "Cancelling a pre-play choice must not rotate.")
            }
        }
    }

    func testPrePlayPreferenceUpdatesDoNotActivateRotation() {
        let orientation = PlozziOSPlayerOrientation(preference: .landscape, isPlaybackActive: false)
        orientation.updateAvailability(true)
        XCTAssertEqual(orientation.requestedMask, .portrait)
        XCTAssertEqual(orientation.supportedMask, .portrait)
        orientation.updatePreference(.portrait)
        XCTAssertEqual(orientation.supportedMask, .portrait)
        orientation.beginPlayback()
        XCTAssertEqual(orientation.supportedMask, .portrait)
    }

    func testPlaybackWaitsForNativePrePlaySheetDismissal() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = PlayerOrientationTestWindow(windowScene: scene)
        let anchor = PlozziOSPlayerPresentation<Color>.Anchor()
        let coordinator = PlozziOSPlayerPresentation<Color>.Coordinator()
        coordinator.anchor = anchor
        coordinator.preference = .landscape
        coordinator.makeContent = { _, _ in AnyView(Color.black) }
        window.rootViewController = anchor
        window.makeKeyAndVisible()
        defer {
            coordinator.host?.tearDown()
            anchor.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { scene.activationState == .foregroundActive }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await waitUntil { scene.effectiveGeometry.interfaceOrientation == .portrait }
        coordinator.request = PlayerCloseProbe.makeRequest()
        coordinator.reconcile()
        try await waitUntil { coordinator.host?.orientation.isAvailable == true }
        let player = try XCTUnwrap(coordinator.host)
        try await waitUntil { player.transitionCoordinator == nil }
        let picker = PortraitPrePlayController(rootView: Color.gray)
        picker.modalPresentationStyle = .pageSheet
        await withCheckedContinuation { continuation in
            player.present(picker, animated: true) { continuation.resume() }
        }

        // Selection resumes preparation before SwiftUI commits the sheet dismissal.
        player.orientation.beginPlayback()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(scene.effectiveGeometry.interfaceOrientation, .portrait)
        XCTAssertFalse(player.orientation.hasGeometryRequestFailed)
        XCTAssertEqual(player.orientation.supportedMask, .landscape)
        XCTAssertEqual(player.supportedInterfaceOrientations, .all)
        await withCheckedContinuation { continuation in
            picker.dismiss(animated: true) { continuation.resume() }
        }
        try await waitUntil(diagnostics: { self.orientationState(player, window, scene) }) {
            scene.effectiveGeometry.interfaceOrientation.isLandscape
        }
        XCTAssertFalse(player.orientation.hasGeometryRequestFailed)
    }

    func testGeometryRejectionRetriesAreBoundedAndStaleFailuresAreIgnored() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = PlayerOrientationTestWindow(windowScene: scene)
        let anchor = UIViewController()
        window.rootViewController = anchor
        window.makeKeyAndVisible()
        defer {
            (anchor.presentedViewController as? PlozziOSOrientationHostingController)?.tearDown()
            anchor.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { scene.activationState == .foregroundActive }
        for rejectsPermanently in [false, true] {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            try await waitUntil { scene.effectiveGeometry.interfaceOrientation == .portrait }
            var requests = 0
            // UIKit may rotate from mask invalidation alone; control both sides of the rejected request.
            var reportedOrientation = UIInterfaceOrientation.portrait
            var delayedFailure: (@MainActor (Error) -> Void)?
            let orientation = PlozziOSPlayerOrientation(preference: .landscape, isPlaybackActive: false)
            let player = PlozziOSOrientationHostingController(
                rootView: AnyView(Color.black), orientation: orientation,
                currentInterfaceOrientation: { _ in reportedOrientation },
                requestGeometry: { _, _, onError in
                    requests += 1
                    delayedFailure = onError
                    if requests == 1 || rejectsPermanently {
                        onError(NSError(domain: "orientation-test", code: 101))
                    } else {
                        reportedOrientation = .landscapeRight
                    }
                }
            )
            await withCheckedContinuation { continuation in
                anchor.present(player, animated: true) { continuation.resume() }
            }
            orientation.beginPlayback()
            if rejectsPermanently {
                try await waitUntil { requests == 3 && orientation.hasGeometryRequestFailed }
                try await Task.sleep(for: .milliseconds(350))
                XCTAssertEqual(requests, 3, "Rejected geometry must not create an unbounded retry loop.")
                XCTAssertEqual(orientation.supportedMask, .landscape)
            } else {
                try await waitUntil {
                    reportedOrientation.isLandscape && !orientation.hasGeometryRequestFailed
                }
                XCTAssertEqual(requests, 2)
            }
            player.tearDown()
            orientation.clearGeometryFailure()
            delayedFailure?(NSError(domain: "stale-orientation-test", code: 101))
            XCTAssertFalse(orientation.hasGeometryRequestFailed, "A dismissed host must ignore late failures.")
            await withCheckedContinuation { continuation in
                player.dismiss(animated: false) { continuation.resume() }
            }
        }
    }

    func testLiveExpansionRotatesAndCollapseRestoresWithoutRecreatingContent() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = PlayerOrientationTestWindow(windowScene: scene)
        let probe = LiveOrientationProbe()
        let host = UIHostingController(rootView: LiveOrientationFixture(probe: probe))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { probe.appearances == 1 && scene.activationState == .foregroundActive }

        for (preference, guideMask, playerMask) in [
            (PlaybackOrientation.landscape, UIInterfaceOrientationMask.portrait, UIInterfaceOrientationMask.landscape),
            (.portrait, .portrait, .portrait)
        ] {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: guideMask))
            try await waitUntil {
                guard let mask = PlozziOSPlayerOrientation.mask(for: scene.effectiveGeometry.interfaceOrientation)
                else { return false }
                return !guideMask.intersection(mask).isEmpty
            }
            let preceding = scene.effectiveGeometry.interfaceOrientation
            host.rootView = LiveOrientationFixture(probe: probe, expanded: true, preference: preference)
            try await waitUntil(diagnostics: { self.orientationState(host, window, scene) }) {
                guard let mask = PlozziOSPlayerOrientation.mask(for: scene.effectiveGeometry.interfaceOrientation)
                else { return false }
                return PlozziOSWindowOrientation.supportedOrientations(for: window) == playerMask
                    && !playerMask.intersection(mask).isEmpty
            }
            XCTAssertNil(host.presentedViewController, "Live playback must remain in place, not open a second player.")
            XCTAssertEqual(probe.appearances, 1)
            XCTAssertEqual(probe.attachments, 1)
            XCTAssertEqual(probe.disappearances, 0)

            host.rootView = LiveOrientationFixture(probe: probe, expanded: false, preference: preference)
            try await waitUntil {
                PlozziOSWindowOrientation.supportedOrientations(for: window) == .portrait
                    && scene.effectiveGeometry.interfaceOrientation == preceding
            }
            XCTAssertEqual(probe.appearances, 1)
            XCTAssertEqual(probe.attachments, 1)
            XCTAssertEqual(probe.disappearances, 0)
        }
    }

    func testLiveAutoAndPreferenceChangesUseTheExistingContent() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = PlayerOrientationTestWindow(windowScene: scene)
        let probe = LiveOrientationProbe()
        let host = UIHostingController(rootView: LiveOrientationFixture(probe: probe, expanded: true, preference: .auto))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { probe.appearances == 1 }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await waitUntil { scene.effectiveGeometry.interfaceOrientation == .portrait }
        XCTAssertEqual(PlozziOSWindowOrientation.supportedOrientations(for: window), .all)

        host.rootView = LiveOrientationFixture(probe: probe, expanded: true, preference: .landscape)
        try await waitUntil(diagnostics: { self.orientationState(host, window, scene) }) {
            PlozziOSWindowOrientation.supportedOrientations(for: window) == .landscape
                && scene.effectiveGeometry.interfaceOrientation.isLandscape
        }
        host.rootView = LiveOrientationFixture(probe: probe, expanded: true, preference: .auto)
        try await waitUntil { PlozziOSWindowOrientation.supportedOrientations(for: window) == .all }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await waitUntil { scene.effectiveGeometry.interfaceOrientation == .portrait }
        XCTAssertEqual(probe.appearances, 1)
        XCTAssertEqual(probe.attachments, 1)
        XCTAssertEqual(probe.disappearances, 0)
    }

    func testCoveringEmbeddedLiveOwnerDoesNotReleaseItsOrientation() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = PlayerOrientationTestWindow(windowScene: scene)
        let root = UIViewController()
        let player = PlozziOSOrientationHostingController(
            rootView: AnyView(Color.black), orientation: .init(preference: .landscape),
            ownsWindowOrientation: true
        )
        root.addChild(player)
        root.view.addSubview(player.view)
        player.view.frame = root.view.bounds
        player.didMove(toParent: root)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            player.tearDown()
            root.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil {
            PlozziOSWindowOrientation.supportedOrientations(for: window) == .landscape
                && scene.effectiveGeometry.interfaceOrientation.isLandscape
        }
        let controls = UIHostingController(rootView: Color.gray)
        controls.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            root.present(controls, animated: true) { continuation.resume() }
        }
        XCTAssertNil(player.view.window, "The native cover must have completed the embedded owner's disappearance.")
        XCTAssertTrue(player.orientation.host === player)
        XCTAssertEqual(PlozziOSWindowOrientation.supportedOrientations(for: window), .landscape)

        player.willMove(toParent: nil)
        player.view.removeFromSuperview()
        player.removeFromParent()
        player.tearDown()
        XCTAssertEqual(PlozziOSWindowOrientation.supportedOrientations(for: window), .portrait)
        await withCheckedContinuation { continuation in
            controls.dismiss(animated: true) { continuation.resume() }
        }
        XCTAssertNil(player.orientation.host)
        XCTAssertEqual(PlozziOSWindowOrientation.supportedOrientations(for: window), .portrait)
    }

    func testWindowOwnershipIsIsolatedAndOldOwnersCannotReleaseReplacements() {
        let window = UIWindow()
        let otherWindow = UIWindow()
        let old = PlozziOSOrientationHostingController(
            rootView: AnyView(Color.clear), orientation: .init(preference: .portrait), ownsWindowOrientation: true
        )
        let replacement = PlozziOSOrientationHostingController(
            rootView: AnyView(Color.clear), orientation: .init(preference: .landscape), ownsWindowOrientation: true
        )
        old.orientation.updateAvailability(true)
        replacement.orientation.updateAvailability(true)
        PlozziOSWindowOrientation.acquire(old, for: window)
        XCTAssertEqual(PlozziOSWindowOrientation.supportedOrientations(for: window), .portrait)
        let browsingMask = PlozziOSWindowOrientation.browsingMask(for: UIDevice.current.userInterfaceIdiom)
        XCTAssertEqual(PlozziOSWindowOrientation.supportedOrientations(for: otherWindow), browsingMask)
        PlozziOSWindowOrientation.acquire(replacement, for: window)
        XCTAssertFalse(PlozziOSWindowOrientation.release(old, for: window))
        XCTAssertEqual(PlozziOSWindowOrientation.supportedOrientations(for: window), .landscape)
        XCTAssertTrue(PlozziOSWindowOrientation.release(replacement, for: window))
        XCTAssertEqual(PlozziOSWindowOrientation.supportedOrientations(for: window), browsingMask)
        XCTAssertEqual(PlozziOSWindowOrientation.supportedOrientations(for: nil), .all)
    }

    func testOldControllerTeardownPreservesReplacementHost() {
        let orientation = PlozziOSPlayerOrientation(preference: .portrait)
        let old = PlozziOSOrientationHostingController(rootView: AnyView(Color.clear), orientation: orientation)
        let replacement = PlozziOSOrientationHostingController(rootView: AnyView(Color.clear), orientation: orientation)
        old.tearDown()
        XCTAssertTrue(orientation.host === replacement)
        replacement.tearDown()
        XCTAssertNil(orientation.host)
    }

    private func orientationState(_ host: UIViewController, _ window: UIWindow, _ scene: UIWindowScene) -> String {
        func describe(_ controller: UIViewController) -> String {
            let state = (controller as? PlozziOSOrientationHostingController).map {
                "available=\($0.orientation.isAvailable) mask=\($0.orientation.supportedMask.rawValue) failed=\($0.orientation.hasGeometryRequestFailed) window=\($0.view.window != nil)"
            } ?? ""
            return "\(type(of: controller)) [\(state)] children: \(controller.children.map(describe))"
        }
        return "window=\(window.bounds) screen=\(window.screen.bounds) scene=\(scene.effectiveGeometry.interfaceOrientation.rawValue) mask=\(PlozziOSWindowOrientation.supportedOrientations(for: window).rawValue) applicationMask=\(UIApplication.shared.supportedInterfaceOrientations(for: window).rawValue) rootMask=\(host.supportedInterfaceOrientations.rawValue) \(describe(host))"
    }

    private func waitUntil(
        diagnostics: () -> String = { "" }, _ condition: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "The native orientation/lifecycle transition did not complete. \(diagnostics())", file: file, line: line)
    }

    func testCloseDismissesOwnedControllerWithoutAnotherPresenterUpdate() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = PlayerOrientationTestWindow(windowScene: scene)
        let anchor = PlozziOSPlayerPresentation<Color>.Anchor()
        let coordinator = PlozziOSPlayerPresentation<Color>.Coordinator()
        var request: PlozziOSPlaybackRequest? = PlayerCloseProbe.makeRequest()
        var disappearances = 0
        coordinator.anchor = anchor
        coordinator.request = request
        coordinator.makeContent = { _, _ in AnyView(Color.black.onDisappear { disappearances += 1 }) }
        coordinator.clearRequest = { id in
            if request?.id == id { request = nil }
        }
        window.rootViewController = anchor
        window.makeKeyAndVisible()
        defer {
            anchor.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        coordinator.reconcile()
        try await Task.sleep(for: .milliseconds(500))
        let player = try XCTUnwrap(coordinator.host)
        XCTAssertTrue(anchor.presentedViewController === player)
        player.orientation.close()
        XCTAssertNil(request, "The parent's request is cleared.")
        let deadline = ContinuousClock.now + .seconds(2)
        while (coordinator.host != nil || disappearances < 1), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertNil(coordinator.host, "Close must dismiss UIKit without waiting for an offscreen SwiftUI update.")
        XCTAssertNil(anchor.presentedViewController)
        XCTAssertNil(player.orientation.host)
        XCTAssertEqual(disappearances, 1, "Dismissal must run the player's cleanup lifecycle.")
        guard coordinator.host == nil else { return }

        request = PlayerCloseProbe.makeRequest()
        coordinator.request = request
        coordinator.reconcile()
        try await Task.sleep(for: .milliseconds(500))
        let replacement = try XCTUnwrap(coordinator.host)
        let replacementID = request?.id
        player.orientation.close()
        XCTAssertEqual(request?.id, replacementID)
        XCTAssertTrue(coordinator.host === replacement, "A stale X must not dismiss the replacement player.")
        replacement.orientation.close()
        let replacementDeadline = ContinuousClock.now + .seconds(2)
        while (coordinator.host != nil || disappearances < 2), ContinuousClock.now < replacementDeadline {
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertNil(coordinator.host)
        XCTAssertEqual(disappearances, 2)
    }

    func testCloseDoesNotDependOnPresentingViewUpdatesAndAllowsReopening() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let probe = PlayerCloseProbe()
        let host = UIHostingController(rootView: PlayerCloseFixture(probe: probe))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while (probe.appearances == 0 || host.presentedViewController != nil || probe.orientation?.host != nil),
              ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertGreaterThan(probe.appearances, 0, "The real UIKit cover must have appeared.")
        XCTAssertNil(probe.request, "Close must clear the request.")
        XCTAssertNil(host.presentedViewController, "An early close must not be lost during the presentation animation.")
        XCTAssertNil(probe.orientation?.host, "Close must release the player's presentation owner.")
        guard host.presentedViewController == nil, probe.orientation?.host == nil else { return }

        let oldOrientation = probe.orientation
        probe.closesOnAppear = false
        probe.request = PlayerCloseProbe.makeRequest()
        host.rootView = PlayerCloseFixture(probe: probe, generation: 1)
        let reopenDeadline = ContinuousClock.now + .seconds(3)
        while (host.presentedViewController == nil || probe.appearances < 2), ContinuousClock.now < reopenDeadline {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertNotNil(host.presentedViewController, "Closing must not prevent another player from opening.")
        XCTAssertEqual(probe.appearances, 2)
        try await Task.sleep(for: .milliseconds(400))
        let reopenedRequest = probe.request?.id
        oldOrientation?.close()
        XCTAssertEqual(probe.request?.id, reopenedRequest, "An old close action must not clear a newer player.")
        XCTAssertNotNil(host.presentedViewController)
        probe.orientation?.close()
        let closeDeadline = ContinuousClock.now + .seconds(3)
        while host.presentedViewController != nil, ContinuousClock.now < closeDeadline {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertNil(host.presentedViewController)
    }

    func testPreferencesAndCurrentOrientationMasksAreDifferent() {
        XCTAssertEqual(PlozziOSPlayerOrientation.mask(for: .auto), .all)
        XCTAssertEqual(PlozziOSPlayerOrientation.mask(for: PlaybackOrientation.landscape), .landscape)
        XCTAssertEqual(PlozziOSPlayerOrientation.mask(for: PlaybackOrientation.portrait), .portrait)
        for orientation in [UIInterfaceOrientation.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight] {
            let mask = PlozziOSPlayerOrientation.mask(for: orientation)
            XCTAssertEqual(mask?.rawValue, 1 << orientation.rawValue)
        }

        XCTAssertNil(PlozziOSPlayerOrientation.mask(for: UIInterfaceOrientation.unknown))
    }

    func testIPadsAndWindowedPresentationsStayAutomatic() {
        let screen = CGSize(width: 1024, height: 1366)
        XCTAssertFalse(PlozziOSPlayerOrientation.supportsPreference(
            idiom: .pad, windowSize: screen, screenSize: screen
        ))
        XCTAssertFalse(PlozziOSPlayerOrientation.supportsPreference(
            idiom: .pad, windowSize: CGSize(width: 500, height: 1366), screenSize: screen
        ))
        XCTAssertFalse(PlozziOSPlayerOrientation.supportsPreference(
            idiom: .phone, windowSize: CGSize(width: 500, height: 1366), screenSize: screen
        ))
        XCTAssertFalse(PlozziOSPlayerOrientation.supportsPreference(
            idiom: .phone,
            windowSize: CGSize(width: 1366, height: 1024), screenSize: screen
        ))
        XCTAssertFalse(PlozziOSPlayerOrientation.supportsPreference(
            idiom: .phone, windowSize: screen, screenSize: screen
        ))
        let compact = CGSize(width: 402, height: 874)
        XCTAssertTrue(PlozziOSPlayerOrientation.supportsPreference(
            idiom: .phone, windowSize: compact, screenSize: compact
        ))
        XCTAssertTrue(PlozziOSPlayerOrientation.supportsPreference(
            idiom: .phone, windowSize: CGSize(width: compact.height, height: compact.width), screenSize: compact
        ))
        XCTAssertEqual(PlozziOSWindowOrientation.browsingMask(for: .phone, windowSize: screen), .all)
        XCTAssertEqual(PlozziOSWindowOrientation.browsingMask(for: .phone, windowSize: compact), .portrait)
    }

    func testWindowedModeSuspendsPreferenceButGeometryFailureDoesNotAbandonIt() {
        let orientation = PlozziOSPlayerOrientation(preference: .landscape)
        XCTAssertEqual(orientation.supportedMask, .all)
        orientation.updateAvailability(true)
        XCTAssertEqual(orientation.supportedMask, .landscape)
        orientation.updateAvailability(false)
        XCTAssertEqual(orientation.supportedMask, .all)
        XCTAssertEqual(orientation.preference, .landscape)
        orientation.updateAvailability(true)
        orientation.geometryRequestFailed(NSError(domain: "orientation-test", code: 1))
        XCTAssertEqual(orientation.supportedMask, .landscape)
        XCTAssertEqual(orientation.preference, .landscape)
        XCTAssertTrue(orientation.hasGeometryRequestFailed)
        orientation.clearGeometryFailure()
        XCTAssertFalse(orientation.hasGeometryRequestFailed)
        XCTAssertFalse(PlozziOSPlayerOrientation(preference: .landscape).hasGeometryRequestFailed)
    }

    func testHostingControllerReleasesOrientationOwnershipOnTeardown() {
        let orientation = PlozziOSPlayerOrientation(preference: .portrait)
        let host = PlozziOSOrientationHostingController(rootView: AnyView(Color.black), orientation: orientation)
        orientation.updateAvailability(true)
        XCTAssertTrue(orientation.host === host)
        XCTAssertEqual(host.supportedInterfaceOrientations, .portrait)
        host.tearDown()
        XCTAssertNil(orientation.host)
    }
}

private final class PortraitPrePlayController: UIHostingController<Color> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
}

@MainActor
private final class LiveOrientationProbe {
    var appearances = 0
    var attachments = 0
    var disappearances = 0
}

private struct LiveOrientationFixture: View {
    let probe: LiveOrientationProbe
    var expanded = false
    var preference: PlaybackOrientation = .landscape

    var body: some View {
        Color.black
            .background(PlayerCloseAttachment { probe.attachments += 1 })
            .onAppear { probe.appearances += 1 }
            .onDisappear { probe.disappearances += 1 }
            .plozziOSLivePlayerOrientation(isPresented: expanded, orientation: preference)
    }
}

@MainActor
private final class PlayerCloseProbe {
    var request: PlozziOSPlaybackRequest? = makeRequest()
    var orientation: PlozziOSPlayerOrientation?
    var appearances = 0
    var closesOnAppear = true

    static func makeRequest() -> PlozziOSPlaybackRequest {
        .init(
            item: .init(id: "close-fixture", title: "Fixture", kind: .movie),
            startPosition: 0, versionPreferences: VersionPreferenceStore(namespace: "close-fixture")
        )
    }
}

private struct PlayerCloseFixture: View {
    let probe: PlayerCloseProbe
    var generation = 0

    var body: some View {
        Text("Presenter \(generation)")
            .plozziOSPlayerCover(item: Binding(
                get: { probe.request }, set: { probe.request = $0 }
            ), orientation: .auto) { _, orientation in
                Color.black
                    .background(PlayerCloseAttachment {
                        probe.orientation = orientation
                        probe.appearances += 1
                        if probe.closesOnAppear { orientation.close() }
                    })
            }
    }
}

private struct PlayerCloseAttachment: UIViewRepresentable {
    let attached: () -> Void

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.attached = attached
        return view
    }

    func updateUIView(_ view: AttachmentView, context: Context) {}

    final class AttachmentView: UIView {
        var attached: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, let attached else { return }
            self.attached = nil
            attached()
        }
    }
}
