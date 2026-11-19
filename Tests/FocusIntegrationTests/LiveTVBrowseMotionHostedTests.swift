import Observation
import SwiftUI
import UIKit
import XCTest
import FeatureLiveTVCore
@testable import AppShell
@testable import FeatureLiveTV
@testable import CoreUI
@testable import FeaturePlayback

@MainActor
final class LiveTVBrowseMotionHostedTests: XCTestCase {
    func testGuideCategoryHandoffOwnsPinnedNavigationFallbackUntilFocusLeaves() async throws {
        let scene = try await foregroundScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        typealias Guide = PrototypeNativeGuideList<Int, Button<Text>>
        let controller = Guide.Controller()
        controller.parentView = Guide(
            rows: [.init(channelID: "channel")], scrollController: PrototypeGuideScrollController(),
            scrolled: { _, _ in }, revision: { _ in 0 }, leadingExit: {}
        ) { _ in Button("Channel") {} }
        controller.swiftUIEnvironment = EnvironmentValues()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let observer = NavigationRailEdgeCatcher.LeftPressRecognizer()
        window.addGestureRecognizer(observer)
        var opens = 0
        observer.onOpenNavigation = { opens += 1 }
        defer {
            window.removeGestureRecognizer(observer)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        for _ in 0..<50 where system.focusedItem == nil {
            window.layoutIfNeeded()
            system.requestFocusUpdate(to: controller)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let item = try XCTUnwrap(system.focusedItem)
        XCTAssertFalse(NavigationRailEdgeCatcher.permitsNavigationFallback(from: item))
        observer.checkFocusAfterInput(before: item, wasInRail: false)
        // A held press keeps guide focus until release, longer than the rail's 70 ms fallback.
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(system.focusedItem === item)
        XCTAssertEqual(opens, 0)

        controller.parentView?.leadingExit = nil
        XCTAssertTrue(NavigationRailEdgeCatcher.permitsNavigationFallback(from: item),
                      "Guides without a category handoff must retain normal edge navigation.")
        observer.checkFocusAfterInput(before: item, wasInRail: false)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(opens, 1)
    }

    func testCategoryFastScrollKeepsVisibleRowsFocusableAfterEntry() async throws {
        let scene = try await foregroundScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = CategoryFocusFixtureState()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = CategoryFocusHost(rootView: CategoryFocusPage(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        for _ in 0..<30 where system.focusedItem == nil {
            window.layoutIfNeeded()
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(250))
        let initial = try XCTUnwrap(system.focusedItem)
        let scroll = try XCTUnwrap(categoryScrollView(in: window))
        let initialFrame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: initial, relativeTo: scroll))
        XCTAssertTrue(scroll.bounds.contains(CGPoint(x: initialFrame.midX, y: initialFrame.midY)))
        XCTAssertLessThan(initialFrame.minY - scroll.bounds.minY, PrototypeLayout.controlHeight)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height * 3)
        XCTAssertGreaterThan(visibleCategoryFocusItems(in: window, scroll: scroll).count, 2,
                             "The initial category entry must complete before the scrolling reproduction.")

        for fraction in [0.7, 0.9, 0.45] {
            scroll.setContentOffset(
                CGPoint(x: 0, y: (scroll.contentSize.height - scroll.bounds.height) * fraction),
                animated: false
            )
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
        }
        let visible = visibleCategoryFocusItems(in: window, scroll: scroll)
        XCTAssertGreaterThan(visible.count, 2, "Fast scrolling must not disable the newly visible categories.")
        let target = try XCTUnwrap(visible.first)
        host.target = target
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(system.focusedItem === target, "A visible category must still accept real native focus.")
    }

    func testCategoryEntryRestoresLastFocusAfterThePaneIsRecreated() async throws {
        let scene = try await foregroundScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = CategoryFocusFixtureState()
        state.allowsExternalFocus = true
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = CategoryFocusHost(rootView: CategoryFocusPage(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        for _ in 0..<30 where system.focusedItem == nil {
            window.layoutIfNeeded()
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(250))
        let scroll = try XCTUnwrap(categoryScrollView(in: window))
        let initial = try XCTUnwrap(system.focusedItem)
        let initialFrame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: initial, relativeTo: scroll))
        XCTAssertTrue(scroll.bounds.contains(CGPoint(x: initialFrame.midX, y: initialFrame.midY)))
        XCTAssertLessThan(initialFrame.minY - scroll.bounds.minY, PrototypeLayout.controlHeight)
        XCTAssertGreaterThan(visibleCategoryFocusItems(in: window, scroll: scroll).count, 2,
                             "The initial category entry must complete before moving focus away.")
        let otherPane = try XCTUnwrap(categoryFocusItems(in: window).first {
            (NavigationRowFocusRequester.frame(of: $0, relativeTo: window)?.minX ?? 0) > 500
        })
        host.target = otherPane
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(system.focusedItem === otherPane)
        let category = try XCTUnwrap(visibleCategoryFocusItems(in: window, scroll: scroll).first { $0 === initial },
                                     "The selected category must remain eligible after departure.")
        host.target = category
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(system.focusedItem === category)
        XCTAssertGreaterThan(visibleCategoryFocusItems(in: window, scroll: scroll).count, 2,
                             "Returning to the selected category must release the entry gate again.")

        host.target = nil
        let next = try XCTUnwrap(visibleCategoryFocusItems(in: window, scroll: scroll).first {
            (NavigationRowFocusRequester.frame(of: $0, relativeTo: scroll)?.minY ?? 0) > initialFrame.maxY
        })
        host.target = next
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let lastControl = try XCTUnwrap(state.lastFocusedControl)
        XCTAssertNotEqual(lastControl, .category(state.model.category),
                          "Focus a category without selecting it.")
        let nextFrame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: next, relativeTo: scroll))
        host.target = nil
        state.request += 1
        try await Task.sleep(for: .milliseconds(250))
        let restored = try XCTUnwrap(system.focusedItem)
        let restoredFrame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: restored, relativeTo: scroll))
        XCTAssertEqual(restoredFrame.minY, nextFrame.minY, accuracy: 1,
                       "Entry must restore the last focused category, not the selected filter.")

        host.target = otherPane
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        host.target = nil
        state.showsSidebar = false
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.lastFocusedControl, lastControl)
        state.isRevealing = true
        state.showsSidebar = true
        state.request += 1
        try await Task.sleep(for: .milliseconds(80))
        state.isRevealing = false
        try await Task.sleep(for: .milliseconds(250))
        let reopenedScroll = try XCTUnwrap(categoryScrollView(in: window))
        XCTAssertTrue(NativeFocusRegion.contains(system.focusedItem, in: reopenedScroll))
        XCTAssertEqual(state.lastFocusedControl, lastControl)
        XCTAssertNil(state.model.category, "Restoring focus must not select a different filter.")

        guard case .category(let removedCategory) = lastControl else {
            return XCTFail("Expected a remembered category")
        }
        host.target = otherPane
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        host.target = nil
        state.showsSidebar = false
        try await Task.sleep(for: .milliseconds(80))
        try state.model.replaceChannels(state.model.channels.filter { $0.category != removedCategory })
        state.isRevealing = true
        state.showsSidebar = true
        state.request += 1
        try await Task.sleep(for: .milliseconds(80))
        state.isRevealing = false
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(NativeFocusRegion.contains(system.focusedItem, in: try XCTUnwrap(categoryScrollView(in: window))))
        XCTAssertEqual(state.lastFocusedControl, .category(nil),
                       "A removed category must fall back to the current filter.")
    }

    func testCategoryFocusRequestWaitsForRevealCompletionWithoutNativeOwner() async throws {
        try await assertCategoryRevealHandoff(usesNativeOwner: false)
    }

    func testNativeCategoryFocusArrivesDuringRevealAndDoesNotReplayOnCompletion() async throws {
        try await assertCategoryRevealHandoff(usesNativeOwner: true)
    }

    private func assertCategoryRevealHandoff(usesNativeOwner: Bool) async throws {
        let scene = try await foregroundScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = CategoryFocusFixtureState()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = CategoryFocusHost(rootView: CategoryFocusPage(state: state))
        var nativeRequests = 0
        if usesNativeOwner {
            state.nativeFocusRequest = { [weak host] marker in
                guard let host, let window = marker.window,
                      let system = UIFocusSystem.focusSystem(for: window),
                      let target = NavigationRowFocusRequester.target(for: marker, in: window) else { return false }
                nativeRequests += 1
                host.target = target
                defer { host.target = nil }
                system.requestFocusUpdate(to: host)
                system.updateFocusIfNeeded()
                return system.focusedItem === target
            }
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        let deadline = ContinuousClock.now + .seconds(2)
        while system.focusedItem == nil, ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(250))
        let scroll = try XCTUnwrap(categoryScrollView(in: window))
        let selected = try XCTUnwrap(system.focusedItem)
        XCTAssertTrue(NativeFocusRegion.contains(selected, in: scroll))
        XCTAssertEqual(state.lastFocusedControl, .category(nil))
        let selectedFrame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: selected, relativeTo: scroll))
        state.allowsExternalFocus = true
        await Task.yield()
        window.layoutIfNeeded()
        let guide = try XCTUnwrap(categoryFocusItems(in: window).first {
            (NavigationRowFocusRequester.frame(of: $0, relativeTo: window)?.minX ?? 0) > 500
        })
        host.target = guide
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(system.focusedItem === guide)
        host.target = nil

        state.isRevealing = true
        state.request += 1
        if usesNativeOwner {
            let deadline = ContinuousClock.now + .seconds(2)
            while !NativeFocusRegion.contains(system.focusedItem, in: scroll), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(state.isRevealing)
            XCTAssertTrue(NativeFocusRegion.contains(system.focusedItem, in: scroll),
                          "The native handoff must not wait for animation completion.")
            let early = try XCTUnwrap(system.focusedItem)
            XCTAssertEqual(try XCTUnwrap(NavigationRowFocusRequester.frame(of: early, relativeTo: scroll)).minY,
                           selectedFrame.minY, accuracy: 1)
            let count = nativeRequests
            host.target = guide
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            host.target = nil
            state.isRevealing = false
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(system.focusedItem === guide,
                          "Leaving during reveal must not let completion pull focus back.")
            XCTAssertEqual(nativeRequests, count)
            return
        }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(system.focusedItem === guide, "SwiftUI-only hosts still wait for the pane to finish opening.")

        state.isRevealing = false
        try await Task.sleep(for: .milliseconds(250))
        let focused = try XCTUnwrap(system.focusedItem)
        let focusedFrame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: focused, relativeTo: scroll))
        XCTAssertTrue(NativeFocusRegion.contains(focused, in: scroll))
        XCTAssertEqual(focusedFrame.minY, selectedFrame.minY, accuracy: 1,
                       "Presentation completion must focus the selected category without another input.")
    }

    func testCategoryReturnPreservesItsScrollPosition() async throws {
        try await assertCategoryScrollRestoration()
    }

    func testCategoryReturnPreservesItsScrollPositionInRightToLeftLayout() async throws {
        try await assertCategoryScrollRestoration(direction: .rightToLeft)
    }

    func testCategoryReturnPreservesItsScrollPositionWithoutAnimation() async throws {
        try await assertCategoryScrollRestoration(disablesAnimations: true)
    }

    private func assertCategoryScrollRestoration(
        direction: LayoutDirection = .leftToRight, disablesAnimations: Bool = false
    ) async throws {
        let scene = try await foregroundScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = CategoryFocusFixtureState()
        state.allowsExternalFocus = true
        state.usesBrowseLayout = true
        state.direction = direction
        state.disablesAnimations = disablesAnimations
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = CategoryFocusHost(rootView: CategoryFocusPage(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        for _ in 0..<30 where system.focusedItem == nil {
            window.layoutIfNeeded()
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(250))
        let scroll = try XCTUnwrap(categoryScrollView(in: window))
        XCTAssertTrue(NativeFocusRegion.contains(system.focusedItem, in: scroll))

        for fraction in [0.45, 0.8, 0.6] {
            scroll.setContentOffset(
                CGPoint(x: 0, y: (scroll.contentSize.height - scroll.bounds.height) * fraction),
                animated: false
            )
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let target = try XCTUnwrap(visibleCategoryFocusItems(in: window, scroll: scroll).first {
                guard let frame = NavigationRowFocusRequester.frame(of: $0, relativeTo: scroll) else { return false }
                let viewportY = frame.minY - scroll.bounds.minY
                return viewportY > 60 && viewportY < scroll.bounds.height / 3
            })
            host.target = target
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(system.focusedItem === target)
            let remembered = try XCTUnwrap(state.lastFocusedControl)
            let before = try XCTUnwrap(NavigationRowFocusRequester.frame(of: target, relativeTo: window))
            let offset = scroll.contentOffset.y
            let guide = try XCTUnwrap(categoryFocusItems(in: window).first {
                guard let frame = NavigationRowFocusRequester.frame(of: $0, relativeTo: window) else { return false }
                return abs(frame.width - 300) < 1 && abs(frame.height - 100) < 1
            })
            host.target = guide
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(system.focusedItem === guide)
            host.target = nil
            state.collapsed = true
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 1)

            state.isRevealing = true
            state.request += 1
            withAnimation(
                disablesAnimations ? nil : PrototypeLayout.sidebarAnimation, completionCriteria: .removed
            ) {
                state.collapsed = false
            } completion: {
                state.isRevealing = false
            }
            try await Task.sleep(for: .milliseconds(600))
            let reopenedScroll = try XCTUnwrap(categoryScrollView(in: window))
            let restored = try XCTUnwrap(system.focusedItem)
            let after = try XCTUnwrap(NavigationRowFocusRequester.frame(of: restored, relativeTo: window))
            XCTAssertTrue(reopenedScroll === scroll, "Collapsing must retain the native category viewport.")
            XCTAssertTrue(NativeFocusRegion.contains(restored, in: scroll))
            XCTAssertEqual(state.lastFocusedControl, remembered)
            XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 1, "Returning must not recenter the category.")
            XCTAssertEqual(after.minY, before.minY, accuracy: 1, "The focused category must stay at the same screen height.")
            XCTAssertNil(state.model.category, "Focus restoration must not select the category.")
        }
    }

    private func categoryScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
            return scroll
        }
        return view.subviews.lazy.compactMap { self.categoryScrollView(in: $0) }.first
    }

    private func categoryFocusItems(in window: UIWindow) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [window]
        var seen = Set<ObjectIdentifier>()
        var result: [any UIFocusItem] = []
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let frame = container.coordinateSpace.convert(window.bounds, from: window)
            for item in container.focusItems(in: frame) {
                if let children = item.focusItemContainer { containers.append(children) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView) { result.append(item) }
            }
        }
        return result
    }

    private func visibleCategoryFocusItems(in window: UIWindow, scroll: UIScrollView) -> [any UIFocusItem] {
        categoryFocusItems(in: window).filter { item in
            guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: scroll) else { return false }
            return scroll.bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
                && frame.width > 300 && frame.height > 30
        }
    }

    @MainActor @Observable final class CategoryFocusFixtureState {
        var active = false
        var request = 1
        var allowsExternalFocus = false
        var isRevealing = false
        var showsSidebar = true
        var usesBrowseLayout = false
        var collapsed = false
        var direction = LayoutDirection.leftToRight
        var disablesAnimations = false
        var nativeFocusRequest: (@MainActor (UIView) -> Bool)?
        var lastFocusedControl: PrototypeBrowseSidebar.Control?
        let model = LiveTVPrototypeModel(channels: (0..<80).map {
            LiveTVPrototypeChannel(
                id: "category-\($0)", number: $0, name: "Channel \($0)",
                category: String(format: "Category %02d", $0), symbol: "tv", accent: 0,
                source: .iptv, tagline: ""
            )
        })
    }

    private struct CategoryFocusPage: View {
        @Bindable var state: CategoryFocusFixtureState

        var body: some View {
            Group {
                if state.usesBrowseLayout {
                    let layout = PrototypePreviewLayout(
                        size: CGSize(width: 1800, height: 960), hidesSidebar: state.collapsed
                    )
                    PrototypeBrowseLayout(layout: layout) {
                        Color.clear.frame(height: layout.heroHeight)
                    } sidebar: {
                        sidebar
                    } guide: {
                        guide
                    }
                    .frame(width: layout.contentFrame.width, height: layout.contentFrame.height)
                } else {
                    HStack(alignment: .top, spacing: 80) {
                        if state.showsSidebar {
                            sidebar.frame(width: 384, height: 900)
                        }
                        guide
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(60)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .environment(\.layoutDirection, state.direction)
            .environment(\.plozzNativeControlFocusRequest, state.nativeFocusRequest)
            .transaction { $0.disablesAnimations = state.disablesAnimations }
        }

        private var sidebar: some View {
            PrototypeBrowseSidebar(
                model: state.model, configuration: .empty, active: $state.active,
                lastFocusedControl: $state.lastFocusedControl, focusRequest: 0,
                categoryFocusRequest: state.request, restoresCategoryFocus: true,
                isRevealing: state.isRevealing,
                search: {}, enterGuide: {}, selectSource: { _ in }, addSource: {}
            )
        }

        private var guide: some View {
            Button {} label: {
                Text("Guide").frame(width: 300, height: 100)
            }
            .buttonStyle(.plain)
            .disabled(!state.allowsExternalFocus)
        }
    }

    private final class CategoryFocusHost: UIHostingController<CategoryFocusPage> {
        weak var target: (any UIFocusEnvironment)?
        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            target.map { [$0] } ?? super.preferredFocusEnvironments
        }
    }

    func testScheduledAndUnscheduledChannelsTravelTogetherWithTheSidebar() async throws {
        throw XCTSkip(
            "The hosted simulator renders a single intermediate frame for this motion; "
                + "the frame-count assertion needs a display-link capture path."
        )
        try await assertMixedGuideMotion()
    }

    func testMixedGuideRowsStayTogetherInRightToLeftLayout() async throws {
        throw XCTSkip(
            "The hosted simulator renders a single intermediate frame for the RTL guide "
                + "motion; the frame-count assertion needs a display-link capture path."
        )
        try await assertMixedGuideMotion(direction: .rightToLeft)
    }

    func testMixedGuideRowsStayTogetherDuringRapidReversal() async throws {
        try await assertMixedGuideMotion(rapidReversal: true)
    }

    func testMixedGuideRowsSkipTravelWithDisabledAnimations() async throws {
        try await assertMixedGuideMotion(disablesAnimations: true)
    }

    private func assertMixedGuideMotion(
        direction: LayoutDirection = .leftToRight, disablesAnimations: Bool = false,
        rapidReversal: Bool = false
    ) async throws {
        let scene = try await foregroundScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let model = try MixedGuideModel()
        window.rootViewController = UIHostingController(rootView: MixedGuidePage(model: model)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .environment(\.layoutDirection, direction)
            .transaction { $0.disablesAnimations = disablesAnimations })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        let reference = try mixedGuideTextEdges(in: window)
        XCTAssertEqual(reference.count, 3)
        for collapsed in [false, true] {
            let start = try mixedGuideTextEdges(in: window)
            // Opening from the station wraps the focus handoff in an explicit
            // transaction; closing relies on the layout's value animation.
            if collapsed {
                model.collapsed = true
            } else {
                withAnimation(disablesAnimations ? nil : PrototypeLayout.sidebarAnimation) {
                    model.collapsed = false
                }
            }
            var history: [[CGFloat]] = []
            let sampleCount = rapidReversal && !collapsed ? 3 : 20
            for _ in 0..<sampleCount {
                try await Task.sleep(for: .milliseconds(16))
                history.append(try mixedGuideTextEdges(in: window))
            }
            let end = try XCTUnwrap(history.last)
            let travel = end[1] - start[1]
            if !rapidReversal {
                XCTAssertEqual(abs(travel), 408, accuracy: 2)
            }
            var movingSamples = 0
            for edges in history {
                let distance = edges[1] - start[1]
                if abs(distance) > 5, abs(distance) < 408 - 5 {
                    movingSamples += 1
                }
                for row in [0, 2] {
                    XCTAssertEqual(edges[row] - start[row], distance, accuracy: 2,
                                   "Plozz, no-guide IPTV and server programme rows must share one displacement")
                }
            }
            let attachment = XCTAttachment(string: "collapsed=\(collapsed) start=\(start) frames=\(history)")
            attachment.name = "Mixed guide sidebar motion"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("Mixed guide motion: collapsed=\(collapsed) start=\(start) frames=\(history)")
            if disablesAnimations {
                XCTAssertEqual(movingSamples, 0)
            } else if !rapidReversal {
                XCTAssertGreaterThanOrEqual(movingSamples, 2)
            } else if !collapsed {
                XCTAssertGreaterThan(abs(travel), 0)
                XCTAssertLessThan(abs(travel), 408)
            }
        }
        for (edge, original) in zip(try mixedGuideTextEdges(in: window), reference) {
            XCTAssertEqual(edge, original, accuracy: 2, "Closing must restore every row's original position")
        }
    }

    private func mixedGuideTextEdges(in window: UIWindow) throws -> [CGFloat] {
        func collection(in view: UIView) -> UICollectionView? {
            if let value = view as? UICollectionView { return value }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        let collection = try XCTUnwrap(collection(in: window))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: false))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        var rgba = [UInt8](repeating: 0, count: width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &rgba, width: width, height: cgImage.height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: window.bounds)
        return try (0..<3).map { row in
            let frame = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: row, section: 0))).frame
            let middle = Int(collection.convert(frame, to: window).midY - PrototypeLayout.rowGap / 2)
            let edge = (0..<width).last { x in
                ((middle - 15)..<(middle + 15)).filter { y in
                    let offset = (y * width + x) * 4
                    return min(rgba[offset], rgba[offset + 1], rgba[offset + 2]) > 160
                }.count > 4
            }
            return CGFloat(try XCTUnwrap(edge, "Expected the channel/programme title in row \(row)"))
        }
    }

    func testActualSidebarLabelsTravelTogetherDespiteButtonFocusTransactions() async throws {
        throw XCTSkip(
            "The hosted simulator often renders a single intermediate frame for this "
                + "motion; the frame-count assertion needs a display-link capture path."
        )
        let fixture = try await makeFixture(realSidebar: true)
        defer { fixture.close() }
        fixture.model.collapsed = false
        _ = try await fixture.sample()
        let reference = try labelRightEdges(in: fixture.sidebarImage())
        XCTAssertEqual(reference.compactMap { $0 }.count, 3)
        fixture.model.collapsed = true
        var movingSamples = 0
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(16))
            let image = fixture.sidebarImage()
            let edges = try labelRightEdges(in: image)
            guard let category = edges[2], let originalCategory = reference[2] else { continue }
            let distance = category - originalCategory
            guard distance < -2, distance > -100 else { continue }
            movingSamples += 1
            for control in 0..<2 {
                guard let edge = edges[control], let original = reference[control] else {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Sidebar label disappeared before categories"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    XCTFail("Search and Multiviews must remain visible while the category label moves")
                    continue
                }
                XCTAssertEqual(Double(edge - original), Double(distance), accuracy: 2,
                               "Search, Multiviews, and categories must share one rendered displacement")
            }
        }
        XCTAssertGreaterThanOrEqual(movingSamples, 2, "Observe actual intermediate rendered frames")
    }

    private func labelRightEdges(in image: UIImage) throws -> [Int?] {
        let image = try XCTUnwrap(image.cgImage)
        let width = image.width
        var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        return [20..<54, 100..<135, 188..<220].map { rows in
            (0..<240).last { x in
                rows.filter { y in
                    let index = (y * width + x) * 4
                    return min(pixels[index], pixels[index + 1], pixels[index + 2]) > 175
                }.count > 3
            }
        }
    }

    func testDisappearanceStopsPlaybackUnlessActiveFullscreenOwnsIt() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        var stops = 0
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        fixture.window.rootViewController = host

        for (active, fullscreen) in [
            (true, true), (true, false), (false, true), (false, false)
        ] {
            host.rootView = AnyView(Color.black.modifier(LiveChannelPlayerView.LiveChannelActivityObserver(
                isActive: active, isAuthorized: true, scenePhase: .active, networkBlock: nil,
                currentModel: { nil }, fullscreenOwnsSurface: { fullscreen },
                updateSource: {}, stopPlayback: { stops += 1 }
            )))
            fixture.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            let before = stops
            host.rootView = AnyView(EmptyView())
            fixture.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(stops - before, active && fullscreen ? 0 : 1)
        }
    }

    func testSidebarOpeningAndClosingHaveIntermediatePresentedFrames() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let closed = try fixture.guideX()

        fixture.model.collapsed = false
        let opening = try await fixture.sample()
        let opened = try fixture.guideX()
        XCTAssertEqual(opened - closed, 408, accuracy: 1)
        XCTAssertTrue(opening.contains { $0 > closed + 12 && $0 < opened - 12 },
                      "Opening must animate, not jump between final layouts: \(opening)")

        fixture.model.collapsed = true
        let closing = try await fixture.sample()
        XCTAssertEqual(try fixture.guideX(), closed, accuracy: 1)
        XCTAssertTrue(closing.contains { $0 > closed + 12 && $0 < opened - 12 },
                      "Closing must animate, not jump between final layouts: \(closing)")
    }

    func testRapidReversalSettlesAtTheRequestedLayout() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let closed = try fixture.guideX()
        fixture.model.collapsed = false
        _ = try await fixture.sample(duration: .milliseconds(90))
        fixture.model.collapsed = true
        _ = try await fixture.sample()
        XCTAssertEqual(try fixture.guideX(), closed, accuracy: 1)
    }

    func testDisabledAnimationsSkipSidebarTravel() async throws {
        let fixture = try await makeFixture(disablesAnimations: true)
        defer { fixture.close() }
        let closed = try fixture.guideX()
        fixture.model.collapsed = false
        let samples = try await fixture.sample()
        let opened = try fixture.guideX()
        XCTAssertEqual(opened - closed, 408, accuracy: 1)
        XCTAssertFalse(samples.contains { $0 > closed + 1 && $0 < opened - 1 })
    }

    func testCollapsingCategoriesFadeToClearBeforePinnedNavigationIcons() throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let layout = PrototypePreviewLayout(
                size: CGSize(width: 1920, height: 1080),
                navigationInset: NavigationRailMetrics.contentInset
            )
            let contentStart = layout.contentFrame.minX
            let clearEdge = contentStart - layout.sidebarLeadingFadeWidth
            let iconEdge = NavigationRailMetrics.leadingInset + NavigationRailMetrics.iconColumnWidth
            XCTAssertGreaterThan(clearEdge, iconEdge)
            for remainingWidth: CGFloat in [layout.sidebarWidth, 160, 16] {
                let pixels = try sidebarAlpha(
                    layout: layout, remainingWidth: remainingWidth, displacement: 96, direction: direction
                )
                for x in 0..<Int(clearEdge) {
                    XCTAssertEqual(pixels[x], 0, "No category pixels may remain beneath the pinned icons.")
                }
                let start = Int(clearEdge)
                let end = Int(contentStart)
                XCTAssertLessThan(pixels[start], 3)
                XCTAssertTrue((100...155).contains(pixels[(start + end) / 2]))
                XCTAssertGreaterThan(pixels[end], 250)
                for x in start..<end {
                    XCTAssertLessThanOrEqual(pixels[x], pixels[x + 1])
                }
            }
            let resting = try sidebarAlpha(
                layout: layout, remainingWidth: layout.sidebarWidth, displacement: 0, direction: direction
            )
            XCTAssertGreaterThan(resting[Int(contentStart)], 250,
                                 "Resting category controls must not be washed out by the feather.")
            let overhang = try sidebarAlpha(
                layout: layout, remainingWidth: layout.sidebarWidth, displacement: -12, direction: direction
            )
            XCTAssertGreaterThan(overhang[Int(contentStart + layout.sidebarWidth + 8)], 250,
                                 "The sidebar viewport must not crop native focus at its trailing edge.")
        }
    }

    private func sidebarAlpha(
        layout: PrototypePreviewLayout, remainingWidth: CGFloat,
        displacement: CGFloat, direction: LayoutDirection
    ) throws -> [Int] {
        let screenWidth = Int(layout.bounds.width)
        let content = Color.white
            .frame(width: layout.availableSidebarWidth, height: 20)
            .offset(x: -displacement)
            .frame(width: remainingWidth, alignment: .leading)
            .modifier(PrototypeSidebarViewport(
                sidebarWidth: layout.availableSidebarWidth, fadeWidth: layout.sidebarLeadingFadeWidth
            ))
            .padding(.leading, layout.contentFrame.minX)
            .frame(width: layout.bounds.width, height: 20, alignment: .leading)
            .environment(\.layoutDirection, direction)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: screenWidth * 20 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: screenWidth, height: 20, bitsPerComponent: 8,
                bytesPerRow: screenWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: screenWidth, height: 20))
        }
        return (0..<screenWidth).map {
            let x = direction == .rightToLeft ? screenWidth - 1 - $0 : $0
            return Int(pixels[(10 * screenWidth + x) * 4 + 3])
        }
    }

    private func makeFixture(disablesAnimations: Bool = false, realSidebar: Bool = false) async throws -> Fixture {
        let scene = try await foregroundScene()
        let fixture = Fixture(scene: scene, disablesAnimations: disablesAnimations, realSidebar: realSidebar)
        var prepared = false
        defer { if !prepared { fixture.close() } }
        let displayDeadline = ContinuousClock.now + .seconds(2)
        while fixture.renderedGuideX(afterScreenUpdates: true) == nil, ContinuousClock.now < displayDeadline {
            try await Task.sleep(for: .milliseconds(16))
            fixture.window.layoutIfNeeded()
        }
        _ = try fixture.guideX()
        prepared = true
        return fixture
    }

    private func foregroundScene() async throws -> UIWindowScene {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }

    private final class Fixture {
        let model = Model()
        let window: UIWindow
        let previous: UIWindow?

        init(scene: UIWindowScene, disablesAnimations: Bool, realSidebar: Bool) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(rootView: Page(model: model, realSidebar: realSidebar)
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
                .transaction { $0.disablesAnimations = disablesAnimations })
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func sidebarImage() -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 384, height: 360), format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: false))
            }
        }

        func guideX() throws -> CGFloat {
            try XCTUnwrap(renderedGuideX(), "The guide must be present in the rendered frame")
        }

        func renderedGuideX(afterScreenUpdates: Bool = false) -> CGFloat? {
            guard let view = model.guide, !view.bounds.isEmpty else { return nil }
            let row = view.convert(view.bounds, to: window).midY
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            var drawn = false
            let image = UIGraphicsImageRenderer(
                size: CGSize(width: window.bounds.width, height: 1), format: format
            ).image { context in
                context.cgContext.translateBy(x: 0, y: -row)
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: afterScreenUpdates)
            }
            guard drawn, let pixels = image.cgImage else { return nil }
            var rgba = [UInt8](repeating: 0, count: pixels.width * 4)
            guard let context = CGContext(
                data: &rgba, width: pixels.width, height: 1, bitsPerComponent: 8,
                bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: 1))
            let leading = (0..<pixels.width).first { x in
                rgba[x * 4 + 1] > 180 && rgba[x * 4] < 50 && rgba[x * 4 + 2] < 50
            }
            return leading.map(CGFloat.init)
        }

        func sample(duration: Duration = .milliseconds(450)) async throws -> [CGFloat] {
            let deadline = ContinuousClock.now + duration
            var samples: [CGFloat] = []
            while ContinuousClock.now < deadline {
                window.layoutIfNeeded()
                samples.append(try guideX())
                try await Task.sleep(for: .milliseconds(16))
            }
            return samples
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }

    @Observable final class Model {
        var collapsed = true
        var sidebarActive = false
        let sidebar = LiveTVPrototypeModel(now: Date(), scenario: .noGuide, channels: [])
        @ObservationIgnored weak var guide: UIView?
    }

    private struct Page: View {
        let model: Model
        let realSidebar: Bool

        var body: some View {
            let layout = PrototypePreviewLayout(
                size: CGSize(width: 1920, height: 1080), hidesSidebar: model.collapsed
            )
            PrototypeBrowseLayout(layout: layout) {
                Color.blue.frame(height: layout.heroHeight)
            } sidebar: {
                if realSidebar {
                    PrototypeBrowseSidebar(
                        model: model.sidebar, configuration: .empty,
                        active: Binding(get: { model.sidebarActive }, set: { model.sidebarActive = $0 }),
                        lastFocusedControl: .constant(nil),
                        focusRequest: 0, search: {}, enterGuide: {},
                        selectSource: { _ in }, addSource: {}, multiviews: {}
                    )
                    .disabled(true)
                } else {
                    Color.red
                }
            } guide: {
                GuideMarker(model: model)
            }
            .frame(width: layout.contentFrame.width, height: layout.contentFrame.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
        }
    }

    private struct GuideMarker: UIViewRepresentable {
        let model: Model

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .green
            model.guide = view
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {}
    }

    @MainActor @Observable final class MixedGuideModel {
        var collapsed = true
        let guide: LiveTVPrototypeModel
        let imports = LiveTVPrototypeImportModel(configuration: .init())

        init() throws {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let channels = [LiveTVPrototypeSource.plozz, .iptv, .jellyfin].enumerated().map { index, source in
                LiveTVPrototypeChannel(
                    id: "mixed-\(index)", number: index, name: "MMMMMMMM", category: "Test",
                    symbol: "tv", accent: index, source: source, tagline: ""
                )
            }
            guide = LiveTVPrototypeModel(now: now, channels: channels)
            try guide.replacePrograms([0, 2].map { index in
                LiveTVPrototypeProgram(
                    id: "programme-\(index)", channelID: channels[index].id, title: "MMMMMMMM", subtitle: "",
                    start: now, end: now.addingTimeInterval(21_600)
                )
            })
        }
    }

    private struct MixedGuidePage: View {
        let model: MixedGuideModel
        @State private var selectedID: String?
        @State private var selectedRowID: LiveTVGuideRowID?
        @State private var railActive = false
        @State private var focusedProgram: LiveTVPrototypeProgram?
        @State private var hasFocus = false
        @State private var guideOffset: TimeInterval = 0
        @State private var timelineOffset: CGFloat = 0

        var body: some View {
            let layout = PrototypePreviewLayout(
                size: CGSize(width: 1920, height: 1080), hidesSidebar: model.collapsed
            )
            PrototypeBrowseLayout(layout: layout) {
                Color.blue.frame(height: layout.heroHeight)
            } sidebar: {
                Color.red
            } guide: {
                PrototypeBrowser(
                    model: model.guide, imports: model.imports, selectedID: $selectedID,
                    selectedRowID: $selectedRowID, railActive: $railActive, focusedProgram: $focusedProgram,
                    hasFocus: $hasFocus, topRequest: 0, nowRequest: 0, guideOffset: $guideOffset,
                    timeAnchor: .constant(model.guide.now), timelineOffset: $timelineOffset,
                    restoreFocusRequest: 0, isPresented: true, isRestoringFocus: false,
                    restoresPlaybackFocus: false, watchOrigin: nil, focusRestored: { _ in },
                    tune: { _ in }, details: { _ in }, openControls: {}, openSources: {},
                    openGuideTime: {}, openToolbar: nil, isLoading: false, loadFailed: false, reload: {}
                )
                .disabled(true)
            }
            .frame(width: layout.contentFrame.width, height: layout.contentFrame.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
        }
    }
}
