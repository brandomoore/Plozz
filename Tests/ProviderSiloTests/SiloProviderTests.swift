import CoreModels
import CoreNetworking
import Foundation
import XCTest

@testable import ProviderSilo

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

actor SiloHTTPStub: HTTPClient {
  private var responses: [String: String]
  private(set) var requests: [Endpoint] = []
  init(_ responses: [String: String]) { self.responses = responses }

  func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
    requests.append(endpoint)
    guard
      let body = responses["\(endpoint.method.rawValue) \(endpoint.path)"]
        ?? responses[endpoint.path]
    else { throw AppError.notFound }
    return (
      Data(body.utf8),
      HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
}

extension SiloProviderTests {
  func playbackResponses() -> [String: String] {
    [
      "/api/v2/catalog/items/movie:1": """
      {"content_id":"movie:1","type":"movie","title":"Test movie","position_seconds":125,
       "versions":[{"file_id":"42","resolution":"2160p","codec_video":"hevc","codec_audio":"eac3",
       "container":"mkv","file_size":100,"duration":600,"bitrate":12000,
       "video_tracks":[{"codec":"hevc","width":3840,"height":2160,"hdr10_plus":true}]}]}
      """,
      "/api/v2/playback/capabilities": """
      {"installation_id":"server1","protocol_versions":[3],"features":["fixed_media_file_v1"],
       "deliveries":["original_http"],"state":"available","allowed":true}
      """,
      "/api/v2/playback/start": """
      {"protocol_version":3,"outcome":"playable","session_id":"session1",
       "playback_plan":{"protocol_version":3,"delivery":"original_http","effective_media_file_id":"42",
       "stream":{"url":"https://silo.test/base/api/v2/stream/session1?st=stream-secret","headers":{},"header_refresh":"none"},
       "timeline":{"source_start_seconds":0,"player_start_seconds":0,"timeline_offset_seconds":0,"can_seek_anywhere":true},
       "subtitle":{"mode":"none","inventory":[]}}}
      """,
      "/api/v2/playback/session1/progress": #"{"outcome":"applied"}"#,
      "DELETE /api/v2/playback/session1": #"{"outcome":"stopped"}"#,
    ]
  }

  func testPlaybackKeepsSignedGrantOutOfLocatorAndReportsSequencedProgress() async throws {
    let raw = try credential().encoded()
    let http = SiloHTTPStub(playbackResponses())
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    let request = try await provider.playbackInfo(
      for: "movie:1", mediaSourceID: "42", forceTranscode: false)
    XCTAssertFalse(request.isTranscoding)
    XCTAssertEqual(request.deliveryMode, .directPlay)
    XCTAssertFalse(request.isManifestStream)
    XCTAssertEqual(request.startPosition, 125)
    XCTAssertEqual(request.sourceMetadata?.video?.videoRangeType, "HDR10Plus")
    XCTAssertNil(request.streamURL)
    guard case .authenticatedHTTP(let locator) = request.playbackSource else {
      return XCTFail("Missing grant")
    }
    XCTAssertFalse(locator.resource.path.contains("stream-secret"))
    let url = try await provider.resolveHTTPResource(locator)
    XCTAssertTrue(url.absoluteString.contains("st=stream-secret"))
    XCTAssertTrue(url.absoluteString.contains("token=access-secret"))
    XCTAssertTrue(locator.resource.queryItems.isEmpty)
    let progress = PlaybackProgress(
      itemID: "movie:1", playSessionID: "session1", positionSeconds: 140, isPaused: false)
    try await provider.reportPlayback(progress, event: .start)
    try await provider.reportPlayback(progress, event: .stop)
    do {
      _ = try await provider.resolveHTTPResource(locator)
      XCTFail("Stopped grants must no longer resolve")
    } catch { XCTAssertEqual(error as? AppError, .notFound) }
    let requests = await http.requests
    let reports = requests.filter { $0.path.contains("/session1") }
    let bodies = try reports.map {
      try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.body)) as? [String: Any])
    }
    XCTAssertEqual(bodies.compactMap { $0["sequence"] as? Int }, [1, 2])
    XCTAssertNotNil(bodies.last?["stop_id"])
  }

  func testForcedServerTranscodeHLSMarksRequestAndRevokesGrantOnStop() async throws {
    let raw = try credential().encoded()
    var responses = playbackResponses()
    responses["/api/v2/playback/capabilities"] = responses["/api/v2/playback/capabilities"]?
      .replacingOccurrences(of: "[\"original_http\"]", with: "[\"original_http\",\"hls\"]")
    responses["/api/v2/playback/start"] = responses["/api/v2/playback/start"]?
      .replacingOccurrences(of: "\"delivery\":\"original_http\"", with: "\"delivery\":\"server_transcode_hls\"")
      .replacingOccurrences(of: "/stream/session1?", with: "/playback/transcode/session1/master.m3u8?")
    let http = SiloHTTPStub(responses)
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    let request = try await provider.playbackInfo(
      for: "movie:1", mediaSourceID: "42", forceTranscode: true)
    XCTAssertEqual(request.deliveryMode, .transcode)
    XCTAssertTrue(request.isTranscoding)
    XCTAssertTrue(request.isManifestStream)
    XCTAssertEqual(request.playSessionID, "session1")
    XCTAssertNil(request.streamingOptions, "The legacy API does not invent a user-selected quality limit")
    XCTAssertNil(request.streamingSessionID, "Cleanup uses the negotiated playback session")
    XCTAssertNil(request.streamURL)
    XCTAssertNil(request.originalFileSource)
    guard case .authenticatedHTTP(let locator) = request.playbackSource else {
      return XCTFail("Missing authenticated HLS grant")
    }
    XCTAssertEqual(locator.deliveryMode, .hls)
    XCTAssertEqual(locator.mediaSourceID, "42")
    XCTAssertTrue(locator.resource.queryItems.isEmpty)
    let resolved = try await provider.resolveHTTPResource(locator)
    XCTAssertEqual(resolved.path, "/base/api/v2/playback/transcode/session1/master.m3u8")
    let query = try XCTUnwrap(URLComponents(url: resolved, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(query.first { $0.name == "st" }?.value, "stream-secret")
    XCTAssertEqual(query.first { $0.name == "token" }?.value, "access-secret")

    try await provider.reportPlayback(.init(
      itemID: "movie:1", playSessionID: request.playSessionID, positionSeconds: 125, isPaused: false
    ), event: .stop)
    do {
      _ = try await provider.resolveHTTPResource(locator)
      XCTFail("Stopped HLS grants must no longer resolve")
    } catch { XCTAssertEqual(error as? AppError, .notFound) }
    let requests = await http.requests
    let start = try XCTUnwrap(requests.first { $0.path == "/api/v2/playback/start" })
    let startBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(start.body)) as? [String: Any])
    XCTAssertEqual(startBody["quality_preference"] as? String, "1080p")
    XCTAssertEqual(startBody["file_id"] as? String, "42")
    XCTAssertEqual(startBody["allow_alternate_versions"] as? Bool, false)
    let stops = requests.filter { $0.method == .delete && $0.path == "/api/v2/playback/session1" }
    XCTAssertEqual(stops.count, 1)
    let stop = try XCTUnwrap(stops.first)
    let stopBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(stop.body)) as? [String: Any])
    XCTAssertEqual(stopBody["installation_id"] as? String, "server1")
    XCTAssertEqual(stopBody["sequence"] as? Int, 1)
    XCTAssertFalse(try XCTUnwrap(stopBody["stop_id"] as? String).isEmpty)
  }

  func testServerRemuxHLSIsManifestWithoutTranscodingFlag() async throws {
    let raw = try credential().encoded()
    var responses = playbackResponses()
    responses["/api/v2/playback/capabilities"] = responses["/api/v2/playback/capabilities"]?
      .replacingOccurrences(of: "[\"original_http\"]", with: "[\"original_http\",\"hls\"]")
    responses["/api/v2/playback/start"] = responses["/api/v2/playback/start"]?
      .replacingOccurrences(of: "\"delivery\":\"original_http\"", with: "\"delivery\":\"server_remux_hls\"")
      .replacingOccurrences(of: "/stream/session1?", with: "/playback/transcode/session1/master.m3u8?")
    let http = SiloHTTPStub(responses)
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    let request = try await provider.playbackInfo(
      for: "movie:1", mediaSourceID: "42", forceTranscode: false)
    XCTAssertEqual(request.deliveryMode, .remux)
    XCTAssertFalse(request.isTranscoding, "HLS delivery alone is not evidence of transcoding")
    XCTAssertTrue(request.isManifestStream)
    guard case .authenticatedHTTP(let locator) = request.playbackSource else {
      return XCTFail("Missing authenticated HLS grant")
    }
    XCTAssertEqual(locator.deliveryMode, .hls)
    try await provider.reportPlayback(.init(
      itemID: "movie:1", playSessionID: request.playSessionID, positionSeconds: 125, isPaused: false
    ), event: .stop)
  }

  func testChosenVersionNeverFallsBackToDifferentFile() async throws {
    let raw = try credential().encoded()
    let http = SiloHTTPStub(playbackResponses())
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    do {
      _ = try await provider.playbackInfo(
        for: "movie:1", mediaSourceID: "999", forceTranscode: false)
      XCTFail("Missing version must not play a different file")
    } catch { XCTAssertEqual(error as? AppError, .notFound) }
    let requests = await http.requests
    XCTAssertFalse(requests.contains { $0.path == "/api/v2/playback/start" })
  }

  func testUnsupportedTimelineReleasesNegotiatedSession() async throws {
    let raw = try credential().encoded()
    var responses = playbackResponses()
    responses["/api/v2/playback/start"] = responses["/api/v2/playback/start"]?
      .replacingOccurrences(
        of: "\"timeline_offset_seconds\":0", with: "\"timeline_offset_seconds\":120")
    let http = SiloHTTPStub(responses)
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    do {
      _ = try await provider.playbackInfo(for: "movie:1")
      XCTFail("A shifted timeline must not report incorrect progress")
    } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
    let requests = await http.requests
    XCTAssertTrue(
      requests.contains { $0.method == .delete && $0.path == "/api/v2/playback/session1" })
  }

  func testUncertainRefreshIsNotReplayedAfterRecreatingProvider() async throws {
    var credential = try credential()
    credential.expiresAt = .distantPast
    let raw = try credential.encoded()
    let store = SiloCredentialStub(raw)
    let http = SiloHTTPStub([:])
    let context = context(raw)
    let provider = try SiloProvider(context: context, credentials: store, http: http)
    do {
      _ = try await provider.libraries()
      XCTFail("Refresh must fail")
    } catch {}
    let recreated = try SiloProvider(context: context, credentials: store, http: http)
    do {
      _ = try await recreated.libraries()
      XCTFail("Uncertain rotation needs sign-in")
    } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
    let requests = await http.requests
    XCTAssertEqual(requests.filter { $0.path == "/api/v2/auth/refresh" }.count, 1)
  }

  func testProfileMismatchIsRejectedBeforeNetworkIO() throws {
    let raw = try credential().encoded()
    let valid = context(raw)
    var session = valid.session
    session.userID = "user1:another-profile"
    let wrong = ProviderResolutionContext(
      session: session, accountID: valid.accountID, credentialRevision: valid.credentialRevision)
    XCTAssertThrowsError(
      try SiloProvider(
        context: wrong, credentials: SiloCredentialStub(raw), http: SiloHTTPStub([:])))
  }

  func testBulkResumeFailureIsNotReportedAsSuccess() async throws {
    let raw = try credential().encoded()
    let http = SiloHTTPStub([
      "/api/v2/sync/progress":
        #"{"items":[{"media_item_id":"movie:1","status":"failure","index":0}]}"#
    ])
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    do {
      try await provider.setResumePosition(42, itemID: "movie:1", capturedAt: Date())
      XCTFail("Bulk item failure must propagate")
    } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
  }

  func testSignedStreamAndArtworkCredentialsAreRedacted() throws {
    for key in ["st", "X-Amz-Signature", "X-Amz-Credential", "X-Goog-Signature"] {
      let url = URL(string: "https://silo.test/art?\(key)=private-secret&size=small")!
      XCTAssertFalse(SyncURLSanitizer.sanitize(url).absoluteString.contains("private-secret"))
      XCTAssertFalse(PlozzLog.redact(url: url).contains("private-secret"))
      XCTAssertThrowsError(try SecretFreeURLSource(url: url))
    }
    XCTAssertEqual(
      PlozzLog.redact(headers: ["X-Profile-Token": "secret"])["X-Profile-Token"], "<redacted>")
    XCTAssertFalse(ProviderKind.silo.permitsCredentialTransfer)
  }

  private var downloadEntry: String {
    #"{"id":"download1","content_id":"movie:1","media_file_id":"42","file_size":100,"status":"ready","quality":"original","delivery_format":"original","revision":2}"#
  }

  func testExistingNativeDownloadIsReusedWithoutPlaybackOrCreation() async throws {
    let raw = try credential().encoded()
    let http = SiloHTTPStub([
      "/api/v2/capabilities/downloads": """
      {"state":"available","allowed":true,"quality_presets":["original"],"file_delivery":true,
      "bounded_creation":true,"bounded_manifests":true,"ordered_status":true}
      """,
      "/api/v2/downloads": "{\"items\":[\(downloadEntry)]}",
      "/api/v2/downloads/download1/manifest": """
      {"download_id":"download1","media_file_id":"42","revision":2,"file_size":100,
       "duration_seconds":600,"container":"mkv","subtitles":[]}
      """,
      "/api/v2/downloads/download1": downloadEntry,
    ])
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    let result = try await provider.prepareDownload(
      itemID: "movie:1", fileID: "42", quality: "original", maximumHeight: nil, reference: nil,
      persistReference: { value in
        XCTAssertEqual(value, SiloDownloadReference(id: "download1", revision: 2))
      })
    XCTAssertEqual(result.url.path, "/base/api/v2/downloads/download1/file")
    XCTAssertNil(result.url.query)
    XCTAssertEqual(result.headers["X-Silo-Device-Id"], "device1")
    XCTAssertEqual(result.headers["X-Profile-Id"], "profile1")
    XCTAssertEqual(result.expectedBytes, 100)
    let requests = await http.requests
    XCTAssertFalse(requests.contains { $0.method == .post })
    XCTAssertTrue(
      requests.filter { $0.path.hasPrefix("/api/v2/downloads") }.allSatisfy {
        $0.headers["X-Silo-Device-Id"] == "device1"
      })
  }

  func testDownloadRevisionMismatchCannotFetchReplacedBytes() async throws {
    let raw = try credential().encoded()
    let http = SiloHTTPStub([
      "/api/v2/capabilities/downloads": """
      {"state":"available","allowed":true,"quality_presets":["original"],"file_delivery":true,
      "bounded_creation":true,"bounded_manifests":true,"ordered_status":true}
      """,
      "/api/v2/downloads": "{\"items\":[\(downloadEntry)]}",
    ])
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    do {
      _ = try await provider.prepareDownload(
        itemID: "movie:1", fileID: "42", quality: "original", maximumHeight: nil,
        reference: .init(id: "download1", revision: 1),
        persistReference: { _ in XCTFail("Stale reference") })
      XCTFail("Revision mismatch must fail")
    } catch { XCTAssertEqual(error as? AppError, .conflict) }
  }

  func testCredentialRefreshDoesNotInvalidateSameLoginProviderContext() throws {
    let raw = try credential().encoded()
    let original = context(raw)
    var updated = original.session
    updated.accessToken = "rotated-material"
    XCTAssertEqual(
      original,
      ProviderResolutionContext(
        session: updated, accountID: original.accountID,
        credentialRevision: original.credentialRevision))
    XCTAssertNotEqual(
      original,
      ProviderResolutionContext(
        session: updated, accountID: original.accountID,
        credentialRevision: CredentialRevision()))
  }
}

final class SiloCredentialStub: RotatingCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?
  init(_ value: String) { self.value = value }
  func credential(accountID: String, revision: CredentialRevision) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    guard let value else { throw AppError.unauthorized }
    return value
  }
  func rotateCredential(
    accountID: String, revision: CredentialRevision, expected: String, replacement: String
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard value == expected else { throw AppError.unauthorized }
    value = replacement
  }
  func remove() {
    lock.lock()
    value = nil
    lock.unlock()
  }
}

final class SiloProviderTests: XCTestCase {
  private let base = URL(string: "https://silo.test/base")!

  func credential() throws -> SiloCredential {
    let tokens = try JSONDecoder().decode(
      SiloTokenPair.self,
      from: Data(
        """
        {"access_token":"access-secret","refresh_token":"refresh-secret","expires_in":3600,"user":{"id":"user1","username":"Viewer"}}
        """.utf8))
    let profile = try JSONDecoder().decode(
      SiloProfile.self,
      from: Data(
        """
        {"id":"profile1","name":"Viewer","has_pin":false,"is_child":false}
        """.utf8))
    return SiloCredential(tokens: tokens, profile: profile, profileToken: nil)
  }

  func context(_ token: String) -> ProviderResolutionContext {
    .init(
      session: UserSession(
        server: MediaServer(id: "server1", name: "Silo", baseURL: base, provider: .silo),
        userID: "user1:profile1", userName: "Viewer", deviceID: "device1", accessToken: token),
      accountID: "account1", credentialRevision: CredentialRevision())
  }

  func testSiloIsNativeAndPlaybackNegotiationIsNotEager() {
    XCTAssertFalse(ProviderKind.silo.usesMediaBrowserAPI)
    XCTAssertFalse(ProviderKind.silo.playbackInfoIsIdempotent)
    XCTAssertEqual(
      ProviderKind.silo.metadataRichnessRank, ProviderKind.jellyfin.metadataRichnessRank)
  }

  func testPairingUsesNativeCapabilityAndDoesNotSendProfileCredentials() async throws {
    let http = SiloHTTPStub([
      "/api/v2/auth/device/capability": #"{"state":"available","protocol_versions":[2]}"#,
      "/api/v2/auth/device/start": """
      {"device_code":"private-device-secret","user_code":"ABCD","match_code":"12","verification_uri":"https://silo.test/link",
      "verification_uri_complete":"https://silo.test/link?code=ABCD","expires_in":600,"interval":5}
      """,
    ])
    let challenge = try await SiloAuthentication(baseURL: base, http: http).beginPairing(
      platform: "tvos")
    XCTAssertEqual(challenge.user_code, "ABCD")
    XCTAssertFalse(challenge.description.contains("private-device-secret"))
    let requests = await http.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests.last?.redirectPolicy, .sameOrigin)
    XCTAssertNil(requests.last?.headers["Authorization"])
    let body = try XCTUnwrap(requests.last?.body)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(fields["temporary"] as? Bool, false)
    XCTAssertEqual(fields["client_purpose"] as? String, "device_login")
  }

  func testScopedLibraryReadCarriesNativeBearerAndProfile() async throws {
    let raw = try credential().encoded()
    let http = SiloHTTPStub([
      "/api/v2/user/libraries": """
      {"items":[{"id":"movies","name":"Movies","type":"movies"},{"id":"books","name":"Books","type":"ebooks"}]}
      """
    ])
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    let libraries = try await provider.libraries()
    XCTAssertEqual(libraries.map(\.id), ["movies"])
    let requests = await http.requests
    XCTAssertEqual(requests.first?.headers["Authorization"], "Bearer access-secret")
    XCTAssertEqual(requests.first?.headers["X-Profile-Id"], "profile1")
    XCTAssertFalse(provider.capabilities.contains(.music))
    XCTAssertTrue(provider.capabilities.contains(.remoteSubtitles))
  }

  func testConcurrentExpiredCredentialRefreshesOnlyOnce() async throws {
    var credential = try credential()
    credential.expiresAt = .distantPast
    let raw = try credential.encoded()
    let store = SiloCredentialStub(raw)
    let http = SiloHTTPStub([
      "/api/v2/auth/refresh":
        #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#,
      "/api/v2/user/libraries": #"{"items":[]}"#,
    ])
    let provider = try SiloProvider(context: context(raw), credentials: store, http: http)
    async let first = provider.libraries()
    async let second = provider.libraries()
    _ = try await (first, second)
    let requests = await http.requests
    XCTAssertEqual(requests.filter { $0.path == "/api/v2/auth/refresh" }.count, 1)
    XCTAssertTrue(
      requests.filter { $0.path == "/api/v2/user/libraries" }.allSatisfy {
        $0.headers["Authorization"] == "Bearer new-access"
      })
    let updated = try SiloCredential.decode(
      store.credential(accountID: "", revision: CredentialRevision()))
    XCTAssertEqual(updated.loginID, credential.loginID)
    XCTAssertEqual(updated.refreshToken, "new-refresh")
  }

  func testRemovedLoginCannotReuseInMemoryBearer() async throws {
    let raw = try credential().encoded()
    let store = SiloCredentialStub(raw)
    let http = SiloHTTPStub(["/api/v2/user/libraries": #"{"items":[]}"#])
    let provider = try SiloProvider(context: context(raw), credentials: store, http: http)
    store.remove()
    do {
      _ = try await provider.libraries()
      XCTFail("Removed credentials must not authorize requests")
    } catch {
      XCTAssertEqual(error as? AppError, .unauthorized)
    }
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testCatalogUsesNativeSeekAndRetainsProviderIdentity() async throws {
    let raw = try credential().encoded()
    let http = SiloHTTPStub([
      "/api/v2/catalog": """
      {"items":[{"content_id":"movie-tmdb-9799","type":"movie","title":"Example","runtime":100}],
      "total":301,"total_exact":true,"window_cursor":"window"}
      """
    ])
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    let page = try await provider.items(
      in: "library1", kind: .movie, page: .init(startIndex: 240, limit: 60))
    XCTAssertEqual(page.startIndex, 240)
    XCTAssertEqual(page.totalCount, 301)
    XCTAssertEqual(page.items.first?.id, "movie-tmdb-9799")
    XCTAssertEqual(page.items.first?.providerID(.tmdb), "9799")
    XCTAssertEqual(page.items.first?.runtime, 6000)
    XCTAssertEqual(page.items.first?.libraryID, "library1")
    let requests = await http.requests
    XCTAssertTrue(
      requests.first?.queryItems.contains(URLQueryItem(name: "seek", value: "240")) == true)
  }

  func testPartialCatalogIdentityHydratesForTMDBWatchlistOwnership() async throws {
    let raw = try credential().encoded()
    let http = SiloHTTPStub([
      "/api/v2/catalog": """
      {"items":[{"content_id":"series-tvdb-420600","type":"series",
      "title":"Star Wars: Skeleton Crew","year":2024}],
      "total":1,"total_exact":true,"window_cursor":"window"}
      """,
      "/api/v2/catalog/items/series-tvdb-420600": """
      {"content_id":"series-tvdb-420600","type":"series","title":"Star Wars: Skeleton Crew",
      "year":2024,"tmdb_id":"202879","tvdb_id":"420600","imdb_id":"tt20600980"}
      """,
    ])
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    let page = try await provider.items(in: "shows", kind: .series, page: .init(limit: 200))
    XCTAssertEqual(page.items.first?.providerID(.tvdb), "420600")
    XCTAssertNil(page.items.first?.providerID(.tmdb))
    let prepared = await IdentityEnrichment.prepare(
      page.items, enrichIdentifiedItems: provider.catalogIdentityRequiresEnrichment
    ) { item in
      try? await provider.item(id: item.id)
    }
    XCTAssertFalse(prepared.inconclusive)
    let index = IdentityIndex()
    await index.ingest(
      prepared.indexable, accountID: provider.accountID,
      serverInfo: SourceServerInfo(providerKind: .silo))
    let snapshot = await index.snapshot()
    let watchlisted = MediaItem(
      id: "tmdb:series:202879", title: "Star Wars: Skeleton Crew", kind: .series,
      productionYear: 2024, providerIDs: ["Tmdb": "202879"], availability: .unknown)
    let owned = try XCTUnwrap(
      watchlisted.retargetedToOwnedLibraryCopy(
        indexedSources: { snapshot.sourceRefs(for: $0) }, capabilities: .default))
    XCTAssertEqual(owned.id, "series-tvdb-420600")
    XCTAssertEqual(owned.sourceAccountID, provider.accountID)
    XCTAssertTrue(owned.locallyValidatedPlayableSource)
    XCTAssertFalse(owned.isNotInLibraryDiscovery)
    var unrelated = watchlisted
    unrelated.providerIDs = ["Tmdb": "999999"]
    XCTAssertTrue(
      snapshot.sourceRefs(for: unrelated).isEmpty, "A matching title is not ownership evidence")
  }

  func testProtocolThreePlaybackWorksWithoutOptionalFixedFileExtension() async throws {
    let raw = try credential().encoded()
    var responses = playbackResponses()
    responses["/api/v2/playback/capabilities"] = responses["/api/v2/playback/capabilities"]?
      .replacingOccurrences(
        of: #""features":["fixed_media_file_v1"]"#, with: #""features":["playback_plan_v3"]"#)
    let http = SiloHTTPStub(responses)
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    let request = try await provider.playbackInfo(for: "movie:1")
    XCTAssertEqual(request.playSessionID, "session1")
    let requests = await http.requests
    let sent = try XCTUnwrap(requests.first { $0.path == "/api/v2/playback/start" }?.body)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
    XCTAssertNil(body["allow_alternate_versions"])
  }

  func testOlderServerCannotSubstituteAnUnrequestedVersion() async throws {
    let raw = try credential().encoded()
    var responses = playbackResponses()
    responses["/api/v2/playback/capabilities"] = responses["/api/v2/playback/capabilities"]?
      .replacingOccurrences(
        of: #""features":["fixed_media_file_v1"]"#, with: #""features":["playback_plan_v3"]"#)
    responses["/api/v2/playback/start"] = responses["/api/v2/playback/start"]?
      .replacingOccurrences(
        of: #""effective_media_file_id":"42""#, with: #""effective_media_file_id":"43""#)
    let http = SiloHTTPStub(responses)
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    do {
      _ = try await provider.playbackInfo(for: "movie:1")
      XCTFail("A different returned file must not play")
    } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
    let requests = await http.requests
    XCTAssertTrue(
      requests.contains { $0.method == .delete && $0.path == "/api/v2/playback/session1" })
  }

  func testExplicitItemMetadataWinsOverEncodedCatalogAnchor() async throws {
    let raw = try credential().encoded()
    let http = SiloHTTPStub([
      "/api/v2/catalog/items/movie-tmdb-9799":
        #"{"content_id":"movie-tmdb-9799","type":"movie","title":"Example","tmdb_id":"1234"}"#
    ])
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    let item = try await provider.item(id: "movie-tmdb-9799")
    XCTAssertEqual(item.providerID(.tmdb), "1234")
  }

  func testMalformedPathIsRejected() {
    for value in ["", "..", "a/b", "a\\b", "a\nb"] {
      XCTAssertThrowsError(try SiloAPI.pathComponent(value))
    }
    XCTAssertEqual(try SiloAPI.pathComponent("movie:1"), "movie:1")
  }

  func testMediaBearerPreservesSignatureAndNeverLeavesIssuedOriginAndSession() async throws {
    let raw = try credential().encoded()
    let client = try SiloClient(
      context: context(raw), store: SiloCredentialStub(raw), http: SiloHTTPStub([:]))
    let original = URL(
      string: "https://silo.test/base/api/v2/stream/session1?st=a%2Bb%2Fc%3D&token=stale&x=1")!
    let resolved = try await client.authorizedMediaURL(original, sessionID: "session1")
    let query = try XCTUnwrap(
      URLComponents(url: resolved, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
    XCTAssertTrue(query.contains("st=a%2Bb%2Fc%3D"))
    XCTAssertTrue(query.contains("token=access-secret"))
    XCTAssertFalse(query.contains("stale"))
    for resource in ["master.m3u8", "video/index.m3u8", "video/init.mp4", "video/segment1.m4s"] {
      let hls = URL(
        string: "https://silo.test/base/api/v2/playback/transcode/session1/\(resource)?st=a%2Bb%2Fc%3D&token=stale")!
      let authorized = try await client.authorizedMediaURL(hls, sessionID: "session1")
      XCTAssertEqual(authorized.path, hls.path)
      let hlsQuery = try XCTUnwrap(
        URLComponents(url: authorized, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
      XCTAssertTrue(hlsQuery.contains("st=a%2Bb%2Fc%3D"))
      XCTAssertTrue(hlsQuery.contains("token=access-secret"))
      XCTAssertFalse(hlsQuery.contains("stale"))
    }
    for path in ["stream/session1", "playback/transcode/session1/master.m3u8"] {
      let foreign = URL(string: "https://node.test/\(path)?st=node-grant")!
      let delegated = try await client.authorizedMediaURL(foreign, sessionID: "session1")
      XCTAssertEqual(delegated, foreign)
    }
    for path in [
      "/api/v2/stream/other-session", "/api/v2/stream/session1suffix", "/api/v2/auth/login",
      "/api/v2/playback/transcode/other-session/master.m3u8",
      "/api/v2/playback/transcode/session1suffix/master.m3u8",
    ] {
      do {
        _ = try await client.authorizedMediaURL(
          URL(string: "https://silo.test/base" + path)!, sessionID: "session1")
        XCTFail("Account bearer must not authorize an unrelated resource")
      } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
    }
  }

  func testPlaybackAdvertisesSoftwareDecodeWithoutClaimingHardwareOrHLS() throws {
    let body = SiloPlaybackStart(
      installation_id: "instance", file_id: "file1", profile_id: "profile1",
      capabilities: .init(supportsHEVC: false, supportsAV1: false), forceTranscode: false)
    let encoded = try JSONEncoder().encode(body)
    let data = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let codecs = try XCTUnwrap(data["client_capabilities"] as? [String: Any])
    let context = try XCTUnwrap(data["client_playback_context"] as? [String: Any])
    let deliveries = try XCTUnwrap(context["deliveries"] as? [String: [String: Any]])
    let original = try XCTUnwrap(deliveries["original_http"]?["video_codecs"] as? [String])
    XCTAssertEqual(codecs["codecs_video"] as? [String], MediaCapabilities.plozzigenVideoCodecs)
    for codec in ["vp9", "vp8", "av1", "hevc", "mpeg4", "mpeg2video", "vc1"] {
      XCTAssertTrue(original.contains(codec))
    }
    XCTAssertEqual(codecs["codecs_video_hardware"] as? [String], ["h264"])
    XCTAssertEqual(deliveries["hls"]?["video_codecs"] as? [String], ["h264"])
  }

  func testResumeWriteCarriesRFC3339TimezoneAndOriginalEventTime() async throws {
    let raw = try credential().encoded()
    let http = SiloHTTPStub([
      "/api/v2/sync/progress":
        #"{"items":[{"media_item_id":"movie:1","status":"success","index":0}]}"#
    ])
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    try await provider.setResumePosition(
      42.125, itemID: "movie:1", capturedAt: Date(timeIntervalSince1970: 1767323045.25))
    let requests = await http.requests
    let data = try XCTUnwrap(requests.first?.body)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let item = try XCTUnwrap((object["items"] as? [[String: Any]])?.first)
    XCTAssertEqual(item["position_ms"] as? Int64, 42125)
    XCTAssertEqual(item["updated_at"] as? String, "2026-01-02T03:04:05.250Z")
  }

  func testEpisodeBadgesUseFileSummaryWhenDetailedTracksAreMissing() async throws {
    let raw = try credential().encoded()
    let http = SiloHTTPStub([
      "/api/v2/catalog/items/episode-tvdb-353367-1-1": """
      {"content_id":"episode-tvdb-353367-1-1","type":"episode","title":"Episode",
       "versions":[{"file_id":"vp9-file","resolution":"1080p","hdr":false,
       "codec_video":"vp9","codec_audio":"aac","container":"mkv",
       "file_size":100,"duration":2100,"bitrate":2000}]}
      """
    ])
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    let item = try await provider.item(id: "episode-tvdb-353367-1-1")
    XCTAssertEqual(item.mediaInfo?.video?.height, 1080)
    XCTAssertNil(item.mediaInfo?.video?.width, "A resolution tier does not supply the actual width")
    XCTAssertEqual(item.mediaInfo?.video?.videoRange, "SDR")
    XCTAssertEqual(item.technicalBadges.map(\.label), ["1080p", "SDR"])
    XCTAssertEqual(item.versions.first?.technicalBadges, item.technicalBadges)
    XCTAssertTrue(
      item.mediaInfo?.audioBadges.isEmpty == true, "Unknown channel count must not invent surround")
  }

  func testDownloadStatusCarriesRFC3339TimezoneAndOriginalEventTime() async throws {
    let raw = try credential().encoded()
    let http = SiloHTTPStub(["PATCH /api/v2/downloads/download1": downloadEntry])
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    try await provider.reportDownload(
      .init(id: "download1", revision: 2), status: "completed",
      at: Date(timeIntervalSince1970: 1767323045.25))
    let requests = await http.requests
    let data = try XCTUnwrap(requests.first?.body)
    let item = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(item["updated_at"] as? String, "2026-01-02T03:04:05.250Z")
    XCTAssertEqual(item["revision"] as? Int, 2)
  }

  func testEpisodeBadgesKeepDetailedHDRAndAudioFactsPerVersion() async throws {
    let raw = try credential().encoded()
    let http = SiloHTTPStub([
      "/api/v2/catalog/items/episode-tvdb-353367-1-1": """
      {"content_id":"episode-tvdb-353367-1-1","type":"episode","title":"Episode",
       "versions":[{"file_id":"hdr-file","resolution":"1080p","hdr":true,
       "codec_video":"hevc","codec_audio":"eac3","container":"mkv",
       "file_size":100,"duration":2100,"bitrate":12000,
       "video_tracks":[{"width":3840,"height":2160,"video_range_type":"HDR10"}],
       "audio_tracks":[{"codec":"eac3","channels":6,"layout":"5.1","default":true}]}]}
      """
    ])
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    let item = try await provider.item(id: "episode-tvdb-353367-1-1")
    XCTAssertEqual(
      item.mediaInfo?.video?.height, 2160, "Detailed track dimensions outrank summary labels")
    XCTAssertTrue(item.technicalBadges.map(\.label).contains("HDR10"))
    XCTAssertTrue(item.technicalBadges.map(\.label).contains("4K"))
    XCTAssertTrue(item.technicalBadges.map(\.accessibilityText).contains("Dolby Digital+ 5.1"))
    XCTAssertEqual(item.versions.first?.technicalBadges, item.technicalBadges)
  }

  func testPlaybackClaimsDoNotInventHeaderRefreshOrHDR10PlusOutput() throws {
    let body = SiloPlaybackStart(
      installation_id: "instance", file_id: "file1", profile_id: "profile1",
      capabilities: .default, forceTranscode: false)
    let encoded = try JSONEncoder().encode(body)
    let data = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(data["protocol_version"] as? Int, 3)
    XCTAssertEqual(data["allow_alternate_versions"] as? Bool, false)
    XCTAssertEqual(data["start_position"] as? Int, 0)
    XCTAssertFalse(
      String(decoding: encoded, as: UTF8.self).contains("header_authenticated_media_v1"))
    XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"hdr10_plus\":false"))
  }
}
