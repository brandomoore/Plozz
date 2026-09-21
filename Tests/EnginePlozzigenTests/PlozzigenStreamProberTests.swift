import Foundation
import XCTest
import AetherEngine
import CoreModels
@testable import EnginePlozzigen

final class PlozzigenStreamProberTests: XCTestCase {
    @MainActor
    func testHTTPRequirementsSelectOneCustomReaderCallAndIndependentFacts() async throws {
        let locator = try makeLocator()
        for requirements: SupplementalStreamProbeRequirements in [.hdr10Plus, .atmos, [.hdr10Plus, .atmos]] {
            let resolver = ProbeHTTPResolver()
            let calls = ProbeTestCounter()
            let prober = PlozzigenAuthenticatedHTTPStreamProber(resolver: resolver) {
                source, details, _, _, _, _ in
                calls.increment()
                guard case .custom(let reader, _) = source else {
                    XCTFail("Authenticated HTTP must not use unbounded URL overload")
                    return ProbeTestResults.make()
                }
                XCTAssertTrue(reader is HDR10PlusAVIOReader)
                XCTAssertEqual(details.contains(.atmos), requirements.contains(.atmos))
                XCTAssertEqual(details.contains(.hdr10Plus), requirements.contains(.hdr10Plus))
                return ProbeTestResults.make(
                    carriesHDR10Plus: true,
                    audioTracks: [ProbeTestResults.audio(7, isDefault: true, isAtmos: true)]
                )
            }
            let result = await prober.probe(locator: locator, requirements: requirements)
            let facts = try XCTUnwrap(result)
            XCTAssertEqual(facts.carriesHDR10PlusMetadata == true, requirements.contains(.hdr10Plus))
            XCTAssertEqual(facts.audioIsAtmos, requirements.contains(.atmos))
            XCTAssertEqual(facts.audioTrackID, requirements.contains(.atmos) ? 7 : nil)
            XCTAssertEqual(calls.value, 1)
            XCTAssertEqual(resolver.calls, 1)
        }
    }

    @MainActor
    func testHTTPUnconfirmedBaseFormatNeverReplacesServerHDR() async throws {
        for format: VideoFormat in [.sdr, .hdr10, .dolbyVision] {
            let prober = PlozzigenAuthenticatedHTTPStreamProber(resolver: ProbeHTTPResolver()) {
                _, _, _, _, _, _ in ProbeTestResults.make(format: format)
            }
            let result = await prober.probe(locator: try makeLocator(), requirements: [.atmos, .hdr10Plus])
            XCTAssertNil(result)
        }
    }

    @MainActor
    func testHTTPNoRequirementsAndNonDirectSourcesNeverResolveOrProbe() async throws {
        let resolver = ProbeHTTPResolver()
        let prober = PlozzigenAuthenticatedHTTPStreamProber(resolver: resolver) { _, _, _, _, _, _ in
            XCTFail("Ineligible sources must not enter native probing")
            return ProbeTestResults.make()
        }
        let empty = await prober.probe(locator: try makeLocator(), requirements: [])
        let manifest = await prober.probe(locator: try makeLocator(mode: .hls), requirements: .hdr10Plus)
        XCTAssertNil(empty)
        XCTAssertNil(manifest)
        XCTAssertEqual(resolver.calls, 0)
    }

    func testDolbyVisionKeepsPrimaryClassificationAndHDR10PlusEvidence() {
        let probe = ProbeTestResults.make(format: .dolbyVision, carriesHDR10Plus: true)
        let share = PlozzigenNetworkFileStreamProber.facts(from: probe)
        let http = PlozzigenAuthenticatedHTTPStreamProber.facts(from: probe, requirements: .hdr10Plus)
        for facts in [share, http] {
            XCTAssertEqual(facts.videoRangeType, "DOVI")
            XCTAssertEqual(facts.carriesHDR10PlusMetadata, true)
        }
        let unknown = PlozzigenNetworkFileStreamProber.facts(from: ProbeTestResults.make())
        XCTAssertNil(unknown.carriesHDR10PlusMetadata)
    }

    func testDefaultAudioWinsOverEarlierAtmosCommentaryTrack() {
        let probe = ProbeTestResults.make(audioTracks: [
            ProbeTestResults.audio(1, isDefault: false, isAtmos: true),
            ProbeTestResults.audio(7, isDefault: true, isAtmos: false)
        ])
        let share = PlozzigenNetworkFileStreamProber.facts(from: probe)
        let http = PlozzigenAuthenticatedHTTPStreamProber.facts(from: probe, requirements: .atmos)
        XCTAssertEqual(share.audioTrackID, 7)
        XCTAssertFalse(share.audioIsAtmos)
        XCTAssertFalse(http.audioIsAtmos)
        XCTAssertNil(http.audioTrackID)
        let fallback = PlozzigenNetworkFileStreamProber.facts(
            from: ProbeTestResults.make(audioTracks: [
                ProbeTestResults.audio(3, isDefault: false, isAtmos: true)
            ])
        )
        XCTAssertEqual(fallback.audioTrackID, 3)
        XCTAssertTrue(fallback.audioIsAtmos)
    }

    func testKnownAtmosDoesNotSuppressIndependentHDRScanOnNetworkFile() async throws {
        let source = ProbeTransportSource()
        let reader = TransportIOReader(source: source, readAheadWindow: 1)
        let calls = ProbeTestCounter()
        let result = await PlozzigenNetworkFileStreamProber.probe(
            reader: reader, relativePath: "film.mkv", requirements: .hdr10Plus
        ) { _, details, _, _, _, _ in
            calls.increment()
            XCTAssertEqual(details, .hdr10Plus)
            return ProbeTestResults.make(
                carriesHDR10Plus: true,
                audioTracks: [ProbeTestResults.audio(7, isDefault: true, isAtmos: true)]
            )
        }
        let facts = try XCTUnwrap(result)
        XCTAssertTrue(facts.audioIsAtmos)
        XCTAssertEqual(facts.carriesHDR10PlusMetadata, true)
        XCTAssertEqual(facts.videoRangeType, "HDR10Plus")
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(source.shutdowns.value, 1)
    }

    func testNetworkReaderClosesAndJoinsFinalShutdownOnSuccessAndFailure() async {
        for fails in [false, true] {
            let source = ProbeTransportSource()
            let reader = TransportIOReader(source: source, readAheadWindow: 1)
            let result = await PlozzigenNetworkFileStreamProber.probe(
                reader: reader, relativePath: "film.mkv", requirements: [.atmos, .hdr10Plus]
            ) { mediaSource, details, _, _, limits, cancellation in
                guard case .custom(let received, let hint) = mediaSource else {
                    XCTFail("Network probing must retain the custom source")
                    throw ProbeError.invalidReaderResult
                }
                XCTAssertTrue(received === reader)
                XCTAssertEqual(hint, "matroska")
                XCTAssertEqual(details, [.atmos, .hdr10Plus])
                XCTAssertEqual(limits.maxInputBytes, 8 * 1024 * 1024)
                XCTAssertFalse(cancellation.isCancelled)
                var byte: UInt8 = 0
                XCTAssertEqual(received.read(&byte, size: 1), 1)
                if fails { throw ProbeError.packetSizeLimit }
                return ProbeTestResults.make(carriesHDR10Plus: true)
            }
            XCTAssertEqual(result == nil, fails)
            XCTAssertEqual(source.shutdowns.value, 1)
            var byte: UInt8 = 0
            XCTAssertEqual(reader.read(&byte, size: 1), -1)
        }
    }

    func testNetworkCancellationLatchesIOAndDiscardsEventualPositive() async {
        let source = ProbeTransportSource()
        let reader = TransportIOReader(source: source, readAheadWindow: 1)
        let started = expectation(description: "native entered")
        let returned = expectation(description: "native returned")
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            await PlozzigenNetworkFileStreamProber.probe(
                reader: reader, relativePath: "film.mkv", requirements: .hdr10Plus
            ) { _, _, _, _, _, cancellation in
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
                XCTAssertTrue(cancellation.isCancelled)
                var byte: UInt8 = 0
                XCTAssertEqual(reader.read(&byte, size: 1), -1)
                returned.fulfill()
                return ProbeTestResults.make(carriesHDR10Plus: true)
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        release.signal()
        await fulfillment(of: [returned], timeout: 1)
        await reader.waitForFinalShutdown()
        XCTAssertEqual(source.shutdowns.value, 1)
    }

    private func makeLocator(
        mode: AuthenticatedHTTPDeliveryMode = .directFile
    ) throws -> AuthenticatedHTTPPlaybackLocator {
        try AuthenticatedHTTPPlaybackLocator(
            provider: .jellyfin, accountID: "account", credentialRevision: .init(),
            itemID: "film", deliveryMode: mode,
            resource: AuthenticatedHTTPResource(pathBase: .serverRoot, path: "/Videos/film/stream")
        )
    }
}

@MainActor
private final class ProbeHTTPResolver: AuthenticatedHTTPResourceResolving {
    var calls = 0
    func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        calls += 1
        return URL(string: "https://example.invalid/movie?api_key=test-only")!
    }
}

private final class ProbeTransportSource: TransportByteSource, @unchecked Sendable {
    let shutdowns = ProbeTestCounter()
    var byteSize: Int64 { 1 }
    func read(at offset: Int64, length: Int) async throws -> Data {
        try Task.checkCancellation()
        return offset == 0 && length > 0 ? Data([42]) : Data()
    }
    func shutdown() async { shutdowns.increment() }
}
