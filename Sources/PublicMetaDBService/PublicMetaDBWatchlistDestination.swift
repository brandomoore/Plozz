import CoreModels
import CoreNetworking
import CoreSecureStore
import Foundation

/// A deliberately selected list, never an implicit consequence of connecting a key.
public actor PublicMetaDBWatchlistDestination: WatchlistBatchApplying {
    public nonisolated let id = WatchlistDestinationID(rawValue: "publicmetadb")!
    public nonisolated var reconciliationScope: String { access.current?.scope ?? "publicmetadb#disabled" }
    public nonisolated let writePolicyVersion = 1
    public nonisolated let maximumBatchSize = 1
    public nonisolated var capabilities: WatchlistDestinationCapabilities {
        let enabled = access.current != nil
        return .init(
            readable: enabled, writable: enabled, removable: enabled,
            bindingRequirement: .globalExternalIdentity, globalIdentityNamespaces: [.tmdb]
        )
    }

    private nonisolated let access = AccessBox()
    private nonisolated let receiptStore: DurableLocalStateStore?
    private let operations = ConcurrencyLimiter(limit: 1)

    public init(receiptStore: DurableLocalStateStore? = nil) { self.receiptStore = receiptStore }

    nonisolated func disable() { access.replace(nil) }

    nonisolated func configure(
        credentials: PublicMetaDBCredentials, selection: PublicMetaDBWatchlistSelection,
        http: (any HTTPClient)?, connectionIsCurrent: @Sendable @escaping () -> Bool
    ) throws {
        disable()
        guard selection.connectionID == credentials.connectionID else { throw PublicMetaDB.Failure.connectionChanged }
        _ = try PublicMetaDBClient.component(selection.listID)
        let epoch = PublicMetaDBConnectionEpoch()
        let client = try PublicMetaDBClient(
            key: credentials.key, http: http,
            isCurrent: { epoch.isCurrent && connectionIsCurrent() }
        )
        let receipts = try PublicMetaDBWatchlistReceipts(
            store: receiptStore ?? DurableLocalStateStoreFactory.userIndependent(),
            selectionID: selection.id
        )
        access.replace(Access(
            client: client, listID: selection.listID, isPublic: selection.isPublic,
            scope: "publicmetadb#\(credentials.connectionID)#\(selection.id)", epoch: epoch, receipts: receipts
        ))
    }

    public func fetchEntries() async throws -> [WatchlistDestinationEntry] {
        guard let captured = access.current else { return [] }
        return try await operations.run { [self] in
            try await mapped { try await self.readEntries(captured) }
        }
    }

    public func resolve(_ target: WatchlistMutationTarget) async throws -> WatchlistDestinationBinding? {
        guard let captured = access.current, capabilities.accepts(target.kind) else { return nil }
        let ids = target.externalIDs.filter { $0.namespace == .tmdb }
        guard !ids.isEmpty else { return nil }
        guard ids.count == 1, let tmdbID = Int(ids[0].value), tmdbID > 0 else {
            throw WatchlistDestinationError.unsupportedIdentity
        }
        return try binding(.init(tmdbID: tmdbID, mediaType: target.kind == .movie ? .movie : .tv), access: captured)
    }

    public func apply(_ desiredState: WatchlistDesiredState, to binding: WatchlistDestinationBinding) async throws {
        try await apply(desiredState, to: binding, expectedReconciliationScope: reconciliationScope)
    }

    public func apply(
        _ desiredState: WatchlistDesiredState, to binding: WatchlistDestinationBinding,
        expectedReconciliationScope: String
    ) async throws {
        let results = try await apply(
            desiredState, to: [binding], idempotencyKey: UUID().uuidString,
            expectedReconciliationScope: expectedReconciliationScope
        )
        try results[0].get()
    }

    public func apply(
        _ desiredState: WatchlistDesiredState, to bindings: [WatchlistDestinationBinding],
        idempotencyKey: String, expectedReconciliationScope: String
    ) async throws -> [Result<Void, WatchlistDestinationError>] {
        guard bindings.count == 1, !idempotencyKey.isEmpty else { throw WatchlistDestinationError.permanent }
        guard let captured = access.current, expectedReconciliationScope == captured.scope else {
            throw WatchlistDestinationError.authenticationRequired
        }
        let content = try content(from: bindings[0], access: captured)
        do {
            try await operations.run { [self] in
                try await mapped {
                    try await self.write(desiredState, content: content, access: captured, deliveryID: idempotencyKey)
                }
            }
            return [.success(())]
        } catch let error as WatchlistDestinationError {
            return [.failure(error)]
        }
    }

    private struct Binding: Codable {
        let scope: String
        let content: PublicMetaDB.Content
    }

    private func binding(_ content: PublicMetaDB.Content, access: Access) throws -> WatchlistDestinationBinding {
        let bytes = try PublicMetaDBClient.encode(Binding(scope: access.scope, content: content))
        guard let binding = WatchlistDestinationBinding(destinationID: id, opaqueValue: bytes.base64EncodedString()) else {
            throw WatchlistDestinationError.permanent
        }
        return binding
    }

    private func content(from binding: WatchlistDestinationBinding, access: Access) throws -> PublicMetaDB.Content {
        guard binding.destinationID == id else { throw WatchlistDestinationError.permanent }
        let values = try binding.opaqueValues.map { value in
            guard let bytes = Data(base64Encoded: value) else { throw WatchlistDestinationError.permanent }
            let value = try PublicMetaDBClient.decoder().decode(Binding.self, from: bytes)
            guard value.scope == access.scope else { throw WatchlistDestinationError.authenticationRequired }
            return value.content
        }
        guard Set(values).count == 1, let content = values.first,
              content.season == nil, content.episode == nil else { throw WatchlistDestinationError.unsupportedIdentity }
        return content
    }

    private func readEntries(_ access: Access) async throws -> [WatchlistDestinationEntry] {
        try await records(access).map { record in
            let content = record.value
            guard let externalID = WatchlistExternalID(namespace: .tmdb, value: String(content.tmdbID)),
                  let entry = WatchlistDestinationEntry(
                    kind: content.mediaType == .movie ? .movie : .series,
                    externalIDs: [externalID], binding: try binding(content, access: access)
                  ) else { throw WatchlistDestinationError.unsupportedIdentity }
            return entry
        }
    }

    private func records(_ access: Access) async throws -> [PublicMetaDB.Record<PublicMetaDB.Content>] {
        let records = try await access.client.completePages(maximumPages: 100) {
            let response = try await access.client.listItems(id: access.listID, page: $0, perPage: 500)
            guard response.list.isPublic == access.isPublic else { throw PublicMetaDB.Failure.blocked }
            return response.page
        }
        guard records.allSatisfy({ $0.value.season == nil && $0.value.episode == nil }),
              Set(records.map(\.value)).count == records.count else { throw PublicMetaDB.Failure.incompleteResponse }
        return records
    }

    private func write(
        _ desiredState: WatchlistDesiredState, content: PublicMetaDB.Content, access: Access, deliveryID: String
    ) async throws {
        let before = try await records(access)
        let matching = before.filter { $0.value == content }
        try access.receipts.observe(content: content, isPresent: !matching.isEmpty)
        if (desiredState == .present) == !matching.isEmpty {
            try access.receipts.confirm(deliveryID: deliveryID, content: content)
            return
        }
        do { try access.receipts.begin(deliveryID: deliveryID, content: content, desiredState: desiredState) }
        catch {
            PlozzLog.networking.error("PublicMetaDB watchlist delivery evidence blocks automatic replay")
            throw WatchlistDestinationError.permanent
        }
        do {
            switch desiredState {
            case .present: _ = try await access.client.addListItem(content, listID: access.listID)
            case .absent:
                for record in matching {
                    try await access.client.removeListItem(listID: access.listID, itemID: record.id)
                }
            }
        } catch PublicMetaDB.Failure.uncertainWrite {
            // Observe once; never turn a missing POST reply into a blind duplicate add.
            return try await confirm(desiredState, content: content, access: access, deliveryID: deliveryID)
        } catch {
            // The client reserves uncertainWrite for ambiguous dispatches; these are definite refusals.
            try access.receipts.allowRetry(deliveryID: deliveryID, content: content)
            throw error
        }
        try await confirm(desiredState, content: content, access: access, deliveryID: deliveryID)
    }

    private func confirm(
        _ desiredState: WatchlistDesiredState, content: PublicMetaDB.Content, access: Access, deliveryID: String
    ) async throws {
        do {
            let observed = try await records(access)
            guard (desiredState == .present) == observed.contains(where: { $0.value == content }) else {
                throw PublicMetaDB.Failure.uncertainWrite
            }
            try access.receipts.confirm(deliveryID: deliveryID, content: content)
        } catch {
            // Even a failed verification GET must not schedule another unconfirmed POST.
            PlozzLog.networking.error("PublicMetaDB watchlist change is unconfirmed; automatic replay stopped")
            throw WatchlistDestinationError.permanent
        }
    }
}

private struct Access: Sendable {
    let client: PublicMetaDBClient
    let listID: String
    let isPublic: Bool
    let scope: String
    let epoch: PublicMetaDBConnectionEpoch
    let receipts: PublicMetaDBWatchlistReceipts
}

private final class AccessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Access?
    var current: Access? { lock.withLock { value } }
    func replace(_ replacement: Access?) {
        lock.withLock {
            value?.epoch.invalidate()
            value = replacement
        }
    }
}

private func mapped<Value: Sendable>(_ operation: () async throws -> Value) async throws -> Value {
    do { return try await operation() }
    catch let error as WatchlistDestinationError { throw error }
    catch is CancellationError { throw CancellationError() }
    catch AppError.rateLimited(let retryAfter) { throw WatchlistDestinationError.rateLimited(retryAfter: retryAfter) }
    catch let failure as PublicMetaDB.Failure {
        switch failure {
        case .invalidKey, .disconnected, .connectionChanged: throw WatchlistDestinationError.authenticationRequired
        case .blocked, .invalidInput, .rejected, .uncertainWrite: throw WatchlistDestinationError.permanent
        case .incompleteResponse, .responseTooLarge: throw WatchlistDestinationError.transient
        }
    } catch {
        throw WatchlistDestinationError.transient
    }
}
