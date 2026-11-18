import Foundation
import Observation

/// Discovers existing section choices without loading their full contents.
/// Identity changes fence every publication, including non-cooperative providers.
@MainActor @Observable
public final class HomeSectionCatalogModel {
    public struct RequestID: Hashable {
        let accounts: [String]
        let libraries: [AggregatedLibrary]
        let profile: ObjectIdentifier
    }

    public struct LoadID: Hashable {
        let scope: RequestID
        let presetRevision: UUID
        let revision: Int
    }

    private struct DiscoveryID: Equatable {
        let load: LoadID
        let scope: UUID?
        let revision: UUID?
        let refreshing: Bool
    }

    public private(set) var catalog = HomeSectionCatalog(libraries: [])
    public private(set) var libraryFailures: [String: AppError] = [:]
    public private(set) var serverFailures: [String: AppError] = [:]
    public private(set) var isLoading = false
    public private(set) var requestID: RequestID?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var recommendations: [String: [LibrarySection]] = [:]
    @ObservationIgnored private var pendingLoadID: DiscoveryID?
    @ObservationIgnored private var pendingLoad: Task<Void, Never>?
    @ObservationIgnored private var consumers: Set<UUID> = []

    public init() {}

    public func currentCatalog(
        libraries: [AggregatedLibrary], accounts: [ResolvedAccount], visibility: HomeLibraryVisibilityModel
    ) -> HomeSectionCatalog {
        if requestID == Self.requestID(libraries: libraries, accounts: accounts, visibility: visibility) {
            return catalog
        }
        let accountIDs = Set(accounts.map(\.account.id))
        return HomeSectionCatalog(
            libraries: libraries.filter { accountIDs.contains($0.accountID) && visibility.isEnabled($0.key) },
            serverRows: (visibility.visibility.rowCustomization?.availableServerRows ?? [])
                .filter { accountIDs.contains($0.accountID) }
        )
    }

    public static func requestID(
        libraries: [AggregatedLibrary], accounts: [ResolvedAccount], visibility: HomeLibraryVisibilityModel
    ) -> RequestID {
        RequestID(
            accounts: accounts.flatMap {
                [$0.account.id, $0.account.server.identityKey, $0.credentialRevision.rawValue.uuidString,
                 $0.provider.session.userID, $0.plexHomeUserID ?? ""]
            },
            libraries: libraries.filter { visibility.isEnabled($0.key) },
            profile: ObjectIdentifier(visibility)
        )
    }

    /// Visible editor pages share discovery; leaving the last consumer cancels it.
    public func load(
        libraries: [AggregatedLibrary], accounts: [ResolvedAccount], visibility: HomeLibraryVisibilityModel,
        recommendationScope: HomeRecommendationScope? = nil, refreshRecommendations: Bool = false
    ) async {
        guard !Task.isCancelled else { return }
        let id = DiscoveryID(
            load: Self.loadID(libraries: libraries, accounts: accounts, visibility: visibility),
            scope: recommendationScope?.id, revision: recommendationScope?.revision, refreshing: refreshRecommendations
        )
        let consumer = UUID()
        let task: Task<Void, Never>
        if pendingLoadID == id, let pendingLoad {
            task = pendingLoad
        } else {
            pendingLoad?.cancel()
            generation = UUID()
            consumers = []
            pendingLoadID = id
            let generation = generation
            task = Task {
                await HomeRecommendationScope.$current.withValue(recommendationScope) {
                    await HomeRecommendationScope.$refreshRequested.withValue(refreshRecommendations) {
                        await discover(libraries: libraries, accounts: accounts, visibility: visibility, generation: generation)
                    }
                }
            }
            pendingLoad = task
        }
        let generation = generation
        consumers.insert(consumer)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.release(consumer, generation: generation)
            }
        }
        release(consumer, generation: generation)
    }

    public static func loadID(
        libraries: [AggregatedLibrary], accounts: [ResolvedAccount],
        visibility: HomeLibraryVisibilityModel, revision: Int = 0
    ) -> LoadID {
        LoadID(
            scope: requestID(libraries: libraries, accounts: accounts, visibility: visibility),
            presetRevision: visibility.rowDefaultsRevision, revision: revision
        )
    }

    private func release(_ consumer: UUID, generation: UUID) {
        guard self.generation == generation, consumers.remove(consumer) != nil,
              consumers.isEmpty else { return }
        pendingLoad?.cancel()
        pendingLoad = nil
        pendingLoadID = nil
        self.generation = UUID()
        isLoading = false
    }

    private func discover(
        libraries: [AggregatedLibrary], accounts: [ResolvedAccount],
        visibility: HomeLibraryVisibilityModel, generation: UUID
    ) async {
        guard !Task.isCancelled, self.generation == generation else { return }
        let request = Self.requestID(libraries: libraries, accounts: accounts, visibility: visibility)
        let accountIDs = Set(accounts.map(\.account.id))
        let available = libraries.filter {
            accountIDs.contains($0.accountID) && visibility.isEnabled($0.key)
                && !$0.library.isMusic && !$0.isRetiredCollectionShortcut
        }
        let known = (visibility.visibility.rowCustomization?.availableServerRows ?? [])
            .filter { accountIDs.contains($0.accountID) }
        let retained = requestID == request ? catalog.choices : []
        var serverRows = known + retained.compactMap(\.serverRow)
        var recommendations = requestID == request ? self.recommendations : [:]
        requestID = request
        libraryFailures = [:]
        serverFailures = [:]
        isLoading = true
        self.recommendations = recommendations
        catalog = HomeSectionCatalog(libraries: available, serverRows: serverRows, recommendations: recommendations)
        defer {
            if self.generation == generation { isLoading = false }
        }

        await visibility.prepareServerDefaults(accounts: accounts)
        guard !Task.isCancelled, self.generation == generation else { return }
        serverRows = (visibility.visibility.rowCustomization?.availableServerRows ?? [])
            .filter { accountIDs.contains($0.accountID) } + serverRows
        let useResolvedServerRows = visibility.visibility.rowCustomization?.defaults == .matchServer
        serverFailures = useResolvedServerRows ? visibility.serverMatchFailures : [:]
        catalog = HomeSectionCatalog(libraries: available, serverRows: serverRows, recommendations: recommendations)
        var requests: [Request] = []
        if !useResolvedServerRows {
            requests += accounts.map { .server($0) }
        }
        requests += available.compactMap { library in
            guard LibraryHomeRowKind.available(for: library).contains(.hubs),
                  let provider = accounts.first(where: { $0.account.id == library.accountID })?.provider
            else { return nil }
            return .library(library, provider)
        }
        await withTaskGroup(of: Response.self) { group in
            var next = 0
            func enqueue() {
                guard next < requests.count, !Task.isCancelled else { return }
                let request = requests[next]
                next += 1
                group.addTask { await Self.fetch(request) }
            }
            for _ in 0..<min(3, requests.count) { enqueue() }
            while let response = await group.next() {
                guard !Task.isCancelled, self.generation == generation else {
                    group.cancelAll()
                    return
                }
                switch response {
                case let .server(accountID, result):
                    switch result {
                    case let .success(rows):
                        serverRows.removeAll { $0.accountID == accountID }
                        serverRows += rows
                    case let .failure(error): serverFailures[accountID] = error
                    }
                case let .library(key, result):
                    switch result {
                    case let .success(rows): recommendations[key] = rows
                    case let .failure(error): libraryFailures[key] = error
                    }
                }
                enqueue()
            }
        }
        guard !Task.isCancelled, self.generation == generation else { return }
        self.recommendations = recommendations
        let savedRows = (visibility.visibility.rowCustomization?.availableServerRows ?? [])
            .filter { accountIDs.contains($0.accountID) }
        serverRows = savedRows + serverRows
        catalog = HomeSectionCatalog(libraries: available, serverRows: serverRows, recommendations: recommendations)
    }

    private enum Request: Sendable {
        case server(ResolvedAccount)
        case library(AggregatedLibrary, any MediaProvider)
    }

    private enum Response: Sendable {
        case server(String, Result<[HomeServerRowDefinition], AppError>)
        case library(String, Result<[LibrarySection], AppError>)
    }

    private nonisolated static func fetch(_ request: Request) async -> Response {
        switch request {
        case let .server(source):
            do {
                let rows = try await source.provider.serverHomeLayout()?.sections ?? []
                try Task.checkCancellation()
                return .server(source.account.id, .success(rows.map {
                    HomeServerRowDefinition(
                        accountID: source.account.id, serverName: source.account.server.name,
                        providerKind: source.account.server.provider, section: $0
                    )
                }))
            } catch {
                return .server(source.account.id, .failure(error is CancellationError ? .cancelled
                    : (error as? AppError) ?? .invalidResponse))
            }
        case let .library(library, provider):
            do {
                let rows = try await provider.homeHubs(
                    libraryID: library.library.id, kind: library.library.kind, limit: 8, includeUnpromoted: true
                )
                try Task.checkCancellation()
                return .library(library.key, .success(rows))
            } catch {
                return .library(library.key, .failure(error is CancellationError ? .cancelled
                    : (error as? AppError) ?? .invalidResponse))
            }
        }
    }
}
