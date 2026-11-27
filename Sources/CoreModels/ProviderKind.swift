import Foundation

/// The media backends Plozz can talk to.
///
/// Includes managed media servers, IPTV, network shares and music-only Subsonic.
/// Features above the provider layer use ``MediaProvider`` and its capability
/// contracts; a provider kind does not imply support for every media feature.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case jellyfin
    case plex
    case emby
    case silo
    case iptv
    /// A network media share over any ``MediaShareTransportKind``.
    /// Plozz owns its catalog, metadata enrichment and watch state instead of
    /// relying on a managed media server. It cannot request server transcoding.
    case mediaShare
    case subsonic

    public var displayName: String {  // l10n:content — brand/format name (Jellyfin/Emby/Plex), never translated; "Media Share" is grouped in for a uniform type
        switch self {
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        case .silo: return "Silo"
        case .subsonic: return "Navidrome (Subsonic)"
        case .iptv: return "IPTV"
        case .mediaShare: return "Media Share"
        }
    }

    /// Rank for choosing between two copies of the same title that are otherwise
    /// equal — same locality, same playability, same quality.
    ///
    /// A managed server curates its library: cast, artwork, canonical titles,
    /// episode ordering. A media share is files on disk, and Plozz synthesises the
    /// rest, so the same show can arrive with no cast and a folder-derived title.
    /// Given otherwise equal copies, prefer the managed server's richer metadata.
    /// This ranks metadata, not whether a source is supported.
    ///
    /// Deliberately the LAST tie-break, below locality and playability: a local
    /// share still beats a remote Jellyfin, because a copy that plays instantly
    /// beats a richer one that buffers.
    public var metadataRichnessRank: Int {
        switch self {
        case .jellyfin, .emby, .plex, .silo, .subsonic: return 1
        case .mediaShare, .iptv: return 0
        }
    }

    /// Jellyfin and Emby share the MediaBrowser API lineage and intentionally use
    /// the same provider implementation, with server-specific compatibility rules.
    public var usesMediaBrowserAPI: Bool {
        self == .jellyfin || self == .emby
    }

    public var supportsAccountReauthentication: Bool {
        switch self {
        case .jellyfin, .emby, .plex, .silo, .subsonic: true
        case .iptv, .mediaShare: false
        }
    }

    /// A rotating Silo refresh token belongs to one installation's login.
    /// Other devices pair independently instead of racing the same token.
    public var permitsCredentialTransfer: Bool { self != .silo }

    /// Whether `MediaProvider.playbackInfo` is idempotent — i.e. resolving a
    /// stream has **no server-side session side-effects**, so it is safe to call
    /// EARLY (an eager next-episode prefetch) without opening a duplicate or
    /// orphaned playback/transcode session.
    ///
    /// - **Plex / mediaShare / Subsonic → `true`.** Plex `playbackInfo` is a read-only
    ///   metadata GET with a deterministic client-minted session id; a media
    ///   share builds a transport-backed request, and Subsonic builds a music
    ///   stream request without opening a playback session. Repeated resolution
    ///   does not create a session, so the next episode can be resolved when it's
    ///   known for a near-instant hand-off.
    /// - **Jellyfin / Emby → `false`.** Their `POST /Items/{id}/PlaybackInfo`
    ///   (`AutoOpenLiveStream: true`) mints a NEW server `PlaySessionId` and may
    ///   start a transcode job. Prefetching it eagerly would orphan a session, so
    ///   the next-episode prefetch is deferred to the hand-off window and the
    ///   resolved request is reused (or released on back-out) rather than
    ///   re-resolved.
    /// - **Silo / IPTV → `false`.** These paths do not opt into eager resolution;
    ///   callers must retain their session/live-stream lifecycle boundaries.
    public var playbackInfoIsIdempotent: Bool {
        switch self {
        case .plex, .mediaShare, .subsonic: return true
        case .jellyfin, .emby, .silo, .iptv: return false
        }
    }
}
