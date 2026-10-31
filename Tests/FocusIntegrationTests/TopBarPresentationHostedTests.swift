#if os(tvOS)
import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import AppShell

@MainActor
final class TopBarPresentationHostedTests: XCTestCase {
    func testScrollOwnershipRejectsDepartedPagesAndResetsOnlyTheActiveRoot() {
        let scroll = TopNavigationScroll()
        let first = UUID()
        let second = UUID()
        var firstResets = 0
        var secondResets = 0
        scroll.register(source: first, offset: 90) { firstResets += 1 }
        scroll.register(source: second, offset: 250) { secondResets += 1 }
        scroll.update(offset: 900, source: first)
        scroll.unregister(source: first)
        XCTAssertEqual(scroll.offset, 250)
        XCTAssertTrue(scroll.scrollToTop())
        XCTAssertEqual(firstResets, 0)
        XCTAssertEqual(secondResets, 1)
        XCTAssertEqual(scroll.offset, 0)
        XCTAssertFalse(scroll.scrollToTop())
        scroll.update(offset: -30, source: second)
        XCTAssertEqual(scroll.offset, 0, "Top-edge bounce must not push the bar down.")
        scroll.update(offset: 180, source: second)
        scroll.unregister(source: second)
        XCTAssertEqual(scroll.offset, 0, "Non-scrolling destinations keep their navigation visible.")
        XCTAssertNil(EnvironmentValues().plozzTopNavigationScroll, "Sidebars do not own a scrolling top bar.")
    }

    func testScrollMovesOnlyTheBarAndKeepsOffscreenNavigationIneligible() async throws {
        let (window, previous) = try await makeWindow()
        let model = Model()
        model.selection = .settings
        window.rootViewController = UIHostingController(rootView: Fixture(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitForPage(.settings, model: model, window: window)
        try await Task.sleep(for: .milliseconds(350))
        let scroll = try XCTUnwrap(model.scroll)
        let source = UUID()
        scroll.register(source: source, offset: 0, scrollToTop: {})
        let marker = try XCTUnwrap(navigationMarkers(in: window).first)
        let initial = marker.convert(marker.bounds, to: window)
        let builds = model.contentBuilds
        for offset: CGFloat in [20, 60, 160, 600, 20, 0] {
            scroll.update(offset: offset, source: source)
            try await Task.sleep(for: .milliseconds(40))
            window.layoutIfNeeded()
            XCTAssertEqual(marker.convert(marker.bounds, to: window).minY, initial.minY - offset, accuracy: 0.5)
            XCTAssertEqual(model.contentBuilds, builds, "Scroll frames must not reconstruct page closures.")
            XCTAssertTrue(model.buttons[.settings]?.isFocused == true)
            if offset >= TopBarNavigationMetrics.foregroundTop {
                XCTAssertNil(NavigationRowFocusRequester.target(for: marker, in: window))
            }
        }
    }

    func testRapidAndSettledNativeFocusNeverChangesTheOpenPage() async throws {
        let (window, previous) = try await makeWindow()
        let model = Model()
        model.destinations = [.home, .watchlist, .liveTV, .search]
        let host = UIHostingController(rootView: Fixture(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        try await waitForPage(.home, model: model, window: window)
        let owner = try XCTUnwrap(find(NavigationRailFocusHostController.self, in: host))
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            window.layoutIfNeeded()
            window.setNeedsFocusUpdate()
            window.updateFocusIfNeeded()
            if system.focusedItem != nil, focusItems(in: window).count == model.destinations.count { break }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        func focus(_ index: Int) throws {
            let items = focusItems(in: window).sorted {
                $0.frame.midX < $1.frame.midX
            }
            XCTAssertEqual(items.count, model.destinations.count, "Only navigation is eligible during traversal.")
            let target = try XCTUnwrap(items.indices.contains(index) ? items[index] : nil)
            XCTAssertTrue(owner.requestFocus(to: target, using: system))
        }
        let builds = model.contentBuilds
        for index in [1, 2, 3, 2, 1, 3] {
            try focus(index)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(model.selection, .home, "Rapid movement must not construct intermediate pages.")
        }
        XCTAssertEqual(model.contentBuilds, builds, "Bar-only focus updates must not rebuild page closures.")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.selection, .home, "Settled focus must not open the highlighted page.")
        XCTAssertEqual(model.contentBuilds, builds)
        XCTAssertNil(model.buttons[.search])
        XCTAssertNil(model.buttons[.watchlist])
        XCTAssertNil(model.buttons[.liveTV])
        try focus(1)
        try await Task.sleep(for: .milliseconds(20))
        model.destinations.removeAll { $0 == .watchlist }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.selection, .home, "Removing a highlighted item must not change the open page.")
        XCTAssertNil(model.buttons[.watchlist])
    }

    func testOffscreenChromeHidesAndReturnsWithoutAnimation() async throws {
        let (window, previous) = try await makeWindow()
        let model = Model()
        model.selection = .settings
        window.rootViewController = UIHostingController(rootView: Fixture(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitForPage(.settings, model: model, window: window)
        try await Task.sleep(for: .milliseconds(350))
        let scroll = try XCTUnwrap(model.scroll)
        let source = UUID()
        scroll.register(source: source, offset: 600, scrollToTop: {})
        try await Task.sleep(for: .milliseconds(100))
        let marker = try XCTUnwrap(navigationMarkers(in: window).first)
        func presentedY() -> CGFloat {
            let layer = marker.layer.presentation() ?? marker.layer
            return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer).minY
        }
        let initial = presentedY()
        for depth in [1, 0] {
            model.chrome.setStackDepth(depth)
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(25))
                let travel: CGFloat = depth > 0 && !UIAccessibility.isReduceMotionEnabled ? 12 : 0
                XCTAssertEqual(presentedY(), initial - travel, accuracy: 0.5)
                XCTAssertEqual(scroll.offset, 600)
                XCTAssertNil(NavigationRowFocusRequester.target(for: marker, in: window))
            }
        }
    }

    func testLiftedSettingsMovementPersistsOnlyAfterAnActualStep() async throws {
        let (window, previous) = try await makeWindow()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = NavigationStyleSettingsModel(
            store: NavigationStyleSettingsStore(defaults: defaults),
            layoutStore: NavigationLibraryLayoutStore(defaults: defaults)
        )
        model.style = .tabBar
        let keys = [NavigationLibraryLayout.homeKey, NavigationLibraryLayout.settingsKey]
        let host = UIHostingController(rootView: ReorderFixture(model: model, keys: keys))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(300))
        func input(in controller: UIViewController) -> (any SettingsAdjustmentRemoteInput)? {
            if let input = controller as? any SettingsAdjustmentRemoteInput { return input }
            return controller.children.lazy.compactMap { input(in: $0) }.first
        }
        let remote = try XCTUnwrap(input(in: host))
        XCTAssertTrue(model.libraryLayout.pinsSettingsInTopBar)
        remote.beginPress(.down)
        remote.stopRepeating()
        XCTAssertTrue(model.libraryLayout.pinsSettingsInTopBar, "An end-of-list press is not movement.")
        remote.beginPress(.up)
        remote.stopRepeating()
        XCTAssertFalse(model.libraryLayout.pinsSettingsInTopBar)
        XCTAssertEqual(model.librarySections(available: keys).enabled, Array(keys.reversed()))
        remote.beginPress(.down)
        remote.stopRepeating()
        XCTAssertEqual(model.librarySections(available: keys).enabled, keys)
        XCTAssertFalse(model.libraryLayout.pinsSettingsInTopBar, "Moving Settings back must not repin it.")
    }

    func testHorizontalFocusOwnerAllowsLeftRightAndKeepsSidebarPolicyUnchanged() {
        let owner = NavigationRailFocusHostController()
        owner.isNavigationFocused = true
        XCTAssertFalse(owner.allowsFocusUpdate(heading: .right))
        XCTAssertTrue(owner.allowsFocusUpdate(heading: .down))
        owner.contentExitHeading = .down
        XCTAssertTrue(owner.allowsFocusUpdate(heading: .left))
        XCTAssertTrue(owner.allowsFocusUpdate(heading: .right))
        XCTAssertFalse(owner.allowsFocusUpdate(heading: .down))
        owner.isNavigationFocused = false
        XCTAssertTrue(owner.allowsFocusUpdate(heading: .down))
    }

    func testHorizontalSelectionMountsOnlyTheRequestedLibraryAndRetainsLiveTV() async throws {
        let (window, previous) = try await makeWindow()
        let model = Model()
        let host = UIHostingController(rootView: Fixture(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        let visits = [NavigationRailDestination.liveTV] + (1...20).map { .library("plex:\($0)") }
        for destination in visits {
            model.selection = destination
            try await waitForPage(destination, model: model, window: window)
            XCTAssertEqual(model.buttons[destination]?.title(for: .normal), destination.storageValue)
            for (other, button) in model.buttons where other != destination && other != .liveTV {
                XCTAssertNil(button.window, "Unselected library grids must not accumulate behind the strip.")
            }
            XCTAssertNil(find(UITabBarController.self, in: host), "Horizontal navigation must not start native tab transitions.")
        }
        let liveTV = try XCTUnwrap(model.buttons[.liveTV])
        model.selection = .liveTV
        try await waitForPage(.liveTV, model: model, window: window)
        XCTAssertTrue(model.buttons[.liveTV] === liveTV, "The guide must retain its state across library visits.")
    }

    func testSettingsReturnPreservesTheHorizontalFocusOwner() async throws {
        let (window, previous) = try await makeWindow()
        let model = Model()
        let host = UIHostingController(rootView: Fixture(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitForPage(.home, model: model, window: window)
        let owner = try XCTUnwrap(find(NavigationRailFocusHostController.self, in: host))
        for _ in 0..<3 {
            for destination in [NavigationRailDestination.settings, .watchlist, .liveTV, .home] {
                model.selection = destination
                window.layoutIfNeeded()
                try await waitForPage(destination, model: model, window: window)
                if destination == .settings {
                    let deadline = ContinuousClock.now + .seconds(5)
                    while model.buttons[.settings]?.isFocused != true, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    XCTAssertTrue(model.buttons[.settings]?.isFocused == true)
                    XCTAssertEqual(model.selection, .settings, "Settings must open even when hidden from navigation.")
                    XCTAssertFalse(owner.isNavigationFocused)
                }
                XCTAssertTrue(find(NavigationRailFocusHostController.self, in: host) === owner)
            }
        }
    }

    func testChromeExitDistanceRespectsReduceMotionAndPreservesContent() async throws {
        for reduceMotion in [false, true] {
            let (window, previous) = try await makeWindow()
            let model = Model()
            model.selection = .settings
            model.reduceMotion = reduceMotion
            window.rootViewController = UIHostingController(rootView: Fixture(model: model))
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            try await waitForPage(.settings, model: model, window: window)
            try await Task.sleep(for: .milliseconds(350))
            let marker = try XCTUnwrap(navigationMarkers(in: window).first)
            let initial = marker.convert(marker.bounds, to: window)
            let page = try XCTUnwrap(model.buttons[.settings])
            XCTAssertTrue(page.isFocused)

            model.chrome.setStackDepth(1)
            try await Task.sleep(for: .milliseconds(90))
            captureMotion(in: window, name: "Top bar exiting; reduced motion \(reduceMotion)")
            try await Task.sleep(for: .milliseconds(350))
            let hidden = marker.convert(marker.bounds, to: window)
            XCTAssertEqual(hidden.minY, initial.minY - (reduceMotion ? 0 : 12), accuracy: 0.5)
            XCTAssertNil(NavigationRowFocusRequester.target(for: marker, in: window))
            XCTAssertTrue(page.isFocused, "Hiding navigation must not interrupt the current page.")
            XCTAssertTrue(page.window === window)

            model.chrome.setStackDepth(0)
            try await Task.sleep(for: .milliseconds(90))
            captureMotion(in: window, name: "Top bar returning; reduced motion \(reduceMotion)")
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(marker.convert(marker.bounds, to: window).minY, initial.minY, accuracy: 0.5)
            XCTAssertTrue(page.isFocused, "Returning chrome must not steal focus.")
        }
    }

    private func navigationMarkers(in view: UIView) -> [NavigationRowFocusRequester.RequestView] {
        if let marker = view as? NavigationRowFocusRequester.RequestView { return [marker] }
        return view.subviews.flatMap { navigationMarkers(in: $0) }
    }

    private func captureMotion(in window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: false))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeWindow() async throws -> (UIWindow, UIWindow?) {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        return (UIWindow(windowScene: scene), scene.windows.first(where: \.isKeyWindow))
    }

    private func waitForPage(_ destination: NavigationRailDestination, model: Model, window: UIWindow) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            window.layoutIfNeeded()
            if model.buttons[destination]?.window === window { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        XCTFail("Missing horizontal destination: \(destination)")
    }

    private func find<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let result = controller as? T { return result }
        return controller.children.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func focusItems(in window: UIWindow) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [window]
        var visited = Set<ObjectIdentifier>()
        var items: [ObjectIdentifier: any UIFocusItem] = [:]
        while let container = containers.popLast() {
            guard visited.insert(ObjectIdentifier(container)).inserted else { continue }
            for item in container.focusItems(in: container.coordinateSpace.convert(window.bounds, from: window)) {
                if let child = item.focusItemContainer { containers.append(child) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView) { items[ObjectIdentifier(item)] = item }
            }
        }
        return Array(items.values)
    }

    private struct ReorderFixture: View {
        let model: NavigationStyleSettingsModel
        let keys: [String]

        var body: some View {
            LiftableReorderList(
                sections: model.librarySections(available: keys),
                disabledSectionTitle: "Hidden", disabledPlaceholder: "None",
                isLifting: .constant(false), allowsHiding: false,
                onMove: { model.recordNavigationMove(of: $0) },
                initialElement: NavigationLibraryLayout.settingsKey,
                row: { .init(title: Text(verbatim: $0)) },
                onChange: { model.applyLibrarySections($0, available: keys) }
            )
        }
    }

    @MainActor @Observable
    final class Model {
        var selection = NavigationRailDestination.home
        let chrome = NavigationChromeModel()
        var reduceMotion = false
        var destinations: [NavigationRailDestination] =
            [.home, .watchlist, .liveTV, .search] + (1...20).map { .library("plex:\($0)") }
        @ObservationIgnored var buttons: [NavigationRailDestination: UIButton] = [:]
        @ObservationIgnored var contentBuilds = 0
        @ObservationIgnored var scroll: TopNavigationScroll?
    }

    private struct Fixture: View {
        @Bindable var model: Model

        var body: some View {
            TopBarNavigation(
                destinations: model.destinations, selection: $model.selection,
                preventsAccidentalExit: true,
                content: { destination, active in
                    model.contentBuilds += 1
                    return AnyView(Probe(destination: destination, active: active, model: model)
                        .frame(width: 500, height: 100)
                        .frame(maxWidth: .infinity, maxHeight: .infinity))
                },
                label: { AnyView(Label($0.storageValue, systemImage: "square")) },
                chrome: model.chrome
            )
            .environment(\.plozzNavigationStyle, .tabBar)
            .environment(\._accessibilityReduceMotion, model.reduceMotion)
        }
    }

    private struct Probe: UIViewRepresentable {
        let destination: NavigationRailDestination
        let active: Bool
        let model: Model

        func makeUIView(context: Context) -> UIButton {
            let button = UIButton(type: .system)
            button.setTitle(destination.storageValue, for: .normal)
            model.buttons[destination] = button
            return button
        }

        func updateUIView(_ button: UIButton, context: Context) {
            button.isEnabled = active && context.environment.isEnabled
            model.scroll = context.environment.plozzTopNavigationScroll
        }
    }
}
#endif
