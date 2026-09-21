import CoreModels
import CoreNetworking
import Foundation
import XCTest

@testable import ProviderSilo

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private actor SiloHTTPStub: HTTPClient {
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
  private func playbackResponses() -> [String: String] {
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
    XCTAssertEqual(request.startPosition, 125)
    XCTAssertEqual(request.sourceMetadata?.video?.videoRangeType, "HDR10Plus")
    XCTAssertNil(request.streamURL)
    guard case .authenticatedHTTP(let locator) = request.playbackSource else {
      return XCTFail("Missing grant")
    }
    XCTAssertFalse(locator.resource.path.contains("stream-secret"))
    let url = try await provider.resolveHTTPResource(locator)
    XCTAssertTrue(url.absoluteString.contains("st=stream-secret"))
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

private final class SiloCredentialStub: RotatingCredentialStoring, @unchecked Sendable {
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

  private func credential() throws -> SiloCredential {
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

  private func context(_ token: String) -> ProviderResolutionContext {
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
    XCTAssertFalse(provider.capabilities.contains(.remoteSubtitles))
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
      {"items":[{"content_id":"movie:1","type":"movie","title":"Example","runtime":100}],
      "total":301,"total_exact":true,"window_cursor":"window"}
      """
    ])
    let provider = try SiloProvider(
      context: context(raw), credentials: SiloCredentialStub(raw), http: http)
    let page = try await provider.items(
      in: "library1", kind: .movie, page: .init(startIndex: 240, limit: 60))
    XCTAssertEqual(page.startIndex, 240)
    XCTAssertEqual(page.totalCount, 301)
    XCTAssertEqual(page.items.first?.id, "movie:1")
    XCTAssertEqual(page.items.first?.runtime, 6000)
    XCTAssertEqual(page.items.first?.libraryID, "library1")
    let requests = await http.requests
    XCTAssertTrue(
      requests.first?.queryItems.contains(URLQueryItem(name: "seek", value: "240")) == true)
  }

  func testMalformedPathIsRejected() {
    for value in ["", "..", "a/b", "a\\b", "a\nb"] {
      XCTAssertThrowsError(try SiloAPI.pathComponent(value))
    }
    XCTAssertEqual(try SiloAPI.pathComponent("movie:1"), "movie:1")
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
