import Foundation

public struct XMLTVDownloadedDocument: Sendable {
    public let data: Data
    public let expiresAt: Date
    public let permitsPersistence: Bool

    public init(data: Data, expiresAt: Date, permitsPersistence: Bool) {
        self.data = data
        self.expiresAt = expiresAt
        self.permitsPersistence = permitsPersistence
    }
}
