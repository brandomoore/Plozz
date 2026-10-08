import Foundation

/// A durable outbox entry committed with the terminal download state.
public struct DownloadNotification: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case completed
        case batchCompleted
        case failed
    }

    public let id: UUID
    public let kind: Kind
    public let identityKey: String
    public let recordCreatedAt: Date
    public let batchID: String?
    public let title: String?

    init(kind: Kind, record: DownloadedMediaRecord) {
        id = UUID()
        self.kind = kind
        identityKey = record.identityKey
        recordCreatedAt = record.createdAt
        batchID = kind == .batchCompleted ? record.batchID : nil
        title = kind == .batchCompleted ? record.batchTitle : record.snapshot.title
    }
}
