#if canImport(UIKit) && canImport(SwiftUI)
import CoreModels
import SwiftUI
import UIKit

public struct LibraryCardArtwork: View {
    private let library: AggregatedLibrary
    private let source: LibraryArtworkSource?

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
                LibraryCollageArtwork(source: source, provider: library.providerKind)
                    .id(source?.cacheIdentity ?? library.key)
            }
        }
    }
}

private struct LibraryCollageArtwork: View {
    let source: LibraryArtworkSource?
    let provider: ProviderKind
    @State private var image: UIImage?
    #if os(tvOS)
    @Environment(\.artworkResolutionState) private var resolution
    #endif

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LibraryArtworkFallback(provider: provider)
            }
        }
        .task(id: source?.cacheIdentity) {
            #if os(tvOS)
            resolution?.image = image
            resolution?.isResolved = image != nil
            #endif
            guard let source else { return }
            let resolved = await LibraryCollageCache.shared.image(for: source)
            guard !Task.isCancelled else { return }
            image = resolved
            #if os(tvOS)
            resolution?.image = resolved
            resolution?.isResolved = true
            #endif
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

/// Kept separate from the bitmap so native posters use their own focus surface.
public struct LibraryArtworkOverlay: View {
    private let library: AggregatedLibrary

    public init(library: AggregatedLibrary) {
        self.library = library
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                if library.library.imageURL == nil {
                    library.library.displayName
                        .font(.system(size: geometry.size.width * 0.095, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.65)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                        .padding(geometry.size.width * 0.075)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                ProviderBrandMark(
                    provider: library.providerKind,
                    size: geometry.size.width * 0.135,
                    showsBackground: false,
                    mediaShareTransport: library.transportKind
                )
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
                .padding(geometry.size.width * 0.04)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
