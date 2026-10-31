@testable import AppShell
import CoreModels
@testable import CoreUI
import FeatureSearch
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PinnedSearchLayoutHostedTests: XCTestCase {
    func testSearchHeaderDoesNotMoveTheNavigationContainerWhenChromeHides() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let navigation = try XCTUnwrap(navigationController(in: fixture.host))
        let initial = navigation.view.convert(navigation.view.bounds, to: fixture.window)
        let search = try XCTUnwrap(searchBar(in: fixture.window))
        let searchFrame = search.convert(search.bounds, to: fixture.window)

        fixture.model.chrome.setStackDepth(1)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(navigation.view.convert(navigation.view.bounds, to: fixture.window), initial)
        XCTAssertEqual(search.convert(search.bounds, to: fixture.window), searchFrame)

        fixture.model.chrome.setStackDepth(0)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(navigation.view.convert(navigation.view.bounds, to: fixture.window), initial)
        XCTAssertEqual(search.convert(search.bounds, to: fixture.window), searchFrame)
    }

    func testSearchPushAndPopKeepAStationaryFullScreenContainer() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let navigation = try XCTUnwrap(navigationController(in: fixture.host))
        let search = try XCTUnwrap(searchBar(in: fixture.window))
        let initialSearch = search.convert(search.bounds, to: fixture.window)
        let initialContainer = navigation.view.convert(navigation.view.bounds, to: fixture.window)
        XCTAssertEqual(initialContainer, fixture.window.bounds)
        XCTAssertEqual(initialSearch.minY, 60 + NavigationRailMetrics.searchHeaderHeight, accuracy: 0.5)

        for _ in 0..<2 {
            withAnimation { fixture.model.path.append(1) }
            try await sampleContainer(navigation.view, in: fixture.window, expected: initialContainer)
            let detail = try XCTUnwrap(fixture.model.detailView)
            XCTAssertEqual(detail.convert(detail.bounds, to: fixture.window), fixture.window.bounds)
            withAnimation { fixture.model.path.removeLast() }
            try await sampleContainer(navigation.view, in: fixture.window, expected: initialContainer)
            let returned = try XCTUnwrap(searchBar(in: fixture.window))
            XCTAssertEqual(returned.convert(returned.bounds, to: fixture.window), initialSearch)
        }
    }

    func testSearchRootDoesNotReservePinnedHeaderOutsidePinnedShell() async throws {
        let fixture = try await makeFixture(isPinned: false)
        defer { fixture.close() }
        let navigation = try XCTUnwrap(navigationController(in: fixture.host))
        let search = try XCTUnwrap(searchBar(in: fixture.window))
        XCTAssertEqual(navigation.view.convert(navigation.view.bounds, to: fixture.window), fixture.window.bounds)
        XCTAssertEqual(search.convert(search.bounds, to: fixture.window).minY, 60, accuracy: 0.5)
    }

    private func sampleContainer(_ view: UIView, in window: UIWindow, expected: CGRect) async throws {
        let deadline = ContinuousClock.now + .milliseconds(700)
        var frames: [CGRect] = []
        while ContinuousClock.now < deadline {
            let layer = view.layer.presentation() ?? view.layer
            let windowLayer = window.layer.presentation() ?? window.layer
            frames.append(layer.convert(layer.bounds, to: windowLayer))
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertFalse(frames.isEmpty)
        XCTAssertEqual(try XCTUnwrap(frames.map(\.minY).min()), expected.minY, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(frames.map(\.minY).max()), expected.minY, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(frames.map(\.height).min()), expected.height, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(frames.map(\.height).max()), expected.height, accuracy: 0.5)
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigationController(in: $0) }.first
    }

    private func searchBar(in view: UIView) -> UISearchBar? {
        if let search = view as? UISearchBar { return search }
        return view.subviews.lazy.compactMap { self.searchBar(in: $0) }.first
    }

    private func makeFixture(isPinned: Bool = true) async throws -> Fixture {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene, isPinned: isPinned)
        do {
            let layoutDeadline = ContinuousClock.now + .seconds(5)
            while (searchBar(in: fixture.window)?.bounds.isEmpty != false
                   || fixture.model.search.state.value == nil),
                  ContinuousClock.now < layoutDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let sections = try XCTUnwrap(fixture.model.search.state.value)
            XCTAssertEqual(sections.flatMap(\.items).map(\.id), ["movie"])
            try await Task.sleep(for: .milliseconds(250))
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    private final class Fixture {
        let model = Model()
        let window: UIWindow
        let previous: UIWindow?
        let host: UIHostingController<SearchRoot>

        init(scene: UIWindowScene, isPinned: Bool) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            host = UIHostingController(rootView: SearchRoot(model: model, isPinned: isPinned))
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }

    @MainActor @Observable
    final class Model {
        let profile = Profile(name: "Viewer")
        let chrome = NavigationChromeModel()
        var selection = NavigationRailDestination.search
        var path = NavigationPath()
        let search = SearchViewModel(
            accounts: [], debounceMilliseconds: 0,
            seerSearch: { _ in [MediaItem(id: "movie", title: "Movie", kind: .movie)] }
        )
        @ObservationIgnored weak var detailView: UIView?

        init() { search.query = "Movie" }
    }

    private struct SearchRoot: View {
        @Bindable var model: Model
        let isPinned: Bool

        var body: some View {
            if isPinned {
                NavigationRailShell(
                    profile: model.profile, entries: [],
                    destinations: [.home, .search, .settings],
                    selection: $model.selection, onOpenProfileSwitcher: {},
                    chrome: model.chrome, content: stack, contentDestination: .search
                )
            } else {
                stack.ignoresSafeArea()
            }
        }

        private var stack: some View {
            NavigationStack(path: $model.path) {
                SearchView(viewModel: model.search) { _ in model.path.append(1) }
                    .modifier(NavigationRailSearchRootInset())
                    .navigationDestination(for: Int.self) { _ in
                        DetailProbe(model: model)
                            .ignoresSafeArea()
                            .toolbar(.hidden, for: .navigationBar)
                    }
            }
            .reportsNavigationDepth(model.path.count, to: isPinned ? model.chrome : nil)
        }
    }

    private struct DetailProbe: UIViewRepresentable {
        let model: Model

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .blue
            model.detailView = view
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {}
    }
}
