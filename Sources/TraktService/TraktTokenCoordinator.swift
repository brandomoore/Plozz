import CoreModels
import Foundation

/// Single-use refresh tokens need one owner across Settings, realtime playback,
/// watchlist sync and independently constructed durable-outbox services.
actor TraktTokenCoordinator {
    static let shared = TraktTokenCoordinator()

    /// Captured before OAuth starts. A nil epoch means confirmed server absence,
    /// never an unknown baseline that may be filled in after authorization.
    struct ConnectionContext: Sendable {
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
        let previous: TraktTokens
        let refreshed: TraktTokens
    }

    var revisions: [String: UInt64] = [:]
    private(set) var refreshes: [String: Refresh] = [:]
    private var pendingWrites: [String: PendingWrite] = [:]
    let sharedConfiguration: TraktSharedRefreshConfiguration?
    var sharedJournalRecovery: [String: TraktSharedJournalState] = [:]
    var preparedConnections: [String: ConnectionContext] = [:]
    let now: @Sendable () -> Date

    init(
        sharedConfiguration: TraktSharedRefreshConfiguration? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sharedConfiguration = sharedConfiguration
        self.now = now
    }

    var sharedRefresh: TraktSharedRefreshConfiguration? {
        sharedConfiguration ?? TraktSharedRefresh.shared.current
    }

    func accessToken(store: any TraktTokenStoring, auth: TraktAuthService) async throws -> String? {
        try Task.checkCancellation()
        let key = store.coordinationID
        if let configuration = sharedRefresh {
            let revision = revisions[key, default: 0]
            while let refresh = refreshes[key] {
                let access: String?
                do {
                    access = try await refresh.task.value
                } catch TraktSharedRefreshError.refreshInProgress where !refresh.renewsExpiredTokens {
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
                try store.save(pending.refreshed)
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
                try store.save(refreshed)
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
        return try await task.value
    }

    func prepareConnection(store: any TraktTokenStoring) async throws -> ConnectionContext {
        try Task.checkCancellation()
        let key = store.coordinationID
        let revision = revisions[key, default: 0]
        guard let configuration = sharedRefresh else {
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
            throw TraktSharedRefreshError.superseded
        }
        return context
    }

    func save(
        _ tokens: TraktTokens, store: any TraktTokenStoring, context: ConnectionContext? = nil
    ) async throws {
        try Task.checkCancellation()
        let key = store.coordinationID
        if let context {
            guard context.scope == key, context.revision == revisions[key, default: 0] else {
                throw TraktSharedRefreshError.superseded
            }
        }
        if let configuration = sharedRefresh {
            guard let context, context.accountID != nil,
                  preparedConnections[key]?.id == context.id else {
                throw TraktSharedRefreshError.superseded
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

    func disconnect(store: any TraktTokenStoring) async throws -> TraktTokens? {
        let tokens = store.load()
        invalidate(store.coordinationID)
        if let configuration = sharedRefresh {
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
        try store.clear()
        return tokens
    }

    func synchronizeShared(store: any TraktTokenStoring) async throws {
        guard let configuration = sharedRefresh else { return }
        let key = store.coordinationID
        while let refresh = refreshes[key] {
            _ = try await refresh.task.value
            if refresh.resolvesAccessToken { return }
        }
        let revision = revisions[key, default: 0]
        let refresh = startSharedOperation(key: key, renewsExpiredTokens: false) {
            try await self.sharedAccess(
                store: store, configuration: configuration, revision: revision, exchange: nil
            )
        }
        _ = try await refresh.task.value
    }

    private func startSharedOperation(
        key: String,
        renewsExpiredTokens: Bool,
        resolvesAccessToken: Bool = true,
        operation: @escaping @Sendable () async throws -> String?
    ) -> Refresh {
        let id = UUID()
        let task = Task<String?, Error> {
            defer { if refreshes[key]?.id == id { refreshes[key] = nil } }
            try Task.checkCancellation()
            return try await operation()
        }
        let refresh = Refresh(
            id: id, task: task, renewsExpiredTokens: renewsExpiredTokens,
            resolvesAccessToken: resolvesAccessToken
        )
        refreshes[key] = refresh
        return refresh
    }

    private func invalidate(_ key: String) {
        revisions[key, default: 0] &+= 1
        refreshes.removeValue(forKey: key)?.task.cancel()
        pendingWrites[key] = nil
        preparedConnections[key] = nil
    }
}
