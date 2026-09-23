import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderSilo
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension SiloProviderTests {
    func testSubtitleSearchAndDownloadFollowSelectedFileAndFetchAuthorizedCues() async throws {
        let (provider, http, _, request) = try await subtitleFixture()
        let context = RemoteSubtitleContext(request: request)
        XCTAssertEqual(context.mediaSourceID, "43")
        let results = try await provider.remoteSubtitleSearch(
            context: context, language: "eng", preference: .init(hearingImpaired: .preferSDH))
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results[0].isHearingImpaired)
        XCTAssertFalse(results[0].isHashMatch, "A match score does not prove a file hash")
        XCTAssertNil(results[0].communityRating)
        XCTAssertEqual(results[0].matchScore, 95)
        XCTAssertNotEqual(results[0].id, results[1].id, "Different providers may reuse the same result id")
        let downloaded = try await provider.downloadRemoteSubtitle(context: context, subtitleID: results[0].id)
        let track = try XCTUnwrap(downloaded)
        XCTAssertTrue(track.isHearingImpaired)
        XCTAssertEqual(track.codec, "webvtt")
        guard case .authenticatedHTTP(let locator) = track.deliverySource else {
            return XCTFail("Downloaded sidecars need the normal credential-free resolver")
        }
        XCTAssertEqual(locator.mediaSourceID, "43")
        XCTAssertEqual(locator.playSessionID, request.playSessionID)
        XCTAssertTrue(locator.resource.queryItems.isEmpty)
        let url = try await provider.resolveHTTPResource(locator)
        XCTAssertEqual(url.path, "/base/api/v2/stream/session1/subtitles/0.vtt")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(.init(name: "file_id", value: "43")))
        XCTAssertTrue(query.contains(.init(name: "downloaded_subtitle_id", value: "90")))
        XCTAssertTrue(query.contains(.init(name: "st", value: "stream-secret")))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleByteProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(SubtitleCueParser.parseCues(String(decoding: bytes, as: UTF8.self)).count, 1)
        let tracks = try await provider.subtitleTracks(context: context)
        XCTAssertEqual(tracks.first?.deliverySource, track.deliverySource, "Refresh must not duplicate the receipt track")
        let requests = await http.requests
        for endpoint in requests.filter({ $0.path.hasPrefix("/api/v2/subtitles") }) {
            XCTAssertEqual(endpoint.headers["X-Profile-Id"], "profile1")
            XCTAssertNotNil(endpoint.headers["Authorization"])
            XCTAssertEqual(endpoint.redirectPolicy, .sameOrigin)
        }
        let search = try XCTUnwrap(requests.first { $0.path == "/api/v2/subtitles/search" }?.body)
        let searchBody = try XCTUnwrap(JSONSerialization.jsonObject(with: search) as? [String: Any])
        XCTAssertEqual(searchBody["media_file_id"] as? String, "43")
        XCTAssertEqual(searchBody["languages"] as? [String], ["eng"])
        let download = try XCTUnwrap(requests.first { $0.path == "/api/v2/subtitles/download" }?.body)
        let downloadBody = try XCTUnwrap(JSONSerialization.jsonObject(with: download) as? [String: Any])
        XCTAssertEqual(downloadBody["media_file_id"] as? String, "43")
        XCTAssertEqual(downloadBody["provider"] as? String, "opensubtitles")
        XCTAssertEqual(downloadBody["subtitle_id"] as? String, "same-id")
        XCTAssertEqual(downloadBody["hearing_impaired"] as? Bool, true)
        XCTAssertEqual(requests.filter { $0.path == "/api/v2/playback/start" }.count, 1)
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("/replan") })
    }

    func testSubtitleResultCannotBeUsedForAnotherFileOrSession() async throws {
        let (provider, http, _, request) = try await subtitleFixture()
        let original = RemoteSubtitleContext(request: request)
        let results = try await provider.remoteSubtitleSearch(context: original, language: "en", preference: .default)
        let wrongFile = RemoteSubtitleContext(itemID: original.itemID, mediaSourceID: "42", playSessionID: original.playSessionID)
        do {
            _ = try await provider.downloadRemoteSubtitle(context: wrongFile, subtitleID: results[0].id)
            XCTFail("Wrong file must not receive a subtitle")
        } catch { XCTAssertTrue(error is RemoteSubtitleError) }
        let second = try await provider.playbackInfo(for: "movie:1", mediaSourceID: "43", forceTranscode: false)
        do {
            _ = try await provider.downloadRemoteSubtitle(context: .init(request: second), subtitleID: results[0].id)
            XCTFail("Search results belong to their original session")
        } catch { XCTAssertTrue(error is RemoteSubtitleError) }
        let downloads = await http.requests.filter { $0.path == "/api/v2/subtitles/download" }
        XCTAssertTrue(downloads.isEmpty)
    }

    func testUnavailableSubtitleProviderHasActionableFailureWithoutSearching() async throws {
        let (provider, http, _, request) = try await subtitleFixture(unavailable: true)
        do {
            _ = try await provider.remoteSubtitleSearch(context: .init(request: request), language: "en", preference: .default)
            XCTFail("An unconfigured source must not be reported as no matches")
        } catch RemoteSubtitleError.unavailable {}
        let searches = await http.requests.filter { $0.path == "/api/v2/subtitles/search" }
        XCTAssertTrue(searches.isEmpty)
    }

    func testFailedSubtitleDownloadIsNotReplayedFromTheSameResult() async throws {
        let (provider, http, _, request) = try await subtitleFixture(failDownload: true)
        let context = RemoteSubtitleContext(request: request)
        let results = try await provider.remoteSubtitleSearch(context: context, language: "en", preference: .default)
        do {
            _ = try await provider.downloadRemoteSubtitle(context: context, subtitleID: results[0].id)
            XCTFail("The outcome is uncertain")
        } catch RemoteSubtitleError.uncertainDownload {}
        do {
            _ = try await provider.downloadRemoteSubtitle(context: context, subtitleID: results[0].id)
            XCTFail("An uncertain POST must not replay")
        } catch RemoteSubtitleError.expiredSearch {}
        let downloads = await http.requests.filter { $0.path == "/api/v2/subtitles/download" }
        XCTAssertEqual(downloads.count, 1)
    }

    func testStoppedSessionAndRemovedLoginCannotResolveDownloadedSubtitle() async throws {
        for removeLogin in [false, true] {
            let (provider, _, store, request) = try await subtitleFixture()
            let context = RemoteSubtitleContext(request: request)
            let results = try await provider.remoteSubtitleSearch(context: context, language: "en", preference: .default)
            let downloaded = try await provider.downloadRemoteSubtitle(context: context, subtitleID: results[0].id)
            guard case .authenticatedHTTP(let locator) = downloaded?.deliverySource else {
                return XCTFail("Missing locator")
            }
            if removeLogin { store.remove() }
            else {
                try await provider.reportPlayback(.init(
                    itemID: "movie:1", playSessionID: request.playSessionID, positionSeconds: 5, isPaused: false
                ), event: .stop)
            }
            do {
                _ = try await provider.resolveHTTPResource(locator)
                XCTFail("Retired authority must not serve a subtitle")
            } catch { XCTAssertTrue(error is AppError) }
        }
    }

    func testSearchWarningsDoNotBecomeMisleadingEmptySuccess() async throws {
        let (provider, _, _, request) = try await subtitleFixture(warningsOnly: true)
        do {
            _ = try await provider.remoteSubtitleSearch(context: .init(request: request), language: "en", preference: .default)
            XCTFail("Provider failure is not an empty match set")
        } catch RemoteSubtitleError.incompleteSearch {}
    }

    func testDistributedMediaKeepsDownloadedSubtitleAuthorizationOnNativeServer() async throws {
        let (provider, _, _, request) = try await subtitleFixture(distributedMedia: true)
        let context = RemoteSubtitleContext(request: request)
        let results = try await provider.remoteSubtitleSearch(context: context, language: "en", preference: .default)
        let downloaded = try await provider.downloadRemoteSubtitle(context: context, subtitleID: results[0].id)
        guard case .authenticatedHTTP(let locator) = downloaded?.deliverySource else {
            return XCTFail("Missing subtitle locator")
        }
        let url = try await provider.resolveHTTPResource(locator)
        XCTAssertEqual(url.host, "silo.test")
        XCTAssertTrue(url.path.hasPrefix("/base/api/v2/stream/session1/subtitles/"))
        guard case .authenticatedHTTP(let mediaLocator) = request.playbackSource else {
            return XCTFail("Missing media locator")
        }
        let mediaURL = try await provider.resolveHTTPResource(mediaLocator)
        XCTAssertEqual(mediaURL.host, "node.test")
        XCTAssertFalse(mediaURL.absoluteString.contains("access-secret"))
    }

    func testDownloadReceiptForDifferentFileNeverProducesDeliveryGrant() async throws {
        let (provider, _, _, request) = try await subtitleFixture(wrongReceiptFile: true)
        let context = RemoteSubtitleContext(request: request)
        let results = try await provider.remoteSubtitleSearch(context: context, language: "en", preference: .default)
        do {
            _ = try await provider.downloadRemoteSubtitle(context: context, subtitleID: results[0].id)
            XCTFail("A receipt cannot replace the chosen file")
        } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
    }

    private func subtitleFixture(unavailable: Bool = false, failDownload: Bool = false,
                                 warningsOnly: Bool = false, distributedMedia: Bool = false,
                                 wrongReceiptFile: Bool = false) async throws
        -> (SiloProvider, SiloSubtitleHTTP, SiloCredentialStub, PlaybackRequest) {
        let raw = try credential().encoded()
        let store = SiloCredentialStub(raw)
        var fixtures = playbackResponses()
        let original = try XCTUnwrap(fixtures["/api/v2/catalog/items/movie:1"])
        var item = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        var versions = try XCTUnwrap(item["versions"] as? [[String: Any]])
        var second = versions[0]
        second["file_id"] = "43"
        versions.append(second)
        item["versions"] = versions
        fixtures["/api/v2/catalog/items/movie:1"] = String(decoding: try JSONSerialization.data(withJSONObject: item), as: UTF8.self)
        fixtures["/api/v2/playback/start"] = fixtures["/api/v2/playback/start"]?
            .replacingOccurrences(of: #""effective_media_file_id":"42""#, with: #""effective_media_file_id":"43""#)
        if distributedMedia {
            fixtures["/api/v2/playback/start"] = fixtures["/api/v2/playback/start"]?
                .replacingOccurrences(of: "https://silo.test/base/api/v2/stream/", with: "https://node.test/stream/")
        }
        let http = SiloSubtitleHTTP(fixtures: fixtures, unavailable: unavailable,
                                    failDownload: failDownload, warningsOnly: warningsOnly,
                                    wrongReceiptFile: wrongReceiptFile)
        let provider = try SiloProvider(context: context(raw), credentials: store, http: http)
        let request = try await provider.playbackInfo(for: "movie:1", mediaSourceID: "43", forceTranscode: false)
        return (provider, http, store, request)
    }
}

private actor SiloSubtitleHTTP: HTTPClient {
    let fixtures: [String: String]
    let unavailable: Bool
    let failDownload: Bool
    let warningsOnly: Bool
    let wrongReceiptFile: Bool
    private(set) var requests: [Endpoint] = []
    private var starts = 0
    private var downloaded = false
    private var receipt = ""

    init(fixtures: [String: String], unavailable: Bool, failDownload: Bool, warningsOnly: Bool, wrongReceiptFile: Bool) {
        self.fixtures = fixtures
        self.unavailable = unavailable
        self.failDownload = failDownload
        self.warningsOnly = warningsOnly
        self.wrongReceiptFile = wrongReceiptFile
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        let body: String
        switch endpoint.path {
        case "/api/v2/subtitles/providers/status":
            body = """
            {"enabled":\(unavailable ? "false" : "true"),"allowed":true,
             "state":"\(unavailable ? "not_configured" : "available")","providers":["opensubtitles"]}
            """
        case "/api/v2/subtitles/search":
            body = warningsOnly ? #"{"results":[],"warnings":["Provider unavailable"]}"# : """
            {"results":[
             {"id":"same-id","provider":"opensubtitles","language":"en","release_name":"English SDH",
              "format":"srt","score":95,"downloads":10,"hearing_impaired":true},
             {"id":"same-id","provider":"other-provider","language":"en","release_name":"English",
              "format":"ass","score":100,"downloads":20,"hearing_impaired":false}],"warnings":[]}
            """
        case "/api/v2/subtitles/download":
            if failDownload { throw AppError.serverUnreachable }
            let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(endpoint.body)) as? [String: Any])
            let row: [String: Any] = [
                "id": "90", "media_file_id": wrongReceiptFile ? "42" : "43", "provider": try XCTUnwrap(sent["provider"]),
                "language": try XCTUnwrap(sent["language"]), "format": "srt",
                "release_name": "English", "hearing_impaired": try XCTUnwrap(sent["hearing_impaired"])
            ]
            receipt = String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self)
            downloaded = true
            body = "{\"subtitle\":\(receipt)}"
        case "/api/v2/subtitles/43":
            body = "{\"subtitles\":\(downloaded ? "[\(receipt)]" : "[]")}"
        case "/api/v2/playback/start":
            starts += 1
            body = try XCTUnwrap(fixtures[endpoint.path]).replacingOccurrences(of: "session1", with: "session\(starts)")
        default:
            body = try XCTUnwrap(fixtures["\(endpoint.method.rawValue) \(endpoint.path)"] ?? fixtures[endpoint.path])
        }
        return (Data(body.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class SubtitleByteProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "silo.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let authorized = url.path == "/base/api/v2/stream/session1/subtitles/0.vtt"
            && fields.contains(.init(name: "token", value: "access-secret"))
            && fields.contains(.init(name: "file_id", value: "43"))
            && fields.contains(.init(name: "downloaded_subtitle_id", value: "90"))
        let body = authorized ? "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello.\n" : "Unauthorized"
        let response = HTTPURLResponse(url: url, statusCode: authorized ? 200 : 401,
                                       httpVersion: nil, headerFields: ["Content-Type": "text/vtt"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
