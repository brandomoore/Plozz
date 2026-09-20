import CoreModels

/// Actor-owned checkpoint of the last successful write for one sync channel.
final class CloudSyncPersistenceState {
    private var persistedLedger: SyncLedger?
    private var persistedEngineRevision: UInt64?

    @discardableResult
    func writeIfChanged(
        ledger: SyncLedger,
        engineRevision: UInt64?,
        write: () throws -> Void
    ) rethrows -> Bool {
        if let persistedLedger,
           persistedEngineRevision == engineRevision,
           ledger.hasSamePersistedState(as: persistedLedger) {
            return false
        }
        try write()
        persistedLedger = ledger
        persistedEngineRevision = engineRevision
        return true
    }
}
