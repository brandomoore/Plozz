import CoreModels
import Foundation
import MediaTransportCore
@testable import MediaTransportHTTP
@testable import MediaTransportWebDAV
@testable import TestSupportNetworking
@testable import TestSupportPerformance
import XCTest

private actor WebDAVPreparationGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// Hermetic coverage for the WebDAV media-transport adapter, driving the full
/// request/response path through a stub `URLProtocol` (no real network). Trust
/// pinning against a live TLS handshake is covered at the primitive level
/// (`TransportTrustTests`, `TransportSessionDelegateTests`); here we exercise
/// the adapter's composition, mapping, path handling, and ETag revalidation.
final class WebDAVMediaTransportTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeAdapter(
        scheme: WebDAVScheme = .https,
        credential: WebDAVCredential = .anonymous,
        trustPolicy: TrustPolicy = .system
    ) -> WebDAVMediaTransportAdapter {
        WebDAVMediaTransportAdapter(
            scheme: scheme,
            configurationProvider: { _, _ in
                WebDAVMediaTransportConfiguration(credential: credential, trustPolicy: trustPolicy)
            },
            registryFactory: { TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self]) }
        )
    }

    private func makeKey(
        scheme: String = "https",
        host: String = "nas.example.com",
        rootPath: String = "/dav/movies",
        revision: CredentialRevision = CredentialRevision(),
        trustRevision: UUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
        role: MediaTransportRole = .scanner
    ) throws -> MediaTransportSessionKey {
        MediaTransportSessionKey(
            accountID: "account",
            credentialRevision: revision,
            endpoint: try MediaTransportEndpointIdentity(
                transportIdentifier: scheme,
                host: host,
                rootPath: rootPath
            ),
            trustRevision: trustRevision,
            role: role
        )
    }

    // MARK: - connect guard

    func testConnectRejectsMismatchedTransportIdentifier() async throws {
        let adapter = makeAdapter(scheme: .https)
        do {
            _ = try await adapter.connect(for: try makeKey(scheme: "smb", host: "nas.local", rootPath: "/Media"))
            XCTFail("expected unsupportedCapability")
        } catch let error as MediaTransportError {
            guard case .unsupportedCapability = error else {
                return XCTFail("expected unsupportedCapability, got \(error)")
            }
        }
    }

    // MARK: - validate

    func testValidateProvesCollectionWithoutOptionsOrDAVHeader() async throws {
        let request = LockedValue<URLRequest?>(nil)
        let xml = """
        <multistatus xmlns="DAV:"><response>
          <href>/dav/movies/</href>
          <propstat><prop><resourcetype><collection/></resourcetype></prop>
          <status>HTTP/1.1 200 OK</status></propstat>
        </response></multistatus>
        """
        StubURLProtocol.queue(
            StubResponse(statusCode: 207, body: Data(xml.utf8), onRequest: { request.set($0) }),
            for: URL(string: "https://nas.example.com/dav/movies")!
        )
        let session = try await makeAdapter().connect(for: try makeKey())
        try await session.fileSystem.validate()
        XCTAssertEqual(request.get()?.httpMethod, "PROPFIND")
        XCTAssertEqual(request.get()?.value(forHTTPHeaderField: "Depth"), "0")
        await session.shutdown()
    }

    func testValidateRejectsPlainHTTPResponseEvenWithDAVHeader() async throws {
        StubURLProtocol.queue(
            StubResponse(statusCode: 200, headers: ["DAV": "1,2"], body: Data("<html/>".utf8)),
            for: URL(string: "https://nas.example.com/dav/movies")!
        )
        let session = try await makeAdapter().connect(for: try makeKey())
        do {
            try await session.fileSystem.validate()
            XCTFail("expected protocolViolation")
        } catch let error as MediaTransportError {
            guard case .protocolViolation = error else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
        await session.shutdown()
    }

    func testValidateRejectsFileRoot() async throws {
        let xml = """
        <multistatus xmlns="DAV:"><response>
          <href>/dav/movies</href>
          <propstat><prop><resourcetype/></prop>
          <status>HTTP/1.1 200 OK</status></propstat>
        </response></multistatus>
        """
        StubURLProtocol.queue(
            StubResponse(statusCode: 207, body: Data(xml.utf8)),
            for: URL(string: "https://nas.example.com/dav/movies")!
        )
        let session = try await makeAdapter().connect(for: try makeKey())
        do {
            try await session.fileSystem.validate()
            XCTFail("expected protocolViolation")
        } catch let error as MediaTransportError {
            guard case .protocolViolation = error else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
        await session.shutdown()
    }

    // MARK: - list

    func testListMapsChildrenToRootRelativeEntries() async throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/</D:href>
            <D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/movies/Show/</D:href>
            <D:propstat>
              <D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/movies/Movie.mkv</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>2048</D:getcontentlength>
                <D:getetag>"strong-1"</D:getetag>
                <D:getcontenttype>video/x-matroska</D:getcontenttype>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        StubURLProtocol.queue(
            StubResponse(statusCode: 207, body: Data(xml.utf8)),
            for: URL(string: "https://nas.example.com/dav/movies")!
        )
        let session = try await makeAdapter().connect(for: try makeKey())
        let entries = try await session.fileSystem.list(relativePath: "")

        XCTAssertEqual(entries.map(\.relativePath), ["Show", "Movie.mkv"])
        XCTAssertEqual(entries.map(\.kind), [.directory, .file])
        let file = try XCTUnwrap(entries.first { $0.kind == .file })
        XCTAssertEqual(file.size, 2048)
        XCTAssertEqual(file.strongETag, "\"strong-1\"")
        XCTAssertEqual(file.mimeType, "video/x-matroska")
    }

    func testListDropsWeakETagButStillListsFile() async throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/Weak.mkv</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>10</D:getcontentlength>
                <D:getetag>W/"weak-1"</D:getetag>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        StubURLProtocol.queue(
            StubResponse(statusCode: 207, body: Data(xml.utf8)),
            for: URL(string: "https://nas.example.com/dav/movies")!
        )
        let session = try await makeAdapter().connect(for: try makeKey())
        let entries = try await session.fileSystem.list(relativePath: "")
        XCTAssertEqual(entries.map(\.relativePath), ["Weak.mkv"])
        XCTAssertNil(entries.first?.strongETag, "a weak ETag must not be stored as a strong validator")
    }

    // MARK: - stat

    func testStatReturnsFileEntry() async throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/movies/Movie.mkv</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>4096</D:getcontentlength>
                <D:getetag>"strong-2"</D:getetag>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        StubURLProtocol.queue(
            StubResponse(statusCode: 207, body: Data(xml.utf8)),
            for: URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        )
        let session = try await makeAdapter().connect(for: try makeKey())
        let entry = try await session.fileSystem.stat(relativePath: "Movie.mkv")
        XCTAssertEqual(entry.relativePath, "Movie.mkv")
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.size, 4096)
        XCTAssertEqual(entry.strongETag, "\"strong-2\"")
    }

    // MARK: - readSmallFile

    func testReadSmallFileReturnsBoundedBody() async throws {
        let payload = Data("<movie/>".utf8)
        StubURLProtocol.queue(
            StubResponse(statusCode: 200, headers: ["Content-Length": "\(payload.count)"], body: payload),
            for: URL(string: "https://nas.example.com/dav/movies/movie.nfo")!
        )
        let session = try await makeAdapter().connect(for: try makeKey())
        let data = try await session.fileSystem.readSmallFile(relativePath: "movie.nfo", maximumBytes: 4096)
        XCTAssertEqual(data, payload)
    }

    // MARK: - openSource

    private func strongETagLocator(
        relativePath: String = "Movie.mkv",
        etag: String = "\"strong-1\"",
        size: Int64 = 1000,
        revision: CredentialRevision
    ) throws -> NetworkFileLocator {
        try NetworkFileLocator(
            accountID: "account",
            sourceID: "account",
            credentialRevision: revision,
            relativePath: relativePath,
            representation: try RemoteFileRepresentation(
                size: size,
                identity: try RemoteFileIdentity(kind: .strongETag, value: etag),
                consistency: .changeDetecting
            )
        )
    }

    func testOpenSourceRejectsNonRevalidatableRepresentation() async throws {
        let revision = CredentialRevision()
        let session = try await makeAdapter().connect(for: try makeKey(revision: revision, role: .playback))
        let locator = try NetworkFileLocator(
            accountID: "account",
            sourceID: "account",
            credentialRevision: revision,
            relativePath: "Movie.mkv",
            representation: try RemoteFileRepresentation(
                size: 10,
                identity: try RemoteFileIdentity(kind: .snapshot, value: "snapshot"),
                consistency: .changeDetecting
            )
        )
        do {
            _ = try await session.fileSystem.openSource(for: locator)
            XCTFail("expected unsupportedRange")
        } catch let error as MediaTransportError {
            guard case .unsupportedRange = error else {
                return XCTFail("expected unsupportedRange, got \(error)")
            }
        }
    }

    func testOpenSourceProbesThenReadsWithIfMatchRevalidation() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        queueStat()
        let observedIfMatch = LockedValue<String?>(nil)
        // 1) range probe: 206 + strong ETag + Content-Range 0-1/1000, 2-byte body.
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-1/1000"],
                body: Data([0x00, 0x00])
            ),
            for: url
        )
        // 2) bounded read: 206 + Content-Range 0-3/1000 + matching ETag, 4-byte body.
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-3/1000"],
                body: Data([1, 2, 3, 4]),
                onRequest: { observedIfMatch.set($0.value(forHTTPHeaderField: "If-Match")) }
            ),
            for: url
        )

        let session = try await makeAdapter().connect(for: try makeKey(revision: revision, role: .playback))
        let lease = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
        XCTAssertEqual(lease.byteSize, 1000)
        XCTAssertEqual(lease.preferredReadSize, 32 * 1024 * 1024)
        let cursor = try XCTUnwrap(lease.makeCursor())
        let bytes = try await cursor.read(at: 0, length: 4)
        XCTAssertEqual(bytes, Data([1, 2, 3, 4]))
        XCTAssertEqual(observedIfMatch.get(), "\"strong-1\"", "every read must revalidate the probed strong ETag")
    }

    func testDuplicateStrongIdentityWithConflictingDatesPreparesOpensAndReads() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let responses = ["00:00:00", "00:00:01"].map { time in
            """
            <response><href>/dav/movies/Movie.mkv</href><propstat><prop>
            <getcontentlength>1000</getcontentlength><getetag>"strong-1"</getetag>
            <getlastmodified>Mon, 01 Jan 2024 \(time) GMT</getlastmodified>
            </prop><status>HTTP/1.1 200 OK</status></propstat></response>
            """
        }.joined()
        let payload = Data("<multistatus xmlns=\"DAV:\">\(responses)</multistatus>".utf8)
        let session = try await makeAdapter().connect(for: try makeKey(revision: revision, role: .playback))
        addTeardownBlock { await session.shutdown() }
        StubURLProtocol.queue(StubResponse(statusCode: 207, body: payload), for: url)
        let file = try await session.fileSystem.statForOpening(relativePath: "Movie.mkv")
        XCTAssertEqual(file.strongETag, "\"strong-1\"")
        XCTAssertNil(file.modifiedAt)
        StubURLProtocol.queue(StubResponse(statusCode: 207, body: payload), for: url)
        StubURLProtocol.queue(StubResponse(
            statusCode: 206, headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-1/1000"],
            body: Data([0, 0])
        ), for: url)
        let lease = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
        StubURLProtocol.queue(StubResponse(
            statusCode: 206, headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-3/1000"],
            body: Data([1, 2, 3, 4]),
            onRequest: { XCTAssertEqual($0.value(forHTTPHeaderField: "If-Match"), "\"strong-1\"") }
        ), for: url)
        let cursor = try XCTUnwrap(lease.makeCursor())
        let bytes = try await cursor.read(at: 0, length: 4)
        XCTAssertEqual(bytes, Data([1, 2, 3, 4]))
    }

    func testOpenSourceDetectsETagDrift() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        queueStat()
        // Probe succeeds but returns a DIFFERENT strong ETag than the locator's.
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "\"changed\"", "Content-Range": "bytes 0-1/1000"],
                body: Data([0x00, 0x00])
            ),
            for: url
        )
        let session = try await makeAdapter().connect(for: try makeKey(revision: revision, role: .playback))
        do {
            _ = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
            XCTFail("expected sourceChanged")
        } catch let error as MediaTransportError {
            guard case .sourceChanged = error else {
                return XCTFail("expected sourceChanged, got \(error)")
            }
        }
    }

    func testLargePlaybackRangeKeepsExactBoundsAndValidator() async throws {
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let total = 64 * 1024 * 1024
        let offset = 4 * 1024 * 1024
        let length = 32 * 1024 * 1024
        let cursor = try await openLargeSource(total: total)
        queueReadHalf(url: url, offset: offset, length: length, total: total, byte: 42)
        let bytes = try await cursor.read(at: Int64(offset), length: length)
        XCTAssertEqual(bytes.count, length)
        XCTAssertTrue(bytes.prefix(length / 2).allSatisfy { $0 == 42 })
        XCTAssertTrue(bytes.suffix(length / 2).allSatisfy { $0 == 42 })
        let reads = StubURLProtocol.requests(for: url).filter {
            $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "If-Match") != nil
        }
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(Set(reads.compactMap { $0.value(forHTTPHeaderField: "Range") }), [
            "bytes=\(offset)-\(offset + length - 1)"
        ])
        XCTAssertTrue(reads.allSatisfy { $0.value(forHTTPHeaderField: "If-Match") == "\"strong-1\"" })
    }

    func testPlaybackReusesValidatedPrefixWithoutAnotherGET() async throws {
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let length = RangeProbe.initialReadByteCount
        let cursor = try await openLargeSource(total: 1_000_000)
        for (offset, count) in [(0, length), (7, 100), (length - 1, 1)] {
            let data = try await cursor.read(at: Int64(offset), length: count)
            XCTAssertEqual(data, Data(repeating: 42, count: count))
        }
        let requests = StubURLProtocol.requests(for: url).filter { $0.httpMethod == "GET" }
        XCTAssertEqual(requests.count, 1, "The validated probe is already the first media window")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Range"), "bytes=0-\(length - 1)")
        queueReadHalf(url: url, offset: length - 2, length: 4, total: 1_000_000, byte: 7)
        let crossing = try await cursor.read(at: Int64(length - 2), length: 4)
        XCTAssertEqual(crossing, Data(repeating: 7, count: 4))
        XCTAssertEqual(StubURLProtocol.requests(for: url).last?.value(forHTTPHeaderField: "If-Match"), "\"strong-1\"")
    }

    func testLargeMetadataOpenKeepsTwoByteProbe() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        queueStat(size: 1_000_000)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206, headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-1/1000000"],
                body: Data([42, 42])
            ), for: url
        )
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .metadata))
        addTeardownBlock { await session.shutdown() }
        let lease = try await session.fileSystem.openSource(
            for: strongETagLocator(size: 1_000_000, revision: revision)
        )
        XCTAssertEqual(StubURLProtocol.requests(for: url).last?.value(forHTTPHeaderField: "Range"), "bytes=0-1")
        lease.close()
        await lease.waitForFinalShutdown()
    }

    func testIncrementalOrdinaryHandoffKeepsOnlyCompletedValidatedRanges() async throws {
        for path in ["Movie.mp4", "Movie.mkv"] {
            let revision = CredentialRevision()
            let url = URL(string: "https://nas.example.com/dav/movies/\(path)")!
            let total = 20 * 1024 * 1024
            let first = RangeProbe.initialReadByteCount
            let chunk = 1024 * 1024
            let pending = expectation(description: "Next complete HTTP range pending")
            queueStat(size: total, relativePath: path)
            queueReadHalf(url: url, offset: 0, length: first, total: total)
            queueReadHalf(url: url, offset: first, length: chunk, total: total, byte: 7)
            queueReadHalf(
                url: url, offset: first + chunk, length: chunk, total: total, byte: 8,
                delay: .seconds(60), onRequest: { _ in pending.fulfill() }
            )
            let key = try makeKey(revision: revision, role: .playback)
            let registry = MediaTransportResolverRegistry(adapter: makeAdapter())
            let resolver = MediaTransportNetworkFileResolver(registry: registry, sessionKeyProvider: { _ in key })
            addTeardownBlock { await registry.retire(accountID: key.accountID, credentialRevision: revision) }
            let locator = try strongETagLocator(relativePath: path, size: Int64(total), revision: revision)
            let handle = try resolver.beginPreparation(locator)
            await fulfillment(of: [pending], timeout: 2)
            XCTAssertNil(handle.warmupOutcome)
            handle.requestPlaybackHandoff()
            try await handle.waitUntilReady()
            XCTAssertEqual(handle.warmupOutcome, .interruptedForPlayback)
            queueStat(size: total, relativePath: path)
            let played = try await resolver.resolve(locator)
            XCTAssertTrue(played.wasPrepared)
            XCTAssertTrue(handle.wasConsumed)
            let cursor = try XCTUnwrap(played.sourceLease.makeCursor())
            let head = try await cursor.read(at: Int64(first), length: 1_000)
            XCTAssertEqual(head, Data(repeating: 7, count: 1_000))
            let boundary = try await cursor.read(at: Int64(first + chunk - 16), length: 32)
            XCTAssertEqual(boundary, Data(repeating: 7, count: 16))
            for _ in 0..<2 {
                queueReadHalf(url: url, offset: first + chunk, length: 100, total: total, byte: 9)
                let bytes = try await cursor.read(at: Int64(first + chunk), length: 100)
                XCTAssertEqual(bytes, Data(repeating: 9, count: 100))
            }
            let gets = StubURLProtocol.requests(for: url).filter { $0.httpMethod == "GET" }
            XCTAssertEqual(gets.count, 5, "The cancelled response is absent; sealed playback reads do not grow the cache")
            XCTAssertTrue(gets.dropFirst().allSatisfy {
                $0.value(forHTTPHeaderField: "If-Match") == "\"strong-1\""
            })
            XCTAssertEqual(StubURLProtocol.requests(for: url).filter { $0.httpMethod == "PROPFIND" }.count, 2)
            cursor.close()
            await played.waitForFinalShutdown()
        }
    }

    func testIncrementalMalformedResponseCannotPublishOrBecomeColdSuccess() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let total = 20 * 1024 * 1024
        let first = RangeProbe.initialReadByteCount
        let chunk = 1024 * 1024
        queueStat(size: total)
        queueReadHalf(url: url, offset: 0, length: first, total: total)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes \(first)-\(first + chunk - 1)/\(total)"],
                body: Data(repeating: 7, count: chunk - 1)
            ), for: url
        )
        let key = try makeKey(revision: revision, role: .playback)
        let registry = MediaTransportResolverRegistry(adapter: makeAdapter())
        let resolver = MediaTransportNetworkFileResolver(registry: registry, sessionKeyProvider: { _ in key })
        addTeardownBlock { await registry.retire(accountID: key.accountID, credentialRevision: revision) }
        let locator = try strongETagLocator(size: Int64(total), revision: revision)
        let handle = try resolver.beginPreparation(locator)
        var observed: MediaTransportError?
        do {
            try await handle.waitUntilReady()
            XCTFail("An incomplete HTTP response cannot become a prepared range")
        } catch let error as MediaTransportError {
            observed = error
            guard case .sourceChanged = error else { return XCTFail("\(error)") }
        }
        handle.requestPlaybackHandoff()
        do { _ = try await resolver.resolve(locator); XCTFail("Failed warmup silently opened cold") }
        catch let error as MediaTransportError { XCTAssertEqual(error, observed) }
        XCTAssertFalse(handle.wasConsumed)
        XCTAssertNil(handle.warmupOutcome)
        XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND", "GET", "GET"])
    }

    func testIncrementalDiscWarmsDiscoveredRangesWithoutBlindPrefixOrTail() async throws {
        let revision = CredentialRevision()
        let path = "Movie.iso"
        let url = URL(string: "https://nas.example.com/dav/movies/\(path)")!
        let total = 20 * 1024 * 1024
        let offset = 9 * 1024 * 1024
        let gate = WebDAVPreparationGate()
        let warmed = expectation(description: "Discovered disc range fully validated")
        queueStat(size: total, relativePath: path)
        queueReadHalf(url: url, offset: 0, length: RangeProbe.initialReadByteCount, total: total)
        queueReadHalf(url: url, offset: offset, length: 100, total: total, byte: 7)
        let key = try makeKey(revision: revision, role: .playback)
        let registry = MediaTransportResolverRegistry(adapter: makeAdapter())
        let resolver = MediaTransportNetworkFileResolver(
            registry: registry,
            sourcePreparer: { _, position, source in
                XCTAssertEqual(position, 600)
                let data = try await source.read(at: Int64(offset), length: 100)
                XCTAssertEqual(data, Data(repeating: 7, count: 100))
                warmed.fulfill()
                await gate.wait()
                try Task.checkCancellation()
            },
            sessionKeyProvider: { _ in key }
        )
        addTeardownBlock { await registry.retire(accountID: key.accountID, credentialRevision: revision) }
        let locator = try strongETagLocator(relativePath: path, size: Int64(total), revision: revision)
        let handle = try resolver.beginPreparation(locator, startPosition: 600)
        await fulfillment(of: [warmed], timeout: 2)
        handle.requestPlaybackHandoff()
        await gate.open()
        try await handle.waitUntilReady()
        queueStat(size: total, relativePath: path)
        let played = try await resolver.resolve(locator)
        let cursor = try XCTUnwrap(played.sourceLease.makeCursor())
        let bytes = try await cursor.read(at: Int64(offset), length: 100)
        XCTAssertEqual(bytes, Data(repeating: 7, count: 100))
        XCTAssertEqual(handle.warmupOutcome, .interruptedForPlayback)
        XCTAssertTrue(handle.wasConsumed)
        XCTAssertEqual(StubURLProtocol.requests(for: url).filter { $0.httpMethod == "GET" }.count, 2)
        cursor.close()
        await played.waitForFinalShutdown()
    }

    func testIncrementalSmallOrdinarySourceCanFinishWarmingWithoutHandoff() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        queueStat()
        queueReadHalf(url: url, offset: 0, length: 2, total: 1_000)
        queueReadHalf(url: url, offset: 0, length: 1_000, total: 1_000)
        let key = try makeKey(revision: revision, role: .playback)
        let registry = MediaTransportResolverRegistry(adapter: makeAdapter())
        let resolver = MediaTransportNetworkFileResolver(registry: registry, sessionKeyProvider: { _ in key })
        addTeardownBlock { await registry.retire(accountID: key.accountID, credentialRevision: revision) }
        let locator = try strongETagLocator(revision: revision)
        let handle = try resolver.beginPreparation(locator)
        try await handle.waitUntilReady()
        XCTAssertEqual(handle.warmupOutcome, .completed)
        queueStat()
        let played = try await resolver.resolve(locator)
        let cursor = try XCTUnwrap(played.sourceLease.makeCursor())
        let bytes = try await cursor.read(at: 900, length: 200)
        XCTAssertEqual(bytes.count, 100)
        XCTAssertEqual(StubURLProtocol.requests(for: url).filter { $0.httpMethod == "GET" }.count, 2)
        cursor.close()
        await played.waitForFinalShutdown()
    }

    func testIncrementalHandoffStillRejectsChangedDAVIdentity() async throws {
        let revision = CredentialRevision()
        let path = "Movie.iso"
        let url = URL(string: "https://nas.example.com/dav/movies/\(path)")!
        let total = 20 * 1024 * 1024
        queueStat(size: total, relativePath: path)
        queueReadHalf(url: url, offset: 0, length: RangeProbe.initialReadByteCount, total: total)
        let key = try makeKey(revision: revision, role: .playback)
        let registry = MediaTransportResolverRegistry(adapter: makeAdapter())
        let resolver = MediaTransportNetworkFileResolver(registry: registry, sessionKeyProvider: { _ in key })
        addTeardownBlock { await registry.retire(accountID: key.accountID, credentialRevision: revision) }
        let locator = try strongETagLocator(relativePath: path, size: Int64(total), revision: revision)
        let handle = try resolver.beginPreparation(locator)
        try await handle.waitUntilReady()
        handle.requestPlaybackHandoff()
        queueStat(etag: "\"changed\"", size: total, relativePath: path)
        do { _ = try await resolver.resolve(locator); XCTFail("Handoff bypassed current DAV identity") }
        catch let error as MediaTransportError {
            guard case .sourceChanged = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(handle.wasConsumed)
        XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND", "GET", "PROPFIND"])
    }

    func testPreparedSourceRetainsOnlyBoundedValidatedOpeningRanges() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let window = 8 * 1024 * 1024
        let tailWindow = 4 * 1024 * 1024
        let total = 20 * 1024 * 1024
        queueStat(size: total)
        queueReadHalf(url: url, offset: 0, length: RangeProbe.initialReadByteCount, total: total)
        queueReadHalf(
            url: url, offset: RangeProbe.initialReadByteCount,
            length: window - RangeProbe.initialReadByteCount, total: total
        )
        queueReadHalf(url: url, offset: total - tailWindow, length: tailWindow, total: total, byte: 7)
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        addTeardownBlock { await session.shutdown() }
        let fileSystem = try XCTUnwrap(session.fileSystem as? WebDAVMediaTransportFileSystem)
        let locator = try strongETagLocator(size: Int64(total), revision: revision)
        let lease = try await fileSystem.prepareSource(for: locator)
        let cursor = try XCTUnwrap(lease.makeCursor())
        addTeardownBlock {
            cursor.close()
            await lease.waitForFinalShutdown()
        }

        queueStat(size: total)
        try await fileSystem.revalidatePreparedSource(for: locator)
        let head = try await cursor.read(at: 300_000, length: 1_000)
        XCTAssertEqual(head, Data(repeating: 42, count: 1_000))
        let tail = try await cursor.read(at: Int64(total - 2_000), length: 1_000)
        XCTAssertEqual(tail, Data(repeating: 7, count: 1_000))
        let boundary = try await cursor.read(at: Int64(window - 100), length: 200)
        XCTAssertEqual(boundary, Data(repeating: 42, count: 100))
        let reads = StubURLProtocol.requests(for: url).filter { $0.httpMethod == "GET" }
        XCTAssertEqual(reads.count, 3)
        XCTAssertEqual(reads.dropFirst().compactMap { $0.value(forHTTPHeaderField: "Range") }, [
            "bytes=\(RangeProbe.initialReadByteCount)-\(window - 1)", "bytes=\(total - tailWindow)-\(total - 1)"
        ])
        XCTAssertTrue(reads.dropFirst().allSatisfy {
            $0.value(forHTTPHeaderField: "If-Match") == "\"strong-1\""
        })
        XCTAssertEqual(StubURLProtocol.requests(for: url).filter { $0.httpMethod == "PROPFIND" }.count, 2)

        queueReadHalf(url: url, offset: window, length: 100, total: total, byte: 8)
        let uncached = try await cursor.read(at: Int64(window), length: 100)
        XCTAssertEqual(uncached, Data(repeating: 8, count: 100))
        XCTAssertEqual(StubURLProtocol.requests(for: url).last?.value(forHTTPHeaderField: "If-Match"), "\"strong-1\"")
    }

    func testPreparedSmallSourceClampsAtEOFWithoutDuplicateTail() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        queueStat()
        queueReadHalf(url: url, offset: 0, length: 2, total: 1_000)
        queueReadHalf(url: url, offset: 0, length: 1_000, total: 1_000)
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        addTeardownBlock { await session.shutdown() }
        let fileSystem = try XCTUnwrap(session.fileSystem as? WebDAVMediaTransportFileSystem)
        let lease = try await fileSystem.prepareSource(for: strongETagLocator(revision: revision))
        let cursor = try XCTUnwrap(lease.makeCursor())
        let bytes = try await cursor.read(at: 900, length: 200)
        XCTAssertEqual(bytes.count, 100)
        XCTAssertEqual(StubURLProtocol.requests(for: url).filter { $0.httpMethod == "GET" }.count, 2)
        cursor.close()
        await lease.waitForFinalShutdown()
    }

    func testClaimedSourceDoesNotGrowItsPreparationCacheDuringPlayback() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let window = 8 * 1024 * 1024
        let tailWindow = 4 * 1024 * 1024
        let total = 40 * 1024 * 1024
        queueStat(size: total)
        queueReadHalf(url: url, offset: 0, length: RangeProbe.initialReadByteCount, total: total)
        queueReadHalf(
            url: url, offset: RangeProbe.initialReadByteCount,
            length: window - RangeProbe.initialReadByteCount, total: total
        )
        queueReadHalf(url: url, offset: total - tailWindow, length: tailWindow, total: total)
        let key = try makeKey(revision: revision, role: .playback)
        let registry = MediaTransportResolverRegistry(adapter: makeAdapter())
        let resolver = MediaTransportNetworkFileResolver(
            registry: registry, sessionKeyProvider: { _ in key }
        )
        addTeardownBlock { await registry.retire(accountID: key.accountID, credentialRevision: revision) }
        let locator = try strongETagLocator(size: Int64(total), revision: revision)
        let prepared = try await resolver.prepare(locator)
        queueStat(size: total)
        let resolved = try await resolver.resolve(locator)
        XCTAssertTrue(prepared.wasConsumed)
        let cursor = try XCTUnwrap(resolved.sourceLease.makeCursor())
        for _ in 0..<2 {
            queueReadHalf(url: url, offset: window, length: 100, total: total, byte: 8)
            let bytes = try await cursor.read(at: Int64(window), length: 100)
            XCTAssertEqual(bytes, Data(repeating: 8, count: 100))
        }
        XCTAssertEqual(StubURLProtocol.requests(for: url).filter { $0.httpMethod == "GET" }.count, 5)
        cursor.close()
        await resolved.waitForFinalShutdown()
    }

    func testPreparedDiscSourceCachesDiscoveredRangesWithinBudgetWithoutBlindTail() async throws {
        let revision = CredentialRevision()
        let path = "Movie.iso"
        let url = URL(string: "https://nas.example.com/dav/movies/\(path)")!
        let window = 4 * 1024 * 1024
        let total = 17 * window
        queueStat(size: total, relativePath: path)
        queueReadHalf(url: url, offset: 0, length: RangeProbe.initialReadByteCount, total: total)
        queueReadHalf(
            url: url, offset: RangeProbe.initialReadByteCount,
            length: window - RangeProbe.initialReadByteCount, total: total
        )
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        addTeardownBlock { await session.shutdown() }
        let fileSystem = try XCTUnwrap(session.fileSystem as? WebDAVMediaTransportFileSystem)
        let locator = try strongETagLocator(relativePath: path, size: Int64(total), revision: revision)
        let lease = try await fileSystem.prepareSource(for: locator)
        XCTAssertEqual(StubURLProtocol.requests(for: url).filter { $0.httpMethod == "GET" }.count, 2)
        let cursor = try XCTUnwrap(lease.makeCursor())
        for offset in stride(from: window, to: 16 * window, by: window) {
            queueReadHalf(url: url, offset: offset, length: window, total: total, byte: 7)
            let first = try await cursor.read(at: Int64(offset), length: window)
            let cached = try await cursor.read(at: Int64(offset), length: window)
            XCTAssertEqual(first, cached)
            XCTAssertEqual(cached.count, window)
        }
        XCTAssertEqual(StubURLProtocol.requests(for: url).filter { $0.httpMethod == "GET" }.count, 17)
        for _ in 0..<2 {
            queueReadHalf(url: url, offset: 16 * window, length: window, total: total)
            let uncached = try await cursor.read(at: Int64(16 * window), length: window)
            XCTAssertEqual(uncached.count, window)
        }
        XCTAssertEqual(
            StubURLProtocol.requests(for: url).filter { $0.httpMethod == "GET" }.count, 19,
            "The 64 MiB disc preparation cache must not grow when full"
        )
        cursor.close()
        await lease.waitForFinalShutdown()
    }

    func testPreparedCacheBoundsSparseRangeCountIndependentlyOfPayload() async throws {
        let revision = CredentialRevision()
        let path = "Movie.iso"
        let url = URL(string: "https://nas.example.com/dav/movies/\(path)")!
        let window = 4 * 1024 * 1024
        let total = 40 * 1024 * 1024
        queueStat(size: total, relativePath: path)
        queueReadHalf(url: url, offset: 0, length: RangeProbe.initialReadByteCount, total: total)
        queueReadHalf(
            url: url, offset: RangeProbe.initialReadByteCount,
            length: window - RangeProbe.initialReadByteCount, total: total
        )
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        addTeardownBlock { await session.shutdown() }
        let fileSystem = try XCTUnwrap(session.fileSystem as? WebDAVMediaTransportFileSystem)
        let locator = try strongETagLocator(relativePath: path, size: Int64(total), revision: revision)
        let lease = try await fileSystem.prepareSource(for: locator)
        let cursor = try XCTUnwrap(lease.makeCursor())
        addTeardownBlock {
            cursor.close()
            await lease.waitForFinalShutdown()
        }
        for index in 0..<63 {
            let offset = window + index * 2
            queueReadHalf(url: url, offset: offset, length: 1, total: total)
            let first = try await cursor.read(at: Int64(offset), length: 1)
            let cached = try await cursor.read(at: Int64(offset), length: 1)
            XCTAssertEqual(first, cached)
        }
        for _ in 0..<2 {
            queueReadHalf(url: url, offset: window + 126, length: 1, total: total)
            let bytes = try await cursor.read(at: Int64(window + 126), length: 1)
            XCTAssertEqual(bytes.count, 1)
        }
        XCTAssertEqual(
            StubURLProtocol.requests(for: url).filter { $0.httpMethod == "GET" }.count, 67,
            "The opening range and 63 sparse ranges exhaust the entry budget"
        )
    }

    func testPreparedOrdinarySourceKeepsSmallerCacheBudget() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let window = 4 * 1024 * 1024
        let total = 12 * window
        queueStat(size: total)
        queueReadHalf(url: url, offset: 0, length: RangeProbe.initialReadByteCount, total: total)
        queueReadHalf(
            url: url, offset: RangeProbe.initialReadByteCount,
            length: 2 * window - RangeProbe.initialReadByteCount, total: total
        )
        queueReadHalf(url: url, offset: total - window, length: window, total: total)
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        addTeardownBlock { await session.shutdown() }
        let fileSystem = try XCTUnwrap(session.fileSystem as? WebDAVMediaTransportFileSystem)
        let lease = try await fileSystem.prepareSource(for: strongETagLocator(size: Int64(total), revision: revision))
        let cursor = try XCTUnwrap(lease.makeCursor())
        addTeardownBlock {
            cursor.close()
            await lease.waitForFinalShutdown()
        }
        for offset in stride(from: 2 * window, to: 9 * window, by: window) {
            queueReadHalf(url: url, offset: offset, length: window, total: total)
            let first = try await cursor.read(at: Int64(offset), length: window)
            let cached = try await cursor.read(at: Int64(offset), length: window)
            XCTAssertEqual(first, cached)
        }
        XCTAssertEqual(StubURLProtocol.requests(for: url).filter { $0.httpMethod == "GET" }.count, 10)
        for _ in 0..<2 {
            queueReadHalf(url: url, offset: 9 * window, length: window, total: total)
            let uncached = try await cursor.read(at: Int64(9 * window), length: window)
            XCTAssertEqual(uncached.count, window)
        }
        XCTAssertEqual(
            StubURLProtocol.requests(for: url).filter { $0.httpMethod == "GET" }.count, 12,
            "The larger ISO budget must not expand the 40 MiB ordinary-container cache"
        )
    }

    func testPreparedSourceRejectsChangedRangeBeforePublication() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        queueStat()
        queueReadHalf(url: url, offset: 0, length: 2, total: 1_000)
        queueReadHalf(url: url, offset: 0, length: 1_000, total: 1_000, etag: "\"changed\"")
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        addTeardownBlock { await session.shutdown() }
        let fileSystem = try XCTUnwrap(session.fileSystem as? WebDAVMediaTransportFileSystem)
        do {
            _ = try await fileSystem.prepareSource(for: strongETagLocator(revision: revision))
            XCTFail("Changed bytes must not enter the prepared cache")
        } catch let error as MediaTransportError {
            guard case .sourceChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testPreparedSourceRevalidationRejectsChangedDAVIdentityWithoutOpeningAgain() async throws {
        let revision = CredentialRevision()
        queueStat(etag: "\"changed\"")
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        addTeardownBlock { await session.shutdown() }
        let fileSystem = try XCTUnwrap(session.fileSystem as? WebDAVMediaTransportFileSystem)
        do {
            try await fileSystem.revalidatePreparedSource(for: strongETagLocator(revision: revision))
            XCTFail("A prepared source must not bypass fresh DAV identity validation")
        } catch let error as MediaTransportError {
            guard case .sourceChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND"])
    }

    func testPrefetchedBytesStillRespectCancellationAndLeaseClosure() async throws {
        let cursor = try await openLargeSource(total: 1_000_000)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cursor.read(at: 0, length: 4)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled work must not return cached bytes")
        } catch is CancellationError {
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .cancelled)
        }
        cursor.close()
        do {
            _ = try await cursor.read(at: 0, length: 4)
            XCTFail("Closed cursors must not return cached bytes")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testChangedPrefetchedRepresentationNeverBecomesReadable() async throws {
        do {
            _ = try await openLargeSource(total: 1_000_000, probeETag: "\"changed\"")
            XCTFail("A matching body cannot override a changed validator")
        } catch let error as MediaTransportError {
            guard case .sourceChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    @MainActor
    func testPerformancePlaybackWindow() async throws {
        try await PerformanceProbe.measure(self, scenario: "webdav-playback-window") {
            StubURLProtocol.reset()
            let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
            let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
            let key = try TransportSessionKey(
                accountID: "fixture", credentialRevision: UUID(),
                origin: XCTUnwrap(TransportOrigin(url: url)), trustRevision: UUID(), role: .playback
            )
            let length = 32 * 1024 * 1024
            let source = WebDAVByteSource(
                client: WebDAVClient(registry: registry),
                representation: RangeProbeResult(
                    etag: try XCTUnwrap(ETag(headerValue: "\"strong-1\"")),
                    totalLength: Int64(length), resourceURL: url
                ),
                sessionKey: key, credential: .anonymous, trustPolicy: .system
            )
            // The same fixture accepts either one full request or two halves.
            // Delay models a per-connection rate, not actual network throughput.
            self.queueReadHalf(url: url, offset: 0, length: length, total: length, delay: .milliseconds(400))
            self.queueReadHalf(url: url, offset: 0, length: length / 2, total: length, delay: .milliseconds(200))
            self.queueReadHalf(
                url: url, offset: length / 2, length: length / 2, total: length, delay: .milliseconds(200)
            )
            let bytes: Data
            do {
                bytes = try await source.read(at: 0, length: length)
            } catch {
                await registry.drainAll()
                throw error
            }
            await registry.drainAll()
            XCTAssertEqual(bytes.count, length)
            XCTAssertTrue(bytes.allSatisfy { $0 == 42 })
            let reads = StubURLProtocol.requests(for: url)
            XCTAssertTrue((1...2).contains(reads.count))
            StubURLProtocol.reset()
            return ["consumedBytes": bytes.count, "transportReads": reads.count]
        }
    }

    func testLargeReadRejectsChangedValidatorWithoutReturningBytes() async throws {
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let half = 16 * 1024 * 1024
        let cursor = try await openLargeSource(total: 4 * half)
        queueReadHalf(url: url, offset: 0, length: 2 * half, total: 4 * half, etag: "\"changed\"")
        do {
            _ = try await cursor.read(at: 0, length: 2 * half)
            XCTFail("A changed representation must reject the entire read")
        } catch let error as MediaTransportError {
            guard case .sourceChanged = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testLargeReadCancellationDrainsTheSingleRequest() async throws {
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let half = 16 * 1024 * 1024
        let cursor = try await openLargeSource(total: 4 * half)
        let started = expectation(description: "The bounded request starts")
        queueReadHalf(
            url: url, offset: 0, length: 2 * half, total: 4 * half,
            delay: .seconds(10), onRequest: { _ in started.fulfill() }
        )
        let task = Task { try await cursor.read(at: 0, length: 2 * half) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not return a successful or partial read")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testLargeReadClampsToEOFWithoutSplitting() async throws {
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let half = 16 * 1024 * 1024
        let total = half + 7
        let cursor = try await openLargeSource(total: total)
        queueReadHalf(url: url, offset: 0, length: total, total: total, byte: 42)
        let bytes = try await cursor.read(at: 0, length: 2 * half)
        XCTAssertEqual(bytes.count, total)
        XCTAssertEqual(bytes.suffix(7), Data(repeating: 42, count: 7))
    }

    private func openLargeSource(total: Int, probeETag: String = "\"strong-1\"") async throws -> MediaTransportSourceCursor {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        queueStat(size: total)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": probeETag, "Content-Range": "bytes 0-\(RangeProbe.initialReadByteCount - 1)/\(total)"],
                body: Data(repeating: 42, count: RangeProbe.initialReadByteCount)
            ), for: url
        )
        let session = try await makeAdapter().connect(for: try makeKey(revision: revision, role: .playback))
        addTeardownBlock { await session.shutdown() }
        let locator = try strongETagLocator(size: Int64(total), revision: revision)
        let lease = try await session.fileSystem.openSource(for: locator)
        let cursor = try XCTUnwrap(lease.makeCursor())
        addTeardownBlock {
            cursor.close()
            await lease.waitForFinalShutdown()
        }
        return cursor
    }

    private func queueReadHalf(
        url: URL, offset: Int, length: Int, total: Int, byte: UInt8 = 42,
        etag: String = "\"strong-1\"", delay: Duration = .zero,
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) {
        let range = "\(offset)-\(offset + length - 1)"
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": etag, "Content-Range": "bytes \(range)/\(total)"],
                body: Data(repeating: byte, count: length),
                matchesRequest: { $0.value(forHTTPHeaderField: "Range") == "bytes=\(range)" },
                delay: delay, onRequest: onRequest
            ), for: url
        )
    }

    func testByteSourceReturnsEmptyAtEOF() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        queueStat()
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-1/1000"],
                body: Data([0x00, 0x00])
            ),
            for: url
        )
        let session = try await makeAdapter().connect(for: try makeKey(revision: revision, role: .playback))
        let lease = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
        let cursor = try XCTUnwrap(lease.makeCursor())
        let atEOF = try await cursor.read(at: 1000, length: 16)
        XCTAssertEqual(atEOF, Data(), "a read at/after EOF returns empty rather than requesting an unsatisfiable range")
    }

    func testOpenSourceRejectsLocatorFromAnotherRevision() async throws {
        let revision = CredentialRevision()
        let session = try await makeAdapter().connect(for: try makeKey(revision: revision, role: .playback))
        let locator = try strongETagLocator(revision: CredentialRevision())
        do {
            _ = try await session.fileSystem.openSource(for: locator)
            XCTFail("expected invalidInput")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .invalidInput(reason: "locator session mismatch"))
        }
    }

    // MARK: - trust-revision threading

    private func queueStat(
        etag: String? = "\"strong-1\"", modified: String? = nil, size: Int = 1000,
        relativePath: String = "Movie.mkv"
    ) {
        let xml = """
        <D:multistatus xmlns:D="DAV:"><D:response>
          <D:href>/dav/movies/\(relativePath)</D:href>
          <D:propstat><D:prop>
            <D:getcontentlength>\(size)</D:getcontentlength>
            \(etag.map { "<D:getetag>\($0)</D:getetag>" } ?? "")
            \(modified.map { "<D:getlastmodified>\($0)</D:getlastmodified>" } ?? "")
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response></D:multistatus>
        """
        StubURLProtocol.queue(
            StubResponse(statusCode: 207, body: Data(xml.utf8)),
            for: URL(string: "https://nas.example.com/dav/movies/\(relativePath)")!
        )
    }

    func testModificationTimeLocatorCanOpenAndSeekWithoutETag() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let modified = "Wed, 14 Oct 2026 12:00:00 GMT"
        let date = try XCTUnwrap(HTTPDate.parse(modified))
        queueStat(etag: nil, modified: modified)
        StubURLProtocol.queue(
            StubResponse(statusCode: 206, headers: ["Last-Modified": modified, "Content-Range": "bytes 0-1/1000"], body: Data([0, 0])),
            for: url
        )
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206, headers: ["Last-Modified": modified, "Content-Range": "bytes 900-909/1000"],
                body: Data(repeating: 7, count: 10),
                onRequest: {
                    XCTAssertNil($0.value(forHTTPHeaderField: "If-Match"))
                    XCTAssertEqual($0.value(forHTTPHeaderField: "If-Unmodified-Since"), modified)
                }
            ), for: url
        )
        let locator = try NetworkFileLocator(
            accountID: "account", sourceID: "account", credentialRevision: revision, relativePath: "Movie.mkv",
            representation: RemoteFileRepresentation(
                size: 1000, identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: date),
                consistency: .changeDetecting
            )
        )
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        let lease = try await session.fileSystem.openSource(for: locator)
        let cursor = try XCTUnwrap(lease.makeCursor())
        let bytes = try await cursor.read(at: 900, length: 10)
        XCTAssertEqual(bytes, Data(repeating: 7, count: 10))
    }

    func testStatLearnsMissingDAVIdentityFromGET() async throws {
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        queueStat(etag: nil)
        StubURLProtocol.queue(
            StubResponse(statusCode: 206, headers: ["ETag": "\"get-only\"", "Content-Range": "bytes 0-1/1000"], body: Data([0, 0])),
            for: url
        )
        let session = try await makeAdapter().connect(for: makeKey())
        let entry = try await session.fileSystem.statForOpening(relativePath: "Movie.mkv")
        XCTAssertEqual(entry.strongETag, "\"get-only\"")
        XCTAssertEqual(entry.size, 1000)
        XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND", "GET"])
    }

    func testStrongGETETagDoesNotHideChangedModificationTime() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let modified = "Wed, 14 Oct 2026 12:00:00 GMT"
        queueStat(etag: nil, modified: modified)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: [
                    "ETag": "\"replacement\"", "Last-Modified": "Thu, 15 Oct 2026 12:00:00 GMT",
                    "Content-Range": "bytes 0-1/1000"
                ],
                body: Data([0, 0])
            ), for: url
        )
        let locator = try NetworkFileLocator(
            accountID: "account", sourceID: "account", credentialRevision: revision, relativePath: "Movie.mkv",
            representation: RemoteFileRepresentation(
                size: 1000,
                identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: XCTUnwrap(HTTPDate.parse(modified))),
                consistency: .changeDetecting
            )
        )
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        do {
            _ = try await session.fileSystem.openSource(for: locator)
            XCTFail("must compare the GET date even when conditional reads would use its ETag")
        } catch let error as MediaTransportError {
            guard case .sourceChanged = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testMissingDAVIdentityCannotPersistARedirectedResourceValidator() async throws {
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        for target in [
            URL(string: "https://cdn.example.com/movie?signature=ephemeral")!,
            URL(string: "https://nas.example.com/dav/movies/Other.mkv")!
        ] {
            queueStat(etag: nil)
            StubURLProtocol.queue(redirect: StubRedirect(location: target), for: url)
            StubURLProtocol.queue(
                StubResponse(statusCode: 206, headers: ["ETag": "\"1\"", "Content-Range": "bytes 0-1/1000"], body: Data([0, 0])),
                for: target
            )
            let session = try await makeAdapter().connect(for: makeKey())
            do {
                _ = try await session.fileSystem.statForOpening(relativePath: "Movie.mkv")
                XCTFail("a different resource's ETag must not become the stable DAV locator identity")
            } catch let error as MediaTransportError {
                guard case .unsupportedRange = error else { return XCTFail("unexpected \(error)") }
            }
        }
    }

    func testGETDerivedLocatorRejectsNewResourceWithSameETagAndSize() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let target = URL(string: "https://cdn.example.com/other?signature=ephemeral")!
        let response = StubResponse(
            statusCode: 206, headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-1/1000"], body: Data([0, 0])
        )
        queueStat(etag: nil)
        StubURLProtocol.queue(response, for: url)
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        let entry = try await session.fileSystem.statForOpening(relativePath: "Movie.mkv")
        XCTAssertEqual(entry.strongETag, "\"strong-1\"")
        queueStat(etag: nil)
        StubURLProtocol.queue(redirect: StubRedirect(location: target), for: url)
        StubURLProtocol.queue(response, for: target)
        StubURLProtocol.queue(redirect: StubRedirect(location: target), for: url)
        StubURLProtocol.queue(response, for: target)
        do {
            _ = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
            XCTFail("matching unscoped ETags must not authorize resuming different content")
        } catch let error as MediaTransportError {
            guard case .unsupportedRange = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testOpenReusesExactResourceIdentityProbeWhenDAVHasNoValidator() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        queueStat(etag: nil)
        StubURLProtocol.queue(
            StubResponse(statusCode: 206, headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 0-1/1000"], body: Data([0, 0])),
            for: url
        )
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206, headers: ["ETag": "\"strong-1\"", "Content-Range": "bytes 900-909/1000"],
                body: Data(repeating: 7, count: 10),
                onRequest: {
                    XCTAssertEqual($0.value(forHTTPHeaderField: "Range"), "bytes=900-909")
                    XCTAssertEqual($0.value(forHTTPHeaderField: "If-Match"), "\"strong-1\"")
                }
            ), for: url
        )
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        let lease = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
        let cursor = try XCTUnwrap(lease.makeCursor())
        let data = try await cursor.read(at: 900, length: 10)
        XCTAssertEqual(data, Data(repeating: 7, count: 10))
        XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND", "GET", "GET"])
    }

    func testStatStillRejectsFileWithNoUsableGETValidator() async throws {
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        queueStat(etag: nil)
        StubURLProtocol.queue(
            StubResponse(statusCode: 206, headers: ["Content-Range": "bytes 0-1/1000"], body: Data([0, 0])),
            for: url
        )
        let session = try await makeAdapter().connect(for: makeKey())
        do {
            _ = try await session.fileSystem.statForOpening(relativePath: "Movie.mkv")
            XCTFail("must not fabricate a representation identity")
        } catch let error as MediaTransportError {
            guard case .unsupportedRange = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testOpenSourceRevalidatesPersistedDAVIdentityBeforeGET() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        queueStat(etag: "\"changed\"")
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        do {
            _ = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
            XCTFail("must reject a stale persisted locator")
        } catch let error as MediaTransportError {
            guard case .sourceChanged = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND"])
    }

    func testOrdinaryStatDoesNotProbeUnvalidatedFileContents() async throws {
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        queueStat(etag: nil)
        let session = try await makeAdapter().connect(for: makeKey())
        let entry = try await session.fileSystem.stat(relativePath: "Movie.mkv")
        XCTAssertEqual(entry.size, 1000)
        XCTAssertNil(entry.strongETag)
        XCTAssertNil(entry.modifiedAt)
        XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND"])
    }

    func testCDNValidatorIsIndependentFromStableDAVIdentity() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let cdn = URL(string: "https://cdn.example.com/movie?signature=ephemeral")!
        queueStat()
        StubURLProtocol.queue(redirect: StubRedirect(location: cdn), for: url)
        StubURLProtocol.queue(
            StubResponse(statusCode: 206, headers: ["ETag": "\"cdn-1\"", "Content-Range": "bytes 0-1/1000"], body: Data([0, 0])),
            for: cdn
        )
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206, headers: ["ETag": "\"cdn-1\"", "Content-Range": "bytes 0-9/1000"],
                body: Data(repeating: 1, count: 10),
                onRequest: {
                    XCTAssertEqual($0.value(forHTTPHeaderField: "If-Match"), "\"cdn-1\"")
                    XCTAssertNil($0.value(forHTTPHeaderField: "Authorization"))
                }
            ), for: cdn
        )
        let session = try await makeAdapter(credential: .bearerToken("dav-secret")).connect(
            for: makeKey(revision: revision, role: .playback)
        )
        let lease = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
        let cursor = try XCTUnwrap(lease.makeCursor())
        let data = try await cursor.read(at: 0, length: 10)
        XCTAssertEqual(data.count, 10)
    }

    func testValidatorFreeDeliveryStreamsWithinOneLeaseWithoutPersistentReuse() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let cdn = URL(string: "https://cdn.example.com/movie?signature=ephemeral")!
        queueStat(size: 300000)
        StubURLProtocol.queue(redirect: StubRedirect(location: cdn), for: url)
        let prefix = Data(repeating: 7, count: RangeProbe.initialReadByteCount)
        StubURLProtocol.queue(
            StubResponse(statusCode: 206, headers: ["Content-Range": "bytes 0-262143/300000"], body: prefix),
            for: cdn
        )
        let session = try await makeAdapter(credential: .bearerToken("dav-secret")).connect(
            for: makeKey(revision: revision, role: .playback)
        )
        let lease = try await session.fileSystem.openSource(for: strongETagLocator(size: 300000, revision: revision))
        XCTAssertFalse(lease.supportsPersistentByteReuse)
        let cursor = try XCTUnwrap(lease.makeCursor())
        let opening = try await cursor.read(at: 0, length: 16)
        XCTAssertEqual(opening, prefix.prefix(16))
        for offset in [Int64(290000), 270000] {
            StubURLProtocol.queue(
                StubResponse(
                    statusCode: 206, headers: ["Content-Range": "bytes \(offset)-\(offset + 9)/300000"],
                    body: Data(repeating: 8, count: 10),
                    onRequest: {
                        XCTAssertEqual($0.value(forHTTPHeaderField: "Range"), "bytes=\(offset)-\(offset + 9)")
                        XCTAssertNil($0.value(forHTTPHeaderField: "If-Match"))
                        XCTAssertNil($0.value(forHTTPHeaderField: "If-Unmodified-Since"))
                        XCTAssertNil($0.value(forHTTPHeaderField: "Authorization"))
                        XCTAssertNil($0.value(forHTTPHeaderField: "Cookie"))
                        XCTAssertNil($0.value(forHTTPHeaderField: "Referer"))
                    }
                ), for: cdn
            )
            let bytes = try await cursor.read(at: offset, length: 10)
            XCTAssertEqual(bytes, Data(repeating: 8, count: 10))
        }
        StubURLProtocol.queue(
            StubResponse(statusCode: 206, headers: ["Content-Range": "bytes 280000-280009/300001"],
                         body: Data(repeating: 0, count: 10)), for: cdn
        )
        do {
            _ = try await cursor.read(at: 280000, length: 10)
            XCTFail("Changed size must remain terminal")
        } catch let error as MediaTransportError {
            guard case .sourceChanged = error else { return XCTFail("unexpected \(error)") }
        }
        let replacement = URL(string: "https://cdn.example.com/replacement")!
        StubURLProtocol.queue(redirect: StubRedirect(location: replacement), for: cdn)
        do {
            _ = try await cursor.read(at: 280000, length: 10)
            XCTFail("An active lease cannot follow a new delivery URL")
        } catch let error as MediaTransportError {
            guard case .sourceChanged = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertTrue(StubURLProtocol.requests(for: replacement).isEmpty)
        StubURLProtocol.queue(StubResponse(statusCode: 403), for: cdn)
        do {
            _ = try await cursor.read(at: 280000, length: 10)
            XCTFail("Expired delivery grants cannot refresh within the lease")
        } catch let error as MediaTransportError {
            guard case .permissionDenied = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND", "GET"])
        cursor.close()
        await lease.waitForFinalShutdown()
        await session.shutdown()
    }

    func testValidatorFreeDeliveryIsNotEnabledForOtherTransportRoles() async throws {
        for role in MediaTransportRole.allCases where role != .playback {
            let revision = CredentialRevision()
            let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
            let cdn = URL(string: "https://cdn.example.com/movie")!
            queueStat()
            StubURLProtocol.queue(redirect: StubRedirect(location: cdn), for: url)
            StubURLProtocol.queue(
                StubResponse(statusCode: 206, headers: ["Content-Range": "bytes 0-1/1000"], body: Data([0, 0])),
                for: cdn
            )
            let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: role))
            do {
                _ = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
                XCTFail("Non-playback opens must retain validator requirements")
            } catch let error as MediaTransportError {
                guard case .unsupportedRange = error else { return XCTFail("unexpected \(error)") }
            }
            await session.shutdown()
        }
    }

    func testPlaybackRecoversOneDeliveryConnectionFailureAndPinsTheRecoveredLease() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let failed = URL(string: "https://cdn.example.com/movie?grant=old")!
        let recovered = URL(string: "https://cdn.example.com/movie?grant=new")!
        queueStat(size: 300000)
        StubURLProtocol.queue(redirect: StubRedirect(location: failed), for: url)
        StubURLProtocol.queue(error: URLError(.cannotConnectToHost), for: failed)
        queueStat(size: 300000)
        StubURLProtocol.queue(redirect: StubRedirect(location: recovered), for: url)
        let prefix = Data(repeating: 7, count: RangeProbe.initialReadByteCount)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206, headers: ["ETag": "\"cdn-new\"", "Content-Range": "bytes 0-262143/300000"],
                body: prefix
            ), for: recovered
        )
        let session = try await makeAdapter(credential: .bearerToken("dav-secret")).connect(
            for: makeKey(revision: revision, role: .playback)
        )
        let lease = try await session.fileSystem.openSource(for: strongETagLocator(size: 300000, revision: revision))
        let cursor = try XCTUnwrap(lease.makeCursor())
        let bytes = try await cursor.read(at: 0, length: 16)
        XCTAssertEqual(bytes, prefix.prefix(16))
        XCTAssertEqual(StubURLProtocol.requests(for: recovered).count, 1)

        StubURLProtocol.queue(error: URLError(.cannotConnectToHost), for: recovered)
        do {
            _ = try await cursor.read(at: 262144, length: 4)
            XCTFail("an active lease must not refresh its delivery URL")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .transport(code: URLError.cannotConnectToHost.rawValue))
        }
        XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND", "GET", "PROPFIND", "GET"])
        for request in StubURLProtocol.requests(for: url) {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dav-secret")
        }
        for request in StubURLProtocol.requests(for: failed) + StubURLProtocol.requests(for: recovered) {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        XCTAssertEqual(StubURLProtocol.requests(for: recovered).last?.value(forHTTPHeaderField: "If-Match"), "\"cdn-new\"")
        await session.shutdown()
    }

    func testDeliveryConnectionRecoveryStopsAfterOneFreshOpening() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let cdn = URL(string: "https://cdn.example.com/movie")!
        for _ in 0..<2 {
            queueStat()
            StubURLProtocol.queue(redirect: StubRedirect(location: cdn), for: url)
            StubURLProtocol.queue(error: URLError(.cannotConnectToHost), for: cdn)
        }
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        do {
            _ = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
            XCTFail("a second failed connection must surface")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .transport(code: URLError.cannotConnectToHost.rawValue))
        }
        XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND", "GET", "PROPFIND", "GET"])
        XCTAssertEqual(StubURLProtocol.requests(for: cdn).count, 2)
        await session.shutdown()
    }

    func testDeliveryRecoveryRevalidatesIdentityAndSizeBeforeAnotherGET() async throws {
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let cdn = URL(string: "https://cdn.example.com/movie")!
        for changesIdentity in [true, false] {
            StubURLProtocol.reset()
            let revision = CredentialRevision()
            queueStat()
            StubURLProtocol.queue(redirect: StubRedirect(location: cdn), for: url)
            StubURLProtocol.queue(error: URLError(.cannotConnectToHost), for: cdn)
            queueStat(etag: changesIdentity ? "\"changed\"" : "\"strong-1\"", size: changesIdentity ? 1000 : 1001)
            let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
            do {
                _ = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
                XCTFail("a fresh delivery must not bypass the persisted file identity")
            } catch let error as MediaTransportError {
                guard case .sourceChanged = error else { return XCTFail("unexpected \(error)") }
            }
            XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND", "GET", "PROPFIND"])
            XCTAssertEqual(StubURLProtocol.requests(for: cdn).count, 1)
            await session.shutdown()
        }
    }

    func testCancellingDuringDeliveryRecoveryStopsBeforeAnotherGET() async throws {
        let revision = CredentialRevision()
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let cdn = URL(string: "https://cdn.example.com/movie")!
        queueStat()
        StubURLProtocol.queue(redirect: StubRedirect(location: cdn), for: url)
        StubURLProtocol.queue(error: URLError(.cannotConnectToHost), for: cdn)
        let revalidating = expectation(description: "fresh identity revalidation started")
        StubURLProtocol.queue(
            StubResponse(statusCode: 207, delay: .seconds(30), onRequest: { _ in revalidating.fulfill() }),
            for: url
        )
        let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
        let locator = try strongETagLocator(revision: revision)
        let opening = Task { try await session.fileSystem.openSource(for: locator) }
        await fulfillment(of: [revalidating], timeout: 5)
        opening.cancel()
        do {
            _ = try await opening.value
            XCTFail("cancellation must end the fresh opening")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND", "GET", "PROPFIND"])
        XCTAssertEqual(StubURLProtocol.requests(for: cdn).count, 1)
        await session.shutdown()
    }

    func testDeliveryRecoveryDoesNotRetryTimeoutCancellationTLSOrHTTPRefusals() async throws {
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let cdn = URL(string: "https://cdn.example.com/movie")!
        let failures: [URLError.Code] = [.timedOut, .cancelled, .secureConnectionFailed, .serverCertificateUntrusted]
        for failure in failures {
            StubURLProtocol.reset()
            let revision = CredentialRevision()
            queueStat()
            StubURLProtocol.queue(redirect: StubRedirect(location: cdn), for: url)
            StubURLProtocol.queue(error: URLError(failure), for: cdn)
            let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
            do {
                _ = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
                XCTFail("expected delivery error \(failure)")
            } catch let error as MediaTransportError {
                XCTAssertEqual(error, failure == .cancelled ? .cancelled : .transport(code: failure.rawValue))
            }
            XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND", "GET"])
            XCTAssertEqual(StubURLProtocol.requests(for: cdn).count, 1)
            await session.shutdown()
        }
        for status in [401, 403, 429, 503, 412, 206] {
            StubURLProtocol.reset()
            let revision = CredentialRevision()
            queueStat()
            StubURLProtocol.queue(redirect: StubRedirect(location: cdn), for: url)
            StubURLProtocol.queue(StubResponse(statusCode: status), for: cdn)
            let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: .playback))
            do {
                _ = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
                XCTFail("expected refusal or malformed range for \(status)")
            } catch {
                XCTAssertTrue(error is MediaTransportError)
            }
            XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND", "GET"])
            XCTAssertEqual(StubURLProtocol.requests(for: cdn).count, 1)
            await session.shutdown()
        }
    }

    func testDeliveryRecoveryDoesNotRetryDAVConnectionsOrNonPlaybackRoles() async throws {
        let url = URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
        let cdn = URL(string: "https://cdn.example.com/movie")!
        for role in MediaTransportRole.allCases {
            StubURLProtocol.reset()
            let revision = CredentialRevision()
            queueStat()
            if role == .playback {
                StubURLProtocol.queue(error: URLError(.cannotConnectToHost), for: url)
            } else {
                StubURLProtocol.queue(redirect: StubRedirect(location: cdn), for: url)
                StubURLProtocol.queue(error: URLError(.cannotConnectToHost), for: cdn)
            }
            let session = try await makeAdapter().connect(for: makeKey(revision: revision, role: role))
            do {
                _ = try await session.fileSystem.openSource(for: strongETagLocator(revision: revision))
                XCTFail("must not retry this connection failure")
            } catch let error as MediaTransportError {
                XCTAssertEqual(error, .transport(code: URLError.cannotConnectToHost.rawValue))
            }
            XCTAssertEqual(StubURLProtocol.requests(for: url).map(\.httpMethod), ["PROPFIND", "GET"])
            await session.shutdown()
        }
    }

    func testTrustRevisionMismatchFailsClosed() async throws {
        // A pinned-leaf trust policy whose revision disagrees with the key's
        // trustRevision must be rejected by the session registry before any
        // request — proving the adapter threads the trust revision, not that
        // it silently ignores a mismatch.
        let keyTrustRevision = UUID()
        let adapter = WebDAVMediaTransportAdapter(
            scheme: .https,
            configurationProvider: { _, _ in
                WebDAVMediaTransportConfiguration(
                    credential: .anonymous,
                    trustPolicy: .pinnedLeaf(sha256: Data(repeating: 0xAB, count: 32), revision: UUID())
                )
            },
            registryFactory: { TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self]) }
        )
        StubURLProtocol.queue(
            StubResponse(statusCode: 200, headers: ["DAV": "1"]),
            for: URL(string: "https://nas.example.com/dav/movies")!
        )
        let session = try await adapter.connect(for: try makeKey(trustRevision: keyTrustRevision))
        do {
            try await session.fileSystem.validate()
            XCTFail("expected a session-configuration mismatch")
        } catch let error as MediaTransportError {
            guard case .protocolViolation = error else {
                return XCTFail("expected protocolViolation (sessionConfigurationMismatch), got \(error)")
            }
        }
    }
}
