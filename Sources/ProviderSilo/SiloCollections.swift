import Foundation
import CoreModels

private struct SiloCollectionCard: Decodable, Sendable {
    let id: String
    let title: String
    let description: String?
    let poster_url: String
    let backdrop_url: String?
}

private struct SiloLibraryCollections: Decodable, Sendable {
    let library_id: String
    let collections: [SiloCollectionCard]
}

extension SiloProvider {
    public func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        guard page.startIndex >= 0, page.limit > 0 else { throw AppError.invalidResponse }
        let response: SiloLibraryCollections = try await client.request(
            "/library/\(try SiloAPI.pathComponent(libraryID))/collections")
        guard response.library_id == libraryID else { throw AppError.invalidResponse }
        var cards = response.collections
        if page.sort.field == .name {
            cards.sort {
                let ascending = $0.title.localizedStandardCompare($1.title) == .orderedAscending
                return page.sort.direction == .ascending ? ascending : !ascending && $0.title != $1.title
            }
        }
        let items = cards.dropFirst(page.startIndex).prefix(page.limit).map { card in
            MediaItem(id: Self.collectionID(libraryID: libraryID, id: card.id), title: card.title,
                      kind: .collection, overview: card.description,
                      posterURL: resourceURL(card.poster_url), backdropURL: resourceURL(card.backdrop_url),
                      sourceAccountID: accountID, libraryID: libraryID)
        }
        return MediaPage(items: Array(items), startIndex: page.startIndex, totalCount: cards.count)
    }

    public func collectionMembers(of collectionID: String, page: PageRequest) async throws -> MediaPage {
        guard page.startIndex >= 0, page.limit > 0,
              let identity = Self.collectionIdentity(collectionID) else { throw AppError.notFound }
        let response: SiloCatalogPage = try await client.request("/catalog", query: [
            URLQueryItem(name: "source", value: "library_collection"),
            URLQueryItem(name: "collection_id", value: identity.id),
            URLQueryItem(name: "library_id", value: identity.libraryID),
            URLQueryItem(name: "seek", value: String(page.startIndex)),
            URLQueryItem(name: "limit", value: String(min(page.limit, 200)))
        ])
        return MediaPage(items: response.items.map { map($0, libraryID: identity.libraryID) },
                         startIndex: page.startIndex, totalCount: response.total)
    }

    static func collectionID(libraryID: String, id: String) -> String {
        "silo-collection:\(Data(libraryID.utf8).base64EncodedString()):\(Data(id.utf8).base64EncodedString())"
    }

    static func collectionIdentity(_ value: String) -> (libraryID: String, id: String)? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "silo-collection",
              let libraryData = Data(base64Encoded: String(parts[1])),
              let idData = Data(base64Encoded: String(parts[2])),
              let library = String(data: libraryData, encoding: .utf8), !library.isEmpty,
              let id = String(data: idData, encoding: .utf8), !id.isEmpty else { return nil }
        return (library, id)
    }
}
