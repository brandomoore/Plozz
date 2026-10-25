import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import LastFmService
@testable import TestSupportNetworking

final class LastFmListeningHistoryTests: XCTestCase {
    private func track(time: Int? = 900, now: Bool = false, mbid: String = "") -> String {
        let date = time.map { #","date":{"uts":"\#($0)"}"# } ?? ""
        let playing = now ? #","@attr":{"nowplaying":"true"}"# : ""
        return """
        {"name":"Fixture track","artist":{"#text":"Fixture artist"},"album":{"#text":"Fixture album"},
         "mbid":"\(mbid)"\(date)\(playing)}
        """
    }

    private func response(
        _ tracks: [String], page: Int = 1, pages: Int = 1, total: Int = 1, user: String = "fixture"
    ) -> String {
        """
        {"recenttracks":{"track":[\(tracks.joined(separator: ","))],
         "@attr":{"user":"\(user)","page":"\(page)","perPage":"50","totalPages":"\(pages)","total":"\(total)"}}}
        """
    }

    private func http(_ body: String) -> RecordingHTTPClient {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/2.0/", json: body)
        return http
    }

    private func read(
        _ http: any HTTPClient, page: Int = 1,
        validate: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> LastFmListeningHistoryPage {
        try await LastFmClient(config: .init(apiKey: "fixture", sharedSecret: "not-sent"), http: http)
            .listeningHistory(username: "fixture", page: page, before: 1000, validateScope: validate)
    }

    func testReadOnlyRequestDoesNotSendSessionKeyOrSignature() async throws {
        let id = "d0c89c8d-bf6c-4c94-8006-5debb44cba19"
        let http = http(response([track(mbid: id)]))
        let page = try await read(HistoryHTTP(http: http))
        let sent = try XCTUnwrap(http.sent.first)
        let query = Dictionary(uniqueKeysWithValues: sent.queryItems.map { ($0.name, $0.value) })
        XCTAssertEqual(query["method"], "user.getRecentTracks")
        XCTAssertEqual(query["user"], "fixture")
        XCTAssertEqual(query["api_key"], "fixture")
        XCTAssertEqual(query["to"], "1000")
        XCTAssertEqual(query["limit"], "50")
        XCTAssertEqual(query["page"], "1")
        XCTAssertNil(query["sk"])
        XCTAssertNil(query["api_sig"])
        XCTAssertNil(sent.headers["Authorization"])
        XCTAssertNil(sent.body)
        XCTAssertEqual(page.totalPlays, 1)
        XCTAssertEqual(page.plays[0].title, "Fixture track")
        XCTAssertEqual(page.plays[0].artist, "Fixture artist")
        XCTAssertEqual(page.plays[0].album, "Fixture album")
        XCTAssertEqual(page.plays[0].musicBrainzID, UUID(uuidString: id))
        XCTAssertEqual(page.plays[0].playedAt, Date(timeIntervalSince1970: 900))
    }

    func testCurrentTrackDoesNotCountAsAScrobbleAndRepeatedPlaysArePreserved() async throws {
        let result = try await read(http(response(
            [track(time: nil, now: true), track(), track()], total: 2
        )))
        XCTAssertEqual(result.plays.count, 2)
        XCTAssertEqual(result.totalPlays, 2)
        XCTAssertNotNil(result.nowPlaying)
        XCTAssertNil(result.nowPlaying?.playedAt)
        XCTAssertNil(result.plays[0].musicBrainzID)
        XCTAssertEqual(result.plays[0].playedAt, result.plays[1].playedAt)
    }

    func testEmptyHistoryAcceptsZeroOrOneAdvertisedPages() async throws {
        for pages in [0, 1] {
            let result = try await read(http(response([track(time: nil, now: true)], pages: pages, total: 0)))
            XCTAssertTrue(result.plays.isEmpty)
            XCTAssertEqual(result.totalPlays, 0)
            XCTAssertNotNil(result.nowPlaying)
        }
    }

    func testFinalPageRequiresItsExactCountAndRequestedPage() async throws {
        let result = try await read(http(response([track()], page: 2, pages: 2, total: 51)), page: 2)
        XCTAssertEqual(result.page, 2)
        XCTAssertEqual(result.totalPages, 2)
        for invalid in [
            response([], page: 2, pages: 2, total: 51),
            response([track()], page: 1, pages: 2, total: 51),
            response([track()], page: 2, pages: 3, total: 51),
            response([track()], page: 2, pages: 2, total: -1)
        ] {
            do { _ = try await read(http(invalid), page: 2); XCTFail("Invalid page accepted") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
        }
    }

    func testInvalidInputDoesNotSendRequests() async {
        for page in [0, -1, Int.max] {
            let http = http(response([track()]))
            do { _ = try await read(http, page: page); XCTFail("Invalid request") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .invalidSelection) }
            XCTAssertTrue(http.sent.isEmpty)
        }
    }

    func testOwnerCheckIsCaseInsensitiveButCannotReadAnotherAccount() async throws {
        _ = try await read(http(response([track()], user: "FIXTURE")))
        do { _ = try await read(http(response([track()], user: "other"))); XCTFail("Wrong owner") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
    }

    func testMalformedFieldsCurrentFlagsAndDatesRejectThePage() async {
        for entry in [
            track(time: nil), track(now: true), track(time: -1), track(mbid: "not-a-uuid"),
            track().replacingOccurrences(of: "Fixture artist", with: ""),
            track().replacingOccurrences(of: "Fixture track", with: ""),
            track().replacingOccurrences(of: #""uts":"900""#, with: #""uts":"invalid""#)
        ] {
            do { _ = try await read(http(response([entry]))); XCTFail("Invalid track") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .invalidObservation) }
        }
        do {
            _ = try await read(http(response([track(time: nil, now: true), track(time: nil, now: true)], total: 0)))
            XCTFail("Duplicate now-playing")
        } catch { XCTAssertEqual(error as? TrackerHistoryError, .invalidObservation) }
    }

    func testFutureDatesOrderingAndMissingDataNeverLookComplete() async {
        for invalid in [
            response([track(time: 1001)]), response([track(time: 800), track(time: 900)], total: 2),
            "{}", #"{"recenttracks":null}"#,
            response([track()]).replacingOccurrences(of: #""perPage":"50""#, with: #""perPage":"200""#),
            response([track()]).replacingOccurrences(of: #""track":["#, with: #""track":[null,"#)
        ] {
            do { _ = try await read(http(invalid)); XCTFail("Incomplete response") }
            catch { XCTAssertNotNil(error as? TrackerHistoryError) }
        }
    }

    func testHTTPOKErrorEnvelopesNeverRetryOrExposeTheirText() async {
        for code in [4, 9, 10, 26, 29, 11] {
            let http = http(#"{"error":\#(code),"message":"private diagnostic"}"#)
            do { _ = try await read(http); XCTFail("API error accepted") }
            catch {
                if code == 29 { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: nil)) }
                else if code == 11 { XCTAssertEqual(error as? AppError, .invalidResponse) }
                else { XCTAssertEqual(error as? AppError, .unauthorized) }
            }
            XCTAssertEqual(http.sent.count, 1)
        }
    }

    func testByteAndPageLimitsAreMeasuredNotSilentlyTruncated() async {
        for body in [
            String(repeating: " ", count: 2 * 1_024 * 1_024 + 1),
            response(Array(repeating: track(), count: 52), pages: 2, total: 52)
        ] {
            do { _ = try await read(http(body)); XCTFail("Oversized response") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
        }
    }

    func testCancellationAndChangedScopeAreCheckedAroundDispatch() async {
        let http = http(response([track()]))
        do {
            _ = try await read(http, validate: { throw TrackerHistoryError.scopeChanged })
            XCTFail("Changed scope")
        } catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
        XCTAssertTrue(http.sent.isEmpty)
        let task = Task {
            try await read(HistoryHTTP(http: http, afterSend: { withUnsafeCurrentTask { $0?.cancel() } }))
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(http.sent.count, 1)
    }

    @MainActor
    func testProfileCredentialAndDisconnectChangesFenceResponses() async throws {
        for change in 0..<3 {
            let http = http(response([track()]))
            let store = InMemoryLastFmTokenStore(tokens: .init(sessionKey: "session", username: "fixture"))
            let transport = ServiceHTTP(http: http)
            let service = LastFmService(
                config: .init(apiKey: "fixture", sharedSecret: "fixture"), http: transport, tokenStore: store
            )
            await service.refreshStatus()
            let connection = try XCTUnwrap(service.historyConnectionID)
            transport.afterSend = {
                switch change {
                case 0: await service.setActiveProfile(namespace: "other")
                case 1: await service.disconnect()
                default: try store.save(.init(sessionKey: "replacement", username: "fixture"))
                }
            }
            do {
                _ = try await service.listeningHistory(page: 1, before: 1000, expectedConnectionID: connection)
                XCTFail("Stale response accepted")
            } catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
            XCTAssertEqual(http.sent.count, 1)
        }
    }

    private struct HistoryHTTP: HTTPClient {
        let http: RecordingHTTPClient
        var afterSend: @Sendable () async -> Void = {}
        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            XCTAssertEqual(endpoint.method, .get)
            XCTAssertEqual(endpoint.redirectPolicy, .sameOrigin)
            XCTAssertEqual(endpoint.maximumResponseBytes, 2 * 1_024 * 1_024)
            XCTAssertTrue(endpoint.redactsURLForLogging)
            let result = try await http.send(endpoint, baseURL: baseURL)
            await afterSend()
            return result
        }
    }

    @MainActor
    private final class ServiceHTTP: HTTPClient {
        let http: RecordingHTTPClient
        var afterSend: (@MainActor @Sendable () async throws -> Void)?
        init(http: RecordingHTTPClient) { self.http = http }
        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            let result = try await http.send(endpoint, baseURL: baseURL)
            try await afterSend?()
            return result
        }
    }
}
