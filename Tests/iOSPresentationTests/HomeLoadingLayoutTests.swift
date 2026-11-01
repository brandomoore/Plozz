#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
import HeroUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class HomeLoadingLayoutTests: XCTestCase {
    func testBrowseActionDoesNotChangeTheHeightOfALoadingRow() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for width in [CGFloat(390), 768] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let heights = Heights()
                fixture.mount(
                    ScrollView {
                        VStack(spacing: 0) {
                            PlozziOSHomeSkeletonRail(title: Text("Recently Added"), style: .poster)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loading = $0 }
                            PlozziOSHomeMediaRail(
                                title: Text("Recently Added"), items: fixture.items,
                                style: .poster, appModel: fixture.app, onBrowse: {}
                            )
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loaded = $0 }
                        }
                    }
                    .environment(\.dynamicTypeSize, size),
                    width: width
                )
                try await fixture.settle()
                XCTAssertGreaterThan(heights.loading, 0)
                XCTAssertEqual(heights.loading, heights.loaded, accuracy: 1, "\(width), \(size)")
            }
        }
    }

    func testRemovingAnEmptyRowAboveTheViewportKeepsTheVisibleRowInPlace() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let state = Rows()
        fixture.mount(LoadingRows(app: fixture.app, items: fixture.items, state: state))
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.scrollViews().first { $0.contentSize.height > $0.bounds.height })
        let marker = try XCTUnwrap(fixture.find("row-3"))
        let contentY = marker.convert(.zero, to: scroll).y
        scroll.setContentOffset(CGPoint(x: 0, y: contentY - 100), animated: false)
        try await fixture.settle()
        let before = marker.convert(.zero, to: fixture.window).y
        XCTAssertEqual(before, 100, accuracy: 1)
        let oldHeight = scroll.contentSize.height
        state.rows.removeFirst()
        try await fixture.settle()
        XCTAssertLessThan(scroll.contentSize.height, oldHeight, "An empty row must not leave a permanent gap.")
        XCTAssertEqual(try XCTUnwrap(fixture.find("row-3")).convert(.zero, to: fixture.window).y,
                       before, accuracy: 1, "Removing an empty row above must not move the visible content.")
    }

    func testReplacingSkeletonsWhileScrolledKeepsPageHeightAndPosition() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let state = Rows()
        fixture.mount(LoadingRows(app: fixture.app, items: fixture.items, state: state))
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.scrollViews().first { $0.contentSize.height > $0.bounds.height })
        scroll.setContentOffset(CGPoint(x: 0, y: 450), animated: false)
        try await fixture.settle()
        let height = scroll.contentSize.height
        let offset = scroll.contentOffset.y
        state.loading = false
        try await fixture.settle()
        XCTAssertEqual(scroll.contentSize.height, height, accuracy: 1)
        XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 1)
    }

    func testRowChangesPreserveTheViewportWithAContentInset() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let state = Rows()
        fixture.mount(LoadingRows(app: fixture.app, items: fixture.items, state: state)
            .safeAreaInset(edge: .top) { Color.clear.frame(height: 80) })
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.scrollViews().first { $0.contentSize.height > $0.bounds.height })
        let marker = try XCTUnwrap(fixture.find("row-3"))
        scroll.setContentOffset(CGPoint(x: 0, y: marker.convert(.zero, to: scroll).y - 100), animated: false)
        try await fixture.settle()
        let before = marker.convert(.zero, to: fixture.window).y
        state.rows.removeFirst()
        try await fixture.settle()
        XCTAssertEqual(try XCTUnwrap(fixture.find("row-3")).convert(.zero, to: fixture.window).y, before, accuracy: 1)
        state.rows.insert(.init(number: 99), at: 0)
        try await fixture.settle()
        XCTAssertEqual(try XCTUnwrap(fixture.find("row-3")).convert(.zero, to: fixture.window).y, before, accuracy: 1)
    }

    func testSuccessiveLayoutChangesAccumulateUntilTheScrollPositionArrives() {
        let preservation = PlozziOSHomeScrollPreservation()
        preservation.geometry = ScrollGeometry(
            contentOffset: CGPoint(x: 0, y: 400), contentSize: CGSize(width: 390, height: 2000),
            contentInsets: .init(), containerSize: CGSize(width: 390, height: 600)
        )
        let id = HomeRowID.global(.recentlyAdded)
        XCTAssertNil(preservation.offset(after: [id: CGRect(x: 0, y: 300, width: 390, height: 300)]))
        XCTAssertEqual(preservation.offset(after: [id: CGRect(x: 0, y: 200, width: 390, height: 300)]), 300)
        XCTAssertEqual(preservation.offset(after: [id: CGRect(x: 0, y: 100, width: 390, height: 300)]), 200)
        preservation.geometry?.contentOffset.y = 200
        XCTAssertNil(preservation.offset(after: [id: CGRect(x: 0, y: 100, width: 390, height: 300)]))
        preservation.geometry?.contentOffset.y = 0
        XCTAssertNil(preservation.offset(after: [id: CGRect(x: 0, y: 0, width: 390, height: 300)]),
                     "At the top, loading must keep the top rather than scroll to a previously visible row.")
        preservation.geometry?.contentOffset.y = 100
        preservation.geometry?.containerSize.height = 500
        XCTAssertNil(preservation.offset(after: [id: CGRect(x: 0, y: 50, width: 390, height: 300)]),
                     "A viewport resize is not a provider row insertion.")
    }

    func testFeaturedCollectionSkeletonMatchesTheFeaturedCardHeight() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let coordinator = FeaturedTrailerCoordinator()
        let controller = HeroTrailerController()
        for width in [CGFloat(390), 768] {
            let heights = Heights()
            fixture.mount(
                ScrollView {
                    VStack {
                        FeaturedMediaRow(
                            title: Text("Featured"), items: [], scope: ObjectIdentifier(controller),
                            coordinator: coordinator, controller: controller, settings: .default,
                            resolver: { _ in nil }, isActive: false, onSelect: { _ in }
                        )
                        .browsingRow(nil)
                        .loading(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loading = $0 }
                        FeaturedMediaRow(
                            title: Text("Featured"), items: fixture.items, scope: ObjectIdentifier(controller),
                            coordinator: coordinator, controller: controller, settings: .default,
                            resolver: { _ in nil }, isActive: false, onSelect: { _ in }
                        )
                        .browsingRow({})
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loaded = $0 }
                    }
                },
                width: width
            )
            try await fixture.settle()
            XCTAssertGreaterThan(heights.loaded, 0)
            XCTAssertEqual(heights.loading, heights.loaded, accuracy: 1)
        }
    }

    func testLibrarySkeletonUsesTheLibraryTilesGeometry() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let library = AggregatedLibrary(
            accountID: "fixture", accountName: "Fixture", serverName: "Server", providerKind: .jellyfin,
            library: MediaLibrary(id: "movies", title: "Movies", kind: .movie)
        )
        for style in [CardStyle.borderless, .framed] {
            for captions in [true, false] {
                let heights = Heights()
                fixture.mount(
                    ScrollView {
                        VStack {
                            PlozziOSHomeSkeletonRail(
                                title: Text("Libraries"), style: .landscape, showsCaption: captions, isLibraryRow: true
                            )
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loading = $0 }
                            PlozziOSMediaSection(title: Text("Libraries")) {
                                ScrollView(.horizontal) {
                                    HStack(spacing: PlozziOSMediaRailLayout.visibleSpacing) {
                                        ForEach(0..<8, id: \.self) { _ in
                                            PlozziOSHomeLibraryCard(library: library, artworkSource: nil, width: 220)
                                        }
                                    }
                                }
                                .contentMargins(.horizontal, 22, for: .scrollContent)
                                .plozziOSMediaRailClearance()
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loaded = $0 }
                        }
                    }
                    .environment(\.plozzCardStyle, style)
                    .environment(\.plozzCardCaptionSettings, CardCaptionSettings(showsLabels: captions))
                )
                try await fixture.settle()
                XCTAssertGreaterThan(heights.loaded, 0)
                XCTAssertEqual(heights.loading, heights.loaded, accuracy: 1, "\(style), captions=\(captions)")
            }
        }
    }

    func testPerformanceLoadingWhileScrolling() async throws {
        try PerformanceProbe.requireEnabled()
        let fixture = try Fixture()
        defer { fixture.close() }
        let state = Rows()
        fixture.mount(LoadingRows(app: fixture.app, items: fixture.items, state: state))
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.scrollViews().first { $0.contentSize.height > $0.bounds.height })
        try await PerformanceProbe.measure(self, scenario: "mobile-home-loading-scroll") {
            state.loading = true
            state.loaded = []
            scroll.setContentOffset(.zero, animated: false)
            try await fixture.settle()
            let height = scroll.contentSize.height
            let destination = (height - scroll.bounds.height) * 0.75
            var greatestHeightChange: CGFloat = 0
            for index in 0..<8 {
                scroll.setContentOffset(CGPoint(x: 0, y: destination * CGFloat(index + 1) / 8), animated: true)
                try await Task.sleep(for: .milliseconds(40))
                state.loaded.insert(index)
                try await Task.sleep(for: .milliseconds(40))
                greatestHeightChange = max(greatestHeightChange, abs(scroll.contentSize.height - height))
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while abs(scroll.contentOffset.y - destination) > 1, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(state.loaded.count, 8)
            XCTAssertEqual(scroll.contentOffset.y, destination, accuracy: 1)
            XCTAssertLessThanOrEqual(greatestHeightChange, 1)
            return ["loadedRows": 8, "scrollTargets": 8, "itemsPerRow": fixture.items.count,
                    "maximumPageHeightChangePoints": Int(greatestHeightChange.rounded())]
        }
    }

    @MainActor private final class Heights {
        var loading: CGFloat = 0
        var loaded: CGFloat = 0
    }

    @MainActor @Observable final class Rows {
        struct Row: Identifiable {
            let number: Int
            var id: HomeRowID { .library(key: "fixture-\(number)", section: "recentlyAdded") }
        }
        var rows = (0..<8).map { Row(number: $0) }
        var loading = true
        var loaded: Set<Int> = []
    }

    private struct LoadingRows: View {
        let app: PlozziOSAppModel
        let items: [MediaItem]
        let state: Rows

        var body: some View {
            PlozziOSHomeScrollView(heroActive: false) {
                EmptyView()
            } rows: {
                ForEach(state.rows) { row in
                    Group {
                        if state.loading && !state.loaded.contains(row.number) {
                            PlozziOSHomeSkeletonRail(title: Text(verbatim: "Row \(row.number)"), style: .poster)
                        } else {
                            PlozziOSHomeMediaRail(
                                title: Text(verbatim: "Row \(row.number)"), items: items,
                                style: .poster, appModel: app, onBrowse: {}
                            )
                        }
                    }
                    .background(RowMarker(name: "row-\(row.number)"))
                    .plozziOSHomeScrollRow(row.id)
                }
            }
        }
    }

    private struct RowMarker: UIViewRepresentable {
        let name: String
        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.accessibilityIdentifier = name
            view.isUserInteractionEnabled = false
            return view
        }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    @MainActor private final class Fixture {
        let app: PlozziOSAppModel
        let items: [MediaItem]
        let window: UIWindow
        let previous: UIWindow?
        let suite = "HomeLoadingLayout.\(UUID())"
        let defaults: UserDefaults
        let profileID: String

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            app = PlozziOSAppModel(
                accountStore: AccountStore(secureStore: InMemorySecureStore()),
                profileStore: ProfileStore(defaults: defaults)
            )
            profileID = app.profiles.add(name: "Fixture", isAwaitingSetup: false).id
            app.selectProfile(profileID)
            app.settings.cardStyle.artwork = ArtworkSettings(preference: .library)
            app.settings.cardStyle.captions = CardCaptionSettings(showsLabels: true)
            items = (0..<20).map {
                MediaItem(id: "loading-\($0)", title: "Movie", kind: .movie,
                          allowsTitleBasedMetadataMatching: false)
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = .dark
        }

        func mount(_ view: some View, width: CGFloat = 390) {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            let host = UIHostingController(rootView: view
                .environment(app)
                .environment(\.horizontalSizeClass, width < 600 ? .compact : .regular)
                .environment(\.plozzCardStyle, .borderless)
                .environment(\.plozzMetrics, .touch(density: .standard))
                .environment(\.themePalette, .dark))
            host.safeAreaRegions = []
            window.rootViewController = host
            window.makeKeyAndVisible()
        }

        func settle() async throws {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
        }

        func scrollViews() -> [UIScrollView] {
            func walk(_ view: UIView) -> [UIScrollView] {
                ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(walk)
            }
            return walk(window)
        }

        func find(_ name: String) -> UIView? {
            func walk(_ view: UIView) -> UIView? {
                if view.accessibilityIdentifier == name { return view }
                return view.subviews.lazy.compactMap(walk).first
            }
            return walk(window)
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.components(separatedBy: ".").contains(profileID) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
#endif
