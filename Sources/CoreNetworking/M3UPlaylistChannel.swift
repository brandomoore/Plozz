import Foundation

public struct M3UPlaylistChannel: Codable, Sendable {
    public let id: String
    public let number: Int
    public let name: String
    public let category: String
    public let symbol: String
    public let accent: Int
    public let tagline: String
    public let logoURL: URL?
    public let streamURL: URL?
    public let logoNeedsDarkBackground: Bool
    public let guideID: String?
    public let guideName: String?
    public let httpHeaders: [String: String]
    public let language: String?
    public let country: String?
    public let groups: [String]
}
