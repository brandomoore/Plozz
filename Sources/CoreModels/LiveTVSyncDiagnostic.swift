import Foundation

/// A closed vocabulary: never include profile IDs, source names, URLs or error descriptions.
public struct LiveTVSyncDiagnostic: Equatable, Sendable {
    public enum Operation: String, Sendable { case capture, apply }
    public enum Stage: String, Sendable {
        case removedProfiles, prepareJournal, libraryState, identities, guideMappings
        case captureRecords, applyRecords, validateRecords, finish
    }
    public enum Outcome: String, Sendable { case started, succeeded, deferred, failed }
    public struct Failure: Equatable, Sendable {
        public enum Reason: String, Sendable {
            case invalidRecord, unsupportedVersion, tooLarge, wrongProfile, incompleteSnapshot
            case snapshotUnavailable, storage, keychain, serialization
            case journalPreparation, journalChanged, authorizationChanged, library, other
        }
        public let reason: Reason
        public let code: Int?

        public init(reason: Reason, code: Int? = nil) {
            self.reason = reason
            self.code = code
        }
    }

    public static let notification = Notification.Name("com.plozz.liveTV.syncDiagnostic")
    public let operation: Operation
    public let stage: Stage
    public let outcome: Outcome
    public let failure: Failure?

    public init(operation: Operation, stage: Stage, outcome: Outcome, failure: Failure? = nil) {
        self.operation = operation
        self.stage = stage
        self.outcome = outcome
        self.failure = failure
    }

    public func publish() {
        NotificationCenter.default.post(name: Self.notification, object: self)
    }
}
