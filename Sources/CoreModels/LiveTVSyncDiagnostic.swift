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

/// Failure-only measurements from existing guards; never serialize inputs for diagnostics.
public struct LiveTVSyncLimitDiagnostic: Equatable, Sendable {
    public enum Limit: String, Sendable, CaseIterable {
        case libraryDefinitions, librarySnapshots, libraryItems
        case snapshotItems, snapshotItemBytes, snapshotParts, recordBytes, libraryExportBytes
        case journalFiles, journalRecords, journalRecordBytes, journalBytes, inputRecords, inputBytes, observedStateBytes
        case snapshotBytes, snapshotStoreBytes, snapshotStoreCount
    }

    public static let notification = Notification.Name("com.plozz.liveTV.syncLimitDiagnostic")
    public static let maximumMeasurement = 1_000_000_000_000
    public let limit: Limit
    public let observed: Int
    public let maximum: Int

    public init?(limit: Limit, observed: Int, maximum: Int) {
        guard maximum > 0, observed > maximum, observed <= Self.maximumMeasurement else { return nil }
        self.limit = limit
        self.observed = observed
        self.maximum = maximum
    }

    public static func record(_ limit: Limit, observed: Int, maximum: Int) {
        guard let diagnostic = Self(limit: limit, observed: observed, maximum: maximum) else { return }
        NotificationCenter.default.post(name: notification, object: diagnostic)
    }
}
