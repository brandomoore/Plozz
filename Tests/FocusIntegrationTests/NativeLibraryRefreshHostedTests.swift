#if os(tvOS)
import CoreModels
@testable import CoreUI
@testable import AppShell
@testable import FeatureHome
import FeatureHomeCore
import SwiftUI
import UIKit
import XCTest

@MainActor
final class NativeLibraryRefreshHostedTests: XCTestCase {
    func testMenuSelectionCommitsOnlyAfterPresentedControllerDismisses() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        try await withLibrary(model: model) { root, window in
            let host = try XCTUnwrap(window.rootViewController)
            let completion = LibraryAlphabetMenuCompletion.Controller()
            host.addChild(completion)
            root.addSubview(completion.view)
            completion.didMove(toParent: host)
            defer {
                completion.update(selection: nil, onCommit: nil)
                completion.willMove(toParent: nil)
                completion.view.removeFromSuperview()
                completion.removeFromParent()
            }
            let menu = UIAlertController(title: "Letters", message: nil, preferredStyle: .alert)
            menu.addAction(UIAlertAction(title: "M", style: .default))
            await withCheckedContinuation { continuation in
                host.present(menu, animated: true) { continuation.resume() }
            }
            var committed: [String] = []
            let finished = expectation(description: "Menu selection committed after dismissal")
            completion.update(selection: "M") { letter in
                committed.append(letter)
                finished.fulfill()
            }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(committed.isEmpty, "The menu still owns focus")
            await withCheckedContinuation { continuation in
                menu.dismiss(animated: true) { continuation.resume() }
            }
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(committed, ["M"])
            completion.update(selection: nil, onCommit: nil)
        }
    }

    func testCustomGridAlphabetJumpTransfersRealFocus() async throws {
        let provider = RefreshLibraryProvider()
        await provider.enableAlphabet()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.loadFirstPage()
        try await withLibrary(model: model, focusStyle: .highlight) { root, window in
            let index = await model.jumpToLetter("M")
            XCTAssertEqual(index, 140)
            try await Task.sleep(for: .milliseconds(800))
            let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            let item = try XCTUnwrap(model.item(at: 140))
            let source = try XCTUnwrap(findSource(item.stablePresentationID, in: root))
            let frame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: focused, relativeTo: source))
            XCTAssertTrue(frame.contains(CGPoint(x: source.bounds.midX, y: source.bounds.midY)),
                          "The real SwiftUI focus item must enclose the destination artwork")
            XCTAssertTrue(window.bounds.intersects(source.convert(source.bounds, to: window)))
            XCTAssertEqual(source.reference?.isFocused, true, "The destination must also draw its focus highlight")
        }
    }

    func testRailPreviewScrollDoesNotStealFocusFromItsControl() async throws {
        let provider = RefreshLibraryProvider()
        await provider.enableAlphabet()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.loadFirstPage()
        try await withLibrary(model: model) { root, window in
            let railControl = UIButton(type: .system)
            railControl.setTitle("M", for: .normal)
            railControl.frame = CGRect(x: root.bounds.maxX - 100, y: 400, width: 80, height: 70)
            root.addSubview(railControl)
            defer { railControl.removeFromSuperview() }
            window.layoutIfNeeded()
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            controller.target = railControl
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === railControl)
            controller.target = nil
            _ = await model.jumpToLetter("M", focusesItem: false)
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(focus.focusedItem === railControl, "Rail navigation only previews the new window")
            let collection = try XCTUnwrap(find(UICollectionView.self, in: root))
            XCTAssertTrue(collection.indexPathsForVisibleItems.contains(IndexPath(item: 140, section: 0)))
        }
    }

    func testDeferredAlphabetJumpScrollsToLoadedNativeCardAndRetainsUsableFocus() async throws {
        let provider = RefreshLibraryProvider()
        await provider.enableAlphabet()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.loadFirstPage()
        var selected: MediaItem?
        try await withGrid(model: model, onSelect: { selected = $0 }) { collection in
            XCTAssertTrue(model.alphabet.isVisible, "The header entry must be available before scrolling")
            let window = try XCTUnwrap(collection.window)
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            let menu = try XCTUnwrap(findController(LibraryAlphabetMenuCompletion.Controller.self, in: controller))
            let headerTarget = try XCTUnwrap(NavigationRowFocusRequester.target(for: menu.view, in: window))
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            controller.target = headerTarget
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === headerTarget, "Begin with the actual header menu focused")
            controller.target = nil
            let index = await model.jumpToLetter("M")
            XCTAssertEqual(index, 140)
            try await Task.sleep(for: .milliseconds(700))
            collection.layoutIfNeeded()
            let path = IndexPath(item: 140, section: 0)
            XCTAssertTrue(collection.indexPathsForVisibleItems.contains(path))
            let cell = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            XCTAssertEqual(cell.item?.title, "Movie 140")
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(cell.isFocused, "A committed alphabet jump must transfer actual focus, not just scroll")
            XCTAssertTrue(UIFocusSystem(for: cell)?.focusedItem === cell)
            collection.delegate?.collectionView?(collection, didSelectItemAt: path)
            XCTAssertEqual(selected?.id, "Before-140")
        }
    }

    func testCorrectedPageTotalsPreserveScrollAndExistingCells() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        let controller = NativeLibraryGridController()
        defer { controller.stopObserving() }
        func update() {
            controller.update(
                model: model, total: model.totalCount, generation: model.contentGeneration,
                spoilerSettings: .default, environment: EnvironmentValues(),
                leadingInset: 40, trailingInset: 40, header: AnyView(Text("Library")),
                hidesScrollIndicator: false, onSelect: { _ in }, onLoaded: { _ in }
            )
        }
        update()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        controller.view.layoutIfNeeded()
        let collection = try XCTUnwrap(find(UICollectionView.self, in: controller.view))
        collection.layoutIfNeeded()
        collection.setContentOffset(CGPoint(x: 0, y: 4000), animated: false)
        collection.layoutIfNeeded()
        let before = collection.contentOffset.y
        XCTAssertGreaterThan(before, 3000)
        let visible = try XCTUnwrap(collection.indexPathsForVisibleItems.sorted().first)
        let cell = try XCTUnwrap(collection.cellForItem(at: visible))

        for (count, index) in [(245, 100), (230, 170)] {
            await provider.change(total: count, prefix: "Before")
            await model.itemAppeared(at: index, generation: model.contentGeneration)
            XCTAssertEqual(model.totalCount, count)
            update()
            collection.layoutIfNeeded()
            XCTAssertEqual(collection.numberOfItems(inSection: 0), count)
            XCTAssertEqual(collection.contentOffset.y, before, accuracy: 1)
            XCTAssertTrue(collection.cellForItem(at: visible) === cell)
        }
        for count in [5, 0] {
            await provider.change(total: count, prefix: "Before")
            await model.refreshAfterCatalogChange()
            update()
            collection.layoutIfNeeded()
            XCTAssertEqual(collection.numberOfItems(inSection: 0), count)
            XCTAssertLessThanOrEqual(collection.contentOffset.y, max(0, collection.contentSize.height - collection.bounds.height))
        }
    }

    func testSameCountCatalogRefreshUpdatesVisibleNativeCellsAndSelection() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 240
        )
        await model.loadFirstPage()
        var selected: MediaItem?
        try await withGrid(model: model, onSelect: { selected = $0 }) { collection in
            let path = IndexPath(item: 0, section: 0)
            let first = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            let slot = model.slot(at: 0)
            XCTAssertEqual(first.item?.title, "Before 0")
            let generation = model.contentGeneration
            await provider.change(total: 240, prefix: "After")
            await model.refreshAfterCatalogChange()
            try await Task.sleep(for: .milliseconds(200))
            let refreshed = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            XCTAssertTrue(refreshed === first)
            XCTAssertTrue(model.slot(at: 0) === slot)
            XCTAssertEqual(model.contentGeneration, generation)
            XCTAssertEqual(refreshed.item?.title, "After 0")
            collection.delegate?.collectionView?(collection, didSelectItemAt: path)
            XCTAssertEqual(selected?.id, refreshed.item?.id)
            XCTAssertEqual(selected?.title, refreshed.item?.title)
        }
    }

    func testCatalogCountChangesKeepScrolledNativeFocus() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 240
        )
        await model.loadFirstPage()
        try await withGrid(model: model) { collection in
            let path = IndexPath(item: 60, section: 0)
            collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collection.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let focused = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            XCTAssertTrue(focused.onRequestFocus?() == true)
            try await Task.sleep(for: .milliseconds(600))
            let offset = collection.contentOffset.y
            XCTAssertGreaterThan(offset, 2000)
            for count in [245, 230] {
                await provider.change(total: count, prefix: "Count \(count)")
                await model.refreshAfterCatalogChange()
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(collection.numberOfItems(inSection: 0), count)
                XCTAssertTrue(collection.cellForItem(at: path) === focused)
                XCTAssertTrue(focused.isFocused)
                XCTAssertEqual(focused.item?.title, "Count \(count) 60")
                XCTAssertEqual(collection.contentOffset.y, offset, accuracy: 2)
            }
        }
    }

    func testFailedCatalogRefreshKeepsExistingPagingCallbacksValid() async {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        let generation = model.contentGeneration
        let slot = model.slot(at: 0)
        await provider.setFailure(true)
        await model.refreshAfterCatalogChange()
        await provider.setFailure(false)
        XCTAssertEqual(model.contentGeneration, generation)
        XCTAssertTrue(model.slot(at: 0) === slot)
        await model.itemAppeared(at: 100, generation: generation)
        XCTAssertNotNil(model.item(at: 100))
    }

    func testRefreshIncludesViewportThatMovedWhileFirstPageWasPending() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 10
        )
        await model.loadFirstPage()
        let generation = model.contentGeneration
        await provider.holdNextPage(at: 0)
        let refresh = Task { await model.refreshAfterCatalogChange() }
        await waitForHeldPage(provider)
        await model.itemAppeared(at: 30, generation: generation)
        XCTAssertNotNil(model.item(at: 30), "The visible snapshot must remain pageable during refresh.")
        let slot = model.slot(at: 30)
        await provider.change(total: 240, prefix: "Moved")
        await provider.releasePage()
        await refresh.value
        XCTAssertEqual(model.contentGeneration, generation)
        XCTAssertTrue(model.slot(at: 30) === slot)
        XCTAssertEqual(model.item(at: 30)?.title, "Moved 30")
        XCTAssertEqual(model.topVisibleIndex, 30)
    }

    func testInFlightPageSurvivesFailedRefresh() async {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 10
        )
        await model.loadFirstPage()
        let generation = model.contentGeneration
        await provider.holdNextPage(at: 30)
        let paging = Task { await model.itemAppeared(at: 30, generation: generation) }
        await waitForHeldPage(provider)
        await provider.setFailure(true)
        await model.refreshAfterCatalogChange()
        await provider.setFailure(false)
        await provider.releasePage()
        await paging.value
        XCTAssertEqual(model.contentGeneration, generation)
        XCTAssertNotNil(model.item(at: 30))
    }

    func testLatePageCannotOverwriteSuccessfulRefresh() async {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 10
        )
        await model.loadFirstPage()
        await provider.holdNextPage(at: 30)
        let paging = Task { await model.itemAppeared(at: 30, generation: model.contentGeneration) }
        await waitForHeldPage(provider)
        await provider.change(total: 240, prefix: "After")
        await model.refreshAfterCatalogChange()
        XCTAssertEqual(model.item(at: 30)?.title, "After 30")
        await provider.releasePage()
        await paging.value
        XCTAssertEqual(model.item(at: 30)?.title, "After 30")
    }

    func testShortRefreshClearsUnreturnedItemsWithinTheRefreshedPage() async {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 10
        )
        await model.loadFirstPage()
        let slot = model.slot(at: 5)
        XCTAssertNotNil(slot?.item)
        await provider.setPageCap(3)
        await model.refreshAfterCatalogChange()
        XCTAssertTrue(model.slot(at: 5) === slot)
        XCTAssertNotNil(model.item(at: 2))
        XCTAssertNil(model.item(at: 3))
        XCTAssertNil(model.item(at: 5))
    }

    private func withGrid(
        model: LibraryBrowseViewModel,
        onSelect: @escaping (MediaItem) -> Void = { _ in },
        body: (UICollectionView) async throws -> Void
    ) async throws {
        try await withLibrary(model: model, onSelect: onSelect) { root, _ in
            try await body(XCTUnwrap(find(UICollectionView.self, in: root)))
        }
    }

    private func withLibrary(
        model: LibraryBrowseViewModel,
        focusStyle: CardFocusStyle = .system,
        onSelect: @escaping (MediaItem) -> Void = { _ in },
        body: (UIView, UIWindow) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(
            rootView:
                LibraryBrowseView(viewModel: model, title: Text("Library"), onSelect: onSelect)
                .environment(\.plozzCardFocusStyle, focusStyle)
                .environment(\.plozzCardStyle, .borderless)
        )
        let container = LibraryFocusFixtureController()
        container.addChild(host)
        container.view.addSubview(host.view)
        host.view.frame = window.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: container)
        window.rootViewController = container
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(400))
        try await body(container.view, window)
    }

    private func waitForHeldPage(_ provider: RefreshLibraryProvider) async {
        for _ in 0..<100 {
            if await provider.isHoldingPage { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected the fixture page request to reach its gate.")
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func findSource(_ itemKey: String, in view: UIView) -> DetailTransitionSourceView? {
        if let source = view as? DetailTransitionSourceView, source.reference?.itemKey == itemKey { return source }
        return view.subviews.lazy.compactMap { self.findSource(itemKey, in: $0) }.first
    }

    private func findController<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let result = controller as? T { return result }
        return controller.children.lazy.compactMap { self.findController(type, in: $0) }.first
    }
}

private final class LibraryFocusFixtureController: UIViewController {
    weak var target: (any UIFocusEnvironment)?
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}

private actor RefreshLibraryProvider: MediaProvider {
    nonisolated let kind = ProviderKind.mediaShare
    nonisolated let session = UserSession(
        server: MediaServer(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.test")!, provider: .mediaShare),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
    )
    private var total = 240
    private var prefix = "Before"
    private var fails = false
    private var pageCap: Int?
    private var alphabetEnabled = false
    private var heldStart: Int?
    private var heldPage: CheckedContinuation<Void, Never>?
    var isHoldingPage: Bool { heldPage != nil }

    func enableAlphabet() { alphabetEnabled = true }
    func letterIndex(in containerID: String, kind: MediaItemKind,
                     sort: CoreModels.SortDescriptor) async throws -> [LibraryLetterIndexEntry] {
        alphabetEnabled && sort.field == .name ? [.init(letter: "A"), .init(letter: "M")] : []
    }
    func letterPosition(in containerID: String, kind: MediaItemKind, letter: String,
                        sort: CoreModels.SortDescriptor) async throws -> Int? {
        letter == "M" ? 140 : 0
    }

    func change(total: Int, prefix: String) {
        self.total = total
        self.prefix = prefix
    }
    func setFailure(_ value: Bool) { fails = value }
    func setPageCap(_ value: Int) { pageCap = value }
    func holdNextPage(at start: Int) { heldStart = start }
    func releasePage() {
        heldPage?.resume()
        heldPage = nil
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        if fails { throw AppError.invalidResponse }
        let end = min(total, page.startIndex + min(page.limit, pageCap ?? page.limit))
        let response = MediaPage(
            items: (min(page.startIndex, end)..<end).map {
                MediaItem(id: "\(prefix)-\($0)",
                          title: "\(alphabetEnabled ? ($0 < 140 ? "Alpha" : "Movie") : prefix) \($0)", kind: .movie)
            }, startIndex: page.startIndex, totalCount: total)
        if heldStart == page.startIndex {
            heldStart = nil
            await withCheckedContinuation { heldPage = $0 }
        }
        return response
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
