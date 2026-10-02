#if os(tvOS)
import CoreModels
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI
@testable import FeatureHome

@MainActor
final class MediaRowExposureHostedTests: XCTestCase {
    func testShowcaseNativeHostsRespectTheVerticalViewportDuringRowChanges() async throws {
        let model = FocusHeroModel()
        let rows = (0..<3).map { row in
            let items = (0..<20).map {
                MediaItem(id: "\(row)-\($0)", title: "Title \(row)-\($0)", kind: .movie)
            }
            return FocusHeroRow(id: "row-\(row)", itemIDs: items.map(\.stablePresentationID),
                                leadItem: items.first, items: items)
        }
        var records: Set<String> = []
        let controller = UIHostingController(rootView:
            FocusHeroScrollingRows(rows: rows, model: model) { row, _ in
                MediaRowView(
                    title: Text(verbatim: row.id), items: row.items,
                    onItemExposed: { records.insert($0.id) }, onSelect: { _ in }
                )
            }
            .frame(width: 1920, height: 1080)
            .environment(\.scenePhase, .active)
            .ignoresSafeArea()
        )
        let window = try await host(controller)
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertGreaterThan(records.count, 1)
        XCTAssertTrue(records.allSatisfy { $0.hasPrefix("0-") })
        model.activate(rows[1], in: rows)
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertGreaterThan(records.filter { $0.hasPrefix("1-") }.count, 1)
        XCTAssertFalse(records.contains { $0.hasPrefix("2-") })
    }

    func testOnlyActuallyVisibleCardsCountAndHorizontalBrowsingFindsUnseenCards() async throws {
        let window = try await host(UIViewController())
        defer { close(window) }
        let viewport = UIView(frame: CGRect(x: 40, y: 40, width: 250, height: 140))
        viewport.clipsToBounds = true
        window.rootViewController!.view.addSubview(viewport)
        let tracker = MediaRowExposureTracker()
        var records: [String] = []
        tracker.onExposure = { records.append($0.id) }
        tracker.setActive(true)
        defer { tracker.setActive(false) }
        for index in 0..<4 {
            let anchor = MediaRowExposureAnchorView(
                frame: CGRect(x: index * 120, y: 0, width: 100, height: 100)
            )
            anchor.item = item(index)
            tracker.register(anchor)
            viewport.addSubview(anchor)
        }
        tracker.sample(at: 0)
        tracker.sample(at: 1.9)
        XCTAssertTrue(records.isEmpty)
        tracker.sample(at: 2)
        XCTAssertEqual(Set(records), ["0", "1"])
        viewport.bounds.origin.x = 120
        tracker.sample(at: 3)
        tracker.sample(at: 5)
        XCTAssertEqual(Set(records), ["0", "1", "2"])
        XCTAssertEqual(records.count, 3, "An exposed card is not recorded on every tick.")
    }

    func testVerticalClippingMaskAndInactiveTimeDoNotCountAsExposure() async throws {
        let window = try await host(UIViewController())
        defer { close(window) }
        let viewport = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        viewport.clipsToBounds = true
        window.rootViewController!.view.addSubview(viewport)
        let anchor = MediaRowExposureAnchorView(frame: CGRect(x: 0, y: 220, width: 100, height: 100))
        anchor.item = item(0)
        viewport.addSubview(anchor)
        let tracker = MediaRowExposureTracker()
        tracker.register(anchor)
        var records: [String] = []
        tracker.onExposure = { records.append($0.id) }
        tracker.setActive(true)
        defer { tracker.setActive(false) }
        tracker.sample(at: 0)
        tracker.sample(at: 3)
        XCTAssertTrue(records.isEmpty)

        anchor.frame.origin.y = 0
        let mask = CALayer()
        mask.frame = CGRect(x: 0, y: 120, width: 400, height: 80)
        viewport.layer.mask = mask
        tracker.sample(at: 4)
        tracker.sample(at: 7)
        XCTAssertTrue(records.isEmpty)
        viewport.layer.mask = nil
        tracker.sample(at: 8)
        tracker.setActive(false)
        tracker.sample(at: 12)
        tracker.setActive(true)
        tracker.sample(at: 13)
        tracker.sample(at: 14.9)
        XCTAssertTrue(records.isEmpty)
        tracker.sample(at: 15)
        XCTAssertEqual(records, ["0"])
    }

    func testRealRowTracksVisibleUnfocusedCardsAndStopsWhenCoveredOrUnmounted() async throws {
        let fixture = RowExposureFixture()
        let controller = UIHostingController(rootView: RowExposureFixtureView(fixture: fixture))
        let window = try await host(controller)
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(2700))
        XCTAssertTrue(fixture.records.isEmpty, "A covered Home must not record cards.")
        fixture.isFrontmost = true
        try await Task.sleep(for: .milliseconds(3200))
        let anchors = descendants(controller.view).compactMap { $0 as? MediaRowExposureAnchorView }
        let visible = Set(anchors.filter(MediaRowExposureTracker.isVisible).compactMap { $0.item?.id })
        XCTAssertGreaterThan(visible.count, 1, "Exposure includes visible cards without focus.")
        XCTAssertLessThan(visible.count, 20)
        XCTAssertEqual(Set(fixture.records), visible)
        let tracker = try XCTUnwrap(descendants(controller.view)
            .compactMap { $0 as? MediaRowExposureDriver.DriverView }.first?.tracker)
        fixture.phase = .inactive
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(tracker.isActive)
        fixture.phase = .active
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(tracker.isActive)
        fixture.isMounted = false
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(tracker.isActive)
        let count = fixture.records.count
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertEqual(fixture.records.count, count)
    }

    private func item(_ index: Int) -> MediaItem {
        MediaItem(id: String(index), title: "Title \(index)", kind: .movie)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func host(_ controller: UIViewController) async throws -> UIWindow {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
@Observable
private final class RowExposureFixture {
    var isMounted = true
    var isFrontmost = false
    var phase = ScenePhase.active
    @ObservationIgnored var records: [String] = []
}

private struct RowExposureFixtureView: View {
    let fixture: RowExposureFixture

    var body: some View {
        Group {
            if fixture.isMounted {
                MediaRowView(
                    title: Text("Discover"),
                    items: (0..<20).map {
                        MediaItem(id: String($0), title: "Title \($0)", kind: .movie)
                    },
                    onItemExposed: { fixture.records.append($0.id) },
                    isExposureActive: fixture.isFrontmost,
                    onSelect: { _ in }
                )
            } else {
                Color.clear
            }
        }
        .environment(\.scenePhase, fixture.phase)
    }
}
#endif
