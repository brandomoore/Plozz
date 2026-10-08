import CoreModels
import CoreUI
import XCTest
@testable import FeatureMusic

@MainActor
final class MusicPlaylistArtworkTests: XCTestCase {
    func testTrackThumbnailOffersOnlineFallbackEvenWhenLibraryArtworkExists() {
        let cover = URL(string: "https://library.example.test/track.jpg")!
        let track = MusicTrack(
            id: "track", title: "Song", albumTitle: "Album", artistName: "Artist",
            artworkURL: cover
        )
        let row = TrackListView(tracks: [track], showArtwork: true, onPlayTrack: { _ in })
        let artwork = row.trackArtwork(for: track)

        XCTAssertEqual(artwork.url, cover)
        XCTAssertNotNil(artwork.asyncFallbackURL)
        XCTAssertEqual(artwork.variant, .musicThumbnail)
        XCTAssertEqual(artwork.pinIdentity, track.id)
    }

    func testTrackThumbnailKeepsPlaylistCoverAndOnlineLookupWhenTrackHasNoCover() {
        let cover = URL(string: "https://library.example.test/playlist.jpg")!
        let track = MusicTrack(id: "track", title: "Song", artistName: "Artist")
        let row = TrackListView(
            tracks: [track], artworkFallback: cover, showArtwork: true, onPlayTrack: { _ in }
        )
        let artwork = row.trackArtwork(for: track)

        XCTAssertEqual(artwork.url, cover)
        XCTAssertNotNil(artwork.asyncFallbackURL)
    }

    func testTrackThumbnailCanLookUpArtworkWithoutAnyLibraryCover() {
        let track = MusicTrack(id: "track", title: "Song")
        let row = TrackListView(tracks: [track], showArtwork: true, onPlayTrack: { _ in })
        let artwork = row.trackArtwork(for: track)

        XCTAssertNil(artwork.url)
        XCTAssertNotNil(artwork.asyncFallbackURL)
    }

    func testTrackThumbnailDoesNotSearchAnEmptyTitleAndAlbum() {
        let track = MusicTrack(id: "track", title: " ", albumTitle: " ")
        let row = TrackListView(tracks: [track], showArtwork: true, onPlayTrack: { _ in })

        XCTAssertNil(row.trackArtwork(for: track).asyncFallbackURL)
    }
}
