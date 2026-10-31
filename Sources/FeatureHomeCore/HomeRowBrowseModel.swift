import CoreModels
import CoreNetworking
import Foundation
import Observation

public struct HomeRowBrowseQuery: Equatable, Sendable {
    public var sort: CoreModels.SortDescriptor?
    public var media: WatchlistMediaFilter = .all
    public var filters: LibraryFilters = .all

    public init() {}
    public var isDefault: Bool { sort == nil && media == .all && filters.isEmpty }

    public func applying(to items: [MediaItem], watchlistDates: Bool = false) -> [MediaItem] {
        let filtered = items.filter {
            (media == .all || (media == .movies ? $0.kind == .movie : [.series, .season, .episode].contains($0.kind)))
                && LibraryQueryRecord($0, includeFormats: false).matches(filters)
        }
        guard let sort else { return filtered }
        if watchlistDates {
            return WatchlistBrowsePreferences(sort: sort).items(from: filtered)
        }
        return filtered.sorted { MediaItemSortOrder.isOrderedBefore($0, $1, sort: sort) }
    }
}

@MainActor
@Observable
public final class HomeRowBrowseModel: Identifiable, Hashable {
    public typealias PageLoader = @Sendable (Int, Int) async throws -> HomeRowPage
    public let id = UUID()
    public nonisolated static func == (lhs: HomeRowBrowseModel, rhs: HomeRowBrowseModel) -> Bool { lhs.id == rhs.id }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public let title: String // l10n:content — original Home row heading
    public let localizedTitle: LocalizedStringResource?
    public let titleSuffix: String?
    public private(set) var items: [MediaItem] = []
    public private(set) var error: AppError?
    public private(set) var isLoading = false
    public private(set) var hasMore: Bool
    public var query = HomeRowBrowseQuery()
    public private(set) var appliedQuery = HomeRowBrowseQuery()
    @ObservationIgnored private let loaders: [PageLoader]
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private let merge: @Sendable ([[MediaItem]]) -> [MediaItem]
    @ObservationIgnored private let snapshotProvider: (@MainActor () -> [MediaItem]?)?
    @ObservationIgnored private let watchlistDates: Bool
    @ObservationIgnored private var mutations: [MediaItemMutation] = []
    @ObservationIgnored private var groups: [[MediaItem]]
    @ObservationIgnored private var offsets: [Int?]
    @ObservationIgnored private var generation = 0

    public init(
        title: String, localizedTitle: LocalizedStringResource? = nil, titleSuffix: String? = nil, // l10n:content — original Home row heading; app copy uses localizedTitle
        snapshot: [MediaItem] = [], loaders: [PageLoader] = [],
        snapshotProvider: (@MainActor () -> [MediaItem]?)? = nil, watchlistDates: Bool = false,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        merge: @escaping @Sendable ([[MediaItem]]) -> [MediaItem] = { $0.flatMap { $0 } }
    ) {
        self.title = title
        self.localizedTitle = localizedTitle
        self.titleSuffix = titleSuffix
        self.loaders = loaders
        self.isCurrent = isCurrent
        self.merge = merge
        self.snapshotProvider = snapshotProvider
        self.watchlistDates = watchlistDates
        groups = loaders.isEmpty ? [snapshot] : Array(repeating: [], count: loaders.count)
        offsets = Array(repeating: 0, count: loaders.count)
        hasMore = !loaders.isEmpty
        items = loaders.isEmpty ? snapshot : []
    }

    public var liveSnapshot: [MediaItem]? { snapshotProvider?() }
    public var scopeIsCurrent: Bool { isCurrent() }

    public func applyMutation(_ mutation: MediaItemMutation) {
        guard isCurrent() else { invalidate(); return }
        mutations.append(mutation)
        groups = groups.map { $0.map { mutation.applied(to: $0) } }
        items = appliedQuery.applying(to: merge(groups), watchlistDates: watchlistDates)
    }

    /// Alternate ordering/filtering operates on the complete shelf, never just
    /// the first loaded page. Default server order remains incrementally loaded.
    public func load() async {
        guard isCurrent() else { invalidate(); return }
        generation += 1
        if loaders.isEmpty, let snapshot = liveSnapshot { groups = [snapshot] }
        isLoading = true
        error = nil
        let token = generation
        let requested = query
        defer { if token == generation { isLoading = false } }
        do {
            repeat {
                if hasMore { try await appendPage(generation: token) }
                try Task.checkCancellation()
                guard token == generation, isCurrent() else { throw CancellationError() }
            } while hasMore && !requested.isDefault
            let merge = merge
            let watchlistDates = watchlistDates
            while true {
                let groups = groups
                let mutations = mutations
                let projection = Task.detached {
                    try Task.checkCancellation()
                    let all = merge(groups.map { $0.map { item in mutations.reduce(item) { $1.applied(to: $0) } } })
                    return requested.applying(to: all, watchlistDates: watchlistDates)
                }
                let result = try await withTaskCancellationHandler {
                    try await projection.value
                } onCancel: { projection.cancel() }
                try Task.checkCancellation()
                guard token == generation, isCurrent() else { throw CancellationError() }
                guard mutations.count == self.mutations.count else { continue }
                items = result
                break
            }
            appliedQuery = requested
        } catch {
            guard token == generation else { return }
            if !isCurrent() { invalidate(); return }
            if error is CancellationError || (error as? AppError) == .cancelled { return }
            self.error = (error as? AppError) ?? .unknown("Home row could not be loaded")
            PlozzLog.app.error("Home row browse failed: \(HandoffDiagnostics.errorCode(self.error ?? .invalidResponse))")
        }
    }

    public func invalidate() {
        generation += 1
        groups = []
        offsets = []
        items = []
        hasMore = false
        isLoading = false
        error = .notFound
    }

    private func appendPage(generation token: Int) async throws {
        var nextGroups = groups
        var nextOffsets = offsets
        for index in loaders.indices {
            guard let start = offsets[index] else { continue }
            try Task.checkCancellation()
            guard token == generation, isCurrent() else { throw CancellationError() }
            let page = try await loaders[index](start, PageRequest.defaultLimit)
            try Task.checkCancellation()
            guard token == generation, isCurrent() else { throw CancellationError() }
            guard page.nextOffset.map({ $0 > start }) ?? true else { throw AppError.invalidResponse }
            var seen = Set(nextGroups[index].map(\.stablePresentationID))
            let fresh = page.items.filter { seen.insert($0.stablePresentationID).inserted }
            if !page.items.isEmpty && fresh.isEmpty && page.nextOffset != nil {
                throw AppError.invalidResponse
            }
            nextGroups[index] += fresh
            nextOffsets[index] = page.nextOffset
        }
        groups = nextGroups.map { $0.map { item in mutations.reduce(item) { $1.applied(to: $0) } } }
        offsets = nextOffsets
        hasMore = nextOffsets.contains { $0 != nil }
    }
}
