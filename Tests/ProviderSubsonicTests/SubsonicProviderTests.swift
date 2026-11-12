import XCTest
import Foundation
import CoreModels
@testable import CoreNetworking
@testable import ProviderSubsonic

final class SubsonicProviderTests: XCTestCase {
    func testAddressPreservesSubpathAndRejectsCredentialURLs() throws {
        XCTAssertEqual(try SubsonicClient.normalizeAddress("https://example.test/music/rest/").absoluteString,
                       "https://example.test/music")
        for value in ["https://user:secret@example.test", "https://example.test?apiKey=secret",
                      "file:///tmp/music", "https://example.test/#secret", ""] {
            XCTAssertThrowsError(try SubsonicClient.normalizeAddress(value))
        }
    }

    func testPasswordTokenMatchesProtocolAndDoesNotPersistPassword() throws {
        let credential = SubsonicCredential.password(username: "listener", password: "sesame", salt: "c19b2d")
        XCTAssertEqual(credential.token, "26719a1196d2a940705a59634eb18eab")
        XCTAssertFalse(try credential.encoded().contains("sesame"))
        XCTAssertNil(credential.apiKey)
    }

    func testSignInUsesValidatedIdentityAndSameOriginPolicy() async throws {
        let http = StubHTTP { endpoint in
            XCTAssertTrue(["/rest/ping.view", "/rest/getUser.view"].contains(endpoint.path))
            let request = try URLSessionHTTPClient.makeRequest(
                endpoint, baseURL: URL(string: "https://example.test/music")!
            )
            XCTAssertEqual(request.url?.path, "/music" + endpoint.path)
            XCTAssertEqual(endpoint.redirectPolicy, .sameOrigin)
            XCTAssertFalse(endpoint.allowsAutomaticAddressRetry)
            XCTAssertEqual(endpoint.queryItems.first { $0.name == "apiKey" }?.value, "fixture-key")
            XCTAssertFalse(endpoint.queryItems.contains { ["t", "p"].contains($0.name) })
            return #"{"subsonic-response":{"status":"ok","version":"1.16.1","user":{"username":"listener"}}}"#
        }
        let session = try await SubsonicProvider.signIn(
            address: "https://example.test/music", username: "listener", password: "fixture-key",
            usesAPIKey: true, deviceID: "test", http: http
        )
        XCTAssertEqual(session.server.provider, .subsonic)
        XCTAssertEqual(session.server.baseURL.path, "/music")
        XCTAssertEqual(session.userID, "listener")
        XCTAssertFalse(session.server.baseURL.absoluteString.contains("fixture-key"))
    }

    func testProtocolAuthenticationErrorIsNotSuccessfulHTTP() async throws {
        let provider = try makeProvider(StubHTTP { _ in
            #"{"subsonic-response":{"status":"failed","error":{"code":40,"message":"secret"}}}"#
        })
        do {
            _ = try await provider.musicLibraries()
            XCTFail("Expected authentication refusal")
        } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
    }

    func testAPIKeyCannotBindAnUnverifiedUsername() async throws {
        let http = StubHTTP { _ in
            #"{"subsonic-response":{"status":"ok","user":{"username":"different"}}}"#
        }
        do {
            _ = try await SubsonicProvider.signIn(
                address: "https://example.test", username: "listener", password: "fixture-key",
                usesAPIKey: true, deviceID: "test", http: http
            )
            XCTFail("API-key sign-in requires a matching server user")
        } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
    }

    func testArtistAlbumsAndSongAlbumNameDecodeIndependently() async throws {
        let provider = try makeProvider(StubHTTP { endpoint in
            if endpoint.path.contains("getArtist") {
                return #"{"subsonic-response":{"status":"ok","artist":{"id":"a","name":"Artist","album":[{"id":"b","name":"Album","coverArt":"cover"}]}}}"#
            }
            return #"{"subsonic-response":{"status":"ok","album":{"id":"b","name":"Album","song":[{"id":"s","title":"Song","album":"Album","suffix":"flac"}]}}}"#
        })
        let page = try await provider.musicItems(in: "a", kind: .album, page: PageRequest())
        XCTAssertEqual(page.albums.map(\.title), ["Album"])
        XCTAssertEqual(page.albums.first?.artworkURL?.scheme, AuthenticatedArtworkReference.scheme)
        let tracks = try await provider.tracks(in: "b")
        XCTAssertEqual(tracks.first?.albumTitle, "Album")
    }

    func testAlbumPaginationHasContinuationWithoutInventingExactTotal() async throws {
        let provider = try makeProvider(StubHTTP { endpoint in
            XCTAssertEqual(endpoint.queryItems.first { $0.name == "offset" }?.value, "5")
            return #"{"subsonic-response":{"status":"ok","albumList2":{"album":[{"id":"one","name":"One"},{"id":"two","name":"Two"}]}}}"#
        })
        let page = try await provider.musicItems(in: "", kind: .album, page: .init(startIndex: 5, limit: 2))
        XCTAssertEqual(page.startIndex, 5)
        XCTAssertEqual(page.totalCount, 8)
        XCTAssertTrue(page.hasMore)
    }

    func testDisabledLibraryDoesNotRequestServer() async throws {
        let provider = try makeProvider(StubHTTP { _ in
            XCTFail("Disabled library must not be queried")
            return ""
        })
        let page = try await provider.musicItems(in: "", kind: .album, page: .init(), libraryIDs: [])
        XCTAssertEqual(page.count, 0)
    }

    func testTrackCatalogueUsesAlbumWalkAndRetainsDuplicatePlaylistEntries() async throws {
        let provider = try makeProvider(StubHTTP { endpoint in
            switch endpoint.path {
            case "/rest/getAlbumList2.view":
                if endpoint.queryItems.first(where: { $0.name == "offset" })?.value == "0" {
                    return #"{"subsonic-response":{"status":"ok","albumList2":{"album":[{"id":"album"}]}}}"#
                }
                return #"{"subsonic-response":{"status":"ok","albumList2":{}}}"#
            case "/rest/getAlbum.view":
                return #"{"subsonic-response":{"status":"ok","album":{"id":"album","song":[{"id":"s1"},{"id":"s2"},{"id":"s3"}]}}}"#
            case "/rest/getPlaylist.view":
                return #"{"subsonic-response":{"status":"ok","playlist":{"id":"p","entry":[{"id":"s1"},{"id":"s1"}]}}}"#
            default:
                XCTFail("Must not use an empty search")
                return ""
            }
        })
        let first = try await provider.musicItems(in: "", kind: .track, page: .init(limit: 2))
        let second = try await provider.musicItems(in: "", kind: .track, page: .init(startIndex: 2, limit: 2))
        XCTAssertEqual(first.tracks.map(\.id), ["s1", "s2"])
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(second.tracks.map(\.id), ["s3"])
        XCTAssertFalse(second.hasMore)
        let playlist = try await provider.tracks(in: "playlist:p")
        XCTAssertEqual(playlist.map(\.id), ["s1", "s1"])
    }

    func testRepeatedAlbumPageFailsRatherThanLoopsOrTruncates() async throws {
        let provider = try makeProvider(StubHTTP { endpoint in
            if endpoint.path == "/rest/getAlbum.view" {
                return #"{"subsonic-response":{"status":"ok","album":{"id":"album","song":[]}}}"#
            }
            return #"{"subsonic-response":{"status":"ok","albumList2":{"album":[{"id":"album"}]}}}"#
        })
        do {
            _ = try await provider.musicItems(in: "", kind: .track, page: .init())
            XCTFail("Repeated pages must be rejected")
        } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
    }

    func testScrobbleRequiresListeningNotSeekingAndDoesNotSubmitTwice() async {
        let session = SubsonicListeningSession()
        func progress(_ position: Double) -> PlaybackProgress {
            .init(itemID: "song", playSessionID: "session", positionSeconds: position,
                  isPaused: false, durationSeconds: 180)
        }
        _ = await session.shouldSubmit(progress(0), event: .start, now: 0)
        let sought = await session.shouldSubmit(progress(170), event: .stop, now: 2)
        XCTAssertFalse(sought)
        _ = await session.shouldSubmit(progress(0), event: .start, now: 10)
        let listened = await session.shouldSubmit(progress(100), event: .stop, now: 110)
        XCTAssertTrue(listened)
        let duplicate = await session.shouldSubmit(progress(100), event: .stop, now: 111)
        XCTAssertFalse(duplicate)
    }

    func testArtworkRefreshStaysWithinAccount() throws {
        let provider = try makeProvider(StubHTTP { _ in "" })
        let old = try XCTUnwrap(AuthenticatedArtworkReference(
            accountID: "account", credentialRevision: .init(), resourceID: "cover", size: 400
        ).url)
        let refreshed = try XCTUnwrap(provider.reauthenticatedImageURL(old, maxWidth: nil))
        XCTAssertNotEqual(old, refreshed)
        XCTAssertEqual(AuthenticatedArtworkReference(url: refreshed)?.resourceID, "cover")
        let other = try XCTUnwrap(AuthenticatedArtworkReference(
            accountID: "other", credentialRevision: .init(), resourceID: "cover", size: nil
        ).url)
        XCTAssertNil(provider.reauthenticatedImageURL(other, maxWidth: nil))
    }

    func testPlaybackLocatorHasNoCredentialsAndRejectsAnotherRevision() async throws {
        let provider = try makeProvider(StubHTTP { _ in
            #"{"subsonic-response":{"status":"ok","song":{"id":"track/one","title":"Song","suffix":"flac"}}}"#
        })
        let request = try await provider.audioPlaybackInfo(for: "track/one", queueContext: nil)
        guard case let .authenticatedHTTP(locator) = request.playbackSource else {
            return XCTFail("Expected authenticated source")
        }
        XCTAssertEqual(locator.resource.queryItems.map(\.name), ["id", "format"])
        XCTAssertFalse(request.isTranscoding)
        let url = try await provider.resolveHTTPResource(locator)
        XCTAssertEqual(url.path, "/music/rest/stream.view")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.queryItems?.first { $0.name == "id" }?.value, "track/one")
        let wrong = try AuthenticatedHTTPPlaybackLocator(
            provider: .subsonic, accountID: locator.accountID, credentialRevision: .init(),
            itemID: locator.itemID, deliveryMode: .directFile, purpose: .audioStream,
            resource: locator.resource
        )
        do {
            _ = try await provider.resolveHTTPResource(wrong)
            XCTFail("Expected identity refusal")
        } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
    }

    func testArtworkReferenceContainsNoCredentials() throws {
        let reference = AuthenticatedArtworkReference(
            accountID: "account", credentialRevision: .init(), resourceID: "cover/a?b", size: 600
        )
        let url = try XCTUnwrap(reference.url)
        XCTAssertEqual(AuthenticatedArtworkReference(url: url), reference)
        XCTAssertFalse(url.absoluteString.contains("fixture-token"))
        XCTAssertFalse(url.absoluteString.contains("example.test"))
    }

    func testMusicOnlyLibrariesAndNavigation() async throws {
        let provider = try makeProvider(StubHTTP { _ in #"{"subsonic-response":{"status":"ok"}}"# })
        let libraries = try await provider.libraries()
        XCTAssertTrue(libraries.allSatisfy(\.isMusic))
        XCTAssertEqual(provider.capabilities, [.music])
        let account = Account(from: provider.session)
        let availability = NavigationContentAvailability(
            accounts: [account], libraries: [], discoveredAccountIDs: [],
            disabledLibraryKeys: [], hasDiscoverySearch: false, hasWatchlistItems: false
        )
        XCTAssertFalse(availability.hasHomeContent)
        XCTAssertFalse(availability.hasSearchContent)
        XCTAssertFalse(availability.prefersLiveTV)
        XCTAssertTrue(availability.prefersMusic)
        var tvAccount = account
        tvAccount.server.provider = .iptv
        let mixed = NavigationContentAvailability(
            accounts: [account, tvAccount], libraries: [], discoveredAccountIDs: [],
            disabledLibraryKeys: [], hasDiscoverySearch: false, hasWatchlistItems: false
        )
        XCTAssertTrue(mixed.prefersLiveTV)
        XCTAssertFalse(mixed.prefersMusic)
    }

    private func makeProvider(_ http: StubHTTP) throws -> SubsonicProvider {
        let credential = SubsonicCredential(username: "listener", token: "fixture-token", salt: "salt", apiKey: nil)
        let session = UserSession(
            server: .init(id: "server", name: "Music", baseURL: URL(string: "https://example.test/music")!,
                          provider: .subsonic),
            userID: "listener", userName: "Listener", deviceID: "test", accessToken: try credential.encoded()
        )
        return try SubsonicProvider(context: .init(session: session, accountID: "account", credentialRevision: .init()),
                                    http: http)
    }
}

private struct StubHTTP: HTTPClient {
    let response: @Sendable (Endpoint) throws -> String
    init(_ response: @escaping @Sendable (Endpoint) throws -> String) { self.response = response }
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let body = try response(endpoint)
        return (Data(body.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
