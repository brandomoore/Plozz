import CoreModels
import Foundation

/// Single-use refresh tokens need one owner across Settings, realtime playback,
/// watchlist sync and independently constructed durable-outbox services.
public actor TrackerTokenCoordinator {
    public static let shared = TrackerTokenCoordinator()

    /// Captured before OAuth starts. A nil epoch means confirmed server absence,
    /// never an unknown baseline that may be filled in after authorization.
    public struct ConnectionContext: Sendable {
        let id: UUID
        let scope: String
        let revision: UInt64
        let accountID: String?
        let expectedEpoch: UUID?
    }

    struct Refresh: Sendable {
        let id: UUID
        let task: Task<String?, Error>
        var renewsExpiredTokens = true
        var resolvesAccessToken = true
    }

    private struct PendingWrite {
        let previous: TrackerTokens
        let refreshed: TrackerTokens
    }

    var revisions: [String: UInt64] = [:]
    private(set) var refreshes: [String: Refresh] = [:]
    private var inFlightOperations: [UUID: (key: String, task: Task<String?, Error>)] = [:]
    private var pendingWrites: [String: PendingWrite] = [:]
    private var erasures: [String: UUID] = [:]
    let sharedConfiguration: TrackerSharedRefreshConfiguration?
    var sharedJournalRecovery: [String: TrackerSharedJournalState] = [:]
    var preparedConnections: [String: ConnectionContext] = [:]
    let now: @Sendable () -> Date

    public init(
        sharedConfiguration: TrackerSharedRefreshConfiguration? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sharedConfiguration = sharedConfiguration
        self.now = now
    }

    var sharedRefresh: TrackerSharedRefreshConfiguration? {
        sharedConfiguration ?? TrackerSharedRefresh.shared.current
    }

    private func sharedRefresh(for store: any TrackerTokenStoring) throws -> TrackerSharedRefreshConfiguration? {
        guard let configuration = sharedRefresh else { return nil }
        if configuration.allowsDiscovery() { return configuration }
        let state = try loadSharedState(store.coordinationID, configuration: configuration)
        if state?.localAuthentication == true { return nil }
        // Previously shared grants still require their single refresh owner.
        // Fresh, opted-out sign-ins neither discover nor publish cloud grants.
        return state?.accepted != nil || state?.pending != nil ? configuration : nil
    }

    public func accessToken(store: any TrackerTokenStoring, auth: any TrackerTokenRefreshing) async throws -> String? {
        try Task.checkCancellation()
        let key = store.coordinationID
        guard erasures[key] == nil else { throw TrackerSharedRefreshError.superseded }
        try recoverLocalAuthentication(store: store)
        if let configuration = try sharedRefresh(for: store) {
            let revision = revisions[key, default: 0]
            while let refresh = refreshes[key] {
                let access: String?
                do {
                    access = try await refresh.task.value
                } catch TrackerSharedRefreshError.refreshInProgress where !refresh.renewsExpiredTokens {
                    try checkSharedRevision(key, revision)
                    continue
                }
                try checkSharedRevision(key, revision)
                if !refresh.resolvesAccessToken { continue }
                if refresh.renewsExpiredTokens { return access }
                // A passive sync can adopt an expired grant but cannot renew it.
                // Re-enter the same owner slot rather than returning that token.
                if let current = store.load() {
                    if !current.isExpired, current.accessToken == access { return access }
                } else if access == nil {
                    return nil
                }
            }
            let refresh = startSharedOperation(key: key, renewsExpiredTokens: true) {
                try await self.sharedAccess(
                    store: store, configuration: configuration, revision: revision,
                    exchange: { try await auth.refresh($0) }
                )
            }
            let access = try await refresh.task.value
            try checkSharedRevision(key, revision)
            return access
        }
        guard let previous = store.load() else { return nil }
        if let pending = pendingWrites[key] {
            if pending.previous == previous {
                try saveLocalRefresh(pending.refreshed, store: store)
                pendingWrites[key] = nil
                return pending.refreshed.accessToken
            }
            pendingWrites[key] = nil
        }
        guard previous.isExpired else { return previous.accessToken }
        if let refresh = refreshes[key] {
            return try await refresh.task.value
        }
        let revision = revisions[key, default: 0]
        let id = UUID()
        let task = Task<String?, Error> {
            defer {
                if refreshes[key]?.id == id { refreshes[key] = nil }
                inFlightOperations[id] = nil
            }
            do {
                let refreshed = try await auth.refresh(previous.refreshToken)
                    .inheritingAccountIdentity(from: previous)
                try Task.checkCancellation()
                guard revisions[key, default: 0] == revision,
                      store.load() == previous else { throw CancellationError() }
                // Keep a failed write in memory: consuming the old refresh token
                // again would lose the only valid replacement.
                pendingWrites[key] = PendingWrite(previous: previous, refreshed: refreshed)
                try saveLocalRefresh(refreshed, store: store)
                pendingWrites[key] = nil
                return refreshed.accessToken
            } catch {
                // iCloud may have delivered another device's successful rotation.
                // Never clear a newer grant or retry against a different account.
                if revisions[key, default: 0] == revision,
                   let current = store.load(), current != previous,
                   current.stableAccountIdentity == previous.stableAccountIdentity,
                   !current.isExpired {
                    return current.accessToken
                }
                throw error
            }
        }
        refreshes[key] = Refresh(id: id, task: task)
        inFlightOperations[id] = (key, task)
        return try await task.value
    }

    public func prepareConnection(store: any TrackerTokenStoring) async throws -> ConnectionContext {
        try Task.checkCancellation()
        let key = store.coordinationID
        guard erasures[key] == nil else { throw TrackerSharedRefreshError.superseded }
        let revision = revisions[key, default: 0]
        guard let configuration = sharedRefresh, configuration.allowsDiscovery() else {
            return ConnectionContext(
                id: UUID(), scope: key, revision: revision, accountID: nil, expectedEpoch: nil
            )
        }
        while let refresh = refreshes[key] {
            // Explicit reconnect must remain possible after an uncertain refresh.
            do { _ = try await refresh.task.value }
            catch { try checkSharedRevision(key, revision) }
            try checkSharedRevision(key, revision)
        }
        let id = UUID()
        preparedConnections[key] = nil
        let refresh = startSharedOperation(key: key, renewsExpiredTokens: false, resolvesAccessToken: false) {
            try await self.prepareSharedConnection(
                store: store, configuration: configuration, revision: revision, id: id
            )
            return store.load()?.accessToken
        }
        _ = try await withTaskCancellationHandler {
            try await refresh.task.value
        } onCancel: {
            refresh.task.cancel()
        }
        try checkSharedRevision(key, revision)
        guard let context = preparedConnections[key], context.id == id else {
            throw TrackerSharedRefreshError.superseded
        }
        return context
    }

    public func save(
        _ tokens: TrackerTokens, store: any TrackerTokenStoring, context: ConnectionContext? = nil
    ) async throws {
        try Task.checkCancellation()
        let key = store.coordinationID
        guard erasures[key] == nil else { throw TrackerSharedRefreshError.superseded }
        if let context {
            guard context.scope == key, context.revision == revisions[key, default: 0] else {
                throw TrackerSharedRefreshError.superseded
            }
            if let configuration = sharedRefresh,
               !configuration.allowsDiscovery() || context.accountID == nil {
                let operations = inFlightOperations.values.filter { $0.key == key }.map(\.task)
                invalidate(key)
                let revision = revisions[key, default: 0]
                for operation in operations { _ = await operation.result }
                try checkSharedRevision(key, revision)
                try saveLocalAuthentication(tokens, store: store, configuration: configuration)
                return
            }
        }
        if let configuration = try sharedRefresh(for: store) {
            guard let context, context.accountID != nil,
                  preparedConnections[key]?.id == context.id else {
                throw TrackerSharedRefreshError.superseded
            }
            invalidate(key)
            let refresh = startSharedOperation(key: key, renewsExpiredTokens: false) {
                try await self.changeSharedConnection(
                    tokens, store: store, configuration: configuration, context: context
                )
                return store.load()?.accessToken
            }
            _ = try await withTaskCancellationHandler {
                try await refresh.task.value
            } onCancel: {
                refresh.task.cancel()
            }
            return
        }
        invalidate(key)
        try store.save(tokens)
    }

    public func disconnect(store: any TrackerTokenStoring) async throws -> TrackerTokens? {
        guard erasures[store.coordinationID] == nil else { throw TrackerSharedRefreshError.superseded }
        let tokens = store.load()
        invalidate(store.coordinationID)
        if let configuration = try sharedRefresh(for: store) {
            let refresh = startSharedOperation(key: store.coordinationID, renewsExpiredTokens: false) {
                try await self.changeSharedConnection(nil, store: store, configuration: configuration)
                return nil
            }
            _ = try await withTaskCancellationHandler {
                try await refresh.task.value
            } onCancel: {
                refresh.task.cancel()
            }
            return tokens
        }
        try retireLocalAuthentication(store: store)
        try store.clear()
        return tokens
    }

    func synchronizeShared(store: any TrackerTokenStoring) async throws {
        guard let configuration = try sharedRefresh(for: store) else { return }
        let key = store.coordinationID
        guard erasures[key] == nil else { throw TrackerSharedRefreshError.superseded }
        let revision = revisions[key, default: 0]
        while let refresh = refreshes[key] {
            _ = try await refresh.task.value
            try checkSharedRevision(key, revision)
            if refresh.resolvesAccessToken { return }
        }
        let refresh = startSharedOperation(key: key, renewsExpiredTokens: false) {
            try await self.sharedAccess(
                store: store, configuration: configuration, revision: revision, exchange: nil
            )
        }
        _ = try await refresh.task.value
    }

    /// Drain single-use exchanges before cloud erasure, then discard local replay
    /// state. A pending connect/successor must not recreate the just-erased grant.
    func beginCloudErasure(stores: [any TrackerTokenStoring]) async throws -> UUID {
        let keys = Set(stores.map(\.coordinationID))
        guard keys.allSatisfy({ erasures[$0] == nil }) else { throw TrackerSharedRefreshError.superseded }
        let owner = UUID()
        let tasks = inFlightOperations.values.filter { keys.contains($0.key) }.map(\.task)
        for key in keys {
            erasures[key] = owner
            invalidate(key)
        }
        do {
            for task in tasks { _ = await task.result }
            try Task.checkCancellation()
            for store in stores {
                try retireSharedStateForErasure(store: store)
                try store.clear()
            }
            return owner
        } catch {
            endCloudErasure(owner: owner)
            throw error
        }
    }

    func endCloudErasure(owner: UUID) {
        erasures = erasures.filter { $0.value != owner }
    }

    private func startSharedOperation(
        key: String,
        renewsExpiredTokens: Bool,
        resolvesAccessToken: Bool = true,
        operation: @escaping @Sendable () async throws -> String?
    ) -> Refresh {
        let id = UUID()
        let task = Task<String?, Error> {
            defer {
                if refreshes[key]?.id == id { refreshes[key] = nil }
                inFlightOperations[id] = nil
            }
            try Task.checkCancellation()
            return try await operation()
        }
        let refresh = Refresh(
            id: id, task: task, renewsExpiredTokens: renewsExpiredTokens,
            resolvesAccessToken: resolvesAccessToken
        )
        refreshes[key] = refresh
        inFlightOperations[id] = (key, task)
        return refresh
    }

    private func invalidate(_ key: String) {
        revisions[key, default: 0] &+= 1
        refreshes.removeValue(forKey: key)?.task.cancel()
        pendingWrites[key] = nil
        preparedConnections[key] = nil
    }
}
