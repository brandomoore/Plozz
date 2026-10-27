#if canImport(SwiftUI)
import CoreModels
import Foundation
import SwiftUI

public typealias ThemeMusicPreviewResolving = @MainActor () async throws -> ThemeMusic?

/// Settings can audition ambient audio without depending on the Home feature.
@MainActor
public protocol ThemeMusicPreviewControlling: AnyObject {
    var previewOwner: UUID? { get }
    var isBlocked: Bool { get }
    var isAppActive: Bool { get }
    var failure: LocalizedStringResource? { get }
    func updateVolume(_ volume: ThemeMusicVolume)
    func stopPreview(owner: UUID)
    func preview(
        owner: UUID, volume: ThemeMusicVolume,
        resolve: ThemeMusicPreviewResolving,
        authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
    ) async
}

private struct ThemeMusicPreviewControllerKey: EnvironmentKey {
    static let defaultValue: (any ThemeMusicPreviewControlling)? = nil
}

private struct ThemeMusicPreviewResolverKey: EnvironmentKey {
    static let defaultValue: ThemeMusicPreviewResolving = { nil }
}

private struct ThemeMusicAuthenticatedHTTPResolverKey: EnvironmentKey {
    static let defaultValue: (any AuthenticatedHTTPResourceResolving)? = nil
}

public extension EnvironmentValues {
    var themeMusicAuthenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)? {
        get { self[ThemeMusicAuthenticatedHTTPResolverKey.self] }
        set { self[ThemeMusicAuthenticatedHTTPResolverKey.self] = newValue }
    }

    var themeMusicPreviewController: (any ThemeMusicPreviewControlling)? {
        get { self[ThemeMusicPreviewControllerKey.self] }
        set { self[ThemeMusicPreviewControllerKey.self] = newValue }
    }

    var themeMusicPreviewResolver: ThemeMusicPreviewResolving {
        get { self[ThemeMusicPreviewResolverKey.self] }
        set { self[ThemeMusicPreviewResolverKey.self] = newValue }
    }
}
#endif
