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
    func testShowDownloadActionUsesSharedLayoutWithoutInventingEpisodeTotals() throws {
        for (seasonCount, completedCount) in [(3, 8), (0, 0)] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let renderer = ImageRenderer(content:
                    PlozziOSShowDownloadActionLabel(
                        title: Text(verbatim: "Avatar: The Last Airbender"),
                        seasonCount: seasonCount, completedCount: completedCount
                    ) {
                        SeasonDownloadRowArtwork(showsMediaEdge: false) { Color.red }
                    } accessory: {
                        PlozziOSBulkDownloadActionControl(action: .download, state: nil)
                    }
                    .frame(width: 320)
                    .padding(16)
                    .background(.black)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en"))
                    .environment(\.dynamicTypeSize, size)
                )
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.width, 1056)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.customWords = ["Download All"]
                try VNImageRequestHandler(cgImage: image).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                XCTAssertTrue(text.contains("Airbender"), text)
                XCTAssertTrue(text.contains("Download"), text)
                XCTAssertEqual(text.contains("Seasons:"), seasonCount > 0, text)
                XCTAssertEqual(text.contains("Downloaded:"), completedCount > 0, text)
                if completedCount > 0 {
                    XCTAssertTrue(text.contains("8"), text)
                    XCTAssertTrue(text.contains("3"), text)
                }
                XCTAssertFalse(text.contains("Episodes:"), "Unknown episode totals must not appear as zero.")
                XCTAssertFalse(text.contains("iPhone"), text)
                XCTAssertFalse(text.contains("offline"), text)
                let attachment = XCTAttachment(image: UIImage(cgImage: image))
                attachment.name = "show-download-summary-\(seasonCount)-\(completedCount)-\(size)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testSeasonDownloadActionDisplaysArtworkWithoutDecorativeDownloadIcon() throws {
        for size in [DynamicTypeSize.large, .accessibility3] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let content = PlozziOSSeasonDownloadActionLabel(
                    title: Text(verbatim: "The Final Season: The Battle for the Future of the Four Nations"),
                    episodeCount: 20
                ) {
                    SeasonDownloadRowArtwork(showsMediaEdge: false) { Color.red }
                } accessory: {
                    PlozziOSBulkDownloadActionControl(action: .download, state: nil)
                }
                .frame(width: 320)
                .padding(16)
                .background(.black)
                .tint(.blue)
                .environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.dynamicTypeSize, size)
                .environment(\.layoutDirection, direction)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.width, 704)
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(
                        data: buffer.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                var redMinX = image.width
                var redMaxX = -1
                var bluePixels = 0
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    if pixels[offset] > 200, pixels[offset + 1] < 80, pixels[offset + 2] < 80 {
                        let x = (offset / 4) % image.width
                        redMinX = min(redMinX, x)
                        redMaxX = max(redMaxX, x)
                    }
                    if pixels[offset] < 80, pixels[offset + 1] < 180, pixels[offset + 2] > 220 {
                        bluePixels += 1
                    }
                }
                XCTAssertEqual(redMaxX - redMinX + 1, 92, "Season artwork stays 46 points wide.")
                XCTAssertEqual(bluePixels, 0, "Only the trailing control should show a download glyph.")
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.customWords = ["Download All"]
                try VNImageRequestHandler(cgImage: image).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                XCTAssertTrue(text.contains("The Final"), text)
                XCTAssertTrue(text.contains("Nations"), text)
                XCTAssertTrue(text.contains("20"), text)
                XCTAssertTrue(text.contains("Download"), text)
                XCTAssertTrue(
                    (request.results ?? []).contains {
                        $0.topCandidates(1).first?.string.contains("Download ") == true
                    },
                    "The action should fit on one rendered line before the title uses its space: \(text)"
                )
                if let action = request.results?.first(where: {
                    $0.topCandidates(1).first?.string.contains("Download ") == true
                }), let count = request.results?.first(where: {
                    $0.topCandidates(1).first?.string.contains("20") == true
                }) {
                    XCTAssertLessThan(action.boundingBox.maxY, count.boundingBox.minY)
                }
                XCTAssertFalse(text.contains("iPhone"), text)
                XCTAssertFalse(text.contains("offline"), text)
                let attachment = XCTAttachment(image: UIImage(cgImage: image))
                attachment.name = "season-download-artwork-\(size)-\(direction)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testProgressBurstsHaveBoundedPresentationUpdatesAndImmediateCompletion() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        var download = record()
        download.status = .downloading
        download.totalBytes = 1_000_000
        _ = try await registry.beginDownload(download)
        let model = makeModel(
            registry: registry, storage: try temporaryStorage(),
            probe: ArtworkProbe(data: imageData()), startsActive: false
        )
        defer { model.beginProfileTransition() }
        try await waitUntil { model.records.count == 1 }
        let observer = DownloadObservationProbe { _ = model.records }
        defer { observer.stop() }
        let clock = ContinuousClock()
        let start = clock.now
        for bytes in 1...100 {
            try await registry.updateProgress(
                identityKey: download.identityKey, bytesDownloaded: Int64(bytes * 1_000),
                totalBytes: 1_000_000
            )
            try await Task.sleep(for: .milliseconds(5))
        }
        try await waitUntil { model.records.first?.bytesDownloaded == 100_000 }
        let duration = start.duration(to: clock.now).components
        let elapsed = Double(duration.attoseconds) / 1e18 + Double(duration.seconds)
        let budget = Int(ceil(elapsed / 0.25)) + 1
        print("DOWNLOAD_PRESENTATION updates=\(observer.changes) elapsed=\(elapsed) budget=\(budget)")
        XCTAssertLessThanOrEqual(observer.changes, budget)

        try await registry.updateProgress(
            identityKey: download.identityKey, bytesDownloaded: 101_000, totalBytes: 1_000_000
        )
        let completed = expectation(description: "Completion bypasses the progress cadence")
        withObservationTracking {
            _ = model.records
        } onChange: {
            completed.fulfill()
        }
        try await registry.markCompleted(identityKey: download.identityKey, totalBytes: 1_000_000)
        await fulfillment(of: [completed], timeout: 0.2)
        XCTAssertEqual(model.records.first?.status, .completed)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.records.first?.status, .completed, "A queued progress update must not replace completion.")
    }

    func testSeasonDownloadActionLabelsClarifyBulkScope() throws {
        let cases: [(SeriesDownloadAction, MediaDownloadBadgeState?, String)] = [
            (.download, nil, "Download All"),
            (.preparing, nil, "Preparing Download"),
            (.pause, .inProgress(fraction: 0.6), "Pause All"),
            (.resume, .paused(fraction: 0.6), "Resume All"),
            (.download, .completed, "Downloaded")
        ]
        for (action, state, expected) in cases {
            let renderer = ImageRenderer(content:
                PlozziOSBulkDownloadActionControl(action: action, state: state)
                    .padding(16)
                    .background(.black)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en"))
            )
            renderer.scale = 3
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(renderer.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
            XCTAssertTrue(text.contains(expected), "\(action): \(text)")
        }
    }

    func testShortSeasonTitleKeepsActionBesideDetails() throws {
        let renderer = ImageRenderer(content:
            PlozziOSSeasonDownloadActionLabel(
                title: Text(verbatim: "Book 1: Water"), episodeCount: 20
            ) {
                SeasonDownloadRowArtwork(showsMediaEdge: false) { Color.red }
            } accessory: {
                PlozziOSBulkDownloadActionControl(action: .download, state: nil)
            }
            .frame(width: 320)
            .padding(16)
            .background(.black)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.dynamicTypeSize, .large)
        )
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.customWords = ["Download All"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let action = try XCTUnwrap(request.results?.first {
            $0.topCandidates(1).first?.string.contains("Download All") == true
        })
        let title = try XCTUnwrap(request.results?.first {
            $0.topCandidates(1).first?.string.contains("Water") == true
        })
        XCTAssertGreaterThan(action.boundingBox.minX, title.boundingBox.maxX)
        XCTAssertLessThan(
            abs(action.boundingBox.midY - title.boundingBox.midY) * CGFloat(image.height) / 3,
            20
        )
    }

    func testDownloadControlKeepsTheSameSlotAcrossStates() throws {
        let states: [MediaDownloadBadgeState?] = [
            nil, .inProgress(fraction: nil), .inProgress(fraction: 0.6),
            .paused(fraction: 0.6), .failed, .completed
        ]
        for state in states {
            let renderer = ImageRenderer(content: PlozziOSDownloadControl(state: state))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 132, "Every state uses the same 44-point accessory slot.")
            XCTAssertEqual(image.height, 132)
        }
    }

    func testProgressDoesNotInvalidateUnrelatedEpisodeLookups() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        var active = record(id: "active")
        active.status = .downloading
        active.totalBytes = 1_000_000
        _ = try await registry.beginDownload(active)
        _ = try await registry.beginDownload(record(id: "complete"))
        let model = makeModel(
            registry: registry, storage: try temporaryStorage(),
            probe: ArtworkProbe(data: imageData()), startsActive: false
        )
        defer { model.beginProfileTransition() }
        try await waitUntil { model.records.count == 2 }
        let complete = MediaItem(id: "complete", title: "Complete", kind: .episode, sourceAccountID: "emby")
        let absent = MediaItem(id: "absent", title: "Absent", kind: .episode, sourceAccountID: "emby")
        let unrelated = DownloadObservationProbe {
            _ = model.cachedRecord(forSelectedVersionOf: complete)
            _ = model.cachedRecord(forSelectedVersionOf: absent)
        }
        defer { unrelated.stop() }
        try await registry.updateProgress(
            identityKey: active.identityKey, bytesDownloaded: 500_000, totalBytes: 1_000_000
        )
        try await waitUntil { model.records.first { $0.identityKey == active.identityKey }?.bytesDownloaded == 500_000 }
        XCTAssertEqual(unrelated.changes, 0, "One transfer must not redraw completed or undownloaded episode rows.")

        let appeared = expectation(description: "A previously undownloaded episode becomes visible")
        withObservationTracking {
            XCTAssertNil(model.cachedRecord(forSelectedVersionOf: absent))
        } onChange: {
            appeared.fulfill()
        }
        _ = try await registry.beginDownload(record(id: "absent"))
        await fulfillment(of: [appeared], timeout: 1)
        try await waitUntil { model.cachedRecord(forSelectedVersionOf: absent)?.status == .completed }
    }

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

@MainActor
private final class DownloadObservationProbe {
    private let read: @MainActor () -> Void
    private var active = true
    private(set) var changes = 0

    init(read: @escaping @MainActor () -> Void) {
        self.read = read
        observe()
    }

    func stop() { active = false }

    private func observe() {
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.active else { return }
                self.changes += 1
                self.observe()
            }
        }
    }
}
#endif
