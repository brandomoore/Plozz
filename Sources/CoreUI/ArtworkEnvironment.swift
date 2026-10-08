#if canImport(SwiftUI)
import CoreModels
import SwiftUI

public struct ArtworkPresentationPolicy: Equatable, Sendable {
    public let area: ArtworkArea
    public let settings: ArtworkSettings
    public let providers: MetadataProviderSettings

    public init(
        area: ArtworkArea = .browse,
        settings: ArtworkSettings = .default,
        providers: MetadataProviderSettings = .default
    ) {
        self.area = area
        self.settings = settings
        self.providers = providers
    }

    public var prefersOnlineArtwork: Bool { settings.prefersOnlineArtwork(in: area) }
    public var prefersTextlessArtwork: Bool { settings.prefersTextlessArtwork(in: area) }

    public func references(for item: MediaItem, placement: ArtworkPlacement) -> [ArtworkReference] {
        settings.artworkReferences(for: item, placement: placement, in: area)
    }

    public var metadataSettings: MetadataProviderSettings {
        var value = providers
        value.preferOnlineArtwork = prefersOnlineArtwork
        return value
    }

    public var identity: String {
        metadataSettings.artworkPolicyIdentity
    }

    public func forArea(_ area: ArtworkArea) -> Self {
        Self(area: area, settings: settings, providers: providers)
    }

    public var heroPolicy: Self {
        forArea(area == .recommended || area == .recommendedHero ? .recommendedHero : .home)
    }
}

private struct ArtworkSettingsKey: EnvironmentKey {
    static let defaultValue = ArtworkSettings.default
}

private struct ArtworkAreaKey: EnvironmentKey {
    static let defaultValue: ArtworkArea? = nil
}

private struct ArtworkProvidersKey: EnvironmentKey {
    static let defaultValue = MetadataProviderSettings.default
}

public extension EnvironmentValues {
    var plozzArtworkSettings: ArtworkSettings {
        get { self[ArtworkSettingsKey.self] }
        set { self[ArtworkSettingsKey.self] = newValue }
    }

    var plozzArtworkArea: ArtworkArea? {
        get { self[ArtworkAreaKey.self] }
        set { self[ArtworkAreaKey.self] = newValue }
    }

    var plozzArtworkProviders: MetadataProviderSettings {
        get { self[ArtworkProvidersKey.self] }
        set { self[ArtworkProvidersKey.self] = newValue }
    }

    var plozzArtworkPolicy: ArtworkPresentationPolicy {
        let area: ArtworkArea
        if let explicit = plozzArtworkArea {
            area = explicit
        } else {
            switch plozzCardCaptionView {
            case .home: area = .homeRows
            case .recommended: area = .recommended
            case .search: area = .search
            case .watchlist: area = .watchlist
            case .related, .filmography, .extras: area = .details
            case .episodes: area = .episodes
            case .browse: area = .browse
            case .collections: area = .collections
            case .playlists: area = .playlists
            }
        }
        return ArtworkPresentationPolicy(
            area: area, settings: plozzArtworkSettings, providers: plozzArtworkProviders
        )
    }
}

struct ArtworkPolicyReader<Content: View>: View {
    let policy: ArtworkPresentationPolicy?
    @ViewBuilder var content: (ArtworkPresentationPolicy) -> Content
    @Environment(\.plozzArtworkPolicy) private var inheritedPolicy

    var body: some View { content(policy ?? inheritedPolicy) }
}
#endif
