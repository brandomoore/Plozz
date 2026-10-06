import CoreSecureStore
import Foundation

/// A server change tag is an opaque compare-and-swap capability, not a clock.
public struct TraktSharedRecord: Sendable {
    public let value: Data
    public let version: Data

    public init(value: Data, version: Data) {
        self.value = value
        self.version = version
    }
}

/// Implementations must use a private, end-to-end encrypted channel. A successful
/// conditional write must be acknowledged by the server before returning.
public protocol TraktSharedRefreshTransport: Sendable {
    func accountID() async throws -> String
    func read(scope: String, accountID: String) async throws -> TraktSharedRecord?
    func readLegacyTokens(scope: String, accountID: String) async throws -> TraktTokens?
    func compareAndSwap(
        scope: String, accountID: String, expected: TraktSharedRecord?, value: Data
    ) async throws -> TraktSharedRecord
}

public extension TraktSharedRefreshTransport {
    func readLegacyTokens(scope: String, accountID: String) async throws -> TraktTokens? { nil }
}

public enum TraktSharedRefreshError: Error, Equatable {
    case conflict
    case unavailable
    case accountChanged
    case invalidRecord
    case missingRecord
    case refreshInProgress
    case outcomeUnknown
    case superseded
    case retryable(retryNotBefore: Date?)

    public var userMessage: LocalizedStringResource {
        switch self {
        case .conflict, .refreshInProgress:
            LocalizedStringResource(
                "trakt.sync.updating",
                defaultValue: "Another device is updating this Trakt connection. Try again shortly.",
                comment: "Trakt shared refresh is owned by another device; retry rather than signing in again."
            )
        case .unavailable:
            LocalizedStringResource(
                "trakt.sync.unavailable",
                defaultValue: "iCloud is unavailable. Your Trakt connection is saved; try again when iCloud is available.",
                comment: "Shared Trakt authorization is retained while iCloud is unavailable."
            )
        case .accountChanged:
            LocalizedStringResource(
                "trakt.sync.accountChanged",
                defaultValue: "The iCloud account changed. The previous account’s Trakt connection was not shared.",
                comment: "Prevents sharing a previous iCloud account's Trakt grant into a different account."
            )
        case .invalidRecord, .missingRecord:
            LocalizedStringResource(
                "trakt.sync.unverified",
                defaultValue: "The shared Trakt connection could not be verified. Try syncing again.",
                comment: "The saved shared Trakt grant could not be verified safely."
            )
        case .outcomeUnknown:
            LocalizedStringResource(
                "trakt.sync.waitingForOwner",
                defaultValue: "The device renewing Trakt has not shared its result yet. Open Plozz on that device and retry. If it cannot recover, reconnect this profile once to restore all devices.",
                comment: "A single-use refresh may have completed on another device. Never replay it; retry recovery or explicitly reconnect the shared profile."
            )
        case .superseded:
            LocalizedStringResource(
                "trakt.sync.changed",
                defaultValue: "This Trakt connection was changed on another device. Try again.",
                comment: "A newer shared Trakt authorization superseded this device's pending change."
            )
        case .retryable:
            LocalizedStringResource(
                "trakt.sync.retry",
                defaultValue: "Trakt could not renew this connection yet. Wait a moment, then retry. You do not need to sign in again.",
                comment: "A refresh was safely deferred or throttled. Retry the existing shared connection, not a new authorization."
            )
        }
    }
}

/// Persisted only in device-local Keychain. Includes the successor BEFORE trying
/// to publish it, so a failed cloud write can resume without another exchange.
public protocol TraktSharedRefreshJournal: Sendable {
    func read(scope: String) throws -> Data?
    func write(_ value: Data, scope: String) throws
}

public struct SecureTraktSharedRefreshJournal: TraktSharedRefreshJournal {
    private let store: any SecureStore

    public init(store: any SecureStore) { self.store = store }

    public func read(scope: String) throws -> Data? {
        guard let raw = try store.readString(for: key(scope)) else { return nil }
        guard let data = Data(base64Encoded: raw) else { throw TraktSharedRefreshError.invalidRecord }
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

public struct TraktSharedRefreshConfiguration: Sendable {
    public let transport: any TraktSharedRefreshTransport
    public let journal: any TraktSharedRefreshJournal
    public let isLocallySignedOut: @Sendable (String) -> Bool

    public init(
        transport: any TraktSharedRefreshTransport,
        journal: any TraktSharedRefreshJournal,
        isLocallySignedOut: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        self.transport = transport
        self.journal = journal
        self.isLocallySignedOut = isLocallySignedOut
    }
}

/// Installed synchronously before constructing the app's Trakt services. Keeping
/// this selection independent of the settings-sync toggle prevents a disabled
/// toggle or cloud outage from silently enabling an unsafe local refresh.
public final class TraktSharedRefresh: @unchecked Sendable {
    public static let shared = TraktSharedRefresh()
    private let lock = NSLock()
    private var configuration: TraktSharedRefreshConfiguration?

    private init() {}

    public func configure(_ configuration: TraktSharedRefreshConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        if self.configuration == nil { self.configuration = configuration }
    }

    public var isConfigured: Bool { current != nil }

    var current: TraktSharedRefreshConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    /// Remote push payloads are hints only. Re-read the current CAS record instead
    /// of letting an old/out-of-order push overwrite a newer local grant.
    public func synchronize(store: any TraktTokenStoring) async throws {
        try await TraktTokenCoordinator.shared.synchronizeShared(store: store.snapshot())
    }
}

struct TraktSharedGrant: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case ready, refreshing, disconnected }
    var format = 1
    var epoch: UUID
    var generation: UInt64
    var phase: Phase
    var claim: UUID?
    var tokens: TraktTokens?

    static func ready(_ tokens: TraktTokens) -> Self {
        .init(epoch: UUID(), generation: 0, phase: .ready, tokens: tokens)
    }

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.format == 1,
              (value.phase == .disconnected ? value.tokens == nil : value.tokens != nil),
              (value.phase == .refreshing) == (value.claim != nil)
        else { throw TraktSharedRefreshError.invalidRecord }
        return value
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

struct TraktSharedJournalState: Codable, Sendable {
    struct Pending: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case claimPrepared, exchangeStarted, successor, connect, disconnect
        }
        var kind: Kind
        var grant: TraktSharedGrant
        var expectedEpoch: UUID?
        var expectedClaim: UUID?
        var needsBaseline = false
        var retryNotBefore: Date?
    }

    var format = 1
    var accountID: String
    var accepted: TraktSharedGrant?
    var pending: Pending?
}
