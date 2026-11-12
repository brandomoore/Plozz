import CoreModels
import CoreNetworking
import Foundation
import Observation

public typealias HomeRowBrowseQuery = HomeContentQuery

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
    public let style: LibrarySection.Style
    public private(set) var items: [MediaItem] = []
    public private(set) var error: AppError?
    public private(set) var isLoading = false
    public private(set) var hasMore: Bool
    public var query = HomeRowBrowseQuery()
    public private(set) var appliedQuery = HomeRowBrowseQuery()
    @ObservationIgnored private let loaders: [PageLoader]
    @ObservationIgnored private let contentPager: HomeContentPager?
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
        style: LibrarySection.Style = .poster,
        snapshot: [MediaItem] = [], loaders: [PageLoader] = [], contentPager: HomeContentPager? = nil,
        snapshotProvider: (@MainActor () -> [MediaItem]?)? = nil, watchlistDates: Bool = false,
        query: HomeRowBrowseQuery = .init(),
        isCurrent: @escaping @MainActor () -> Bool = { true },
        merge: @escaping @Sendable ([[MediaItem]]) -> [MediaItem] = { $0.flatMap { $0 } }
    ) {
        self.title = title
        self.localizedTitle = localizedTitle
        self.titleSuffix = titleSuffix
        self.style = style
        self.loaders = loaders
        self.contentPager = contentPager
        self.isCurrent = isCurrent
        self.merge = merge
        self.snapshotProvider = snapshotProvider
        self.watchlistDates = watchlistDates
        self.query = query
        groups = contentPager != nil ? [[]] : loaders.isEmpty ? [snapshot] : Array(repeating: [], count: loaders.count)
        offsets = Array(repeating: 0, count: loaders.count)
        hasMore = contentPager != nil || !loaders.isEmpty
        items = contentPager == nil && loaders.isEmpty ? query.applying(to: snapshot, watchlistDates: watchlistDates) : []
    }

    public var liveSnapshot: [MediaItem]? { snapshotProvider?() }
    public var scopeIsCurrent: Bool { isCurrent() }

    func page(start: Int, limit: Int) async throws -> HomeRowPage {
        guard start >= 0, limit > 0, start < Int.max - limit, isCurrent() else { throw AppError.notFound }
        let end = start + limit
        while items.count <= end && hasMore {
            try Task.checkCancellation()
            await load()
            if let error { throw error }
        }
        try Task.checkCancellation()
        guard isCurrent() else { throw AppError.notFound }
        return .init(items: Array(items.dropFirst(start).prefix(limit)), nextOffset: items.count > end || hasMore ? end : nil)
    }

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
                if hasMore { try await appendPage(generation: token, complete: !requested.isDefault) }
                try Task.checkCancellation()
                guard token == generation, isCurrent() else { throw CancellationError() }
            } while hasMore && error == nil && !requested.isDefault
            if !requested.isDefault, let error { throw error }
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

    private func appendPage(generation token: Int, complete: Bool = false) async throws {
        if let contentPager {
            let result = complete ? try await contentPager.loadAll()
                : try await contentPager.loadNext(limit: PageRequest.defaultLimit)
            try Task.checkCancellation()
            guard token == generation, isCurrent() else { throw CancellationError() }
            groups = [result.items]
            hasMore = result.hasMore
            error = contentPager.sources.compactMap { result.failures[$0.id] }.first
            if error != nil { PlozzLog.app.error("Some custom Home row sources could not be loaded") }
            return
        }
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
