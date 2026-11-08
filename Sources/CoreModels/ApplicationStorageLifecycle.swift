import Foundation

public protocol ApplicationStorageParticipant: AnyObject, Sendable {
    func prepareForSuspension() async
}

/// Process-wide admission for actor-confined stores. Register before opening a
/// connection, and check admission before each new operation or lazy reopen.
public final class ApplicationStorageLifecycle: @unchecked Sendable {
    public static let shared = ApplicationStorageLifecycle()

    private struct Participant {
        weak var value: (any ApplicationStorageParticipant)?
    }

    private let lock = NSLock()
    private var active = true
    private var revision: UInt64?
    private var participants: [ObjectIdentifier: Participant] = [:]

    public init() {}

    public var isActive: Bool { lock.withLock { active } }

    public func checkAccess() throws {
        guard isActive else { throw CancellationError() }
    }

    public func register(_ participant: any ApplicationStorageParticipant) {
        lock.withLock {
            participants = participants.filter { $0.value.value != nil }
            participants[ObjectIdentifier(participant)] = Participant(value: participant)
        }
    }

    public func setApplicationActive(_ active: Bool, revision: UInt64) async {
        let stores = transition(active: active, revision: revision)
        await withTaskGroup(of: Void.self) { group in
            for store in stores {
                group.addTask { await store.prepareForSuspension() }
            }
        }
    }

    private func transition(active: Bool, revision: UInt64) -> [any ApplicationStorageParticipant] {
        lock.withLock {
            if let current = self.revision, revision < current { return [] }
            if self.revision == revision, active != self.active { return [] }
            self.revision = revision
            self.active = active
            return active ? [] : participants.values.compactMap(\.value)
        }
    }
}
