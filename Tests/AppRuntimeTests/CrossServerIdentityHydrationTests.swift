import CoreModels
import Foundation
import XCTest

@testable import AppRuntime

final class CrossServerIdentityHydrationTests: XCTestCase {
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
            let sources = await resolve(seed)
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

    let sources = await resolve(seed)
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

    let sources = await resolve(fresh)
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

    let sources = await resolve(seed)
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
        let sources = await resolve(seed)
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
      let sources = await resolve(primary)
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
