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
    func testBluRayFolderPlaybackUsesOneManifestAcrossShareTransports() async throws {
        let root = "Test Pattern (2026)/BDMV"
        let index = try RemoteFileEntry(
            relativePath: "\(root)/index.bdmv", kind: .file, size: 40, strongETag: "\"index\""
        )
        let playlist = try RemoteFileEntry(
            relativePath: "\(root)/PLAYLIST/00001.mpls", kind: .file, size: 120, strongETag: "\"playlist\""
        )
        let clips = try ["00001", "00002"].map {
            try RemoteFileEntry(
                relativePath: "\(root)/STREAM/\($0).m2ts", kind: .file, size: 4096,
                modifiedAt: Date(timeIntervalSince1970: 100)
            )
        }
        let objects = try RemoteFileEntry(
            relativePath: "\(root)/MovieObject.bdmv", kind: .file, size: 128, strongETag: "\"objects\""
        )
        let backup = try RemoteFileEntry(
            relativePath: "\(root)/BACKUP/CLIPINF/00002.clpi", kind: .file, size: 256, strongETag: "\"backup\""
        )
        let java = try ["JAR/00000.jar", "JAR/00000/menu.png", "BDJO/00000.bdjo", "AUXDATA/00000.otf"].map {
            try RemoteFileEntry(relativePath: "\(root)/\($0)", kind: .file, size: 128, strongETag: "\"java\"")
        }
        let folders = try ["PLAYLIST", "STREAM", "BACKUP", "JAR", "BDJO", "AUXDATA"].map {
            try RemoteFileEntry(relativePath: "\(root)/\($0)", kind: .directory)
        }
        let certificate = try RemoteFileEntry(
            relativePath: "Test Pattern (2026)/CERTIFICATE/id.bdmv",
            kind: .file, size: 128, strongETag: "\"disc-id\""
        )
        for scheme in ["smb", "sftp", "ftp", "ftps", "http", "https"] {
            let fileSystem = LocatorFakeFileSystem(statEntry: index, directoryTree: [
                root: [index, objects] + folders,
                "Test Pattern (2026)": [try RemoteFileEntry(
                    relativePath: "Test Pattern (2026)/CERTIFICATE", kind: .directory
                )],
                "Test Pattern (2026)/CERTIFICATE": [certificate],
                "\(root)/PLAYLIST": [playlist],
                "\(root)/BACKUP": [try RemoteFileEntry(relativePath: "\(root)/BACKUP/CLIPINF", kind: .directory)],
                "\(root)/BACKUP/CLIPINF": [backup],
                "\(root)/STREAM": clips,
                "\(root)/JAR": [java[0], try RemoteFileEntry(relativePath: "\(root)/JAR/00000", kind: .directory)],
                "\(root)/JAR/00000": [java[1]],
                "\(root)/BDJO": [java[2]],
                "\(root)/AUXDATA": [java[3]]
            ])
            let provider = makeProvider(
                stat: index, fileSystem: fileSystem,
                baseURL: try XCTUnwrap(URL(string: "\(scheme)://nas.example.com/media"))
            )
            addTeardownBlock { await provider.teardown() }
            let request = try await provider.playbackInfo(for: "f:\(index.relativePath)")
            guard case .networkDisc(let disc) = request.playbackSource else {
                return XCTFail("\(scheme) must use folder playback, never the first clip")
            }
            XCTAssertEqual(disc.files.count, DiscMenuInspection.supportsJavaMenus ? 11 : 7)
            XCTAssertEqual(request.item.title, "Test Pattern")
            XCTAssertEqual(disc.anchor.relativePath, index.relativePath)
            XCTAssertEqual(
                disc.files.first(where: { $0.path == "BDMV/STREAM/00001.m2ts" })?.locator.representation.identity.kind,
                .modificationTime
            )
            XCTAssertTrue(disc.files.contains { $0.path == "BDMV/MovieObject.bdmv" })
            XCTAssertTrue(disc.files.contains { $0.path == "BDMV/BACKUP/CLIPINF/00002.clpi" })
            for entry in java.prefix(3) {
                XCTAssertEqual(disc.files.contains { $0.locator.relativePath == entry.relativePath },
                               DiscMenuInspection.supportsJavaMenus)
            }
            XCTAssertTrue(disc.files.contains { $0.locator.relativePath == java[3].relativePath })
            XCTAssertEqual(disc.files.contains { $0.path == "CERTIFICATE/id.bdmv" },
                           DiscMenuInspection.supportsJavaMenus)
            XCTAssertNil(request.downloadableOriginalSource)
            let preparation = try await provider.playbackPreparationLocator(
                for: request.item.id, mediaSourceID: index.relativePath
            )
            XCTAssertNil(preparation, "Do not warm the index as a video")
            let reads = await fileSystem.fileReads
            XCTAssertEqual(reads, 0, "Manifest discovery must not download clips")
        }
    }

    func testNativeDiscPlaybackDoesNotReadInaccessibleJavaDirectories() async throws {
        guard !DiscMenuInspection.supportsJavaMenus else { throw XCTSkip("Native-only inventory contract") }
        let root = "Movie/BDMV"
        let index = try RemoteFileEntry(
            relativePath: "\(root)/index.bdmv", kind: .file, size: 40, strongETag: "\"index\""
        )
        let directories = try ["JAR", "BDJO", "BACKUP", "STREAM", "PLAYLIST"].map {
            try RemoteFileEntry(relativePath: "\(root)/\($0)", kind: .directory)
        }
        let denied = ["\(root)/JAR", "\(root)/BDJO", "\(root)/BACKUP/BDJO", "Movie/CERTIFICATE"]
        let fileSystem = LocatorFakeFileSystem(statEntry: index, directoryTree: [
            root: [index] + directories,
            "\(root)/BACKUP": [try .init(relativePath: "\(root)/BACKUP/BDJO", kind: .directory)],
            "\(root)/PLAYLIST": [try .init(
                relativePath: "\(root)/PLAYLIST/00001.mpls", kind: .file, size: 120, strongETag: "\"playlist\""
            )],
            "\(root)/STREAM": [try .init(
                relativePath: "\(root)/STREAM/00001.m2ts", kind: .file, size: 4096, strongETag: "\"clip\""
            )]
        ], deniedDirectories: Set(denied))
        let provider = makeProvider(stat: index, fileSystem: fileSystem)
        addTeardownBlock { await provider.teardown() }
        let request = try await provider.playbackInfo(for: "f:\(index.relativePath)")
        guard case .networkDisc(let disc) = request.playbackSource else { return XCTFail("Expected disc") }
        XCTAssertEqual(disc.files.count, 3)
        let listed = await fileSystem.listedPaths
        XCTAssertTrue(Set(listed).isDisjoint(with: denied))
    }

    func testOfflineSubtitlesMatchExactVideoAndPreserveFlags() async throws {
        let video = try RemoteFileEntry(relativePath: "movie.mkv", kind: .file, size: 100, strongETag: "\"a\"")
        let own = try RemoteFileEntry(relativePath: "movie.en.forced.sdh.srt", kind: .file, size: 40)
        let other = try RemoteFileEntry(relativePath: "movie-extended.fr.srt", kind: .file, size: 40)
        let filesystem = LocatorFakeFileSystem(statEntry: video, listedEntries: [video, own, other],
                                              fileContents: Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8))
        let provider = makeProvider(stat: video, fileSystem: filesystem)
        addTeardownBlock { await provider.teardown() }
        let tracks = try await provider.subtitleTracks(context: .init(itemID: "f:movie.mkv", mediaSourceID: "movie.mkv"))
        XCTAssertEqual(tracks.count, 1)
        XCTAssertTrue(tracks[0].isForced)
        XCTAssertTrue(tracks[0].isHearingImpaired)
        XCTAssertEqual(tracks[0].language, "en")
        guard case .localFile(let file)? = tracks[0].deliverySource else { return XCTFail("Expected bounded local asset") }
        XCTAssertFalse(try Data(contentsOf: file).isEmpty)
    }

    func testOfflineSubtitleListingFailureIsNotAnEmptySuccess() async throws {
        let video = try RemoteFileEntry(relativePath: "movie.mkv", kind: .file, size: 100)
        let filesystem = LocatorFakeFileSystem(statEntry: video, listingError: .authentication(reason: "test"))
        let provider = makeProvider(stat: video, fileSystem: filesystem)
        addTeardownBlock { await provider.teardown() }
        do {
            _ = try await provider.subtitleTracks(context: .init(itemID: "f:movie.mkv", mediaSourceID: "movie.mkv"))
            XCTFail("The downloader needs the failure to report a warning")
        } catch { XCTAssertEqual(error as? MediaTransportError, .authentication(reason: "test")) }
    }

    func testPreparationDiagnosticCodesNeverIncludeAssociatedErrorText() {
        let secret = "https://private.example/file?token=private-secret"
        let cases: [(Error, String)] = [
            (MediaTransportError.protocolViolation(reason: secret), "transport.protocolViolation"),
            (MediaTransportError.authentication(reason: secret), "transport.authentication"),
            (MediaTransportError.transport(code: -1004), "transport.transport(code: -1004)"),
            (MediaSourceModelError.sensitiveQueryItem(name: secret), "model.sensitiveQueryItem"),
            (MediaSourceModelError.emptyIdentifier(field: secret), "model.emptyIdentifier"),
            (MediaSourceModelError.invalidRepresentationIdentity, "model.invalidRepresentationIdentity"),
            (AppError.unknown(secret), "app.unknown"),
            (URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: secret]), "url.-1001"),
            (NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret]), "unknown"),
            (CancellationError(), "cancelled")
        ]
        for (error, expected) in cases {
            XCTAssertEqual(SharePlaybackSourceService.diagnosticErrorCode(error), expected)
        }
    }

    func testLocatorDiagnosticsClassifyMetadataWithoutPublishingItsValues() throws {
        let path = "private-folder/private-title.mkv"
        let entry = try RemoteFileEntry(
            relativePath: path, kind: .file, size: 8192,
            modifiedAt: Date(timeIntervalSince1970: 12345), strongETag: "\"private-validator\""
        )
        let diagnostic = SharePlaybackSourceService.metadataDiagnostic(relativePath: path, entry: entry)
        XCTAssertTrue(diagnostic.contains("isFile=true size=8192 strongETag=true modifiedAt=true"))
        for secret in ["private-folder", "private-title", "private-validator", "12345"] {
            XCTAssertFalse(diagnostic.contains(secret))
        }
    }

    func testPreparationFailureRetainsStageAndRequestCorrelationWithoutChangingError() async throws {
        let wasEnabled = HandoffDiagnostics.isEnabled
        HandoffDiagnostics.setEnabled(true)
        defer { HandoffDiagnostics.setEnabled(wasEnabled) }
        let path = "private-no-identity-\(UUID().uuidString).mkv"
        let entry = try RemoteFileEntry(relativePath: path, kind: .file, size: 4096)
        let provider = makeProvider(stat: entry)
        addTeardownBlock { await provider.teardown() }
        do {
            _ = try await provider.playbackInfo(for: "f:\(path)")
            XCTFail("Missing identity must still fail")
        } catch {
            XCTAssertEqual(error as? MediaTransportError, .protocolViolation(
                reason: "network file lacks a stable identity (no strong ETag or modification time)"
            ))
        }
        let lines = HandoffDiagnostics.persistentPlaybackLogText().components(separatedBy: "\n")
        let failure = try XCTUnwrap(lines.last {
            $0.contains("sharePlayback") && $0.contains("item=\(HandoffDiagnostics.correlationID("f:\(path)"))")
                && $0.contains("event=failed")
        })
        XCTAssertTrue(failure.contains("stage=locator event=failed error=transport.protocolViolation"))
        let requestID = try XCTUnwrap(failure.split(separator: " ").first { $0.hasPrefix("request=") })
        let requestLines = lines.filter { $0.contains(requestID) }
        XCTAssertEqual(requestLines.count, 3)
        XCTAssertTrue(requestLines[0].contains("stage=selection event=start"))
        XCTAssertTrue(requestLines[1].contains("stage=locator event=start"))
        XCTAssertFalse(requestLines.joined().contains(path))
        XCTAssertTrue(lines.contains {
            $0.contains("file=\(HandoffDiagnostics.correlationID(path))")
                && $0.contains("rejected=missingIdentity")
        })
    }

    func testConcurrentPreparationRequestsHaveDistinctSuccessfulTraces() async throws {
        let wasEnabled = HandoffDiagnostics.isEnabled
        HandoffDiagnostics.setEnabled(true)
        defer { HandoffDiagnostics.setEnabled(wasEnabled) }
        let path = "private-success-\(UUID().uuidString).mkv"
        let entry = try RemoteFileEntry(
            relativePath: path, kind: .file, size: 4096, strongETag: "\"private-validator\""
        )
        let provider = makeProvider(stat: entry)
        addTeardownBlock { await provider.teardown() }
        async let first = provider.playbackInfo(for: "f:\(path)")
        async let second = provider.playbackInfo(for: "f:\(path)")
        _ = try await (first, second)
        let lines = HandoffDiagnostics.persistentPlaybackLogText().components(separatedBy: "\n").filter {
            $0.contains("sharePlayback") && $0.contains("item=\(HandoffDiagnostics.correlationID("f:\(path)"))")
        }
        let ready = lines.filter { $0.contains("event=ready") }
        XCTAssertEqual(ready.count, 2)
        let requestIDs = Set(ready.compactMap { $0.split(separator: " ").first { $0.hasPrefix("request=") } })
        XCTAssertEqual(requestIDs.count, 2)
        for requestID in requestIDs {
            let trace = lines.filter { $0.contains(requestID) }.joined(separator: "\n")
            for stage in ["selection", "locator", "item", "sidecars"] {
                XCTAssertTrue(trace.contains("stage=\(stage) event=start"))
            }
            XCTAssertFalse(trace.contains("event=failed"))
            XCTAssertFalse(trace.contains("private"))
        }
    }

    func testExternalLinkResolutionIsBoundedAndNeverOpensAVideoSource() async throws {
        let path = "Movie (2020).strmlnk"
        let entry = try RemoteFileEntry(relativePath: path, kind: .file, size: 100)
        let fileSystem = LocatorFakeFileSystem(
            statEntry: entry, listedEntries: [entry],
            fileContents: Data("https://tv.apple.com/us/movie/example/id".utf8)
        )
        let provider = makeProvider(stat: entry, fileSystem: fileSystem)
        addTeardownBlock { await provider.teardown() }
        let item = try await provider.item(id: "f:\(path)")
        XCTAssertTrue(item.opensExternalSource)
        XCTAssertEqual(item.externalSourceVersion?.externalLink?.service, .appleTV)
        let link = try await provider.externalMediaLink(for: item.id, mediaSourceID: path)
        XCTAssertEqual(link.service, .appleTV)
        let limits = await fileSystem.readLimits
        XCTAssertFalse(limits.isEmpty)
        XCTAssertTrue(limits.allSatisfy { $0 == ExternalMediaLink.maximumFileBytes })
        do {
            _ = try await provider.playbackInfo(for: item.id, mediaSourceID: path, forceTranscode: false)
            XCTFail("An external link must not enter the player")
        } catch { XCTAssertTrue(error is AppError) }
        let locator = try await provider.playbackPreparationLocator(for: item.id, mediaSourceID: path)
        XCTAssertNil(locator)
        let openingCalls = await fileSystem.openingCalls
        XCTAssertEqual(openingCalls, 0)
    }

    private func makeProvider(
        stat: RemoteFileEntry,
        streamProber: NetworkFileStreamProbing? = nil,
        fileSystem: LocatorFakeFileSystem? = nil,
        baseURL: URL = URL(string: "https://nas.example.com/dav")!
    ) -> ShareProvider {
        let fileSystem = fileSystem ?? LocatorFakeFileSystem(statEntry: stat)
        let session = LocatorFakeSession(fileSystem: fileSystem)
        let server = MediaServer(
            id: "share:https://nas.example.com/dav#anon",
            name: "DAV",
            baseURL: baseURL,
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
            catalogCoordinator: ShareCatalogCoordinator(initialWorkScope: .paused),
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

    func testPlayUsesFreshListingMetadataWithoutAnotherOpeningStat() async throws {
        let path = "Movies/movie.mkv"
        let old = try RemoteFileEntry(
            relativePath: path, kind: .file, size: 1024, strongETag: "\"old\""
        )
        let current = try RemoteFileEntry(
            relativePath: path, kind: .file, size: 8192,
            modifiedAt: Date(timeIntervalSince1970: 20), strongETag: "\"current\""
        )
        let fileSystem = LocatorFakeFileSystem(statEntry: old, listedEntries: [current])
        let provider = makeProvider(stat: old, fileSystem: fileSystem)
        addTeardownBlock { await provider.teardown() }
        let request = try await provider.playbackInfo(for: "f:\(path)")
        guard case .networkFile(let locator) = request.playbackSource else {
            return XCTFail("Expected network-file playback")
        }
        XCTAssertEqual(locator.relativePath, path)
        XCTAssertEqual(locator.representation.size, 8192)
        XCTAssertEqual(locator.representation.identity.kind, .strongETag)
        XCTAssertEqual(locator.representation.identity.value, "\"current\"")
        let openingCalls = await fileSystem.openingCalls
        let listingCalls = await fileSystem.listingCalls
        XCTAssertEqual(openingCalls, 0)
        XCTAssertEqual(listingCalls, 1, "Subtitles must reuse this request's parent listing")
    }

    func testPlayDoesNotCacheListingAcrossRequestsAndSupportsModificationTimeIdentity() async throws {
        let path = "movie.mkv"
        let first = try RemoteFileEntry(
            relativePath: path, kind: .file, size: 1024,
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
        let second = try RemoteFileEntry(
            relativePath: path, kind: .file, size: 2048,
            modifiedAt: Date(timeIntervalSince1970: 20)
        )
        let fileSystem = LocatorFakeFileSystem(statEntry: first, listedEntries: [first])
        let provider = makeProvider(stat: first, fileSystem: fileSystem)
        addTeardownBlock { await provider.teardown() }
        let firstRequest = try await provider.playbackInfo(for: "f:\(path)")
        await fileSystem.replaceListing([second])
        let secondRequest = try await provider.playbackInfo(for: "f:\(path)")
        guard case .networkFile(let firstLocator) = firstRequest.playbackSource,
              case .networkFile(let secondLocator) = secondRequest.playbackSource else {
            return XCTFail("Expected network-file playback")
        }
        XCTAssertEqual(firstLocator.representation.identity.modifiedAt, first.modifiedAt)
        XCTAssertEqual(secondLocator.representation.identity.kind, .modificationTime)
        XCTAssertEqual(secondLocator.representation.identity.modifiedAt, second.modifiedAt)
        XCTAssertEqual(secondLocator.representation.size, 2048)
        let openingCalls = await fileSystem.openingCalls
        let listingCalls = await fileSystem.listingCalls
        XCTAssertEqual(openingCalls, 0)
        XCTAssertEqual(listingCalls, 2)
    }

    func testOtherTransportsKeepAuthoritativeOpeningStat() async throws {
        let listed = try RemoteFileEntry(
            relativePath: "movie.mkv", kind: .file, size: 1024,
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
        let opening = try RemoteFileEntry(
            relativePath: "movie.mkv", kind: .file, size: 2048,
            modifiedAt: Date(timeIntervalSince1970: 10.5)
        )
        for scheme in ["smb", "nfs", "sftp", "ftp", "ftps"] {
            let fileSystem = LocatorFakeFileSystem(statEntry: opening, listedEntries: [listed])
            let provider = makeProvider(
                stat: opening, fileSystem: fileSystem,
                baseURL: try XCTUnwrap(URL(string: "\(scheme)://nas.example.com/Media"))
            )
            addTeardownBlock { await provider.teardown() }
            let request = try await provider.playbackInfo(for: "f:movie.mkv")
            guard case .networkFile(let locator) = request.playbackSource else {
                return XCTFail("Expected network-file playback")
            }
            XCTAssertEqual(locator.representation.size, 2048)
            XCTAssertEqual(locator.representation.identity.modifiedAt, opening.modifiedAt)
            let openingCalls = await fileSystem.openingCalls
            let listingCalls = await fileSystem.listingCalls
            XCTAssertEqual(openingCalls, 1, scheme)
            XCTAssertEqual(listingCalls, 1, scheme)
        }
    }

    func testIncompleteAmbiguousOrDifferentListingFallsBackToOpeningMetadata() async throws {
        let path = "Movies/movie.mkv"
        let opening = try RemoteFileEntry(
            relativePath: path, kind: .file, size: 4096, strongETag: "\"opening\""
        )
        let cases: [[RemoteFileEntry]] = [
            [],
            [try RemoteFileEntry(relativePath: path, kind: .file, size: 4096)],
            [try RemoteFileEntry(relativePath: path, kind: .file, strongETag: "\"listed\"")],
            [try RemoteFileEntry(relativePath: path, kind: .directory)],
            [try RemoteFileEntry(
                relativePath: "Elsewhere/movie.mkv", kind: .file, size: 4096, strongETag: "\"elsewhere\""
            )],
            [opening, opening]
        ]
        for entries in cases {
            let fileSystem = LocatorFakeFileSystem(statEntry: opening, listedEntries: entries)
            let provider = makeProvider(stat: opening, fileSystem: fileSystem)
            addTeardownBlock { await provider.teardown() }
            let request = try await provider.playbackInfo(for: "f:\(path)")
            guard case .networkFile(let locator) = request.playbackSource else {
                return XCTFail("Expected network-file playback")
            }
            XCTAssertEqual(locator.relativePath, path)
            XCTAssertEqual(locator.representation.identity.value, "\"opening\"")
            let openingCalls = await fileSystem.openingCalls
            let listingCalls = await fileSystem.listingCalls
            XCTAssertEqual(openingCalls, 1)
            XCTAssertEqual(listingCalls, 1)
        }
    }

    func testUnlistableParentStillUsesOpeningStatAndLegacySubtitleProbes() async throws {
        let entry = try RemoteFileEntry(
            relativePath: "movie.mkv", kind: .file, size: 4096, strongETag: "\"opening\""
        )
        let fileSystem = LocatorFakeFileSystem(statEntry: entry, listingError: .permissionDenied)
        let provider = makeProvider(stat: entry, fileSystem: fileSystem)
        addTeardownBlock { await provider.teardown() }
        let request = try await provider.playbackInfo(for: "f:movie.mkv")
        guard case .networkFile(let locator) = request.playbackSource else {
            return XCTFail("Expected network-file playback")
        }
        XCTAssertEqual(locator.representation.identity.value, "\"opening\"")
        let openingCalls = await fileSystem.openingCalls
        let listingCalls = await fileSystem.listingCalls
        XCTAssertEqual(openingCalls, 1)
        XCTAssertEqual(listingCalls, 5)
    }

    func testCancelledOpeningListingDoesNotStartStatOrSubtitleFallback() async throws {
        let wasEnabled = HandoffDiagnostics.isEnabled
        HandoffDiagnostics.setEnabled(true)
        defer { HandoffDiagnostics.setEnabled(wasEnabled) }
        let entry = try RemoteFileEntry(
            relativePath: "movie.mkv", kind: .file, size: 4096, strongETag: "\"opening\""
        )
        let fileSystem = LocatorFakeFileSystem(statEntry: entry, listingError: .cancelled)
        let provider = makeProvider(stat: entry, fileSystem: fileSystem)
        addTeardownBlock { await provider.teardown() }
        do {
            _ = try await provider.playbackInfo(for: "f:movie.mkv")
            XCTFail("Cancellation must not become successful playback")
        } catch {
            XCTAssertEqual(error as? MediaTransportError, .cancelled)
        }
        let diagnostic = try XCTUnwrap(HandoffDiagnostics.persistentPlaybackLogText()
            .components(separatedBy: "\n").last { $0.contains("sharePlayback") })
        XCTAssertTrue(diagnostic.contains("stage=locator event=cancelled error=transport.cancelled"))
        let openingCalls = await fileSystem.openingCalls
        let listingCalls = await fileSystem.listingCalls
        XCTAssertEqual(openingCalls, 0)
        XCTAssertEqual(listingCalls, 1)
    }

    func testDetailPreparationResolvesExactFileWithoutSidecarWork() async throws {
        let entry = try RemoteFileEntry(
            relativePath: "Episode.mkv", kind: .file, size: 4096, strongETag: "\"episode\""
        )
        let fileSystem = LocatorFakeFileSystem(statEntry: entry)
        let provider = makeProvider(stat: entry, fileSystem: fileSystem)
        addTeardownBlock { await provider.teardown() }
        let prepared = try await provider.playbackPreparationLocator(
            for: "f:Episode.mkv", mediaSourceID: "Episode.mkv"
        )
        let locator = try XCTUnwrap(prepared)
        XCTAssertEqual(locator.relativePath, "Episode.mkv")
        XCTAssertEqual(locator.representation.identity.value, "\"episode\"")
        let openingCalls = await fileSystem.openingCalls
        let listingCalls = await fileSystem.listingCalls
        let fileReads = await fileSystem.fileReads
        XCTAssertEqual(openingCalls, 1)
        XCTAssertEqual(listingCalls, 0)
        XCTAssertEqual(fileReads, 0)
    }

    func testExactFileProofDoesNotInventAVersionForLogicalItems() {
        let episode = MediaItem(id: "f:Show/Episode.mkv", title: "Episode", kind: .episode)
        XCTAssertEqual(ShareProvider.exactFileRelativePath(for: episode), "Show/Episode.mkv")
        for id in ["movie:show", "series:show", "d:Show"] {
            XCTAssertNil(ShareProvider.exactFileRelativePath(
                for: MediaItem(id: id, title: "Logical item", kind: .movie)
            ))
        }
    }

    func testDetailPreparationRejectsAnotherFilesVersionBeforeNetworkWork() async throws {
        let entry = try RemoteFileEntry(
            relativePath: "Episode.mkv", kind: .file, size: 4096, strongETag: "\"episode\""
        )
        let fileSystem = LocatorFakeFileSystem(statEntry: entry)
        let provider = makeProvider(stat: entry, fileSystem: fileSystem)
        addTeardownBlock { await provider.teardown() }
        do {
            _ = try await provider.playbackPreparationLocator(
                for: "f:Episode.mkv", mediaSourceID: "Another.mkv"
            )
            XCTFail("A different file must not be prepared")
        } catch let error as MediaTransportError {
            guard case .sourceChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let openingCalls = await fileSystem.openingCalls
        XCTAssertEqual(openingCalls, 0)
    }

    func testDetailPreparationDoesNotChangeOtherShareTransports() async throws {
        let entry = try RemoteFileEntry(
            relativePath: "Episode.mkv", kind: .file, size: 4096, strongETag: "\"episode\""
        )
        let fileSystem = LocatorFakeFileSystem(statEntry: entry)
        let provider = makeProvider(
            stat: entry, fileSystem: fileSystem, baseURL: URL(string: "smb://nas.example.com/Media")!
        )
        addTeardownBlock { await provider.teardown() }
        let locator = try await provider.playbackPreparationLocator(
            for: "f:Episode.mkv", mediaSourceID: "Episode.mkv"
        )
        XCTAssertNil(locator)
        let openingCalls = await fileSystem.openingCalls
        XCTAssertEqual(openingCalls, 0)
    }

    func testISOPlaybackKeepsLargeFileIdentityAndUsesNetworkReader() async throws {
        let path = "Movies/Disc (2024).ISO"
        let entry = try RemoteFileEntry(
            relativePath: path, kind: .file, size: 31_316_770_816, strongETag: "\"disc-1\""
        )
        let request = try await makeProvider(stat: entry).playbackInfo(
            for: "f:\(path)", mediaSourceID: nil, forceTranscode: false
        )
        guard case .networkFile(let locator) = request.playbackSource else {
            return XCTFail("ISO playback must use the existing authenticated network-file resolver")
        }
        XCTAssertEqual(locator.relativePath, path)
        XCTAssertEqual(locator.formatHint.container, "iso")
        XCTAssertEqual(locator.representation.size, 31_316_770_816)
        XCTAssertEqual(locator.representation.identity.value, "\"disc-1\"")
        XCTAssertNil(request.streamURL)
        XCTAssertEqual(request.item.id, "f:\(path)")
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

    func testLocatorUsesOpeningMetadataWithoutChangingOrdinaryStat() async throws {
        let listed = try RemoteFileEntry(relativePath: "movie.mkv", kind: .file, size: 4096)
        let opening = try RemoteFileEntry(
            relativePath: "movie.mkv", kind: .file, size: 4096, strongETag: "\"get-validator\""
        )
        let fileSystem = LocatorFakeFileSystem(statEntry: listed, openingEntry: opening)
        let provider = makeProvider(stat: listed, fileSystem: fileSystem)
        let locator = try await provider.networkFileLocator(for: "movie.mkv")
        XCTAssertEqual(locator.representation.identity.value, "\"get-validator\"")
        let ordinary = try await fileSystem.stat(relativePath: "movie.mkv")
        XCTAssertNil(ordinary.strongETag)
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
    private let openingEntry: RemoteFileEntry?
    private var listedEntries: [RemoteFileEntry]
    private let listingError: MediaTransportError?
    private(set) var openingCalls = 0
    private(set) var listingCalls = 0
    private(set) var fileReads = 0
    private(set) var readLimits: [Int] = []
    private let fileContents: Data
    private let directoryTree: [String: [RemoteFileEntry]]?
    private let deniedDirectories: Set<String>
    private(set) var listedPaths: [String] = []

    init(
        statEntry: RemoteFileEntry, openingEntry: RemoteFileEntry? = nil,
        listedEntries: [RemoteFileEntry] = [], listingError: MediaTransportError? = nil,
        fileContents: Data = Data(), directoryTree: [String: [RemoteFileEntry]]? = nil,
        deniedDirectories: Set<String> = []
    ) {
        self.statEntry = statEntry
        self.openingEntry = openingEntry
        self.listedEntries = listedEntries
        self.listingError = listingError
        self.fileContents = fileContents
        self.directoryTree = directoryTree
        self.deniedDirectories = deniedDirectories
    }

    func replaceStat(_ entry: RemoteFileEntry) { statEntry = entry }
    func replaceListing(_ entries: [RemoteFileEntry]) { listedEntries = entries }

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

    func list(relativePath: String) async throws -> [RemoteFileEntry] {
        listingCalls += 1
        listedPaths.append(relativePath)
        if deniedDirectories.contains(relativePath) { throw MediaTransportError.permissionDenied }
        if let listingError { throw listingError }
        if let directoryTree { return directoryTree[relativePath] ?? [] }
        return listedEntries
    }

    func stat(relativePath: String) async throws -> RemoteFileEntry { statEntry }

    func statForOpening(relativePath: String) async throws -> RemoteFileEntry {
        openingCalls += 1
        return openingEntry ?? statEntry
    }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        fileReads += 1
        readLimits.append(maximumBytes)
        return fileContents
    }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        throw MediaTransportError.unsupportedCapability("test")
    }
}
