#if DEBUG && os(tvOS)
import CoreUI
import FeatureLiveTVCore
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

@MainActor
final class PrototypeNativeGuideListTests: XCTestCase {
    private typealias Guide = PrototypeNativeGuideList<Int, Text>

    func testLayoutIncludesSectionHeadersAndOnlyReturnsIntersectingRows() throws {
        let layout = PrototypeGuideCollectionLayout()
        let collection = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 1_400, height: 720), collectionViewLayout: layout)
        layout.update(rowCount: 100_000, rowHeight: 144, sectionHeight: 68, sectionStarts: [2, 5])
        let expectedHeights: [CGFloat] = [144, 144, 212, 144, 144, 212, 144]
        var y = PrototypeLayout.smallGap
        for (index, height) in expectedHeights.enumerated() {
            let attributes = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0)))
            XCTAssertEqual(attributes.frame, CGRect(x: 0, y: y, width: 1_400, height: height))
            XCTAssertEqual(
                layout.layoutAttributesForElements(in: attributes.frame)?.map(\.indexPath.item), [index])
            y += height
        }
        let target = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 99_900, section: 0)))
        let visible = try XCTUnwrap(layout.layoutAttributesForElements(in: CGRect(
            x: 0, y: target.frame.minY, width: 1_400, height: 720)))
        XCTAssertEqual(visible.map(\.indexPath.item), Array(99_900..<99_905))
        XCTAssertEqual(layout.collectionViewContentSize.height, PrototypeLayout.smallGap + 100_000 * 144 + 2 * 68)
        XCTAssertEqual(layout.collectionViewContentSize.width, collection.bounds.width)
        XCTAssertNil(layout.layoutAttributesForItem(at: IndexPath(item: 100_000, section: 0)))
        XCTAssertTrue(try XCTUnwrap(layout.layoutAttributesForElements(in: CGRect(x: 0, y: -100, width: 100, height: 10))).isEmpty)
    }

    func testLayoutAdaptsToScaledHeightsWidthAndCatalogRemoval() throws {
        let layout = PrototypeGuideCollectionLayout()
        let collection = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 1_400, height: 720), collectionViewLayout: layout)
        layout.update(rowCount: 30, rowHeight: 288, sectionHeight: 100, sectionStarts: [2, 5])
        let section = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 5, section: 0)))
        XCTAssertEqual(section.frame.height, 388)
        XCTAssertEqual(section.frame.minY, PrototypeLayout.smallGap + 5 * 288 + 100)
        XCTAssertTrue(layout.shouldInvalidateLayout(forBoundsChange: CGRect(x: 0, y: 0, width: 600, height: 720)))
        XCTAssertFalse(layout.shouldInvalidateLayout(forBoundsChange: collection.bounds.offsetBy(dx: 0, dy: 288)))
        collection.bounds.size.width = 600
        XCTAssertEqual(layout.layoutAttributesForItem(at: section.indexPath)?.frame.width, 600)
        layout.update(rowCount: 0, rowHeight: 288, sectionHeight: 100, sectionStarts: [])
        XCTAssertNil(layout.layoutAttributesForItem(at: section.indexPath))
        XCTAssertTrue(try XCTUnwrap(layout.layoutAttributesForElements(in: collection.bounds)).isEmpty)
        XCTAssertEqual(layout.collectionViewContentSize.height, PrototypeLayout.smallGap)
    }

    func testColdRestorationIntoHundredThousandRowsRemainsBounded() {
        let rows = (0..<100_000).map { LiveTVGuideRowID(channelID: "channel-\($0)") }
        let scroll = PrototypeGuideScrollController()
        var renders = 0
        let list = Guide(
            rows: rows, scrollController: scroll, scrolled: { _, _ in }, revision: { _ in 0 }
        ) { row in
            renders += 1
            return Text(row.channelID)
        }
        let controller = Guide.Controller()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 720))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            Guide.dismantleUIViewController(controller, coordinator: ())
        }
        controller.view.frame = window.bounds
        controller.update(list, environment: EnvironmentValues())
        let started = ContinuousClock.now
        scroll.scrollTo(rows[99_900], anchor: .center)
        controller.view.layoutIfNeeded()
        let elapsed = started.duration(to: .now)
        print("Guide cold restoration: rows=100000 elapsed=\(elapsed) rendered=\(renders)")
        XCTAssertLessThan(elapsed, .milliseconds(500), "Restoration must not synchronously lay out the entire catalog")
        XCTAssertLessThan(renders, 100)
        XCTAssertTrue(controller.collectionView.indexPathsForVisibleItems.contains { $0.item == 99_900 })
        for (index, anchor) in [(0, UnitPoint.top), (99_999, .center), (50_000, .top)] {
            scroll.scrollTo(rows[index], anchor: anchor)
            controller.view.layoutIfNeeded()
            XCTAssertTrue(controller.collectionView.indexPathsForVisibleItems.contains { $0.item == index })
        }
    }

    func testThousandsOfChannelsOnlyCreateVisibleRowHostsAndReuseUnchangedContent() {
        let rows = (0..<5_000).map { LiveTVGuideRowID(channelID: "channel-\($0)") }
        let scroll = PrototypeGuideScrollController()
        var renders = 0
        let list = Guide(
            rows: rows, scrollController: scroll, scrolled: { _, _ in }, revision: { _ in 0 }
        ) { row in
            renders += 1
            return Text(row.channelID)
        }
        let controller = Guide.Controller()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 720))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            Guide.dismantleUIViewController(controller, coordinator: ())
        }
        controller.view.frame = window.bounds
        controller.update(list, environment: EnvironmentValues())
        controller.view.layoutIfNeeded()
        let rendered = renders
        XCTAssertGreaterThan(rendered, 0)
        XCTAssertLessThan(rendered, 100, "Offscreen channels must not materialize a full-catalog focus tree")
        XCTAssertLessThan(controller.children.count, 100)

        controller.update(list, environment: EnvironmentValues())
        controller.view.layoutIfNeeded()
        XCTAssertEqual(renders, rendered, "Unchanged row revisions must reuse their hosted content")

        scroll.scrollTo(rows[4_900], anchor: .top)
        controller.view.layoutIfNeeded()
        XCTAssertLessThan(renders, 200)
        XCTAssertLessThan(controller.children.count, 100, "Offscreen hosts must leave the controller hierarchy")
    }

    func testPresentationEnvironmentIgnoresPrivateFocusChangesButTracksVisiblePreferences() {
        var environment = EnvironmentValues()
        let baseline = Guide.RowEnvironment(environment)
        XCTAssertEqual(baseline, Guide.RowEnvironment(environment))
        environment.isEnabled = false
        XCTAssertNotEqual(baseline, Guide.RowEnvironment(environment))
        environment.isEnabled = true
        environment.layoutDirection = .rightToLeft
        XCTAssertNotEqual(baseline, Guide.RowEnvironment(environment))
    }
}
#endif
