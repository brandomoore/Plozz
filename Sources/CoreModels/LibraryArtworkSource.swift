import Foundation

/// A library-scoped, bounded source for a missing library cover.
public struct LibraryArtworkSource: Sendable {
    public let accountID: String
    public let credentialRevision: String
    public let cacheIdentity: String
    private let library: MediaLibrary
    private let provider: any MediaProvider

    public init(library: AggregatedLibrary, account: ResolvedAccount, scope: String) {
        self.library = library.library
        self.provider = account.provider
        self.accountID = account.account.id
        self.credentialRevision = account.account.credentialRevision.rawValue.uuidString
        self.cacheIdentity = [
            "library-collage-v1", scope, account.account.id,
            credentialRevision, account.provider.session.userID,
            account.provider.kind.rawValue, library.library.id
        ].map { "\($0.utf8.count):\($0)" }.joined()
    }

    public func candidates() async throws -> [[ArtworkReference]] {
        guard library.imageURL == nil else { return [] }
        try Task.checkCancellation()
        let items: [MediaItem]
        if let files = provider as? any MediaFileBrowsing,
           library.id == files.fileBrowserLibrary.id {
            // The raw root contains folders, not posters. Use this same
            // provider's indexed media without recursively browsing the share.
            items = try await provider.latest(limit: 18)
        } else {
            items = try await provider.items(
                in: library.id,
                kind: library.kind,
                page: PageRequest(limit: 18, sort: .init(field: .name, direction: .ascending))
            ).items
        }
        try Task.checkCancellation()
        return Self.selectCandidates(from: items)
    }

    static func selectCandidates(from items: [MediaItem]) -> [[ArtworkReference]] {
        var seen = Set<ArtworkReference>()
        var result: [[ArtworkReference]] = []
        for item in items {
            let references = Array(item.artworkReferences(for: .poster).prefix(2))
            guard let first = references.first, seen.insert(first).inserted else { continue }
            result.append(references)
            if result.count == 6 { break }
        }
        return result
    }
}
