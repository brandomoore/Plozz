import CoreModels
import Foundation
import XCTest
@testable import MediaDownloads

final class OfflineSubtitleStoreTests: XCTestCase {
    private let srt = Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n\n".utf8)

    func testPersistsTextAndMetadataAndResolvesWithoutProviderAccess() async throws {
        let directory = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FixedDownloadStorageLocator(root: directory)
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let record = try DownloadTestFactory.record()
        _ = try await registry.beginDownload(record)
        let video = try storage.pinnedFileURL(for: record)
        try FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: video)
        let track = MediaTrack(
            id: 8, kind: .subtitle, displayTitle: "English SDH", language: "en", codec: "srt",
            isForced: true, isHearingImpaired: true, isExternal: true
        )
        try OfflineSubtitleStore.save([.init(track: track, data: srt, format: "subrip")], beside: video)
        try await registry.markCompleted(identityKey: record.identityKey, totalBytes: 1, subtitleStatus: .saved)
        let resolver = RegistryOfflinePlaybackResolver(registry: registry, storage: storage)
        let tracks = resolver.subtitleTracks(at: video)
        XCTAssertEqual(tracks.count, 1)
        let loaded = try XCTUnwrap(tracks.first)
        XCTAssertEqual(loaded.language, "en")
        XCTAssertEqual(loaded.displayTitle, "English SDH")
        XCTAssertEqual(loaded.codec, "srt")
        XCTAssertTrue(loaded.isForced)
        XCTAssertTrue(loaded.isHearingImpaired)
        guard case .localFile(let url)? = loaded.deliverySource else { return XCTFail("Must resolve locally") }
        XCTAssertEqual(try Data(contentsOf: url), srt)
        let index = try Data(contentsOf: video.appendingPathExtension("subtitles.json"))
        XCTAssertFalse(String(decoding: index, as: UTF8.self).contains("http"))
        let denied = RegistryOfflinePlaybackResolver(registry: registry, storage: storage, authorizesRecord: { _ in false })
        let blocked = await denied.localSubtitleTracks(for: DownloadTestFactory.movie(), versionID: nil)
        XCTAssertTrue(blocked.isEmpty)
    }

    func testPartialRefreshPreservesSavedFilesAndFullReplacementCleansThem() throws {
        let directory = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("media.mkv")
        let track = MediaTrack(id: 1, kind: .subtitle, displayTitle: "English", language: "en")
        try OfflineSubtitleStore.save([.init(track: track, data: srt, format: "srt")], beside: video)
        let old = try XCTUnwrap(OfflineSubtitleStore.files(beside: video).first)
        try OfflineSubtitleStore.save([], beside: video, preservingExisting: true)
        XCTAssertEqual(try OfflineSubtitleStore.files(beside: video).count, 1)
        let replacement = Data("WEBVTT\n\n00:00:03.000 --> 00:00:04.000\nReplacement\n\n".utf8)
        try OfflineSubtitleStore.save([.init(track: track, data: replacement, format: "vtt")], beside: video)
        XCTAssertEqual(try OfflineSubtitleStore.files(beside: video).map(\.codec), ["vtt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(old.fileName).path))
    }

    func testInvalidPayloadNeverReplacesPublishedIndexAndStagingIsRemoved() throws {
        let directory = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("media.mkv")
        let track = MediaTrack(id: 1, kind: .subtitle, displayTitle: "Text")
        try OfflineSubtitleStore.save([.init(track: track, data: srt, format: "srt")], beside: video)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let index = try Data(contentsOf: video.appendingPathExtension("subtitles.json"))
        for invalid in [Data(), Data("<html>sign in</html>".utf8), Data(repeating: 65, count: OfflineSubtitleStore.maximumFileBytes + 1)] {
            XCTAssertThrowsError(try OfflineSubtitleStore.save([
                .init(track: track, data: Data("1\n00:00:03,000 --> 00:00:04,000\nNew\n".utf8), format: "srt"),
                .init(track: track, data: invalid, format: "srt")
            ], beside: video))
            XCTAssertEqual(try Data(contentsOf: video.appendingPathExtension("subtitles.json")), index)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
        }
    }

    func testLegacySiloIndexAndUnsafePaths() throws {
        let directory = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("media.mp4")
        try srt.write(to: directory.appendingPathComponent("silo-subtitle-0.srt"))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link.srt").path,
                                                  withDestinationPath: directory.appendingPathComponent("silo-subtitle-0.srt").path)
        let json = """
        [{"fileName":"silo-subtitle-0.srt","language":"en","codec":"srt","forced":false,"hearingImpaired":true},
         {"fileName":"../outside.srt","codec":"srt","forced":false,"hearingImpaired":false},
         {"fileName":"link.srt","codec":"srt","forced":false,"hearingImpaired":false}]
        """
        try Data(json.utf8).write(to: video.appendingPathExtension("subtitles.json"))
        let files = try OfflineSubtitleStore.files(beside: video)
        XCTAssertEqual(files.map(\.fileName), ["silo-subtitle-0.srt"])
        XCTAssertNil(files.first?.displayTitle)
    }

    func testRefreshRepairsCorruptIndexAndExistingPayload() throws {
        let directory = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("media.mkv")
        let track = MediaTrack(id: 1, kind: .subtitle, displayTitle: "English")
        let assets = [OfflineSubtitleAsset(track: track, data: srt, format: "srt")]
        try OfflineSubtitleStore.save(assets, beside: video)
        let file = try XCTUnwrap(OfflineSubtitleStore.files(beside: video).first)
        let url = directory.appendingPathComponent(file.fileName)
        try Data("damaged".utf8).write(to: url)
        try Data("{".utf8).write(to: video.appendingPathExtension("subtitles.json"))
        try OfflineSubtitleStore.save(assets, beside: video)
        XCTAssertEqual(try Data(contentsOf: url), srt)
        XCTAssertEqual(try OfflineSubtitleStore.files(beside: video).count, 1)
    }

    func testPartialRefreshCannotGrowBeyondTrackLimit() throws {
        let directory = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("media.mkv")
        let track = MediaTrack(id: 1, kind: .subtitle, displayTitle: "Text")
        let assets = (0..<OfflineSubtitleStore.maximumTracks).map { index in
            OfflineSubtitleAsset(
                track: track, data: Data("1\n00:00:01,000 --> 00:00:02,000\nLine \(index)\n".utf8), format: "srt"
            )
        }
        try OfflineSubtitleStore.save(assets, beside: video)
        let indexURL = video.appendingPathExtension("subtitles.json")
        let original = try Data(contentsOf: indexURL)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertThrowsError(try OfflineSubtitleStore.save(
            [.init(track: track, data: srt, format: "srt")], beside: video, preservingExisting: true
        ))
        XCTAssertEqual(try Data(contentsOf: indexURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), names)
    }
}
