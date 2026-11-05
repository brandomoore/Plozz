import CoreModels
import Darwin
import EnginePlozzigen
import FeatureHomeCore
import Foundation
import MediaTransportCore
import MediaTransportHTTP
import MediaTransportWebDAV
@testable import ProviderShare
import UIKit
import XCTest

@MainActor
final class WebDAVDiscPlaybackHostedTests: XCTestCase {
    private enum CheckFailure: Error {
        case invalidInput, engineFailed, deadlineExceeded
    }

    private actor BodyChunkPacer {
        let interval: Duration
        private var next = ContinuousClock.now

        init(interval: Duration) {
            self.interval = interval
        }

        func wait() async throws {
            try Task.checkCancellation()
            let deadline = max(next, .now) + interval
            next = deadline
            try await Task.sleep(until: deadline, clock: .continuous)
        }
    }

    func testLocalBodyPacingIsSharedAcrossRequests() async throws {
        let pacer = BodyChunkPacer(interval: .milliseconds(20))
        let started = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { try await pacer.wait() }
            }
            try await group.waitForAll()
        }
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(80))
    }

    func testSyntheticDVDISOPlaysAndSeeksOverWebDAV() async throws {
        try await checkFixturePlayback(named: "dvd-test-pattern", fileExtension: "iso")
    }

    private final class FixtureReads: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []
        func record(_ path: String) { lock.withLock { _ = paths.insert(path) } }
        func contains(_ path: String) -> Bool { lock.withLock { paths.contains(path) } }
    }

    func testSyntheticBluRayFolderPlaysBothClipsAndSeeksOverWebDAV() async throws {
        try await checkBluRayPlayback(startPosition: 0)
    }

    func testSyntheticBluRayFolderResumesIntoSecondClipOverWebDAV() async throws {
        try await checkBluRayPlayback(startPosition: 9)
    }

    func testNativeVideoCatalogSelectsAnExplicitPlaylistWithoutMenus() async throws {
        try await checkBluRayPlayback(startPosition: 0, inspectVideos: true)
    }

    func testNativeHDMVFirstPlayAndTopMenuUseProductionTransport() async throws {
        try await checkBluRayPlayback(startPosition: 0, discMenus: true)
    }

    func testNativeHDMVMissingOpeningRecoversToTopMenu() async throws {
        try await checkBluRayPlayback(startPosition: 0, discMenus: true, missingOpening: true)
    }

    func testNativeHDMVFiniteStillHonorsPauseAndResumesNavigation() async throws {
        try await checkBluRayPlayback(startPosition: 0, discMenus: true, discStillSeconds: 2)
    }

    func testNativeHDMVInfiniteStillKeepsFrameUntilMenuCommand() async throws {
        try await checkBluRayPlayback(startPosition: 0, discMenus: true, discStillSeconds: 0)
    }

    func testNativeHDMVAudioSelectionUsesPIDRatherThanOrdinal() async throws {
        try await checkBluRayPlayback(startPosition: 0, discMenus: true, discAudioSelection: true)
    }

    func testNativeHDMVRepeatedClipStopsAtIntermediateStill() async throws {
        try await checkBluRayPlayback(startPosition: 0, discMenus: true, discIntermediateStill: true)
    }

    func testJavaMenuPlaysBothChoicesAndReopensAfterShutdown() async throws {
        let manager = FileManager.default
        let caches = try XCTUnwrap(manager.urls(for: .cachesDirectory, in: .userDomainMask).first)
        func cacheFixture(marked: Bool) throws -> URL {
            let root = caches.appendingPathComponent("DiscJava-\(UUID().uuidString)")
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
            if marked {
                try Data("Plozz disc cache v1\n".utf8).write(to: root.appendingPathComponent(".plozz-disc-cache"))
                try Data().write(to: root.appendingPathComponent(".lease"))
            }
            addTeardownBlock {
                if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
            }
            return root
        }
        let expired = try cacheFixture(marked: true)
        let active = try cacheFixture(marked: true)
        let unowned = try cacheFixture(marked: false)
        let lease = open(active.appendingPathComponent(".lease").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(lease, 0)
        guard lease >= 0 else { throw CheckFailure.invalidInput }
        defer { close(lease) }
        XCTAssertEqual(flock(lease, LOCK_EX | LOCK_NB), 0)
        let quarantine = ProcessInfo.processInfo.environment["PLOZZ_BDJ_SHUTDOWN_CHECK"] == "1"
        for iteration in 0..<2 {
            try await checkBluRayPlayback(startPosition: 0, discMenus: true, discJava: true,
                                         discJavaQuarantine: quarantine && iteration == 1)
        }
        XCTAssertFalse(manager.fileExists(atPath: expired.path))
        XCTAssertTrue(manager.fileExists(atPath: active.path))
        XCTAssertTrue(manager.fileExists(atPath: unowned.path))
    }

    func testNativeHDMVShortRepeatedItemReachesItsOwnStill() async throws {
        try await checkBluRayPlayback(startPosition: 0, discMenus: true,
                                      discIntermediateStill: true, discShortSecondItem: true)
    }

    private func checkBluRayPlayback(
        startPosition: Double, discMenus: Bool = false, missingOpening: Bool = false,
        discStillSeconds: UInt16? = nil, discAudioSelection: Bool = false, discIntermediateStill: Bool = false,
        discShortSecondItem: Bool = false, discJava: Bool = false, discJavaQuarantine: Bool = false,
        inspectVideos: Bool = false
    ) async throws {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
            .appendingPathComponent("Fixtures/bluray-test-pattern")
        let subpaths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        var files: [String: URL] = [:]
        var sizes: [String: Int] = [:]
        var overrides: [String: Data] = [:]
        var directories: Set<String> = [""]
        for path in subpaths {
            let url = root.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true {
                directories.insert(path)
            } else {
                files[path] = url
                sizes[path] = try XCTUnwrap(values.fileSize)
            }
        }
        if discMenus || inspectVideos {
            let metadata = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
                .appendingPathComponent(discJava ? "Fixtures/bdj-navigation" : "Fixtures/hdmv-navigation")
            for path in try FileManager.default.subpathsOfDirectory(atPath: metadata.path) {
                let url = metadata.appendingPathComponent(path)
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values.isDirectory == true {
                    directories.insert(path)
                } else {
                    files[path] = url
                    sizes[path] = try XCTUnwrap(values.fileSize)
                }
            }
            if discAudioSelection {
                let playlist = metadata.appendingPathComponent("audio-selection.mpls")
                files["BDMV/PLAYLIST/00001.mpls"] = playlist
                sizes["BDMV/PLAYLIST/00001.mpls"] = try Data(contentsOf: playlist).count
            }
            if missingOpening {
                let clipInfo = "BDMV/CLIPINF/00001.clpi"
                files["BDMV/BACKUP/CLIPINF/00001.clpi"] = files.removeValue(forKey: clipInfo)
                sizes["BDMV/BACKUP/CLIPINF/00001.clpi"] = sizes.removeValue(forKey: clipInfo)
                directories.formUnion(["BDMV/BACKUP", "BDMV/BACKUP/CLIPINF"])
                files.removeValue(forKey: "BDMV/STREAM/00001.m2ts")
                sizes.removeValue(forKey: "BDMV/STREAM/00001.m2ts")
            }
            if let discStillSeconds {
                let path = "BDMV/PLAYLIST/00001.mpls"
                var data = try Data(contentsOf: XCTUnwrap(files[path]))
                let playlistStart = data[8..<12].reduce(0) { ($0 << 8) | Int($1) }
                let item = playlistStart + 12
                data[item + 29] = discStillSeconds == 0 ? 2 : 1
                data[item + 30] = UInt8(discStillSeconds >> 8)
                data[item + 31] = UInt8(truncatingIfNeeded: discStillSeconds)
                overrides[path] = data
            }
            if discIntermediateStill {
                let path = "BDMV/PLAYLIST/00001.mpls"
                let data = try Data(contentsOf: XCTUnwrap(files[path]))
                let list = data[8..<12].reduce(0) { ($0 << 8) | Int($1) }
                let marks = data[12..<16].reduce(0) { ($0 << 8) | Int($1) }
                let itemLength = Int(data[list + 10]) << 8 | Int(data[list + 11])
                var first = Data(data[(list + 12)..<(list + 12 + itemLength)])
                var second = first
                func write32(_ value: UInt32, into bytes: inout Data, at index: Int) {
                    for offset in 0..<4 {
                        bytes[index + offset] = UInt8(truncatingIfNeeded: value >> (24 - offset * 8))
                    }
                }
                write32(4 * 45_000, into: &first, at: 16)
                first[29] = 1
                first[30] = 0
                first[31] = 2
                write32(4 * 45_000, into: &second, at: 12)
                if discShortSecondItem { write32(4 * 45_000 + 1_890, into: &second, at: 16) }
                second[29] = 2
                var combined = Data(data[..<(list + 12)])
                combined[list + 7] = 2
                combined.append(first)
                combined.append(contentsOf: [UInt8(itemLength >> 8), UInt8(truncatingIfNeeded: itemLength)])
                combined.append(second)
                write32(UInt32(combined.count - list - 4), into: &combined, at: list)
                write32(UInt32(combined.count), into: &combined, at: 12)
                combined.append(data[marks...])
                overrides[path] = combined
                sizes[path] = combined.count
            }
        }
        let fixtureFiles = files
        let fixtureSizes = sizes
        let fixtureDirectories = directories
        let fixtureOverrides = overrides
        let reads = FixtureReads()
        let server = try IPTVTestHTTPServer { request in
            let target = String(request.split(separator: " ").dropFirst().first ?? "")
            let path = String(target.dropFirst("/dav".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if request.hasPrefix("OPTIONS ") { return .init(headers: ["DAV": "1, 2"]) }
            if request.hasPrefix("PROPFIND ") {
                guard fixtureDirectories.contains(path) || fixtureFiles[path] != nil else { return .init(status: 404) }
                var paths = [path]
                if request.lowercased().contains("\r\ndepth: 1\r\n") {
                    paths += (Array(fixtureDirectories) + Array(fixtureFiles.keys)).filter {
                        !$0.isEmpty && $0 != path && ($0 as NSString).deletingLastPathComponent == path
                    }
                }
                let properties = paths.sorted().map { entry in
                    let collection = fixtureDirectories.contains(entry)
                    let body = collection ? "<D:resourcetype><D:collection/></D:resourcetype>"
                        : "<D:getcontentlength>\(fixtureSizes[entry]!)</D:getcontentlength><D:getetag>\"fixture\"</D:getetag>"
                    return "<D:response><D:href>/dav/\(entry)\(collection ? "/" : "")</D:href><D:propstat><D:prop>\(body)</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
                }.joined()
                return .init(data: Data("<D:multistatus xmlns:D=\"DAV:\">\(properties)</D:multistatus>".utf8),
                             status: 207, headers: ["Content-Type": "application/xml"])
            }
            guard request.hasPrefix("GET "), let file = fixtureFiles[path], let size = fixtureSizes[path],
                  let range = request.components(separatedBy: "\r\n").first(where: {
                      $0.lowercased().hasPrefix("range: bytes=")
                  })?.split(separator: "=").last?.split(separator: "-"),
                  range.count == 2, let start = Int(range[0]), let end = Int(range[1]),
                  start >= 0, end >= start, end < size else { return .init(status: 416) }
            reads.record(path)
            if let data = fixtureOverrides[path] {
                return .init(data: data.subdata(in: start..<(end + 1)), status: 206, headers: [
                    "Content-Range": "bytes \(start)-\(end)/\(size)", "ETag": "\"fixture\""
                ])
            }
            return .init(file: file, status: 206, headers: [
                "Content-Range": "bytes \(start)-\(end)/\(size)", "ETag": "\"fixture\""
            ], range: start..<(end + 1))
        }
        addTeardownBlock { await server.stop() }
        let base = try await server.start().appendingPathComponent("dav")
        try await checkPlayback(
            base: base, path: "BDMV/index.bdmv", credential: .anonymous,
            seekPositions: discMenus ? [2] : [10, 2, 13], startPosition: startPosition,
            discMenus: discMenus, expectedDiscPlaylist: missingOpening ? 2 : 1,
            discStillSeconds: discStillSeconds, discAudioSelection: discAudioSelection,
            discIntermediateStill: discIntermediateStill, discShortSecondItem: discShortSecondItem,
            discJava: discJava, discJavaQuarantine: discJavaQuarantine, inspectVideos: inspectVideos
        )
        XCTAssertEqual(reads.contains("BDMV/STREAM/00001.m2ts"), !missingOpening && !discAudioSelection)
        XCTAssertEqual(reads.contains("BDMV/STREAM/00004.m2ts"), discAudioSelection)
        XCTAssertTrue(reads.contains("BDMV/STREAM/00002.m2ts"))
        XCTAssertFalse(reads.contains("BDMV/STREAM/00003.m2ts"), "The largest clip is not the selected movie")
    }

    func testMP4PlaysAndSeeksOverWebDAV() async throws {
        try await checkFixturePlayback(named: "embedded", fileExtension: "mp4")
    }

    func testMKVPlaysAndSeeksOverWebDAV() async throws {
        try await checkFixturePlayback(named: "glow-software", fileExtension: "mkv")
    }

    func testMKVResumesOverWebDAV() async throws {
        try await checkFixturePlayback(named: "glow-software", fileExtension: "mkv", startPosition: 3)
    }

    func testSyntheticDVDISOResumesOverWebDAV() async throws {
        try await checkFixturePlayback(named: "dvd-test-pattern", fileExtension: "iso", startPosition: 3)
    }

    func testExplicitLocalHighBitratePlaybackWithLatency() async throws {
        guard let name = ProcessInfo.processInfo.environment["PLOZZ_WEBDAV_LOCAL_PLAYBACK_FIXTURE"] else {
            throw XCTSkip("Requires a staged synthetic local playback fixture; never contacts a public server.")
        }
        guard name == (name as NSString).lastPathComponent, name.hasSuffix(".mkv") else {
            throw CheckFailure.invalidInput
        }
        let file = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            .appendingPathComponent(name)
        try await checkFixturePlayback(
            file: file, fileExtension: "mkv", seekPositions: [35, 5, 20],
            sustainedPlaybackSeconds: 60, headerDelay: .milliseconds(80), bodyDelay: .milliseconds(1)
        )
    }

    func testExplicitLocalISOPlaybackWithLatency() async throws {
        try await checkExplicitLocalPlayback(
            fixtureKey: "PLOZZ_WEBDAV_LOCAL_ISO_FIXTURE", extensions: ["iso"], requiresNativeHLS: true
        )
    }

    func testExplicitLocalContainerPlaybackWithLatency() async throws {
        try await checkExplicitLocalPlayback(
            fixtureKey: "PLOZZ_WEBDAV_LOCAL_CONTAINER_FIXTURE", extensions: ["mp4", "mkv"],
            requiresNativeHLS: false
        )
    }

    private func checkExplicitLocalPlayback(
        fixtureKey: String, extensions: Set<String>, requiresNativeHLS: Bool
    ) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment[fixtureKey] else {
            throw XCTSkip("Requires a staged synthetic local file; never contacts a public server.")
        }
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard name == (name as NSString).lastPathComponent,
              extensions.contains(fileExtension),
              let start = Double(environment["PLOZZ_WEBDAV_LOCAL_START_POSITION"] ?? "0"),
              start.isFinite, start >= 0 else {
            throw CheckFailure.invalidInput
        }
        let file = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            .appendingPathComponent(name)
        try await checkFixturePlayback(
            file: file, fileExtension: fileExtension, seekPositions: [30], startPosition: start,
            sustainedPlaybackSeconds: 60, headerDelay: .milliseconds(250), bodyDelay: .milliseconds(10),
            requiresNativeHLS: requiresNativeHLS
        )
    }

    private func checkFixturePlayback(
        named name: String, fileExtension: String, startPosition: Double = 0
    ) async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: fileExtension, subdirectory: "Fixtures"
        ))
        try await checkFixturePlayback(
            file: file, fileExtension: fileExtension, seekPositions: [4, 1], startPosition: startPosition
        )
    }

    private func checkFixturePlayback(
        file: URL, fileExtension: String, seekPositions: [Double],
        startPosition: Double = 0, sustainedPlaybackSeconds: Int = 0,
        headerDelay: Duration = .zero, bodyDelay: Duration = .zero,
        requiresNativeHLS: Bool = false
    ) async throws {
        let path = "fixture.\(fileExtension)"
        let fileSize = try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let etag = "\"synthetic-disc\""
        let collection = """
        <D:response><D:href>/dav/</D:href><D:propstat><D:prop>
        <D:resourcetype><D:collection/></D:resourcetype>
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        """
        let fileProperties = """
        <D:response>
        <D:href>/dav/\(path)</D:href><D:propstat><D:prop>
        <D:getcontentlength>\(fileSize)</D:getcontentlength>
        <D:getetag>\(etag)</D:getetag>
        <D:getcontenttype>application/octet-stream</D:getcontenttype>
        </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        """
        let aggregate = ProcessInfo.processInfo.environment["PLOZZ_WEBDAV_AGGREGATE_BANDWIDTH"] == "1"
        let pacer = aggregate && bodyDelay != .zero ? BodyChunkPacer(interval: bodyDelay) : nil
        let server = try IPTVTestHTTPServer(beforeBodyChunk: {
            try await pacer?.wait()
        }) { request in
            if request.hasPrefix("OPTIONS ") {
                return .init(headers: ["DAV": "1, 2"])
            }
            if request.hasPrefix("PROPFIND ") {
                let target = request.split(separator: " ").dropFirst().first
                let properties: String
                if target == "/dav" || target == "/dav/" {
                    let listsChildren = request.components(separatedBy: "\r\n").contains {
                        $0.lowercased() == "depth: 1"
                    }
                    properties = collection + (listsChildren ? fileProperties : "")
                } else if target == "/dav/\(path)" {
                    properties = fileProperties
                } else {
                    return .init(status: 404)
                }
                let xml = "<D:multistatus xmlns:D=\"DAV:\">\(properties)</D:multistatus>"
                return .init(data: Data(xml.utf8), status: 207, headers: ["Content-Type": "application/xml"])
            }
            guard request.hasPrefix("GET /dav/\(path) "),
                  let range = request.components(separatedBy: "\r\n").first(where: {
                      $0.lowercased().hasPrefix("range: bytes=")
                  })?.split(separator: "=").last?.split(separator: "-"),
                  range.count == 2,
                  let start = Int(range[0]), let end = Int(range[1]),
                  start >= 0, end >= start, end < fileSize else {
                return .init(status: 416)
            }
            return .init(file: file, status: 206, headers: [
                "Content-Range": "bytes \(start)-\(end)/\(fileSize)",
                "ETag": etag,
                "Content-Type": "application/octet-stream"
            ], headerDelay: headerDelay, delay: pacer == nil ? bodyDelay : .zero, range: start..<(end + 1))
        }
        let recordIO: @Sendable (String) async -> Void = { phase in
            print("WEBDAV_LOCAL phase=\(phase) requests=\(await server.requestCount) peakActive=\(await server.peakActiveRequestCount) bodyBytes=\(await server.bodyBytesSent)")
        }
        addTeardownBlock {
            await server.stop()
            await recordIO("teardown")
        }
        let base = try await server.start().appendingPathComponent("dav")
        print("WEBDAV_LOCAL bandwidth=\(pacer == nil ? "per-connection" : "aggregate") headerDelay=\(headerDelay) chunkDelay=\(bodyDelay)")
        try await checkPlayback(
            base: base, path: path, credential: .anonymous, seekPositions: seekPositions,
            startPosition: startPosition, sustainedPlaybackSeconds: sustainedPlaybackSeconds,
            requiresNativeHLS: requiresNativeHLS, recordIO: recordIO
        )
    }

    func testExplicitLiveWebDAVISOPlaysAndSeeks() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLOZZ_WEBDAV_PLAYBACK_JSON"] != nil
                || environment["PLOZZ_WEBDAV_PLAYBACK_INPUT"] != nil else {
            throw XCTSkip("Requires an explicitly supplied private WebDAV playback configuration.")
        }
        struct Input: Decodable {
            let baseURL: URL
            let username: String
            let password: String
            let relativePath: String
            let seekPositions: [Double]
            let startPosition: Double?
            let discMenuInspection: Bool?
            let discJavaInspection: Bool?
            let discJavaKeys: [UInt32]?
            let discJavaFeaturePlayback: Bool?
        }
        let data: Data
        if let json = environment["PLOZZ_WEBDAV_PLAYBACK_JSON"] {
            data = Data(json.utf8)
        } else {
            let inputPath = try XCTUnwrap(environment["PLOZZ_WEBDAV_PLAYBACK_INPUT"])
            let inputURL = inputPath.hasPrefix("cache:")
                ? try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
                    .appendingPathComponent(String(inputPath.dropFirst("cache:".count)))
                : URL(fileURLWithPath: inputPath)
            data = try Data(contentsOf: inputURL)
        }
        let input = try JSONDecoder().decode(Input.self, from: data)
        let startPosition = input.startPosition ?? 0
        let anonymousLoopback = input.baseURL.scheme == "http" &&
            ["127.0.0.1", "::1"].contains(input.baseURL.host ?? "") &&
            input.username.isEmpty && input.password.isEmpty
        guard input.baseURL.scheme == "https" || anonymousLoopback, input.baseURL.user == nil,
              input.baseURL.password == nil, input.baseURL.query == nil,
              startPosition.isFinite, startPosition >= 0,
              !input.seekPositions.isEmpty, input.seekPositions.count <= 3,
              input.seekPositions.allSatisfy({ $0.isFinite && $0 >= 0 }),
              (input.discJavaKeys ?? []).count <= 4,
              (input.discJavaKeys ?? []).allSatisfy({ [12, 13, 14, 15, 16].contains($0) }) else {
            throw CheckFailure.invalidInput
        }
        try await checkPlayback(
            base: input.baseURL, path: input.relativePath,
            credential: .password(username: input.username, password: input.password, policy: .automatic),
            seekPositions: input.seekPositions, startPosition: startPosition, sustainedPlaybackSeconds: 60,
            discMenus: input.discMenuInspection == true || input.discJavaInspection == true,
            discMenuInspection: input.discMenuInspection == true,
            discJavaInspection: input.discJavaInspection == true,
            discJavaKeys: input.discJavaKeys ?? [],
            discJavaFeaturePlayback: input.discJavaFeaturePlayback == true
        )
    }

    private func checkPlayback(
        base: URL, path: String, credential: WebDAVCredential, seekPositions: [Double],
        startPosition: Double = 0, sustainedPlaybackSeconds: Int = 0,
        requiresNativeHLS: Bool = false, recordIO: (@Sendable (String) async -> Void)? = nil,
        discMenus: Bool = false, expectedDiscPlaylist: Int = 1, discStillSeconds: UInt16? = nil,
        discAudioSelection: Bool = false, discIntermediateStill: Bool = false, discShortSecondItem: Bool = false,
        discMenuInspection: Bool = false, discJava: Bool = false, discJavaInspection: Bool = false,
        discJavaKeys: [UInt32] = [], discJavaQuarantine: Bool = false,
        discJavaFeaturePlayback: Bool = false, inspectVideos: Bool = false
    ) async throws {
        let environment = ProcessInfo.processInfo.environment
        let detailPlayDelay: Duration?
        if let value = environment["PLOZZ_WEBDAV_DETAIL_PLAY_DELAY_SECONDS"] {
            guard environment["PLOZZ_WEBDAV_DETAIL_PREPARATION"] == "1",
                  let seconds = Double(value), [2.0, 3.0].contains(seconds) else {
                throw CheckFailure.invalidInput
            }
            detailPlayDelay = .seconds(seconds)
        } else {
            detailPlayDelay = nil
        }
        let earlyHandoff = environment["PLOZZ_WEBDAV_EARLY_HANDOFF"] == "1"
        guard !earlyHandoff || detailPlayDelay != nil else { throw CheckFailure.invalidInput }
        let sceneDeadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < sceneDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let scheme = try XCTUnwrap(base.scheme.flatMap(WebDAVScheme.init(rawValue:)))
        let account = "webdav-playback-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let endpoint = try MediaTransportEndpointIdentity(
            transportIdentifier: scheme.rawValue, host: try XCTUnwrap(base.host),
            port: base.port, rootPath: base.path
        )
        let key = MediaTransportSessionKey(
            accountID: account, credentialRevision: revision, endpoint: endpoint,
            trustRevision: UUID(), role: .playback
        )
        let adapter = WebDAVMediaTransportAdapter(scheme: scheme) { _, _ in
            .init(credential: credential, trustPolicy: .system)
        }
        let metadataKey = MediaTransportSessionKey(
            accountID: account, credentialRevision: revision, endpoint: endpoint,
            trustRevision: key.trustRevision, role: .metadata
        )
        let metadata = try await adapter.connect(for: metadataKey)
        addTeardownBlock { await metadata.shutdown() }
        try await metadata.fileSystem.validate()
        let browser = ShareTransportBrowser(role: .metadata, sessionFactory: { _ in metadata })
        let library = ShareLibraryStore(browser: browser, serverName: "Disc fixture")
        addTeardownBlock { await library.close() }
        let parent = (path as NSString).deletingLastPathComponent
        let container = parent.isEmpty ? ShareLibraryStore.rootLibraryID : "d:\(parent)"
        let entries = try await library.entries(forContainerID: container)
        let item = try XCTUnwrap(entries.first { $0.id == "f:\(path)" },
                                 "The production browser must expose the selected media")
        let provider = ShareProvider(
            session: UserSession(
                server: .init(id: account, name: "Disc fixture", baseURL: base, provider: .mediaShare),
                userID: "fixture", userName: "", deviceID: "fixture", accessToken: ""
            ),
            credentialRevision: revision, sessionFactory: { _ in metadata },
            catalogCoordinator: ShareCatalogCoordinator(initialWorkScope: .paused)
        )
        addTeardownBlock { await provider.teardown() }
        let registry = MediaTransportResolverRegistry(adapter: adapter)
        let resolver = MediaTransportNetworkFileResolver(
            registry: registry,
            sourcePreparer: PlozzigenNetworkFileStreamProber.preparePlaybackSource,
            sessionKeyProvider: { _ in key }
        )
        let coordinator = DetailPlaybackPreparationCoordinator()
        defer { coordinator.invalidate() }
        var preparationHandle: MediaTransportPreparation?
        let preparationStarted: ContinuousClock.Instant
        if let detailPlayDelay {
            var detailItem = item
            detailItem.sourceAccountID = account
            detailItem.resumePosition = startPosition
            let candidate = try XCTUnwrap(DetailPlaybackPreparationCandidate(
                detailItem, exactFileRelativePath: ShareProvider.exactFileRelativePath(for: detailItem)
            ))
            let detailScope = DetailPlaybackPreparationScope(
                profileID: "fixture", authorizationID: "fixture", accountID: account,
                serverUserID: "fixture", credentialRevision: revision
            )
            let detailStarted = ContinuousClock.now
            let preparationEnvironment = DetailPlaybackPreparationEnvironment(
                scope: { $0 == account ? detailScope : nil },
                exactFileRelativePath: { ShareProvider.exactFileRelativePath(for: $0) },
                provider: { $0 == account ? provider : nil },
                reserve: { locator, position in
                    if earlyHandoff {
                        let handle = try resolver.beginPreparation(locator, startPosition: position)
                        preparationHandle = handle
                        print("WEBDAV_DISC detailPreparationTicketSeconds=\(detailStarted.duration(to: .now))")
                        return DetailPlaybackPreparationReservation(
                            cancel: { handle.cancel() },
                            requestPlaybackHandoff: { handle.requestPlaybackHandoff() }
                        )
                    }
                    let handle = try await resolver.prepare(locator, startPosition: position)
                    preparationHandle = handle
                    print("WEBDAV_DISC detailPreparationSeconds=\(detailStarted.duration(to: .now))")
                    return DetailPlaybackPreparationReservation { handle.cancel() }
                }
            )
            await recordIO?("detail")
            let detailVisible = ContinuousClock.now
            coordinator.update(candidate: candidate, environment: preparationEnvironment, isActive: true)
            try await Task.sleep(for: detailPlayDelay)
            preparationStarted = .now
            let readyAtPlay = preparationHandle?.warmupOutcome != nil
            coordinator.handoff(detailItem)
            coordinator.stop()
            print("WEBDAV_DISC detailPlayDelaySeconds=\(detailVisible.duration(to: preparationStarted)) preparationReadyAtPlay=\(readyAtPlay) earlyHandoff=\(earlyHandoff)")
        } else if environment["PLOZZ_WEBDAV_DETAIL_PREPARATION"] == "1" {
            let detailStarted = ContinuousClock.now
            let detailLocator = try await provider.playbackPreparationLocator(
                for: item.id, mediaSourceID: path
            )
            let locator = try XCTUnwrap(detailLocator)
            do {
                preparationHandle = try await resolver.prepare(locator, startPosition: startPosition)
            } catch {
                print("WEBDAV_DISC preparationFailureType=\(String(reflecting: type(of: error))) cancelled=\(Task.isCancelled)")
                if let transportError = error as? MediaTransportError {
                    switch transportError {
                    case .timeout: print("WEBDAV_DISC preparationFailure=timeout")
                    case .cancelled: print("WEBDAV_DISC preparationFailure=cancelled")
                    case .transport(let code): print("WEBDAV_DISC preparationFailure=transport code=\(code)")
                    default: print("WEBDAV_DISC preparationFailure=otherTransport")
                    }
                }
                throw error
            }
            print("WEBDAV_DISC detailPreparationSeconds=\(detailStarted.duration(to: .now))")
            preparationStarted = .now
        } else {
            preparationStarted = .now
        }
        let prepared = preparationHandle
        defer { withExtendedLifetime(prepared) {} }
        await recordIO?("play")
        var request = try await provider.playbackInfo(for: item.id, mediaSourceID: nil, forceTranscode: false)
        request.discPlayback = discMenus ? .openMenu : .playVideo
        let preparationDuration = preparationStarted.duration(to: .now)
        print("WEBDAV_DISC preparationSeconds=\(preparationDuration)")
        guard request.playbackSource?.requiresNetworkFileResolver == true else {
            return XCTFail("Disc playback must use the production transport path")
        }
        if path.hasSuffix("index.bdmv") {
            guard case .networkDisc = request.playbackSource else {
                return XCTFail("A Blu-ray folder must not play its index as an ordinary file")
            }
        }
        let engine = try PlozzigenVideoEngine(
            networkFileResolver: resolver
        )
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        let initiallyRendered = await engine.hasRenderedVideoFrame()
        XCTAssertFalse(initiallyRendered)
        addTeardownBlock {
            await engine.stop()
            await engine.drainTransport()
            await registry.retire(accountID: account, credentialRevision: revision)
        }
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = engine.makeVideoOutputView()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        let started = ContinuousClock.now
        try await perform(engine: engine) { await engine.load(request: request, startPosition: startPosition) }
        if inspectVideos {
            let videos = try await engine.discVideos()
            XCTAssertTrue(videos.contains { $0.playlist == 1 })
            let selected = try XCTUnwrap(videos.first { $0.playlist == 2 })
            XCTAssertGreaterThan(selected.duration, 0)
            XCTAssertEqual(Set(videos.map(\.playlist)).count, videos.count)
            engine.stop()
            await engine.drainTransport()
            request.discPlaylistOverride = selected.playlist
            await engine.load(request: request, startPosition: 0)
            XCTAssertNil(engine.discMenu)
            try await waitForPlayback(engine, after: 1, before: selected.duration)
            let rendered = await engine.hasRenderedVideoFrame()
            XCTAssertTrue(rendered)
            return
        }
        if discJava {
            let menu = try XCTUnwrap(engine.discMenu)
            try await wait(engine: engine, seconds: 45) {
                menu.failure != nil || (menu.image != nil && menu.isMenuVisible)
            }
            XCTAssertNil(menu.failure)
            XCTAssertNil(menu.playlist, "A menu-only Java title must not silently start a video")
            menu.sendKey(16)
            try await wait(engine: engine, seconds: 45) {
                guard menu.playlist == 1, !menu.isMenuVisible, menu.failure == nil else { return false }
                return await engine.hasRenderedVideoFrame()
            }
            try await waitForPlayback(engine, after: 1, before: 6)
            engine.pause()
            let position = engine.currentTime
            try await Task.sleep(for: .seconds(1))
            XCTAssertEqual(engine.currentTime, position, accuracy: 0.2)
            engine.play()
            try await waitForPlayback(engine, after: position + 0.5, before: 7)
            menu.openMenu()
            try await wait(engine: engine, seconds: 30) { menu.image != nil && menu.isMenuVisible }
            menu.sendPointerClick(10, 10)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(menu.isMenuVisible, "A pointer miss must not activate the selected episode")
            menu.sendPointerClick(920, 360)
            try await wait(engine: engine, seconds: 45) {
                guard menu.playlist == 2, !menu.isMenuVisible, menu.failure == nil else { return false }
                return await engine.hasRenderedVideoFrame()
            }
            try await waitForPlayback(engine, after: 1, before: 6)
            try await wait(engine: engine, seconds: 15) { menu.image != nil && menu.isMenuVisible }
            XCTAssertNil(menu.failure)
            if discJavaQuarantine {
                let previousImage = try XCTUnwrap(menu.image?.pngData())
                menu.sendKey(13)
                try await wait(engine: engine, seconds: 5) { menu.image?.pngData() != previousImage }
            }
            engine.stop()
            await engine.drainTransport()
            if discJavaQuarantine {
                var failure = ""
                for _ in 0..<10 {
                    await engine.load(request: request, startPosition: 0)
                    failure = try XCTUnwrap(engine.discMenu?.failure)
                    if failure.contains("Restart Plozz") { break }
                    XCTAssertEqual(failure, "Another disc menu is still closing")
                    engine.stop()
                    await engine.drainTransport()
                    try await Task.sleep(for: .seconds(2))
                }
                XCTAssertTrue(failure.contains("Restart Plozz"), failure)
            }
            return
        }
        if discJavaInspection {
            let menu = try XCTUnwrap(engine.discMenu)
            try await wait(engine: engine, seconds: 60) { menu.failure != nil || menu.image != nil }
            XCTAssertNil(menu.failure)
            try await Task.sleep(for: .seconds(30))
            XCTAssertNil(menu.failure)
            let image = try XCTUnwrap(menu.image)
            let directory = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("disc-java-inspection.png"))
            print("WEBDAV_DISC javaMenuReadySeconds=\(started.duration(to: .now)) playlist=\(menu.playlist ?? -1)")
            for (index, key) in discJavaKeys.enumerated() {
                menu.sendKey(key)
                try await Task.sleep(for: .seconds(30))
                XCTAssertNil(menu.failure)
                if let image = menu.image {
                    try XCTUnwrap(image.pngData()).write(
                        to: directory.appendingPathComponent("disc-java-step-\(index).png"))
                }
                let rendered = await engine.hasRenderedVideoFrame()
                print("WEBDAV_DISC javaStep=\(index) playlist=\(menu.playlist ?? -1) position=\(engine.currentTime) rendered=\(rendered)")
            }
            if discJavaFeaturePlayback {
                try await wait(engine: engine, seconds: 90) {
                    guard engine.duration > 600, engine.currentTime > 2, menu.failure == nil else { return false }
                    return await engine.hasRenderedVideoFrame()
                }
                let position = engine.currentTime
                try await Task.sleep(for: .seconds(10))
                XCTAssertGreaterThan(engine.currentTime, position + 8)
                engine.pause()
                let paused = engine.currentTime
                try await Task.sleep(for: .seconds(1))
                XCTAssertEqual(engine.currentTime, paused, accuracy: 0.2)
                engine.play()
                try await waitForPlayback(engine, after: paused + 1, before: paused + 8)
                if let failure = menu.failure { return XCTFail(failure) }
                print("WEBDAV_DISC javaFeatureVerified playlist=\(menu.playlist ?? -1) position=\(engine.currentTime)")
                let featureDuration = engine.duration
                let featurePlaylist = menu.playlist
                menu.openMenu()
                try await Task.sleep(for: .seconds(20))
                var visibleSince: ContinuousClock.Instant?
                try await wait(engine: engine, seconds: 60) {
                    guard menu.image != nil && menu.isMenuVisible else {
                        visibleSince = nil
                        return false
                    }
                    let now = ContinuousClock.now
                    if visibleSince == nil { visibleSince = now }
                    return visibleSince!.duration(to: now) >= .seconds(2)
                }
                XCTAssertNil(menu.failure)
                let topMenu = try XCTUnwrap(menu.image?.pngData())
                try topMenu.write(to: directory.appendingPathComponent("disc-java-top-menu.png"))
                menu.sendKey(16)
                try await wait(engine: engine, seconds: 60) {
                    guard abs(engine.duration - featureDuration) < 0.5,
                          menu.playlist == featurePlaylist, engine.currentTime > 2, !menu.isMenuVisible,
                          menu.failure == nil else { return false }
                    return await engine.hasRenderedVideoFrame()
                }
                let selectedPosition = engine.currentTime
                try await waitForPlayback(engine, after: selectedPosition + 2, before: selectedPosition + 10)
                print("WEBDAV_DISC javaTopMenuPlayVerified playlist=\(menu.playlist ?? -1) position=\(engine.currentTime)")
            }
            engine.stop()
            await engine.drainTransport()
            return
        }
        if discMenuInspection {
            let menu = try XCTUnwrap(engine.discMenu)
            try await wait(engine: engine, seconds: 60) {
                if menu.failure != nil { return true }
                guard menu.isMenuVisible, menu.isStill, menu.image != nil else { return false }
                return await engine.hasRenderedVideoFrame()
            }
            XCTAssertNil(menu.failure)
            XCTAssertTrue(menu.isMenuVisible)
            XCTAssertTrue(menu.isStill)
            XCTAssertNotNil(menu.image)
            let frame = await engine.hasRenderedVideoFrame()
            XCTAssertTrue(frame)
            print("WEBDAV_DISC menuReadySeconds=\(started.duration(to: .now)) playlist=\(menu.playlist ?? -1) playItem=\(menu.playItem ?? -1) region=\(menu.region)")
            try await Task.sleep(for: .seconds(5))
            XCTAssertNil(menu.failure)
            XCTAssertTrue(menu.isStill)
            engine.stop()
            await engine.drainTransport()
            return
        }
        if requiresNativeHLS {
            XCTAssertEqual(engine.diagnosticRoute, .localHLS, "The native ISO workload must not use a software fallback")
        }
        if let prepared {
            XCTAssertTrue(prepared.wasConsumed, "A prepared sample must consume its exact reservation")
        }
        try await wait(engine: engine, seconds: 45) {
            guard engine.isPlaybackPositionReady else { return false }
            let rendered = await engine.hasRenderedVideoFrame()
            return rendered && engine.isPlaybackPositionReady
        }
        let renderedAt = ContinuousClock.now
        let firstRenderedDuration = started.duration(to: renderedAt)
        let playToFirstRenderedDuration = preparationStarted.duration(to: renderedAt)
        let firstPresentedPosition = engine.currentTime
        await recordIO?("firstFrame")
        XCTAssertGreaterThanOrEqual(firstPresentedPosition, max(0, startPosition - 1))
        XCTAssertLessThan(firstPresentedPosition, startPosition + 5)
        try await waitForPlayback(engine, after: firstPresentedPosition + 0.5, before: startPosition + 5)
        let startupDuration = preparationStarted.duration(to: .now)
        if environment["PLOZZ_WEBDAV_REQUIRE_SUBTHREE_START"] == "1" {
            if detailPlayDelay == nil {
                XCTAssertNotNil(prepared, "The prepared-start acceptance run must consume a reservation")
            }
            XCTAssertLessThan(startupDuration, .seconds(3), "Play-to-render-and-advance exceeded the target")
        }
        XCTAssertGreaterThan(
            engine.duration, max(startPosition, seekPositions.max()!) + Double(max(1, sustainedPlaybackSeconds))
        )
        if path.hasSuffix("index.bdmv") {
            XCTAssertEqual(engine.duration, discMenus ? 8 : 16, accuracy: 0.5)
        }
        if discMenus {
            let menu = try XCTUnwrap(engine.discMenu)
            XCTAssertEqual(menu.playlist, expectedDiscPlaylist, "Native navigation must select the authored playlist")
            XCTAssertNil(menu.failure)
            if discAudioSelection {
                try await wait(engine: engine, seconds: 10) { engine.currentAudioTrackID == 2 }
                XCTAssertEqual(menu.playlist, 1)
                XCTAssertNil(menu.notice)
                engine.selectAudioTrack(try XCTUnwrap(engine.audioTracks.first { $0.id == 1 }))
                try await wait(engine: engine, seconds: 15) { engine.currentAudioTrackID == 1 }
                XCTAssertEqual(menu.playlist, 1, "The player choice must not escape to another playlist")
                XCTAssertNil(menu.notice)
            }
            if discIntermediateStill {
                try await wait(engine: engine, seconds: 20) { menu.isStill && menu.failure == nil }
                XCTAssertEqual(engine.currentTime, 4, accuracy: 0.15,
                               "The renderer must stop at the first item's out-time, not the clip EOF")
                engine.pause()
                try await Task.sleep(for: .seconds(3))
                XCTAssertTrue(menu.isStill)
                let heldFrame = await engine.hasRenderedVideoFrame()
                XCTAssertTrue(heldFrame)
                engine.play()
                if !discShortSecondItem {
                    try await wait(engine: engine, seconds: 20) {
                        !menu.isStill && menu.playItem == 1 && menu.failure == nil && engine.currentTime > 4.2
                    }
                }
                try await wait(engine: engine, seconds: 20) {
                    menu.isStill && menu.playItem == 1 && menu.failure == nil
                }
                XCTAssertEqual(menu.playlist, 1, "The next item is in the same authored playlist")
                XCTAssertEqual(engine.currentTime, discShortSecondItem ? 4.042 : 8, accuracy: 0.15)
                let finalFrame = await engine.hasRenderedVideoFrame()
                XCTAssertTrue(finalFrame)
                menu.openMenu()
            } else if let discStillSeconds {
                try await wait(engine: engine, seconds: 20) { menu.isStill && menu.failure == nil }
                engine.pause()
                try await Task.sleep(for: .seconds(3))
                XCTAssertTrue(menu.isStill, "User pause must suspend the authored still timer")
                XCTAssertEqual(menu.playlist, 1)
                let heldFrame = await engine.hasRenderedVideoFrame()
                XCTAssertTrue(heldFrame, "A still must retain the presented video frame")
                engine.play()
                if discStillSeconds == 0 {
                    try await Task.sleep(for: .seconds(1))
                    XCTAssertTrue(menu.isStill, "An infinite still must not advance by itself")
                    menu.openMenu()
                } else {
                    let resumed = ContinuousClock.now
                    try await wait(engine: engine, seconds: 10) { menu.playlist == 2 }
                    XCTAssertGreaterThan(resumed.duration(to: .now), .seconds(1))
                }
            } else {
                menu.openMenu()
            }
            try await wait(engine: engine, seconds: 45) {
                guard menu.playlist == 2, menu.failure == nil else { return false }
                return await engine.hasRenderedVideoFrame()
            }
            try await waitForPlayback(engine, after: 0.5, before: 5)
            XCTAssertNil(menu.failure)
            XCTAssertFalse(menu.isStill)
            engine.stop()
            await engine.drainTransport()
            return
        }
        print("WEBDAV_DISC startPosition=\(startPosition) firstPresentedPosition=\(firstPresentedPosition)")
        print("WEBDAV_DISC firstRenderedFrameSeconds=\(firstRenderedDuration) duration=\(engine.duration)")
        print("WEBDAV_DISC playToFirstRenderedFrameSeconds=\(playToFirstRenderedDuration)")
        print("WEBDAV_DISC population=\(detailPlayDelay == nil ? (prepared == nil ? "cold" : "prepared") : "timed-detail") reservationConsumed=\(prepared?.wasConsumed ?? false)")
        print("WEBDAV_DISC warmupOutcome=\(prepared?.warmupOutcome.map { String(describing: $0) } ?? "none")")
        print("WEBDAV_DISC startupSeconds=\(startupDuration) route=\(engine.diagnosticRoute?.rawValue ?? "unknown")")
        try await checkSustainedPlayback(
            engine, seconds: sustainedPlaybackSeconds, phase: "startup"
        )
        for target in seekPositions {
            let seekStart = ContinuousClock.now
            try await perform(engine: engine) { await engine.seek(to: target) }
            try await waitForPlayback(engine, after: target + 0.3, before: target + 5)
            print("WEBDAV_DISC seek=\(target) landed=\(engine.currentTime) elapsed=\(seekStart.duration(to: .now))")
        }
        try await checkSustainedPlayback(
            engine, seconds: sustainedPlaybackSeconds, phase: "afterSeek"
        )
        engine.stop()
        await engine.drainTransport()
        let renderedAfterStop = await engine.hasRenderedVideoFrame()
        XCTAssertFalse(renderedAfterStop)
    }

    private func checkSustainedPlayback(
        _ engine: PlozzigenVideoEngine, seconds: Int, phase: String
    ) async throws {
        guard seconds > 0 else { return }
        let initialPosition = engine.currentTime
        let started = ContinuousClock.now
        while started.duration(to: .now) < .seconds(seconds) {
            if case .failed = engine.status { throw CheckFailure.engineFailed }
            try await Task.sleep(for: .milliseconds(250))
        }
        let progress = engine.currentTime - initialPosition
        XCTAssertGreaterThan(progress, Double(seconds) - 2, "Sustained playback stalled during \(phase)")
        print("WEBDAV_DISC sustainedSeconds=\(seconds) progressed=\(progress) phase=\(phase)")
    }

    private func perform(
        engine: PlozzigenVideoEngine, operation: @escaping @MainActor () async -> Void
    ) async throws {
        var completed = false
        let task = Task { await operation(); completed = true }
        do {
            try await wait(engine: engine, seconds: 120) { completed }
            await task.value
        } catch {
            task.cancel()
            engine.stop()
            await task.value
            throw error
        }
    }

    private func waitForPlayback(
        _ engine: PlozzigenVideoEngine, after: Double, before: Double = .greatestFiniteMagnitude
    ) async throws {
        try await wait(engine: engine, seconds: 45) {
            guard engine.isPlaybackPositionReady else { return false }
            let rendered = await engine.hasRenderedVideoFrame()
            return rendered && engine.isPlaybackPositionReady
                && engine.currentTime > after && engine.currentTime < before
        }
    }

    private func wait(
        engine: PlozzigenVideoEngine, seconds: Int, condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !(await condition()) {
            if case .failed = engine.status { throw CheckFailure.engineFailed }
            guard ContinuousClock.now < deadline else { throw CheckFailure.deadlineExceeded }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
