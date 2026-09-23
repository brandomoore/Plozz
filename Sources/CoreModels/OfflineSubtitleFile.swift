import Foundation

public struct OfflineSubtitleFile: Codable, Sendable {
    public let fileName: String
    public let language: String?
    public let codec: String
    public let forced: Bool
    public let hearingImpaired: Bool

    public init(fileName: String, language: String?, codec: String, forced: Bool, hearingImpaired: Bool) {
        self.fileName = fileName
        self.language = language
        self.codec = codec
        self.forced = forced
        self.hearingImpaired = hearingImpaired
    }
}
