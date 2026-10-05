import Foundation
import CoreModels

/// Serializes blocking Keychain work without blocking the caller. The state lock
/// protects admission only; it is never held while reading or writing credentials.
public final class SerializedCredentialPublisher: @unchecked Sendable {
    public enum Operation: String, Sendable {
        case publish, remove, removeAll
    }

    private let queue = DispatchQueue(label: "plozz.portable-credentials", qos: .utility)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var removals: [String: UInt64] = [:]
    private var removalOfAll: UInt64?
    private let store: any SecureStoring
    private let clearStore: @Sendable () throws -> Void
    private let isEnabled: @Sendable () -> Bool
    private let onFailure: @Sendable (Operation, Error) -> Void

    public init(
        store: any SecureStoring,
        clearStore: @escaping @Sendable () throws -> Void,
        isEnabled: @escaping @Sendable () -> Bool,
        onFailure: @escaping @Sendable (Operation, Error) -> Void
    ) {
        self.store = store
        self.clearStore = clearStore
        self.isEnabled = isEnabled
        self.onFailure = onFailure
    }

    public func publish(_ records: @escaping @Sendable () throws -> [String: String]) {
        let revision = lock.withLock {
            generation &+= 1
            return generation
        }
        queue.async { [self] in
            guard mayPublish(revision) else { return }
            do {
                let values = try records()
                for key in values.keys.sorted() {
                    guard mayPublish(revision) else { return }
                    guard mayRead(key), let value = values[key] else { continue }
                    do {
                        let previous = try store.readString(for: key)
                        guard mayPublish(revision) else { return }
                        if previous != value { try store.setString(value, for: key) }
                    } catch {
                        onFailure(.publish, error)
                    }
                }
            } catch {
                onFailure(.publish, error)
            }
        }
    }

    public func cancelPendingPublication() {
        lock.withLock { generation &+= 1 }
    }

    /// A queued deletion also hides the old item from synchronous auto-connect
    /// checks until the deletion is confirmed, including when a prior write stalls.
    public func mayRead(_ key: String) -> Bool {
        lock.withLock { removalOfAll == nil && removals[key] == nil }
    }

    public func removeValue(for key: String) {
        let revision = lock.withLock {
            generation &+= 1
            removals[key] = generation
            return generation
        }
        queue.async { [self] in
            do {
                try store.removeValue(for: key)
                lock.withLock {
                    if removals[key] == revision { removals[key] = nil }
                }
            } catch {
                onFailure(.remove, error)
            }
        }
    }

    public func removeAll(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let revision = lock.withLock {
            generation &+= 1
            removalOfAll = generation
            return generation
        }
        queue.async { [self] in
            do {
                try clearStore()
                lock.withLock {
                    removals = removals.filter { $0.value > revision }
                    if removalOfAll == revision { removalOfAll = nil }
                }
                completion(.success(()))
            } catch {
                onFailure(.removeAll, error)
                completion(.failure(error))
            }
        }
    }

    private func mayPublish(_ revision: UInt64) -> Bool {
        isEnabled() && lock.withLock { generation == revision && removalOfAll == nil }
    }

    func waitForPendingOperations() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
