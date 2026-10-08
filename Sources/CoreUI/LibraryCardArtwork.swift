#if canImport(UIKit) && canImport(SwiftUI)
import CoreModels
import SwiftUI
import UIKit

public struct LibraryCardArtwork: View {
    private let library: AggregatedLibrary
    private let source: LibraryArtworkSource?
    @Environment(\.plozzArtworkPolicy) private var artworkPolicy

    public init(library: AggregatedLibrary, source: LibraryArtworkSource? = nil) {
        self.library = library
        self.source = source
    }

    public var body: some View {
        Group {
            if let url = library.library.imageURL {
                FallbackAsyncImage(
                    urls: [url], variant: .landscapeCard, pinIdentity: library.key
                ) {
                    LibraryArtworkFallback(provider: library.providerKind)
                }
            } else {
                LibraryCollageArtwork(source: source, provider: library.providerKind, policy: artworkPolicy)
                    .id((source?.cacheIdentity ?? library.key) + "|" + artworkPolicy.identity)
            }
        }
    }
}

private struct LibraryCollageArtwork: View {
    let source: LibraryArtworkSource?
    let provider: ProviderKind
    let policy: ArtworkPresentationPolicy
    @State private var image: UIImage?
    @State private var resolved: Bool
    #if os(tvOS)
    @Environment(\.artworkResolutionState) private var resolution
    #endif

    init(source: LibraryArtworkSource?, provider: ProviderKind, policy: ArtworkPresentationPolicy) {
        self.source = source
        self.provider = provider
        self.policy = policy
        let cached = source.flatMap { LibraryCollageCache.shared.cachedImage(for: $0, policy: policy) }
        _image = State(initialValue: cached)
        _resolved = State(initialValue: cached != nil)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LibraryArtworkFallback(provider: provider)
            }
        }
        #if os(tvOS)
        .onChange(of: image, initial: true) { _, value in
            resolution?.image = value
        }
        .onChange(of: resolved, initial: true) { _, value in
            resolution?.isResolved = value
        }
        #endif
        .task(id: source.map { LibraryCollageCache.identity(for: $0, policy: policy) }) {
            guard image == nil, let source else { return }
            let loaded = await LibraryCollageCache.shared.image(for: source, policy: policy)
            guard !Task.isCancelled else { return }
            image = loaded
            resolved = true
        }
    }
}

public struct LibraryArtworkFallback: View {
    let provider: ProviderKind

    public init(provider: ProviderKind) {
        self.provider = provider
    }

    public var body: some View {
        LinearGradient(
            colors: [ProviderBrandMark.brandTint(provider).opacity(0.55), Color(white: 0.07)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

#endif
