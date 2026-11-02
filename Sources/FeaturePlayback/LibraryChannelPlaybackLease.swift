import CoreModels
import CoreNetworking
import Foundation

/// Owns provider transport independently of watch reporting and view cancellation.
actor LibraryChannelPlaybackLease {
    private let provider: any LibraryChannelPlaybackProviding
    private let request: PlaybackRequest
    private var progressTask: Task<Void, Error>?
    private var releaseTask: Task<Void, Error>?

    init(provider: any LibraryChannelPlaybackProviding, request: PlaybackRequest) {
        self.provider = provider
        self.request = request
    }

    deinit {
        guard releaseTask == nil else { return }
        let provider = provider
        let request = request
        let pending = progressTask
        pending?.cancel()
        Task {
            _ = await pending?.result
            do { try await provider.releaseLibraryChannelPlayback(request) }
            catch { PlozzLog.playback.error("Library channel transport cleanup failed") }
        }
    }

    func report(position: Double, isPaused: Bool) async throws {
        guard releaseTask == nil, progressTask == nil else { return }
        let progress = PlaybackProgress(
            itemID: request.item.id, playSessionID: request.playSessionID,
            positionSeconds: position, isPaused: isPaused)
        let task = Task { [provider] in try await provider.reportLibraryChannelPlayback(progress) }
        progressTask = task
        defer { progressTask = nil }
        try await task.value
    }

    func release() async throws {
        if let releaseTask { return try await releaseTask.value }
        let pending = progressTask
        pending?.cancel()
        let task = Task { [provider, request] in
            _ = await pending?.result
            do { try await provider.releaseLibraryChannelPlayback(request) }
            catch {
                PlozzLog.playback.error("Library channel transport cleanup failed")
                throw error
            }
        }
        releaseTask = task
        try await task.value
    }
}
