import XCTest
@testable import ProviderShare
import CoreModels
import MediaTransportCore

/// Sidecar subtitle filename parsing (Phase 5): teasing the stem / language /
/// forced / SDH out of a `.srt`/`.ass` filename so it can be matched to a video.
final class ShareSidecarParserTests: XCTestCase {
    func testDetectsSubtitleExtensions() {
        XCTAssertTrue(ShareMediaParser.isSubtitleFile("Movie.en.srt"))
        XCTAssertTrue(ShareMediaParser.isSubtitleFile("Movie.ass"))
        XCTAssertTrue(ShareMediaParser.isSubtitleFile("Movie.VTT"))
        XCTAssertFalse(ShareMediaParser.isSubtitleFile("Movie.mkv"))
        XCTAssertFalse(ShareMediaParser.isSubtitleFile("Movie.sup"), "image sidecars excluded")
    }

    final class ShareSidecarDiscoveryTests: XCTestCase {
        func testNoSubtitleFoldersNeedsOnlyTheParentListing() async throws {
            let session = try SidecarSession(directories: [
                "": [entry("Film.mp4"), entry("Subs"), entry("Unrelated", .directory)]
            ])
            let tracks = try await service(session).discoverSidecarSubtitles(forVideoRelPath: "Film.mp4")
            let lists = await session.listedPaths
            XCTAssertTrue(tracks.isEmpty)
            XCTAssertEqual(lists, [""])
        }

        func testListsRealFolderCasingOnceAndPreservesSidecarMatching() async throws {
            let session = try SidecarSession(directories: [
                "Movies": [
                    entry("Film.en.srt"), entry("Film Extended.en.srt"),
                    entry("Subs", .directory), entry("Subs", .directory),
                    entry("subs", .directory), entry("SuBtItLeS", .symlink)
                ],
                "Movies/Subs": [entry("Film.fr.srt")],
                "Movies/subs": [entry("Film.fr.srt"), entry("Film.de.srt")],
                "Movies/SuBtItLeS": [entry("Film Extended.es.srt")]
            ])
            let tracks = try await service(session).discoverSidecarSubtitles(forVideoRelPath: "Movies/Film.mp4")
            removeTracksOnTeardown(tracks)
            let lists = await session.listedPaths
            let reads = await session.readPaths
            XCTAssertEqual(lists, ["Movies", "Movies/SuBtItLeS", "Movies/Subs", "Movies/subs"])
            XCTAssertEqual(Set(tracks.compactMap(\.language)), ["en", "es", "fr", "de"])
            XCTAssertEqual(tracks.count, 4)
            XCTAssertEqual(reads.count, 4, "Casing aliases must not duplicate a sidecar read")
            for track in tracks {
                guard case .localFile(let url)? = track.deliverySource else {
                    return XCTFail("Sidecars must still be materialized locally")
                }
                XCTAssertEqual(try Data(contentsOf: url), SidecarSession.subtitle)
            }
        }

        func testUnlistableParentPreservesLegacyFolderFallback() async throws {
            let session = try SidecarSession(
                directories: ["Movies/Subs": [entry("Film.en.srt")]],
                failures: ["Movies": .permissionDenied]
            )
            let tracks = try await service(session).discoverSidecarSubtitles(forVideoRelPath: "Movies/Film.mp4")
            removeTracksOnTeardown(tracks)
            let lists = await session.listedPaths
            XCTAssertEqual(lists, [
                "Movies", "Movies/Subs", "Movies/Subtitles", "Movies/subs", "Movies/subtitles"
            ])
            XCTAssertEqual(tracks.count, 1)
        }

        func testUnavailableSubtitleFolderDoesNotDiscardOwnDirectoryTracks() async throws {
            let session = try SidecarSession(
                directories: ["Movies": [entry("Film.en.srt"), entry("Subs", .directory)]],
                failures: ["Movies/Subs": .permissionDenied]
            )
            let tracks = try await service(session).discoverSidecarSubtitles(forVideoRelPath: "Movies/Film.mp4")
            removeTracksOnTeardown(tracks)
            XCTAssertEqual(tracks.count, 1)
        }

        func testCancelledListingDoesNotStartFallbackRequests() async throws {
            let session = try SidecarSession(directories: [:], failures: ["Movies": .cancelled])
            do {
                _ = try await service(session).discoverSidecarSubtitles(forVideoRelPath: "Movies/Film.mp4")
                XCTFail("Cancellation must not become an empty successful result")
            } catch {
                XCTAssertEqual(error as? MediaTransportError, .cancelled)
            }
            let lists = await session.listedPaths
            XCTAssertEqual(lists, ["Movies"])
        }

        func testCancelledReadStopsBeforeTheNextSidecar() async throws {
            let session = try SidecarSession(
                directories: ["Movies": [entry("Film.en.srt"), entry("Film.fr.srt")]],
                failures: ["Movies/Film.en.srt": .cancelled]
            )
            do {
                _ = try await service(session).discoverSidecarSubtitles(forVideoRelPath: "Movies/Film.mp4")
                XCTFail("Read cancellation must not become an empty successful result")
            } catch {
                XCTAssertEqual(error as? MediaTransportError, .cancelled)
            }
            let reads = await session.readPaths
            XCTAssertEqual(reads, ["Movies/Film.en.srt"])
        }

        private func entry(_ path: String, _ kind: RemoteFileEntryKind = .file) throws -> RemoteFileEntry {
            try RemoteFileEntry(relativePath: path, kind: kind)
        }

        private func service(_ session: SidecarSession) -> SharePlaybackSourceService {
            let store = ShareLibraryStore(
                browser: ShareTransportBrowser(role: .metadata, sessionFactory: { _ in session }),
                serverName: "Sidecar fixture"
            )
            addTeardownBlock { await store.close() }
            return SharePlaybackSourceService(
                store: store, streamProber: nil, accountID: session.key.accountID,
                credentialRevision: session.key.credentialRevision
            )
        }

        private func removeTracksOnTeardown(_ tracks: [MediaTrack]) {
            addTeardownBlock {
                for track in tracks {
                    if case .localFile(let url)? = track.deliverySource {
                        try FileManager.default.removeItem(at: url)
                    }
                }
            }
        }

        private actor SidecarSession: MediaTransportSession, MediaTransportFileSystem {
            nonisolated let key: MediaTransportSessionKey
            nonisolated var fileSystem: any MediaTransportFileSystem { self }
            static let subtitle = Data("1\n00:00:00,000 --> 00:00:01,000\nHello\n".utf8)
            let directories: [String: [RemoteFileEntry]]
            let failures: [String: MediaTransportError]
            var listedPaths: [String] = []
            var readPaths: [String] = []

            init(directories: [String: [RemoteFileEntry]], failures: [String: MediaTransportError] = [:]) throws {
                self.directories = directories
                self.failures = failures
                key = MediaTransportSessionKey(
                    accountID: UUID().uuidString, credentialRevision: CredentialRevision(),
                    endpoint: try MediaTransportEndpointIdentity(transportIdentifier: "https", host: "fixture.invalid"),
                    trustRevision: UUID(), role: .metadata
                )
            }

            func shutdown() async {}
            func isHealthy() async -> Bool { true }
            func validate() async throws {}
            func probe() async throws -> MediaTransportProbe {
                throw MediaTransportError.unsupportedCapability("unused")
            }
            func list(relativePath: String) async throws -> [RemoteFileEntry] {
                listedPaths.append(relativePath)
                if let error = failures[relativePath] { throw error }
                return directories[relativePath] ?? []
            }
            func stat(relativePath: String) async throws -> RemoteFileEntry {
                throw MediaTransportError.unsupportedCapability("unused")
            }
            func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
                readPaths.append(relativePath)
                if let error = failures[relativePath] { throw error }
                return Self.subtitle
            }
            func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
                throw MediaTransportError.unsupportedCapability("unused")
            }
        }
    }

    func testParsesLanguageOnly() {
        let s = ShareMediaParser.parseSidecar("The Matrix (1999).en.srt")
        XCTAssertEqual(s?.stem, "The Matrix (1999)")
        XCTAssertEqual(s?.language, "en")
        XCTAssertEqual(s?.isForced, false)
        XCTAssertEqual(s?.isSDH, false)
        XCTAssertEqual(s?.ext, "srt")
    }

    func testParsesForcedAndSDHTokens() {
        let forced = ShareMediaParser.parseSidecar("Dune.2021.en.forced.srt")
        XCTAssertEqual(forced?.stem, "Dune.2021")
        XCTAssertEqual(forced?.language, "en")
        XCTAssertTrue(forced?.isForced ?? false)

        let sdh = ShareMediaParser.parseSidecar("Show.S01E01.eng.sdh.ass")
        XCTAssertEqual(sdh?.stem, "Show.S01E01")
        XCTAssertEqual(sdh?.language, "en", "3-letter code folds to 2-letter")
        XCTAssertTrue(sdh?.isSDH ?? false)
        XCTAssertEqual(sdh?.ext, "ass")
    }

    func testParsesFullLanguageName() {
        let s = ShareMediaParser.parseSidecar("Amelie.French.srt")
        XCTAssertEqual(s?.stem, "Amelie")
        XCTAssertEqual(s?.language, "fr")
    }

    func testNoQualifiersLeavesWholeStem() {
        let s = ShareMediaParser.parseSidecar("Movie.srt")
        XCTAssertEqual(s?.stem, "Movie")
        XCTAssertNil(s?.language)
        XCTAssertFalse(s?.isForced ?? true)
    }

    func testReturnsNilForNonSubtitle() {
        XCTAssertNil(ShareMediaParser.parseSidecar("Movie.mkv"))
    }

    func testVideoStemStripsExtension() {
        XCTAssertEqual(ShareMediaParser.videoStem("The Matrix (1999).mkv"), "The Matrix (1999)")
    }

    func testStemMatchesVideoStem() {
        // The parsed sidecar stem should equal the video stem for same-dir pairing.
        let video = ShareMediaParser.videoStem("The Matrix (1999).mkv")
        let sidecar = ShareMediaParser.parseSidecar("The Matrix (1999).en.srt")
        XCTAssertEqual(sidecar?.stem, video)
    }

    // MARK: - Sidecar ↔ video matching

    func testSameDirRequiresExactStem() {
        // Non-zero-padded episodes must NOT cross-attach in the video's own dir.
        XCTAssertTrue(ShareProvider.sidecarMatchesVideo(sidecarStem: "Show.S01E10", videoStem: "Show.S01E10", dedicatedFolder: false))
        XCTAssertFalse(ShareProvider.sidecarMatchesVideo(sidecarStem: "Show.S01E1", videoStem: "Show.S01E10", dedicatedFolder: false))
        XCTAssertFalse(ShareProvider.sidecarMatchesVideo(sidecarStem: "Batman", videoStem: "Batman Begins", dedicatedFolder: false))
    }

    func testDedicatedFolderAllowsBoundaryPrefix() {
        // In a Subs/ folder a boundary-aligned prefix match is allowed…
        XCTAssertTrue(ShareProvider.sidecarMatchesVideo(sidecarStem: "Movie", videoStem: "Movie.1080p", dedicatedFolder: true))
        XCTAssertTrue(ShareProvider.sidecarMatchesVideo(sidecarStem: "Movie.1080p", videoStem: "Movie", dedicatedFolder: true))
        // …but E1 still must not prefix-match E10 (no separator boundary).
        XCTAssertFalse(ShareProvider.sidecarMatchesVideo(sidecarStem: "Show.S01E1", videoStem: "Show.S01E10", dedicatedFolder: true))
    }
}
