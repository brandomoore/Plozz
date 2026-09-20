import CoreModels
import Foundation
import Observation
import XCTest
@testable import FeatureHomeCore

@MainActor
final class HeroFreshnessPersistenceTests: XCTestCase {
    private func item(_ id: String) -> MediaItem {
        MediaItem(
            id: id, title: id, kind: .movie,
            backdropURL: URL(string: "https://example.com/\(id).jpg")
        )
    }

    private func settings(limit: Int = 1) -> HeroSettings {
        var settings = HeroSettings.default
        settings.sources = [.featured]
        settings.maxItems = limit
        return settings
    }

    private func pool(_ ids: [String]) -> HeroFreshnessCandidatePool {
        HeroFreshnessCandidatePool(buckets: [.init(source: .featured, items: ids.map(item))])
    }

    private func model(_ store: any HomeContentStoring) -> HomeViewModel {
        HomeViewModel(accounts: [], layoutStore: InMemoryHomeLayoutStore(), contentStore: store)
    }

    func testCachedStartupSelectsOnceWithoutRecordingExposure() {
        let store = InMemoryHomeContentStore()
        let config = settings()
        store.saveHeroCandidatePool(pool(["a", "b", "c"]), for: .init(settings: config))
        let model = model(store)
        let selected = model.cachedHeroItems(for: config)
        XCTAssertEqual(selected?.count, 1)
        XCTAssertEqual(model.cachedHeroItems(for: config), selected)
        XCTAssertTrue(model.heroFreshnessSnapshot().history.entries.isEmpty)
        XCTAssertTrue(store.loadHeroExposureHistory().entries.isEmpty)
    }

    func testExposureSurvivesModelReplacementAndChangesNextStartup() async throws {
        let store = InMemoryHomeContentStore()
        let config = settings()
        store.saveHeroCandidatePool(pool(["a", "b", "c"]), for: .init(settings: config))
        let first = model(store)
        let opener = try XCTUnwrap(first.cachedHeroItems(for: config)?.first)
        first.recordHeroExposure(opener)
        XCTAssertEqual(first.cachedHeroItems(for: config)?.first?.id, opener.id)
        await first.waitForHeroExposurePersistence()
        let replacement = model(store)
        XCTAssertNotEqual(replacement.cachedHeroItems(for: config)?.first?.id, opener.id)
        XCTAssertNotNil(store.loadHeroExposureHistory().lastSeenAt(for: opener))
    }

    func testExplicitNewSessionChangesSelectionButNotHistory() async throws {
        let store = InMemoryHomeContentStore()
        let config = settings()
        store.saveHeroCandidatePool(pool(["a", "b"]), for: .init(settings: config))
        let model = model(store)
        let opener = try XCTUnwrap(model.cachedHeroItems(for: config)?.first)
        model.recordHeroExposure(opener)
        let history = model.heroFreshnessSnapshot().history
        model.beginHeroBrowsingSession()
        XCTAssertNotEqual(model.cachedHeroItems(for: config)?.first?.id, opener.id)
        XCTAssertEqual(model.heroFreshnessSnapshot().history, history)
        await model.waitForHeroExposurePersistence()
    }

    func testProfilesHaveIndependentExposureAndCandidateState() async {
        let firstStore = InMemoryHomeContentStore()
        let otherStore = InMemoryHomeContentStore()
        let first = model(firstStore)
        let other = model(otherStore)
        first.recordHeroExposure(item("shared"))
        await first.waitForHeroExposurePersistence()
        XCTAssertNotNil(first.heroFreshnessSnapshot().history.lastSeenAt(for: item("shared")))
        XCTAssertNil(other.heroFreshnessSnapshot().history.lastSeenAt(for: item("shared")))
        XCTAssertTrue(otherStore.loadHeroExposureHistory().entries.isEmpty)
    }

    func testReplacementModelKeepsAcceptedHistoryBeforeDiskWriteCompletes() async {
        let backing = InMemoryHomeContentStore()
        let scope = UUID().uuidString
        let first = model(FreshnessRecordingStore(backing: backing, scope: scope))
        first.recordHeroExposure(item("first"))
        let replacement = model(FreshnessRecordingStore(backing: backing, scope: scope))
        replacement.recordHeroExposure(item("second"))
        await first.waitForHeroExposurePersistence()
        await replacement.waitForHeroExposurePersistence()
        XCTAssertNotNil(backing.loadHeroExposureHistory().lastSeenAt(for: item("first")))
        XCTAssertNotNil(backing.loadHeroExposureHistory().lastSeenAt(for: item("second")))
    }

    func testCachedCandidatesRespectCurrentLibraryVisibility() {
        var config = settings()
        config.sources = [.randomFromLibrary]
        let hidden = item("hidden").taggingSource("account").taggingLibrary("hidden")
        let visible = item("visible").taggingSource("account").taggingLibrary("visible")
        let store = InMemoryHomeContentStore()
        store.saveHeroCandidatePool(HeroFreshnessCandidatePool(buckets: [
            .init(source: .randomFromLibrary, items: [hidden, visible])
        ]), for: .init(settings: config))
        let visibility = HomeLibraryVisibility(disabledKeys: ["account:hidden"])
        let model = HomeViewModel(
            accounts: [], layoutStore: InMemoryHomeLayoutStore(), contentStore: store,
            currentVisibility: { visibility }
        )
        XCTAssertEqual(model.cachedHeroItems(for: config)?.map(\.id), ["visible"])
    }

    func testDisablingTheOpenersLibraryInvalidatesMemoizedSelection() throws {
        var config = settings()
        config.sources = [.randomFromLibrary]
        let candidates = ["a", "b"].map { item($0).taggingSource("account").taggingLibrary($0) }
        let store = InMemoryHomeContentStore()
        store.saveHeroCandidatePool(.init(buckets: [
            .init(source: .randomFromLibrary, items: candidates)
        ]), for: .init(settings: config))
        var visibility = HomeLibraryVisibility.default
        let model = HomeViewModel(
            accounts: [], layoutStore: InMemoryHomeLayoutStore(), contentStore: store,
            currentVisibility: { visibility }
        )
        let opener = try XCTUnwrap(model.cachedHeroItems(for: config)?.first)
        visibility.setEnabled(false, for: "account:\(opener.id)")
        let replacement = try XCTUnwrap(model.cachedHeroItems(for: config)?.first)
        XCTAssertNotEqual(replacement.id, opener.id)
        XCTAssertEqual(model.cachedHeroItems(for: config)?.first?.id, replacement.id)
    }

    func testLegacyCacheCannotRestoreAnExplicitlyDisabledLibrary() {
        var config = settings()
        config.sources = [.randomFromLibrary]
        let candidates = ["a", "b"].map { item($0).taggingSource("account").taggingLibrary($0) }
        let store = InMemoryHomeContentStore()
        store.saveHero(candidates, for: .init(settings: config))
        var visibility = HomeLibraryVisibility.default
        let model = HomeViewModel(
            accounts: [], layoutStore: InMemoryHomeLayoutStore(), contentStore: store,
            currentVisibility: { visibility }
        )
        XCTAssertEqual(model.cachedHeroItems(for: config)?.first?.id, "a")
        visibility.setEnabled(false, for: "account:a")
        XCTAssertEqual(model.cachedHeroItems(for: config)?.map(\.id), ["b"])
    }

    func testExposureDoesNotInvalidateObservedHome() async {
        let model = model(InMemoryHomeContentStore())
        let changed = expectation(description: "Exposure does not publish Home state")
        changed.isInverted = true
        withObservationTracking {
            _ = model.state
            _ = model.heroFreshnessSnapshot()
        } onChange: {
            changed.fulfill()
        }
        model.recordHeroExposure(item("a"))
        await model.waitForHeroExposurePersistence()
        await fulfillment(of: [changed], timeout: 0.05)
    }

    func testPoolWritesAndClearsShareGenerationFence() async {
        let persistence = HomeSnapshotPersistence()
        let store = InMemoryHomeContentStore()
        let key = HeroConfigurationKey(settings: settings())
        await persistence.saveHeroCandidatePool(pool(["new", "alternative"]), for: key, generation: 2, to: store)
        await persistence.saveHeroCandidatePool(pool(["old"]), for: key, generation: 1, to: store)
        await persistence.clearHero(generation: 1, store: store)
        XCTAssertEqual(store.loadHeroCandidatePool(for: key)?.buckets[0].items.map(\.id), ["new", "alternative"])
        await persistence.clearHero(generation: 3, store: store)
        await persistence.saveHeroCandidatePool(pool(["stale"]), for: key, generation: 2, to: store)
        XCTAssertNil(store.loadHeroCandidatePool(for: key))
        XCTAssertNil(store.loadHero(for: key))
    }

    func testHistoryGenerationsAreIndependentFromHeroAndRows() async {
        let persistence = HomeSnapshotPersistence()
        let store = InMemoryHomeContentStore()
        var old = HeroExposureHistory()
        old.record(item("old"))
        var newest = old
        newest.record(item("new"))
        await persistence.saveHeroExposureHistory(newest, generation: 2, to: store)
        await persistence.saveHeroExposureHistory(old, generation: 1, to: store)
        await persistence.clear(generation: 100, store: store)
        XCTAssertEqual(store.loadHeroExposureHistory(), newest)
        XCTAssertNil(store.load())
    }

    func testPoolAndHistoryPersistenceRunsOffMainAndDoesNotRetainModel() async {
        let store = FreshnessRecordingStore()
        var model: HomeViewModel? = self.model(store)
        weak var weakModel = model
        model?.recordHeroExposure(item("seen"))
        model?.cacheHeroCandidatePool(pool(["a", "b"]), for: settings())
        await model?.waitForHeroExposurePersistence()
        await model?.waitForHeroPersistence()
        model = nil
        XCTAssertNil(weakModel)
        XCTAssertEqual(store.writeThreads.count, 2)
        XCTAssertTrue(store.writeThreads.allSatisfy { !$0 })
        XCTAssertEqual(store.backing.loadHeroCandidatePool(for: .init(settings: settings()))?.buckets[0].items.count, 2)
    }

    func testLegacyFlatCacheKeepsOrderWithoutInventingProvenance() async {
        let store = InMemoryHomeContentStore()
        let config = settings(limit: 8)
        let original = [item("first"), item("second")]
        store.saveHero(original, for: .init(settings: config))
        let model = model(store)
        model.recordHeroExposure(original[0])
        XCTAssertEqual(model.cachedHeroItems(for: config), original)
        XCTAssertNil(store.loadHeroCandidatePool(for: .init(settings: config)))
        await model.waitForHeroExposurePersistence()
    }

    func testConfigurationIncludesWatchlistDiscoveryOnlyWhenSourceEnabled() throws {
        var config = settings()
        let original = HeroConfigurationKey(settings: config)
        config.watchlistDiscoveryEnabled = true
        XCTAssertEqual(HeroConfigurationKey(settings: config), original)
        config.sources = [.watchlist]
        let discovery = HeroConfigurationKey(settings: config)
        config.watchlistDiscoveryEnabled = false
        XCTAssertNotEqual(discovery, HeroConfigurationKey(settings: config))
        let legacy = Data(#"{"sources":["watchlist"],"maxItems":8,"hideWatched":true,"randomLibraryKeys":[]}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(HeroConfigurationKey.self, from: legacy).watchlistDiscoveryEnabled)
    }

    func testDiskPoolAndHistoryRoundTripAreBoundedScopedAndCredentialFree() throws {
        let directory = try ownedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HomeContentStore(namespace: "one", directory: directory)
        let other = HomeContentStore(namespace: "two", directory: directory)
        let config = settings()
        var secret = item("secret")
        secret.backdropURL = URL(string: "https://example.com/art?X-Plex-Token=POOL-SECRET")
        var history = HeroExposureHistory()
        history.record(secret)
        let candidates = HeroFreshnessCandidatePool(buckets: [
            .init(source: .featured, items: [secret] + (0..<99).map { item("candidate-\($0)") }),
            .init(source: .continueWatching, items: [item("resume")])
        ])
        store.saveHeroCandidatePool(candidates, for: .init(settings: config))
        store.saveHeroExposureHistory(history)
        let replacement = HomeContentStore(namespace: "one", directory: directory)
        let restored = try XCTUnwrap(replacement.loadHeroCandidatePool(for: .init(settings: config)))
        XCTAssertEqual(restored.buckets.map(\.source), [.featured])
        XCTAssertEqual(restored.buckets[0].items.count, 40)
        XCTAssertEqual(replacement.loadHeroExposureHistory(), history)
        XCTAssertNil(other.loadHeroCandidatePool(for: .init(settings: config)))
        XCTAssertTrue(other.loadHeroExposureHistory().entries.isEmpty)
        for file in try jsonFiles(in: directory) {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            XCTAssertFalse(text.contains("POOL-SECRET"))
            XCTAssertFalse(text.lowercased().contains("x-plex-token"))
            if file.lastPathComponent.contains("hero-exposure") {
                XCTAssertFalse(text.contains("example.com"))
                XCTAssertEqual(
                    try JSONDecoder().decode(HeroExposureHistory.self, from: Data(contentsOf: file)),
                    history
                )
            }
        }
    }

    func testOldDiskBlobDecodesAndDoesNotClaimCandidateProvenance() throws {
        struct LegacyHero: Encodable {
            var key: HeroConfigurationKey
            var items: [MediaItem]
            var savedAt: Date
        }
        let directory = try ownedDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HomeContentStore(namespace: "legacy", directory: directory)
        let config = settings(limit: 8)
        let key = HeroConfigurationKey(settings: config)
        let items = [item("first"), item("second")]
        store.saveHero(items, for: key)
        let file = try XCTUnwrap(try jsonFiles(in: directory).first { $0.lastPathComponent.hasSuffix("-hero.json") })
        let legacy = try JSONEncoder().encode(LegacyHero(key: key, items: items, savedAt: Date()))
        try legacy.write(to: file, options: .atomic)
        XCTAssertEqual(store.loadHero(for: key), items)
        XCTAssertNil(store.loadHeroCandidatePool(for: key))
        XCTAssertEqual(model(store).cachedHeroItems(for: config), items)
    }

    private func ownedDirectory() throws -> URL {
        let root = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let directory = root.appendingPathComponent("HeroFreshnessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func jsonFiles(in directory: URL) throws -> [URL] {
        let schema = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix("plozz-home-content") })
        return try FileManager.default.contentsOfDirectory(
            at: schema, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }
}

private final class FreshnessRecordingStore: HomeContentStoring, @unchecked Sendable {
    let backing: InMemoryHomeContentStore
    let persistenceScope: String
    private let lock = NSLock()
    private var threads: [Bool] = []
    var writeThreads: [Bool] { lock.withLock { threads } }

    init(
        backing: InMemoryHomeContentStore = InMemoryHomeContentStore(),
        scope: String = UUID().uuidString
    ) {
        self.backing = backing
        self.persistenceScope = scope
    }

    func load() -> HomeViewModel.Content? { backing.load() }
    func save(_ content: HomeViewModel.Content) { backing.save(content) }
    func loadHero(for key: HeroConfigurationKey) -> [MediaItem]? { backing.loadHero(for: key) }
    func saveHero(_ items: [MediaItem], for key: HeroConfigurationKey) { backing.saveHero(items, for: key) }
    func clearHero() { backing.clearHero() }
    func clear() { backing.clear() }
    func clearRows() { backing.clearRows() }
    func loadHeroCandidatePool(for key: HeroConfigurationKey) -> HeroFreshnessCandidatePool? {
        backing.loadHeroCandidatePool(for: key)
    }
    func saveHeroCandidatePool(_ pool: HeroFreshnessCandidatePool, for key: HeroConfigurationKey) {
        lock.withLock { threads.append(Thread.isMainThread) }
        backing.saveHeroCandidatePool(pool, for: key)
    }
    func loadHeroExposureHistory() -> HeroExposureHistory { backing.loadHeroExposureHistory() }
    func saveHeroExposureHistory(_ history: HeroExposureHistory) {
        lock.withLock { threads.append(Thread.isMainThread) }
        backing.saveHeroExposureHistory(history)
    }
}
