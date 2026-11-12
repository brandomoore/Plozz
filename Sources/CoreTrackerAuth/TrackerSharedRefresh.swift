import CoreSecureStore
import Foundation

/// A server change tag is an opaque compare-and-swap capability, not a clock.
public struct TrackerSharedRecord: Sendable {
    public let value: Data
    public let version: Data

    public init(value: Data, version: Data) {
        self.value = value
        self.version = version
    }
}

/// Implementations must use a private, end-to-end encrypted channel. A successful
/// conditional write must be acknowledged by the server before returning.
public protocol TrackerSharedRefreshTransport: Sendable {
    func accountID() async throws -> String
    func read(scope: String, accountID: String) async throws -> TrackerSharedRecord?
    func readLegacyTokens(scope: String, accountID: String) async throws -> TrackerTokens?
    func compareAndSwap(
        scope: String, accountID: String, expected: TrackerSharedRecord?, value: Data
    ) async throws -> TrackerSharedRecord
}

public extension TrackerSharedRefreshTransport {
    func readLegacyTokens(scope: String, accountID: String) async throws -> TrackerTokens? { nil }
}

public enum TrackerSharedRefreshError: Error, Equatable {
    case conflict
    case unavailable
    case cloudFailure(code: Int)
    case accountChanged
    case invalidRecord
    case missingRecord
    case refreshInProgress
    case outcomeUnknown
    case superseded
    case retryable(retryNotBefore: Date?)


}

/// Persisted only in device-local Keychain. Includes the successor BEFORE trying
/// to publish it, so a failed cloud write can resume without another exchange.
public protocol TrackerSharedRefreshJournal: Sendable {
    func read(scope: String) throws -> Data?
    func write(_ value: Data, scope: String) throws
}

public struct SecureTrackerSharedRefreshJournal: TrackerSharedRefreshJournal {
    private let store: any SecureStore

    public init(store: any SecureStore) { self.store = store }

    public func read(scope: String) throws -> Data? {
        guard let raw = try store.readString(for: key(scope)) else { return nil }
        guard let data = Data(base64Encoded: raw) else { throw TrackerSharedRefreshError.invalidRecord }
        return data
    }

    public func write(_ value: Data, scope: String) throws {
        try store.setString(value.base64EncodedString(), for: key(scope))
    }

    private func key(_ scope: String) -> String {
        // Scope contains service/profile identifiers, never credential material.
        Data(scope.utf8).base64EncodedString()
    }
}

public struct TrackerSharedRefreshConfiguration: Sendable {
    public let transport: any TrackerSharedRefreshTransport
    public let journal: any TrackerSharedRefreshJournal
    public let isLocallySignedOut: @Sendable (String) -> Bool
    public let allowsDiscovery: @Sendable () -> Bool

    public init(
        transport: any TrackerSharedRefreshTransport,
        journal: any TrackerSharedRefreshJournal,
        isLocallySignedOut: @escaping @Sendable (String) -> Bool = { _ in false },
        allowsDiscovery: @escaping @Sendable () -> Bool = { true }
    ) {
        self.transport = transport
        self.journal = journal
        self.isLocallySignedOut = isLocallySignedOut
        self.allowsDiscovery = allowsDiscovery
    }
}

/// Installed synchronously before constructing the app's Trakt services. Keeping
/// this selection independent of the settings-sync toggle prevents a disabled
/// toggle or cloud outage from silently enabling an unsafe local refresh.
public final class TrackerSharedRefresh: @unchecked Sendable {
    public static let shared = TrackerSharedRefresh()
    private let lock = NSLock()
    private var configuration: TrackerSharedRefreshConfiguration?

    private init() {}

    public func configure(_ configuration: TrackerSharedRefreshConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        if self.configuration == nil { self.configuration = configuration }
    }

    public var isConfigured: Bool { current != nil }

    var current: TrackerSharedRefreshConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    /// Remote push payloads are hints only. Re-read the current CAS record instead
    /// of letting an old/out-of-order push overwrite a newer local grant.
    public func synchronize(store: any TrackerTokenStoring) async throws {
        try await TrackerTokenCoordinator.shared.synchronizeShared(store: store.snapshot())
    }

    public func withCloudErasure<Result: Sendable>(
        stores: [any TrackerTokenStoring],
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let coordinator = TrackerTokenCoordinator.shared
        let owner = try await coordinator.beginCloudErasure(stores: stores)
        do {
            let result = try await operation()
            await coordinator.endCloudErasure(owner: owner)
            return result
        } catch {
            await coordinator.endCloudErasure(owner: owner)
            throw error
        }
    }
}

struct TrackerSharedGrant: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case ready, refreshing, disconnected }
    var format = 1
    var epoch: UUID
    var generation: UInt64
    var phase: Phase
    var claim: UUID?
    var tokens: TrackerTokens?

    static func ready(_ tokens: TrackerTokens) -> Self {
        .init(epoch: UUID(), generation: 0, phase: .ready, tokens: tokens)
    }

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.format == 1,
              (value.phase == .disconnected ? value.tokens == nil : value.tokens != nil),
              (value.phase == .refreshing) == (value.claim != nil)
        else { throw TrackerSharedRefreshError.invalidRecord }
        return value
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

struct TrackerSharedJournalState: Codable, Sendable {
    struct Pending: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case claimPrepared, exchangeStarted, successor, connect, disconnect
        }
        var kind: Kind
        var grant: TrackerSharedGrant
        var expectedEpoch: UUID?
        var expectedClaim: UUID?
        var needsBaseline = false
        var retryNotBefore: Date?
    }

    var format = 1
    var accountID: String
    var accepted: TrackerSharedGrant?
    var pending: Pending?
    var localAuthentication: Bool?
}
