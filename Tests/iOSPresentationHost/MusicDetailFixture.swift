import CoreModels
import CoreUI
@testable import FeatureMusic
import SwiftUI
import UIKit

struct MusicDetailFixture: View {
    @State private var selectedTrack: MusicTrack?
    @State private var selection: MusicAlbum?
    @State private var path = ["detail"]
    private let artwork = Self.seedArtwork()
    private var arguments: [String] { ProcessInfo.processInfo.arguments }
    private var album: MusicAlbum {
        MusicAlbum(
            id: "evening", title: "Evening Light", artistName: "The Night Signals",
            year: 2026, artworkURL: arguments.contains("--music-no-art") ? nil : artwork,
            trackCount: 8, totalDuration: 2_184, sourceAccountID: "fixture"
        )
    }
    private var tracks: [MusicTrack] {
        ["A New Beginning", "Coastlines", "After the Rain", "Slow Motion", "Midnight Drive",
         "City Lights", "Another Day", "The Long Way Home"].enumerated().map { index, title in
            MusicTrack(id: "\(index)", title: title, trackNumber: index + 1,
                       duration: 230 + Double(index * 17), sourceAccountID: "fixture")
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Text("Music").navigationTitle("Music")
                .navigationDestination(for: String.self) { _ in
                    Group {
                        if arguments.contains("--music-artist") {
                            MobileMusicArtistDetail(
                                artist: MusicArtist(id: "artist", name: "The Night Signals",
                                                    artworkURL: album.artworkURL, genres: ["Alternative"],
                                                    sourceAccountID: "fixture"),
                                albums: [album, MusicAlbum(id: "second", title: "Blue Hour", year: 2024,
                                                           artworkURL: album.artworkURL, sourceAccountID: "fixture")],
                                onSelectAlbum: { selection = $0 }
                            )
                        } else {
                            albumPage(album)
                        }
                    }
                    .navigationDestination(item: $selection) { albumPage($0) }
                }
        }
        .environment(\.themePalette, arguments.contains("--music-oled") ? .pureBlack :
                        arguments.contains("--music-light") ? .light : .dark)
        .environment(\.dynamicTypeSize, arguments.contains("--music-large-text") ? .accessibility3 : .large)
        .tint(.blue)
    }

    private func albumPage(_ album: MusicAlbum) -> some View {
        MobileMusicAlbumDetail(
            album: album, tracks: tracks, nowPlayingTrack: selectedTrack, isPlaying: false,
            onPlay: { selectedTrack = tracks.first },
            onShuffle: { selectedTrack = tracks.last },
            onPlayTrack: { selectedTrack = $0 }
        )
    }

    private static func seedArtwork() -> URL {
        let url = URL(string: "https://music-detail.invalid/fixture-cover.png")!
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600)).image { context in
            UIColor(red: 0.13, green: 0.32, blue: 0.35, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            UIColor(red: 0.93, green: 0.65, blue: 0.35, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 140, y: 100, width: 320, height: 320))
            UIColor(red: 0.07, green: 0.17, blue: 0.21, alpha: 1).setFill()
            for index in 0..<7 {
                context.fill(CGRect(x: 0, y: 350 + index * 36, width: 600, height: 16))
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"])!
        ArtworkSession.shared.configuration.urlCache?.storeCachedResponse(
            CachedURLResponse(response: response, data: image.pngData()!), for: URLRequest(url: url)
        )
        return url
    }
}
