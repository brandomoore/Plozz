import CoreModels
import CoreNetworking
import Foundation
import Observation

public struct PlayerEpisodeEntry: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        public let seasonID: String?
        public let episodeID: String
    }

    public let item: MediaItem
    public let seasonID: String?
    public let seasonNumber: Int?

    public var id: ID { ID(seasonID: seasonID, episodeID: item.id) }

    public var badge: String? {
        guard let episode = item.episodeNumber else { return nil }
        if let season = item.seasonNumber ?? seasonNumber {
            return "S\(season) · E\(episode)"
        }
        return "E\(episode)"
    }
}

/// Browses episodes across seasons without fetching an entire long-running show.
/// The loaded range remains contiguous and expands only when its edges are seen.
@MainActor
@Observable
public final class PlayerEpisodeBrowser {
    public private(set) var seasons: [MediaItem] = []
    public private(set) var episodes: [PlayerEpisodeEntry] = []
    public private(set) var loadError: AppError?
    public private(set) var previousLoadError: AppError?
    public private(set) var nextLoadError: AppError?
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var isLoadingPrevious = false
    public private(set) var isLoadingNext = false
    public private(set) var previousSeasonIndex: Int?
    public private(set) var nextSeasonIndex: Int?

    private let provider: any MediaProvider
    private var initialSeasonID: String?
    private let initialEpisodeID: String
    private let accountID: String?
    private let openingEpisodeNumber: Int?
    private enum Load: String { case initial, previous, next }
    @ObservationIgnored private var loads: [Load: Task<Void, Never>] = [:]
    @ObservationIgnored private var isStopped = false

    public init(item: MediaItem, provider: any MediaProvider) {
        self.provider = provider
        initialSeasonID = item.seasonID
        initialEpisodeID = item.id
        accountID = item.sourceAccountID
        openingEpisodeNumber = item.episodeNumber
    }

    var initialHasPreviousEpisode: Bool {
        if let index = episodes.firstIndex(where: { $0.item.id == initialEpisodeID }) {
            return index > 0
        }
        return (openingEpisodeNumber ?? 1) > 1
    }

    public var initialEntryID: PlayerEpisodeEntry.ID? {
        episodes.first {
            $0.item.id == initialEpisodeID
                && (initialSeasonID == nil || $0.seasonID == initialSeasonID)
        }?.id
    }

    public func loadIfNeeded() async {
        await runLoad(.initial)
    }

    public func loadPrevious() async {
        await runLoad(.previous)
    }

    public func loadNext() async {
        await runLoad(.next)
    }

    func stop() {
        isStopped = true
        for task in loads.values { task.cancel() }
    }

    /// A replacement view must wait for the cancelled request to drain, then
    /// restart it. Returning merely because `isLoading` is true strands its tab.
    private func runLoad(_ load: Load) async {
        while !Task.isCancelled, !isStopped {
            let task: Task<Void, Never>
            if let existing = loads[load] {
                task = existing
            } else {
                task = Task { [weak self] in
                    guard let self else { return }
                    defer { self.loads[load] = nil }
                    switch load {
                    case .initial: await self.loadInitial()
                    case .previous: await self.loadEarlier()
                    case .next: await self.loadLater()
                    }
                }
                loads[load] = task
            }
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard task.isCancelled else { return }
        }
    }

    private func loadInitial() async {
        guard !Task.isCancelled, !hasLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        loadError = nil
        HandoffDiagnostics.emit("episodes LOAD_BEGIN")
        do {
            // Source selection can retain another server's parent IDs on the opening card.
            let playing = try await provider.item(id: initialEpisodeID)
            try Task.checkCancellation()
            guard playing.id == initialEpisodeID, playing.kind == .episode else {
                throw AppError.invalidResponse
            }
            guard let seriesID = playing.seriesID, !seriesID.isEmpty else {
                throw AppError.notFound
            }
            initialSeasonID = playing.seasonID
            let all = try await provider.children(of: seriesID)
            try Task.checkCancellation()
            seasons = all.filter { $0.kind == .season }
            if seasons.isEmpty {
                episodes = all.filter { $0.kind == .episode }.map {
                    entry(for: $0, season: nil)
                }
            } else {
                let seed = seasons.firstIndex { $0.id == initialSeasonID } ?? 0
                previousSeasonIndex = seed > 0 ? seed - 1 : nil
                nextSeasonIndex = seed + 1 < seasons.count ? seed + 1 : nil
                episodes = try await entries(in: seed)
                try Task.checkCancellation()
                if episodes.isEmpty {
                    try await findFirstEpisodes()
                }
            }
            hasLoaded = true
            HandoffDiagnostics.emit("episodes LOAD_READY count=\(episodes.count)")
        } catch where Task.isCancelled {
            HandoffDiagnostics.emit("episodes LOAD_CANCELLED")
        } catch {
            loadError = Self.reportFailure(error, load: .initial)
        }
    }

    private func loadEarlier() async {
        guard !Task.isCancelled, hasLoaded, let start = previousSeasonIndex,
              !isLoadingPrevious, previousLoadError == nil else { return }
        isLoadingPrevious = true
        defer { isLoadingPrevious = false }
        do {
            for index in stride(from: start, through: 0, by: -1) {
                let fetched = try await entries(in: index)
                try Task.checkCancellation()
                previousSeasonIndex = index > 0 ? index - 1 : nil
                if !fetched.isEmpty {
                    episodes.insert(contentsOf: fetched, at: 0)
                    break
                }
            }
        } catch where Task.isCancelled {
            HandoffDiagnostics.emit("episodes PREVIOUS_CANCELLED")
        } catch {
            previousLoadError = Self.reportFailure(error, load: .previous)
        }
    }

    private func loadLater() async {
        guard !Task.isCancelled, hasLoaded, let start = nextSeasonIndex,
              !isLoadingNext, nextLoadError == nil else { return }
        isLoadingNext = true
        defer { isLoadingNext = false }
        do {
            for index in start..<seasons.count {
                let fetched = try await entries(in: index)
                try Task.checkCancellation()
                nextSeasonIndex = index + 1 < seasons.count ? index + 1 : nil
                if !fetched.isEmpty {
                    episodes.append(contentsOf: fetched)
                    break
                }
            }
        } catch where Task.isCancelled {
            HandoffDiagnostics.emit("episodes NEXT_CANCELLED")
        } catch {
            nextLoadError = Self.reportFailure(error, load: .next)
        }
    }

    public func retryPrevious() async {
        previousLoadError = nil
        await loadPrevious()
    }

    public func retryNext() async {
        nextLoadError = nil
        await loadNext()
    }

    private static func reportFailure(_ error: any Error, load: Load) -> AppError {
        let cancelled = error is CancellationError || error as? AppError == .cancelled
            || (error as? URLError)?.code == .cancelled
        HandoffDiagnostics.emit("episodes LOAD_FAILED direction=\(load.rawValue) providerCancelled=\(cancelled)")
        PlozzLog.playback.error("Episode loading failed; the browser is ready to retry.")
        return cancelled ? .cancelled : error as? AppError ?? .invalidResponse
    }

    private func findFirstEpisodes() async throws {
        while let index = nextSeasonIndex, episodes.isEmpty {
            episodes = try await entries(in: index)
            try Task.checkCancellation()
            nextSeasonIndex = index + 1 < seasons.count ? index + 1 : nil
        }
        while let index = previousSeasonIndex, episodes.isEmpty {
            episodes = try await entries(in: index)
            try Task.checkCancellation()
            previousSeasonIndex = index > 0 ? index - 1 : nil
        }
    }

    private func entries(in index: Int) async throws -> [PlayerEpisodeEntry] {
        let season = seasons[index]
        let members = try await provider.children(of: season.id)
        try Task.checkCancellation()
        return members.filter { $0.kind == .episode }.map {
            entry(for: $0, season: season)
        }
    }

    private func entry(for item: MediaItem, season: MediaItem?) -> PlayerEpisodeEntry {
        PlayerEpisodeEntry(
            item: accountID.map { item.taggingSource($0) } ?? item,
            seasonID: season?.id,
            seasonNumber: season?.seasonNumber
        )
    }
}
