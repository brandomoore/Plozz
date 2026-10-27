import CoreModels
import Foundation

public enum HeroArtworkStyle: Sendable, Equatable {
    case compactPortrait
    case landscape
}

public enum HeroPresentationSurface: Sendable, Equatable {
    case home
    case detail
}

/// Platform-neutral hero content and artwork ordering. Touch and focus surfaces
/// retain their own geometry and controls while sharing the same media policy.
public struct HeroPresentation: Sendable, Equatable {
    public let itemID: String
    public let kind: MediaItemKind
    public let title: String   // l10n:content — media title from the server
    public let artworkReferences: [ArtworkReference]
    private let libraryArtworkReferences: [ArtworkReference]
    private let recommendedArtworkReferences: [ArtworkReference]
    private let providerHomeArtworkReference: ArtworkReference?
    public let logoReferences: [ArtworkReference]
    public let metadataComponents: [String]
    public let metadataText: String?
    public let overview: String?
    public let tagline: String?
    public let certification: String?
    public let genres: [String]
    public let ratingBadge: MediaBadge?
    public let technicalBadges: [MediaBadge]
    public let ratings: [ExternalRating]
    public let familyGuidanceAge: Double?
    public let starringNames: [String]
    public let directorNames: [String]
    public let studios: [String]
    public let isAnime: Bool
    public let sourceMaterial: String?
    public let isResumable: Bool

    public init(
        item: MediaItem,
        artworkStyle: HeroArtworkStyle,
        surface: HeroPresentationSurface
    ) {
        itemID = item.id
        kind = item.kind
        title = Self.normalizedTitle(for: item)
        let logos = item.artworkReferences(for: .logo)
        artworkReferences = Self.artworkReferences(
            for: item,
            style: artworkStyle,
            surface: surface
        )
        libraryArtworkReferences = Self.artworkReferences(
            for: item, style: artworkStyle, surface: surface,
            preferringLibrarySelection: true
        )
        recommendedArtworkReferences = Self.artworkReferences(
            for: item, style: artworkStyle, surface: surface,
            settings: .default
        )
        providerHomeArtworkReference = item.artworkReferences(for: .homeHero).first
        logoReferences = logos
        metadataComponents = item.metadataComponents()
        metadataText = metadataComponents.isEmpty
            ? nil
            : metadataComponents.joined(separator: "  ·  ")
        if surface == .home, item.kind == .episode {
            let synopsis = item.seriesSynopsis.flatMap { $0.matches(item) ? $0 : nil }
            overview = Self.nonempty(synopsis?.overview)
            tagline = Self.nonempty(synopsis?.tagline)
        } else {
            overview = Self.nonempty(item.overview)
            tagline = item.tagline
        }
        certification = Self.nonempty(item.officialRating)
        genres = Array(item.genres.prefix(4))
        ratingBadge = item.ratingBadge
        technicalBadges = item.technicalBadges
        ratings = item.ratings
        familyGuidanceAge = item.familyGuidance?.recommendedAge
        starringNames = item.cast.prefix(3).map(\.name)
        directorNames = item.people
            .filter { $0.kind?.lowercased() == "director" }
            .prefix(2)
            .map(\.name)
        studios = Array(item.studios.prefix(3))
        // Credit classification is intentionally stricter than artwork routing.
        // A fuzzy tag/provider-key match is useful for trying anime artwork APIs,
        // but must never turn a live-action movie's "Starring" into "Studio".
        let animeIDCount = [
            item.providerID(.aniList),
            item.providerID(.myAnimeList),
            item.providerID(.aniDB)
        ].compactMap { $0 }.count
        let hasAnimeGenre = item.genres.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare("Anime") == .orderedSame
            }
        switch item.kind {
        case .movie, .video:
            isAnime = hasAnimeGenre || animeIDCount >= 2
        default:
            isAnime = hasAnimeGenre || animeIDCount >= 1
        }
        sourceMaterial = Self.sourceMaterial(from: item.tags)
        isResumable = (item.resumePosition ?? 0) > 1
    }

    public static func normalizedTitle(for item: MediaItem) -> String {
        if item.kind == .episode, let parent = nonempty(item.parentTitle) {
            return parent
        }

        return nonempty(item.title) ?? item.title
    }

    public func artworkReferences(preferringLibrarySelection: Bool) -> [ArtworkReference] {
        preferringLibrarySelection ? libraryArtworkReferences : artworkReferences
    }

    public func artworkReferences(preference: ArtworkPreference) -> [ArtworkReference] {
        switch preference {
        case .recommended: recommendedArtworkReferences
        case .library: libraryArtworkReferences
        case .online: artworkReferences
        }
    }

    public func artworkReferences(settings: ArtworkSettings, in area: ArtworkArea) -> [ArtworkReference] {
        let preference = settings.preference(in: area)
        guard preference == .recommended, area == .details,
              settings.prefersOnlineArtwork(in: .home), let home = providerHomeArtworkReference else {
            return artworkReferences(preference: preference)
        }
        return artworkReferences.filter { $0 != home } + artworkReferences.filter { $0 == home }
    }

    /// Library artwork has no reliable text-presence metadata. Prefer a backdrop
    /// even before a logo arrives; portrait heroes resolve clean online portraits
    /// separately, without changing ordinary poster selection.
    public static func artworkReferences(
        for item: MediaItem,
        style: HeroArtworkStyle,
        surface: HeroPresentationSurface,
        preferringLibrarySelection: Bool = false,
        settings: ArtworkSettings? = nil
    ) -> [ArtworkReference] {
        let landscapePlacement: ArtworkPlacement = surface == .home
            ? .homeHero
            : .detailBackdrop
        let placements: [ArtworkPlacement] = [landscapePlacement, .poster]
        var seen = Set<ArtworkReference>()
        return placements
            .flatMap {
                settings?.artworkReferences(for: item, placement: $0, in: surface == .home ? .home : .details)
                    ?? item.artworkReferences(for: $0, preferringLibrarySelection: preferringLibrarySelection)
            }
            .filter { seen.insert($0).inserted }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func sourceMaterial(from tags: [String]) -> String? {   // l10n:content — source-material tag from the server
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()
            for prefix in ["based on:", "source material:"] {
                guard lowered.hasPrefix(prefix) else { continue }
                let value = trimmed.dropFirst(prefix.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }
}
