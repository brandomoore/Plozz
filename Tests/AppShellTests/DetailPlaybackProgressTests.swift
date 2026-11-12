import Combine
import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
import Foundation
import XCTest
@testable import AppShell

@MainActor
final class DetailPlaybackProgressTests: XCTestCase {
    func testEmptyEnabledSourceSetAndRemovedExplicitSourcesFailWithoutFallback() throws {
        for kind in [ProviderKind.plex, .jellyfin] {
            let item = MediaItem(id: "movie", title: "Fixture", kind: .movie, sourceAccountID: "active")
            let provider = ProgressProbeProvider(item: item, kind: kind)
            let accounts = [ResolvedAccount(account: Account(id: "active", from: provider.session), provider: provider)]
            XCTAssertEqual(try resolveProvider(nil, in: accounts).kind, kind)
            XCTAssertEqual(try resolveProvider("active", in: accounts).session.server.id, "active")
            for id: String? in [nil, "removed"] {
                XCTAssertThrowsError(try resolveProvider(id, in: [])) {
                    XCTAssertEqual($0 as? AppError, .unauthorized)
                }
            }
            XCTAssertThrowsError(try resolveProvider("removed", in: accounts)) {
                XCTAssertEqual($0 as? AppError, .unauthorized)
            }
        }
    }

    func testFailedDetailConstructionIsNotCachedAsASuccess() throws {
        let cache = KeyedViewStateCache<String, String>()
        XCTAssertThrowsError(try cache.value(forKey: "detail") { throw AppError.unauthorized })
        XCTAssertEqual(cache.value(forKey: "detail") { "available" }, "available")
        XCTAssertEqual(try cache.value(forKey: "detail") { throw AppError.unauthorized }, "available")
    }

    func testRetainedDetailCacheSeparatesIdenticalProviderIDsAcrossAccountsAndOrigins() throws {
        let cache = KeyedViewStateCache<DetailViewModelCacheKey, ItemDetailViewModel>(capacity: 12)
        var retained: [DetailViewModelCacheKey: ItemDetailViewModel] = [:]
        for account in ["plex-a", "plex-b"] {
            for origin: String? in [nil, account] {
                let movie = MediaItem(id: "42", title: "Movie", kind: .movie, sourceAccountID: account)
                let episode = MediaItem(id: "42", title: "Episode", kind: .episode, seriesID: "1", sourceAccountID: account)
                let season = MediaItem(id: "42", title: "Season", kind: .season, seriesID: "1", sourceAccountID: account)
                let provider = ProgressProbeProvider(item: movie, kind: .plex)
                let environment = DetailOpenEnvironment(
                    resolveProvider: { id in
                        XCTAssertEqual(id, account)
                        return provider
                    },
                    resolveOptionalProvider: { $0 == account ? provider : nil },
                    identitySources: { _ in [] },
                    crossServerSourceResolver: nil
                )
                let titleKey = DetailViewModelCacheKey.title(for: movie, libraryOrigin: origin)
                let episodeRoute = EpisodeContextRoute(episode: episode, originAccountID: origin)
                let seasonRoute = SeasonContextRoute(season: season, originAccountID: origin)
                let titleModel = try cache.value(forKey: titleKey) {
                    try environment.makeViewModel(for: movie, libraryOrigin: origin)
                }
                let episodeModel = try cache.value(forKey: DetailViewModelCacheKey(episodeRoute)) {
                    try environment.makeSeriesContextViewModel(
                        seriesID: episodeRoute.seriesID, seed: episode,
                        sourceAccountID: account, originAccountID: origin
                    )
                }
                let seasonModel = try cache.value(forKey: DetailViewModelCacheKey(seasonRoute)) {
                    try environment.makeSeriesContextViewModel(
                        seriesID: seasonRoute.seriesID, seed: season,
                        sourceAccountID: account, originAccountID: origin
                    )
                }
                for (key, model) in [
                    (titleKey, titleModel),
                    (DetailViewModelCacheKey(episodeRoute), episodeModel),
                    (DetailViewModelCacheKey(seasonRoute), seasonModel)
                ] {
                    XCTAssertNil(retained[key])
                    XCTAssertFalse(retained.values.contains { $0 === model })
                    XCTAssertEqual(model.currentSourceForDisplay?.accountID, account)
                    XCTAssertEqual(
                        model.originSourceAccountID, model === seasonModel ? account : nil,
                        "Only explicit season navigation retains a provider-local child choice"
                    )
                    retained[key] = model
                }
                XCTAssertEqual(titleModel.currentSourceForDisplay?.itemID, "42")
                XCTAssertEqual(episodeModel.currentSourceForDisplay?.itemID, "1")
                XCTAssertEqual(seasonModel.currentSourceForDisplay?.itemID, "1")
            }
        }
        XCTAssertEqual(retained.count, 12)
        for (key, model) in retained {
            XCTAssertTrue(try cache.value(forKey: key) { throw AppError.unauthorized } === model)
        }
    }

    private struct Fixture {
        let app: AppState
        let detail: ItemDetailViewModel
        let sources: [MediaSourceRef]
    }

    private let shareAccount = "share:fixture/Movies#viewer"
    private let plexAccount = "plex-fixture"

    func testShareOnlyDetailUpdatesImmediatelyAfterPlayback() async throws {
        let fixture = try await makeFixture(merged: false)
        defer { fixture.detail.suspendEnrichment() }
        let played = try playItem(fixture)
        XCTAssertEqual(played.sourceAccountID, shareAccount)
        XCTAssertEqual(fixture.detail.state.value?.item.sourceAccountID, shareAccount)

        let mutation = try await stop(played, fixture: fixture, sync: false)
        XCTAssertEqual(mutation.scopedItemIDs, ["\(shareAccount):\(played.id)"])
        XCTAssertEqual(fixture.detail.state.value?.item.resumePosition, 120)
        XCTAssertEqual(fixture.detail.state.value?.item.resumeProgressFraction, 0.12)
        XCTAssertEqual(try playItem(fixture).resumePosition, 120)
    }

    func testMergedSMBPlaybackUpdatesDetailWithWatchSyncEnabled() async throws {
        let fixture = try await makeFixture(merged: true)
        defer { fixture.detail.suspendEnrichment() }
        let played = try playItem(fixture)
        XCTAssertEqual(played.sourceAccountID, shareAccount)
        XCTAssertEqual(fixture.detail.state.value?.item.sourceAccountID, plexAccount)

        let mutation = try await stop(played, fixture: fixture, sync: true)
        XCTAssertEqual(mutation.scopedItemIDs, Set(fixture.sources.map(\.id)))
        XCTAssertEqual(fixture.detail.state.value?.item.resumePosition, 120)
        XCTAssertEqual(fixture.detail.state.value?.item.resumeProgressFraction, 0.12)
    }

    func testMergedSMBPlaybackUpdatesDetailWithWatchSyncDisabled() async throws {
        let fixture = try await makeFixture(merged: true)
        defer { fixture.detail.suspendEnrichment() }
        let played = try playItem(fixture)
        XCTAssertEqual(played.sourceAccountID, shareAccount)
        XCTAssertEqual(fixture.detail.state.value?.item.sourceAccountID, plexAccount)

        let mutation = try await stop(played, fixture: fixture, sync: false)
        XCTAssertEqual(mutation.scopedItemIDs, ["\(shareAccount):\(played.id)"])
        XCTAssertEqual(fixture.detail.state.value?.item.resumePosition, 120)
        XCTAssertEqual(fixture.detail.state.value?.item.resumeProgressFraction, 0.12)
        XCTAssertEqual(fixture.detail.sources.first { $0.accountID == shareAccount }?.resumePosition, 120)
        XCTAssertNil(fixture.detail.sources.first { $0.accountID == plexAccount }?.resumePosition)
        XCTAssertEqual(try playItem(fixture).resumePosition, 120)
    }

    func testResumeActionUsesNewSMBProgressWithoutReloadingDetail() async throws {
        let fixture = try await makeFixture(merged: true)
        defer { fixture.detail.suspendEnrichment() }
        let played = try playItem(fixture)
        _ = try await stop(played, fixture: fixture, sync: true)
        XCTAssertEqual(fixture.detail.state.value?.item.resumePosition, 120)

        let nextPlay = try playItem(fixture)
        XCTAssertEqual(nextPlay.sourceAccountID, shareAccount)
        XCTAssertEqual(nextPlay.id, played.id)
        XCTAssertEqual(nextPlay.resumePosition, 120, "The visible Resume action must not reuse pre-play source progress")
    }

    func testStopUpdatesTheDetailSourcePickerWatchState() async throws {
        let fixture = try await makeFixture(merged: true)
        defer { fixture.detail.suspendEnrichment() }
        _ = try await stop(try playItem(fixture), fixture: fixture, sync: true)
        XCTAssertEqual(fixture.detail.state.value?.item.resumePosition, 120)
        XCTAssertEqual(
            fixture.detail.sources.map(\.resumePosition),
            [120, 120],
            "The detail's separate source records must not retain the pre-play state"
        )
    }

    func testCompletionClearsResumeAndUnwatchUpdatesTheSameSources() async throws {
        for sync in [true, false] {
            let fixture = try await makeFixture(merged: true)
            defer { fixture.detail.suspendEnrichment() }
            _ = try await stop(try playItem(fixture), fixture: fixture, sync: sync)
            let played = try playItem(fixture)
            let finished = try await stop(played, fixture: fixture, sync: sync, position: 950, percent: 95)

            XCTAssertTrue(fixture.detail.state.value?.item.isPlayed == true)
            XCTAssertNil(fixture.detail.state.value?.item.resumePosition)
            XCTAssertNil(try playItem(fixture).resumePosition)
            let share = try XCTUnwrap(fixture.detail.sources.first { $0.accountID == shareAccount })
            XCTAssertTrue(share.isPlayed)
            XCTAssertTrue(share.hasBeenPlayed)
            XCTAssertNil(share.resumePosition)
            XCTAssertEqual(fixture.detail.sources.first { $0.accountID == plexAccount }?.isPlayed, sync)

            fixture.detail.applyWatchedState(MediaItemMutation(
                itemIDs: finished.itemIDs, scopedItemIDs: finished.scopedItemIDs,
                played: false, resumePosition: 0, playedPercentage: 0
            ))
            XCTAssertFalse(fixture.detail.state.value?.item.isPlayed ?? true)
            XCTAssertFalse(try XCTUnwrap(fixture.detail.sources.first { $0.accountID == shareAccount }).isPlayed)
            XCTAssertNil(try playItem(fixture).resumePosition)
        }
    }

    func testDetailReloadAndSourceSwitchCannotUndoPendingSMBProgress() async throws {
        let fixture = try await makeFixture(merged: true)
        defer { fixture.detail.suspendEnrichment() }
        _ = try await stop(try playItem(fixture), fixture: fixture, sync: false)

        // Both fixture providers still return their pre-write state.
        await fixture.detail.load()
        fixture.detail.suspendEnrichment()
        XCTAssertEqual(fixture.detail.state.value?.item.resumePosition, 120)
        XCTAssertEqual(try playItem(fixture).resumePosition, 120)
        await fixture.detail.switchToSource(accountID: shareAccount)
        XCTAssertEqual(fixture.detail.state.value?.item.sourceAccountID, shareAccount)
        XCTAssertEqual(fixture.detail.state.value?.item.resumePosition, 120)
        XCTAssertEqual(try playItem(fixture).resumePosition, 120)
    }

    func testUnrelatedAccountWithCollidingItemIDCannotChangeTheDetail() async throws {
        let fixture = try await makeFixture(merged: true)
        defer { fixture.detail.suspendEnrichment() }
        let prior = try XCTUnwrap(fixture.detail.state.value?.item)
        let priorSources = fixture.detail.sources
        fixture.detail.applyWatchedState(MediaItemMutation(
            itemIDs: [prior.id], scopedItemIDs: ["unrelated:\(prior.id)"],
            played: true, resumePosition: 0, playedPercentage: 1
        ))
        XCTAssertEqual(fixture.detail.state.value?.item, prior)
        XCTAssertEqual(fixture.detail.sources, priorSources)
    }

    private func playItem(_ fixture: Fixture) throws -> MediaItem {
        let item = try XCTUnwrap(fixture.detail.state.value?.item)
        let selected = DetailPlaybackSelection.preferredSource(
            sourceOverride: nil,
            libraryOrigin: shareAccount,
            itemSourceAccountID: item.sourceAccountID,
            sources: fixture.detail.sources,
            capabilities: .detected()
        )
        return DetailPlaybackSelection.playItem(
            for: item,
            sources: fixture.detail.sources,
            activeAccountID: selected?.accountID,
            versionID: nil,
            explicit: fixture.detail.isLibraryOriginPinned
        )
    }

    private func stop(
        _ played: MediaItem, fixture: Fixture, sync: Bool,
        position: TimeInterval = 120, percent: Double = 12
    ) async throws -> MediaItemMutation {
        let posted = expectation(description: "Production stop notification")
        var received: MediaItemMutation?
        let observer = NotificationCenter.default.publisher(for: .mediaItemDidMutate).sink { note in
            guard let mutation = MediaItemMutation.from(note),
                  mutation.itemIDs.contains(played.id),
                  mutation.resumePosition == (percent >= 90 ? 0 : position) else { return }
            received = mutation
            fixture.detail.applyWatchedState(mutation)
            posted.fulfill()
        }
        defer { observer.cancel() }
        let app = fixture.app
        let bridge = WatchOutboxBridge(
            beginLiveSession: { _, _ in },
            finishPlayback: { account, itemID, percent, mutation, item in
                Task { @MainActor in
                    app.finishLiveWatchSession(
                        accountID: account, itemID: itemID,
                        watchedPercent: percent, mutation: mutation, item: item
                    )
                }
            },
            checkpoint: { _ in },
            crossServerSync: { sync }
        )
        let sources = fixture.sources
        let handler = makePlaybackStoppedHandler(
            convergingItem: played,
            primaryAccountID: plexAccount,
            liveAccountID: played.sourceAccountID,
            liveItemID: played.id,
            watchBridge: bridge,
            identitySources: { _ in sources }
        )
        handler(position, percent)
        await fulfillment(of: [posted], timeout: 3)
        return try XCTUnwrap(received)
    }

    private func makeFixture(merged: Bool) async throws -> Fixture {
        let suffix = UUID().uuidString
        let share = MediaItem(
            id: "share-movie-\(suffix)", title: "Watch progress fixture", kind: .movie,
            overview: "Fixture overview", runtime: 1_000,
            providerIDs: ["Tmdb": "fixture"], sourceAccountID: shareAccount
        )
        let plex = MediaItem(
            id: "plex-movie-\(suffix)", title: share.title, kind: .movie,
            overview: "Fixture overview", runtime: 1_000,
            providerIDs: share.providerIDs, sourceAccountID: plexAccount
        )
        let shareProvider = ProgressProbeProvider(item: share, kind: .mediaShare)
        let plexProvider = ProgressProbeProvider(item: plex, kind: .plex)
        var shareSource = MediaSourceRef(accountID: shareAccount, itemID: share.id, providerKind: .mediaShare)
        shareSource.kind = .movie
        shareSource.locality = .local
        var plexSource = MediaSourceRef(accountID: plexAccount, itemID: plex.id, providerKind: .plex)
        plexSource.kind = .movie
        plexSource.locality = .local
        let sources = merged ? [shareSource, plexSource] : [shareSource]
        let selection = DetailOpenEnvironment.initialSourceSelection(
            for: share, isDiscovery: false, libraryOrigin: shareAccount,
            identitySources: { _ in sources }, sourceLocality: { _ in .local }
        )
        let selected = try XCTUnwrap(selection.selected)
        let providers = [shareAccount: shareProvider, plexAccount: plexProvider]
        let provider = try XCTUnwrap(providers[selected.accountID])
        let detail = ItemDetailViewModel(
            provider: provider,
            itemID: selected.itemID,
            initialItem: DetailOpenEnvironment.initialItem(for: share, selectedSource: selected),
            sourceAccountID: selected.accountID,
            originSourceAccountID: shareAccount,
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            initialSources: selection.sources,
            alternateProviderResolver: { providers[$0] }
        )
        await detail.load()
        detail.suspendEnrichment()

        let suite = "DetailPlaybackProgressTests.\(suffix)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let app = AppState(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            registry: ProviderRegistry(),
            profilesModel: ProfilesModel(store: ProfileStore(defaults: defaults)),
            appAdmissionStore: AppAdmissionStore(defaults: defaults)
        )
        return Fixture(app: app, detail: detail, sources: sources)
    }
}

private struct ProgressProbeProvider: MediaProvider {
    let storedItem: MediaItem
    let kind: ProviderKind
    let session: UserSession
    var connectionLocality: SourceLocality { .local }

    init(item: MediaItem, kind: ProviderKind) {
        storedItem = item
        self.kind = kind
        session = UserSession(
            server: MediaServer(id: item.sourceAccountID!, name: "Fixture", baseURL: URL(string: "https://fixture.test")!, provider: kind),
            userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: "fixture"
        )
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        guard id == storedItem.id else { throw AppError.notFound }
        return storedItem
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
