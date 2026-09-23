#if canImport(AVFoundation)
import AppRuntime
import AVFoundation
import CoreModels
import CoreNetworking
@testable import FeaturePlayback
import Foundation
import ProviderJellyfin
import ProviderPlex
import ProviderSilo
import XCTest

/// Opt-in real services, real provider adapters, real authenticated resolver,
/// and the production native engine. Normal package runs never contact servers.
@MainActor
final class ProviderPlaybackIntegrationTests: XCTestCase {
    func testJellyfinPlayback() async throws { try await run(providerName: "jellyfin") }
    func testPlexPlayback() async throws { try await run(providerName: "plex") }
    func testEmbyPlayback() async throws { try await run(providerName: "emby") }
    func testSiloPlayback() async throws { try await run(providerName: "silo") }

    private func run(providerName: String) async throws {
        guard let configPath = ProcessInfo.processInfo.environment["PLOZZ_PLAYBACK_E2E_CONFIG"] else {
            throw XCTSkip("Opt in using tools/run-provider-playback-tests.py and a private server configuration.")
        }
        // Catch every error at this boundary: server errors/URLs can contain tokens.
        do {
            let configuration = try JSONDecoder().decode(
                PlaybackTestConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: configPath))
            )
            try configuration.validate()
            guard let server = configuration.servers[providerName] else {
                throw PlaybackTestFailure.invalidConfiguration
            }
            if server.codecs.contains("hevc"), !MediaCapabilities.detected().supportsHEVC {
                throw PlaybackTestFailure.clientHEVCUnavailable
            }
            let token = try String(contentsOfFile: server.tokenFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw PlaybackTestFailure.missingToken }
            let kind: ProviderKind = providerName == "silo" ? .silo : providerName == "plex" ? .plex : providerName == "emby" ? .emby : .jellyfin
            let session = UserSession(
                server: .init(id: server.serverID, name: "Playback test", baseURL: server.baseURL, provider: kind),
                userID: server.userID, userName: "Playback test",
                deviceID: "plozz-playback-test-\(UUID().uuidString)", accessToken: token
            )
            let http = PlaybackTestHTTPClient()
            let revision = CredentialRevision()
            let provider: any MediaProvider
            if kind == .silo {
                let credential = try SiloCredential.decode(token)
                let requiredLifetime = 2 * (configuration.startupTimeoutSeconds * 2 + configuration.playbackSeconds + 35)
                guard credential.expiresAt.timeIntervalSinceNow > requiredLifetime else {
                    throw PlaybackTestFailure.missingToken
                }
                provider = try SiloProvider(
                    context: .init(session: session, accountID: "e2e", credentialRevision: revision),
                    credentials: PlaybackTestSiloCredentialStore(raw: token, revision: revision), http: http
                )
            } else if kind == .plex {
                provider = PlexProvider(session: session, accountID: "e2e", credentialRevision: revision, http: http, probe: http)
            } else {
                provider = JellyfinProvider(session: session, accountID: "e2e", credentialRevision: revision, http: http)
            }
            let resolver = ManagedAuthenticatedHTTPResolver()
            resolver.configure { locator in
                .init(provider: kind, accountID: "e2e", credentialRevision: revision,
                      baseURL: (provider as? any AuthenticatedHTTPOriginProviding)?.authenticatedHTTPOrigin ?? server.baseURL,
                      token: token, resourceResolver: provider as? any ProviderHTTPResourceResolving)
            }

            var evidence: [[String: Any]] = []
            // Native-compatible fixture: this baseline must NOT become a transcode.
            evidence.append(try await exercise(
                provider: provider, resolver: resolver, http: http, server: server, configuration: configuration,
                options: .init(quality: .original), resumeAt: 0, expectedCodec: nil, name: "maximum", deviceID: session.deviceID
            ))
            for codec in server.codecs {
                let options = StreamingPlaybackOptions(
                    quality: try .custom(maximumHeight: 1080, bitrateKbps: 2_000),
                    codec: codec == "hevc" ? .preferHEVC : .preferH264, forceTranscoding: true
                )
                evidence.append(try await exercise(
                    provider: provider, resolver: resolver, http: http, server: server, configuration: configuration,
                    options: options, resumeAt: configuration.resumeSeconds, expectedCodec: codec == "server" ? "h264" : codec,
                    name: "custom-1080p-2000Kbps-\(codec)", deviceID: session.deviceID
                ))
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "provider": providerName, "cases": evidence,
                "audioEvidence": "Decoded PCM from bytes of the served stream; not speaker-route or HDMI validation."
            ], options: [.sortedKeys, .prettyPrinted])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "\(providerName)-playback-evidence"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            XCTFail("Provider playback failed: \(providerName); \(safeFailure(error))")
        }
    }

    private func exercise(
        provider: any MediaProvider, resolver: ManagedAuthenticatedHTTPResolver,
        http: PlaybackTestHTTPClient, server: PlaybackTestConfiguration.Server,
        configuration: PlaybackTestConfiguration, options: StreamingPlaybackOptions,
        resumeAt: Double, expectedCodec: String?, name: String, deviceID: String
    ) async throws -> [String: Any] {
        let started = ContinuousClock.now
        guard let streaming = provider as? any StreamingQualityProviding else {
            throw PlaybackTestFailure.invalidConfiguration
        }
        var requested = options
        requested.startPosition = resumeAt
        let request = try await streaming.playbackInfo(
            for: server.itemID, mediaSourceID: server.mediaSourceID,
            forceTranscode: options.forceTranscoding, streaming: requested
        )
        guard !request.isTranscoding || (request.streamingSessionID ?? request.playSessionID) != nil else {
            await (provider as? any StreamingQualityProviding)?.releaseStreamingSession(request)
            throw PlaybackTestFailure.cleanupFailed
        }
        let lease = try recordLease(request, provider: provider.kind.rawValue, deviceID: deviceID, server: server,
                                   installationID: await http.siloInstallationID)
        let engine = NativeVideoEngine(authenticatedHTTPResolver: resolver, startsMuted: true)
        let cleanupBaseline = await http.cleanupAcknowledgments
        do {
            guard request.isTranscoding == options.requiresConversionPolicy else {
                throw PlaybackTestFailure.unexpectedDelivery
            }
            if let source = server.mediaSourceID {
            guard case .authenticatedHTTP(let locator) = request.playbackSource,
                  locator.mediaSourceID == source else {
                    throw PlaybackTestFailure.unexpectedDelivery
                }
            }
            let load = Task { await engine.load(request: request, startPosition: resumeAt) }
            defer { load.cancel() }
            let output = AVPlayerItemVideoOutput(outputSettings: nil)
            var attachedItem: AVPlayerItem?
            var presented = false
            let deadline = ContinuousClock.now + .seconds(configuration.startupTimeoutSeconds)
            while ContinuousClock.now < deadline {
                if let item = engine.underlyingPlayer?.currentItem, item !== attachedItem {
                    item.add(output)
                    attachedItem = item
                }
                try checkEngine(engine)
                if let item = attachedItem, item.status == .readyToPlay,
                   output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) != nil {
                    presented = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let item = attachedItem, let player = engine.underlyingPlayer,
                  item.status == .readyToPlay, presented else {
                throw PlaybackTestFailure.startupTimeout
            }
            let firstFrame = started.duration(to: .now).seconds
            try await provider.reportPlayback(.init(
                itemID: request.item.id, playSessionID: request.playSessionID,
                positionSeconds: engine.currentTime, isPaused: false
            ), event: .start)
            let sustained = try await frames(engine: engine, output: output, seconds: configuration.playbackSeconds)
            guard sustained.frames >= 10, sustained.progress >= configuration.playbackSeconds * 0.8 else {
                throw PlaybackTestFailure.sustainedPlaybackFailed
            }
            let actual = try await format(item)
            if options.requiresConversionPolicy {
                guard actual.width <= (options.quality.maximumWidth ?? 0),
                      actual.height <= (options.quality.maximumHeight ?? 0) else {
                    throw PlaybackTestFailure.wrongDimensions
                }
                if let expectedCodec, actual.codec != expectedCodec { throw PlaybackTestFailure.wrongCodec }
            }
            let decodedAudioSamples = try await verifyAudio(item: item, http: http)
            engine.pause()
            let pausedAt = engine.currentTime
            try await Task.sleep(for: .milliseconds(500))
            guard abs(engine.currentTime - pausedAt) < 0.25 else { throw PlaybackTestFailure.pauseFailed }
            engine.play()
            let seek = Task { await engine.seek(to: configuration.seekSeconds) }
            defer { seek.cancel() }
            let seekDeadline = ContinuousClock.now + .seconds(configuration.startupTimeoutSeconds)
            var reached = false
            while ContinuousClock.now < seekDeadline {
                try checkEngine(engine)
                if abs(engine.currentTime - configuration.seekSeconds) < 2,
                   output.hasNewPixelBuffer(forItemTime: player.currentTime()) {
                    reached = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard reached else { throw PlaybackTestFailure.seekFailed }
            let afterSeek = try await frames(engine: engine, output: output, seconds: 3)
            guard afterSeek.frames >= 5, afterSeek.progress > 1 else { throw PlaybackTestFailure.seekFailed }
            let stoppedAt = engine.currentTime
            engine.stop()
            player.replaceCurrentItem(with: nil)
            try await provider.reportPlayback(.init(
                itemID: request.item.id, playSessionID: request.playSessionID,
                positionSeconds: stoppedAt, isPaused: true
            ), event: .stop)
            await (provider as? any StreamingQualityProviding)?.releaseStreamingSession(request)
            if request.isTranscoding || provider.kind == .silo {
                guard await http.cleanupAcknowledgments > cleanupBaseline else { throw PlaybackTestFailure.cleanupFailed }
            }
            if let lease { try FileManager.default.removeItem(at: lease) }
            return [
                "case": name, "firstFrameSeconds": firstFrame, "decodedVideoFrames": sustained.frames,
                "playbackProgressSeconds": sustained.progress, "width": actual.width, "height": actual.height,
                "videoCodec": actual.codec, "decodedAudioSamples": decodedAudioSamples,
                "seekPositionSeconds": configuration.seekSeconds, "cleanup": "acknowledged"
            ]
        } catch {
            let position = engine.currentTime
            let player = engine.underlyingPlayer
            engine.stop()
            player?.replaceCurrentItem(with: nil)
            // Failed startup still owns a server encoding. Only this request is released.
            do {
                try await provider.reportPlayback(.init(
                    itemID: request.item.id, playSessionID: request.playSessionID,
                    positionSeconds: position, isPaused: true
                ), event: .stop)
            } catch {
                // The lease remains until explicit encoding release is acknowledged.
                HandoffDiagnostics.emit("e2e STOP_REPORT_FAILED provider=\(provider.kind.rawValue)")
            }
            await (provider as? any StreamingQualityProviding)?.releaseStreamingSession(request)
            if await http.cleanupAcknowledgments > cleanupBaseline, let lease {
                try? FileManager.default.removeItem(at: lease)
            }
            throw error
        }
    }

    private func recordLease(
        _ request: PlaybackRequest, provider: String, deviceID: String, server: PlaybackTestConfiguration.Server,
        installationID: String?
    ) throws -> URL? {
        guard request.isTranscoding || provider == "silo",
              let sessionID = request.streamingSessionID ?? request.playSessionID,
              let root = ProcessInfo.processInfo.environment["PLOZZ_PLAYBACK_E2E_LEASE_DIR"] else { return nil }
        let url = URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString + ".json")
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": provider, "sessionID": sessionID, "deviceID": deviceID,
            "serverID": server.serverID, "baseURL": server.baseURL.absoluteString, "userID": server.userID,
            "installationID": installationID ?? "", "stopID": UUID().uuidString.lowercased()
        ])
        try data.write(to: url, options: .atomic)
        return url
    }

    private func checkEngine(_ engine: NativeVideoEngine) throws {
        if let player = engine.underlyingPlayer, !player.isMuted {
            player.pause()
            throw PlaybackTestFailure.audibleTestPlayer
        }
        if case .failed = engine.status { throw PlaybackTestFailure.missingVideo }
        if engine.underlyingPlayer?.currentItem?.status == .failed { throw PlaybackTestFailure.missingVideo }
    }

    private func frames(engine: NativeVideoEngine, output: AVPlayerItemVideoOutput, seconds: Double) async throws -> (frames: Int, progress: Double) {
        let start = engine.currentTime
        let deadline = ContinuousClock.now + .seconds(seconds)
        var count = 0
        while ContinuousClock.now < deadline {
            try checkEngine(engine)
            let time = CMTime(seconds: engine.currentTime, preferredTimescale: 600)
            if output.hasNewPixelBuffer(forItemTime: time),
               output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil { count += 1 }
            try await Task.sleep(for: .milliseconds(50))
        }
        return (count, engine.currentTime - start)
    }

    private func format(_ item: AVPlayerItem) async throws -> (codec: String, width: Int, height: Int) {
        for _ in 0..<30 {
            let details = await NativeStreamDetailsReader.read(item)
            if let video = details.video, let codec = video.codec, let width = video.width, let height = video.height {
                return (codec, width, height)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PlaybackTestFailure.missingVideo
    }

    private func verifyAudio(item: AVPlayerItem, http: PlaybackTestHTTPClient) async throws -> Int {
        guard let url = (item.asset as? AVURLAsset)?.url else { throw PlaybackTestFailure.missingAudio }
        let data: Data
        if url.pathExtension.lowercased() == "m3u8" {
            let playlist = try await http.media(url, maximumBytes: 2_000_000)
            guard var text = String(data: playlist, encoding: .utf8) else { throw PlaybackTestFailure.invalidPlaylist }
            var mediaURL = url
            if let variant = StreamingMediaPlaylist.singleMediaURL(in: text, masterURL: url) {
                mediaURL = variant
                let mediaPlaylist = try await http.media(variant, maximumBytes: 2_000_000)
                guard let decoded = String(data: mediaPlaylist, encoding: .utf8) else { throw PlaybackTestFailure.invalidPlaylist }
                text = decoded
            }
            let segment = try PlaybackTestPlaylist.segment(text, baseURL: mediaURL, position: max(0, item.currentTime().seconds))
            var bytes = Data()
            if let initialization = segment.initialization {
                bytes = try await http.media(initialization, maximumBytes: 2_000_000)
            }
            bytes.append(try await http.media(segment.media, maximumBytes: 16_000_000))
            data = bytes
        } else {
            data = try await http.media(url, maximumBytes: 64_000_000)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-audio-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        let asset = AVURLAsset(url: temporary)
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else { throw PlaybackTestFailure.missingAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        guard reader.startReading() else { throw PlaybackTestFailure.audioDecodeFailed }
        defer { reader.cancelReading() }
        var samples = 0
        while samples < 48_000, let buffer = output.copyNextSampleBuffer() {
            samples += CMSampleBufferGetNumSamples(buffer)
        }
        guard samples > 0, reader.status != .failed else { throw PlaybackTestFailure.audioDecodeFailed }
        return samples
    }

    private func safeFailure(_ error: Error) -> String {
        if let known = error as? PlaybackTestFailure { return known.rawValue }
        if let known = error as? StreamingQualityError { return known.diagnosticCode ?? "provider-negotiation" }
        if let known = error as? AppError { return HandoffDiagnostics.errorCode(known) }
        return "unclassified-error"
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

actor PlaybackTestHTTPClient: HTTPClient {
    private let client: URLSessionHTTPClient
    private(set) var cleanupAcknowledgments = 0
    private(set) var siloInstallationID: String?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        client = URLSessionHTTPClient(session: URLSession(configuration: configuration))
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let result = try await client.send(endpoint, baseURL: baseURL)
        recordCleanup(endpoint, result.1, data: result.0)
        recordSiloCapabilities(endpoint, result.0)
        return result
    }

    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let result = try await client.sendRaw(endpoint, baseURL: baseURL)
        recordCleanup(endpoint, result.1, data: result.0)
        recordSiloCapabilities(endpoint, result.0)
        return result
    }

    private func recordCleanup(_ endpoint: Endpoint, _ response: HTTPURLResponse, data: Data) {
        guard (200...299).contains(response.statusCode) else { return }
        if endpoint.path.hasSuffix("/ActiveEncodings") || endpoint.path.hasSuffix("/transcode/universal/stop") {
            cleanupAcknowledgments += 1
        } else if endpoint.method == .delete, endpoint.path.hasPrefix("/api/v2/playback/"),
                  let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let outcome = receipt["outcome"] as? String, ["stopped", "replayed"].contains(outcome) {
            cleanupAcknowledgments += 1
        }
    }

    private func recordSiloCapabilities(_ endpoint: Endpoint, _ data: Data) {
        guard endpoint.path == "/api/v2/playback/capabilities",
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        siloInstallationID = object["installation_id"] as? String
    }

    func media(_ url: URL, maximumBytes: Int) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(maximumBytes)", forHTTPHeaderField: "Range")
        let (file, response) = try await session.download(for: request, delegate: BoundedMediaDownload(origin: url, limit: maximumBytes))
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes else {
            throw PlaybackTestFailure.mediaFetchFailed
        }
        let data = try Data(contentsOf: file)
        guard !data.isEmpty, data.count <= maximumBytes, let responseURL = response.url,
              PlaybackTestPlaylist.sameOrigin(responseURL, url) else { throw PlaybackTestFailure.mediaFetchFailed }
        return data
    }
}

/// Dedicated test login only. Refuse token rotation rather than spend a refresh
/// token without persisting its replacement back into the owner's Keychain.
private struct PlaybackTestSiloCredentialStore: RotatingCredentialStoring {
    let raw: String
    let revision: CredentialRevision
    func credential(accountID: String, revision: CredentialRevision) throws -> String {
        guard accountID == "e2e", revision == self.revision else { throw AppError.unauthorized }
        return raw
    }
    func rotateCredential(accountID: String, revision: CredentialRevision, expected: String, replacement: String) throws {
        throw AppError.unauthorized
    }
}

private final class BoundedMediaDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let origin: URL
    let limit: Int
    init(origin: URL, limit: Int) { self.origin = origin; self.limit = limit }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map { PlaybackTestPlaylist.sameOrigin($0, origin) } == true ? request : nil)
    }
}
#endif
