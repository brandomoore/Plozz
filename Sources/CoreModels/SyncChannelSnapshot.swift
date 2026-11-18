import Foundation

public struct SyncChannelSnapshot: Sendable {
    public let sequence: UInt64
    public let authority: String
    public let cloudAccountID: String?
    public let records: [SyncRecordID: Data]
    public let deleted: Set<SyncRecordID>
    public let localCaptureDigests: [SyncRecordID: Data]
    public let changes: SyncLocalChanges

    public init(
        sequence: UInt64, authority: String, records: [SyncRecordID: Data],
        deleted: Set<SyncRecordID> = [], localCaptureDigests: [SyncRecordID: Data] = [:],
        changes: SyncLocalChanges = [:], cloudAccountID: String? = nil
    ) {
        self.sequence = sequence
        self.authority = authority
        self.cloudAccountID = cloudAccountID
        self.records = records
        self.deleted = deleted
        self.localCaptureDigests = localCaptureDigests
        self.changes = changes
    }
}
