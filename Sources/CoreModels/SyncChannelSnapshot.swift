import Foundation

public struct SyncChannelSnapshot: Sendable {
    public let sequence: UInt64
    public let authority: String
    public let records: [SyncRecordID: Data]
    public let deleted: Set<SyncRecordID>
    public let localCaptureDigests: [SyncRecordID: Data]

    public init(
        sequence: UInt64, authority: String, records: [SyncRecordID: Data],
        deleted: Set<SyncRecordID> = [], localCaptureDigests: [SyncRecordID: Data] = [:]
    ) {
        self.sequence = sequence
        self.authority = authority
        self.records = records
        self.deleted = deleted
        self.localCaptureDigests = localCaptureDigests
    }
}
