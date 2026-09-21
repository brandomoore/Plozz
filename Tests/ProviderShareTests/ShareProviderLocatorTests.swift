import CoreModels
import Foundation
import MediaTransportCore
@testable import ProviderShare
import XCTest

/// Coverage for the representation identity `ShareProvider.networkFileLocator`
/// builds: a WebDAV `stat` carrying a strong ETag must produce a `.strongETag`
/// identity (so the byte source can `If-Match`-revalidate every read), while an
/// SMB-style entry (modification time, no ETag) falls back to
/// `.modificationTime`, and an entry with neither is rejected.
final class ShareProviderLocatorTests: XCTestCase {
    private func makeProvider(
        stat: RemoteFileEntry,
        streamProber: NetworkFileStreamProbing? = nil,
        fileSystem: LocatorFakeFileSystem? = nil
    ) -> ShareProvider {
        let fileSystem = fileSystem ?? LocatorFakeFileSystem(statEntry: stat)
        let session = LocatorFakeSession(fileSystem: fileSystem)
        let server = MediaServer(
            id: "share:https://nas.example.com/dav#anon",
            name: "DAV",
            baseURL: URL(string: "https://nas.example.com/dav")!,
            provider: .mediaShare
        )
        let userSession = UserSession(
            server: server,
            userID: "anon",
            userName: "",
            deviceID: "device",
            accessToken: ""
        )
        return ShareProvider(
            session: userSession,
            sessionFactory: { _ in session },
            streamProber: streamProber
        )
    }

    func testStrongETagStatProducesStrongETagIdentity() async throws {
        let entry = try RemoteFileEntry(
            relativePath: "movie.mkv",
            kind: .file,
            size: 4096,
            modifiedAt: Date(timeIntervalSince1970: 10),
            strongETag: "\"abc-123\""
        )
        let locator = try await makeProvider(stat: entry).networkFileLocator(for: "movie.mkv")
        XCTAssertEqual(locator.representation.identity.kind, .strongETag)
        XCTAssertEqual(locator.representation.identity.value, "\"abc-123\"")
        XCTAssertEqual(locator.representation.size, 4096)
    }

    func testModificationTimeStatProducesModificationTimeIdentity() async throws {
        let entry = try RemoteFileEntry(
            relativePath: "movie.mkv",
            kind: .file,
            size: 4096,
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
        let locator = try await makeProvider(stat: entry).networkFileLocator(for: "movie.mkv")
        XCTAssertEqual(locator.representation.identity.kind, .modificationTime)
    }

    func testStatWithNeitherIdentityIsRejected() async throws {
        let entry = try RemoteFileEntry(relativePath: "movie.mkv", kind: .file, size: 4096)
        do {
            _ = try await makeProvider(stat: entry).networkFileLocator(for: "movie.mkv")
            XCTFail("expected a protocolViolation for an entry with no stable identity")
        } catch let error as MediaTransportError {
            guard case .protocolViolation = error else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
    }

    func testSupplementalProbeIsCachedAndPropagatesAtmosIntoPlayback() async throws {
        let entry = try RemoteFileEntry(
            relativePath: "movie.mkv",
            kind: .file,
            size: 4096,
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
        let prober = LocatorStreamProber(
            facts: ProbedStreamFacts(
                videoWidth: 3840,
                videoHeight: 2160,
                videoRangeType: "DOVI",
                videoCodec: "hevc",
                audioTrackID: 1,
                audioCodec: "eac3",
                audioChannels: 6,
                audioIsAtmos: true
            )
        )
        let provider = makeProvider(stat: entry, streamProber: prober)
        let item = MediaItem(id: "f:movie.mkv", title: "Movie", kind: .video)

        let first = await provider.supplementalStreamFacts(for: item)
        let second = await provider.supplementalStreamFacts(for: item)
        let request = try await provider.playbackInfo(
            for: item.id,
            mediaSourceID: nil,
            forceTranscode: false
        )
        let callCount = await prober.callCount

        XCTAssertEqual(first, second)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(request.item.mediaInfo?.video?.videoRangeType, "DOVI")
        XCTAssertEqual(request.item.mediaInfo?.audio?.profile, "Dolby Atmos")
        XCTAssertEqual(request.sourceMetadata?.audio?.profile, "Dolby Atmos")
        XCTAssertEqual(request.audioTracks.first?.id, 1)
        XCTAssertTrue(request.audioTracks.first?.isAtmos ?? false)
    }

    func testKnownAtmosRequestsOnlyMissingNetworkHDRScan() async throws {
        let entry = try RemoteFileEntry(
            relativePath: "movie.mkv", kind: .file, size: 4096,
            modifiedAt: Date(timeIntervalSince1970: 10))
        let prober = RequirementsStreamProber(facts: [.init(videoRangeType: "HDR10Plus")])
        let provider = makeProvider(stat: entry, streamProber: prober)
        let item = MediaItem(
            id: "f:movie.mkv", title: "Movie", kind: .video,
            mediaInfo: .init(
                video: .init(codec: "av1", width: 3840, height: 2160, videoRangeType: "HDR10"),
                audio: .init(codec: "eac3", profile: "Dolby Atmos", channels: 6)))
        let facts = await provider.supplementalStreamFacts(for: item)
        let requirements = await prober.requirements
        XCTAssertEqual(requirements, [.hdr10Plus])
        let enriched = item.applyingSupplementalStreamFacts(try XCTUnwrap(facts))
        XCTAssertEqual(enriched.mediaInfo?.video?.videoRangeType, "HDR10Plus")
        XCTAssertEqual(enriched.mediaInfo?.audio?.profile, "Dolby Atmos")
    }

    func testMissingNetworkAudioAndHDRUseOneCombinedProbe() async throws {
        let entry = try RemoteFileEntry(
            relativePath: "movie.mkv", kind: .file, size: 4096,
            modifiedAt: Date(timeIntervalSince1970: 10))
        let prober = RequirementsStreamProber(facts: [
            .init(videoRangeType: "HDR10Plus", audioTrackID: 2, audioCodec: "eac3", audioIsAtmos: true)
        ])
        let provider = makeProvider(stat: entry, streamProber: prober)
        let item = MediaItem(id: "f:movie.mkv", title: "Movie", kind: .video)
        _ = await provider.supplementalStreamFacts(for: item)
        _ = await provider.supplementalStreamFacts(for: item)
        let requirements = await prober.requirements
        XCTAssertEqual(requirements, [[.streamDetails, .atmos, .hdr10Plus]])
        let playback = try await provider.playbackInfo(for: item.id, mediaSourceID: nil, forceTranscode: false)
        XCTAssertEqual(playback.item.mediaInfo?.video?.videoRangeType, "HDR10Plus")
        XCTAssertEqual(playback.sourceMetadata?.video?.videoRangeType, "HDR10Plus")
        XCTAssertEqual(playback.sourceMetadata?.audio?.profile, "Dolby Atmos")
        XCTAssertEqual(playback.audioTracks.first?.id, 2)
        XCTAssertTrue(playback.audioTracks.first?.isDefault == true)
    }

    func testKnownFormatsWithMissingDimensionsRequestHeadersOnly() async throws {
        let entry = try RemoteFileEntry(
            relativePath: "movie.mkv", kind: .file, size: 4096,
            modifiedAt: Date(timeIntervalSince1970: 10))
        let prober = RequirementsStreamProber(facts: [.init(videoWidth: 1920, videoHeight: 1080)])
        let provider = makeProvider(stat: entry, streamProber: prober)
        let item = MediaItem(
            id: "f:movie.mkv", title: "Movie", kind: .video,
            mediaInfo: .init(
                video: .init(codec: "h264", videoRangeType: "SDR"),
                audio: .init(codec: "aac", channels: 2)))
        _ = await provider.supplementalStreamFacts(for: item)
        let requirements = await prober.requirements
        XCTAssertEqual(requirements, [.streamDetails])
    }

    func testIndependentNetworkScansKeepPositiveFactsAndDefaultTrackThroughPlayback() async throws {
        let entry = try RemoteFileEntry(
            relativePath: "movie.mkv", kind: .file, size: 4096,
            modifiedAt: Date(timeIntervalSince1970: 10))
        let prober = RequirementsStreamProber(facts: [
            .init(videoRangeType: "HDR10Plus", audioTrackID: 4, audioCodec: "eac3",
                  audioChannels: 6, audioIsAtmos: true),
            .init(videoRangeType: "HDR10", audioTrackID: 4, audioCodec: "eac3", audioIsAtmos: false)
        ])
        let provider = makeProvider(stat: entry, streamProber: prober)
        var item = MediaItem(
            id: "f:movie.mkv", title: "Movie", kind: .video,
            mediaInfo: .init(
                video: .init(codec: "hevc", width: 3840, height: 2160, videoRangeType: "HDR10Plus"),
                audio: .init(codec: "eac3", channels: 6)))
        _ = await provider.supplementalStreamFacts(for: item)
        item.mediaInfo?.video?.videoRangeType = "HDR10"
        item.mediaInfo?.audio?.profile = "Dolby Atmos"
        let merged = await provider.supplementalStreamFacts(for: item)
        let requirements = await prober.requirements
        XCTAssertEqual(requirements, [.atmos, .hdr10Plus])
        XCTAssertEqual(merged?.videoRangeType, "HDR10Plus")
        XCTAssertTrue(merged?.audioIsAtmos == true)
        let playback = try await provider.playbackInfo(for: item.id, mediaSourceID: nil, forceTranscode: false)
        XCTAssertEqual(playback.sourceMetadata?.video?.videoRangeType, "HDR10Plus")
        XCTAssertEqual(playback.sourceMetadata?.audio?.profile, "Dolby Atmos")
        XCTAssertEqual(playback.audioTracks.first?.id, 4)
        XCTAssertTrue(playback.audioTracks.first?.isAtmos == true)
    }

    func testReplacedRepresentationDoesNotCarryOldFactsIntoPlayback() async throws {
        let firstEntry = try RemoteFileEntry(
            relativePath: "movie.mkv", kind: .file, size: 4096, strongETag: "\"original\"")
        let replacementEntry = try RemoteFileEntry(
            relativePath: "movie.mkv", kind: .file, size: 4096, strongETag: "\"replacement\"")
        let fileSystem = LocatorFakeFileSystem(statEntry: firstEntry)
        let prober = RequirementsStreamProber(facts: [
            .init(videoRangeType: "DOVI", audioTrackID: 1, audioCodec: "eac3", audioIsAtmos: true),
            .init(videoRangeType: "SDR", audioTrackID: 3, audioCodec: "aac")
        ])
        let provider = makeProvider(stat: firstEntry, streamProber: prober, fileSystem: fileSystem)
        let item = MediaItem(id: "f:movie.mkv", title: "Movie", kind: .video)
        _ = await provider.supplementalStreamFacts(for: item)
        await fileSystem.replaceStat(replacementEntry)
        let beforeReprobe = try await provider.playbackInfo(for: item.id, mediaSourceID: nil, forceTranscode: false)
        XCTAssertNil(beforeReprobe.sourceMetadata?.video?.videoRangeType)
        XCTAssertNil(beforeReprobe.sourceMetadata?.audio?.profile)
        XCTAssertTrue(beforeReprobe.audioTracks.isEmpty)

        _ = await provider.supplementalStreamFacts(for: item)
        let playback = try await provider.playbackInfo(for: item.id, mediaSourceID: nil, forceTranscode: false)
        let requirements = await prober.requirements
        XCTAssertEqual(requirements.count, 2)
        XCTAssertEqual(playback.item.mediaInfo?.video?.videoRangeType, "SDR")
        XCTAssertNil(playback.sourceMetadata?.audio?.profile)
        XCTAssertEqual(playback.audioTracks.first?.id, 3)
        XCTAssertFalse(playback.audioTracks.first?.isAtmos ?? true)
    }

    private actor RequirementsStreamProber: NetworkFileStreamProbing {
        private var facts: [ProbedStreamFacts]
        private(set) var requirements: [SupplementalStreamProbeRequirements] = []

        init(facts: [ProbedStreamFacts]) { self.facts = facts }

        func probe(locator: NetworkFileLocator) async -> ProbedStreamFacts? {
            XCTFail("ShareProvider must forward independent requirements")
            return nil
        }

        func probe(
            locator: NetworkFileLocator, requirements: SupplementalStreamProbeRequirements
        ) async -> ProbedStreamFacts? {
            self.requirements.append(requirements)
            return facts.isEmpty ? nil : facts.removeFirst()
        }
    }

    private actor LocatorStreamProber: NetworkFileStreamProbing {
        let facts: ProbedStreamFacts?
        private(set) var callCount = 0

        init(facts: ProbedStreamFacts?) {
            self.facts = facts
        }

        func probe(locator: NetworkFileLocator) async -> ProbedStreamFacts? {
            callCount += 1
            return facts
        }
    }
}

private final class LocatorFakeSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem

    init(fileSystem: any MediaTransportFileSystem) {
        // Force-try in a test helper: the endpoint inputs are valid constants.
        // swiftlint:disable:next force_try
        key = MediaTransportSessionKey(
            accountID: "account",
            credentialRevision: CredentialRevision(),
            endpoint: try! MediaTransportEndpointIdentity(
                transportIdentifier: "https",
                host: "nas.example.com",
                rootPath: "/dav"
            ),
            trustRevision: UUID(),
            role: .metadata
        )
        self.fileSystem = fileSystem
    }

    func shutdown() async {}
    /// Always healthy: this fake models a stateless session, so the registry
    /// reuses it while idle. Health-driven eviction is covered by
    /// `ResolverStaleSessionTests`.
    func isHealthy() async -> Bool { true }
}

private actor LocatorFakeFileSystem: MediaTransportFileSystem {
    private var statEntry: RemoteFileEntry

    init(statEntry: RemoteFileEntry) {
        self.statEntry = statEntry
    }

    func replaceStat(_ entry: RemoteFileEntry) { statEntry = entry }

    func validate() async throws {}

    func probe() async throws -> MediaTransportProbe {
        MediaTransportProbe(
            capabilities: try MediaTransportCapabilities(
                supportsList: true,
                supportsStat: true,
                supportsBoundedWholeFileRead: true,
                byteRangeBehavior: .randomAccess,
                maximumBoundedWholeFileReadBytes: 1_024,
                consistency: .changeDetecting
            )
        )
    }

    func list(relativePath: String) async throws -> [RemoteFileEntry] { [] }

    func stat(relativePath: String) async throws -> RemoteFileEntry { statEntry }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data { Data() }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        throw MediaTransportError.unsupportedCapability("test")
    }
}
