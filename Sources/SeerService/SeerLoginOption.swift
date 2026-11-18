import Foundation

public struct SeerLoginOption: Identifiable {
    public let id: String
    public let name: String
    public let mediaServerType: Int
    public let serverName: String?
    public let serverURL: URL?
    public let authenticate: @MainActor (URL) async throws -> SeerAuthenticatedAccount

    public init(
        id: String, name: String, mediaServerType: Int,
        serverName: String? = nil, serverURL: URL? = nil,
        authenticate: @escaping @MainActor (URL) async throws -> SeerAuthenticatedAccount
    ) {
        self.id = id
        self.name = name
        self.mediaServerType = mediaServerType
        self.serverName = serverName
        self.serverURL = serverURL
        self.authenticate = authenticate
    }
}
