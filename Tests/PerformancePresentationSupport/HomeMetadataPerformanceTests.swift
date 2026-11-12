import CoreModels
import CoreUI
import FeatureHomeCore
import Foundation
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HomeMetadataPerformanceTests: XCTestCase {
    func testPerformanceHomeMetadataPublication() async throws {
        try PerformanceProbe.requireEnabled()
        let fixture = try PublicationFixture(itemCount: 200, peoplePerItem: 32, kind: .mediaShare)
        try await fixture.load()
        fixture.observeState()

        try await PerformanceProbe.measure(self, scenario: "home-metadata-publication") {
            try await self.withMainActorSchedulingProbe {
                let requests = await fixture.provider.requestCount
                let saves = fixture.store.saves.value
                let publications = fixture.publications.value
                let notifications = fixture.notifications.value
                var refreshes = 0
                for index in 0..<8 {
                    await fixture.provider.useSnapshot((index + 1) % 2)
                    try await fixture.load()
                    refreshes += 1
                }
                let content = try XCTUnwrap(fixture.model.state.value)
                let requestDelta = await fixture.provider.requestCount - requests
                let notificationDelta = fixture.notifications.value - notifications
                XCTAssertEqual(content.continueWatching.count, 200)
                XCTAssertEqual(content.latest.count, 20)
                XCTAssertEqual(requestDelta, refreshes * 3)
                XCTAssertEqual(fixture.store.saves.value - saves, refreshes)
                XCTAssertEqual(fixture.publications.value - publications, refreshes)
                XCTAssertEqual(notificationDelta, 0, "Equal fresh provider payloads must not invalidate observed Home state.")
                return [
                    "refreshes": refreshes,
                    "providerRequests": requestDelta,
                    "snapshotSaves": fixture.store.saves.value - saves,
                    "contentPublications": fixture.publications.value - publications,
                    "stateNotifications": notificationDelta,
                    "continueWatchingItems": content.continueWatching.count,
                    "metadataPeople": content.continueWatching.reduce(0) { $0 + $1.people.count }
                ]
            }
        }

        // Change the last credit of the last item, not an ID or an early title field.
        var changed = fixture.snapshots[0]
        changed[changed.count - 1].people[31].biography = "Updated final credit biography"
        await fixture.provider.replaceItems(changed)
        try await fixture.load()
        XCTAssertEqual(fixture.notifications.value, 1)
        XCTAssertEqual(fixture.model.state.value?.continueWatching.last?.people.last?.biography,
                       "Updated final credit biography")
        XCTAssertEqual(fixture.store.lastContent?.continueWatching.last?.people.last?.biography,
                       "Updated final credit biography")
    }

    func testPerformanceProductionRowMetadataUpdates() async throws {
        try PerformanceProbe.requireEnabled()
        let snapshots = try independentlyDecodedSnapshots(itemCount: 75, peoplePerItem: 32)
        try await measureProductionRows(snapshots: snapshots, scenario: "home-row-metadata-updates")
    }

    func testPerformanceMultiSourceRowPresentation() async throws {
        try PerformanceProbe.requireEnabled()
        let originals = try independentlyDecodedSnapshots(itemCount: 20, peoplePerItem: 32)[0]
        let sources = (0..<8).map {
            HomeContentSource(feed: .collection("collection"), accountID: "account-\($0)", serverUserID: "viewer", title: "Source")
        }
        let pager = HomeContentPager(sources: sources) { source, start, limit in
            let items = originals.enumerated().map { index, original in
                var item = original
                item.id = "\(source.accountID ?? "")-\(index)"
                item.sourceAccountID = source.accountID
                item.providerIDs = ["Tmdb": "\(index + 1)"]
                return item
            }
            return .prefix(items, startIndex: start, limit: limit)
        }
        let result = try await pager.loadNext(limit: 50)
        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(result.items.count, 20)
        XCTAssertTrue(result.items.allSatisfy { $0.sources.count == 8 })
        let data = try JSONEncoder().encode(result.items)
        let snapshots = try (0..<2).map { _ in try JSONDecoder().decode([MediaItem].self, from: data) }
        try await measureProductionRows(snapshots: snapshots, scenario: "home-multi-source-presentation")
    }

    func testPerformanceObservedHomeMetadataPublication() async throws {
        try PerformanceProbe.requireEnabled()
        try await measureObservedHomeMetadata(scenario: "home-observed-metadata-publication")
    }

    func testPerformanceObservedHomeMetadataWithDiagnostics() async throws {
        try PerformanceProbe.requireEnabled()
        PerformanceDiagnostics.shared.start()
        defer { PerformanceDiagnostics.shared.stop() }
        try await measureObservedHomeMetadata(scenario: "home-observed-metadata-diagnostics")
    }

    private func measureObservedHomeMetadata(scenario: String) async throws {
        let fixture = try PublicationFixture(itemCount: 200, peoplePerItem: 32, kind: .mediaShare)
        try await fixture.load()
        let row = try await RowFixture(items: [], model: fixture.model)
        defer { row.close() }
        try await row.settle()
        var changed = fixture.snapshots[1]
        changed[199].people[31].biography = "Updated final credit biography"

        try await PerformanceProbe.measure(self, scenario: scenario) {
            try await self.withMainActorSchedulingProbe {
                let requests = await fixture.provider.requestCount
                let notifications = fixture.notifications.value
                let saves = fixture.store.saves.value
                let publications = fixture.publications.value
                let bodies = row.probe.parentBodies
                let cardInputs = row.probe.cardInputs
                var updates = 0
                for index in 0..<8 {
                    fixture.observeState()
                    let before = row.probe.parentBodies
                    let expected = index.isMultiple(of: 2) ? changed : fixture.snapshots[0]
                    await fixture.provider.replaceItems(expected)
                    try await fixture.load()
                    try await row.waitForObservedUpdate(after: before)
                    XCTAssertEqual(row.probe.observedTailBiography, expected.last?.people.last?.biography)
                    updates += 1
                }
                let content = try XCTUnwrap(fixture.model.state.value)
                let requestDelta = await fixture.provider.requestCount - requests
                XCTAssertEqual(requestDelta, updates * 3)
                XCTAssertEqual(fixture.notifications.value - notifications, updates)
                XCTAssertEqual(fixture.store.saves.value - saves, updates)
                XCTAssertEqual(fixture.publications.value - publications, updates)
                XCTAssertGreaterThanOrEqual(row.probe.parentBodies - bodies, updates)
                XCTAssertEqual(content.continueWatching.last?.people.last?.biography,
                               fixture.snapshots[0].last?.people.last?.biography)
                return [
                    "refreshes": updates,
                    "providerRequests": requestDelta,
                    "snapshotSaves": fixture.store.saves.value - saves,
                    "contentPublications": fixture.publications.value - publications,
                    "stateNotifications": fixture.notifications.value - notifications,
                    "observedRowUpdates": updates,
                    "parentBodies": row.probe.parentBodies - bodies,
                    "cardInputBuilds": row.probe.cardInputs - cardInputs,
                    "continueWatchingItems": content.continueWatching.count,
                    "metadataPeople": content.continueWatching.reduce(0) { $0 + $1.people.count }
                ]
            }
        }
    }

    func testPerformanceProductionRowMetadataReuse() async throws {
        try PerformanceProbe.requireEnabled()
        let items = try independentlyDecodedSnapshots(itemCount: 75, peoplePerItem: 32)[0]
        try await measureProductionRows(snapshots: [items, items], scenario: "home-row-metadata-reuse")
    }

    private func measureProductionRows(snapshots: [[MediaItem]], scenario: String) async throws {
        let fixture = try await RowFixture(items: snapshots[0])
        defer { fixture.close() }
        try await fixture.settle()

        try await PerformanceProbe.measure(self, scenario: scenario) {
            let inputs = fixture.probe.cardInputs
            let bodies = fixture.probe.parentBodies
            var updates = 0
            for index in 0..<24 {
                try await fixture.update(items: snapshots[(index + 1) % 2])
                updates += 1
            }
            let bodyDelta = fixture.probe.parentBodies - bodies
            XCTAssertGreaterThanOrEqual(bodyDelta, updates, "Every update must reach the hosting graph.")
            XCTAssertFalse(fixture.probe.presentedItems.isEmpty)
            return [
                "rootUpdates": updates,
                "parentBodies": bodyDelta,
                "cardInputBuilds": fixture.probe.cardInputs - inputs,
                "rowItems": snapshots[0].count,
                "metadataPeople": snapshots[0].reduce(0) { $0 + $1.people.count }
            ]
        }

        try await verifyRowMetadataUpdates(fixture, original: snapshots[0])
    }

    func testHomeSilentRefreshPublishesMetadataChangesForEveryBackend() async throws {
        for kind: ProviderKind in [.plex, .jellyfin, .emby, .mediaShare, .iptv] {
            let fixture = try PublicationFixture(itemCount: 8, peoplePerItem: 4, kind: kind)
            try await fixture.load()
            var expected = fixture.snapshots[0]
            let mutations: [(inout MediaItem) -> Void] = [
                { $0.people[3].biography = "Revised biography" },
                { $0.people[3].externalID = "revised-person-identity" },
                { $0.librarySortValues?.hasAtmos = true },
                { $0.librarySortValues?.sortName = "Revised server sort name" },
                { $0.overview = "Revised server overview" },
                { $0.resumePosition = 456 },
                { $0.isFavorite = true }
            ]
            for mutate in mutations {
                let previous = try XCTUnwrap(fixture.model.state.value)
                let notifications = fixture.notifications.value
                fixture.observeState()
                mutate(&expected[7])
                await fixture.provider.replaceItems(expected)
                try await fixture.load()
                let content = try XCTUnwrap(fixture.model.state.value)
                let actual = try XCTUnwrap(content.continueWatching.last)
                XCTAssertEqual(fixture.notifications.value - notifications, 1, "\(kind)")
                XCTAssertNotEqual(content, previous, "\(kind)")
                XCTAssertEqual(actual.people, expected[7].people, "\(kind)")
                XCTAssertEqual(actual.librarySortValues, expected[7].librarySortValues, "\(kind)")
                XCTAssertEqual(actual.overview, expected[7].overview, "\(kind)")
                XCTAssertEqual(actual.resumePosition, expected[7].resumePosition, "\(kind)")
                XCTAssertEqual(actual.isFavorite, expected[7].isFavorite, "\(kind)")
                XCTAssertEqual(actual.sourceAccountID, fixture.accountID)
                XCTAssertEqual(content.continueWatching.map(\.id), previous.continueWatching.map(\.id))
            }
        }

    }

    func testHomeDiagnosticsPreserveAccountCountsAndMeasurePublishedContent() async throws {
        PerformanceDiagnostics.shared.start()
        defer { PerformanceDiagnostics.shared.stop() }
        let fixture = try PublicationFixture(itemCount: 8, peoplePerItem: 4, kind: .emby)
        try await fixture.load()
        let content = try XCTUnwrap(fixture.model.state.value)
        let snapshot = try XCTUnwrap(PerformanceDiagnostics.shared.snapshot())
        let records = snapshot.recent + snapshot.slow
        let load = try XCTUnwrap(records.last { $0.operation == .homeLoad })
        XCTAssertEqual(load.outcome, .succeeded)
        XCTAssertEqual(load.metrics.accounts, 1)
        XCTAssertEqual(load.metrics.items,
                       content.continueWatching.count + content.latest.count + content.watchlist.count)
        XCTAssertEqual(load.metrics.credits,
                       (content.continueWatching + content.latest + content.watchlist).reduce(0) {
                           $0 + $1.people.count
                       })
        XCTAssertTrue(records.contains { $0.operation == .homeFetch && $0.provider == .emby })
        XCTAssertTrue(records.contains { $0.operation == .homePublish && $0.startedOnMain })
        XCTAssertTrue(snapshot.active.isEmpty)
        let text = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(text.contains(fixture.accountID))
        for item in content.continueWatching {
            XCTAssertFalse(text.contains(item.title))
        }
    }

    func testProductionRowReceivesMetadataOnlyAndPlaybackInputChanges() async throws {
        let items = try independentlyDecodedSnapshots(itemCount: 6, peoplePerItem: 4)[0]
        let fixture = try await RowFixture(items: items)
        defer { fixture.close() }
        try await fixture.settle()
        try await verifyRowMetadataUpdates(fixture, original: items)
    }

    func testHomeDiagnosticsBoundOptionalCreditCountingForLargeFeeds() async throws {
        PerformanceDiagnostics.shared.start()
        defer { PerformanceDiagnostics.shared.stop() }
        let fixture = try PublicationFixture(itemCount: 2_049, peoplePerItem: 1, kind: .plex)
        try await fixture.load()
        let content = try XCTUnwrap(fixture.model.state.value)
        XCTAssertEqual(content.continueWatching.count, 2_049)
        let snapshot = try XCTUnwrap(PerformanceDiagnostics.shared.snapshot())
        let load = try XCTUnwrap((snapshot.recent + snapshot.slow).last { $0.operation == .homeLoad })
        XCTAssertEqual(load.metrics.items, content.continueWatching.count + content.latest.count)
        XCTAssertNil(load.metrics.credits, "An omitted count is unknown, not a sampled total.")
    }

    func testHomePublicationPreservesMembershipOrderAndLibraryMetadata() async throws {
        let fixture = try PublicationFixture(itemCount: 8, peoplePerItem: 4, kind: .plex)
        try await fixture.load()
        let previous = try XCTUnwrap(fixture.model.state.value)
        fixture.observeState()
        var changed = Array(fixture.snapshots[0].dropFirst().reversed())
        var inserted = changed[0]
        inserted.id = "inserted-metadata-item"
        inserted.title = "Inserted title"
        changed.insert(inserted, at: 0)
        await fixture.provider.replaceItems(changed)
        await fixture.provider.replaceLibraryTitle("Renamed library")
        try await fixture.load()

        let content = try XCTUnwrap(fixture.model.state.value)
        XCTAssertEqual(fixture.notifications.value, 1)
        XCTAssertEqual(content.latest.map(\.id), changed.map(\.id))
        XCTAssertFalse(content.latest.contains { $0.id == previous.latest[0].id })
        XCTAssertEqual(content.libraries.first?.library.title, "Renamed library")
        XCTAssertEqual(content.libraries.first?.key, previous.libraries.first?.key)
    }

    func testCopiedMediaItemMetadataRetainsFullEqualityHashingAndValueSemantics() throws {
        let snapshots = try independentlyDecodedSnapshots(itemCount: 1, peoplePerItem: 4)
        let original = snapshots[0][0]
        let independentEqual = snapshots[1][0]
        XCTAssertEqual(original, independentEqual)
        XCTAssertEqual(original.hashValue, independentEqual.hashValue)
        let mutations: [(inout MediaItem) -> Void] = [
            { $0.people[3].biography = "Changed biography" },
            { $0.people[3].externalID = "changed-person-id" },
            { $0.people[3].lifeSummary = "Changed life summary" },
            { $0.librarySortValues?.sortName = "Changed sort title" },
            { $0.librarySortValues?.dateAdded = Date(timeIntervalSince1970: 123) },
            { $0.librarySortValues?.hasAtmos = true },
            { $0.librarySortValues?.episodeWatchRollup = true },
            { $0.title = "Changed title" },
            { $0.overview = "Changed overview" },
            { $0.genres.append("Changed genre") },
            { $0.tags.append("Changed tag") },
            { $0.providerIDs["fixture"] = "changed-provider-id" },
            { $0.resumePosition = 456 },
            { $0.isPlayed = true },
            { $0.isFavorite = true },
            { $0.sourceAccountID = "changed-account" },
            { $0.libraryID = "changed-library" },
            { $0.rejectedSourceIDs.insert("changed-peer") },
            { $0.selectedVersionID = "changed-version" },
            { $0.selectedSourceAccountID = "changed-playback-account" },
            { $0.explicitSourceSelection = true }
        ]
        for (index, mutate) in mutations.enumerated() {
            var changed = original
            mutate(&changed)
            XCTAssertEqual(original, independentEqual, "Copy mutation \(index) must not mutate the original.")
            XCTAssertNotEqual(changed, original, "Metadata mutation \(index) must remain significant.")
            XCTAssertEqual(Set([original, changed]).count, 2, "Equality/hash consistency for mutation \(index).")
            XCTAssertNotEqual(HomeViewModel.Content(latest: [changed]), .init(latest: [original]))
        }
    }

    private func verifyRowMetadataUpdates(_ fixture: RowFixture, original: [MediaItem]) async throws {
        var items = original
        let mutations: [(inout MediaItem) -> Void] = [
            { $0.people[$0.people.count - 1].biography = "Changed visible card biography" },
            { $0.librarySortValues?.hasAtmos = true },
            { $0.selectedVersionID = "new-playback-version" },
            { $0.selectedSourceAccountID = "new-playback-account"; $0.explicitSourceSelection = true },
            { $0.resumePosition = 456 },
            { $0.title = "Changed visible card title" }
        ]
        for mutate in mutations {
            mutate(&items[0])
            let expected = items[0]
            let inputs = fixture.probe.cardInputs
            try await fixture.update(items: items)
            try await waitUntil {
                fixture.probe.presentedItems[expected.stablePresentationID] == expected
            }
            XCTAssertGreaterThan(fixture.probe.cardInputs, inputs,
                                 "Production card construction must receive the complete changed item.")
        }
    }

    private func independentlyDecodedSnapshots(itemCount: Int, peoplePerItem: Int) throws -> [[MediaItem]] {
        try Self.makeSnapshots(itemCount: itemCount, peoplePerItem: peoplePerItem)
    }

    private func withMainActorSchedulingProbe(
        _ operation: () async throws -> [String: Int]
    ) async throws -> [String: Int] {
        let samples = Counter()
        let sampler = Task.detached(priority: .userInitiated) {
            var maximumMicroseconds = 0
            while !Task.isCancelled {
                let requested = ContinuousClock.now
                let delay = await MainActor.run { requested.duration(to: .now) }
                let components = delay.components
                let microseconds = Int(components.seconds * 1_000_000
                    + components.attoseconds / 1_000_000_000_000)
                maximumMicroseconds = max(maximumMicroseconds, microseconds)
                samples.increment()
                do { try await Task.sleep(for: .milliseconds(1)) }
                catch { break }
            }
            return maximumMicroseconds
        }
        do {
            // Arm before publication starts. Queue delay includes executor/OS
            // scheduling, not just equality, and is not a presented-frame metric.
            try await Self.waitUntil { samples.value > 0 }
            var counters = try await operation()
            sampler.cancel()
            let maximum = await sampler.value
            XCTAssertGreaterThan(samples.value, 1, "The sampler must observe more than its startup handshake.")
            counters["mainActorSchedulingSamples"] = samples.value
            counters["mainActorMaxSchedulingDelayMicroseconds"] = maximum
            return counters
        } catch {
            sampler.cancel()
            _ = await sampler.value
            throw error
        }
    }

    private static func makeSnapshots(itemCount: Int, peoplePerItem: Int) throws -> [[MediaItem]] {
        let items = (0..<itemCount).map { index in
            MediaItem(
                id: "metadata-item-\(index)",
                title: "Metadata fixture title \(index)",
                kind: .movie,
                overview: String(repeating: "Synthetic server overview \(index). ", count: 16),
                genres: ["Fixture drama", "Fixture adventure"],
                people: (0..<peoplePerItem).map { person in
                    MediaPerson(
                        id: "person-\(index)-\(person)",
                        name: "Fixture credited person \(index)-\(person)",
                        role: "Fixture credited role \(index)-\(person)",
                        kind: "Actor",
                        biography: String(repeating: "Synthetic biography \(index)-\(person). ", count: 16),
                        externalID: "fixture-person-\(index)-\(person)",
                        lifeSummary: "Synthetic person metadata \(index)-\(person)"
                    )
                },
                runtime: 7_200,
                resumePosition: 120,
                allowsTitleBasedMetadataMatching: false,
                libraryID: "movies",
                lastPlayedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)),
                librarySortValues: .init(
                    sortName: "Fixture server sort name \(index)",
                    dateAdded: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)),
                    audienceRating: 80, criticRating: 75, userRating: 60, playCount: 1,
                    watched: false, matched: true, episodeWatchRollup: false, hasAtmos: false
                )
            )
        }
        let data = try JSONEncoder().encode(items)
        // Independent decodes prevent Array/String storage identity from hiding deep comparisons.
        return try (0..<2).map { _ in try JSONDecoder().decode([MediaItem].self, from: data) }
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard condition() else {
            XCTFail("Metadata fixture did not reach its required production state.")
            throw FixtureError.notSettled
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        try await Self.waitUntil(condition)
    }

    private enum FixtureError: Error { case notSettled }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
        func increment() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }
    }

    private final class PublicationStore: HomeContentStoring, @unchecked Sendable {
        let saves = Counter()
        private let lock = NSLock()
        private var content: HomeViewModel.Content?
        var lastContent: HomeViewModel.Content? {
            lock.lock(); defer { lock.unlock() }
            return content
        }
        func load() -> HomeViewModel.Content? { nil }
        func save(_ content: HomeViewModel.Content) {
            lock.lock()
            self.content = content
            lock.unlock()
            saves.increment()
        }
        func clear() {}
        func clearRows() {}
        func loadHero(for key: HeroConfigurationKey) -> [MediaItem]? { nil }
        func saveHero(_ items: [MediaItem], for key: HeroConfigurationKey) {}
        func clearHero() {}
    }

    @MainActor
    private final class PublicationFixture {
        let accountID = "metadata-account"
        let snapshots: [[MediaItem]]
        let provider: MetadataProvider
        let model: HomeViewModel
        let store = PublicationStore()
        let publications = Counter()
        let notifications = Counter()

        init(itemCount: Int, peoplePerItem: Int, kind: ProviderKind) throws {
            snapshots = try HomeMetadataPerformanceTests.makeSnapshots(
                itemCount: itemCount, peoplePerItem: peoplePerItem
            )
            provider = MetadataProvider(snapshots: snapshots, kind: kind)
            let account = Account(
                id: accountID, server: provider.session.server,
                userID: "metadata-user", userName: "Fixture", deviceID: "metadata-device"
            )
            let publications = publications
            model = HomeViewModel(
                accounts: [.init(account: account, provider: provider)],
                layoutStore: InMemoryHomeLayoutStore(),
                contentStore: store,
                currentVisibility: { .init(mergeLibrariesOnHome: true) },
                contentPublisher: { _, _ in publications.increment() }
            )
        }

        func observeState() {
            let notifications = notifications
            withObservationTracking { _ = model.state } onChange: { notifications.increment() }
        }

        func load() async throws {
            let saves = store.saves.value
            let publications = publications.value
            await model.load(showLoadingState: false)
            try await HomeMetadataPerformanceTests.waitUntil {
                self.store.saves.value > saves && self.publications.value > publications
            }
        }
    }

    private actor MetadataProvider: MediaProvider {
        nonisolated let kind: ProviderKind
        nonisolated let session: UserSession
        private let snapshots: [[MediaItem]]
        private var items: [MediaItem]
        private var libraryTitle = "Movies"
        private(set) var requestCount = 0

        init(snapshots: [[MediaItem]], kind: ProviderKind) {
            self.snapshots = snapshots
            items = snapshots[0]
            self.kind = kind
            session = .init(
                server: .init(id: "metadata-server", name: "Fixture",
                              baseURL: URL(string: "https://fixture.invalid")!, provider: kind),
                userID: "metadata-user", userName: "Fixture", deviceID: "metadata-device",
                accessToken: "fixture-not-a-credential"
            )
        }

        func useSnapshot(_ index: Int) { items = snapshots[index] }
        func replaceItems(_ items: [MediaItem]) { self.items = items }
        func replaceLibraryTitle(_ title: String) { libraryTitle = title }
        func libraries() async throws -> [MediaLibrary] {
            requestCount += 1
            return [.init(id: "movies", title: libraryTitle, kind: .movie)]
        }
        func continueWatching(limit: Int) async throws -> [MediaItem] {
            requestCount += 1
            return Array(items.prefix(limit))
        }
        func latest(limit: Int) async throws -> [MediaItem] {
            requestCount += 1
            return Array(items.prefix(limit))
        }
        func item(id: String) async throws -> MediaItem { throw AppError.notFound }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
            .init(items: [], startIndex: 0, totalCount: 0)
        }
        func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
        func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }

    @MainActor
    private final class RowProbe {
        var parentBodies = 0
        var cardInputs = 0
        var observedTailBiography: String?
        var presentedItems: [String: MediaItem] = [:]
        lazy var statusCue: (MediaItem) -> LocalizedStringResource? = { [weak self] item in
            self?.cardInputs += 1
            self?.presentedItems[item.stablePresentationID] = item
            return nil
        }
        let onSelect: (MediaItem) -> Void = { _ in }
    }

    private struct Rows: View, Equatable {
        let items: [MediaItem]
        let update: Int
        let probe: RowProbe

        // The harness advances this revision on every update; compare rich values
        // inside the production row, not a second time in this fixture's root.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.update == rhs.update && lhs.probe === rhs.probe
        }

        var body: some View {
            let _ = probe.parentBodies += 1
            MediaRowView(
                title: Text(verbatim: "Metadata fixture"), items: items,
                style: .landscape, statusCue: probe.statusCue, onSelect: probe.onSelect
            )
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.themePalette, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
        }
    }

    private struct ObservedRows: View {
        let model: HomeViewModel
        let probe: RowProbe

        var body: some View {
            let content = model.state.value
            let _ = probe.parentBodies += 1
            let _ = probe.observedTailBiography = content?.continueWatching.last?.people.last?.biography
            MediaRowView(
                title: Text(verbatim: "Metadata fixture"),
                items: content?.continueWatching ?? [],
                style: .landscape, statusCue: probe.statusCue, onSelect: probe.onSelect
            )
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.themePalette, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
        }
    }

    @MainActor
    private final class RowFixture {
        let probe = RowProbe()
        let window: UIWindow
        let previous: UIWindow?
        let host: UIViewController
        private let rowsHost: UIHostingController<Rows>?
        private var updateGeneration = 0

        init(items: [MediaItem], model: HomeViewModel? = nil) async throws {
            try await HomeMetadataPerformanceTests.waitUntil {
                UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.overrideUserInterfaceStyle = .dark
            if let model {
                rowsHost = nil
                host = UIHostingController(rootView: ObservedRows(model: model, probe: probe))
            } else {
                let rows = UIHostingController(rootView: Rows(items: items, update: updateGeneration, probe: probe))
                rowsHost = rows
                host = rows
            }
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func settle() async throws {
            try await HomeMetadataPerformanceTests.waitUntil { self.probe.cardInputs > 0 }
            try await Task.sleep(for: .milliseconds(300))
        }

        func update(items: [MediaItem]) async throws {
            let rowsHost = try XCTUnwrap(rowsHost)
            let bodies = probe.parentBodies
            updateGeneration += 1
            rowsHost.rootView = Rows(items: items, update: updateGeneration, probe: probe)
            try await waitForObservedUpdate(after: bodies)
        }

        func waitForObservedUpdate(after bodies: Int) async throws {
            host.view.setNeedsLayout()
            window.layoutIfNeeded()
            try await HomeMetadataPerformanceTests.waitUntil { self.probe.parentBodies > bodies }
            window.layoutIfNeeded()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }
}
