import CoreModels
import CoreUI
import SwiftUI
import UIKit

struct PosterCaptionFixture: View {
    @State private var artwork: URL?
    @State private var revision = 0
    private let usesLongTitle = ProcessInfo.processInfo.arguments.contains("--poster-caption-long-title")

    private func title(at index: Int) -> String {
        if usesLongTitle, index == 1 {
            return "A long poster title with enough words to scroll across the artwork"
        }
        return revision == 0 ? "Poster \(index)" : "Poster \(index) v\(revision)"
    }

    var body: some View {
        VStack(spacing: 28) {
            if let artwork {
                Text("Poster captions ready").accessibilityIdentifier("poster-captions-ready")
                ForEach(0..<2) { row in
                    HStack(alignment: .top, spacing: 28) {
                        ForEach(0..<4) { column in
                            let index = row * 4 + column
                            PosterCardView(
                                item: MediaItem(
                                    id: "poster-\(index)",
                                    title: title(at: index),
                                    kind: .movie,
                                    productionYear: 2000 + index, posterURL: artwork, backdropURL: artwork,
                                    allowsTitleBasedMetadataMatching: false
                                ),
                                enablesAsyncArtworkFallback: false, action: {}
                            )
                            .frame(width: 200)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.plozzCardStyle, .borderless)
        .onPlayPauseCommand { revision += 1 }
        .task {
            guard artwork == nil else { return }
            let url = URL(string: "https://poster-caption.example.test/art.png")!
            let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 240)).image {
                UIColor(red: 0.08, green: 0.12, blue: 0.22, alpha: 1).setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 160, height: 240))
            }
            guard let bytes = image.pngData(), let cache = ArtworkSession.shared.configuration.urlCache else {
                preconditionFailure("The caption fixture requires a local artwork cache.")
            }
            for variant in ArtworkImageVariant.allCases {
                let target = variant.requestURL(for: url)
                let response = HTTPURLResponse(
                    url: target, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"]
                )!
                cache.storeCachedResponse(CachedURLResponse(response: response, data: bytes), for: URLRequest(url: target))
            }
            artwork = url
        }
    }
}
