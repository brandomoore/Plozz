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

    func testCategoryEntryRestoresSelectionAfterFocusLeavesThePane() async throws {
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
        let category = try XCTUnwrap(visibleCategoryFocusItems(in: window, scroll: scroll).first)
        let targetFrame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: category, relativeTo: scroll))
        XCTAssertEqual(targetFrame.minY, initialFrame.minY, accuracy: 1,
                       "A real departure must retain selected-category entry rather than preferring Search.")
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
        host.target = nil
        state.request += 1
        try await Task.sleep(for: .milliseconds(250))
        let restored = try XCTUnwrap(system.focusedItem)
        let restoredFrame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: restored, relativeTo: scroll))
        XCTAssertEqual(restoredFrame.minY, initialFrame.minY, accuracy: 1,
                       "A new explicit entry request must still restore the selected category.")
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
            HStack(alignment: .top, spacing: 80) {
                PrototypeBrowseSidebar(
                    model: state.model, active: $state.active, focusRequest: 0,
                    categoryFocusRequest: state.request, restoresCategoryFocus: true,
                    search: {}, enterGuide: {}
                )
                .frame(width: 384, height: 900)
                Button("Guide") {}
                    .frame(width: 300, height: 100)
                    .disabled(!state.allowsExternalFocus)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(60)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
        }
    }

    private final class CategoryFocusHost: UIHostingController<CategoryFocusPage> {
        weak var target: (any UIFocusEnvironment)?
        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            target.map { [$0] } ?? super.preferredFocusEnvironments
        }
    }

    func testScheduledAndUnscheduledChannelsTravelTogetherWithTheSidebar() async throws {
        try await assertMixedGuideMotion()
    }

    func testMixedGuideRowsStayTogetherInRightToLeftLayout() async throws {
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
            model.collapsed = collapsed
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
                        model: model.sidebar,
                        active: Binding(get: { model.sidebarActive }, set: { model.sidebarActive = $0 }),
                        focusRequest: 0, search: {}, enterGuide: {}, multiviews: {}
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
