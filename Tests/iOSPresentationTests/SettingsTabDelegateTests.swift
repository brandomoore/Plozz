#if os(iOS)
import UIKit
import XCTest
import SwiftUI
import CoreModels
import CoreUI
@testable import FeatureHomeCore
@testable import AppShelliOS

@MainActor
final class SettingsTabDelegateTests: XCTestCase {
    func testUpcomingTodayAnchorSurvivesScrollingThroughSparseDates() async throws {
        try await verifyUpcomingTodayAnchor(size: CGSize(width: 390, height: 844), hasTodayRelease: true)
    }

    func testUpcomingEmptyTodayAnchorSurvivesTabletScrolling() async throws {
        try await verifyUpcomingTodayAnchor(size: CGSize(width: 1024, height: 1366), hasTodayRelease: false)
    }

    private func verifyUpcomingTodayAnchor(size: CGSize, hasTodayRelease: Bool) async throws {
        let today = Calendar.current.startOfDay(for: Date())
        let model = UpcomingFeedModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let releases = (-30...30).flatMap { day in
            (0..<(day == 0 ? (hasTodayRelease ? 1 : 0) : 1 + abs(day) % 7)).map { index in
                UpcomingRelease(
                    id: "\(day)-\(index)", titleKey: "\(day)-\(index)",
                    item: MediaItem(id: "\(day)-\(index)", title: "Series \(day) \(index)", kind: .series),
                    date: Calendar.current.date(byAdding: .day, value: day, to: today)!,
                    datePrecision: .dateOnly, kind: .episode, interests: [.watching]
                )
            }
        }
        await model.refresh(scope: "scroll-test", namespace: nil, isCurrent: { true }) {
            UpcomingFeedSnapshot(releases: releases)
        }
        let host = UIHostingController(rootView:
            UpcomingView(model: model, interval: DateInterval(
                start: today.addingTimeInterval(-30 * 86_400), duration: 120 * 86_400
            ))
                .environment(\.plozzMetrics, .touch(density: .standard))
                .environment(\.horizontalSizeClass, size.width < 800 ? .compact : .regular)
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(500))
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let probe = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UpcomingScrollProbe.Probe }
            .first(where: { $0.role == .container }))
        let detent = try XCTUnwrap(probe.detent)
        let scroll = try XCTUnwrap(detent.scrollView)
        var catches = 0
        detent.onFeedback = { if $0 == .selection { catches += 1 } }
        let initialToday = try XCTUnwrap(detent.todayOffset)
        let initialDeadline = Date().addingTimeInterval(3)
        while abs(scroll.contentOffset.y - initialToday) > 1, Date() < initialDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(scroll.contentOffset.y, initialToday, accuracy: 1)
        for displacement in [1_500.0, 3_000.0, 1_500.0, 0.0, -300.0, 0.0] {
            scroll.setContentOffset(
                CGPoint(x: scroll.contentOffset.x, y: initialToday + displacement), animated: false
            )
            try await Task.sleep(for: .milliseconds(100))
            detent.updateAnchor()
            XCTAssertEqual(
                try XCTUnwrap(detent.todayOffset), initialToday, accuracy: 1,
                "Scrolling away must not remove or shift the Today detent"
            )
        }
        for _ in 1...2 {
            scroll.contentOffset.y = initialToday + 1_500
            try await Task.sleep(for: .milliseconds(100))
            detent.reduceMotion = true
            XCTAssertTrue(UpcomingView.scrollToToday(in: scroll))
            let deadline = Date().addingTimeInterval(3)
            while abs(scroll.contentOffset.y - initialToday) > 1, Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(scroll.contentOffset.y, initialToday, accuracy: 1, "Each navigation tap returns to Today")
        }
        XCTAssertEqual(catches, 0, "Positioning and navigation must not emit catch feedback")
        let approaches: [(CGFloat, CGFloat, CGFloat, CGFloat, Bool)] = [
            (-300, -30, -0.3, -300, true),
            (-300, 30, 0.3, 300, true),
            (-300, 30, 2, 900, false),
            (-300, -300, 0.3, -30, true),
            (300, 30, -2, -900, true)
        ]
        var expectedCatches = 0
        for (start, displacement, velocity, projection, shouldCatch) in approaches {
            scroll.contentOffset.y = initialToday + start
            try await Task.sleep(for: .milliseconds(100))
            scroll.delegate?.scrollViewWillBeginDragging?(scroll)
            let startDeadline = Date().addingTimeInterval(3)
            while detent.phase != .interacting, Date() < startDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(detent.phase, .interacting)
            scroll.contentOffset.y = initialToday + displacement
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(scroll.contentOffset.y, initialToday + displacement, accuracy: 1)
            var target = CGPoint(x: scroll.contentOffset.x, y: initialToday + projection)
            scroll.delegate?.scrollViewWillEndDragging?(
                scroll, withVelocity: CGPoint(x: 0, y: velocity), targetContentOffset: &target
            )
            XCTAssertEqual(target.y, shouldCatch ? initialToday : initialToday + projection, accuracy: 1)
            XCTAssertEqual(catches, expectedCatches, "Choosing a target is not arrival")
            scroll.contentOffset = target
            scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
            let endDeadline = Date().addingTimeInterval(3)
            while detent.phase != .idle, Date() < endDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(detent.phase, .idle)
            if shouldCatch { expectedCatches += 1 }
            XCTAssertEqual(catches, expectedCatches, "Each completed catch emits feedback once")
        }
        try await verifyUpcomingAnimatedReselection(detent: detent, scroll: scroll)
        if size.width >= 800 {
            let calendar = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIDatePicker }.first)
            for days in [-5, 5] {
                calendar.date = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: days, to: today))
                calendar.sendActions(for: .valueChanged)
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertGreaterThan(abs(scroll.contentOffset.y - (try XCTUnwrap(detent.todayOffset))), 300)
                try await verifyUpcomingAnimatedReset(detent: detent, scroll: scroll)
            }
        }
        try await verifyUpcomingNativeSpring(detent: detent, scroll: scroll, today: initialToday)
    }

    private func verifyUpcomingAnimatedReselection(
        detent: UpcomingScrollDetent, scroll: UIScrollView
    ) async throws {
        detent.reduceMotion = false
        for displacement in [-600.0, 1_500.0] {
            let today = try XCTUnwrap(detent.todayOffset)
            scroll.contentOffset.y = today + displacement
            try await Task.sleep(for: .milliseconds(100))
            try await verifyUpcomingAnimatedReset(detent: detent, scroll: scroll, repeatsDuringMotion: true)
        }
    }

    private func verifyUpcomingAnimatedReset(
        detent: UpcomingScrollDetent, scroll: UIScrollView, repeatsDuringMotion: Bool = false
    ) async throws {
        let start = try XCTUnwrap(scroll.layer.presentation()).bounds.origin.y
        var today = try XCTUnwrap(detent.todayOffset)
        let distance = abs(start - today)
        XCTAssertTrue(UpcomingView.scrollToToday(in: scroll))
        var intermediateOffsets: [CGFloat] = []
        var previousOffset = start
        var repeated = false
        let deadline = Date().addingTimeInterval(3)
        repeat {
            try await Task.sleep(for: .milliseconds(10))
            let offset = try XCTUnwrap(scroll.layer.presentation()).bounds.origin.y
            today = try XCTUnwrap(detent.todayOffset)
            if abs(offset - today) > 2, abs(offset - start) > 2 {
                intermediateOffsets.append(offset)
            }
            XCTAssertLessThan(abs(offset - previousOffset), distance * 0.5, "Navigation must not jump between frames")
            if repeatsDuringMotion, !repeated, intermediateOffsets.count >= 4 {
                XCTAssertTrue(UpcomingView.scrollToToday(in: scroll))
                repeated = true
            }
            previousOffset = offset
        } while (abs(scroll.contentOffset.y - today) > 1 || detent.phase != .idle)
            && Date() < deadline
        XCTAssertEqual(scroll.contentOffset.y, try XCTUnwrap(detent.todayOffset), accuracy: 1)
        XCTAssertGreaterThan(intermediateOffsets.count, 3,
                             "Tab reselection must visibly scroll toward Today from either direction")
        XCTAssertGreaterThan(
            (intermediateOffsets.max() ?? 0) - (intermediateOffsets.min() ?? 0),
            distance * 0.5, "Observe travel, not a delayed teleport"
        )
        if repeatsDuringMotion { XCTAssertTrue(repeated) }
    }

    private func verifyUpcomingNativeSpring(
        detent: UpcomingScrollDetent, scroll: UIScrollView, today: CGFloat
    ) async throws {
        let animationKey = "plozz.upcoming.elasticity"
        let contentLayer = try XCTUnwrap(detent.contentLayer)
        XCTAssertTrue(contentLayer.superlayer === scroll.layer, "The agenda host is separate from viewport chrome")
        detent.reduceMotion = false
        var events: [TouchFeedback.Event] = []
        detent.onFeedback = { events.append($0) }
        func beginPull() async throws {
            detent.cancelInteraction()
            scroll.contentOffset.y = today
            scroll.delegate?.scrollViewWillBeginDragging?(scroll)
            let deadline = Date().addingTimeInterval(3)
            while detent.phase != .interacting, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(detent.phase, .interacting)
        }
        func returnHeldPull() async throws {
            var target = CGPoint(x: scroll.contentOffset.x, y: today - 900)
            scroll.delegate?.scrollViewWillEndDragging?(
                scroll, withVelocity: CGPoint(x: 0, y: -2), targetContentOffset: &target
            )
            XCTAssertEqual(target.y, today, accuracy: 1)
            scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
            let deadline = Date().addingTimeInterval(3)
            while contentLayer.animation(forKey: animationKey) == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertNotNil(contentLayer.animation(forKey: animationKey))
            XCTAssertNil(scroll.layer.animation(forKey: animationKey))
        }
        func sampleMotion(at modelOffset: CGFloat) async throws -> [CGFloat] {
            var samples: [CGFloat] = []
            let deadline = Date().addingTimeInterval(3)
            while contentLayer.animation(forKey: animationKey) != nil, Date() < deadline {
                let translation = try XCTUnwrap(contentLayer.presentation()).transform.m42 - contentLayer.transform.m42
                samples.append(scroll.contentOffset.y - translation)
                XCTAssertEqual(try XCTUnwrap(scroll.layer.presentation()).bounds.origin.y, modelOffset, accuracy: 0.5,
                               "The viewport and native edge blur must stay fixed while the agenda springs")
                XCTAssertEqual(scroll.contentOffset.y, modelOffset, accuracy: 0.5,
                               "The spring must not compete with native scrolling frame by frame")
                detent.updateAnchor()
                XCTAssertEqual(try XCTUnwrap(detent.todayOffset), today, accuracy: 0.5)
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(contentLayer.animation(forKey: animationKey))
            XCTAssertGreaterThan(samples.count, 3, "Observe rendered motion, not just animation configuration")
            return samples
        }

        try await beginPull()
        // Translation requires real touches. Exercise the native handoff here
        // using the held position; the interaction suite drives the actual pan.
        scroll.contentOffset.y = today - 54.247
        try await returnHeldPull()
        XCTAssertFalse(events.contains(.selection), "Committing the target is not visual arrival")
        let returning = try await sampleMotion(at: today)
        XCTAssertLessThan(try XCTUnwrap(returning.min()), today - 20)
        XCTAssertGreaterThan(try XCTUnwrap(returning.max()), today + 0.1,
                             "A return must have a damped spring response, not a linear reset")
        XCTAssertLessThan(try XCTUnwrap(returning.max()), today + 3)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(events.filter { $0 == .selection }.count, 1)

        events.removeAll()
        try await beginPull()
        scroll.contentOffset.y = today - 54.247
        try await returnHeldPull()
        try await Task.sleep(for: .milliseconds(30))
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        let grabDeadline = Date().addingTimeInterval(3)
        while detent.phase != .interacting, Date() < grabDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(contentLayer.animation(forKey: animationKey))
        let grabbedOffset = scroll.contentOffset.y
        XCTAssertLessThan(grabbedOffset, today - 5, "A new touch must grab the visible spring, not jump to its target")
        var target = CGPoint(x: scroll.contentOffset.x, y: today - 900)
        scroll.delegate?.scrollViewWillEndDragging?(
            scroll, withVelocity: CGPoint(x: 0, y: -2), targetContentOffset: &target
        )
        XCTAssertEqual(target.y, today, accuracy: 0.5, "Regrabbing a return must retain the Today hold")
        XCTAssertFalse(events.contains(.selection), "Interrupted returns cannot produce late arrival feedback")
        detent.cancelInteraction()
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
        try await Task.sleep(for: .milliseconds(30))

        try await beginPull()
        scroll.contentOffset.y = today - 54.247
        try await Task.sleep(for: .milliseconds(30))
        try await returnHeldPull()
        let visibleAtTap = try XCTUnwrap(scroll.layer.presentation()).bounds.origin.y
            - (try XCTUnwrap(contentLayer.presentation()).transform.m42 - contentLayer.transform.m42)
        detent.phaseChanged(to: .tracking)
        XCTAssertEqual(scroll.contentOffset.y, visibleAtTap, accuracy: 0.5,
                       "A touch before the first spring frame must preserve the rendered offset")
        XCTAssertLessThan(scroll.contentOffset.y, today - 5)
        detent.phaseChanged(to: .idle)
        let afterTap = try await sampleMotion(at: today)
        XCTAssertLessThan(try XCTUnwrap(afterTap.min()), today - 5,
                          "A touch without a drag must resume the interrupted return, not strand the held offset")
        XCTAssertFalse(events.contains(.selection), "Cancelling a return with a tap must not replay feedback")

        try await beginPull()
        scroll.contentOffset.y = today - 54.247
        try await returnHeldPull()
        try await Task.sleep(for: .milliseconds(30))
        let visibleBeforeNavigation = try XCTUnwrap(scroll.layer.presentation()).bounds.origin.y
            - (try XCTUnwrap(contentLayer.presentation()).transform.m42 - contentLayer.transform.m42)
        XCTAssertTrue(UpcomingView.scrollToToday(in: scroll))
        XCTAssertEqual(scroll.contentOffset.y, visibleBeforeNavigation, accuracy: 0.5,
                       "Navigation must pick up the visible spring before animating its date target")
        let navigationDeadline = Date().addingTimeInterval(3)
        while abs(scroll.contentOffset.y - today) > 1 || detent.phase != .idle, Date() < navigationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(scroll.contentOffset.y, today, accuracy: 1)
        XCTAssertNil(contentLayer.animation(forKey: animationKey))
        XCTAssertFalse(events.contains(.selection), "Navigation must cancel pending spring feedback")
    }

    func testPageReselectionOverrideHandlesNativeLegacyAndOpaqueRequests() {
        for native in [false, true] {
            let root = UIViewController()
            let tabs = UITabBarController()
            let page = UIViewController()
            let scroll = pageScroll(in: page)
            if native {
                tabs.tabs = [UITab(title: "Upcoming", image: nil, identifier: "upcoming") { _ in page }]
            } else {
                tabs.viewControllers = [page]
            }
            root.addChild(tabs)
            let controller = bridge(in: root)
            defer { controller.restore() }
            var resets = 0
            controller.onPageReselection = { selected in
                XCTAssertTrue(selected === scroll)
                resets += 1
                return true
            }
            controller.install()
            if native {
                XCTAssertTrue(controller.tabBarController(tabs, shouldSelectTab: tabs.tabs[0]))
            } else {
                XCTAssertTrue(controller.tabBarController(tabs, shouldSelect: page))
            }
            controller.receiveScrollToTopRequest(0)
            controller.receiveScrollToTopRequest(1)
            controller.receiveScrollToTopRequest(1)
            XCTAssertEqual(resets, 2)
            XCTAssertEqual(scroll.contentOffset.y, 250, "A date-based reset must not also scroll to the start of history")

            controller.onPageReselection = UpcomingView.scrollToToday
            controller.receiveScrollToTopRequest(2)
            XCTAssertEqual(scroll.contentOffset.y, -scroll.adjustedContentInset.top)
        }
    }

    func testReselectionScrollsOnlyTheCurrentPageForNativeAndLegacyTabs() {
        for native in [false, true] {
            let root = UIViewController()
            let tabs = UITabBarController()
            let pages = (0..<3).map { _ in UIViewController() }
            let scroll = pageScroll(in: pages[0])
            let otherScroll = pageScroll(in: pages[2])
            let horizontal = UIScrollView(frame: CGRect(x: 0, y: 60, width: 300, height: 100))
            horizontal.contentSize = CGSize(width: 1800, height: 100)
            horizontal.contentOffset.x = 160
            scroll.addSubview(horizontal)
            if native {
                tabs.tabs = pages.enumerated().map { index, page in
                    UITab(title: "\(index)", image: nil, identifier: "\(index)") { _ in page }
                }
                tabs.selectedTab = tabs.tabs[0]
            } else {
                tabs.viewControllers = pages
                tabs.selectedViewController = pages[0]
            }
            root.addChild(tabs)
            let controller = bridge(in: root)
            defer { controller.restore() }
            var settingsActions = 0
            controller.action = { settingsActions += 1 }
            controller.install()

            if native {
                XCTAssertTrue(controller.tabBarController(tabs, shouldSelectTab: tabs.tabs[2]))
                XCTAssertFalse(controller.tabBarController(tabs, shouldSelectTab: tabs.tabs[1]))
            } else {
                XCTAssertTrue(controller.tabBarController(tabs, shouldSelect: pages[2]))
                XCTAssertFalse(controller.tabBarController(tabs, shouldSelect: pages[1]))
            }
            XCTAssertEqual(scroll.contentOffset.y, 250)
            XCTAssertEqual(otherScroll.contentOffset.y, 250)
            XCTAssertEqual(settingsActions, 1)
            if native {
                XCTAssertTrue(controller.tabBarController(tabs, shouldSelectTab: tabs.tabs[0]))
            } else {
                XCTAssertTrue(controller.tabBarController(tabs, shouldSelect: pages[0]))
            }
            XCTAssertEqual(scroll.contentOffset.y, -scroll.adjustedContentInset.top)
            XCTAssertEqual(scroll.contentOffset.x, 30)
            XCTAssertEqual(horizontal.contentOffset.x, 160)
            XCTAssertEqual(otherScroll.contentOffset.y, 250)
        }
    }

    func testOpaqueReselectionRequestsDoNotReplayOnMountOrUnrelatedUpdates() {
        let root = UIViewController()
        let tabs = UITabBarController()
        let page = UIViewController()
        let scroll = pageScroll(in: page)
        tabs.viewControllers = [page, UIViewController()]
        root.addChild(tabs)
        let controller = bridge(in: root)
        defer { controller.restore() }
        controller.install()
        controller.receiveScrollToTopRequest(8)
        XCTAssertEqual(scroll.contentOffset.y, 250)
        controller.receiveScrollToTopRequest(9)
        XCTAssertEqual(scroll.contentOffset.y, -scroll.adjustedContentInset.top)
        scroll.contentOffset.y = 200
        controller.receiveScrollToTopRequest(9)
        XCTAssertEqual(scroll.contentOffset.y, 200)
    }

    func testRejectedReselectionKeepsThePagePosition() {
        let root = UIViewController()
        let tabs = UITabBarController()
        let page = UIViewController()
        let scroll = pageScroll(in: page)
        tabs.tabs = [UITab(title: "Home", image: nil, identifier: "home") { _ in page }]
        let original = Delegate()
        tabs.delegate = original
        root.addChild(tabs)
        let controller = bridge(in: root)
        defer { controller.restore() }
        controller.install()
        XCTAssertFalse(controller.tabBarController(tabs, shouldSelectTab: tabs.tabs[0]))
        XCTAssertFalse(controller.tabBarController(tabs, shouldSelect: page))
        XCTAssertEqual(scroll.contentOffset.y, 250)
    }

    func testOpaqueReselectionScrollsOverflowContentWithoutChangingMoreNavigation() throws {
        let root = UIViewController()
        let tabs = UITabBarController()
        let pages = (0..<12).map { _ in UIViewController() }
        let scroll = pageScroll(in: pages[11])
        tabs.viewControllers = pages
        root.addChild(tabs)
        let more = tabs.moreNavigationController
        let moreRoot = try XCTUnwrap(more.viewControllers.first)
        tabs.selectedViewController = more
        more.setViewControllers([moreRoot, pages[11]], animated: false)
        let controller = bridge(in: root)
        defer { controller.restore() }
        controller.install()

        XCTAssertTrue(controller.tabBarController(tabs, shouldSelect: more))
        XCTAssertEqual(scroll.contentOffset.y, 250, "More keeps its native back-to-list behavior.")
        controller.receiveScrollToTopRequest(0)
        controller.receiveScrollToTopRequest(1)
        XCTAssertEqual(scroll.contentOffset.y, -scroll.adjustedContentInset.top)
        XCTAssertTrue(more.topViewController === pages[11])
    }

    private func pageScroll(in controller: UIViewController) -> UIScrollView {
        controller.view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        let hidden = ImmediateScrollView(frame: controller.view.bounds)
        hidden.contentSize = CGSize(width: 320, height: 2000)
        hidden.isHidden = true
        controller.view.addSubview(hidden)
        let scroll = ImmediateScrollView(frame: controller.view.bounds)
        scroll.contentSize = CGSize(width: 600, height: 2400)
        scroll.contentInset.top = 24
        scroll.contentOffset = CGPoint(x: 30, y: 250)
        controller.view.addSubview(scroll)
        return scroll
    }

    private final class ImmediateScrollView: UIScrollView {
        override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            super.setContentOffset(contentOffset, animated: false)
        }
    }

    func testNativeTabsIdentifyOverflowWhenLegacyControllersAreEmpty() async throws {
        let root = UIViewController()
        let tabs = NativeOnlyTabs()
        let pages = (0..<6).map { _ in UIViewController() }
        tabs.tabs = pages.enumerated().map { index, page in
            UITab(title: "Page \(index)", image: nil, identifier: "\(index)") { _ in page }
        }
        root.addChild(tabs)
        let more = tabs.moreNavigationController
        let moreRoot = try XCTUnwrap(more.viewControllers.first)
        let controller = bridge(in: root)
        let overflow = PlozziOSOverflowNavigation()
        controller.overflowNavigation = overflow
        defer { controller.restore() }
        controller.install()

        more.setViewControllers([moreRoot, pages[5]], animated: false)
        controller.navigationController(more, didShow: pages[5], animated: false)
        await Task.yield()

        XCTAssertTrue(tabs.viewControllers?.isEmpty == true)
        XCTAssertTrue(more.isNavigationBarHidden)
        XCTAssertEqual(overflow.destinationIndex, 5)
        var actions = 0
        controller.action = { actions += 1 }
        XCTAssertFalse(controller.tabBarController(tabs, shouldSelect: pages[1]))
        XCTAssertEqual(actions, 1)
    }

    func testOverflowUsesOneBarAndRestoresMoreWithoutReplacingTheTabStack() async throws {
        let root = UIViewController()
        let tabs = UITabBarController()
        // Newer runtimes can display more than five tabs without using More.
        let pages = (0..<12).map { _ in UIViewController() }
        let destinationIndex = pages.count - 1
        tabs.tabs = pages.enumerated().map { index, page in
            UITab(title: "Page \(index)", image: UIImage(systemName: "folder"), identifier: "\(index)") { _ in page }
        }
        root.addChild(tabs)
        root.view.addSubview(tabs.view)
        tabs.view.frame = root.view.bounds
        tabs.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tabs.didMove(toParent: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        await Task.yield()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let more = tabs.moreNavigationController
        let moreRoot = try XCTUnwrap(more.viewControllers.first)
        let original = NavigationDelegate()
        more.delegate = original
        let controller = bridge(in: root)
        let overflow = PlozziOSOverflowNavigation()
        controller.overflowNavigation = overflow
        defer { controller.restore() }
        controller.install()

        XCTAssertLessThan(tabs.tabBar.items?.count ?? pages.count, pages.count)
        XCTAssertFalse((tabs.tabBar.items ?? []).contains { $0 === pages[destinationIndex].tabBarItem })
        tabs.selectedTab = tabs.tabs[destinationIndex]
        let deadline = Date().addingTimeInterval(2)
        while overflow.destinationIndex != destinationIndex, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(more.isNavigationBarHidden, "The outer bar must not sit above the page's NavigationStack.")
        XCTAssertEqual(overflow.destinationIndex, destinationIndex)
        XCTAssertTrue(more.topViewController === pages[destinationIndex], "Keep the original tab controller and its navigation state.")
        XCTAssertGreaterThan(original.willShowCount, 0)
        XCTAssertGreaterThan(original.didShowCount, 0)

        more.popToRootViewController(animated: false)
        let returnDeadline = Date().addingTimeInterval(2)
        while overflow.destinationIndex != nil, Date() < returnDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(more.topViewController === moreRoot)
        XCTAssertFalse(more.isNavigationBarHidden)
        XCTAssertNil(overflow.destinationIndex)
        controller.restore()
        XCTAssertTrue(more.delegate === original)
    }

    func testRemovingOverflowBridgeRestoresOriginalNavigationBarVisibility() {
        let root = UIViewController()
        let tabs = UITabBarController()
        let pages = (0..<6).map { _ in UIViewController() }
        tabs.viewControllers = pages
        root.addChild(tabs)
        let more = tabs.moreNavigationController
        let controller = bridge(in: root)
        controller.overflowNavigation = PlozziOSOverflowNavigation()
        controller.install()
        controller.navigationController(more, willShow: pages[5], animated: false)
        XCTAssertTrue(more.isNavigationBarHidden)

        controller.restore()

        XCTAssertFalse(more.isNavigationBarHidden)
    }

    func testOverlappingBridgesNeverForwardToEachOther() {
        let root = UIViewController()
        let tabs = UITabBarController()
        let original = Delegate()
        tabs.delegate = original
        root.addChild(tabs)
        let first = bridge(in: root)
        let second = bridge(in: root)
        defer { first.restore(); second.restore() }

        for _ in 0..<4 {
            first.install()
            second.install()
        }
        let selection = #selector(UITabBarControllerDelegate.tabBarController(_:didSelect:))
        XCTAssertTrue(second.responds(to: selection))
        XCTAssertTrue(second.forwardingTarget(for: selection) as AnyObject === original)
        XCTAssertFalse(second.responds(to: NSSelectorFromString("plozzUnknownDelegateSelector")))

        first.restore()
        XCTAssertTrue(tabs.delegate === second, "A displaced bridge must not uninstall its replacement.")
        second.restore()
        XCTAssertTrue(tabs.delegate === original)
    }

    func testSettingsRemainsAnActionAndOtherSelectionsReachOriginalDelegate() {
        let root = UIViewController()
        let tabs = UITabBarController()
        let original = Delegate()
        let home = UIViewController()
        let settings = UIViewController()
        tabs.viewControllers = [home, settings]
        tabs.delegate = original
        root.addChild(tabs)
        let controller = bridge(in: root)
        defer { controller.restore() }
        var actions = 0
        controller.action = { actions += 1 }
        controller.install()

        XCTAssertFalse(controller.tabBarController(tabs, shouldSelect: settings))
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(original.selections, 0)
        XCTAssertFalse(controller.tabBarController(tabs, shouldSelect: home))
        XCTAssertEqual(original.selections, 1)
        XCTAssertEqual(actions, 1)
    }

    func testNativeTabSelectionPreservesSettingsActionAndForwarding() {
        let root = UIViewController()
        let tabs = UITabBarController()
        let original = Delegate()
        let home = UITab(title: "Home", image: nil, identifier: "home") { _ in UIViewController() }
        let settings = UITab(title: "Settings", image: nil, identifier: "settings") { _ in UIViewController() }
        tabs.tabs = [home, settings]
        tabs.delegate = original
        root.addChild(tabs)
        let controller = bridge(in: root)
        defer { controller.restore() }
        var actions = 0
        controller.action = { actions += 1 }
        controller.install()

        XCTAssertFalse(controller.tabBarController(tabs, shouldSelectTab: settings))
        XCTAssertEqual(actions, 1)
        XCTAssertFalse(controller.tabBarController(tabs, shouldSelectTab: home))
        XCTAssertEqual(original.selections, 1)
    }

    func testRemovalDoesNotOverwriteAnExternallyReplacedDelegate() {
        let root = UIViewController()
        let tabs = UITabBarController()
        let original = Delegate()
        let replacement = Delegate()
        tabs.delegate = original
        root.addChild(tabs)
        let controller = bridge(in: root)
        controller.install()
        tabs.delegate = replacement

        controller.restore()

        XCTAssertTrue(tabs.delegate === replacement)
    }

    private func bridge(in root: UIViewController) -> PlozziOSSettingsTabAction.Controller {
        let controller = PlozziOSSettingsTabAction.Controller()
        controller.tabIndex = 1
        root.addChild(controller)
        return controller
    }

    private final class Delegate: NSObject, UITabBarControllerDelegate {
        var selections = 0

        func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            selections += 1
            return false
        }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            selections += 1
            return false
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {}
    }

    private final class NavigationDelegate: NSObject, UINavigationControllerDelegate {
        var willShowCount = 0
        var didShowCount = 0

        func navigationController(
            _ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool
        ) {
            willShowCount += 1
        }

        func navigationController(
            _ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool
        ) {
            didShowCount += 1
        }
    }

    private final class NativeOnlyTabs: UITabBarController {
        override var viewControllers: [UIViewController]? {
            get { [] }
            set { super.viewControllers = newValue }
        }
    }
}
#endif
