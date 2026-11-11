import CoreModels
import CoreUI
@testable import FeatureMusic
import SwiftUI
import UIKit

struct MusicLandingFixture: View {
    @State private var controller = AudioPlaybackController()
    @State private var path: [MusicRoute] = []
    let palette: ThemePalette
    let textSize: DynamicTypeSize

    var body: some View {
        TabView {
            NavigationStack(path: $path) {
                MusicLandingContent(
                    content: Self.content, controller: controller,
                    onSelectRoute: { path.append($0) }, onPlayTrack: { _ in }
                )
                .background(palette.backgroundBase)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward") {}
                            .labelStyle(.iconOnly)
                    }
                }
                .navigationDestination(for: MusicRoute.self) { route in
                    switch route {
                    case let .grid(kind):
                        MusicPageHeader(title: kind == .playlist ? "Playlists" :
                                            kind == .album ? "Albums" :
                                            kind == .artist ? "Artists" : "Genres", controller: controller)
                    case let .album(album):
                        MobileMusicAlbumDetail(
                            album: album, tracks: [], nowPlayingTrack: nil, isPlaying: false,
                            onPlay: {}, onShuffle: {}, onPlayTrack: { _ in }
                        )
                    default:
                        Text("Music")
                    }
                }
            }
            .tabItem { Label("Music", systemImage: "music.note") }
            Text("Library").tabItem { Label("Library", systemImage: "square.stack") }
        }
        .environment(\.themePalette, palette)
        .environment(\.dynamicTypeSize, textSize)
        .preferredColorScheme(palette == .light ? .light : .dark)
        .tint(palette.primaryText)
    }

    static let content: MusicLandingViewModel.Content = {
        let names = ["Evening Light", "Blue Hour", "Coastlines", "After the Rain", "City Lights", "Another Day"]
        let colors: [UIColor] = [.systemTeal, .systemIndigo, .systemOrange, .systemPurple, .systemPink, .systemBlue]
        let albums = names.enumerated().map { index, name in
            let url = URL(string: "https://music-landing.invalid/cover-\(index).png")!
            let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).image { context in
                colors[index].setFill()
                context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
                UIColor.white.withAlphaComponent(0.65).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 65, y: 40, width: 170, height: 170))
                UIColor.black.withAlphaComponent(0.45).setFill()
                for line in 0..<4 {
                    context.fill(CGRect(x: 0, y: 180 + line * 30, width: 300, height: 12))
                }
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            )!
            ArtworkSession.shared.configuration.urlCache?.storeCachedResponse(
                CachedURLResponse(response: response, data: image.pngData()!), for: URLRequest(url: url)
            )
            return MusicAlbum(id: "\(index)", title: name, artistName: "The Night Signals",
                              year: 2026, artworkURL: url, sourceAccountID: "fixture")
        }
        return MusicLandingViewModel.Content(
            recentlyPlayed: albums.map { .album($0) }, albums: albums,
            playlists: zip(["Favorites", "Late Nights", "Morning Mix", "On Repeat"], albums).enumerated().map {
                MusicPlaylist(id: "\($0.offset)", title: $0.element.0, artworkURL: $0.element.1.artworkURL,
                              trackCount: 48, sourceAccountID: "fixture")
            }
        )
    }()
}
