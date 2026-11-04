import CommonCrypto
import XCTest

@testable import EnginePlozzigen

final class HLSSampleDecryptionTests: XCTestCase {
    private let key = Data((0..<16).map { UInt8($0 &* 7 &+ 3) })
    private let iv = Data((0..<16).map { UInt8(0xF0 &- $0) })

    /// Encrypts `ranges` of `bytes` as one chained run, as a packager would.
    private func encrypt(_ bytes: [UInt8], ranges: [Range<Int>], mode: Int) -> [UInt8] {
        var output = bytes
        var ref: CCCryptorRef?
        key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                _ = CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(mode), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    v.baseAddress, k.baseAddress, 16, nil, 0, 0,
                    CCModeOptions(mode == kCCModeCTR ? kCCModeOptionCTR_BE : 0), &ref
                )
            }
        }
        defer { CCCryptorRelease(ref) }
        for range in ranges {
            var out = [UInt8](repeating: 0, count: range.count)
            var moved = 0
            _ = output.withUnsafeBufferPointer {
                CCCryptorUpdate(ref, $0.baseAddress! + range.lowerBound, range.count, &out, out.count, &moved)
            }
            output.replaceSubrange(range, with: out)
        }
        return output
    }

    private func pattern(_ bytes: [UInt8]) -> [UInt8] { bytes.indices.map { UInt8(($0 * 31 + 5) & 0xFF) } }

    func testEmulationPreventionRoundTrips() {
        let raw: [UInt8] = [0x65, 0, 0, 1, 0, 0, 0, 7, 0, 0, 3, 9]
        let escaped = HLSSampleDecryption.escape(raw)
        XCTAssertFalse(escaped.windows(ofCount: 3).contains { $0.elementsEqual([0, 0, 1]) })
        XCTAssertEqual(HLSSampleDecryption.unescape(escaped), raw)
    }

    func testSampleAESNALDecryptsApplesPattern() {
        var plain = pattern([UInt8](repeating: 0, count: 400))
        plain[0] = 0x65
        // 32 clear bytes, then one block in ten, chained; a last block of 16 or fewer stays clear.
        var ranges: [Range<Int>] = []
        var offset = 32
        var remaining = plain.count - 32
        while remaining > 0 {
            if remaining > 16 { ranges.append(offset..<(offset + 16)); offset += 16; remaining -= 16 }
            let skip = min(144, remaining); offset += skip; remaining -= skip
        }
        var encrypted = encrypt(plain, ranges: ranges, mode: kCCModeCBC)
        XCTAssertNotEqual(encrypted, plain)
        HLSSampleDecryption.decryptSampleAESNAL(&encrypted, key: key, iv: iv)
        XCTAssertEqual(encrypted, plain)
    }

    func testWholeSegmentCBCDecryptsOnlyCompletePrefixBlocks() {
        let plain = pattern(Array(repeating: 0, count: 48))
        let encrypted = encrypt(plain, ranges: [0..<48], mode: kCCModeCBC)
        XCTAssertEqual(HLSSampleDecryption.cbcDecrypt(Data(encrypted.prefix(35)), key: key, iv: iv), Data(plain.prefix(32)))
    }

    func testCBCSSubsamplesRestartTheIVAndFollowThePattern() {
        let plain = pattern([UInt8](repeating: 0, count: 700))
        let track = HLSSampleDecryption.TrackEncryption(
            scheme: .cbcs, trackID: 1, cryptBlocks: 1, skipBlocks: 9, perSampleIVSize: 0, constantIV: iv
        )
        let subsamples = [(clear: 20, protected: 300), (clear: 10, protected: 370)]
        var encrypted = plain
        var cursor = 0
        for entry in subsamples {
            let start = cursor + entry.clear
            var ranges: [Range<Int>] = []
            var offset = start
            while offset + 16 <= start + entry.protected { ranges.append(offset..<(offset + 16)); offset += 160 }
            encrypted = encrypt(encrypted, ranges: ranges, mode: kCCModeCBC)
            cursor = start + entry.protected
        }
        XCTAssertNotEqual(encrypted, plain)
        HLSSampleDecryption.decryptSample(&encrypted, 0..<700, subsamples: subsamples, track: track, key: key, iv: iv)
        XCTAssertEqual(encrypted, plain)
    }

    func testCENCCounterRunsThroughASamplesProtectedBytes() {
        let plain = pattern([UInt8](repeating: 0, count: 300))
        let track = HLSSampleDecryption.TrackEncryption(
            scheme: .cenc, trackID: 1, cryptBlocks: 0, skipBlocks: 0, perSampleIVSize: 16, constantIV: nil
        )
        let subsamples = [(clear: 10, protected: 90), (clear: 5, protected: 195)]
        let encrypted = encrypt(plain, ranges: [10..<100, 105..<300], mode: kCCModeCTR)
        var bytes = encrypted
        HLSSampleDecryption.decryptSample(&bytes, 0..<300, subsamples: subsamples, track: track, key: key, iv: iv)
        XCTAssertEqual(bytes, plain)
    }

    func testPlaylistKeysAndSequences() throws {
        let base = try XCTUnwrap(URL(string: "https://cdn.test/live/index.m3u8"))
        let text = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:41
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin",IV=0x000102030405060708090A0B0C0D0E0F,KEYFORMAT="identity"
        #EXTINF:6.0,
        a.ts
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:6.0,
        b.ts
        """
        let playlist = try XCTUnwrap(LiveHLSScrubThumbnails.parseMediaPlaylist(text, base: base))
        XCTAssertEqual(playlist.segments.map(\.sequence), [41, 42])
        let key = try XCTUnwrap(playlist.segments[0].key)
        XCTAssertEqual(key.method, "SAMPLE-AES")
        XCTAssertEqual(key.url?.absoluteString, "https://cdn.test/live/key.bin")
        XCTAssertEqual(key.iv?.count, 16)
        XCTAssertNil(playlist.segments[1].key)
        XCTAssertTrue(LiveHLSScrubThumbnails.canDecrypt(key, fragmented: false))
        let fairPlay = LiveHLSScrubThumbnails.Key(
            method: "SAMPLE-AES", url: URL(string: "skd://x"), iv: nil, keyFormat: "com.apple.streamingkeydelivery"
        )
        XCTAssertFalse(LiveHLSScrubThumbnails.canDecrypt(fairPlay, fragmented: true))
        XCTAssertEqual(LiveHLSScrubThumbnails.sequenceIV(258).suffix(2), Data([1, 2]))
    }

    func testMalformedMP4BoxesAndUnboundedSampleCountsAreRejected() {
        XCTAssertTrue(HLSSampleDecryption.boxes(
            in: [0, 0, 0, 1] + Array("moof".utf8) + Array(repeating: 255, count: 8), range: 0..<16
        ).isEmpty)
        XCTAssertTrue(HLSSampleDecryption.boxes(in: [], range: 0..<8).isEmpty)
        XCTAssertTrue(HLSSampleDecryption.boxes(in: Array(repeating: 0, count: 8), range: -1..<8).isEmpty)
        let senc: [UInt8] = [0, 0, 0, 0, 255, 255, 255, 255]
        XCTAssertTrue(HLSSampleDecryption.sampleEncryption(senc, senc: 0..<8, ivSize: 0).isEmpty)
        let run: [UInt8] = Array(repeating: 0, count: 12) + [255, 255, 255, 255]
        XCTAssertTrue(HLSSampleDecryption.trackRunSampleSizes(run, tfhd: 0..<8, trun: 8..<16).isEmpty)
    }

    func testShortVideoSampleEntryAndAuxiliaryIVAreRejected() {
        func word(_ value: UInt32) -> [UInt8] {
            [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
             UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        }
        func box(_ type: String, _ body: [UInt8]) -> [UInt8] { word(UInt32(body.count + 8)) + Array(type.utf8) + body }
        let stsd = box("stsd", Array(repeating: 0, count: 8) + box("encv", []))
        let trak = box("trak", box("tkhd", [0]) + box("mdia", box("minf", box("stbl", stsd))))
        XCTAssertNil(HLSSampleDecryption.videoTrackEncryption(initSegment: Data(box("moov", trak))))
        let saiz = box("saiz", [0, 0, 0, 0, 1] + word(1))
        let saio = box("saio", [0, 0, 0, 0] + word(1) + word(UInt32(saiz.count + 20)))
        let auxiliary = saiz + saio + [0]
        XCTAssertNil(HLSSampleDecryption.auxiliaryEncryption(
            auxiliary, traf: 0..<auxiliary.count, moofStart: 0, ivSize: 16
        ))
    }

    func testInvalidFragmentSampleOffsetsDoNotDecryptOutsideTheSegment() {
        func word(_ value: UInt32) -> [UInt8] {
            [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
             UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        }
        func box(_ type: String, _ body: [UInt8]) -> [UInt8] { word(UInt32(body.count + 8)) + Array(type.utf8) + body }
        let tfhd = box("tfhd", word(0) + word(1))
        let trun = box("trun", word(0x201) + word(1) + word(UInt32(bitPattern: -100)) + word(16))
        let senc = box("senc", word(0) + word(1) + Array(iv))
        let data = Data(box("moof", box("traf", tfhd + trun + senc)))
        let track = HLSSampleDecryption.TrackEncryption(
            scheme: .cenc, trackID: 1, cryptBlocks: 0, skipBlocks: 0, perSampleIVSize: 16, constantIV: nil
        )
        XCTAssertEqual(HLSSampleDecryption.decryptFragmentedMP4(data, track: track, key: key), data)
        let plain = pattern(Array(repeating: 0, count: 16))
        let encrypted = encrypt(plain, ranges: [0..<16], mode: kCCModeCTR)
        let validRun = box("trun", word(0x201) + word(1) + word(UInt32(data.count + 8)) + word(16))
        let segment = Data(box("moof", box("traf", tfhd + validRun + senc)) + box("mdat", encrypted))
        XCTAssertEqual(HLSSampleDecryption.decryptFragmentedMP4(segment, track: track, key: key).suffix(16), Data(plain))
    }

    func testUnsupportedByteRangesMapSwitchesAndInvalidDurationsDoNotProduceWrongSegments() {
        let base = URL(string: "https://cdn.test/live/index.m3u8")!
        XCTAssertNil(LiveHLSScrubThumbnails.parseMediaPlaylist(
            "#EXTM3U\n#EXTINF:6,\n#EXT-X-BYTERANGE:512@0\nall.ts", base: base
        ))
        XCTAssertNil(LiveHLSScrubThumbnails.parseMediaPlaylist(
            "#EXTM3U\n#EXT-X-MAP:URI=\"one.mp4\"\n#EXTINF:6,\na.m4s\n#EXT-X-MAP:URI=\"two.mp4\"\n#EXTINF:6,\nb.m4s", base: base
        ))
        XCTAssertEqual(LiveHLSScrubThumbnails.parseMediaPlaylist(
            "#EXTM3U\n#EXTINF:nan,\na.ts\n#EXTINF:-1,\nb.ts\n#EXTINF:6,\nc.ts", base: base
        )?.segments.map(\.url.lastPathComponent), ["c.ts"])
    }
}

final class LiveHLSScrubNetworkingTests: XCTestCase {
    func testRedirectsKeepCredentialsOnlyWithinTheOriginalOrigin() {
        let origin = URL(string: "https://fixture.invalid/start")!
        var request = URLRequest(url: origin)
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        request.setValue("fixture", forHTTPHeaderField: "X-Token")
        request.setValue("FixturePlayer/1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://fixture.invalid/", forHTTPHeaderField: "Referer")
        request.setValue("bytes=0-31", forHTTPHeaderField: "Range")

        let local = LiveHLSScrubRedirects.redirect(request, from: origin, to: URL(string: "https://fixture.invalid/next")!)
        XCTAssertEqual(local?.url?.absoluteString, "https://fixture.invalid/next")
        XCTAssertEqual(local?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(local?.value(forHTTPHeaderField: "X-Token"), "fixture")
        XCTAssertEqual(local?.value(forHTTPHeaderField: "Range"), "bytes=0-31")

        // Providers hand segments and keys to a CDN by redirect, as AVPlayer follows.
        for url in ["https://cdn.invalid/next", "https://fixture.invalid:444/next"] {
            let foreign = LiveHLSScrubRedirects.redirect(request, from: origin, to: URL(string: url)!)
            XCTAssertEqual(foreign?.url?.absoluteString, url)
            XCTAssertNil(foreign?.value(forHTTPHeaderField: "Authorization"), url)
            XCTAssertNil(foreign?.value(forHTTPHeaderField: "X-Token"), url)
            XCTAssertEqual(foreign?.value(forHTTPHeaderField: "User-Agent"), "FixturePlayer/1", url)
            XCTAssertEqual(foreign?.value(forHTTPHeaderField: "Referer"), "https://fixture.invalid/", url)
            XCTAssertEqual(foreign?.value(forHTTPHeaderField: "Range"), "bytes=0-31", url)
        }
        for url in ["http://fixture.invalid/next", "ftp://fixture.invalid/next", "https://user:pass@cdn.invalid/next"] {
            XCTAssertNil(LiveHLSScrubRedirects.redirect(request, from: origin, to: URL(string: url)!), url)
        }
    }

    func testRedirectCannotDowngradeAfterAnHTTPOriginUpgradesToHTTPS() throws {
        let origin = URL(string: "http://fixture.invalid/start")!
        let secure = URL(string: "https://cdn.invalid/playlist")!
        var request = URLRequest(url: origin)
        request.setValue("fixture-token", forHTTPHeaderField: "Authorization")
        let upgrade = try XCTUnwrap(LiveHLSScrubRedirects.redirect(request, from: origin, to: secure))
        XCTAssertNil(upgrade.value(forHTTPHeaderField: "Authorization"))
        for target in ["http://cdn.invalid/next", "http://fixture.invalid/return"] {
            XCTAssertNil(LiveHLSScrubRedirects.redirect(request, from: secure, to: URL(string: target)))
        }
        let next = LiveHLSScrubRedirects.redirect(
            request, from: secure, to: URL(string: "https://second-cdn.invalid/next")
        )
        XCTAssertNotNil(next)
        XCTAssertNil(next?.value(forHTTPHeaderField: "Authorization"))
    }

    @MainActor
    func testCancelledVariantFetchDoesNotAbandonThePreviewRendition() async {
        let started = expectation(description: "Preferred variant request started")
        let fixture = LiveHLSScrubHTTPStub.CancellationFixture(started: started)
        let source = LiveHLSScrubHTTPStub.register(fixture)
        defer { LiveHLSScrubHTTPStub.unregister(source) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveHLSScrubHTTPStub.self]
        let thumbnails = LiveHLSScrubThumbnails(
            playlistURL: source, headers: [:], configuration: configuration,
            playingMediaPlaylist: { source.deletingLastPathComponent().appendingPathComponent("playing.m3u8") }
        )
        let cancelled = Task { await thumbnails.thumbnail(secondsIntoWindow: 0, maxWidth: 180) }
        await fulfillment(of: [started], timeout: 3)
        cancelled.cancel()
        _ = await cancelled.value
        _ = await thumbnails.thumbnail(secondsIntoWindow: 0, maxWidth: 180)
        XCTAssertEqual(fixture.paths.filter { $0 == "preview.m3u8" }.count, 2)
        XCTAssertFalse(fixture.paths.contains("playing.m3u8"))
    }

    func testPrefixReadIsBoundedWhenOriginIgnoresRange() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let data = await LiveHLSScrubThumbnails.fetch(
            URLRequest(url: URL(string: "https://fixture.invalid/large")!),
            session: session, maximumBytes: 32, allowsPrefix: true
        )
        XCTAssertEqual(data, Data(repeating: 7, count: 32))
    }

    func testOversizedWholeResourcesAndWrongRangeStartAreRejected() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        for path in ["large", "unknown-length", "wrong-range", "error"] {
            let data = await LiveHLSScrubThumbnails.fetch(
                URLRequest(url: URL(string: "https://fixture.invalid/\(path)")!),
                session: session, maximumBytes: 16
            )
            XCTAssertNil(data, path)
        }
    }

    func testRedirectedPlaylistResolvesItsVariantsAgainstTheServingOrigin() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let fetched = await LiveHLSScrubThumbnails.fetchServed(
            URLRequest(url: URL(string: "https://fixture.invalid/fta/abctv/redirected.m3u8")!),
            session: session, maximumBytes: 512 * 1_024
        )
        let served = try XCTUnwrap(fetched)
        XCTAssertEqual(served.url.absoluteString, "https://cdn.invalid/live/redirected.m3u8")
        // AVPlayer resolves relative variants against the CDN it was redirected
        // to; the provider's own host answers 404 for them.
        let variant = LiveHLSScrubThumbnails.thumbnailVariant(
            in: try XCTUnwrap(String(data: served.data, encoding: .utf8)), base: served.url
        )
        XCTAssertEqual(variant?.absoluteString, "https://cdn.invalid/live/hdntl=token/index_25.m3u8")
    }

    @MainActor
    func testOnlyClientIdentityIsForwardedToPlaylistSuppliedForeignOrigins() {
        let source = URL(string: "https://fixture.invalid/live.m3u8")!
        let thumbnails = LiveHLSScrubThumbnails(playlistURL: source, headers: [
            "Authorization": "Bearer fixture", "X-Token": "fixture",
            "User-Agent": "FixturePlayer/1", "Referer": "https://fixture.invalid/", "Origin": "https://fixture.invalid",
        ])
        XCTAssertEqual(thumbnails.request(source).value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        let foreign = thumbnails.request(URL(string: "https://cdn.invalid/key")!)
        XCTAssertNil(foreign.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(foreign.value(forHTTPHeaderField: "X-Token"))
        // The channel's client identity is what CDN and key hosts check.
        XCTAssertEqual(foreign.value(forHTTPHeaderField: "User-Agent"), "FixturePlayer/1")
        XCTAssertEqual(foreign.value(forHTTPHeaderField: "Referer"), "https://fixture.invalid/")
        XCTAssertEqual(foreign.value(forHTTPHeaderField: "Origin"), "https://fixture.invalid")
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveHLSScrubHTTPStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class LiveHLSScrubHTTPStub: URLProtocol, @unchecked Sendable {
    final class CancellationFixture: @unchecked Sendable {
        let started: XCTestExpectation
        private let lock = NSLock()
        private var requests: [String] = []
        init(started: XCTestExpectation) { self.started = started }
        var paths: [String] { lock.withLock { requests } }
        func record(_ path: String) -> Int {
            lock.withLock {
                requests.append(path)
                return requests.filter { $0 == path }.count
            }
        }
    }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var fixtures: [String: CancellationFixture] = [:]
    }
    private static let registry = Registry()

    static func register(_ fixture: CancellationFixture) -> URL {
        let host = "\(UUID().uuidString.lowercased()).invalid"
        registry.lock.withLock { registry.fixtures[host] = fixture }
        return URL(string: "https://\(host)/master.m3u8")!
    }

    static func unregister(_ source: URL) {
        _ = registry.lock.withLock { registry.fixtures.removeValue(forKey: source.host!) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        if let fixture = Self.registry.lock.withLock({ Self.registry.fixtures[request.url!.host!] }) {
            let count = fixture.record(path)
            if path == "preview.m3u8", count == 1 {
                fixture.started.fulfill()
                return
            }
            let text = path == "master.m3u8"
                ? "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=640x360\npreview.m3u8\n"
                : "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n"
            let body = Data(text.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: path == "segment.ts" ? 403 : 200, httpVersion: nil,
                headerFields: ["Content-Length": String(body.count)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if path == "redirected.m3u8" {
            if request.url!.host == "fixture.invalid" {
                // A provider handing its master to a CDN, as some IPTV hosts do.
                let destination = URL(string: "https://cdn.invalid/live/redirected.m3u8")!
                let redirect = HTTPURLResponse(
                    url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": destination.absoluteString]
                )!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: redirect)
                return
            }
            let master = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=640x360\nhdntl=token/index_25.m3u8\n".utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(master.count)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: master)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var headers = path == "unknown-length" ? [:] : ["Content-Length": "65536"]
        if path == "wrong-range" { headers["Content-Range"] = "bytes 100-115/65536" }
        let status = path == "error" ? 403 : path == "wrong-range" ? 206 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 65_536))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LiveHLSThumbnailVariantTests: XCTestCase {
    private let base = URL(string: "https://cdn.test/live/master.m3u8")!

    func testPicksTheSmallestVideoVariantAtLeast640Wide() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.2"
        audio.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=416x234,CODECS="avc1.42c01e,mp4a.40.2"
        234.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
        1080.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
        360.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=960x540,CODECS="avc1.4d401f,mp4a.40.2"
        540.m3u8
        """
        XCTAssertEqual(LiveHLSScrubThumbnails.thumbnailVariant(in: master, base: base)?.lastPathComponent, "360.m3u8")
    }

    func testFallsBackToTheWidestBelow640ThenTheLowestBandwidth() {
        let small = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=320x180
        180.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=480x270
        270.m3u8
        """
        XCTAssertEqual(LiveHLSScrubThumbnails.thumbnailVariant(in: small, base: base)?.lastPathComponent, "270.m3u8")
        let unsized = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=3000000
        hi.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=800000
        lo.m3u8
        """
        XCTAssertEqual(LiveHLSScrubThumbnails.thumbnailVariant(in: unsized, base: base)?.lastPathComponent, "lo.m3u8")
        XCTAssertNil(LiveHLSScrubThumbnails.thumbnailVariant(in: "#EXTM3U\n#EXTINF:6,\na.ts", base: base))
    }
}

private extension Array {
    func windows(ofCount count: Int) -> [ArraySlice<Element>] {
        guard self.count >= count else { return [] }
        return (0...(self.count - count)).map { self[$0..<($0 + count)] }
    }
}
