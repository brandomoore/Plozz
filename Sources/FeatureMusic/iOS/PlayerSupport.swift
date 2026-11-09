#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI
import UIKit

private struct PlayerBackgroundKey: EnvironmentKey {
    static let defaultValue = PlayerBackgroundStyle.adaptive
}
private struct PlayerBlackoutKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var musicPlayerBackground: PlayerBackgroundStyle {
        get { self[PlayerBackgroundKey.self] }
        set { self[PlayerBackgroundKey.self] = newValue }
    }
    var musicPlayerBlackout: Bool {
        get { self[PlayerBlackoutKey.self] }
        set { self[PlayerBlackoutKey.self] = newValue }
    }
}

extension Color {
    static var musicPlayerAccent: Color { Color("MusicPlayerAccent", bundle: .module) }
    static var mozzBackground: Color { Color(uiColor: .systemBackground) }
    static var mozzChrome: Color { Color(uiColor: .secondarySystemBackground) }
    static var mozzArtworkPlaceholder: Color { Color(uiColor: .tertiarySystemFill) }
    static var mozzHairline: Color { Color(uiColor: .separator) }
}

extension View {
    func glassBackground<S: Shape>(_ shape: S) -> some View {
        modifier(PlayerGlassBackground(shape: shape))
    }
}

private struct PlayerGlassBackground<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color.mozzChrome, in: shape)
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

// Mozz's dock geometry is retained; the host supplies the navigation arrangement.
enum BottomBar {
    static let edgeMargin: CGFloat = 22
    static let hMargin: CGFloat = 22
    static let tabHeight: CGFloat = 63
    static let islandHeight: CGFloat = 56
    static let islandGap: CGFloat = 8
    static let minElementH: CGFloat = 48
    static let dockMaxWidth: CGFloat = 640
    static func barCenterY(inHeight height: CGFloat) -> CGFloat { height - edgeMargin - tabHeight / 2 }
    static func centerGap(inWidth width: CGFloat) -> (centerX: CGFloat, width: CGFloat) {
        (width / 2, max(width - 2 * (28 + 48 + 13), 90))
    }
}

enum LikeControl {
    static func format(_ rating: Double) -> String {
        rating == rating.rounded() ? String(Int(rating)) : String(format: "%.1f", rating)
    }
}

struct ArtworkImageLoader: Sendable {
    static let shared = ArtworkImageLoader()
    func cached(_ url: URL) -> UIImage? { ArtworkImageCache.shared.cachedImage(for: url) }
    func image(for url: URL) async -> UIImage? { await ArtworkImageCache.shared.image(for: url) }
    func prefetch(_ url: URL) {
        ArtworkImageCache.shared.prefetch(url)
    }
}

struct CachedArtworkImage<Placeholder: View>: View {
    let url: URL
    let retainWhileLoading: Bool
    let placeholder: Placeholder
    @State private var image: UIImage?

    init(url: URL, retainWhileLoading: Bool = false, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.retainWhileLoading = retainWhileLoading
        self.placeholder = placeholder()
        _image = State(initialValue: ArtworkImageLoader.shared.cached(url))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            if let cached = ArtworkImageLoader.shared.cached(url) {
                image = cached
                return
            }
            if !retainWhileLoading { image = nil }
            let loaded = await ArtworkImageLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

struct TrackActionButtons: View {
    let track: Track
    @EnvironmentObject private var env: MusicPlayerEnvironment
    var body: some View {
        TrackNavigationButtons(track: track, surface: .player, showsSubtitles: true)
        Button("Clear Up Next", systemImage: "text.badge.minus") { env.playback.clearUpNext() }
            .disabled(env.playback.upNext.isEmpty)
        Button("Stop Playing", systemImage: "stop.fill") { env.playback.controller.stop() }
    }
}

struct TrackNavigationButtons: View {
    @EnvironmentObject private var env: MusicPlayerEnvironment
    enum Surface { case player }
    let track: Track
    let surface: Surface
    let showsSubtitles: Bool
    static func canNavigate(_ track: Track, surface: Surface) -> Bool {
        track.source.sourceAccountID != nil && (track.source.albumID != nil || track.source.artistID != nil)
    }
    var body: some View {
        if let id = track.source.albumID {
            Button {
                env.navigate(to: .album(MusicAlbum(
                    id: id, title: track.albumTitle ?? track.title,
                    artistName: track.artistName, artistID: track.source.artistID,
                    artworkURL: track.source.artworkURL,
                    sourceAccountID: track.source.sourceAccountID
                )), track: track)
            } label: {
                Label("Go to Album", systemImage: "square.stack")
                if showsSubtitles, let title = track.albumTitle { Text(title) }
            }
        }
        if let id = track.source.artistID {
            Button {
                env.navigate(to: .artist(MusicArtist(
                    id: id, name: track.artistName, sourceAccountID: track.source.sourceAccountID
                )), track: track)
            } label: {
                Label("Go to Artist", systemImage: "music.mic")
                if showsSubtitles { Text(track.artistName) }
            }
        }
    }
}
#endif
