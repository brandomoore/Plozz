import CoreModels
import FeatureHome
import Foundation
import XCTest
@testable import AppRuntime

final class HeroDiscoveryWatchStateRefreshTests: XCTestCase {
    private enum RejectedCopy: CaseIterable {
        case unavailable, conflictingIDs, hiddenIndex, hiddenLive
        case wrongKind, wrongReturnedID, unplayable
    }

    private enum LiveDisqualification: CaseIterable {
        case conflictingIDs, wrongKind, wrongReturnedID, unplayable
    }

    func testRejectedCopiesCannotReenterThroughWatchRefreshOrPlaybackRouting() async throws {
        for kind in [MediaItemKind.movie, .series] {
            for providerKind in [ProviderKind.plex, .jellyfin] {
                for rejection in RejectedCopy.allCases {
                    let raw = external(kind: kind)
                    let original = owned(kind: kind)
                    var rejected = original
                    rejected.isPlayed = true
                    rejected.hasBeenPlayed = true
                    rejected.resumePosition = 999
                    var rejectedRef = MediaSourceRef(
                        accountID: "b", itemID: original.id, libraryID: "visible", kind: kind,
                        resumePosition: 999, isPlayed: true
                    )
                    switch rejection {
                    case .unavailable:
                        break
                    case .conflictingIDs:
                        rejected.providerIDs = ["TMDB ID": "42", "IMDb": "tt9999"]
                    case .hiddenIndex:
                        rejectedRef.libraryID = "hidden"
                    case .hiddenLive:
                        rejected.libraryID = "hidden"
                    case .wrongKind:
                        rejected.kind = kind == .movie ? .series : .movie
                        rejectedRef.kind = nil
                    case .wrongReturnedID:
                        rejected.id = "different-physical-item"
                    case .unplayable:
                        rejected.locallyValidatedPlayableSource = false
                    }
                    let first = fixture("a", kind: providerKind, record: original, locality: .remote)
                    let second = fixture(
                        "b", kind: providerKind == .plex ? .jellyfin : .plex,
                        record: rejection == .unavailable ? nil : rejected, locality: .local
                    )
                    let accounts = [first.account, second.account]
                    let hints = [
                        MediaSourceRef(accountID: "a", itemID: original.id, kind: kind),
                        rejectedRef
                    ]
                    let candidate = try await discover(
                        raw, accounts: accounts, hints: hints,
                        visibility: .init(disabledKeys: ["b:hidden"])
                    )
                    XCTAssertTrue(candidate.locallyValidatedPlayableSource)
                    XCTAssertEqual(candidate.sources.map(\.id), ["a:\(original.id)"])
                    let rejectedLookups = await second.provider.lookupIDs

                    var live = original
                    live.resumePosition = 120
                    live.playedPercentage = 0.2
                    live.lastPlayedAt = Date(timeIntervalSince1970: 20)
                    live.sources = [
                        .init(accountID: "b", itemID: original.id, kind: kind, isPlayed: true)
                    ]
                    await first.provider.setRecord(live)
                    let refreshed = try await refresh(candidate, accounts: accounts, hints: hints)
                    let selected = PlaybackSourceSelection.bestPlayItem(
                        refreshed, accounts: accounts, identitySources: { _ in hints }
                    )

                    XCTAssertFalse(refreshed.hasBeenPlayed, "\(providerKind), \(kind), \(rejection)")
                    XCTAssertFalse(refreshed.isPlayed)
                    XCTAssertEqual(refreshed.resumePosition, 120)
                    XCTAssertEqual(refreshed.sources.map(\.id), ["a:\(original.id)"])
                    XCTAssertEqual(refreshed.sources.first?.resumePosition, 120)
                    XCTAssertTrue(selected.locallyValidatedPlayableSource)
                    XCTAssertEqual(selected.sourceAccountID, "a", "A rejected local copy must not beat verified remote A.")
                    XCTAssertEqual(selected.id, original.id)
                    let afterRefresh = await second.provider.lookupIDs
                    XCTAssertEqual(afterRefresh, rejectedLookups, "Refresh must not retry a rejected global-index hint.")
                }
            }
        }
    }

    func testExternalDiscoveryDoesNotAcquireOwnershipOrWatchStateOnRefresh() async throws {
        for kind in [ProviderKind.plex, .jellyfin] {
            let raw = external()
            let missing = fixture("b", kind: kind, record: nil, locality: .local)
            let hints = [MediaSourceRef(
                accountID: "b", itemID: "library-42", kind: .movie,
                resumePosition: 999, isPlayed: true
            )]
            let candidate = try await discover(raw, accounts: [missing.account], hints: hints)
            var recovered = owned()
            recovered.isPlayed = true
            recovered.hasBeenPlayed = true
            await missing.provider.setRecord(recovered)

            let refreshed = try await refresh(candidate, accounts: [missing.account], hints: hints)
            let selected = PlaybackSourceSelection.bestPlayItem(
                refreshed, accounts: [missing.account], identitySources: { _ in hints }
            )

            XCTAssertEqual(refreshed, candidate, "A lightweight watch refresh is not a new ownership-verification pass.")
            XCTAssertFalse(selected.locallyValidatedPlayableSource)
            XCTAssertFalse(selected.hasBeenPlayed)
            XCTAssertNil(selected.sourceAccountID)
            XCTAssertTrue(selected.sources.isEmpty)
            let lookups = await missing.provider.lookupIDs
            XCTAssertEqual(lookups, ["library-42"])
        }
    }

    func testEveryVerifiedCopyRefreshesWithoutNeedingNewIndexHintsAcrossProvidersAndAccounts() async throws {
        for kind in [MediaItemKind.movie, .series] {
            for providerKind in [ProviderKind.plex, .jellyfin] {
                let original = owned(kind: kind)
                let first = fixture("a", kind: providerKind, record: original, locality: .remote)
                let second = fixture(
                    "b", kind: providerKind == .plex ? .jellyfin : .plex,
                    record: original, locality: .local
                )
                let third = fixture("c", kind: providerKind, record: original, locality: .remote)
                let accounts = [first.account, second.account, third.account]
                let hints = accounts.map {
                    MediaSourceRef(accountID: $0.account.id, itemID: original.id, kind: kind)
                }
                let candidate = try await discover(external(kind: kind), accounts: accounts, hints: hints)
                XCTAssertEqual(candidate.sources.count, 3)

                var earlier = original
                earlier.resumePosition = 100
                earlier.lastPlayedAt = Date(timeIntervalSince1970: 10)
                await first.provider.setRecord(earlier)
                var rewatch = original
                rewatch.resumePosition = 200
                rewatch.playedPercentage = 0.2
                rewatch.hasBeenPlayed = true
                rewatch.isFavorite = true
                rewatch.lastPlayedAt = Date(timeIntervalSince1970: 20)
                rewatch.sources = [
                    .init(accountID: "foreign-profile", itemID: "foreign", kind: kind, isPlayed: true)
                ]
                await second.provider.setRecord(rewatch)

                let refreshed = try await refresh(candidate, accounts: accounts, hints: [])
                let selected = PlaybackSourceSelection.bestPlayItem(
                    refreshed, accounts: accounts, identitySources: { _ in [] }
                )
                XCTAssertTrue(refreshed.hasBeenPlayed)
                XCTAssertFalse(refreshed.isPlayed)
                XCTAssertTrue(refreshed.isFavorite)
                XCTAssertEqual(refreshed.resumePosition, 200)
                XCTAssertEqual(refreshed.playedPercentage, 0.2)
                XCTAssertEqual(refreshed.lastPlayedAt, rewatch.lastPlayedAt)
                XCTAssertEqual(Set(refreshed.sources.map(\.id)), Set(hints.map(\.id)))
                XCTAssertEqual(refreshed.sources.first { $0.accountID == "a" }?.resumePosition, 100)
                XCTAssertEqual(refreshed.sources.first { $0.accountID == "b" }?.hasBeenPlayed, true)
                XCTAssertEqual(refreshed.sources.first { $0.accountID == "c" }?.hasBeenPlayed, false)
                XCTAssertEqual(selected.sourceAccountID, "b")
                XCTAssertEqual(selected.resumePosition, 200)
                XCTAssertTrue(selected.locallyValidatedPlayableSource)
                for provider in [first.provider, second.provider, third.provider] {
                    let lookups = await provider.lookupIDs
                    XCTAssertEqual(lookups, [original.id, original.id])
                }
            }
        }
    }

    func testUnavailableOrInconclusiveVerifiedDetailPreservesKnownOwnershipAndState() async throws {
        var original = owned()
        original.resumePosition = 45
        original.lastPlayedAt = Date(timeIntervalSince1970: 10)
        var sparse = original
        sparse.isPlayed = true
        sparse.hasBeenPlayed = true
        sparse.resumePosition = 999
        sparse.providerIDs = [:]
        var missingKind = sparse
        missingKind.kind = .unknown
        var missingID = sparse
        missingID.id = ""

        for kind in [ProviderKind.plex, .jellyfin] {
            for response in [nil, sparse, missingKind, missingID] as [MediaItem?] {
                let first = fixture("a", kind: kind, record: original, locality: .remote)
                let hints = [MediaSourceRef(accountID: "a", itemID: original.id, kind: .movie)]
                let candidate = try await discover(external(), accounts: [first.account], hints: hints)
                await first.provider.setRecord(response)
                let refreshed = try await refresh(candidate, accounts: [first.account], hints: hints)
                let selected = PlaybackSourceSelection.bestPlayItem(
                    refreshed, accounts: [first.account], identitySources: { _ in hints }
                )
                XCTAssertEqual(refreshed, candidate)
                XCTAssertFalse(refreshed.hasBeenPlayed)
                XCTAssertEqual(refreshed.resumePosition, 45)
                XCTAssertTrue(selected.locallyValidatedPlayableSource)
                XCTAssertEqual(selected.sourceAccountID, "a")
            }
        }
    }

    func testPositiveDisqualificationRevokesLocalCopyAndRoutesOnlyToSurvivingRemoteCopy() async throws {
        for kind in [MediaItemKind.movie, .series] {
            for providerKind in [ProviderKind.plex, .jellyfin] {
                for rejection in LiveDisqualification.allCases {
                    for primaryAccount in ["a", "b"] {
                        var remote = owned(kind: kind)
                        remote.id = "remote-42"
                        remote.resumePosition = 45
                        var local = owned(kind: kind)
                        local.id = "local-42"
                        local.versions = [
                            .init(id: "local-version", sourceItemID: local.id, sourceAccountID: "b")
                        ]
                        let first = fixture("a", kind: providerKind, record: remote, locality: .remote)
                        let second = fixture(
                            "b", kind: providerKind == .plex ? .jellyfin : .plex,
                            record: local, locality: .local
                        )
                        let accounts = [first.account, second.account]
                        let hints = [
                            MediaSourceRef(accountID: "a", itemID: remote.id, kind: kind),
                            MediaSourceRef(accountID: "b", itemID: local.id, kind: kind)
                        ]
                        var candidate = try await discover(external(kind: kind), accounts: accounts, hints: hints)
                        let primary = try XCTUnwrap(candidate.sources.first { $0.accountID == primaryAccount })
                        candidate = candidate.selectingSource(primary)
                        candidate.selectedSourceAccountID = "b"
                        candidate.explicitSourceSelection = true
                        candidate.selectedVersionID = "local-version"
                        await second.provider.setRecord(disqualified(local, by: rejection))

                        let refreshed = try await refresh(candidate, accounts: accounts, hints: hints)
                        let selected = PlaybackSourceSelection.bestPlayItem(
                            refreshed, accounts: accounts, identitySources: { _ in hints }
                        )
                        XCTAssertEqual(refreshed.sources.map(\.id), ["a:remote-42"], "\(rejection)")
                        XCTAssertTrue(refreshed.locallyValidatedPlayableSource)
                        XCTAssertFalse(refreshed.hasBeenPlayed)
                        XCTAssertEqual(refreshed.resumePosition, 45)
                        XCTAssertEqual(refreshed.id, "remote-42")
                        XCTAssertEqual(refreshed.sourceAccountID, "a")
                        XCTAssertNotEqual(refreshed.selectedSourceAccountID, "b")
                        XCTAssertFalse(refreshed.explicitSourceSelection)
                        XCTAssertNil(refreshed.selectedVersionID)
                        XCTAssertFalse(refreshed.additionalSourceAccountIDs.contains("b"))
                        XCTAssertFalse(refreshed.versions.contains { $0.sourceAccountID == "b" })
                        XCTAssertEqual(selected.sourceAccountID, "a")
                        XCTAssertEqual(selected.id, "remote-42")
                        XCTAssertTrue(selected.locallyValidatedPlayableSource)
                    }
                }
            }
        }
    }

    func testSolePositivelyDisqualifiedCopyLosesAllDiscoveryRoutingOwnership() async throws {
        for kind in [MediaItemKind.movie, .series] {
            for providerKind in [ProviderKind.plex, .jellyfin] {
                for rejection in LiveDisqualification.allCases {
                    var original = owned(kind: kind)
                    original.resumePosition = 45
                    original.versions = [
                        .init(id: "old-version", sourceItemID: original.id, sourceAccountID: "a")
                    ]
                    let first = fixture("a", kind: providerKind, record: original, locality: .local)
                    let hints = [MediaSourceRef(accountID: "a", itemID: original.id, kind: kind)]
                    var candidate = try await discover(external(kind: kind), accounts: [first.account], hints: hints)
                    candidate = candidate.selectingSource(
                        try XCTUnwrap(candidate.sources.first), versionID: "old-version", explicit: true
                    )
                    await first.provider.setRecord(disqualified(original, by: rejection))

                    let refreshed = try await refresh(candidate, accounts: [first.account], hints: hints)
                    let selected = PlaybackSourceSelection.bestPlayItem(
                        refreshed, accounts: [first.account], identitySources: { _ in hints }
                    )
                    XCTAssertEqual(refreshed.id, candidate.id, "Keep stable presentation identity without physical ownership.")
                    XCTAssertEqual(refreshed.title, candidate.title)
                    XCTAssertEqual(refreshed.providerIDs, candidate.providerIDs)
                    XCTAssertEqual(refreshed.discoverySources, candidate.discoverySources)
                    XCTAssertFalse(refreshed.locallyValidatedPlayableSource)
                    XCTAssertFalse(refreshed.hasBeenPlayed)
                    XCTAssertNil(refreshed.resumePosition)
                    XCTAssertNil(refreshed.sourceAccountID)
                    XCTAssertNil(refreshed.selectedSourceAccountID)
                    XCTAssertFalse(refreshed.explicitSourceSelection)
                    XCTAssertTrue(refreshed.additionalSourceAccountIDs.isEmpty)
                    XCTAssertTrue(refreshed.sources.isEmpty)
                    XCTAssertTrue(refreshed.versions.isEmpty)
                    XCTAssertNil(refreshed.selectedVersionID)
                    XCTAssertNil(refreshed.libraryID)
                    XCTAssertNil(refreshed.mediaInfo)
                    XCTAssertFalse(selected.locallyValidatedPlayableSource)
                    XCTAssertNil(selected.sourceAccountID)
                    XCTAssertTrue(selected.sources.isEmpty)
                }
            }
        }
    }

    func testRejectedPrimaryCannotReturnThroughRetainedVersionBackingOrSparseReplacement() async throws {
        var remote = owned()
        remote.id = "remote-42"
        remote.resumePosition = 45
        var local = owned()
        local.id = "local-42"
        let version = MediaVersion(id: "local-version", sourceItemID: local.id, sourceAccountID: "b")
        local.versions = [version]
        let first = fixture("a", kind: .plex, record: remote, locality: .remote)
        let second = fixture("b", kind: .jellyfin, record: local, locality: .local)
        let accounts = [first.account, second.account]
        let hints = [
            MediaSourceRef(accountID: "a", itemID: remote.id, kind: .movie),
            MediaSourceRef(accountID: "b", itemID: local.id, kind: .movie)
        ]
        var candidate = try await discover(external(), accounts: accounts, hints: hints)
        let remoteIndex = try XCTUnwrap(candidate.sources.firstIndex { $0.accountID == "a" })
        candidate.sources[remoteIndex].versions = [version]
        let localSource = try XCTUnwrap(candidate.sources.first { $0.accountID == "b" })
        candidate = candidate.selectingSource(localSource, versionID: version.id, explicit: true)
        await first.provider.setRecord(nil)
        await second.provider.setRecord(disqualified(local, by: .conflictingIDs))

        let refreshed = try await refresh(candidate, accounts: accounts, hints: hints)
        let selected = PlaybackSourceSelection.bestPlayItem(
            refreshed, accounts: accounts, identitySources: { _ in hints }
        )
        let staleVersionSelection = MediaItem.retargetedForPlayback(
            item: refreshed, sources: refreshed.sources, activeAccountID: "a", versionID: version.id
        )
        XCTAssertEqual(refreshed.sources.map(\.id), ["a:remote-42"])
        XCTAssertTrue(refreshed.versions.isEmpty, "A sparse replacement cannot inherit the revoked primary's versions.")
        XCTAssertTrue(refreshed.sources.allSatisfy { $0.versions.isEmpty })
        XCTAssertNil(refreshed.selectedVersionID)
        XCTAssertEqual(refreshed.resumePosition, 45)
        XCTAssertEqual(selected.sourceAccountID, "a")
        XCTAssertEqual(selected.id, remote.id)
        XCTAssertEqual(staleVersionSelection.sourceAccountID, "a")
        XCTAssertEqual(staleVersionSelection.id, remote.id)
    }

    func testNewConflictingNamespaceBetweenLiveCopiesRevokesRoutingAndRejectsHistory() async throws {
        var original = owned()
        original.providerIDs = ["Tmdb": "42"]
        let first = fixture("a", kind: .plex, record: original, locality: .remote)
        let second = fixture("b", kind: .jellyfin, record: original, locality: .local)
        let accounts = [first.account, second.account]
        let hints = accounts.map {
            MediaSourceRef(accountID: $0.account.id, itemID: original.id, kind: .movie)
        }
        let candidate = try await discover(external(), accounts: accounts, hints: hints)
        var firstLive = original
        firstLive.providerIDs["Imdb"] = "tt0042"
        firstLive.resumePosition = 120
        var conflictingLive = original
        conflictingLive.providerIDs["IMDb"] = "tt9999"
        conflictingLive.hasBeenPlayed = true
        await first.provider.setRecord(firstLive)
        await second.provider.setRecord(conflictingLive)

        let refreshed = try await refresh(candidate, accounts: accounts, hints: hints)
        let selected = PlaybackSourceSelection.bestPlayItem(
            refreshed, accounts: accounts, identitySources: { _ in hints }
        )
        XCTAssertFalse(refreshed.hasBeenPlayed)
        XCTAssertEqual(refreshed.sources.first { $0.accountID == "a" }?.resumePosition, 120)
        XCTAssertEqual(refreshed.sources.map(\.id), ["a:\(original.id)"])
        XCTAssertEqual(selected.sourceAccountID, "a")
        XCTAssertTrue(selected.locallyValidatedPlayableSource)
    }

    func testOrdinaryCandidatesStillUseIndexCopiesAndLocalPlaybackPreference() async throws {
        for kind in [ProviderKind.plex, .jellyfin] {
            let original = owned().taggingSource("a")
            let first = fixture("a", kind: kind, record: original, locality: .remote)
            var alternate = owned()
            alternate.id = "alternate"
            alternate.resumePosition = 400
            let second = fixture(
                "b", kind: kind == .plex ? .jellyfin : .plex, record: alternate, locality: .local
            )
            let accounts = [first.account, second.account]
            let hints = [MediaSourceRef(accountID: "b", itemID: alternate.id, kind: .movie)]
            let refreshed = try await refresh(
                original, accounts: accounts, hints: hints, expectsIndexLookup: true
            )
            let selected = PlaybackSourceSelection.bestPlayItem(
                refreshed, accounts: accounts, identitySources: { _ in hints }
            )
            XCTAssertEqual(refreshed.sources.map(\.id), ["b:alternate"])
            XCTAssertEqual(refreshed.sources.first?.resumePosition, 400)
            XCTAssertEqual(selected.sourceAccountID, "b")
            XCTAssertEqual(selected.id, "alternate")
            XCTAssertTrue(selected.locallyValidatedPlayableSource)
            let lookups = await second.provider.lookupIDs
            XCTAssertEqual(lookups, ["alternate"])
        }
    }

    private func external(kind: MediaItemKind = .movie) -> MediaItem {
        MediaItem(
            id: "discovery:42", title: "Title", kind: kind, productionYear: 2026,
            providerIDs: ["Tmdb": "42"], discoverySources: [.tmdb],
            locallyValidatedPlayableSource: false
        )
    }

    private func owned(kind: MediaItemKind = .movie) -> MediaItem {
        MediaItem(
            id: "library-42", title: "Title", kind: kind, productionYear: 2026,
            providerIDs: ["Tmdb": "42", "Imdb": "tt0042"], libraryID: "visible"
        )
    }

    private func disqualified(_ original: MediaItem, by reason: LiveDisqualification) -> MediaItem {
        var record = original
        record.isPlayed = true
        record.hasBeenPlayed = true
        record.resumePosition = 999
        switch reason {
        case .conflictingIDs:
            record.providerIDs = ["TMDB ID": "42", "IMDb": "tt9999"]
        case .wrongKind:
            record.kind = original.kind == .movie ? .series : .movie
        case .wrongReturnedID:
            record.id = "different-physical-item"
        case .unplayable:
            record.locallyValidatedPlayableSource = false
        }
        return record
    }

    private func fixture(
        _ accountID: String, kind: ProviderKind, record: MediaItem?, locality: SourceLocality
    ) -> (account: ResolvedAccount, provider: WatchRefreshProvider) {
        let session = UserSession(
            server: MediaServer(
                id: "server-\(accountID)", name: accountID,
                baseURL: URL(string: "https://server.example")!, provider: kind
            ),
            userID: "profile-\(accountID)", userName: "Viewer",
            deviceID: "fixture", accessToken: "TEST-ONLY"
        )
        let provider = WatchRefreshProvider(
            kind: kind, session: session, record: record, locality: locality
        )
        return (ResolvedAccount(account: Account(id: accountID, from: session), provider: provider), provider)
    }

    private func discover(
        _ raw: MediaItem, accounts: [ResolvedAccount], hints: [MediaSourceRef],
        visibility: HomeLibraryVisibility = .default
    ) async throws -> MediaItem {
        let runtime = HeroDiscoveryRuntime(
            accounts: accounts, identitySources: { _ in hints }, discovery: { _, _ in [raw] }
        )
        let candidates = await runtime.candidates(
            .init(), sources: [.tmdb], hideWatched: true, visibility: visibility
        )
        return try XCTUnwrap(candidates.first)
    }

    private func refresh(
        _ candidate: MediaItem, accounts: [ResolvedAccount], hints: [MediaSourceRef],
        expectsIndexLookup: Bool = false
    ) async throws -> MediaItem {
        let providers = Dictionary(uniqueKeysWithValues: accounts.map { ($0.account.id, $0.provider) })
        let refreshed = await HeroCandidateWatchStateEnricher.enrich(
            [candidate],
            sourceRefs: { _ in
                XCTAssertTrue(expectsIndexLookup, "Discovery must not consult the global identity index during refresh.")
                return hints
            },
            fetch: { source in
                guard let provider = providers[source.accountID] else { return nil }
                do {
                    return try await provider.item(id: source.itemID).taggingSource(source.accountID)
                } catch {
                    return nil
                }
            }
        )
        return try XCTUnwrap(refreshed.first)
    }
}

private actor WatchRefreshProvider: MediaProvider {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    nonisolated let connectionLocality: SourceLocality
    private var record: MediaItem?
    private(set) var lookupIDs: [String] = []

    init(kind: ProviderKind, session: UserSession, record: MediaItem?, locality: SourceLocality) {
        self.kind = kind
        self.session = session
        self.record = record
        self.connectionLocality = locality
    }

    func setRecord(_ record: MediaItem?) { self.record = record }
    func item(id: String) async throws -> MediaItem {
        lookupIDs.append(id)
        guard let record else { throw AppError.notFound }
        return record
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
