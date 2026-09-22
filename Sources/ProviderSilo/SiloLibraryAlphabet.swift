import CoreModels
import Foundation

extension SiloProvider {
    public func letterIndex(in containerID: String, kind: MediaItemKind,
                            sort: CoreModels.SortDescriptor) async throws -> [LibraryLetterIndexEntry] {
        guard sort.field == .name, [.movie, .series, .video].contains(kind) else { return [] }
        return LibraryLetterIndex.deferredEntries(direction: sort.direction)
    }

    public func letterPosition(in containerID: String, kind: MediaItemKind, letter: String,
                               sort: CoreModels.SortDescriptor) async throws -> Int? {
        guard sort.field == .name, LibraryLetterIndex.railLetters.contains(letter),
              [.movie, .series, .video].contains(kind) else { throw AppError.invalidResponse }
        let scope = [URLQueryItem(name: "library_id", value: containerID),
                     URLQueryItem(name: "type", value: kind.rawValue)]
        var targetID: String?
        if letter != "#" {
            // Silo's prefix predicate matches both display title and sort title.
            // Check the full sort title so "The Alien" does not masquerade as T.
            var offset = 0
            while targetID == nil {
                try Task.checkCancellation()
                let candidates = try await catalogPage(scope + [.init(name: "name_prefix", value: letter)],
                                                      page: .init(startIndex: offset, limit: 50, sort: sort),
                                                      libraryID: containerID)
                for candidate in candidates.items {
                    try Task.checkCancellation()
                    if try await alphabetBucket(itemID: candidate.id) == letter {
                        targetID = candidate.id
                        break
                    }
                }
                guard targetID == nil else { break }
                offset += candidates.items.count
                if offset >= candidates.totalCount { return nil }
                guard !candidates.items.isEmpty else { throw AppError.invalidResponse }
            }
        }
        let target = targetID
        let position = try await LibraryLetterIndex.findPosition(
            fetch: { [self] offset, limit in
                try await catalogPage(scope, page: .init(startIndex: offset, limit: limit, sort: sort),
                                      libraryID: containerID)
            },
            matches: { [self] item in
                if let target { return item.id == target }
                return try await alphabetBucket(itemID: item.id) == "#"
            }
        )
        if target != nil, position == nil { throw AppError.conflict }
        return position
    }

    private func alphabetBucket(itemID: String) async throws -> String {
        let detail: SiloItem = try await client.request("/catalog/items/\(try SiloAPI.pathComponent(itemID))")
        guard detail.content_id == itemID else { throw AppError.invalidResponse }
        let sortTitle = detail.sort_title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = sortTitle.flatMap { $0.isEmpty ? nil : $0 } ?? detail.title
        return LibraryLetterIndex.bucket(forPrefix: name)
    }
}
