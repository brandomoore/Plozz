import TVServices

/// Supplies content for the tvOS Top Shelf — the banner shown above the app
/// grid when Plozz is in the top row of the Home screen.
///
/// Runs as the current Apple TV user and reads the snapshot Plozz Home last
/// published for that user. The extension doesn't select a profile or sign in
/// to a media provider.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(
        completionHandler: @escaping (TVTopShelfContent?) -> Void
    ) {
        completionHandler(Self.makeContent())
    }

    private static func makeContent() -> TVTopShelfContent? {
        guard let snapshot = TopShelfStore.load() else { return nil }
        return TopShelfContentBuilder.makeContent(from: snapshot)
    }
}
