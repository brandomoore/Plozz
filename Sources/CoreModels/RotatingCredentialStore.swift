import Foundation

/// Refreshing a login's bearer must not change its authorization identity.
/// Replacing/removing the login fences every in-flight credential rotation.
public protocol RotatingCredentialStoring: Sendable {
    func credential(accountID: String, revision: CredentialRevision) throws -> String
    func rotateCredential(
        accountID: String, revision: CredentialRevision, expected: String, replacement: String
    ) throws
}

/// A provider may keep short-lived, signed delivery grants behind secret-free
/// locators rather than persisting the server's signed media URLs.
public protocol ProviderHTTPResourceResolving: Sendable {
    func resolveHTTPResource(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL
}
