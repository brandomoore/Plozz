import Foundation

/// The primary call-to-action a Home **hero** slide offers for a title, derived
/// purely from the title's discovery-backend `availability` (Seerr/Overseerr) and
/// live `downloadProgress`, plus whether Seerr is currently connected.
///
/// Kept in `CoreModels` (Foundation-only, no SwiftUI, no Seerr import) so the
/// decision is exhaustively unit-testable and the UI never reaches into the Seerr
/// module to figure out which button to show.
public enum HeroCTA: Equatable, Sendable {
    /// Play/Resume — an ordinary library item, or a featured title already
    /// available (fully or partially) in the library.
    case play
    /// A one-tap "Request" — a featured title that isn't in the library yet and
    /// can be requested, shown only while Seerr is connected.
    case request
    /// The title has an approved request that's **actively downloading** — there's
    /// a real item in the Radarr/Sonarr queue. `progress` is the aggregate fetched
    /// fraction (`0..<1`). Approved-but-not-yet-downloading (no queue item, e.g.
    /// still searching for a release) is reported as ``requested``, not this.
    case downloading(progress: Double)
    /// A request exists but nothing is downloading yet — either awaiting approval
    /// (`pending`) or approved and still searching (`processing` with no active
    /// queue item). Shown as a "Requested" status.
    case requested
    /// An approved request for a future release, without library or queue evidence.
    case awaitingRelease
    /// No Play/Request button: no verified playable copy, and requesting is
    /// unavailable or the server already reports availability. The title remains
    /// navigable without offering an unverified Play or a redundant Request.
    case unavailable

    public var requestStatusTitle: LocalizedStringResource {
        self == .awaitingRelease ? "Requested · Unreleased" : "Requested"
    }

    public var requestStatusSystemImage: String {
        self == .awaitingRelease ? "calendar" : "clock"
    }
}

public struct MediaOwnershipPresentation: Equatable, Sendable {
    public let canPlay: Bool
    public let showsProviderManagement: Bool
    public let showsPlaybackDetails: Bool

    public init(hasValidatedPlayableSource: Bool) {
        canPlay = hasValidatedPlayableSource
        showsProviderManagement = hasValidatedPlayableSource
        showsPlaybackDetails = hasValidatedPlayableSource
    }
}

public extension MediaItem {
    var startsWatching: Bool {
        kind == .episode
            && (seasonNumber ?? 0) > 0
            && episodeNumber == 1
            && locallyValidatedPlayableSource
            && !isUpcomingUnaired
            && !isPlayed
            && !hasBeenPlayed
            && (resumePosition ?? 0) == 0
            && (playedPercentage ?? 0) == 0
    }

    var playActionTitle: LocalizedStringResource {
        if let source = externalSourceVersion {
            return source.externalLink?.actionTitle ?? LocalizedStringResource("Open Link", comment: "Open an imported external title link whose destination has not loaded yet.")
        }
        return startsWatching
            ? LocalizedStringResource("Start watching", comment: "Play an unstarted first episode. The season and episode numbers follow this label.")
            : "Play"
    }

    /// The hero primary CTA for this item given the current Seerr connection.
    func heroCTA(
        seerConnected: Bool, now: Date = Date(), calendar: Calendar = .current
    ) -> HeroCTA {
        Self.heroCTA(
            availability: availability,
            downloadProgress: downloadProgress,
            hasValidatedPlayableSource: hasPlayableLibraryTarget(),
            seerConnected: seerConnected,
            releaseDate: releaseDate,
            hasDownloadActivity: hasRequestDownloadActivity == true,
            now: now, calendar: calendar
        )
    }

    /// Whether this is a Seerr **discovery** title that isn't in the library — it
    /// carries a discovery `availability` that is requestable or in-flight
    /// (`unknown`/`pending`/`processing`/`deleted`), as opposed to an *owned*
    /// discovery title (`available`/`partiallyAvailable`, which still resolves to a
    /// real library copy via the identity index) or an ordinary library item (no
    /// `availability`).
    ///
    /// Drives request-focused detail routing and the suppression of library
    /// actions (Play / Watchlist / Watched / Refresh) that can't apply to a title
    /// with no resolvable library id. Owned featured titles are deliberately
    /// excluded so their working Play/Watchlist affordances are preserved.
    var isNotInLibraryDiscovery: Bool {
        guard let availability else { return false }
        switch availability {
        case .available, .partiallyAvailable: return false
        case .unknown, .pending, .processing, .deleted: return true
        }
    }

    /// Whether this is a schedule-derived placeholder for an episode that has not
    /// aired yet, and so exists in no library on any server.
    ///
    /// Like ``isNotInLibraryDiscovery`` it stays focusable and navigable — you can
    /// browse the rest of a season's run and read what's coming — but every action
    /// that needs a real file (Play, Watched, Download) is suppressed, because
    /// there is nothing to act on yet.
    var isUpcomingUnaired: Bool { scheduledAirDate != nil }

    /// Whether this item resolves to a real playable library record. Only explicit
    /// local validation or a source supplied by the active identity index counts.
    /// `sourceAccountID`, global provider ids, and synced binding hints do not.
    func hasPlayableLibraryTarget(additionalSources: [MediaSourceRef] = []) -> Bool {
        if locallyValidatedPlayableSource { return true }
        // Discovery feeds undergo explicit active-profile/library verification.
        // An index hint cannot override a rejection from that verification.
        guard discoverySources.isEmpty else { return false }
        return additionalSources.contains {
            $0.kind == nil || $0.kind == kind
        }
    }

    func ownershipPresentation(
        additionalSources: [MediaSourceRef] = []
    ) -> MediaOwnershipPresentation {
        MediaOwnershipPresentation(
            hasValidatedPlayableSource: hasPlayableLibraryTarget(
                additionalSources: additionalSources
            )
        )
    }

    /// Pure decision used by ``heroCTA(seerConnected:)`` and directly by the hero
    /// (which may apply a just-tapped optimistic `availability` override).
    ///
    /// Verified library copies offer Play. Server availability alone cannot
    /// establish access for this profile, but must not offer a duplicate request.
    /// Other request states require a connected Seerr service.
    static func heroCTA(
        availability: MediaAvailabilityStatus?,
        downloadProgress: Double?,
        hasValidatedPlayableSource: Bool,
        seerConnected: Bool,
        releaseDate: Date? = nil,
        hasDownloadActivity: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HeroCTA {
        if hasValidatedPlayableSource { return .play }
        guard seerConnected else { return .unavailable }
        switch availability {
        case .pending:
            return .requested
        case .processing:
            if let downloadProgress {
                return .downloading(progress: downloadProgress)
            }
            if !hasDownloadActivity,
               SeasonEpisodeAvailability.scheduled(
                   airDate: releaseDate, now: now, calendar: calendar
               ) == .unaired {
                return .awaitingRelease
            }
            return .requested
        case .available, .partiallyAvailable:
            return .unavailable
        case .none, .unknown, .deleted:
            return .request
        }
    }
}
