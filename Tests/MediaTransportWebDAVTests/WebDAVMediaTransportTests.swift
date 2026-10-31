import CoreModels
import Foundation
import MediaTransportCore
@testable import MediaTransportHTTP
@testable import MediaTransportWebDAV
@testable import TestSupportNetworking
@testable import TestSupportPerformance
import XCTest

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

    private func queueStat(etag: String? = "\"strong-1\"", modified: String? = nil, size: Int = 1000) {
        let xml = """
        <D:multistatus xmlns:D="DAV:"><D:response>
          <D:href>/dav/movies/Movie.mkv</D:href>
          <D:propstat><D:prop>
            <D:getcontentlength>\(size)</D:getcontentlength>
            \(etag.map { "<D:getetag>\($0)</D:getetag>" } ?? "")
            \(modified.map { "<D:getlastmodified>\($0)</D:getlastmodified>" } ?? "")
          </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response></D:multistatus>
        """
        StubURLProtocol.queue(
            StubResponse(statusCode: 207, body: Data(xml.utf8)),
            for: URL(string: "https://nas.example.com/dav/movies/Movie.mkv")!
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
