@testable import AppShell
import CoreModels
@testable import CoreUI
@testable import FeatureHome
import Observation
import SwiftUI
import UIKit
import TVUIKit
import XCTest

@MainActor
final class PinnedChromeTransitionHostedTests: XCTestCase {
    func testExplicitHomeNavigationDoesNotChangeHiddenNavigationPreferences() {
        let configured: [NavigationRailDestination] = [.liveTV, .settings]
        XCTAssertEqual(MainTabView.includingExplicitHome(configured, isRequested: false), configured)
        XCTAssertEqual(MainTabView.includingExplicitHome(configured, isRequested: true), [.home, .liveTV, .settings])
        XCTAssertEqual(
            MainTabView.includingExplicitHome([.settings, .home], isRequested: true), [.settings, .home]
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

    func testPinnedExpansionPreservesRowVerticalPositions() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(300))
        let rows = markers(in: fixture.window).sorted {
            $0.convert($0.bounds, to: fixture.window).midY < $1.convert($1.bounds, to: fixture.window).midY
        }
        XCTAssertEqual(rows.count, 4)
        let frames = rows.map { $0.convert($0.bounds, to: fixture.window) }
        fixture.model.interaction?.requestOpen()
        try await waitUntil { !self.targets(in: fixture.window).isEmpty }
        try await Task.sleep(for: .milliseconds(350))
        for (row, initial) in zip(rows, frames) {
            let expanded = row.convert(row.bounds, to: fixture.window)
            XCTAssertEqual(expanded.midY, initial.midY, accuracy: 0.5)
            XCTAssertEqual(expanded.height, initial.height, accuracy: 0.5)
            XCTAssertGreaterThan(expanded.minX, initial.minX)
        }
    }

    func testOpeningLongRailDoesNotRecenterAnAlreadyVisibleSelection() async throws {
        let fixture = try await makeFixture(libraryCount: 20)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(300))
        let rows = markers(in: fixture.window).sorted {
            $0.convert($0.bounds, to: fixture.window).midY < $1.convert($1.bounds, to: fixture.window).midY
        }
        XCTAssertEqual(rows.count, 24)
        // Profile, Home, Search, then library 0 through library 19.
        let selected = try XCTUnwrap(rows.dropFirst(9).first)
        var ancestor = selected.superview
        while ancestor != nil, !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
        let scroll = try XCTUnwrap(ancestor as? UIScrollView)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + 100), animated: false)
        try await Task.sleep(for: .milliseconds(150))
        let before = selected.convert(selected.bounds, to: fixture.window)
        XCTAssertTrue(scroll.convert(scroll.bounds, to: fixture.window).contains(before))
        fixture.model.interaction?.requestOpen()
        try await waitUntil {
            guard let target = NavigationRowFocusRequester.target(for: selected, in: fixture.window) else { return false }
            return UIFocusSystem.focusSystem(for: fixture.window)?.focusedItem === target
        }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(selected.convert(selected.bounds, to: fixture.window).midY, before.midY, accuracy: 0.5)
    }

    func testLibraryFocusHostPropagatesEnabledChangesWithoutContentChanges() async throws {
        let fixture = try await makeFixture(hostedHeader: true)
        defer { fixture.close() }
        try await waitUntil { fixture.model.buttonEnabled }
        fixture.model.blocksContent = true
        try await waitUntil { !fixture.model.buttonEnabled }
        fixture.model.blocksContent = false
        try await waitUntil { fixture.model.buttonEnabled }
    }

    func testOpeningNavigationDoesNotReplaceTheHostedRoot() async throws {
        let fixture = try await makeFixture(hostedHeader: true)
        defer { fixture.close() }
        try await waitUntil { fixture.model.buttonEnabled }
        let marker = try XCTUnwrap(markers(in: fixture.window).first)
        let owner = try XCTUnwrap(NavigationRailFocusHostController.containing(marker))
        let updates = owner.rootUpdateCount
        fixture.model.interaction?.requestOpen()
        try await waitUntil { owner.isNavigationFocused }
        XCTAssertEqual(owner.rootUpdateCount, updates)
        XCTAssertTrue(fixture.model.buttonEnabled)

        fixture.model.seasonContext = "updated-profile"
        try await waitUntil { fixture.model.observedSeasonContext == "updated-profile" }
        XCTAssertGreaterThan(owner.rootUpdateCount, updates,
                             "Real environment updates must still reach hosted content.")
        XCTAssertTrue(owner.isNavigationFocused,
                      "An environment refresh must preserve the native owner's focus state.")
    }

    func testNestedHostsPreserveChangingSeasonAndThemeMusicContext() async throws {
        let fixture = try await makeFixture(hostedHeader: true)
        defer { fixture.close() }
        try await waitUntil { fixture.model.observedSeasonContext == "initial-profile" }
        XCTAssertEqual(fixture.model.observedMusicSettings, fixture.model.musicSettings)
        XCTAssertTrue(fixture.model.observedMusicController === fixture.model.musicController)
        fixture.model.seasonContext = "replacement-profile"
        fixture.model.musicSettings = .init(isEnabled: true, volume: .high)
        try await waitUntil {
            fixture.model.observedSeasonContext == "replacement-profile"
                && fixture.model.observedMusicSettings == fixture.model.musicSettings
        }
    }

    func testSidebarReturnRejectsUnavailableOriginalControls() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let controller = FocusFallbackController()
        fixture.window.rootViewController = controller
        controller.view.layoutIfNeeded()
        try await waitUntil { controller.hero.isFocused }
        let source = NavigationContentFocusRequester.ReturnFocus()
        source.marker = controller.view
        source.capture()
        XCTAssertTrue(source.target(relativeTo: controller.view) === controller.hero)

        controller.hero.isHidden = true
        XCTAssertNil(source.target(relativeTo: controller.view))
        controller.hero.isHidden = false
        controller.hero.isEnabled = false
        XCTAssertNil(source.target(relativeTo: controller.view))
        controller.hero.isEnabled = true
        XCTAssertTrue(source.target(relativeTo: controller.view) === controller.hero)
        controller.hero.removeFromSuperview()
        XCTAssertNil(source.target(relativeTo: controller.view))
        XCTAssertTrue(NavigationContentFocusRequester.firstTarget(
            in: fixture.window, relativeTo: controller.view, isRightToLeft: false
        ) === controller.card)

        controller.view.addSubview(controller.hero)
        source.clear()
        XCTAssertNil(source.target(relativeTo: controller.view))
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

    private func makeFixture(hostedHeader: Bool = false, libraryCount: Int = 0) async throws -> Fixture {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene, hostedHeader: hostedHeader, libraryCount: libraryCount)
        try await waitUntil {
            DetailTransitionNavigation.chromeModel(in: fixture.window) === fixture.model.chrome
                && fixture.model.interaction != nil
        }
        return fixture
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let previous: UIWindow?
        let model = Model()

        init(scene: UIWindowScene, hostedHeader: Bool, libraryCount: Int) {
            model.hostedHeader = hostedHeader
            model.entries = (0..<libraryCount).map { index in
                let library = AggregatedLibrary(
                    accountID: "fixture", accountName: "Fixture", serverName: "Fixture",
                    providerKind: .jellyfin,
                    library: MediaLibrary(id: "\(index)", title: "Library \(index)", kind: .movie)
                )
                return NavigationRailLibraryEntry(key: library.key, library: library)
            }
            if libraryCount > 6 { model.selection = model.entries[6].destination }
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
        var entries: [NavigationRailLibraryEntry] = []
        @ObservationIgnored var interaction: PlozzPinnedSidebarInteraction?
        @ObservationIgnored var buttonEnabled = false
        @ObservationIgnored var observedSeasonContext: String?
        @ObservationIgnored var observedMusicSettings: ThemeMusicSettings?
        @ObservationIgnored weak var observedMusicController: ThemeMusicController?
        let musicController = ThemeMusicController()
        var musicSettings = ThemeMusicSettings(isEnabled: true, volume: .low)
        var seasonContext = "initial-profile"
        var hostedHeader = false
        var blocksContent = false
        let scrollTarget = NativeLibraryScrollTarget()
    }

    private struct RailFixture: View {
        @Bindable var model: Model

        var body: some View {
            NavigationRailShell(
                profile: model.profile, entries: model.entries,
                destinations: [.home, .search] + model.entries.map(\.destination) + [.settings],
                selection: $model.selection, onOpenProfileSwitcher: {},
                chrome: model.chrome,
                content: PageContent(model: model),
                contentDestination: model.selection
            )
            .environment(\.seasonRequestContextID, model.seasonContext)
            .environment(\.themeMusicController, model.musicController)
            .environment(\.themeMusicSettings, model.musicSettings)
        }
    }

    private struct PageContent: View {
        let model: Model
        @Environment(\.plozzPinnedSidebarInteraction) private var interaction

        var body: some View {
            Group {
                if model.hostedHeader {
                    NativeLibraryFocusHost(
                        scrollTarget: model.scrollTarget,
                        content: NativeLibraryScrollingHeader(
                            scrollTarget: model.scrollTarget, content: ContentButton(model: model)
                        )
                        .background(HostedContextProbe(model: model))
                    )
                } else {
                    ContentButton(model: model)
                }
            }
            .disabled(model.blocksContent)
            .frame(width: 400, height: 100)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { model.interaction = interaction }
        }
    }

    private struct ContentButton: View {
        let model: Model
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button("Page content") {}
                .onChange(of: isEnabled, initial: true) { _, enabled in model.buttonEnabled = enabled }
        }
    }

    private struct HostedContextProbe: View {
        let model: Model
        @Environment(\.seasonRequestContextID) private var seasonContext
        @Environment(\.themeMusicController) private var musicController
        @Environment(\.themeMusicSettings) private var musicSettings

        var body: some View {
            Color.clear
                .onChange(of: seasonContext, initial: true) { _, value in
                    model.observedSeasonContext = value
                    model.observedMusicController = musicController
                }
                .onChange(of: musicSettings, initial: true) { _, value in
                    model.observedMusicSettings = value
                }
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
