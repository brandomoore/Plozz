import CoreModels
import CoreNetworking
import Foundation
import Observation

@MainActor
@Observable
public final class PlayerCommunityTimestampsModel: Identifiable {
    public let id = UUID()
    public var sourceName: String { source.name }
    public private(set) var entries: [CommunityPlaybackTimestamp] = []
    public private(set) var isLoading = false
    public private(set) var failure: AppError?
    public private(set) var loaded = false
    public var isCurrent: Bool { source.isCurrent && playbackIsCurrent() }
    private let item: MediaItem?
    private let source: any CommunityPlaybackTimestampProviding
    private let duration: () -> TimeInterval
    private let playbackIsCurrent: () -> Bool
    private let requestSeek: (TimeInterval) -> Void
    private var generation = UUID()

    init(
        item: MediaItem?, source: any CommunityPlaybackTimestampProviding,
        duration: @escaping () -> TimeInterval, isCurrent: @escaping () -> Bool,
        requestSeek: @escaping (TimeInterval) -> Void
    ) {
        self.item = item
        self.source = source
        self.duration = duration
        self.playbackIsCurrent = isCurrent
        self.requestSeek = requestSeek
    }

    public func load(includeHighlights: Bool) async {
        generation = UUID()
        let generation = generation
        entries = []
        loaded = false
        failure = nil
        isLoading = true
        defer { if self.generation == generation { isLoading = false } }
        do {
            try Task.checkCancellation()
            guard let item, source.isCurrent, playbackIsCurrent() else { throw AppError.conflict }
            let result = try await source.timestamps(for: item, includeHighlights: includeHighlights)
            guard !Task.isCancelled, self.generation == generation else { return }
            guard source.isCurrent, playbackIsCurrent() else { throw AppError.conflict }
            guard Set(result.map(\.id)).count == result.count else { throw AppError.invalidResponse }
            entries = result
            loaded = true
        } catch {
            guard !Task.isCancelled, self.generation == generation else { return }
            failure = (error as? AppError) ?? .unknown("Could not load community timestamps.")
            PlozzLog.playback.error("Community timestamp lookup failed")
        }
    }

    public func canSeek(_ entry: CommunityPlaybackTimestamp, toEnd: Bool = false) -> Bool {
        loaded && !isLoading && isCurrent
            && entries.contains(entry) && entry.fits(duration: duration())
            && (toEnd ? entry.end : entry.start) < duration()
    }

    @discardableResult
    public func seek(_ entry: CommunityPlaybackTimestamp, toEnd: Bool) -> Bool {
        let target = toEnd ? entry.end : entry.start
        guard canSeek(entry, toEnd: toEnd) else {
            failure = .conflict
            PlozzLog.playback.error("Community timestamp selection no longer matches the playback timeline")
            return false
        }
        requestSeek(target)
        return true
    }

    public func cancel() {
        generation = UUID()
        entries = []
        loaded = false
        isLoading = false
    }
}
