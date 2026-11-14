import CloudKit

/// Completion events are not acknowledgements. Keep each failure until the
/// corresponding operation succeeds, including across unrelated fetches/sends.
struct CloudSyncFailures {
    struct LocalCaptureFailure: Error {
        let zoneID: CKRecordZone.ID
        let underlying: any Error
    }

    enum Operation: Hashable {
        case fetchDatabase
        case sendChanges
        case fetchZone(CKRecordZone.ID)
        case saveZone(CKRecordZone.ID)
        case deleteZone(CKRecordZone.ID)
        case saveRecord(CKRecord.ID)
        case deleteRecord(CKRecord.ID)
        case captureZone(CKRecordZone.ID)
    }

    private var errors: [Operation: any Error] = [:]

    var fetchError: (any Error)? {
        errors.first {
            switch $0.key {
            case .fetchDatabase, .fetchZone: return true
            default: return false
            }
        }?.value
    }

    var sendError: (any Error)? {
        errors.first {
            switch $0.key {
            case .fetchDatabase, .fetchZone: return false
            default: return true
            }
        }?.value
    }

    var error: (any Error)? { fetchError ?? sendError }

    var canRetryAutomatically: Bool {
        !errors.isEmpty && errors.values.allSatisfy(Self.isRetryable)
    }

    static func isRetryable(_ error: any Error) -> Bool {
        guard let error = error as? CKError else { return false }
        switch error.code {
        case .zoneBusy, .serviceUnavailable, .requestRateLimited, .serverRecordChanged,
             .networkFailure, .networkUnavailable:
            return true
        case .serverRejectedRequest:
            return error.retryAfterSeconds.map { $0.isFinite && $0 >= 0 } == true
        default:
            return false
        }
    }

    mutating func record(_ error: (any Error)?, for operation: Operation) {
        errors[operation] = error
    }

    mutating func resolveRecord(_ id: CKRecord.ID) {
        errors[.saveRecord(id)] = nil
        errors[.deleteRecord(id)] = nil
    }

    mutating func resolveUnneededSaves(isPending: (CKRecord.ID) -> Bool) {
        errors = errors.filter { operation, _ in
            if case .saveRecord(let id) = operation { return isPending(id) }
            return true
        }
    }

    mutating func removeZone(_ id: CKRecordZone.ID) {
        errors = errors.filter { operation, _ in
            switch operation {
            case .fetchZone(let zone), .saveZone(let zone), .deleteZone(let zone):
                return zone != id
            case .saveRecord(let record), .deleteRecord(let record):
                return record.zoneID != id
            case .fetchDatabase, .sendChanges, .captureZone:
                return true
            }
        }
    }

    func phase(hasPendingChanges: Bool) -> CloudSyncStatus.Phase {
        if error != nil { return .error }
        return hasPendingChanges ? .syncing : .idle
    }
}
