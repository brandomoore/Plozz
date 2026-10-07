#if os(iOS)
import CoreModels
import CoreUI
import Foundation
import MediaDownloads
import MediaTransportCore
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS

@MainActor
final class DownloadPresentationTests: XCTestCase {
    func testUnavailableBackdropFallsBackToDecodablePoster() async throws {
        let data = imageData()
        let prefix = "https://download-artwork.invalid/\(UUID())"
        let backdrop = try XCTUnwrap(URL(string: "\(prefix)/backdrop"))
        let fallback = try XCTUnwrap(URL(string: "\(prefix)/fallback"))
        let poster = try XCTUnwrap(URL(string: "\(prefix)/poster"))
        try cache(backdrop, status: 404, data: Data("Not found".utf8))
        try cache(fallback, status: 200, data: Data("<html>Not an image</html>".utf8))
        try cache(poster, status: 200, data: data)
        let item = MediaItem(
            id: "movie", title: "Movie", kind: .movie,
            posterURL: poster, backdropURL: backdrop, fallbackArtworkURL: fallback
        )

        let pinned = try await PlozziOSDownloadArtwork.load(for: item)
        XCTAssertNotNil(UIImage(data: pinned))
        XCTAssertEqual(PlozziOSDownloadArtwork.references(for: item), [
            .remote(backdrop), .remote(fallback), .remote(poster)
        ])
    }

    func testExistingDownloadsRepairMissingAndCorruptArtworkWithoutChangingMedia() async throws {
        let storage = try temporaryStorage()
        let fixtures = (0..<4).map { record(id: "episode-\($0)") }
        var records = fixtures
        for index in 1..<4 { records[index].snapshot.artworkFileName = "artwork.img" }
        for index in [2, 3] {
            let folder = try storage.pinnedFolderURL(forKey: records[index].identityKey)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (index == 2 ? Data("broken image".utf8) : imageData())
                .write(to: folder.appendingPathComponent("artwork.img"))
        }
        let store = InMemoryDownloadedMediaStore(.init(records: Dictionary(
            uniqueKeysWithValues: records.map { ($0.identityKey, $0) }
        )))
        let registry = DownloadedMediaRegistry(store: store)
        let probe = ArtworkProbe(data: imageData())
        let model = makeModel(registry: registry, storage: storage, probe: probe)
        defer { model.beginProfileTransition() }
        try await waitUntil { model.records.count == 4 }
        await model.refreshArtwork()

        for original in records {
            let current = try XCTUnwrap(model.records.first { $0.identityKey == original.identityKey })
            let localURL = try XCTUnwrap(model.artworkURL(for: current))
            XCTAssertNotNil(UIImage(contentsOfFile: localURL.path))
            XCTAssertEqual(current.status, .completed)
            XCTAssertEqual(current.bytesDownloaded, original.bytesDownloaded)
            XCTAssertEqual(current.localFileName, original.localFileName)
            XCTAssertEqual(current.snapshot.sourceAccountID, original.snapshot.sourceAccountID)
            XCTAssertEqual(current.snapshot.sourceItemID, original.snapshot.sourceItemID)
        }
        let calls = await probe.calls
        XCTAssertEqual(calls, 3, "A valid pinned image must not be fetched again.")
        XCTAssertEqual(model.records.first { $0.identityKey == records[3].identityKey }?.snapshot.artworkFileName, "artwork.img")
        model.beginProfileTransition()

        let reopened = makeModel(registry: DownloadedMediaRegistry(store: store), storage: storage, probe: probe)
        defer { reopened.beginProfileTransition() }
        try await waitUntil { reopened.records.count == 4 }
        await reopened.refreshArtwork()
        let reopenedCalls = await probe.calls
        XCTAssertEqual(reopenedCalls, calls, "Pinned artwork must survive a fresh registry/model without contacting a server.")
    }

    func testFailedArtworkCanRecoverOnTheNextVisit() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let record = record()
        _ = try await registry.beginDownload(record)
        let probe = ArtworkProbe(data: imageData(), failures: .max)
        let model = makeModel(registry: registry, storage: try temporaryStorage(), probe: probe)
        defer { model.beginProfileTransition() }
        try await waitUntil { model.records.count == 1 }
        await model.refreshArtwork()
        XCTAssertNil(model.records.first?.snapshot.artworkFileName)
        XCTAssertEqual(model.records.first?.status, .completed)
        let failedCalls = await probe.calls
        XCTAssertGreaterThan(failedCalls, 0)
        try await registry.setRuntime(identityKey: record.identityKey, runtime: 321)
        try await waitUntil { model.records.first?.snapshot.runtime == 321 }
        let callsAfterUpdate = await probe.calls
        XCTAssertEqual(callsAfterUpdate, failedCalls, "Ordinary record updates must respect the repair cooldown.")

        await probe.allowSuccess()
        await model.refreshArtwork()
        XCTAssertNotNil(model.records.first?.snapshot.artworkFileName)
        let calls = await probe.calls
        XCTAssertEqual(calls, failedCalls + 1)
    }

    func testProfileTransitionDiscardsLateArtworkWithoutTouchingTheMediaFile() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let record = record()
        _ = try await registry.beginDownload(record)
        let storage = try temporaryStorage()
        let folder = try storage.pinnedFolderURL(forKey: record.identityKey)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mediaURL = try storage.pinnedFileURL(for: record)
        let media = Data("downloaded media".utf8)
        try media.write(to: mediaURL)
        let probe = ArtworkProbe(data: imageData(), blocked: true)
        let model = makeModel(registry: registry, storage: storage, probe: probe)
        let refresh = Task { await model.refreshArtwork() }
        try await waitUntil { await probe.calls == 1 }
        model.beginProfileTransition()
        await probe.release()
        await refresh.value

        let current = await registry.record(forKey: record.identityKey)
        XCTAssertNil(current?.snapshot.artworkFileName)
        XCTAssertEqual(try Data(contentsOf: mediaURL), media)
        XCTAssertEqual(current?.status, .completed)
    }

    func testRecoveryDoesNotUseAnExpensiveNetworkWithoutPermission() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        _ = try await registry.beginDownload(record())
        let probe = ArtworkProbe(data: imageData(), blocked: true)
        let observer = StaticDownloadNetworkObserver(.init(isSatisfied: true, isExpensive: true, isConstrained: false))
        let model = makeModel(registry: registry, storage: try temporaryStorage(), probe: probe, observer: observer)
        defer { model.beginProfileTransition() }
        try await waitUntil { model.records.count == 1 }
        await model.refreshArtwork()
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.records.first?.status, .completed)

        model.allowsCellular = true
        let refresh = Task { await model.refreshArtwork() }
        try await waitUntil { await probe.calls == 1 }
        model.allowsCellular = false
        await probe.release()
        await refresh.value
        XCTAssertNil(model.records.first?.snapshot.artworkFileName)
        XCTAssertEqual(model.records.first?.status, .completed)

        model.allowsCellular = true
        await model.refreshArtwork()
        XCTAssertNotNil(model.records.first?.snapshot.artworkFileName)
    }

    func testCachedVersionAndIdentityLookupsObserveCompletionAndRemoval() async throws {
        for version in [nil, "file-1080p"] as [String?] {
            var item = MediaItem(
                id: "movie", title: "Movie", kind: .movie,
                providerIDs: ["imdb": "tt1234"], sourceAccountID: "emby"
            )
            item.selectedVersionID = version
            let record = DownloadedMediaRecord(
                identity: try XCTUnwrap(DownloadMediaIdentity.primary(for: item)),
                versionID: version, sourceKind: .managedHTTP, status: .downloading,
                localFileName: "media.mkv", bytesDownloaded: 100, totalBytes: 100,
                snapshot: PinnedMediaSnapshot(item: item)
            )
            let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
            _ = try await registry.beginDownload(record)
            let model = makeModel(
                registry: registry, storage: try temporaryStorage(),
                probe: ArtworkProbe(data: imageData()), startsActive: false
            )
            defer { model.beginProfileTransition() }
            try await waitUntil { model.cachedRecord(forSelectedVersionOf: item) != nil }
            let completed = expectation(description: "Cached lookup publishes completion")
            withObservationTracking {
                XCTAssertEqual(model.cachedRecord(forSelectedVersionOf: item)?.status, .downloading)
            } onChange: {
                completed.fulfill()
            }
            try await registry.markCompleted(identityKey: record.identityKey, totalBytes: 100)
            await fulfillment(of: [completed], timeout: 3)
            try await waitUntil { model.cachedRecord(forSelectedVersionOf: item)?.status == .completed }

            let removed = expectation(description: "Cached lookup publishes removal")
            withObservationTracking {
                XCTAssertNotNil(model.cachedRecord(for: item))
            } onChange: {
                removed.fulfill()
            }
            try await registry.remove(identityKey: record.identityKey)
            await fulfillment(of: [removed], timeout: 3)
            try await waitUntil { model.cachedRecord(for: item) == nil }
        }
    }

    func testWholeShowCompletionIsVisibleButOneHundredPercentAloneIsNotCompletion() throws {
        let completed = [record(id: "first"), record(id: "second")]
        var show = try XCTUnwrap(PlozziOSDownloadLibrary.make(from: completed).shows.first)
        XCTAssertEqual(show.status, .completed)
        XCTAssertEqual(show.fractionCompleted, 1)
        XCTAssertTrue(try renderedStatus(show).contains("Available offline"))
        let frenchStatus = try renderedStatus(show, language: "fr")
        XCTAssertTrue(frenchStatus.contains("Disponible hors ligne"), frenchStatus)

        var finishing = completed
        finishing[1].status = .downloading
        show = try XCTUnwrap(PlozziOSDownloadLibrary.make(from: finishing).shows.first)
        XCTAssertEqual(show.status, .downloading)
        XCTAssertEqual(show.fractionCompleted, 1)
        XCTAssertFalse(try renderedStatus(show).contains("Available offline"))

        finishing[1].status = .failed
        show = try XCTUnwrap(PlozziOSDownloadLibrary.make(from: finishing).shows.first)
        XCTAssertEqual(show.status, .failed)
        XCTAssertTrue(try renderedStatus(show).contains("Failed"))
    }

    private func renderedStatus(_ show: PlozziOSDownloadedShow, language: String = "en") throws -> String {
        let renderer = ImageRenderer(content: DownloadFormatting.status(for: show)
            .font(.title2).foregroundStyle(.black).padding()
            .frame(width: 900).background(.white).environment(\.locale, Locale(identifier: language)))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = [language == "fr" ? "fr-FR" : "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func makeModel(
        registry: DownloadedMediaRegistry, storage: any DownloadStorageLocating,
        probe: ArtworkProbe, startsActive: Bool = true,
        observer: any DownloadNetworkObserving = StaticDownloadNetworkObserver()
    ) -> PlozziOSDownloadsModel {
        PlozziOSDownloadsModel(
            profileID: "download-test-\(UUID())", registry: registry, storage: storage,
            networkObserver: observer, networkFileResolver: UnusedNetworkResolver(),
            providerKind: { _ in .emby }, preferredAudioLanguages: { _ in [] },
            startsActive: startsActive,
            resolveArtworkItem: { record in
                MediaItem(id: record.snapshot.sourceItemID ?? "item", title: record.snapshot.title, kind: record.snapshot.kind)
            },
            loadArtwork: { try await probe.load($0) },
            managedURLResolver: { _, _, _ in throw CancellationError() }
        )
    }

    private func record(id: String = "episode") -> DownloadedMediaRecord {
        DownloadedMediaRecord(
            identity: .external(source: "plozz-account:emby", value: id),
            sourceKind: .managedHTTP, status: .completed, localFileName: "media.mkv",
            bytesDownloaded: 100, totalBytes: 100,
            snapshot: .init(
                title: id, kind: .episode, sourceAccountID: "emby", sourceItemID: id,
                seriesTitle: "Show", seriesID: "show", seasonNumber: 1
            )
        )
    }

    private func imageData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 100, height: 60)).pngData { context in
            UIColor.magenta.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        }
    }

    private func cache(_ url: URL, status: Int, data: Data) throws {
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        let request = URLRequest(url: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
        addTeardownBlock { cache.removeCachedResponse(for: request) }
    }

    private func temporaryStorage() throws -> TemporaryDownloadStorage {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return TemporaryDownloadStorage(root: root)
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let satisfied = await predicate()
        XCTAssertTrue(satisfied)
    }
}

private struct TemporaryDownloadStorage: DownloadStorageLocating {
    let root: URL
    func pinnedMediaDirectory() throws -> URL { root }
}

private struct UnusedNetworkResolver: MediaTransportNetworkFileResolving {
    func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
        throw CancellationError()
    }
}

private actor ArtworkProbe {
    let data: Data
    var failures: Int
    var blocked: Bool
    var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    init(data: Data, failures: Int = 0, blocked: Bool = false) {
        self.data = data
        self.failures = failures
        self.blocked = blocked
    }

    func load(_ item: MediaItem) async throws -> Data {
        calls += 1
        if blocked { await withCheckedContinuation { continuation = $0 } }
        if failures > 0 {
            failures -= 1
            throw URLError(.notConnectedToInternet)
        }
        return data
    }

    func release() {
        blocked = false
        continuation?.resume()
        continuation = nil
    }

    func allowSuccess() {
        failures = 0
    }
}
#endif
