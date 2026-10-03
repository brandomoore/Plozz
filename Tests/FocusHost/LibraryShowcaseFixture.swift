import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI
import UIKit
@testable import FeatureHome

struct LibraryShowcaseFixture: View {
    @State private var provider: LibraryShowcaseProvider?

    var body: some View {
        NavigationStack {
            if let provider {
                if ProcessInfo.processInfo.arguments.contains("--library-showcase-home-comparison") {
                    homeComparison(provider)
                } else {
                    LibraryBrowseView(
                        viewModel: LibraryBrowseViewModel(
                            provider: provider, containerID: "library", containerKind: .movie,
                            sourceAccountID: "fixture"
                        ),
                        title: Text("Showcase library"), onSelect: { _ in }
                    )
                }
            } else {
                ProgressView("Preparing fixture")
            }
        }
        .environment(\.plozzNavigationStyle, .rail)
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.plozzCardStyle, .borderless)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .task {
            guard provider == nil else { return }
            let logo = URL(string: "https://library-showcase.example.test/\(UUID()).png")!
            let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 100)).image {
                UIColor.red.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 320, height: 100))
            }
            let response = HTTPURLResponse(
                url: logo, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            )!
            guard let cache = ArtworkSession.shared.configuration.urlCache, let data = image.pngData() else {
                preconditionFailure("Showcase fixture requires its isolated artwork cache")
            }
            cache.storeCachedResponse(
                CachedURLResponse(response: response, data: data), for: URLRequest(url: logo)
            )
            provider = LibraryShowcaseProvider(logo: logo)
        }
    }

    private func homeComparison(_ provider: LibraryShowcaseProvider) -> some View {
        let items = provider.resumeItems
        let row = FocusHeroRow(
            id: "continueWatching", itemIDs: items.map(\.stablePresentationID),
            leadItem: items.first, items: items
        )
        return FocusHeroHomeView(
            rows: [row], settings: .default, spoilerSettings: .default,
            navigationStyle: .rail, isFrontmost: true
        ) { _, reporter in
            MediaRowView(
                title: Text("Continue Watching"), items: items, style: .landscape,
                onFocusEntered: reporter.entered,
                onFocusChange: { if let item = $0 { reporter.focusedItem(item) } },
                onCardFocused: reporter.cardFocused,
                playsOnSelect: true, onSelect: { _ in }
            )
        }
    }
}

private struct LibraryShowcaseProvider: MediaProvider, CapabilityReporting {
    let logo: URL
    let kind: ProviderKind = .jellyfin
    let capabilities: ProviderCapability = [.libraryCollections, .videoPlaylists]
    let session = UserSession(
        server: MediaServer(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.test")!,
                            provider: .jellyfin),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
    )

    var resumeItems: [MediaItem] {
        (0..<3).map { index in
            var item = MediaItem(
                id: "resume-\(index)", title: "Showcase movie \(index)", kind: .movie, logoURL: logo
            )
            item.libraryID = "library"
            item.sourceAccountID = "fixture"
            item.officialRating = "PG-13"
            item.genres = ["Action", "Adventure"]
            item.taglines = ["A short description beneath the metadata."]
            item.resumePosition = 120
            item.runtime = 7200
            return item
        }
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { resumeItems }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        guard let item = resumeItems.first(where: { $0.id == id }) else { throw AppError.notFound }
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
