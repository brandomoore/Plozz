import CoreModels
import CoreNetworking
import Foundation

/// Coalesces public feed reads. Individual UI consumers can leave without
/// cancelling another profile's identical read or waiting for a slow provider.
public actor HeroDiscoveryService {
    public static let shared = HeroDiscoveryService()

    private struct Key: Hashable {
        let source: HeroDiscoverySource
        let provider: String
        let language: String
        let region: String
        let day: Int
        let limit: Int
        let seeds: [HeroDiscoveryRequest.SeedIdentity]
        let recency: HeroDiscoveryRecency
    }

    private struct Cached {
        let items: [MediaItem]
        let refreshedAt: Date
        var accessedAt: Date
    }

    private struct Reply: Sendable {
        let index: Int
        let items: [MediaItem]
    }

    private struct Subscriber {
        let index: Int
        let continuation: AsyncStream<Reply>.Continuation
    }

    private struct Load {
        let generation: UUID
        let task: Task<Void, Never>
        let deadline: Task<Void, Never>
        var subscribers: [UUID: Subscriber]
    }

    private var cached: [Key: Cached] = [:]
    private var inFlight: [Key: Load] = [:]
    private var retryAfter: [Key: Date] = [:]
    private var activeGenerations: Set<UUID> = []
    private let cacheLifetime: TimeInterval
    private let responseBudget: Duration
    private let loadBudget: Duration
    private let maximumInFlight: Int
    private let now: @Sendable () -> Date
    private let maximumCachedKeys = 64

    var activeLoadCount: Int { activeGenerations.count }
    var backoffEntryCount: Int { retryAfter.count }
    var subscriberCount: Int {
        inFlight.values.reduce(0) { $0 + $1.subscribers.count }
    }

    public init(
        cacheLifetime: TimeInterval = 600,
        responseBudget: Duration = .seconds(15),
        loadBudget: Duration = .seconds(20),
        maximumInFlight: Int = 16,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cacheLifetime = max(1, cacheLifetime)
        self.responseBudget = responseBudget
        self.loadBudget = loadBudget
        self.maximumInFlight = max(1, maximumInFlight)
        self.now = now
    }

    public func discover(
        _ request: HeroDiscoveryRequest,
        sources: [HeroDiscoverySource],
        providers: [any HeroDiscoveryProviding]
    ) async -> [MediaItem] {
        guard request.limit > 0, !Task.isCancelled else { return [] }
        let selected = HeroDiscoverySource.normalized(sources)
        let active = selected.compactMap { source in
            providers.first { $0.source == source && $0.isEnabled }
        }
        guard !active.isEmpty else { return [] }
        let perProviderLimit = min(
            HeroDiscoveryRequest.maximumLimit,
            max(12, ((request.limit + active.count - 1) / active.count) * 2)
        )
        let providerRequest = HeroDiscoveryRequest(
            limit: perProviderLimit, language: request.language,
            region: request.region, seeds: request.seeds, now: request.now, recency: request.recency
        )
        let requestID = UUID()
        let channel = AsyncStream<Reply>.makeStream(bufferingPolicy: .bufferingNewest(active.count))
        for (index, provider) in active.enumerated() {
            subscribe(
                requestID: requestID, index: index, provider: provider,
                request: providerRequest, continuation: channel.continuation
            )
        }
        let budget = responseBudget
        let deadline = Task {
            do { try await Task.sleep(for: budget) }
            catch { return }
            channel.continuation.finish()
        }
        var replies: [Int: [MediaItem]] = [:]
        for await reply in channel.stream {
            replies[reply.index] = reply.items
            if replies.count == active.count { break }
        }
        deadline.cancel()
        channel.continuation.finish()
        for key in Array(inFlight.keys) {
            inFlight[key]?.subscribers.removeValue(forKey: requestID)
        }
        guard !Task.isCancelled else { return [] }
        if replies.count < active.count {
            PlozzLog.discovery.error("Featured discovery reached its response deadline; keeping completed sources")
        }
        return Self.compose(
            active.indices.map { replies[$0] ?? [] },
            limit: request.limit
        )
    }

    private func subscribe(
        requestID: UUID,
        index: Int,
        provider: any HeroDiscoveryProviding,
        request: HeroDiscoveryRequest,
        continuation: AsyncStream<Reply>.Continuation
    ) {
        let key = Self.key(provider: provider, request: request)
        let currentTime = now()
        if var entry = cached[key] {
            entry.accessedAt = currentTime
            cached[key] = entry
            if currentTime.timeIntervalSince(entry.refreshedAt) < cacheLifetime {
                continuation.yield(Reply(index: index, items: entry.items))
                return
            }
        }
        if let retry = retryAfter[key], retry > currentTime {
            continuation.yield(Reply(index: index, items: cached[key]?.items ?? []))
            return
        }
        let subscriber = Subscriber(index: index, continuation: continuation)
        if inFlight[key] != nil {
            inFlight[key]?.subscribers[requestID] = subscriber
            return
        }
        guard activeGenerations.count < maximumInFlight else {
            PlozzLog.discovery.error("Featured discovery admission is full; keeping cached source results")
            continuation.yield(Reply(index: index, items: cached[key]?.items ?? []))
            return
        }
        let generation = UUID()
        activeGenerations.insert(generation)
        let task = Task {
            do {
                let items = try await provider.discover(request)
                finish(
                    key: key, generation: generation,
                    result: .success(Self.externalItems(items, source: provider.source, limit: request.limit))
                )
            } catch {
                finish(key: key, generation: generation, result: .failure(error))
            }
        }
        let budget = loadBudget
        let deadline = Task {
            do { try await Task.sleep(for: budget) }
            catch { return }
            expire(key: key, generation: generation)
        }
        inFlight[key] = Load(
            generation: generation, task: task, deadline: deadline,
            subscribers: [requestID: subscriber]
        )
    }

    private func finish(key: Key, generation: UUID, result: Result<[MediaItem], Error>) {
        activeGenerations.remove(generation)
        guard let load = inFlight[key], load.generation == generation else { return }
        inFlight[key] = nil
        load.deadline.cancel()
        let currentTime = now()
        let items: [MediaItem]
        switch result {
        case let .success(fresh):
            items = fresh
            cached[key] = Cached(items: fresh, refreshedAt: currentTime, accessedAt: currentTime)
            retryAfter[key] = nil
        case let .failure(error):
            items = cached[key]?.items ?? []
            var delay: TimeInterval = 60
            if case let MetadataDiscoveryHTTPError.status(status, retry) = error {
                if status == 401 || status == 403 { delay = 600 }
                if let retry, retry.isFinite { delay = min(900, max(delay, retry)) }
            }
            if error is CancellationError {
                retryAfter[key] = nil
            } else {
                retryAfter[key] = currentTime.addingTimeInterval(delay)
                PlozzLog.discovery.error("Featured discovery \(key.source.rawValue) failed; retaining cached results")
            }
        }
        trim(at: currentTime)
        for subscriber in load.subscribers.values {
            subscriber.continuation.yield(Reply(index: subscriber.index, items: items))
        }
    }

    private func expire(key: Key, generation: UUID) {
        guard let load = inFlight[key], load.generation == generation else { return }
        inFlight[key] = nil
        load.task.cancel()
        let currentTime = now()
        retryAfter[key] = currentTime.addingTimeInterval(60)
        trim(at: currentTime)
        PlozzLog.discovery.error("Featured discovery \(key.source.rawValue) exceeded its load deadline")
        let items = cached[key]?.items ?? []
        for subscriber in load.subscribers.values {
            subscriber.continuation.yield(Reply(index: subscriber.index, items: items))
        }
    }

    private func trim(at date: Date) {
        retryAfter = retryAfter.filter { $0.value > date }
        if retryAfter.count > maximumCachedKeys {
            for key in retryAfter.sorted(by: { $0.value < $1.value })
                .prefix(retryAfter.count - maximumCachedKeys).map(\.key) {
                retryAfter[key] = nil
            }
        }
        guard cached.count > maximumCachedKeys else { return }
        for key in cached.sorted(by: { $0.value.accessedAt < $1.value.accessedAt })
            .prefix(cached.count - maximumCachedKeys).map(\.key) {
            cached[key] = nil
        }
    }

    private static func key(provider: any HeroDiscoveryProviding, request: HeroDiscoveryRequest) -> Key {
        let seeds = provider.usesTitleSeeds ? request.seedIdentities : []
        return Key(
            source: provider.source, provider: provider.cacheIdentifier,
            language: request.language, region: request.region,
            day: Int(request.now.timeIntervalSince1970 / 86_400),
            limit: request.limit, seeds: seeds, recency: request.recency
        )
    }

    private static func externalItems(
        _ items: [MediaItem], source: HeroDiscoverySource, limit: Int
    ) -> [MediaItem] {
        Array(items.lazy.filter {
            [.movie, .series].contains($0.kind)
                && !$0.id.isEmpty
                && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.providerIDs.isEmpty
        }.prefix(limit)).map { item in
            var item = item.sanitizingArtworkCredentials()
            item.discoverySources = [source]
            if let attribution = item.metadataProvenance[.title],
               attribution.source.rawValue == source.rawValue,
               let url = attribution.sourceURL, source.acceptsAttributionURL(url) {
                item.discoveryURLs = [source.rawValue: url]
            } else {
                item.discoveryURLs = HeroDiscoverySource.validatedURLs(item.discoveryURLs)
                    .filter { $0.key == source.rawValue }
            }
            item.locallyValidatedPlayableSource = false
            item.availability = .unknown
            item.downloadProgress = nil
            item.watchlistAliasID = nil
            item.fileBrowserContainerID = nil
            item.sourceAccountID = nil
            item.artworkSourceAccountIDsByURL = [:]
            item.additionalSourceAccountIDs = []
            item.sources = []
            item.libraryID = nil
            item.mediaInfo = nil
            item.versions = []
            item.selectedVersionID = nil
            item.selectedSourceAccountID = nil
            item.explicitSourceSelection = false
            item.resumePosition = nil
            item.playedPercentage = nil
            item.isPlayed = false
            item.hasBeenPlayed = false
            item.isFavorite = false
            item.lastPlayedAt = nil
            return item
        }
    }

    private static func compose(_ buckets: [[MediaItem]], limit: Int) -> [MediaItem] {
        var interleaved: [MediaItem] = []
        for index in 0..<(buckets.map(\.count).max() ?? 0) {
            for bucket in buckets where index < bucket.count {
                interleaved.append(bucket[index])
            }
        }
        return Array(TitleDedupe.collapsed(interleaved, policy: .titleAndYear).prefix(limit))
    }
}
