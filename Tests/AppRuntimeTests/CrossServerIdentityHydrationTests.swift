import CoreModels
import Foundation
import XCTest

@testable import AppRuntime

final class CrossServerIdentityHydrationTests: XCTestCase {
  func testRejectedSparseSourceCannotBridgeToAnotherWatchTarget() async throws {
    var a = MediaItem(id: "a", title: "Movie", kind: .movie,
                      providerIDs: ["Imdb": "tt111", "Tmdb": "123"], sourceAccountID: "server")
    let b = MediaItem(id: "b", title: "Movie", kind: .movie,
                      providerIDs: ["Tmdb": "123", "Tvdb": "456"])
    let c = MediaItem(id: "c", title: "Movie", kind: .movie, providerIDs: ["Tvdb": "456"])
    let index = IdentityIndex()
    await index.ingest([a, b, c], accountID: "server")
    let snapshot = await index.snapshot()
    a.rejectedSourceIDs = ["server:b"]
    XCTAssertEqual(snapshot.sourceRefs(for: a).map(\.itemID), ["a"])
    let mutation = try XCTUnwrap(WatchMutationFactory.playedToggle(
      item: a, played: true, primaryAccountID: "server", additionalSources: snapshot.sourceRefs(for: a)
    ))
    let applier = AppShellWatchMutationApplier(
      resolveProvider: { _ in nil }, applyTrakt: { _ in }, applySimkl: { _ in },
      applyAniList: { _ in }, applyMAL: { _ in }, allAccountIDs: { ["server"] },
      indexedSources: { ids, kind, title, year, rejected in
        snapshot.sources(forIdentities: ids, kind: kind, anchorTitle: title,
                         anchorYear: year, rejectedSourceIDs: rejected)
      }, indexedAccountIDs: { ["server"] }
    )
    let expansion = await applier.expandTargets(for: mutation)
    XCTAssertEqual(expansion.targets.map(\.itemID), ["a"])
  }

  func testCompatibleSparseSearchKeepsIndexedOwnershipAndLiveVersions() async throws {
    for kind in [MediaItemKind.movie, .series] {
      let seed = MediaItem(
        id: "discovery", title: "Same Title", kind: kind, providerIDs: ["Tmdb": "123"],
        availability: .unknown, locallyValidatedPlayableSource: false
      )
      let full = MediaItem(
        id: "owned", title: seed.title, kind: kind,
        providerIDs: ["Imdb": "tt111", "Tmdb": "123"]
      )
      for sparseIDs in [["Imdb": "tt111"], [:]] {
        var sparse = full
        sparse.providerIDs = sparseIDs
        let session = sourceLookupSession()
        let index = IdentityIndex()
        await index.ingest([full], accountID: "server")
        let snapshot = await index.snapshot()
        for searchEnabled in [true, false] {
          let provider = PartialIdentityProvider(
            session: session, sparse: sparse, full: sparse, searchEnabled: searchEnabled
          )
          let accounts = [ResolvedAccount(account: Account(id: "server", from: session), provider: provider)]
          let resolve = try XCTUnwrap(crossServerSourceResolver(
            in: accounts, identitySources: { snapshot.sourceRefs(for: $0) }
          ))
          let sources = await resolve(seed).sources
          XCTAssertEqual(sources.map(\.itemID), [full.id])
          XCTAssertFalse(TitleClassifier.isDiscoveryRouting(seed, identitySources: sources))
          if searchEnabled && !sparseIDs.isEmpty {
            XCTAssertFalse(sources.first?.versions.isEmpty ?? true, "Keep the fresh source, not just a cached ref")
          }
        }
      }
    }
  }

  @MainActor
  func testIncrementalCardsOnlyTargetTheirAcceptedMovieForWatchWrites() async throws {
    let first = MediaItem(
      id: "first", title: "Same Title", kind: .movie,
      providerIDs: ["Imdb": "tt111", "Tmdb": "123"], sourceAccountID: "server"
    )
    var second = first
    second.id = "second"
    second.providerIDs["Imdb"] = "tt222"
    let index = IdentityIndex()
    var sparse = first
    sparse.providerIDs = ["Tmdb": "123"]
    var sparseSecond = sparse
    sparseSecond.id = second.id
    await index.ingest([sparse, sparseSecond], accountID: "server")
    let snapshot = await index.snapshot()
    var merger = IncrementalMediaItemMerger(identitySources: { snapshot.sourceRefs(for: $0) })
    merger.append([first, second])
    for card in merger.mergedItems() {
      let mutation = try XCTUnwrap(WatchMutationFactory.playedToggle(
        item: card, played: true, primaryAccountID: "server",
        additionalSources: snapshot.sourceRefs(for: card)
      ))
      XCTAssertEqual(mutation.targets.map(\.itemID), [card.id])
      let restored = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(card))
      XCTAssertEqual(restored.rejectedSourceIDs, card.rejectedSourceIDs)
      XCTAssertEqual(snapshot.sourceRefs(for: restored).map(\.itemID), [card.id])
      var queued: [WatchMutation] = []
      let coordinator = MediaItemActionCoordinator(
        providerResolver: { _ in nil },
        additionalSources: { _ in snapshot.sourceRefs(for: first) },
        primaryAccountID: { "server" },
        crossServerWatchSyncEnabled: { true },
        enqueueWatchMutation: { queued.append($0) }
      )
      coordinator.perform(.markWatched, on: restored, context: MediaItemActionContext())
      XCTAssertEqual(queued.first?.targets.map(\.itemID), [card.id])
      let persisted = try JSONDecoder().decode(WatchMutation.self, from: JSONEncoder().encode(mutation))
      let applier = AppShellWatchMutationApplier(
        resolveProvider: { _ in nil }, applyTrakt: { _ in }, applySimkl: { _ in },
        applyAniList: { _ in }, applyMAL: { _ in }, allAccountIDs: { ["server"] },
        indexedSources: { ids, kind, title, year, rejected in
          snapshot.sources(forIdentities: ids, kind: kind, anchorTitle: title, anchorYear: year, rejectedSourceIDs: rejected)
        },
        indexedAccountIDs: { ["server"] }
      )
      let expansion = await applier.expandTargets(for: persisted)
      XCTAssertEqual(expansion.targets.map(\.itemID), [card.id])
    }
  }

  func testFreshRejectionRemovesPreviouslyCarriedSource() async throws {
    var seed = MediaItem(
      id: "owned", title: "Same Title", kind: .movie,
      providerIDs: ["Imdb": "tt111", "Tmdb": "123"], sourceAccountID: "server"
    )
    seed.sources = [
      MediaSourceRef(accountID: "server", itemID: seed.id, kind: .movie),
      MediaSourceRef(accountID: "server", itemID: "wrong", kind: .movie)
    ]
    let wrong = MediaItem(
      id: "wrong", title: seed.title, kind: .movie,
      providerIDs: ["Imdb": "tt222", "Tmdb": "123"]
    )
    var valid = seed
    valid.id = "valid"
    valid.sources = []
    let session = sourceLookupSession()
    let provider = PartialIdentityProvider(
      session: session, sparse: valid, full: valid, additionalItems: [wrong]
    )
    let accounts = [ResolvedAccount(account: Account(id: "server", from: session), provider: provider)]
    let resolve = try XCTUnwrap(crossServerSourceResolver(in: accounts, identitySources: { _ in [] }))
    let sources = await resolve(seed).sources
    XCTAssertEqual(Set(sources.map(\.itemID)), [seed.id, valid.id])
  }

  func testSparseDiscoveryKeepsAcceptedSearchGroupWithWarmIndex() async throws {
    for kind in [MediaItemKind.movie, .series] {
      for seedIsRicher in [false, true] {
        let seed = MediaItem(
          id: "discovery", title: "Same Title", kind: kind,
          people: seedIsRicher ? [MediaPerson(id: "actor", name: "Actor", kind: "Actor")] : [],
          providerIDs: ["Tmdb": "123"], availability: .unknown,
          locallyValidatedPlayableSource: false
        )
        let first = MediaItem(
          id: "first", title: seed.title, kind: kind,
          providerIDs: ["Imdb": "tt111", "Tmdb": "123"]
        )
        var second = first
        second.id = "second"
        second.providerIDs["Imdb"] = "tt222"
        for hits in [[first, second], [second, first]] {
          var indexedCopy = hits[0]
          indexedCopy.id = "indexed-copy"
          let session = sourceLookupSession()
          let provider = PartialIdentityProvider(
            session: session, sparse: hits[0], full: hits[0], additionalItems: [hits[1]]
          )
          let accounts = [ResolvedAccount(account: Account(id: "server", from: session), provider: provider)]
          let index = IdentityIndex()
          await index.ingest([first, second, indexedCopy], accountID: "server")
          let warm = await index.snapshot()
          var sparseRejected = hits[1]
          sparseRejected.providerIDs = ["Tmdb": "123"]
          let sparseIndex = IdentityIndex()
          await sparseIndex.ingest([hits[0], sparseRejected, indexedCopy], accountID: "server")
          let sparseWarm = await sparseIndex.snapshot()
          for snapshot in [IdentityIndexSnapshot.empty, warm, sparseWarm] {
            let resolve = try XCTUnwrap(crossServerSourceResolver(
              in: accounts, identitySources: { snapshot.sourceRefs(for: $0) }
            ))
            let sources = await resolve(seed).sources
            let expected = snapshot.isEmpty ? [hits[0].id] : [hits[0].id, indexedCopy.id]
            XCTAssertEqual(
              sources.map(\.itemID), expected,
              "\(kind), seed richer: \(seedIsRicher), warm: \(!snapshot.isEmpty)"
            )
            XCTAssertFalse(TitleClassifier.isDiscoveryRouting(seed, identitySources: sources))
          }
        }
      }
    }
  }

  func testRejectedFreshHitCannotReturnFromSparseIndex() async throws {
    let seed = MediaItem(
      id: "discovery", title: "Same Title", kind: .movie,
      providerIDs: ["Imdb": "tt111", "Tmdb": "123"],
      availability: .unknown, locallyValidatedPlayableSource: false
    )
    let wrong = MediaItem(
      id: "wrong", title: seed.title, kind: .movie,
      providerIDs: ["Imdb": "tt222", "Tmdb": "123"]
    )
    var sparse = wrong
    sparse.providerIDs = ["Tmdb": "123"]
    let session = sourceLookupSession()
    let provider = PartialIdentityProvider(session: session, sparse: wrong, full: wrong)
    let accounts = [ResolvedAccount(account: Account(id: "server", from: session), provider: provider)]
    let index = IdentityIndex()
    await index.ingest([sparse], accountID: "server")
    let snapshot = await index.snapshot()
    XCTAssertEqual(snapshot.sourceRefs(for: seed).map(\.itemID), [wrong.id])
    let resolve = try XCTUnwrap(crossServerSourceResolver(
      in: accounts, identitySources: { snapshot.sourceRefs(for: $0) }
    ))

    let sources = await resolve(seed).sources
    XCTAssertTrue(sources.isEmpty)
  }

  func testFreshOpenedSourceDoesNotRestoreStaleIndexedPeers() async throws {
    let stale = MediaItem(
      id: "retagged", title: "Same Title", kind: .movie,
      providerIDs: ["Imdb": "tt222", "Tmdb": "123"], sourceAccountID: "server"
    )
    var fresh = stale
    fresh.providerIDs["Imdb"] = "tt111"
    var wrongPeer = stale
    wrongPeer.id = "wrong-peer"
    let session = sourceLookupSession()
    let provider = PartialIdentityProvider(session: session, sparse: wrongPeer, full: wrongPeer)
    let accounts = [ResolvedAccount(account: Account(id: "server", from: session), provider: provider)]
    let index = IdentityIndex()
    await index.ingest([stale, wrongPeer], accountID: "server")
    let snapshot = await index.snapshot()
    let resolve = try XCTUnwrap(crossServerSourceResolver(
      in: accounts, identitySources: { snapshot.sourceRefs(for: $0) }
    ))

    let sources = await resolve(fresh).sources
    XCTAssertTrue(sources.isEmpty)
    XCTAssertFalse(TitleClassifier.isDiscoveryRouting(fresh, identitySources: sources))
    XCTAssertEqual(fresh.sourceAccountID, "server")
    XCTAssertEqual(fresh.id, "retagged")
  }

  func testUnambiguousIndexedSourceSurvivesEmptySearch() async throws {
    let seed = MediaItem(
      id: "discovery", title: "Same Title", kind: .movie,
      providerIDs: ["Imdb": "tt111", "Tmdb": "123"],
      availability: .unknown, locallyValidatedPlayableSource: false
    )
    let owned = MediaItem(
      id: "owned", title: seed.title, kind: .movie, providerIDs: seed.providerIDs
    )
    let session = sourceLookupSession()
    let provider = PartialIdentityProvider(
      session: session, sparse: owned, full: owned, searchEnabled: false
    )
    let accounts = [ResolvedAccount(account: Account(id: "server", from: session), provider: provider)]
    let index = IdentityIndex()
    await index.ingest([owned], accountID: "server")
    let snapshot = await index.snapshot()
    let resolve = try XCTUnwrap(crossServerSourceResolver(
      in: accounts, identitySources: { snapshot.sourceRefs(for: $0) }
    ))

    let sources = await resolve(seed).sources
    XCTAssertEqual(sources.map(\.itemID), [owned.id])
  }

  private func sourceLookupSession() -> UserSession {
    UserSession(
      server: MediaServer(
        id: "server", name: "Server", baseURL: URL(string: "https://server.test")!, provider: .silo),
      userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "TEST-ONLY"
    )
  }

  func testConflictingOwnershipStaysRejectedWithColdAndWarmIndex() async throws {
    for kind in [MediaItemKind.movie, .series] {
      let seed = MediaItem(
        id: "discovery", title: "Same Title", kind: kind,
        providerIDs: ["Imdb": "tt111", "Tmdb": "123"],
        availability: .unknown, locallyValidatedPlayableSource: false
      )
      let hit = MediaItem(
        id: "wrong", title: seed.title, kind: kind,
        people: [MediaPerson(id: "actor", name: "Actor", kind: "Actor")],
        providerIDs: ["Imdb": "tt222", "Tmdb": "123"]
      )
      let session = UserSession(
        server: MediaServer(
          id: "server", name: "Server", baseURL: URL(string: "https://server.test")!, provider: .silo),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "TEST-ONLY"
      )
      let provider = PartialIdentityProvider(session: session, sparse: hit, full: hit)
      let accounts = [ResolvedAccount(account: Account(id: "server", from: session), provider: provider)]
      let index = IdentityIndex()
      await index.ingest([hit], accountID: "server")
      let warm = await index.snapshot()
      for snapshot in [IdentityIndexSnapshot.empty, warm] {
        let resolve = try XCTUnwrap(crossServerSourceResolver(
          in: accounts, identitySources: { snapshot.sourceRefs(for: $0) }
        ))
        let sources = await resolve(seed).sources
        XCTAssertTrue(sources.isEmpty, "\(kind), warm: \(!snapshot.isEmpty)")
        XCTAssertTrue(TitleClassifier.isDiscoveryRouting(seed, identitySources: sources))
      }
    }
  }

  func testSourceLookupHydratesPartialIDsWithoutTitleOnlyMatching() async throws {
    let primary = MediaItem(
      id: "tmdb:series:202879", title: "Star Wars: Skeleton Crew", kind: .series,
      productionYear: 2024, providerIDs: ["Tmdb": "202879"], availability: .unknown
    )
    let sparse = MediaItem(
      id: "series-tvdb-420600", title: primary.title, kind: .series,
      productionYear: 2024, providerIDs: ["Tvdb": "420600"], libraryID: "shows"
    )
    var full = sparse
    full.providerIDs["Tmdb"] = "202879"
    full.libraryID = nil
    let session = UserSession(
      server: MediaServer(
        id: "silo", name: "Silo", baseURL: URL(string: "https://silo.test")!, provider: .silo),
      userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "TEST-ONLY"
    )
    for acceptsMatch in [true, false] {
      var detail = full
      if !acceptsMatch { detail.providerIDs["Tmdb"] = "999999" }
      let provider = PartialIdentityProvider(session: session, sparse: sparse, full: detail)
      let accounts = [
        ResolvedAccount(account: Account(id: "silo", from: session), provider: provider)
      ]
      let resolve = try XCTUnwrap(
        crossServerSourceResolver(in: accounts, identitySources: { _ in [] }))
      let sources = await resolve(primary).sources
      XCTAssertEqual(
        sources.contains { $0.accountID == "silo" && $0.itemID == sparse.id }, acceptsMatch)
      let search = try XCTUnwrap(relatedTitleLibrarySearch(in: accounts))
      let matches = await search(primary.title, 25)
      XCTAssertEqual(
        matches.first?.libraryID, "shows", "Hydration must preserve the search's library scope")
    }
  }
}

private struct PartialIdentityProvider: MediaProvider {
  let kind = ProviderKind.silo
  let catalogIdentityRequiresEnrichment = true
  let session: UserSession
  let sparse: MediaItem
  let full: MediaItem
  var additionalItems: [MediaItem] = []
  var searchEnabled = true

  func libraries() async throws -> [MediaLibrary] { [] }
  func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
  func latest(limit: Int) async throws -> [MediaItem] { [] }
  func item(id: String) async throws -> MediaItem {
    if id == sparse.id { return full }
    if let item = additionalItems.first(where: { $0.id == id }) { return item }
    throw AppError.notFound
  }
  func children(of itemID: String) async throws -> [MediaItem] { [] }
  func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws
    -> MediaPage
  {
    throw AppError.notFound
  }
  func search(query: String, limit: Int) async throws -> [MediaItem] {
    searchEnabled ? [sparse] + additionalItems : []
  }
  func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
  func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
  func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
