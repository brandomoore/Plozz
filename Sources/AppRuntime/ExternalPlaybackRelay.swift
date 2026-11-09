import CoreModels
import CoreNetworking
import Foundation
import MediaTransportCore

@MainActor
final class ExternalPlaybackRelay {
    typealias ExecutionProvider = @MainActor (String, ExternalPlayer, Int64) async throws -> any ExternalPlaybackExecutionLease
    let mediaURL: URL
    let subtitleURLs: [URL]
    let contextIdentity: String
    private let execution: any ExternalPlaybackExecutionLease
    private let server: ExternalPlaybackByteServer
    private let sources: [MediaTransportResolvedSource]
    private var shutdown: Task<Void, Never>?
    var isValid: Bool { shutdown == nil && execution.isValid }

    private init(
        urls: [URL], contextIdentity: String, execution: any ExternalPlaybackExecutionLease,
        server: ExternalPlaybackByteServer, sources: [MediaTransportResolvedSource]
    ) {
        mediaURL = urls[0]
        subtitleURLs = Array(urls.dropFirst())
        self.contextIdentity = contextIdentity
        self.execution = execution
        self.server = server
        self.sources = sources
    }

    static func prepare(
        request: PlaybackRequest, player: ExternalPlayer, contextIdentity: String,
        resolver: any MediaTransportNetworkFileResolving,
        acquire: ExecutionProvider,
        authorized: @escaping @MainActor @Sendable () -> Bool,
        expired: @escaping @MainActor () -> Void
    ) async throws -> ExternalPlaybackRelay {
        guard case .networkFile(let locator) = request.playbackSource,
              request.sourceProvider == .mediaShare, player != .custom,
              !["m3u", "m3u8", "mpd", "strm", "iso", "bdmv"].contains(
                (locator.relativePath as NSString).pathExtension.lowercased()
              ) else { throw ExternalPlayerError.unsupportedSource }
        var sources: [MediaTransportResolvedSource] = []
        var resources: [ExternalPlaybackByteServer.Resource] = []
        var execution: (any ExternalPlaybackExecutionLease)?
        var server: ExternalPlaybackByteServer?
        do {
            let source = try await resolver.resolve(locator)
            sources.append(source)
            guard authorized(), let cursor = source.sourceLease.makeCursor() else { throw CancellationError() }
            let ext = (locator.relativePath as NSString).pathExtension.lowercased()
            resources.append(.init(
                cursor: cursor, suffix: ext.isEmpty ? "bin" : ext, preferredReadSize: source.sourceLease.preferredReadSize
            ))
            for subtitle in request.externalSubtitleLocators.prefix(player == .vlc ? 1 : 8) {
                guard subtitle.accountID == locator.accountID, subtitle.sourceID == locator.sourceID,
                      subtitle.credentialRevision == locator.credentialRevision,
                      (subtitle.relativePath as NSString).pathExtension.lowercased() == "srt" else {
                    throw ExternalPlayerError.unsupportedSource
                }
                do {
                    let resolved = try await resolver.withoutPlaybackAdmission().resolve(subtitle)
                    sources.append(resolved)
                    guard authorized(), let cursor = resolved.sourceLease.makeCursor() else { throw CancellationError() }
                    resources.append(.init(cursor: cursor, suffix: "srt"))
                } catch {
                    if error is CancellationError || (error as? MediaTransportError) == .cancelled { throw error }
                    try Task.checkCancellation()
                    PlozzLog.playback.error("External file subtitle could not be opened.")
                }
            }
            try Task.checkCancellation()
            guard authorized() else { throw CancellationError() }
            let grant = try await acquire(request.item.title, player, source.sourceLease.byteSize)
            execution = grant
            guard grant.isValid, authorized() else { throw CancellationError() }
            let endpoint = try ExternalPlaybackByteServer(
                resources: resources,
                authorized: { grant.isValid && authorized() },
                progress: { grant.update(deliveredBytes: $0) },
                failed: {
                    grant.finish(success: false)
                    expired()
                }
            )
            server = endpoint
            let urls = try await endpoint.start()
            try Task.checkCancellation()
            guard grant.isValid, authorized() else { throw CancellationError() }
            let relay = ExternalPlaybackRelay(
                urls: urls, contextIdentity: contextIdentity, execution: grant, server: endpoint, sources: sources
            )
            grant.onExpiration { [weak relay] in
                relay?.stop(success: false)
                expired()
            }
            guard relay.isValid else { throw ExternalPlayerError.unavailable }
            return relay
        } catch {
            execution?.finish(success: false)
            await server?.stop()
            resources.forEach { $0.cursor.close() }
            for source in sources { await source.waitForFinalShutdown() }
            throw error
        }
    }

    func stop(success: Bool) {
        guard shutdown == nil else { return }
        execution.finish(success: success)
        let server = server
        let sources = sources
        shutdown = Task {
            await server.stop()
            for source in sources { await source.waitForFinalShutdown() }
        }
    }

    func waitForShutdown() async { await shutdown?.value }

    deinit {
        let server = server
        let sources = sources
        let execution = execution
        Task { @MainActor in
            execution.finish(success: false)
            await server.stop()
            for source in sources { await source.waitForFinalShutdown() }
        }
    }
}
