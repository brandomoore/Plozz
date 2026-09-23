import CoreModels
import Foundation
import XCTest

@testable import AppRuntime

final class CrossServerIdentityHydrationTests: XCTestCase {
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

  func libraries() async throws -> [MediaLibrary] { [] }
  func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
  func latest(limit: Int) async throws -> [MediaItem] { [] }
  func item(id: String) async throws -> MediaItem {
    guard id == sparse.id else { throw AppError.notFound }
    return full
  }
  func children(of itemID: String) async throws -> [MediaItem] { [] }
  func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws
    -> MediaPage
  {
    throw AppError.notFound
  }
  func search(query: String, limit: Int) async throws -> [MediaItem] { [sparse] }
  func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
  func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
  func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
