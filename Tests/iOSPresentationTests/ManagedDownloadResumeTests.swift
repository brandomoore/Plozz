#if os(iOS)
import CoreModels
import Foundation
import MediaDownloads
import XCTest
@testable import AppShelliOS

@MainActor
final class ManagedDownloadResumeTests: XCTestCase {
    func testTransferIdentityAcceptsLegacyJSONOrderingAndEscaping() throws {
        let descriptor = BackgroundTaskDescriptor(
            profileID: "profile", identityKey: "folder/item", localFileName: "media.bin"
        )
        let expected = try descriptor.encoded()
        let variants = [
            #"{"profileID":"profile","identityKey":"folder/item","localFileName":"media.bin"}"#,
            #"{"profileID":"profile","localFileName":"media.bin","identityKey":"folder/item"}"#,
            #"{"identityKey":"folder/item","profileID":"profile","localFileName":"media.bin"}"#,
            #"{"identityKey":"folder\/item","localFileName":"media.bin","profileID":"profile"}"#,
            #"{"localFileName":"media.bin","profileID":"profile","identityKey":"folder/item"}"#,
            #"{"localFileName":"media.bin","identityKey":"folder\/item","profileID":"profile"}"#
        ]
        for json in variants {
            let legacy = Data(json.utf8).base64EncodedString()
            XCTAssertEqual(try BackgroundTaskDescriptor.canonicalKey(legacy), expected)
        }
        for _ in 0..<100 { XCTAssertEqual(try descriptor.encoded(), expected) }
    }

    func testTransferIdentityPreservesEveryScopeComponentAndRejectsMalformedData() throws {
        let descriptors = [
            BackgroundTaskDescriptor(profileID: "profile", identityKey: "item", localFileName: "media.bin"),
            BackgroundTaskDescriptor(profileID: "other", identityKey: "item", localFileName: "media.bin"),
            BackgroundTaskDescriptor(profileID: "profile", identityKey: "other", localFileName: "media.bin"),
            BackgroundTaskDescriptor(profileID: "profile", identityKey: "item", localFileName: "other.bin")
        ]
        XCTAssertEqual(Set(try descriptors.map { try $0.encoded() }).count, 4)
        XCTAssertThrowsError(try BackgroundTaskDescriptor.canonicalKey("invalid"))
        XCTAssertThrowsError(try BackgroundTaskDescriptor.canonicalKey(
            Data(#"{"profileID":"incomplete"}"#.utf8).base64EncodedString()
        ))
    }

    func testOriginalHTTPDownloadResumesWithoutRestartingBytes() async throws {
        try await verifyPauseResume(includesValidator: true)
    }

    func testOriginalHTTPDownloadWithoutValidatorPreservesPausedTransfer() async throws {
        try await verifyPauseResume(includesValidator: false)
    }

    private func verifyPauseResume(includesValidator: Bool) async throws {
        let bytes = Data((0..<(3 * 1_024 * 1_024)).map {
            UInt8(truncatingIfNeeded: $0 ^ ($0 >> 8) ^ ($0 >> 16))
        })
        let requests = ResumeRequestRecorder()
        let server = try IPTVTestHTTPServer { request in
            let range = request.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("range:") }
            let offset = range.flatMap {
                $0.split(separator: "=").last?.split(separator: "-").first.flatMap { Int($0) }
            } ?? 0
            if request.hasPrefix("GET ") { requests.append(offset: offset) }
            guard offset >= 0, offset < bytes.count else {
                return .init(status: 416, headers: ["Content-Range": "bytes */\(bytes.count)"])
            }
            var headers = ["Accept-Ranges": "bytes", "Content-Type": "application/octet-stream"]
            if includesValidator { headers["ETag"] = "\"resume-fixture\"" }
            if range != nil {
                headers["Content-Range"] = "bytes \(offset)-\(bytes.count - 1)/\(bytes.count)"
            }
            return .init(
                data: bytes.subdata(in: offset..<bytes.count),
                status: range == nil ? 200 : 206, headers: headers,
                delay: .milliseconds(100)
            )
        }
        let url = try await server.start()
        let profile = "resume-test-\(UUID().uuidString)"
        let storage = PlatformDownloadStorageLocator(subdirectory: "PlozzDownloads/\(profile)")
        let directory = try storage.pinnedMediaDirectory()
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let engine = PlozziOSBackgroundHTTPDownloadEngine(
            profileID: profile, registry: registry,
            resolveURL: { _, _, _ in
                .init(url: url, expectedDuration: nil, cleanupURL: nil, expectedBytes: Int64(bytes.count))
            }
        )
        let queue = DownloadQueue(
            registry: registry, storage: storage, engine: engine, observer: StaticDownloadNetworkObserver()
        )
        let record = try await queue.enqueue(
            DownloadRequest(
                identity: .external(source: "resume-fixture", value: profile),
                expectedBytes: Int64(bytes.count), sourceKind: .managedHTTP,
                managedHTTPSource: .init(provider: .emby, accountID: "fixture", itemID: "fixture"),
                contentType: "application/octet-stream", fileExtension: "bin",
                snapshot: .init(title: "Resume fixture", kind: .movie)
            )
        )
        let progress = ResumeProgressRecorder()
        let events = await registry.events()
        let observation = Task {
            for await event in events {
                if Task.isCancelled { return }
                if progress.resumed, case .item(let item) = event, item.status == .downloading {
                    progress.values.append(item.bytesDownloaded)
                }
            }
        }
        addTeardownBlock {
            observation.cancel()
            await queue.pause(identityKey: record.identityKey)
            await queue.discardPersistentWork(identityKey: record.identityKey)
            await server.stop()
            try FileManager.default.removeItem(at: directory)
        }
        try await waitForRecord(registry, key: record.identityKey) {
            $0.bytesDownloaded >= 256 * 1_024 && $0.status == .downloading
        }
        await queue.pause(identityKey: record.identityKey)
        let pausedSnapshot = await registry.record(forKey: record.identityKey)
        let paused = try XCTUnwrap(pausedSnapshot)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertLessThan(paused.bytesDownloaded, Int64(bytes.count))
        progress.resumed = true
        await queue.resume(identityKey: record.identityKey)
        try await waitForRecord(registry, key: record.identityKey) { $0.status == .completed }
        XCTAssertFalse(progress.values.isEmpty)
        XCTAssertGreaterThanOrEqual(progress.values.min() ?? 0, paused.bytesDownloaded,
                                    "Paused at \(paused.bytesDownloaded); resumed values \(progress.values); request offsets \(requests.offsets)")
        XCTAssertEqual(requests.offsets.filter { $0 == 0 }.count, 1,
                       "Pause/resume must not issue another full-body download: \(requests.offsets)")
        XCTAssertEqual(try Data(contentsOf: storage.pinnedFileURL(for: record)), bytes)
    }

    @MainActor
    private final class ResumeProgressRecorder {
        var resumed = false
        var values: [Int64] = []
    }

    private func waitForRecord(
        _ registry: DownloadedMediaRegistry,
        key: String,
        matching predicate: (DownloadedMediaRecord) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let record = await registry.record(forKey: key), predicate(record) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let record = await registry.record(forKey: key)
        XCTFail("Transfer did not reach the expected state: \(String(describing: record?.status)), \(record?.bytesDownloaded ?? 0) bytes")
        throw URLError(.timedOut)
    }
}

private final class ResumeRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var offsets: [Int] { lock.withLock { values } }
    func append(offset: Int) { lock.withLock { values.append(offset) } }
}
#endif
