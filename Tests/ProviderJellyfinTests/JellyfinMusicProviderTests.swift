import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin

final class JellyfinMusicProviderTests: XCTestCase {
    private func makeSession(provider: ProviderKind = .jellyfin) -> UserSession {
        UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: provider),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testMusicLibrariesFilterCollectionType() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Views", json: """
        {"Items":[
          {"Id":"v1","Name":"Movies","Type":"CollectionFolder","CollectionType":"movies"},
          {"Id":"v2","Name":"Tunes","Type":"CollectionFolder","CollectionType":"music"}
        ],"TotalRecordCount":2}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let libraries = try await provider.musicLibraries()
        XCTAssertEqual(libraries.count, 1)
        XCTAssertEqual(libraries[0].id, "v2")
        XCTAssertEqual(libraries[0].title, "Tunes")
    }

    func testAlbumBrowseMapsFields() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[{"Id":"al1","Name":"Greatest Hits","Type":"MusicAlbum",
          "AlbumArtist":"The Band","ProductionYear":1999,"ChildCount":12,
          "RunTimeTicks":36000000000,"Genres":["Rock"]}],"TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let page = try await provider.musicItems(in: "", kind: .album, page: PageRequest(startIndex: 0, limit: 50))
        XCTAssertEqual(page.totalCount, 1)
        let album = try XCTUnwrap(page.albums.first)
        XCTAssertEqual(album.id, "al1")
        XCTAssertEqual(album.title, "Greatest Hits")
        XCTAssertEqual(album.artistName, "The Band")
        XCTAssertEqual(album.year, 1999)
        XCTAssertEqual(album.trackCount, 12)
        XCTAssertEqual(album.totalDuration ?? 0, 3600, accuracy: 0.001)
        XCTAssertEqual(album.genres, ["Rock"])
    }

    func testArtistBrowseMapsFields() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Artists", json: """
        {"Items":[{"Id":"ar1","Name":"The Band","Type":"MusicArtist",
          "ChildCount":4,"Genres":["Rock","Folk"]}],"TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let page = try await provider.musicItems(in: "", kind: .artist, page: PageRequest(startIndex: 0, limit: 50))
        let artist = try XCTUnwrap(page.artists.first)
        XCTAssertEqual(artist.id, "ar1")
        XCTAssertEqual(artist.name, "The Band")
        XCTAssertEqual(artist.albumCount, 4)
        XCTAssertEqual(artist.genres, ["Rock", "Folk"])
    }

    func testTrackMappingFromAlbumChildren() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/al1", json: #"{"Id":"al1","Type":"MusicAlbum"}"#)
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[{"Id":"t1","Name":"Opening","Type":"Audio","Album":"Greatest Hits",
          "AlbumId":"al1","Artists":["The Band"],"IndexNumber":1,"ParentIndexNumber":1,
          "RunTimeTicks":1870000000}],"TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let tracks = try await provider.tracks(in: "al1")
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.id, "t1")
        XCTAssertEqual(track.title, "Opening")
        XCTAssertEqual(track.albumTitle, "Greatest Hits")
        XCTAssertEqual(track.albumID, "al1")
        XCTAssertEqual(track.artistName, "The Band")
        XCTAssertEqual(track.trackNumber, 1)
        XCTAssertEqual(track.discNumber, 1)
        XCTAssertEqual(track.duration ?? 0, 187, accuracy: 0.001)
    }

    func testArtistAlbumsUsePerformingArtistRelationForCompilations() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Artists", json: #"{"Items":[{"Id":"singer","Name":"Singer","Type":"MusicArtist"}],"TotalRecordCount":1}"#)
            stub.stub(pathSuffix: "/Users/u1/Items",
                      requiring: [URLQueryItem(name: "ArtistIds", value: "singer")],
                      json: #"{"Items":[{"Id":"compilation","Name":"Compilation","AlbumArtist":"Various Artists","Type":"MusicAlbum"}],"TotalRecordCount":1}"#)
            let provider = JellyfinProvider(session: makeSession(provider: kind), http: stub)
            let artists = try await provider.musicItems(in: "", kind: .artist, page: PageRequest())
            let artist = try XCTUnwrap(artists.artists.first)
            let albums = try await provider.musicItems(in: artist.id, kind: .album, page: PageRequest())
            XCTAssertEqual(albums.albums.first?.id, "compilation")
            XCTAssertEqual(albums.albums.first?.artistName, "Various Artists")
            let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/u1/Items"))
            XCTAssertFalse(query.contains { $0.name == "AlbumArtistIds" || $0.name == "ParentId" })
        }
    }

    func testPlaylistPaginatesInAuthoredOrderIncludingRepeatedTracks() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Users/u1/Items/list", json: #"{"Id":"list","Type":"Playlist"}"#)
            let firstIDs = (0..<500).map { "track-\(499 - $0)" }
            let lastIDs = ["track-499", "track-0", "last"]
            for (start, ids) in [(0, firstIDs), (500, lastIDs)] {
                let entries = ids.map { #"{"Id":"\#($0)","Name":"Song","Type":"Audio"}"# }.joined(separator: ",")
                stub.stub(pathSuffix: "/Playlists/list/Items",
                          requiring: [URLQueryItem(name: "StartIndex", value: "\(start)"),
                                      URLQueryItem(name: "Limit", value: "500")],
                          json: #"{"Items":[\#(entries)],"TotalRecordCount":503}"#)
            }
            let provider = JellyfinProvider(session: makeSession(provider: kind), http: stub)
            let tracks = try await provider.tracks(in: "list")
            XCTAssertEqual(tracks.map(\.id), firstIDs + lastIDs)
            XCTAssertFalse(stub.sentPaths.contains("/Users/u1/Items"))
            XCTAssertFalse(stub.sentQueryItems.flatMap { $0 }.contains { $0.name == "SortBy" })
            XCTAssertEqual(stub.sentPaths.count, 3)
        }
    }

    func testEmptyAlbumDoesNotFallBackToPlaylist() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/empty", json: #"{"Id":"empty","Type":"MusicAlbum"}"#)
        stub.stub(pathSuffix: "/Users/u1/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)
        let tracks = try await provider.tracks(in: "empty")
        XCTAssertTrue(tracks.isEmpty)
        XCTAssertEqual(stub.sentPaths, ["/Users/u1/Items/empty", "/Users/u1/Items"])
    }

    func testPlaylistPageFailureDoesNotReturnPartialSuccess() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/list", json: #"{"Id":"list","Type":"Playlist"}"#)
        stub.stub(pathSuffix: "/Playlists/list/Items",
                  requiring: [URLQueryItem(name: "StartIndex", value: "0")],
                  json: #"{"Items":[{"Id":"first","Type":"Audio"}],"TotalRecordCount":2}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)
        do {
            _ = try await provider.tracks(in: "list")
            XCTFail("The missing second page must fail the load")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }

    func testTruncatedPlaylistDoesNotReturnPartialSuccess() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/list", json: #"{"Id":"list","Type":"Playlist"}"#)
        stub.stubSequence(pathSuffix: "/Playlists/list/Items", jsons: [
            #"{"Items":[{"Id":"first","Type":"Audio"}],"TotalRecordCount":2}"#,
            #"{"Items":[]}"#
        ])
        let provider = JellyfinProvider(session: makeSession(), http: stub)
        do {
            _ = try await provider.tracks(in: "list")
            XCTFail("Premature empty pages must fail the load")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
    }

    func testUniversalAudioConstrainsCodecsAndPredictsTheSameProfile() async throws {
        let cases: [(String, String, Bool)] = [
            ("mp3", "mp3", true), ("aac", "aac", true),
            ("m4a", "alac", true), ("m4b", "aac", true),
            ("flac", "flac", true), ("wav", "pcm_s24le", true),
            ("wav", "dts", false), ("m4a", "dts", false),
            ("ogg", "vorbis", false), ("m4a", "unknown", false),
            ("mov,mp4,m4a,3gp,3g2,mj2", "aac", true)
        ]
        for kind in [ProviderKind.jellyfin, .emby] {
            for (container, codec, expectedDirect) in cases {
                let stub = StubHTTPClient()
                stub.stub(pathSuffix: "/Users/u1/Items/track", json: """
                {"Id":"track","Type":"Audio","MediaSources":[{"Id":"source","Container":"\(container)",
                 "MediaStreams":[{"Index":0,"Type":"Audio","Codec":"\(codec)","BitRate":256000}]}]}
                """)
                let provider = JellyfinProvider(session: makeSession(provider: kind), http: stub)
                let request = try await provider.audioPlaybackInfo(for: "track", queueContext: nil)
                XCTAssertEqual(request.quality?.isDirectPlay, expectedDirect, "\(kind) \(container)/\(codec)")
                guard case .authenticatedHTTP(let locator) = request.playbackSource else {
                    return XCTFail("Expected authenticated audio")
                }
                let advertised = try XCTUnwrap(locator.resource.queryItems.first { $0.name == "Container" }?.value)
                // Reproduce the server's per-container pipe-codec parsing, not the client's helper.
                let profiles = advertised.split(separator: ",").map { $0.split(separator: "|").map(String.init) }
                XCTAssertTrue(profiles.allSatisfy { $0.count > 1 }, "No wildcard codec profiles")
                let serverDirect = profiles.contains {
                    container.split(separator: ",").map(String.init).contains($0[0])
                        && $0.dropFirst().contains(codec)
                }
                XCTAssertEqual(serverDirect, expectedDirect)
                XCTAssertEqual(locator.deliveryMode, expectedDirect ? .directFile : .serverTranscode)
                if !expectedDirect {
                    XCTAssertEqual(request.quality?.transcodeCodec, "aac")
                }
            }
        }
    }

    func testGenreBrowseMapsFields() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/MusicGenres", json: """
        {"Items":[{"Id":"g1","Name":"Jazz","Type":"MusicGenre"}],"TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let page = try await provider.musicItems(in: "", kind: .genre, page: PageRequest(startIndex: 0, limit: 50))
        XCTAssertEqual(page.genres.first?.name, "Jazz")
    }

    func testAudioPlaybackInfoBuildsUniversalStreamURL() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/t1", json: """
        {"Id":"t1","Name":"Opening","Type":"Audio","Album":"Greatest Hits","AlbumId":"al1",
         "Artists":["The Band"],"RunTimeTicks":1870000000}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let request = try await provider.audioPlaybackInfo(for: "t1", queueContext: nil)
        guard case .authenticatedHTTP(let locator) = request.playbackSource else {
            return XCTFail("expected authenticated HTTP audio locator")
        }
        XCTAssertEqual(locator.resource.path, "Audio/t1/universal")
        XCTAssertEqual(locator.purpose, .audioStream)
        XCTAssertEqual(locator.playSessionID, request.playSessionID)
        XCTAssertFalse(
            locator.resource.queryItems.contains {
                $0.name.localizedCaseInsensitiveContains("token")
                    || $0.name.localizedCaseInsensitiveContains("session")
            }
        )
        XCTAssertNil(request.streamURL)
        XCTAssertNotNil(request.playSessionID)
        XCTAssertEqual(request.track.title, "Opening")
        XCTAssertEqual(request.queue.count, 1)
    }
}
