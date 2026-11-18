import Foundation

/// Persistable artwork identity; authentication happens only at the download boundary.
public struct AuthenticatedArtworkReference: Sendable, Equatable {
    public static let scheme = "plozz-artwork"
    public let accountID: String
    public let credentialRevision: CredentialRevision
    public let resourceID: String
    public let size: Int?

    public init(accountID: String, credentialRevision: CredentialRevision, resourceID: String, size: Int?) {
        self.accountID = accountID
        self.credentialRevision = credentialRevision
        self.resourceID = resourceID
        self.size = size
    }

    public var url: URL? {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "cover"
        parts.queryItems = [
            .init(name: "account", value: accountID),
            .init(name: "revision", value: credentialRevision.rawValue.uuidString),
            .init(name: "id", value: resourceID),
            .init(name: "size", value: size.map(String.init))
        ]
        return parts.url
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "cover",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ key: String) -> String? { parts.queryItems?.first { $0.name == key }?.value }
        guard let account = value("account"), !account.isEmpty,
              let revision = value("revision").flatMap(UUID.init(uuidString:)),
              let id = value("id"), !id.isEmpty else { return nil }
        self.init(accountID: account, credentialRevision: .init(rawValue: revision),
                  resourceID: id, size: value("size").flatMap(Int.init))
    }
}

public protocol AuthenticatedArtworkProviding: Sendable {
    func artworkData(for reference: AuthenticatedArtworkReference) async throws -> Data
}
