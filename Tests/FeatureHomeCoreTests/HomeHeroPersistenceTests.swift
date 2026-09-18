import CoreModels
import Foundation
import XCTest
@testable import FeatureHomeCore

@MainActor
final class HomeHeroPersistenceTests: XCTestCase {
    private let settings = HeroSettings.default

    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, title: id, kind: .movie)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    func testReplacementStoresShareHeroGenerationFence() async {
        let persistence = HomeSnapshotPersistence()
        let backing = InMemoryHomeContentStore()
        let scope = UUID().uuidString
        let first = HeroRecordingStore(backing: backing, scope: scope)
        let replacement = HeroRecordingStore(backing: backing, scope: scope)
        let key = HeroConfigurationKey(settings: settings)
        await persistence.saveHero([item("new")], for: key, generation: 2, to: replacement)
        await persistence.saveHero([item("old")], for: key, generation: 1, to: first)
        await persistence.clearHero(generation: 1, store: first)
        XCTAssertEqual(backing.loadHero(for: key)?.map(\.id), ["new"])
        XCTAssertFalse(replacement.usedMainThread)
        XCTAssertEqual(first.heroSaveCount, 0)
    }

    func testWholeHomeClearCannotDeleteNewerHeroButStillClearsOlderRows() async {
        let persistence = HomeSnapshotPersistence()
        let store = InMemoryHomeContentStore(.init(latest: [item("row")]))
        let key = HeroConfigurationKey(settings: settings)
        await persistence.saveHero([item("new")], for: key, generation: 2, to: store)
        await persistence.clear(generation: 1, store: store)
        XCTAssertNil(store.load())
        XCTAssertEqual(store.loadHero(for: key)?.map(\.id), ["new"])
        await persistence.clear(generation: 3, store: store)
        await persistence.saveHero([item("stale")], for: key, generation: 2, to: store)
        XCTAssertNil(store.loadHero(for: key))
    }

    func testWholeHomeClearStillClearsHeroWhenNewerRowsAlreadySaved() async {
        let persistence = HomeSnapshotPersistence()
        let store = InMemoryHomeContentStore()
        let key = HeroConfigurationKey(settings: settings)
        await persistence.saveHero([item("old")], for: key, generation: 1, to: store)
        await persistence.save(
            .init(latest: [item("new-row")]), generation: 3, to: store,
            preservePreviousWatchlist: false,
            excludingUnconfirmedContinueWatchingIDs: []
        )
        await persistence.clear(generation: 2, store: store)
        XCTAssertEqual(store.load()?.latest.map(\.id), ["new-row"])
        XCTAssertNil(store.loadHero(for: key))
    }

    func testHeroAndRowWritesAndOtherProfilesHaveIndependentGenerations() async {
        let persistence = HomeSnapshotPersistence()
        let first = InMemoryHomeContentStore()
        let other = InMemoryHomeContentStore()
        let key = HeroConfigurationKey(settings: settings)
        await persistence.saveHero([item("hero")], for: key, generation: 10, to: first)
        await persistence.save(
            .init(latest: [item("row")]), generation: 1, to: first,
            preservePreviousWatchlist: false,
            excludingUnconfirmedContinueWatchingIDs: []
        )
        await persistence.saveHero([item("other")], for: key, generation: 1, to: other)
        XCTAssertEqual(first.load()?.latest.map(\.id), ["row"])
        XCTAssertEqual(first.loadHero(for: key)?.map(\.id), ["hero"])
        XCTAssertEqual(other.loadHero(for: key)?.map(\.id), ["other"])
    }

    func testModelDoesNotWaitOnWriterAndLatestSaveWinsAfterClear() async {
        let store = HeroRecordingStore(blockFirstSave: true)
        defer { store.releaseSave() }
        let model = HomeViewModel(
            accounts: [], layoutStore: InMemoryHomeLayoutStore(), contentStore: store
        )
        model.cacheHeroItems([item("old")], for: settings)
        let entered = await waitUntil { store.heroSaveCount == 1 }
        XCTAssertTrue(entered)
        model.clearCachedHeroItems()
        XCTAssertNil(model.cachedHeroItems(for: settings), "A queued clear invalidates the seed immediately.")
        model.cacheHeroItems([item("new")], for: settings)
        store.releaseSave()
        await model.waitForHeroPersistence()
        XCTAssertEqual(store.loadHero(for: HeroConfigurationKey(settings: settings))?.map(\.id), ["new"])
        XCTAssertFalse(store.usedMainThread)
        XCTAssertFalse(store.gateTimedOut)
    }

    func testAcceptedHeroWriteDoesNotRetainOrRequireModel() async {
        let store = HeroRecordingStore()
        var model: HomeViewModel? = HomeViewModel(
            accounts: [], layoutStore: InMemoryHomeLayoutStore(), contentStore: store
        )
        weak var weakModel = model
        model?.cacheHeroItems([item("saved")], for: settings)
        model = nil
        XCTAssertNil(weakModel)
        let key = HeroConfigurationKey(settings: settings)
        let saved = await waitUntil { store.loadHero(for: key)?.first?.id == "saved" }
        XCTAssertTrue(saved)
        XCTAssertFalse(store.usedMainThread)
    }
}

private final class HeroRecordingStore: HomeContentStoring, @unchecked Sendable {
    let persistenceScope: String
    private let backing: InMemoryHomeContentStore
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blockFirstSave: Bool
    private var heroSaves = 0
    private var mainThread = false
    private var timedOut = false

    init(
        backing: InMemoryHomeContentStore = InMemoryHomeContentStore(),
        scope: String = UUID().uuidString,
        blockFirstSave: Bool = false
    ) {
        self.backing = backing
        self.persistenceScope = scope
        self.blockFirstSave = blockFirstSave
    }

    var heroSaveCount: Int { lock.withLock { heroSaves } }
    var usedMainThread: Bool { lock.withLock { mainThread } }
    var gateTimedOut: Bool { lock.withLock { timedOut } }
    func releaseSave() { gate.signal() }
    func load() -> HomeViewModel.Content? { backing.load() }
    func save(_ content: HomeViewModel.Content) { backing.save(content) }
    func clearRows() { backing.clearRows() }
    func clear() { backing.clear() }
    func loadHero(for key: HeroConfigurationKey) -> [MediaItem]? { backing.loadHero(for: key) }
    func clearHero() {
        lock.withLock { mainThread = mainThread || Thread.isMainThread }
        backing.clearHero()
    }

    func saveHero(_ items: [MediaItem], for key: HeroConfigurationKey) {
        let first = lock.withLock {
            heroSaves += 1
            mainThread = mainThread || Thread.isMainThread
            return heroSaves == 1
        }
        if first && blockFirstSave, gate.wait(timeout: .now() + 8) == .timedOut {
            lock.withLock { timedOut = true }
        }
        backing.saveHero(items, for: key)
    }
}
