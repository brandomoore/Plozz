@testable import AppShell
import CoreModels
@testable import CoreUI
import Observation
import SwiftUI
import UIKit
import TVUIKit
import XCTest

@MainActor
final class PinnedChromeTransitionHostedTests: XCTestCase {
    func testExplicitTitleNavigationCanUseHomeWithoutChangingHiddenNavigationPreferences() {
        let configured: [NavigationRailDestination] = [.liveTV, .settings]
        XCTAssertEqual(MainTabView.includingTitleHome(configured, isRequested: false), configured)
        XCTAssertEqual(MainTabView.includingTitleHome(configured, isRequested: true), [.home, .liveTV, .settings])
        XCTAssertEqual(
            MainTabView.includingTitleHome([.settings, .home], isRequested: true), [.settings, .home]
        )
        XCTAssertEqual(configured, [.liveTV, .settings])
    }

    func testReturningRailHasNoNativeFocusTargetsUntilInputIsReleased() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.interaction?.requestOpen()
        try await waitUntil { !self.targets(in: fixture.window).isEmpty }
        let guardView = DetailTransitionNavigation.installInputGuard(in: fixture.window, phase: .returning)
        try await waitUntil { self.targets(in: fixture.window).isEmpty }
        XCTAssertFalse(fixture.model.chrome.isChromeHidden, "The returning rail can draw without accepting focus.")
        XCTAssertFalse(markers(in: fixture.window).isEmpty)
        XCTAssertTrue(fixture.model.chrome.transitionSuppressesFocus)

        let press = HeldUp()
        guardView.pressesBegan([press], with: UIPressesEvent())
        guardView.releaseWhenIdle()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(targets(in: fixture.window).isEmpty, "Up must have no eligible rail target during the return.")
        guardView.pressesEnded([press], with: UIPressesEvent())
        try await waitUntil { !self.targets(in: fixture.window).isEmpty }
        XCTAssertFalse(fixture.model.chrome.transitionSuppressesFocus)
    }

    func testOpeningHidesTheRailBeforeDepthPublicationAndThroughDetailAppearance() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        try await waitUntil { !self.markers(in: fixture.window).isEmpty }
        let guardView = DetailTransitionNavigation.installInputGuard(in: fixture.window)
        try await waitUntil { self.markers(in: fixture.window).isEmpty }
        XCTAssertTrue(fixture.model.chrome.isChromeHidden)

        let session = TVDetailEntranceSession()
        defer { session.disappeared() }
        session.attach(to: fixture.window, enabled: true)
        fixture.model.chrome.setStackDepth(1)
        fixture.model.chrome.setStackDepth(0)
        guardView.invalidate()
        session.finishImmediately()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fixture.model.chrome.isChromeHidden, "A late zero-depth report must not reveal navigation on a detail page.")
        XCTAssertTrue(markers(in: fixture.window).isEmpty)

        session.pageDisappeared()
        try await waitUntil { !self.markers(in: fixture.window).isEmpty }
        XCTAssertFalse(fixture.model.chrome.isChromeHidden)
    }

    func testChangingAnOpeningGuardToReturnRestoresOnlyVisibility() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let guardView = DetailTransitionNavigation.installInputGuard(in: fixture.window)
        try await waitUntil { self.markers(in: fixture.window).isEmpty }
        guardView.setPhase(.returning)
        try await waitUntil { !self.markers(in: fixture.window).isEmpty }
        XCTAssertFalse(fixture.model.chrome.isChromeHidden)
        XCTAssertTrue(targets(in: fixture.window).isEmpty)
        guardView.invalidate()
        fixture.model.interaction?.requestOpen()
        try await waitUntil { !self.targets(in: fixture.window).isEmpty }
    }

    func testPinnedRailStartsClosedUntilExplicitEntry() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        XCTAssertTrue(targets(in: fixture.window).isEmpty)
        XCTAssertFalse(fixture.model.chrome.isChromeHidden)
        fixture.model.interaction?.requestOpen()
        try await waitUntil { !self.targets(in: fixture.window).isEmpty }
    }

    func testFreshLaunchStartsOnHomeWithoutResettingSameProcessNavigation() {
        for destination in [NavigationRailDestination.settings, .search, .music, .home] {
            XCTAssertEqual(
                MainTabView.launchDestination(stored: destination, recordedProcess: "old", currentProcess: "new"),
                .home
            )
            XCTAssertEqual(
                MainTabView.launchDestination(stored: destination, recordedProcess: "same", currentProcess: "same"),
                destination
            )
        }
    }

    func testRecreatedSourceUsesItemIdentityAndItsOriginalScrollContainer() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let controller = UIViewController()
        fixture.window.rootViewController = controller
        controller.view.frame = fixture.window.bounds
        let firstRow = UIScrollView(frame: CGRect(x: 100, y: 100, width: 800, height: 300))
        let secondRow = UIScrollView(frame: CGRect(x: 100, y: 500, width: 800, height: 300))
        controller.view.addSubview(firstRow)
        controller.view.addSubview(secondRow)
        let references = [firstRow, secondRow].map { row in
            let marker = DetailTransitionSourceView(frame: CGRect(x: 100, y: 20, width: 200, height: 250))
            row.addSubview(marker)
            let reference = DetailTransitionSourceReference()
            reference.view = marker
            reference.itemKey = "same-title"
            marker.reference = reference
            return reference
        }
        let secondFrame = try XCTUnwrap(references[1].visibleFrame(in: fixture.window))
        XCTAssertTrue(DetailTransitionSourceReference.liveSource(
            in: fixture.window, itemKey: "same-title", scrollContext: firstRow, near: secondFrame
        ) === references[0])
        XCTAssertTrue(DetailTransitionSourceReference.liveSource(
            in: fixture.window, itemKey: "same-title", scrollContext: nil, near: secondFrame
        ) === references[1])
        XCTAssertNil(DetailTransitionSourceReference.liveSource(
            in: fixture.window, itemKey: "same-title", scrollContext: nil, near: nil
        ))
        XCTAssertNil(DetailTransitionSourceReference.liveSource(
            in: fixture.window, itemKey: "removed-title", scrollContext: firstRow, near: secondFrame
        ))
        references[0].view?.isHidden = true
        XCTAssertNil(DetailTransitionSourceReference.liveSource(
            in: fixture.window, itemKey: "same-title", scrollContext: firstRow, near: secondFrame
        ))
    }

    func testRejectedNativeSourceFocusFallsBackToTheExplicitBinding() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let controller = FocusFallbackController()
        fixture.window.rootViewController = controller
        controller.view.layoutIfNeeded()
        try await waitUntil { controller.hero.isFocused }
        let marker = UIView(frame: controller.card.bounds)
        marker.isUserInteractionEnabled = false
        controller.card.addSubview(marker)
        let source = DetailTransitionSourceReference()
        source.view = controller.card
        source.nativeArtworkView = marker
        let requester = FocusFallbackRequester(controller: controller)
        source.focusRequester = requester
        source.restoreFocus(in: fixture.window, preferred: nil)
        try await waitUntil { controller.card.isFocused }
        XCTAssertEqual(requester.requests, 1)
    }

    func testClosingPageCannotReclaimChromeThroughALateAppearanceCallback() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let session = TVDetailEntranceSession()
        defer { session.disappeared() }
        session.attach(to: fixture.window, enabled: true)
        XCTAssertTrue(fixture.model.chrome.isChromeHidden)
        session.close {}
        session.pageAppeared()
        XCTAssertFalse(fixture.model.chrome.isChromeHidden)
        session.finishImmediately()
    }

    private func markers(in view: UIView) -> [NavigationRowFocusRequester.RequestView] {
        if let marker = view as? NavigationRowFocusRequester.RequestView { return [marker] }
        return view.subviews.flatMap { markers(in: $0) }
    }

    private func targets(in window: UIWindow) -> [any UIFocusItem] {
        markers(in: window).compactMap { NavigationRowFocusRequester.target(for: $0, in: window) }
    }

    private func makeFixture() async throws -> Fixture {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene)
        try await waitUntil {
            DetailTransitionNavigation.chromeModel(in: fixture.window) === fixture.model.chrome
                && fixture.model.interaction != nil
        }
        return fixture
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
        let window: UIWindow
        let previous: UIWindow?
        let model = Model()

        init(scene: UIWindowScene) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(rootView: RailFixture(model: model))
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func close() {
            for guardView in (window.gestureRecognizers ?? []).compactMap({ $0 as? DetailTransitionInputGuard }) {
                guardView.invalidate()
            }
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }

    @MainActor @Observable
    final class Model {
        let profile = Profile(name: "Viewer")
        let chrome = NavigationChromeModel()
        var selection = NavigationRailDestination.home
        @ObservationIgnored var interaction: PlozzPinnedSidebarInteraction?
    }

    private struct RailFixture: View {
        @Bindable var model: Model

        var body: some View {
            NavigationRailShell(
                profile: model.profile, entries: [], destinations: [.home, .search, .settings],
                selection: $model.selection, onOpenProfileSwitcher: {},
                chrome: model.chrome,
                content: PageContent(model: model),
                contentDestination: model.selection
            )
        }
    }

    private struct PageContent: View {
        let model: Model
        @Environment(\.plozzPinnedSidebarInteraction) private var interaction

        var body: some View {
            Button("Page content") {}
                .frame(width: 400, height: 100)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { model.interaction = interaction }
        }
    }

    private final class HeldUp: UIPress {
        override var type: UIPress.PressType { .upArrow }
    }

    private final class FocusFallbackController: UIViewController {
        let hero = UIButton(type: .system)
        let card = TVCardView()
        var allowsCardFocus = false
        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            [allowsCardFocus ? card : hero]
        }
        override func viewDidLoad() {
            super.viewDidLoad()
            hero.setTitle("Hero", for: .normal)
            hero.frame = CGRect(x: 700, y: 100, width: 300, height: 100)
            card.contentSize = CGSize(width: 260, height: 160)
            card.frame = CGRect(x: 700, y: 600, width: 300, height: 200)
            view.addSubview(hero)
            view.addSubview(card)
        }
        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            context.nextFocusedItem !== card || allowsCardFocus
        }
    }

    @MainActor
    private final class FocusFallbackRequester: DetailTransitionFocusRequesting {
        let controller: FocusFallbackController
        var requests = 0
        init(controller: FocusFallbackController) { self.controller = controller }
        func requestFocus() -> Bool {
            requests += 1
            controller.allowsCardFocus = true
            controller.setNeedsFocusUpdate()
            controller.updateFocusIfNeeded()
            return true
        }
    }
}
