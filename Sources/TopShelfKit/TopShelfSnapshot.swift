import Foundation

/// A lightweight, `Codable` snapshot of the rows Plozz wants to surface in the
/// tvOS Top Shelf. The main app writes this into the shared App Group
/// container; the Top Shelf extension (a separate process) reads it back.
///
/// The snapshot, store and native content builder compile into both the app
/// package and extension without the provider or app UI stack. The app exports
/// policy-resolved artwork so the extension needs no provider credentials.
public struct TopShelfSnapshot: Codable, Equatable, Sendable {
    public enum MediaOption: String, Codable, Equatable, Sendable {
        case hd, ultraHD, hdr, dolbyVision, dolbyAtmos, closedCaptions, sdh
    }

    public struct NamedAttribute: Codable, Equatable, Sendable {
        public var name: String  // l10n:content — localized by the app before crossing the process boundary
        public var values: [String]

        public init(name: String, values: [String]) {  // l10n:content — already-resolved label
            self.name = name
            self.values = values
        }
    }

    /// When the snapshot was produced. Used purely for debugging/freshness.
    public var generatedAt: Date
    public var usesFullScreen: Bool
    /// Opaque authorization for this Apple TV user's selected viewer. Legacy snapshots
    /// have no authorization and must not be presented by the extension.
    public internal(set) var authorizationID: UUID?

    /// Ordered feeds, rendered as separate poster rows or one full-screen carousel.
    public var sections: [Section]

    public struct Section: Codable, Equatable, Identifiable, Sendable {
        /// Stable identifier for the section (e.g. "continue", "latest").
        public var id: String
        /// User-facing carousel title (e.g. "Continue Watching").
        public var title: String  // l10n:content — already-resolved section title text; must cross the App Group process boundary as plain text (see TopShelfPublisher.resolved)
        public var items: [Item]

        public init(id: String, title: String, items: [Item]) {  // l10n:content — see `title` above
            self.id = id
            self.title = title
            self.items = items
        }
    }

    public struct Item: Codable, Equatable, Identifiable, Sendable {
        /// The owning server's local id for the title.
        ///
        /// **Not unique on its own.** A Plex `ratingKey` is a small per-server
        /// integer, so two accounts routinely hand back the same value for entirely
        /// different titles — which is why ``shelfIdentifier`` scopes it by account
        /// before tvOS or a deep link ever sees it.
        public var id: String
        /// The account this copy came from. Optional so a snapshot written by an
        /// older build still decodes; such an entry keeps today's unscoped behavior.
        public var accountID: String?
        public var title: String  // l10n:content — server-supplied media title
        public var subtitle: String?  // l10n:content — server-supplied media subtitle (e.g. episode label)
        /// Artwork in the selected layout: 2:3 poster or 16:9 full-screen background.
        /// The app exports policy-resolved images into the shared App Group.
        /// Posters may include a composited resume bar; backdrops never do.
        public var imageURL: URL?
        /// Fraction watched (0…1), recorded for reference. The bar itself is
        /// burned into poster artwork. Full-screen backgrounds omit the bar.
        public var playbackProgress: Double?
        public var summary: String?  // l10n:content — spoiler-filtered server synopsis
        public var genre: String?  // l10n:content — server-supplied genre
        public var duration: TimeInterval?
        public var releaseDate: Date?
        public var mediaOptions: [MediaOption]?
        public var namedAttributes: [NamedAttribute]?

        /// Collision-free identity for the shelf card and its deep link.
        public var shelfIdentifier: String {
            guard let accountID, !accountID.isEmpty else { return id }
            return "\(accountID):\(id)"
        }

        public init(
            id: String,
            accountID: String? = nil,
            title: String,  // l10n:content — server-supplied media title
            subtitle: String? = nil,  // l10n:content — server-supplied media subtitle
            imageURL: URL? = nil,
            playbackProgress: Double? = nil,
            summary: String? = nil,  // l10n:content — spoiler-filtered server synopsis
            genre: String? = nil,  // l10n:content — server-supplied genre
            duration: TimeInterval? = nil,
            releaseDate: Date? = nil,
            mediaOptions: [MediaOption]? = nil,
            namedAttributes: [NamedAttribute]? = nil
        ) {
            self.id = id
            self.accountID = accountID
            self.title = title
            self.subtitle = subtitle
            self.imageURL = imageURL
            self.playbackProgress = playbackProgress
            self.summary = summary
            self.genre = genre
            self.duration = duration
            self.releaseDate = releaseDate
            self.mediaOptions = mediaOptions
            self.namedAttributes = namedAttributes
        }
    }

    public init(generatedAt: Date = Date(), usesFullScreen: Bool = false, sections: [Section]) {
        self.generatedAt = generatedAt
        self.usesFullScreen = usesFullScreen
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt, usesFullScreen, authorizationID, sections
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        usesFullScreen = try values.decodeIfPresent(Bool.self, forKey: .usesFullScreen) ?? false
        authorizationID = try values.decodeIfPresent(UUID.self, forKey: .authorizationID)
        sections = try values.decode([Section].self, forKey: .sections)
    }
}
