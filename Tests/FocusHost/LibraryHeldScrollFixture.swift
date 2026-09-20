import CoreModels
import CoreUI
import FeatureHome
import FeatureHomeCore
import Observation
import SwiftUI
import UIKit

struct LibraryHeldScrollFixture: View {
    @State private var model: LibraryBrowseViewModel?
    @State private var metrics = LibraryScrollMetrics()
    @State private var selection = ""

    var body: some View {
        NavigationStack {
            if let model {
                LibraryBrowseView(
                    viewModel: model, title: Text("Library hold fixture"),
                    onSelect: { selection = $0.title }
                )
                .overlay(alignment: .bottomLeading) {
                    LibraryScrollStatus(model: model, metrics: metrics, selection: selection)
                }
                .background { LibraryScrollObserver(metrics: metrics) }
            } else {
                ProgressView("Preparing fixture")
            }
        }
        .environment(\.plozzCardFocusStyle, .system)
        .environment(
            \.plozzCardStyle,
            ProcessInfo.processInfo.arguments.contains("--borderless") ? .borderless : .framed
        )
        .environment(\.plozzMetrics, .standard)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .task {
            guard model == nil else { return }
            var settings = MetadataProviderSettingsStore().load()
            settings.preferOnlineArtwork = false
            MetadataProviderSettingsStore().save(settings)
            let artwork = URL(string: "https://library-held-fixture.example.test/poster.png")!
            let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image {
                UIColor.systemBlue.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            }
            guard let data = image.pngData(),
                  let cache = ArtworkSession.shared.configuration.urlCache else {
                preconditionFailure("Library fixture requires its isolated image cache")
            }
            for variant in [ArtworkImageVariant.posterCard, .posterPreview] {
                let url = variant.requestURL(for: artwork)
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
                )!
                cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: URLRequest(url: url))
                guard await ArtworkImageCache.shared.image(for: artwork, variant: variant) != nil else {
                    preconditionFailure("Library fixture image failed to decode")
                }
            }
            model = LibraryBrowseViewModel(
                provider: LibraryHeldScrollProvider(
                    artwork: artwork,
                    delayed: ProcessInfo.processInfo.arguments.contains("--delayed-library-page")
                ),
                containerID: "library", containerKind: .movie,
                pageSize: ProcessInfo.processInfo.arguments.contains("--all-library-items")
                    ? 500 : PageRequest.defaultLimit,
                sourceAccountID: "fixture"
            )
        }
    }
}

@MainActor
@Observable
private final class LibraryScrollMetrics {
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
}

private struct LibraryScrollStatus: View {
    let model: LibraryBrowseViewModel
    let metrics: LibraryScrollMetrics
    let selection: String

    var body: some View {
        VStack {
            Text("loaded=\(model.loadedCount) total=\(model.totalCount)")
                .accessibilityIdentifier("library-hold-status")
            Text(verbatim: "\(Int(metrics.offset))|\(Int(metrics.viewport))")
                .accessibilityIdentifier("library-scroll-position")
            Text(selection).accessibilityIdentifier("library-hold-selection")
        }
        .font(.caption2)
        .allowsHitTesting(false)
    }
}

private struct LibraryScrollObserver: UIViewRepresentable {
    let metrics: LibraryScrollMetrics
    func makeUIView(context: Context) -> Observer { Observer(metrics: metrics) }
    func updateUIView(_ view: Observer, context: Context) {}

    final class Observer: UIView {
        let metrics: LibraryScrollMetrics
        private var displayLink: CADisplayLink?
        private weak var scroll: UIScrollView?

        init(metrics: LibraryScrollMetrics) {
            self.metrics = metrics
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            displayLink?.invalidate()
            displayLink = nil
            scroll = nil
            guard window != nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(sample))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 10, preferred: 10)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func sample() {
            guard let window else { return }
            if scroll?.window !== window { scroll = findScroll(in: window) }
            guard let scroll else { return }
            if abs(metrics.offset - scroll.contentOffset.y) > 0.5 { metrics.offset = scroll.contentOffset.y }
            if metrics.viewport != scroll.bounds.height { metrics.viewport = scroll.bounds.height }
        }

        private func findScroll(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView,
               scroll.bounds.width > 800,
               scroll.contentSize.height > scroll.bounds.height * 2 {
                return scroll
            }
            return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
        }
    }
}

private struct LibraryHeldScrollProvider: MediaProvider {
    let artwork: URL
    let delayed: Bool
    let kind: ProviderKind = .plex
    let session = UserSession(
        server: MediaServer(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.test")!, provider: .plex),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
    )

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        if delayed && page.startIndex > 0 {
            try await Task.sleep(for: .seconds(20))
        }
        let end = min(500, page.startIndex + page.limit)
        let items = (min(page.startIndex, end)..<end).map { index in
            MediaItem(
                id: "held-\(index)", title: String(format: "%@: Library item %03d", index < 250 ? "A" : "M", index),
                kind: .movie, posterURL: artwork, sourceAccountID: "fixture"
            )
        }
        return MediaPage(items: items, startIndex: page.startIndex, totalCount: 500)
    }

    func letterIndex(in containerID: String, kind: MediaItemKind, sort: CoreModels.SortDescriptor) async throws -> [LibraryLetterIndexEntry] {
        [LibraryLetterIndexEntry(letter: "A", startIndex: 0), LibraryLetterIndexEntry(letter: "M", startIndex: 250)]
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
