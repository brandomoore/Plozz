import Foundation

public struct SeerLoginOption: Identifiable {
    public let id: String
    public let name: String
    public let mediaServerType: Int
    public let authenticate: @MainActor (URL) async throws -> SeerAuthenticatedAccount

    public init(
        id: String, name: String, mediaServerType: Int,
        authenticate: @escaping @MainActor (URL) async throws -> SeerAuthenticatedAccount
    ) {
        self.id = id
        self.name = name
        self.mediaServerType = mediaServerType
        self.authenticate = authenticate
    }
}
