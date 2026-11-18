#if os(iOS)
import AVFoundation
import CoreModels
import FeaturePlayback
import Foundation
import MediaDownloads
import UIKit
import XCTest
@testable import AppShelliOS

/// Run each phase in a separate test-host process; see MediaDownloads/README.md.
@MainActor
final class OfflineDownloadPlaybackHostedTests: XCTestCase {
    private struct Context {
        let run: String
        let fixtures: URL
        var storage: PlatformDownloadStorageLocator {
            .init(subdirectory: "PlozzDownloads/\(run)")
        }
        func registry() throws -> DownloadedMediaRegistry {
            let backing = try DurableLocalStateStore(
                secureStore: OfflineValidationDiskStore(
                    url: try storage.pinnedMediaDirectory().appendingPathComponent("catalog.json")
                )
            )
            return DownloadedMediaRegistry(store: try DurableDownloadedMediaStore(
                store: backing, profileID: run, onLoadFailure: { XCTFail("Could not reload the persisted catalog") }
            ))
        }
    }

    private func context() throws -> Context {
        let environment = ProcessInfo.processInfo.environment
        guard let run = environment["PLOZZ_OFFLINE_VALIDATION_RUN"],
              let path = environment["PLOZZ_OFFLINE_VALIDATION_FIXTURES"] else {
            throw XCTSkip("Requires the two-process offline download validation fixture.")
        }
        _ = try XCTUnwrap(UUID(uuidString: run), "Use a fresh UUID for each two-phase run")
        return Context(run: run, fixtures: URL(fileURLWithPath: path, isDirectory: true))
    }

    func testPrepareReducedDownloadsForProcessRestart() async throws {
        let context = try context()
        OfflineMode.shared.setEnabled(false)
        let registry = try context.registry()
        let initial = await registry.all()
        XCTAssertTrue(initial.isEmpty, "Do not reuse a completed or interrupted validation run")
        guard initial.isEmpty else { return }
        let files = try ["media.mp4", "primary.mp4", "alternate.m4a"].reduce(into: [String: Data]()) {
            $0[$1] = try Data(contentsOf: context.fixtures.appendingPathComponent($1))
        }
        let nativeFixture = try context.storage.pinnedMediaDirectory().appendingPathComponent("fixture.mp4")
        try XCTUnwrap(files["media.mp4"]).write(to: nativeFixture)
        let fixtureDuration = try await AVURLAsset(url: nativeFixture).load(.duration)
        XCTAssertEqual(fixtureDuration.seconds, 24, accuracy: 0.1)
        try FileManager.default.removeItem(at: nativeFixture)
        let requests = OfflineValidationRequests()
        let server = try IPTVTestHTTPServer { request in
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if path.hasSuffix(".srt") {
                let language = path.contains("french") ? "French" : "English"
                return .init(data: Data(
                    "1\n00:00:01,000 --> 00:00:04,000\n\(language) early\n\n2\n00:00:12,000 --> 00:00:16,000\n\(language) late\n\n".utf8
                ), headers: ["Content-Type": "application/x-subrip"])
            }
            guard let data = files[String(path.dropFirst())] else { return .init(status: 404) }
            let range = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
            let offset = range.flatMap {
                $0.split(separator: "=").last?.split(separator: "-").first.flatMap { Int($0) }
            } ?? 0
            if request.hasPrefix("GET ") { requests.append(path: path, offset: offset) }
            guard (0..<data.count).contains(offset) else { return .init(status: 416) }
            var headers = ["Accept-Ranges": "bytes", "ETag": "\"offline-fixture\"", "Content-Type": "video/mp4"]
            if range != nil { headers["Content-Range"] = "bytes \(offset)-\(data.count - 1)/\(data.count)" }
            return .init(
                data: data.subdata(in: offset..<data.count), status: range == nil ? 200 : 206,
                headers: headers, delay: .milliseconds(80), chunkSize: 32_768
            )
        }
        let base = try await server.start()
        addTeardownBlock { await server.stop() }
        let engine = PlozziOSBackgroundHTTPDownloadEngine(
            profileID: context.run, registry: registry,
            resolveURL: { source, _, _, _ in
                if source.provider == .plex {
                    return .init(
                        url: base.appendingPathComponent("media.mp4"), expectedDuration: 24, cleanupURL: nil,
                        singleFile: true, expectedBytes: Int64(files["media.mp4"]!.count),
                        expectedAudioLanguages: ["en", "fr"]
                    )
                }
                return .init(
                    audioPackage: .init(
                        plan: .init(sourceFingerprint: "synthetic-v1", tracks: [
                            .init(id: 1, language: "en"), .init(id: 2, language: "fr")
                        ], primaryAudioID: 1, duration: 24),
                        authorize: {},
                        prepare: { track in
                            let name = track == nil ? "primary.mp4" : "alternate.m4a"
                            return .init(
                                url: base.appendingPathComponent(name), expectedDuration: 24, cleanupURL: nil,
                                singleFile: true, expectedBytes: Int64(files[name]!.count)
                            )
                        }, finishPreparation: { _ in }
                    ), expectedDuration: 24
                )
            }
        )
        let queue = DownloadQueue(
            registry: registry, storage: context.storage, engine: engine,
            saveSubtitles: { record, destination, policy in
                let kind = try XCTUnwrap(record.managedHTTPSource?.provider)
                return try await PlozziOSOfflineSubtitles.save(
                    record: record, destination: destination, policy: policy,
                    provider: OfflineValidationProvider(kind: kind, subtitleBase: base),
                    authorize: {}, resolve: { base.appendingPathComponent($0.resource.path) }
                )
            }, maxAttempts: 1
        )
        for kind in [ProviderKind.plex, .emby] {
            let record = try await queue.enqueue(.init(
                identity: .external(source: "offline-validation", value: kind.rawValue),
                versionID: "selected", sourceKind: .managedHTTP, quality: .sd480,
                managedHTTPSource: .init(provider: kind, accountID: "fixture", itemID: kind.rawValue,
                                         mediaSourceID: "selected", quality: .sd480, includesAllAudioTracks: true),
                contentType: "video/mp4", fileExtension: "mp4",
                snapshot: .init(title: "Offline validation", kind: .movie, sourceAccountID: "fixture",
                                sourceItemID: kind.rawValue, runtime: 24)
            ))
            addTeardownBlock {
                await queue.pause(identityKey: record.identityKey)
                await queue.discardPersistentWork(identityKey: record.identityKey)
            }
            try await waitUntil {
                let current = await registry.record(forKey: record.identityKey)
                return current?.status == .downloading && (current?.bytesDownloaded ?? 0) >= 65_536
            }
            await queue.pause(identityKey: record.identityKey)
            let paused = await registry.record(forKey: record.identityKey)
            XCTAssertEqual(paused?.status, .paused)
            await queue.resume(identityKey: record.identityKey)
            try await waitUntil {
                let current = await registry.record(forKey: record.identityKey)
                if current?.status == .failed {
                    XCTFail("Reduced download failed: \(String(describing: current))")
                    throw AppError.invalidResponse
                }
                return current?.status == .completed && current?.subtitleStatus == .saved
            }
            let fullPath = kind == .plex ? "/media.mp4" : "/primary.mp4"
            XCTAssertEqual(requests.offsets(for: fullPath).filter { $0 == 0 }.count, 1)
            let destination = try context.storage.pinnedFileURL(for: record)
            XCTAssertEqual(try OfflineSubtitleStore.files(beside: destination).map(\.language), ["en", "fr"])
        }
        XCTAssertEqual(requests.offsets(for: "/alternate.m4a").filter { $0 == 0 }.count, 1)
        await server.stop()
        let root = try context.storage.pinnedMediaDirectory()
        try Data(String(ProcessInfo.processInfo.processIdentifier).utf8)
            .write(to: root.appendingPathComponent("producer-process.txt"), options: .atomic)
    }

    func testPlayPersistedDownloadsOfflineAfterProcessRestart() async throws {
        let context = try context()
        let root = try context.storage.pinnedMediaDirectory()
        let previousPID = try String(contentsOf: root.appendingPathComponent("producer-process.txt"), encoding: .utf8)
        XCTAssertNotEqual(previousPID, String(ProcessInfo.processInfo.processIdentifier),
                          "The prepare phase must finish in a different app process")
        OfflineMode.shared.setEnabled(true)
        defer { OfflineMode.shared.setEnabled(false) }
        let registry = try context.registry()
        let records = await registry.all().sorted { $0.identityKey > $1.identityKey }
        XCTAssertEqual(records.count, 2)
        for record in records {
            XCTAssertEqual(record.status, .completed)
            XCTAssertEqual(record.subtitleStatus, .saved)
            try await verifyPlayback(record, registry: registry, storage: context.storage)
        }
        guard testRun?.failureCount == 0 else { return }
        try FileManager.default.removeItem(at: root)
    }

    private func verifyPlayback(
        _ record: DownloadedMediaRecord, registry: DownloadedMediaRegistry,
        storage: PlatformDownloadStorageLocator
    ) async throws {
        let item = try XCTUnwrap(PlozziOSDownloadsModel(initializationError: "fixture").detailItem(for: record))
        let kind = try XCTUnwrap(record.managedHTTPSource?.provider)
        let engine = NativeVideoEngine(startsMuted: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let surface = engine.makeVideoOutputView()
        surface.frame = host.view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(surface)
        defer {
            engine.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let model = PlayerViewModel(
            provider: OfflineValidationProvider(kind: kind), itemID: item.id, mediaSourceID: "selected",
            offlineItem: item, offlinePlaybackResolver: RegistryOfflinePlaybackResolver(registry: registry, storage: storage),
            audioPolicy: .init(basePreference: .language("fr")),
            engineFactory: .init(makeNative: { _ in engine })
        )
        await model.load()
        addTeardownBlock { await model.stop() }
        try await waitUntil {
            engine.status == .ready && engine.currentTime > 0.3
                && engine.pictureInPicturePlayerLayer()?.isReadyForDisplay == true
                && model.controls.audioOptions.count == 2
        }
        let playerItem = try XCTUnwrap(engine.nowPlayingPlayer?.currentItem)
        let asset = try XCTUnwrap(playerItem.asset as? AVURLAsset)
        XCTAssertTrue(asset.url.isFileURL)
        XCTAssertEqual(asset.url.standardizedFileURL, try storage.pinnedFileURL(for: record).standardizedFileURL)
        let loadedGroup = try await asset.loadMediaSelectionGroup(for: .audible)
        let group = try XCTUnwrap(loadedGroup)
        try await waitUntil {
            playerItem.currentMediaSelection.selectedMediaOption(in: group)?.locale?.language.languageCode?.identifier == "fr"
        }
        let initial = try XCTUnwrap(model.controls.audioOptions.first(where: \.isSelected))
        let alternate = try XCTUnwrap(model.controls.audioOptions.first { $0.id != initial.id })
        for option in [alternate, initial] {
            let before = engine.currentTime
            model.selectAudioOption(id: option.id)
            try await waitUntil {
                model.controls.audioOptions.first(where: \.isSelected)?.id == option.id
                    && engine.currentTime > before + 0.2
            }
            XCTAssertEqual(
                playerItem.currentMediaSelection.selectedMediaOption(in: group)?.locale?.language.languageCode?.identifier,
                option.id == initial.id ? "fr" : "en"
            )
        }
        model.togglePlayPause()
        try await waitUntil { engine.isPaused }
        XCTAssertEqual(model.availableSubtitleTracks.map(\.language), ["en", "fr"])
        for (index, language) in ["English", "French"].enumerated() {
            model.selectSubtitleOption(id: model.availableSubtitleTracks[index].id)
            for (position, suffix) in [(2.0, "early"), (14.0, "late"), (2.0, "early")] {
                await model.seek(to: position)
                try await waitUntil {
                    model.liveSubtitles.tick(engine.subtitlePresentationTime)
                    return model.liveSubtitles.primary.map(\.text) == ["\(language) \(suffix)"]
                }
                XCTAssertEqual(engine.currentTime, position, accuracy: 0.25)
                XCTAssertTrue(engine.nowPlayingPlayer?.currentItem === playerItem)
            }
            await model.seek(to: 8)
            model.liveSubtitles.tick(engine.subtitlePresentationTime)
            XCTAssertTrue(model.liveSubtitles.primary.isEmpty, "No stale cue in the subtitle gap")
        }
        model.selectSubtitleOption(id: PlayerTrackOption.offID)
        await model.seek(to: 2)
        model.liveSubtitles.tick(engine.subtitlePresentationTime)
        XCTAssertTrue(model.liveSubtitles.primary.isEmpty)
        await model.stop()
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Offline validation did not reach the expected state", file: file, line: line)
        throw URLError(.timedOut)
    }
}

private final class OfflineValidationRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [Int]] = [:]
    func append(path: String, offset: Int) { lock.withLock { values[path, default: []].append(offset) } }
    func offsets(for path: String) -> [Int] { lock.withLock { values[path] ?? [] } }
}

/// Unsigned simulator hosts cannot use Keychain. Persist the production store's
/// envelopes to disk instead; no credentials are used by this fixture.
private final class OfflineValidationDiskStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    init(url: URL) { self.url = url }
    private func read() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }
    func readString(for key: String) throws -> String? {
        try lock.withLock { try read()[key] }
    }
    func string(for key: String) -> String? {
        do { return try readString(for: key) }
        catch { XCTFail("Fixture catalog read failed: \(error)"); return nil }
    }
    func setString(_ value: String, for key: String) throws {
        try lock.withLock {
            var values = try read()
            values[key] = value
            try JSONEncoder().encode(values).write(to: url, options: .atomic)
        }
    }
    func removeValue(for key: String) throws {
        try lock.withLock {
            var values = try read()
            values.removeValue(forKey: key)
            try JSONEncoder().encode(values).write(to: url, options: .atomic)
        }
    }
}

private struct OfflineValidationProvider: MediaProvider {
    let kind: ProviderKind
    var subtitleBase: URL?
    var session: UserSession {
        .init(server: .init(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!, provider: kind),
              userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture")
    }
    func subtitleTracks(context: RemoteSubtitleContext) async throws -> [MediaTrack] {
        guard subtitleBase != nil else { throw AppError.serverUnreachable }
        return try [(2, "English", "en", "english.srt"), (3, "French", "fr", "french.srt")].map {
            let locator = try AuthenticatedHTTPPlaybackLocator(
                provider: kind, accountID: "fixture", credentialRevision: .init(),
                itemID: context.itemID, mediaSourceID: context.mediaSourceID,
                deliveryMode: .directFile, formatHint: .init(container: "srt"), purpose: .subtitle,
                resource: .init(pathBase: .configuredBaseURL, path: $0.3)
            )
            return .init(id: $0.0, kind: .subtitle, displayTitle: $0.1, language: $0.2, codec: "srt",
                         deliverySource: .authenticatedHTTP(locator), isExternal: kind == .plex)
        }
    }
    func libraries() async throws -> [MediaLibrary] { throw AppError.serverUnreachable }
    func continueWatching(limit: Int) async throws -> [MediaItem] { throw AppError.serverUnreachable }
    func latest(limit: Int) async throws -> [MediaItem] { throw AppError.serverUnreachable }
    func item(id: String) async throws -> MediaItem { throw AppError.serverUnreachable }
    func children(of itemID: String) async throws -> [MediaItem] { throw AppError.serverUnreachable }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.serverUnreachable
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { throw AppError.serverUnreachable }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        XCTFail("Persisted playback must never request the unavailable server")
        throw AppError.serverUnreachable
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
