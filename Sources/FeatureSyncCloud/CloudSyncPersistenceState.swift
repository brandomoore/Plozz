import CoreModels

/// Actor-owned checkpoint of the last successful write for one sync channel.
final class CloudSyncPersistenceState {
    private var persistedLedger: SyncLedger?
    private var persistedEngineRevision: UInt64?
    private var persistedAuthority: String?

    @discardableResult
    func writeIfChanged(
        ledger: SyncLedger,
        engineRevision: UInt64?,
        authority: String? = nil,
        write: () throws -> Void
    ) rethrows -> Bool {
        if let persistedLedger,
           persistedEngineRevision == engineRevision,
           persistedAuthority == authority,
           ledger.hasSamePersistedState(as: persistedLedger) {
            return false
        }
        try write()
        persistedLedger = ledger
        persistedEngineRevision = engineRevision
        persistedAuthority = authority
        return true
    }
}
